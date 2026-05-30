pub const x86 = @import("x86");

pub const uart = x86.uart;
pub const cpu = @import("cpu.zig");
pub const traps = @import("traps.zig");
pub const pic = @import("pic.zig");
pub const pit = @import("pit.zig");
pub const timer = @import("timer.zig");
pub const thread = @import("thread.zig");
pub const mmu = @import("mmu.zig");
pub const usermode = @import("usermode.zig");
pub const pci = @import("pci.zig");

// Force-analyze the dispatchSyscall export so isr.S's INT 0x80 stub
// finds the symbol even when no Zig code references it.
comptime {
    _ = &usermode.dispatchSyscall;
}

pub inline fn idle() void {
    cpu.idle();
}
