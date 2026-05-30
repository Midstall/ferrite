// x86_64 SYSCALL stub reads `scratch_user_rsp` at %gs:0 and `kernel_rsp` at %gs:8.

const std = @import("std");
const arch = @import("arch");
const sync = @import("sync.zig");
const thread = @import("thread.zig");

pub const MAX_CPUS: usize = 32;

pub const Cpu = extern struct {
    /// Offset 0, load-bearing for x86_64 SYSCALL stub.
    scratch_user_rsp: u64 = 0,
    /// Offset 8, load-bearing for x86_64 SYSCALL stub.
    kernel_rsp: u64 = 0,

    id: u32 = 0,
    _pad_id: u32 = 0,

    current: ?*thread.Thread = null,

    /// Per-priority FIFO; index = priority (lower = higher priority).
    runqueue_heads: [thread.NUM_PRIORITIES]?*thread.Thread = @splat(null),
    runqueue_tails: [thread.NUM_PRIORITIES]?*thread.Thread = @splat(null),
    /// Bit i set iff queue[i] is non-empty; @ctz picks highest priority.
    runqueue_bitmap: u8 = 0,
    _pad_bm: [3]u8 = @splat(0),
    /// Also held by remote CPUs while stealing from this queue.
    runqueue_lock: sync.Spinlock = .{},

    /// Request reschedule at next safe point (end of IRQ / syscall).
    needs_resched: u32 = 0,

    online: u32 = 0,

    bootstrap: ?*thread.Thread = null,

    /// Number of context switches this CPU has performed (observability/SMP).
    context_switches: u64 = 0,
};

pub var cpus: [MAX_CPUS]Cpu = blk: {
    var arr: [MAX_CPUS]Cpu = undefined;
    var i: usize = 0;
    while (i < MAX_CPUS) : (i += 1) {
        arr[i] = .{ .id = @intCast(i) };
    }
    break :blk arr;
};

/// Boot CPU is always index 0.
pub var num_cpus: u32 = 0;

/// Idempotent. cpus[] is comptime-initialized with the right field values
/// already; the runtime reinit was just defensive. Skipped here because
/// the implicit struct-literal store wedges silently on Limine x86_64 BIOS
/// (LLVM lowers to a wide store that the Limine-mapped .data leaf
/// somehow can't satisfy even with WRITABLE=1 and CR0.WP=0).
pub fn init(count: u32) void {
    if (num_cpus != 0) return;
    const n = if (count == 0) 1 else @min(count, @as(u32, MAX_CPUS));
    num_cpus = n;
}

pub inline fn thisCpu() *Cpu {
    return @ptrFromInt(arch.cpu.thisCpuPtr());
}

pub inline fn current() ?*thread.Thread {
    return thisCpu().current;
}

pub fn bringUpBoot(t: *thread.Thread) void {
    if (num_cpus == 0) init(1);
    const c = &cpus[0];
    c.current = t;
    c.bootstrap = t;
    c.online = 1;
    arch.cpu.setThisCpu(c);
}
