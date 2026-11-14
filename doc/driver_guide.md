<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos C driver guide

*Bare-metal C driver for the Belenos graphic controller: register definitions, a small
API for the controller, the GPU and the built-in display drivers, and panel drivers.*

*For the driver's users: the build, porting, conventions, the API, display bring-up and
examples. The files are listed in [sw/README.md](../sw/README.md#layout). The hardware is
described in [integration_guide.md](integration_guide.md); the register-level programming
model in [programming_model.md](programming_model.md), [register_map.md](register_map.md)
and [gpu_commands.md](gpu_commands.md).*

---

## Table of Contents

1. [Build](#1-build)
2. [Porting](#2-porting)
    - [2.1 Platform header (optional)](#21-platform-header-optional)
    - [2.2 Code size](#22-code-size)
3. [Using it](#3-using-it)
    - [3.1 Quick start](#31-quick-start)
4. [Conventions](#4-conventions)
    - [4.1 Interface policy](#41-interface-policy)
5. [Concurrency](#5-concurrency)
6. [Recovery](#6-recovery)
7. [API summary](#7-api-summary)
8. [Bring-up](#8-bring-up)
    - [8.1 DBI panel (ILI9341)](#81-dbi-panel-ili9341)
    - [8.2 DPI panel](#82-dpi-panel)
    - [8.3 HDMI monitor](#83-hdmi-monitor)
9. [Examples](#9-examples)
10. [LVGL](#10-lvgl)
11. [Adding a panel driver](#11-adding-a-panel-driver)
12. [Host tests](#12-host-tests)
- [See Also](#see-also)

---

## 1. Build

Add the sources and the two include directories to the application build:

```make
BLNS_SW   = <path>/arvern-belenos/sw
SRCS     += $(BLNS_SW)/src/belenos.c $(BLNS_SW)/src/blns_gpu.c
SRCS     += $(BLNS_SW)/src/blns_dbi.c $(BLNS_SW)/panel/ili9341.c        # a DBI panel
SRCS     += $(BLNS_SW)/src/blns_dpi.c $(BLNS_SW)/src/blns_ddc.c \
            $(BLNS_SW)/src/blns_hotplug.c                               # a DPI panel or HDMI
CFLAGS   += -I$(BLNS_SW)/include -I$(BLNS_SW)/panel -ffunction-sections -fdata-sections
LDFLAGS  += -Wl,--gc-sections
```

The library is C11 (the header also compiles as C++11), needs no `malloc`, no libc
beyond `<stdint.h>`, `<stdbool.h>` and `<stddef.h>` (the compiler may call `memset`
and `memcpy`), no 64-bit arithmetic, and builds for RV32E. With `--gc-sections` an
application only pays for the functions it calls. Two calls reach into the DPI files:
`blns_gpu_present_copy` calls `blns_dpi_copy_now` (`blns_dpi.c`) and `blns_dpi_picture`
the EDID read (`blns_ddc.c`); a DBI build that presents by copy links `blns_dpi.c` too,
or states `BLNS_HW_DPI 0` in a [platform header](#21-platform-header-optional). Initialise every structure of the API with designated
initialisers (or zero it): they grow at the end, and a zero field keeps the earlier
behaviour.

---

## 2. Porting

What an integrator provides:

- **Two base addresses**: the 4 KB register port and the VRAM window
  (`blns_config_t`). The window must be uncached, and strongly ordered with the
  register port: a list written through the window must be complete before the
  `CALL` that the register port takes afterwards (and an upload before the GPU copy
  of it). On one AHB-Lite path (aRVern) the order holds by itself; behind a posted
  bridge or a write buffer, define `BLNS_WMB()` (e.g. `fence w,w` on RISC-V) before
  including `belenos.h`: the driver calls it before each `CALL` and after
  `blns_vram_write_rect`.
- **The Belenos clock** (`hclk_hz`), used only by `blns_refresh_rate`.
- **Delays**: a panel driver's `delay_ms`, and the quarter-bit delay of the HDMI DDC
  (`quarter`, 2.5 µs for 100 kHz).
- **Waits**: optionally a wait hook (`blns_config_t.wait_hook`), called on every poll
  of every wait, and a poll limit (`wait_polls`): see [Conventions](#4-conventions).
- **The interrupt line**, if the application uses interrupts (`blns_irq_service` in
  the handler).
- **A little-endian CPU** for the 16-bit pixel views (`blns_vram16`) and the immediate
  data packing; the VRAM itself is little-endian.
- **32-bit registers**: pixel addresses are `uint32_t` (at most `VRAM_AW + 5` bits),
  bases `uintptr_t`; the driver never truncates a pointer.

The presets `BLNS_DPI_480X272` / `BLNS_DPI_800X480` and the hot-plug timing defaults
are examples from the boards they were tuned on; `CLK_DIV` depends on the build's
pixel-domain clock.

### 2.1 Platform header (optional)

By default the driver detects every optional feature at run time (`BLNS_CFG`,
`BLNS_CFG2`, `DPI_CAPS`, into `blns_t.caps`), and an application links the code of
every call it makes, whatever the bitstream has. A board whose Belenos configuration
is fixed states it in a platform header, which its build names explicitly:

```make
CFLAGS += -I<bsp> -DBLNS_PLATFORM_HEADER='"myboard_blns.h"'   # every file, the driver's included
```

```c
/* myboard_blns.h */
#define BLNS_HW_GPU         1      /* present: the driver does not test caps           */
#define BLNS_HW_GPU_XY      1
#define BLNS_HW_GPU_REMAP   0      /* absent: inline BLNS_ERR_ABSENT, no code compiled */
#define BLNS_HW_DBI         0
/* not defined: detected at run time, as without a header                              */
```

Each feature (`GPU`, `GPU_XY`, `GPU_GRAD`, `GPU_BLEND`, `GPU_TRI`, `GPU_REMAP`,
`GPU_MPLANE`, `GPU_IMM`, `GPU_LINE`, `GPU_BILINEAR` (needs `GPU_XY`), `LUT`, `LUT2`, `DPI`, `DBI`, `DPI_DDC`,
`DPI_ISLAND`, `DPI_AUDIO`, `CURSOR`) has three states:

| `BLNS_HW_<F>` | Effect |
|---|---|
| `1` | present: the caps test folds away |
| `0` | absent: the feature's calls are inline returns of `BLNS_ERR_ABSENT` (or `BLNS_OK` for an `enable = false`), their implementation and its helpers are not compiled, and the shared code's branches for it fold away; a feature whose parent is `0` is `0` too |
| not defined | run-time detection through `caps`, exactly as without a header |

Any other value, or a contradiction (`BLNS_HW_DBI` and `BLNS_HW_DPI` both `1`, a child
set to `1` under a parent set to `0`) is a compile error. `BLNS_HAS(dev, F)` is the
one place the three states are resolved; the driver tests every feature through it,
and an application may too (`if (BLNS_HAS(&blns, GPU_XY)) ...`).

`blns_init` compares every feature the header states with the hardware and returns
`BLNS_ERR_CONFIG` on a difference, before writing anything (`dev->caps` then holds what
the hardware has): a firmware and a bitstream that disagree stop at start-up instead
of drawing wrongly. The macros never change a structure's layout, so a file built
without the header still works (it only detects at run time). A firmware that runs on
several bitstreams states only what they share (the Tang Console's one firmware runs
on the RGB panel and the HDMI bitstreams: the HDMI options stay at run time).
`BLNS_HW_GPU 0` keeps the GPU calls' symbols, each reduced to a few-byte return of
`BLNS_ERR_ABSENT`.

The header is named, never found by its name on the include path, so a build is
configured only where its Makefile says so, and the same set reaches every file. The
arvern-belenos `check_deployed.py` compares the arvern-soc board headers
(`bsp/tang_blns.h`, `bsp/de0_blns.h`) with the board tops' Belenos parameters.

### 2.2 Code size

The six driver objects of `src/` (an application links only what it calls), compiled
without a platform header and with the header of each
[persona](integration_guide.md#21-personas) (`include/persona/blns_<persona>.h`: the GPU,
LUT and cursor features the persona builds; the display driver and the HDMI options
left to run-time detection, as they follow `DIF_TYPE`, the SoC's choice, so `blns_dpi.c`,
`blns_dbi.c`, `blns_ddc.c` and `blns_hotplug.c` do not change with the persona). A
board's header includes its persona's and states its display:

```c
/* myboard_blns.h */
#include "persona/blns_classic.h"
#define BLNS_HW_DPI 1
#define BLNS_HW_DBI 0
```

<!-- driver_size:begin table -->

Bytes of each driver object (text; none has data or bss), with `riscv-none-elf-gcc` 15.2.0,
`-Os -march=rv32emc_zbb_zba_zbs_zicsr_zcb -mabi=ilp32e -ffunction-sections`:

| Platform header | `belenos.c` | `blns_gpu.c` | `blns_dpi.c` | `blns_dbi.c` | `blns_ddc.c` | `blns_hotplug.c` | Total |
|---|---:|---:|---:|---:|---:|---:|---:|
| none (run-time detection) | 3 342 | 17 826 | 2 272 | 652 | 1 396 | 554 | 26 042 |
| light (`persona/blns_light.h`) | 2 196 | 1 068 | 2 272 | 652 | 1 396 | 554 | 8 138 |
| essential (`persona/blns_essential.h`) | 2 320 | 8 010 | 2 272 | 652 | 1 396 | 554 | 15 204 |
| classic (`persona/blns_classic.h`) | 3 202 | 15 804 | 2 272 | 652 | 1 396 | 554 | 23 880 |
| performance (`persona/blns_performance.h`) | 3 202 | 16 124 | 2 272 | 652 | 1 396 | 554 | 24 200 |
| ultra (`persona/blns_ultra.h`) | 3 198 | 16 996 | 2 272 | 652 | 1 396 | 554 | 25 068 |

<!-- driver_size:end table -->

`doc/tools/driver_size.py --update` regenerates the persona headers (from the personas of
`sim/rtl_sim/bin/rtl_configs.py`) and this table (`--check`: whether they are current; it
needs the cross compiler).

The set-up and recovery calls are compiled for size whatever the build's optimisation
level (`cold`).

---

## 3. Using it

Every program starts the same way: `blns_init`, the depth and size of the frame, the
frame pointer, then the display's own bring-up, which depends on the build's display
driver (`blns_t.caps.dif_type`): one of the three recipes of [Bring-up](#8-bring-up).

### 3.1 Quick start

A 320 × 240 RGB565 frame at pixel address 0, drawn through the VRAM window, then shown;
`display_start()` is one of the [bring-up](#8-bring-up) recipes:

```c
#include "belenos.h"

#define BLNS_BASE  0x10050000u                   /* the board's addresses and clock */
#define VRAM_BASE  0x82000000u
#define CLK_HZ     50000000u

blns_t blns;                                     // the handle: one per Belenos
blns_status_t display_start(void);               // DBI panel, DPI panel or HDMI monitor

blns_status_t video_init(void)
{
    const blns_config_t cfg = { .reg_base = BLNS_BASE, .vram_base = VRAM_BASE, .hclk_hz = CLK_HZ };
    blns_status_t st = blns_init(&blns, &cfg);   // checks BLNS_ID, reads BLNS_CFG / CFG2
    if (st != BLNS_OK)
        return st;
    blns_set_mode(&blns, BLNS_BPP_16);           // CTRL.GFX_MODE
    blns_set_size(&blns, 320, 240);              // DISP_SIZE
    blns_set_frame(&blns, 0, 0);                 // FRAME0_PTR: frame at pixel address 0
    blns_select_frame(&blns, 0);                 // FRAME_SEL: the display shows frame 0

    volatile uint16_t *fb = blns_vram16(&blns);  // draw through the VRAM window
    for (uint32_t y = 0; y < 240; y++)
        for (uint32_t x = 0; x < 320; x++)
            fb[blns_pixel_addr(&blns, 0, x, y)] = (uint16_t) ((x / 10u) << 11 | (y / 4u) << 5);

    blns_gpu_enable(&blns, true);                // the GPU (when built), every setting reset
    return display_start();
}
```

The library calls are thin: each names the register it writes. The
[programming model](programming_model.md) explains the registers behind each step,
and the [GPU command set](gpu_commands.md) the faster ways to draw.

---

## 4. Conventions

- **Device handle.** Every call takes the `blns_t` filled by `blns_init()`; the library
  keeps no global state, so several Belenos instances can coexist. The handle records
  the build configuration (`caps`: frame pointers, LUT banks, GPU and FIFO depth,
  the optional GPU features, display driver type, `DIM_W`)
  and the current mode and size.
- **Addresses.** `blns_pa_t` is a pixel address (pixel n of the VRAM at the current
  depth): surfaces, frames, spans, glyph sources. `blns_wa_t` is a 32-bit word address:
  command lists, the remap table. `blns_ba_t` is a bit address (a 1-bpp pixel address):
  the mask plane. An alpha plane is given by a byte address (`uint32_t`, an 8-bpp pixel
  address); `blns_alpha_of` gives the alpha of a pixel of an image. `blns_vram_ptr` / `blns_vram_pa` / `blns_vram_wa` / `blns_vram_ba` convert between
  them and window pointers; `blns_surf_rect` gives the first pixel visited of a
  mirrored rectangle.
- **Status codes.** Every call that can fail returns `blns_status_t` (a `void` call has
  no precondition): `BLNS_OK`, or an argument out of range for this build
  (`BLNS_ERR_PARAM`), a feature that is not built (`BLNS_ERR_ABSENT`: nothing is
  sent, so a graphics library can fall back to its own software renderer; also every
  DBI call on a DPI build and the reverse), a GPU that is disabled or stopped on an
  invalid command (`BLNS_ERR_GPU`, so that no call spins on a FIFO that cannot
  drain), a call out of order or a wait that needs the refresh to run
  (`BLNS_ERR_STATE`), no answer on the HDMI DDC
  (`BLNS_ERR_BUS`), no Belenos at the base address (`BLNS_ERR_ID`), a command list
  that overflowed (`BLNS_ERR_FULL`), a wait ended by the wait hook or the poll limit
  (`BLNS_ERR_TIMEOUT`), no room in non-blocking mode (`BLNS_ERR_BUSY`), a platform
  header that does not match the hardware (`BLNS_ERR_CONFIG`, from `blns_init`), work
  dropped by a recover before a fence (`BLNS_ERR_DROPPED`, from
  `blns_gpu_fence_status` and `blns_gpu_wait_fence`). `BLNS_ERR_GPU` also covers a
  recover requested while a call waits for FIFO room (that call is not sent; the next
  one performs the recover and is sent: [Recovery](#6-recovery)); `BLNS_ERR_STATE` a
  session or pointer not set and a fence tag no fence will reach.
- **Checked before sending.** A pitch of 0 is replaced by the display pitch at the
  call (`blns_display_pitch`: `REFR_PITCH` when set, else the frame width, halved with
  pixel doubling), so a later mode or size change does not move a queued drawing. This
  is the driver's rule: the GPU's own pitch 0, in words pushed raw, is the frame width
  and ignores `REFR_PITCH` ([commands](gpu_commands.md#7-commands)). A
  width or height of 0 draws nothing; above `caps.size_max` (2^min(`DIM_W`, 14) − 1)
  it is `BLNS_ERR_PARAM`. x/y positions outside −2048 … 2047 and vertices and line end
  points outside 16 bits return `BLNS_ERR_PARAM` instead of wrapping (clip to the
  visible area first).
  The palette arithmetic (gradient, texture shade, the 2/4/8 bpp `EXPAND` ramp) adds
  to the pixel value, so it is refused at 16 bpp (`BLNS_ERR_PARAM`).
- **Sessions.** `blns_gpu_*_begin` sets a destination and the session values of the
  per-item calls that follow (span colour, glyph size and colours, texture);
  `blns_gpu_*_set` (and `blns_gpu_colour_set`) set session values without a
  destination. The per-item calls (`span`, `expand`, `tex_span` and their `_xy`
  forms, `fill_xy`, `tri_xy`, the lines) send again whatever a fill, a copy or a raw
  push changed in between: a fill between two glyphs is safe. A copy or blit with op 15
  (`BLNS_ROP_FILL_IF_S`, a one-colour silhouette) writes the session colour of
  `blns_gpu_colour_set` (sent only when the GPU's fill colour differs), never the colour
  an earlier call happened to leave.
- **No call draws with state the API never set.**
  - Ops 13–15 compare S with a transparent colour on every `EXEC`: a blit sends
    `blns_blit_t.transparent` (0 by default) whether `transp` is set or not, and a fill or
    a plain copy, which take none, send 0, the same value as a zero `blns_blit_t` (a
    session colour would make the result depend on an earlier call). Sent only
    when the GPU's differs.
  - The remap table, the mask plane and the alpha plane are pointers the GPU keeps: a
    blit, expansion, texture, `remap_rect` or `remap_tri_xy` that uses one before
    `blns_gpu_remap_table` / `blns_gpu_mask_plane` / `blns_gpu_alpha_plane` returns
    `BLNS_ERR_STATE` with nothing sent; an expansion or texture session begun with a
    remap or `src_alpha` is checked at each of its draws, as the session outlives the
    pointer. `blns_gpu_alpha_plane` is always sent (2 words). The pointers are unknown again after `RESET_STATE`
    (`blns_gpu_enable(true)`, `blns_gpu_reset_state`), after `blns_gpu_recover` (a
    `SET_AUX` still in the FIFO is flushed) and after `blns_gpu_forget`, and from
    `blns_init` on; `GPU_EN = 0` keeps them. A list
    recorded without `BLNS_LIST_INHERIT` starts with them unknown and sets its own;
    what a list sets or resets applies to the caller at each `blns_gpu_list_call`.
    `remap_rect` and `remap_tri_xy` (a FILL with `REMAP` `DST`) are refused at 16 bpp
    (`BLNS_ERR_PARAM`: the remap has no effect there, the GPU would fill).
  - The per-item calls need their session: `span` after `span_begin`; the
    address-mode `expand` and `expand_imm` after `expand_begin`, and `tex_span` after
    `tex_begin` (they need its destination pitch); `expand_xy` / `text_xy` after
    `expand_begin` or `_set`; `tex_shade`, `tex_step`, `texrect_xy`, `tritex_xy` after
    `tex_begin` or `_set`; else `BLNS_ERR_STATE`. Each session keeps its own
    destination pitch, and a session call that does not return `BLNS_OK` changes no
    session. Sessions are the driver's and survive recover, enable and lists.
  - Lines: ops 13–15 compare the line colour with `SET_TRANSP`, which is `bg` with
    `opaque` (the gap colour) and 0 otherwise, sent only when the GPU's differs. The
    pen is tracked like the settings above: `LINE_PEN` is sent only when a line does
    not start where the last one ended, so a connected segment costs 2 words; it is
    unknown after a recover, `blns_gpu_forget`, a raw push and around lists, and
    (0, 0) after `RESET_STATE`. The pattern phase is the GPU's (0 after every
    flush); `phase_reset` sets it on purpose, and a list that wants a known rhythm
    sets it on its first line. Lines refuse address mode: before
    `blns_gpu_xy_begin`, `BLNS_ERR_STATE`.
  - The blend rule (`blns_gpu_blend_rule`: `BLNS_MIX_ROUND`, the reset, or `BLNS_MIX5`,
    LVGL's) is a session setting of the driver: nothing is pushed by the call, the rule
    goes with the next `SET_ALPHA` word (`blns_gpu_alpha`). It survives a recover and
    lists, and is back to `BLNS_MIX_ROUND` after `blns_gpu_reset_state` and
    `blns_gpu_enable(true)`. Without blending `BLNS_MIX_ROUND` returns `BLNS_OK`,
    `BLNS_MIX5` `BLNS_ERR_ABSENT`.
  - The texture filter (`blns_tex_t.bilinear`, `border_transparent`) goes with the
    texture: `SET_AUX` `TEX_FILTER` is sent by `blns_gpu_tex_begin` / `_set` when it
    differs from the GPU's or is unknown. `bilinear` without `caps.gpu_bilinear` is
    `BLNS_ERR_ABSENT` (below 16 bpp the GPU samples the nearest texel), and so is
    `border_transparent` without `caps.gpu_blend`; `border_transparent` without `bound`
    is `BLNS_ERR_PARAM`. `src_alpha` with `mplane` or the immediate source is
    `BLNS_ERR_PARAM`.
  - Everything else is either sent with each call (vertices, UV and steps of texrect
    and triangles, sizes, destinations, the source format of an immediate copy, the
    line pattern) or a mode with a defined reset value that a program sets on purpose
    (clip window, gradient, alpha, line pattern: reset by `blns_gpu_enable(true)` and
    at the start of a list).
- **What `blns_init` keeps.** It resets the refresh, the interrupts, the GPU (off),
  orientation, frame pointer 0, the LUT and `REFR_PITCH`; it keeps the depth and the
  display size, read back into the handle, and keeps the DPI timing and the HDMI link
  running, so a program started by another one does not blank the monitor.
  `blns_gpu_enable(dev, true)` resets every GPU setting (`RESET_STATE`): clip,
  gradient, alpha and texture of the previous program do not leak in.
- **Waiting.** Waits poll status bits and leave `IRQ_FLAG` alone (the frame waits
  count `FRAME_NUM`, so any number of them coexist, and work with the DPI driver,
  which needs no refresh timer). Each poll calls the wait hook of `blns_config_t`
  (service audio, USB or hot-plug, yield to an RTOS); the hook returning true, or
  `wait_polls` polls without progress (words of a long push sent, `GPU_FENCE`
  moving), ends the wait with `BLNS_ERR_TIMEOUT`. `blns_gpu_wait_refresh` refuses
  (`BLNS_ERR_STATE`) when no frames flow, since the GPU would wait for ever; the frame
  waits end (`BLNS_ERR_STATE`) when frames stop flowing. `GPU_STAT.ERR` is tested where
  a call waits for FIFO room (`BLNS_ERR_GPU`): a call whose words fit pushes them into
  the stopped FIFO and returns `BLNS_OK`, the recover drops them, and the fences tell
  ([Recovery](#6-recovery)). A timeout never cuts a helper's command:
  - A GPU call that fits the FIFO waits for room for all its words before the first
    one: a timeout sends nothing.
  - A helper longer than the FIFO (a textured triangle or an affine blit sending every
    setting again can exceed 16 words; in an 8-word FIFO outlines, blits, triangles and
    textured spans too) goes command by command as room appears, each command with its
    operand, `SET_SRC IMM` with its `EXEC`. A timeout returns between two commands: the
    stream is in step, the next call sends every setting again, no recover. The
    commands sent run: the call's `EXEC` is its last command, so nothing is drawn,
    except an outline, which may have some edges drawn.
  - Immediate data (`blns_gpu_blit_imm`, `blns_gpu_expand_imm`) goes word by word once
    its `EXEC` is sent: a timeout (or a GPU error) in it discards the rectangle
    (`blns_gpu_discard`: `GPU_CTRL.DISCARD`, the GPU abandons it where the data stop, the
    pixels already drawn stay) and returns `BLNS_ERR_TIMEOUT`; the stream is in step,
    the work queued before runs, no recover.
  - A raw `blns_gpu_push` longer than the FIFO goes word by word (the driver does not
    parse raw words: a call may start or end inside a command): a timeout in it is
    discarded the same way (the command it cut is dropped by the GPU).
- **Non-blocking mode.** `blns_set_nonblocking(dev, true)`: a GPU call that does not
  find room for all its words, and a DPI setter while an update is pending, return
  `BLNS_ERR_BUSY` with nothing sent; `blns_gpu_space` tells the free FIFO words. A
  call longer than the FIFO needs it empty, then goes on as when blocking (a timeout
  then as above). A game queues a present (`blns_gpu_present_copy`) and goes on with
  CPU work instead of blocking behind the frame end once the FIFO is full.
- **Fences and lists.** Fences are `FENCE AUTO` (`GPU_FENCE` + 1 when reached): the
  driver predicts the tags, also for fences recorded in a list and replayed by each
  call, so `GPU_FENCE` never goes back. `blns_gpu_list_call` pushes `CALL` and a fence:
  `list->tag` (and `blns_gpu_list_busy`) tells when the GPU is out of the list.
- **Hot paths.** Pixels go through the VRAM window pointers (`blns_vram8/16/32`,
  `blns_vram_write_rect`). The per-item GPU calls (`span`, `span_xy`, `fill_xy`,
  `expand`, `expand_xy`, `tex_span`) are inline: with the session in place and the
  FIFO room counted they store their words straight into `GPU_CMD` (about 35–45
  instructions with `-Os`); the batches
  (`blns_gpu_spans`, `blns_gpu_fills_xy`, `blns_gpu_text_xy`) loop over them. A whole
  call (`blns_gpu_fill`, `copy`) costs about 120–140 instructions; `GPU_STAT` is read
  once per FIFO-full and the enable bit is cached. Build note: `-O2` (or
  `-msave-restore` off) on the application's hot files helps more than anything in the
  driver.
- **Platform services.** See [Porting](#2-porting).

### 4.1 Interface policy

During the 0.x previews the interface may change from one release to the next; the
[changelog](../CHANGELOG.md) lists each change. From 1.0.0, within a major version:
source compatibility, not binary: rebuild the driver with the application (as every
build does). Structures grow only at the end and a zero field keeps the earlier
behaviour, so designated initialisers keep compiling. New calls and status codes may
be added; existing names and meanings stay.

---

## 5. Concurrency

One context owns a `blns_t`: every call that takes a non-`const` handle runs in that
context only, except the calls of this table, which are safe from any context (an
interrupt handler, another task):

| Call | Why |
|---|---|
| `blns_irq_status`, `blns_irq_clear`, `blns_irq_service` | registers only (`irq_service` requests a recover on `GPU_ERR`) |
| `blns_gpu_recover_request` | sets a flag: the owner performs the recover at its next GPU call |
| `blns_gpu_fence_done`, `blns_gpu_list_busy`, `blns_gpu_fifo_low` | one register read |
| `blns_gpu_fence_status` | register reads (from another context the result can lag the owner's last recover) |
| `blns_frame_num`, `blns_frame_abandoned`, `blns_flip_done`, `blns_refresh_running`, `blns_frames_flowing` | register reads |
| `blns_dpi_scan_line`, `blns_dpi_present` | register reads |

`blns_gpu_enable(false)` and `blns_gpu_discard` from another context break the stream
(the next word pushed is decoded as a command, or a whole command is dropped). For
interrupt-driven waits enable `BLNS_IRQ_GPU_FENCE`, `BLNS_IRQ_REFR_DONE` or
`BLNS_IRQ_GPU_FIFO_LOW`, call `blns_irq_service` in the handler, and let the wait hook
sleep until it has run. `blns_gpu_wait_space(dev, words)` sets `GPU_FIFO_LOW.THRESH`
to `words − 1` before its first hook call (the write re-arms the event: no lost
wake-up), so such a hook wakes when the words fit; it writes the threshold of
`blns_gpu_fifo_low_set` back at the end. `blns_gpu_fifo_low_set` is the raw threshold
for a producer that manages the interrupt itself (half the FIFO after `blns_init`,
kept by `blns_gpu_enable` and the recover).

---

## 6. Recovery

A GPU that stops on a refused command (`GPU_STAT.ERR`), or `GPU_EN = 0`, loses the work
queued behind it (a raw push or immediate data cut by a timeout loses only the command
it cut: the driver discards it at once, [waiting](#4-conventions)). The recover puts
the stream back in order, and the fences tell which work was lost:

- **The owner recovers.** `blns_gpu_recover` runs in the owner's context: one
  `GPU_CTRL` write, `ABORT | CLEAR_ERR | DISCARD` (whatever a cut push left owed, an
  operand or immediate data, is dropped with the rest; no `GPU_EN` pulse), and every
  setting sent again from the next call on (the remap table and the mask plane must be
  set again). `blns_gpu_error` reads the cause first, when it matters.
- **Any other context requests it.** An interrupt handler on `GPU_ERR` or a watchdog
  calls `blns_gpu_recover_request`, or `blns_irq_service` with `BLNS_IRQ_GPU_ERR_Msk` in
  its mask: the owner performs the recover at the start of its next GPU call (the inline
  fast paths included), which is then sent, so a FIFO it is pushing is never flushed
  under it. Its waits end: a call waiting for FIFO room returns `BLNS_ERR_GPU` (what a
  call longer than the FIFO sent is dropped by the recover), `blns_gpu_wait` and `blns_gpu_wait_fence` perform the recover.
- **The fences tell.** `blns_gpu_fence_status(dev, tag)` says what became of the work
  pushed before a fence (or a list's `list->tag`); `blns_gpu_wait_fence` waits for the
  first status other than `BLNS_ERR_BUSY`:

  | Status | The work before the fence |
  |---|---|
  | `BLNS_OK` | drawn: the fence was reached |
  | `BLNS_ERR_BUSY` | not reached yet, the GPU runs |
  | `BLNS_ERR_GPU` | not reached, and will not be: the GPU stopped on an error, is disabled, or a recover is requested; after the recover it reads `BLNS_ERR_DROPPED` |
  | `BLNS_ERR_DROPPED` | dropped by a recover (or `GPU_EN = 0`): it may be partly drawn |
  | `BLNS_ERR_STATE` | the GPU is idle and the tag unreached: a tag no fence will reach (raw fences, a list called by other means) |

  The work a fence covers starts after the fence before it: the first fence pushed after
  a recover that dropped unfenced work reads `BLNS_ERR_DROPPED` too. A tag carries the
  stream it was pushed in (bits [31:24]) and the driver moves `GPU_FENCE` past the
  dropped tags, so a tag is never reused and `blns_gpu_fence_done` /
  `blns_gpu_list_busy` read done. The status is exact for a fence pushed before at most
  one loss; one pushed before two or more reads `BLNS_ERR_DROPPED` even when it was
  reached (conservative).
- **Raw pushes.** `blns_gpu_push` (raw words) makes the helpers re-send every setting and
  the pointers. A `FENCE` pushed raw, or a list called by other means than
  `blns_gpu_list_call`, moves `GPU_FENCE` behind the driver's back and breaks its tag
  count: the driver's own fences may then read done too early. Push fences with
  `blns_gpu_fence` only.

A renderer keeps the tag of each batch and draws it again when it was dropped (the
[LVGL driver](lvgl_guide.md#5-faults) does):

```c
#include "belenos.h"

extern blns_t blns;
void draw_batch(void);                             // the application's GPU calls

void belenos_irq_handler(void)                     // the platform's handler of irq_o
{
    (void) blns_irq_service(&blns, BLNS_IRQ_GPU_ERR_Msk);   // a GPU error: recover requested
}

void draw_frame(void)                              // blns_irq_enable(&blns, BLNS_IRQ_GPU_ERR_Msk) once
{
    uint32_t      tag;
    blns_status_t st;
    draw_batch();
    st = blns_gpu_fence(&blns, false, &tag);
    if (st == BLNS_OK)
        st = blns_gpu_wait_fence(&blns, tag);      // OK, DROPPED, GPU, STATE or TIMEOUT
    if (st == BLNS_ERR_GPU || st == BLNS_ERR_STATE || st == BLNS_ERR_TIMEOUT)   // stopped, a stray tag, or the wait ended
        st = blns_gpu_recover(&blns) == BLNS_OK ? BLNS_ERR_DROPPED : st;
    if (st == BLNS_ERR_DROPPED)
        draw_batch();                              // partly drawn at most: draw it again
}
```

---

## 7. API summary

| Area | Functions |
|---|---|
| Set-up | `blns_init`, `blns_set_mode`, `blns_set_size`, `blns_set_orientation`, `blns_set_pix_double`, `blns_set_pitch`, `blns_display_pitch`, `blns_set_nonblocking` |
| Frame buffers | `blns_set_frame`, `blns_select_frame`, `blns_flip`, `blns_flip_async`, `blns_flip_done` (`FRAME_SEL.LATCHED`: exact), `blns_flip_wait` (hooked, bounded), `blns_pixel_addr` |
| VRAM | `blns_vram8/16/32`, `blns_vram_ptr`, `blns_vram_pa`, `blns_vram_wa`, `blns_vram_ba`, `blns_vram_contains`, `blns_surf_rect(dev, top_left, pitch, w, h, swap)`, `blns_vram_write_rect(dev, src, src_stride, pa, pitch, w, h)`, `blns_vram_read_rect(dev, pa, pitch, dst, dst_stride, w, h)` (source first, as the GPU copies), `blns_argb8888_to_rgb565a8` (staging: colours truncated as LVGL's `LV_COLOR_24_TO_16`, alphas copied) |
| Refresh | `blns_refresh_period`, `blns_refresh_rate`, `blns_refresh_once`, `blns_refresh_stop`, `blns_refresh_running`, `blns_frames_flowing`, `blns_wait_frame`, `blns_wait_frames`, `blns_frame_num` (non-exclusive pacing), `blns_frame_abandoned` |
| Colour | `blns_lut_load`, `blns_lut_select`, `blns_lut_present` (double-buffered), `blns_lut_rotate`, `blns_hw_palette` |
| Hardware cursor | `blns_cursor_shape` (rows and the column copy, `BLNS_CURSOR_WORDS` at a 128-aligned word), `blns_cursor_select`, `blns_cursor_colours`, `blns_cursor_hotspot`, `blns_cursor_move` (frame pixels), `blns_cursor_move_panel` (panel pixels: DPI placement and steps, orientation, doubling inverted), `blns_cursor_origin` (a windowed refresh's corner), `blns_cursor_show` (`caps.cursor`, `BLNS_HW_CURSOR`; else `BLNS_ERR_ABSENT`) |
| Interrupts, debug | `blns_irq_enable`, `blns_irq_status`, `blns_irq_clear`, `blns_irq_service`, `blns_debug_freeze` |
| GPU stream | `blns_gpu_enable`, `blns_gpu_push` (raw words), `blns_gpu_forget`, `blns_gpu_space`, `blns_gpu_wait_space`, `blns_gpu_discard` (owner only), `blns_gpu_reset_state` |
| GPU drawing | `blns_gpu_fill`, `blns_gpu_copy`, `blns_gpu_copy_transp`, `blns_gpu_blit` (`blns_blit_t`), `blns_gpu_remap_table`, `blns_gpu_remap_rect`, `blns_gpu_mask_plane`, `blns_gpu_alpha_plane` and `blns_alpha_of` (RGB565A8 sources, `caps.gpu_blend`), `blns_gpu_blit_imm` (immediate source, `caps.gpu_imm`), `blns_gpu_present_copy` |
| GPU per-item (inline fast paths) | `blns_gpu_colour_set`, `blns_gpu_span_begin`, `blns_gpu_span`, `blns_gpu_spans`, `blns_gpu_expand_begin`, `blns_gpu_expand`, `blns_gpu_expand_imm`, `blns_gpu_tex_begin`, `blns_gpu_tex_set`, `blns_gpu_tex_shade`, `blns_gpu_tex_step`, `blns_gpu_tex_span` |
| GPU x/y, blits, effects | `blns_gpu_xy_begin`, `blns_gpu_clip`, `blns_gpu_span_xy`, `blns_gpu_fill_xy`, `blns_gpu_fills_xy`, `blns_gpu_copy_xy`, `blns_gpu_copy_transp_xy`, `blns_gpu_blit_xy`, `blns_gpu_remap_rect_xy`, `blns_gpu_expand_set`, `blns_gpu_expand_xy`, `blns_gpu_text_xy`, `blns_gpu_texrect_xy`, `blns_gpu_texrect_fx_xy` (an affine blit from a 1/65536-texel model, in tiles of at most 64 × 64), `blns_gpu_gradient`, `blns_gpu_gradient_rgb`, `blns_gpu_alpha`, `blns_gpu_blend_rule` (`blns_mix_t`), `blns_gpu_tri_xy`, `blns_gpu_remap_tri_xy`, `blns_gpu_tritex_xy`, `blns_gpu_tri_uv_gradients`, `blns_gpu_line_pattern`, `blns_gpu_line_solid`, `blns_gpu_line_xy` / `blns_gpu_line_px` (`blns_line_t`), `blns_gpu_polyline_xy`, `blns_gpu_rect_outline_xy` (each returns `BLNS_ERR_ABSENT` when its feature is not built: see `caps`) |
| GPU lists | `blns_gpu_list_begin` (`BLNS_LIST_INHERIT`), `blns_gpu_list_end`, `blns_gpu_list_call` (`list->tag`), `blns_gpu_list_busy`, `blns_gpu_list_wait`, `blns_gpu_list_spill` |
| GPU sync, errors | `blns_gpu_fence` (`FENCE AUTO`), `blns_gpu_fence_done`, `blns_gpu_fence_status` ([fence status](#6-recovery)), `blns_gpu_wait_fence`, `blns_gpu_wait_refresh`, `blns_gpu_fifo_low`, `blns_gpu_wait_fifo_low`, `blns_gpu_fifo_low_set`, `blns_gpu_wait`, `blns_gpu_error`, `blns_gpu_recover`, `blns_gpu_recover_request` (any context) |
| DBI transport | `blns_dbi_config`, `blns_dbi_power`, `blns_dbi_reset`, `blns_dbi_cmd`, `blns_dbi_fill`, `blns_dbi_sync`, `blns_dbi_wait_idle` |
| DPI driver | `blns_dpi_config` (example presets `BLNS_DPI_480X272`, `BLNS_DPI_800X480`, `BLNS_DPI_640X480_60`, `BLNS_DPI_720X480_60`), `blns_dpi_image`, `blns_dpi_fit`, `blns_dpi_image_aspect`, `blns_dpi_picture` (`blns_picture_t`), `blns_dpi_border`, `blns_dpi_filter`, `blns_dpi_test`, `blns_dpi_enable`, `blns_dpi_present`, `blns_dpi_scan_line`, `blns_dpi_image_rows`, `blns_dpi_copy_now`, `blns_dpi_hotplug_init`, `blns_dpi_hotplug_poll` (`blns_hotplug_t`) |
| HDMI | DDC: `blns_dpi_ddc_read`, `blns_dpi_edid_read`, `blns_dpi_edid_parse`; mode: `blns_dpi_hdmi` (`blns_avi_t`); audio and packets: `blns_dpi_hdmi_audio` (`blns_audio_t`), `blns_dpi_hdmi_audio_cts`, `blns_dpi_hdmi_packet`, `blns_dpi_hdmi_spd` |
| ILI9341 | `ili9341_init`, `ili9341_set_window`, `ili9341_display_on` |

`belenos.h` documents each function; the [examples](#9-examples) below, the
[programming model](programming_model.md) and the [GPU command set](gpu_commands.md)
show them in context.

---

## 8. Bring-up

Each recipe is the `display_start()` of the [quick start](#31-quick-start): it runs after
`blns_init`, `blns_set_mode` and `blns_set_size`, and returns once the display shows the
frame. The display driver is a build parameter (`DIF_TYPE`); the calls of another
driver return `BLNS_ERR_ABSENT`.

### 8.1 DBI panel (ILI9341)

A panel with its own frame memory (`DIF_TYPE` 1–3) takes a frame on each refresh
request. The library's ILI9341 driver (`sw/panel/ili9341.c`) brings the panel up at
16 bpp on either PHY; `delay_ms` comes from the platform:

```c
#include "belenos.h"
#include "ili9341.h"

extern blns_t blns;
void delay_ms(uint32_t ms);                              // the platform's delay

blns_status_t display_start(void)                        // 320 x 240 on an ILI9341 module
{
    const blns_dbi_config_t dbi = { .spi = false,        // true for the SPI PHY
                                    .clk_div = 1,        // write timing for your hclk
                                    .hw_window = true,   // CASET/PASET before each refresh
                                    .rd_div = 0 };       // 8080 reads: derived from hclk_hz
    blns_status_t st = blns_dbi_config(&blns, &dbi);
    if (st != BLNS_OK)
        return st;
    const ili9341_config_t panel = {
        .delay_ms = delay_ms,
        .madctl   = ILI9341_MADCTL_MV,                   // landscape; orientation and colour order are panel dependent
        .clear    = true, .clear_rgb888 = 0x000000 };    // DIF_DFILL black over DISP_SIZE
    st = ili9341_init(&blns, &panel);
    if (st != BLNS_OK)
        return st;
    return blns_refresh_rate(&blns, 60);                 // REFRESH: a frame every 1/60 s
}
```

`ili9341_init()` runs the sequence the panel needs, through the DBI transport:

| Step | Register-level action |
|---|---|
| power and reset | `DIF_CFG.LCD_ON` = 1; `LCD_RESET` asserted for 10 ms, then 120 ms of wait |
| sleep out | command `0x11`, then 120 ms of wait |
| pixel format | command `0x3A` with `0x55` (16 bits per pixel) |
| orientation | command `0x36` (MADCTL) with the configured value |
| window (optional) | `0x2A` / `0x2B` once, when `win_width` / `win_height` are set: for `CL_SWAP` with `HW_WINDOW_EN = 0` |
| clear (optional) | `DIF_DFILL` with the colour, then wait for `DFILL_BUSY` / `DFILL_PENDING` to clear |
| display on | command `0x29` |

The MADCTL value sets the panel's own orientation and colour order: combine it with
`DISP_CFG` (`blns_set_orientation`) to obtain the picture the right way up on a given
module. A 240 × 320 portrait frame takes `blns_set_size(&blns, 240, 320)` and
`.madctl = ILI9341_MADCTL_BGR` on the Terasic LT24.

Any other command goes through `blns_dbi_cmd()`, which implements the
[DBI command protocol](programming_model.md#92-commands-and-parameters):

```c
static const uint8_t madctl = ILI9341_MADCTL_BGR;
blns_dbi_cmd(&blns, 0x36, &madctl, 1);       // MADCTL with one parameter
```

It waits until the command slot is free and the parameter FIFO empty (`CMD_PENDING`,
`PARAM_LEVEL`), pre-loads up to 16 parameters into `DIF_PARAM`, writes `DIF_CMD`, then
feeds the further parameters as the command drains the FIFO (each when `PARAM_FULL` is
clear): a command takes up to 255 parameters (`NPARAM`; more is `BLNS_ERR_PARAM`), and
no `DIF_PARAM` write meets a full FIFO (which would drop it and set `PARAM_OVFL`). A timeout after `DIF_CMD` is written leaves the
command with fewer parameters than announced: the panel then needs a reset.

### 8.2 DPI panel

A panel without frame memory (`DIF_TYPE = 4`) takes its timing from Belenos; the DPI
driver takes a frame per panel frame, so no refresh timer runs. The presets hold the
timing of common panels and modes (`CLK_DIV` depends on the build's pixel-domain clock):

```c
#include "belenos.h"

extern blns_t blns;

blns_status_t display_start(void)                    // the 320 x 240 frame on a 480 x 272 panel
{
    const blns_dpi_timing_t lcd = BLNS_DPI_480X272;  // pixel clock divider, H and V timing, polarities
    blns_status_t st = blns_dpi_config(&blns, &lcd); // staged timing and polarities
    if (st == BLNS_OK)
        st = blns_dpi_fit(&blns, 320, 240);          // largest image of the frame's shape, centred
    if (st == BLNS_OK)
        st = blns_dpi_enable(&blns, true);           // LCD_ON, DPI_EN: the panel timing starts
    return st;
}
```

`blns_dpi_config()` writes the staged registers and sets `UPDATE` when the driver runs,
so a running panel changes mode at a frame boundary. The staging calls first wait for an
earlier `UPDATE` to be taken, so consecutive calls all reach the panel (in non-blocking
mode they return `BLNS_ERR_BUSY` instead). `blns_dpi_fit` and `blns_dpi_image_aspect`
read the active size back, so they come after `blns_dpi_config` (`BLNS_ERR_STATE`
before). A scaled image needs a build with the scaler (`caps.dpi_scaler`, else
`BLNS_ERR_PARAM`); without one, `blns_dpi_image(&blns, 320, 240, 0, 0)` shows the frame
1:1, centred, with the border colour around it. The registers: [the built-in DPI driver](programming_model.md#10-the-built-in-dpi-driver).

### 8.3 HDMI monitor

An HDMI build (`DIF_TYPE = 5`) is the DPI driver with a TMDS encoder: the same calls,
with a standard mode, the monitor's EDID and a hot-plug service. The preset
`BLNS_DPI_640X480_60` is exact on a 25.175 MHz pixel-domain clock with `CLK_DIV` 0
([HDMI](programming_model.md#11-hdmi)). `blns_dpi_picture` places the frame at
its own shape on a monitor that stretches the signal (the shape of its EDID, or a
fallback), and the hot-plug service places it again once a monitor that did not answer
at start-up does:

```c
#include "belenos.h"

extern blns_t blns;
uint32_t now_ms(void);                                   // the platform's millisecond clock
void ddc_quarter(void);                                  // waits 2.5 us: a quarter of a 100 kHz bit

static const blns_picture_t pic = { .src_w = 320, .src_h = 240, .stretch = true,
                                    .fallback_x100 = 178, .quarter = ddc_quarter };
static blns_hotplug_t hp;                                // zero: the example hot-plug timing

blns_status_t display_start(void)                        // 640 x 480 at 60 Hz
{
    const blns_dpi_timing_t mode = BLNS_DPI_640X480_60;
    blns_status_t st = blns_dpi_config(&blns, &mode);
    hp.picture = &pic;                                   // placed again after a restart
    if (st == BLNS_OK)
        st = blns_dpi_picture(&blns, &pic, &hp.settled); // EDID shape, else 16:9
    if (st == BLNS_OK)
        st = blns_dpi_enable(&blns, true);
    blns_dpi_hotplug_init(&blns, &hp, now_ms());
    return st;
}

void display_poll(bool key_pressed)                      // every few ms, from the main loop
{
    (void) blns_dpi_hotplug_poll(&blns, &hp, now_ms(), key_pressed);   // a key forces a restart
}
```

Until `blns_dpi_hdmi` switches it, the link is DVI, which every sink accepts; HDMI mode
and audio are the optional steps below.

#### EDID over the DDC

With the DDC register (`caps.dpi_ddc`, an HDMI build with
[`DPI_DDC`](programming_model.md#114-ddc)), the driver reads the monitor's EDID with
an I2C master in software. The bit time comes from the caller: a function that waits
a quarter of a bit, 2.5 µs for the standard 100 kHz.

```c
blns_edid_t edid;
if (blns_dpi_edid_read(&blns, ddc_quarter, &edid) == BLNS_OK && edid.aspect_x100 != 0u) {
    /* edid.width_mm x edid.height_mm: the screen; edid.pref_w x edid.pref_h at
       edid.pref_pclk_khz: its preferred mode */
}
```

| Function | Returns |
|---|---|
| `blns_dpi_ddc_read(dev, quarter, addr7, offset, buf, n)` | a random read (offset written, repeated start, bytes read): `BLNS_OK`; `BLNS_ERR_BUS` when the device does not acknowledge or holds SCL low; `BLNS_ERR_ABSENT` without the DDC register |
| `blns_dpi_edid_read(dev, quarter, edid)` | the EDID base block (and its first extension when announced) read and parsed; `BLNS_ERR_PARAM` when the base block is not a valid EDID |
| `blns_dpi_edid_parse(edid)` | the fields of `edid->raw`: the preferred mode from the first detailed timing, the screen size in mm from the same descriptor (else bytes 21–22 in cm, or the aspect ratio they code), `aspect_x100` = width / height × 100 |

The size tells the shape of the screen, not how the monitor scales a signal of another
shape: a monitor set to fill its screen stretches a 4:3 signal to its width, one set to
keep the aspect ratio shows it with bars. A picture meant for a stretching monitor is
sized from `aspect_x100` (the image `blns_dpi_image()` places), one for the other kind
with `blns_dpi_fit()`. `blns_dpi_image_aspect()` does that arithmetic, and
`blns_dpi_picture()` the whole policy: the EDID read, a fallback shape without one, and
(with `blns_hotplug_t.picture`) placing the picture again when a monitor that did not
answer at start-up appears.

#### HDMI mode

With data islands (`caps.dpi_island`), `blns_dpi_hdmi()` switches the link to HDMI
signalling with an AVI InfoFrame; `NULL` returns to DVI. HDMI mode needs a timing whose
`CLK_DIV` is 0, and the InfoFrame a horizontal blanking of at least 63 pixels (every
standard mode has more): without them the link stays DVI or goes without InfoFrame,
with no error ([HDMI mode](programming_model.md#112-hdmi-mode)).

```c
const blns_avi_t avi = { .vic = 1u, .picture = BLNS_AVI_PICTURE_4_3,
                         .active = BLNS_AVI_ACTIVE_16_9 };   /* 640 x 480, a 16:9 frame inside */
blns_dpi_hdmi(&blns, &avi);
```

| Field | Values |
|---|---|
| `vic` | the CTA-861 video code of the mode (1: 640 × 480 at 60 Hz; 0: none) |
| `picture` | `BLNS_AVI_PICTURE_4_3` or `BLNS_AVI_PICTURE_16_9`: the shape of the signal's picture |
| `active` | `BLNS_AVI_ACTIVE_SAME`, `_4_3`, `_16_9`, `_14_9`: the shape of the useful part, centred in the picture |
| `quant` | `BLNS_AVI_QUANT_DEFAULT` (0), `_LIMITED` (16–235), `_FULL` (0–255): the RGB quantization range; `_FULL` for a framebuffer drawn in 0–255 on a CE timing (a `vic` other than 0 and 1, whose default is limited), when the sink's EDID allows it: `blns_avi_quant_auto(&edid)` gives `_FULL` when the EDID's Video Capability Data Block sets QS (`edid.quant_select`), else `_DEFAULT` |

A second call while the InfoFrame is sent changes its fields at the next frame start,
without a gap (it waits for an earlier `UPDATE` first, and for a start in progress).

#### HDMI audio and packets

With audio (`caps.dpi_audio`), `blns_dpi_hdmi_audio()` sends the I2S input to the sink
with the clock regeneration and the audio InfoFrame; it needs HDMI mode on
(`blns_dpi_hdmi()` with an AVI argument), and the line rate and blanking of
[HDMI audio](programming_model.md#113-hdmi-audio). `n` is a multiple of 128 (6272
at 44.1 kHz, 6144 at 48 kHz, 4096 at 32 kHz; since the CTS is measured, others work);
the call clears `AUD` and writes `n` until it reads back (the hardware ignores the
write until the pixel domain has stopped the audio).
`NULL` stops the audio, and so does `blns_dpi_hdmi(&blns, NULL)`, along with the
generic packet. `blns_dpi_hdmi_spd()` sends a Source Product Description InfoFrame once
per frame, the name some sinks show for the source; `blns_dpi_hdmi_packet()` sends any
packet given as header and PB0–PB27 (changing a packet already sent waits for a frame
start).

```c
const blns_audio_t aud = { .n = 6272u, .fs = BLNS_AUD_FS_44K1, .wl = BLNS_AUD_WL_16 };  /* 44.1 kHz, 16-bit */
blns_dpi_hdmi_audio(&blns, &aud);
blns_dpi_hdmi_spd(&blns, "aRVern", "Tang Console", BLNS_SPD_GAME);

bool lost;
if (blns_dpi_hdmi_audio_cts(&blns, &lost) == 0u || lost) {
    /* no CTS measured yet, or an audio frame lost: check the I2S source */
}
```

---

## 9. Examples

**Pixel doubling** ([programming model](programming_model.md#25-pixel-doubling)):

```c
blns_set_pix_double(&blns, true);      // 160 x 120 frames on a 320 x 240 panel
```

**Pacing with `FRAME_NUM`** ([refresh](programming_model.md#3-refresh)):

```c
uint16_t n0 = blns_frame_num(&blns);
// ... later, without blocking:
if ((uint16_t) (blns_frame_num(&blns) - n0) >= 3) next_animation_step();
```

**Loading the LUT** ([programmable LUT](programming_model.md#42-programmable-lut)):

```c
blns_lut_load(&blns, 0, 0, palette_rgb888, 256);   // entries 0x800 + 4*i of bank 0
blns_lut_select(&blns, true, 0);                    // LUT_CFG: SW_LUT_EN, REFR_BANK = 0
```

**Colour cycling** ([palette rotation](programming_model.md#43-palette-rotation)):

```c
for (uint8_t t = 0; ; t = (t + 1) % 32) {
    blns_lut_rotate(&blns, 64, 95, t);   // indices 64..95 cycle
    blns_wait_frame(&blns);
}
```

**One pixel through the VRAM window** ([VRAM window](programming_model.md#5-drawing-through-the-vram-window)):

```c
volatile uint16_t *fb = blns_vram16(&blns);                  // 16 bpp, frame at 0
fb[blns_pixel_addr(&blns, 0, x, y)] = 0xF800;                // one red pixel
```

**Double buffering at 16 bpp, 320 × 240** (frames at pixel addresses 0 and 76800, VRAM of
2 × 38400 words):

```c
unsigned show = 0, draw = 1;
blns_set_frame(&blns, 0, 0);
blns_set_frame(&blns, 1, 320 * 240);
blns_select_frame(&blns, show);                      // the refresh shows frame 'show'
for (;;) {
    draw_scene(draw == 0 ? 0 : 320 * 240);           // GPU or window, at the frame's pixel address
    blns_flip(&blns, draw);                          // display the new frame, wait until the old is free
    unsigned t = show; show = draw; draw = t;        // now draw into the old one
}
```

`blns_flip()` writes `FRAME_SEL` and waits until nothing reads the old buffer. The
refresh takes the frame pointer at the start of each frame, so a frame already being sent
finishes from the old buffer: the driver polls `FRAME_SEL.LATCHED` until it shows the new
index (at once between frames) and leaves `IRQ_FLAG` alone.

**Scroll by moving the frame pointer** (8 bpp, frame twice as tall as the screen):

```c
for (uint32_t line = 0; ; line = (line + 1) % 240) {
    blns_set_frame(&blns, 0, line * 320);            // FRAME0_PTR: start one line lower
    blns_wait_frames(&blns, 1);                      // one frame per step
}
```

**Sprite with a transparent background** (sprite stored off screen at `spr`):

```c
const blns_surf_t sheet  = { .addr = spr, .pitch = 16, .swap = BLNS_SWAP_NONE };
const blns_surf_t screen = { .addr = blns_pixel_addr(&blns, 0, x, y), .pitch = 0,
                             .swap = BLNS_SWAP_NONE };
blns_gpu_copy_transp(&blns, &sheet, &screen, 16, 16, BLNS_ROP_S, 0xF81F);  // magenta = transparent
blns_gpu_fence(&blns, true, NULL);                   // GPU_FENCE interrupt when drawn
```

**Team colours through a remap table** (8 bpp, x/y mode set with `blns_gpu_xy_begin`; a
256-entry table at VRAM word 0x9000, a multiple of 64): the same sprite drawn for the blue
team as stored and for the red team through the table, which swaps palette entries 16–19
for 32–35 and leaves the others.

```c
volatile uint8_t *t = blns_vram8(&blns) + 4u * 0x9000u;    // entry i at byte i
for (unsigned i = 0; i < 256u; i++)
    t[i] = (uint8_t) i;                                    // the identity...
for (unsigned i = 0; i < 4u; i++)
    t[16u + i] = (uint8_t) (32u + i);                      // ... blue 16..19 -> red 32..35
blns_gpu_remap_table(&blns, 0x9000u);                      // after the table is written

const blns_surf_t soldier = { .addr = SOLDIER, .pitch = 16, .swap = BLNS_SWAP_NONE };
const blns_blit_t blue = { .rop = BLNS_ROP_S, .transp = true, .transparent = 0 };
const blns_blit_t red  = { .rop = BLNS_ROP_S, .transp = true, .transparent = 0,
                           .remap = BLNS_REMAP_SRC };      // 0 stays transparent: keyed first
blns_gpu_blit_xy(&blns, &soldier, 40, 100, 16, 16, BLNS_SWAP_NONE, &blue);
blns_gpu_blit_xy(&blns, &soldier, 200, 100, 16, 16, BLNS_SWAP_X, &red);   // facing left
uint32_t tag;
blns_gpu_fence(&blns, false, &tag);                        // wait for it before the table
                                                           // is written again
```

A highlight is the same with a table that brightens every entry (with the palette in
shade blocks, T[i] = the next block's entry) applied to what is already drawn:
`blns_gpu_remap_rect_xy(&blns, x, y, 16, 16)` (`REMAP` `DST`).

**A round sprite through the mask plane** (8 bpp, x/y mode; a 24 × 24 sprite at pixel
address `SPR`, pitch 24; its 1-bpp mask at bit address `MASK`, a multiple of 32, with the
same pitch: 24 bits a row, bit *k* = row · 24 + column):

```c
volatile uint32_t *m = blns_vram32(&blns) + MASK / 32u;
for (unsigned k = 0; k < 24u * 24u; k++) {                 // 1 inside a disc of radius 12
    const int dx = 2 * (int) (k % 24u) - 23, dy = 2 * (int) (k / 24u) - 23;
    const uint32_t bit = 1u << (k % 32u);
    m[k / 32u] = (dx * dx + dy * dy <= 24 * 24) ? (m[k / 32u] | bit) : (m[k / 32u] & ~bit);
}
blns_gpu_mask_plane(&blns, MASK, false);                   // the mask bit of the sprite's first pixel

const blns_surf_t ball  = { .addr = SPR, .pitch = 24, .swap = BLNS_SWAP_NONE };
const blns_blit_t round = { .rop = BLNS_ROP_S, .mplane = true };
blns_gpu_blit_xy(&blns, &ball, x, y, 24, 24, BLNS_SWAP_NONE, &round);  // every colour drawn,
                                                                       // none spent as a key
```

The mask follows the source walk, so the same call with `BLNS_SWAP_X` (x then being the
sprite's right column) or clipped by the window draws the same shape, mirrored or cut.

**An icon with soft edges** ([alpha planes](gpu_commands.md#26-alpha-planes-rgb565a8),
`caps.gpu_blend`): an ARGB8888 image converted once into an RGB565A8 block of the VRAM,
then drawn with its own alpha, as LVGL would draw it:

```c
uint16_t *rgb = (uint16_t *) (void *) (blns_vram16(&blns) + ICON);   // ICON: 16-bpp pixel address
uint8_t  *a8  = (uint8_t *) (void *) (blns_vram8(&blns) + ICON_A8);  // ICON_A8: byte address
blns_argb8888_to_rgb565a8(rgb, a8, 32, argb_icon, 32, 32, 32);       // 32 x 32, pitch 32

blns_gpu_blend_rule(&blns, BLNS_MIX5);                     // LVGL's rule...
blns_gpu_alpha(&blns, false, 0);                           // ...sent with SET_ALPHA, no opacity
blns_gpu_alpha_plane(&blns, ICON_A8);                      // the alpha of the first pixel
const blns_surf_t icon = { .addr = ICON, .pitch = 32, .swap = BLNS_SWAP_NONE };
const blns_blit_t soft = { .rop = BLNS_ROP_S, .src_alpha = true };
blns_gpu_blit_xy(&blns, &icon, x, y, 32, 32, BLNS_SWAP_NONE, &soft);
```

---

## 10. LVGL

`lvgl/lv_belenos.c` makes an LVGL v9 display of a 16-bpp frame, with a CPU, GPU or
DIRECT flush and an optional GPU draw unit; its configuration, fault handling, build
and host test are in [lvgl_guide.md](lvgl_guide.md).

---

## 11. Adding a panel driver

A panel driver is a pair of files in `panel/` that only calls the DBI transport
(`blns_dbi_cmd`, `blns_dbi_fill`, `blns_dbi_power`, `blns_dbi_reset`): its start-up
sequence, its orientation register and its window commands. `ili9341.c` is the
template. A display that the built-in DBI driver cannot drive needs a hardware driver on
the [Belenos Display Interface](display_interface.md) instead (`DIF_TYPE = 0`); its
registers then live in the window at `0x180`–`0x27C`, and its software next to the panel
drivers ([software side](display_interface.md#27-software)).

---

## 12. Host tests

`make -C sw/test` runs the host unit test and `make -C sw/test -j8 lvgl` the LVGL host
test; what they check, the target builds and the board-level runs are described in the
[verification guide](verification_guide.md#3-driver-host-tests).

---

## See Also

- [lvgl_guide.md](lvgl_guide.md) — the LVGL v9 display driver built on this library
- [programming_model.md](programming_model.md), [register_map.md](register_map.md), [gpu_commands.md](gpu_commands.md) — the registers behind each call
- [verification_guide.md](verification_guide.md#3-driver-host-tests) — what the host tests check
- `sw/include/belenos.h` — the full API reference
