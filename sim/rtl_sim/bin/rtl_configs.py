#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    rtl_configs.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Single source of truth for the belenos RTL parameterization sweep set.
#
# Consumed by run_lint_sweep.py (./run_lint -sweep), this directory's
# gen_rtl_params.py (VC Static run_vclint -rtl_config/-rtl_sweep) and
# synthesis/synopsys/gen_rtl_params.py (run_syn -rtl_config/-rtl_sweep).
#
# Each entry is (label, {PARAM: value}). Unspecified parameters take their
# RTL default. The label is used to name log files and the summary column.
# Every entry must be legal for the elaboration checks of belenos.v
# (DIM_W 4..16, FRAME_NR 1, 2 or 4, ...); VRAM_AW is derived from VRAM_WORDS.
#
# PERSONAS is the integrator-facing ladder, ordered by the CPU time the GPU
# saves for an LVGL-style UI: light (no GPU, the CPU draws through the VRAM
# window), essential (the 2D GPU core, every feature knob off), classic
# (+ x/y + clip and affine blit, gradient, lines, remap, mask plane,
# immediate source, the hardware cursor: the RTL defaults), performance
# (+ alpha blending and with it anti-aliased lines, run-ahead, bilinear
# sampling, a command FIFO of 16 words), ultra (+ triangles, a FIFO of 32 words). A persona sets every
# feature parameter, the command FIFO depth (GPU_FIFO_AW: 8 words up to
# classic) included; integration parameters (VRAM_WORDS, DIM_W, DIF_TYPE,
# PRIV_CHECK_EN, ASYNC_RST_EN) stay at their defaults, they belong to the SoC
# and the panel.
#
# Coverage rationale -- every parameter that gates a generate block or sizes
# an interface has an entry reaching each of its branches:
#   - DIF_TYPE selects the built-in display driver (0 = BDI: none, the BDI
#     is exported; 1 = DBI over SPI; 2 = DBI over the 8080 bus, the default;
#     3 = both DBI buses plus the PHY_SEL mux; 4 = DPI). All five values are
#     listed. With DPI, DPI_SCALER 0/1/2 (none, nearest, bilinear: two or three
#     banks), DPI_PCLK_SEP=1 (the crossing synchronisers) and DPI_LB_AW below,
#     at and above DIM_W (truncated, full, extended line-buffer addresses).
#   - FRAME_NR sizes the frame-pointer bank and the FRAME_SEL masks; 1 (no
#     select bits) and 4 (two select bits, every pointer) bracket the default 2
#     (3 is not a legal value).
#   - LUT_EN removes blns_lut and the LUT macro port logic; LUT_BANKS=1 makes
#     bank 1 RAZ/WI and pins LUT_CFG.REFR_BANK.
#   - GPU_EN removes the GPU and its arbiter requester. Each GPU feature
#     knob is off in one config (classic has blending and triangles off, the
#     personas switch them on); "essential" turns every feature off (remap and
#     mask plane, lines and the immediate source included: on in classic
#     and above). "imm_off" turns the immediate source (GPU_IMM_EN) off,
#     "drv_hw_ra" has it with run-ahead, "gpunoline" the lines off.
#   - CURSOR_EN adds the hardware cursor (backend, register bank, the read
#     tag of the refresh's arbiter slot): on from classic up and by default
#     (so in most configs), off in light, essential, "cursor0" (classic
#     without it); "light_cursor" has it without a GPU.
#   - GPU_FIFO_AW sizes the command FIFO and its FREE / USED counts: 3 (the
#     default, essential, classic and the boards), 4 in performance and
#     "gpu_fifo16" (classic), 5 in ultra and every config built from it, 6 in
#     "gpu_fifo64".
#   - PRIV_CHECK_EN adds the U-mode ERROR path on both AHB ports.
#   - ASYNC_RST_EN=0 is the only config that builds the arv_ipdff and
#     arv_synchronizer synchronous-reset branches (both PHYs, dif3 variant).
#   - VRAM_WORDS changes the VRAM address width everywhere (window port,
#     arbiter, GPU, backend, pixel-address width PA_W = VRAM_AW+5); the
#     non-power-of-two small config has an out-of-range window region, the
#     1-bit and 24-bit configs are the two width extremes.
#   - DIM_W sizes every width/height field and walker counter; 4 and 16 are
#     the extremes around the default 10.
#   - VRAM_RD_REG_EN adds the read data register and every requester's
#     second read stage (the GPU's second read-ahead entries): on with the
#     RTL defaults, with the ultra GPU, and in "full".
#   - VRAM_RD_LAT (the macro's own latency) deepens the arbiter's read
#     return register and the refresh's token line like VRAM_RD_REG_EN, but
#     no data register: 2 alone, 3 with the ultra GPU, 3 with VRAM_RD_REG_EN
#     (the longest latency, 4 cycles).
#   - "minimal" and "full" cross the axes at their two ends.
#----------------------------------------------------------------------------

_GPU_OFF  = {"GPU_EN": 0, "GPU_XY_EN": 0, "GPU_GRAD_EN": 0,
             "GPU_BLEND_EN": 0, "GPU_TRI_EN": 0, "GPU_RUNAHEAD_EN": 0,
             "GPU_REMAP_EN": 0, "GPU_MPLANE_EN": 0, "GPU_IMM_EN": 0, "GPU_LINE_EN": 0,
             "GPU_BILINEAR_EN": 0, "GPU_FIFO_AW": 3}
_DISPLAY  = {"LUT_EN": 1, "LUT_BANKS": 2, "FRAME_NR": 2}
_CLASSIC  = dict(_DISPLAY, GPU_EN=1, GPU_XY_EN=1,
                 GPU_GRAD_EN=1, GPU_BLEND_EN=0, GPU_TRI_EN=0, GPU_RUNAHEAD_EN=0,
                 GPU_REMAP_EN=1, GPU_MPLANE_EN=1, GPU_IMM_EN=1, GPU_LINE_EN=1, CURSOR_EN=1,
                 GPU_BILINEAR_EN=0, GPU_FIFO_AW=3)
# The immediate source: on from classic up and by default, off
# in essential and imm_off
_DRV_HW_OFF = {"GPU_IMM_EN": 0}

PERSONAS = [
    ("light",          dict(_DISPLAY, LUT_BANKS=1, CURSOR_EN=0, **_GPU_OFF)),  # display controller, the CPU draws, one LUT bank
    ("essential",      dict(_CLASSIC, GPU_XY_EN=0, GPU_GRAD_EN=0,
                            GPU_REMAP_EN=0, GPU_MPLANE_EN=0, GPU_IMM_EN=0, GPU_LINE_EN=0,
                            CURSOR_EN=0)),                          # the 2D GPU core: every feature knob off
    ("classic",        _CLASSIC),                                   # RTL defaults: 2D GPU, x/y + clip, affine blit, gradient, lines, cursor, FIFO of 8
    ("performance",    dict(_CLASSIC, GPU_BLEND_EN=1, GPU_RUNAHEAD_EN=1, GPU_BILINEAR_EN=1,
                            GPU_FIFO_AW=4)),                        # + alpha blending (LVGL at 16 bpp), run-ahead, bilinear, FIFO of 16
    ("ultra",          dict(_CLASSIC, GPU_BLEND_EN=1, GPU_TRI_EN=1, GPU_RUNAHEAD_EN=1, GPU_BILINEAR_EN=1,
                            GPU_FIFO_AW=5)),                        # + triangles, FIFO of 32
]

_ULTRA    = dict(dict(PERSONAS)["ultra"])

CONFIGS = PERSONAS + [
    # label            parameter overrides (from the RTL defaults = classic)
    ("dif0",           {"DIF_TYPE": 0}),                            # No built-in driver: BDI exported, panel pins tied
    ("dif1",           {"DIF_TYPE": 1}),                            # SPI PHY only
    ("dif3",           {"DIF_TYPE": 3}),                            # Both PHYs and the PHY_SEL mux
    ("dif4",           {"DIF_TYPE": 4}),                            # DPI driver, nearest-neighbour scaler, one clock
    ("dif4_noscale",   {"DIF_TYPE": 4, "DPI_SCALER": 0}),           # DPI without a scaler
    ("dif4_bilinear",  {"DIF_TYPE": 4, "DPI_SCALER": 2}),           # DPI with bilinear (three banks)
    ("dif4_pclk",      {"DIF_TYPE": 4, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2}),  # Separate pixel clock: the crossing synchronisers
    ("dif4_lb9",       {"DIF_TYPE": 4, "DPI_LB_AW": 9}),            # Line buffer narrower than DIM_W (truncated addresses)
    ("dif4_lb12",      {"DIF_TYPE": 4, "DPI_LB_AW": 12}),           # Line buffer wider than DIM_W (extended addresses)
    ("dif4_dim16",     {"DIF_TYPE": 4, "DIM_W": 16, "DPI_SCALER": 2}),  # DPI at the widest fields
    ("dif5",           {"DIF_TYPE": 5}),                            # HDMI: DPI driver and TMDS encoder, one clock
    ("dif5_pclk",      {"DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2}),  # HDMI on its own pixel clock
    ("dif5_noddc",     {"DIF_TYPE": 5, "DPI_DDC_EN": 0, "DPI_ISLAND_EN": 0}),  # HDMI without DDC and data islands (DVI only)
    ("dif5_audio",     {"DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_AUDIO_EN": 1}),  # HDMI audio on its own pixel clock
    ("dif5_audio_1clk", {"DIF_TYPE": 5, "DPI_AUDIO_EN": 1}),            # HDMI audio, one clock (no crossing synchronisers)
    ("frame1",         {"FRAME_NR": 1}),                            # Single frame pointer, zero-width FRAME_SEL field
    ("frame4",         {"FRAME_NR": 4}),                            # Every frame pointer
    ("lut0",           {"LUT_EN": 0}),                              # LUT absent (LUT window unmapped)
    ("lut1bank",       {"LUT_BANKS": 1}),                           # Bank 1 RAZ/WI, REFR_BANK pinned
    ("gpu0",           {"GPU_EN": 0}),                              # GPU absent
    ("gpunoxy",        {"GPU_XY_EN": 0}),                           # No x/y destinations / clip window / affine blit
    ("gpunograd",      {"GPU_GRAD_EN": 0}),                         # No gradient fill
    ("ultranoxy",      dict(_ULTRA, GPU_XY_EN=0)),                  # Triangles requested without x/y: absent
    ("classic_ra",     {"GPU_RUNAHEAD_EN": 1}),                     # Run-ahead: descriptor copy, decoder free while drawing
    ("priv1",          {"PRIV_CHECK_EN": 1}),                       # U-mode ERROR on both ports
    ("sync_rst",       {"ASYNC_RST_EN": 0}),                        # Synchronous reset branches of arv_ipdff / arv_synchronizer
    ("sync_rst_dif3",  {"ASYNC_RST_EN": 0, "DIF_TYPE": 3}),         # Sync reset with both PHYs (every synchronizer instance)
    ("sync_rst_dif4",  {"ASYNC_RST_EN": 0, "DIF_TYPE": 4, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2}),  # Sync reset in both DPI domains
    ("sync_rst_dif5",  {"ASYNC_RST_EN": 0, "DIF_TYPE": 5, "DPI_PCLK_SEP": 1}),  # Sync reset with the TMDS encoder
    ("sync_rst_audio", {"ASYNC_RST_EN": 0, "DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_AUDIO_EN": 1}),  # Sync reset with HDMI audio
    ("vram_small",     {"VRAM_WORDS": 1000}),                       # Narrow, non-power-of-two VRAM (out-of-range window words)
    ("vram_tiny",      {"VRAM_WORDS": 2}),                          # Minimum address width
    ("vram_max",       {"VRAM_WORDS": 16777216}),                   # Maximum address width
    ("dim4",           {"DIM_W": 4}),                               # Narrowest width/height fields
    ("dim16",          {"DIM_W": 16}),                              # Widest width/height fields
    ("ultra_dim4",     dict(_ULTRA, DIM_W=4)),                      # Blending and triangles at the narrowest fields
    ("ultra_vram_tiny", dict(_ULTRA, VRAM_WORDS=2)),                # ... and the narrowest addresses
    ("minimal",        {"LUT_EN": 0, "GPU_EN": 0, "DIF_TYPE": 0,
                        "FRAME_NR": 1, "VRAM_WORDS": 1000}),        # Everything optional removed
    ("full",           dict(_ULTRA, DIF_TYPE=3, PRIV_CHECK_EN=1, FRAME_NR=4,
                            DIM_W=16, VRAM_RD_REG_EN=1)),           # Everything at its largest
    ("rdreg",          {"VRAM_RD_REG_EN": 1}),                      # Registered VRAM read data
    ("ultra_rdreg",    dict(_ULTRA, VRAM_RD_REG_EN=1)),             # ... with blending, triangles and run-ahead
    # Added after the 1.0 review (appended, so the numbering above does not move)
    ("gpu_fifo16",     {"GPU_FIFO_AW": 4}),                         # Classic with the performance FIFO (16 words)
    ("gpu_fifo64",     {"GPU_FIFO_AW": 6}),                         # Largest command FIFO (64 words, FPGA LUT RAM)
    ("rdlat2",         {"VRAM_RD_LAT": 2}),                         # Two-cycle VRAM macro (block RAM with its output register)
    ("ultra_rdlat3",   dict(_ULTRA, VRAM_RD_LAT=3)),                # Three-cycle VRAM macro, blending, triangles and run-ahead
    ("rdlat3_rdreg",   {"VRAM_RD_LAT": 3, "VRAM_RD_REG_EN": 1}),    # Longest read latency: three-cycle macro and the data register
    # Later additions, appended
    ("imm_off",        dict(_DRV_HW_OFF)),                          # Classic without the immediate source
    ("drv_hw_ra",      {"GPU_RUNAHEAD_EN": 1, "GPU_IMM_EN": 1}),    # Immediate source with run-ahead (data behind a drawing primitive)
    ("drv_hw_ra_dif0", {"GPU_RUNAHEAD_EN": 1, "VRAM_RD_REG_EN": 1, "DIF_TYPE": 0}),  # ... registered reads, frames driven by the bench
    # Feature-cost pair partners for doc_area_tables.py --features, appended
    ("gpunoremap",     {"GPU_REMAP_EN": 0}),                        # Classic without the palette remap
    ("gpunomplane",    {"GPU_MPLANE_EN": 0}),                       # Classic without the mask plane
]

# DEPLOYED: the builds the boards ship, with every parameter the SoC sets
# (bin/check_deployed.py compares them with the arvern-soc sources when that
# repository is checked out next to this one). They follow the configs above
# so the numbering of those does not move; the DPI crosses below are appended
# after them for the same reason.
#   tang_hdmi   Tang Console 138K, BOARD_HDMI = 1 (with BOARD_HDMI_AUDIO = 1):
#               arvern-soc/fpga/sipeed_tang_console_138k/rtl/verilog/arvern_fpga.v
#   tang_panel  the same board with its RGB panel (BOARD_HDMI = 0,
#               BOARD_LCD_PCLK_SEP = 1, the defaults)
#   de0         DE0-Nano-SoC with the LT24 8080 panel:
#               arvern-soc/fpga/alteral_de0_nano_soc/rtl/verilog/arvern_fpga.v
# Both boards build the classic persona (a command FIFO of 8 words, the RTL
# default) and use the synchronous reset
# (ASYNC_RST_EN = 0).
_TANG     = dict(_CLASSIC, VRAM_WORDS=69632, DIM_W=10, VRAM_RD_REG_EN=0,
                 DPI_LB_AW=10, DPI_SCALER=2, DPI_PCLK_SEP=1,
                 PRIV_CHECK_EN=0, ASYNC_RST_EN=0)

DEPLOYED = [
    ("tang_hdmi",      dict(_TANG, DIF_TYPE=5, DPI_AUDIO_EN=1)),
    ("tang_panel",     dict(_TANG, DIF_TYPE=4, DPI_AUDIO_EN=0)),
    ("de0",            dict(_CLASSIC, VRAM_WORDS=40960, DIM_W=10, VRAM_RD_REG_EN=0, DIF_TYPE=2,
                            PRIV_CHECK_EN=0, ASYNC_RST_EN=0)),
]

CONFIGS = CONFIGS + DEPLOYED

# DPI and HDMI crossed with what the configs above give only the 8080 driver:
# the richer GPUs (run-ahead and blending raise
# the VRAM pressure against the urgent refresh of the DPI driver), no LUT, one
# and four frame pointers, the smallest and largest VRAM. Each runs the tests
# of sim_configs.SHARED_TEST_LISTS, not every applicable one.
_PERF     = dict(dict(PERSONAS)["performance"])
CONFIGS = CONFIGS + [
    ("dif5_ultra_rdreg", dict(_ULTRA, DIF_TYPE=5, DPI_PCLK_SEP=1, DPI_SCALER=2, DPI_AUDIO_EN=1,
                              VRAM_RD_REG_EN=1)),                   # HDMI with audio, ultra GPU, registered reads
    ("dif4_perf",      dict(_PERF, DIF_TYPE=4, DPI_PCLK_SEP=1)),    # RGB panel on its pixel clock, performance GPU
    ("dif4_lut0",      {"DIF_TYPE": 4, "LUT_EN": 0}),               # DPI without the LUT
    ("dif4_frame1",    {"DIF_TYPE": 4, "FRAME_NR": 1}),             # DPI with one frame pointer
    ("dif5_frame4",    {"DIF_TYPE": 5, "FRAME_NR": 4, "DPI_PCLK_SEP": 1}),  # HDMI with every frame pointer
    ("dif4_vram_small", {"DIF_TYPE": 4, "VRAM_WORDS": 1000}),       # DPI with a 1000-word VRAM
    ("dif5_vram_max",  {"DIF_TYPE": 5, "VRAM_WORDS": 16777216, "DPI_PCLK_SEP": 1}),  # HDMI at the widest VRAM address
]

# Design-review additions (2026-11-04), appended
CONFIGS = CONFIGS + [
    ("classic_ra_nox", {"GPU_RUNAHEAD_EN": 1, "GPU_REMAP_EN": 0, "GPU_MPLANE_EN": 0,
                        "GPU_IMM_EN": 0}),                          # Run-ahead without remap, mask plane and immediate source
]

# Lines and the hardware cursor (2026-11-07), appended
CONFIGS = CONFIGS + [
    ("gpunoline",      {"GPU_LINE_EN": 0}),                         # Classic without lines (EXEC_FILL LINE refused)
    ("cursor0",        {"CURSOR_EN": 0}),                           # Classic without the cursor (the backend slot untagged)
    ("light_cursor",   dict(dict(PERSONAS)["light"], CURSOR_EN=1)), # The cursor without a GPU, one LUT bank
]

# Per-pixel alpha and bilinear sampling (2026-11-10), appended. Bilinear
# (GPU_BILINEAR_EN) is in performance and ultra (ultra_rdlat3 covers the tap
# cache's misses at a three-cycle macro); classic with it (no blending:
# opaque taps); blending without the mask plane (the alpha plane's word
# holder built for blending alone); bilinear requested without x/y (absent)
CONFIGS = CONFIGS + [
    ("classic_bil",     dict(_CLASSIC, GPU_BILINEAR_EN=1)),         # Classic + bilinear (opaque only: no blending)
    ("blend_nomplane",  {"GPU_BLEND_EN": 1, "GPU_MPLANE_EN": 0}),   # Blending without the mask plane (A8 holder alone)
    ("bil_noxy",        {"GPU_XY_EN": 0, "GPU_BILINEAR_EN": 1}),    # Bilinear requested without x/y: absent
]

# AREA_STEPS: synthesis only (run_syn -rtl_config <label>), not linted nor
# simulated: the area ladder of doc/synthesis_guide.md, without a display
# driver (DIF_TYPE 0, the display driver costs are a table of their own,
# against dif0): light to ultra, one feature added at each step (dif0, the
# cursor added to imm_bdi, is the classic step; the command FIFO grows to 16
# words before performance, to 32 at ultra). Indices follow CONFIGS.
_BARE     = dict(_CLASSIC, GPU_XY_EN=0, GPU_GRAD_EN=0, GPU_REMAP_EN=0, GPU_MPLANE_EN=0, GPU_IMM_EN=0,
                 GPU_LINE_EN=0, CURSOR_EN=0)
_BY_LABEL = dict(CONFIGS)
AREA_STEPS = [(label, dict(ov, DIF_TYPE=0)) for label, ov in [
    ("light_bdi",       _BY_LABEL["light"]),                        # light
    ("lut2_bdi",        dict(_DISPLAY, CURSOR_EN=0, **_GPU_OFF)),   # + second LUT bank
    ("gpu_bdi",         _BARE),                                     # + GPU, every feature off
    ("xy_bdi",          dict(_BARE, GPU_XY_EN=1)),                  # + x/y, clip and affine
    ("grad_bdi",        dict(_BARE, GPU_XY_EN=1, GPU_GRAD_EN=1)),   # + gradient
    ("line_bdi",        dict(_BARE, GPU_XY_EN=1, GPU_GRAD_EN=1, GPU_LINE_EN=1)),                      # + lines and dashes
    ("remap_bdi",       dict(_BARE, GPU_XY_EN=1, GPU_GRAD_EN=1, GPU_LINE_EN=1, GPU_REMAP_EN=1)),      # + palette remap
    ("mplane_bdi",      dict(_BARE, GPU_XY_EN=1, GPU_GRAD_EN=1, GPU_LINE_EN=1, GPU_REMAP_EN=1,
                             GPU_MPLANE_EN=1)),                                                       # + mask plane
    ("imm_bdi",         dict(_CLASSIC, CURSOR_EN=0)),               # + immediate source (dif0 adds the cursor: classic)
    ("blend_bdi",       dict(_CLASSIC, GPU_BLEND_EN=1)),            # classic (dif0) + blending
    ("fifo16_bdi",      dict(_CLASSIC, GPU_BLEND_EN=1, GPU_FIFO_AW=4)),  # + command FIFO of 16 words
    ("runahead_bdi",    dict(_BY_LABEL["performance"], GPU_BILINEAR_EN=0)),   # + run-ahead
    ("performance_bdi", _BY_LABEL["performance"]),                  # + bilinear sampling
    ("tri_bdi",         dict(_BY_LABEL["performance"], GPU_TRI_EN=1)),   # + triangles
    ("ultra_bdi",       _BY_LABEL["ultra"]),                        # + command FIFO of 32 words
    ("classic_bil_bdi", dict(_CLASSIC, GPU_BILINEAR_EN=1)),         # classic (dif0) + bilinear: its cost without blending
]] + [
    ("hdmi_pclk",       {"DIF_TYPE": 5, "DPI_PCLK_SEP": 1}),         # display drivers: HDMI on its pixel clock (dif5_audio less the audio)
]

TOP_MODULE = "belenos"
