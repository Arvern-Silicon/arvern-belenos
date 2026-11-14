# Changelog

All notable changes to Belenos are recorded here. The version is the one the hardware
reports in `BLNS_ID`; what a major, minor or patch version may change is described in
[versions](doc/register_map.md#3-versions) for the hardware and in the
[interface policy](doc/driver_guide.md#41-interface-policy) for the driver.

## Versions

| Version | Date |
|---|---|
| [0.1.0-preview](#v0.1.0-preview) | Nov 14, 2026 |

<a id="v0.1.0-preview"></a>

## 0.1.0-preview

First public release, a preview for evaluation, integration trials and feedback.

### Hardware

- **Graphic controller:** a 32-bit frame-buffer controller with two AHB-Lite ports (a 4 KB
  register port and a VRAM window), a single-port video memory, 1 to 16 bits per pixel,
  hardware palettes and a programmable RGB888 LUT, one to four frame pointers, eight scan
  orientations, timer or manual refresh ([features](README.md#what-it-supports),
  [integration guide](doc/integration_guide.md)).
- **2D GPU:** fill, copy, transparent copy, sixteen raster operations, text expansion,
  textured spans, command lists, fences, a FIFO low-water threshold (`GPU_FIFO_LOW`) and
  the discard of a command cut by its pusher (`GPU_CTRL` `DISCARD`); optionally x/y
  coordinates with clipping, affine blits, gradient fills, alpha blending, triangles,
  palette remap, a mask plane on copies and an immediate source of CPU pixels
  ([GPU commands](doc/gpu_commands.md)).
- **Lines:** solid and dashed 1-pixel lines with raster operations, transparency, clipping
  and skip-last, and Wu-style anti-aliased lines with blending (`GPU_LINE_EN`).
- **Hardware cursor:** 32 × 32 at 2 bpp from the VRAM, three RGB888 colours and
  transparency, a hotspot and a frame-latched position, laid over the frame before the
  display driver (`CURSOR_EN`).
- **Per-pixel alpha:** RGB565A8 sources (`SET_SRC` `SRC_FMT` 5, `SET_AUX` `ALPHA_PLANE`)
  for copies and textures, and the `SET_ALPHA` `MIX5` blend rule, bit-exact with LVGL's
  RGB565 blend; part of `GPU_BLEND_EN` ([alpha planes](doc/gpu_commands.md#26-alpha-planes-rgb565a8),
  [blending](doc/gpu_commands.md#16-blending)).
- **Bilinear sampling:** `GPU_BILINEAR_EN` (needs `GPU_XY_EN`; `BLNS_CFG2` [12]):
  `SET_AUX` `TEX_FILTER` for textured spans, affine blits and textured triangles, with a
  clamped or transparent border under `BOUND`
  ([bilinear sampling](doc/gpu_commands.md#27-bilinear-sampling)).
- **VRAM bound faults (`ERR_CAUSE` 5):** every pixel before the faulting one is drawn, in
  every build ([errors](doc/gpu_commands.md#6-errors-abort-and-flush)).
- **Display drivers:** MIPI-DBI for ILI9341-class panels over an 8080-16 bus or SPI,
  MIPI-DPI for parallel RGB panels (programmable timing, nearest-neighbour or bilinear
  scaling, its own pixel clock), the same driver with a TMDS encoder for HDMI (DVI, or HDMI
  with InfoFrames, stereo audio from I2S and the DDC lines), and the Belenos Display
  Interface for any other display.
- **Personas:** five ready-made feature sets, `light`, `essential`, `classic`,
  `performance` and `ultra`, from a display controller to a GPU for games
  ([cost by persona](README.md#cost-by-persona)).
- **Integration:** clock-gating request, debug freeze of the refresh and the GPU, optional
  user-mode check, registered VRAM-window response and posted writes.

### Software

- **Driver:** the bare-metal C driver library with its panel drivers, per-persona
  configuration headers (`sw/include/persona/`), and DDC / hot-plug support for HDMI
  ([driver guide](doc/driver_guide.md)).
- **LVGL:** the LVGL v9 display driver with a GPU draw unit: fills, borders, image and
  layer blits, blended draws exact with `MIX5`, RGB565A8 and ARGB8888 images, and image
  transforms under `LV_BELENOS_APPROX_TRANSFORM` ([LVGL guide](doc/lvgl_guide.md)).

### Verification

- **Simulation:** the RTL bench, directed tests across a sweep of configurations in four
  tiers, a constrained-random GPU command stream checked against a reference model, and
  functional coverage ([simulation guide](doc/simulation_guide.md),
  [verification guide](doc/verification_guide.md)).
- **Code coverage:** 100 % line, branch and toggle after waivers, every waiver argued in
  `sim/rtl_sim/run/waivers_cov.md`.
- **Formal proofs, lint and synthesis:** formal proofs of the VRAM arbiter, the FIFOs, the
  VRAM window, the register port and the DPI clock-domain crossings; Verilator and VC
  Static lint on every shared configuration; Design Compiler synthesis with scan
  insertion, the 9.0 ns period met in every configuration
  ([synthesis guide](doc/synthesis_guide.md)).
- **Software and boards:** driver host tests, an LVGL host test against LVGL's software
  renderer, the LVGL benchmark per persona ([performance](doc/performance.md)), and the
  board builds and application regressions in
  [`arvern-soc`](https://github.com/Arvern-Silicon/arvern-soc) (Sipeed Tang Console 138K
  and DE0-Nano-SoC).
