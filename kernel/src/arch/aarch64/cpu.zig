pub inline fn idle() void {
    asm volatile ("wfi");
}

pub fn halt() noreturn {
    disableIrq();
    while (true) asm volatile ("wfi");
}

pub inline fn enableIrq() void {
    asm volatile ("msr daifclr, #2");
}

pub inline fn disableIrq() void {
    asm volatile ("msr daifset, #2");
}

pub inline fn irqsEnabled() bool {
    var daif: u64 = undefined;
    asm volatile ("mrs %[d], daif"
        : [d] "=r" (daif),
    );
    return (daif & (1 << 7)) == 0;
}

pub inline fn pause() void {
    asm volatile ("yield");
}

pub inline fn barrier() void {
    asm volatile ("dmb sy" ::: "memory");
}

pub fn cpuId() u32 {
    var mpidr: u64 = undefined;
    asm volatile ("mrs %[r], mpidr_el1"
        : [r] "=r" (mpidr),
    );
    return @intCast(mpidr & 0xff);
}

pub fn currentEl() u2 {
    var v: u64 = undefined;
    asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (v),
    );
    return @intCast((v >> 2) & 0x3);
}

pub inline fn setThisCpu(ptr: *anyopaque) void {
    asm volatile ("msr tpidr_el1, %[v]"
        :
        : [v] "r" (@intFromPtr(ptr)),
    );
}

pub inline fn thisCpuPtr() usize {
    var v: usize = undefined;
    asm volatile ("mrs %[r], tpidr_el1"
        : [r] "=r" (v),
    );
    return v;
}
