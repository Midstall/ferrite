/* ESP32-C6 2nd-stage bootloader linker. Loaded by ROM into upper SRAM
 * at 0x4085C000, out of the way of the lower 376 KB reserved for
 * kernel IRAM. One-shot: after handoff to the kernel its SRAM is free
 * for reuse. */

ENTRY(_start)

MEMORY {
    iram (rwx) : ORIGIN = 0x4085C000, LENGTH = 144K
}

SECTIONS {
    . = 0x4085C000;
    __bootloader_start = .;

    .text : ALIGN(4) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > iram

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > iram

    .data : ALIGN(4) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > iram

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
        . = . + 0x4000;
        __stack_top = .;
    } > iram

    __bootloader_end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
