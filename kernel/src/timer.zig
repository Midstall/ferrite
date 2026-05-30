// arch.timer.now() is assumed coherent across cores (true on aarch64; x86 TSC
// would need per-CPU offsets here).

const std = @import("std");
const arch = @import("arch");
const cpu_mod = @import("cpu.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");

/// Mono-ns at init(); reference for uptime.
pub var boot_mono_ns: u64 = 0;

/// Sorted earliest-first, linked through Thread.sleep_next (NOT `next`): a thread
/// is on this list during the window between enqueue and `sched.block`, where it
/// can still be runqueue-linked via `next`. Sharing one field corrupts both.
var sleepers_head: ?*thread.Thread = null;
var sleepers_lock: sync.Spinlock = .{};

pub fn init() void {
    if (boot_mono_ns == 0) boot_mono_ns = arch.timer.now();
}

/// Raw arch monotonic counter; use uptimeNs for "since kernel boot".
pub inline fn nowNs() u64 {
    return arch.timer.now();
}

pub inline fn uptimeNs() u64 {
    const n = arch.timer.now();
    return if (n > boot_mono_ns) n - boot_mono_ns else 0;
}

/// Granularity = tick period (10 ms).
pub fn nanosleep(ns: u64) void {
    const cur = cpu_mod.current() orelse return;
    const deadline = arch.timer.now() + ns;

    cur.deadline_ns = deadline;

    {
        const prev = irqSave();
        defer irqRestore(prev);
        sleepers_lock.acquire();
        defer sleepers_lock.release();

        var prev_node: ?*thread.Thread = null;
        var node = sleepers_head;
        while (node) |n| {
            if (n.deadline_ns > deadline) break;
            prev_node = n;
            node = n.sleep_next;
        }
        cur.sleep_next = node;
        if (prev_node) |p| p.sleep_next = cur else sleepers_head = cur;
    }

    sched.block();

    // Stale deadline would bias EDF; reset.
    cur.deadline_ns = 0;
}

/// Unlink `t` from the sleeper list (it's blocked in nanosleep). Returns true if
/// it was found. Used by the kill path so a signal can reap a sleeping thread
/// instead of waiting out its nanosleep. Linked through Thread.sleep_next.
pub fn removeSleeper(t: *thread.Thread) bool {
    const prev = irqSave();
    defer irqRestore(prev);
    sleepers_lock.acquire();
    defer sleepers_lock.release();
    var prev_node: ?*thread.Thread = null;
    var node = sleepers_head;
    while (node) |n| {
        if (n == t) {
            if (prev_node) |p| p.sleep_next = n.sleep_next else sleepers_head = n.sleep_next;
            t.sleep_next = null;
            return true;
        }
        prev_node = n;
        node = n.sleep_next;
    }
    return false;
}

pub fn tick() void {
    // Only the boot CPU drains the global sleepers list. A secondary draining it
    // would sched.wake() the sleeper onto its OWN runqueue (wake targets the
    // current CPU), pulling work onto a core that may not run it and racing.
    // Secondary timer ticks still drive preemption (needs_resched) via schedTick.
    if (cpu_mod.thisCpu().id != 0) return;

    const now_ns = arch.timer.now();

    const prev = irqSave();
    defer irqRestore(prev);
    sleepers_lock.acquire();

    // Wake outside the lock, since sched.wake takes runqueue_lock. The transient
    // to_wake list stays on sleep_next; sched.wake then runqueue-links via `next`.
    var to_wake: ?*thread.Thread = null;
    while (sleepers_head) |head| {
        if (head.deadline_ns > now_ns) break;
        sleepers_head = head.sleep_next;
        head.sleep_next = to_wake;
        to_wake = head;
    }
    sleepers_lock.release();

    while (to_wake) |t| {
        const next = t.sleep_next;
        t.sleep_next = null;
        sched.wake(t);
        to_wake = next;
    }
}

inline fn irqSave() bool {
    const enabled = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return enabled;
}

inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}
