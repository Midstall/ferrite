// x86_64 multiboot1 + multiboot2 boot. Both headers in same binary; a loader
// (QEMU's `-kernel`, GRUB, etc.) recognizes one or the other and jumps to _start.
// On entry we're in 32-bit protected mode. We build a 4-level page table identity-
// mapping the first 1 GB with 2 MB huge pages, enable PAE+LME+PG, load a 64-bit
// GDT, and far-jump into start64 (the 64-bit landing pad that calls zigStart).

.section .multiboot1, "a"
.align 4
.long 0x1BADB002                        // magic
.long 0                                 // flags
.long -(0x1BADB002 + 0)                 // checksum (so the three sum to 0)

.section .multiboot2, "a"
.align 8
mb2_hdr_start:
    .long 0xE85250D6                                                                   // magic
    .long 0                                                                            // arch: i386 protected mode
    .long mb2_hdr_end - mb2_hdr_start                                                  // header length
    .long -(0xE85250D6 + 0 + (mb2_hdr_end - mb2_hdr_start))                            // checksum
    // End tag
    .word 0                                                                            // type
    .word 0                                                                            // flags
    .long 8                                                                            // size
mb2_hdr_end:

// Boot-time page tables and 32-bit stack (not zeroed by zigStart).
.section .bss.boot, "aw", @nobits
.align 4096
boot_pml4: .skip 4096
boot_pdpt: .skip 4096
boot_pd:   .skip 4096
.align 16
boot_stack32_lo: .skip 4096
boot_stack32_top:

.section .rodata.boot, "a"
.align 8
gdt64:
    .quad 0                              // null
    .quad 0x00AF9A000000FFFF             // 64-bit code segment (L=1, P=1, S=1, type=code)
    .quad 0x00CF92000000FFFF             // data segment (P=1, S=1, type=data writable)
gdt64_end:

.align 2
gdt64_ptr:
    .word gdt64_end - gdt64 - 1
    .quad gdt64

.section .text.boot, "ax"
.global _start
.type _start, @function
.code32
_start:
    cli
    movl $boot_stack32_top, %esp

    // Build identity-mapping page tables.
    // PML4[0] -> PDPT (P|W)
    movl $boot_pdpt, %eax
    orl $0x3, %eax
    movl %eax, boot_pml4

    // PDPT[0] -> PD (P|W)
    movl $boot_pd, %eax
    orl $0x3, %eax
    movl %eax, boot_pdpt

    // Fill PD with 512 2MB pages: PD[i] = (i << 21) | P|W|PS
    movl $boot_pd, %edi
    movl $0x83, %eax                     // present | writable | page-size (2 MB)
    xorl %edx, %edx
1:  movl %eax, (%edi)
    movl %edx, 4(%edi)
    addl $0x200000, %eax
    adcl $0, %edx
    addl $8, %edi
    cmpl $boot_pd + 4096, %edi
    jb 1b

    // CR3 = PML4
    movl $boot_pml4, %eax
    movl %eax, %cr3

    // Ensure SSE is usable (CR0.EM=0, CR0.MP=1) in case the compiler emits SSE
    // in long-mode code paths (Zig's std lib float code does, even if unreached).
    movl %cr0, %eax
    andl $~(1 << 2), %eax                // clear EM
    orl  $(1 << 1), %eax                 // set MP
    movl %eax, %cr0

    // CR4: PAE | OSFXSR | OSXMMEXCPT
    movl %cr4, %eax
    orl $((1 << 5) | (1 << 9) | (1 << 10)), %eax
    movl %eax, %cr4

    // EFER.LME = 1
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr

    // CR0.PG = 1 (this activates long mode)
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    lgdt gdt64_ptr
    ljmp $0x08, $start64

.code64
.global start64
.type start64, @function
start64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    movabsq $__stack_top, %rsp
    xorq %rbp, %rbp

    call zigStart

    // Should never return.
1:  hlt
    jmp 1b

.size _start, . - _start
