// Flat RV64 S-mode demo guest for vmboot. Boots at the guest base (a0 =
// hartid, a1 = initrd GPA, a2 = initrd size; see vmboot's ABI), prints a
// greeting plus the first byte of its initrd payload via SBI console_putchar,
// then powers off via SBI shutdown. Proves vmboot's load + SBI relay path.
//
// Position independent (la); runs at whatever base vmboot loads it to.
.section .text.boot,"ax"
.global _start
_start:
    la   a3, msg
1:  lbu  a0, 0(a3)
    beqz a0, 2f
    li   a7, 1                   // SBI console_putchar
    ecall
    addi a3, a3, 1
    j    1b
2:  lbu  a0, 0(a1)               // first byte of the initrd payload (a1 = GPA)
    li   a7, 1
    ecall
    li   a0, '\n'
    li   a7, 1
    ecall
    li   a7, 8                   // SBI shutdown
    ecall
3:  j    3b
msg: .asciz "hello "
