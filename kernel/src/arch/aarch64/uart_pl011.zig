// PL011 UART. The data path (DR/FR, the TXFF/RXFE polls) is conduit's
// `driver.pl011` over the Mmio seam, shared with Weir. The RX-interrupt plumbing
// (IMSC/ICR/LCR_H, the ring buffer, echo, the std.Io writer) stays here, since
// conduit's PL011 is a console-only driver and does not model interrupts. Base
// defaults to QEMU virt + most ARM boards and is upgraded by FDT discovery via
// `setBase` (see kmain.discoverDevices).

const std = @import("std");
const conduit = @import("conduit");
const mmio = @import("mmio.zig");
const traps = @import("traps.zig");
const gic = @import("gic.zig");

const DEFAULT_BASE: usize = 0x0900_0000;
var base: usize = DEFAULT_BASE;

/// Point the driver at a discovered MMIO base, before the console is used.
pub fn setBase(phys: usize) void {
    base = phys;
}

// conduit's PL011 over the discovered base, honoring the kernel's phys->virt
// device offset (0 on every current aarch64 boot path). All register access,
// including the IRQ-only registers below, goes through this one Mmio seam.
inline fn dev() conduit.driver.pl011.Pl011 {
    return .{ .mmio = conduit.Mmio.direct(base + mmio.offset) };
}

// Register offsets conduit's console-only PL011 does not name (interrupt set,
// interrupt clear, line control), addressed off the same Mmio base.
const LCR_H_OFF: usize = 0x02c;
const IMSC_OFF: usize = 0x038;
const ICR_OFF: usize = 0x044;
const DR_OFF: usize = 0x000;

const INT_RX: u32 = 1 << 4;
// RX timeout. FIFO is also kept off so single bytes trigger INT_RX directly,
// since QEMU's pl011 model doesn't implement RT reliably.
const INT_RT: u32 = 1 << 6;
const LCR_H_8N1: u32 = 3 << 5;

// QEMU virt routes PL011 on SPI 1 = GIC INTID 33 (SPI base 32).
const UART_IRQ: u32 = 33;

/// When true, the IRQ handler echoes each received byte with CR/LF
/// and backspace translation.
pub var rx_echo: bool = true;

pub fn putc(c: u8) void {
    dev().putc(c);
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
    dev().mmio.write(u32, LCR_H_OFF, LCR_H_8N1);

    traps.registerIrq(UART_IRQ, &onIrq);
    gic.setPriority(UART_IRQ, 0xa0);
    gic.enableIrq(UART_IRQ);
    dev().mmio.write(u32, IMSC_OFF, INT_RX | INT_RT);
}

/// Polling fallback for diagnosing lost RX IRQs.
pub fn pollRx() bool {
    const u = dev();
    var any = false;
    while (u.rxReady()) {
        const c: u8 = @truncate(u.mmio.read(u32, DR_OFF));
        const next = (rx_head + 1) % rx_ring.len;
        if (next != rx_tail) {
            rx_ring[rx_head] = c;
            rx_head = next;
            any = true;
        }
    }
    if (any) {
        u.mmio.write(u32, ICR_OFF, INT_RX | INT_RT);
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
    const u = dev();
    var woke_any = false;
    while (u.rxReady()) {
        const c: u8 = @truncate(u.mmio.read(u32, DR_OFF));
        if (rx_echo) echoByte(c);
        const next = (rx_head + 1) % rx_ring.len;
        if (next != rx_tail) {
            rx_ring[rx_head] = c;
            rx_head = next;
            woke_any = true;
        }
    }
    u.mmio.write(u32, ICR_OFF, INT_RX | INT_RT);
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
