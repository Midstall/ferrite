// Flat RV64 VS-mode guest for vmexec exercising a PERIODIC virtual timer via
// SBI. Sets a trap vector, enables the supervisor timer interrupt, then arms
// SBI set_timer and WFIs. On each timer interrupt it prints "tick", re-arms the
// timer (the re-arm clears the previous injection), and returns via sret -- a
// few times -- then SBI shutdown. Demonstrates the repeating fire -> re-arm
// cycle (the basis for a guest running its own scheduler tick).
//
// Loaded at the guest base; _start at offset 0 (position independent).

.section .text.boot,"ax"
.global _start
_start:
    la   t0, handler
    csrw stvec, t0               // VS-mode trap vector
    li   t0, (1 << 1)
    csrs sstatus, t0             // sstatus.SIE
    li   t0, (1 << 5)
    csrs sie, t0                 // sie.STIE
    li   s0, 5                   // remaining ticks (callee-saved; survives traps)
    call arm                     // arm the first deadline
1:  wfi
    j    1b

arm:                             // SBI set_timer(now + delta)
    csrr t0, time
    li   t1, 0x80000             // ~ a couple ms of CLINT ticks
    add  a0, t0, t1
    li   a7, 0                   // SBI legacy set_timer
    ecall
    ret

.balign 4
handler:                         // VS-mode supervisor timer interrupt
    la   a3, msg
2:  lbu  a0, 0(a3)
    beqz a0, 3f
    li   a7, 1                   // SBI console_putchar
    ecall
    addi a3, a3, 1
    j    2b
3:  addi s0, s0, -1
    beqz s0, 4f
    call arm                     // re-arm (clears the prior VSTIP injection)
    sret                         // return to the WFI loop for the next tick
4:  li   a7, 8                   // SBI shutdown after the last tick
    ecall
5:  j    5b
msg: .asciz "tick\n"
