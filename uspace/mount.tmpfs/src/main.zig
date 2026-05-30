const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const DEFAULT_URI = "com.midstall.ferrite.tmpfs@v0";

const MAX_FIDS = 16;
const MAX_ENTRIES = 16;
const FILE_CAP: usize = 4096;
const NAME_MAX = 32;

const Entry = struct {
    used: bool = false,
    kind: p9.Kind = .file,
    name_buf: [NAME_MAX]u8 = @splat(0),
    name_len: u8 = 0,
    data: [FILE_CAP]u8 = undefined,
    size: usize = 0,

    fn nameSlice(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const FidTarget = union(enum) { root, entry: u8 };

const Fid = struct {
    used: bool = false,
    target: FidTarget = .root,
    opened: bool = false,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
    entries: [MAX_ENTRIES]Entry = @splat(.{}),
};

var state: State = .{};

pub fn main() void {
    const argv = ferrite.argv;
    const uri_prefix: []const u8 = if (argv.len >= 2) std.mem.span(argv[1]) else DEFAULT_URI;

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(uri_prefix, svc_send) catch |e| {
        ferrite.console.print("[mount.tmpfs:{s}] register failed: {t}\n", .{ uri_prefix, e }) catch {};
        return;
    };

    state.fids[0] = .{ .used = true, .target = .root, .opened = true };

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
        .on_create = onCreate,
        .on_remove = onRemove,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn findEntry(s: *State, name: []const u8) ?u8 {
    var i: u8 = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        const e = &s.entries[i];
        if (!e.used) continue;
        if (std.mem.eql(u8, e.nameSlice(), name)) return i;
    }
    return null;
}

fn allocEntry(s: *State, name: []const u8, kind: p9.Kind) ?u8 {
    if (name.len == 0 or name.len > NAME_MAX) return null;
    var i: u8 = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        const e = &s.entries[i];
        if (e.used) continue;
        e.used = true;
        e.kind = kind;
        @memcpy(e.name_buf[0..name.len], name);
        e.name_len = @intCast(name.len);
        e.size = 0;
        return i;
    }
    return null;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var target = s.fids[fid].target;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        switch (target) {
            .root => {
                const idx = findEntry(s, comp) orelse return error.NotFound;
                target = .{ .entry = idx };
            },
            .entry => return error.NotFound,
        }
    }
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .target = target, .opened = false };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].target) {
        .root => {
            var listing: [512]u8 = undefined;
            var w: usize = 0;
            for (&s.entries) |*e| {
                if (!e.used) continue;
                const name = e.nameSlice();
                if (w + name.len + 1 > listing.len) break;
                @memcpy(listing[w..][0..name.len], name);
                w += name.len;
                listing[w] = '\n';
                w += 1;
            }
            if (offset >= w) return 0;
            const start: usize = @intCast(offset);
            const n = @min(w - start, out.len);
            @memcpy(out[0..n], listing[start..][0..n]);
            return n;
        },
        .entry => |idx| {
            const e = &s.entries[idx];
            if (e.kind == .dir) return 0;
            if (offset >= e.size) return 0;
            const start: usize = @intCast(offset);
            const n = @min(e.size - start, out.len);
            @memcpy(out[0..n], e.data[start..][0..n]);
            return n;
        },
    }
}

fn onWrite(s: *State, fid: u32, offset: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].target) {
        .entry => |idx| {
            const e = &s.entries[idx];
            if (e.kind == .dir) return error.BadOp;
            const off: usize = @intCast(offset);
            if (off >= e.data.len) return error.BadOp;
            const space = e.data.len - off;
            const n = @min(space, data.len);
            @memcpy(e.data[off..][0..n], data[0..n]);
            if (off + n > e.size) e.size = off + n;
            return @intCast(n);
        },
        .root => return error.BadOp,
    }
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].target) {
        .root => .{ .kind = .dir, .size = 0 },
        .entry => |idx| .{ .kind = s.entries[idx].kind, .size = s.entries[idx].size },
    };
}

fn onCreate(s: *State, kind: p9.Kind, path: []const u8) fs.HandlerError!void {
    var name = path;
    if (name.len > 0 and name[0] == '/') name = name[1..];
    if (name.len == 0) return error.BadOp;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.BadOp;
    if (findEntry(s, name) != null) return error.BadOp;
    _ = allocEntry(s, name, kind) orelse return error.ServerBusy;
}

fn onRemove(s: *State, path: []const u8) fs.HandlerError!void {
    var name = path;
    if (name.len > 0 and name[0] == '/') name = name[1..];
    const idx = findEntry(s, name) orelse return error.NotFound;
    s.entries[idx] = .{};
}
