//! Process control + errno + allocator. Everything else (string,
//! stdio, stdlib parsing, ctype) lives in its own file.

const std = @import("std");

// errno -----------------------------------------------------------------

const EINVAL: c_int = 22;
const ENOMEM: c_int = 12;

var errno_storage: c_int = 0;

export fn __errno_location() *c_int {
    return &errno_storage;
}

fn setErrno(v: c_int) void {
    errno_storage = v;
}

// process control -------------------------------------------------------

extern fn _ferrite_exit(code: c_int) callconv(.c) noreturn;
extern fn _ferrite_run_atexit() callconv(.c) void;

comptime {
    @export(&doExit, .{ .name = "exit", .linkage = .strong });
    @export(&doExitNoFinalize, .{ .name = "_Exit", .linkage = .strong });
    @export(&doAbort, .{ .name = "abort", .linkage = .strong });
}

fn doExit(code: c_int) callconv(.c) noreturn {
    _ferrite_run_atexit();
    _ferrite_exit(code);
}

fn doExitNoFinalize(code: c_int) callconv(.c) noreturn {
    // POSIX: _Exit skips atexit handlers and stdio flushing.
    _ferrite_exit(code);
}

fn doAbort() callconv(.c) noreturn {
    _ferrite_exit(134); // SIGABRT semantics
}

// io --------------------------------------------------------------------
//
// open/read/write/close/lseek are POSIX wrappers around the libc's
// `_ferrite_*` extern symbols. Implemented strongly by glue.zig.
//
// Convention (Linux-kernel-style): the `_ferrite_*` helpers return the
// successful value as a non-negative integer, or a negative errno on
// failure. POSIX wrappers below translate the negative-errno path into
// the `-1 + errno` shape that C code expects.

extern fn _ferrite_open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
extern fn _ferrite_close(fd: c_int) callconv(.c) c_int;
extern fn _ferrite_read(fd: c_int, buf: [*]u8, n: usize) callconv(.c) isize;
extern fn _ferrite_write(fd: c_int, buf: [*]const u8, n: usize) callconv(.c) isize;
extern fn _ferrite_lseek(fd: c_int, off: i64, whence: c_int) callconv(.c) i64;

/// Translate a Linux-style return (negative errno on error, non-negative on
/// success) into the POSIX `-1 + errno` convention. Mutates errno.
fn translate(ret: isize) isize {
    if (ret < 0) {
        const err: c_int = @intCast(-ret);
        setErrno(err);
        return -1;
    }
    return ret;
}

export fn open(path: ?[*:0]const u8, flags: c_int, ...) callconv(.c) c_int {
    const p = path orelse {
        setErrno(EINVAL);
        return -1;
    };
    // The variadic third argument carries `mode_t` for O_CREAT. We ignore
    // it for now; the Ferrite fs has its own permissions model.
    const ret = _ferrite_open(p, flags, 0);
    return @intCast(translate(ret));
}

export fn close(fd: c_int) callconv(.c) c_int {
    const ret = _ferrite_close(fd);
    return @intCast(translate(ret));
}

export fn read(fd: c_int, buf: ?[*]u8, n: usize) callconv(.c) isize {
    const b = buf orelse {
        setErrno(EINVAL);
        return -1;
    };
    return translate(_ferrite_read(fd, b, n));
}

export fn write(fd: c_int, buf: ?[*]const u8, n: usize) callconv(.c) isize {
    const b = buf orelse {
        setErrno(EINVAL);
        return -1;
    };
    return translate(_ferrite_write(fd, b, n));
}

export fn lseek(fd: c_int, off: i64, whence: c_int) callconv(.c) i64 {
    const ret = _ferrite_lseek(fd, off, whence);
    if (ret < 0) {
        setErrno(@intCast(-ret));
        return -1;
    }
    return ret;
}

// malloc/free/calloc/realloc/aligned_alloc/posix_memalign live in
// heap.zig, a real free-list allocator backed by syscall.allocPages.
