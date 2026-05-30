const std = @import("std");

// MAIR indices. Limine on aarch64 sets MAIR_EL1 = 0x00FF, so attrIdx 0 must be
// Normal and attrIdx 1 must be Device for our leaf descriptors to keep matching
// across raw and Limine boot.
const MAIR_DEVICE_nGnRnE: u8 = 0x00;
const MAIR_NORMAL: u8 = 0xff;

// Descriptor bits (stage 1).
const DESC_VALID: u64 = 1 << 0;
// 0 = block, 1 = table at non-leaf levels.
const DESC_TABLE: u64 = 1 << 1;
const BLOCK_AF: u64 = 1 << 10;
const BLOCK_SH_INNER: u64 = 0b11 << 8;
const BLOCK_SH_OUTER: u64 = 0b10 << 8;
const BLOCK_AP_RW_EL1: u64 = 0b00 << 6;
const BLOCK_AP_RW_USER: u64 = 0b01 << 6;
const BLOCK_AP_RO_EL1: u64 = 0b10 << 6;
const BLOCK_AP_RO_USER: u64 = 0b11 << 6;
const BLOCK_UXN: u64 = @as(u64, 1) << 54;
const BLOCK_PXN: u64 = @as(u64, 1) << 53;

const PAGE_DESC: u64 = DESC_TABLE;

const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_F000;

inline fn attrIndex(i: u3) u64 {
    return @as(u64, i) << 2;
}

const Granule = struct {
    page_size: u64,
    page_shift: u6,
    level_bits: u6,
    level_count: u3,
    tg0: u2,
    t0sz: u6,
    entries_per_table: usize,
    kernel_shared_entries: usize,
};

const granule_4k: Granule = .{
    .page_size = 4096,
    .page_shift = 12,
    .level_bits = 9,
    .level_count = 4,
    .tg0 = 0b00,
    .t0sz = 16,
    .entries_per_table = 512,
    .kernel_shared_entries = 1,
};

const granule_16k: Granule = .{
    .page_size = 16384,
    .page_shift = 14,
    .level_bits = 11,
    .level_count = 3,
    .tg0 = 0b10,
    .t0sz = 17,
    .entries_per_table = 2048,
    .kernel_shared_entries = 1,
};

const granule_64k: Granule = .{
    .page_size = 65536,
    .page_shift = 16,
    .level_bits = 13,
    .level_count = 2,
    .tg0 = 0b01,
    .t0sz = 22,
    .entries_per_table = 8192,
    .kernel_shared_entries = 8,
};

var g: Granule = granule_4k;

pub fn pickGranule(n: u64) bool {
    g = switch (n) {
        4096 => granule_4k,
        16384 => granule_16k,
        65536 => granule_64k,
        else => return false,
    };
    return true;
}

pub fn supportsPageSize(n: u64) bool {
    return n == 4096 or n == 16384 or n == 65536;
}

// Sized + aligned for the worst-case 64 KB granule. `l0_table` keeps its
// historical name; secondary_entry.S references it as the kernel root.
pub export var l0_table: [granule_64k.entries_per_table]u64 align(65536) = @splat(0);
var block_table: [granule_64k.entries_per_table]u64 align(65536) = @splat(0);

// SCTLR M | C | I.
const SCTLR_ENABLE: u64 = (1 << 0) | (1 << 2) | (1 << 12);

pub export var kernel_tcr: u64 = 0;

fn tcrValue() u64 {
    // T0SZ | IRGN0=WBWA | ORGN0=WBWA | SH0=Inner | TG0 | EPD1 | IPS
    // IPS in bits 34:32 caps the output PA width; default 0 = 32-bit means
    // any leaf PA > 4 GB takes an Address-Size Fault. Read PARange from
    // ID_AA64MMFR0_EL1 and mirror it so MMIO at 0x40_1000_0000 (qemu virt
    // PCIe ECAM) doesn't fault drv.pci's first config read.
    var mmfr0: u64 = undefined;
    asm volatile ("mrs %[r], id_aa64mmfr0_el1"
        : [r] "=r" (mmfr0),
    );
    const parange: u64 = mmfr0 & 0xF;
    return @as(u64, g.t0sz) |
        (3 << 8) | (3 << 10) | (3 << 12) |
        (@as(u64, g.tg0) << 14) |
        (1 << 23) |
        (parange << 32);
}

pub fn init() void {
    // Disable MMU first. ARM ARM forbids mutating live tables or changing TG0
    // with the MMU on; re-entry would otherwise corrupt translation.
    asm volatile (
        \\ mrs x9, sctlr_el1
        \\ bic x9, x9, %[en]
        \\ msr sctlr_el1, x9
        \\ isb
        \\ tlbi vmalle1
        \\ dsb sy
        \\ isb
        :
        : [en] "r" (SCTLR_ENABLE),
        : .{ .x9 = true, .memory = true });

    {
        var i: usize = 0;
        while (i < granule_64k.entries_per_table) : (i += 1) {
            l0_table[i] = 0;
            block_table[i] = 0;
        }
    }

    const device_block: u64 = attrIndex(1) | BLOCK_SH_OUTER | BLOCK_AP_RW_EL1 | BLOCK_AF | DESC_VALID;
    const normal_block: u64 = attrIndex(0) | BLOCK_SH_INNER | BLOCK_AP_RW_EL1 | BLOCK_AF | DESC_VALID;

    // Identity-map 0..1 GB Device, 1..4 GB Normal. Coarsest block size per granule:
    //   4K  -> 1 GB at L1
    //   16K -> 32 MB at L2
    //   64K -> 512 MB at L2 (root for 42-bit VA)
    switch (g.page_size) {
        4096 => {
            block_table[0] = 0x0000_0000 | device_block;
            block_table[1] = 0x4000_0000 | normal_block;
            block_table[2] = 0x8000_0000 | normal_block;
            block_table[3] = 0xC000_0000 | normal_block;
            l0_table[0] = (@intFromPtr(&block_table) & ADDR_MASK) | DESC_TABLE | DESC_VALID;
        },
        16384 => {
            const block_size: u64 = 0x0200_0000;
            var i: usize = 0;
            while (i < 128) : (i += 1) {
                const pa = @as(u64, i) * block_size;
                const attrs = if (pa < 0x4000_0000) device_block else normal_block;
                block_table[i] = pa | attrs;
            }
            l0_table[0] = (@intFromPtr(&block_table) & ADDR_MASK) | DESC_TABLE | DESC_VALID;
        },
        65536 => {
            const block_size: u64 = 0x2000_0000;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                const pa = @as(u64, i) * block_size;
                const attrs = if (pa < 0x4000_0000) device_block else normal_block;
                l0_table[i] = pa | attrs;
            }
        },
        else => unreachable,
    }

    kernel_tcr = tcrValue();
    const mair: u64 = (@as(u64, MAIR_NORMAL) << 0) |
        (@as(u64, MAIR_DEVICE_nGnRnE) << 8);
    const ttbr = @intFromPtr(&l0_table);

    asm volatile (
        \\ msr mair_el1, %[mair]
        \\ msr ttbr0_el1, %[ttbr]
        \\ msr tcr_el1, %[tcr]
        \\ isb
        \\ tlbi vmalle1
        \\ dsb sy
        \\ isb
        \\ mrs x9, sctlr_el1
        \\ orr x9, x9, %[en]
        \\ msr sctlr_el1, x9
        \\ isb
        :
        : [mair] "r" (mair),
          [ttbr] "r" (ttbr),
          [tcr] "r" (kernel_tcr),
          [en] "r" (SCTLR_ENABLE),
        : .{ .x9 = true, .memory = true });
}

pub const MapError = error{ OutOfMemory, TableLocked, BadAlignment };

pub const WalkerConfig = struct {
    hhdm_offset: usize,
    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
};

pub var hhdm_offset: usize = 0;
var alloc_page: *const fn () ?u64 = unsetAlloc;
var free_page: *const fn (u64) void = unsetFree;

fn unsetAlloc() ?u64 {
    return null;
}

fn unsetFree(_: u64) void {}

pub fn configureWalker(cfg: WalkerConfig) void {
    hhdm_offset = cfg.hhdm_offset;
    alloc_page = cfg.alloc_page;
    free_page = cfg.free_page;
}

const memory = struct {
    fn freePage(pa: u64) void {
        free_page(pa);
    }
};

inline fn tablePtr(phys: u64) [*]u64 {
    return @ptrFromInt(@as(usize, @intCast(phys)) + hhdm_offset);
}

inline fn idx(virt: u64, d: u3) usize {
    const shift: u6 = @intCast(
        @as(u32, g.page_shift) + @as(u32, g.level_bits) * (@as(u32, g.level_count) - 1 - @as(u32, d)),
    );
    const mask: u64 = (@as(u64, 1) << @intCast(g.level_bits)) - 1;
    return @intCast((virt >> shift) & mask);
}

inline fn zeroTable(tbl: [*]u64) void {
    var i: usize = 0;
    while (i < g.entries_per_table) : (i += 1) tbl[i] = 0;
}

fn walkOrCreate(parent: [*]u64, i: usize) MapError![*]u64 {
    const entry = parent[i];
    if ((entry & DESC_VALID) != 0) {
        if ((entry & DESC_TABLE) == 0) return error.TableLocked;
        return tablePtr(entry & ADDR_MASK);
    }
    const phys = alloc_page() orelse return error.OutOfMemory;
    const new = tablePtr(phys);
    zeroTable(new);
    parent[i] = (phys & ADDR_MASK) | DESC_TABLE | DESC_VALID;
    return new;
}

/// 2 MB Device-nGnRnE identity mapping (Limine boot path, 4 KB granule only).
pub fn mapDeviceIdentity2m(phys: u64) MapError!void {
    var ttbr0: u64 = undefined;
    asm volatile ("mrs %[r], ttbr0_el1"
        : [r] "=r" (ttbr0),
    );
    const l0 = tablePtr(ttbr0 & ADDR_MASK);

    const l1 = try walkOrCreate(l0, idx(phys, 0));
    const l2 = try walkOrCreate(l1, idx(phys, 1));

    const block_va = phys & ~@as(u64, 0x1F_FFFF);
    const leaf = idx(block_va, 2);
    if ((l2[leaf] & DESC_VALID) != 0) return;

    l2[leaf] = (block_va & ADDR_MASK) |
        attrIndex(1) | BLOCK_SH_OUTER | BLOCK_AP_RW_EL1 | BLOCK_AF | DESC_VALID;

    asm volatile (
        \\ dsb ishst
        \\ tlbi vaae1is, %[va]
        \\ dsb ish
        \\ isb
        :
        : [va] "r" (block_va >> 12),
        : .{ .memory = true });
}

var kernel_ttbr0_root: u64 = 0;

pub fn captureKernelTtbr0() void {
    var v: u64 = undefined;
    asm volatile ("mrs %[r], ttbr0_el1"
        : [r] "=r" (v),
    );
    kernel_ttbr0_root = v & ADDR_MASK;
}

pub const PageTable = struct {
    root: u64,
};

pub fn userTableCreate() MapError!PageTable {
    const phys = alloc_page() orelse return error.OutOfMemory;
    const root = tablePtr(phys);
    zeroTable(root);

    if (kernel_ttbr0_root != 0) {
        const kroot = tablePtr(kernel_ttbr0_root);
        var i: usize = 0;
        while (i < g.kernel_shared_entries) : (i += 1) root[i] = kroot[i];
    }

    return .{ .root = phys };
}

/// Frees page-table pages only; aspace.destroy frees leaf PAs.
pub fn userTableDestroy(t: *PageTable) void {
    const root = tablePtr(t.root);
    var i: usize = g.kernel_shared_entries;
    while (i < g.entries_per_table) : (i += 1) {
        if ((root[i] & DESC_VALID) != 0) freeSubtree(root[i] & ADDR_MASK, 1);
        root[i] = 0;
    }
    memory.freePage(t.root);
    t.root = 0;
}

fn freeSubtree(table_phys: u64, depth: u3) void {
    if (depth + 1 < g.level_count) {
        const tbl = tablePtr(table_phys);
        var i: usize = 0;
        while (i < g.entries_per_table) : (i += 1) {
            const entry = tbl[i];
            if ((entry & DESC_VALID) == 0) continue;
            if ((entry & DESC_TABLE) == 0) continue;
            freeSubtree(entry & ADDR_MASK, depth + 1);
        }
    }
    memory.freePage(table_phys);
}

pub fn userTableTranslate(t: *PageTable, va: u64) ?u64 {
    var tbl = tablePtr(t.root);
    var depth: u3 = 0;
    while (depth + 1 < g.level_count) : (depth += 1) {
        const e = tbl[idx(va, depth)];
        if ((e & DESC_VALID) == 0) return null;
        if ((e & DESC_TABLE) == 0) return null;
        tbl = tablePtr(e & ADDR_MASK);
    }
    const leaf = tbl[idx(va, depth)];
    if ((leaf & DESC_VALID) == 0) return null;
    return leaf & ADDR_MASK;
}

pub const MapFlags = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
    user: bool = false,
    device: bool = false,
};

fn leafEntry(pa: u64, prot: MapFlags) u64 {
    var e: u64 = (pa & ADDR_MASK) | PAGE_DESC | BLOCK_AF | DESC_VALID;
    e |= if (prot.device) attrIndex(1) | BLOCK_SH_OUTER else attrIndex(0) | BLOCK_SH_INNER;

    const ap: u64 = if (prot.user)
        (if (prot.write) BLOCK_AP_RW_USER else BLOCK_AP_RO_USER)
    else
        (if (prot.write) BLOCK_AP_RW_EL1 else BLOCK_AP_RO_EL1);
    e |= ap;

    if (!prot.execute) {
        e |= BLOCK_UXN | BLOCK_PXN;
    } else if (prot.user) {
        e |= BLOCK_PXN;
    }

    return e;
}

pub fn userTableMap(t: *PageTable, va: u64, pa: u64, prot: MapFlags) MapError!void {
    const mask = g.page_size - 1;
    if ((va & mask) != 0 or (pa & mask) != 0) return error.BadAlignment;

    var tbl = tablePtr(t.root);
    var depth: u3 = 0;
    while (depth + 1 < g.level_count) : (depth += 1) {
        tbl = try walkOrCreate(tbl, idx(va, depth));
    }
    tbl[idx(va, depth)] = leafEntry(pa, prot);

    asm volatile (
        \\ dsb ishst
        \\ tlbi vaae1is, %[v]
        \\ dsb ish
        \\ isb
        :
        : [v] "r" (va >> 12),
        : .{ .memory = true });
}

pub fn userTableUnmap(t: *PageTable, va: u64) void {
    var tbl = tablePtr(t.root);
    var depth: u3 = 0;
    while (depth + 1 < g.level_count) : (depth += 1) {
        const e = tbl[idx(va, depth)];
        if ((e & DESC_VALID) == 0) return;
        if ((e & DESC_TABLE) == 0) return;
        tbl = tablePtr(e & ADDR_MASK);
    }
    tbl[idx(va, depth)] = 0;

    asm volatile (
        \\ dsb ishst
        \\ tlbi vaae1is, %[v]
        \\ dsb ish
        \\ isb
        :
        : [v] "r" (va >> 12),
        : .{ .memory = true });
}

pub fn userTableLoad(t: *PageTable) void {
    asm volatile (
        \\ msr ttbr0_el1, %[r]
        \\ isb
        \\ tlbi vmalle1
        \\ dsb sy
        \\ isb
        :
        : [r] "r" (t.root),
        : .{ .memory = true });
}
