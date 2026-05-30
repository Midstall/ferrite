const std = @import("std");
const arch = @import("arch");
const aspace = @import("aspace.zig");
const cap = @import("cap.zig");
const cpu = @import("cpu.zig");
const heap = @import("heap.zig");
const ns = @import("ns.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");

const DEFAULT_CAP_CAPACITY: usize = 64;

/// System-class authority granted to a process at exec time.
pub const Authority = packed struct(u32) {
    /// May spawn child processes (Process.create + exec).
    spawn: bool = false,
    /// May claim hardware IRQs via arch.traps.registerIrq surface.
    irq_claim: bool = false,
    /// May map device-class memory (MMIO).
    mmio_map: bool = false,
    /// May write into the global namespace (ns.zig root).
    ns_global: bool = false,
    /// May create new channels (otherwise must receive them from parent).
    channel_create: bool = false,
    /// May serve the filesystem root.
    fs_root: bool = false,
    /// May open raw network sockets / drive a NIC.
    net_raw: bool = false,
    /// May register / revoke trust-anchor keys (signature.zig).
    sign_install: bool = false,
    /// May change its own process's uid (SYS_SETUID).
    setuid: bool = false,
    _pad: u23 = 0,

    pub const all: Authority = @bitCast(@as(u32, 0xFFFFFFFF));
    pub const none: Authority = .{};

    pub fn intersect(a: Authority, b: Authority) Authority {
        return @bitCast(@as(u32, @bitCast(a)) & @as(u32, @bitCast(b)));
    }
};

pub const NAME_MAX: usize = 16;
const MAX_PROCESSES: usize = 32;
/// Global process table. Slot 0 is the kernel/idle pseudo-process (never used).
var processes: [MAX_PROCESSES]?*Process = @splat(null);
var next_pid: u32 = 1;

pub fn list() []const ?*Process {
    return processes[0..];
}

pub fn byPid(pid: u32) ?*Process {
    for (processes) |entry| {
        if (entry) |p| if (p.pid == pid) return p;
    }
    return null;
}

// POSIX signal numbers. Default action = terminate; a process may install a
// catchable userspace handler via SYS_SIGACTION (except SIGKILL, uncatchable).
pub const SIGINT: u32 = 2;
pub const SIGKILL: u32 = 9;
pub const SIGTERM: u32 = 15;
/// Size of the per-process handler table + per-thread pending bitmask domain.
pub const NSIG: u32 = 32;

/// Deliver `sig` to every process in group `pgid`. Returns the number signalled.
pub fn signalGroup(pgid: u32, sig: u32) u32 {
    var n: u32 = 0;
    for (processes) |entry| {
        if (entry) |p| {
            if (p.pgid == pgid and !p.exited) {
                p.signal(sig);
                n += 1;
            }
        }
    }
    return n;
}

pub const Process = struct {
    aspace: *aspace.AddressSpace,
    cap_table: cap.Table,
    namespace: ns.Namespace,
    authority: Authority,
    threads: ?*thread.Thread,
    /// Latched once every thread has reached .zombie. Never un-sets.
    exited: bool = false,
    /// Exit status from SYS_EXIT (low 8 bits), read by SYS_WAIT.
    exit_code: i32 = 0,
    /// Caps are released at exit (not at destroy/wait) so a zombie's channels
    /// close promptly - pipe/redirect readers need EOF before the parent waits.
    caps_freed: bool = false,
    /// Threads blocked in SYS_WAIT on this process, linked via Thread.next.
    wait_list: ?*thread.Thread = null,
    /// Protects exited + wait_list. sysWait holds it across addWaiter +
    /// sched.blockReleasing so it can't race notifyThreadExit.
    wait_lock: sync.Spinlock = .{},
    pid: u32 = 0,
    uid: u32 = 0,
    /// Process group id (POSIX). Defaults to pid (process is its own group
    /// leader); a child inherits the parent's, and setpgid can move it. Ctrl-C
    /// and killpg target every process sharing a pgid.
    pgid: u32 = 0,
    /// Signal that terminated this process (0 = exited normally via SYS_EXIT).
    /// SYS_WAIT reports signal death as 128+term_signal.
    term_signal: u32 = 0,
    /// Catchable signal handlers (user VA; 0 = default action = terminate).
    /// Indexed by signal number. Set via SYS_SIGACTION.
    sig_handlers: [NSIG]u64 = @splat(0),
    /// User VA of the sigreturn trampoline (handler return address).
    sig_restorer: u64 = 0,
    /// Charged kernel-side bytes (channel buffers); small slab allocs aren't tracked.
    kmem_bytes: u64 = 0,
    name_buf: [NAME_MAX]u8 = @splat(0),
    name_len: u8 = 0,

    pub const Error = error{ OutOfMemory, ArchUnsupported };
    pub const CreateError = error{ OutOfMemory, ArchUnsupported, TableFull };

    pub fn create() CreateError!*Process {
        const a = heap.allocator();
        const p = a.create(Process) catch return error.OutOfMemory;
        errdefer a.destroy(p);

        const as = aspace.AddressSpace.create() catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ArchUnsupported,
        };
        errdefer as.destroy();

        const table = cap.Table.init(DEFAULT_CAP_CAPACITY) catch return error.OutOfMemory;

        var slot: ?usize = null;
        for (processes, 0..) |entry, i| {
            if (entry == null and i != 0) {
                slot = i;
                break;
            }
        }
        const idx = slot orelse return error.TableFull;

        p.* = .{
            .aspace = as,
            .cap_table = table,
            .namespace = ns.Namespace.init(),
            .authority = .{},
            .threads = null,
            .pid = next_pid,
            .pgid = next_pid, // own group leader until setpgid/inherit
        };
        next_pid += 1;
        processes[idx] = p;
        return p;
    }

    pub fn setName(self: *Process, name: []const u8) void {
        const n = @min(name.len, NAME_MAX);
        @memcpy(self.name_buf[0..n], name[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn nameSlice(self: *const Process) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn addWaiter(self: *Process, t: *thread.Thread) void {
        t.next = self.wait_list;
        self.wait_list = t;
    }

    pub fn notifyThreadExit(self: *Process) void {
        var t = self.threads;
        while (t) |th| : (t = th.next_in_process) {
            if (th.state != .zombie) return;
        }
        // Latch exited + drain wait_list under the same lock sysWait takes,
        // so a waiter that's between addWaiter and sched.block can't lose
        // its wake. Without this, the waiter sets state=blocked AFTER our
        // wake() set it to runnable, and stays blocked forever. Observed
        // on riscv64-limine as init never returning from selfTestPing.
        self.wait_lock.acquire();
        const first_exit = !self.exited;
        self.exited = true;
        if (first_exit) self.caps_freed = true; // claim the cap-release
        var w = self.wait_list;
        self.wait_list = null;
        self.wait_lock.release();
        while (w) |th| {
            const nxt = th.next;
            th.next = null;
            sched.wake(th);
            w = nxt;
        }
        // Release caps now (no spinlock held): this closes the process's
        // channels so blocked pipe/redirect peers get EOF without waiting for
        // the parent's reap. Must run exactly once, before destroy.
        if (first_exit) self.cap_table.deinit();
    }

    pub fn kill(self: *Process) void {
        var t = self.threads;
        while (t) |th| {
            const nxt = th.next_in_process;
            _ = sched.killOther(th);
            t = nxt;
        }
    }

    /// Deliver a signal. If the process installed a catchable handler for `sig`
    /// (and it isn't SIGKILL), mark it pending on each thread -- it's delivered to
    /// the handler at the thread's next EL0 trap return (timer IRQ / syscall).
    /// Otherwise the default action applies: record the terminating signal (for
    /// SYS_WAIT to report 128+sig) and kill. SIG 0 is a no-op existence probe.
    pub fn signal(self: *Process, sig: u32) void {
        if (sig == 0 or self.exited) return;
        if (sig != SIGKILL and sig < NSIG and self.sig_handlers[sig] != 0) {
            const bit = @as(u32, 1) << @intCast(sig);
            var t = self.threads;
            while (t) |th| : (t = th.next_in_process) {
                _ = @atomicRmw(u32, &th.pending_sig, .Or, bit, .release);
            }
            // A nanosleep-blocked thread must return to user to run the handler;
            // pull it off the sleeper list and make it runnable. (Channel-blocked
            // threads still defer until woken -- a known follow-up.)
            t = self.threads;
            while (t) |th| : (t = th.next_in_process) {
                if (th.state == .blocked and timer.removeSleeper(th)) {
                    th.deadline_ns = 0;
                    sched.wake(th);
                }
            }
            return;
        }
        if (self.term_signal == 0) self.term_signal = sig;
        self.kill();
    }

    /// Caller must guarantee no thread in this process is still running.
    pub fn destroy(self: *Process) void {
        var t = self.threads;
        while (t) |th| {
            const nxt = th.next_in_process;
            sched.remove(th);
            th.deinit();
            t = nxt;
        }
        self.threads = null;
        self.namespace.deinit();
        if (!self.caps_freed) self.cap_table.deinit(); // exit path may have freed already
        self.aspace.destroy();
        for (&processes) |*entry| {
            if (entry.*) |p| if (p == self) {
                entry.* = null;
                break;
            };
        }
        heap.allocator().destroy(self);
    }

    /// Caller must add the returned thread to the run queue.
    pub fn spawnThread(
        self: *Process,
        entry: *const fn () callconv(.c) noreturn,
    ) Error!*thread.Thread {
        const t = thread.Thread.init(entry) catch return error.OutOfMemory;
        t.process = @ptrCast(self);
        t.next_in_process = self.threads;
        self.threads = t;
        return t;
    }

    pub fn spawnUser(
        self: *Process,
        user_pc: u64,
        user_sp: u64,
    ) Error!*thread.Thread {
        const t = thread.Thread.init(&userBootstrap) catch return error.OutOfMemory;
        t.process = @ptrCast(self);
        t.next_in_process = self.threads;
        t.user_pc = user_pc;
        t.user_sp = user_sp;
        self.threads = t;
        return t;
    }
};

fn userBootstrap() callconv(.c) noreturn {
    const t = cpu.current() orelse @panic("userBootstrap: no current thread");
    const p = fromThread(t) orelse @panic("userBootstrap: thread has no process");
    p.aspace.switchTo();
    arch.usermode.enterUser(t.user_pc, t.user_sp);
}

/// Thread.process is anyopaque to break the thread<->process import cycle.
pub inline fn fromThread(t: *thread.Thread) ?*Process {
    return @ptrCast(@alignCast(t.process));
}

/// Null = kernel-only allocation, ignored.
pub fn chargeKmem(p: ?*Process, bytes: u64) void {
    const proc = p orelse return;
    kmemAdd(&proc.kmem_bytes, bytes);
}

pub fn refundKmem(p: ?*Process, bytes: u64) void {
    const proc = p orelse return;
    kmemSub(&proc.kmem_bytes, bytes);
}

// 32-bit targets lack u64 atomic ops; accounting is best-effort there.
const has_u64_atomics = @sizeOf(usize) >= 8;

inline fn kmemAdd(p: *u64, n: u64) void {
    if (has_u64_atomics) {
        _ = @atomicRmw(u64, p, .Add, n, .monotonic);
    } else {
        p.* +%= n;
    }
}
inline fn kmemSub(p: *u64, n: u64) void {
    if (has_u64_atomics) {
        _ = @atomicRmw(u64, p, .Sub, n, .monotonic);
    } else {
        p.* -%= n;
    }
}
inline fn kmemLoad(p: *const u64) u64 {
    if (has_u64_atomics) return @atomicLoad(u64, p, .monotonic);
    return p.*;
}

pub const Stats = struct {
    total_cpu_ns: u64,
    sys_cpu_ns: u64,
    rss_bytes: u64,
    kstack_bytes: u64,
    kmem_bytes: u64,
    num_threads: u32,
};

pub fn stats(p: *const Process) Stats {
    var s: Stats = .{
        .total_cpu_ns = 0,
        .sys_cpu_ns = 0,
        .rss_bytes = 0,
        .kstack_bytes = 0,
        .kmem_bytes = kmemLoad(&p.kmem_bytes),
        .num_threads = 0,
    };
    const kstack_per_thread: u64 = thread.Thread.kernelStackBytes();
    var t = p.threads;
    while (t) |th| : (t = th.next_in_process) {
        s.total_cpu_ns += th.total_cpu_ns;
        s.sys_cpu_ns += th.sys_cpu_ns;
        s.kstack_bytes += kstack_per_thread;
        s.num_threads += 1;
    }
    var r = p.aspace.regions;
    while (r) |reg| : (r = reg.next) {
        // Skip MMIO (owns_phys == false), since only RAM-backed counts toward RSS.
        if (reg.owns_phys) s.rss_bytes += reg.len;
    }
    return s;
}
