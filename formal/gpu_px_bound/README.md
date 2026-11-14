# gpu_px_bound — ERR_CAUSE 5 by stage F keeps the prefix

`blns_gpu_px_fw` (stages F and W and the VRAM port), built without blending and bilinear
sampling, with the mask plane, the palette remap and the immediate source, `VRAM_AW` 4 and
`VRAM_WORDS` 12 (words at and past 12 out of range).

- Harness:
  - Stage A is free: a token appears while A runs, is held with its fields until F takes
    it, and is dropped by an abort.
  - The VRAM port is free: a grant only while requested, the read data exactly `RD_LAT`
    cycles after a read grant, any data.
  - The rectangle's operation is decoded as `blns_gpu_px_a` does, from a free kind, raster
    op, depth, remap mode and mask plane, constant over the run.
  - The free tokens over-approximate what A sends.
- Property: a bound error that W did not raise itself (its read, or the slot's write, past
  the VRAM) leaves no older pixel behind: W takes its token in that cycle and L holds none
  (`a_no_drop`). An F read past `VRAM_WORDS` (source, mask) and an immediate index past it
  therefore wait while W holds a pixel it cannot take in the cycle: a DST remap looking its
  colour up, the buffer waiting for the write-back slot. The pixels before the faulting
  one are drawn.
- Technique: bounded, depth 20 from reset, at `RD_LAT` 1, 2 and 3; the cover (a bound
  error raised by F) is reached.
- Mutations: 2 in `proof.json` (the F bound error and the immediate-index bound error
  raised at once), each killed.
