pub const x86 = @import("x86");

pub const uart = x86.uart;
pub const cpu = @import("cpu.zig");
pub const idt = @import("idt.zig");
pub const mmu = @import("mmu.zig");
pub const pic = @import("pic.zig");
pub const pit = @import("pit.zig");
pub const lapic = @import("lapic.zig");
pub const traps = @import("traps.zig");
pub const timer = @import("timer.zig");
pub const thread = @import("thread.zig");
pub const usermode = @import("usermode.zig");

// Force-analyze so syscall_entry.S finds the symbol; UEFI/multiboot paths
// don't otherwise reach into usermode.
comptime {
    _ = &usermode.dispatchSyscall;
}

pub inline fn idle() void {
    cpu.idle();
}
