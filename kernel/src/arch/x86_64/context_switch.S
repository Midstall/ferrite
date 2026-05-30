// x86_64 cooperative context switch (SysV AMD64).
//
//   void context_switch(usize *prev_sp /* rdi */, const usize *next_sp /* rsi */);
//
// Push rbx/rbp/r12..r15, save rsp into *prev_sp, load rsp from *next_sp,
// pop the same set in reverse, ret. Frame is 7 × 8 = 56 bytes. After
// `ret` the new thread's rsp = stack_top - 8, which matches the ABI
// post-call alignment (rsp ≡ 8 mod 16).

.section .text.ctx, "ax"
.balign 16
.global context_switch
context_switch:
    pushq   %rbx
    pushq   %rbp
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15

    movq    %rsp, (%rdi)            // *prev_sp = rsp
    movq    (%rsi), %rsp            // rsp = *next_sp

    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbp
    popq    %rbx
    ret
