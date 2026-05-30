// 8259 PIC. Limine masks all IRQs on boot; we remap (master→0x20, slave→0x28)
// and unmask the ones we use.

const cmd = struct {
    const M = 0x20;
    const M_DATA = 0x21;
    const S = 0xA0;
    const S_DATA = 0xA1;
};

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (val),
          [p] "{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

inline fn ioWait() void {
    outb(0x80, 0);
}

pub fn init() void {
    outb(cmd.M, 0x11);
    ioWait();
    outb(cmd.S, 0x11);
    ioWait();
    outb(cmd.M_DATA, 0x20);
    ioWait();
    outb(cmd.S_DATA, 0x28);
    ioWait();
    outb(cmd.M_DATA, 0x04);
    ioWait();
    outb(cmd.S_DATA, 0x02);
    ioWait();
    outb(cmd.M_DATA, 0x01);
    ioWait();
    outb(cmd.S_DATA, 0x01);
    ioWait();
    outb(cmd.M_DATA, 0xFF);
    outb(cmd.S_DATA, 0xFF);
}

pub fn unmask(irq: u8) void {
    if (irq < 8) {
        const cur = inb(cmd.M_DATA);
        outb(cmd.M_DATA, cur & ~(@as(u8, 1) << @intCast(irq)));
    } else {
        const cur = inb(cmd.S_DATA);
        outb(cmd.S_DATA, cur & ~(@as(u8, 1) << @intCast(irq - 8)));
        const m = inb(cmd.M_DATA);
        outb(cmd.M_DATA, m & ~@as(u8, 1 << 2));
    }
}

pub fn endOfInterrupt(irq: u8) void {
    if (irq >= 8) outb(cmd.S, 0x20);
    outb(cmd.M, 0x20);
}
