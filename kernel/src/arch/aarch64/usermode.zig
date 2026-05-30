// SPSR=0 means EL0t/AArch64 with interrupts unmasked.

pub fn init() void {}

pub fn enterUser(user_pc: u64, user_sp: u64) noreturn {
    asm volatile (
        \\ msr sp_el0, %[sp]
        \\ msr elr_el1, %[pc]
        \\ msr spsr_el1, xzr
        \\ isb
        \\ eret
        :
        : [sp] "r" (user_sp),
          [pc] "r" (user_pc),
    );
    unreachable;
}
