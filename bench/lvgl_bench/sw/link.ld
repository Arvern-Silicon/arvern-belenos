/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      link.ld (bench/lvgl_bench)
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * LVGL benchmark bench firmware: code, read-only data (the benchmark's
 * images and fonts) and the .data image in the code memory (4 MB at
 * 0x20000000), .data, .bss (LVGL's pool) and a 32 KB stack in the data
 * memory (1 MB at 0x80000000); both zero-wait (verilog/tb_lvgl_bench.v).
 * No heap: LVGL allocates from its own pool.
 *
 * LVGL is placed first, at fixed addresses: its code from 0x20001000 (every
 * function of LVGL's objects, the whole archive linked, kept whether this
 * build calls it or not) and its read-only data, in their own output
 * section; then the libraries, and the code of the build (main.c, the
 * driver, the glue) last; LVGL's .data and .bss first in the data memory.
 * LVGL's code is then the same bytes at the same address in every persona
 * and option, whatever the size of the code that differs: its loops do not
 * move across the 4-byte fetch words, so the speed-ups compare the same
 * LVGL code (the firmware's size changes LVGL's cycles otherwise, by a few
 * per cent).
 *----------------------------------------------------------------------------*/
ENTRY(_start)

MEMORY
{
    CODE (rx)  : ORIGIN = 0x20000000, LENGTH = 4M
    RAM  (rw)  : ORIGIN = 0x80000000, LENGTH = 1M
}

SECTIONS
{
    .init : {
        KEEP(*(.init))
    } > CODE

    /* LVGL: its code, every function kept, then its read-only data (its own
     * output section, so that its merged strings stay here too) */
    .lvgl ALIGN(4096) : {
        _lvgl_text = .;
        KEEP(*liblvgl.a:*(.text .text.*))
        . = ALIGN(4096);
        *liblvgl.a:*(.rodata .rodata.* .srodata .srodata.*)
        _lvgl_end = .;
    } > CODE

    /* The libraries, then the code that differs from build to build */
    .text ALIGN(4096) : {
        *.a:*(.text .text.*)
        *.a:*(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4096);
        *(.text*)
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(4);
    } > CODE

    .data : {
        . = ALIGN(4);
        *liblvgl.a:*(.data .data.* .sdata .sdata.*)
        . = ALIGN(256);
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
    } > RAM AT > CODE

    .bss (NOLOAD) : {
        . = ALIGN(4);
        _bss_start = .;
        *liblvgl.a:*(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(256);
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    .stack (NOLOAD) : {
        . = ALIGN(16);
        . += 32K;
        _stack_end = .;
    } > RAM

    _end = .;
    end  = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
    }

    __romdatastart    = LOADADDR(.data);
    __datastart       = ADDR(.data);
    __romdatacopysize = SIZEOF(.data);
    __bssstart        = _bss_start;
    __bssend          = _bss_end;
}
