// CLINT (Core Local Interruptor), driven through conduit's `driver.clint` over
// the Mmio seam. The register layout (MTIME 0xBFF8, MTIMECMP 0x4000+8*hart) is
// shared with Weir. The base defaults to QEMU virt rv64 and is upgraded by FDT
// discovery via `setBase` (see kmain.discoverDevices).

const conduit = @import("conduit");

const DEFAULT_BASE: usize = 0x0200_0000;
const MTIMECMP_OFF: usize = 0x4000;
var base: usize = DEFAULT_BASE;

pub fn setBase(phys: usize) void {
    base = phys;
}

inline fn dev() conduit.driver.clint.Clint {
    return conduit.driver.clint.bind(conduit.Mmio.direct(base));
}

pub fn readMtime() u64 {
    return dev().time();
}

pub fn setMtimecmp(hart: u32, val: u64) void {
    dev().setTimecmp(hart, val);
}

pub fn readMtimecmp(hart: u32) u64 {
    // conduit's Clint has no mtimecmp read-back (it is write-mostly); read the
    // per-hart compare register directly through the same Mmio window.
    return dev().mmio.read(u64, MTIMECMP_OFF + @as(usize, hart) * 8);
}
