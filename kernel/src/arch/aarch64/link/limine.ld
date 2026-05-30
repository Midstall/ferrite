OUTPUT_FORMAT(elf64-littleaarch64)
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
        KEEP(*(.text.smp))
        *(.text .text.*)
    } :text

    . = ALIGN(0x800);

    /* VBAR_EL1 requires 0x800 alignment. */
    .vectors : {
        KEEP(*(.vectors))
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

    /* .got must precede .bss; otherwise FileSize == MemSize for the data
       segment, which bloats the ELF by the stack reservation and trips Limine. */
    .got : {
        *(.got)
        *(.got.plt)
    } :data

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
        /* Stack inside .bss so it lives in a mapped PT_LOAD segment. */
        . = ALIGN(16);
        . = . + 0x40000;
        __stack_top = .;
    } :data

    __kernel_end = .;

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
        *(.ARM.attributes)
    }
}
