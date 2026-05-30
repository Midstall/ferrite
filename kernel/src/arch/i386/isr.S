.section .text.isr, "ax"

.macro IRQ_STUB n
.global isr_irq_\n
.type isr_irq_\n, @function
isr_irq_\n:
    pushl $\n
    jmp irq_common
.endm

IRQ_STUB 0
IRQ_STUB 1
IRQ_STUB 2
IRQ_STUB 3
IRQ_STUB 4
IRQ_STUB 5
IRQ_STUB 6
IRQ_STUB 7
IRQ_STUB 8
IRQ_STUB 9
IRQ_STUB 10
IRQ_STUB 11
IRQ_STUB 12
IRQ_STUB 13
IRQ_STUB 14
IRQ_STUB 15

irq_common:
    // Stack: [ ... iret frame ... | vec ]
    pusha
    cld

    movl 32(%esp), %eax
    pushl %eax
    call dispatchIrq
    addl $4, %esp

    popa
    addl $4, %esp
    iret

.global isr_panic
.type isr_panic, @function
isr_panic:
    // Default vector, no per-exception stub installed. Tag as 0xFF so
    // dispatchPanic can distinguish it from a known vector.
    pushl $0xFF
    jmp panic_common

// Per-exception stubs (0..31). Each pushes its vector number then jumps to
// panic_common, which forwards to dispatchPanic. Vectors with hardware
// error codes (8, 10..14, 17, 21) push a dummy error so the frame layout
// stays uniform.
.macro EXC_STUB n
.global isr_exc_\n
.type isr_exc_\n, @function
isr_exc_\n:
    pushl $0
    pushl $\n
    jmp panic_common
.endm

.macro EXC_STUB_ERR n
.global isr_exc_\n
.type isr_exc_\n, @function
isr_exc_\n:
    pushl $\n
    jmp panic_common
.endm

EXC_STUB 0
EXC_STUB 1
EXC_STUB 2
EXC_STUB 3
EXC_STUB 4
EXC_STUB 5
EXC_STUB 6
EXC_STUB 7
EXC_STUB_ERR 8
EXC_STUB 9
EXC_STUB_ERR 10
EXC_STUB_ERR 11
EXC_STUB_ERR 12
EXC_STUB_ERR 13
EXC_STUB_ERR 14
EXC_STUB 15
EXC_STUB 16
EXC_STUB_ERR 17
EXC_STUB 18
EXC_STUB 19
EXC_STUB 20

panic_common:
    pusha
    cld
    // cdecl pushes args right-to-left: eip (arg 3) first, cr2 (arg 2),
    // vec (arg 1) last. After pusha (32 B) the per-stub-pushed slots are
    // vec @ +32, errcode @ +36, eip @ +40.
    movl 32+8(%esp), %eax    // eip
    pushl %eax
    movl %cr2, %eax
    pushl %eax
    movl 32+8(%esp), %eax    // vec was @ +32; after 2 pushes it's @ +40 = 32+8
    pushl %eax
    call dispatchPanic
    addl $12, %esp
.Lhang_panic:
    hlt
    jmp .Lhang_panic

// Wrapped as C-ABI; Zig 0.16 inline asm rejects lgdt/ltr operand-size forms.
.global do_lgdt
.type do_lgdt, @function
do_lgdt:
    movl 4(%esp), %eax
    lgdt (%eax)
    ret

.global do_ltr
.type do_ltr, @function
do_ltr:
    movw 4(%esp), %ax
    ltr %ax
    ret

.global gdt_reload
.type gdt_reload, @function
gdt_reload:
    movzwl 4(%esp), %ecx
    movzwl 8(%esp), %edx
    movw %dx, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    pushl %ecx
    pushl $1f
    lret
1:
    ret

// INT 0x80: ABI is eax=num, ebx/ecx/edx/esi/edi/ebp = args 0..5, return -> eax.
.global isr_int80
.type isr_int80, @function
isr_int80:
    pusha
    pushl %ds
    pushl %es
    pushl %fs
    pushl %gs

    movl $0x10, %eax
    movw %ax, %ds
    movw %ax, %es

    // pusha frame offsets after the 4 segment pushes (16 bytes):
    //   16 edi (a4) / 20 esi (a3) / 24 ebp (a5) / 28 esp_orig
    //   32 ebx (a0) / 36 edx (a2) / 40 ecx (a1) / 44 eax (num)
    subl $28, %esp
    movl 44+28(%esp), %eax;  movl %eax, 0(%esp)
    movl 32+28(%esp), %eax;  movl %eax, 4(%esp)
    movl 40+28(%esp), %eax;  movl %eax, 8(%esp)
    movl 36+28(%esp), %eax;  movl %eax, 12(%esp)
    movl 20+28(%esp), %eax;  movl %eax, 16(%esp)
    movl 16+28(%esp), %eax;  movl %eax, 20(%esp)
    movl 24+28(%esp), %eax;  movl %eax, 24(%esp)
    call dispatchSyscall

    // isize fits in eax on i386. Write it back to the pusha frame's eax slot.
    movl %eax, 44+28(%esp)
    addl $28, %esp

    popl %gs
    popl %fs
    popl %es
    popl %ds
    popa
    iret
