# gpu_tapcache — the bilinear tap cache

`blns_gpu_px_tc` (built with `GPU_BILINEAR_EN`): four colour words direct-mapped by (texel
row parity, word parity), each with its two A8 bytes. The harness keeps a shadow of one
VRAM word chosen by the solver (`trk`, constant): the memory reads a word at the grant and
returns it exactly `RD_LAT` cycles later; the write-back slot writes free data to a free
word in any cycle but the cycle of a read grant (one access per cycle on the GPU's port).
The look-up, the W merges, the clear and the data of the other words are free. The
contract of `blns_gpu_px_fw` is assumed: one read in flight, a colour read for the looked-up
word (its entry from the look-up's row parity and word parity), an A8 read for the
looked-up texel, the fill of the kind granted exactly `RD_LAT` cycles after the grant.
`RD_LAT` 1, 3, and 2 with the synchronous reset.

- Properties: a hit on `trk` returns the shadow value (`a_hit_data`: coherent with the
  VRAM, a write overtaking a colour read in flight or in its data cycle drops its data);
  no entry holds `trk` the cycle after a write to it (`a_drop_write_e*`) nor after a
  clear (`a_drop_clr_e*`: the command start and the freeze's hold); an A8 fill stores the
  texel's byte lane of the returned word (`a_abyte`) and its neighbour's when both share
  the A8 word (`a_apart`).
- Not proved here: "one read in flight" and "the request held with its address until
  granted" are properties of `blns_gpu_px_fw`'s port (the shared `rd_pend` rule of every
  F / W read), checked in simulation by `vram_arb_check.v` and `contract_check.v`; the
  formal model assumes them.
- Technique: k-induction (depth 8 / 10) with lemmas on the entries holding `trk`, the
  read in flight and the recorded fill fields (`h_*`, white-box probes). Unbounded.
- Mutations: 6 in `proof.json`, each killed.
