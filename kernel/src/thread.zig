const std = @import("std");
const arch = @import("arch");
const heap = @import("heap.zig");
const memory = @import("memory.zig");

pub const State = enum(u8) {
    running,
    runnable,
    blocked,
    zombie,
};

/// 8 levels; 0 = highest (RT).
pub const Priority = enum(u8) {
    rt_high = 0,
    rt_mid = 1,
    rt_low = 2,
    high = 3,
    normal = 4,
    low = 5,
    background = 6,
    idle = 7,
};
pub const NUM_PRIORITIES: usize = 8;
pub const DEFAULT_PRIORITY: Priority = .normal;

pub const Thread = struct {
    sp: usize,
    state: State,
    stack_base: usize,
    /// Scheduler runqueue link ONLY. Must never be aliased with a wait queue:
    /// a thread on an IPC wait queue (see `wait_next`) can be runqueue-linked
    /// or double-woken under load, and sharing one field corrupts both lists
    /// (manifests as a kernel return to a garbage address). See ipc.zig.
    next: ?*Thread,
    /// IPC channel wait-queue link, distinct from the scheduler's `next`.
    wait_next: ?*Thread,
    /// nanosleep sleeper-list link, distinct from the scheduler's `next` for the
    /// same reason as `wait_next`: a sleeping thread can be runqueue-linked in the
    /// window between enqueue and `sched.block`. See timer.zig.
    sleep_next: ?*Thread,
    /// Null for kernel-only threads.
    process: ?*anyopaque,
    /// Per-process linked list, distinct from scheduler's `next`.
    next_in_process: ?*Thread,
    /// Used only on the first descent into userspace.
    user_pc: u64,
    /// Used only on the first descent into userspace.
    user_sp: u64,
    /// Cross-CPU kill request; honoured at target's next yield.
    die_requested: u32,
    /// Base priority requested by user/driver.
    priority: Priority,
    /// Scheduler-visible; PI may transiently raise this above `priority`.
    effective_priority: Priority,
    /// Absolute deadline (mono ns); 0 = no deadline.
    deadline_ns: u64,
    total_cpu_ns: u64,
    /// Subset of total spent in syscall handlers.
    sys_cpu_ns: u64,
    /// Last sched-in timestamp; 0 when not running.
    sched_in_ns: u64,
    /// Last syscall-entry timestamp; 0 when not in a syscall.
    sys_in_ns: u64,
    /// SMP: 1 while this thread is being switched away from but its registers
    /// aren't saved yet. A thread is published to the runqueue (stealable) before
    /// `context_switch` saves its SP; a stealing core must wait for on_cpu==0
    /// before running it, or it runs on a stale/shared stack. Cleared inside
    /// `context_switch_smp` the instant the SP is saved (handles new threads,
    /// which never return into handoff). See sched.zig.
    on_cpu: u32 = 0,
    /// Pending caught signals (bit i = signal i). Delivered to the process's
    /// handler at this thread's next EL0 trap return. See process.signal.
    pending_sig: u32 = 0,

    pub const Error = error{OutOfMemory};

    /// Sized for worst-case syscall depth + 16 KB inline IPC frame.
    pub const KERNEL_STACK_PAGES: usize = 32;

    pub fn kernelStackBytes() usize {
        return KERNEL_STACK_PAGES * @as(usize, @intCast(memory.pageSize()));
    }

    pub fn init(entry: *const fn () callconv(.c) noreturn) Error!*Thread {
        const allocator = heap.allocator();
        const t = try allocator.create(Thread);
        errdefer allocator.destroy(t);

        const stack_phys = memory.allocPages(KERNEL_STACK_PAGES) orelse return error.OutOfMemory;
        const stack_base = memory.physToVirt(stack_phys);

        t.* = .{
            .sp = arch.thread.initStack(stack_base + kernelStackBytes(), @intFromPtr(entry)),
            .state = .runnable,
            .stack_base = stack_base,
            .next = null,
            .wait_next = null,
            .sleep_next = null,
            .process = null,
            .next_in_process = null,
            .user_pc = 0,
            .user_sp = 0,
            .die_requested = 0,
            .priority = DEFAULT_PRIORITY,
            .effective_priority = DEFAULT_PRIORITY,
            .deadline_ns = 0,
            .total_cpu_ns = 0,
            .sys_cpu_ns = 0,
            .sched_in_ns = 0,
            .sys_in_ns = 0,
        };
        return t;
    }

    /// Wraps the boot stub's stack as thread 0; sp/stack_base zero until first switch.
    pub fn initBootstrap() Error!*Thread {
        const allocator = heap.allocator();
        const t = try allocator.create(Thread);
        t.* = .{
            .sp = 0,
            .state = .running,
            .stack_base = 0,
            .next = null,
            .wait_next = null,
            .sleep_next = null,
            .process = null,
            .next_in_process = null,
            .user_pc = 0,
            .user_sp = 0,
            .die_requested = 0,
            .priority = DEFAULT_PRIORITY,
            .effective_priority = DEFAULT_PRIORITY,
            .deadline_ns = 0,
            .total_cpu_ns = 0,
            .sys_cpu_ns = 0,
            .sched_in_ns = 0,
            .sys_in_ns = 0,
        };
        return t;
    }

    pub fn deinit(self: *Thread) void {
        if (self.stack_base != 0) {
            const stack_phys = memory.virtToPhys(self.stack_base);
            memory.freePages(stack_phys, KERNEL_STACK_PAGES);
        }
        heap.allocator().destroy(self);
    }
};
