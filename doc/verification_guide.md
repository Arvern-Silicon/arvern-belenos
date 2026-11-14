<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos verification guide

*For verification engineers and contributors: what is verified and how — the bench and
its always-on checks, the tests and the random command stream, coverage and its waivers,
the driver's host tests, formal proofs, lint and clock-domain crossings, and the
documentation checks. How to run the simulations is in the
[simulation guide](simulation_guide.md); the GPU trace format in
[slipstream_trace_format.md](slipstream_trace_format.md).*

---

## Table of Contents

1. [Test architecture](#1-test-architecture)
    - [1.1 Bench](#11-bench)
    - [1.2 Tests](#12-tests)
    - [1.3 Random command stream](#13-random-command-stream)
2. [Coverage and waivers](#2-coverage-and-waivers)
3. [Driver host tests](#3-driver-host-tests)
4. [Formal proofs](#4-formal-proofs)
5. [Lint](#5-lint)
6. [Documentation checks](#6-documentation-checks)
- [See Also](#see-also)

---

## 1. Test architecture

### 1.1 Bench

The bench (`bench/verilog/tb_belenos.v`) instantiates Belenos with behavioural VRAM and
LUT macros, two AHB-Lite managers, ILI9341 panel models on both PHYs (8080 and SPI) and a
BDI driver model, and an optional ICG model driven by `hclk_en_o` (`BLNS_ICG_EN = 1`;
its enable is `hclk_en_o | ~hresetn`, the rule of the
[integration guide](integration_guide.md#61-clock-gating)).
Reference models check what the hardware produces: a GPU model (every
raster operation, swap and transparency case), a backend model that predicts the pixel
stream, and the panel models that rebuild the image the panel receives.
`BLNS_MACRO_FREECLK = 1` puts the VRAM and LUT macro models (and the VRAM read pipeline)
on the free-running clock instead of the gated `hclk`, the other placement the
integration guide allows.

Always on, in every test (`contract_check.v`), each violation an `ERROR:` line that fails
the test:

- **AHB-Lite port contract**, both ports, on every `hclk` edge: `hreadyout` and `hresp`
  never X; `hreadyout` high and OKAY with no data phase in progress; an ERROR is two
  cycles (`hreadyout` low then high, `hresp` high in both, held while the fabric stalls
  the second), never one; read data known on the active byte lanes of a completing OKAY
  read. The coverage bins `r_hresp_err` and `v_hresp_err` are raised here, by a
  well-formed ERROR only.
- **Clock request**: while `hclk_en_o` is low, no VRAM or LUT enable, no line-buffer write
  and both `hreadyout` high; with the macros on the free-running clock
  (`MACRO_FREECLK`) and `VRAM_RD_LAT > 1` or `VRAM_POISON`, no VRAM read still in flight
  (its data would move on while Belenos is not clocked).
- **Macro ports**: no X enable; no X address, write enable or enabled write-data lane with
  an enable active; no LUT access with `LUT_EN = 0`, no bank-1 address with
  `LUT_BANKS = 1`.
- **Outputs**: no X on a control output once the reset is done, nor on a data bus while
  it is qualified (`dpi_rgb_o` with DE, the BDI pixel with its valid, the BDI register
  bus with its select, `lcd_d_o` while driven).

At the end of every test (and of a skip) the model counters that are not already in the
error count fail it too: the 8080 and SPI panel models' protocol anomalies
(`anomaly_total`, counted from the end of the power-on reset and never cleared by a
test), the DPI panel model's timing errors, the
TMDS receiver's audio errors. The common check tasks (checked reads, polls, image, VRAM,
pixel-stream and panel-log compares) count their comparisons (`tb_checks`, printed as
`CHECKS:`); a test that passes with fewer than its minimum fails. The minimum is 1, or
the `min_checks` of the test in `run_config.json` (0 for a test whose comparisons are
all its own).

The other models and checkers in `bench/verilog/`:

| File | Role |
|---|---|
| `dpi_panel_model.v` | DPI panel: samples `dpi_*` on the panel clock with the polarities a test sets and rebuilds the image |
| `tmds_rx_model.v` | TMDS receiver check (`DIF_TYPE = 5`): decodes `tmds_o` and compares it with the DPI pins (video, control and island periods) |
| `ddc_eeprom_model.v` | the monitor side of the DDC: an I2C EEPROM holding a test EDID |
| `i2s_src_model.v` | I2S clock master and audio source for the HDMI audio input |
| `vram_shadow.v` | a shadow of the VRAM and pipelined bus drivers for the stress tests (whole-VRAM compare) |
| `vram_arb_check.v` | passive VRAM-arbiter checker, always on: grants, read valids and tags, priority, the refresh slot's request held until granted |
| `gpu_inv_check.v` | GPU invariants the RTL relies on instead of a register or a bit, always on: the decoder fields stable from S_LAT (set-up busy, engine drawing without run-ahead), the engine's fill colour stable while busy, no set-up state of a feature not built, set-up value ranges where read (box offsets, first pixel, multiplier operands, gradient remainder), pixel-aligned source rotations and DST-remap offsets, the cache's word below 2^VRAM_AW, the list request and the destination pitch against reference counters, the `GPU_FIFO_LOW` event against a reference (`FREE` crossing `THRESH`, the write re-arm), a pending `DISCARD` marker holding the room (`FREE` 0, `FULL`, no push taken), an `ERR_CAUSE` 5 raised by stage F leaving no older pixel unmerged (W holding a pixel it does not take in the cycle, L busy) |
| `contract_check.v` | the always-on contract monitors above, and the end-of-test fold of the model counters |
| `perf_monitor.v` | passive cycle counters (VRAM grants per requester, GPU busy cycles), the `PERF:` line of a test |
| `probes_gpu.v` | the GPU trace, [slipstream](slipstream_trace_format.md) |
| `cover_monitor.v` | the functional-coverage bins ([coverage](#2-coverage-and-waivers)) |

### 1.2 Tests

<!-- doc_counts:begin tests -->

The 156 enabled directed tests in `sim/rtl_sim/src/`, by group: `smoke_*` 6, `regs_*` 17, `gpu_*` 70, `bk_*` 20, `dbi_*` 18, `dpi_*` 25.

<!-- doc_counts:end tests -->

The counts in this guide and in the [simulation guide](simulation_guide.md) are generated from the regression's own tables by
`python3 doc/tools/doc_counts.py --update` (`--check` tells whether they are stale);
`./run -list` lists every test with its description and `requires`.

| Group | Covers |
|---|---|
| `smoke_*` | one feature end to end: registers, VRAM window, LUT, GPU, 8080 and SPI refresh (the SPI test needs `DIF_TYPE` 1 or 3 and skips in the default configuration) |
| `regs_*` | register map, AHB ports and ERRORs, interrupts, refresh timer (also with the DBI driver), VRAM contention, the window's read-ahead buffer, its wait states per access pattern (`regs_vram_timing`), its posted writes and their order with the register port on one bus (`regs_vram_order`: a list or an upload then its `CALL` / `COPY`, a frame then its refresh, byte lanes and ERRORs under contention), LUT, clock request (also through an address phase held by fabric wait states), `FRAME_NUM` and `FRAME_SEL.LATCHED` |
| `gpu_*` | fills and copies (all raster operations), swaps, surfaces, copies overlapping their destination, write-back slot under freezes, textured triangles, FIFO, errors and error causes, flushes during a command push, VRAM bounds, fences, the frame wait and state reset, clip trimming, abort, freeze, performance, extremes, spans, text expansion, textures, command lists, x/y and clipping, affine blits, gradients (per channel too), blending, triangles, palette remap, mask plane, immediate source, the `SET_EXT2` codes, absent features (also their errors), the settings kept through every flush and cut commands, error causes per command and their precedence, blending with every other feature, command lists of every command kind, work at the top of a large VRAM and back to word 0, the length extremes of lists and the immediate source, texture, gradient and triangle operand extremes, `DISCARD` of every partial command (the pending marker, with the flushes, in `ERR`), the `GPU_FIFO_LOW` threshold, RGB565A8 sources and the `MIX5` blend rule, bilinear sampling, random |
| `bk_*` | colour tables, LUT and its rotation, scan orders, frames, `REFR_PITCH`, configuration latching, stream timing, back-pressure, aborted frames, contention, the largest `DISP_SIZE` read from the top of the VRAM, then from word 0 again |
| `dbi_*` | driver registers, commands, parameter FIFO, fill, refresh (also queued behind a frame), size changes during a refresh, priority, scanline and TE synchronisation, interrupts, PHY selection, sizes beyond 2047, commands under back-to-back refreshes, the 8080 read strobe and bus timing against the ILI9341 AC table (pulse widths, CS set-up, read access and output disable, the bus released before `RD` falls), `DIF_CFG` settings taken per operation |
| `dpi_*` | DPI driver registers, frames, scaling, HD line widths (1280 pixels), polarities and events, underflow; HDMI DDC, mode and data islands, InfoFrame and packet changes at `UPDATE`, audio (also at its edges: enable phases, one-packet islands, slot lengths, I2S pauses, N changes, CTS at the ends of its range; packets read while sent: frames completing during a sample packet, a CTS measurement during clock regeneration, `AUD` cleared mid-packet, the packet pairs of an island, at 32 / 44.1 / 48 kHz; the slot capture against a reference model on a random stream), lines longer than the line buffer, bilinear scaling of full-range colours, timing at the field limits |

The per-pixel alpha and bilinear tests, each against `bench/verilog/gpu_model.v`, which
implements the [command set](gpu_commands.md#26-alpha-planes-rgb565a8) as written
(the per-field blend formulas, the tap MAC), not as the RTL computes it:

| Test | Checks |
|---|---|
| `gpu_mix5` | `SET_ALPHA` `MIX5` in every blend at 16 bpp (FILL, COPY, COPY_TRANSP, SPAN, EXPAND and `MASK` A1–A8, textures, flat and textured triangles, mask plane, immediate source, AA lines), the model's arithmetic first checked against hand values and LVGL's packed `lv_color_16_16_mix`; `A` at the rule's edges, `EN` off (`MASK` and AA only), back to rounding, `RESET_STATE`, palette modes |
| `gpu_a8_copy` | RGB565A8 copies: alphas 0, 1–3, 4, 251–253, 255 with and without `MIX5`, `EN` with `A` 0 / 1 / 128 / 254 / 255; the no-destination-read rule one pixel at a time (bytes 252 / 253 with `EN`, `A` = 255, `MIX5`: 252 reads D, the counts stated by the test); one destination word with alpha 255 then 128 and the reverse; key then alpha, ops 0, 5, 13–15, every swap, clipping, odd alpha offsets; palette modes |
| `gpu_a8_tex` | RGB565A8 TEXSPAN, TEXRECT and textured triangles: wrap, free pitch, `BOUND` (a skipped texel reads no alpha), `TRANSP_EN`, `SET_ALPHA` `EN`, `MIX5`, odd offsets, the words accessed |
| `gpu_a8_err` | the causes of `SRC_FMT` 5, `ALPHA_PLANE` and `TEX_FILTER` in every build (absent, `PITCH`, `TBORDER`, `SEL` 6–15, no operand taken, a list cut), `MPLANE` or the immediate source with `SRC_FMT` 5, `EXPAND` with it, an alpha word past the VRAM (cause 5, a prefix drawn); the pointer and `MIX5` through the flushes and `RESET_STATE`, a cut `ALPHA_PLANE` |
| `gpu_bil_basic` | the tap MAC and blend against hand values; one pixel for each (fx, fy) in {0, 1, 7, 8, 16, 24, 31, 32}²; texel-aligned (one tap), 90° turns, zoom-in and zoom-out; random TEXSPAN, TEXRECT, textured triangles; `MIX5`, `SRC_FMT` 0 and 5, `EN`; without blending the straight colour and nearest with `TRANSP_EN`; nearest again and in the palette modes |
| `gpu_bil_edges` | `BOUND` with `TBORDER` and with the clamp along every box edge and through every corner (x0 = −1, x0 + 1 = TW, the pixel skip), wrap seams, keyed taps, `SET_ALPHA` per tap, RGB565A8 taps, rotated blits over the box |
| `gpu_bil_mixd` | an interior pixel (no destination read) and an edge pixel in one destination word, both orders (reads and writes stated by the test); random edge blits with exact destination reads and writes |
| `gpu_bil_cache` | footprints across words and rows, rotations and zooms, odd pitches and pitches of 2 048 to 65 535 pixels, wraps (the colour and alpha reads against the model's 2 × 2 cache); the debug freeze, `ABORT` and `GPU_EN` = 0 mid-blit; a texture overlapping its destination (undefined image, but no error and the next blit exact); every configuration's read latency |
| `gpu_bil_err` | a tap's colour or alpha word past the VRAM (cause 5, a prefix drawn), a tap past the pixel-address range and a destination past 2^`VRAM_AW` words (cause 5, nothing drawn); the filter through the flushes and `RESET_STATE`; a `TEX_FILTER` cut before its operand keeps its word's effect; one decoded while the previous blit draws applies to the next |
| `gpu_bnd_prefix` | an `ERR_CAUSE` 5 raised by stage F keeps the pixels before it: 600 copies and keyed copies whose source row crosses `VRAM_WORDS` (every depth, ops S / S&D / XOR, destination X swaps, `REMAP` off / `SRC` / `DST`), and in a small VRAM (`sim_bnd_small`) an 8-bpp immediate copy with `REMAP` `DST` whose data index crosses it; the test requires cycles where W holds a pixel it does not take while F asks past the VRAM; run in the default build (T1), with run-ahead, a two-cycle macro, the DPI refresh and the 1000-word VRAM (`sim_bnd_*`, T2) |

`gpu_perf` measures the RGB565A8 and bilinear rows of the
[performance table](gpu_commands.md#24-performance) (the slope between a 16 × 8 and a
48 × 8 rectangle, floor and ceiling at read latency 1, the floor above), and
`gpu_retain`, `gpu_causes`, `gpu_nofx_err` and `gpu_rstream` take the new settings and
causes. The personas `performance` and `ultra` (bilinear and blending), the configurations
`classic_bil`, `blend_nomplane`, `bil_noxy` and `ultra_rdlat3` ([simulation
guide](simulation_guide.md#4-configurations-and-tiers)) run them with and without
blending, the mask plane and x/y, and behind a three-cycle VRAM macro.

`sim/rtl_sim/run/run_config.json` registers every test (name, description, `enabled`) with
an optional `requires`, a Python expression over the parameter names (for example
`GPU_EN==1 and GPU_TRI_EN==1`), and describes every parameter with its value in the
default build. The default build is the RTL defaults (`classic`, 8080 driver).
Each build receives every parameter as a `BLNS_<PARAMETER>` define, so `requires` is
evaluated on exactly what the bench elaborates. A test still skips itself where the
VRAM is too small for it.

### 1.3 Random command stream

`gpu_rstream` drives the GPU with a seeded constrained-random command stream and checks
it against the reference model of `bench/verilog/gpu_model.v`.

- **Stream.** Segments of one to six primitives over every `EXEC` kind the build has
  (FILL, COPY, COPY_TRANSP, SPAN, EXPAND with `MASK` and `OPAQUE`, TEXSPAN, TEXRECT,
  triangles and textured triangles, lines solid, dashed and anti-aliased with pen and
  pattern changes, `PH_RST`, `NO_LAST` and `OPAQUE`), at every `GFX_MODE`, in address and x/y mode
  (negative coordinates, random clip windows), pitch 0 and explicit pitches, swaps,
  raster ops 0–15, keys, gradients (per channel too), blending, palette remap, mask
  plane, the immediate source (with a short or long `N`), RGB565A8 copies and textures
  (random alpha offsets), `MIX5`, the texture filter (`BILINEAR`, `TBORDER`, clamp, wrap),
  `FENCE` (tag, `AUTO`, `IRQ`), `RESET_STATE` and `WAIT_REFR_DONE` (before a flush).
  Reserved and ignored bits are set at random (not `SET_ALPHA` [9], which is `MIX5`). A quarter of the segments run as a `CALL` list. A setting is sent only
  when the next primitive needs another value than the GPU holds, so nothing is re-sent
  after a flush; a segment after a flush may start with a bare `EXEC` on the kept
  settings.
- **Injections**, at random points of the push stream and random cycles: `CLEAR_ERR`,
  `ABORT`, both, `GPU_EN` 0 → 1 (commands cut between word and operand, immediate data
  still owed), `DISCARD` (alone: an operand owed, after a flush's skip too, immediate
  data owed, the source armed, nothing owed; with `CLEAR_ERR` / `ABORT` in the same
  write; in `ERR`; with the FIFO full, its marker pending), a bad word of every
  `ERR_CAUSE` (1–6, in the FIFO and in lists) followed by each recovery, a push dropped
  on a full FIFO (debug freeze) then resynchronised, discarded or misread, debug-freeze
  pulses (a flush while held too), and `GPU_FIFO_LOW` writes (the event checked every
  cycle by `gpu_inv_check`).
- **Model.** The stream model logs every word the FIFO accepted with the kind the
  pushed-stream parser gives it (command, operand, immediate data, a cut command's
  operand to discard) and the `DISCARD` markers where the stream was partial (the
  GPU's own decision to queue one, probed, must agree), then decodes the log as the
  specification describes: each command word and operand sets its half of the
  settings, a marker drops the command waiting for its operand and disarms, the error
  causes in their precedence with the record, lists read from VRAM, every `EXEC`
  through the drawing models. An immediate rectangle a marker abandons must have left
  a prefix of its writes.
- **Observation boundary.** The model decodes up to where the GPU had got: at a flush,
  `GPU_STAT.USED`, `LIST` and `GPU_LIST` as a register read in the flush's first cycle
  would return them; elsewhere the registers are read. After a flush (or an
  `ERR_CAUSE` 5 fault) the primitives still in flight must have left a prefix of the
  model's writes in VRAM, whole primitives for a `CLEAR_ERR` outside `ERR`.
- **Checks** at every idle or `ERR` point: the whole VRAM against the model, `GPU_STAT`
  (`ERR`, `BUSY`, `ERR_CAUSE`, `ERR_OPCODE`, `LIST`), `GPU_ERR`, `GPU_FENCE`,
  `GPU_LIST`, `IRQ_FLAG` (`GPU_OVFL`, `GPU_ERR`, `GPU_FENCE`), the number of words the
  FIFO accepted, and the byte enables of every GPU write (only bytes of pixels visited).
  The contract monitors stay on.
- **Coverage.** `COVERAGE HIT: rs_*` lines: kind × depth (`rs_fill_d8`), kind × feature
  (`rs_copy_mask`: clip, remap, mask, blend, grad, imm, list, xy), flush kind × kind in
  flight (`rs_fl_abort_tritex`), error cause × context (`rs_err_c4_list`), the cut
  command by opcode, the line bins (`rs_line_dash`, `rs_line_phrst`, `rs_err_c2_line`,
  `rs_err_c4_line`), the alpha and bilinear bins (`rs_a8_copy`, `rs_a8_tex`, `rs_mix5`,
  `rs_bil`, `rs_bil_a8`, `rs_bil_tborder`, `rs_bil_clamp`, `rs_bil_wrap`, `rs_err_c2_a8`,
  `rs_err_c1_a8_mplane`, `rs_err_c1_a8_imm`, `rs_err_c2_bil`, `rs_fl_abort_bil`,
  `rs_fl_clr_bil`), and the injections. `RS_COVER_BINS` in `sim_configs.py` makes the
  crosses the stream reliably reaches mandatory for the full sweep; `RS_T1_BINS`, which
  every seed reaches, also for a single configuration.
- **Runs.** One seed per configuration in T3 (every configuration with a GPU and a VRAM
  of 38 400 words or more, the clock-gate, free-running-macro, poisoned-read and
  no-run-ahead crosses included); in T1 in the default, ultra and Tang HDMI builds; in T2 the personas and deployed builds plus `sim_rs_classic`,
  `sim_rs_performance`, `sim_rs_ultra`, `sim_rs_essential`, `sim_rs_tang_hdmi`
  and `sim_rs_classic_bil`, which
  run four seed streams in one simulation (bench parameter `GPU_RS_SEEDS`). Knobs:
  `RS_SEGS_DEF` (segments per seed stream), `RS_TRACE_ON` (every push, flush and settle
  point, and the model write behind a VRAM difference).

---

## 2. Coverage and waivers

A functional-coverage monitor (`bench/verilog/cover_monitor.v`) reports bins such as
zero-wait / wait-state / ERROR transfers on each port, every window access size, both
panel PHYs, both clock-request states, the arbiter's priority cases, DPI frames and
underflow, the HDMI video lines, InfoFrames, audio and two-packet islands, and the GPU's
RGB565A8 and bilinear cases (an alpha factor of 0, 256 and between, the alpha read-ahead
hit, 1 to 4 taps a pixel, the taps dropped, each tap-cache entry hit and missed, an
alpha companion straddling two words, an entry dropped by a write, α₂₅₆ 0, 256 and
between). The full
sweep (`./run_all -rtl_sweep`, mode `all`) fails if a mandatory bin is never hit; a
partial sweep or one configuration only reports the bins.

<!-- doc_counts:begin bins -->

Mandatory bins: 267 (`MANDATORY_COVER_BINS` in `sim/rtl_sim/bin/sim_configs.py`), of which 210 are required only of the full sweep (`SWEEP_ONLY_COVER_BINS`).

<!-- doc_counts:end bins -->

Code coverage (Verilator line, branch and toggle) is collected by the `-cov` runs
([coverage runs](simulation_guide.md#6-coverage-runs)).

Verilator's line metric counts procedural blocks only; branch (`?:`, `if`) and toggle
carry the information. `bin/cov_report.py` reports them against `run/waivers_cov.md`:
rules by file, source pattern and point name, each with its reason, which take the
points they match out of the denominator (counted apart; one that matches nothing is
reported STALE). Waived are Verilator counting artefacts (function bodies, generate
loops, `initial` blocks and parameter-selected `?:` that are never counted) and
structural points (the FSM default arm, the `sinit_i` arm of `arv_ipdff_sinit`, the
8080 pins the 8-bit PHY ignores, pixel-mask bits constant by construction, bits that
the value range of their operands keeps constant, the no-connect `spi_miso_i`), one point outside the input contract (an HDMI audio frame lost with I2S slots
shorter than the 28 pixel clocks the [programming model](programming_model.md#113-hdmi-audio) requires), the
most significant bits of event counters that need 2^n events, and the maximum-configuration
bits (DPI source lines and positions beyond about 2 048, `DIM_W` 16 drawing and DBI
windows: covered up to the deployed and HD geometries, the upper bits being the same
logic as the exercised low bits); the
`*_unused` lint sinks are excluded whether they toggled or not (`"exclude": true`). The
bits tied to a constant in every configuration are generated:
`../bin/cov_const.py cov/dats --write` (Yosys) rewrites that section, to be run after a
coverage sweep on changed RTL. `../bin/cov_report.py cov/dats --lint` checks every entry
(STALE, or BROAD when it also matches covered points). The target is 100 % line, branch
and toggle after the waivers; holes that a test can reach and dead RTL are not waived. The jitter model of `arv_synchronizer` is outside the measurement by a
`coverage_off` pragma.

---

## 3. Driver host tests

- **Host checks of the GPU's arithmetic** (`make -C sw/test`, no LVGL needed: its
  kernels are quoted): `check_mix5`, the `MIX5` rule against LVGL 9.6's
  `lv_color_16_16_mix`, `lv_color_24_16_mix` and `LV_OPA_MIX2` (exhaustive per field and
  on LVGL's shortcuts, random pairs for the rest, and the no-destination-read rule of an
  RGB565A8 pixel): 0 differences; `check_bilinear`, the bilinear kernel against LVGL's
  two (`rgb565a8_row_fast` and the alpha-weighted one), 2 million cases a kind: the bounds
  of the [command set](gpu_commands.md#27-bilinear-sampling) (opaque 1 / 1 / 1 and
  2 / 4 / 2, image edges and random alphas 3 / 5 / 3, smooth images 2 / 3 / 2; LVGL's
  kernels within 5 of G of each other).
- **Host unit test** (`make -C sw/test`, any C11 compiler; three builds: no platform
  header (under AddressSanitizer and UBSan; `make SAN=` without them), every feature
  stated present (`plat_all.h`), the essential persona's set (`plat_essential.h`: the
  GPU core alone, no cursor, the absent calls as inline stubs); `./test_driver <n>`
  runs test n alone): the driver against a model in RAM: the register port as a
  `BLNS_TypeDef`, the VRAM as an array, the GPU as a FIFO (depth from `BLNS_CFG2`) and a command decoder that behave as
  the RTL at the register port (`blns_gpu_dec.v`: the push side's operand and
  immediate-data tracking, `ABORT` / `CLEAR_ERR` discarding the operand a cut command
  still owes, `DISCARD` and its marker (pending while the FIFO is full, none with a
  flush or in `ERR`; the cut command dropped, the immediate copy abandoned),
  `GPU_EN = 0` resetting the stream, words dropped into a full FIFO or with
  `GPU_EN = 0`, an invalid word and a rectangle past the VRAM (cause 5) stopping the
  decoder, `GPU_FIFO_LOW` saturated at the depth), keep the GPU's settings, log every `EXEC` as a draw (operation,
  destination, size, colours, source, texture box, immediate data) and write the pixels
  of fills, spans, copies (every walk) and lines (solid, dashed and anti-aliased, from
  the closed forms; the pen, pattern and phase with their resets), RGB565A8 copies and
  bilinear textures (checked against references written from the command set's text). `CTRL`, `GPU_CTRL` and the hot-plug and DDC
  registers reach the model through `BLNS_REG_WR` / `BLNS_REG_RD` (the hot-plug flags
  write 1 to clear; an EDID EEPROM sits on the DDC lines, bit by bit). The wait hook
  runs the decoder, so FIFO-full waits drain as on the hardware; after every test the
  FIFO must not have overflowed nor the draw log be full. The tests check what is
  drawn, not the words: the state `blns_init` keeps, sizes 0 and too large, the
  sessions of the per-item calls across fills and copies (their own pitches, commit
  on `BLNS_OK`), the batches and inline fast paths, recovery between calls and asked
  from an interrupt in the middle of a call or of immediate data, a stream cut between
  a command and its operand (discarded, no recover), `blns_gpu_discard` and the
  one-write recover (no `GPU_EN` pulse), the `GPU_FIFO_LOW` threshold
  (`blns_gpu_fifo_low_set`, `blns_gpu_wait_space` moving it and writing it back),
  dropped fences (`blns_gpu_fence_status`), errors after
  acceptance, bounded waits (polls without progress) and timeouts (each helper longer
  than the FIFO stopped at every word position: whole commands only, the settings cache
  as the GPU, the next calls as without the timeout; in immediate data, discarded),
  non-blocking mode,
  presence checks on the shared driver window, fences in replayed lists, list
  overflow and spill, argument checks, the double-buffered palette, the VRAM
  helpers, the HDMI picture policy and hot-plug machine, the DDC master (bus clear,
  repeated START timing), the DPI setters that change nothing, and `blns_init`'s
  `BLNS_ERR_CONFIG` on a platform header that differs from the model.
- **LVGL host test** (`make -C sw/test -j8 lvgl`; LVGL v9.6.0 fetched on first use from
  its release archive into `sw/test/lvgl_src/` (SHA-256 checked), `LVGL=<root>` for another copy; `GLUE=<file>` tests another
  `lv_belenos.c`): `lv_belenos.c`, the driver and real LVGL against the same model,
  under AddressSanitizer and UBSan, in four LVGL builds: LVGL's defaults (as the
  `lvgl_demo`) and buffers and strides aligned to 8 bytes with `LV_DRAW_SW_COMPLEX 0`,
  each without and with the draw unit's [extensions](lvgl_guide.md#42-extensions)
  (`LV_BELENOS_USE_*` 1, a 256 KB VRAM model whose GPU also draws blended fills and
  copies, RGB565A8 copies, gradients, `EXPAND MASK` and bilinear textures as
  `bench/verilog/gpu_model.v` does).
  Every scene is rendered by a plain LVGL display in RAM (the software renderer, no
  Belenos code) and through the glue in each of its ways (DIRECT, GPU flush, CPU flush,
  with and without the draw unit), and the frames must be equal pixel for pixel. The GPU
  runs a few words per LVGL dispatch round (a test draw unit), so batches and flush
  copies are in flight while LVGL goes on. Faults: a recover requested before every
  word pushed and at every dispatch round, the decoder stopped at every `EXEC` (an
  error after acceptance), non-blocking mode on an 8-word FIFO, a FIFO wait that times
  out; the same with immediate blits in flight (a timeout in their data discards the
  blit, sent again whole); images in the CPU's memory with and without the immediate source (pushed in
  one piece, or left to the software renderer: more than 1024 pixels, rows not packed, a
  misaligned image, a push that would read past the image), each case's pushes
  counted; also images with stride 0, areas of every width, `lv_belenos_create`'s
  refusals, display delete (memory, the unit taken again), the unit bound to its
  display, and waiting through the wait hook. With the extensions: rounded shapes split
  between the GPU and the CPU, images staged in the pool (tiled, one that changes left
  out), layers in the pool, and with blending (`MIX5`) translucent fills, borders, images
  and layers, RGB565A8 images in the VRAM and in RAM, ARGB8888 images (every class of
  alpha around LVGL's thresholds) and labels, pixel for pixel; one blend under `MIX5`
  against `lv_color_16_16_mix` (an opacity, a glyph's coverage times it, an alpha byte
  times it); gradients within 2 per field; rotated and scaled images (`approx`
  `TRANSFORM`) pixel by pixel within the kernel bound (3, 5, 3) plus 2/32 of the local
  texel contrast (the whole contrast within 1/32 texel of the image's edge), LVGL's
  sample point computed from its own set-up, and with nearest sampling a texel within
  1/32 texel of it; the GPU's share counted (blended, gradient, `EXPAND` and texture
  commands); the same fault sweeps with them in flight, a pool too small for all (dropped and refilled),
  the blended draws checked after the refresh that redraws a fault's area. Each test
  runs in a child process with a time limit (a hang fails).
- **Target builds**: `riscv-none-elf-gcc -march=rv32emc_zbb_zba_zbs_zbc_zicsr_zcb
  -mabi=ilp32e -Os -std=c11 -Wall -Wextra -Werror` of `src/*.c` and `panel/*.c`, without
  and with a platform header (`lvgl/lv_belenos.c`: `-std=gnu11`, with LVGL's headers),
  and a C++11 compile of `belenos.h` (`BLNS_STATIC_ASSERT` checks the register offsets in
  both languages).
- **Board level**: the arvern-soc regressions run the Tang Console applications (the
  demos, `tst_blns` on the RGB panel and on HDMI, the games, LVGL) on the SoC RTL and
  compare their panel images with golden lists; the DE0-Nano-SoC example builds the
  same applications for an ILI9341 / LT24 board.

---

## 4. Formal proofs

`formal/run_all` runs every proof and prints PASS / FAIL per task (`-mutate`: the
mutation checks; `-list`: the tasks). Free tools only: Yosys elaborates each harness
(`formal/<proof>/*_fv.sv`) and `yosys-smtbmc` with z3 checks it (driver:
`formal/common/fv.py`; no SymbiYosys). A task passes when the bounded check from reset
finds no failing assertion, the induction step proves when the task has one, and every
cover is reached. Each proof's README lists its properties, its technique (unbounded by
k-induction, or bounded with its depth) and its assumptions; every assertion is shown to
fail on at least one mutation of a temporary copy of the RTL (`run_all -mutate`, which
also reports an assertion no mutation makes fail).

| Proof | Subject |
|---|---|
| `vram_arb` | arbiter: one grant, priority order, starvation bounds (GPU 7, window 1 non-urgent cycles), read return with requester, tag (the GPU's, the refresh's cursor reads) and data at every read latency, `rd_pend_o`, the read valid announced one cycle ahead |
| `gpu_px_bound` | the pixel engine's stages F and W (`blns_gpu_px_fw` without blending, with the mask plane, remap and immediate source; stage A's tokens free), at read latencies 1, 2 and 3: an `ERR_CAUSE` 5 raised by F (a source or mask read, an immediate index past `VRAM_WORDS`) never leaves an older pixel unmerged; bounded, 20 steps |
| `gpu_tapcache` | the bilinear tap cache (`blns_gpu_px_tc`) against a shadow VRAM word, at read latencies 1, 3 and 2 with the synchronous reset: a hit returns the word last written (a write overtaking a colour read in flight drops its data), no entry holds a word after a write to it, a command start or the freeze's hold, an alpha fill stores the right byte lanes; one read in flight and the request held until granted are `blns_gpu_px_fw`'s port contract, assumed here and checked in simulation |
| `fifo_gpu`, `fifo_dbi` | GPU command FIFO (its 1- or 2-bit tags: the `DISCARD` marker, the immediate data), DBI parameter FIFO: count, flags, no overflow, order |
| `fifo_bk` | backend FIFO alone, and in `blns_backend`: never pushed full nor popped empty; the hardware cursor on the backend's VRAM slot (request held until granted, tagged returns kept out of the pixel path, no line-buffer load under a cursor token); the LUT request announced one cycle ahead is the next cycle's; the walker's start address of every frame (the shift-add Y offset) |
| `cdc_dpi` | DPI crossings, both clocks free and every synchroniser bit with its own delay: quasi-static data stable when sampled, handshakes without loss or duplication |
| `ahb_vram` | the window behind the arbiter, at total read latencies 1 to 4: a read returns the latest bus write (read-ahead buffer, posted write), every completed write made once and in order, the posted-write flag exact, HREADYOUT equal to the same-cycle ready, idle OKAY, two-cycle ERROR, bounded wait; HREADYOUT, HRESP and HRDATA from flops (a structural step: no input in their combinational cone) |
| `ahb_reg` | the register port with the LUT window: its registered HREADYOUT equals the ready decoded in the same cycle (the same wait states), a LUT write never completes without its macro write, no transfer starts while a window write is posted and none started is interrupted |

---

## 5. Lint

Two lint flows run on the RTL:

- **Verilator**: `sim/rtl_sim/run/run_lint` lints the RTL defaults, and first runs two
  checks: `bin/check_core_manifest.py` (the FuseSoC manifest `belenos.core` lists exactly
  the files of `rtl/verilog/filelist.f`) and `bin/check_deployed.py` (the deployed builds
  against the arvern-soc sources, skipped with a note when arvern-soc is not checked out
  next to this repository). `run_lint -sweep` lints every shared configuration of
  `sim/rtl_sim/bin/rtl_configs.py` (`bin/run_lint_sweep.py`, a summary table) and does not
  run the two checks.
- **VC Static**: `lint/vc_static/run_vclint` and `run_vclint -rtl_sweep` (every
  configuration), with the rule set `rules.tcl` and the justified waivers `waivers.tcl`;
  usage in [lint/vc_static/README.md](../lint/vc_static/README.md). A bare `run_vclint`
  lints the RTL defaults, `classic` (configuration 3); `run_vclint -rtl_config <N|label>`
  lints another configuration.

- **Structural clock-domain crossings**: `run_lint -cdc` (`lint/cdc/cdc_check.py`, Yosys
  and Python, no commercial tool) elaborates the configurations with a crossing
  (`dif4_pclk`, `dif5_pclk`, `dif5_audio`, `tang_hdmi`, `tang_panel`, `sync_rst_dif5`,
  `sync_rst_audio`, and `dif3` for the DBI asynchronous inputs), gives every flop the
  domain of its clock port (`hclk_i`, `dpi_pclk_i`; input ports have a declared domain,
  the panel, DDC and I2S pins are asynchronous) and follows every flop's data, enable and
  synchronous-reset cone back to flops and ports. Each source of another domain must
  enter the first stage of an `arv_synchronizer` directly; anything else is an error
  unless `lint/cdc/waivers.txt` names it with its reason and document: the quasi-static
  and toggle-protected data of `blns_dpi_cdc.v`'s header (the staged configuration, the
  frame size, the bank tags, the HDMI fields, the generic packet, `DPI_AUD`, the `LINE` /
  `CTS` snapshots). It also reports logic in front of a synchroniser, a register
  synchronised bit by bit, separately synchronised bits combined in one cone
  (reconvergence), an output driven from another domain and a flop reset from another
  domain, and lists every synchroniser bundle with the source of each bit. A waiver no
  configuration uses fails the check; `cdc_check.py -selftest` seeds a bypassed
  synchroniser and logic in front of one into a temporary copy of the RTL and checks that
  both are reported (`run_lint -cdc` runs it first). Reports:
  `lint/cdc/results/<config>/cdc_report.txt`. What it cannot see is functional: that the
  handshakes keep the waived data stable while they are sampled is proved by
  `formal/cdc_dpi` ([Formal proofs](#4-formal-proofs)).

A lint run passes when every configuration reports no violation outside the waivers.

---

## 6. Documentation checks

- The register figures `doc/img/reg_*.json` are hand-written. `python3 doc/tools/check_reg_figures.py`
  (from anywhere in the repo, Python standard library only) checks each field's name, position and
  width against `sw/include/belenos_regs.h`, that no header field falls in a gap of its figure, that
  each SVG was rendered from its current JSON, and that every figure is referenced from a Markdown
  file; it exits non-zero on any mismatch. Re-render a changed figure alone with
  `python3 doc/img/render.py <name>.json` (register figures need Node and `npx`; wavedrom-cli is
  downloaded on first use).
- The test, configuration and tier counts in this guide and in the simulation guide are generated:
  `python3 doc/tools/doc_counts.py --check` tells whether they are stale, `--update` rewrites them.
- The LVGL benchmark tables of `doc/performance.md` are generated from the bench's results
  (`bench/lvgl_bench/results/`): `python3 bench/lvgl_bench/bin/lvgl_bench_tables.py --check`
  tells whether they are stale, `--update` rewrites them
  ([LVGL benchmark bench](simulation_guide.md#9-lvgl-benchmark-bench)).

The drawings in `doc/img` are generated: `render.py` turns the hand-written WaveDrom
(`*.json`) sources (register fields and waveforms) into SVG (nothing checks them against
the RTL), and `figures.py` writes the block
diagrams, the GPU command gallery and the scan-order, palette and packing figures as
draw.io diagrams, exported through the draw.io desktop CLI to `*.drawio.svg` with the
diagram embedded.

---

## See Also

- [simulation_guide.md](simulation_guide.md) — prerequisites, the run scripts, configurations and tiers
- [slipstream_trace_format.md](slipstream_trace_format.md) — the GPU trace written by every simulation
- [lint/vc_static/README.md](../lint/vc_static/README.md) — the VC Static sign-off lint flow
- [formal/README.md](../formal/README.md) — the formal proofs and their harnesses
- [integration_guide.md](integration_guide.md) — the parameters the configurations sweep
