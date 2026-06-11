// NS16550 UART, driven through conduit's `driver.ns16550a` over the Mmio seam.
// The register layout (THR/LSR + the THRE poll) lives in conduit and is shared
// with Weir; this file keeps only the kernel-side concerns (the std.Io writer,
// the RX stubs). The base defaults to QEMU virt rv64 and is upgraded by FDT
// discovery via `setBase` (see kmain.discoverDevices).

const std = @import("std");
const conduit = @import("conduit");
const mmio = @import("riscv").mmio;

const DEFAULT_BASE: usize = 0x1000_0000;
var base: usize = DEFAULT_BASE;

/// Point the driver at a discovered MMIO base. Called once at boot before the
/// console is used in anger; a no-op when discovery returns the same address.
pub fn setBase(phys: usize) void {
    base = phys;
}

// A conduit Ns16550a over `base`, honoring the kernel's phys->virt device
// offset (0 on every current riscv boot path, so this is bit-identical to the
// old `@ptrFromInt(phys)` pokes, but routed through one seam).
inline fn dev() conduit.driver.ns16550a.Ns16550a {
    return .{ .mmio = conduit.Mmio.direct(base + mmio.offset) };
}

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

pub var rx_wake: ?*const fn () void = null;

pub var rx_echo: bool = false;

pub fn enableRx() void {}

pub fn tryRead(_: []u8) usize {
    return 0;
}
