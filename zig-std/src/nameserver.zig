const std = @import("std");
const p9 = @import("p9.zig");
const syscall = @import("syscall.zig");

pub const MAX_NAME: usize = 128;
pub const MAX_ENTRIES: usize = 32;
pub const MAX_MOUNTS: usize = 16;
pub const MAX_PREFIX: usize = 64;

pub const Error = error{
    TableFull,
    NameTooLong,
    NotFound,
    AlreadyRegistered,
};

pub const Entry = struct {
    name_buf: [MAX_NAME]u8,
    name_len: u8,
    cap_handle: u32,
};

pub const MountEntry = struct {
    prefix_buf: [MAX_PREFIX]u8,
    prefix_len: u8,
    authority_buf: [MAX_NAME]u8,
    authority_len: u8,
};

pub const MountTable = struct {
    entries: [MAX_MOUNTS]MountEntry = undefined,
    count: usize = 0,

    pub fn add(self: *MountTable, prefix: []const u8, authority: []const u8) Error!void {
        if (prefix.len == 0 or prefix[0] != '/') return error.NameTooLong;
        if (prefix.len > MAX_PREFIX or authority.len > MAX_NAME) return error.NameTooLong;
        if (self.find(prefix) != null) return error.AlreadyRegistered;
        if (self.count >= MAX_MOUNTS) return error.TableFull;
        var e = &self.entries[self.count];
        @memcpy(e.prefix_buf[0..prefix.len], prefix);
        e.prefix_len = @intCast(prefix.len);
        @memcpy(e.authority_buf[0..authority.len], authority);
        e.authority_len = @intCast(authority.len);
        self.count += 1;
    }

    /// Longest-prefix match; sub-path always starts with '/'.
    pub fn resolve(self: *const MountTable, path: []const u8) ?struct { entry: *const MountEntry, sub: []const u8 } {
        if (path.len == 0 or path[0] != '/') return null;
        var best: ?*const MountEntry = null;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const e = &self.entries[i];
            const pref = e.prefix_buf[0..e.prefix_len];
            // Match must end on a '/' boundary so "/dev" doesn't shadow "/devel".
            if (std.mem.eql(u8, pref, "/") or
                (std.mem.startsWith(u8, path, pref) and
                    (path.len == pref.len or path[pref.len] == '/')))
            {
                if (best == null or pref.len > best.?.prefix_len) best = e;
            }
        }
        const e = best orelse return null;
        const pref = e.prefix_buf[0..e.prefix_len];
        const sub = if (std.mem.eql(u8, pref, "/")) path else path[pref.len..];
        return .{ .entry = e, .sub = if (sub.len == 0) "/" else sub };
    }

    fn find(self: *const MountTable, prefix: []const u8) ?*const MountEntry {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const e = &self.entries[i];
            if (e.prefix_len == prefix.len and std.mem.eql(u8, e.prefix_buf[0..e.prefix_len], prefix)) return e;
        }
        return null;
    }

    pub fn dumpInto(self: *const MountTable, out: []u8) usize {
        var w: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const e = &self.entries[i];
            const pref = e.prefix_buf[0..e.prefix_len];
            const auth = e.authority_buf[0..e.authority_len];
            const need = pref.len + 1 + auth.len + 1;
            if (w + need > out.len) break;
            @memcpy(out[w..][0..pref.len], pref);
            w += pref.len;
            out[w] = '\t';
            w += 1;
            @memcpy(out[w..][0..auth.len], auth);
            w += auth.len;
            out[w] = '\n';
            w += 1;
        }
        return w;
    }

    /// Appends NUL-separated first path components beneath `path`.
    /// e.g. `childrenOf("/")` over a `/sys/net` mount yields `sys`.
    pub fn childrenOf(self: *const MountTable, path: []const u8, out: []u8) usize {
        var w: usize = 0;
        const norm = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const e = &self.entries[i];
            const pref = e.prefix_buf[0..e.prefix_len];
            const rest: []const u8 = if (std.mem.eql(u8, norm, "/")) blk: {
                if (pref.len < 2 or pref[0] != '/') continue;
                break :blk pref[1..];
            } else blk: {
                if (!std.mem.startsWith(u8, pref, norm)) continue;
                if (pref.len == norm.len) continue;
                if (pref[norm.len] != '/') continue;
                break :blk pref[norm.len + 1 ..];
            };
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const name = rest[0..slash];
            if (name.len == 0) continue;
            if (containsName(out[0..w], name)) continue;
            if (w + name.len + 1 > out.len) break;
            @memcpy(out[w..][0..name.len], name);
            w += name.len;
            out[w] = 0;
            w += 1;
        }
        return w;
    }
};

fn containsName(buf: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, buf, 0);
    while (it.next()) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn parentOfPrefix(prefix: []const u8) []const u8 {
    if (prefix.len <= 1) return "";
    if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |i| {
        if (i == 0) return "/";
        return prefix[0..i];
    }
    return "";
}

fn nameOfPrefix(prefix: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |i| return prefix[i + 1 ..];
    return prefix;
}

pub const Registry = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    count: usize = 0,

    pub fn register(self: *Registry, name: []const u8, cap_handle: u32) Error!void {
        if (name.len > MAX_NAME) return error.NameTooLong;
        if (self.findIndex(name) != null) return error.AlreadyRegistered;
        if (self.count >= MAX_ENTRIES) return error.TableFull;

        var e = &self.entries[self.count];
        @memcpy(e.name_buf[0..name.len], name);
        e.name_len = @intCast(name.len);
        e.cap_handle = cap_handle;
        self.count += 1;
    }

    pub fn lookup(self: *const Registry, name: []const u8) Error!u32 {
        const idx = self.findIndex(name) orelse return error.NotFound;
        return self.entries[idx].cap_handle;
    }

    pub fn unregister(self: *Registry, name: []const u8) Error!void {
        const idx = self.findIndex(name) orelse return error.NotFound;
        self.entries[idx] = self.entries[self.count - 1];
        self.count -= 1;
    }

    fn findIndex(self: *const Registry, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const e = &self.entries[i];
            if (e.name_len == name.len and
                std.mem.eql(u8, e.name_buf[0..e.name_len], name))
            {
                return i;
            }
        }
        return null;
    }
};

/// Handles `register` and `lookup`; other ops return `bad_op`.
pub fn dispatch(
    reg: *Registry,
    req: p9.Request,
    tag: u8,
    in_cap: u32,
    resp_buf: []u8,
    out_cap: *u32,
) p9.Error!usize {
    out_cap.* = 0;
    return switch (req) {
        .register => |m| blk: {
            if (in_cap == 0) {
                break :blk p9.encodeErrReply(resp_buf, tag, .permission);
            }
            reg.register(m.prefix, in_cap) catch |e| switch (e) {
                error.TableFull, error.NameTooLong => break :blk p9.encodeErrReply(resp_buf, tag, .server_busy),
                error.AlreadyRegistered => break :blk p9.encodeErrReply(resp_buf, tag, .permission),
                else => unreachable,
            };
            break :blk p9.encodeRegisterReply(resp_buf, tag);
        },
        .lookup => |m| blk: {
            const h = reg.lookup(m.prefix) catch
                break :blk p9.encodeErrReply(resp_buf, tag, .not_found);
            out_cap.* = h;
            break :blk p9.encodeLookupReply(resp_buf, tag);
        },
        else => p9.encodeErrReply(resp_buf, tag, .bad_op),
    };
}
