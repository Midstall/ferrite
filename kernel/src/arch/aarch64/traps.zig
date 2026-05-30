const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const uart = @import("uart_pl011.zig");

/// Called from EL1-sync dump; lets kernel print "what was running" without an import cycle.
pub var sync_diag_hook: ?*const fn () void = null;

/// Called at IRQ/syscall exit; kernel wires this to sched.maybePreempt.
pub var preempt_hook: ?*const fn () void = null;

pub const Frame = extern struct {
    x: [31]u64,
    elr: u64,
    spsr: u64,
    /// SP_EL0 must be saved per-trap to survive context switches across EL0 threads.
    sp_el0: u64,
};

pub const IrqHandler = *const fn (frame: *Frame) void;

pub const SyscallHandler = *const fn (num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) callconv(.c) isize;
pub var syscall_handler: ?SyscallHandler = null;

pub const FaultHandler = *const fn () noreturn;
pub var user_fault_handler: ?FaultHandler = null;

// Catchable signal delivery.
// The kernel (process/thread state) can't be named from this arch module
// without an import cycle, so signal delivery is split: the kernel installs
// `take_signal_hook`, which (in the context of the current thread, at an EL0
// trap return) returns the next deliverable caught signal or sig=0 for none.
// traps.zig does the arch-specific frame surgery here.
pub const PendingSig = extern struct {
    sig: u32 = 0,
    _pad: u32 = 0,
    handler: u64 = 0,
    restorer: u64 = 0,
};
pub var take_signal_hook: ?*const fn () callconv(.c) PendingSig = null;

/// Must match syscall.SYS_SIGRETURN. sigreturn can't be a normal syscall (it
/// rewrites the whole frame, not just x0), so it's special-cased on entry.
const SYS_SIGRETURN: usize = 54;

/// Total bytes the vector SAVE_REGS pushes (GPR frame 0..0x10F + FP/NEON area).
/// Must match vectors.S `sub sp, sp, #800`. The signal sigframe copies all of
/// it so FP/NEON survives a handler too.
const FRAME_BYTES: usize = 800;

/// True if `frame` interrupted EL0 (SPSR_EL1.M[3:0] == 0 == EL0t).
inline fn fromEl0(frame: *const Frame) bool {
    return (frame.spsr & 0xf) == 0;
}

// If a caught signal is pending for the current thread, redirect this EL0 return
// into its handler: save the interrupted user context as a sigframe on the user
// stack, point ELR at the handler with x0=signum and LR=restorer (which calls
// SYS_SIGRETURN on handler return). Runs with the user's aspace active, so user
// VAs are directly writable.
fn maybeDeliverSignal(frame: *Frame) void {
    const h = take_signal_hook orelse return;
    const ps = h();
    if (ps.sig == 0) return;
    var sp = frame.sp_el0;
    sp -= FRAME_BYTES;
    sp &= ~@as(u64, 15);
    // Snapshot the FULL interrupted context (GPRs + FP/NEON) onto the user stack,
    // so a handler that uses FP/NEON can't corrupt the interrupted code.
    const src: [*]const u8 = @ptrCast(frame);
    const dst: [*]u8 = @ptrFromInt(sp);
    @memcpy(dst[0..FRAME_BYTES], src[0..FRAME_BYTES]);
    frame.sp_el0 = sp;
    frame.elr = ps.handler;
    frame.x[0] = ps.sig;
    frame.x[30] = ps.restorer; // handler `ret` -> restorer -> SYS_SIGRETURN
}

const MAX_IRQ: u32 = 256;
var irq_table: [MAX_IRQ]?IrqHandler = @splat(null);

extern const vector_table_start: u8;

pub fn init() void {
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (&vector_table_start),
    );
    asm volatile ("isb");
    gic.init();
}

// Per-CPU trap setup for a secondary: the vector base (VBAR_EL1) is per-CPU, and
// gic.initCpu brings up this CPU's interface/redistributor (NOT the global
// distributor, which the boot CPU already enabled).
pub fn initCpu(cpu_index: u32) void {
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (&vector_table_start),
    );
    asm volatile ("isb");
    gic.initCpu(cpu_index);
}

pub fn registerIrq(irq: u32, handler: ?IrqHandler) void {
    if (irq < MAX_IRQ) irq_table[irq] = handler;
}

export fn dispatchSync(frame: *Frame) callconv(.c) void {
    var esr: u64 = undefined;
    var far: u64 = undefined;
    asm volatile ("mrs %[r], esr_el1"
        : [r] "=r" (esr),
    );
    asm volatile ("mrs %[r], far_el1"
        : [r] "=r" (far),
    );
    const ec = (esr >> 26) & 0x3f;

    uart.print(
        "\n[SYNC] EC=0x{x} ESR=0x{x:0>16} FAR=0x{x:0>16} ELR=0x{x:0>16}\n",
        .{ ec, esr, far, frame.elr },
    );
    uart.print("[SYNC] x30(LR)=0x{x:0>16} sp_el0=0x{x:0>16}\n", .{
        frame.x[30], frame.sp_el0,
    });
    if (sync_diag_hook) |h| h();

    cpu.halt();
}

export fn dispatchIrq(frame: *Frame) callconv(.c) void {
    const iar = gic.acknowledge();
    const irq = iar & 0x3ff;

    if (irq < MAX_IRQ) {
        if (irq_table[irq]) |h| h(frame);
    }

    gic.endOfInterrupt(iar);

    if (preempt_hook) |h| h();

    // Deliver a pending caught signal on return to a user (EL0) context.
    if (fromEl0(frame)) maybeDeliverSignal(frame);
}

export fn dispatchFiq(_: *Frame) callconv(.c) void {
    uart.write("\n[FIQ] unexpected\n");
    cpu.halt();
}

export fn dispatchSError(_: *Frame) callconv(.c) void {
    uart.write("\n[SERROR] unexpected\n");
    cpu.halt();
}

export fn dispatchUnknown(_: *Frame) callconv(.c) void {
    uart.write("\n[TRAP] unknown vector\n");
    cpu.halt();
}

/// EC=0x15 is SVC; everything else is a fault.
/// Do not advance ELR_EL1; CPU already set it to the instruction after SVC.
export fn dispatchSyncEl0(frame: *Frame) callconv(.c) void {
    var esr: u64 = undefined;
    asm volatile ("mrs %[r], esr_el1"
        : [r] "=r" (esr),
    );
    const ec = (esr >> 26) & 0x3f;

    if (ec == 0x15) {
        // sigreturn: restore the sigframe the delivery path saved on the user
        // stack (sp_el0 points at it) into this frame, so eret resumes the
        // interrupted code. Must not run the generic handler or touch x0.
        if (frame.x[8] == SYS_SIGRETURN) {
            // Restore the full sigframe (GPRs + FP/NEON) saved by the delivery
            // path; sp_el0 currently points at it.
            const src: [*]const u8 = @ptrFromInt(frame.sp_el0);
            const dst: [*]u8 = @ptrCast(frame);
            @memcpy(dst[0..FRAME_BYTES], src[0..FRAME_BYTES]);
            if (preempt_hook) |h| h();
            maybeDeliverSignal(frame); // another signal may be queued
            return;
        }
        const ret: isize = if (syscall_handler) |h|
            h(frame.x[8], frame.x[0], frame.x[1], frame.x[2], frame.x[3], frame.x[4], frame.x[5])
        else
            -1;
        frame.x[0] = @bitCast(@as(i64, ret));
        if (preempt_hook) |h| h();
        maybeDeliverSignal(frame); // deliver caught signals at syscall return
        return;
    }

    var far: u64 = undefined;
    asm volatile ("mrs %[r], far_el1"
        : [r] "=r" (far),
    );
    uart.print(
        "\n[EL0 SYNC] EC=0x{x} ESR=0x{x:0>16} FAR=0x{x:0>16} ELR=0x{x:0>16}\n",
        .{ ec, esr, far, frame.elr },
    );
    if (user_fault_handler) |h| h();
    cpu.halt();
}
