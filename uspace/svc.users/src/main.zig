const std = @import("std");
const ferrite = std.os.ferrite;
const p9 = ferrite.p9;
const fs = ferrite.fs;

pub const panic = ferrite.panic;

const URI_PREFIX = "com.midstall.ferrite.users@v0";

const MAX_USERS = 16;
const MAX_FIDS = 16;
const NAME_MAX = 32;
const PASS_MAX = 64;
const SALT_MAX = 32;
const HASH_HEX_LEN = 64;
const AUTH_BUF_MAX = NAME_MAX + 1 + PASS_MAX;

const ETC_USERS = "etc/users";
const ETC_USERS_BUF = 1024;

const User = struct {
    used: bool = false,
    name_buf: [NAME_MAX]u8 = @splat(0),
    name_len: u8 = 0,
    salt_buf: [SALT_MAX]u8 = @splat(0),
    salt_len: u8 = 0,
    hash_hex: [HASH_HEX_LEN]u8 = @splat(0),
    uid: u32 = 0,

    fn nameSlice(self: *const User) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn saltSlice(self: *const User) []const u8 {
        return self.salt_buf[0..self.salt_len];
    }
};

const FidKind = enum { root, auth, user_by_uid };

const Fid = struct {
    used: bool = false,
    opened: bool = false,
    kind: FidKind = .root,
    uid_arg: u32 = 0,
    auth_buf: [AUTH_BUF_MAX]u8 = @splat(0),
    auth_len: usize = 0,
    result_buf: [64]u8 = @splat(0),
    result_len: usize = 0,
};

const State = struct {
    users: [MAX_USERS]User = @splat(.{}),
    fids: [MAX_FIDS]Fid = @splat(.{}),
};

var state: State = .{};

pub fn main() void {
    var buf: [ETC_USERS_BUF]u8 = undefined;
    const n = ferrite.readInitrdFile(ETC_USERS, &buf);
    if (n == 0) {
        ferrite.console.print("[svc.users] {s} missing. No users will authenticate\n", .{ETC_USERS}) catch {};
    } else {
        loadUsers(buf[0..n]);
    }

    const ch = ferrite.channelCreate(0);
    if (ch < 0) return;
    const svc_send: u32 = @truncate(@as(u64, @bitCast(ch)));
    const svc_recv: u32 = @truncate(@as(u64, @bitCast(ch)) >> 32);

    fs.register(URI_PREFIX, svc_send) catch |e| {
        ferrite.console.print("[svc.users] register failed: {t}\n", .{e}) catch {};
        return;
    };

    state.fids[0] = .{ .used = true, .opened = true, .kind = .root };

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

fn loadUsers(content: []const u8) void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var loaded: u32 = 0;
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (loaded >= MAX_USERS) break;

        const c1 = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const rest1 = trimmed[c1 + 1 ..];
        const c2 = std.mem.indexOfScalar(u8, rest1, ':') orelse continue;

        const name = trimmed[0..c1];
        const uid_str = rest1[0..c2];
        const cred = rest1[c2 + 1 ..];
        if (name.len == 0 or name.len > NAME_MAX) continue;
        const uid = std.fmt.parseUnsigned(u32, uid_str, 10) catch continue;

        if (!std.mem.startsWith(u8, cred, "sha256$")) {
            ferrite.console.print("[svc.users] {s}: unsupported password format (need sha256$salt$hex)\n", .{name}) catch {};
            continue;
        }
        const after_algo = cred["sha256$".len..];
        const dollar = std.mem.indexOfScalar(u8, after_algo, '$') orelse continue;
        const salt = after_algo[0..dollar];
        const hex = after_algo[dollar + 1 ..];
        if (salt.len == 0 or salt.len > SALT_MAX or hex.len != HASH_HEX_LEN) continue;

        var u = &state.users[loaded];
        u.used = true;
        @memcpy(u.name_buf[0..name.len], name);
        u.name_len = @intCast(name.len);
        @memcpy(u.salt_buf[0..salt.len], salt);
        u.salt_len = @intCast(salt.len);
        @memcpy(u.hash_hex[0..HASH_HEX_LEN], hex);
        u.uid = uid;
        loaded += 1;
    }
}

fn verifyPassword(u: *const User, password: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var h = Sha256.init(.{});
    h.update(u.saltSlice());
    h.update(":");
    h.update(password);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);

    var hex_buf: [HASH_HEX_LEN]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return std.mem.eql(u8, &hex_buf, &u.hash_hex);
}

fn findByName(name: []const u8) ?*User {
    for (&state.users) |*u| {
        if (!u.used) continue;
        if (std.mem.eql(u8, u.nameSlice(), name)) return u;
    }
    return null;
}

fn findByUid(uid: u32) ?*User {
    for (&state.users) |*u| {
        if (!u.used) continue;
        if (u.uid == uid) return u;
    }
    return null;
}

fn onWalk(s: *State, fid: u32, path: []const u8) fs.HandlerError!fs.WalkResult {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;

    var new_fid = Fid{ .used = true, .kind = .root };

    var it = std.mem.tokenizeScalar(u8, path, '/');
    if (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "auth")) {
            new_fid.kind = .auth;
            if (it.next() != null) return error.NotFound;
        } else if (std.mem.eql(u8, comp, "users")) {
            const uid_comp = it.next() orelse return error.NotFound;
            const uid = std.fmt.parseUnsigned(u32, uid_comp, 10) catch return error.NotFound;
            if (findByUid(uid) == null) return error.NotFound;
            new_fid.kind = .user_by_uid;
            new_fid.uid_arg = uid;
            if (it.next() != null) return error.NotFound;
        } else return error.NotFound;
    }

    var i: u32 = 1;
    while (i < MAX_FIDS) : (i += 1) {
        if (!s.fids[i].used) {
            s.fids[i] = new_fid;
            return .{ .bound = i };
        }
    }
    return error.ServerBusy;
}

fn onOpen(s: *State, fid: u32, _: p9.Mode) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    s.fids[fid].opened = true;
    s.fids[fid].auth_len = 0;
    s.fids[fid].result_len = 0;
}

fn onWrite(s: *State, fid: u32, _: u64, data: []const u8) fs.HandlerError!u32 {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    if (s.fids[fid].kind != .auth) return error.BadOp;
    const f = &s.fids[fid];
    const space = f.auth_buf.len - f.auth_len;
    if (space == 0) return error.BadOp;
    const n = @min(space, data.len);
    @memcpy(f.auth_buf[f.auth_len..][0..n], data[0..n]);
    f.auth_len += n;
    if (std.mem.indexOfScalar(u8, f.auth_buf[0..f.auth_len], 0)) |sep| {
        const name = f.auth_buf[0..sep];
        const pass = f.auth_buf[sep + 1 .. f.auth_len];
        if (findByName(name)) |u_match| {
            if (verifyPassword(u_match, pass)) {
                const written = std.fmt.bufPrint(&f.result_buf, "ok {d}\n", .{u_match.uid}) catch {
                    @memcpy(f.result_buf[0.."fail\n".len], "fail\n");
                    f.result_len = "fail\n".len;
                    return @intCast(n);
                };
                f.result_len = written.len;
            } else {
                @memcpy(f.result_buf[0.."fail\n".len], "fail\n");
                f.result_len = "fail\n".len;
            }
        } else {
            @memcpy(f.result_buf[0.."fail\n".len], "fail\n");
            f.result_len = "fail\n".len;
        }
    }
    return @intCast(n);
}

fn onRead(s: *State, fid: u32, offset: u64, out: []u8) fs.HandlerError!usize {
    if (fid >= MAX_FIDS or !s.fids[fid].used or !s.fids[fid].opened) return error.BadFid;
    const f = &s.fids[fid];
    switch (f.kind) {
        .root => {
            const listing = "auth\nusers\n";
            return sliceAt(listing, offset, out);
        },
        .auth => {
            if (f.result_len == 0) return 0;
            return sliceAt(f.result_buf[0..f.result_len], offset, out);
        },
        .user_by_uid => {
            const u = findByUid(f.uid_arg) orelse return error.NotFound;
            return sliceAt(u.nameSlice(), offset, out);
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

fn onClose(s: *State, fid: u32) fs.HandlerError!void {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    if (fid != 0) s.fids[fid] = .{};
}

fn onStatus(s: *State, fid: u32) fs.HandlerError!p9.StatusReply {
    if (fid >= MAX_FIDS or !s.fids[fid].used) return error.BadFid;
    return switch (s.fids[fid].kind) {
        .root => .{ .kind = .dir, .size = 0 },
        .auth, .user_by_uid => .{ .kind = .file, .size = 0 },
    };
}
