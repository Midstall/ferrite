// riscv64 S-mode CPU primitives. Kernel runs under Limine in supervisor mode.

pub inline fn idle() void {
    asm volatile ("wfi");
}

pub fn halt() noreturn {
    disableIrq();
    while (true) asm volatile ("wfi");
}

pub inline fn enableIrq() void {
    // sstatus.SIE = bit 1.
    asm volatile ("csrsi sstatus, 2");
    // sstatus.SUM = bit 18, lets S-mode read/write user pages without
    // having to bounce through the HHDM mapping. loader's rebase + argv
    // path touches user VAs directly and otherwise takes a load-page-fault.
    asm volatile (
        \\ li t0, (1 << 18)
        \\ csrs sstatus, t0
        ::: .{ .t0 = true });
}

pub inline fn disableIrq() void {
    asm volatile ("csrci sstatus, 2");
}

pub inline fn irqsEnabled() bool {
    var ss: u64 = undefined;
    asm volatile ("csrr %[r], sstatus"
        : [r] "=r" (ss),
    );
    return (ss & 2) != 0;
}

pub inline fn pause() void {
    asm volatile ("nop");
}

pub inline fn barrier() void {
    asm volatile ("fence rw,rw" ::: .{ .memory = true });
}

pub fn cpuId() u32 {
    // mhartid isn't S-mode accessible; the boot path stashes it from a0.
    return boot_hartid;
}

pub var boot_hartid: u32 = 0;

// Kernel repurposes tp (psABI thread-local) for the per-CPU *Cpu pointer.
// User code is free to use tp for its own TLS, so trap_entry_smode.S swaps
// it for `kernel_tp_for_traps` on every U→S transition and restores the
// user value on S→U.
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
