const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const pic = @import("pic.zig");
const uart = @import("x86").uart;

pub const Frame = extern struct {
    _placeholder: u32 = 0,
};

pub const IrqHandler = *const fn (frame: *Frame) void;

pub const SyscallHandler = *const fn (num: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) callconv(.c) isize;
pub var syscall_handler: ?SyscallHandler = null;

pub const FaultHandler = *const fn () noreturn;
pub var user_fault_handler: ?FaultHandler = null;
pub var sync_diag_hook: ?*const fn () void = null;
pub var preempt_hook: ?*const fn () void = null;

const PIC_BASE: u32 = 0x20;
const MAX_IRQ: u32 = 16;
var irq_table: [MAX_IRQ]?IrqHandler = @splat(null);

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    zero: u8,
    type_attr: u8,
    offset_high: u16,
};

var idt: [256]IdtEntry align(8) = @splat(.{
    .offset_low = 0,
    .selector = 0,
    .zero = 0,
    .type_attr = 0,
    .offset_high = 0,
});

const IdtPtr = extern struct {
    limit: u16 align(1),
    base: u32 align(1),
};

var idt_ptr: IdtPtr = .{ .limit = 0, .base = 0 };

fn setGate(vec: u8, handler_addr: u32) void {
    idt[vec] = .{
        .offset_low = @intCast(handler_addr & 0xFFFF),
        .selector = gdt.KERNEL_CS,
        .zero = 0,
        .type_attr = 0x8E,
        .offset_high = @intCast((handler_addr >> 16) & 0xFFFF),
    };
}

/// DPL=3 variant for INT 0x80.
pub fn setUserGate(vec: u8, handler_addr: u32) void {
    idt[vec] = .{
        .offset_low = @intCast(handler_addr & 0xFFFF),
        .selector = gdt.KERNEL_CS,
        .zero = 0,
        .type_attr = 0xEE,
        .offset_high = @intCast((handler_addr >> 16) & 0xFFFF),
    };
}

extern fn isr_panic() void;

// Per-exception entries push their vector + (synthetic-or-real) errcode
// then jump to panic_common, so a fault tells us which one.
extern fn isr_exc_0() void;
extern fn isr_exc_1() void;
extern fn isr_exc_2() void;
extern fn isr_exc_3() void;
extern fn isr_exc_4() void;
extern fn isr_exc_5() void;
extern fn isr_exc_6() void;
extern fn isr_exc_7() void;
extern fn isr_exc_8() void;
extern fn isr_exc_9() void;
extern fn isr_exc_10() void;
extern fn isr_exc_11() void;
extern fn isr_exc_12() void;
extern fn isr_exc_13() void;
extern fn isr_exc_14() void;
extern fn isr_exc_15() void;
extern fn isr_exc_16() void;
extern fn isr_exc_17() void;
extern fn isr_exc_18() void;
extern fn isr_exc_19() void;
extern fn isr_exc_20() void;
extern fn isr_irq_0() void;
extern fn isr_irq_1() void;
extern fn isr_irq_2() void;
extern fn isr_irq_3() void;
extern fn isr_irq_4() void;
extern fn isr_irq_5() void;
extern fn isr_irq_6() void;
extern fn isr_irq_7() void;
extern fn isr_irq_8() void;
extern fn isr_irq_9() void;
extern fn isr_irq_10() void;
extern fn isr_irq_11() void;
extern fn isr_irq_12() void;
extern fn isr_irq_13() void;
extern fn isr_irq_14() void;
extern fn isr_irq_15() void;

pub fn init() void {
    // Install GDT before IDT. Ring-3 transitions need user segments + a TSS.
    gdt.install();

    const panic_addr = @intFromPtr(&isr_panic);
    for (0..256) |i| setGate(@intCast(i), panic_addr);

    const exc_stubs = [_]usize{
        @intFromPtr(&isr_exc_0),  @intFromPtr(&isr_exc_1),
        @intFromPtr(&isr_exc_2),  @intFromPtr(&isr_exc_3),
        @intFromPtr(&isr_exc_4),  @intFromPtr(&isr_exc_5),
        @intFromPtr(&isr_exc_6),  @intFromPtr(&isr_exc_7),
        @intFromPtr(&isr_exc_8),  @intFromPtr(&isr_exc_9),
        @intFromPtr(&isr_exc_10), @intFromPtr(&isr_exc_11),
        @intFromPtr(&isr_exc_12), @intFromPtr(&isr_exc_13),
        @intFromPtr(&isr_exc_14), @intFromPtr(&isr_exc_15),
        @intFromPtr(&isr_exc_16), @intFromPtr(&isr_exc_17),
        @intFromPtr(&isr_exc_18), @intFromPtr(&isr_exc_19),
        @intFromPtr(&isr_exc_20),
    };
    for (exc_stubs, 0..) |addr, i| setGate(@intCast(i), @intCast(addr));

    const irq_stubs = [_]usize{
        @intFromPtr(&isr_irq_0),  @intFromPtr(&isr_irq_1),
        @intFromPtr(&isr_irq_2),  @intFromPtr(&isr_irq_3),
        @intFromPtr(&isr_irq_4),  @intFromPtr(&isr_irq_5),
        @intFromPtr(&isr_irq_6),  @intFromPtr(&isr_irq_7),
        @intFromPtr(&isr_irq_8),  @intFromPtr(&isr_irq_9),
        @intFromPtr(&isr_irq_10), @intFromPtr(&isr_irq_11),
        @intFromPtr(&isr_irq_12), @intFromPtr(&isr_irq_13),
        @intFromPtr(&isr_irq_14), @intFromPtr(&isr_irq_15),
    };
    for (irq_stubs, 0..) |addr, i| {
        setGate(@intCast(PIC_BASE + i), @intCast(addr));
    }

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idt_ptr),
    );

    pic.init();
}

pub fn registerIrq(irq: u32, handler: ?IrqHandler) void {
    if (irq < MAX_IRQ) {
        irq_table[irq] = handler;
        pic.unmask(@intCast(irq));
    }
}

export fn dispatchIrq(irq: u32) callconv(.c) void {
    // Stubs push the raw IRQ number, not the IDT vector.
    if (irq < MAX_IRQ) {
        if (irq_table[irq]) |h| {
            var dummy: Frame = .{};
            h(&dummy);
        }
        pic.endOfInterrupt(@intCast(irq));
    }
}

export fn dispatchPanic(vec: u32, cr2: u32, eip: u32) callconv(.c) void {
    uart.print("\n[TRAP] vec=0x{x:0>2} cr2=0x{x:0>8} eip=0x{x:0>8}\n", .{ vec, cr2, eip });
    if (user_fault_handler) |h| h();
    cpu.halt();
}
