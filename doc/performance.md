<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos performance

*For integrators choosing a persona and LVGL users: what each persona gains on LVGL's own
benchmark, measured in simulation on an aRVern core, under stated conditions, and the
GPU's cycles per pixel. The bench that measures it is described in the
[simulation guide](simulation_guide.md#9-lvgl-benchmark-bench).*

---

## Table of Contents

1. [Summary](#1-summary)
2. [LVGL benchmark](#2-lvgl-benchmark)
    - [2.1 Conditions](#21-conditions)
    - [2.2 Method](#22-method)
    - [2.3 Results at 480 × 272](#23-results-at-480--272)
    - [2.4 Results at 800 × 480](#24-results-at-800--480)
    - [2.5 Deviations from the unmodified benchmark](#25-deviations-from-the-unmodified-benchmark)
    - [2.6 Reading the results](#26-reading-the-results)
3. [GPU primitives](#3-gpu-primitives)
4. [Reproducing the results](#4-reproducing-the-results)
- [See Also](#see-also)

---

## 1. Summary

On LVGL v9.6's own benchmark at 480 × 272 RGB565, with the CPU (aRVern's Performance
persona) at 111 MHz, a frame takes 9.04 ms on average without a GPU
(`light`). **With the GPU's blending, per-pixel alpha and bilinear sampling
(`performance`, `ultra`) it takes 4.6 ms: × 1.95 to × 1.96**, up to × 7.9 on rotated
images, × 3.5 on images with an alpha channel, × 3.1 on a translucent overlay and × 1.9
on screen-sized text. The GPU then draws the translucent fills, images and layers, the
ARGB8888 images (staged in its VRAM pool as RGB565A8) and every glyph exactly as LVGL
does, and the rotated images approximately, within 2 of LVGL's values per RGB565
field here (the draw unit's opt-in `approx` TRANSFORM, which this bench runs; every other scene draws
LVGL's pixels exactly; with `approx` 0, every pixel LVGL's, 5.27 ms: × 1.71). Without blending (`essential`, `classic`) the GPU draws only
opaque shapes (the straight parts of rounded ones), RGB565 images staged in the pool
and layers in it: 8.6 ms, × 1.05, up to × 1.45 on the image scenes,
the same pixels as LVGL's. The frame time left is the CPU's: LVGL's object tree, styles
and draw tasks, text layout, and what the GPU cannot draw at all (ARGB8888 layers,
anti-aliased corners and arcs: [what is not offloaded](lvgl_guide.md#43-what-each-persona-offloads)).
At 800 × 480 the picture is the same: 21.9 ms per frame without a GPU, 10.7 to 10.8 ms with
blending (× 2.03 to × 2.04, × 8.5 on rotated images, × 3.2 on the overlay), 20.8 ms
without (× 1.05, up to × 1.45 on the tiled wallpaper)
([§2.4](#24-results-at-800--480)).

<!-- lvgl_bench:begin headline -->

| | `light` | `essential` | `classic` | `performance` | `ultra` |
|---|---:|---:|---:|---:|---:|
| All scenes avg., ms per frame at 111 MHz, 480 × 272 | 9.04 | 8.59 (× 1.05) | 8.60 (× 1.05) | 4.63 (× 1.95) | 4.61 (× 1.96) |
| All scenes avg., ms per frame at 111 MHz, 800 × 480 | 21.9 | 20.8 (× 1.05) | 20.8 (× 1.05) | 10.8 (× 2.03) | 10.7 (× 2.04) |

<!-- lvgl_bench:end headline -->

The area of each persona, for scale ([synthesis guide](synthesis_guide.md#1-area-results)):

| | `light` | `essential` | `classic` | `performance` | `ultra` |
|---|---:|---:|---:|---:|---:|
| Area, kGates | 14.0 | 38.6 | 67.3 | 94.5 | 122.8 |

The cycles-per-pixel figures of the GPU itself are in [§3](#3-gpu-primitives).

---

## 2. LVGL benchmark

LVGL v9.6.0's `lv_demo_benchmark` (16 scenes: fills, images, text, arcs, containers with
opacity and layers, scrolling and the widgets demo), run unmodified on an aRVern core and
Belenos in Verilator, once per [persona](integration_guide.md#21-personas). The
software baseline is `light` (no GPU: LVGL's software renderer draws everything, through
the VRAM window); the other personas draw with the [LVGL driver](lvgl_guide.md)'s GPU draw
unit and its [extensions](lvgl_guide.md#42-extensions), with `approx` GRAD | TRANSFORM:
the gradients and the rotated and scaled images of the personas that can draw them
round as the GPU does (the blended draws are exact in every mode). **Compare these figures with LVGL 9 results
only**: the v8 benchmark has other scenes.

### 2.1 Conditions

| | |
|---|---|
| CPU | aRVern in its **Performance persona**, exactly as the arvern repository defines and publishes it (`sim/rtl_sim/bin/rtl_sweep_configs.py`, persona `performance`; [arvern benchmarking guide §1.2](https://github.com/Arvern-Silicon/arvern/blob/main/doc/benchmarking_guide.md#12-arvern-personas)): RV32I, M (one-cycle multiplier, radix-8 12-cycle divider), Zba, Zbb, Zbs, Zbc, Zca, Zcb, Zicsr, Zicntr; no taken-branch bubble (`SINGLE_CYCLE_BRANCH = 1`); M, S and U modes with 4 PMP entries (the firmware runs in M-mode); no Zihpm, no debug module (performance-neutral). The bench times with its own memory-mapped cycle counter (Zicntr is there but unused). The CPU's own speed is documented with the core ([arvern benchmarking guide](https://github.com/Arvern-Silicon/arvern/blob/main/doc/benchmarking_guide.md)) |
| Clock | one clock for the CPU, the buses and Belenos; times at **111 MHz** (9.0 ns, the period Belenos meets in every configuration in [synthesis](synthesis_guide.md#11-sweep-conditions)); cycles are given too |
| Memories | behavioural, **zero wait state**: 4 MB of code memory (code, read-only data: the benchmark's images and fonts, at the CPU's instruction and data ports) and 1 MB of data memory (LVGL's 128 KB pool, the stack). An FPGA board is slower (the Tang Console adds wait states to the data reads from the program memory) |
| VRAM | the single-port VRAM macro model, `VRAM_RD_LAT` = 1, `VRAM_RD_REG_EN` = 0 (the defaults): a VRAM-window read takes 2 wait states unless the read-ahead word has it, a write none ([VRAM window](memory_and_ahb.md#2-vram-window)); `VRAM_WORDS` = W × H (two RGB565 frames): the frame, and the draw unit's pool in the second frame's room (W × H × 2 bytes: 255 KB at 480 × 272, 750 KB at 800 × 480) |
| Display | the built-in DPI driver (`DIF_TYPE = 4`, on the system clock, no scaler) and the bench's DPI panel model, the refresh on all the time: at 480 × 272, 535 × 298 pixels per frame and `CLK_DIV` 11 (9.25 MHz pixel clock, 58.0 Hz); at 800 × 480, 928 × 525 and `CLK_DIV` 3 (27.75 MHz, 57.0 Hz). The panel timings are the driver's presets `BLNS_DPI_480X272` and `BLNS_DPI_800X480` |
| Belenos | the personas of `sim/rtl_sim/bin/rtl_configs.py`, every other parameter at its default; the driver built with each persona's [platform header](driver_guide.md#21-platform-header-optional) |
| LVGL | v9.6.0 from the release archive (SHA-256 checked), RGB565, the [`lv_belenos.c`](lvgl_guide.md) driver in DIRECT mode (LVGL renders into the one frame the refresh shows), its GPU draw unit on in every persona with a GPU, with its three [extensions](lvgl_guide.md#42-extensions) built (`LV_BELENOS_USE_CORNERS`, `_POOL`, `_APPROX`), the pool above with LVGL's layers in it, and **`approx` = GRAD \| TRANSFORM: the GPU's gradients and image transforms on**, as a user who accepts the GPU's rounding would run it ([what each persona offloads](lvgl_guide.md#43-what-each-persona-offloads): `essential` neither, `classic` the gradients and nearest-sampled opaque RGB565 transforms, `performance` and `ultra` both, the transforms bilinear); the blending (`performance`, `ultra`) is exact, LVGL's own rule (`MIX5`), in every mode; LVGL's default configuration but for the [deviations](#25-deviations-from-the-unmodified-benchmark) |
| Compiler | xPack `riscv-none-elf-gcc` 15.2.0, `-O2 -march=rv32imc_zbb_zba_zbs_zbc_zcb_zicsr_zifencei -mabi=ilp32 -ffunction-sections -fdata-sections` (the persona's `-march`, as the arvern repository derives it), newlib-nano, no LTO; **LVGL's code pinned**: linked whole and placed first, at a fixed address (`bench/lvgl_bench/sw/link.ld`), so that it is the same bytes at the same address in every persona and option, since otherwise the size of the code that differs (the driver, the glue, the bench's main) moves LVGL's loops across the CPU's 4-byte fetch words and its cycles by a few per cent |

The bench ran earlier on the Tang Console 138K's core (RV32E, 33-cycle divider, one bubble
per taken branch); this core takes 12 to 15 % fewer cycles per frame
in every persona (a third fewer on "Rotated ARGB images": LVGL's image transform and its divisions),
and the speed-ups of the personas stayed within 0.04 of what they were there (measured
before the per-pixel alpha and bilinear sampling).

### 2.2 Method

- **The same frames in every persona.** LVGL's clock is the bench's lockstep clock: it
  moves by `LV_DEF_REFR_PERIOD` (33 ms, the default) for each pass of the main loop (one
  `lv_timer_handler` call) and stands still while a frame is drawn. Every pass refreshes
  the display once, so each scene is drawn in its scene time / 33 ms frames (about 90 for
  a 3 s scene, 600 for the widgets demo), each 33 ms of animation after the last, and
  every persona draws exactly the same frames: the speed-ups compare equal work. This is
  what a system that keeps up with the 30 Hz refresh draws; a slower one, in real time,
  draws fewer frames with more change in each.
- **The measurement** is LVGL's own: the display events its system monitor uses (render
  start and ready, flush start and finish), timed with the bench's cycle counter instead
  of LVGL's millisecond tick. Render time = the rendering without the flushes inside it,
  flush time = the flushes; the time per frame is their sum, as the benchmark's
  "Avg. time (render + flush)". The first frame of each scene (its set-up, a
  whole-screen redraw) is left out, as the benchmark leaves out its first measurement of a
  scene. The frame rate is 111 MHz / the cycles per frame: the rate the system can draw,
  where LVGL's FPS stops at 1000 / `LV_DEF_REFR_PERIOD` (30).
- **The GPU's part** comes from the bench's counters on Belenos's VRAM arbiter (writes by
  the GPU and by the VRAM window, the refresh's reads) and on the GPU's busy flag, over
  each frame's rendering.
- **Checks**: every run ends with the benchmark's end callback, with no LVGL assertion,
  no trap and no GPU recovery (a fault the driver would redraw on the CPU, which would
  skew the timing); the frames dumped from the VRAM (`--dump`) show each scene.

### 2.3 Results at 480 × 272

Averages over the frames of each scene (all but the first), in the benchmark's scene
order; "All scenes avg." is the mean of the scenes, as LVGL's summary computes it.

<!-- lvgl_bench:begin summary_480x272 -->

| Persona | Time per frame, ms | Frame rate, FPS | Cycles per frame, k | Speed-up | Frame-buffer writes by the GPU | GPU busy |
|---|---:|---:|---:|---:|---:|---:|
| **light** | 9.04 | 257 | 1 004 | — | 0 % | 0 % |
| **essential** | 8.59 | 291 | 954 | × 1.05 | 72 % | 8 % |
| **classic** | 8.60 | 290 | 954 | × 1.05 | 72 % | 8 % |
| **performance** | 4.63 | 454 | 514 | × 1.95 | 97 % | 24 % |
| **ultra** | 4.61 | 454 | 512 | × 1.96 | 97 % | 24 % |

<!-- lvgl_bench:end summary_480x272 -->

**Time per frame** (render + flush) in ms at 111 MHz, and the speed-up against `light`:

<!-- lvgl_bench:begin time_480x272 -->

| Scene | **light** | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|---:|
| Empty screen | 4.10 | 3.51 (× 1.17) | 3.51 (× 1.17) | 2.01 (× 2.04) | 2.01 (× 2.04) |
| Moving wallpaper | 6.75 | 4.98 (× 1.36) | 4.98 (× 1.36) | 3.32 (× 2.04) | 3.32 (× 2.04) |
| Single rectangle | 0.75 | 0.67 (× 1.12) | 0.67 (× 1.12) | 0.52 (× 1.44) | 0.52 (× 1.44) |
| Multiple rectangles | 4.29 | 3.91 (× 1.10) | 3.92 (× 1.09) | 3.56 (× 1.21) | 3.56 (× 1.21) |
| Multiple RGB images | 2.01 | 1.39 (× 1.45) | 1.39 (× 1.45) | 1.23 (× 1.63) | 1.23 (× 1.63) |
| Multiple ARGB images | 4.70 | 4.54 (× 1.04) | 4.55 (× 1.03) | 1.36 (× 3.47) | 1.35 (× 3.49) |
| Rotated ARGB images | 11.9 | 11.8 (× 1.01) | 11.8 (× 1.01) | 1.51 (× 7.87) | 1.51 (× 7.87) |
| Multiple labels | 5.56 | 5.41 (× 1.03) | 5.42 (× 1.03) | 3.66 (× 1.52) | 3.66 (× 1.52) |
| Screen sized text | 28.1 | 27.3 (× 1.03) | 27.3 (× 1.03) | 15.0 (× 1.87) | 15.0 (× 1.87) |
| Multiple arcs | 1.72 | 1.71 (× 1.01) | 1.71 (× 1.01) | 1.57 (× 1.10) | 1.57 (× 1.10) |
| Containers | 5.18 | 4.96 (× 1.04) | 4.97 (× 1.04) | 3.26 (× 1.59) | 3.23 (× 1.61) |
| Containers with overlay | 18.3 | 17.6 (× 1.04) | 17.6 (× 1.04) | 5.94 (× 3.09) | 5.87 (× 3.12) |
| Containers with opa | 8.98 | 8.77 (× 1.02) | 8.77 (× 1.02) | 3.90 (× 2.30) | 3.86 (× 2.33) |
| Containers with opa_layer | 14.1 | 14.2 (× 1.00) | 14.2 (× 1.00) | 7.48 (× 1.89) | 7.48 (× 1.89) |
| Containers with scrolling | 13.0 | 12.2 (× 1.06) | 12.2 (× 1.06) | 7.54 (× 1.73) | 7.50 (× 1.73) |
| Widgets demo | 15.2 | 14.5 (× 1.05) | 14.5 (× 1.05) | 12.2 (× 1.25) | 12.1 (× 1.25) |
| **All scenes avg.** | 9.04 | 8.59 (× 1.05) | 8.60 (× 1.05) | 4.63 (× 1.95) | 4.61 (× 1.96) |

<!-- lvgl_bench:end time_480x272 -->

**Cycles per frame** in thousands (clock-independent), with the frames measured and the
pixels LVGL invalidated per frame (the same in every persona):

<!-- lvgl_bench:begin cycles_480x272 -->

| Scene | Frames | Invalidated pixels | **light** | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|---:|---:|---:|
| Empty screen | 89 | 130 560 | 455 | 390 | 390 | 223 | 223 |
| Moving wallpaper | 89 | 130 560 | 750 | 552 | 552 | 368 | 368 |
| Single rectangle | 89 | 11 162 | 84 | 75 | 75 | 58 | 58 |
| Multiple rectangles | 89 | 58 590 | 476 | 434 | 435 | 395 | 395 |
| Multiple RGB images | 89 | 22 530 | 224 | 154 | 154 | 137 | 137 |
| Multiple ARGB images | 89 | 22 530 | 522 | 504 | 505 | 150 | 150 |
| Rotated ARGB images | 89 | 23 225 | 1 321 | 1 304 | 1 305 | 168 | 168 |
| Multiple labels | 89 | 26 266 | 617 | 601 | 601 | 406 | 406 |
| Screen sized text | 150 | 130 560 | 3 115 | 3 036 | 3 036 | 1 668 | 1 667 |
| Multiple arcs | 89 | 3 410 | 191 | 190 | 190 | 174 | 174 |
| Containers | 56 | 33 937 | 575 | 551 | 551 | 362 | 358 |
| Containers with overlay | 89 | 130 560 | 2 036 | 1 956 | 1 957 | 660 | 651 |
| Containers with opa | 54 | 35 194 | 997 | 973 | 973 | 433 | 429 |
| Containers with opa_layer | 57 | 33 342 | 1 570 | 1 577 | 1 578 | 830 | 830 |
| Containers with scrolling | 150 | 130 560 | 1 444 | 1 358 | 1 359 | 837 | 833 |
| Widgets demo | 606 | 87 757 | 1 684 | 1 605 | 1 606 | 1 350 | 1 347 |

<!-- lvgl_bench:end cycles_480x272 -->

**The GPU's part**: the share of the frame-buffer writes made by the GPU (the rest by the
CPU through the VRAM window) / the GPU busy cycles as a share of the frame time; and the
refresh's share of the VRAM cycles:

<!-- lvgl_bench:begin gpu_480x272 -->

| Scene | **essential** | **classic** | **performance** | **ultra** | Refresh, share of the VRAM cycles |
|---|---:|---:|---:|---:|---:|
| Empty screen | 93 % / 20 % | 93 % / 20 % | 100 % / 41 % | 100 % / 41 % | 3 % |
| Moving wallpaper | 96 % / 38 % | 96 % / 38 % | 100 % / 62 % | 100 % / 62 % | 3 % |
| Single rectangle | 92 % / 9 % | 92 % / 9 % | 100 % / 14 % | 100 % / 14 % | 3 % |
| Multiple rectangles | 95 % / 7 % | 95 % / 7 % | 100 % / 9 % | 100 % / 9 % | 3 % |
| Multiple RGB images | 97 % / 22 % | 97 % / 22 % | 100 % / 26 % | 100 % / 26 % | 3 % |
| Multiple ARGB images | 41 % / 2 % | 41 % / 2 % | 100 % / 32 % | 100 % / 33 % | 3 % |
| Rotated ARGB images | 38 % / 1 % | 38 % / 1 % | 100 % / 65 % | 100 % / 65 % | 3 % |
| Multiple labels | 75 % / 2 % | 75 % / 2 % | 100 % / 7 % | 100 % / 7 % | 3 % |
| Screen sized text | 69 % / 3 % | 69 % / 3 % | 100 % / 11 % | 100 % / 11 % | 3 % |
| Multiple arcs | 74 % / 1 % | 74 % / 1 % | 90 % / 2 % | 90 % / 2 % | 3 % |
| Containers | 79 % / 7 % | 79 % / 7 % | 95 % / 15 % | 95 % / 15 % | 3 % |
| Containers with overlay | 52 % / 5 % | 52 % / 5 % | 99 % / 40 % | 99 % / 40 % | 3 % |
| Containers with opa | 40 % / 2 % | 40 % / 2 % | 98 % / 18 % | 98 % / 18 % | 3 % |
| Containers with opa_layer | 45 % / 2 % | 45 % / 2 % | 84 % / 11 % | 84 % / 11 % | 3 % |
| Containers with scrolling | 83 % / 8 % | 83 % / 8 % | 97 % / 19 % | 97 % / 19 % | 3 % |
| Widgets demo | 84 % / 6 % | 84 % / 6 % | 92 % / 8 % | 92 % / 8 % | 3 % |

<!-- lvgl_bench:end gpu_480x272 -->

**The software baseline with the CPU flush** instead of DIRECT (LVGL renders a tenth of
the screen at a time into a buffer in the zero-wait data memory, and the CPU copies it
into the frame): the choice of the baseline, measured.

<!-- lvgl_bench:begin flush_480x272 -->

| Scene | DIRECT, ms | CPU flush, ms (render + flush) | CPU flush / DIRECT |
|---|---:|---:|---:|
| Empty screen | 4.10 | 9.30 (7.42 + 1.88) | 2.27 |
| Moving wallpaper | 6.75 | 13.5 (11.7 + 1.88) | 2.00 |
| Single rectangle | 0.75 | 1.16 (0.97 + 0.20) | 1.54 |
| Multiple rectangles | 4.29 | 6.08 (4.94 + 1.14) | 1.42 |
| Multiple RGB images | 2.01 | 2.51 (2.08 + 0.43) | 1.25 |
| Multiple ARGB images | 4.70 | 5.20 (4.77 + 0.43) | 1.11 |
| Rotated ARGB images | 11.9 | 12.7 (12.3 + 0.38) | 1.06 |
| Multiple labels | 5.56 | 6.10 (5.57 + 0.53) | 1.10 |
| Screen sized text | 28.1 | 98.4 (96.5 + 1.88) | 3.51 |
| Multiple arcs | 1.72 | 1.93 (1.82 + 0.10) | 1.12 |
| Containers | 5.18 | 7.38 (6.86 + 0.52) | 1.42 |
| Containers with overlay | 18.3 | 26.2 (24.3 + 1.88) | 1.43 |
| Containers with opa | 8.98 | 11.3 (10.7 + 0.54) | 1.25 |
| Containers with opa_layer | 14.1 | 16.7 (16.2 + 0.51) | 1.18 |
| Containers with scrolling | 13.0 | 23.6 (21.7 + 1.88) | 1.81 |
| Widgets demo | 15.2 | 32.2 (30.9 + 1.27) | 2.12 |
| **All scenes avg.** | 9.04 | 17.1 | 1.90 |

<!-- lvgl_bench:end flush_480x272 -->

**The pixels against the software renderer's**: each scene's third frame dumped from
the VRAM by every GPU persona, against `light`'s; the pixels that differ, and the
largest difference of an RGB565 field (R, G, B; of 31, 63, 31). `essential` and
`classic` draw exactly LVGL's pixels; `performance` and `ultra` too, but for the
rotated images (`approx` TRANSFORM: bilinear, within the bound of the
[extensions](lvgl_guide.md#42-extensions)):

<!-- lvgl_bench:begin frames_480x272 -->

| Scene | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|
| Empty screen | 0 | 0 | 0 | 0 |
| Moving wallpaper | 0 | 0 | 0 | 0 |
| Single rectangle | 0 | 0 | 0 | 0 |
| Multiple rectangles | 0 | 0 | 0 | 0 |
| Multiple RGB images | 0 | 0 | 0 | 0 |
| Multiple ARGB images | 0 | 0 | 0 | 0 |
| Rotated ARGB images | 0 | 0 | 1 029 (2, 2, 2) | 1 029 (2, 2, 2) |
| Multiple labels | 0 | 0 | 0 | 0 |
| Screen sized text | 0 | 0 | 0 | 0 |
| Multiple arcs | 0 | 0 | 0 | 0 |
| Containers | 0 | 0 | 0 | 0 |
| Containers with overlay | 0 | 0 | 0 | 0 |
| Containers with opa | 0 | 0 | 0 | 0 |
| Containers with opa_layer | 0 | 0 | 0 | 0 |
| Containers with scrolling | 0 | 0 | 0 | 0 |
| Widgets demo | 0 | 0 | 0 | 0 |

<!-- lvgl_bench:end frames_480x272 -->

**Where the CPU's cycles go**: the whole run (every frame, the scenes' set-ups and LVGL's
timers too), from the bench's profile (`--profile`: each cycle counted to the code word
fetched last, functions from the firmware's symbols):

<!-- lvgl_bench:begin profile_480x272 -->

| CPU cycles of the run | **light** | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|---:|
| LVGL's software renderer (blends, masks, transforms, glyph bitmaps) | 1 421 M (51 %) | 1 260 M (47 %) | 1 260 M (47 %) | 356 M (19 %) | 356 M (19 %) |
| text layout and glyph look-up (LVGL) | 380 M (14 %) | 381 M (14 %) | 381 M (14 %) | 364 M (20 %) | 364 M (20 %) |
| the rest of LVGL (objects, styles, events, layout, draw tasks, memory) | 730 M (26 %) | 730 M (27 %) | 730 M (27 %) | 749 M (41 %) | 749 M (41 %) |
| the Belenos driver and its draw unit | 0 M (0 %) | 30 M (1 %) | 28 M (1 %) | 161 M (9 %) | 157 M (9 %) |
| functions below 0.2 % of a scene each | 263 M (9 %) | 272 M (10 %) | 275 M (10 %) | 214 M (12 %) | 214 M (12 %) |
| **total** | 2 794 M | 2 673 M (× 1.05) | 2 674 M (× 1.04) | 1 844 M (× 1.52) | 1 840 M (× 1.52) |
| largest functions | `lv_draw_sw_blend_color_to_rgb565` 24 %, `lv_font_get_bitmap_fmt_txt` 7 %, `lv_draw_sw_blend_image_to_rgb565` 7 %, `get_selector_style_prop` 4 %, `get_prop_core` 4 % | `lv_draw_sw_blend_color_to_rgb565` 19 %, `lv_font_get_bitmap_fmt_txt` 8 %, `lv_draw_sw_blend_image_to_rgb565` 7 %, `get_selector_style_prop` 4 %, `get_prop_core` 4 % | `lv_draw_sw_blend_color_to_rgb565` 19 %, `lv_font_get_bitmap_fmt_txt` 8 %, `lv_draw_sw_blend_image_to_rgb565` 7 %, `get_selector_style_prop` 4 %, `get_prop_core` 4 % | `lv_draw_sw_blend_color_to_rgb565` 7 %, `get_selector_style_prop` 6 %, `get_prop_core` 6 %, `lv_memset` 5 %, `lv_text_get_next_line.part.0` 5 % | `lv_draw_sw_blend_color_to_rgb565` 7 %, `get_selector_style_prop` 6 %, `get_prop_core` 6 %, `lv_memset` 5 %, `lv_text_get_next_line.part.0` 5 % |

<!-- lvgl_bench:end profile_480x272 -->

### 2.4 Results at 800 × 480

The same benchmark on a 800 × 480 frame (the benchmark picks larger fonts and more objects
above 320 × 240 and 800 × 480 pixels: compare with LVGL 9 results at this size only).

<!-- lvgl_bench:begin summary_800x480 -->

| Persona | Time per frame, ms | Frame rate, FPS | Cycles per frame, k | Speed-up | Frame-buffer writes by the GPU | GPU busy |
|---|---:|---:|---:|---:|---:|---:|
| **light** | 21.9 | 142 | 2 429 | — | 0 % | 0 % |
| **essential** | 20.8 | 179 | 2 303 | × 1.05 | 73 % | 15 % |
| **classic** | 20.8 | 179 | 2 304 | × 1.05 | 73 % | 15 % |
| **performance** | 10.8 | 255 | 1 194 | × 2.03 | 96 % | 30 % |
| **ultra** | 10.7 | 255 | 1 191 | × 2.04 | 96 % | 30 % |

<!-- lvgl_bench:end summary_800x480 -->

Time per frame in ms at 111 MHz, and the speed-up against `light`:

<!-- lvgl_bench:begin time_800x480 -->

| Scene | **light** | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|---:|
| Empty screen | 5.97 | 4.88 (× 1.22) | 4.88 (× 1.22) | 3.31 (× 1.80) | 3.31 (× 1.80) |
| Moving wallpaper | 13.0 | 8.99 (× 1.45) | 8.99 (× 1.45) | 7.24 (× 1.80) | 7.24 (× 1.80) |
| Single rectangle | 0.93 | 0.69 (× 1.35) | 0.69 (× 1.35) | 0.52 (× 1.79) | 0.52 (× 1.79) |
| Multiple rectangles | 5.17 | 3.79 (× 1.36) | 3.80 (× 1.36) | 3.57 (× 1.45) | 3.57 (× 1.45) |
| Multiple RGB images | 5.67 | 4.46 (× 1.27) | 4.47 (× 1.27) | 4.33 (× 1.31) | 4.33 (× 1.31) |
| Multiple ARGB images | 17.4 | 16.8 (× 1.04) | 16.8 (× 1.04) | 4.76 (× 3.66) | 4.76 (× 3.66) |
| Rotated ARGB images | 34.0 | 33.5 (× 1.01) | 33.5 (× 1.01) | 4.00 (× 8.51) | 3.99 (× 8.52) |
| Multiple labels | 24.5 | 24.0 (× 1.02) | 24.0 (× 1.02) | 17.3 (× 1.42) | 17.3 (× 1.42) |
| Screen sized text | 63.5 | 62.3 (× 1.02) | 62.3 (× 1.02) | 29.8 (× 2.13) | 29.8 (× 2.13) |
| Multiple arcs | 5.80 | 5.79 (× 1.00) | 5.79 (× 1.00) | 5.66 (× 1.03) | 5.66 (× 1.03) |
| Containers | 10.5 | 10.2 (× 1.03) | 10.2 (× 1.03) | 6.97 (× 1.51) | 6.89 (× 1.53) |
| Containers with overlay | 59.4 | 57.5 (× 1.03) | 57.5 (× 1.03) | 18.6 (× 3.19) | 18.5 (× 3.22) |
| Containers with opa | 18.6 | 18.1 (× 1.02) | 18.1 (× 1.02) | 8.19 (× 2.27) | 8.11 (× 2.29) |
| Containers with opa_layer | 31.1 | 30.8 (× 1.01) | 30.9 (× 1.01) | 19.3 (× 1.61) | 19.3 (× 1.61) |
| Containers with scrolling | 22.2 | 20.1 (× 1.10) | 20.1 (× 1.10) | 13.0 (× 1.70) | 12.9 (× 1.72) |
| Widgets demo | 32.3 | 30.1 (× 1.07) | 30.2 (× 1.07) | 25.6 (× 1.26) | 25.5 (× 1.27) |
| **All scenes avg.** | 21.9 | 20.8 (× 1.05) | 20.8 (× 1.05) | 10.8 (× 2.03) | 10.7 (× 2.04) |

<!-- lvgl_bench:end time_800x480 -->

Cycles per frame in thousands:

<!-- lvgl_bench:begin cycles_800x480 -->

| Scene | Frames | Invalidated pixels | **light** | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|---:|---:|---:|
| Empty screen | 89 | 384 000 | 662 | 542 | 542 | 367 | 367 |
| Moving wallpaper | 89 | 384 000 | 1 448 | 998 | 998 | 803 | 803 |
| Single rectangle | 89 | 33 276 | 104 | 77 | 77 | 58 | 58 |
| Multiple rectangles | 89 | 190 414 | 574 | 421 | 422 | 396 | 396 |
| Multiple RGB images | 89 | 81 253 | 629 | 496 | 497 | 481 | 481 |
| Multiple ARGB images | 89 | 81 253 | 1 936 | 1 866 | 1 867 | 528 | 528 |
| Rotated ARGB images | 89 | 63 525 | 3 776 | 3 722 | 3 723 | 444 | 443 |
| Multiple labels | 89 | 99 430 | 2 725 | 2 660 | 2 662 | 1 918 | 1 918 |
| Screen sized text | 150 | 384 000 | 7 047 | 6 911 | 6 911 | 3 308 | 3 306 |
| Multiple arcs | 89 | 8 078 | 644 | 642 | 643 | 628 | 628 |
| Containers | 84 | 65 085 | 1 169 | 1 130 | 1 130 | 773 | 765 |
| Containers with overlay | 89 | 384 000 | 6 596 | 6 377 | 6 379 | 2 064 | 2 052 |
| Containers with opa | 83 | 65 870 | 2 061 | 2 013 | 2 013 | 909 | 901 |
| Containers with opa_layer | 81 | 67 496 | 3 448 | 3 424 | 3 425 | 2 147 | 2 147 |
| Containers with scrolling | 150 | 384 000 | 2 461 | 2 231 | 2 233 | 1 444 | 1 432 |
| Widgets demo | 606 | 288 793 | 3 591 | 3 345 | 3 348 | 2 842 | 2 835 |

<!-- lvgl_bench:end cycles_800x480 -->

The GPU's part, as at 480 × 272:

<!-- lvgl_bench:begin gpu_800x480 -->

| Scene | **essential** | **classic** | **performance** | **ultra** | Refresh, share of the VRAM cycles |
|---|---:|---:|---:|---:|---:|
| Empty screen | 97 % / 42 % | 97 % / 42 % | 100 % / 66 % | 100 % / 66 % | 10 % |
| Moving wallpaper | 99 % / 66 % | 99 % / 66 % | 100 % / 83 % | 100 % / 83 % | 10 % |
| Single rectangle | 97 % / 26 % | 97 % / 26 % | 100 % / 37 % | 100 % / 37 % | 10 % |
| Multiple rectangles | 99 % / 26 % | 99 % / 26 % | 100 % / 28 % | 100 % / 28 % | 10 % |
| Multiple RGB images | 99 % / 27 % | 99 % / 26 % | 100 % / 28 % | 100 % / 28 % | 10 % |
| Multiple ARGB images | 39 % / 2 % | 39 % / 2 % | 100 % / 34 % | 100 % / 34 % | 10 % |
| Rotated ARGB images | 37 % / 1 % | 37 % / 1 % | 100 % / 71 % | 100 % / 71 % | 10 % |
| Multiple labels | 75 % / 2 % | 75 % / 2 % | 100 % / 6 % | 100 % / 6 % | 10 % |
| Screen sized text | 71 % / 3 % | 71 % / 3 % | 100 % / 15 % | 100 % / 15 % | 10 % |
| Multiple arcs | 74 % / 1 % | 74 % / 1 % | 81 % / 1 % | 81 % / 1 % | 10 % |
| Containers | 78 % / 7 % | 78 % / 7 % | 93 % / 14 % | 93 % / 14 % | 10 % |
| Containers with overlay | 52 % / 5 % | 52 % / 5 % | 98 % / 40 % | 98 % / 40 % | 10 % |
| Containers with opa | 37 % / 2 % | 37 % / 2 % | 96 % / 17 % | 96 % / 17 % | 10 % |
| Containers with opa_layer | 42 % / 2 % | 42 % / 2 % | 73 % / 8 % | 73 % / 8 % | 10 % |
| Containers with scrolling | 88 % / 13 % | 88 % / 13 % | 97 % / 25 % | 97 % / 25 % | 10 % |
| Widgets demo | 89 % / 11 % | 89 % / 11 % | 93 % / 14 % | 93 % / 14 % | 10 % |

<!-- lvgl_bench:end gpu_800x480 -->

The pixels against `light`'s, as at 480 × 272:

<!-- lvgl_bench:begin frames_800x480 -->

| Scene | **essential** | **classic** | **performance** | **ultra** |
|---|---:|---:|---:|---:|
| Empty screen | 0 | 0 | 0 | 0 |
| Moving wallpaper | 0 | 0 | 0 | 0 |
| Single rectangle | 0 | 0 | 0 | 0 |
| Multiple rectangles | 0 | 0 | 0 | 0 |
| Multiple RGB images | 0 | 0 | 0 | 0 |
| Multiple ARGB images | 0 | 0 | 0 | 0 |
| Rotated ARGB images | 0 | 0 | 3 145 (2, 2, 2) | 3 145 (2, 2, 2) |
| Multiple labels | 0 | 0 | 0 | 0 |
| Screen sized text | 0 | 0 | 0 | 0 |
| Multiple arcs | 0 | 0 | 0 | 0 |
| Containers | 0 | 0 | 0 | 0 |
| Containers with overlay | 0 | 0 | 0 | 0 |
| Containers with opa | 0 | 0 | 0 | 0 |
| Containers with opa_layer | 0 | 0 | 0 | 0 |
| Containers with scrolling | 0 | 0 | 0 | 0 |
| Widgets demo | 0 | 0 | 0 | 0 |

<!-- lvgl_bench:end frames_800x480 -->

### 2.5 Deviations from the unmodified benchmark

The benchmark's source is not changed. Its configuration and port differ from LVGL's
defaults as follows (`bench/lvgl_bench/sw/lv_conf.h` holds the whole list):

| Item | Here | LVGL default / the benchmark's own | Why |
|---|---|---|---|
| `LV_MEM_SIZE` | 128 KB | 64 KB | the benchmark asks for at least 128 KB |
| `LV_USE_SYSMON`, `LV_USE_PERF_MONITOR` | 1 | 0 | the benchmark's measurement (its Kconfig implies both); the label stays on screen (`LV_USE_PERF_MONITOR_LOG_MODE` 0, the default) |
| `LV_USE_LOG`, `LV_LOG_LEVEL` | 1, `WARN` | 0 | the console; the level the benchmark asks for |
| `LV_FONT_MONTSERRAT_20`, `_24`, `_26` | 1 | 0 | required by the benchmark |
| `LV_USE_DEMO_BENCHMARK`, `LV_USE_DEMO_WIDGETS` | 1 | 0 | the benchmark and its last scene |
| `LV_ASSERT_HANDLER` | ends the simulation | spins | a failed run ends (none happened) |
| `LV_USE_CHECK_ARG` | 1, kept | 1 | LVGL's default; the benchmark's summary warns that it may slow the widgets demo (the bench prints the same warning, `LB WARN`) |
| `LV_DRAW_LAYER_SIMPLE_BUF_SIZE` | 24 KB at 480 × 272, 38 KB at 800 × 480 | 24 KB | at least 1/20 of the screen, which the benchmark warns about otherwise (800 × 480 only) |
| LVGL's clock | the lockstep clock ([method](#22-method)) | the application's millisecond tick | the same frames in every persona, and simulation time bounded by the frames, not by 69 s of real time (7.7 G cycles at 111 MHz) |
| Measurement | the bench's cycle counter on LVGL's display events | LVGL's millisecond tick on the same events | cycle resolution: many frames take less than a millisecond |
| Summary | printed by the bench in LVGL's CSV format from the cycle counts (`LB CSV` lines of the log; the CPU load column empty) | `lv_demo_benchmark_summary_display`: LVGL's table and CSV log | under the lockstep clock LVGL's millisecond figures read 0, and the summary's compiler-optimisation probe would spin for about a billion cycles. `--tick real` runs LVGL's own summary |
| Display | DIRECT mode into the frame in the VRAM, one buffer | the port's choice | no copy (the draw buffer is the whole screen, so the benchmark's 1/10-screen warning does not apply) |
| Draw unit | the extensions built, a VRAM pool of W × H × 2 bytes (the VRAM's second frame) with LVGL's layers in it, `approx` GRAD \| TRANSFORM (`LB_APPROX`, `--approx`; the `LB CFG` line of the log states the mode) | — (the port's choice) | the personas' gradients and image transforms used: those draws are then within a field or two of LVGL's ([same pixels?](#26-reading-the-results)); `--approx 0` runs the exact draws only |
| `PROF` bench register | written at each scene change (one store) | — | the CPU profile of a `--profile` run; no effect on the timing otherwise |

### 2.6 Reading the results

- **Where the time goes.** Without a GPU, half of the CPU's cycles are LVGL's software
  renderer (its RGB565 colour blend alone a quarter: text, fills, translucency), a
  quarter LVGL's object tree, styles, events and draw tasks, an eighth text layout and
  glyph look-up ([profile](#23-results-at-480--272)). The GPU personas take the
  renderer's part they can draw and leave the rest: with blending (`performance`,
  `ultra`) the renderer falls from 1.42 G to 0.36 G cycles of the run (now anti-aliased
  corners, arcs, masks and ARGB8888 layers), and LVGL's own work (0.75 G) and text
  layout (0.36 G) become most of the frame time; the driver and its draw unit take 9 %
  (the GPU commands, the glyph and image look-ups, and waits for FIFO room behind long
  GPU draws: the rotated images' textured rectangles). Each invalidated area still
  costs tens of thousands of cycles of LVGL's work besides its pixels ("Single
  rectangle": one area of 11 000 pixels, 58 000 cycles with the GPU drawing all of it).
- **The personas against each other.** `essential` and `classic` draw the same tasks
  ([what each persona offloads](lvgl_guide.md#43-what-each-persona-offloads)): opaque
  fills and borders (the straight parts of rounded ones), RGB565 images staged in the
  pool and layers in the pool; `classic`'s gradients do not occur in the benchmark (its
  only one, the widgets demo's chart, is translucent), nor do its nearest-sampled
  transforms (the benchmark's rotated images are ARGB8888 with `antialias` on): they
  take the same time, within 0.04 % on average and 0.2 % per scene, with the same share of
  the writes by the GPU. Blending is
  what moves the benchmark: `performance` and `ultra` also draw the translucent fills,
  borders, images and layers, every label and every image with an alpha channel,
  rotated ones included, × 1.95 to × 2.04 on average and up to × 8.5 ("Rotated ARGB
  images"). `ultra`'s 32-word FIFO, triangles and the rest give nothing more here (LVGL
  has no task they map: [what is not offloaded](lvgl_guide.md#43-what-each-persona-offloads)).
- **Text** gains × 1.4 to × 2.1 with blending: each glyph is one `EXEC_EXPAND MASK`
  from its 4-bpp coverage mask, staged in the pool at its first use; LVGL's line
  breaking and glyph look-up (`lv_text_get_next_line`, `lv_font_get_glyph_dsc_fmt_txt`)
  then take most of "Screen sized text".
- **The images.** The benchmark's 100 × 100 RGB565 logo (constant data, with row
  padding) is staged in the pool at its first draw and then copied by the GPU, tiled for
  "Moving wallpaper" (× 1.3 to × 1.5 in every GPU persona, × 1.8 to × 2.0 with the
  blended perf-monitor label). The ARGB8888 logo and the 80 × 80 avatar need the
  per-pixel alpha (`performance`, `ultra`): each is converted once into an RGB565A8
  block of the pool (LVGL's own truncation of the colours) and then drawn by a GPU copy
  with its alpha plane, exactly as LVGL blends it: "Multiple ARGB images" × 3.5 to
  × 3.7, and the containers and the widgets demo, which show them too, take 4 to 30 %
  less time than before. "Rotated ARGB images" (`approx` TRANSFORM): LVGL's transform set-up
  replicated by the draw unit, one bilinear `EXEC_TEXRECT` per 64 × 64 tile with
  transparent taps outside the image, × 7.9 at 480 × 272 and × 8.5 at 800 × 480: the
  scene that cost the most without a GPU (LVGL's transform, its divisions and its
  ARGB8888 blend) now takes a third of the average frame (1.5 ms against 4.6) where it took twice
  it. Without blending
  (`essential`, `classic`) these scenes stay at × 1.01 to × 1.04.
- **The baseline.** `light` draws in DIRECT mode through the VRAM window: the window costs
  little (its wait cycles are about 1 % of the frame time: the read-ahead serves LVGL's
  reads, writes are posted). The CPU flush (a tenth of the screen in the zero-wait data
  memory, copied into the frame) is slower here, 1.9 times on average: LVGL then renders
  each frame in strips of 28 lines and pays its per-area work once per strip. DIRECT is
  thus the faster software baseline, and the speed-ups are against it.
- **The refresh** reads the frame at the panel's rate in every run: 3 % of the VRAM cycles
  at 480 × 272, 10 % at 800 × 480. It slows the CPU's window accesses and the GPU only when they meet it.
- **Same pixels?** `essential` and `classic` draw exactly LVGL's pixels in every
  dumped frame: their draws are bit for bit the software renderer's. So do
  `performance` and `ultra` in every scene but "Rotated ARGB images": their blending is
  LVGL's own rule (`MIX5`), and their RGB565A8 copies of the ARGB8888 images use LVGL's
  truncation. The rotated images are bilinear-sampled by the GPU (`approx` TRANSFORM):
  1 029 pixels of the dumped frame differ from `light`'s at 480 × 272 and 3 145 at
  800 × 480, by at most 2 of 31 or 63 in a field. The bound of a bilinear transform
  ([extensions](lvgl_guide.md#42-extensions)) is the kernel's, 3, 5 and 3 for R, G and
  B, plus a position term of at most 2/32 of the contrast between neighbouring texels,
  and up to the whole contrast at the image's edge, where LVGL or the GPU may skip the
  pixel; the largest difference the host test measured in its scenes is (2, 7, 2).
  With `--approx 0` (no transform, no gradient by the GPU) every dumped frame of
  `performance` is identical to `light`'s, at 5.27 ms per frame (× 1.71; before the alpha copy
  and `MIX5` the exact mode drew only what `essential` draws, × 1.06): the exact draws alone, the rotated images back on
  the CPU (11.6 ms, × 1.03).
- **Before the alpha copy and bilinear sampling.**
  The previous results (the same bench, `approx` BLEND \| GRAD, the blending then
  approximate; LVGL's code not yet pinned) against these, ms per frame:

  | | `light` | `essential` | `classic` | `performance` | `ultra` |
  |---|---:|---:|---:|---:|---:|
  | 480 × 272, before | 9.25 | 8.76 (× 1.06) | 8.58 (× 1.08) | 5.88 (× 1.57) | 5.83 (× 1.59) |
  | 480 × 272, now | 9.04 | 8.59 (× 1.05) | 8.60 (× 1.05) | 4.63 (× 1.95) | 4.61 (× 1.96) |
  | 800 × 480, before | 21.4 | 20.4 (× 1.05) | 20.8 (× 1.03) | 14.2 (× 1.50) | 14.3 (× 1.50) |
  | 800 × 480, now | 21.9 | 20.8 (× 1.05) | 20.8 (× 1.05) | 10.8 (× 2.03) | 10.7 (× 2.04) |

  `light`, `essential` and `classic` draw the same frames as before with the same
  work: their times differ from the previous ones by up to 2.3 % (`light` 2.2 % faster
  at 480 × 272 and 2.3 % slower at 800 × 480, `essential` 1.9 % faster and 1.7 %
  slower), by the placement of LVGL's code, which then moved with the size of the
  code linked before it (the bench's main, the driver and the glue) and which the
  bench now pins (for `light` at 480 × 272, checked to the cycle: its firmware rebuilt
  with the previous driver and glue gave the previous count on this RTL); the
  speed-ups of `essential` and `classic` moved with it.
  `performance` and `ultra` are 21 % faster at 480 × 272 and 24 to 25 % at 800 × 480,
  all of it on the scenes with ARGB8888 images (above), and draw LVGL's exact pixels
  where they differed by up to 2 per field in every scene before (the blending).
  The pinning fixes one placement of LVGL's code, the same in every build, so that the
  personas are compared on the same code; another placement would move the figures
  again, by up to the few per cent seen here, most where the software renderer runs.
- **Compared with published LVGL 9 figures**, these are the frames of a system that keeps
  up with the 30 Hz refresh ([method](#22-method)); a system slower than that renders fewer
  frames, each with more change. The memories are zero-wait, which an FPGA or a
  flash-based MCU is not.

---

## 3. GPU primitives

The GPU's best-case throughput, with no VRAM contention, is specified and checked
operation by operation (fills, copies with and without the destination read, keyed
copies, scrolls, CL swaps, text expansion, textured spans, gradients, blending, lines,
triangles, palette remap and the mask plane, at every depth and at read latencies 1
and 2) in the [performance section](gpu_commands.md#24-performance) of the GPU command
set; the `gpu_perf` test measures each figure and fails when one is off by more than a
cycle. The main ones at 16 bpp:

| Operation, 16 bpp | Cycles per pixel |
|---|---|
| FILL (ops 0, 1, 13–15), also with a gradient across the rows | 0.5 (one destination word per cycle) |
| FILL with a gradient along the run | 1 |
| COPY along rows, COPY_TRANSP | 1 (a source and a destination word every 2 cycles) |
| COPY with blending (`performance`, `ultra`) | 2 |
| FILL with blending | 1 |
| EXPAND (text), TEXSPAN | 1 |
| Line, solid | 1 per step; anti-aliased 2 per pixel drawn |
| Triangle (FILL) | about 480 cycles for a 48 × 32 triangle |

Each primitive costs about ten GPU cycles on top of its pixels, and its command words one
CPU store each: the GPU pays off from runs of about a dozen pixels.

---

## 4. Reproducing the results

From `bench/lvgl_bench` ([simulation guide](simulation_guide.md#9-lvgl-benchmark-bench)),
with the aRVern repository next to this one:

```bash
python3 bin/lvgl_bench.py run --res 480x272 -j 3 --dump 3 --profile   # the five personas, 3 at a time
python3 bin/lvgl_bench.py run --res 800x480 -j 3 --dump 3
python3 bin/lvgl_bench.py run --res 480x272 --persona light --flush cpu --tag cpu
python3 bin/lvgl_bench.py frames --res 480x272        # the frames against light's
python3 bin/lvgl_bench.py frames --res 800x480
python3 bin/lvgl_bench.py run --res 480x272 --persona performance --approx 0 --tag approx0 --dump 3
python3 bin/lvgl_bench.py frames --res 480x272 --tag approx0   # the exact mode against light's
python3 bin/lvgl_bench.py tables --update             # the tables of this page
```

The tables of §2 are generated from `bench/lvgl_bench/results/` by
`bin/lvgl_bench_tables.py` (`--check` tells whether this page is up to date with them).
The cycle counts are exact for a given RTL, firmware and LVGL: a run gives the same
figures again.

---

## See Also

- [lvgl_guide.md](lvgl_guide.md) — the LVGL driver and its GPU draw unit: what the GPU draws
- [gpu_commands.md](gpu_commands.md#24-performance) — the GPU's cycles per pixel
- [integration_guide.md](integration_guide.md#21-personas) — the personas
- [synthesis_guide.md](synthesis_guide.md) — the area of each persona, at the 9.0 ns period used here
- [simulation_guide.md](simulation_guide.md#9-lvgl-benchmark-bench) — the benchmark bench
