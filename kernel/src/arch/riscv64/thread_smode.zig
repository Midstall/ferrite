// riscv64 S-mode thread context. The asm in context_switch.S is the same
// at every privilege level (it only touches user-visible registers), so
// we just point at it.

extern fn context_switch(prev_sp: *usize, next_sp: *const usize) callconv(.c) void;

pub const contextSwitch = context_switch;

pub fn initStack(stack_top: usize, entry: usize) usize {
    const frame_bytes: usize = 14 * 8;
    const sp = (stack_top - frame_bytes) & ~@as(usize, 15);
    const slots: [*]usize = @ptrFromInt(sp);
    var i: usize = 0;
    while (i < 14) : (i += 1) slots[i] = 0;
    slots[0] = entry; // ra
    return sp;
}
