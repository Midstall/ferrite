// arch interface for the riscv64 S-mode (Limine) build. Same surface as
// arch.zig (the M-mode root) but routes through supervisor-mode CSRs and
// SBI ecalls for everything that would otherwise touch M-mode-only state.

pub const uart = @import("uart_ns16550.zig");
pub const mmio = @import("riscv").mmio;
// S-mode can't read misa, so detection differs from the M-mode arch.zig (which
// re-exports riscv.features). See features_smode.zig.
pub const features = @import("features_smode.zig");
pub const cpu = @import("cpu_smode.zig");
pub const traps = @import("traps_smode.zig");
pub const timer = @import("timer_smode.zig");
pub const sbi = @import("sbi.zig");
pub const mmu = @import("mmu_smode.zig");
pub const thread = @import("thread_smode.zig");
pub const usermode = @import("usermode_smode.zig");
