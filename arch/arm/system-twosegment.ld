OUTPUT_FORMAT("elf32-littlearm", "elf32-littlearm", "elf32-littlearm")
OUTPUT_ARCH(arm)

ENTRY(_start)
SECTIONS
{
    . = %ROMBASE%;
    __rom_start = .;

    /* text/read-only data */
    .text : {
        KEEP(*(.text.boot.vectab1))
        KEEP(*(.text.boot.vectab2))
        KEEP(*(.text.boot))
        *(.text* .sram.text.glue_7* .gnu.linkonce.t.*)
    }

    .interp : { *(.interp) }
    .hash : { *(.hash) }
    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .rel.text : { *(.rel.text) *(.rel.gnu.linkonce.t*) }
    .rela.text : { *(.rela.text) *(.rela.gnu.linkonce.t*) }
    .rel.data : { *(.rel.data) *(.rel.gnu.linkonce.d*) }
    .rela.data : { *(.rela.data) *(.rela.gnu.linkonce.d*) }
    .rel.rodata : { *(.rel.rodata) *(.rel.gnu.linkonce.r*) }
    .rela.rodata : { *(.rela.rodata) *(.rela.gnu.linkonce.r*) }
    .rel.got : { *(.rel.got) }
    .rela.got : { *(.rela.got) }
    .rel.ctors : { *(.rel.ctors) }
    .rela.ctors : { *(.rela.ctors) }
    .rel.dtors : { *(.rel.dtors) }
    .rela.dtors : { *(.rela.dtors) }
    .rel.init : { *(.rel.init) }
    .rela.init : { *(.rela.init) }
    .rel.fini : { *(.rel.fini) }
    .rela.fini : { *(.rela.fini) }
    .rel.bss : { *(.rel.bss) }
    .rela.bss : { *(.rela.bss) }
    .rel.plt : { *(.rel.plt) }
    .rela.plt : { *(.rela.plt) }
    .init : { *(.init) } =0x9090
    .plt : { *(.plt) }

    /* .ARM.exidx is sorted, so has to go in its own output section.  */
    __exidx_start = .;
    .ARM.exidx : { *(.ARM.exidx* .gnu.linkonce.armexidx.*) }
    __exidx_end = .;

    .rodata : ALIGN(4) {
        __rodata_start = .;
        __fault_handler_table_start = .;
        KEEP(*(.rodata.fault_handler_table))
        __fault_handler_table_end = .;
        *(.rodata .rodata.* .gnu.linkonce.r.*)
    }

    .ctors : ALIGN(4) {
        __ctor_list = .;
        KEEP(*(.ctors .init_array))
        __ctor_end = .;
    }
    .dtors : ALIGN(4) {
        __dtor_list = .;
        KEEP(*(.dtors .fini_array))
        __dtor_end = .;
    }

    /* fake section for .data to anchor off of
     * needed because extra linker scripts tend to insert sections
     * just after .rodata
     */
    .fake_post_rodata : {
        /* end of rodata, start of data area */
        __rodata_end = . ;
        __rom_end = . ;
        __data_start_rom = .;
    }

    /* in two segment binaries, the data starts at the bottom of ram (MEMBASE)
     * bump us forward to the start of ram
     */
    . = %MEMBASE%;

    /* start .data segment, force the physical address to be AT() __data_start_rom */
    .data : AT ( ADDR (.fake_post_rodata) + SIZEOF (.fake_post_rodata) ) ALIGN(4) {
        __data_start = .;
        *(.data .data.* .gnu.linkonce.d.*)
    }

    /* code that is located in ram */
    .sram.text : ALIGN(4) {
        KEEP (*(.sram.text*))
    }

    .got : { *(.got.plt) *(.got) }
    .dynamic : { *(.dynamic) }

    /*
     * extra linker scripts tend to insert sections just after .data,
     * so we want to make sure this symbol comes after anything inserted above,
     * but not aligned to the next section necessarily.
     */
    .fake_post_data : {
        __data_end = .;
    }

    /* uninitialized data (in same segment as writable data) */
    .bss : ALIGN(4) {
        KEEP(*(.bss.prebss.*))
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    }

    _end = .;

    . = %MEMBASE% + %MEMSIZE%;
    _end_of_ram = .;

    /* Strip unnecessary stuff */
    /DISCARD/ : { *(.comment .note .eh_frame) }
}
