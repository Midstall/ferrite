// Kernel heap allocator: slab-style.
// Sizes > 1024 bytes fall through to the one-page large-alloc path.
// Anything > one page fails.

const std = @import("std");
const Alignment = std.mem.Alignment;
const memory = @import("memory.zig");
const sync = @import("sync.zig");

// PI-aware sleeping mutex (not spinlock) so a low-prio holder can't pin a high-prio waiter.
var heap_lock: sync.Mutex = .{};

inline fn pageSize() usize {
    return @intCast(memory.pageSize());
}
inline fn pageMask() usize {
    return pageSize() - 1;
}

const class_sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024 };
const NUM_CLASSES = class_sizes.len;
const MAX_CLASS_SIZE = class_sizes[NUM_CLASSES - 1];

/// Slab metadata at offset 0 of every slab page.
const SlabHeader = extern struct {
    class_idx: u8,
    _pad1: [3]u8,
    used: u32,
    /// 0 if the slab is fully used.
    free_head: usize,
    /// 0 if tail.
    next_partial: usize,
};

const HEADER_RESERVE: usize = 32;

comptime {
    std.debug.assert(@sizeOf(SlabHeader) <= HEADER_RESERVE);
}

var partial_slabs: [NUM_CLASSES]usize = @splat(0);

pub var stats: Stats = .{};
pub const Stats = struct {
    pages_to_slabs: usize = 0,
    pages_to_large: usize = 0,
};

pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = vtableAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = vtableFree,
};

fn vtableAlloc(_: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const align_bytes = alignment.toByteUnits();

    heap_lock.acquire();
    defer heap_lock.release();

    if (len > MAX_CLASS_SIZE or align_bytes > MAX_CLASS_SIZE) {
        const ps = pageSize();
        if (len > ps or align_bytes > ps) return null;
        const phys = memory.allocPage() orelse return null;
        stats.pages_to_large += 1;
        return @ptrFromInt(memory.physToVirt(phys));
    }

    var idx: usize = 0;
    while (idx < NUM_CLASSES) : (idx += 1) {
        const sz = class_sizes[idx];
        if (sz >= len and sz >= align_bytes) break;
    }
    if (idx >= NUM_CLASSES) return null;

    const va = slabAlloc(idx) orelse return null;
    return @ptrFromInt(va);
}

fn vtableFree(_: *anyopaque, slice: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const va = @intFromPtr(slice.ptr);

    heap_lock.acquire();
    defer heap_lock.release();

    if (slice.len > MAX_CLASS_SIZE) {
        memory.freePage(memory.virtToPhys(va));
        return;
    }

    slabFree(va);
}

fn slabAlloc(class_idx: usize) ?usize {
    var slab_va = partial_slabs[class_idx];
    if (slab_va == 0) {
        slab_va = newSlab(class_idx) orelse return null;
    }
    const header: *SlabHeader = @ptrFromInt(slab_va);

    const obj_va = header.free_head;
    std.debug.assert(obj_va != 0);
    const next_ptr: *usize = @ptrFromInt(obj_va);
    header.free_head = next_ptr.*;
    header.used += 1;

    if (header.free_head == 0) {
        partial_slabs[class_idx] = header.next_partial;
        header.next_partial = 0;
    }

    return obj_va;
}

fn slabFree(obj_va: usize) void {
    const slab_va = obj_va & ~pageMask();
    const header: *SlabHeader = @ptrFromInt(slab_va);
    const class_idx = header.class_idx;

    const was_full = header.free_head == 0;

    const obj_ptr: *usize = @ptrFromInt(obj_va);
    obj_ptr.* = header.free_head;
    header.free_head = obj_va;
    header.used -= 1;

    if (was_full) {
        header.next_partial = partial_slabs[class_idx];
        partial_slabs[class_idx] = slab_va;
    }
}

fn newSlab(class_idx: usize) ?usize {
    const phys = memory.allocPage() orelse return null;
    const slab_va = memory.physToVirt(phys);
    stats.pages_to_slabs += 1;

    const sz = class_sizes[class_idx];
    const first_obj_offset = if (sz > HEADER_RESERVE) sz else HEADER_RESERVE;

    var cur = slab_va + first_obj_offset;
    const slab_end = slab_va + pageSize();
    var head: usize = 0;
    var prev_free: usize = 0;
    while (cur + sz <= slab_end) : (cur += sz) {
        if (prev_free != 0) {
            const prev_ptr: *usize = @ptrFromInt(prev_free);
            prev_ptr.* = cur;
        } else {
            head = cur;
        }
        prev_free = cur;
    }
    if (prev_free != 0) {
        const prev_ptr: *usize = @ptrFromInt(prev_free);
        prev_ptr.* = 0;
    }

    const header: *SlabHeader = @ptrFromInt(slab_va);
    header.* = .{
        .class_idx = @intCast(class_idx),
        ._pad1 = .{ 0, 0, 0 },
        .used = 0,
        .free_head = head,
        .next_partial = partial_slabs[class_idx],
    };
    partial_slabs[class_idx] = slab_va;
    return slab_va;
}
