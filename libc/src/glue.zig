//! Strong overrides for the libc's `_ferrite_*` hooks.
//!
//! When linked into a binary alongside libferrite_libc.a, these displace
//! the weak ENOSYS defaults in stubs.zig and route C file IO through
//! the Plan-9 fs client. C code and Zig code (via the std.Io vtable
//! backend) share a single fd namespace because both ultimately call
//! into `ferrite.fs`.
//!
//! Convention: return non-negative on success, negative errno on
//! failure. The libc wrappers in stubs.zig translate the negative-errno
//! return into the POSIX `-1 + errno` shape.

const std = @import("std");

// Wired in by build/src/libc.zig as Module imports. Keeps glue.zig
// independent of the patched zig-std overlay so libc builds against
// stock zig std.
const fs = @import("ferrite_fs");
const syscall = @import("ferrite_syscall");
const p9 = @import("ferrite_p9");

// errno values (matches libc/src/stubs.zig).
const ENOENT: i32 = 2;
const EBADF: i32 = 9;
const ENOMEM: i32 = 12;
const EACCES: i32 = 13;
const EINVAL: i32 = 22;
const EMFILE: i32 = 24;

// Mirrors fcntl.h in libc/include.
const O_RDONLY: i32 = 0x0;
const O_WRONLY: i32 = 0x1;
const O_RDWR: i32 = 0x2;
const O_ACCMODE: i32 = 0x3;

const SEEK_SET: i32 = 0;
const SEEK_CUR: i32 = 1;
const SEEK_END: i32 = 2;

const STDIN_FD: i32 = 0;
const STDOUT_FD: i32 = 1;
const STDERR_FD: i32 = 2;

const MAX_FDS: usize = 64;

const Slot = struct {
    in_use: bool = false,
    file: fs.File = undefined,
    pos: u64 = 0,
};

var slots: [MAX_FDS]Slot = [_]Slot{.{}} ** MAX_FDS;

fn allocSlot() ?usize {
    for (&slots, 0..) |*s, i| {
        if (!s.in_use) {
            s.* = .{ .in_use = true };
            return i;
        }
    }
    return null;
}

fn slotFromFd(fd: i32) ?*Slot {
    if (fd < 3) return null;
    const idx: usize = @intCast(fd - 3);
    if (idx >= MAX_FDS) return null;
    const s = &slots[idx];
    if (!s.in_use) return null;
    return s;
}

fn fdFromSlot(idx: usize) i32 {
    return @intCast(idx + 3);
}

fn mapFsError(err: fs.Error) i32 {
    return switch (err) {
        error.NotFound => ENOENT,
        error.Permission => EACCES,
        error.BadFid, error.BadOffset, error.BadOp => EBADF,
        error.ServerBusy, error.NoMemory => ENOMEM,
        error.SendFailed, error.RecvFailed, error.Protocol => EINVAL,
        error.BadUri => EINVAL,
        error.NoNameserver => ENOENT,
    };
}

comptime {
    @export(&open_impl, .{ .name = "_ferrite_open", .linkage = .strong });
    @export(&close_impl, .{ .name = "_ferrite_close", .linkage = .strong });
    @export(&read_impl, .{ .name = "_ferrite_read", .linkage = .strong });
    @export(&write_impl, .{ .name = "_ferrite_write", .linkage = .strong });
    @export(&lseek_impl, .{ .name = "_ferrite_lseek", .linkage = .strong });
    @export(&exit_impl, .{ .name = "_ferrite_exit", .linkage = .strong });
}

fn exit_impl(code: c_int) callconv(.c) noreturn {
    _ = syscall.exit(@as(usize, @intCast(code & 0xff)));
    while (true) {}
}

fn open_impl(path_ptr: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int {
    _ = mode;
    const path = std.mem.span(path_ptr);

    if (path.len == 0) return -ENOENT;

    var uri_buf: [1024]u8 = undefined;
    const uri_str = if (path[0] == '/')
        fs.resolvePath(path, &uri_buf) catch |e| return -mapFsError(e)
    else
        path;

    const p9_mode: p9.Mode = switch (flags & O_ACCMODE) {
        O_RDONLY => .read,
        O_WRONLY => .write,
        O_RDWR => .rdwr,
        else => return -EINVAL,
    };

    const idx = allocSlot() orelse return -EMFILE;
    const slot = &slots[idx];

    slot.file = fs.open(uri_str, .{ .mode = p9_mode }) catch |e| {
        slot.in_use = false;
        return -mapFsError(e);
    };
    slot.pos = 0;
    return fdFromSlot(idx);
}

fn close_impl(fd: c_int) callconv(.c) c_int {
    if (fd >= 0 and fd <= 2) return 0;
    const slot = slotFromFd(fd) orelse return -EBADF;
    slot.file.close();
    slot.in_use = false;
    return 0;
}

fn read_impl(fd: c_int, buf: [*]u8, n: usize) callconv(.c) isize {
    if (fd == STDIN_FD) {
        const raw = syscall.readConsole(buf[0..n]);
        if (raw < 0) return -EBADF;
        return @intCast(raw);
    }
    if (fd == STDOUT_FD or fd == STDERR_FD) return -EBADF;

    const slot = slotFromFd(fd) orelse return -EBADF;
    const got = slot.file.read(slot.pos, buf[0..n]) catch |e| return -mapFsError(e);
    slot.pos += got;
    return @intCast(got);
}

fn write_impl(fd: c_int, buf: [*]const u8, n: usize) callconv(.c) isize {
    if (fd == STDOUT_FD or fd == STDERR_FD) {
        const sent = syscall.writeConsole(buf[0..n]);
        if (sent < 0) return -EBADF;
        return @intCast(sent);
    }
    if (fd == STDIN_FD) return -EBADF;

    const slot = slotFromFd(fd) orelse return -EBADF;
    const wrote = slot.file.writeAll(buf[0..n]) catch |e| return -mapFsError(e);
    slot.pos += wrote;
    return @intCast(wrote);
}

fn lseek_impl(fd: c_int, off: i64, whence: c_int) callconv(.c) i64 {
    if (fd >= 0 and fd <= 2) return -EBADF;
    const slot = slotFromFd(fd) orelse return -EBADF;
    const new_pos: i64 = switch (whence) {
        SEEK_SET => off,
        SEEK_CUR => @as(i64, @intCast(slot.pos)) + off,
        SEEK_END => blk: {
            const st = slot.file.status() catch |e| return -mapFsError(e);
            break :blk @as(i64, @intCast(st.size)) + off;
        },
        else => return -EINVAL,
    };
    if (new_pos < 0) return -EINVAL;
    slot.pos = @intCast(new_pos);
    return new_pos;
}
