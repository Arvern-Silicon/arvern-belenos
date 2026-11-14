# ahb_reg — the register port's registered HREADYOUT

`blns_ahb_reg` with the LUT window (`blns_lut`) behind it. The port's HREADYOUT is a flop,
loaded with the ready of the next cycle's data phase decided from the next state of the
flops that ready depends on; this proof shows it equals, in every cycle, the ready
decoded from the same cycle's state, so the port has exactly the wait states of a
combinational HREADYOUT.

- Environment: an AHB-Lite manager with free transfers and sizes; HREADY is the port's
  HREADYOUT while it has the data phase, free otherwise (and free in every cycle in
  `free_hready`). The backend's LUT request is the one it announced one cycle ahead
  (`bk_lreq_nxt` free, the request its registered copy: the backend's side of the
  contract is `fifo_bk` `a_lreq_nxt`). The register and GPU windows are ready with the
  transfer, as in `belenos_core`; the BDI window too with a built-in driver, its ready
  free with an external one (`BDI_EXT_EN`). The VRAM window's posted-write flag is
  the registered copy of its free next state (`vw_pend_nxt_i`: the window's side of the
  contract is `ahb_vram` `a_wb_nxt`).
- Properties: `a_hready`, HREADYOUT equals the same-cycle ready (the selected window's
  ready, the two-cycle ERROR), whatever the transfer, the LUT bank count, the bounded
  wait of the LUT window and the backend's requests; `a_lut_wr` (with the fabric's
  HREADY), a LUT write never completes without its macro write; `a_vw_start`, no
  transfer starts on the register bus while a window write is posted; `a_vw_cont`, a
  transfer started is not interrupted by one (an external driver's or the LUT's
  handshake). Lemmas: the harness's data-phase flag is the port's (`h_dph`), a granted
  LUT read holds its data phase (`h_rd_pend`), the harness's started flag is the port's
  (`h_go`).
- Covers: a LUT write that waits, one that takes the macro over the backend (the bounded
  wait), one without a wait; a LUT read, back to back with the next LUT access; an
  ERROR; a wait from the external BDI driver; a transfer held behind a posted window
  write, one started that continues while a write is posted.
- Technique: k-induction, depth 10 (5 tasks: two banks, one bank, external BDI with the
  privilege check, free HREADY, synchronous reset).
- Mutations: 10 in `proof.json` (each next-state term of the ready dropped or shifted,
  the window hold removed or made to interrupt), each killed.
