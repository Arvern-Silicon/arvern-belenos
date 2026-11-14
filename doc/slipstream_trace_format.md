<p align="center">
  <img src="img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Slipstream — the Belenos GPU trace

`slipstream.log` records what the Belenos GPU does, one cycle-stamped row per event:
every word written to `GPU_CMD`, every command decoded, every primitive from its `EXEC`
to its last write, command lists, errors, busy and idle periods and display frames. It
is written by a bench probe, `bench/verilog/probes_gpu.v`, that only observes the design.

In a SoC simulation it counts cycles exactly like the aRVern CPU trace (`asphalt.log`),
so the two merge by cycle: each command is matched to the store that pushed it, hence to
the firmware function that issued it. `sim/rtl_sim/bin/slipstream_profile.py` builds a
CPU + GPU profile from the two traces and the firmware ELF.

---

## Contents

1. [File at a glance](#1-file-at-a-glance)
2. [Row format](#2-row-format)
3. [Primitives](#3-primitives)
4. [Example](#4-example)
5. [Production](#5-production)
6. [Tools](#6-tools)

---

## 1. File at a glance

| Property | Value |
|---|---|
| Location | the simulation working directory: `sim/rtl_sim/run/slipstream.log` for the Belenos bench, next to `asphalt.log` in a SoC bench |
| Encoding | ASCII, LF line endings; a `#` header with the row legend |
| Granularity | one row per event, in cycle order; several rows may share a cycle |
| Generator | `bench/verilog/probes_gpu.v` (module `probes_gpu`) |
| Suppressed by | `NOTRACE` (the regression and coverage flows define it) |
| Present only when | the GPU is built (`GPU_EN = 1`) |

**Parsing contract:**

1. Skip every line that is empty or starts with `#`.
2. Every row is `<cycle>  <tag>  <payload>`: the cycle right-aligned in 12 characters,
   then a tag of up to three letters padded to three (`GO `), separated by two spaces.
3. Payload fields are `name=value` tokens separated by spaces, after the positional
   fields described below. Ignore unknown tokens and anything after a `#`: fields may be
   added.

---

## 2. Row format

| Tag | Payload | Written when |
|---|---|---|
| `PSH` | `w=<n>  <word>  used=<FIFO words>` | a word written to `GPU_CMD` enters the FIFO |
| `PSH` | `w=<n>  <word>  DROP full`\|`DROP GPU_EN=0` | a word written to `GPU_CMD` is dropped (`GPU_OVFL`) |
| `CMD` | `<src>  w=<n>  q=<cycles>  <word> [<operand>]  <COMMAND>  <fields>` | a command is decoded (with its operand, when it has one) |
| `GO` | `#<id>  <kind>  <w>x<h>  setup=<cycles>` | a primitive leaves the set-up for the pixel engine |
| `END` | `#<id>  <kind>  <how>  total=<cycles> [draw= px= rd= wr= wait= wbk= wwin=]` | a primitive is complete, draws nothing, or is abandoned |
| `LST` | `end`\|`flush`  `words=<n>  rd=<n>` | a command list ends (consumed, or ended by a flush) |
| `ERR` | `cause=<n> <name>  word=0x<word>` | the decoder stops on an error |
| `CTL` | `GPU_EN=0`\|`GPU_EN=1`, `CLEAR_ERR`, `ABORT`, `DISCARD`, `FLUSHED <n> words  w=<a>..<b>`, `MARK  used=<n>`, `MARK done`, `FREEZE`, `RELEASE` | control events: the GPU enabled or disabled, a `GPU_CTRL` write, the FIFO words a flush dropped, a `DISCARD` marker entering the FIFO and reached by the decoder (a command waiting for its operand then ends `(cut: no operand)`), the debug freeze |
| `BSY` / `IDL` | — | `GPU_STAT.BUSY` rises / falls |
| `WAI` | `start` / `end  frame`\|`end  flush` | a `WAIT_REFR_DONE` holds the decoder (`GPU_STAT.WAIT` rises), until the end of a frame or a flush (`CLEAR_ERR`, `ABORT`, `GPU_EN = 0`) |
| `FRM` | `start  n=<k>` / `done` | a display refresh starts / ends |

**`w` — the word number.** Every write to `GPU_CMD`, accepted or dropped, gets the next
number, from 0. A `CMD` row from the FIFO carries the `w` of its command word, so the
`PSH` row, and in a SoC the CPU store, of every command is known. `q` is the number of
cycles that word waited in the FIFO. A command read from a command list shows the list
word address as its source (`L:0x<word address>`), the `w` of the `CALL` that started the
list, and `q=-`.

**Commands.** The command name is followed by its decoded fields:

| Command | Fields |
|---|---|
| `SET_SRC` | `pitch` `fmt` [`IMM`] `base` |
| `SET_DST` | `pitch` [`XY`] `fmt`, then `base` (address mode) or `origin` (x/y mode) |
| `SET_SIZE` | `w` `h` |
| `SET_FILL`, `SET_TRANSP` | `c` |
| `SET_TEX` | `log2w` `log2h` `transp` `dsw` `free_pitch` `bound` `shade` [`remap`] |
| `SET_UV` | `u` `v` (`/64`: 10.6 texels) |
| `SET_STEP`, `SET_STEP_ROW` | `du` `dv` (`/2048`: signed 5.11) |
| `SET_XY` | `x` `y` |
| `SET_CLIP` | `x0` `y0` `x1` `y1` |
| `SET_TEXBOX` | `tw` `th` |
| `SET_GRAD` | `en` `n` `axis` `step` [`RGB`] |
| `SET_ALPHA` | `en` `a` |
| `SET_V0`…`SET_V2` | `x` `y` (`/16`: signed 12.4) |
| `SET_GRAD_RGB` | `dr` `dg` `db` (`/64`: signed, in 1/64 of an RGB565 field unit) |
| `SET_AUX` | `REMAP_TABLE` `addr` (word address), or `MASK_PLANE` `inv` `pitch` `addr` (1-bpp pixel address); `addr` in 8 hex digits |
| `SET_EXT sub=<n>`, `SET_AUX sel=<n>`, `INVALID` | none: an undefined sub-command, selector or opcode. A refused word is not decoded: it has no `CMD` row, its `ERR` row shows it (these names are a fallback) |
| `SET_EXT2` | `WAIT_REFR_DONE` (code `0x01`) or `RESET_STATE` (code `0x02`), then `code` `imm` (hex) |
| `CALL` | `n` `addr` (word address) |
| `EXEC_FILL` | `#<id>` `rop` `dsw` [`TRI`] [`remap`] |
| `EXEC_COPY`, `EXEC_COPYT` | `#<id>` `rop` `dsw` `ssw` [`MPLANE`] [`remap`] |
| `EXEC_SPAN` | `#<id>` `w` `delta` |
| `EXEC_EXPAND` | `#<id>` [`OPAQUE`] [`MASK`] `dsw` `delta` [`remap`] |
| `EXEC_TEXSPAN` | `#<id>` `n` `delta` |
| `EXEC_TEXRECT` | `#<id>` `delta` [`TRI`] |
| `FENCE` | `tag` [`IRQ`] [`AUTO`] |

Fields in brackets are printed only when set: a flag (`TRI`, `MPLANE`, `RGB`, `AUTO`, ...)
when its bit is 1, `remap=<n>` when the `REMAP` field is not 0 (1 `SRC`, 2 `DST`, 3
reserved: [palette remap](gpu_commands.md#17-palette-remap)).

`dsw` and `ssw` are the destination and source swaps as three bits {X, Y, CL}. `rop` is
the raster operation by name: `S ~S ~D S&D S|D S^D ~(S&D) ~(S|D) ~(S^D) ~S&D S&~D ~S|D
S|~D` for 0–12, then `ZERO`, `ONES`, `FILL` for 13–15
([raster operations](gpu_commands.md#4-raster-operations)). Two `CMD` rows have no
command fields: the operand of a flushed command, which the decoder discards
(`(operand of a flushed command: discarded)`), and a command whose operand never came
(`(cut: no operand)`).

**Errors.** The cause numbers and names follow `GPU_STAT.ERR_CAUSE`: 1 `invalid`, 2
`absent`, 3 `format`, 4 `list_cut`, 5 `rect_past_vram`, 6 `call_past_vram`; `word` is the
word `GPU_ERR` records ([errors](gpu_commands.md#6-errors-abort-and-flush)).

---

## 3. Primitives

Every `EXEC` gets an id, `#0` upwards, shown on its `CMD` row. The id goes through the
set-up (`GO`, with the size after clipping) and the pixel engine, and ends in exactly one
`END` row. With [run-ahead](gpu_commands.md#242-run-ahead), the set-up of one
primitive overlaps the drawing of the previous one, so their rows interleave.

| `<how>` | Meaning |
|---|---|
| `done` | the last pixel is written (`GPU_DONE`) |
| `empty` | nothing to draw: clipped away, or a triangle with no pixel |
| `abort` | abandoned by `ABORT` or `GPU_EN = 0` (closed once the engine has written its buffer) |
| `bound` | stopped by an access past the VRAM (`ERR_CAUSE` 5) |
| `drop` | dropped in the set-up by a flush |

`<kind>` is `FILL`, `TRI`, `LINE`, `COPY`, `COPYT`, `SPAN`, `EXPAND`, `TEXSPAN`, `TEXRECT` or
`TEXTRI`. The counters of a primitive that reached the pixel engine:

| Field | Meaning |
|---|---|
| `total` | cycles from its `EXEC` to its `END` |
| `draw` | cycles in the pixel engine (from `GO`) |
| `px` | pixels walked, written or not (transparent, clipped in a triangle box) |
| `rd`, `wr` | VRAM reads and writes it made |
| `wait` | cycles its VRAM request was refused |
| `wbk`, `wwin` | ... of which the VRAM went to the display refresh, the VRAM window (with its read-ahead) |

The reads and writes of all primitives plus the list reads (`LST rd`) are every GPU
access to the VRAM.

---

## 4. Example

A command list (from the FIFO word `w=0`) whose first command is a copy (abridged: the
`SET_FILL` and `SET_TRANSP` rows of the list are left out):

```
          28  PSH  w=0       70000060  used=1
          29  BSY
          32  PSH  w=1       00000008  used=1
          33  CMD  FIFO        w=0       q=5      70000060 00000008   CALL          n=96 addr=0x000008
          37  CMD  L:0x000008  w=0       q=-      2000001d 00004d79   SET_DST       pitch=29 fmt=0 base=0x004d79
          39  CMD  L:0x00000a  w=0       q=-      30008007            SET_SIZE      w=7 h=2
          45  CMD  L:0x00000d  w=0       q=-      1000000c 00001b5e   SET_SRC       pitch=12 fmt=0 base=0x001b5e
          49  CMD  L:0x000011  w=0       q=-      90000410            EXEC_COPY     #0 rop=S dsw=001 ssw=100
          52  GO   #0      COPY     7x2  setup=3
          87  END  #0      COPY     done   total=38 draw=35 px=14 rd=16 wr=14 wait=0 wbk=0 wwin=0
```

The `CALL` waited 5 cycles in the FIFO for its operand. Its list starts at word 8 and
inherits `w=0`. The copy of 7 × 2 pixels with the destination X swap and the source CL
swap takes 3 cycles of set-up and 35 of drawing, 16 reads and 14 writes, never refused.

---

## 5. Production

The Belenos bench instantiates the probe (`probes_gpu #(.GPU_EN(GPU_EN)) probes_gpu ();`)
and closes the file at the end of the test (`probes_gpu.close`). `./run <test>` writes
`slipstream.log`; `./run_all`, the sweeps and the coverage builds define `NOTRACE`, which
stops the file but keeps the probe's references elaborated.

A SoC bench adds `bench/verilog/probes_gpu.v` to its file list and sets, with `+define+`:

| Define | Default | Set to |
|---|---|---|
| `BLNS_INST` | `dut` | the hierarchical path of the Belenos instance |
| `BLNS_TRACE_CYCLE` | — | an existing cycle counter, for one cycle basis with another trace: the aRVern CPU trace's `probes_instructions.trace_cycle` |
| `BLNS_TRACE_CLK` | `` `BLNS_INST.hclk_i `` | without `BLNS_TRACE_CYCLE`, the clock the probe counts (a free-running clock when Belenos's clock is gated) |

The probe samples on the Belenos clock and starts once the reset has been applied. For
the merge with `asphalt.log`, Belenos and the CPU must run on the same clock.

---

## 6. Tools

**`sim/rtl_sim/bin/slipstream_summary.py [slipstream.log] [--perf sim.log]`** — the trace
on its own: primitives per kind with their set-up and drawing cycles, pixels, cycles per
pixel, accesses and refused cycles; command lists; the slowest primitives; errors. It
checks that every id is opened by one `EXEC` and closed by exactly one `END`, and that the
`w` numbers follow each other; with `--perf`, that the traced accesses equal the
`gpu_rd` / `gpu_wr` counts of the Belenos bench `PERF:` line. It exits with 1 when a check
fails.

**`sim/rtl_sim/bin/slipstream_profile.py --asphalt asphalt.log --slipstream slipstream.log --elf fw.elf`**
— the CPU and GPU together. The n-th store to `GPU_CMD` in `asphalt.log` is the word
`w=n` (the store data is checked against the pushed word), so every command, and the
primitive it starts, is charged to the function that pushed it; the commands of a list
to the function that pushed its `CALL`. A shadow call stack, rebuilt from the calls and
returns of `asphalt.log` (a trap handler counted as called from the interrupted
function), charges the same work to every caller too, so a drawing routine is credited
with the GPU work of the driver calls it makes.

The first table is the CPU time per function:

| Column | Meaning |
|---|---|
| `self cyc`, `self %` | CPU cycles in the function itself |
| `incl %` | ... with its callees |
| `instr` | instructions executed |
| `reg rd` | Belenos register reads: status polling (`GPU_STAT`, `STATUS`) |
| `vram` | VRAM window accesses: pixels the CPU draws or reads itself |

The second, the GPU work per issuing function, callees included:

| Column | Meaning |
|---|---|
| `gpu wr` | words pushed to `GPU_CMD` |
| `prims`, `listed` | primitives started, of which from command lists |
| `draw`, `draw %` | the GPU drawing cycles those primitives cost |
| `px`, `cyc/px` | their pixels, drawing cycles per pixel |
| `wait` | cycles their VRAM requests were refused |

then the primitives per kind, and with `--frames` one line per display frame: its length,
the share of it the GPU is busy and the share it waits for a frame end, the primitives and
pixels started in it and the functions that took the most CPU time. A `WAIT_REFR_DONE`
keeps `GPU_STAT.BUSY` set while the GPU does nothing: the profiler counts those cycles
(`WAI` rows) as waiting, not as busy. `--marks` gives the same line per interval between
the firmware's trace markers (`# mark <n>` rows of `asphalt.log`), for instance one per
frame of a demo rather than per display refresh.

Down to the instruction: `--annotate <function>` lists every instruction of the function
with its execution count, the cycles until the next instruction and its source line;
`--lines` gives the CPU cycles per source line, across all functions (both read the
ELF's line information through `addr2line` and `objdump`).

`asphalt.log` may cover only part of the run (a cycle or marker window): the GPU tables
then count only what was pushed or started inside it, the `w` numbering is aligned on the
window's first `GPU_CMD` store, and the inclusive column only knows the calls made inside
the window. A loop collapsed in `asphalt.log` (`# repeat:`) is counted in full: its
instructions and accesses are added to the loop's instructions.

Reading it: a function with many `reg rd` while the GPU is busy most of the frame waits
for the GPU; a GPU idle most of the frame waits for the CPU. The CPU cycles of the
driver's push path against the GPU cycles they buy tell whether recording the commands
into a list would pay. Options: `--from` / `--to` (a cycle window), `--blns-base`
(register port, default `0x10050000`, the FPGA boards' address; `0x10043000` for the
arvern-soc `chip_example`), `--vram-base` / `--vram-size` (the window),
`--top`, `--mhz`, `--nm` (default `riscv-none-elf-nm`; `addr2line` and `objdump` are
taken next to it).
