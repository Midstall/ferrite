// 8253/8254 PIT channel 0 → IRQ 0. Input clock 1.193182 MHz, 16-bit divisor.
// Max period ~54.93 ms.

const PIT_HZ: u64 = 1_193_182;
const CH0_DATA: u16 = 0x40;
const CMD: u16 = 0x43;

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (val),
          [p] "{dx}" (port),
    );
}

pub fn configure(period_ns: u64) u64 {
    var div: u64 = (PIT_HZ * period_ns) / 1_000_000_000;
    if (div == 0) div = 1;
    if (div > 0xFFFF) div = 0xFFFF;

    // Mode 2 (rate generator), channel 0, lobyte/hibyte access
    outb(CMD, 0x34);
    outb(CH0_DATA, @intCast(div & 0xFF));
    outb(CH0_DATA, @intCast((div >> 8) & 0xFF));

    // Return actual period (ns) given the divisor chosen.
    return (div * 1_000_000_000) / PIT_HZ;
}
