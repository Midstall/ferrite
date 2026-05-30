// PCI mech-1: 0xCF8 (address) + 0xCFC (data). Required on i440fx, which
// has no ECAM. `bdf` is packed `(bus << 8) | (dev << 3) | func`.

pub const Error = error{BadWidth};

const ADDR_PORT: u16 = 0xCF8;
const DATA_PORT: u16 = 0xCFC;

inline fn addr(bdf: u16, off: u16) u32 {
    return (@as(u32, 1) << 31) |
        (@as(u32, bdf) << 8) |
        (@as(u32, off) & 0xFC);
}

inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (val),
          [p] "N{dx}" (port),
    );
}

inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "N{dx}" (port),
    );
}

inline fn cli() void {
    asm volatile ("cli" ::: .{ .memory = true });
}
inline fn sti() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

/// The 0xCF8+0xCFC pair must be atomic. An IRQ between the two could
/// let another PCI access reprogram 0xCF8 and steer our data write.
pub fn cfgRead(bdf: u16, off: u16, width: u32) Error!u32 {
    cli();
    defer sti();
    outl(ADDR_PORT, addr(bdf, off));
    const data = inl(DATA_PORT);
    return switch (width) {
        1 => (data >> @intCast((off & 3) * 8)) & 0xFF,
        2 => (data >> @intCast((off & 3) * 8)) & 0xFFFF,
        4 => data,
        else => Error.BadWidth,
    };
}

pub fn cfgWrite(bdf: u16, off: u16, width: u32, value: u32) Error!void {
    cli();
    defer sti();
    if (width == 4) {
        outl(ADDR_PORT, addr(bdf, off));
        outl(DATA_PORT, value);
        return;
    }
    // Narrow writes do read-modify-write on the surrounding dword.
    outl(ADDR_PORT, addr(bdf, off));
    const cur = inl(DATA_PORT);
    const shift: u5 = @intCast((off & 3) * 8);
    const mask: u32 = switch (width) {
        1 => @as(u32, 0xFF) << shift,
        2 => @as(u32, 0xFFFF) << shift,
        else => return Error.BadWidth,
    };
    const v = (cur & ~mask) | ((value << shift) & mask);
    outl(ADDR_PORT, addr(bdf, off));
    outl(DATA_PORT, v);
}
