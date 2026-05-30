ENTRY(_start)

SECTIONS {
    . = 0x100000;
    __kernel_start = .;

    /* Multiboot headers must be within first 8 KB (MB1) / 32 KB (MB2). */
    .multiboot1 : ALIGN(4) {
        KEEP(*(.multiboot1))
    }
    .multiboot2 : ALIGN(8) {
        KEEP(*(.multiboot2))
    }

    .text : ALIGN(4K) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata.boot)
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
    }

    /* Boot-time data (page tables, 32-bit stack); not zeroed by zigStart. */
    .bss.boot (NOLOAD) : ALIGN(4K) {
        *(.bss.boot)
    }

    .bss (NOLOAD) : ALIGN(4K) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    . = ALIGN(16);
    . = . + 0x10000;
    __stack_top = .;

    __kernel_end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
