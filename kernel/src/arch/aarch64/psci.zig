const std = @import("std");

pub const FN_CPU_ON: u32 = 0xC4000003;
pub const FN_CPU_OFF: u32 = 0x84000002;
pub const FN_SYSTEM_OFF: u32 = 0x84000008;
pub const FN_SYSTEM_RESET: u32 = 0x84000009;

pub const Conduit = enum { hvc, smc };
pub var conduit: Conduit = .hvc;

pub fn cpuOn(target: u64, entry_point: u64, context_id: u64) i64 {
    return call4(FN_CPU_ON, target, entry_point, context_id);
}

pub fn systemReset() noreturn {
    _ = call1(FN_SYSTEM_RESET);
    while (true) asm volatile ("wfe");
}

pub fn systemOff() noreturn {
    _ = call1(FN_SYSTEM_OFF);
    while (true) asm volatile ("wfe");
}

fn call1(fn_id: u32) i64 {
    return call4(fn_id, 0, 0, 0);
}

fn call4(fn_id: u32, a1: u64, a2: u64, a3: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("hvc #0"
        : [r] "={x0}" (ret),
        : [f] "{x0}" (@as(u64, fn_id)),
          [b] "{x1}" (a1),
          [c] "{x2}" (a2),
          [d] "{x3}" (a3),
        : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .memory = true });
    return ret;
}
