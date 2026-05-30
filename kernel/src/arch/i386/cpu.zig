pub inline fn idle() void {
    asm volatile ("hlt");
}

pub fn halt() noreturn {
    disableIrq();
    while (true) asm volatile ("hlt");
}

pub inline fn enableIrq() void {
    asm volatile ("sti");
}

pub inline fn disableIrq() void {
    asm volatile ("cli");
}

pub inline fn irqsEnabled() bool {
    var fl: u32 = undefined;
    asm volatile (
        \\ pushfl
        \\ popl %[r]
        : [r] "=r" (fl),
    );
    return (fl & (1 << 9)) != 0; // IF
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn barrier() void {
    asm volatile ("mfence" ::: "memory");
}

pub fn cpuId() u32 {
    return 0;
}

// Global, no per-CPU scratch reg on i386 across ring transitions.
var this_cpu_ptr: usize = 0;

pub inline fn setThisCpu(ptr: *anyopaque) void {
    this_cpu_ptr = @intFromPtr(ptr);
}

pub inline fn thisCpuPtr() usize {
    return this_cpu_ptr;
}
