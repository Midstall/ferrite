// PIT driver. Channel 0 generates IRQ 0 (used as our periodic timer source).
// Channel 2 stays gated and polled (for future LAPIC calibration).

const PIT_HZ: u64 = 1_193_182;

const CH0_DATA: u16 = 0x40;
const CMD: u16 = 0x43;

/// Configure channel 0 mode 2 (rate generator). 16-bit divisor caps the
/// period at ~54.9 ms. Returns the actual period (ns) given the divisor
/// chosen.
pub fn configurePeriodic(period_ns: u64) u64 {
    var div: u64 = (PIT_HZ * period_ns) / 1_000_000_000;
    if (div == 0) div = 1;
    if (div > 0xFFFF) div = 0xFFFF;
    outb(CMD, 0x34);
    outb(CH0_DATA, @intCast(div & 0xFF));
    outb(CH0_DATA, @intCast((div >> 8) & 0xFF));
    return (div * 1_000_000_000) / PIT_HZ;
}

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

/// Configures PIT channel 2 for a one-shot countdown of `ms` milliseconds
/// and raises the gate to start counting. Speaker output (bit 1 of port 0x61)
/// is masked off so we don't actually beep.
pub fn calibrationStart(ms: u32) void {
    var ctrl = inb(0x61);
    ctrl &= ~@as(u8, 0b11); // clear speaker enable + gate
    outb(0x61, ctrl);

    // Channel 2, lobyte/hibyte, mode 0 (interrupt on terminal count), binary.
    outb(0x43, 0xB0);
    const count: u32 = @intCast((PIT_HZ * @as(u64, ms)) / 1000);
    outb(0x42, @intCast(count & 0xFF));
    outb(0x42, @intCast((count >> 8) & 0xFF));

    // Raise gate (bit 0). Speaker stays muted (bit 1 clear).
    outb(0x61, ctrl | 1);
}

/// True once the channel-2 countdown has reached zero. Reads the OUT2 status
/// bit on port 0x61.
pub fn calibrationDone() bool {
    return (inb(0x61) & 0x20) != 0;
}

pub fn calibrationWait() void {
    while (!calibrationDone()) asm volatile ("pause");
}
