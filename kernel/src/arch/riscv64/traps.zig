const cpu = @import("riscv").cpu;
const uart = @import("uart_ns16550.zig");

// Layout must match trap_entry.S exactly.
pub const Frame = extern struct {
    x: [32]u64,
    mepc: u64,
    mstatus: u64,
    mcause: u64,
    mtval: u64,
};

pub const IrqHandler = *const fn (frame: *Frame) void;

pub const SyscallHandler = *const fn (num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) callconv(.c) isize;
pub var syscall_handler: ?SyscallHandler = null;

pub const FaultHandler = *const fn () noreturn;
pub var user_fault_handler: ?FaultHandler = null;
pub var sync_diag_hook: ?*const fn () void = null;
pub var preempt_hook: ?*const fn () void = null;

const MAX_IRQ: u32 = 32;
var irq_table: [MAX_IRQ]?IrqHandler = @splat(null);

extern fn trap_entry() void;

pub fn init() void {
    asm volatile ("csrw mtvec, %[v]"
        :
        : [v] "r" (@intFromPtr(&trap_entry)),
    );
}

pub fn registerIrq(irq: u32, handler: ?IrqHandler) void {
    if (irq < MAX_IRQ) irq_table[irq] = handler;
}

const CAUSE_ECALL_FROM_U: u64 = 8;

export fn dispatchTrap(frame: *Frame) callconv(.c) void {
    const mcause = frame.mcause;
    const is_interrupt = (mcause >> 63) != 0;
    const code: u32 = @intCast(mcause & 0xff);

    if (is_interrupt) {
        if (code < MAX_IRQ) {
            if (irq_table[code]) |h| h(frame);
        }
        return;
    }

    if (mcause == CAUSE_ECALL_FROM_U) {
        const ret: isize = if (syscall_handler) |h|
            h(@intCast(frame.x[17]), @intCast(frame.x[10]), @intCast(frame.x[11]), @intCast(frame.x[12]), @intCast(frame.x[13]), @intCast(frame.x[14]), @intCast(frame.x[15]))
        else
            -1;
        frame.x[10] = @bitCast(@as(i64, ret));
        frame.mepc +%= 4;
        return;
    }

    uart.print(
        "\n[TRAP] mcause=0x{x:0>16} mepc=0x{x:0>16} mtval=0x{x:0>16}\n",
        .{ mcause, frame.mepc, frame.mtval },
    );
    if (user_fault_handler) |h| h();
    cpu.halt();
}
