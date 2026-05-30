// void context_switch(usize *prev_sp /* a0 */, const usize *next_sp /* a1 */);
//
// Cooperative kernel-thread switch (M-mode). Save callee-saved regs of
// the current thread onto its stack, update *prev_sp, load *next_sp into
// sp, restore callee-saved regs of the new thread, return.
//
// Layout on switch stack (14 slots x 4 bytes = 56 bytes):
//   0: ra        28: s6
//   4: s0        32: s7
//   8: s1        36: s8
//  12: s2        40: s9
//  16: s3        44: s10
//  20: s4        48: s11
//  24: s5        52: padding

.section .text.ctx, "ax"
.balign 4
.global context_switch
context_switch:
    addi    sp, sp, -56
    sw      ra,  0(sp)
    sw      s0,  4(sp)
    sw      s1,  8(sp)
    sw      s2, 12(sp)
    sw      s3, 16(sp)
    sw      s4, 20(sp)
    sw      s5, 24(sp)
    sw      s6, 28(sp)
    sw      s7, 32(sp)
    sw      s8, 36(sp)
    sw      s9, 40(sp)
    sw      s10, 44(sp)
    sw      s11, 48(sp)

    sw      sp, 0(a0)         // *prev_sp = current sp
    lw      sp, 0(a1)         // sp = *next_sp

    lw      ra,  0(sp)
    lw      s0,  4(sp)
    lw      s1,  8(sp)
    lw      s2, 12(sp)
    lw      s3, 16(sp)
    lw      s4, 20(sp)
    lw      s5, 24(sp)
    lw      s6, 28(sp)
    lw      s7, 32(sp)
    lw      s8, 36(sp)
    lw      s9, 40(sp)
    lw      s10, 44(sp)
    lw      s11, 48(sp)
    addi    sp, sp, 56
    ret
