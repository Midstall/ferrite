// Priority-preemptive scheduler with EDF tiebreak within a class.

const std = @import("std");
const arch = @import("arch");
const cpu_mod = @import("cpu.zig");
const process = @import("process.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");

inline fn thisCpu() *cpu_mod.Cpu {
    return @ptrFromInt(arch.cpu.thisCpuPtr());
}

/// Cross-CPU work stealing. OFF: the context-switch race IS fixed (Thread.on_cpu
/// + context_switch_smp: publish with on_cpu=1, clear it the instant the SP is
/// saved, resumer waits for on_cpu==0 -> boot/parked paths are fault-free). But
/// actually RUNNING a stolen thread concurrently with the boot CPU still hits a
/// deeper SMP race: an EC=0 (illegal-execution) fault in a service's kernel path,
/// pointing at shared state that still assumes single-CPU (page-table edits, or
/// some per-CPU/global the syscall path touches unlocked). Re-enabling needs that
/// audited. Until then secondaries come online + park (validated). See #265.
pub var allow_steal: bool = false;

/// Runqueue lock is touched from IRQ context; plain spinlock would deadlock.
inline fn irqSave() bool {
    const prev = arch.cpu.irqsEnabled();
    arch.cpu.disableIrq();
    return prev;
}

inline fn irqRestore(prev: bool) void {
    if (prev) arch.cpu.enableIrq();
}

pub fn add(t: *thread.Thread) void {
    pushTo(thisCpu(), t);
}

pub fn wake(t: *thread.Thread) void {
    t.state = .runnable;
    if (arch.cpu.thisCpuPtr() == 0) return; // bootstrap window
    const cpu = thisCpu();
    pushTo(cpu, t);
    // Can't switch directly: caller may hold locks or be in IRQ. Defer to safe-point.
    if (cpu.current) |cur| {
        if (@intFromEnum(t.effective_priority) < @intFromEnum(cur.effective_priority)) {
            @atomicStore(u32, &cpu.needs_resched, 1, .release);
        }
    }
}

/// Direct handoff, L4-style.
pub fn switchTo(target: *thread.Thread) void {
    const cpu = thisCpu();
    const cur = cpu.current orelse return;
    if (target == cur) return;
    cur.state = .runnable;
    @atomicStore(u32, &cur.on_cpu, 1, .release); // stealable only after its regs are saved
    pushTo(cpu, cur);
    handoff(cpu, cur, target);
}

pub fn yield() void {
    const cpu = thisCpu();
    const cur = cpu.current orelse return;

    if (@atomicLoad(u32, &cur.die_requested, .acquire) != 0) {
        exit();
    }

    @atomicStore(u32, &cpu.needs_resched, 0, .release);

    const next = popHighest(cpu) orelse blk: {
        // Nothing local: an IDLE core pulls work from a busier one (SMP load
        // balancing). Only the idle thread steals -- a busy thread that yields
        // with an empty local queue just idles, so busy cores never reach into
        // another core's runqueue (keeps cross-CPU runqueue contention minimal).
        if (allow_steal and @intFromEnum(cur.effective_priority) == @intFromEnum(thread.Priority.idle)) {
            if (stealFromOthers(cpu)) |stolen| break :blk stolen;
        }
        // WFI lets qemu TCG service chardev/timers; pure spin starves PL011 RX.
        arch.cpu.idle();
        return;
    };
    if (next == cur) return;
    // Lower-prio next: requeue + WFI so we don't burn CPU on pure polling.
    if (@intFromEnum(next.effective_priority) > @intFromEnum(cur.effective_priority)) {
        pushTo(cpu, next);
        arch.cpu.idle();
        return;
    }
    cur.state = .runnable;
    @atomicStore(u32, &cur.on_cpu, 1, .release); // stealable only after its regs are saved
    pushTo(cpu, cur);
    handoff(cpu, cur, next);
}

/// Called from IRQ/syscall return; switches iff a higher-prio (or earlier-deadline) thread is queued.
pub fn maybePreempt() void {
    if (arch.cpu.thisCpuPtr() == 0) return;
    const cpu = thisCpu();
    if (@atomicLoad(u32, &cpu.needs_resched, .acquire) == 0) return;
    @atomicStore(u32, &cpu.needs_resched, 0, .release);

    const cur = cpu.current orelse return;
    if (!shouldPreempt(cpu, cur)) return;

    const next = popHighest(cpu) orelse return;
    if (next == cur) return;
    cur.state = .runnable;
    @atomicStore(u32, &cur.on_cpu, 1, .release); // stealable only after its regs are saved
    pushTo(cpu, cur);
    handoff(cpu, cur, next);
}

fn shouldPreempt(cpu: *cpu_mod.Cpu, cur: *thread.Thread) bool {
    const prev_irq = irqSave();
    defer irqRestore(prev_irq);
    cpu.runqueue_lock.acquire();
    defer cpu.runqueue_lock.release();

    if (cpu.runqueue_bitmap == 0) return false;
    const idx: usize = @ctz(cpu.runqueue_bitmap);
    if (idx > @intFromEnum(cur.effective_priority)) return false;
    if (idx < @intFromEnum(cur.effective_priority)) return true;

    // Equal class, EDF tiebreak.
    var t: ?*thread.Thread = cpu.runqueue_heads[idx];
    while (t) |x| : (t = x.next) {
        if (edfBeats(x, cur)) return true;
    }
    return false;
}

/// Caller must chain current onto its wait resource first.
pub fn block() void {
    const cpu = thisCpu();
    const cur = cpu.current orelse return;
    // cur is already chained on its wait resource (caller did that), so another
    // core can wake+run it; mark it on_cpu until handoff saves its registers.
    @atomicStore(u32, &cur.on_cpu, 1, .release);
    // The local idle/bootstrap thread is always queued as the fallback, so no
    // cross-CPU steal is needed here (and busy cores shouldn't steal anyway).
    const next = popHighest(cpu) orelse @panic("sched.block: nothing else to run, would deadlock");
    cur.state = .blocked;
    handoff(cpu, cur, next);
}

/// block() but releases guard after state=.blocked commits, before the switch.
/// Closes the wake-vs-not-yet-blocked race.
pub fn blockReleasing(guard: anytype) void {
    const cpu = thisCpu();
    const cur = cpu.current orelse {
        guard.release();
        return;
    };
    const next = popHighest(cpu) orelse @panic("sched.blockReleasing: nothing else to run, would deadlock");
    cur.state = .blocked;
    // Set on_cpu while the guard still serialises wake(): once released a remote
    // wake can push+run cur, which must wait for handoff to save its registers.
    @atomicStore(u32, &cur.on_cpu, 1, .release);
    guard.release();
    handoff(cpu, cur, next);
}

pub fn exit() noreturn {
    const cpu = thisCpu();
    const cur = cpu.current.?;
    cur.state = .zombie;
    // Final charge, since the handoff path won't run for this thread.
    const now_exit = arch.timer.now();
    if (cur.sched_in_ns != 0 and now_exit > cur.sched_in_ns) cur.total_cpu_ns += now_exit - cur.sched_in_ns;
    if (cur.sys_in_ns != 0 and now_exit > cur.sys_in_ns) cur.sys_cpu_ns += now_exit - cur.sys_in_ns;
    cur.sched_in_ns = 0;
    cur.sys_in_ns = 0;
    if (process.fromThread(cur)) |proc| proc.notifyThreadExit();
    const next = popHighest(cpu) orelse stealFromOthers(cpu) orelse @panic("sched.exit: no other runnable thread, system halted");
    next.sched_in_ns = arch.timer.now();
    if (next.sys_in_ns != 0) next.sys_in_ns = next.sched_in_ns;
    next.state = .running;
    cpu.current = next;
    // Same TSS-rsp0 + cpu.kernel_rsp update handoff() does on context switch.
    // Without this, a later U-mode IRQ in `next` pushes its iret frame onto
    // the dead thread's kernel stack. Manifests on UEFI as a triple-fault
    // reboot the moment any post-exit user-mode interrupt fires.
    if (next.stack_base != 0) {
        cpu.kernel_rsp = next.stack_base + thread.Thread.kernelStackBytes();
        if (@hasDecl(arch.thread, "setKernelStack")) {
            arch.thread.setKernelStack(cpu.kernel_rsp);
        }
    }
    if (process.fromThread(next)) |proc| {
        const prev_proc = process.fromThread(cur);
        if (prev_proc != proc) proc.aspace.switchTo();
    }
    var dead: usize = 0;
    // The zombie isn't on any runqueue (not stealable), so no on_cpu to clear;
    // still wait for next's regs to be saved before resuming it.
    archSwitch(&dead, &next.sp, null, &next.on_cpu);
    unreachable;
}

pub fn idleLoop() noreturn {
    // Bootstrap may not be wired (init failed before bringUpBoot); thisCpu is null.
    if (arch.cpu.thisCpuPtr() == 0) {
        while (true) arch.cpu.idle();
    }
    if (cpu_mod.current()) |t| {
        t.priority = .idle;
        t.effective_priority = .idle;
    }
    while (true) {
        yield();
        arch.cpu.idle();
    }
}

inline fn edfBeats(a: *const thread.Thread, b: *const thread.Thread) bool {
    if (a.deadline_ns == 0) return false;
    if (b.deadline_ns == 0) return true;
    return a.deadline_ns < b.deadline_ns;
}

fn pushTo(cpu: *cpu_mod.Cpu, t: *thread.Thread) void {
    t.next = null;
    const prev_irq = irqSave();
    defer irqRestore(prev_irq);
    cpu.runqueue_lock.acquire();
    defer cpu.runqueue_lock.release();
    const idx: usize = @intFromEnum(t.effective_priority);
    if (cpu.runqueue_tails[idx]) |last| {
        last.next = t;
        cpu.runqueue_tails[idx] = t;
    } else {
        cpu.runqueue_heads[idx] = t;
        cpu.runqueue_tails[idx] = t;
    }
    cpu.runqueue_bitmap |= @as(u8, 1) << @intCast(idx);
}

/// O(N) scan within the highest non-empty class for EDF.
fn popHighest(cpu: *cpu_mod.Cpu) ?*thread.Thread {
    const prev_irq = irqSave();
    defer irqRestore(prev_irq);
    cpu.runqueue_lock.acquire();
    defer cpu.runqueue_lock.release();

    if (cpu.runqueue_bitmap == 0) return null;
    const idx: usize = @ctz(cpu.runqueue_bitmap);

    var prev_best: ?*thread.Thread = null;
    var best: *thread.Thread = cpu.runqueue_heads[idx].?;
    var prev_cur: ?*thread.Thread = null;
    var cur: ?*thread.Thread = cpu.runqueue_heads[idx];
    while (cur) |t| {
        if (t.deadline_ns != 0 and (best.deadline_ns == 0 or t.deadline_ns < best.deadline_ns)) {
            best = t;
            prev_best = prev_cur;
        }
        prev_cur = t;
        cur = t.next;
    }

    if (prev_best) |p| {
        p.next = best.next;
    } else {
        cpu.runqueue_heads[idx] = best.next;
    }
    if (cpu.runqueue_tails[idx] == best) cpu.runqueue_tails[idx] = prev_best;
    if (cpu.runqueue_heads[idx] == null) cpu.runqueue_bitmap &= ~(@as(u8, 1) << @intCast(idx));
    best.next = null;
    return best;
}

/// Doesn't touch `t.state`.
pub fn remove(t: *thread.Thread) void {
    var i: u32 = 0;
    while (i < cpu_mod.num_cpus) : (i += 1) {
        if (removeFromRunqueue(&cpu_mod.cpus[i], t)) return;
    }
}

pub fn killOther(t: *thread.Thread) bool {
    @atomicStore(u32, &t.die_requested, 1, .release);
    if (t.state == .zombie) return false;

    var i: u32 = 0;
    while (i < cpu_mod.num_cpus) : (i += 1) {
        const c = &cpu_mod.cpus[i];
        if (removeFromRunqueue(c, t)) {
            t.state = .zombie;
            if (process.fromThread(t)) |proc| proc.notifyThreadExit();
            return true;
        }
    }
    // Not on any runqueue: it may be blocked in nanosleep. Pull it off the
    // sleeper list and reap it, so a signal (e.g. Ctrl-C on `sleep`) takes effect
    // immediately rather than after the sleep elapses. Other block sites (channel
    // recv) still defer until woken -- a known follow-up.
    if (timer.removeSleeper(t)) {
        t.state = .zombie;
        if (process.fromThread(t)) |proc| proc.notifyThreadExit();
        return true;
    }
    return false;
}

fn removeFromRunqueue(cpu: *cpu_mod.Cpu, target: *thread.Thread) bool {
    const prev_irq = irqSave();
    defer irqRestore(prev_irq);
    cpu.runqueue_lock.acquire();
    defer cpu.runqueue_lock.release();

    const idx: usize = @intFromEnum(target.effective_priority);
    var prev: ?*thread.Thread = null;
    var cur = cpu.runqueue_heads[idx];
    while (cur) |t| {
        if (t == target) {
            if (prev) |p| p.next = t.next else cpu.runqueue_heads[idx] = t.next;
            if (cpu.runqueue_tails[idx] == t) cpu.runqueue_tails[idx] = prev;
            if (cpu.runqueue_heads[idx] == null) cpu.runqueue_bitmap &= ~(@as(u8, 1) << @intCast(idx));
            t.next = null;
            return true;
        }
        prev = t;
        cur = t.next;
    }
    return false;
}

fn stealFromOthers(cpu: *cpu_mod.Cpu) ?*thread.Thread {
    // Gated globally: when off, CPUs never touch each other's runqueues, so a
    // parked secondary is fully isolated from the boot CPU.
    if (!allow_steal) return null;
    var i: u32 = 0;
    while (i < cpu_mod.num_cpus) : (i += 1) {
        if (i == cpu.id) continue;
        const victim = &cpu_mod.cpus[i];
        if (victim.online == 0) continue;
        if (popHighest(victim)) |t| {
            // Never migrate another core's idle/bootstrap thread: it's that core's
            // last-resort fallback and stealing it can leave the victim with
            // nothing to run (and risks idle<->idle steal cycles). Put it back.
            if (@intFromEnum(t.effective_priority) >= @intFromEnum(thread.Priority.idle)) {
                pushTo(victim, t);
                continue;
            }
            // The stolen thread may still be mid-switch-away on its old core; the
            // resume path (context_switch_smp) waits for on_cpu==0 before using
            // its SP, so no extra wait is needed here.
            return t;
        }
    }
    return null;
}

fn handoff(cpu: *cpu_mod.Cpu, cur: *thread.Thread, next: *thread.Thread) void {
    chargeAndArm(cur, next);

    cpu.context_switches +%= 1;
    next.state = .running;
    cpu.current = next;

    if (next.stack_base != 0) {
        cpu.kernel_rsp = next.stack_base + thread.Thread.kernelStackBytes();
        // x86: the TSS rsp0/esp0 holds the kernel SP the CPU loads on a
        // privilege change from U-mode (IRQs, exceptions). It must point at
        // the CURRENT thread's kernel stack. Without this update, a U-mode
        // IRQ in thread B uses thread A's kernel stack, corrupting whatever
        // saved state A had there. enterUser sets it once at first launch
        // but doesn't see subsequent context switches; do it here.
        if (@hasDecl(arch.thread, "setKernelStack")) {
            arch.thread.setKernelStack(cpu.kernel_rsp);
        }
    }

    if (process.fromThread(next)) |proc| {
        const prev_proc = process.fromThread(cur);
        if (prev_proc != proc) proc.aspace.switchTo();
    }

    // `cur` may already be published to a runqueue (yield/maybePreempt/switchTo
    // set cur.on_cpu=1 before pushTo); the SMP switch clears cur.on_cpu the
    // instant cur's SP is saved, then waits for next.on_cpu==0 before resuming.
    archSwitch(&cur.sp, &next.sp, &cur.on_cpu, &next.on_cpu);
}

/// SMP-safe context switch where available; plain switch on single-CPU arches.
/// `cur_on_cpu` may be null (prev not published to a runqueue, e.g. exit).
inline fn archSwitch(cur_sp: *usize, next_sp: *const usize, cur_on_cpu: ?*u32, next_on_cpu: *u32) void {
    if (@hasDecl(arch.thread, "contextSwitchSmp")) {
        arch.thread.contextSwitchSmp(cur_sp, next_sp, cur_on_cpu, next_on_cpu);
    } else {
        arch.thread.contextSwitch(cur_sp, next_sp);
    }
}

fn chargeAndArm(cur: *thread.Thread, next: *thread.Thread) void {
    // `now > x` guards: a preempt between now() and the read can leave x past now.
    const now = arch.timer.now();
    if (cur.sched_in_ns != 0 and now > cur.sched_in_ns) {
        cur.total_cpu_ns += now - cur.sched_in_ns;
    }
    if (cur.sys_in_ns != 0) {
        if (now > cur.sys_in_ns) cur.sys_cpu_ns += now - cur.sys_in_ns;
        // Re-arm for when this thread resumes mid-syscall.
        cur.sys_in_ns = now;
    }
    cur.sched_in_ns = 0;

    next.sched_in_ns = now;
    if (next.sys_in_ns != 0) next.sys_in_ns = now;
}

/// Sets both base and effective; discards any active PI boost.
pub fn setPriority(t: *thread.Thread, new_prio: thread.Priority) void {
    if (t.priority == new_prio and t.effective_priority == new_prio) return;
    if (t.state == .runnable) {
        remove(t);
        t.priority = new_prio;
        t.effective_priority = new_prio;
        pushTo(thisCpu(), t);
    } else {
        t.priority = new_prio;
        t.effective_priority = new_prio;
    }
    @atomicStore(u32, &thisCpu().needs_resched, 1, .release);
}

/// PI-only: updates effective priority without touching base.
pub fn setEffectivePriority(t: *thread.Thread, new_prio: thread.Priority) void {
    if (t.effective_priority == new_prio) return;
    if (t.state == .runnable) {
        remove(t);
        t.effective_priority = new_prio;
        pushTo(thisCpu(), t);
    } else {
        t.effective_priority = new_prio;
    }
    if (arch.cpu.thisCpuPtr() != 0) {
        @atomicStore(u32, &thisCpu().needs_resched, 1, .release);
    }
}

pub fn setDeadline(t: *thread.Thread, deadline_ns: u64) void {
    t.deadline_ns = deadline_ns;
    @atomicStore(u32, &thisCpu().needs_resched, 1, .release);
}
