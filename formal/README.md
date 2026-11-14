# Belenos formal proofs

Free tools only: Yosys reads and elaborates each harness, `yosys-smtbmc` with z3 checks
the model. The driver is `common/fv.py` (Python standard library; SymbiYosys is not used
and not needed).

```
./run_all                   every task of every proof, PASS / FAIL per task
./run_all vram_arb          one proof (shell patterns; proof:task for one task)
./run_all -mutate [proofs]  the mutation checks
./run_all -list             the tasks, their depth and technique
./run_all -all              also the slow tasks (deep multi-clock checks, ~20 min each)
-j N                        parallel tasks (default 2)
```

Each proof directory holds a `README.md`, the harness (`*_fv.sv`), `proof.json` (sources,
tasks, white-box probes, mutations) and a `run` script (`./run`, `./run -mutate`). Work
files (models, logs, counterexample VCDs) go to `<proof>/work/` (not tracked).

## How a task is checked

- Yosys: `read_verilog -formal`, `hierarchy` with the task's parameters, `proc`,
  `flatten`, `memory` (memories as flops), then `async2sync` (one clock) or `clk2fflogic`
  (several clocks: every clock is a free input sampled on the solver's step, so every
  frequency and phase relation is covered).
- Bounded check from reset to the task's depth (`yosys-smtbmc -t`), then, for the tasks
  marked with induction, the induction step at the same depth (`-i`): both pass = an
  unbounded proof. Then the covers (`-c`): every cover statement must be reached, so no
  assumption hides the behaviour the assertions talk about.
- Yosys has no hierarchical references (and ignores `bind`): a harness reads a DUT
  internal through a *probe*, a wire it declares undriven that the driver connects to the
  flattened DUT net (`connect -set`); a probe whose target does not exist is an error.
- A task with `comb_free` also checks, with Yosys on the elaborated design, that the
  listed outputs have no harness input in their combinational cone cut at every flop
  (outputs that come from flops only: step `comb`).
- `a_*` labels are the properties; `h_*` labels are lemmas of the reference model or of
  the DUT's internals that make the induction go through (they are asserted too).

## Mutations

`run_all -mutate` applies each mutation of a proof (an exact-text edit, or several) to a
temporary copy of the RTL, runs the bounded check with `--keep-going`, and requires it to
fail on one of the assertions the mutation targets ("killed"). It then lists every `a_*`
assertion that no mutation made fail: there must be none.

Last full run: 132 mutations, 132 killed (the kill column of the table below), every
`a_*` assertion failed by at least one, none timed out; the slowest are `cdc_dpi`'s
(`frame_start_ignores_done` and `fields_unlocked` about 45 minutes each, within their
tasks' time limits). The 49 tasks of `./run_all` all pass.

## Proofs

| Proof | What | Technique | Mutations killed |
|---|---|---|---:|
| [vram_arb](vram_arb/README.md) | grants, priority, starvation bounds, read return (tags), `rd_pend_o` | k-induction, 9 tasks | 29 / 29 |
| [fifo_gpu](fifo_gpu/README.md) | GPU command FIFO | k-induction | 13 / 13 |
| [gpu_px_bound](gpu_px_bound/README.md) | pixel engine without blending: an `ERR_CAUSE` 5 raised by F (a read or an immediate index past `VRAM_WORDS`) leaves no older pixel behind | bounded: 20 steps, 3 tasks | 2 / 2 |
| [gpu_tapcache](gpu_tapcache/README.md) | bilinear tap cache: hits coherent with a shadow VRAM word, drops at a write and a clear, the A8 companion lanes | k-induction, 3 tasks | 6 / 6 |
| [fifo_dbi](fifo_dbi/README.md) | DBI parameter FIFO | k-induction | 7 / 7 |
| [fifo_bk](fifo_bk/README.md) | backend FIFO alone and in `blns_backend`, the cursor on its VRAM slot, the frame start address | k-induction / bounded 24 | 25 / 25 |
| [cdc_dpi](cdc_dpi/README.md) | DPI clock-domain crossings, two free clocks | bounded: 14 steps, 24 in the slow tasks (`-all`) | 17 / 17 |
| [ahb_vram](ahb_vram/README.md) | window: read-ahead and posted-write coherence, write order, registered response, outputs from flops | bounded: 16 cycles, 7 tasks | 23 / 23 |
| [ahb_reg](ahb_reg/README.md) | register port: registered HREADYOUT equals the same-cycle ready, held behind a posted window write | k-induction, 5 tasks | 10 / 10 |
