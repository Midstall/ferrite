// riscv32 M-mode trap entry for ESP32-C6.
//
// The chip uses CLIC-style mtvec: writes are masked to a 64-byte-aligned
// base and mode is force-set to vectored (01). `_vector_table` is that
// base - 32 single-instruction jumps, each indexed by trap cause. For
// now every cause funnels into `trap_common`; per-IRQ vectoring will use
// dedicated slots later.

.section .trap, "ax"
// ESP32-C6 mtvec masks BASE to bits[31:8] - alignment is 256 bytes, not the
// 64 the RISC-V privileged spec allows. Empirically: writing 0x40850480
// reads back as 0x40850400 (bit 7 cleared).
.balign 256
.global _vector_table
// CLIC vectored mode uses a 4-byte stride: cause N lands at base + 4*N.
// Two assembler options matter here, both copied from esp-riscv-rt:
//   `.option norvc`     - keep each `j` a full 4 bytes (compressed `c.j`
//                         would shrink slots to 2 bytes, every jump misses).
//   `.option norelax`   - disable linker relaxation, which could shorten
//                         the `j` despite norvc and break stride alignment.
.option push
.option norelax
.option norvc
_vector_table:
    j trap_common   // 0  inst addr misaligned
    j trap_common   // 1  inst access fault
    j trap_common   // 2  illegal instruction
    j trap_common   // 3  breakpoint
    j trap_common   // 4  load addr misaligned
    j trap_common   // 5  load access fault
    j trap_common   // 6  store/AMO addr misaligned
    j trap_common   // 7  store/AMO access fault
    j trap_common   // 8  ecall from U
    j trap_common   // 9  ecall from S
    j trap_common   // 10 reserved
    j trap_common   // 11 ecall from M
    j trap_common   // 12 inst page fault
    j trap_common   // 13 load page fault
    j trap_common   // 14 reserved
    j trap_common   // 15 store page fault
    j trap_common   // 16 (interrupts start here when vectored mode routes irqs)
    j trap_common   // 17
    j trap_common   // 18
    j trap_common   // 19
    j trap_common   // 20
    j trap_common   // 21
    j trap_common   // 22
    j trap_common   // 23
    j trap_common   // 24
    j trap_common   // 25
    j trap_common   // 26
    j trap_common   // 27
    j trap_common   // 28
    j trap_common   // 29
    j trap_common   // 30
    j trap_common   // 31
.option pop

.balign 4
.global trap_common
trap_common:
    addi sp, sp, -144

    sw x1,   4(sp)
    sw x3,  12(sp)
    sw x4,  16(sp)
    sw x5,  20(sp)
    sw x6,  24(sp)
    sw x7,  28(sp)
    sw x8,  32(sp)
    sw x9,  36(sp)
    sw x10, 40(sp)
    sw x11, 44(sp)
    sw x12, 48(sp)
    sw x13, 52(sp)
    sw x14, 56(sp)
    sw x15, 60(sp)
    sw x16, 64(sp)
    sw x17, 68(sp)
    sw x18, 72(sp)
    sw x19, 76(sp)
    sw x20, 80(sp)
    sw x21, 84(sp)
    sw x22, 88(sp)
    sw x23, 92(sp)
    sw x24, 96(sp)
    sw x25, 100(sp)
    sw x26, 104(sp)
    sw x27, 108(sp)
    sw x28, 112(sp)
    sw x29, 116(sp)
    sw x30, 120(sp)
    sw x31, 124(sp)

    addi t0, sp, 144
    sw t0,   8(sp)

    csrr t0, mepc
    sw t0, 128(sp)
    csrr t0, mstatus
    sw t0, 132(sp)
    csrr t0, mcause
    sw t0, 136(sp)
    csrr t0, mtval
    sw t0, 140(sp)

    mv a0, sp
    call dispatchTrap
    // dispatchTrap returns the frame pointer to restore from. Same pointer
    // for "stay on this thread"; different pointer for a thread switch.
    mv sp, a0

    lw t0, 128(sp)
    csrw mepc, t0
    lw t0, 132(sp)
    csrw mstatus, t0

    lw x1,   4(sp)
    lw x3,  12(sp)
    lw x4,  16(sp)
    lw x5,  20(sp)
    lw x6,  24(sp)
    lw x7,  28(sp)
    lw x8,  32(sp)
    lw x9,  36(sp)
    lw x10, 40(sp)
    lw x11, 44(sp)
    lw x12, 48(sp)
    lw x13, 52(sp)
    lw x14, 56(sp)
    lw x15, 60(sp)
    lw x16, 64(sp)
    lw x17, 68(sp)
    lw x18, 72(sp)
    lw x19, 76(sp)
    lw x20, 80(sp)
    lw x21, 84(sp)
    lw x22, 88(sp)
    lw x23, 92(sp)
    lw x24, 96(sp)
    lw x25, 100(sp)
    lw x26, 104(sp)
    lw x27, 108(sp)
    lw x28, 112(sp)
    lw x29, 116(sp)
    lw x30, 120(sp)
    lw x31, 124(sp)

    addi sp, sp, 144
    mret
