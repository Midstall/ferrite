ENTRY(_start)

/* Bare S-mode kernel loaded by an SBI (Weir). The SBI lives at the low end of
   DRAM (0x8000_0000), so the kernel links at +2 MiB, the conventional
   OpenSBI/Linux split. Weir's ELF loader reads the program headers and copies
   each segment to its p_paddr, so nothing here is position-dependent beyond the
   base. Bare S-mode means PA == VA, identical to the raw M-mode layout. */
SECTIONS {
    . = 0x80200000;
    __kernel_start = .;

    .text : ALIGN(4K) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }

    .bss (NOLOAD) : ALIGN(4K) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
        /* Stack inside the BSS LOAD so its p_memsz reserves it, keeping the SBI's
           handoff (DTB/initrd it placed) clear of the boot stack. */
        . = . + 0x10000;
        __stack_top = .;
    }

    __kernel_end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
