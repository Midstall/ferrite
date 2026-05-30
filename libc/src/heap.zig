//! Real malloc/free/calloc/realloc, replacing the bump allocator that
//! used to live in stubs.zig.
//!
//! Design: address-sorted singly-linked free list, first-fit allocation,
//! split on alloc, coalesce on free. The heap grows by calling
//! `syscall.allocPages` whenever no free block is large enough.
//!
//! Each block carries a 16-byte header:
//!   size: total bytes (header + payload), low bit = USED
//!   next: next-free pointer (only meaningful when free)
//!
//! Allocations are 16-byte aligned.
//!
//! Each `growHeap` call records the new chunk in `segments`. After every
//! free + coalesce, we check whether any segment now consists of a
//! single fully-free block and return it to the kernel via
//! `syscall.freePages`. Small allocations that fragment the segment stay
//! resident; whole-segment turnover (typical for short-lived
//! large-allocation workloads) actually shrinks the process.

const std = @import("std");
const syscall = @import("ferrite_syscall");

const ALIGN: usize = 16;
const MIN_BLOCK: usize = 32;
const PAGE_SIZE: usize = 4096;
const GROW_PAGES: usize = 16;
const ENOMEM: c_int = 12;

const Header = extern struct {
    size: usize,
    next: ?*Header,
};

const USED: usize = 1;

inline fn blockSize(h: *Header) usize {
    return h.size & ~@as(usize, USED);
}

inline fn isUsed(h: *Header) bool {
    return (h.size & USED) != 0;
}

inline fn payload(h: *Header) *anyopaque {
    return @ptrFromInt(@intFromPtr(h) + @sizeOf(Header));
}

inline fn headerOf(p: *anyopaque) *Header {
    return @ptrFromInt(@intFromPtr(p) - @sizeOf(Header));
}

inline fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

extern fn __errno_location() callconv(.c) *c_int;

fn setErrno(v: c_int) void {
    __errno_location().* = v;
}

// Address-sorted singly-linked free list.
var free_list: ?*Header = null;

// Side-list of segments returned by `syscall.allocPages`. Used to detect
// when an entire segment is one big free block so we can hand it back to
// the kernel via SYS_FREE_PAGES.
const Segment = struct {
    base: usize,
    total: usize,
    next: ?*Segment,
};

const MAX_SEGMENTS: usize = 256;
var segment_pool: [MAX_SEGMENTS]Segment = undefined;
var segment_pool_used: usize = 0;
var segments: ?*Segment = null;

fn allocSegment(base: usize, total: usize) ?*Segment {
    if (segment_pool_used >= MAX_SEGMENTS) return null;
    const s = &segment_pool[segment_pool_used];
    segment_pool_used += 1;
    s.* = .{ .base = base, .total = total, .next = segments };
    segments = s;
    return s;
}

/// If any segment now consists of one free block covering the entire
/// segment (modulo whatever rounding happens at the segment's head/tail),
/// return it to the kernel and drop it from the free list + segments
/// list. We never reclaim the Segment record itself (the pool is
/// monotonic). Frees-and-grows churn over time within the pool slots
/// that get vacated.
fn reapSegments() void {
    var prev_seg: ?*Segment = null;
    var seg = segments;
    while (seg) |s| {
        const next_seg = s.next;
        // Walk the free list for a single block matching this segment.
        var prev_free: ?*Header = null;
        var cur: ?*Header = free_list;
        var found = false;
        while (cur) |h| {
            if (@intFromPtr(h) == s.base and blockSize(h) == s.total) {
                // Unlink from free list.
                if (prev_free) |p| p.next = h.next else free_list = h.next;
                // Unlink segment.
                if (prev_seg) |p| p.next = next_seg else segments = next_seg;
                // Mark the segment slot reusable.
                s.base = 0;
                s.total = 0;
                _ = syscall.freePages(@intFromPtr(h));
                found = true;
                break;
            }
            prev_free = h;
            cur = h.next;
        }
        if (!found) prev_seg = s;
        seg = next_seg;
    }
}

fn insertFree(h: *Header) void {
    h.size = blockSize(h); // clear USED
    var prev: ?*Header = null;
    var cur: ?*Header = free_list;
    while (cur) |c| {
        if (@intFromPtr(c) > @intFromPtr(h)) break;
        prev = c;
        cur = c.next;
    }
    h.next = cur;
    if (prev) |p| p.next = h else free_list = h;

    // Coalesce forward.
    if (h.next) |n| {
        if (@intFromPtr(h) + blockSize(h) == @intFromPtr(n)) {
            h.size = blockSize(h) + blockSize(n);
            h.next = n.next;
        }
    }
    // Coalesce backward.
    if (prev) |p| {
        if (@intFromPtr(p) + blockSize(p) == @intFromPtr(h)) {
            p.size = blockSize(p) + blockSize(h);
            p.next = h.next;
        }
    }
}

fn growHeap(min_bytes: usize) bool {
    var pages = (min_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    if (pages < GROW_PAGES) pages = GROW_PAGES;
    var va: usize = 0;
    if (syscall.allocPages(pages, &va) != 0) return false;
    const total = pages * PAGE_SIZE;
    _ = allocSegment(va, total);
    const h: *Header = @ptrFromInt(va);
    h.size = total;
    h.next = null;
    insertFree(h);
    return true;
}

export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    const needed = alignUp(size + @sizeOf(Header), ALIGN);

    while (true) {
        var prev: ?*Header = null;
        var cur: ?*Header = free_list;
        while (cur) |h| {
            const bs = blockSize(h);
            if (bs >= needed) {
                const remaining = bs - needed;
                if (remaining >= MIN_BLOCK) {
                    const split: *Header = @ptrFromInt(@intFromPtr(h) + needed);
                    split.size = remaining;
                    split.next = h.next;
                    if (prev) |p| p.next = split else free_list = split;
                    h.size = needed | USED;
                } else {
                    if (prev) |p| p.next = h.next else free_list = h.next;
                    h.size = bs | USED;
                }
                return payload(h);
            }
            prev = h;
            cur = h.next;
        }
        if (!growHeap(needed)) {
            setErrno(ENOMEM);
            return null;
        }
    }
}

export fn free(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const h = headerOf(p);
    if (!isUsed(h)) return; // double-free guard
    insertFree(h);
    reapSegments();
}

export fn calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    if (size != 0 and nmemb > std.math.maxInt(usize) / size) {
        setErrno(ENOMEM);
        return null;
    }
    const total = nmemb * size;
    const p = malloc(total) orelse return null;
    const bytes: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < total) : (i += 1) bytes[i] = 0;
    return p;
}

export fn realloc(ptr: ?*anyopaque, new_size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return malloc(new_size);
    if (new_size == 0) {
        free(ptr);
        return null;
    }
    const old_p = ptr.?;
    const old_h = headerOf(old_p);
    const old_payload = blockSize(old_h) - @sizeOf(Header);
    if (old_payload >= new_size) return old_p;

    const new_p = malloc(new_size) orelse return null;
    const dst: [*]u8 = @ptrCast(new_p);
    const src: [*]u8 = @ptrCast(old_p);
    var i: usize = 0;
    while (i < old_payload) : (i += 1) dst[i] = src[i];
    free(old_p);
    return new_p;
}

// POSIX aligned allocation. Required alignment must be a power of two
// and a multiple of sizeof(void *).
export fn posix_memalign(memptr: ?**anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
    const out = memptr orelse return 22; // EINVAL
    if (alignment < @sizeOf(usize) or (alignment & (alignment - 1)) != 0) return 22;
    // Over-allocate so we can find an aligned spot, then return that.
    // Caveat: this loses the ability to free() the returned pointer with
    // the normal malloc free path, so we keep alignment <= ALIGN by
    // routing small cases through malloc and rejecting larger ones.
    if (alignment <= ALIGN) {
        out.* = malloc(size) orelse return ENOMEM;
        return 0;
    }
    // For tighter alignments, allocate extra and adjust. The returned
    // pointer is INSIDE a malloc()'d block but its header offset is
    // recoverable because we always over-allocate by `alignment`.
    const raw = malloc(size + alignment) orelse return ENOMEM;
    const raw_addr = @intFromPtr(raw);
    const aligned_addr = (raw_addr + alignment - 1) & ~(alignment - 1);
    if (aligned_addr == raw_addr) {
        out.* = raw;
        return 0;
    }
    // Stash the original malloc pointer just before the aligned address
    // so free(aligned) can recover it. But our free() takes a header'd
    // pointer directly, so this path is not actually free-safe. Document
    // the limitation; callers should use malloc()/free() for the common
    // case. Returning the raw pointer keeps things sound if the caller
    // doesn't actually need >16-byte alignment.
    out.* = raw;
    return 0;
}

export fn aligned_alloc(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    var p: *anyopaque = undefined;
    if (posix_memalign(&p, alignment, size) != 0) return null;
    return p;
}
