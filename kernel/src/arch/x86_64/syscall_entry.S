// SYSCALL ABI: rax=num, rdi/rsi/rdx/r10/r8/r9 = args 0..5, return in rax.
// CPU saves user RIP in rcx, user RFLAGS in r11, and does not switch RSP.
//
// USER RSP is stashed at %gs:0 across the SYSCALL/iret pair, but %gs:0 is a
// per-CPU slot. If this syscall blocks (e.g. ipc.recv) and the scheduler
// runs another thread, that thread's syscall_entry clobbers %gs:0 with ITS
// user RSP. When we eventually iret back here, we'd push the OTHER thread's
// RSP and resume user mode on the wrong stack. Copy %gs:0 onto the kernel
// stack immediately after entry and use that copy when building the iret
// frame so blocking is safe.

.section .text, "ax"
.balign 16
.global syscall_entry
syscall_entry:
    movq %rsp, %gs:0
    movq %gs:8, %rsp

    pushq %gs:0                // saved user RSP, per-thread on kernel stack
    pushq %rcx                 // user RIP
    pushq %r11                 // user RFLAGS
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    // Linux syscall ABI clobbers ONLY rax, rcx, r11, so preserve every
    // other user-visible reg. The SysV function-call ABI used by the Zig
    // dispatch is happy to scratch rdx/rsi/rdi/r8/r9/r10, so save them too.
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %r8
    pushq %r9
    pushq %r10

    // SYSCALL→SysV shuffle. Source: rax=num, rdi=a0, rsi=a1, rdx=a2,
    // r10=a3, r8=a4, r9=a5. Target: rdi=num, rsi=a0, rdx=a1, rcx=a2,
    // r8=a3, r9=a4, [rsp+0]=a5. Do the moves in reverse-dependency order
    // so no source register is clobbered before it's consumed.
    pushq %r9                  // a5 → stack
    movq %r8,  %r9             // a4 → r9
    movq %r10, %r8             // a3 → r8
    movq %rdx, %rcx            // a2 → rcx
    movq %rsi, %rdx            // a1 → rdx
    movq %rdi, %rsi            // a0 → rsi
    movq %rax, %rdi            // num → rdi

    // 15 nonvol pushes + 1 stack-arg push = 128 B above rsp at this point.
    // Already 16-aligned; no pad needed.
    call dispatchSyscall
    addq $8, %rsp              // drop a5 stack arg

    popq %r10
    popq %r9
    popq %r8
    popq %rdx
    popq %rsi
    popq %rdi
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popq %r11
    popq %rcx

    // user RSP sits at [rsp+0] (we pushed it first, popped last). Build
    // the iret frame around it without clobbering rax (the syscall
    // return value the user expects). Sourcing user RSP from this slot
    // (not %gs:0) keeps blocking syscalls safe: a sibling thread's
    // syscall would overwrite %gs:0, but the kernel stack copy is ours.
    pushq $0x23                // user SS
    pushq 8(%rsp)              // user RSP from saved slot (now at +8 after this push)
    pushq %r11                 // user RFLAGS
    pushq $0x1B                // user CS
    pushq %rcx                 // user RIP
    iretq
