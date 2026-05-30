// PIT-driven periodic timer. PIT max period is ~55 ms, so for longer logical
// periods we count multiple PIT IRQs internally and only fire kmain's tick
// callback at the requested rate.

const pic = @import("pic.zig");
const pit = @import("pit.zig");
const traps = @import("traps.zig");
const uart = @import("x86").uart;

const PIT_IRQ: u32 = 0;

var actual_period_ns: u64 = 0;
var irqs_per_tick: u64 = 1;
var irq_count: u64 = 0;
var tick_count: u64 = 0;

pub var tick_hook: ?*const fn () void = null;

pub fn init(period_ns: u64) void {
    actual_period_ns = pit.configure(period_ns);
    irqs_per_tick = if (period_ns > actual_period_ns)
        (period_ns + actual_period_ns / 2) / actual_period_ns
    else
        1;
    if (irqs_per_tick == 0) irqs_per_tick = 1;

    traps.registerIrq(PIT_IRQ, &handle);
}

pub fn now() u64 {
    return irq_count * actual_period_ns;
}

pub fn ticks() u64 {
    return tick_count;
}

fn handle(_: *traps.Frame) void {
    irq_count += 1;
    if (irq_count % irqs_per_tick != 0) return;

    tick_count += 1;
    if (tick_hook) |h| h();
}
