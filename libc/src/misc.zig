//! Small extras: signal (stubs), assert, atexit, isatty, sleep/usleep.
//! Each section is tiny enough that grouping is easier than per-file
//! splits.

const std = @import("std");
const syscall = @import("ferrite_syscall");

extern fn _ferrite_exit(code: c_int) callconv(.c) noreturn;
extern fn write(fd: c_int, buf: ?[*]const u8, n: usize) callconv(.c) isize;

// ---- atexit -----------------------------------------------------------

const MAX_ATEXIT: usize = 32;
var atexit_fns: [MAX_ATEXIT]?*const fn () callconv(.c) void = @splat(null);
var atexit_count: usize = 0;

export fn atexit(func: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    const f = func orelse return -1;
    if (atexit_count >= MAX_ATEXIT) return -1;
    atexit_fns[atexit_count] = f;
    atexit_count += 1;
    return 0;
}

/// Called by exit() before the actual SYS_EXIT to drain registered
/// atexit handlers in reverse order (POSIX).
export fn _ferrite_run_atexit() callconv(.c) void {
    var i: usize = atexit_count;
    while (i > 0) {
        i -= 1;
        if (atexit_fns[i]) |f| f();
    }
}

// ---- assert -----------------------------------------------------------

/// Backing for the `assert(cond)` macro in <assert.h>. We never return.
/// Print and exit with SIGABRT-equivalent.
export fn __assert_fail(
    expr: ?[*:0]const u8,
    file: ?[*:0]const u8,
    line: c_uint,
    func: ?[*:0]const u8,
) callconv(.c) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}:{d}: {s}: Assertion `{s}' failed.\n", .{
        if (file) |p| std.mem.span(p) else "?",
        line,
        if (func) |p| std.mem.span(p) else "?",
        if (expr) |p| std.mem.span(p) else "?",
    }) catch buf[0..0];
    _ = write(2, msg.ptr, msg.len);
    _ferrite_exit(134); // SIGABRT
}

// ---- signal -----------------------------------------------------------

const SignalHandler = ?*const fn (c_int) callconv(.c) void;
const SIG_DFL: SignalHandler = null;
const SIG_IGN: SignalHandler = @ptrFromInt(1);
const SIG_ERR: SignalHandler = @ptrFromInt(@as(usize, std.math.maxInt(usize)));

/// signal/raise are stubs. Ferrite doesn't expose POSIX signals yet.
/// signal() pretends to install the handler (returns SIG_DFL).
/// raise(SIGABRT) maps to exit(134); everything else is a no-op so
/// programs that "if (signal(SIGPIPE, SIG_IGN)" don't crash.
export fn signal(sig: c_int, handler: SignalHandler) callconv(.c) SignalHandler {
    _ = sig;
    _ = handler;
    return SIG_DFL;
}

export fn raise(sig: c_int) callconv(.c) c_int {
    if (sig == 6) _ferrite_exit(134); // SIGABRT
    return 0;
}

// ---- misc unistd helpers ----------------------------------------------

export fn isatty(fd: c_int) callconv(.c) c_int {
    // stdin/stdout/stderr are routed through the console syscalls,
    // which is what `isatty` is really asking about. Other fds go
    // through the p9 fs and aren't ttys.
    return @intFromBool(fd >= 0 and fd <= 2);
}

export fn sleep(seconds: c_uint) callconv(.c) c_uint {
    const ns: u64 = @as(u64, seconds) * std.time.ns_per_s;
    _ = syscall.nanosleep(ns);
    return 0;
}

export fn usleep(usec: c_ulong) callconv(.c) c_int {
    const ns: u64 = @as(u64, usec) * std.time.ns_per_us;
    _ = syscall.nanosleep(ns);
    return 0;
}

export fn getpid() callconv(.c) c_int {
    // Ferrite doesn't expose a real getpid syscall yet; fixed dummy
    // value so any code that just wants a "process identity" tag for
    // logging gets something.
    return 1;
}

export fn getppid() callconv(.c) c_int {
    return 0;
}

export fn getuid() callconv(.c) c_uint {
    return @intCast(syscall.getUid());
}

export fn geteuid() callconv(.c) c_uint {
    return @intCast(syscall.getUid());
}

export fn getgid() callconv(.c) c_uint {
    return 0;
}

export fn getegid() callconv(.c) c_uint {
    return 0;
}
