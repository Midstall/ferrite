const std = @import("std");
const p9 = @import("p9.zig");
const uri = @import("uri.zig");
const syscall = @import("syscall.zig");

pub const Error = error{
    BadUri,
    NoNameserver,
    NoMemory,
    SendFailed,
    RecvFailed,
    Protocol,
    NotFound,
    Permission,
    BadFid,
    BadOffset,
    BadOp,
    ServerBusy,
};

pub const OpenOptions = struct {
    mode: p9.Mode = .read,
};

/// Resolve a Unix path to a service URI via the nameserver mount table.
pub fn resolvePath(path: []const u8, buf: []u8) Error![]const u8 {
    if (path.len == 0 or path[0] != '/') return error.BadUri;
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeResolveMount(&req, 1, path) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var dummy_cap: u32 = 0;
    const rn = syscall.recv(reply_recv, &resp, &dummy_cap);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (decoded.resp) {
        .resolve_mount => |m| return std.fmt.bufPrint(buf, "{s}:{s}", .{ m.authority, m.sub_path }) catch return error.BadUri,
        .err => |e| return errnoToError(e.errno),
        else => return error.Protocol,
    }
}

/// Look up a registered authority (e.g. "com.midstall.ferrite.net@v0") in the
/// nameserver, returning its service send cap (caller must capRelease it).
/// error.NotFound means no service has registered that authority yet, which is
/// how callers poll for a service becoming ready.
pub fn lookupService(authority: []const u8) Error!u32 {
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeLookup(&req, 1, authority) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var svc_cap: u32 = 0;
    const rn = syscall.recv(reply_recv, &resp, &svc_cap);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    return switch (decoded.resp) {
        .lookup => if (svc_cap != 0) svc_cap else error.NotFound,
        .err => |e| errnoToError(e.errno),
        else => error.Protocol,
    };
}

pub fn create(path: []const u8, kind: p9.Kind) Error!void {
    var uri_buf: [256]u8 = undefined;
    const uri_str = resolvePath(path, &uri_buf) catch |e| return e;
    return doCreateRemove(uri_str, .{ .create = .{ .kind = kind, .path = "" } });
}

pub fn remove(path: []const u8) Error!void {
    var uri_buf: [256]u8 = undefined;
    const uri_str = resolvePath(path, &uri_buf) catch |e| return e;
    return doCreateRemove(uri_str, .{ .remove = .{ .path = "" } });
}

/// Create a symbolic link at `linkpath` pointing to `target`.
pub fn symlink(linkpath: []const u8, target: []const u8) Error!void {
    var uri_buf: [256]u8 = undefined;
    const uri_str = resolvePath(linkpath, &uri_buf) catch |e| return e;
    return doCreateRemove(uri_str, .{ .symlink = .{ .path = "", .target = target } });
}

/// Read a symlink's target into `out` (without following it). Returns its length.
pub fn readlink(path: []const u8, out: []u8) Error!usize {
    var uri_buf: [256]u8 = undefined;
    const uri_str = resolvePath(path, &uri_buf) catch |e| return e;
    const parts = uri.parse(uri_str) catch return error.BadUri;
    var prefix_buf: [256]u8 = undefined;
    const prefix = uri.formatPrefix(&prefix_buf, parts) catch return error.BadUri;
    const svc_cap = lookupService(prefix) catch |e| return e;
    defer _ = syscall.capRelease(svc_cap);

    const sub = if (parts.path.len > 0 and parts.path[0] == '/') parts.path[1..] else parts.path;

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeReadlink(&req, 1, sub) catch return error.Protocol;
    if (syscall.send(svc_cap, req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var dummy: u32 = 0;
    const rn = syscall.recv(reply_recv, &resp, &dummy);
    if (rn < 0) return error.RecvFailed;
    const dec = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    return switch (dec.resp) {
        .readlink => |r| blk: {
            const n = @min(r.target.len, out.len);
            @memcpy(out[0..n], r.target[0..n]);
            break :blk n;
        },
        .err => |e| errnoToError(e.errno),
        else => error.Protocol,
    };
}

fn doCreateRemove(uri_str: []const u8, op: p9.Request) Error!void {
    const parts = uri.parse(uri_str) catch return error.BadUri;
    var prefix_buf: [256]u8 = undefined;
    const prefix = uri.formatPrefix(&prefix_buf, parts) catch return error.BadUri;

    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const lookup_packed = syscall.channelCreate(0);
    if (lookup_packed < 0) return error.NoMemory;
    const lookup_send: u32 = @truncate(@as(u64, @bitCast(lookup_packed)));
    const lookup_recv: u32 = @truncate(@as(u64, @bitCast(lookup_packed)) >> 32);
    defer _ = syscall.capRelease(lookup_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    var rlen = p9.encodeLookup(&req, 1, prefix) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], lookup_send) != 0) {
        _ = syscall.capRelease(lookup_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var svc_cap: u32 = 0;
    const rn = syscall.recv(lookup_recv, &resp, &svc_cap);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (decoded.resp) {
        .lookup => {},
        .err => |e| return errnoToError(e.errno),
        else => return error.Protocol,
    }
    defer _ = syscall.capRelease(svc_cap);

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    const path = if (parts.path.len > 0 and parts.path[0] == '/') parts.path[1..] else parts.path;

    rlen = switch (op) {
        .create => |c| p9.encodeCreate(&req, 1, .{ .kind = c.kind, .path = path }) catch return error.Protocol,
        .remove => p9.encodeRemove(&req, 1, .{ .path = path }) catch return error.Protocol,
        .symlink => |sl| p9.encodeSymlink(&req, 1, .{ .path = path, .target = sl.target }) catch return error.Protocol,
        else => return error.Protocol,
    };
    if (syscall.send(svc_cap, req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var op_resp: [p9.MAX_MSG]u8 = undefined;
    var dummy_cap: u32 = 0;
    const orn = syscall.recv(reply_recv, &op_resp, &dummy_cap);
    if (orn < 0) return error.RecvFailed;
    const odec = p9.decodeResponse(op_resp[0..@intCast(orn)]) catch return error.Protocol;
    return switch (odec.resp) {
        .create, .remove, .symlink => {},
        .err => |e| errnoToError(e.errno),
        else => error.Protocol,
    };
}

/// Writes NUL-separated names of mount points whose parent directory is `path`.
pub fn listMountsAt(path: []const u8, out: []u8) Error!usize {
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeListMounts(&req, 1, path) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var dummy: u32 = 0;
    const rn = syscall.recv(reply_recv, &resp, &dummy);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (decoded.resp) {
        .list_mounts => |m| {
            const n = @min(m.names.len, out.len);
            @memcpy(out[0..n], m.names[0..n]);
            return n;
        },
        .err => |e| return errnoToError(e.errno),
        else => return error.Protocol,
    }
}

/// Writes the full mount table as `prefix\tauthority\n` lines.
pub fn dumpMounts(out: []u8) Error!usize {
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeDumpMounts(&req, 1) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var dummy: u32 = 0;
    const rn = syscall.recv(reply_recv, &resp, &dummy);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (decoded.resp) {
        .dump_mounts => |m| {
            const n = @min(m.table.len, out.len);
            @memcpy(out[0..n], m.table[0..n]);
            return n;
        },
        .err => |e| return errnoToError(e.errno),
        else => return error.Protocol,
    }
}

/// `authority` must already be registered via `fs.register`.
pub fn mount(prefix: []const u8, authority: []const u8) Error!void {
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const reply_packed = syscall.channelCreate(0);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    defer _ = syscall.capRelease(reply_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    const rlen = p9.encodeAddMount(&req, 1, prefix, authority) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], reply_send) != 0) {
        _ = syscall.capRelease(reply_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var dummy_cap: u32 = 0;
    const rn = syscall.recv(reply_recv, &resp, &dummy_cap);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    return switch (decoded.resp) {
        .add_mount => {},
        .err => |e| errnoToError(e.errno),
        else => error.Protocol,
    };
}

// Fids are server-allocated so one service channel can host many clients
// without fid namespace collisions.

pub const File = struct {
    svc: u32,
    fid: u32,
    reply_send: u32,
    reply_recv: u32,

    fn rpc(self: *const File, req: []const u8, resp_buf: []u8) Error!struct { resp: p9.Response, cap: u32 } {
        const dup = syscall.capDup(self.reply_send);
        if (dup < 0) return error.NoMemory;
        const sr = syscall.send(self.svc, req, @intCast(dup));
        if (sr != 0) return error.SendFailed;
        var cap_out: u32 = 0;
        const rn = syscall.recv(self.reply_recv, resp_buf, &cap_out);
        if (rn < 0) return error.RecvFailed;
        const decoded = p9.decodeResponse(resp_buf[0..@intCast(rn)]) catch return error.Protocol;
        return .{ .resp = decoded.resp, .cap = cap_out };
    }

    pub fn read(self: *const File, offset: u64, dst: []u8) Error!usize {
        const want: u32 = @intCast(@min(dst.len, p9.MAX_MSG - p9.HEADER_SIZE - 2));
        var req: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeRead(&req, 1, .{ .fid = self.fid, .offset = offset, .count = want }) catch return error.Protocol;
        var resp: [p9.MAX_MSG]u8 = undefined;
        const r = (try self.rpc(req[0..n], &resp)).resp;
        return switch (r) {
            .read => |m| blk: {
                const copy = @min(dst.len, m.data.len);
                @memcpy(dst[0..copy], m.data[0..copy]);
                break :blk copy;
            },
            .err => |e| errnoToError(e.errno),
            else => error.Protocol,
        };
    }

    /// Keeps `DEPTH` reads in flight on this fid. Reply channel capacity in
    /// `fs.open` must match `DEPTH` so the server doesn't back-pressure.
    pub fn readPipelined(self: *const File, offset: u64, dst: []u8) Error!usize {
        const DEPTH: usize = 8;
        const PER_READ: usize = p9.MAX_MSG - p9.HEADER_SIZE - 2;

        var total: usize = 0;
        while (total < dst.len) {
            const remaining = dst.len - total;
            const want_chunks = (remaining + PER_READ - 1) / PER_READ;
            const chunks = @min(DEPTH, want_chunks);

            // 1-based tag lets us reassemble out-of-order replies.
            var i: usize = 0;
            while (i < chunks) : (i += 1) {
                const chunk_off_in_dst = total + i * PER_READ;
                if (chunk_off_in_dst >= dst.len) break;
                const want: u32 = @intCast(@min(dst.len - chunk_off_in_dst, PER_READ));

                var req: [p9.MAX_MSG]u8 = undefined;
                const tag: u8 = @intCast(i + 1);
                const n = p9.encodeRead(&req, tag, .{
                    .fid = self.fid,
                    .offset = offset + chunk_off_in_dst,
                    .count = want,
                }) catch return error.Protocol;

                const dup = syscall.capDup(self.reply_send);
                if (dup < 0) return error.NoMemory;
                if (syscall.send(self.svc, req[0..n], @intCast(dup)) != 0) {
                    _ = syscall.capRelease(@intCast(dup));
                    return error.SendFailed;
                }
            }

            var got_in_batch: usize = 0;
            var short_seen = false;
            i = 0;
            while (i < chunks) : (i += 1) {
                var resp: [p9.MAX_MSG]u8 = undefined;
                var cap_out: u32 = 0;
                const rn = syscall.recv(self.reply_recv, &resp, &cap_out);
                if (rn < 0) return error.RecvFailed;
                const tag = resp[1];
                if (tag == 0 or tag > chunks) return error.Protocol;
                const slot: usize = tag - 1;
                const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
                switch (decoded.resp) {
                    .read => |m| {
                        const dst_off = total + slot * PER_READ;
                        const room = dst.len - dst_off;
                        const copy = @min(m.data.len, room);
                        @memcpy(dst[dst_off..][0..copy], m.data[0..copy]);
                        got_in_batch += copy;
                        const asked: u32 = @intCast(@min(room, PER_READ));
                        if (m.data.len < asked) short_seen = true;
                    },
                    .err => |e| return errnoToError(e.errno),
                    else => return error.Protocol,
                }
            }

            total += got_in_batch;
            if (short_seen) break;
        }
        return total;
    }

    pub fn write(self: *const File, offset: u64, bytes: []const u8) Error!u32 {
        const cap: usize = p9.MAX_MSG - p9.HEADER_SIZE - 14;
        const slice = bytes[0..@min(bytes.len, cap)];
        var req: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeWrite(&req, 1, .{ .fid = self.fid, .offset = offset, .data = slice }) catch return error.Protocol;
        var resp: [p9.MAX_MSG]u8 = undefined;
        const r = (try self.rpc(req[0..n], &resp)).resp;
        return switch (r) {
            .write => |m| m.count,
            .err => |e| errnoToError(e.errno),
            else => error.Protocol,
        };
    }

    pub fn writeAll(self: *const File, bytes: []const u8) Error!usize {
        var off: u64 = 0;
        var total: usize = 0;
        while (total < bytes.len) {
            const n = try self.write(off, bytes[total..]);
            if (n == 0) return total;
            total += n;
            off += n;
        }
        return total;
    }

    pub fn status(self: *const File) Error!p9.StatusReply {
        var req: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeStatus(&req, 1, .{ .fid = self.fid }) catch return error.Protocol;
        var resp: [p9.MAX_MSG]u8 = undefined;
        const r = (try self.rpc(req[0..n], &resp)).resp;
        return switch (r) {
            .status => |m| m,
            .err => |e| errnoToError(e.errno),
            else => error.Protocol,
        };
    }

    pub fn close(self: *const File) void {
        var req: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeClose(&req, 1, .{ .fid = self.fid }) catch return;
        var resp: [p9.MAX_MSG]u8 = undefined;
        _ = self.rpc(req[0..n], &resp) catch {};
        _ = syscall.capRelease(self.svc);
        _ = syscall.capRelease(self.reply_send);
        _ = syscall.capRelease(self.reply_recv);
    }
};

pub fn open(uri_str: []const u8, opts: OpenOptions) Error!File {
    const parts = uri.parse(uri_str) catch return error.BadUri;
    var prefix_buf: [256]u8 = undefined;
    const prefix = uri.formatPrefix(&prefix_buf, parts) catch return error.BadUri;

    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const lookup_packed = syscall.channelCreate(0);
    if (lookup_packed < 0) return error.NoMemory;
    const lookup_send: u32 = @truncate(@as(u64, @bitCast(lookup_packed)));
    const lookup_recv: u32 = @truncate(@as(u64, @bitCast(lookup_packed)) >> 32);
    defer _ = syscall.capRelease(lookup_recv);

    var req: [p9.MAX_MSG]u8 = undefined;
    var rlen = p9.encodeLookup(&req, 1, prefix) catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..rlen], lookup_send) != 0) {
        _ = syscall.capRelease(lookup_send);
        return error.SendFailed;
    }
    var resp: [p9.MAX_MSG]u8 = undefined;
    var svc_cap: u32 = 0;
    const rn = syscall.recv(lookup_recv, &resp, &svc_cap);
    if (rn < 0) return error.RecvFailed;
    const lookup_resp = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (lookup_resp.resp) {
        .lookup => {},
        .err => |e| {
            _ = syscall.capRelease(svc_cap);
            return errnoToError(e.errno);
        },
        else => {
            _ = syscall.capRelease(svc_cap);
            return error.Protocol;
        },
    }
    errdefer _ = syscall.capRelease(svc_cap);

    // Must match readPipelined DEPTH.
    const reply_packed = syscall.channelCreate(8);
    if (reply_packed < 0) return error.NoMemory;
    const reply_send: u32 = @truncate(@as(u64, @bitCast(reply_packed)));
    const reply_recv: u32 = @truncate(@as(u64, @bitCast(reply_packed)) >> 32);
    errdefer _ = syscall.capRelease(reply_send);
    errdefer _ = syscall.capRelease(reply_recv);

    var file: File = .{
        .svc = svc_cap,
        .fid = 0,
        .reply_send = reply_send,
        .reply_recv = reply_recv,
    };

    var path = if (parts.path.len > 0 and parts.path[0] == '/') parts.path[1..] else parts.path;
    // Stash remaining_path before the next rpc clobbers `resp`.
    var path_stash: [256]u8 = undefined;
    var hops: u32 = 0;
    while (true) : (hops += 1) {
        if (hops > 4) return error.Protocol;
        rlen = p9.encodeWalk(&req, 1, .{ .fid = 0, .path = path }) catch return error.Protocol;
        const r = try file.rpc(req[0..rlen], &resp);
        switch (r.resp) {
            .walk => |m| {
                file.fid = m.newfid;
                break;
            },
            .walk_redirect => |m| {
                if (r.cap == 0) return error.Protocol;
                file.svc = r.cap;
                if (m.remaining_path.len > path_stash.len) return error.Protocol;
                @memcpy(path_stash[0..m.remaining_path.len], m.remaining_path);
                path = path_stash[0..m.remaining_path.len];
                continue;
            },
            .err => |e| return errnoToError(e.errno),
            else => return error.Protocol,
        }
    }

    rlen = p9.encodeOpen(&req, 1, .{ .fid = file.fid, .mode = opts.mode }) catch return error.Protocol;
    const open_r = (try file.rpc(req[0..rlen], &resp)).resp;
    switch (open_r) {
        .open => {},
        .err => |e| return errnoToError(e.errno),
        else => return error.Protocol,
    }
    return file;
}

fn errnoToError(e: p9.Errno) Error {
    return switch (e) {
        .not_found => error.NotFound,
        .permission => error.Permission,
        .bad_fid => error.BadFid,
        .bad_offset => error.BadOffset,
        .bad_op => error.BadOp,
        .server_busy => error.ServerBusy,
        .truncated => error.Protocol,
        .ok => error.Protocol,
    };
}

pub const HandlerError = error{
    NotFound,
    Permission,
    BadFid,
    BadOffset,
    BadOp,
    ServerBusy,
    Truncated,
};

fn handlerErrToErrno(e: HandlerError) p9.Errno {
    return switch (e) {
        error.NotFound => .not_found,
        error.Permission => .permission,
        error.BadFid => .bad_fid,
        error.BadOffset => .bad_offset,
        error.BadOp => .bad_op,
        error.ServerBusy => .server_busy,
        error.Truncated => .truncated,
    };
}

pub const WalkResult = union(enum) {
    bound: u32,
    handoff: struct { cap: u32, remaining: []const u8 },
};

/// Handler MUST eventually call `respondRead` or `respondErr` or it leaks
/// the reply cap and starves the client.
pub const PendingRead = struct {
    reply_cap: u32,
    tag: u8,
    fid: u32,
    offset: u64,
    want: u32,

    pub fn respondRead(self: PendingRead, data: []const u8) void {
        var resp: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeReadReply(&resp, self.tag, data) catch {
            _ = syscall.capRelease(self.reply_cap);
            return;
        };
        _ = syscall.send(self.reply_cap, resp[0..n], 0);
        _ = syscall.capRelease(self.reply_cap);
    }

    pub fn respondErr(self: PendingRead, errno: p9.Errno) void {
        var resp: [p9.MAX_MSG]u8 = undefined;
        const n = p9.encodeErrReply(&resp, self.tag, errno) catch {
            _ = syscall.capRelease(self.reply_cap);
            return;
        };
        _ = syscall.send(self.reply_cap, resp[0..n], 0);
        _ = syscall.capRelease(self.reply_cap);
    }
};

pub const ReadOutcome = union(enum) {
    /// fs.serve sends + releases reply_cap. Slice must outlive the send.
    immediate: []const u8,
    /// Handler owns reply_cap and will respond via PendingRead.
    deferred,
    /// fs.serve falls through to sync `on_read`.
    fall_through,
};

pub fn Handlers(comptime Ctx: type) type {
    return struct {
        on_walk: *const fn (ctx: *Ctx, fid: u32, path: []const u8) HandlerError!WalkResult,
        on_open: *const fn (ctx: *Ctx, fid: u32, mode: p9.Mode) HandlerError!void,
        on_read: *const fn (ctx: *Ctx, fid: u32, offset: u64, out: []u8) HandlerError!usize,
        on_write: *const fn (ctx: *Ctx, fid: u32, offset: u64, data: []const u8) HandlerError!u32,
        on_close: *const fn (ctx: *Ctx, fid: u32) HandlerError!void,
        on_status: *const fn (ctx: *Ctx, fid: u32) HandlerError!p9.StatusReply,
        on_register_device: ?*const fn (ctx: *Ctx, args: p9.RegisterDeviceArgs, cap: u32) HandlerError!void = null,
        on_create: ?*const fn (ctx: *Ctx, kind: p9.Kind, path: []const u8) HandlerError!void = null,
        on_remove: ?*const fn (ctx: *Ctx, path: []const u8) HandlerError!void = null,
        on_symlink: ?*const fn (ctx: *Ctx, path: []const u8, target: []const u8) HandlerError!void = null,
        on_readlink: ?*const fn (ctx: *Ctx, path: []const u8, out: []u8) HandlerError!usize = null,
        /// Takes ownership of reply_cap so the handler can block without stalling fs.serve.
        on_read_async: ?*const fn (ctx: *Ctx, pending: PendingRead) HandlerError!ReadOutcome = null,
    };
}

pub fn spawnPath(path: []const u8, args: []const u8) i64 {
    var uri_buf: [256]u8 = undefined;
    const uri_str = resolvePath(path, &uri_buf) catch return -1;

    const file = open(uri_str, .{ .mode = .read }) catch return -1;
    defer file.close();

    const st = file.status() catch return -1;
    if (st.size == 0 or st.size > 16 * 1024 * 1024) return -1;

    const page_size = syscall.pageSize();
    const npages: usize = @intCast((st.size + page_size - 1) / page_size);
    var buf_va: usize = 0;
    if (syscall.allocPages(npages, &buf_va) != 0) return -1;

    const buf_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(buf_va)));
    var off: u64 = 0;
    while (off < st.size) {
        const n = file.read(off, buf_ptr[@intCast(off)..@intCast(st.size)]) catch return -1;
        if (n == 0) return -1;
        off += n;
    }

    return syscall.exec(buf_ptr[0..@intCast(st.size)], args);
}

/// Consumes `my_send_cap`. SYS_SEND transfers it to devfs.
pub fn registerDevice(name: []const u8, kind: p9.DeviceKind, my_send_cap: u32) Error!void {
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;

    const lookup_packed = syscall.channelCreate(0);
    if (lookup_packed < 0) return error.NoMemory;
    const lookup_send: u32 = @truncate(@as(u64, @bitCast(lookup_packed)));
    const lookup_recv: u32 = @truncate(@as(u64, @bitCast(lookup_packed)) >> 32);

    var req: [p9.MAX_MSG]u8 = undefined;
    var n: usize = p9.encodeLookup(&req, 1, "com.midstall.ferrite.devfs@v0") catch return error.Protocol;
    if (syscall.send(@intCast(ns_h), req[0..n], lookup_send) != 0) return error.SendFailed;

    var resp: [p9.MAX_MSG]u8 = undefined;
    var devfs_cap: u32 = 0;
    const rn = syscall.recv(lookup_recv, &resp, &devfs_cap);
    if (rn < 0) return error.RecvFailed;
    const decoded = p9.decodeResponse(resp[0..@intCast(rn)]) catch return error.Protocol;
    switch (decoded.resp) {
        .lookup => {},
        .err => |e| return errnoToError(e.errno),
        else => return error.Protocol,
    }

    n = p9.encodeRegisterDevice(&req, 1, .{ .kind = kind, .name = name }) catch return error.Protocol;
    if (syscall.send(devfs_cap, req[0..n], my_send_cap) != 0) return error.SendFailed;
}

pub fn register(prefix: []const u8, svc_send_cap: u32) Error!void {
    const ns_h = syscall.nsLookup("nameserver");
    if (ns_h < 0) return error.NoNameserver;
    var buf: [p9.MAX_MSG]u8 = undefined;
    const n = p9.encodeRegister(&buf, 1, prefix) catch return error.Protocol;
    const sr = syscall.send(@intCast(ns_h), buf[0..n], svc_send_cap);
    if (sr != 0) return error.SendFailed;
}

pub fn serve(
    comptime Ctx: type,
    req_recv: u32,
    ctx: *Ctx,
    handlers: *const Handlers(Ctx),
) void {
    var req_buf: [p9.MAX_MSG]u8 = undefined;
    var resp_buf: [p9.MAX_MSG]u8 = undefined;
    var scratch: [p9.MAX_MSG]u8 = undefined;

    while (true) {
        var reply_cap: u32 = 0;
        const n = syscall.recv(req_recv, &req_buf, &reply_cap);
        if (n < 0) return;

        const decoded = p9.decodeRequest(req_buf[0..@intCast(n)]) catch continue;
        if (reply_cap == 0) continue;
        const tag = decoded.hdr.tag;

        // register_device hands the cap to the handler and skips the reply.
        if (decoded.req == .register_device) {
            if (handlers.on_register_device) |handler| {
                handler(ctx, decoded.req.register_device, reply_cap) catch {
                    _ = syscall.capRelease(reply_cap);
                };
            } else _ = syscall.capRelease(reply_cap);
            continue;
        }

        var xfer_cap: u32 = 0;
        // Set when an async handler takes ownership of reply_cap.
        var defer_reply: bool = false;

        const reply_len: usize = switch (decoded.req) {
            .walk => |m| blk: {
                const result = handlers.on_walk(ctx, m.fid, m.path) catch |e|
                    break :blk (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue);
                switch (result) {
                    .bound => |newfid| break :blk p9.encodeWalkReply(&resp_buf, tag, .{ .newfid = newfid }) catch continue,
                    .handoff => |h| {
                        // Dup so the server retains a copy after send transfers ownership.
                        const dup = syscall.capDup(h.cap);
                        if (dup < 0) break :blk p9.encodeErrReply(&resp_buf, tag, .server_busy) catch continue;
                        xfer_cap = @intCast(dup);
                        break :blk p9.encodeWalkRedirect(&resp_buf, tag, .{ .remaining_path = h.remaining }) catch continue;
                    },
                }
            },

            .open => |m| if (handlers.on_open(ctx, m.fid, m.mode)) |_|
                (p9.encodeOpenReply(&resp_buf, tag) catch continue)
            else |e|
                (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue),

            .read => |m| blk: {
                const cap_bytes = p9.MAX_MSG - p9.HEADER_SIZE - 2;
                const want = @min(@as(usize, m.count), cap_bytes);
                if (handlers.on_read_async) |h| {
                    const pending = PendingRead{
                        .reply_cap = reply_cap,
                        .tag = tag,
                        .fid = m.fid,
                        .offset = m.offset,
                        .want = @intCast(want),
                    };
                    const outcome = h(ctx, pending) catch |e|
                        break :blk (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue);
                    switch (outcome) {
                        .immediate => |data| break :blk p9.encodeReadReply(&resp_buf, tag, data) catch continue,
                        .deferred => {
                            defer_reply = true;
                            break :blk 0;
                        },
                        .fall_through => {},
                    }
                }
                const got = handlers.on_read(ctx, m.fid, m.offset, scratch[0..want]) catch |e|
                    break :blk (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue);
                break :blk p9.encodeReadReply(&resp_buf, tag, scratch[0..got]) catch continue;
            },

            .write => |m| if (handlers.on_write(ctx, m.fid, m.offset, m.data)) |count|
                (p9.encodeWriteReply(&resp_buf, tag, count) catch continue)
            else |e|
                (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue),

            .close => |m| if (handlers.on_close(ctx, m.fid)) |_|
                (p9.encodeCloseReply(&resp_buf, tag) catch continue)
            else |e|
                (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue),

            .status => |m| if (handlers.on_status(ctx, m.fid)) |s|
                (p9.encodeStatusReply(&resp_buf, tag, s) catch continue)
            else |e|
                (p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue),

            .create => |m| if (handlers.on_create) |handler| blk: {
                if (handler(ctx, m.kind, m.path)) |_|
                    break :blk p9.encodeCreateReply(&resp_buf, tag) catch continue
                else |e|
                    break :blk p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue;
            } else (p9.encodeErrReply(&resp_buf, tag, .bad_op) catch continue),

            .remove => |m| if (handlers.on_remove) |handler| blk: {
                if (handler(ctx, m.path)) |_|
                    break :blk p9.encodeRemoveReply(&resp_buf, tag) catch continue
                else |e|
                    break :blk p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue;
            } else (p9.encodeErrReply(&resp_buf, tag, .bad_op) catch continue),

            .symlink => |m| if (handlers.on_symlink) |handler| blk: {
                if (handler(ctx, m.path, m.target)) |_|
                    break :blk p9.encodeSymlinkReply(&resp_buf, tag) catch continue
                else |e|
                    break :blk p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue;
            } else (p9.encodeErrReply(&resp_buf, tag, .bad_op) catch continue),

            .readlink => |m| if (handlers.on_readlink) |handler| blk: {
                if (handler(ctx, m.path, &scratch)) |rl|
                    break :blk p9.encodeReadlinkReply(&resp_buf, tag, scratch[0..rl]) catch continue
                else |e|
                    break :blk p9.encodeErrReply(&resp_buf, tag, handlerErrToErrno(e)) catch continue;
            } else (p9.encodeErrReply(&resp_buf, tag, .bad_op) catch continue),

            else => p9.encodeErrReply(&resp_buf, tag, .bad_op) catch continue,
        };

        if (defer_reply) continue;
        _ = syscall.send(reply_cap, resp_buf[0..reply_len], xfer_cap);
        _ = syscall.capRelease(reply_cap);
    }
}
