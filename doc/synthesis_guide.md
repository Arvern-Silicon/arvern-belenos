<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos synthesis guide

*The area of Belenos per persona, per block and per feature, and the Design Compiler flow
that measures it: set-up, library flavours, constraints, commands and outputs. The
timing constraints an SoC needs for a belenos instance are in the
[integration guide](integration_guide.md#7-timing-constraints).*

---

## Table of Contents

1. [Area results](#1-area-results)
    - [1.1 Sweep conditions](#11-sweep-conditions)
    - [1.2 Area per persona and block](#12-area-per-persona-and-block)
    - [1.3 Feature cost](#13-feature-cost)
    - [1.4 Display drivers](#14-display-drivers)
    - [1.5 Regenerating the tables](#15-regenerating-the-tables)
2. [Flow overview](#2-flow-overview)
3. [Library set-up](#3-library-set-up)
4. [Running](#4-running)
5. [Constraints](#5-constraints)
6. [Output files](#6-output-files)
- [See Also](#see-also)

---

## 1. Area results

### 1.1 Sweep conditions

| Sweep | |
|---|---|
| Date | 2026-11-12 |
| Library (class, corner) | 130 nm standard cells, SVT and LVT, slow corner (1.35 V, 125 °C) |
| Clock period (`hclk_i`, `dpi_pclk_i`) | 9.0 ns (111 MHz), met in every configuration |
| DFT | scan inserted (multiplexed flip-flops, one clock per chain), no DRC violation |

Every figure is in NAND2-equivalent kGates, without the VRAM, LUT and line-buffer macros,
with the same library and constraints, and **without a display driver** (`DIF_TYPE` 0, the
[BDI](display_interface.md) exported): the driver a panel needs is added from the
[display driver](#14-display-drivers) table. The other integration parameters are the
defaults (38400-word VRAM, `DIM_W` = 10).

### 1.2 Area per persona and block

The five [personas](integration_guide.md#21-personas):

| Block | light | essential | classic | performance | ultra |
|---|---:|---:|---:|---:|---:|
| AHB register port | 0.3 | 0.4 | 0.4 | 0.4 | 0.4 |
| Register bank | 2.1 | 2.2 | 3.8 | 3.8 | 3.8 |
| Refresh timing | 1.1 | 1.1 | 1.1 | 1.1 | 1.1 |
| AHB VRAM window | 2.0 | 2.1 | 2.2 | 2.3 | 2.3 |
| VRAM arbiter | 0.2 | 0.4 | 0.4 | 0.4 | 0.4 |
| GPU command FIFO | 0.0 | 2.9 | 3.0 | 5.8 | 11.4 |
| GPU decoder | 0.0 | 4.2 | 8.1 | 8.6 | 9.6 |
| GPU set-up | 0.0 | 0.4 | 11.3 | 14.3 | 27.0 |
| GPU pixel engine | 0.0 | 12.9 | 21.7 | 39.0 | 45.8 |
| GPU walkers | 0.0 | 1.9 | 1.9 | 1.9 | 1.9 |
| GPU control | 0.0 | 1.8 | 1.9 | 5.5 | 7.7 |
| Backend fetch | 3.1 | 3.2 | 3.2 | 3.2 | 3.2 |
| Backend colour | 0.6 | 0.6 | 0.7 | 0.7 | 0.7 |
| Backend FIFOs | 2.1 | 2.1 | 2.2 | 2.2 | 2.2 |
| Hardware cursor | 0.0 | 0.0 | 2.9 | 2.9 | 2.9 |
| Backend control | 2.2 | 2.2 | 2.3 | 2.3 | 2.3 |
| Colour LUT | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 |
| Top-level glue | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 |
| **Total (kGates)** | **14.0** | **38.6** | **67.3** | **94.5** | **122.8** |
| Combinational | 5.3 | 18.8 | 34.7 | 50.2 | 67.3 |
| Sequential | 8.8 | 19.8 | 32.6 | 44.3 | 55.5 |
| Flop count | 895 | 2,260 | 3,717 | 5,069 | 6,553 |

### 1.3 Feature cost

From the smallest build to the largest, one feature added at each step: each row is the
build of the row above plus that feature, and the personas are the bold rows. A step is
measured on top of the steps before it; features that share logic would show slightly
different steps in another order.

| Step | Adds (kGates) | Total (kGates) |
|---|---:|---:|
| **`light` persona**: display controller, one LUT bank | — | 14.0 |
| second LUT bank (`LUT_BANKS` = 2) | +0.0 | 14.0 |
| GPU (`GPU_EN`): fills, copies, spans, colour expansion, textured spans, command lists: **`essential` persona** | +24.5 | 38.6 |
| x/y coordinates, clip window and affine blit (`GPU_XY_EN`) | +8.9 | 47.5 |
| gradient fill (`GPU_GRAD_EN`) | +4.0 | 51.4 |
| lines and dashes (`GPU_LINE_EN`) | +6.1 | 57.5 |
| palette remap (`GPU_REMAP_EN`) | +1.5 | 59.0 |
| mask plane (`GPU_MPLANE_EN`) | +2.2 | 61.3 |
| immediate source (`GPU_IMM_EN`) | +1.2 | 62.5 |
| hardware cursor (`CURSOR_EN`): **`classic` persona** | +4.8 | 67.3 |
| alpha blending (`GPU_BLEND_EN`) | +8.1 | 75.4 |
| command FIFO of 16 words (`GPU_FIFO_AW` = 4) | +2.9 | 78.3 |
| run-ahead (`GPU_RUNAHEAD_EN`) | +3.5 | 81.8 |
| bilinear sampling (`GPU_BILINEAR_EN`): **`performance` persona** | +12.7 | 94.5 |
| triangles (`GPU_TRI_EN`) | +22.6 | 117.1 |
| command FIFO of 32 words (`GPU_FIFO_AW` = 5): **`ultra` persona** | +5.7 | 122.8 |

The second LUT bank (`LUT_BANKS`) costs no logic: it doubles the LUT macro (512 instead of
256 entries of 24 bits, [LUT macro](memory_and_ahb.md#5-lut-macro)).

Alpha blending includes the RGB565A8 sources and the `MIX5` blend rule. Bilinear
sampling costs less without blending (opaque filtering only, no transparent border, no
RGB565A8 taps): `classic` with `GPU_BILINEAR_EN` (`classic_bil_bdi`) is 76.0 kGates,
+8.7 on `classic`.

### 1.4 Display drivers

What each built-in driver adds to a build without one (`classic`, `DIF_TYPE` 0); a row
starting with + is an option of the driver above it, measured on top of it:

| Display driver | Adds (kGates) |
|---|---:|
| DBI over SPI (`DIF_TYPE` 1) | +4.0 |
| DBI over the 8080 bus (`DIF_TYPE` 2, the default) | +5.8 |
| DBI, both buses and the PHY select (`DIF_TYPE` 3) | +6.2 |
| DPI without a scaler (`DIF_TYPE` 4, `DPI_SCALER` 0) | +12.1 |
| DPI, nearest-neighbour scaler (`DPI_SCALER` 1, the default) | +14.5 |
| DPI, nearest and bilinear scaler (`DPI_SCALER` 2) | +21.2 |
| + panel timing on its own pixel clock (`DPI_PCLK_SEP` 1) | +0.2 |
| HDMI without DDC nor data islands (`DIF_TYPE` 5, `DPI_DDC_EN` 0, `DPI_ISLAND_EN` 0) | +15.6 |
| HDMI with DDC and data islands (the defaults) | +17.4 |
| + panel timing on its own pixel clock (`DPI_PCLK_SEP` 1) | +0.4 |
| + audio (`DPI_AUDIO_EN` 1) | +9.6 |

The DPI and HDMI line buffers are macros, outside these figures
([line-buffer macro](memory_and_ahb.md#6-dpi-line-buffer-macro)).

### 1.5 Regenerating the tables

The tables are the output of `synthesis/synopsys/doc_area_tables.py`, pasted as they
are, after a sweep with the library and period stated above. The build of each row is
named in the script; the steps between the personas are the synthesis-only
configurations `AREA_STEPS` of `sim/rtl_sim/bin/rtl_configs.py`:

```bash
cd synthesis/synopsys
./run_syn -rtl_config light_bdi,lut2_bdi,gpu_bdi,xy_bdi,grad_bdi,line_bdi,remap_bdi,mplane_bdi,\
imm_bdi,dif0,blend_bdi,fifo16_bdi,performance_bdi,tri_bdi,ultra_bdi,classic,dif1,dif3,\
dif4_noscale,dif4,dif4_bilinear,dif4_pclk,dif5_noddc,dif5,hdmi_pclk,dif5_audio
python3 doc_area_tables.py               # the block table of the five personas
python3 doc_area_tables.py --features    # the feature steps and the display drivers
```

How to run a synthesis: [flow overview](#2-flow-overview) and [running](#4-running).

---

## 2. Flow overview

`synthesis/synopsys/run_syn` synthesises Belenos with Design Compiler (without the VRAM,
LUT and line-buffer macros, with DFT scan insertion) in any configuration of
`rtl_configs.py`, and reports the area per block and the timing. The scan chains use
multiplexed flip-flops, one clock per chain: `hclk_i`, and `dpi_pclk_i` when the DPI or
HDMI driver has its own pixel clock (`DPI_PCLK_SEP` 1); `hresetn_i` and `dpi_presetn_i`
are the scan resets (held inactive as constants with `ASYNC_RST_EN` 0).

---

## 3. Library set-up

Run `run_syn` from `synthesis/synopsys/`, with `dc_shell-t` on the `PATH`. It needs a
technology library setup, which the repository does not ship:

1. Copy `libraries/setup_lib_example.tcl` to `libraries/setup_<flavour>.tcl` and rename its
   namespace from `lib_example` to `<flavour>` (`library.tcl` reads the variables as
   `<flavour>::LIB_WC_FILE`, ...). The default flavour is `lib_default`: a clean clone has no
   `libraries/setup_lib_default.tcl` (it is git-ignored), so a bare `./run_syn` stops with
   "Unknown library flavor" until it is created.
2. Fill in the worst- and best-case libraries (`.db`, a list for several Vt variants) and
   their names, the operating conditions, the wire-load model and the name of the
   library's smallest NAND2 cell (the area unit of the reports).
3. Optionally set `CLOCK_PERIOD` (ns) in the namespace. Without it `constraints.tcl` uses
   **15 ns (66 MHz)** for `hclk_i`.

---

## 4. Running

```bash
./run_syn                              # RTL defaults (classic) into results/
./run_syn -rtl_config <N|label>[,...]  # one or several configurations (a list also to results_sweep/<label>/)
./run_syn -rtl_sweep                   # every configuration, to results_sweep/<label>/ and sweep_summary.log
./run_syn ... -with_sync_reset         # the same with ASYNC_RST_EN = 0 (results_sweep/<label>_sync/)
./run_syn -lib <flavour>               # another library setup
./run_syn -list_configs                # the configuration table
./run_syn -i                           # leave dc_shell open
./run_check_reset_style                # PrimeTime check of the reset style of results/belenos.gate.v
```

---

## 5. Constraints

The constraints are `constraints.tcl` (clocks, and with `DIF_TYPE` 4/5 and
`DPI_PCLK_SEP = 1` the pixel clock and `constraints_dpi.tcl`, the crossings) and
`constraints_ports.tcl` (port delays, the false paths of the asynchronous inputs and,
with `ASYNC_RST_EN = 1`, of the resets); an SoC uses its own, see the
[integration guide](integration_guide.md#7-timing-constraints).

---

## 6. Output files

Outputs: `results/` (`synthesis.log`, `belenos.gate.v`, `report.area_analysis.txt`,
`report.timing_analysis.txt`, `report.dft_drc`, ...). Every run ends with a one-line
summary (`WNS`, `TNS`, gates, `warn`, `err`, `waive`): a run passes with `err=0` and
`warn=0`, the warnings matched by `waivers.txt` being counted apart. The [area tables](#1-area-results)
are rendered from a sweep by
`python3 doc_area_tables.py` (the five personas) and `python3 doc_area_tables.py
--features` (the cost of each feature), which read `results_sweep/<label>/`.

---

## See Also

- [integration_guide.md](integration_guide.md) — the personas, the parameters and the timing constraints of an SoC
- [verification_guide.md](verification_guide.md) — lint, including the VC Static flow run on the same configurations
- `sim/rtl_sim/bin/rtl_configs.py` — the configurations shared by synthesis, lint and simulation
