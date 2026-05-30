// S-mode timer driven via SBI. We poll the `time` CSR for the current mtime
// value and ask SBI to fire the next interrupt at now+period.

const sbi = @import("sbi.zig");
const traps = @import("traps_smode.zig");
const uart = @import("uart_ns16550.zig");

const STI_IRQ: u32 = 5; // S-mode timer (cause low bits = 5).

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
    traps.registerIrq(STI_IRQ, &handle);
    armNext();
    // sie.STIE = bit 5. csrsi's immediate is 5-bit (0..31), so bit 5 needs
    // the register form.
    asm volatile ("csrs sie, %[v]"
        :
        : [v] "r" (@as(u64, 1 << 5)),
    );
}

pub fn now() u64 {
    return (readTime() * 1_000_000_000) / timebase_freq;
}

pub fn ticks() u64 {
    return tick_count;
}

fn handle(_: *traps.Frame) void {
    tick_count += 1;
    armNext();
    if (tick_hook) |h| h();
}

fn armNext() void {
    sbi.setTimer(readTime() + period_ticks);
}

inline fn readTime() u64 {
    var v: u64 = undefined;
    asm volatile ("csrr %[r], time"
        : [r] "=r" (v),
    );
    return v;
}
