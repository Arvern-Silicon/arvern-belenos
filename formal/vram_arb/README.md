# vram_arb — the VRAM arbiter

`blns_vram_arb` with the Belenos requester map (window, GPU, refresh, read ahead), at
`RD_LAT` 1/2/3 × `RD_REG_EN` 0/1, with `GPU_EN = 0`, with the refresh untagged (`BK_TAG = 0`:
`CURSOR_EN = 0`; tagged otherwise, its cursor reads) and with the synchronous reset.

- Harness: `vram_arb_fv.sv` (black-box reference written from the documented policy:
  `doc/integration_guide.md` "VRAM arbitration", the module header).
- Environment (assumed): a request is held until granted; urgent only on the refresh and
  only with its request; an unbuilt slot never requests; no request during reset.
- Properties:
  - grants: one-hot (`a_onehot`), only with a request (`a_gnt_req`), never idle with a
    request (`a_work`);
  - priority: urgent refresh first (`a_urgent`), then the window (`a_win`) unless the GPU has
    lost `AGE_MAX` = 7 cycles in a row to it (`a_gpu_aged`), then the GPU (`a_gpu_normal`),
    then the refresh (`a_bk_normal`), the read ahead only in an idle cycle (`a_idle_only`);
  - starvation, in cycles without an urgent refresh (a wall-clock bound does not hold:
    the urgent refresh may take every cycle, a CL-swap frame at a pixel per cycle):
    GPU at most `AGE_MAX` = 7 (`a_gpu_starve`, granted by the 8th), window at most 1
    (`a_win_starve`), losses never past `AGE_MAX` (`a_lost_bound`); the urgent refresh
    never waits (`a_urgent`); the non-urgent refresh and the read ahead have no bound by
    design (the refresh turns urgent, the read ahead only takes idle cycles);
  - macro port: the granted requester's address, data and byte write enables
    (`a_mux_*`, `a_cen`, `a_idle`);
  - read return: valid exactly `RD_LAT + RD_REG_EN` cycles after a read grant, to that
    requester (`a_rvalid`), with its tag (`a_rtag`), with the macro's data of cycle
    grant + `RD_LAT` (`a_rdata_reg`, `a_rdata`); `rvalid_nxt_o` is the next cycle's
    `rvalid_o` (`a_rvalid_nxt`: the window's registered HREADYOUT relies on it);
  - `rd_pend_o` is 1 exactly when a read was granted in cycles t-`RD_L` .. t-1, i.e. from
    the cycle after the grant to the cycle its data returns (`a_rd_pend`);
  - `a_age_link`, `a_wait_link`: the arbiter's lost-cycle counter equals the model's.
- Technique: k-induction (depth 14; 10 without the GPU) with the base case to the same
  depth; `h_*` are lemmas of the model. Covers: every read return, a tagged GPU read,
  a tagged refresh (cursor) read, the aged cycle, an urgent cycle while the GPU is aged,
  back-to-back returns.
- Mutations: 29 in `proof.json`, each killed (`./run -mutate`).
