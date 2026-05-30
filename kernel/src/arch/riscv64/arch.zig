pub const uart = @import("uart_ns16550.zig");
pub const traps = @import("traps.zig");
pub const clint = @import("clint.zig");
pub const timer = @import("timer.zig");
pub const thread = @import("thread.zig");
pub const mmu = @import("mmu.zig");
pub const usermode = @import("usermode.zig");

const riscv = @import("riscv");
pub const cpu = riscv.cpu;
pub const mmio = riscv.mmio;

pub inline fn idle() void {
    cpu.idle();
}
