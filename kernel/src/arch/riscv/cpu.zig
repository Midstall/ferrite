// RISC-V M-mode CPU primitives. S-mode uses different CSRs (sstatus,
// shartid, ...) - see cpu_smode.zig.

pub inline fn idle() void {
    asm volatile ("wfi");
}

pub fn halt() noreturn {
    disableIrq();
    while (true) asm volatile ("wfi");
}

pub inline fn enableIrq() void {
    // mstatus.MIE
    asm volatile ("csrsi mstatus, 8");
}

pub inline fn disableIrq() void {
    asm volatile ("csrci mstatus, 8");
}

pub inline fn irqsEnabled() bool {
    var ms: usize = undefined;
    asm volatile ("csrr %[r], mstatus"
        : [r] "=r" (ms),
    );
    return (ms & 8) != 0;
}

pub inline fn pause() void {
    // No Zihintpause assumed.
    asm volatile ("nop");
}

pub inline fn barrier() void {
    asm volatile ("fence rw,rw" ::: .{ .memory = true });
}

pub fn cpuId() u32 {
    var hid: usize = undefined;
    asm volatile ("csrr %[r], mhartid"
        : [r] "=r" (hid),
    );
    return @intCast(hid);
}

pub export var kernel_tp_for_traps: usize = 0;

pub inline fn setThisCpu(ptr: *anyopaque) void {
    const v: usize = @intFromPtr(ptr);
    kernel_tp_for_traps = v;
    asm volatile ("mv tp, %[v]"
        :
        : [v] "r" (v),
    );
}

pub inline fn thisCpuPtr() usize {
    var v: usize = undefined;
    asm volatile ("mv %[r], tp"
        : [r] "=r" (v),
    );
    return v;
}
