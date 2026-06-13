// Flat aarch64 EL1 demo guest for vmboot. Boots at the guest base with x0 =
// initrd GPA (see vmboot's ABI), prints a greeting plus the first byte of its
// initrd payload to the PL011 (each store traps to the VMM, which relays it to
// the tty), then powers off via PSCI SYSTEM_OFF. Proves vmboot's load + MMIO
// relay path.
.section .text.boot,"ax"
.global _start
_start:
    mov  x4, x0                  // preserve initrd GPA across the print loop
    movz x1, #0x0900, lsl #16    // PL011 base (0x09000000)
    adr  x2, msg
1:  ldrb w0, [x2], #1
    cbz  w0, 2f
    str  w0, [x1]                // UARTDR (trapped -> relayed by the VMM)
    b    1b
2:  ldrb w0, [x4]                // first byte of the initrd payload
    str  w0, [x1]
    mov  w0, #'\n'
    str  w0, [x1]
    movz x0, #0x0008
    movk x0, #0x8400, lsl #16    // PSCI SYSTEM_OFF
    .inst 0xd4000003             // smc #0
3:  b    3b
msg: .asciz "hello "
