// ESP32-C6 console - routed through the USB-Serial/JTAG controller, not
// the UART0 peripheral. ROM bootloader exposes /dev/ttyACM0 through this
// path; UART0 TX is a chip pin that isn't wired to anything in the dev
// kit's USB bridge.
//
// TRM section30 (USB Serial/JTAG Controller). FIFO is bytewise; CONF.EP1_FREE
// tells us when there's room, WR_DONE flushes the in-FIFO bytes to host.

const BASE: usize = 0x6000_F000;
const EP1_OFF: usize = 0x00; // FIFO write port
const EP1_CONF_OFF: usize = 0x04; // status: bit 1 = serial_in_ep_data_free
const SERIAL_IN_EP_DATA_FREE_BIT: u32 = 1 << 1;
const WR_DONE_BIT: u32 = 1 << 0;

inline fn reg(off: usize) *volatile u32 {
    return @ptrFromInt(BASE + off);
}

fn waitFreeSpace() void {
    while ((reg(EP1_CONF_OFF).* & SERIAL_IN_EP_DATA_FREE_BIT) == 0) {}
}

fn flush() void {
    reg(EP1_CONF_OFF).* = WR_DONE_BIT;
}

pub fn putc(c: u8) void {
    waitFreeSpace();
    reg(EP1_OFF).* = c;
    flush();
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const std = @import("std");
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write(slice);
}

/// Set by console.zig and raised from the UART RX-ready IRQ. We don't
/// yet generate RX IRQs on c6 (USB-Serial/JTAG path is poll-only for
/// now), so this stays unused, but kmain references it.
pub var rx_wake: ?*const fn () void = null;

/// Whether console.zig should echo characters as they're read. Defaults
/// off. mount.tty enables it in cooked mode.
pub var rx_echo: bool = false;

/// Enable RX-data IRQ delivery. No-op for now (poll-only path).
pub fn enableRx() void {}

/// Drain any pending RX bytes into `buf`. Returns 0 (nothing buffered)
/// until we wire the USB-Serial/JTAG RX FIFO into the IRQ path.
pub fn tryRead(_: []u8) usize {
    return 0;
}
