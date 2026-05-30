extern fn context_switch(prev_sp: *usize, next_sp: *const usize) callconv(.c) void;
extern fn context_switch_smp(prev_sp: *usize, next_sp: *const usize, prev_on_cpu: ?*u32, next_on_cpu: *u32) callconv(.c) void;

pub const contextSwitch = context_switch;
/// SMP-safe switch: release-clears *prev_on_cpu the instant prev's SP is saved,
/// then waits for *next_on_cpu==0 before loading next. Pass null prev_on_cpu when
/// prev isn't published to a runqueue (exit).
pub const contextSwitchSmp = context_switch_smp;

/// Seed a stack so the first contextSwitch into it lands at `entry`.
/// Frame matches context_switch's save area: 8 slots for d8..d15, then 12 for
/// x19..x30 (x30 holds `entry`, the slot popped last). 20 8-byte slots total.
pub fn initStack(stack_top: usize, entry: usize) usize {
    const frame_bytes: usize = 20 * 8;
    const sp = (stack_top - frame_bytes) & ~@as(usize, 15);
    const slots: [*]usize = @ptrFromInt(sp);
    var i: usize = 0;
    while (i < 20) : (i += 1) slots[i] = 0;
    slots[19] = entry;
    return sp;
}
