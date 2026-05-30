// 8259 PIC remap + mask helpers. Default vectors (IRQ0=8) collide with CPU
// exception vectors; we remap master to 0x20 and slave to 0x28.

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

inline fn ioWait() void {
    // Slow port to give the PIC time to settle.
    outb(0x80, 0);
}

pub fn init() void {
    // ICW1: init + ICW4 needed
    outb(cmd.M, 0x11);
    ioWait();
    outb(cmd.S, 0x11);
    ioWait();
    // ICW2: vector offsets
    outb(cmd.M_DATA, 0x20); // master → 0x20..0x27
    ioWait();
    outb(cmd.S_DATA, 0x28); // slave  → 0x28..0x2F
    ioWait();
    // ICW3: cascade wiring
    outb(cmd.M_DATA, 0x04); // master has slave on IRQ2
    ioWait();
    outb(cmd.S_DATA, 0x02); // slave identifies as 2
    ioWait();
    // ICW4: 8086 mode
    outb(cmd.M_DATA, 0x01);
    ioWait();
    outb(cmd.S_DATA, 0x01);
    ioWait();
    // OCW1: mask everything to start
    outb(cmd.M_DATA, 0xFF);
    outb(cmd.S_DATA, 0xFF);
}

pub fn unmask(irq: u8) void {
    if (irq < 8) {
        const port = cmd.M_DATA;
        const cur = inb(port);
        outb(port, cur & ~(@as(u8, 1) << @intCast(irq)));
    } else {
        const port = cmd.S_DATA;
        const cur = inb(port);
        outb(port, cur & ~(@as(u8, 1) << @intCast(irq - 8)));
        // Also unmask cascade line on master
        const m = inb(cmd.M_DATA);
        outb(cmd.M_DATA, m & ~@as(u8, 1 << 2));
    }
}

pub fn endOfInterrupt(irq: u8) void {
    if (irq >= 8) outb(cmd.S, 0x20);
    outb(cmd.M, 0x20);
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}
