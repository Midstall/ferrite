// Flat aarch64 vmexec guest that exercises the virtualized virtual timer.
//
// Boots at EL1 (stage-1 off, VA == guest IPA), arms CNTV ~a few ms out, spins
// on CNTV_CTL.ISTATUS until it fires, prints "tick" via the PL011 (trapped +
// relayed to the tty by the VMM), then powers off via PSCI. Proves the per-run
// CNTV save/restore + counter virtualization in hyp.zig.
//
// (An IRQ-driven WFI+vGIC variant works far enough to prove the GICH vIRQ
// injection -- the guest takes the injected interrupt and runs its handler --
// but qemu doesn't deliver the virtual timer to EL2 in this post-boot context,
// so waiting for it is unreliable under TCG; needs KVM. This poll form
// validates the timer itself without depending on that delivery path.)
.section .text.boot,"ax"
.global _start
_start:
    movz x13, #0x4, lsl #16      // 0x40000 cycles (~ a few ms)
    msr  cntv_tval_el0, x13
    mov  x13, #1
    msr  cntv_ctl_el0, x13       // ENABLE (IMASK=0)
    isb
1:  mrs  x14, cntv_ctl_el0
    tbz  x14, #2, 1b             // poll ISTATUS (bit 2) until the timer fires

    movz x1, #0x0900, lsl #16    // PL011
    adr  x2, msg
2:  ldrb w0, [x2], #1
    cbz  w0, 3f
    str  w0, [x1]                // UARTDR (trapped -> relayed by the VMM)
    b    2b
3:  movz x0, #0x0008
    movk x0, #0x8400, lsl #16    // PSCI SYSTEM_OFF
    .inst 0xd4000003             // smc #0
4:  b    4b
msg: .asciz "tick\n"
