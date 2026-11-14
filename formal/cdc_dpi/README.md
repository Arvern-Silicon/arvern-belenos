# cdc_dpi — the DPI clock-domain crossings

`blns_dpi` with `DPI_PCLK_SEP = 1` (`DIM_W` 4, `DPI_LB_AW` 9): the register side, the BDI
side, `blns_dpi_cdc` and the pixel-domain scan, with the HDMI transmitter in the `hdmi`
task, the bilinear scaler (three banks) in `dpi_nb3`.

## Model

- **Clocks**: `hclk` and `pclk` are free inputs (Yosys `clk2fflogic`): at every solver
  step either may move, so every frequency ratio and phase is covered, including edges in
  the same step.
- **Synchronisers**: every `arv_synchronizer` is replaced by
  `formal/common/arv_synchronizer_fv.v` (same name and ports): per bit and per
  destination edge the solver may capture a changed input one edge late (never twice in a
  row), so a change takes two or three destination edges and the bits of a bundle arrive
  independently: the formal counterpart of the `ARV_SYNC_JITTER` simulation model. The
  real primitive is not read.
- **Software and stream**: any register write in any cycle; the BDI pixels, the frame
  size and the line-buffer read data free; the line length the driver takes
  (`line_len_m1_i`: in Belenos the backend's latched one) latched from that size while
  `refresh_active` is low, as the backend latches it (`bk_ln_len`). Both resets at the start; in the tasks
  `dpi_prst` and `hdmi_prst` (`PRST_FREE`) the pixel reset alone may also be asserted at
  any step afterwards, for any number of steps (a pixel-only reset of any width, down to
  one solver step without a pixel-clock edge): there only the data taken at a start are
  checked (`a_staged_stable`, `a_fld_stable`, `a_aud_stable`; the handshake counts and the
  bank state restart with the pixel domain by design), and cover `c_prst_start` reaches a
  restart after such a reset. Before RTL change DR2-DPI-4 (the pixel-reset detector) a
  reset too short for `run_h` to show let staging writes through: the mutation
  `no_prst_detect` puts that back and fails `a_staged_stable` (depth 24).
- **No software rule for the staged configuration**: the register side keeps it locked
  while the pixel domain may take it (`blns_dpi_regs.v` section 4: from the `DPI_EN` write
  until the driver runs, a start in flight completed, and while an `UPDATE` is pending
  until the pixel domain has stopped). Before RTL change CDC-2 (VERIF_REVIEW.md, finding
  CDC-F1) `a_staged_stable` failed in two windows (a stop with an `UPDATE` pending: 23
  steps; `DPI_EN` cleared during the start: 14 steps); the mutations `start_not_held` and
  `stop_unlocks_update` put each window back and must fail.
- **No software rule for the AVI fields around a start, nor for `DPI_AUD`**: the register
  side ignores the field writes from the `DPI_EN` write until the driver runs (the
  staging lock's start terms, `start_lock`; formerly software rule SW4, assumed here), and
  the `DPI_AUD` writes while `AUD` is set or its pixel-domain copy has not come back clear
  (`AUD` crosses as a level handshake, `u_aud_x`; formerly the rule "change `DPI_AUD`
  with `AUD` clear and `ACTIVE` read 0", not modelled). The mutations
  `fields_start_unlocked`, `aud_unlocked`, `aud_no_handshake` and `aud_lock_on_active`
  (the lock on `AUD` and `ACTIVE` only, without the handshake) put the windows back and
  must fail.
- **HDMI field rule** (`hdmi` task, assumed): SW3 (finding CDC-F2, documented in the
  programming guide "HDMI mode"): the fields do not change while an `AVI` change is crossing (`AVI`
  not the same in the register, both synchroniser stages and the pixel copy). The
  documented rule "written with `AVI` clear" is not enough: a write that clears `AVI` and
  changes the fields just after `AVI` was set, or a short `AVI` pulse, lands while the
  pixel side copies them at the `AVI` rise; `hdmi_nosw3` keeps that counterexample.

## Properties

A value sampled at a pixel-clock edge is that of the solver step before it; "stable"
means unchanged since the previous pixel-clock edge, i.e. for a whole pixel period
before the sampling edge (what `belenos_dpi.sdc`'s one-period max delay assumes).

- `a_staged_stable`: the staged configuration, when the scan takes it (`apply`: the start,
  or a frame start with `UPDATE` pending);
- `a_sz_stable`, `a_sz_value`: the frame size, when its toggle is seen, and it is the size
  sent with that toggle;
- `a_tag_stable`: every bank's tag while the bank is full in the pixel view;
- `a_fld_stable` (`hdmi`): the AVI fields when the copy the InfoFrame sends loads (an
  `UPDATE` taken while `AVI` is on in the pixel domain, `AVI` rising there); a copy taken
  while `AVI` is off there is never sent (the rise takes the fields again).
- `a_aud_stable` (`hdmi`): `DPI_AUD` at every pixel-clock edge while `AUD` is set in the
  pixel domain or was in the clock before (the clock regeneration `N`, the channel
  status, the CTS meter); cover `c_aud` reaches the clock after `AUD` clears.
- Not checked: the generic packet (`DPI_PKT0-7`), read while the packet former sends it
  (loaded while `GP` is set); that load needs an HDMI vertical blanking with `GP` pending, beyond 30
  solver steps (cover unreached), so the proof says nothing about it (the hardware lock
  is `pkt_wr = ... & ~GP` on the register side, the waiver of `lint/cdc`);
- `a_upd_handshake`, `a_sz_handshake`, `a_bank_fill_rel`: requests sent minus
  acknowledges (fills minus releases per bank) is 0 or 1: no transfer lost (a second
  request before the first is acknowledged) or duplicated;
- `a_done_order`: the image done toggle (pixel → hclk, its own synchroniser bit, moved at
  or before the frame start it belongs to) is taken into account when the BDI side decides
  that frame start, one `hclk` cycle after it: an abandon never comes at a frame start
  whose previous frame had its image done. Checked while the pixel-side events (frame start, image done) come at least
  4 `hclk` edges apart (lines of at least the documented minimum, integration guide
  "Separate pixel clock"; the solver may program shorter ones, frames of one pixel
  included);
- `a_drop_no_write`: while the rest of a frame is dropped (image done), no line-buffer
  write.

## Technique

Bounded model checking from reset (multi-clock models of the whole driver are beyond
k-induction here). Default tasks (`dpi_quick`, `hdmi`, `dpi_nb3`, `hdmi_nosw3`, `dpi_prst` 16 steps, `hdmi_prst`): 14 solver steps, about
a minute each. Slow tasks (`run_all -all`): `dpi` 24 steps (about 20 minutes), whose
covers (to 36 steps) reach a start, a size taken, a stop with an `UPDATE` pending, a
full bank and two full banks, a frame dropped after its image done (`c_drop`) with the
next frame start waiting for it (`c_drop_start`: frames of a few pixels, which the
solver programs), and an `UPDATE` taken at a frame start (an `UPDATE` is accepted only
once the driver runs, so it needs the deeper covers), and `hdmi_deep` (24, covers to 36).
The bank and image done properties (`a_bank_fill_rel`, `a_tag_stable`, `a_done_order`,
`a_drop_no_write`) therefore need the slow task: at 14 steps no bank is filled yet;
their mutations run at depth 24-26. A solver step is one move of either clock, so 24
steps is about a dozen clock edges of each domain: enough for a start, an `UPDATE` and
a stop, and for frames of a few pixels only. The structural side
(which data cross without a synchroniser) is `lint/cdc`.
