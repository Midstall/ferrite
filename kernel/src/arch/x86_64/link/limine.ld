OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS {
    text    PT_LOAD;
    rodata  PT_LOAD;
    data    PT_LOAD;
}

SECTIONS {
    . = 0xffffffff80000000;
    __kernel_start = .;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
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

    /* All RW data in one PT_LOAD, .bss last so its NOBITS reduces filesz.
     * Limine maps PT_LOAD writable per p_flags=RW; this layout keeps .data
     * and .bss in the same segment but with filesz < memsz, so the BSS
     * portion is zero-allocated by Limine (not file-backed) and the .data
     * portion comes from file content. */
    .data : {
        *(.data .data.*)
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
    }
}
