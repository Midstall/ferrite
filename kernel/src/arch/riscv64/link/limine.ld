OUTPUT_FORMAT(elf64-littleriscv)
ENTRY(_start)

PHDRS {
    text    PT_LOAD;
    rodata  PT_LOAD;
    data    PT_LOAD;
}

SECTIONS {
    . = 0xFFFFFFFF80000000;
    __kernel_start = .;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
        *(.text.trap)
    } :text

    . = ALIGN(4K);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    .limine_requests_start_marker : {
        KEEP(*(.limine_requests_start_marker))
    } :rodata

    .limine_requests : {
        KEEP(*(.limine_requests))
    } :rodata

    .limine_requests_end_marker : {
        KEEP(*(.limine_requests_end_marker))
    } :rodata

    . = ALIGN(4K);

    .data : {
        *(.data .data.*)
    } :data

    /* .got/.sdata must precede .bss; otherwise the linker file-fills the BSS,
       ballooning the ELF and tripping Limine. */
    .got : {
        *(.got)
        *(.got.plt)
    } :data
    .sdata : {
        *(.sdata .sdata.*)
    } :data

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
        . = ALIGN(16);
        . = . + 0x40000;
        __stack_top = .;
    } :data

    __kernel_end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
