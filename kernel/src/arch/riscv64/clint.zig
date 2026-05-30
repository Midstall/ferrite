// CLINT (Core Local Interruptor) driver for QEMU virt rv64.
// mtime at 0x02000000+0xBFF8 (RO 64-bit counter), mtimecmp at 0x02000000+0x4000+8*hart.

const CLINT_BASE: usize = 0x0200_0000;
const MTIME: usize = CLINT_BASE + 0xBFF8;
const MTIMECMP0: usize = CLINT_BASE + 0x4000;

pub fn readMtime() u64 {
    return @as(*volatile u64, @ptrFromInt(MTIME)).*;
}

pub fn setMtimecmp(hart: u32, val: u64) void {
    const addr = MTIMECMP0 + @as(usize, hart) * 8;
    @as(*volatile u64, @ptrFromInt(addr)).* = val;
}
