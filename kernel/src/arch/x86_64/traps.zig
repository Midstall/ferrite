const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const lapic = @import("lapic.zig");
const pic = @import("pic.zig");
const uart = @import("x86").uart;

pub const Frame = extern struct {
    _placeholder: u64 = 0,
};

pub const IrqHandler = *const fn (frame: *Frame) void;

pub const SyscallHandler = *const fn (num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) callconv(.c) isize;
pub var syscall_handler: ?SyscallHandler = null;

pub const FaultHandler = *const fn () noreturn;
pub var user_fault_handler: ?FaultHandler = null;
pub var sync_diag_hook: ?*const fn () void = null;
pub var preempt_hook: ?*const fn () void = null;

const MAX_IRQ: u32 = 256;
var irq_table: [MAX_IRQ]?IrqHandler = @splat(null);

extern fn isr_timer() callconv(.c) void;
extern fn isr_panic_default() callconv(.c) void;
extern fn isr_panic_0() callconv(.c) void;
extern fn isr_panic_1() callconv(.c) void;
extern fn isr_panic_2() callconv(.c) void;
extern fn isr_panic_3() callconv(.c) void;
extern fn isr_panic_4() callconv(.c) void;
extern fn isr_panic_5() callconv(.c) void;
extern fn isr_panic_6() callconv(.c) void;
extern fn isr_panic_7() callconv(.c) void;
extern fn isr_panic_8() callconv(.c) void;
extern fn isr_panic_9() callconv(.c) void;
extern fn isr_panic_10() callconv(.c) void;
extern fn isr_panic_11() callconv(.c) void;
extern fn isr_panic_12() callconv(.c) void;
extern fn isr_panic_13() callconv(.c) void;
extern fn isr_panic_14() callconv(.c) void;
extern fn isr_panic_15() callconv(.c) void;
extern fn isr_panic_16() callconv(.c) void;
extern fn isr_panic_17() callconv(.c) void;
extern fn isr_panic_18() callconv(.c) void;
extern fn isr_panic_19() callconv(.c) void;
extern fn isr_panic_20() callconv(.c) void;
extern fn isr_panic_21() callconv(.c) void;
extern fn isr_panic_22() callconv(.c) void;
extern fn isr_panic_23() callconv(.c) void;
extern fn isr_panic_24() callconv(.c) void;
extern fn isr_panic_25() callconv(.c) void;
extern fn isr_panic_26() callconv(.c) void;
extern fn isr_panic_27() callconv(.c) void;
extern fn isr_panic_28() callconv(.c) void;
extern fn isr_panic_29() callconv(.c) void;
extern fn isr_panic_30() callconv(.c) void;
extern fn isr_panic_31() callconv(.c) void;

const PANIC_STUBS = [_]*const fn () callconv(.c) void{
    &isr_panic_0,  &isr_panic_1,  &isr_panic_2,  &isr_panic_3,
    &isr_panic_4,  &isr_panic_5,  &isr_panic_6,  &isr_panic_7,
    &isr_panic_8,  &isr_panic_9,  &isr_panic_10, &isr_panic_11,
    &isr_panic_12, &isr_panic_13, &isr_panic_14, &isr_panic_15,
    &isr_panic_16, &isr_panic_17, &isr_panic_18, &isr_panic_19,
    &isr_panic_20, &isr_panic_21, &isr_panic_22, &isr_panic_23,
    &isr_panic_24, &isr_panic_25, &isr_panic_26, &isr_panic_27,
    &isr_panic_28, &isr_panic_29, &isr_panic_30, &isr_panic_31,
};

pub fn init() void {
    // Install GDT before IDT so CS = gdt.KERNEL_CS for the gates set below.
    gdt.install();
    const cs: u16 = gdt.KERNEL_CS;

    const default_addr = @intFromPtr(&isr_panic_default);
    for (0..256) |i| idt.setGate(@intCast(i), default_addr, cs);
    for (PANIC_STUBS, 0..) |stub, vec| {
        idt.setGate(@intCast(vec), @intFromPtr(stub), cs);
    }
    idt.setGate(0x20, @intFromPtr(&isr_timer), cs);

    idt.load();

    // Mask the legacy 8259. Routing goes through the LAPIC.
    pic.init();

    lapic.init() catch |e| {
        uart.print("\n[traps] lapic.init failed: {s}\n", .{@errorName(e)});
        cpu.halt();
    };
}

pub fn registerIrq(irq: u32, handler: ?IrqHandler) void {
    if (irq < MAX_IRQ) irq_table[irq] = handler;
}

export fn dispatchIrq(vec: u32) callconv(.c) void {
    if (vec < MAX_IRQ) {
        if (irq_table[vec]) |h| {
            var dummy: Frame = .{};
            h(&dummy);
        }
    }
}

export fn dispatchPanic(vec: u32, cr2: u64, rip: u64, rsp: u64) callconv(.c) void {
    uart.print("\n[TRAP] vec=0x{x:0>2} cr2=0x{x:0>16} rip=0x{x:0>16} rsp=0x{x:0>16}\n", .{ vec, cr2, rip, rsp });
    if (user_fault_handler) |h| h();
    cpu.halt();
}

fn currentCs() u16 {
    var cs: u16 = undefined;
    asm volatile ("mov %%cs, %[r]"
        : [r] "=r" (cs),
    );
    return cs;
}
