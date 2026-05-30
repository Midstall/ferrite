ENTRY(_start)

/* QEMU virt loads Linux-format aarch64 images at 0x40080000. */
SECTIONS {
    . = 0x40080000;
    __kernel_start = .;

    .text : ALIGN(4K) {
        KEEP(*(.text.boot))
        KEEP(*(.text.smp))
        *(.text .text.*)
    }

    /* VBAR_EL1 requires 0x800 alignment. */
    .vectors : ALIGN(0x800) {
        KEEP(*(.vectors))
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
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
        *(.ARM.attributes)
    }
}
