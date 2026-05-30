// S-mode→U via sret. sscratch holds kernel sp for trap_entry_smode.S to swap on next trap.

const SSTATUS_SPP: u64 = 1 << 8; // S-mode previous-privilege (1=S, 0=U)
const SSTATUS_SPIE: u64 = 1 << 5; // S-mode previous-IE

pub fn init() void {}

pub fn enterUser(user_pc: u64, user_sp: u64) noreturn {
    asm volatile (
    // sstatus = (sstatus & ~SPP) | SPIE
        \\ csrr  t0, sstatus
        \\ li    t1, 0x100
        \\ not   t1, t1
        \\ and   t0, t0, t1     // clear SPP
        \\ li    t1, 0x20
        \\ or    t0, t0, t1     // set SPIE
        \\ csrw  sstatus, t0
        \\ csrw  sepc, %[pc]
        \\ // sscratch = current sp (still on kernel stack here); the trap
        \\ // entry's swap will use this on the next U→S trap.
        \\ csrw  sscratch, sp
        \\ // Swap sp to user_sp and return.
        \\ mv    sp, %[sp]
        \\ sret
        :
        : [pc] "r" (user_pc),
          [sp] "r" (user_sp),
        : .{ .t0 = true, .t1 = true, .memory = true });
    unreachable;
}
