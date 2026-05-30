const builtin = @import("builtin");

extern fn context_switch(prev_sp: *usize, next_sp: *const usize) callconv(.c) void;

pub const contextSwitch = context_switch;

const gdt = @import("gdt.zig");

/// Called by the scheduler on every context switch. The TSS rsp0 is loaded
/// by the CPU on a U→K privilege change (IRQs, exceptions). Without per-
/// switch updates, an IRQ in thread B uses thread A's kernel stack and
/// corrupts whatever saved state A had there. The SYSCALL path uses gs:8
/// instead of TSS so it's already covered by cpu.kernel_rsp.
pub fn setKernelStack(rsp0: u64) void {
    gdt.setKernelStack(rsp0);
}

// MSVC ABI nonvolatile-set has 8 GPRs (rbx, rbp, rdi, rsi, r12..r15);
// SysV has 6 (rbx, rbp, r12..r15). The matching context_switch.S in each
// build path pushes its ABI's set; initStack lays out a synthetic frame
// the first switch-in pops through. Entry sits at the slot the final
// `ret` loads into %rip.
const is_msvc = builtin.target.abi == .msvc;
const saved_regs: usize = if (is_msvc) 8 else 6;

pub fn initStack(stack_top: usize, entry: usize) usize {
    const slots_total: usize = saved_regs + 1;
    const frame_bytes: usize = slots_total * 8;
    const sp = (stack_top - frame_bytes) & ~@as(usize, 15);
    const slots: [*]usize = @ptrFromInt(sp);
    var i: usize = 0;
    while (i < slots_total) : (i += 1) slots[i] = 0;
    slots[saved_regs] = entry;
    return sp;
}
