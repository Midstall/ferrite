// riscv64 M-mode trap entry. Handles traps from both M-mode (kernel)
// and U-mode (userspace). Mirrors the S-mode entry in
// trap_entry_smode.S but reads/writes M-mode CSRs and ends with `mret`.
//
// SP convention via mscratch:
//   * While the CPU is in M-mode, mscratch = 0.
//   * Just before mret-ing to U-mode, the kernel sets
//     mscratch = current thread's kernel-sp top.
// On trap entry we swap sp with mscratch and detect "from M" via
// sp == 0 after the swap.

.section .text.trap, "ax"
.balign 4
.global trap_entry
trap_entry:
    csrrw sp, mscratch, sp
    bnez  sp, 1f
    csrrw sp, mscratch, sp        // was M-mode: swap back
1:
    addi sp, sp, -288

    // Save user t0/t1 FIRST. Same bug as s_trap_entry: the MPP check
    // below clobbers them with mstatus + bit-mask before the save loop
    // got to them. Save now so restore-on-exit gives the user back their
    // own values, not the MPP scratch.
    sd   x5,  0x28(sp)
    sd   x6,  0x30(sp)
    sd   x4,  0x20(sp)            // save user tp before we overwrite it

    sd   x1,  0x08(sp)
    csrr t0, mstatus
    li   t1, 0x1800               // MPP mask (bits 12:11)
    and  t1, t0, t1
    bnez t1, 2f
    // MPP = 00 → from U-mode. x2 = user_sp lives in mscratch.
    csrr t0, mscratch
    sd   t0, 0x10(sp)
    csrw mscratch, zero
    j 3f
2:
    // From M-mode: kernel sp at trap time = current sp + 288.
    addi t0, sp, 288
    sd   t0, 0x10(sp)
3:
    // Restore kernel tp (per-CPU pointer) so kernel-side thisCpuPtr()
    // doesn't see user's tp (often 0). Same fix as s_trap_entry.
    la   t0, kernel_tp_for_traps
    ld   tp, 0(t0)
    sd   x3,  0x18(sp)
    sd   x7,  0x38(sp)
    sd   x8,  0x40(sp)
    sd   x9,  0x48(sp)
    sd   x10, 0x50(sp)
    sd   x11, 0x58(sp)
    sd   x12, 0x60(sp)
    sd   x13, 0x68(sp)
    sd   x14, 0x70(sp)
    sd   x15, 0x78(sp)
    sd   x16, 0x80(sp)
    sd   x17, 0x88(sp)
    sd   x18, 0x90(sp)
    sd   x19, 0x98(sp)
    sd   x20, 0xA0(sp)
    sd   x21, 0xA8(sp)
    sd   x22, 0xB0(sp)
    sd   x23, 0xB8(sp)
    sd   x24, 0xC0(sp)
    sd   x25, 0xC8(sp)
    sd   x26, 0xD0(sp)
    sd   x27, 0xD8(sp)
    sd   x28, 0xE0(sp)
    sd   x29, 0xE8(sp)
    sd   x30, 0xF0(sp)
    sd   x31, 0xF8(sp)

    csrr t0, mepc
    sd   t0, 0x100(sp)
    csrr t0, mstatus
    sd   t0, 0x108(sp)
    csrr t0, mcause
    sd   t0, 0x110(sp)
    csrr t0, mtval
    sd   t0, 0x118(sp)

    mv   a0, sp
    call dispatchTrap

    ld   t0, 0x100(sp)
    csrw mepc, t0
    ld   t0, 0x108(sp)
    csrw mstatus, t0

    // Decide which exit path BEFORE restoring t0/t1. Otherwise reading
    // mstatus into them clobbers the user's just-restored t-regs and
    // mret delivers garbage to user-mode. Branch first, then each path
    // restores everything cleanly. Same bug pattern as the S-mode entry.
    csrr t0, mstatus
    li   t1, 0x1800
    and  t0, t0, t1
    bnez t0, .Lret_kernel_m

.Lret_user_m:
    // Stash user_sp in mscratch BEFORE restoring user GPRs.
    ld   t0, 0x10(sp)
    csrw mscratch, t0
    ld   x1,  0x08(sp)
    ld   x3,  0x18(sp)
    ld   x4,  0x20(sp)
    ld   x5,  0x28(sp)            // restores user t0
    ld   x6,  0x30(sp)
    ld   x7,  0x38(sp)
    ld   x8,  0x40(sp)
    ld   x9,  0x48(sp)
    ld   x10, 0x50(sp)
    ld   x11, 0x58(sp)
    ld   x12, 0x60(sp)
    ld   x13, 0x68(sp)
    ld   x14, 0x70(sp)
    ld   x15, 0x78(sp)
    ld   x16, 0x80(sp)
    ld   x17, 0x88(sp)
    ld   x18, 0x90(sp)
    ld   x19, 0x98(sp)
    ld   x20, 0xA0(sp)
    ld   x21, 0xA8(sp)
    ld   x22, 0xB0(sp)
    ld   x23, 0xB8(sp)
    ld   x24, 0xC0(sp)
    ld   x25, 0xC8(sp)
    ld   x26, 0xD0(sp)
    ld   x27, 0xD8(sp)
    ld   x28, 0xE0(sp)
    ld   x29, 0xE8(sp)
    ld   x30, 0xF0(sp)
    ld   x31, 0xF8(sp)
    addi sp, sp, 288              // sp = kernel_sp_top
    csrrw sp, mscratch, sp        // swap: sp = user_sp, mscratch = kernel_sp_top
    mret

.Lret_kernel_m:
    ld   x1,  0x08(sp)
    ld   x3,  0x18(sp)
    ld   x4,  0x20(sp)
    ld   x5,  0x28(sp)
    ld   x6,  0x30(sp)
    ld   x7,  0x38(sp)
    ld   x8,  0x40(sp)
    ld   x9,  0x48(sp)
    ld   x10, 0x50(sp)
    ld   x11, 0x58(sp)
    ld   x12, 0x60(sp)
    ld   x13, 0x68(sp)
    ld   x14, 0x70(sp)
    ld   x15, 0x78(sp)
    ld   x16, 0x80(sp)
    ld   x17, 0x88(sp)
    ld   x18, 0x90(sp)
    ld   x19, 0x98(sp)
    ld   x20, 0xA0(sp)
    ld   x21, 0xA8(sp)
    ld   x22, 0xB0(sp)
    ld   x23, 0xB8(sp)
    ld   x24, 0xC0(sp)
    ld   x25, 0xC8(sp)
    ld   x26, 0xD0(sp)
    ld   x27, 0xD8(sp)
    ld   x28, 0xE0(sp)
    ld   x29, 0xE8(sp)
    ld   x30, 0xF0(sp)
    ld   x31, 0xF8(sp)
    addi sp, sp, 288
    mret
