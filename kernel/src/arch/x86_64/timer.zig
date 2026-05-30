// LAPIC for the periodic IRQ, TSC for `now()`. The LAPIC counter pauses
// during HLT under QEMU TCG, so a tick-derived clock under-reports
// wall time whenever the CPU spends any cycles idle.

const lapic = @import("lapic.zig");
const pit = @import("pit.zig");
const traps = @import("traps.zig");
const uart = @import("x86").uart;

const TIMER_VECTOR: u8 = 0x20;

var tick_count: u64 = 0;
/// Calibrated against PIT in `init`; ns per TSC tick × 2^32 (fixed-point
/// for cheap multiply-shift in `now`). 0 until init runs.
var tsc_ns_per_tick_fx32: u64 = 0;
var tsc_at_boot: u64 = 0;

pub var tick_hook: ?*const fn () void = null;

pub fn init(period_ns: u64) void {
    traps.registerIrq(TIMER_VECTOR, &handle);
    calibrateTsc();
    lapic.calibrate();
    lapic.enableTimerPeriodic(TIMER_VECTOR, period_ns);
}

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn calibrateTsc() void {
    const CAL_MS: u32 = 10;
    pit.calibrationStart(CAL_MS);
    const t0 = rdtsc();
    pit.calibrationWait();
    const t1 = rdtsc();
    const elapsed_ticks: u64 = t1 -% t0;
    // ns per tick = (CAL_MS * 1_000_000) / elapsed_ticks.
    // For fixed-point 32: store (ns * 2^32) / tick.
    const ns_total: u64 = @as(u64, CAL_MS) * 1_000_000;
    if (elapsed_ticks != 0) {
        tsc_ns_per_tick_fx32 = (ns_total << 32) / elapsed_ticks;
    }
    tsc_at_boot = rdtsc();
}

pub fn now() u64 {
    if (tsc_ns_per_tick_fx32 == 0) return 0;
    const delta = rdtsc() -% tsc_at_boot;
    // ns = (delta * tsc_ns_per_tick_fx32) >> 32.
    return @intCast((@as(u128, delta) * @as(u128, tsc_ns_per_tick_fx32)) >> 32);
}

pub fn ticks() u64 {
    return tick_count;
}

fn handle(_: *traps.Frame) void {
    tick_count += 1;
    lapic.endOfInterrupt();
    if (tick_hook) |h| h();
}
