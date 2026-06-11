/* Flat layout for an RV64 vmexec guest: _start at offset 0. Position
   independent (auipc/la), so it runs at whatever base vmexec loads it to. */
ENTRY(_start)

SECTIONS {
    . = 0;
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : { *(.rodata .rodata.*) }
}
