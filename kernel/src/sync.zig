const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const cpu_mod = @import("cpu.zig");
const sched = @import("sched.zig");
const thread = @import("thread.zig");

/// No PI; for IRQ-disabled critical sections. Otherwise use Mutex.
pub const Spinlock = extern struct {
    state: u32 = 0,

    pub fn acquire(self: *Spinlock) void {
        while (true) {
            if (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;
            while (@atomicLoad(u32, &self.state, .monotonic) != 0) std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *Spinlock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }
};

/// Sleeping PI mutex. Not for IRQ context. Use Spinlock there.
pub const Mutex = struct {
    holder: ?*thread.Thread = null,
    /// Reuses thread.next; blocked threads aren't on any runqueue.
    waiters: ?*thread.Thread = null,
    guard: Spinlock = .{},

    inline fn irqSave() bool {
        const prev = arch.cpu.irqsEnabled();
        arch.cpu.disableIrq();
        return prev;
    }

    inline fn irqRestore(prev: bool) void {
        if (prev) arch.cpu.enableIrq();
    }

    pub fn acquire(self: *Mutex) void {
        // Pre-per-CPU world is single-threaded; no-op (heap is used to allocate the first Thread).
        if (arch.cpu.thisCpuPtr() == 0) return;
        const cur = cpu_mod.current() orelse return;

        const prev_irq = irqSave();
        self.guard.acquire();

        if (self.holder == null) {
            self.holder = cur;
            self.guard.release();
            irqRestore(prev_irq);
            return;
        }

        // Contended: boost holder, block; release() hands the lock to us directly (no reacquire loop).
        const holder = self.holder.?;
        if (@intFromEnum(cur.effective_priority) < @intFromEnum(holder.effective_priority)) {
            sched.setEffectivePriority(holder, cur.effective_priority);
        }

        cur.next = self.waiters;
        self.waiters = cur;

        // Atomic guard release + state=.blocked vs a remote release()/wake().
        sched.blockReleasing(&self.guard);
        irqRestore(prev_irq);

        std.debug.assert(self.holder == cur);
    }

    pub fn release(self: *Mutex) void {
        if (arch.cpu.thisCpuPtr() == 0) return;

        const prev_irq = irqSave();
        defer irqRestore(prev_irq);

        self.guard.acquire();

        const me = cpu_mod.current() orelse {
            self.guard.release();
            return;
        };
        std.debug.assert(self.holder == me);

        // Drop boost; no per-lock stack, so other PI mutexes will re-boost on their next acquire.
        if (me.effective_priority != me.priority) {
            sched.setEffectivePriority(me, me.priority);
        }

        if (self.waiters == null) {
            self.holder = null;
            self.guard.release();
            return;
        }

        var prev_best: ?*thread.Thread = null;
        var best: *thread.Thread = self.waiters.?;
        var prev_cur: ?*thread.Thread = null;
        var cur: ?*thread.Thread = self.waiters;
        while (cur) |w| {
            if (@intFromEnum(w.effective_priority) < @intFromEnum(best.effective_priority)) {
                best = w;
                prev_best = prev_cur;
            }
            prev_cur = w;
            cur = w.next;
        }

        if (prev_best) |p| p.next = best.next else self.waiters = best.next;
        best.next = null;

        // Direct handoff: waker only needs to runqueue `best`.
        self.holder = best;

        // Inherit from any remaining higher-prio waiter.
        var w = self.waiters;
        while (w) |x| : (w = x.next) {
            if (@intFromEnum(x.effective_priority) < @intFromEnum(best.effective_priority)) {
                sched.setEffectivePriority(best, x.effective_priority);
            }
        }

        self.guard.release();
        sched.wake(best);
    }
};
