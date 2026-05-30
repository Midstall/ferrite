const std = @import("std");
const ferrite = std.os.ferrite;

pub const panic = ferrite.panic;
const p9 = ferrite.p9;
const fs = ferrite.fs;

const MAX_FIDS = 32;
const NAME_MAX = 128;
const LISTING_MAX = 8192;
const SCAN_BUF_BYTES: usize = 64 * 1024;
const ENTRIES_PER_PAGE: usize = 4096 / @sizeOf(Entry);

const CPIO_HEADER = 110;
const CPIO_MAGIC = "070701";
const TRAILER = "TRAILER!!!";

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;

const Entry = struct {
    name: [NAME_MAX]u8 = @splat(0),
    name_len: u16 = 0,
    data_off: u32 = 0,
    data_len: u32 = 0,
};

const FidKind = enum { dir, file };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .dir,
    prefix: [NAME_MAX]u8 = @splat(0),
    prefix_len: u16 = 0,
    entry_idx: u16 = 0,
};

const State = struct {
    fids: [MAX_FIDS]Fid = @splat(.{}),
    entries_ptr: [*]Entry = undefined,
    entries_cap: u32 = 0,
    entries_len: u32 = 0,
    backing: ferrite.fs.File = undefined,
};

var state: State = .{};

pub fn main() void {
    const argv = ferrite.argv;
    if (argv.len < 4) {
        ferrite.console.print("usage: mount.cpio <backing-path> <authority> <mount-prefix>\n", .{}) catch {};
        return;
    }
    const backing_path = std.mem.span(argv[1]);
    const authority = std.mem.span(argv[2]);
    const mount_prefix = std.mem.span(argv[3]);

    state.backing = openBackingWithRetry(backing_path) orelse {
        ferrite.console.print("[mount.cpio] {s} never appeared. Exiting\n", .{backing_path}) catch {};
        return;
    };

    if (!scanArchive()) {
        ferrite.console.print("[mount.cpio] scan failed. Exiting\n", .{}) catch {};
        return;
    }
    ferrite.console.print("[mount.cpio] scanned {d} entries\n", .{state.entries_len}) catch {};

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(authority, svc_send) catch |e| {
        ferrite.console.print("[mount.cpio] register failed: {t}\n", .{e}) catch {};
        return;
    };

    // Permission = prefix already mounted via /etc/mounts; silent.
    fs.mount(mount_prefix, authority) catch |e| switch (e) {
        error.Permission => {},
        else => ferrite.console.print("[mount.cpio] mount({s} -> {s}) failed: {t}\n", .{ mount_prefix, authority, e }) catch {},
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .dir };

    const handlers: fs.Handlers(State) = .{
        .on_walk = onWalk,
        .on_open = onOpen,
        .on_read = onRead,
        .on_write = onWrite,
        .on_close = onClose,
        .on_status = onStatus,
    };
    fs.serve(State, svc_recv, &state, &handlers);
}

fn openBackingWithRetry(path: []const u8) ?ferrite.fs.File {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(path, &uri_buf) catch return null;
    var attempts: u32 = 0;
    while (attempts < 4) : (attempts += 1) {
        if (fs.open(uri, .{ .mode = .read })) |f| return f else |_| {}
        var i: u32 = 0;
        while (i < 4) : (i += 1) ferrite.yield();
    }
    return null;
}

/// Sliding window over the backing file; one RPC per refill.
const Reader = struct {
    backing: *ferrite.fs.File,
    buf: [SCAN_BUF_BYTES]u8 = undefined,
    base: u64 = 0,
    len: usize = 0,

    fn slice(self: *Reader, off: u64, want: usize) ?[]const u8 {
        if (off < self.base or off + want > self.base + self.len) {
            self.base = off;
            self.len = 0;
            while (self.len < self.buf.len) {
                const got = self.backing.read(off + self.len, self.buf[self.len..]) catch return null;
                if (got == 0) break;
                self.len += got;
                if (self.len >= want) break;
            }
        }
        if (off + want > self.base + self.len) return null;
        const start: usize = @intCast(off - self.base);
        return self.buf[start..][0..want];
    }
};

var scan_reader: Reader = .{ .backing = undefined };

fn scanArchive() bool {
    scan_reader = .{ .backing = &state.backing };
    var off: u64 = 0;
    while (true) {
        const hdr = scan_reader.slice(off, CPIO_HEADER) orelse return state.entries_len > 0;
        if (!std.mem.eql(u8, hdr[0..6], CPIO_MAGIC)) return false;

        const mode = parseHex(hdr[14..22]) orelse return false;
        const filesize = parseHex(hdr[54..62]) orelse return false;
        const namesize = parseHex(hdr[94..102]) orelse return false;
        if (namesize == 0 or namesize > NAME_MAX + 1) return false;

        const name_with_nul = scan_reader.slice(off + CPIO_HEADER, @intCast(namesize)) orelse return false;
        const name = if (name_with_nul[name_with_nul.len - 1] == 0)
            name_with_nul[0 .. name_with_nul.len - 1]
        else
            name_with_nul;

        const data_off: u64 = alignUp(off + CPIO_HEADER + namesize, 4);
        const next_off: u64 = alignUp(data_off + filesize, 4);

        if (std.mem.eql(u8, name, TRAILER)) return true;

        if ((mode & S_IFMT) == S_IFREG) {
            if (state.entries_len >= state.entries_cap) {
                if (!growEntries()) return state.entries_len > 0;
            }
            const e = &state.entries_ptr[state.entries_len];
            const copy_len = @min(name.len, NAME_MAX);
            @memcpy(e.name[0..copy_len], name[0..copy_len]);
            e.name_len = @intCast(copy_len);
            e.data_off = @intCast(data_off);
            e.data_len = @intCast(filesize);
            state.entries_len += 1;
        }
        off = next_off;
    }
}

/// Relies on successive allocPages being virtually contiguous (verified).
fn growEntries() bool {
    var va: usize = 0;
    if (ferrite.allocPages(1, &va) != 0) return false;
    const new_ptr: [*]Entry = @ptrFromInt(@as(usize, @intCast(va)));
    if (state.entries_cap == 0) {
        state.entries_ptr = new_ptr;
    } else {
        const expected = @intFromPtr(state.entries_ptr) + state.entries_cap * @sizeOf(Entry);
        if (@intFromPtr(new_ptr) < expected or @intFromPtr(new_ptr) > expected + 4095) {
            return false;
        }
    }
    state.entries_cap += @intCast(ENTRIES_PER_PAGE);
    return true;
}

fn parseHex(field: []const u8) ?u64 {
    var v: u64 = 0;
    for (field) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

inline fn alignUp(x: u64, a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}

const ResolveResult = union(enum) {
    file: u16,
    dir,
};

fn resolve(path: []const u8) ?ResolveResult {
    if (path.len == 0) return .dir;
    var i: u16 = 0;
    while (i < state.entries_len) : (i += 1) {
        const ename = state.entries_ptr[i].name[0..state.entries_ptr[i].name_len];
        if (std.mem.eql(u8, ename, path)) return .{ .file = i };
    }
    i = 0;
    while (i < state.entries_len) : (i += 1) {
        const ename = state.entries_ptr[i].name[0..state.entries_ptr[i].name_len];
        if (ename.len > path.len and
            std.mem.startsWith(u8, ename, path) and
            ename[path.len] == '/') return .dir;
    }
    return null;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (s.fids[fid].kind != .dir) return error.NotFound;

    var full: [NAME_MAX]u8 = undefined;
    var full_len: usize = 0;
    const pre = s.fids[fid].prefix[0..s.fids[fid].prefix_len];
    if (pre.len > 0) {
        const trimmed = if (pre[pre.len - 1] == '/') pre[0 .. pre.len - 1] else pre;
        if (trimmed.len > full.len) return error.NotFound;
        @memcpy(full[0..trimmed.len], trimmed);
        full_len = trimmed.len;
    }
    if (path.len > 0) {
        if (full_len > 0) {
            if (full_len + 1 > full.len) return error.NotFound;
            full[full_len] = '/';
            full_len += 1;
        }
        if (full_len + path.len > full.len) return error.NotFound;
        @memcpy(full[full_len..][0..path.len], path);
        full_len += path.len;
    }
    var view: []const u8 = full[0..full_len];
    while (view.len > 0 and view[0] == '/') view = view[1..];

    const r = resolve(view) orelse return error.NotFound;

    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (s.fids[i].used) continue;
        switch (r) {
            .file => |idx| {
                s.fids[i] = .{ .used = true, .kind = .file, .entry_idx = idx };
            },
            .dir => {
                s.fids[i] = .{ .used = true, .kind = .dir };
                if (view.len > 0) {
                    @memcpy(s.fids[i].prefix[0..view.len], view);
                    s.fids[i].prefix[view.len] = '/';
                    s.fids[i].prefix_len = @intCast(view.len + 1);
                }
            },
        }
        return .{ .bound = i };
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    switch (s.fids[fid].kind) {
        .file => {
            const e = &s.entries_ptr[s.fids[fid].entry_idx];
            if (offset >= e.data_len) return 0;
            const remaining = e.data_len - @as(u32, @intCast(offset));
            const want = @min(@as(usize, remaining), out.len);
            const got = state.backing.read(e.data_off + offset, out[0..want]) catch return error.BadOp;
            return got;
        },
        .dir => return listDir(s.fids[fid].prefix[0..s.fids[fid].prefix_len], offset, out),
    }
}

fn listDir(prefix: []const u8, offset: u64, out: []u8) fs.HandlerError!usize {
    var listing: [LISTING_MAX]u8 = undefined;
    var w: usize = 0;
    var i: u32 = 0;
    while (i < state.entries_len) : (i += 1) {
        const name = state.entries_ptr[i].name[0..state.entries_ptr[i].name_len];
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const rest = name[prefix.len..];
        if (rest.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const comp = rest[0..slash];
        if (comp.len == 0) continue;

        if (containsName(listing[0..w], comp)) continue;
        if (w + comp.len + 1 > listing.len) break;
        @memcpy(listing[w..][0..comp.len], comp);
        w += comp.len;
        listing[w] = '\n';
        w += 1;
    }
    if (offset >= w) return 0;
    const start: usize = @intCast(offset);
    const n = @min(w - start, out.len);
    @memcpy(out[0..n], listing[start..][0..n]);
    return n;
}

fn containsName(listing: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, listing, '\n');
    while (it.next()) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn onWrite(_: *State, _: u32, _: u64, _: []const u8) fs.HandlerError!u32 {
    return error.BadOp;
}

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .dir => .{ .kind = .dir, .size = 0 },
        .file => .{ .kind = .file, .size = s.entries_ptr[s.fids[fid].entry_idx].data_len },
    };
}
