extern fn context_switch(prev_sp: *usize, next_sp: *const usize) callconv(.c) void;

pub const contextSwitch = context_switch;

const gdt = @import("gdt.zig");

/// Called by the scheduler on every context switch so the TSS's esp0
/// (kernel SP loaded by the CPU on a U→K privilege change for IRQs and
/// exceptions) points at the CURRENT thread's kernel stack. Without this,
/// an IRQ in thread B clobbers thread A's kernel stack.
pub fn setKernelStack(rsp0: u64) void {
    gdt.setKernelStack(@intCast(rsp0));
}

pub fn initStack(stack_top: usize, entry: usize) usize {
    const frame_bytes: usize = 5 * 4;
    const sp = (stack_top - frame_bytes) & ~@as(usize, 15);
    const slots: [*]usize = @ptrFromInt(sp);
    var i: usize = 0;
    while (i < 5) : (i += 1) slots[i] = 0;
    slots[4] = entry;
    return sp;
}
