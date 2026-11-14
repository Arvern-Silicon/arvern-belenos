# fifo_dbi — the DBI parameter FIFO

`blns_dbi_fifo` (16 × 16 bits), asynchronous and synchronous reset, every input free (a
push while full is dropped: `DIF_PARAM` to a full FIFO, `PARAM_OVFL`; a pop while empty is
ignored; push and pop may come together). It is the DBI driver's only FIFO.

- Properties: level = pushes taken − pops taken (`a_level`), never above 16 (`a_no_ovfl`),
  FULL / EMPTY (`a_full`, `a_empty`), order with a tracked entry (`a_order`).
- Technique: k-induction (depth 10) with pointer and slot lemmas (`h_*`). Unbounded.
- Mutations: 7 in `proof.json`, each killed.
