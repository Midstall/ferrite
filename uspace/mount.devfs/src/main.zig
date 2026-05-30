const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const URI_PREFIX = "com.midstall.ferrite.devfs@v0";

const MAX_FIDS = 16;
const MAX_DEVICES = 16;
const MAX_ALIASES = 16;
const NAME_MAX = 16;

const ETC_DEVICES = "etc/devices";

const NodeKind = enum { root, console, banner };

const BANNER: []const u8 = "ferrite microkernel @ aarch64\n";

const Fid = struct {
    used: bool = false,
    node: NodeKind = .root,
    opened: bool = false,
};

const Device = struct {
    used: bool = false,
    kind: p9.DeviceKind = .char,
    name_len: u8 = 0,
    name: [NAME_MAX]u8 = @splat(0),
    cap: u32 = 0,
};

const Alias = struct {
    used: bool = false,
    name_len: u8 = 0,
    name: [NAME_MAX]u8 = @splat(0),
    target_len: u8 = 0,
    target: [NAME_MAX]u8 = @splat(0),
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
    devices: [MAX_DEVICES]Device = @splat(.{}),
    aliases: [MAX_ALIASES]Alias = @splat(.{}),
};

var state: State = .{};

fn findDevice(s: *State, name: []const u8) ?*Device {
    if (name.len == 0 or name.len > NAME_MAX) return null;
    for (&s.devices) |*d| {
        if (!d.used) continue;
        if (d.name_len != name.len) continue;
        if (std.mem.eql(u8, d.name[0..d.name_len], name)) return d;
    }
    return null;
}

fn findAlias(s: *State, name: []const u8) ?[]const u8 {
    for (&s.aliases) |*a| {
        if (!a.used) continue;
        if (a.name_len != name.len) continue;
        if (std.mem.eql(u8, a.name[0..a.name_len], name)) return a.target[0..a.target_len];
    }
    return null;
}

fn loadAliases(s: *State) void {
    var buf: [512]u8 = undefined;
    const n = ferrite.readInitrdFile(ETC_DEVICES, &buf);
    if (n == 0) return;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
        const alias_name = tok.next() orelse continue;
        const target = tok.next() orelse continue;
        if (alias_name.len > NAME_MAX or target.len > NAME_MAX) continue;
        for (&s.aliases) |*a| {
            if (a.used) continue;
            a.used = true;
            @memcpy(a.name[0..alias_name.len], alias_name);
            a.name_len = @intCast(alias_name.len);
            @memcpy(a.target[0..target.len], target);
            a.target_len = @intCast(target.len);
            break;
        }
    }
}

fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

pub fn main() void {
    const ch = ferrite.channelCreate(0);
    if (ch < 0) {
        ferrite.console.print("[mount.devfs] channelCreate failed: {d}\n", .{ch}) catch {};
        return;
    }
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[mount.devfs] register failed: {t}\n", .{e}) catch {};
        return;
    };

    state.fids[0] = .{ .used = true, .node = .root, .opened = true };

    loadAliases(&state);

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
        .on_register_device = onRegisterDevice,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    var cur = s.fids[fid].node;
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    while (iter.next()) |comp| {
        switch (cur) {
            .root => {
                // Hop-bounded alias chain; real drivers win over /etc/devices.
                var resolved: []const u8 = comp;
                var hops: u8 = 0;
                while (hops < 4) : (hops += 1) {
                    if (std.mem.eql(u8, resolved, "console")) {
                        cur = .console;
                        break;
                    } else if (std.mem.eql(u8, resolved, "banner")) {
                        cur = .banner;
                        break;
                    } else if (findDevice(s, resolved)) |dev| {
                        const rest_start = (@intFromPtr(comp.ptr) - @intFromPtr(path.ptr)) + comp.len;
                        var remaining: []const u8 = if (rest_start >= path.len) "" else path[rest_start..];
                        if (remaining.len > 0 and remaining[0] == '/') remaining = remaining[1..];
                        return .{ .handoff = .{ .cap = dev.cap, .remaining = remaining } };
                    } else if (findAlias(s, resolved)) |target| {
                        resolved = target;
                        continue;
                    } else return error.NotFound;
                } else return error.NotFound;
            },
            .console, .banner => return error.NotFound,
        }
    }
    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = .{ .used = true, .node = cur, .opened = false };
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onRegisterDevice(s: *State, args: p9.RegisterDeviceArgs, cap: u32) fs.HandlerError!void {
    if (args.name.len == 0 or args.name.len > NAME_MAX) return error.BadOp;
    if (findDevice(s, args.name) != null) return error.BadOp;
    for (&s.devices) |*d| {
        if (d.used) continue;
        d.used = true;
        d.kind = args.kind;
        d.name_len = @intCast(args.name.len);
        @memcpy(d.name[0..args.name.len], args.name);
        d.cap = cap;
        return;
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].node) {
        .console => {
            const n = ferrite.readConsole(out);
            if (n < 0) return error.BadOp;
            return @intCast(n);
        },
        .banner => return sliceAt(BANNER, offset, out),
        .root => {
            var tmp: [512]u8 = undefined;
            var w: usize = 0;
            const statics = "banner\nconsole\n";
            @memcpy(tmp[w..][0..statics.len], statics);
            w += statics.len;
            for (&s.devices) |*d| {
                if (!d.used) continue;
                if (w + d.name_len + 1 > tmp.len) break;
                @memcpy(tmp[w..][0..d.name_len], d.name[0..d.name_len]);
                w += d.name_len;
                tmp[w] = '\n';
                w += 1;
            }
            return sliceAt(tmp[0..w], offset, out);
        },
    }
}

fn sliceAt(src: []const u8, offset: u64, out: []u8) usize {
    if (offset >= src.len) return 0;
    const start: usize = @intCast(offset);
    const n = @min(src.len - start, out.len);
    @memcpy(out[0..n], src[start..][0..n]);
    return n;
}

fn onWrite(s: *State, fid: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].node) {
        .console => {
            ferrite.console.writeAll(data) catch {};
            return @intCast(data.len);
        },
        .root, .banner => return error.BadOp,
    }
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].node) {
        .root => .{ .kind = .dir, .size = 0 },
        .console => .{ .kind = .file, .size = 0 },
        .banner => .{ .kind = .file, .size = BANNER.len },
    };
}
