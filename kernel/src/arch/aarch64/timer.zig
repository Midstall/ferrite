const std = @import("std");
const traps = @import("traps.zig");
const gic = @import("gic.zig");
const uart = @import("uart_pl011.zig");

/// Set by the kernel to flag a scheduler tick. Called once per timer IRQ.
pub var tick_hook: ?*const fn () void = null;

const TIMER_IRQ: u32 = 27;

var freq_hz: u64 = 0;
var period_ticks: u64 = 0;
var tick_count: u64 = 0;

pub fn init(period_ns: u64) void {
    asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (freq_hz),
    );
    period_ticks = (freq_hz * period_ns) / 1_000_000_000;

    // The IRQ->handler table is global; register once.
    traps.registerIrq(TIMER_IRQ, &handle);

    // Arm the boot CPU's own virtual timer + PPI.
    initCpu(0);
}

// The virtual timer (CNTV_*_EL0) and its PPI (banked in the GIC) are per-CPU, so
// every CPU must arm its own. Requires gic.initCpu(cpu_index) to have run first.
pub fn initCpu(cpu_index: u32) void {
    gic.setPriorityCpu(cpu_index, TIMER_IRQ, 0xa0);
    gic.enableIrqCpu(cpu_index, TIMER_IRQ);

    setTval(period_ticks);
    asm volatile ("msr cntv_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 1)),
    );
    asm volatile ("isb");
}

pub fn ticks() u64 {
    return @atomicLoad(u64, &tick_count, .monotonic);
}

pub fn now() u64 {
    var cnt: u64 = undefined;
    asm volatile ("mrs %[r], cntvct_el0"
        : [r] "=r" (cnt),
    );
    // Avoid `cnt * 1e9` overflowing u64 (would wrap at ~18 s with cntfrq=1 GHz)
    // without u128 division: split into integer + fractional seconds.
    const sec = cnt / freq_hz;
    const rem = cnt % freq_hz;
    return sec * 1_000_000_000 + (rem * 1_000_000_000) / freq_hz;
}

inline fn setTval(t: u64) void {
    asm volatile ("msr cntv_tval_el0, %[v]"
        :
        : [v] "r" (t),
    );
}

fn handle(_: *traps.Frame) void {
    _ = @atomicRmw(u64, &tick_count, .Add, 1, .monotonic);
    setTval(period_ticks);
    if (tick_hook) |h| h();
}
