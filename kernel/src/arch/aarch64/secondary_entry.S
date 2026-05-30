// NOT .text.boot: that section is reserved for the BSP _start so the Linux
// Image header magic at file offset 0x38 lands at the load address.
.section .text.smp, "ax"
.balign 4
.global _start_secondary
_start_secondary:
    mov  x19, x0

    mov  x2, #(3 << 20)
    msr  cpacr_el1, x2
    isb

    // MAIR_EL1: attr0 = Device-nGnRnE, attr1 = Normal WB.
    mov  x2, #0xFF00
    msr  mair_el1, x2

    adrp x2, l0_table
    add  x2, x2, :lo12:l0_table
    msr  ttbr0_el1, x2

    adrp x2, kernel_tcr
    add  x2, x2, :lo12:kernel_tcr
    ldr  x2, [x2]
    msr  tcr_el1, x2
    isb

    tlbi vmalle1
    dsb  sy
    isb

    // SCTLR_EL1 |= M | C | I
    mov  x3, #0x1005
    mrs  x2, sctlr_el1
    orr  x2, x2, x3
    msr  sctlr_el1, x2
    isb

    adrp x2, inits
    add  x2, x2, :lo12:inits
    add  x2, x2, x19, lsl #4
    ldr  x1, [x2]
    mov  sp, x1

    mov  x0, x19
    bl   secondaryStart
1:  wfe
    b    1b
