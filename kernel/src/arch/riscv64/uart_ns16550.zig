// NS16550 UART. MMIO at 0x1000_0000 (QEMU virt riscv64).

const std = @import("std");
const mmio = @import("riscv").mmio;

const UART_BASE: usize = 0x1000_0000;

const Reg = struct {
    const THR = UART_BASE + 0;
    const LSR = UART_BASE + 5;
};

const LSR_THRE: u8 = 1 << 5;

pub fn putc(c: u8) void {
    while ((mmio.read(u8, Reg.LSR) & LSR_THRE) == 0) {}
    mmio.write(u8, Reg.THR, c);
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

pub var rx_wake: ?*const fn () void = null;

pub var rx_echo: bool = false;

pub fn enableRx() void {}

pub fn tryRead(_: []u8) usize {
    return 0;
}
