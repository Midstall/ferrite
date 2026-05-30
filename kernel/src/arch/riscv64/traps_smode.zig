const cpu = @import("cpu_smode.zig");
const uart = @import("uart_ns16550.zig");

pub const Frame = extern struct {
    x: [32]u64,
    sepc: u64,
    sstatus: u64,
};

pub const IrqHandler = *const fn (frame: *Frame) void;

pub const SyscallHandler = *const fn (num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) callconv(.c) isize;
pub var syscall_handler: ?SyscallHandler = null;

pub const FaultHandler = *const fn () noreturn;
pub var user_fault_handler: ?FaultHandler = null;
pub var sync_diag_hook: ?*const fn () void = null;
pub var preempt_hook: ?*const fn () void = null;

const MAX_IRQ: u32 = 64;
var irq_table: [MAX_IRQ]?IrqHandler = @splat(null);

extern fn s_trap_entry() callconv(.naked) void;

pub fn init() void {
    asm volatile ("csrw stvec, %[v]"
        :
        : [v] "r" (@intFromPtr(&s_trap_entry)),
    );
}

pub fn registerIrq(irq: u32, handler: ?IrqHandler) void {
    if (irq < MAX_IRQ) irq_table[irq] = handler;
}

const STI_CAUSE: u64 = 5;
const INTERRUPT_MASK: u64 = @as(u64, 1) << 63;
const CAUSE_ECALL_FROM_U: u64 = 8;

export fn dispatchTrap(frame: *Frame) callconv(.c) void {
    var cause: u64 = undefined;
    asm volatile ("csrr %[r], scause"
        : [r] "=r" (cause),
    );

    if ((cause & INTERRUPT_MASK) != 0) {
        const code = cause & 0xff;
        if (code < MAX_IRQ) {
            if (irq_table[@intCast(code)]) |h| h(frame);
        }
        return;
    }

    // RISC-V psABI: a7 (x17) = num, a0..a5 (x10..x15) = args, a0 = return.
    if (cause == CAUSE_ECALL_FROM_U) {
        const ret: isize = if (syscall_handler) |h|
            h(@intCast(frame.x[17]), @intCast(frame.x[10]), @intCast(frame.x[11]), @intCast(frame.x[12]), @intCast(frame.x[13]), @intCast(frame.x[14]), @intCast(frame.x[15]))
        else
            -1;
        frame.x[10] = @bitCast(@as(i64, ret));
        // ECALL doesn't auto-advance sepc.
        frame.sepc +%= 4;
        return;
    }

    var stval: u64 = undefined;
    asm volatile ("csrr %[r], stval"
        : [r] "=r" (stval),
    );

    uart.print(
        "\n[STRAP] scause=0x{x:0>16} sepc=0x{x:0>16} stval=0x{x:0>16}\n",
        .{ cause, frame.sepc, stval },
    );

    if (user_fault_handler) |h| h();
    cpu.halt();
}
