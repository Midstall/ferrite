pub const uart = @import("uart_ns16550.zig");
pub const traps = @import("traps.zig");
pub const clint = @import("clint.zig");
pub const timer = @import("timer.zig");
pub const thread = @import("thread.zig");
pub const mmu = @import("mmu.zig");
pub const usermode = @import("usermode.zig");

const riscv = @import("riscv");
pub const features = riscv.features;
pub const cpu = riscv.cpu;
pub const mmio = riscv.mmio;

// H-extension microVM (M-mode hosts a VS-mode guest). kmain runs the in-kernel
// demo when -Dhyp + misa.H; the Vm/Vcpu/Exit facility backs the userspace VMM
// syscalls (kernel/src/vmm.zig keys `available` off these decls).
pub const hypRiscvDemo = @import("hyp.zig").hypRunGuestDemo;
pub const Vm = @import("hyp.zig").Vm;
pub const Vcpu = @import("hyp.zig").Vcpu;
pub const Exit = @import("hyp.zig").Exit;
pub const ExitReason = @import("hyp.zig").ExitReason;

pub inline fn idle() void {
    cpu.idle();
}
