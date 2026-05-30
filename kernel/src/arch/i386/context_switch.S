// i386 cooperative context switch (cdecl).
//
//   void context_switch(usize *prev_sp /* [esp+4] */, const usize *next_sp /* [esp+8] */);
//
// Push ebx/esi/edi/ebp on the current stack, save SP into *prev_sp, load
// SP from *next_sp, pop ebp/edi/esi/ebx, ret to whatever return address
// was sitting at the top of the new stack.

.section .text.ctx, "ax"
.balign 4
.global context_switch
context_switch:
    pushl   %ebp
    pushl   %edi
    pushl   %esi
    pushl   %ebx

    // After the 4 pushes, the original args are at +20 and +24.
    movl    20(%esp), %eax
    movl    %esp, (%eax)            // *prev_sp = esp
    movl    24(%esp), %eax
    movl    (%eax), %esp            // esp = *next_sp

    popl    %ebx
    popl    %esi
    popl    %edi
    popl    %ebp
    ret
