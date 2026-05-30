// M-mode -> U-mode entry. The PMP/PMA/APM setup that makes U-mode
// usable at all happens elsewhere (board pmp.configureRegionProtection,
// apm.allowAllUmode). This just performs the `mret` transition.

pub fn init() void {}

/// u64 args match the shared kernel/src/thread.zig field types. Truncated
/// to u32 at the boundary since c6 addresses are 32-bit.
pub fn enterUser(user_pc: u64, user_sp: u64) noreturn {
    const pc32: u32 = @intCast(user_pc);
    const sp32: u32 = @intCast(user_sp);
    asm volatile (
    // Clear mstatus.MPP (bits 12:11 -> U-mode), set MPIE.
        \\ csrr  t0, mstatus
        \\ li    t1, 0x1800
        \\ not   t1, t1
        \\ and   t0, t0, t1
        \\ li    t1, 0x80
        \\ or    t0, t0, t1
        \\ csrw  mstatus, t0
        \\ csrw  mepc, %[pc]
        \\ csrw  mscratch, sp
        \\ mv    sp, %[sp]
        \\ mret
        :
        : [pc] "r" (pc32),
          [sp] "r" (sp32),
        : .{ .t0 = true, .t1 = true, .memory = true });
    unreachable;
}
