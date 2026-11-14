<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos simulation guide

*For verification engineers and contributors: what the simulations need, the repository
layout, the run scripts, the configuration sweep and its tiers, the clock-crossing
stress, coverage runs, the GPU trace and the LVGL benchmark bench. What the bench checks and how the design is
verified is in the [verification guide](verification_guide.md).*

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Repository layout](#2-repository-layout)
3. [Running](#3-running)
4. [Configurations and tiers](#4-configurations-and-tiers)
5. [Clock crossings](#5-clock-crossings)
6. [Coverage runs](#6-coverage-runs)
7. [GPU trace](#7-gpu-trace)
8. [Driver host tests](#8-driver-host-tests)
9. [LVGL benchmark bench](#9-lvgl-benchmark-bench)
- [See Also](#see-also)

---

## 1. Prerequisites

The RTL depends on
[arv_primitives](https://github.com/Arvern-Silicon/arvern-ips/tree/main/arv_primitives)
from the arvern-ips repository, checked out next to this one (`rtl/verilog/filelist.f`
includes it by a relative path; with FuseSoC, `belenos.core` depends on it).

Optional, also next to this one: the arvern-soc repository holds the board builds and the
regressions of the applications; `run_lint` compares the deployed builds with it (skipped
with a note when it is absent), and the driver's LVGL host test takes LVGL from its tree
([driver host tests](verification_guide.md#3-driver-host-tests)).

Tools: Python 3, Icarus Verilog (the default simulator) or Verilator (also the lint), a C11
compiler for the driver's host tests; VC Static and Design Compiler for the sign-off lint
and the synthesis ([lint](verification_guide.md#5-lint), [synthesis guide](synthesis_guide.md)).

The [LVGL benchmark bench](#9-lvgl-benchmark-bench) also needs the
[aRVern](https://github.com/Arvern-Silicon/arvern) repository next to this one (its CPU
core; a dependency of that bench only, not of the IP), Verilator, `riscv-none-elf-gcc`
(xPack 15.2) and `curl` (LVGL is fetched on first use).

---

## 2. Repository layout

```
arvern-belenos/
├── rtl/verilog/            RTL (belenos.v, belenos_core.v, blns_*.v) and filelist.f
├── rtl/constraints/        belenos_dpi.sdc / belenos_dpi_dc.sdc, the crossing constraints of a DPI_PCLK_SEP = 1 build
├── bench/verilog/          testbench, AHB tasks, reference and panel models, GPU trace probe
├── bench/lvgl_bench/       LVGL benchmark bench: aRVern + Belenos, firmware, run script, results
├── sim/rtl_sim/
│   ├── src/                directed tests
│   ├── bin/                run scripts, test_config.py, rtl_configs.py, sim_configs.py, coverage and trace tools
│   └── run/                run, run_all, run_lint, cov_view, run_config.json (working directory)
├── lint/vc_static/         VC Static lint flow
├── lint/cdc/               structural clock-domain-crossing check (cdc_check.py, waivers.txt)
├── formal/                 formal proofs (run_all, one directory per proof)
├── synthesis/synopsys/     synthesis flow and area reporting
├── sw/                     C driver library (register header, API, panel drivers)
│   ├── lvgl/               the LVGL v9 display driver
│   └── test/               the driver's host tests
├── doc/                    this documentation, its drawings (doc/img) and doc/tools/doc_counts.py
└── belenos.core            FuseSoC manifest
```

---

## 3. Running

Run from `sim/rtl_sim/run/` (Icarus Verilog by default, `VERILOG_SIMULATOR=verilator`
for Verilator):

```bash
./run <test> [-seed N] [-nodump]                    # one test, default build
./run <test> -rtl_config <N|label>                  # one test in a sweep configuration
BLNS_DEFINES="BLNS_DIF_TYPE=3" ./run <test>         # ... with single parameters overridden
./run <test> -cov                                   # Verilator coverage of that test
./run -list | -list_configs                         # tests with their requires / configurations
./run_all -fast -j 8                                # T1: the default build and tang_hdmi (also: no option)
./run_all -tier T0|T1|T2|T3 -j 8                    # one tier (tier table below)
./run_all -deployed -j 8                            # the deployed board builds only
./run_all -rtl_config <N|label> -j 8                # every test of one configuration
./run_all -rtl_sweep -j 8                           # every configuration (= -tier T3)
./run_all -rtl_sweep --sweep-mode M -j 8            # M: all, personas, shared, sim, deployed, release, smoke, fast
./run_all -cov [--sweep-mode M] [-j N]              # Verilator line/branch/toggle coverage
./run_all -tier T2 -sim verilator -j 8              # any of the above under Verilator, random initial values
./run_all ... -seed S                               # master seed of the per-run seeds (summary.log)
./run_all -list | -list_configs                     # as ./run
```

Every `./run` and `./run_all` builds and simulates in a work directory of its own
(`WORK/<run>/`, removed at the end), so several can go in one run directory at once.
Logs: `log_sweep/<configuration>/<test>.log` and `log_sweep/summary.log`, `log_sweep`
being a link to the newest run's `log_runs/<date>-<time>_<pid>/`; the ten newest
finished runs are kept (`LOG_KEEP`). `./run` moves its waveform and `slipstream.log`
into the run directory at the end. A run passes only with a PASSED banner and no
`ERROR:` line in its log. `-sim verilator` builds each pair with Verilator
(`--x-initial unique`, `+verilator+rand+reset+2` seeded from the run's seed), so a
missing reset shows; it is not the default.

A test reports PASSED, FAILED or SKIPPED. `./run` runs a test even where its `requires`
fails (with a note); the test then usually skips itself.

---

## 4. Configurations and tiers

<!-- doc_counts:begin configs -->

The sweep has 173 configurations (6 899 test runs): the 73 shared configurations and the 100 simulation-only ones below.

<!-- doc_counts:end configs -->

- The shared configurations, `sim/rtl_sim/bin/rtl_configs.py`: the set that lint, VC
  Static and synthesis also use, with the same numbering; every enabled test whose
  `requires` holds runs in each of them (a few one-feature configurations run only the
  tests of their feature). Three are the **deployed builds**, with the exact
  parameters of the boards: `tang_hdmi` (Tang Console 138K, HDMI with audio),
  `tang_panel` (its RGB panel) and `de0` (DE0-Nano-SoC, 8080 panel);
  `bin/check_deployed.py`, run by `run_lint`, compares them with the arvern-soc sources.
  The DPI and HDMI crosses after them (`dif5_ultra_rdreg`, `dif4_perf`, `dif4_lut0`,
  `dif4_frame1`, `dif5_frame4`, `dif4_vram_small`, `dif5_vram_max`) run the display
  driver with the richer GPUs, without the LUT, with one and four frame pointers and at
  both VRAM extremes, each with its own test list. The per-pixel alpha and bilinear builds after
  them: `classic_bil` (classic with `GPU_BILINEAR_EN`, which performance and ultra
  have: bilinear without blending), `blend_nomplane` (the alpha plane's word holder
  built for blending alone) and `bil_noxy` (bilinear asked for without x/y: absent);
  `ultra_rdlat3` puts the tap cache behind a three-cycle VRAM macro;
- the simulation-only configurations, `sim_*` in `sim/rtl_sim/bin/sim_configs.py`, each
  with its own test list. They cover the clock gate, both reset styles, every display
  driver, HD line widths (`DIM_W` and `DPI_LB_AW` 11), a 64 K-word VRAM, `DIM_W` 6 and
  the registered VRAM read data, also with the BDI exported (and without the LUT at the
  longest read latency, the pixel FIFO filled to its depth), and the pixel-clock crossing
  at four clock ratios with synchroniser jitter (below). The clock gate is crossed with
  the read latencies 2 and 3 and the data register, the ultra GPU (run-ahead, blending,
  triangles), the SPI and dual-PHY drivers and the Tang HDMI build (`sim_icg_*`), and
  the macros sit on the free-running clock in `sim_icg_freeclk*` (also at latency 3 with
  the data register and poisoned read data, and in the Tang panel build).

The sweep is run in tiers (`./run_all -list_configs` lists the configurations with
their test counts):

<!-- doc_counts:begin tiers -->

| Tier | `./run_all` | Configurations | Runs | Content |
|---|---|---:|---:|---|
| T0 | `-tier T0` | 173 | 397 | the `smoke_*` tests in every configuration |
| T1 | `-fast` (the default) | 3 | 196 | every test of the default build and of the shipped Tang HDMI build, the blending, per-pixel alpha, triangle, random-stream and discard tests and the bilinear tests in the ultra build |
| T2 | `-tier T2` | 21 | 766 | the personas and the deployed builds, the Tang HDMI build with the clock gate and under jitter, bilinear without blending (`classic_bil`), the F bound error's prefix behind run-ahead, a two-cycle macro, the DPI refresh and a small VRAM (`sim_bnd_*`), the random command stream with four seeds in six builds |
| T3 | `-tier T3`, `-rtl_sweep` | 173 | 6 899 | every configuration, and the functional-coverage gate |
| — | `-deployed` | 3 | 263 | the deployed builds alone |

<!-- doc_counts:end tiers -->

`BLNS_DEFINES="BLNS_VRAM_POISON=1"` (the configurations `sim_poison`, `sim_rdlat2_poison`,
`sim_rdlat3_poison` at read latencies 1, 2 and 3, and `sim_dif0_poison` with the BDI
exported) makes the bench VRAM return random data in every cycle but a read's data cycle,
as the macro contract allows (the data is valid in that cycle only, no hold), to show a
requester sampling the data late.

---

## 5. Clock crossings

With `DPI_PCLK_SEP = 1` the DPI/HDMI driver's crossings
(`blns_dpi_cdc`, `blns_dpi_regs`, `blns_dpi_bdi`, `blns_dpi_scan`) are timed by synthesis
but checked functionally by simulation only. Two bench-only parameters stress them:

- `PCLK_HALF`: the bench pixel clock's half period in 100 ps units (default 73 = 7.3 ns,
  pclk/hclk 0.68 with HCLK at 10 ns). Tests that change the pixel clock for a check
  (`dpi_underflow`, the slow phase of `dpi_audio_edge`) return to it; `dpi_wide` and
  `regs_lut_dpi` set their own. A slower clock scales the simulation timeout and the
  polls that span a frame; the I2S bit clock of `dpi_audio` and `dpi_audio_edge` follows
  the pixel clock (frames per line as by default); a faster clock raises `dpi_scale`'s
  `CLK_DIV` (`dpi_div`) so the pixel rate stays within the stream (underflow is
  `dpi_underflow`'s subject). All of these are unchanged at the default.
- `SYNC_JITTER = 1`: defines `ARV_SYNC_JITTER` (added by `bin/test_config.py`), the
  simulation-only metastability model of `arv_synchronizer` (arvern-ips): a bit whose
  input changed is captured one destination edge late at random, never twice in a row, so
  a change crosses in two or three edges and the bits of a bundle may arrive on different
  edges. The draws are seeded from the run's `SEED` and the instance path (reproducible
  with `-seed`); each instance prints `ARV_SYNC_JITTER: <path>: first late capture`.

`sim_dif4_pclk_r03/r1/r22/r45` (the DPI tests), `sim_dif5_audio_r03/r1/r22/r45` (HDMI
with audio, also `dpi_audio` and `dpi_audio_edge`) and the deployed Tang builds
`sim_tang_hdmi_r*` (also `dpi_ddc`) and `sim_tang_panel_r*` (the bilinear scaler, three
banks), both with the synchronous reset, run with jitter at pclk/hclk 0.3, 1,
2.2 and 4.5 (`PCLK_HALF` 167, 49, 23, 11: 0.30, 1.02, 2.17, 4.55; 49 rather than 50 so the
two clocks' edges drift instead of coinciding). The DBI
synchronisers (TE, scan line) run with jitter in `sim_dif3_jit` and, with the synchronous
reset, `sim_dif3_srst_jit`. By hand:
`BLNS_DEFINES="BLNS_PCLK_HALF=23 BLNS_SYNC_JITTER=1" ./run dpi_frame -rtl_config sim_dif4_pclk`.

---

## 6. Coverage runs

`./run_all -cov` and `./run <test> -cov` collect Verilator line, branch and toggle
coverage under `run/cov/` (`bin/runcov`, an HTML report `coverage.html`; `-j N` sets the
parallel builds, the CPU count by default; `COV_DIR=<dir>` writes elsewhere, and a lock
refuses a second run into one directory); `./cov_view`
lists those databases and opens one (`./cov_view -l` lists only). Each pair keeps its
`COVERAGE HIT:` lines in `cov/bins/` and, when it does not pass (a FAILED banner, a
timeout or an `ERROR:` line), its log in `cov/fail_logs/`. The compiler cache
(`bin/objcache_nopch`) caches every object but the precompiled header, which names the
build directory that made it.

---

## 7. GPU trace

`./run` also writes `slipstream.log`, a trace of every command, primitive and VRAM access
of the GPU ([format](slipstream_trace_format.md)); `sim/rtl_sim/bin/slipstream_summary.py`
summarises and checks it.

---

## 8. Driver host tests

`make -C sw/test` runs the driver's host unit test and `make -C sw/test -j8 lvgl` the
LVGL host test; what they check, the target builds and the board-level runs are in the
[verification guide](verification_guide.md#3-driver-host-tests).

---

## 9. LVGL benchmark bench

`bench/lvgl_bench/` runs LVGL v9.6's `lv_demo_benchmark`, unmodified, on an aRVern core
in aRVern's Performance persona and Belenos, in Verilator, once per Belenos persona; the results
and the conditions are in [performance.md](performance.md#2-lvgl-benchmark).

```
bench/lvgl_bench/
├── verilog/    tb_lvgl_bench.v (core, Belenos, zero-wait memories, counters, console,
│               the DPI panel model), lb_ahb_mem.v, submit.f (the core from ../arvern)
├── sw/         main.c (display, lockstep clock, per-frame measurement), lv_conf.h (the
│               deviations from LVGL's defaults), startup.S, link.ld, Makefile (fetches
│               LVGL 9.6.0, SHA-256 checked, into lvgl_src/), coremark/ (CoreMark port)
├── bin/        lvgl_bench.py (build, run, reduce), lvgl_bench_tables.py (the tables)
├── results/    per-scene results of each persona and resolution (tracked)
└── run/        builds, models and logs (git-ignored)
```

```bash
cd bench/lvgl_bench
python3 bin/lvgl_bench.py run --res 480x272 -j 3        # every persona, 3 simulations at once
python3 bin/lvgl_bench.py run --res 800x480 --persona light,ultra
python3 bin/lvgl_bench.py coremark                       # a CoreMark check of the core (run/coremark/, not published)
python3 bin/lvgl_bench.py tables --update                # the tables of doc/performance.md
```

`run` builds each persona's firmware (its platform header generated from
`rtl_configs.PERSONAS`), then its Verilator model (`BLNS_<P>` defines, the DPI driver,
`VRAM_WORDS` = W × H), and simulates in `run/<W>x<H>_<persona>/` (`sim.log`, `frame_<n>.ppm`
with `--dump n`: each scene's n-th frame from the VRAM, `panel_0.ppm`: the panel's last
frame). A run passes with the PASSED banner, no `ERROR` line and no GPU recovery; its
log is then reduced to `results/<W>x<H>/<persona>.csv`. Options: `--flush cpu` (the CPU
flush instead of DIRECT), `--tick real` (LVGL's clock in real time at 111 MHz instead of
the lockstep clock, and LVGL's own summary at the end), `--limit-ms` (a simulated-time
limit), `--tag` (a run name suffix), `--approx A` (the draw unit's `cfg.approx`: 6 by
default, GRAD \| TRANSFORM, the gradients and the rotated or scaled images of the personas
that can draw them; the blending is exact in every mode; 0: only the draws the GPU makes as
LVGL does; the `LB CFG` line of the log states the mode), `--profile` (the model counts the CPU's cycles per code word,
dumped per scene at the bench's `PROF` register: `results/<W>x<H>/<persona>_profile.csv`,
cycles per function and scene). `frames` compares the frames each GPU persona dumped
(`--dump`) with `light`'s: the pixels that differ and the largest difference per RGB565
field, per scene (`results/<W>x<H>/frames.csv`). A run takes 30 to 35 minutes at 480 × 272 and 55 to 75
minutes at 800 × 480 (1.0 to 1.6 M cycles per second, three at once).

---

## See Also

- [verification_guide.md](verification_guide.md) — the bench, the tests, coverage, formal proofs, lint and documentation checks
- [slipstream_trace_format.md](slipstream_trace_format.md) — the GPU trace format and the CPU + GPU profiler
- [synthesis_guide.md](synthesis_guide.md) — the synthesis flow on the same configurations
- [performance.md](performance.md) — the LVGL benchmark results and the GPU's cycles per pixel
- [lint/vc_static/README.md](../lint/vc_static/README.md) — the VC Static sign-off lint flow
