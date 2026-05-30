ENTRY(_start)

SECTIONS {
    . = 0x100000;
    __kernel_start = .;

    .multiboot : ALIGN(4) {
        KEEP(*(.multiboot1))
        . = ALIGN(8);
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

    .bss (NOLOAD) : ALIGN(4K) {
        *(.bss.boot)
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
        /* Boot stack lives inside the BSS LOAD segment so its p_memsz
           covers it. Without this GRUB drops the initrd module on top
           of the stack region. */
        . = . + 0x10000;
        __stack_top = .;
    }

    __kernel_end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
