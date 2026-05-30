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
    var fl: u64 = undefined;
    asm volatile (
        \\ pushfq
        \\ popq %[r]
        : [r] "=r" (fl),
    );
    return (fl & (1 << 9)) != 0;
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

const IA32_GS_BASE: u32 = 0xC0000101;
const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;

pub inline fn setThisCpu(ptr: *anyopaque) void {
    const v: u64 = @intFromPtr(ptr);
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
          [m] "{ecx}" (IA32_GS_BASE),
    );
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
          [m] "{ecx}" (IA32_KERNEL_GS_BASE),
    );
}

// Writes `rsp` into the per-CPU `kernel_rsp` slot at %gs:8 (syscall_entry.S
// loads %rsp from this on user→kernel transitions). The kernel.cpu.Cpu
// layout pins this offset.
pub inline fn setKernelRsp(rsp: u64) void {
    asm volatile ("movq %[v], %%gs:8"
        :
        : [v] "r" (rsp),
        : .{ .memory = true });
}

pub inline fn thisCpuPtr() usize {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [m] "{ecx}" (IA32_GS_BASE),
    );
    return @intCast((@as(u64, hi) << 32) | lo);
}
