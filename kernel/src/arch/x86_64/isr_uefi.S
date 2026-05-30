// MSVC-x64 ABI variants of every kernel-shared asm stub. The UEFI x86_64
// build links THIS file (not isr.S), so the kernel's `extern fn foo()
// callconv(.c)` (which resolves to MSVC under x86_64-uefi-msvc) lands on
// the right register convention: first arg in %rcx, second in %rdx, etc.
//
// Hardware-invoked ISRs (isr_timer, isr_panic_default) read their vector
// from immediates, save MSVC caller-saved regs, and reserve 32 B of
// shadow space before calling the Zig dispatchers.

.section .text.isr_uefi, "ax"
.balign 16

.macro SAVE_CALLER_SAVED_MS
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
.endm

.macro RESTORE_CALLER_SAVED_MS
    popq  %r11
    popq  %r10
    popq  %r9
    popq  %r8
    popq  %rdx
    popq  %rcx
    popq  %rax
.endm

.global isr_timer
isr_timer:
    SAVE_CALLER_SAVED_MS
    cld
    movl $0x20, %ecx
    subq $32, %rsp
    call dispatchIrq
    addq $32, %rsp
    RESTORE_CALLER_SAVED_MS
    iretq

.global isr_panic_default
isr_panic_default:
    SAVE_CALLER_SAVED_MS
    cld
    movl $0xFF, %ecx
    movq %cr2, %rdx
    // #PF/#GP/#TS/#NP/#SS/#DF/#AC push an error code before RIP. For the
    // default handler we don't know the vector, but the diagnostic value
    // is more useful if we report RIP from the WITH-errcode layout (the
    // common user-fault path). 7 pushes + 8 B errcode = 64 B above us.
    movq 64(%rsp), %r8
    subq $32, %rsp
    call dispatchPanic
.Lhang_default:
    hlt
    jmp .Lhang_default

// Per-vector panic stubs (MSVC ABI). Match isr.S so traps.zig's PANIC_STUBS
// array resolves on both SysV and UEFI builds.
.macro PANIC_STUB_MS n
.global isr_panic_\n
isr_panic_\n:
    pushq $0                  // dummy error code
    SAVE_CALLER_SAVED_MS
    cld
    movl $\n, %ecx
    movq %cr2, %rdx
    // 7 caller-saved pushes + 8B err = 64B above rsp; iret RIP is the next slot.
    movq 64(%rsp), %r8
    // 4th MSVC arg = saved RSP from the iret frame (offset 64 + 8 (RIP) + 8 (CS) + 8 (RFLAGS) = 88).
    movq 88(%rsp), %r9
    subq $32, %rsp
    call dispatchPanic
.Lhang_ms_\n:
    hlt
    jmp .Lhang_ms_\n
.endm

.macro PANIC_STUB_MS_ERR n
.global isr_panic_\n
isr_panic_\n:
    SAVE_CALLER_SAVED_MS
    cld
    movl $\n, %ecx
    movq %cr2, %rdx
    movq 64(%rsp), %r8
    movq 88(%rsp), %r9
    subq $32, %rsp
    call dispatchPanic
.Lhang_ms_err_\n:
    hlt
    jmp .Lhang_ms_err_\n
.endm

PANIC_STUB_MS 0
PANIC_STUB_MS 1
PANIC_STUB_MS 2
PANIC_STUB_MS 3
PANIC_STUB_MS 4
PANIC_STUB_MS 5
PANIC_STUB_MS 6
PANIC_STUB_MS 7
PANIC_STUB_MS_ERR 8
PANIC_STUB_MS 9
PANIC_STUB_MS_ERR 10
PANIC_STUB_MS_ERR 11
PANIC_STUB_MS_ERR 12
PANIC_STUB_MS_ERR 13
PANIC_STUB_MS_ERR 14
PANIC_STUB_MS 15
PANIC_STUB_MS 16
PANIC_STUB_MS_ERR 17
PANIC_STUB_MS 18
PANIC_STUB_MS 19
PANIC_STUB_MS 20
PANIC_STUB_MS_ERR 21
PANIC_STUB_MS 22
PANIC_STUB_MS 23
PANIC_STUB_MS 24
PANIC_STUB_MS 25
PANIC_STUB_MS 26
PANIC_STUB_MS 27
PANIC_STUB_MS 28
PANIC_STUB_MS 29
PANIC_STUB_MS 30
PANIC_STUB_MS 31

.global do_lidt
do_lidt:
    lidt (%rcx)
    retq

.global do_invlpg
do_invlpg:
    invlpg (%rcx)
    retq

.global do_lgdt
do_lgdt:
    lgdt (%rcx)
    retq

.global do_ltr
do_ltr:
    movzwl %cx, %ecx
    ltr %cx
    retq

// rcx = new kernel CS, rdx = new kernel DS (low 16 bits each).
.global gdt_reload
gdt_reload:
    movw %dx, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    leaq 1f(%rip), %rax
    pushq %rcx
    pushq %rax
    lretq
1:
    retq

// MSVC SYSCALL entry. User ABI: rax=num, rdi/rsi/rdx/r10/r8/r9 = args 0..5;
// CPU saved user RIP in rcx, user RFLAGS in r11. Swap to the kernel stack
// via the per-CPU slots, save user nonvolatiles, shuffle args from the
// SYSCALL ABI into the MSVC dispatch ABI (rcx, rdx, r8, r9, [rsp+32..48]),
// then iretq back with the user-saved RIP/RFLAGS.
//
// USER RSP is stashed at %gs:0 across the SYSCALL/iret pair, but %gs:0 is a
// per-CPU slot. If this syscall blocks (e.g. ipc.recv) and the scheduler
// runs another thread, that thread's syscall_entry clobbers %gs:0 with ITS
// user RSP. When we eventually iret back here, we'd push the OTHER thread's
// RSP. Copy %gs:0 onto the kernel stack immediately after entry and use
// that copy when building the iret frame so blocking is safe.
.global syscall_entry
syscall_entry:
    movq %rsp, %gs:0                  // save user rsp
    movq %gs:8, %rsp                  // load kernel rsp

    pushq %gs:0                       // saved user RSP, per-thread on kernel stack
    pushq %rcx                        // user RIP
    pushq %r11                        // user RFLAGS
    pushq %rbx
    pushq %rbp
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    // User-mode also expects rdx, r8, r9, r10 unchanged across SYSCALL
    // (Linux syscall ABI: only rax, rcx, r11 are clobbered). MSVC dispatch
    // is free to scratch them, so save here and restore on return.
    pushq %rdx
    pushq %r8
    pushq %r9
    pushq %r10

    // Shuffle SYSCALL args (rax=num, rdi=a0, rsi=a1, rdx=a2, r10=a3,
    // r8=a4, r9=a5) into MSVC dispatch ABI:
    //   rcx=num, rdx=a0, r8=a1, r9=a2, [rsp+32]=a3, [rsp+40]=a4, [rsp+48]=a5.
    // 15 pushes (120 B) above us; we need 32 B shadow + 24 B stack args = 56 B.
    // 120 + 56 = 176 = 16-aligned as MSVC requires at the call site.
    subq $56, %rsp
    movq %r10, 32(%rsp)               // a3
    movq %r8,  40(%rsp)               // a4
    movq %r9,  48(%rsp)               // a5
    movq %rdx, %r9                    // a2
    movq %rsi, %r8                    // a1
    movq %rdi, %rdx                   // a0
    movq %rax, %rcx                   // num

    call dispatchSyscall
    addq $56, %rsp

    popq %r10
    popq %r9
    popq %r8
    popq %rdx
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbp
    popq %rbx
    popq %r11                         // user RFLAGS
    popq %rcx                         // user RIP

    // Build the iretq frame. Read user RSP from the saved slot at [rsp+8]
    // (after pushing $0x23 it's at +8), NOT %gs:0, which a blocked-syscall
    // sibling thread may have clobbered.
    pushq $0x23                       // SS
    pushq 8(%rsp)                     // user RSP from saved slot
    pushq %r11                        // RFLAGS
    pushq $0x1B                       // CS
    pushq %rcx                        // PC
    iretq

// MSVC context_switch: rcx = prev_sp*, rdx = next_sp*.
// Saves the MSVC nonvolatile set + return addr; layout matches initStack.
.global context_switch
context_switch:
    pushq   %rbx
    pushq   %rbp
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    pushq   %rdi
    pushq   %rsi

    movq    %rsp, (%rcx)            // *prev_sp = rsp
    movq    (%rdx), %rsp            // rsp = *next_sp

    popq    %rsi
    popq    %rdi
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbp
    popq    %rbx
    ret
