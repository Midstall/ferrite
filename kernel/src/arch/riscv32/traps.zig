const uart = @import("board/esp32c6/uart.zig");
const systimer = @import("board/esp32c6/systimer.zig");
const thread = @import("thread.zig");
const pmp = @import("board/esp32c6/pmp.zig");

pub const Frame = extern struct {
    x: [32]u32,
    mepc: u32,
    mstatus: u32,
    mcause: u32,
    mtval: u32,
};

extern fn _vector_table() void;

pub fn init() void {
    const base = @intFromPtr(&_vector_table);
    asm volatile ("csrw mtvec, %[v]"
        :
        : [v] "r" (base | 0x1),
    );
}

const CAUSE_ECALL_U: u32 = 8;
const CAUSE_ECALL_M: u32 = 11;
var tick_count: u32 = 0;

pub const FaultHandler = *const fn () void;
pub const SyscallHandler = *const fn (num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) callconv(.c) isize;
pub var user_fault_handler: ?FaultHandler = null;
pub var sync_diag_hook: ?*const fn () void = null;
pub var preempt_hook: ?*const fn () void = null;
pub var syscall_handler: ?SyscallHandler = null;

pub const IrqHandler = *const fn (frame: *Frame) void;
const MAX_IRQ: u32 = 64;
pub var irq_table: [MAX_IRQ]?IrqHandler = .{null} ** MAX_IRQ;
pub fn registerIrq(irq: u32, handler: ?IrqHandler) void {
    if (irq < MAX_IRQ) irq_table[irq] = handler;
}

inline fn loadAspaceIfAny(t: *thread.Thread) void {
    if (t.aspace) |a| pmp.loadAspace(a);
}

/// Returns the Frame to restore from on `mret`. Same pointer = no switch;
/// different pointer = thread switch.
export fn dispatchTrap(frame: *Frame) callconv(.c) *Frame {
    const is_irq = (frame.mcause >> 31) != 0;
    const code = frame.mcause & 0x7FFF_FFFF;

    if (is_irq) {
        const irq = systimer.plicClaim();
        if (irq == systimer.CPU_IRQ_SYSTIMER) {
            systimer.ack();
            tick_count +%= 1;

            thread.currentThread().saved_sp = @intCast(@intFromPtr(frame));
            const next = thread.nextThread();
            loadAspaceIfAny(next);
            systimer.plicComplete(irq);
            return @ptrFromInt(next.saved_sp);
        }
        uart.print("[IRQ] unexpected claim={d} mcause_lo={d}\n", .{ irq, code });
        systimer.plicComplete(irq);
        return frame;
    }

    if (code == CAUSE_ECALL_M) {
        // Kick the scheduler. Interrupt machinery is configured here (not
        // in zigStart) so the main boot stack never has IRQs enabled -
        // a timer fired in kmain would trash the pre-built thread frame
        // at threads[N].saved_sp.
        systimer.init(systimer.TICKS_PER_SECOND * 2);
        asm volatile ("csrw mie, %[v]"
            :
            : [v] "r" (@as(u32, 0xFFFF_FFFF)),
        );
        thread.current = 0;
        const t = thread.currentThread();
        loadAspaceIfAny(t);
        return @ptrFromInt(t.saved_sp);
    }

    if (code == CAUSE_ECALL_U) {
        // riscv user-syscall ABI: a7 = num, a0..a5 = args, a0 = ret.
        const num: usize = frame.x[17];
        const a0: usize = frame.x[10];
        const a1: usize = frame.x[11];
        const a2: usize = frame.x[12];
        const a3: usize = frame.x[13];
        const a4: usize = frame.x[14];
        const a5: usize = frame.x[15];
        const ret: isize = if (syscall_handler) |h|
            h(num, a0, a1, a2, a3, a4, a5)
        else
            -1;
        frame.x[10] = @bitCast(ret);
        frame.mepc +%= 4;
        return frame;
    }

    uart.print("\n[TRAP] mcause={d} mepc=0x{x} mtval=0x{x}\n", .{ code, frame.mepc, frame.mtval });
    while (true) asm volatile ("wfi");
}
