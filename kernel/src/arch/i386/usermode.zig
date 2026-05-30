const std = @import("std");
const gdt = @import("gdt.zig");
const traps = @import("traps.zig");

extern fn isr_int80() callconv(.c) void;

pub fn init() void {
    traps.setUserGate(0x80, @intCast(@intFromPtr(&isr_int80)));
}

pub fn enterUser(user_pc: u64, user_sp: u64) noreturn {
    const pc32: u32 = @intCast(user_pc);
    const sp32: u32 = @intCast(user_sp);

    var current_esp: u32 = undefined;
    asm volatile ("movl %%esp, %[r]"
        : [r] "=r" (current_esp),
    );
    gdt.setKernelStack(current_esp);

    asm volatile (
        \\ pushl %[ss]
        \\ pushl %[sp]
        \\ pushl %[flags]
        \\ pushl %[cs]
        \\ pushl %[pc]
        \\ iret
        :
        : [ss] "r" (@as(u32, gdt.USER_DS)),
          [sp] "r" (sp32),
          [flags] "r" (@as(u32, 0x202)),
          [cs] "r" (@as(u32, gdt.USER_CS)),
          [pc] "r" (pc32),
        : .{ .memory = true });
    unreachable;
}

/// Returns isize (i32 on i386, fits in eax). isr_int80 only writes eax back
/// to the pusha frame, no edx stitching needed since all syscall returns
/// fit in a single register now (channelCreate uses out-params for the
/// recv/send handle pair).
pub export fn dispatchSyscall(
    num: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
) callconv(.c) isize {
    if (traps.syscall_handler) |h| {
        return h(num, a0, a1, a2, a3, a4, a5);
    }
    return -1;
}
