// Physical page allocator. alloc_lock is a leaf spinlock, since heap.zig's
// sleeping Mutex holds it during calls in, so this cannot be a Mutex itself.

const kernel_options = @import("kernel-options");
const arch = @import("arch");
const sync = @import("sync.zig");

var page_size: u64 = kernel_options.page_size;

pub inline fn pageSize() u64 {
    return page_size;
}

pub inline fn pageMask() u64 {
    return page_size - 1;
}

/// Must be called before any allocPage/allocPages.
pub fn setPageSize(n: u64) void {
    page_size = n;
}

pub const RegionKind = enum { usable, reclaimable, reserved };

pub const Region = extern struct {
    phys: u64,
    len: u64,
    kind_raw: u8,

    pub fn kind(self: Region) RegionKind {
        return @enumFromInt(self.kind_raw);
    }
};

pub const MAX_REGIONS: usize = 64;

const Range = struct {
    start: u64,
    end: u64,
};

var regions_buf: [MAX_REGIONS]Region = undefined;
var regions_count: usize = 0;
var ranges_buf: [MAX_REGIONS]Range = undefined;
var ranges_count: usize = 0;
/// 0 is the empty-list sentinel (PA 0 is unusable on every supported arch).
var free_head: u64 = 0;
var hhdm_offset: u64 = 0;
var inited: bool = false;

pub fn register(phys: u64, len: u64, kind: RegionKind) void {
    if (regions_count >= MAX_REGIONS) return;
    regions_buf[regions_count] = .{
        .phys = phys,
        .len = len,
        .kind_raw = @intFromEnum(kind),
    };
    regions_count += 1;
}

pub fn regions() []const Region {
    return regions_buf[0..regions_count];
}

pub const MemInfo = extern struct {
    total_bytes: u64,
    free_bytes: u64,
};

pub fn meminfo() MemInfo {
    var total: u64 = 0;
    for (regions()) |r| {
        if (r.kind() == .usable) total += r.len;
    }

    const g = LockGuard.enter();
    defer g.release();
    var free_bytes: u64 = 0;
    var head = free_head;
    const ps = pageSize();
    while (head != 0) : (free_bytes += ps) head = readNextPtr(head);
    for (ranges_buf[0..ranges_count]) |r| {
        if (r.end > r.start) free_bytes += r.end - r.start;
    }

    return .{ .total_bytes = total, .free_bytes = free_bytes };
}

/// Idempotent.
pub fn init(hhdm: u64) void {
    if (inited) return;
    inited = true;
    hhdm_offset = hhdm;
    ranges_count = 0;
    const mask = pageMask();
    for (regions()) |r| {
        if (r.kind() != .usable) continue;
        var start = (r.phys + mask) & ~mask;
        const end = (r.phys + r.len) & ~mask;
        // PA 0 is the free-list empty sentinel.
        if (start == 0) start = pageSize();
        if (end <= start) continue;
        addUsableCarved(start, end);
    }
}

const MAX_SEGS_PER_REGION: usize = 16;

fn addUsableCarved(start: u64, end: u64) void {
    var segs: [MAX_SEGS_PER_REGION]Range = undefined;
    var count: usize = 1;
    segs[0] = .{ .start = start, .end = end };

    const mask = pageMask();
    for (regions()) |r| {
        if (r.kind() != .reserved) continue;
        const rs = r.phys & ~mask;
        const re = (r.phys + r.len + mask) & ~mask;

        var i: usize = 0;
        var new_count: usize = 0;
        var new_segs: [MAX_SEGS_PER_REGION]Range = undefined;
        while (i < count) : (i += 1) {
            const s = segs[i];
            if (rs >= s.end or re <= s.start) {
                if (new_count < MAX_SEGS_PER_REGION) {
                    new_segs[new_count] = s;
                    new_count += 1;
                }
                continue;
            }
            if (rs > s.start and new_count < MAX_SEGS_PER_REGION) {
                new_segs[new_count] = .{ .start = s.start, .end = rs };
                new_count += 1;
            }
            if (re < s.end and new_count < MAX_SEGS_PER_REGION) {
                new_segs[new_count] = .{ .start = re, .end = s.end };
                new_count += 1;
            }
        }
        count = new_count;
        for (0..count) |k| segs[k] = new_segs[k];
        if (count == 0) return;
    }

    for (segs[0..count]) |s| {
        if (s.end <= s.start) continue;
        if (ranges_count >= MAX_REGIONS) return;
        ranges_buf[ranges_count] = s;
        ranges_count += 1;
    }
}

var alloc_trace_enabled: bool = false;
pub fn enableAllocTrace(on: bool) void {
    alloc_trace_enabled = on;
}

var alloc_lock: sync.Spinlock = .{};

inline fn irqSave() bool {
    const prev = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return prev;
}

inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}

const LockGuard = struct {
    prev_irq: bool,

    fn enter() LockGuard {
        const prev = irqSave();
        alloc_lock.acquire();
        return .{ .prev_irq = prev };
    }

    fn release(self: LockGuard) void {
        alloc_lock.release();
        irqRestore(self.prev_irq);
    }
};

/// Lives at offset 0 of every freed multi-page run; without this, freed runs
/// never come back and the contiguous allocator bleeds dry.
const MultiRunHeader = extern struct {
    next_phys: u64,
    npages: u64,
};

/// Sentinel for "no next" (pa=0 isn't a valid page anyway).
var multi_free_head: u64 = 0;

/// No contiguous run can plausibly exceed this (1 TiB at 4K pages). A larger
/// npages in a free-list header means the run was corrupted after freeing.
const MAX_RUN_PAGES: u64 = 1 << 28;

inline fn readMultiHeader(phys: u64) MultiRunHeader {
    const ptr: *const MultiRunHeader = @ptrFromInt(physToVirt(phys));
    return ptr.*;
}

inline fn writeMultiHeader(phys: u64, h: MultiRunHeader) void {
    const ptr: *MultiRunHeader = @ptrFromInt(physToVirt(phys));
    ptr.* = h;
}

pub fn allocPage() ?u64 {
    const g = LockGuard.enter();
    defer g.release();
    if (free_head != 0) {
        const head = free_head;
        free_head = readNextPtr(head);
        if (alloc_trace_enabled) {
            arch.uart.print("[a] 0x{x} (fl)\n", .{head});
        }
        return head;
    }
    for (ranges_buf[0..ranges_count]) |*r| {
        if (r.start < r.end) {
            const p = r.start;
            r.start += pageSize();
            if (alloc_trace_enabled) {
                arch.uart.print("[a] 0x{x}\n", .{p});
            }
            return p;
        }
    }
    return null;
}

/// Tries the freed-runs list first (exact-fit or split), then carves from
/// the unallocated ranges.
pub fn allocPages(n: usize) ?u64 {
    if (n == 0) return null;
    const ps = pageSize();
    const g = LockGuard.enter();
    defer g.release();

    var prev_phys: u64 = 0;
    var cur_phys = multi_free_head;
    while (cur_phys != 0) {
        const h = readMultiHeader(cur_phys);
        // A run still on the free list whose header got clobbered (use-after-
        // free, double-free) would make the split math below overflow. Catch
        // an implausible header, report it, and bail rather than fault.
        if (h.npages == 0 or h.npages > MAX_RUN_PAGES or (h.next_phys & (ps - 1)) != 0) {
            arch.uart.print("[mem] corrupt free run @0x{x}: next=0x{x} npages=0x{x} (req n={d})\n", .{ cur_phys, h.next_phys, h.npages, n });
            break;
        }
        if (h.npages == n) {
            if (prev_phys == 0) {
                multi_free_head = h.next_phys;
            } else {
                const ph = readMultiHeader(prev_phys);
                writeMultiHeader(prev_phys, .{ .next_phys = h.next_phys, .npages = ph.npages });
            }
            // Wipe header so the returned page looks freshly-allocated.
            writeMultiHeader(cur_phys, .{ .next_phys = 0, .npages = 0 });
            if (alloc_trace_enabled) {
                arch.uart.print("[an] 0x{x}*{d} (rfl)\n", .{ cur_phys, n });
            }
            return cur_phys;
        }
        if (h.npages > n) {
            // Hand out the tail; remainder keeps the header at its head.
            const take_phys = cur_phys + (h.npages - n) * ps;
            writeMultiHeader(cur_phys, .{ .next_phys = h.next_phys, .npages = h.npages - n });
            if (alloc_trace_enabled) {
                arch.uart.print("[an] 0x{x}*{d} (split)\n", .{ take_phys, n });
            }
            return take_phys;
        }
        prev_phys = cur_phys;
        cur_phys = h.next_phys;
    }

    const need: u64 = @as(u64, n) * ps;
    for (ranges_buf[0..ranges_count]) |*r| {
        if (r.end - r.start >= need) {
            const p = r.start;
            r.start += need;
            if (alloc_trace_enabled) {
                arch.uart.print("[an] 0x{x}*{d}\n", .{ p, n });
            }
            return p;
        }
    }
    return null;
}

/// Must have come from allocPage. Not validated.
pub fn freePage(phys: u64) void {
    const g = LockGuard.enter();
    defer g.release();
    if (alloc_trace_enabled) {
        arch.uart.print("[f] 0x{x}\n", .{phys});
    }
    writeNextPtr(phys, free_head);
    free_head = phys;
}

/// Push the run onto multi_free so a later allocPages of matching size can
/// reuse it. n==1 falls through to the per-page free list.
pub fn freePages(phys: u64, n: usize) void {
    if (n == 0) return;
    if (n == 1) return freePage(phys);
    const g = LockGuard.enter();
    defer g.release();
    writeMultiHeader(phys, .{ .next_phys = multi_free_head, .npages = @intCast(n) });
    multi_free_head = phys;
    if (alloc_trace_enabled) {
        arch.uart.print("[fn] 0x{x}*{d}\n", .{ phys, n });
    }
}

inline fn readNextPtr(phys: u64) u64 {
    const ptr: *const u64 = @ptrFromInt(physToVirt(phys));
    return ptr.*;
}

inline fn writeNextPtr(phys: u64, val: u64) void {
    const ptr: *u64 = @ptrFromInt(physToVirt(phys));
    ptr.* = val;
}

pub inline fn physToVirt(phys: u64) usize {
    return @intCast(phys + hhdm_offset);
}

/// Non-inline variant whose address can be taken as a plain `*const fn`.
/// Used by the VMM facility (vmm.zig / arch hyp.zig) to reach guest page-table
/// pages, since those aren't identity-mapped on a higher-half kernel.
pub fn physToVirtFn(phys: u64) usize {
    return physToVirt(phys);
}

/// Only valid for addresses obtained via `physToVirt`.
pub inline fn virtToPhys(virt: usize) u64 {
    return @as(u64, virt) - hhdm_offset;
}

pub fn freeBytes() u64 {
    const g = LockGuard.enter();
    defer g.release();
    var total: u64 = 0;
    for (ranges_buf[0..ranges_count]) |r| total += r.end - r.start;
    var node = free_head;
    const ps = pageSize();
    while (node != 0) : (node = readNextPtr(node)) total += ps;
    return total;
}
