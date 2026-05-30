.section .text.isr, "ax"
.balign 16

.macro SAVE_CALLER_SAVED
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
.endm

.macro RESTORE_CALLER_SAVED
    popq  %r11
    popq  %r10
    popq  %r9
    popq  %r8
    popq  %rdi
    popq  %rsi
    popq  %rdx
    popq  %rcx
    popq  %rax
.endm

.global isr_timer
.type isr_timer, @function
isr_timer:
    SAVE_CALLER_SAVED
    cld
    movl $0x20, %edi
    call dispatchIrq
    RESTORE_CALLER_SAVED
    iretq

// Vectors that DON'T push an error code; we synthesize a 0 placeholder so
// the iret-frame layout is uniform.
.macro PANIC_STUB n
.global isr_panic_\n
.type isr_panic_\n, @function
isr_panic_\n:
    pushq $0                  // dummy error code
    SAVE_CALLER_SAVED
    cld
    movl $\n, %edi
    movq %cr2, %rsi
    // Iret frame starts at rsp + 9*8 (caller-saved) + 8 (err code we pushed)
    // = rsp + 80. Layout: [err][RIP][CS][RFLAGS][RSP][SS].
    movq 80(%rsp), %rdx       // saved RIP
    movq 104(%rsp), %rcx      // saved user RSP
    call dispatchPanic
.Lhang_\n:
    hlt
    jmp .Lhang_\n
.endm

// Vectors 8, 10..14, 17, 21 (and 29, 30 if supported) push a hardware
// error code. Don't synthesize one; jump straight to the same body.
.macro PANIC_STUB_ERR n
.global isr_panic_\n
.type isr_panic_\n, @function
isr_panic_\n:
    SAVE_CALLER_SAVED
    cld
    movl $\n, %edi
    movq %cr2, %rsi
    movq 80(%rsp), %rdx       // saved RIP (after caller-saved + err code)
    movq 104(%rsp), %rcx      // saved user RSP
    call dispatchPanic
.Lhang_err_\n:
    hlt
    jmp .Lhang_err_\n
.endm

PANIC_STUB 0
PANIC_STUB 1
PANIC_STUB 2
PANIC_STUB 3
PANIC_STUB 4
PANIC_STUB 5
PANIC_STUB 6
PANIC_STUB 7
PANIC_STUB_ERR 8
PANIC_STUB 9
PANIC_STUB_ERR 10
PANIC_STUB_ERR 11
PANIC_STUB_ERR 12
PANIC_STUB_ERR 13
PANIC_STUB_ERR 14
PANIC_STUB 15
PANIC_STUB 16
PANIC_STUB_ERR 17
PANIC_STUB 18
PANIC_STUB 19
PANIC_STUB 20
PANIC_STUB_ERR 21
PANIC_STUB 22
PANIC_STUB 23
PANIC_STUB 24
PANIC_STUB 25
PANIC_STUB 26
PANIC_STUB 27
PANIC_STUB 28
PANIC_STUB 29
PANIC_STUB 30
PANIC_STUB 31

.global isr_panic_default
.type isr_panic_default, @function
isr_panic_default:
    SAVE_CALLER_SAVED
    cld
    movl $0xFF, %edi
    movq %cr2, %rsi
    call dispatchPanic
.Lhang_default:
    hlt
    jmp .Lhang_default

// Wrapped as C-ABI functions; Zig 0.16 inline asm rejects lidt's m80 form.
.global do_lidt
.type do_lidt, @function
do_lidt:
    lidt (%rdi)
    retq

.global do_invlpg
.type do_invlpg, @function
do_invlpg:
    invlpg (%rdi)
    retq

.global do_lgdt
.type do_lgdt, @function
do_lgdt:
    lgdt (%rdi)
    retq

.global do_ltr
.type do_ltr, @function
do_ltr:
    ltr %di
    retq

// rdi = new kernel CS (u64), rsi = new kernel DS (u16).
.global gdt_reload
.type gdt_reload, @function
gdt_reload:
    movw %si, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    leaq 1f(%rip), %rax
    pushq %rdi
    pushq %rax
    lretq
1:
    retq
