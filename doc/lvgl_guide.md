<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos LVGL driver guide

*For LVGL users: `lv_belenos.c`, an LVGL v9 display driver for Belenos at 16 bpp, with an
optional GPU draw unit. It is built on the [C driver](driver_guide.md);
`sw/lvgl/lv_belenos.h` documents it in full.*

---

## Table of Contents

1. [Overview](#1-overview)
2. [Configuration](#2-configuration)
3. [Flush modes](#3-flush-modes)
4. [GPU draw unit](#4-gpu-draw-unit)
    - [4.1 Images in the CPU's memory](#41-images-in-the-cpus-memory)
    - [4.2 Extensions](#42-extensions)
    - [4.3 What each persona offloads](#43-what-each-persona-offloads)
5. [Faults](#5-faults)
6. [Contexts and lifetime](#6-contexts-and-lifetime)
7. [Build](#7-build)
8. [Host test](#8-host-test)
- [See Also](#see-also)

---

## 1. Overview

`lv_belenos_create()` makes an LVGL display of an RGB565 frame in the VRAM that the
refresh shows. The board sets Belenos up first with the driver library: `blns_init`,
`blns_set_mode(BLNS_BPP_16)`, the size, the frame pointer, the display
([bring-up](driver_guide.md#8-bring-up)) and, for the GPU flush or the draw unit,
`blns_gpu_enable`. Then `lv_init` and:

```c
#include "lv_belenos.h"

extern blns_t blns;                  // set up as above: 320 x 240 at 16 bpp, frame at pixel 0

lv_display_t *display_create(void)
{
    const lv_belenos_config_t cfg = { .dev = &blns, .frame = 0, .width = 320, .height = 240,
                                      .flush = LV_BELENOS_FLUSH_DIRECT, .gpu_draw = true };
    return lv_belenos_create(&cfg);  // NULL: a configuration it refuses, or LVGL's memory short
}
```

The arvern-soc `lvgl_demo` (Tang Console) is the reference integration, with each flush
mode and the draw unit selected at build time.

---

## 2. Configuration

`lv_belenos_config_t`, best written with designated initialisers (the fields left out
are 0):

| Field | Meaning |
|---|---|
| `dev` | the Belenos handle, `blns_init` done, depth `BLNS_BPP_16` |
| `frame` | pixel address of the frame's (0, 0) |
| `pitch` | frame line stride in pixels; 0 = `width` (not the display pitch of the driver library); else at least `width` |
| `width`, `height` | display size in pixels (1 … 65535) |
| `flush` | `LV_BELENOS_FLUSH_CPU`, `_GPU` or `_DIRECT`: [flush modes](#3-flush-modes) |
| `gpu_draw` | the [GPU draw unit](#4-gpu-draw-unit), with the GPU or DIRECT flush |
| `buf[2]`, `buf_bytes` | the draw buffers and the size of each: CPU flush `buf[0]` in RAM (`buf[1]` NULL); GPU flush `buf[0]` and optionally `buf[1]` in the VRAM window (pointers into `blns_vram8(dev)`); DIRECT none. Aligned to `LV_DRAW_BUF_ALIGN`, at least one line of LVGL's stride |
| `pool`, `pool_bytes`, `pool_layers` | with `LV_BELENOS_USE_POOL` only: the draw unit's [VRAM pool](#42-extensions) (a 4-byte-aligned pointer into the VRAM window, apart from the frame and the buffers; NULL: none), and LVGL's RGB565 layers in it |
| `approx` | with `LV_BELENOS_USE_APPROX` only: the draws the GPU [computes its own way](#42-extensions), `LV_BELENOS_APPROX_GRAD` and / or `_TRANSFORM` (0: none) |

`lv_belenos_create` returns NULL, with nothing allocated, when LVGL would refuse the
buffers (misaligned, shorter than a line), when the frame or a GPU-flush buffer is not
wholly in the VRAM, when the depth is not 16 bpp or `pitch` is below `width`, when the
GPU flush or `gpu_draw` finds no GPU or the GPU disabled, for `gpu_draw` with the CPU
flush, for a DIRECT frame not aligned to `LV_DRAW_BUF_ALIGN`, for a pool not word-aligned or not
wholly in the VRAM, and when LVGL's memory is short.

---

## 3. Flush modes

| Mode | LVGL renders | Flush |
|---|---|---|
| CPU | PARTIAL, into `buf[0]` in the CPU's RAM | the CPU copies the area into the frame (`blns_vram_write_rect`: 32-bit stores when the area and the buffer allow); invalidated areas are widened to even columns so that every row is whole words |
| GPU | PARTIAL, into `buf[0]` / `buf[1]` in the VRAM (through the window) | one GPU `COPY` into the frame and a `FENCE`; LVGL waits for the fence before it renders into that buffer again, and the last area of a frame is waited for at once (the frame is whole when LVGL's refresh returns). With two buffers LVGL renders the next area while the GPU copies the last one |
| DIRECT | DIRECT, into the frame itself (LVGL's stride the frame's pitch) | none: only what changed is redrawn; without a second frame the panel may show an area while it is redrawn (a tear) |

---

## 4. GPU draw unit

With `gpu_draw`, an LVGL draw unit next to LVGL's software renderer takes the draw tasks
the GPU renders exactly as the software renderer does, pixel for pixel, when the target
layer is an RGB565 buffer in the VRAM (so with the GPU or DIRECT flush). With blending
(`caps.gpu_blend`) the GPU's `MIX5` rule is LVGL's own (`lv_color_16_16_mix`,
[blending](gpu_commands.md#16-blending)), so translucent draws are exact too:

| Task | Taken when |
|---|---|
| `FILL` | opaque, or with `caps.gpu_blend` at an opacity `LV_OPA_MIN` < opa < `LV_OPA_MAX`; no gradient; with a radius only when the clipped area misses the four corners (`LV_DRAW_SW_COMPLEX 0`: radius 0 only) |
| `BORDER` | as `FILL`; all four sides, sides that do not meet, corners missed as for `FILL`: up to four rectangles |
| `IMAGE`, `LAYER` | RGB565 pixels, the size of the area, full opacity (with `caps.gpu_blend` also an opacity as for `FILL`), no rotation, scale, skew, recolour, colour key, mask, clip radius, tiling, premultiplied alpha or other blend mode; in the VRAM (a GPU `COPY`), or in the CPU's memory with the [immediate source](#41-images-in-the-cpus-memory) |
| `IMAGE` RGB565A8 | (`caps.gpu_blend`) as above, in the VRAM, any opacity: a copy with the GPU's [per-pixel alpha](gpu_commands.md#26-alpha-planes-rgb565a8) (`SET_ALPHA` `EN` only below `LV_OPA_MAX`, as LVGL) |

Everything else stays with the software renderer: anti-aliased edges (rounded corners,
arcs, lines), shadows, text (but with the [pool](#42-extensions)), gradients (LVGL rounds
per pixel in RGB888, the GPU steps RGB565 fields: not the same pixels), rotated and
scaled images (but with the approximate extension), and images and layers in the CPU's
memory without the immediate source or that it does not push (ARGB8888 and RGB565A8
ones: the pool).

| Capability | Used |
|---|---|
| `caps.gpu` | fills and copies (required) |
| `caps.gpu_imm` | images and layers in the CPU's memory (without a [pool](#42-extensions)) |
| `caps.gpu_blend` | opacity, RGB565A8 images; with the pool labels and ARGB8888 images: exact (`MIX5`), unless the [platform header](driver_guide.md#21-platform-header-optional) states `BLNS_HW_GPU_BLEND` 0 |
| `caps.gpu_grad` | horizontal and vertical gradients, opt-in (`approx` GRAD) |
| `caps.gpu_xy` | rotated and scaled images, opt-in (`approx` TRANSFORM): nearest sampling |
| `caps.gpu_bilinear` | with `caps.gpu_blend`, the same with LVGL's default `antialias`: bilinear sampling and anti-aliased edges |
| `caps.gpu_tri`, `caps.gpu_line` | no: see [4.3](#43-what-each-persona-offloads) |
| `caps.gpu_remap` | no: at 16 bpp the palette remap has no effect |
| `caps.gpu_mplane` | no: LVGL's masks and alpha channels are 8-bit coverage in the CPU's memory, not a 1-bit plane in the VRAM |

The tasks the unit takes are pushed to the GPU and marked `QUEUED`, one `FENCE` behind
each batch, at most two batches in flight; LVGL gives the software renderer no task
whose area meets a queued one, and the unit marks them `FINISHED` once
`blns_gpu_fence_status` reports their fences reached. The flush comes after every task
is `FINISHED`, so the GPU is idle on the frame by then.

### 4.1 Images in the CPU's memory

With the immediate source (`caps.gpu_imm`, `GPU_IMM_EN`), an image or layer whose pixels
are not in the VRAM (ROM, RAM, a layer on LVGL's heap) is pushed by the CPU through
`GPU_CMD` (`blns_gpu_blit_imm`), in order with the GPU's drawing: no staging copy in the
VRAM and no fence between the GPU's work and the image (in LVGL a small gain: LVGL
dispatches nothing while the task covering the whole layer, the screen's background, is
not finished). The CPU still reads and writes every pixel once, as the software
renderer's copy does, but a pushed word costs it more: about 8.6 cycles, plus about 310
per push (the call, its command words and its FIFO checks), against about 2.4 cycles a
word plus about 50 a row for the software renderer's copy (`lv_memcpy` row by row into
the frame). Measured in the [LVGL bench](performance.md#2-lvgl-benchmark)
(`bench/lvgl_bench`: the classic persona, a FIFO of 8 words, its aRVern core at `-O2` and
111 MHz, the image in its zero-wait data memory, the refresh running), timing
`blns_gpu_blit_imm` and the row copies of images of 1 to 1024 words with the bench's
cycle counter, the GPU idle at each push's start. What the push saves is LVGL's per-image
work (the decoder, the blend set-up: about 1100 cycles, measured on the Tang Console), so
only small images gain. The drawn area (the task's area in its clip area and layer) is
pushed in one piece when:

- its rows are packed: one row, or whole rows of an image without row padding (stride
  `w × 2`); the immediate source has no row stride, and one push per row costs more
  than the software renderer's copy;
- it has at most 1024 pixels (measured on the Tang Console: 16 × 16 is drawn 32 µs
  faster than by the software renderer, 32 × 32 3 µs faster, 64 × 32 73 µs slower);
- it starts on a 32-bit word and is read with nothing past the source's `data_size` (a
  push of an odd number of pixels reads the half word after them).

Larger, horizontally clipped, misaligned or padded images stay with the software
renderer.

### 4.2 Extensions

Three build options (`lv_conf.h` or `-D`, all 0 by default: the unit above, nothing
more; with 0 the new configuration fields do not exist and the code is not compiled)
let the unit take more of LVGL's tasks. Each also needs its GPU feature built (the
[platform header](driver_guide.md#21-platform-header-optional)), and the approximate ones a
`cfg.approx` flag at run time:

| Option | Exact | What the GPU then draws |
|---|---|---|
| `LV_BELENOS_USE_CORNERS` | yes | a rounded `FILL` or `BORDER` whose clipped area meets its corners (not only the straight parts as above): the GPU draws the straight parts, the software renderer the four corner squares, after the GPU has drawn what it has queued over them. When the corners are more than a quarter of the area (a circle, a pill) the software renderer draws it all. `LV_DRAW_SW_COMPLEX` 1 only |
| `LV_BELENOS_USE_POOL` | yes | a VRAM region the unit owns (`pool`, `pool_bytes`). RGB565 images in the CPU's memory are staged there by the CPU at their first draw, then drawn by GPU copies, tiled ones (`LV_IMAGE_ALIGN_TILE`) too: this replaces the immediate source, whatever the image's size and stride. With `pool_layers`, the unit allocates LVGL's RGB565 layers there before LVGL does, so the GPU draws into them and copies them (a layer that does not fit goes to LVGL's heap; its tasks are then drawn by the CPU). With `caps.gpu_blend` also: RGB565A8 images in the CPU's memory staged as they are, ARGB8888 images (wherever they are) converted to RGB565A8 at their first draw with LVGL's truncation (`LV_COLOR_24_TO_16`, the rule of LVGL's own ARGB8888 blend: `blns_argb8888_to_rgb565a8`), both drawn by copies with the GPU's per-pixel alpha, tiled ones too; and labels: the A1 to A8 glyphs of LVGL's bitmap fonts, one `EXEC_EXPAND MASK` each from its coverage mask staged in the pool (4 bpp when LVGL's A8 values are multiples of 17, as for LVGL's own A4 fonts, else 8 bpp), the label's fills (selection, underline) as GPU fills. Labels with rotation, an outline, a font that is not LVGL's bitmap format, and every label in non-blocking mode stay with the software renderer. When the pool is full the GPU is waited for and every staged image and glyph dropped; what still does not fit is drawn by the CPU |
| `LV_BELENOS_USE_APPROX`, `approx` `LV_BELENOS_APPROX_GRAD` | no | (`caps.gpu_grad`) opaque horizontal and vertical gradients of fills, any stops: runs of at most 64 rows or columns in one stop interval, each a GPU `FILL` with a per-channel ramp (`SET_GRAD_RGB`) from LVGL's colour at its start towards LVGL's colour just past it (the ramp's rounding drifts less than half a field over a run); a ramp steeper than `SET_GRAD_RGB` takes (8 field units a step) is drawn one row or column at a time, each a plain fill of LVGL's colour |
| `LV_BELENOS_USE_APPROX`, `approx` `LV_BELENOS_APPROX_TRANSFORM` | no | (`caps.gpu_xy`) rotated and scaled `IMAGE` tasks (no skew, tiling, recolour, colour key, clip radius or mask; NORMAL blend mode) of the formats above (ARGB8888 staged in the pool), up to 512 × 512: LVGL's set-up of `lv_draw_sw_transform` replicated (its sine table, steps and start, the right and bottom clamp of a scale without rotation as a second blit), one `EXEC_TEXRECT` with `BOUND` per tile of at most 64 × 64, each seeded from LVGL's 1/65536-texel model (`blns_gpu_texrect_fx_xy`). With `antialias` (LVGL's default): [bilinear sampling](gpu_commands.md#27-bilinear-sampling) with transparent taps outside the image (`TBORDER`; `caps.gpu_bilinear` and `caps.gpu_blend`); without: the nearest texel (an RGB565 image at full opacity needs `caps.gpu_xy` only, anything else blending). Transformed layers stay with the software renderer: LVGL renders them as ARGB8888 |

**How far the approximate draws are from LVGL's.** The blended draws are exact (the
GPU's `MIX5` rule is LVGL's, checked bit for bit by the host test). The approximate ones,
measured by the host test:

| Draw | R (of 31) | G (of 63) | B (of 31) |
|---|---:|---:|---:|
| gradient (3 000 random two-stop gradients of 2 to 1 024 rows, sharp ones included) | 2 | 2 | 2 |
| rotated or scaled image, bilinear: the GPU's kernel against LVGL's at the same sample point (LVGL's own two kernels differ by up to 5 in G) | 3 | 5 | 3 |
| ... the largest difference measured in the host test's scenes | 2 | 7 | 2 |

The bilinear bound is the kernel's plus a position term: the GPU samples within 1/32
texel of LVGL's point (the tiles keep the walk's drift small, and LVGL floors its own
point to 1/256 twice), which adds at most 2/32 of the contrast between neighbouring
texels, and near the image's edge, where LVGL or the GPU may skip the pixel, the whole
contrast. Without `antialias` the GPU's texel lies within 1/32 texel of LVGL's sample
point, so a pixel may take the neighbouring texel. The draws that are not approximate
are exact in every mode.

**Faults.** A blended draw (an opacity, an image with alpha, a label, a transform) is not
idempotent: when the GPU did not draw a batch, the CPU
draws its tasks again over what the GPU may have drawn of them, which can blend a pixel
twice. The unit then invalidates the area of each such task after the refresh
(`LV_EVENT_REFR_READY`), so the next refresh draws it whole again: one frame may show
it wrong. The CPU's corner squares are not drawn twice (after a fault the CPU draws the
straight parts again, not the corners).

**What the extensions cost.** The pool's block list and staged-image table take about
1 KB of LVGL's heap, the glyph table (256 entries of 20 bytes on RV32) 5 KB, each display with a pool one
more small allocation; nothing without a pool. GPU modes (blending, gradients, the
texture filter) are set
for a task and cleared before the next plain one and at the end of each dispatch round,
so between rounds they are off, as the flush copy and any other GPU user expect.

### 4.3 What each persona offloads

With every extension built and `approx` GRAD | TRANSFORM:

| Persona | Draws the GPU takes |
|---|---|
| `essential` | opaque fills, borders and the straight parts of rounded ones; RGB565 images (staged in the pool, tiled ones too) and layers (in the pool) |
| `classic` | the same, opaque horizontal / vertical gradients, and RGB565 images rotated or scaled at full opacity with `antialias` off (nearest) |
| `performance`, `ultra` | the same, and exactly: fills, borders, images and layers at an opacity, RGB565A8 and ARGB8888 images, labels; rotated or scaled images of every format, with `antialias` on (LVGL's default: bilinear, anti-aliased edges) or off (nearest) |

What no persona offloads, and why:

| LVGL draw | Why not |
|---|---|
| ARGB8888 layers (a rounded or translucent-edged layer chunk, a transformed layer) | LVGL renders them with its software renderer into an ARGB8888 buffer; the GPU draws only into RGB565, and converting each chunk would cost the CPU what LVGL's own blend costs |
| rotated or scaled images with `antialias` on, without `GPU_BILINEAR_EN` and `GPU_BLEND_EN` (`classic` and below, or a build without them) | LVGL filters them (bilinear) and anti-aliases their edges; the GPU would sample the nearest texel only. The benchmark's rotated images are such |
| arcs, anti-aliased edges of rounded shapes (the corners), lines, triangles, masks | LVGL's anti-aliasing is an 8-bit coverage computed per pixel in the CPU's memory; the GPU's lines are one pixel wide (LVGL's have a width and caps), its triangles are not anti-aliased |
| box shadows, blur | a blur: no GPU command |
| text in a palette depth, the palette remap, the mask plane | the driver is RGB565; LVGL's masks are 8-bit |

---

## 5. Faults

No fault leaves wrong pixels: what the GPU did not complete is drawn again by the CPU.
The driver tells it from the fence status ([recovery](driver_guide.md#6-recovery)):

- **GPU flush.** A copy the GPU did not complete (stopped on an error, dropped by a
  recover, still running when a wait ends) is stopped (a recover, or a wait for what
  came after it) and copied again by the CPU. A copy refused because the GPU is stopped
  is retried once after a recover; a GPU without room (non-blocking
  `BLNS_ERR_BUSY`, a wait hook's timeout) or disabled leaves that area to the CPU copy
  at once.
- **Draw unit.** A batch whose fence does not read `BLNS_OK` is drawn again by the CPU,
  every queued task in its order with the software renderer's functions, once the GPU
  is recovered (stopped, a wait that ended) or idle (dropped by a recover from
  another context): never `FINISHED` with wrong pixels (a blended task may show
  blended twice until the next refresh redraws it:
  [extensions](#42-extensions)). A GPU without room only defers
  the task to LVGL's next dispatch round, and so does a timeout in the data of an
  immediate blit: the driver discards the blit (`blns_gpu_discard`, the stream stays in
  step) and the task is sent again whole.

---

## 6. Contexts and lifetime

- The driver runs in the context that owns the `blns_t`; another context may only
  request a recover (`blns_gpu_recover_request`, `blns_irq_service`).
- When LVGL has nothing else to do, the unit waits for its fence with
  `blns_gpu_wait_fence`, through the wait hook (where an OS sleeps), not in LVGL's
  dispatch loop.
- The unit draws for its display only, while that display is refreshed;
  `lv_display_delete` frees the display's state and detaches the unit (LVGL keeps its
  draw units until `lv_deinit`: the next display created with `gpu_draw` takes it
  again).
- `lv_belenos_flush_cb` is the flush callback `lv_belenos_create` installs: a wrapper
  may replace it (`lv_display_set_flush_cb`) and call it, e.g. to time the flushes.

---

## 7. Build

Add `lv_belenos.c` to the driver library's [build](driver_guide.md#1-build), with LVGL v9
(not bundled; tested with v9.6) and its `lv_conf.h`:

```make
SRCS   += $(BLNS_SW)/lvgl/lv_belenos.c
CFLAGS += -I$(BLNS_SW)/lvgl -I<lvgl root> -I<dir of lv_conf.h> -DLV_CONF_INCLUDE_SIMPLE
```

LVGL's root directory goes on the include path, as for `lvgl.h`: the draw unit includes
LVGL's internal headers (`src/draw/sw/lv_draw_sw.h`, `src/misc/lv_area_private.h`,
`src/core/lv_refr_private.h`, `src/core/lv_global.h`,
`src/display/lv_display_private.h`; with the extensions also `src/draw/lv_draw_buf_private.h`,
`src/draw/lv_draw_label_private.h`, `src/draw/sw/blend/lv_draw_sw_blend_private.h` and
`src/draw/sw/lv_draw_sw_grad.h`). The draw unit is always linked (`lv_belenos_create`
refers to it): `lv_belenos.o` is 4 856 bytes of text and data with `riscv-none-elf-gcc`
15.2, `-Os -march=rv32emc_zbb_zba_zbs_zicsr_zcb -mabi=ilp32e` and the host test's
`lv_conf.h`, on top of the driver library calls it uses, with the extension options 0
(the default; their code is not compiled: the arvern-soc `lvgl_demo` is the same size
with them as without). With all three options 1 it grows to 13 454 bytes (and 44 of bss).

---

## 8. Host test

`make -C sw/test -j8 lvgl` builds LVGL v9.6.0 (fetched on first use from the official
release archive into `sw/test/lvgl_src/`, its SHA-256 checked; `LVGL=<root>` for another
copy) in four configurations,
LVGL's defaults and 8-byte buffer and stride alignment with `LV_DRAW_SW_COMPLEX 0`, each
without and with the [extensions](#42-extensions) (`ext`, `exta8`: the three options 1,
a 256 KB VRAM model), and checks the driver against LVGL's software renderer, faults
included: pixel for pixel (the blended draws too), the approximate draws within the
bounds above (that of a gradient on 3 000 random ones); details in the
[verification guide](verification_guide.md#3-driver-host-tests).

---

## See Also

- [driver_guide.md](driver_guide.md) — the driver library: set-up, recovery and fences
- [gpu_commands.md](gpu_commands.md) — the GPU commands the draw unit uses (fills, copies, the immediate source)
- [verification_guide.md](verification_guide.md#3-driver-host-tests) — the LVGL host test
- [performance.md](performance.md#2-lvgl-benchmark) — LVGL's benchmark with this driver, persona by persona
- `sw/lvgl/lv_belenos.h` — the full reference
