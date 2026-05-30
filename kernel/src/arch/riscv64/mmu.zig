// M-mode kernel runs paging-off; satp is only walked for U-mode loads/stores.
//
// The kernel cannot dereference user VAs directly. Callers must translate
// via `userTableTranslate` and access through `memory.physToVirt(pa)`.
pub const kernel_translates_user = true;

const std = @import("std");

const PAGE_SIZE: u64 = 4096;

// Sv39 PTE bits.
const PTE_V: u64 = 1 << 0;
const PTE_R: u64 = 1 << 1;
const PTE_W: u64 = 1 << 2;
const PTE_X: u64 = 1 << 3;
const PTE_U: u64 = 1 << 4;
const PTE_A: u64 = 1 << 6;
const PTE_D: u64 = 1 << 7;
const PTE_PPN_SHIFT: u6 = 10;

pub const MapError = error{ OutOfMemory, Unsupported };

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

var alloc_page: *const fn () ?u64 = unsetAlloc;
var free_page: *const fn (u64) void = unsetFree;

fn unsetAlloc() ?u64 {
    return null;
}

fn unsetFree(_: u64) void {}

pub const Config = struct {
    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
};

pub fn init(cfg: Config) void {
    alloc_page = cfg.alloc_page;
    free_page = cfg.free_page;
}

pub fn captureKernelTtbr0() void {}

inline fn tablePtr(phys: u64) *[512]u64 {
    // Paging off: PA == VA for kernel-side access.
    return @ptrFromInt(@as(usize, @intCast(phys)));
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
        if (pteHasLeaf(pte)) return error.Unsupported;
        return tablePtr(pteAddr(pte));
    }
    const phys = alloc_page() orelse return error.OutOfMemory;
    const child = tablePtr(phys);
    child.* = @splat(0);
    parent[i] = ((phys >> 12) << PTE_PPN_SHIFT) | PTE_V;
    return child;
}

pub fn userTableCreate() MapError!PageTable {
    const phys = alloc_page() orelse return error.OutOfMemory;
    const root = tablePtr(phys);
    root.* = @splat(0);
    return .{ .root = phys };
}

/// Leaf PAs are not freed; the caller walks the regions list.
pub fn userTableDestroy(t: *PageTable) void {
    const root = tablePtr(t.root);
    var i: usize = 0;
    while (i < 512) : (i += 1) {
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
    const root = tablePtr(t.root);
    const l2_pte = root[vpn(va, 2)];
    if ((l2_pte & PTE_V) == 0 or pteHasLeaf(l2_pte)) return null;
    const l1 = tablePtr(pteAddr(l2_pte));
    const l1_pte = l1[vpn(va, 1)];
    if ((l1_pte & PTE_V) == 0 or pteHasLeaf(l1_pte)) return null;
    const l0 = tablePtr(pteAddr(l1_pte));
    const l0_pte = l0[vpn(va, 0)];
    if ((l0_pte & PTE_V) == 0) return null;
    return pteAddr(l0_pte);
}

fn leafPteFlags(prot: MapFlags) u64 {
    var e: u64 = PTE_V | PTE_A | PTE_D;
    if (prot.read) e |= PTE_R;
    if (prot.write) e |= PTE_W;
    if (prot.execute) e |= PTE_X;
    if (prot.user) e |= PTE_U;
    return e;
}

pub fn userTableMap(t: *PageTable, va: u64, pa: u64, prot: MapFlags) MapError!void {
    const root = tablePtr(t.root);
    const l1 = try walkOrCreate(root, vpn(va, 2));
    const l0 = try walkOrCreate(l1, vpn(va, 1));
    l0[vpn(va, 0)] = ((pa >> 12) << PTE_PPN_SHIFT) | leafPteFlags(prot);
}

pub fn userTableUnmap(t: *PageTable, va: u64) void {
    const root = tablePtr(t.root);
    const l1_pte = root[vpn(va, 2)];
    if ((l1_pte & PTE_V) == 0 or pteHasLeaf(l1_pte)) return;
    const l1 = tablePtr(pteAddr(l1_pte));
    const l0_pte = l1[vpn(va, 1)];
    if ((l0_pte & PTE_V) == 0 or pteHasLeaf(l0_pte)) return;
    const l0 = tablePtr(pteAddr(l0_pte));
    l0[vpn(va, 0)] = 0;
    asm volatile ("sfence.vma %[v], zero"
        :
        : [v] "r" (va),
        : .{ .memory = true });
}

pub fn userTableLoad(t: *PageTable) void {
    // Sv39 satp: mode=8 in [63:60], PPN in [43:0].
    const satp = (@as(u64, 8) << 60) | (t.root >> 12);
    asm volatile (
        \\ csrw satp, %[v]
        \\ sfence.vma zero, zero
        :
        : [v] "r" (satp),
        : .{ .memory = true });
}
