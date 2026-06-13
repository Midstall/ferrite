/* Flat layout for a 32-bit x86 vmboot guest: linked absolute at the guest base
   (0x40000000, matching vmboot's GUEST_BASE), objcopy'd to a raw binary. No PIC,
   so data references resolve to the load address. _start is first. */
ENTRY(_start)

SECTIONS {
    . = 0x40000000;
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : { *(.rodata .rodata.*) }
}
