const std = @import("std");

pub const MapError = error{ OutOfMemory, LeafInTheWay };

pub const WalkerConfig = struct {
    hhdm_offset: usize,
    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
};

var hhdm_offset: usize = 0;
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

// Sv39 PTE bits.
const PTE_V: u64 = 1 << 0;
const PTE_R: u64 = 1 << 1;
const PTE_W: u64 = 1 << 2;
const PTE_X: u64 = 1 << 3;
const PTE_G: u64 = 1 << 5;
const PTE_A: u64 = 1 << 6;
const PTE_D: u64 = 1 << 7;

const PTE_PPN_SHIFT: u6 = 10;

inline fn tablePtr(phys: u64) *[512]u64 {
    return @ptrFromInt(@as(usize, @intCast(phys)) + hhdm_offset);
}

inline fn vpn(virt: u64, level: u3) usize {
    const shift: u6 = @intCast(12 + 9 * @as(u32, level));
    return @intCast((virt >> shift) & 0x1FF);
}

inline fn pteHasLeaf(pte: u64) bool {
    return (pte & (PTE_R | PTE_W | PTE_X)) != 0;
}

inline fn pteAddr(pte: u64) u64 {
    return (pte >> PTE_PPN_SHIFT) << 12;
}

fn walkOrCreate(parent: *[512]u64, i: usize) MapError!*[512]u64 {
    const pte = parent[i];
    if ((pte & PTE_V) != 0) {
        if (pteHasLeaf(pte)) return error.LeafInTheWay;
        return tablePtr(pteAddr(pte));
    }
    const phys = alloc_page() orelse return error.OutOfMemory;
    const child = tablePtr(phys);
    child.* = @splat(0);
    parent[i] = ((phys >> 12) << PTE_PPN_SHIFT) | PTE_V;
    return child;
}

/// Drops a 2 MB R/W superpage at level 1; mode picked from satp.MODE.
pub fn mapIdentity2m(phys: u64) MapError!void {
    var satp: u64 = undefined;
    asm volatile ("csrr %[r], satp"
        : [r] "=r" (satp),
    );
    const mode: u4 = @intCast((satp >> 60) & 0xf);
    const top_level: u3 = switch (mode) {
        8 => 2,
        9 => 3,
        10 => 4,
        else => return error.OutOfMemory,
    };

    const root_ppn = satp & 0x0FFF_FFFF_FFFF;
    var table = tablePtr(root_ppn << 12);

    var level: u3 = top_level;
    while (level > 1) : (level -= 1) {
        table = try walkOrCreate(table, vpn(phys, level));
    }

    const leaf_va = phys & ~@as(u64, 0x1F_FFFF);
    const leaf_i = vpn(leaf_va, 1);
    if ((table[leaf_i] & PTE_V) != 0) return;

    table[leaf_i] = ((leaf_va >> 12) << PTE_PPN_SHIFT) |
        PTE_V | PTE_R | PTE_W | PTE_A | PTE_D | PTE_G;

    asm volatile (
        \\ sfence.vma %[va], zero
        :
        : [va] "r" (leaf_va),
        : .{ .memory = true });
}

const PTE_U: u64 = 1 << 4;

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

var kernel_satp: u64 = 0;
// Paging-mode-driven walk depth. satp.MODE: 8=Sv39 (3 levels), 9=Sv48 (4),
// 10=Sv57 (5). 0=Bare (raw boot, but we don't install user pages there).
var walk_levels: u3 = 3;

pub fn captureKernelTtbr0() void {
    asm volatile ("csrr %[r], satp"
        : [r] "=r" (kernel_satp),
    );
    const mode: u4 = @intCast((kernel_satp >> 60) & 0xF);
    walk_levels = switch (mode) {
        8 => 3,
        9 => 4,
        10 => 5,
        else => 3,
    };
}

/// Top-level slot index the user range lives in. For Sv39 USER_VA_BASE=64
/// GB lands in L2[64] (top-level). For Sv48 it lands in L3[0]. For Sv57
/// L4[0]. We detect this dynamically from walk_levels.
inline fn userTopSlot(va: u64) usize {
    const top: u3 = walk_levels - 1;
    const shift: u6 = @intCast(12 + 9 * @as(u32, top));
    return @intCast((va >> shift) & 0x1FF);
}

pub fn userTableCreate() MapError!PageTable {
    const phys = alloc_page() orelse return error.OutOfMemory;
    const root = tablePtr(phys);
    root.* = @splat(0);
    // Start with all kernel top-level entries. Kernel/HHDM/device mappings
    // must stay valid when satp swaps to this user table.
    if (kernel_satp == 0) return .{ .root = phys };

    const ksatp = kernel_satp;
    const root_ppn = ksatp & 0x0FFF_FFFF_FFFF;
    const kroot = tablePtr(root_ppn << 12);
    root.* = kroot.*;

    // Sv48/Sv57 problem: USER_VA_BASE (64 GB) sits in the SAME top-level
    // slot Limine uses for identity-mapping low memory (devices, kernel
    // image, all in the lowest L3 entry). If we leave that L3 entry
    // pointing at Limine's sub-table, every process userTableMap into
    // L2[64+] modifies Limine's L2, and the next process inherits those
    // mappings on userTableCreate. Symptom: init's .data.rel.ro pointers
    // get aliased across processes; user PC jumps to garbage.
    //
    // Fix: when the user slot conflicts with a populated kernel slot,
    // deep-copy the sub-table so the user owns its own L2/L1/L0 chain.
    // Devices Limine identity-mapped in L2[0..] stay reachable through the
    // copy, but L2[64+] becomes per-process.
    if (walk_levels >= 4) {
        const slot = userTopSlot(USER_VA_BASE_RV);
        const k_entry = root[slot];
        if ((k_entry & PTE_V) != 0 and !pteHasLeaf(k_entry)) {
            const new_phys = alloc_page() orelse return error.OutOfMemory;
            const new_l2 = tablePtr(new_phys);
            const kernel_l2 = tablePtr(pteAddr(k_entry));
            new_l2.* = kernel_l2.*;
            root[slot] = ((new_phys >> 12) << PTE_PPN_SHIFT) | PTE_V;
        }
    }

    return .{ .root = phys };
}

/// Local copy of kernel/aspace.zig USER_VA_BASE for riscv64 to avoid an
/// import cycle (aspace imports arch).
const USER_VA_BASE_RV: u64 = 0x10_0000_0000;

/// Frees only the user-range subtrees [USER_VA_BASE, USER_STACK_TOP). The
/// other root entries are kernel-inherited (low identity-mapped devices +
/// high-half kernel image) and shared across every process. Freeing them
/// would corrupt the kernel mapping when this process exits. Leaf PAs are
/// not freed. Caller walks regions for user-leaf cleanup.
pub fn userTableDestroy(t: *PageTable) void {
    const root = tablePtr(t.root);
    const top: u3 = walk_levels - 1;
    const shift: u6 = @intCast(12 + 9 * @as(u32, top));
    const user_lo: usize = @intCast((USER_VA_BASE_RV >> shift) & 0x1FF);
    // USER_STACK_TOP for riscv64 = 0x0000_0030_0000_0000.
    const user_hi: usize = @intCast(((0x0000_0030_0000_0000 + (@as(u64, 1) << shift) - 1) >> shift) & 0x1FF);
    var i: usize = user_lo;
    while (i < user_hi) : (i += 1) {
        const pte = root[i];
        if ((pte & PTE_V) != 0 and !pteHasLeaf(pte)) {
            freeSubtree(pteAddr(pte), 1);
        }
        root[i] = 0;
    }
    free_page(t.root);
    t.root = 0;
}

fn freeSubtree(table_phys: u64, level_below_top: u3) void {
    if (level_below_top < 2) {
        const tbl = tablePtr(table_phys);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            const pte = tbl[i];
            if ((pte & PTE_V) == 0) continue;
            if (pteHasLeaf(pte)) continue;
            freeSubtree(pteAddr(pte), level_below_top + 1);
        }
    }
    free_page(table_phys);
}

pub fn userTableTranslate(t: *PageTable, va: u64) ?u64 {
    var cur = tablePtr(t.root);
    var level: i32 = @as(i32, walk_levels) - 1;
    while (level > 0) : (level -= 1) {
        const pte = cur[vpn(va, @intCast(level))];
        if ((pte & PTE_V) == 0 or pteHasLeaf(pte)) return null;
        cur = tablePtr(pteAddr(pte));
    }
    const leaf = cur[vpn(va, 0)];
    if ((leaf & PTE_V) == 0) return null;
    return pteAddr(leaf);
}

pub fn userLeafPte(t: *PageTable, va: u64) u64 {
    var cur = tablePtr(t.root);
    var level: i32 = @as(i32, walk_levels) - 1;
    while (level > 0) : (level -= 1) {
        const pte = cur[vpn(va, @intCast(level))];
        if ((pte & PTE_V) == 0 or pteHasLeaf(pte)) return 0;
        cur = tablePtr(pteAddr(pte));
    }
    return cur[vpn(va, 0)];
}

fn leafPteFlags(prot: MapFlags) u64 {
    var e: u64 = PTE_V | PTE_A | PTE_D;
    if (prot.read) e |= PTE_R;
    if (prot.write) e |= PTE_W;
    if (prot.execute) e |= PTE_X;
    if (prot.user) e |= PTE_U;
    return e;
}

fn userWalkOrCreate(parent: *[512]u64, i: usize) MapError!*[512]u64 {
    const pte = parent[i];
    if ((pte & PTE_V) != 0) {
        if (pteHasLeaf(pte)) return error.LeafInTheWay;
        return tablePtr(pteAddr(pte));
    }
    const phys = alloc_page() orelse return error.OutOfMemory;
    const child = tablePtr(phys);
    child.* = @splat(0);
    parent[i] = ((phys >> 12) << PTE_PPN_SHIFT) | PTE_V;
    return child;
}

pub fn userTableMap(t: *PageTable, va: u64, pa: u64, prot: MapFlags) MapError!void {
    const root = tablePtr(t.root);
    // walk_levels mirrors satp.MODE (Sv39 = 3 levels, Sv48 = 4 levels,
    // Sv57 = 5 levels). userTableLoad preserves Limine's MODE so the user
    // PT must match. Installing Sv39-shaped entries while the HW walker
    // does Sv48 produces an instruction-page-fault on the very first
    // U-mode fetch.
    var cur: *[512]u64 = root;
    var level: i32 = @as(i32, walk_levels) - 1;
    while (level > 0) : (level -= 1) {
        cur = try userWalkOrCreate(cur, vpn(va, @intCast(level)));
    }
    const i = vpn(va, 0);
    cur[i] = ((pa >> 12) << PTE_PPN_SHIFT) | leafPteFlags(prot);
}

pub fn userTableUnmap(t: *PageTable, va: u64) void {
    var cur = tablePtr(t.root);
    var level: i32 = @as(i32, walk_levels) - 1;
    while (level > 0) : (level -= 1) {
        const pte = cur[vpn(va, @intCast(level))];
        if ((pte & PTE_V) == 0 or pteHasLeaf(pte)) return;
        cur = tablePtr(pteAddr(pte));
    }
    cur[vpn(va, 0)] = 0;
    asm volatile ("sfence.vma %[va], zero"
        :
        : [va] "r" (va),
        : .{ .memory = true });
}

pub fn userTableLoad(t: *PageTable) void {
    // Preserve the MODE Limine left in satp (typically Sv48 on QEMU virt).
    // Hardcoding MODE=Sv39 here would change the address-translation depth
    // mid-execution and corrupt the kernel's higher-half mapping.
    var cur: u64 = undefined;
    asm volatile ("csrr %[r], satp"
        : [r] "=r" (cur),
    );
    const mode_mask: u64 = @as(u64, 0xF) << 60;
    const satp = (cur & mode_mask) | (t.root >> 12);
    asm volatile (
        \\ csrw satp, %[v]
        \\ sfence.vma zero, zero
        :
        : [v] "r" (satp),
        : .{ .memory = true });
}
