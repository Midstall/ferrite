/* ESP32-C6 kernel linker - XIP layout.
 *
 *   .text + .rodata -> IROM virtual (0x42000000+). Lives in flash;
 *                     CPU fetches via cache, costs zero SRAM.
 *   .data + .bss   -> IRAM (0x40800000+). Lives in SRAM. The initial
 *                     .data values are stored in the flash image
 *                     (LMA in IROM) and copied to IRAM by the
 *                     bootloader. */

ENTRY(_start)

MEMORY {
    iram (rw)  : ORIGIN = 0x40800000, LENGTH = 376K
    irom (rx)  : ORIGIN = 0x42000000, LENGTH = 4M
}

SECTIONS {
    .text : ALIGN(4) {
        KEEP(*(.text.boot))
        *(.text .text.*)
        /* ESP32-C6 mtvec requires 256-byte BASE alignment in CLIC
         * vectored mode (not the 4-byte minimum the riscv-priv spec
         * allows). The vector table sits in `.trap`. */
        . = ALIGN(256);
        KEEP(*(.trap))
    } > irom

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > irom

    /* VMA in IRAM (where the kernel reads/writes), LMA in IROM (where
     * the flash image stores the init values). Bootloader copies one
     * to the other. */
    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > iram AT > irom
    __data_load_start = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
        /* 16 KB boot stack. */
        . = . + 0x4000;
        __stack_top = .;
    } > iram

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
