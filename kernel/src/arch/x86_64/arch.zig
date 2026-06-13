pub const x86 = @import("x86");

pub const uart = x86.uart;
pub const features = x86.features;
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

// microVM facility (AMD SVM backend): the Vm/Vcpu/Exit objects behind the
// userspace VMM. enable()/hypActive() gate it at runtime on real SVM hardware;
// it stays inactive (syscalls return .denied) under QEMU TCG and on this ARM
// dev host. hypX86Demo runs the in-kernel guest demo when -Dhyp is set.
pub const hyp = @import("hyp.zig");
pub const Vm = hyp.Vm;
pub const Vcpu = hyp.Vcpu;
pub const Exit = hyp.Exit;
pub const ExitReason = hyp.ExitReason;
pub const hypActive = hyp.active;
pub const hypX86Enable = hyp.enable;
pub const hypX86Demo = hyp.hypRunGuestDemo;

// Force-analyze so syscall_entry.S finds the symbol; UEFI/multiboot paths
// don't otherwise reach into usermode.
comptime {
    _ = &usermode.dispatchSyscall;
}

pub inline fn idle() void {
    cpu.idle();
}
