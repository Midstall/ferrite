// Shared x86 drivers re-exported as the `x86` module for i386/x86_64.

pub const io = @import("io.zig");
pub const uart = @import("uart_16550_pio.zig");
