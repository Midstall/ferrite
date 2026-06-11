/* Flat layout for a vmexec guest image: _start at offset 0, the EL1 vector
   table at +0x800. objcopy'd to a raw binary and loaded at the guest base. */
ENTRY(_start)

SECTIONS {
    . = 0;
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : { *(.rodata .rodata.*) }
    .vectors 0x800 : { KEEP(*(.vectors)) }
}
