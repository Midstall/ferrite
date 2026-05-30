pub const uart = @import("uart_pl011.zig");
pub const cpu = @import("cpu.zig");
pub const traps = @import("traps.zig");
pub const gic = @import("gic.zig");
pub const timer = @import("timer.zig");
pub const mmu = @import("mmu.zig");
pub const mmio = @import("mmio.zig");
pub const thread = @import("thread.zig");
pub const usermode = @import("usermode.zig");
pub const psci = @import("psci.zig");
pub const smp = @import("smp.zig");

comptime {
    _ = &smp.inits;
}

pub inline fn idle() void {
    cpu.idle();
}
