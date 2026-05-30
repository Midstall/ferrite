// Limine entrypoint shim. Limine's bootloader stack lives in
// bootloader_reclaimable memory; once the kernel starts handing out pages
// from those regions, anything on that stack gets clobbered. Switch to our
// own .bss-allocated stack before calling into Zig.

.section .text.boot, "ax"
.balign 16
.global _start
.type _start, @function
_start:
    cld
    leaq __stack_top(%rip), %rsp
    andq $-16, %rsp
    xorq %rbp, %rbp
    call zigStart
0:  hlt
    jmp 0b
