// Flat 32-bit x86 demo guest for vmboot. Runs in protected mode with paging off
// (linear == GPA), EAX = initrd GPA (vmboot's boot register). Prints a greeting
// plus the first byte of its initrd payload to COM1 (port 0x3F8, which the
// hypervisor traps as port I/O and vmboot relays to the tty), then HLTs. Linked
// absolute at the guest base (0x40000000) so its data references resolve.
.code32
.section .text.boot,"ax"
.global _start
_start:
    movl %eax, %edi              // EAX = initrd GPA (preserve across the loop)
    movl $msg, %esi
    movw $0x3f8, %dx             // COM1 data port
1:  movb (%esi), %al
    testb %al, %al
    jz 2f
    outb %al, %dx                // trapped as port I/O -> relayed by vmboot
    incl %esi
    jmp 1b
2:  movb (%edi), %al             // first byte of the initrd payload
    outb %al, %dx
    movb $0x0a, %al              // newline
    outb %al, %dx
    hlt
3:  jmp 3b
msg: .asciz "hello "
