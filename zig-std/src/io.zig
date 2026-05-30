//! Ferrite std.Io backend.
//!
//! Bridges Zig's std.Io VTable to Ferrite syscalls and the Plan-9 fs client
//! in `std.os.ferrite.fs`. Userspace constructs one and gets back an
//! `std.Io` instance that stock std code (`std.Io.Dir.cwd().openFile(io,
//! ...)`, `file.read(io, ...)`) routes through.
//!
//! Phase 1 implements the file open/read/write/close path plus sleep/now.
//! All other vtable methods inherit from `Io.failing`, which returns the
//! error variant std code is willing to handle gracefully (typically
//! `error.OperationUnsupported` or equivalent). As uspace grows into more
//! operations, replace failing slots with real impls in `vtable_storage`.
//!
//! The slot table (`MAX_OPEN_FILES`) keeps `fs.File` records keyed by the
//! u32 handle stored in `Io.File.handle`. The Zig fork patches make those
//! handles u32 on `.ferrite` so we can use them as table indices.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Cancelable = Io.Cancelable;
const Timeout = Io.Timeout;
const Clock = Io.Clock;
const Alignment = std.mem.Alignment;

const ferrite = @import("../ferrite.zig");
const fs = ferrite.fs;
const syscall = ferrite.syscall;
const p9 = ferrite.p9;

const Backend = @This();

pub const MAX_OPEN_FILES: usize = 64;

/// Sentinels that fit in u32 but won't collide with a slot index.
pub const HANDLE_CWD: u32 = 0xFFFF_FFFE;
pub const HANDLE_STDIN: u32 = 0xFFFF_FFFD;
pub const HANDLE_STDOUT: u32 = 0xFFFF_FFFC;
pub const HANDLE_STDERR: u32 = 0xFFFF_FFFB;

const Slot = struct {
    in_use: bool = false,
    file: fs.File = undefined,
    pos: u64 = 0,
};

pub const MAX_OPEN_SOCKETS: usize = 32;

const SocketSlot = struct {
    in_use: bool = false,
    // Decimal `n` returned by /sys/net/tcp/clone; fits in well under 16 bytes.
    sock_n_buf: [16]u8 = undefined,
    sock_n_len: u8 = 0,
    // Persistent rdwr handle on /sys/net/tcp/{n}/data. Caching this saves
    // an open+close round-trip on every read/write through std.http.
    data_file: fs.File = undefined,
    address: Io.net.IpAddress = undefined,

    fn sockN(self: *const SocketSlot) []const u8 {
        return self.sock_n_buf[0..self.sock_n_len];
    }
};

slots: [MAX_OPEN_FILES]Slot = [_]Slot{.{}} ** MAX_OPEN_FILES,
sockets: [MAX_OPEN_SOCKETS]SocketSlot = [_]SocketSlot{.{}} ** MAX_OPEN_SOCKETS,

pub fn init() Backend {
    return .{};
}

pub fn deinit(self: *Backend) void {
    for (&self.slots) |*slot| {
        if (slot.in_use) {
            slot.file.close();
            slot.in_use = false;
        }
    }
    for (&self.sockets, 0..) |*s, i| {
        if (s.in_use) {
            netHangup(s.sockN());
            s.data_file.close();
            s.in_use = false;
            _ = i;
        }
    }
}

fn allocSocketSlot(self: *Backend) ?u32 {
    for (&self.sockets, 0..) |*s, i| {
        if (!s.in_use) {
            s.in_use = true;
            return @intCast(i);
        }
    }
    return null;
}

fn socketPtr(self: *Backend, handle: u32) ?*SocketSlot {
    if (handle >= MAX_OPEN_SOCKETS) return null;
    const s = &self.sockets[handle];
    if (!s.in_use) return null;
    return s;
}

pub fn io(self: *Backend) Io {
    return .{
        .userdata = self,
        .vtable = &vtable_storage,
    };
}

fn fromUserdata(userdata: ?*anyopaque) *Backend {
    return @ptrCast(@alignCast(userdata.?));
}

fn allocSlot(self: *Backend) ?u32 {
    for (&self.slots, 0..) |*slot, i| {
        if (!slot.in_use) {
            slot.* = .{ .in_use = true };
            return @intCast(i);
        }
    }
    return null;
}

fn slotPtr(self: *Backend, handle: u32) ?*Slot {
    if (handle >= MAX_OPEN_FILES) return null;
    const s = &self.slots[handle];
    if (!s.in_use) return null;
    return s;
}

fn isStdHandle(handle: u32) bool {
    return handle == HANDLE_STDIN or handle == HANDLE_STDOUT or handle == HANDLE_STDERR;
}

fn mapFsError(err: fs.Error) File.OpenError {
    return switch (err) {
        error.NotFound => error.FileNotFound,
        error.Permission => error.PermissionDenied,
        error.BadFid, error.BadOffset, error.BadOp, error.Protocol => error.Unexpected,
        error.ServerBusy, error.NoMemory => error.SystemResources,
        error.NoNameserver => error.FileNotFound,
        error.SendFailed, error.RecvFailed => error.Unexpected,
        error.BadUri => error.BadPathName,
    };
}

fn mapReadError(err: fs.Error) File.ReadPositionalError {
    return switch (err) {
        error.NotFound, error.BadFid => error.NotOpenForReading,
        error.Permission => error.AccessDenied,
        error.BadOffset, error.BadOp, error.Protocol => error.Unexpected,
        error.ServerBusy, error.NoMemory => error.SystemResources,
        error.SendFailed, error.RecvFailed => error.Unexpected,
        error.BadUri, error.NoNameserver => error.Unexpected,
    };
}

fn mapWriteError(err: fs.Error) File.WritePositionalError {
    return switch (err) {
        error.NotFound, error.BadFid => error.NotOpenForWriting,
        error.Permission => error.AccessDenied,
        error.BadOffset, error.BadOp, error.Protocol => error.Unexpected,
        error.ServerBusy, error.NoMemory => error.SystemResources,
        error.SendFailed, error.RecvFailed => error.Unexpected,
        error.BadUri, error.NoNameserver => error.Unexpected,
    };
}

const vtable_storage: Io.VTable = blk: {
    var v: Io.VTable = Io.failing.vtable.*;
    v.crashHandler = crashHandler;
    v.dirOpenFile = dirOpenFile;
    v.dirClose = dirClose;
    v.fileClose = fileClose;
    v.fileReadPositional = fileReadPositional;
    v.fileWritePositional = fileWritePositional;
    v.fileStat = fileStat;
    v.fileLength = fileLength;
    v.fileSeekTo = fileSeekTo;
    v.fileSeekBy = fileSeekBy;
    v.fileIsTty = fileIsTty;
    v.fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes;
    v.fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes;
    v.fileUnlock = fileUnlock;
    v.now = now;
    v.sleep = sleep;
    v.random = randomFn;
    v.randomSecure = randomSecureFn;
    v.netConnectIp = netConnectIp;
    v.netRead = netRead;
    v.netWrite = netWrite;
    v.netClose = netClose;
    v.netShutdown = netShutdown;
    v.netLookup = netLookup;
    break :blk v;
};

fn crashHandler(_: ?*anyopaque) void {
    _ = syscall.exit(@as(usize, 134)); // 128 + SIGABRT
}

fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenFileOptions,
) File.OpenError!File {
    const self = fromUserdata(userdata);
    if (dir.handle != HANDLE_CWD) return error.Unexpected;

    const slot_idx = self.allocSlot() orelse return error.ProcessFdQuotaExceeded;
    errdefer self.slots[slot_idx].in_use = false;

    const mode: p9.Mode = switch (options.mode) {
        .read_only => .read,
        .write_only => .write,
        .read_write => .rdwr,
    };

    // `fs.open` expects a Ferrite service URI (authority@version:path), but
    // std code calls us with Unix-style paths like `/etc/users`. Resolve
    // through the mount table if the caller didn't already give us a URI.
    var uri_buf: [1024]u8 = undefined;
    const uri_str = if (sub_path.len > 0 and sub_path[0] == '/')
        fs.resolvePath(sub_path, &uri_buf) catch |e| return mapFsError(e)
    else
        sub_path;

    self.slots[slot_idx].file = fs.open(uri_str, .{ .mode = mode }) catch |e| {
        return mapFsError(e);
    };

    return .{
        .handle = slot_idx,
        .flags = .{ .nonblocking = false },
    };
}

fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    _ = dirs;
}

fn fileClose(userdata: ?*anyopaque, files: []const File) void {
    const self = fromUserdata(userdata);
    for (files) |f| {
        if (isStdHandle(f.handle)) continue;
        const slot = self.slotPtr(f.handle) orelse continue;
        slot.file.close();
        slot.in_use = false;
    }
}

fn fileReadPositional(
    userdata: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    const self = fromUserdata(userdata);

    if (file.handle == HANDLE_STDIN) {
        var total: usize = 0;
        for (data) |buf| {
            const n = ferrite.readStdin(buf); // inherited stdin channel or console
            if (n == 0) break;
            total += n;
            if (n < buf.len) break;
        }
        return total;
    }
    if (file.handle == HANDLE_STDOUT or file.handle == HANDLE_STDERR) {
        return error.NotOpenForReading;
    }

    const slot = self.slotPtr(file.handle) orelse return error.NotOpenForReading;

    var total: usize = 0;
    var cur_offset = offset;
    for (data) |buf| {
        if (buf.len == 0) continue;
        const n = slot.file.read(cur_offset, buf) catch |e| {
            if (total > 0) return total;
            return mapReadError(e);
        };
        if (n == 0) break;
        total += n;
        cur_offset += n;
        if (n < buf.len) break;
    }
    return total;
}

fn fileWritePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    const self = fromUserdata(userdata);

    if (file.handle == HANDLE_STDOUT or file.handle == HANDLE_STDERR) {
        var total: usize = 0;
        if (header.len > 0) {
            ferrite.writeStdout(header); // inherited stdout channel or console
            total += header.len;
        }
        if (data.len > 0) {
            // All but the last element are written exactly once.
            for (data[0 .. data.len - 1]) |chunk| {
                ferrite.writeStdout(chunk);
                total += chunk.len;
            }
            // The last element is written `splat` times (which may be 0).
            const tail = data[data.len - 1];
            var k: usize = 0;
            while (k < splat) : (k += 1) {
                ferrite.writeStdout(tail);
                total += tail.len;
            }
        }
        return total;
    }
    if (file.handle == HANDLE_STDIN) return error.NotOpenForWriting;

    const slot = self.slotPtr(file.handle) orelse return error.NotOpenForWriting;

    var total: usize = 0;
    var cur_offset = offset;
    if (header.len > 0) {
        const n = slot.file.writeAll(header) catch |e| return mapWriteError(e);
        total += n;
        cur_offset += n;
        if (n < header.len) return total;
    }
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |chunk| {
            if (chunk.len == 0) continue;
            const n = slot.file.writeAll(chunk) catch |e| {
                if (total > 0) return total;
                return mapWriteError(e);
            };
            total += n;
            cur_offset += n;
            if (n < chunk.len) return total;
        }
        const tail = data[data.len - 1];
        if (tail.len > 0) {
            var k: usize = 0;
            while (k < splat) : (k += 1) {
                const n = slot.file.writeAll(tail) catch |e| {
                    if (total > 0) return total;
                    return mapWriteError(e);
                };
                total += n;
                cur_offset += n;
                if (n < tail.len) return total;
            }
        }
    }
    return total;
}

fn fileStat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const self = fromUserdata(userdata);
    if (isStdHandle(file.handle)) return error.Unexpected;
    const slot = self.slotPtr(file.handle) orelse return error.Unexpected;
    const st = slot.file.status() catch return error.Unexpected;
    const kind: File.Kind = switch (st.kind) {
        .file => .file,
        .dir => .directory,
    };
    return .{
        .inode = 0,
        .nlink = 1,
        .size = st.size,
        .permissions = if (kind == .directory) .default_dir else .default_file,
        .kind = kind,
        .atime = null,
        .mtime = .{ .nanoseconds = 0 },
        .ctime = .{ .nanoseconds = 0 },
        .block_size = 4096,
    };
}

fn fileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    const self = fromUserdata(userdata);
    if (isStdHandle(file.handle)) return 0;
    const slot = self.slotPtr(file.handle) orelse return error.Unexpected;
    const st = slot.file.status() catch return error.Unexpected;
    return st.size;
}

fn fileSeekTo(userdata: ?*anyopaque, file: File, absolute_offset: u64) File.SeekError!void {
    const self = fromUserdata(userdata);
    const slot = self.slotPtr(file.handle) orelse return error.Unexpected;
    slot.pos = absolute_offset;
}

fn fileSeekBy(userdata: ?*anyopaque, file: File, relative_offset: i64) File.SeekError!void {
    const self = fromUserdata(userdata);
    const slot = self.slotPtr(file.handle) orelse return error.Unexpected;
    if (relative_offset < 0) {
        const back: u64 = @intCast(-relative_offset);
        if (back > slot.pos) return error.Unexpected;
        slot.pos -= back;
    } else {
        slot.pos += @intCast(relative_offset);
    }
}

fn fileIsTty(_: ?*anyopaque, file: File) Cancelable!bool {
    return isStdHandle(file.handle);
}

fn fileSupportsAnsiEscapeCodes(_: ?*anyopaque, file: File) Cancelable!bool {
    return file.handle == HANDLE_STDOUT or file.handle == HANDLE_STDERR;
}

fn fileEnableAnsiEscapeCodes(_: ?*anyopaque, _: File) File.EnableAnsiEscapeCodesError!void {}

fn fileUnlock(_: ?*anyopaque, _: File) void {}

fn sleep(_: ?*anyopaque, timeout: Timeout) Cancelable!void {
    const ns: u64 = switch (timeout) {
        .none => return,
        .duration => |d| @intCast(d.raw.nanoseconds),
        // TODO: compute now-vs-deadline once Clock.Timestamp is fully wired.
        .deadline => 0,
    };
    if (ns > 0) _ = syscall.nanosleep(ns);
}

fn now(_: ?*anyopaque, clock: Clock) Io.Timestamp {
    return switch (clock) {
        .real => .{ .nanoseconds = readWallClockNs() },
        // For awake, boot, cpu_process, and cpu_thread we don't separate
        // per-CPU accounting here, so fall back to monotonic uptime.
        else => .{ .nanoseconds = @intCast(syscall.uptimeNs()) },
    };
}

/// Reads `/sys/time/utc` (the wall-clock anchor maintained by svc.time +
/// pushed by svc.ntp / ntpdate). If the file is unavailable or unparseable
/// we degrade to boot-relative uptime. TLS cert validity checks will
/// likely fail in that case, but the alternative is panicking inside
/// std.http's connect path.
fn readWallClockNs() i96 {
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/sys/time/utc", &uri_buf) catch return @intCast(syscall.uptimeNs());
    var f = fs.open(uri, .{ .mode = .read }) catch return @intCast(syscall.uptimeNs());
    defer f.close();
    var buf: [32]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = f.read(got, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    const trimmed = std.mem.trim(u8, buf[0..got], " \t\r\n");
    const secs = std.fmt.parseInt(u64, trimmed, 10) catch return @intCast(syscall.uptimeNs());
    return @as(i96, secs) * std.time.ns_per_s;
}

fn randomFn(_: ?*anyopaque, buffer: []u8) void {
    // Read from /dev/random served by drv.virtio-rng. If unavailable,
    // zero-fill, which is better than a panic in the random hot path;
    // std.http's TLS will fail with a noisy error if entropy is bad.
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath("/dev/random", &uri_buf) catch {
        @memset(buffer, 0);
        return;
    };
    var f = fs.open(uri, .{ .mode = .read }) catch {
        @memset(buffer, 0);
        return;
    };
    defer f.close();
    var got: usize = 0;
    while (got < buffer.len) {
        const n = f.read(got, buffer[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    if (got < buffer.len) {
        @memset(buffer[got..], 0);
    }
}

fn randomSecureFn(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    randomFn(userdata, buffer);
}

// ---- Net (Plan-9 socket fs at /sys/net/tcp) ----

const net = Io.net;

fn formatIp(addr: *const net.IpAddress, buf: []u8) ?[]const u8 {
    return switch (addr.*) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3],
        }) catch null,
        .ip6 => null, // svc.net is IPv4 only for now
    };
}

fn netHangup(sock_n: []const u8) void {
    var path: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/sys/net/tcp/{s}/ctl", .{sock_n}) catch return;
    var uri_buf: [128]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return;
    var f = fs.open(uri, .{ .mode = .write }) catch return;
    defer f.close();
    _ = f.writeAll("hangup") catch {};
}

fn netConnectIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    _ = options;
    const self = fromUserdata(userdata);

    if (address.* == .ip6) return error.AddressFamilyUnsupported;

    // Phase 1: open /sys/net/tcp/clone, read the "n" identifier.
    var clone_uri_buf: [128]u8 = undefined;
    const clone_uri = fs.resolvePath("/sys/net/tcp/clone", &clone_uri_buf) catch return error.NetworkUnreachable;
    var clone_file = fs.open(clone_uri, .{ .mode = .rdwr }) catch return error.NetworkUnreachable;
    defer clone_file.close();

    var raw_n: [16]u8 = undefined;
    var got: usize = 0;
    while (got < raw_n.len) {
        const n = clone_file.read(got, raw_n[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    const sock_n = std.mem.trim(u8, raw_n[0..got], " \t\r\n");
    if (sock_n.len == 0 or sock_n.len > 15) return error.NetworkUnreachable;

    const slot_idx = self.allocSocketSlot() orelse return error.ProcessFdQuotaExceeded;
    const slot = &self.sockets[slot_idx];
    errdefer slot.in_use = false;
    @memcpy(slot.sock_n_buf[0..sock_n.len], sock_n);
    slot.sock_n_len = @intCast(sock_n.len);

    // Phase 2: write "connect a.b.c.d!port" to /sys/net/tcp/{n}/ctl.
    var ctl_path: [128]u8 = undefined;
    const ctl_p = std.fmt.bufPrint(&ctl_path, "/sys/net/tcp/{s}/ctl", .{slot.sockN()}) catch return error.NetworkUnreachable;
    var ctl_uri_buf: [128]u8 = undefined;
    const ctl_uri = fs.resolvePath(ctl_p, &ctl_uri_buf) catch return error.NetworkUnreachable;
    var ctl_file = fs.open(ctl_uri, .{ .mode = .write }) catch return error.NetworkUnreachable;
    defer ctl_file.close();

    var ip_buf: [48]u8 = undefined;
    const ip_str = formatIp(address, &ip_buf) orelse return error.AddressFamilyUnsupported;
    const port: u16 = address.ip4.port;
    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "connect {s}!{d}", .{ ip_str, port }) catch return error.NetworkUnreachable;
    _ = ctl_file.writeAll(cmd) catch |e| return switch (e) {
        error.Permission => error.ConnectionRefused,
        error.NotFound, error.BadFid, error.BadOp => error.NetworkUnreachable,
        error.ServerBusy, error.NoMemory => error.SystemResources,
        error.SendFailed, error.RecvFailed => error.HostUnreachable,
        else => error.ConnectionRefused,
    };

    // Phase 3: persistent rdwr handle on data file for the socket lifetime.
    var data_path: [128]u8 = undefined;
    const data_p = std.fmt.bufPrint(&data_path, "/sys/net/tcp/{s}/data", .{slot.sockN()}) catch return error.NetworkUnreachable;
    var data_uri_buf: [128]u8 = undefined;
    const data_uri = fs.resolvePath(data_p, &data_uri_buf) catch return error.NetworkUnreachable;
    slot.data_file = fs.open(data_uri, .{ .mode = .rdwr }) catch return error.NetworkUnreachable;
    slot.address = address.*;

    return .{ .handle = slot_idx, .address = address.* };
}

fn netRead(
    userdata: ?*anyopaque,
    src: net.Socket.Handle,
    data: [][]u8,
) net.Stream.Reader.Error!usize {
    const self = fromUserdata(userdata);
    const slot = self.socketPtr(src) orelse return error.SocketUnconnected;

    var total: usize = 0;
    for (data) |buf| {
        if (buf.len == 0) continue;
        const n = slot.data_file.read(0, buf) catch |e| {
            if (total > 0) return total;
            return switch (e) {
                error.Permission => error.AccessDenied,
                error.NotFound, error.BadFid => error.SocketUnconnected,
                else => error.Unexpected,
            };
        };
        if (n == 0) break;
        total += n;
        if (n < buf.len) break;
    }
    return total;
}

fn netWrite(
    userdata: ?*anyopaque,
    dest: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const self = fromUserdata(userdata);
    const slot = self.socketPtr(dest) orelse return error.SocketUnconnected;

    var total: usize = 0;
    if (header.len > 0) {
        const n = slot.data_file.writeAll(header) catch return error.SocketUnconnected;
        total += n;
        if (n < header.len) return total;
    }
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |chunk| {
            if (chunk.len == 0) continue;
            const n = slot.data_file.writeAll(chunk) catch {
                if (total > 0) return total;
                return error.SocketUnconnected;
            };
            total += n;
            if (n < chunk.len) return total;
        }
        const tail = data[data.len - 1];
        if (tail.len > 0) {
            var k: usize = 0;
            while (k < splat) : (k += 1) {
                const n = slot.data_file.writeAll(tail) catch {
                    if (total > 0) return total;
                    return error.SocketUnconnected;
                };
                total += n;
                if (n < tail.len) return total;
            }
        }
    }
    return total;
}

fn netClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    const self = fromUserdata(userdata);
    for (handles) |h| {
        const slot = self.socketPtr(h) orelse continue;
        netHangup(slot.sockN());
        slot.data_file.close();
        slot.in_use = false;
    }
}

fn netShutdown(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    how: net.ShutdownHow,
) net.ShutdownError!void {
    _ = how;
    netClose(userdata, &.{handle});
}

fn netLookup(
    userdata: ?*anyopaque,
    host_name: net.HostName,
    resolved: *Io.Queue(net.HostName.LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    _ = userdata;
    const port = options.port;
    const io_inst: Io = .{ .userdata = null, .vtable = &vtable_storage };
    defer resolved.close(io_inst);

    const host_bytes = host_name.bytes;
    if (host_bytes.len == 0 or host_bytes.len > 253) return error.NoAddressReturned;

    // Literal IPs bypass DNS, since std.http always routes through HostName
    // even when the URL is a numeric address.
    if (net.Ip4Address.parse(host_bytes, port)) |ip4| {
        resolved.putOneUncancelable(io_inst, .{ .canonical_name = host_name }) catch return;
        resolved.putOneUncancelable(io_inst, .{ .address = .{ .ip4 = ip4 } }) catch return;
        return;
    } else |_| {}

    var path_buf: [320]u8 = undefined;
    const p = std.fmt.bufPrint(&path_buf, "/sys/dns/{s}", .{host_bytes}) catch return error.NoAddressReturned;
    var uri_buf: [320]u8 = undefined;
    const uri = fs.resolvePath(p, &uri_buf) catch return error.NoAddressReturned;
    var f = fs.open(uri, .{ .mode = .read }) catch return error.NoAddressReturned;
    defer f.close();

    var buf: [512]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = f.read(got, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    if (got == 0) return error.NoAddressReturned;

    // host_name.bytes is owned by the caller and outlives this call, so
    // we can hand it straight back as the canonical name without copying
    // through a stack buffer that would dangle.
    resolved.putOneUncancelable(io_inst, .{ .canonical_name = host_name }) catch return;

    var any: bool = false;
    var line_it = std.mem.tokenizeAny(u8, buf[0..got], "\r\n");
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const ip4 = net.Ip4Address.parse(trimmed, port) catch continue;
        resolved.putOneUncancelable(io_inst, .{ .address = .{ .ip4 = ip4 } }) catch return;
        any = true;
    }
    if (!any) return error.NoAddressReturned;
}

// ---- std.Options + std-extension hooks ----

/// Hook for `std.Options.cwd`. Roots that use `std.Io.Dir.cwd()` must
/// re-export this as `pub const std_options_cwd = ferrite.io.cwdFn;` so
/// std bypasses the posix-default path that doesn't compile on ferrite.
pub fn cwdFn() Dir {
    return .{ .handle = HANDLE_CWD };
}

pub fn stdin() File {
    return .{ .handle = HANDLE_STDIN, .flags = .{ .nonblocking = false } };
}
pub fn stdout() File {
    return .{ .handle = HANDLE_STDOUT, .flags = .{ .nonblocking = false } };
}
pub fn stderr() File {
    return .{ .handle = HANDLE_STDERR, .flags = .{ .nonblocking = false } };
}
