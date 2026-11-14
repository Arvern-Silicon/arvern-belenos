# fifo_bk — the backend FIFOs

`blns_bk_fifo` has no guard: its users must never push when it is full nor pop when it is
empty. Two halves:

- alone (`fifo_bk_fv.sv`), with that rule assumed, at the raw pixel FIFO's shapes (read
  latency + 4: 5, 6, 7 and 8) and the output queue's (3); 3, 5, 6 and 7 are non-power-of-two
  wraps: count (`a_cnt`) and order with a tracked entry (`a_order`); k-induction (depth 8)
  with pointer and slot lemmas;
- in `blns_backend` (`bk_ctx_fv.sv`), with a free display driver and configuration and a
  VRAM / LUT that follow the arbiter's contract (grant only with a request, read data
  valid exactly `RD_LAT` cycles after a VRAM grant, one after a LUT grant): the fetch never
  pushes into a full raw FIFO (`a_raw_no_ovfl`), the colour stage never pushes into a full
  output queue (`a_oq_no_ovfl`), neither is popped when empty (`a_raw_no_udfl`,
  `a_oq_no_udfl`), and the pixel credit stays within the raw FIFO's depth, read latency + 4
  (`a_credit`); the fixed-latency
  contract the backend relies on without masking it: a token that fetched its word meets
  the word's read data valid at stage B (`a_word_data`), a LUT pixel in stage C its LUT
  read data valid (`a_lut_data`); the VRAM and LUT requests come from flops, so a grant in
  the cycle `refresh_active_i` falls is wasted, and the covers `c_vgnt_end` / `c_lgnt_end`
  reach it; LUT build at read latency 1 and 4, no-LUT build at 2, and without the cursor
  at 1. Bounded: 24 cycles from reset (a frame runs 5 cycles after `refresh_active`
  rises, after the start address' shift-add; the covers reach a full raw FIFO and a full
  output queue inside it).
- The hardware cursor (`CURSOR_EN = 1`, free cursor registers) on the backend's VRAM slot:
  the slot's request is held with its address and tag until granted while the backend may
  request (`a_slot_hold`); a pixel grant always issues its pixel (`a_pgnt_issue`: no read
  whose word would land in the word buffer under the tokens behind it); a tagged return
  never loads the word buffer (`a_tag_wbuf`), never meets a pixel token that fetched
  (`a_word_data`) nor a cursor-box token in stage B (`a_cur_ret`: the line buffer is never
  loaded under it); the registered `cur_wait` equals its terms (`a_cur_wait`). The LUT
  request announced one cycle ahead (`lreq_nxt_o`, for the register port's registered
  HREADYOUT, proof `ahb_reg`) is the next cycle's request (`a_lreq_nxt`). Covers: a
  cursor pixel in stage B, a tagged return, a cursor read waiting for its grant.
- The start address: the walker starts every frame that runs (its first running cycle) at
  base + (X ? W'−1 : 0) + (Y ? (H'−1)·P : 0) of the latched frame (`a_start_pa`), and the
  shift-add offset is (H'−1)·P (mod 2^9) while the requests may be raised (`a_yofs`),
  under any configuration change and any frame start, end or abandon.
- Mutations: 25 in `proof.json`, each killed. `lreq_nxt_lut_mode` (the LUT request
  announced one cycle ahead without its `lut_mode` term) replaces `lreq_nxt_req_on`, which
  was equivalent: `req_on_i` and `req_on_nxt_i` differ only in the cycles
  `refresh_active_i` rises or falls, where the backend is flushing and `raw_valid_nxt_i`
  is 0.
