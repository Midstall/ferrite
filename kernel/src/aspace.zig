const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const heap = @import("heap.zig");
const memory = @import("memory.zig");

pub const Prot = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
    user: bool = false,
    /// Non-cacheable, strongly ordered.
    device: bool = false,
};

pub const Error = error{ OutOfMemory, BadAlignment, ArchUnsupported };

pub const USER_VA_BASE: u64 = switch (builtin.cpu.arch) {
    // x86 kernel identity-maps 0..N via PSE 4 MB pages and shares that
    // mapping with every user PT (otherwise context_switch can't reach
    // the kernel stack after CR3 swap). Park user above the kernel
    // identity window - 1 GB is well past anything QEMU's PC ever
    // populates.
    .x86 => 0x4000_0000,
    // Sv39 sign-extends bit 38; addresses >= 2^39 land in the kernel half.
    // Keep user-half base well below 2^38 (256 GB) to stay user-side.
    .riscv64 => 0x10_0000_0000,
    // No MMU; VA == PA. PMP handles per-process isolation, so this is
    // just an allocation hint inside the IRAM-allocatable range that
    // happens to fit in u32 (the other branches' values overflow).
    .riscv32 => 0x4082_0000,
    else => 0x80_0000_0000,
};

pub const USER_STACK_TOP: u64 = switch (builtin.cpu.arch) {
    .x86 => 0xC000_0000,
    .riscv64 => 0x0000_0030_0000_0000,
    .riscv32 => 0x4087_F000, // near end of c6 IRAM
    else => 0x0000_0200_0000_0000,
};

// Must sit above USER_VA_BASE (or the first allocPages remaps over the
// loaded binary) and below USER_STACK_TOP.
pub const USER_MMAP_BASE: u64 = switch (builtin.cpu.arch) {
    .x86 => 0x8000_0000,
    .riscv64 => 0x0000_0020_0000_0000,
    .riscv32 => 0x4084_0000,
    else => 0x0000_0090_0000_0000,
};

pub const MemRegion = struct {
    phys: u64,
    len: u64,
    /// MMIO regions get Device-class attributes; normal RAM doesn't.
    device: bool,
};

pub const AddressSpace = struct {
    table: arch.mmu.PageTable,
    regions: ?*Region,
    /// Grows up from USER_MMAP_BASE.
    mmap_next: u64,

    pub const Region = struct {
        va: u64,
        len: u64,
        /// True if the backing physical pages must be returned on destroy.
        owns_phys: bool,
        next: ?*Region,
    };

    pub fn create() Error!*AddressSpace {
        const a = heap.allocator().create(AddressSpace) catch return error.OutOfMemory;
        errdefer heap.allocator().destroy(a);
        a.* = .{
            .table = arch.mmu.userTableCreate() catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return error.ArchUnsupported;
            },
            .regions = null,
            .mmap_next = USER_MMAP_BASE,
        };
        return a;
    }

    pub fn destroy(self: *AddressSpace) void {
        var r = self.regions;
        while (r) |reg| {
            self.unmapRegion(reg);
            const next = reg.next;
            heap.allocator().destroy(reg);
            r = next;
        }
        arch.mmu.userTableDestroy(&self.table);
        heap.allocator().destroy(self);
    }

    fn unmapRegion(self: *AddressSpace, reg: *Region) void {
        const page_size = memory.pageSize();
        var off: u64 = 0;
        while (off < reg.len) : (off += page_size) {
            const va = reg.va + off;
            if (reg.owns_phys) {
                if (arch.mmu.userTableTranslate(&self.table, va)) |pa| {
                    memory.freePage(pa);
                }
            }
            arch.mmu.userTableUnmap(&self.table, va);
        }
    }

    /// Both must be page-aligned; virt must be at or above USER_VA_BASE.
    pub fn map(self: *AddressSpace, virt: u64, len: u64, prot: Prot) Error!void {
        const page_size = memory.pageSize();
        if ((virt & (page_size - 1)) != 0 or (len & (page_size - 1)) != 0) {
            return error.BadAlignment;
        }
        if (virt < USER_VA_BASE) return error.BadAlignment;

        const flags = arch.mmu.MapFlags{
            .read = prot.read,
            .write = prot.write,
            .execute = prot.execute,
            .user = prot.user,
            .device = prot.device,
        };

        var off: u64 = 0;
        while (off < len) : (off += page_size) {
            const pa = memory.allocPage() orelse return error.OutOfMemory;
            arch.mmu.userTableMap(&self.table, virt + off, pa, flags) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return error.ArchUnsupported;
            };
        }

        const reg = heap.allocator().create(Region) catch return error.OutOfMemory;
        reg.* = .{ .va = virt, .len = len, .owns_phys = true, .next = self.regions };
        self.regions = reg;
    }

    /// Only call for regions produced by `map`, not `mmap`.
    pub fn unmap(self: *AddressSpace, virt: u64, len: u64) void {
        const page_size = memory.pageSize();
        var off: u64 = 0;
        while (off < len) : (off += page_size) {
            const va = virt + off;
            if (arch.mmu.userTableTranslate(&self.table, va)) |pa| {
                memory.freePage(pa);
            }
            arch.mmu.userTableUnmap(&self.table, va);
        }
    }

    /// Free a region previously returned by mmap / dmaAlloc (i.e. tracked
    /// in `self.regions`). The va MUST match a region's base; partial
    /// unmaps aren't supported yet. Returns BadAlignment when no such
    /// region is found.
    pub fn freeRegion(self: *AddressSpace, virt: u64) Error!void {
        var prev: ?*Region = null;
        var r = self.regions;
        while (r) |reg| {
            if (reg.va == virt) {
                self.unmapRegion(reg);
                if (prev) |p| p.next = reg.next else self.regions = reg.next;
                heap.allocator().destroy(reg);
                return;
            }
            prev = reg;
            r = reg.next;
        }
        return error.BadAlignment;
    }

    pub fn mmap(self: *AddressSpace, region: *const MemRegion, prot: Prot) Error!u64 {
        const page_size = memory.pageSize();
        if ((region.phys & (page_size - 1)) != 0 or (region.len & (page_size - 1)) != 0) {
            return error.BadAlignment;
        }
        if (region.len == 0) return error.BadAlignment;

        const aligned_next = std.mem.alignForward(u64, self.mmap_next, page_size);
        const va = aligned_next;
        const end = va + region.len;
        // Headroom for an 8-page stack plus a guard.
        const stack_guard: u64 = 64 * 1024;
        if (end + stack_guard > USER_STACK_TOP) return error.OutOfMemory;
        self.mmap_next = end;

        var p = prot;
        p.user = true;
        p.device = region.device;
        const flags = arch.mmu.MapFlags{
            .read = p.read,
            .write = p.write,
            .execute = p.execute,
            .user = p.user,
            .device = p.device,
        };

        var off: u64 = 0;
        while (off < region.len) : (off += page_size) {
            arch.mmu.userTableMap(&self.table, va + off, region.phys + off, flags) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return error.ArchUnsupported;
            };
        }

        const reg = heap.allocator().create(Region) catch return error.OutOfMemory;
        reg.* = .{ .va = va, .len = region.len, .owns_phys = false, .next = self.regions };
        self.regions = reg;
        return va;
    }

    /// Allocates `npages` physically-contiguous pages so device DMA addressed
    /// at `pa + i*PAGE_SIZE` lines up with CPU access at `va + i*PAGE_SIZE`.
    pub fn dmaAlloc(self: *AddressSpace, npages: u32) Error!struct { va: u64, pa: u64 } {
        if (npages == 0) return error.BadAlignment;
        const page_size = memory.pageSize();

        const aligned_next = std.mem.alignForward(u64, self.mmap_next, page_size);
        const va = aligned_next;
        const total_len = page_size * npages;
        const end = va + total_len;
        const stack_guard: u64 = 64 * 1024;
        if (end + stack_guard > USER_STACK_TOP) return error.OutOfMemory;

        const flags = arch.mmu.MapFlags{
            .read = true,
            .write = true,
            .execute = false,
            .user = true,
            .device = false,
        };

        const first_pa = memory.allocPages(npages) orelse return error.OutOfMemory;
        const kva: [*]u8 = @ptrFromInt(memory.physToVirt(first_pa));
        @memset(kva[0..@intCast(total_len)], 0);

        var i: u32 = 0;
        while (i < npages) : (i += 1) {
            arch.mmu.userTableMap(&self.table, va + @as(u64, i) * page_size, first_pa + @as(u64, i) * page_size, flags) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return error.ArchUnsupported;
            };
        }
        self.mmap_next = end;

        const reg = heap.allocator().create(Region) catch return error.OutOfMemory;
        reg.* = .{ .va = va, .len = total_len, .owns_phys = true, .next = self.regions };
        self.regions = reg;

        return .{ .va = va, .pa = first_pa };
    }

    pub fn switchTo(self: *AddressSpace) void {
        arch.mmu.userTableLoad(&self.table);
    }
};
