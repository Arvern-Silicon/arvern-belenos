# fifo_gpu — the GPU command FIFO

`blns_gpu_fifo` at `AW` 3 and 4 (8 and 16 words, `DEPTH = 2^AW` as `blns_gpu` builds it:
the pointers wrap at `DEPTH` in every legal `GPU_FIFO_AW`), with the 2 tag bits of a build
with the immediate source (the `DISCARD` marker and the data) and the 1 of one without (the
marker), and with the synchronous reset. Every input is free: a push while full, a pop while empty and a
flush in any cycle.

- Properties: count = pushes taken − pops taken since the last flush (`a_count`), never
  above `DEPTH` (`a_no_ovfl`), FULL / EMPTY (`a_full`, `a_empty`), head and tag 0 while
  empty (`a_head_0`), order: a tracked word chosen by the solver is the head, with its
  tags, once every word ahead of it has been popped (`a_order`, `a_order_tag`). `FREE`
  (`GPU_STAT`) is `DEPTH − count` in `blns_gpu.v` (0 while a marker is pending).
- Technique: k-induction (depth 8) with lemmas on the pointers and the storage word of
  the tracked entry (`h_*`, white-box probes of the mapped memory). Unbounded.
- Mutations: 13 in `proof.json`, each killed.
