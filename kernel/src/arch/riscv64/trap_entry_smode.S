// SP convention via sscratch: kernel mode keeps sscratch = 0; before sret to
// U-mode the kernel sets sscratch = thread kernel_sp_top. Trap entry swaps
// sp <-> sscratch. sp == 0 after the swap indicates an S-mode trap.

.section .text.trap, "ax"
.balign 4
.global s_trap_entry
s_trap_entry:
    csrrw sp, sscratch, sp
    bnez  sp, 1f
    csrrw sp, sscratch, sp
1:
    addi sp, sp, -272

    // Save user t0/t1 FIRST. The original code clobbered them with sstatus
    // + SPP-bit computation before saving, so the "saved" t0/t1 below
    // were already corrupted, and restoring them on exit delivered the
    // SPP value to user-mode `t1`. That breaks any Zig codegen that relies
    // on temps surviving ecall (mount.cpio's File.read does, and faulted
    // on a NULL self load right after capDup).
    sd   x5,  0x28(sp)
    sd   x6,  0x30(sp)
    sd   x4,  0x20(sp)            // save user tp before we overwrite it

    sd   x1,  0x08(sp)
    csrr t0, sstatus
    andi t1, t0, 0x100            // SPP
    bnez t1, 2f
    csrr t0, sscratch
    sd   t0, 0x10(sp)
    csrw sscratch, zero
    j 3f
2:
    addi t0, sp, 272
    sd   t0, 0x10(sp)
3:
    // Restore kernel tp (per-CPU pointer). User code can clobber tp for
    // its own TLS, but the kernel needs it for thisCpuPtr(). Without
    // this, sched.wake takes the "bootstrap window" early-return and
    // never queues the wakee, so sysWait blocks forever.
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

    csrr t0, sepc
    sd   t0, 0x100(sp)
    csrr t0, sstatus
    sd   t0, 0x108(sp)

    mv   a0, sp
    call dispatchTrap

    ld   t0, 0x100(sp)
    csrw sepc, t0
    ld   t0, 0x108(sp)
    csrw sstatus, t0

    // Decide which exit path BEFORE restoring t0/t1. Otherwise the SPP
    // check below clobbers the user's t0/t1, and `sret` delivers garbage
    // to user-mode (manifests as NULL deref at the next load that uses a
    // t-reg). Branch first, then each tail restores everything cleanly.
    csrr t0, sstatus
    andi t0, t0, 0x100            // SPP
    bnez t0, .Lret_kernel

.Lret_user:
    // Stash user_sp in sscratch BEFORE restoring user GPRs (the load
    // would otherwise need to happen after the restore, requiring a
    // scratch register that clobbers a user value).
    ld   t0, 0x10(sp)             // user_sp
    csrw sscratch, t0             // sscratch = user_sp (temp)
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
    addi sp, sp, 272              // sp = kernel_sp_top
    csrrw sp, sscratch, sp        // swap: sp = user_sp, sscratch = kernel_sp_top
    sret

.Lret_kernel:
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
    addi sp, sp, 272
    sret
