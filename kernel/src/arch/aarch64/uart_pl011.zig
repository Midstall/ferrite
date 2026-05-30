// PL011 UART. MMIO at 0x0900_0000 (QEMU virt + most ARM dev boards).

const std = @import("std");
const mmio = @import("mmio.zig");
const traps = @import("traps.zig");
const gic = @import("gic.zig");

const UART_BASE: usize = 0x0900_0000;

const Reg = struct {
    const DR = UART_BASE + 0x000;
    const FR = UART_BASE + 0x018;
    const LCR_H = UART_BASE + 0x02c;
    const CR = UART_BASE + 0x030;
    const IFLS = UART_BASE + 0x034;
    const IMSC = UART_BASE + 0x038;
    const ICR = UART_BASE + 0x044;
};

const FR_RXFE: u32 = 1 << 4;
const FR_TXFF: u32 = 1 << 5;
const INT_RX: u32 = 1 << 4;
// RX timeout. FIFO is also kept off so single bytes trigger INT_RX directly,
// since QEMU's pl011 model doesn't implement RT reliably.
const INT_RT: u32 = 1 << 6;

const LCR_H_8N1: u32 = 3 << 5;
const CR_UARTEN: u32 = 1 << 0;
const CR_TXE: u32 = 1 << 8;
const CR_RXE: u32 = 1 << 9;

// QEMU virt routes PL011 on SPI 1 = GIC INTID 33 (SPI base 32).
const UART_IRQ: u32 = 33;

/// When true, the IRQ handler echoes each received byte with CR/LF
/// and backspace translation.
pub var rx_echo: bool = true;

pub fn putc(c: u8) void {
    while ((mmio.read(u32, Reg.FR) & FR_TXFF) != 0) {}
    mmio.write(u32, Reg.DR, c);
}

pub fn write(s: []const u8) void {
    for (s) |c| putc(c);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch {};
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    var total: usize = w.end;
    for (w.buffer[0..w.end]) |c| putc(c);
    w.end = 0;
    if (data.len == 0) return total;
    for (data[0 .. data.len - 1]) |bytes| {
        for (bytes) |c| putc(c);
        total += bytes.len;
    }
    const last = data[data.len - 1];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        for (last) |c| putc(c);
        total += last.len;
    }
    return total;
}

pub var writer: std.Io.Writer = .{
    .buffer = &.{},
    .end = 0,
    .vtable = &.{ .drain = drain },
};

var rx_ring: [256]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;

pub var rx_wake: ?*const fn () void = null;

pub fn enableRx() void {
    // Force FIFO off. UEFI leaves FEN=1, which with QEMU's incomplete
    // RT-timeout emulation means single bytes (interactive typing) sit
    // in FIFO without firing INT_RX until the next byte pushes the
    // threshold. With FEN=0, every byte triggers INT_RX immediately.
    mmio.write(u32, Reg.LCR_H, LCR_H_8N1);

    traps.registerIrq(UART_IRQ, &onIrq);
    gic.setPriority(UART_IRQ, 0xa0);
    gic.enableIrq(UART_IRQ);
    mmio.write(u32, Reg.IMSC, INT_RX | INT_RT);
}

/// Polling fallback for diagnosing lost RX IRQs.
pub fn pollRx() bool {
    var any = false;
    while ((mmio.read(u32, Reg.FR) & FR_RXFE) == 0) {
        const c: u8 = @truncate(mmio.read(u32, Reg.DR));
        const next = (rx_head + 1) % rx_ring.len;
        if (next != rx_tail) {
            rx_ring[rx_head] = c;
            rx_head = next;
            any = true;
        }
    }
    if (any) {
        mmio.write(u32, Reg.ICR, INT_RX | INT_RT);
        if (rx_wake) |cb| cb();
    }
    return any;
}

fn echoByte(c: u8) void {
    switch (c) {
        '\r' => write("\r\n"),
        0x7f, 0x08 => write("\x08 \x08"),
        else => putc(c),
    }
}

fn onIrq(_: *traps.Frame) void {
    var woke_any = false;
    while ((mmio.read(u32, Reg.FR) & FR_RXFE) == 0) {
        const c: u8 = @truncate(mmio.read(u32, Reg.DR));
        if (rx_echo) echoByte(c);
        const next = (rx_head + 1) % rx_ring.len;
        if (next != rx_tail) {
            rx_ring[rx_head] = c;
            rx_head = next;
            woke_any = true;
        }
    }
    mmio.write(u32, Reg.ICR, INT_RX | INT_RT);
    if (woke_any) if (rx_wake) |cb| cb();
}

pub fn tryRead(buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len and rx_tail != rx_head) : (n += 1) {
        buf[n] = rx_ring[rx_tail];
        rx_tail = (rx_tail + 1) % rx_ring.len;
    }
    return n;
}
