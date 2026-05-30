// Module root for code shared between riscv32 and riscv64 M-mode arch
// modules. The build system wires this in as `@import("riscv")`.

pub const cpu = @import("cpu.zig");
pub const mmio = @import("mmio.zig");
