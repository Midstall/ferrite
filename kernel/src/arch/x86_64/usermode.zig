const std = @import("std");
const gdt = @import("gdt.zig");
const cpu = @import("cpu.zig");

const IA32_EFER: u32 = 0xC0000080;
const IA32_STAR: u32 = 0xC0000081;
const IA32_LSTAR: u32 = 0xC0000082;
const IA32_FMASK: u32 = 0xC0000084;
const IA32_GS_BASE: u32 = 0xC0000101;
const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;

const EFER_SCE: u64 = 1;

extern fn syscall_entry() callconv(.naked) void;

pub fn init() void {
    // SYSCALL CS/SS plus the SYSRET pair. CPU sets CS = STAR[48:63]|3,
    // SS = (STAR[48:63]|3)+8 on SYSRET; USER_DS-8 == USER_CS arrangement.
    const star: u64 =
        (@as(u64, gdt.KERNEL_CS) << 32) |
        (@as(u64, gdt.USER_DS - 8) << 48);
    writeMsr(IA32_STAR, star);
    writeMsr(IA32_LSTAR, @intFromPtr(&syscall_entry));
    // FMASK clears IF | TF | DF from RFLAGS on SYSCALL entry.
    writeMsr(IA32_FMASK, 0x200 | 0x100 | 0x400);

    const efer = readMsr(IA32_EFER);
    writeMsr(IA32_EFER, efer | EFER_SCE);
}

pub fn enterUser(user_pc: u64, user_sp: u64) noreturn {
    var current_sp: u64 = undefined;
    asm volatile ("mov %%rsp, %[r]"
        : [r] "=r" (current_sp),
    );
    gdt.setKernelStack(current_sp);
    // syscall_entry reads %gs:8 (kernel_rsp) on entry from user. Write
    // through GS so it lands on whatever per-CPU struct is currently
    // active. kernel.cpu sets that, and a previous usermode-local
    // struct would be stale by the time SYSCALL fires.
    cpu.setKernelRsp(current_sp);

    asm volatile (
        \\ pushq %[ss]
        \\ pushq %[sp]
        \\ pushq %[rflags]
        \\ pushq %[cs]
        \\ pushq %[pc]
        \\ iretq
        :
        : [ss] "r" (@as(u64, gdt.USER_DS)),
          [sp] "r" (user_sp),
          [rflags] "r" (@as(u64, 0x202)),
          [cs] "r" (@as(u64, gdt.USER_CS)),
          [pc] "r" (user_pc),
        : .{ .memory = true });
    unreachable;
}

inline fn readMsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [m] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

inline fn writeMsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
          [m] "{ecx}" (msr),
    );
}

pub export fn dispatchSyscall(
    num: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
) callconv(.c) isize {
    const t = @import("traps.zig");
    if (t.syscall_handler) |h| return h(num, a0, a1, a2, a3, a4, a5);
    return -1;
}
