// Classic 2-level paging (no PAE). PD index = VA[31:22], PT index = VA[21:12].
// The kernel PD identity-maps the first 4 MB with a 4 MB PSE page.

const PAGE_SIZE: u32 = 4096;

const P: u32 = 1 << 0;
const RW: u32 = 1 << 1;
const US: u32 = 1 << 2;
const PWT: u32 = 1 << 3;
const PCD: u32 = 1 << 4;
const PS: u32 = 1 << 7;

const ADDR_MASK: u32 = 0xFFFFF000;

pub const MapError = error{OutOfMemory};

pub const MapFlags = struct {
    read: bool = true,
    write: bool = false,
    // i386 32-bit paging has no NX without PAE. Ignored.
    execute: bool = false,
    user: bool = false,
    device: bool = false,
};

pub const PageTable = struct {
    root: u64,
};

var kernel_pd: [1024]u32 align(4096) = @splat(0);
var kernel_pd_phys: u32 = 0;

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

pub fn enable() void {
    // Identity-map the full 4 GB via PSE 4 MB pages, set up in asm so LLVM
    // can't reorder/eliminate. The plain Zig version (loop or even two
    // unrolled stores) triple-faulted in ReleaseFast; doing it inline keeps
    // the codegen out of the way entirely.
    kernel_pd_phys = @intCast(@intFromPtr(&kernel_pd));
    asm volatile (
        \\ cld
        \\ // edi = &kernel_pd; ecx = 1024; eax = first PDE (0 | P|RW|PS).
        \\ movl %[pd], %%edi
        \\ movl $1024, %%ecx
        \\ movl $0x83, %%eax
        \\0:
        \\ stosl
        \\ addl $0x400000, %%eax
        \\ loop 0b
        \\
        \\ // Load CR3, enable CR4.PSE, enable CR0.PG.
        \\ movl %[pd], %%cr3
        \\ movl %%cr4, %%eax
        \\ orl  $0x10, %%eax
        \\ movl %%eax, %%cr4
        \\ movl %%cr0, %%eax
        \\ orl  $0x80000000, %%eax
        \\ movl %%eax, %%cr0
        :
        : [pd] "r" (kernel_pd_phys),
        : .{ .eax = true, .ecx = true, .edi = true, .memory = true });
}

pub fn captureKernelTtbr0() void {}

fn tablePtr(phys: u32) *[1024]u32 {
    return @ptrFromInt(phys);
}

/// PD slot index for USER_VA_BASE (kernel/aspace.zig). Anything below
/// belongs to the kernel identity map; above is owned by the user PT.
const USER_PD_LO: usize = 0x4000_0000 >> 22;

pub fn userTableCreate() MapError!PageTable {
    const phys64 = alloc_page() orelse return error.OutOfMemory;
    const phys: u32 = @intCast(phys64);
    const pd = tablePtr(phys);
    // Manual byte-loop zero. @memset risks LLVM rewriting it into a call
    // that loops back into itself ([[libc-mem-recursion]]).
    const pd_bytes: [*]volatile u8 = @ptrCast(pd);
    var k: usize = 0;
    while (k < PAGE_SIZE) : (k += 1) pd_bytes[k] = 0;
    // Copy kernel PSE identity slots BELOW USER_VA_BASE so context_switch,
    // IRQ handlers, kernel heap, etc. stay reachable when the user PT is
    // active. User-range slots stay empty for userTableMap to populate.
    var i: usize = 0;
    while (i < USER_PD_LO) : (i += 1) {
        const k_entry = kernel_pd[i];
        if ((k_entry & P) != 0) pd[i] = k_entry;
    }
    return .{ .root = phys };
}

/// Skips kernel-identity slots (PD[0..USER_PD_LO]); leaf PAs aren't freed.
pub fn userTableDestroy(t: *PageTable) void {
    const pd = tablePtr(@intCast(t.root));
    var i: usize = USER_PD_LO;
    while (i < 1024) : (i += 1) {
        const entry = pd[i];
        if ((entry & P) != 0 and (entry & PS) == 0) {
            free_page(entry & ADDR_MASK);
        }
        pd[i] = 0;
    }
    free_page(t.root);
    t.root = 0;
}

pub fn userTableTranslate(t: *PageTable, va: u64) ?u64 {
    if (va > 0xFFFFFFFF) return null;
    const va32: u32 = @intCast(va);
    const pd = tablePtr(@intCast(t.root));
    const pd_i = va32 >> 22;
    const pde = pd[pd_i];
    if ((pde & P) == 0) return null;
    if ((pde & PS) != 0) {
        return (pde & 0xFFC00000) | (va32 & 0x003FF000);
    }
    const pt = tablePtr(pde & ADDR_MASK);
    const pte = pt[(va32 >> 12) & 0x3FF];
    if ((pte & P) == 0) return null;
    return pte & ADDR_MASK;
}

fn leafFlags(prot: MapFlags) u32 {
    var e: u32 = P;
    if (prot.write) e |= RW;
    if (prot.user) e |= US;
    if (prot.device) e |= PCD;
    return e;
}

pub fn userTableMap(t: *PageTable, va: u64, pa: u64, prot: MapFlags) MapError!void {
    if (va > 0xFFFFFFFF or pa > 0xFFFFFFFF) return error.OutOfMemory;
    const va32: u32 = @intCast(va);
    const pa32: u32 = @intCast(pa);

    const pd = tablePtr(@intCast(t.root));
    const pd_i = va32 >> 22;
    const pt_i = (va32 >> 12) & 0x3FF;

    var pt: *[1024]u32 = undefined;
    if ((pd[pd_i] & P) != 0) {
        // Kernel-identity PSE slot below USER_VA_BASE. Callers shouldn't
        // be mapping into the kernel range. Reject so a stray user_map at
        // a low VA isn't silently swallowed.
        if ((pd[pd_i] & PS) != 0) return error.OutOfMemory;
        pt = tablePtr(pd[pd_i] & ADDR_MASK);
        pd[pd_i] |= US;
    } else {
        const new_phys64 = alloc_page() orelse return error.OutOfMemory;
        const new_phys: u32 = @intCast(new_phys64);
        pt = tablePtr(new_phys);
        @memset(@as([*]u8, @ptrCast(pt))[0..PAGE_SIZE], 0);
        pd[pd_i] = new_phys | P | RW | US;
    }
    pt[pt_i] = (pa32 & ADDR_MASK) | leafFlags(prot);
}

pub fn userTableUnmap(t: *PageTable, va: u64) void {
    if (va > 0xFFFFFFFF) return;
    const va32: u32 = @intCast(va);
    const pd = tablePtr(@intCast(t.root));
    const pd_i = va32 >> 22;
    if ((pd[pd_i] & P) == 0 or (pd[pd_i] & PS) != 0) return;
    const pt = tablePtr(pd[pd_i] & ADDR_MASK);
    pt[(va32 >> 12) & 0x3FF] = 0;
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (va32),
        : .{ .memory = true });
}

pub fn userTableLoad(t: *PageTable) void {
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (@as(u32, @intCast(t.root))),
        : .{ .memory = true });
}
