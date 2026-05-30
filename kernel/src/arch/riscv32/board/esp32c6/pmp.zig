// ESP32-C6 memory protection - PMP + PMA setup ported from ESP-IDF's
// `esp_cpu_configure_region_protection()` for esp32c6
// (components/esp_hw_support/port/esp32c6/cpu_region_protect.c).
//
// Critical constraint from that file: "ESP32-C6 CPU doesn't support
// overlapping PMP regions". A single wide-open NAPOT covering [0,2^34)
// silently does NOT work as an "allow all" rule - the chip needs one
// PMP entry per real address region, and PMA entries marking the gaps
// between them as PMA_NONE.

const PMA_EN: u32 = 1 << 0;
const PMA_X: u32 = 1 << 2;
const PMA_W: u32 = 1 << 3;
const PMA_R: u32 = 1 << 4;
const PMA_L: u32 = 1 << 29;
const PMA_TOR: u32 = 1 << 30;

const PMP_R: u32 = 1 << 0;
const PMP_W: u32 = 1 << 1;
const PMP_X: u32 = 1 << 2;
const PMP_A_TOR: u32 = 0b01 << 3;
const PMP_A_NAPOT: u32 = 0b11 << 3;
const PMP_L: u32 = 1 << 7;

// ESP32-C6 SoC address ranges (from components/soc/esp32c6/include/soc/soc.h).
const SOC_CPU_SUBSYSTEM_LOW: u32 = 0x2000_0000;
const SOC_CPU_SUBSYSTEM_HIGH: u32 = 0x3000_0000;
const SOC_IROM_MASK_LOW: u32 = 0x4000_0000;
const SOC_IROM_MASK_HIGH: u32 = 0x4005_0000;
const SOC_DROM_MASK_HIGH: u32 = SOC_IROM_MASK_HIGH;
const SOC_IRAM_LOW: u32 = 0x4080_0000;
const SOC_IRAM_HIGH: u32 = 0x4088_0000;
const SOC_DROM_HIGH: u32 = 0x4400_0000;
const SOC_IROM_LOW: u32 = 0x4200_0000;
const SOC_RTC_IRAM_LOW: u32 = 0x5000_0000;
const SOC_RTC_IRAM_HIGH: u32 = 0x5000_4000;
const SOC_PERIPHERAL_LOW: u32 = 0x6000_0000;
const SOC_PERIPHERAL_HIGH: u32 = 0x6010_0000;

/// Encode a NAPOT region [base, end) for a pmpaddr CSR. base/end must be a
/// power-of-2 size. Result is the 32-bit value to write into pmpaddrN.
fn pmpaddrNapot(base: u32, end: u32) u32 {
    const size = end - base;
    return (base | (size >> 1) - 1) >> 2;
}

inline fn writePma(comptime idx: u32, cfg: u32, addr: u32) void {
    asm volatile ("csrw %[csr], %[v]"
        :
        : [csr] "i" (0xBD0 + idx),
          [v] "r" (addr >> 2),
    );
    asm volatile ("csrw %[csr], %[v]"
        :
        : [csr] "i" (0xBC0 + idx),
          [v] "r" (cfg),
    );
}

inline fn writePmpAddr(comptime idx: u32, val: u32) void {
    asm volatile ("csrw %[csr], %[v]"
        :
        : [csr] "i" (0x3B0 + idx),
          [v] "r" (val),
    );
}

inline fn writePmpCfg(comptime cfg_idx: u32, val: u32) void {
    // RV32 packs 4 8-bit PMP cfgs per pmpcfgN reg. cfg_idx is the 32-bit
    // reg slot (0..3 -> pmpcfg0..pmpcfg3).
    asm volatile ("csrw %[csr], %[v]"
        :
        : [csr] "i" (0x3A0 + cfg_idx),
          [v] "r" (val),
    );
}

/// Configure the 12 PMA entries that mark all invalid address ranges as
/// PMA_NONE (locked), so the chip knows where legitimate memory lives.
/// Modeled exactly on esp_cpu_configure_invalid_regions().
fn configureInvalidRegions() void {
    const NONE_FIRST: u32 = PMA_L | PMA_EN | PMA_TOR;
    const NONE: u32 = PMA_L | PMA_EN;

    // Each entry is TOR with upper bound at the named address. The
    // first entry covers [0, SOC_CPU_SUBSYSTEM_LOW) explicitly via TOR
    // (no preceding entry). esp-idf does TOR for entry 0 too.
    writePma(0, NONE_FIRST, SOC_CPU_SUBSYSTEM_LOW);
    writePma(1, NONE, SOC_CPU_SUBSYSTEM_HIGH);
    writePma(2, NONE_FIRST, SOC_IROM_MASK_LOW);
    writePma(3, NONE, SOC_DROM_MASK_HIGH);
    writePma(4, NONE_FIRST, SOC_IRAM_LOW);
    writePma(5, NONE, SOC_IRAM_HIGH);
    writePma(6, NONE_FIRST, SOC_IROM_LOW);
    writePma(7, NONE, SOC_DROM_HIGH);
    writePma(8, NONE_FIRST, SOC_RTC_IRAM_LOW);
    writePma(9, NONE, SOC_RTC_IRAM_HIGH);
    writePma(10, NONE_FIRST, SOC_PERIPHERAL_LOW);
    writePma(11, NONE, SOC_PERIPHERAL_HIGH);
    writePma(12, NONE_FIRST, 0xFFFF_FFFF);
}

/// Chip-permanent locked PMP entries for non-IRAM address regions:
/// CPU subsystem, ROM, flash XIP, LP IRAM, peripherals.
///
/// The broad IRAM grant is intentionally absent. ESP32-C6 has no
/// Smepmp/mseccfg, so unlocked entries gate U-mode only - M-mode bypasses
/// them entirely. With no PMP entry covering IRAM, M-mode default-allow
/// keeps the kernel running while U-mode default-denies, forcing each
/// process to claim its IRAM via an Aspace grant in entries 3/4/6/7.
/// Lowest-numbered match wins, so per-process entries take precedence
/// over the higher-numbered chip-permanent ones for their address ranges.
pub fn configureRegionProtection() void {
    configureInvalidRegions();

    const RX: u32 = PMP_L | PMP_R | PMP_X;
    const RWX: u32 = PMP_L | PMP_R | PMP_W | PMP_X;

    // CPU subsystem (PLIC/CLINT/...).
    writePmpAddr(0, pmpaddrNapot(SOC_CPU_SUBSYSTEM_LOW, SOC_CPU_SUBSYSTEM_HIGH));

    // I/D-ROM (TOR pair).
    writePmpAddr(1, SOC_IROM_MASK_LOW >> 2);
    writePmpAddr(2, SOC_IROM_MASK_HIGH >> 2);

    // Flash IROM. Kernel XIP lives here, so U-mode threads with their
    // entry point in IROM can fetch.
    writePmpAddr(8, pmpaddrNapot(SOC_IROM_LOW, SOC_IROM_HIGH(SOC_IROM_LOW)));

    writePmpAddr(11, pmpaddrNapot(SOC_RTC_IRAM_LOW, SOC_RTC_IRAM_HIGH));

    // Peripheral region. Kept open for U-mode for early bring-up so
    // direct MMIO works. A syscall-based design would close this off.
    writePmpAddr(15, pmpaddrNapot(SOC_PERIPHERAL_LOW, SOC_PERIPHERAL_HIGH));

    // pmpcfg layout: 4 cfg bytes per 32-bit slot.
    //   pmpcfg0 = entry 0|1|2|3
    //   pmpcfg1 = entry 4|5|6|7   (Aspace owns 6/7, 5 stays OFF)
    //   pmpcfg2 = entry 8|9|10|11
    //   pmpcfg3 = entry 12|13|14|15
    writePmpCfg(0, (PMP_A_NAPOT | RWX) | ((PMP_L) << 8) | ((PMP_A_TOR | RX) << 16));
    writePmpCfg(1, 0);
    writePmpCfg(2, (PMP_A_NAPOT | RX) | ((PMP_A_NAPOT | RWX) << 24));
    writePmpCfg(3, (PMP_A_NAPOT | RWX) << 24);
}

// Per-process address space.

pub const PmpPerms = packed struct(u8) {
    r: bool = false,
    w: bool = false,
    x: bool = false,
    _pad: u5 = 0,
};

pub const Region = struct {
    base: u32,
    /// Power of 2, with `base` naturally aligned to `size` for NAPOT.
    size: u32,
    perms: PmpPerms,

    pub const off: Region = .{ .base = 0, .size = 0, .perms = .{} };
};

/// Per-process U-mode region table. Slots map 1:1 onto PMP entries
/// 3, 4, 6, 7 - the only unlocked, reprogrammable indices that don't
/// overlap our chip-permanent locked ranges.
pub const Aspace = struct {
    regions: [4]Region = .{ Region.off, Region.off, Region.off, Region.off },
};

inline fn permsToCfg(p: PmpPerms) u32 {
    var c: u32 = 0;
    if (p.r) c |= PMP_R;
    if (p.w) c |= PMP_W;
    if (p.x) c |= PMP_X;
    return c;
}

/// Program PMP entries 3/4/6/7 from `aspace`. Read-modify-write of the
/// pmpcfg slots preserves the locked entries that share each register.
pub fn loadAspace(aspace: *const Aspace) void {
    var cfg0 = readPmpCfg(0);
    var cfg1 = readPmpCfg(1);
    cfg0 &= 0x00FF_FFFF;
    cfg1 &= 0x0000_FF00;

    if (aspace.regions[0].size != 0) {
        const r = aspace.regions[0];
        writePmpAddr(3, pmpaddrNapot(r.base, r.base + r.size));
        cfg0 |= (PMP_A_NAPOT | permsToCfg(r.perms)) << 24;
    }
    if (aspace.regions[1].size != 0) {
        const r = aspace.regions[1];
        writePmpAddr(4, pmpaddrNapot(r.base, r.base + r.size));
        cfg1 |= (PMP_A_NAPOT | permsToCfg(r.perms)) << 0;
    }
    if (aspace.regions[2].size != 0) {
        const r = aspace.regions[2];
        writePmpAddr(6, pmpaddrNapot(r.base, r.base + r.size));
        cfg1 |= (PMP_A_NAPOT | permsToCfg(r.perms)) << 16;
    }
    if (aspace.regions[3].size != 0) {
        const r = aspace.regions[3];
        writePmpAddr(7, pmpaddrNapot(r.base, r.base + r.size));
        cfg1 |= (PMP_A_NAPOT | permsToCfg(r.perms)) << 24;
    }

    writePmpCfg(0, cfg0);
    writePmpCfg(1, cfg1);
}

fn readPmpCfg(comptime cfg_idx: u32) u32 {
    var v: u32 = 0;
    asm volatile ("csrr %[v], %[csr]"
        : [v] "=r" (v),
        : [csr] "i" (0x3A0 + cfg_idx),
    );
    return v;
}

// SOC_IROM_HIGH is computed from SOC_MMU_PAGE_SIZE. Keep it conservative
// (8 MB above SOC_IROM_LOW = SOC_IROM_LOW + 0x800_0000).
fn SOC_IROM_HIGH(low: u32) u32 {
    return low + 0x0080_0000;
}

pub fn dump(uart: anytype) void {
    inline for (0..4) |i| {
        var cfg: u32 = 0;
        asm volatile ("csrr %[v], %[csr]"
            : [v] "=r" (cfg),
            : [csr] "i" (0x3A0 + i),
        );
        uart.print("pmpcfg{d} = 0x{x}\n", .{ i, cfg });
    }
    inline for (0..16) |i| {
        var addr: u32 = 0;
        asm volatile ("csrr %[v], %[csr]"
            : [v] "=r" (addr),
            : [csr] "i" (0x3B0 + i),
        );
        if (addr != 0) uart.print("pmpaddr{d} = 0x{x}\n", .{ i, addr });
    }
}
