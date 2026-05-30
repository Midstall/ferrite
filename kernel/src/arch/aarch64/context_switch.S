// void context_switch(usize *prev_sp, const usize *next_sp);

.section .text.ctx, "ax"
.balign 4
.global context_switch
context_switch:
    stp x29, x30, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    // AAPCS64 also makes d8..d15 (low 64 bits of v8..v15) callee-saved, so a
    // voluntary switch must preserve them too - otherwise an FP/NEON-using
    // thread (the softsynth, the NEON blit) loses state across a yield.
    stp d14, d15, [sp, #-16]!
    stp d12, d13, [sp, #-16]!
    stp d10, d11, [sp, #-16]!
    stp d8,  d9,  [sp, #-16]!

    mov x9, sp
    str x9, [x0]

    ldr x9, [x1]
    mov sp, x9

    ldp d8,  d9,  [sp], #16
    ldp d10, d11, [sp], #16
    ldp d12, d13, [sp], #16
    ldp d14, d15, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x27, x28, [sp], #16
    ldp x29, x30, [sp], #16

    ret

// void context_switch_smp(usize *prev_sp, const usize *next_sp,
//                         u32 *prev_on_cpu, u32 *next_on_cpu);
// As context_switch, plus SMP hand-off bookkeeping done in this exact order:
//   1. save prev's regs, store SP into *prev_sp
//   2. release-store 0 to *prev_on_cpu (if non-null) -> prev is now safe for
//      another core to resume
//   3. spin until *next_on_cpu == 0 -> next's regs are fully saved on its old
//      core before we load its SP
//   4. load next.
// Clearing prev BEFORE waiting on next is essential: if two cores steal each
// other's just-pushed thread, each must release its own thread before blocking on
// the other's, or they deadlock. Doing this in asm (not Zig) is required because
// a switch INTO a brand-new thread never returns into the caller.
.balign 4
.global context_switch_smp
context_switch_smp:
    stp x29, x30, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp d14, d15, [sp, #-16]!
    stp d12, d13, [sp, #-16]!
    stp d10, d11, [sp, #-16]!
    stp d8,  d9,  [sp, #-16]!

    mov x9, sp
    str x9, [x0]

    // prev fully saved: release-store 0 to *prev_on_cpu so a steal can proceed.
    cbz x2, 1f
    stlr wzr, [x2]
1:
    // Wait for next's old core to finish saving it (acquire-load on_cpu == 0).
2:  ldar w10, [x3]
    cbz  w10, 3f
    yield
    b    2b
3:

    ldr x9, [x1]
    mov sp, x9

    ldp d8,  d9,  [sp], #16
    ldp d10, d11, [sp], #16
    ldp d12, d13, [sp], #16
    ldp d14, d15, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x27, x28, [sp], #16
    ldp x29, x30, [sp], #16

    ret
