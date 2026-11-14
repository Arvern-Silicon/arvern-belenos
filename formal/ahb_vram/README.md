# ahb_vram — the VRAM window

`blns_ahb_vram` behind the real `blns_vram_arb` (Belenos map), at total read latencies 1
to 4 (`RD_LAT` 1–3, with and without `RD_REG_EN`: the window registers the read data
itself without it), and with 6 populated words (the read ahead stops at the end of the
VRAM).

- Environment: an AHB-Lite manager with free transfers (address and control held while
  HREADY is low; HREADY is the window's HREADYOUT), a free GPU (reads and writes, held
  until granted; its granted writes snooped through `mwr_i` / `mwaddr_i` as in
  `belenos_core`), a free refresh (reads, urgent or not). The VRAM is modelled for one
  word A chosen by the solver: its content follows every granted write to A with its
  byte enables and is returned `RD_LAT` cycles after a read of A; other words read free
  data. The VRAM is not reset (A's content starts free).
- Properties:
  - `a_coherent`: an AHB read of A that completes OKAY, with no GPU write to A between
    its address phase and its completion, returns A as the bus wrote it: the VRAM's
    content with the window's posted write over it, whether the read-ahead buffer
    serves it (no wait state), a read ahead in flight does, or a demand read. The rules
    behind it: `dm_stale` (a write during a demand read: the data is not kept),
    `pb_whit` (a write to the buffered word, by the GPU at its grant or by the window at
    its completion on the bus, drops it), `pb_stale` (a read ahead retargeted or written
    in flight is not used), a read the buffer misses waiting for the posted write;
  - `a_wr_post`, `a_wr_now`, `a_wr_room`: every window macro write is the posted write
    or the write completing in that cycle, with its address, byte enables and data; no
    write completes while one is posted (none lost, duplicated or reordered);
  - `a_wb_pend`, `a_wb_nxt`: `wb_pend_o` is set exactly while a completed write is not
    yet made, `wb_pend_nxt_o` is its next state (the contract `ahb_reg` assumes);
  - `a_hready`: HREADYOUT equals the ready decoded from the same cycle's state;
    `a_idle` (also the first cycle out of reset), `a_resp`, `a_err2`: no data phase is
    OKAY with no wait state, HRESP is set exactly in an ERROR's two cycles, HREADYOUT
    low then high; `a_progress`: a transfer the refresh does not hold off completes
    within 2·`RD_L` + 4 cycles;
  - structural (`comb_free`): HREADYOUT, HRESP and HRDATA have no harness input in their
    combinational cone: no grant, read valid, request or macro output reaches them in
    the same cycle.
- Covers: a hit from the buffer, a wait for a read ahead in flight, a demand read, a hit
  on a word written earlier, a write posted, a write waiting behind a posted one, a hit
  while a write is posted, a read of A after its posted write was made, an ERROR.
- Technique: bounded from reset (depth in `proof.json`); 7 tasks, every one but `lat1_w6` with covers.
- Mutations: 23 in `proof.json` (each rule above removed, each next-state term of the
  ready shifted, the outputs made combinational), each killed.
