.section .vectors, "ax"

// Frame is 800 bytes: 0x000..0x10F is the GPR/system trap frame (matches
// traps.Frame, 272 bytes); 0x110..0x31F is the FP/NEON save area. The kernel
// itself uses NEON (std.fmt q-loads), so every trap MUST save+restore the
// interrupted context's v0..v31 + fpsr/fpcr, or it corrupts whatever userspace
// (or nested-kernel) NEON code was mid-flight - e.g. badapple's NEON blit.
.macro SAVE_REGS
    sub  sp, sp, #800
    stp  x0,  x1,  [sp, #0x00]
    stp  x2,  x3,  [sp, #0x10]
    stp  x4,  x5,  [sp, #0x20]
    stp  x6,  x7,  [sp, #0x30]
    stp  x8,  x9,  [sp, #0x40]
    stp  x10, x11, [sp, #0x50]
    stp  x12, x13, [sp, #0x60]
    stp  x14, x15, [sp, #0x70]
    stp  x16, x17, [sp, #0x80]
    stp  x18, x19, [sp, #0x90]
    stp  x20, x21, [sp, #0xA0]
    stp  x22, x23, [sp, #0xB0]
    stp  x24, x25, [sp, #0xC0]
    stp  x26, x27, [sp, #0xD0]
    stp  x28, x29, [sp, #0xE0]
    str  x30,      [sp, #0xF0]
    mrs  x0, elr_el1
    mrs  x1, spsr_el1
    stp  x0, x1,   [sp, #0xF8]
    mrs  x0, sp_el0
    str  x0,       [sp, #0x108]
    // FP/NEON: fpsr/fpcr at 0x110, then v0..v31.
    mrs  x0, fpsr
    mrs  x1, fpcr
    stp  x0,  x1,  [sp, #272]
    stp  q0,  q1,  [sp, #288]
    stp  q2,  q3,  [sp, #320]
    stp  q4,  q5,  [sp, #352]
    stp  q6,  q7,  [sp, #384]
    stp  q8,  q9,  [sp, #416]
    stp  q10, q11, [sp, #448]
    stp  q12, q13, [sp, #480]
    stp  q14, q15, [sp, #512]
    stp  q16, q17, [sp, #544]
    stp  q18, q19, [sp, #576]
    stp  q20, q21, [sp, #608]
    stp  q22, q23, [sp, #640]
    stp  q24, q25, [sp, #672]
    stp  q26, q27, [sp, #704]
    stp  q28, q29, [sp, #736]
    stp  q30, q31, [sp, #768]
.endm

.macro RESTORE_REGS
    ldp  q30, q31, [sp, #768]
    ldp  q28, q29, [sp, #736]
    ldp  q26, q27, [sp, #704]
    ldp  q24, q25, [sp, #672]
    ldp  q22, q23, [sp, #640]
    ldp  q20, q21, [sp, #608]
    ldp  q18, q19, [sp, #576]
    ldp  q16, q17, [sp, #544]
    ldp  q14, q15, [sp, #512]
    ldp  q12, q13, [sp, #480]
    ldp  q10, q11, [sp, #448]
    ldp  q8,  q9,  [sp, #416]
    ldp  q6,  q7,  [sp, #384]
    ldp  q4,  q5,  [sp, #352]
    ldp  q2,  q3,  [sp, #320]
    ldp  q0,  q1,  [sp, #288]
    ldp  x0,  x1,  [sp, #272]
    msr  fpsr, x0
    msr  fpcr, x1
    ldr  x0,       [sp, #0x108]
    msr  sp_el0,   x0
    ldp  x0, x1,   [sp, #0xF8]
    msr  elr_el1,  x0
    msr  spsr_el1, x1
    ldr  x30,      [sp, #0xF0]
    ldp  x28, x29, [sp, #0xE0]
    ldp  x26, x27, [sp, #0xD0]
    ldp  x24, x25, [sp, #0xC0]
    ldp  x22, x23, [sp, #0xB0]
    ldp  x20, x21, [sp, #0xA0]
    ldp  x18, x19, [sp, #0x90]
    ldp  x16, x17, [sp, #0x80]
    ldp  x14, x15, [sp, #0x70]
    ldp  x12, x13, [sp, #0x60]
    ldp  x10, x11, [sp, #0x50]
    ldp  x8,  x9,  [sp, #0x40]
    ldp  x6,  x7,  [sp, #0x30]
    ldp  x4,  x5,  [sp, #0x20]
    ldp  x2,  x3,  [sp, #0x10]
    ldp  x0,  x1,  [sp, #0x00]
    add  sp, sp, #800
.endm

.balign 0x800
.global vector_table_start
vector_table_start:
    // Current EL with SP_EL0
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown

    // Current EL with SP_ELx
    .balign 0x80
    b    vec_sync_el1
    .balign 0x80
    b    vec_irq_el1
    .balign 0x80
    b    vec_fiq_el1
    .balign 0x80
    b    vec_serror_el1

    // Lower EL using AArch64
    .balign 0x80
    b    vec_sync_el0
    .balign 0x80
    b    vec_irq_el0
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown

    // Lower EL using AArch32
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown
    .balign 0x80
    b    vec_unknown

vec_sync_el1:
    SAVE_REGS
    mov  x0, sp
    bl   dispatchSync
    RESTORE_REGS
    eret

vec_irq_el1:
    SAVE_REGS
    mov  x0, sp
    bl   dispatchIrq
    RESTORE_REGS
    eret

vec_fiq_el1:
    SAVE_REGS
    mov  x0, sp
    bl   dispatchFiq
    RESTORE_REGS
    eret

vec_serror_el1:
    SAVE_REGS
    mov  x0, sp
    bl   dispatchSError
    RESTORE_REGS
    eret

vec_unknown:
    SAVE_REGS
    mov  x0, sp
    bl   dispatchUnknown
    RESTORE_REGS
    eret

// Unmask IRQs so syscall bodies that sched.block/yield run with IRQs enabled;
// the trap entry left DAIF.I set.
vec_sync_el0:
    SAVE_REGS
    msr  daifclr, #2
    mov  x0, sp
    bl   dispatchSyncEl0
    msr  daifset, #2
    RESTORE_REGS
    eret

vec_irq_el0:
    SAVE_REGS
    mov  x0, sp
    bl   dispatchIrq
    RESTORE_REGS
    eret
