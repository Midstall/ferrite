// Board-specific drivers (UART, PMP/PMA/APM layout, bootloader,
// partition table) live under `board/<name>/`. Future boards drop
// in alongside esp32c6.

const riscv = @import("riscv");

pub const cpu = riscv.cpu;
pub const mmio = riscv.mmio;
pub const traps = @import("traps.zig");
pub const thread = @import("thread.zig");
pub const timer = @import("timer.zig");
pub const usermode = @import("usermode.zig");
pub const mmu = @import("mmu.zig");

pub const uart = @import("board/esp32c6/uart.zig");
pub const systimer = @import("board/esp32c6/systimer.zig");
pub const pmp = @import("board/esp32c6/pmp.zig");
pub const apm = @import("board/esp32c6/apm.zig");

pub inline fn idle() void {
    cpu.idle();
}

pub inline fn enableInterrupts() void {
    cpu.enableIrq();
}
