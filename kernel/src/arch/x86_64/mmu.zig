const PAGE_SIZE: u64 = 4096;
const PRESENT: u64 = 1 << 0;
const WRITABLE: u64 = 1 << 1;
const PAGE_SIZE_BIT: u64 = 1 << 7;
const CACHE_DISABLE: u64 = 1 << 4;
const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

extern fn do_invlpg(virt: u64) callconv(.c) void;

pub const Config = struct {
    hhdm_offset: u64,
    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
};

var hhdm_offset: u64 = 0;
var alloc_page: *const fn () ?u64 = unset_alloc_page;
var free_page: *const fn (u64) void = unset_free_page;

fn unset_alloc_page() ?u64 {
    return null;
}

fn unset_free_page(_: u64) void {}

pub fn init(cfg: Config) void {
    hhdm_offset = cfg.hhdm_offset;
    alloc_page = cfg.alloc_page;
    free_page = cfg.free_page;
}

pub fn hhdmOffset() u64 {
    return hhdm_offset;
}

fn tablePtr(phys: u64) *[512]u64 {
    return @ptrFromInt(@as(usize, @intCast(phys + hhdm_offset)));
}

fn readCr3() u64 {
    var v: u64 = undefined;
    asm volatile ("mov %%cr3, %[r]"
        : [r] "=r" (v),
    );
    return v & ADDR_MASK;
}

inline fn idx(virt: u64, level: u6) usize {
    return @intCast((virt >> @intCast(12 + 9 * @as(u32, level))) & 0x1FF);
}

pub const MapError = error{ OutOfMemory, HugePageInWay };

pub fn map2m(virt: u64, phys: u64, flags: u64) MapError!void {
    const pml4 = tablePtr(readCr3());
    const pdpt = try walkOrCreate(pml4, idx(virt, 3));
    const pd = try walkOrCreate(pdpt, idx(virt, 2));

    const i = idx(virt, 1);
    // UEFI firmware identity-maps low memory including MMIO. Don't overwrite.
    if ((pd[i] & PRESENT) != 0) return;

    pd[i] = (phys & ~@as(u64, 0x1F_FFFF)) | PRESENT | PAGE_SIZE_BIT | flags;
    do_invlpg(virt);
}

fn walkOrCreate(parent: *[512]u64, i: usize) MapError!*[512]u64 {
    const entry = parent[i];
    if ((entry & PRESENT) != 0 and (entry & PAGE_SIZE_BIT) == 0) {
        return tablePtr(entry & ADDR_MASK);
    }
    if ((entry & PRESENT) != 0 and (entry & PAGE_SIZE_BIT) != 0) {
        return error.HugePageInWay;
    }
    const new_phys = alloc_page() orelse return error.OutOfMemory;
    const new = tablePtr(new_phys);
    // Manual byte-loop zero: @memset(4096) lowers to `rep stosq`, which has
    // hung on fresh HHDM pages under UEFI Limine.
    var k: usize = 0;
    const bytes: [*]volatile u8 = @ptrCast(new);
    while (k < PAGE_SIZE) : (k += 1) bytes[k] = 0;
    parent[i] = new_phys | PRESENT | WRITABLE;
    return new;
}

pub fn mapMmio(virt: u64, phys: u64, len: u64) MapError!void {
    const align_2m: u64 = 0x20_0000;
    const phys_base = phys & ~(align_2m - 1);
    const virt_base = virt & ~(align_2m - 1);
    const end_phys = ((phys + len) + align_2m - 1) & ~(align_2m - 1);
    var cur: u64 = 0;
    while (phys_base + cur < end_phys) : (cur += align_2m) {
        try map2m(virt_base + cur, phys_base + cur, WRITABLE | CACHE_DISABLE);
    }
}

/// HHDM-map a phys range as cacheable. Used when Limine HHDM has gaps over
/// non-usable phys regions (e.g. ACPI table pages on UEFI x86_64): the PD
/// slot may be empty (no mapping at all) OR point at a sparse 4 K PT
/// (Limine maps only known-usable subpages). In the sparse case we fill
/// only the 4 K slot for `phys`; otherwise we install a fresh 2 M leaf.
pub fn ensurePhysMapped(phys: u64, len: u64) void {
    const page_4k: u64 = 0x1000;
    const phys_lo = phys & ~(page_4k - 1);
    const phys_hi = (phys + len + page_4k - 1) & ~(page_4k - 1);
    var p = phys_lo;
    while (p < phys_hi) : (p += page_4k) {
        ensure4k(p + hhdm_offset, p);
    }
}

fn ensure4k(virt: u64, phys: u64) void {
    const pml4 = tablePtr(readCr3());
    const pdpt = walkOrCreate(pml4, idx(virt, 3)) catch return;
    const pd = walkOrCreate(pdpt, idx(virt, 2)) catch return;

    const i = idx(virt, 1);
    const e = pd[i];
    if ((e & PRESENT) != 0 and (e & PAGE_SIZE_BIT) != 0) return;
    if ((e & PRESENT) != 0 and (e & PAGE_SIZE_BIT) == 0) {
        const pt = tablePtr(e & ADDR_MASK);
        const j = idx(virt, 0);
        if ((pt[j] & PRESENT) == 0) {
            pt[j] = (phys & ADDR_MASK) | PRESENT | WRITABLE;
            do_invlpg(virt);
        }
        return;
    }

    pd[i] = (phys & ~@as(u64, 0x1F_FFFF)) | PRESENT | PAGE_SIZE_BIT | WRITABLE;
    do_invlpg(virt);
}

const US: u64 = 1 << 2;
const NX: u64 = 1 << 63;

pub const MapFlags = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
    user: bool = false,
    device: bool = false,
};

pub const PageTable = struct {
    root: u64,
};

var kernel_pml4_phys: u64 = 0;

pub fn captureKernelTtbr0() void {
    kernel_pml4_phys = readCr3();
}

pub fn readLeafPte(va: u64) u64 {
    const pml4 = tablePtr(readCr3());
    const e_pml4 = pml4[idx(va, 3)];
    if ((e_pml4 & PRESENT) == 0) return 0;
    const pdpt = tablePtr(e_pml4 & ADDR_MASK);
    const e_pdpt = pdpt[idx(va, 2)];
    if ((e_pdpt & PRESENT) == 0) return 0;
    if ((e_pdpt & PAGE_SIZE_BIT) != 0) return e_pdpt;
    const pd = tablePtr(e_pdpt & ADDR_MASK);
    const e_pd = pd[idx(va, 1)];
    if ((e_pd & PRESENT) == 0) return 0;
    if ((e_pd & PAGE_SIZE_BIT) != 0) return e_pd;
    const pt = tablePtr(e_pd & ADDR_MASK);
    return pt[idx(va, 0)];
}

/// Forces the WRITABLE bit on every page-table leaf covering
/// `[virt_lo, virt_hi)`. Needed under Limine x86_64 BIOS, which maps
/// PT_LOAD .data segments without the WRITABLE bit set on the leaf even
/// when p_flags=RW, making every store to a `pub var` silently fault.
pub fn forceWritableRange(virt_lo: u64, virt_hi: u64) void {
    const pml4 = tablePtr(readCr3());
    var va = virt_lo & ~@as(u64, 0xFFF);
    while (va < virt_hi) : (va += PAGE_SIZE) {
        const e_pml4 = pml4[idx(va, 3)];
        if ((e_pml4 & PRESENT) == 0) continue;
        pml4[idx(va, 3)] = e_pml4 | WRITABLE;
        const pdpt = tablePtr(e_pml4 & ADDR_MASK);
        const e_pdpt = pdpt[idx(va, 2)];
        if ((e_pdpt & PRESENT) == 0) continue;
        pdpt[idx(va, 2)] = e_pdpt | WRITABLE;
        if ((e_pdpt & PAGE_SIZE_BIT) != 0) {
            do_invlpg(va);
            continue;
        }
        const pd = tablePtr(e_pdpt & ADDR_MASK);
        const e_pd = pd[idx(va, 1)];
        if ((e_pd & PRESENT) == 0) continue;
        pd[idx(va, 1)] = e_pd | WRITABLE;
        if ((e_pd & PAGE_SIZE_BIT) != 0) {
            do_invlpg(va);
            continue;
        }
        const pt = tablePtr(e_pd & ADDR_MASK);
        const e_pt = pt[idx(va, 0)];
        if ((e_pt & PRESENT) == 0) continue;
        pt[idx(va, 0)] = e_pt | WRITABLE;
        do_invlpg(va);
    }
}

pub fn userTableCreate() MapError!PageTable {
    const phys = alloc_page() orelse return error.OutOfMemory;
    const new = tablePtr(phys);
    var k: usize = 0;
    const new_bytes: [*]volatile u8 = @ptrCast(new);
    while (k < PAGE_SIZE) : (k += 1) new_bytes[k] = 0;
    if (kernel_pml4_phys != 0) {
        // PML4 slots 1..3 cover [USER_VA_BASE, USER_STACK_TOP) for
        // x86_64 (see kernel/src/aspace.zig). Copy every kernel slot
        // except those three so the kernel stays mapped regardless of
        // whether it lives in PML4[0] (UEFI) or PML4[256..512] (Limine).
        const USER_LO: usize = 1;
        const USER_HI: usize = 4;
        const kpml4 = tablePtr(kernel_pml4_phys);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            if (i >= USER_LO and i < USER_HI) continue;
            new[i] = kpml4[i];
        }
    }
    return .{ .root = phys };
}

/// Free ONLY the PML4 entries that cover [USER_VA_BASE, USER_STACK_TOP).
/// PML4[0] is kernel-inherited (low identity-mapped image + IO + initrd
/// under UEFI; HHDM low half under Limine) and PML4[256..512] is the
/// kernel high half. Both are shared across every process. Freeing
/// PML4[0] corrupted the kernel mapping for every subsequent process and
/// crashed UEFI at cr2=0xea05000 (an ex-kernel PT page on the free list).
/// Leaf PAs are not freed. Caller walks regions for user-leaf cleanup.
pub fn userTableDestroy(t: *PageTable) void {
    const pml4 = tablePtr(t.root);
    // x86_64 USER_VA_BASE=0x80_0000_0000, USER_STACK_TOP=0x200_0000_0000.
    // PML4 stride = 1 << 39 = 0x80_0000_0000 → indices [1, 4).
    const USER_LO: usize = 1;
    const USER_HI: usize = 4;
    var i: usize = USER_LO;
    while (i < USER_HI) : (i += 1) {
        const entry = pml4[i];
        if ((entry & PRESENT) != 0 and (entry & PAGE_SIZE_BIT) == 0) {
            freeSubtree(entry & ADDR_MASK, 1);
        }
        pml4[i] = 0;
    }
    free_page(t.root);
    t.root = 0;
}

fn freeSubtree(table_phys: u64, level: u3) void {
    if (level < 3) {
        const tbl = tablePtr(table_phys);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const entry = tbl[i];
            if ((entry & PRESENT) == 0) continue;
            if ((entry & PAGE_SIZE_BIT) != 0) continue;
            freeSubtree(entry & ADDR_MASK, level + 1);
        }
    }
    free_page(table_phys);
}

pub fn userTableTranslate(t: *PageTable, va: u64) ?u64 {
    const pml4 = tablePtr(t.root);
    const pdpt_e = pml4[idx(va, 3)];
    if ((pdpt_e & PRESENT) == 0) return null;
    const pdpt = tablePtr(pdpt_e & ADDR_MASK);
    const pd_e = pdpt[idx(va, 2)];
    if ((pd_e & PRESENT) == 0) return null;
    const pd = tablePtr(pd_e & ADDR_MASK);
    const pt_e = pd[idx(va, 1)];
    if ((pt_e & PRESENT) == 0) return null;
    const pt = tablePtr(pt_e & ADDR_MASK);
    const leaf = pt[idx(va, 0)];
    if ((leaf & PRESENT) == 0) return null;
    return leaf & ADDR_MASK;
}

fn leafFlags(prot: MapFlags) u64 {
    var e: u64 = PRESENT | US;
    if (prot.write) e |= WRITABLE;
    if (!prot.execute) e |= NX;
    if (prot.device) e |= CACHE_DISABLE;
    return e;
}

fn userWalkOrCreate(parent: *[512]u64, i: usize, user_visible: bool) MapError!*[512]u64 {
    const entry = parent[i];
    if ((entry & PRESENT) != 0 and (entry & PAGE_SIZE_BIT) == 0) {
        if (user_visible) parent[i] |= US;
        return tablePtr(entry & ADDR_MASK);
    }
    if ((entry & PRESENT) != 0 and (entry & PAGE_SIZE_BIT) != 0) {
        return error.HugePageInWay;
    }
    const new_phys = alloc_page() orelse return error.OutOfMemory;
    const new = tablePtr(new_phys);
    @memset(@as([*]u8, @ptrCast(new))[0..PAGE_SIZE], 0);
    parent[i] = new_phys | PRESENT | WRITABLE | (if (user_visible) US else 0);
    return new;
}

pub fn userTableMap(t: *PageTable, va: u64, pa: u64, prot: MapFlags) MapError!void {
    const pml4 = tablePtr(t.root);
    const pdpt = try userWalkOrCreate(pml4, idx(va, 3), true);
    const pd = try userWalkOrCreate(pdpt, idx(va, 2), true);
    const pt = try userWalkOrCreate(pd, idx(va, 1), true);
    pt[idx(va, 0)] = (pa & ADDR_MASK) | leafFlags(prot);
}

pub fn userTableUnmap(t: *PageTable, va: u64) void {
    const pml4 = tablePtr(t.root);
    const pdpt_e = pml4[idx(va, 3)];
    if ((pdpt_e & PRESENT) == 0) return;
    const pdpt = tablePtr(pdpt_e & ADDR_MASK);
    const pd_e = pdpt[idx(va, 2)];
    if ((pd_e & PRESENT) == 0) return;
    const pd = tablePtr(pd_e & ADDR_MASK);
    const pt_e = pd[idx(va, 1)];
    if ((pt_e & PRESENT) == 0) return;
    const pt = tablePtr(pt_e & ADDR_MASK);
    pt[idx(va, 0)] = 0;
    do_invlpg(va);
}

pub fn userTableLoad(t: *PageTable) void {
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (t.root),
        : .{ .memory = true });
}
