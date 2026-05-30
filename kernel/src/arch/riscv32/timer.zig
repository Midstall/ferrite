// Adapter that lets the shared kernel/src/timer.zig + sched.zig talk to
// the board's systimer.

const systimer = @import("board/esp32c6/systimer.zig");
const traps = @import("traps.zig");

const TICK_HZ: u64 = systimer.TICKS_PER_SECOND;

pub var tick_hook: ?*const fn () void = null;

var tick_count: u64 = 0;

pub fn init(period_ns: u64) void {
    const period_ticks: u32 = @intCast((TICK_HZ * period_ns) / 1_000_000_000);
    systimer.init(period_ticks);
}

pub fn now() u64 {
    const counter = systimer.snapshot();
    return (counter * 1_000_000_000) / TICK_HZ;
}

pub fn ticks() u64 {
    return tick_count;
}
