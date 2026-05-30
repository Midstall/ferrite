// riscv64 machine timer via CLINT. Period rearmed each tick.

const clint = @import("clint.zig");
const traps = @import("traps.zig");
const uart = @import("uart_ns16550.zig");

const TIMER_IRQ: u32 = 7;

/// Default for QEMU virt rv64. Overridden at boot from
/// `/cpus/timebase-frequency` via [`setTimebaseFreq`].
var timebase_freq: u64 = 10_000_000;

var period_ticks: u64 = 0;
var tick_count: u64 = 0;

pub var tick_hook: ?*const fn () void = null;

/// Override the assumed mtime tick rate. Must be called before `init`.
pub fn setTimebaseFreq(hz: u64) void {
    if (hz != 0) timebase_freq = hz;
}

pub fn init(period_ns: u64) void {
    period_ticks = (timebase_freq * period_ns) / 1_000_000_000;

    traps.registerIrq(TIMER_IRQ, &handle);

    const now_t = clint.readMtime();
    clint.setMtimecmp(0, now_t + period_ticks);

    asm volatile ("csrs mie, %[v]"
        :
        : [v] "r" (@as(u64, 1 << 7)),
    );
}

pub fn now() u64 {
    return (clint.readMtime() * 1_000_000_000) / timebase_freq;
}

pub fn ticks() u64 {
    return tick_count;
}

fn handle(_: *traps.Frame) void {
    tick_count += 1;
    const now_t = clint.readMtime();
    clint.setMtimecmp(0, now_t + period_ticks);
    if (tick_hook) |h| h();
}
