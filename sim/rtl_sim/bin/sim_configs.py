#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    sim_configs.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# The simulation-only configs and the functional-coverage bins.
#
# The configs every flow shares (lint, VC Static, synthesis, simulation) are
# in rtl_configs.py; run_config.json holds the parameters, their default build
# and the tests with their `requires`. The sim_* configs below add what only
# simulation needs: the bench clock gate (ICG_EN), and the reset style, display
# driver and feature crosses. Each entry is
# (label, overrides of the default build, test list); a listed test still runs
# only where its `requires` holds. bin/test_config.py numbers them after the
# shared configs.
#----------------------------------------------------------------------------

import rtl_configs
from rtl_configs import PERSONAS, DEPLOYED

SMOKE = ["smoke_regs", "smoke_vram_window", "smoke_lut", "smoke_gpu",
         "smoke_refresh_8080"]
REGS  = ["regs_global", "regs_port", "regs_irq", "regs_refresh", "regs_refresh_dbi", "regs_frame_num",
         "regs_vram", "regs_vram_contention", "regs_vram_prefetch", "regs_vram_timing", "regs_vram_order",
         "regs_lut", "regs_hclk_en", "regs_hclk_en_held",
         "regs_irq_icg"]
GPU   = ["gpu_rstream", "gpu_fill_ops", "gpu_copy_ops", "gpu_swaps", "gpu_surfaces", "gpu_irq", "gpu_err",
         "gpu_fifo", "gpu_fifo_race", "gpu_abort", "gpu_freeze", "gpu_freeze_abort",
         "gpu_perf", "gpu_extremes", "gpu_random", "gpu_contention", "gpu_absent", "gpu_span",
         "gpu_expand", "gpu_texspan", "gpu_newkind_stress", "gpu_call", "gpu_win_starve",
         "gpu_xyclip", "gpu_texrect", "gpu_grad", "gpu_blend", "gpu_tri", "gpu_nofx_err",
         "gpu_api", "gpu_trim", "gpu_overlap", "gpu_slot_freeze", "gpu_tritex", "gpu_flush_sync",
         "gpu_ext2", "gpu_wcopy", "gpu_mplane", "gpu_remap", "gpu_imm", "gpu_sync",
         "gpu_line_basic", "gpu_line_clip", "gpu_line_dash", "gpu_line_aa", "gpu_line_err",
         "gpu_line_flush", "gpu_line_list"]
BK    = ["bk_hwcol", "bk_lut", "bk_scan", "bk_pitch", "bk_frames", "bk_latch", "bk_latch_lead0",
         "bk_stream", "bk_nobubble", "bk_contention", "bk_dbi", "bk_lut_rot", "bk_pix_double",
         "bk_pix_double_stress", "bk_cursor_basic", "bk_cursor_orient", "bk_cursor_latch", "bk_cursor_bw"]
DBI   = ["dbi_regs", "dbi_cmd", "dbi_fifo", "dbi_dfill", "dbi_refresh", "dbi_refresh_queued",
         "dbi_prio", "dbi_scan", "dbi_te", "dbi_irq", "dbi_phy_sel", "dbi_size_race", "dbi_size_queued",
         "dbi_cmd_refresh", "dbi_rd_timing", "dbi_op_cfg"]
DPI   = ["dpi_regs", "dpi_frame", "dpi_scale", "dpi_events", "dpi_underflow", "dpi_preset", "dpi_ddc", "dpi_hdmi",
         "dpi_wide", "regs_lut_dpi", "dpi_hdmi_update", "dpi_status", "dpi_pclk_stop", "dpi_reset", "dpi_reg_walk"]
ALL   = SMOKE + ["smoke_refresh_spi"] + REGS + GPU + DBI + BK + DPI

# Round-1 features (x/y + clip and affine blit, gradient) and the tests that
# exercise them; FX = blending and triangles on (the ultra feature set)
GPU_FEAT = ["gpu_xyclip", "gpu_texrect", "gpu_grad", "gpu_random", "gpu_call", "gpu_texspan",
            "gpu_newkind_stress", "gpu_nofx_err", "gpu_api", "gpu_trim"]
FX = {"GPU_BLEND_EN": 1, "GPU_TRI_EN": 1}
ULTRA = dict(PERSONAS)["ultra"]

SIM_ONLY_CONFIGS = [
    # label                overrides of the default build                    tests
    ("sim_icg",            {"ICG_EN": 1},                                     ALL),
    ("sim_sync_rst",       {"ASYNC_RST_EN": 0},                               ALL),
    ("sim_icg_sync_rst",   {"ICG_EN": 1, "ASYNC_RST_EN": 0},                  SMOKE + REGS + DBI),
    ("sim_ultra_sync_rst", dict(ULTRA, ASYNC_RST_EN=0),                       ["smoke_gpu"] + GPU),
    ("sim_ultra_nora",     dict(ULTRA, GPU_RUNAHEAD_EN=0),                    ["smoke_gpu", "regs_global", "regs_irq"] + GPU),
    # External display driver (BDI exported): backend tests observe the stream directly
    ("sim_dif0",           {"DIF_TYPE": 0},                                   ["smoke_regs", "smoke_vram_window"] + REGS + BK),
    ("sim_dif0_sync_rst",  {"DIF_TYPE": 0, "ASYNC_RST_EN": 0},                REGS + BK),
    ("sim_dif0_icg",       {"DIF_TYPE": 0, "ICG_EN": 1},                      ["regs_irq", "regs_irq_icg", "regs_hclk_en", "bk_latch", "bk_latch_lead0", "bk_stream", "gpu_ext2",
                                                                              "bk_cursor_latch", "bk_cursor_bw"]),
    ("sim_dif0_frame1",    {"DIF_TYPE": 0, "FRAME_NR": 1},                    ["bk_frames", "bk_latch", "regs_global"]),
    ("sim_dif0_frame4",    {"DIF_TYPE": 0, "FRAME_NR": 4},                    ["bk_frames", "regs_global", "regs_frame_num"]),
    ("sim_dif0_lut0",      {"DIF_TYPE": 0, "LUT_EN": 0},                      ["bk_lut", "bk_lut_rot", "bk_nobubble", "bk_pix_double_stress", "regs_lut", "regs_global", "regs_vram_contention",
                                                                              "bk_cursor_basic", "bk_cursor_orient", "bk_cursor_bw"]),
    ("sim_dif0_lut1bank",  {"DIF_TYPE": 0, "LUT_BANKS": 1},                   ["bk_lut", "bk_lut_rot", "bk_contention", "bk_pix_double_stress", "regs_lut"]),
    ("sim_dif0_nogpu",     {"DIF_TYPE": 0, "GPU_EN": 0},                      ["bk_contention", "bk_pix_double_stress", "regs_global", "regs_port", "bk_cursor_bw"]),
    # SPI and dual-PHY display drivers
    ("sim_dif1",           {"DIF_TYPE": 1},                                   ["smoke_regs", "smoke_refresh_spi", "regs_refresh_dbi", "bk_dbi", "bk_pix_double"] + DBI),
    ("sim_dif1_sync_rst",  {"DIF_TYPE": 1, "ASYNC_RST_EN": 0},                DBI),
    ("sim_dif3",           {"DIF_TYPE": 3},                                   ["smoke_regs", "smoke_refresh_8080", "smoke_refresh_spi", "regs_refresh_dbi", "bk_dbi"] + DBI),
    ("sim_dif3_sync_rst",  {"DIF_TYPE": 3, "ASYNC_RST_EN": 0},                DBI),
    ("sim_dif3_lut0",      {"DIF_TYPE": 3, "LUT_EN": 0},                      ["bk_dbi"]),
    # DPI display driver: each scaler, its own pixel clock (faster, slower,
    # nearly equal to hclk is set by the tests), line-buffer sizes, sync reset
    ("sim_dif4",           {"DIF_TYPE": 4},                                   ["smoke_regs", "smoke_vram_window", "regs_global", "regs_port", "regs_irq", "regs_hclk_en", "bk_pix_double", "gpu_ext2"] + DPI),
    ("sim_dif4_bilinear",  {"DIF_TYPE": 4, "DPI_SCALER": 2},                  DPI),
    ("sim_dif4_noscale",   {"DIF_TYPE": 4, "DPI_SCALER": 0},                  DPI),
    ("sim_dif4_pclk",      {"DIF_TYPE": 4, "DPI_PCLK_SEP": 1},                DPI),
    ("sim_dif4_pclk_bil",  {"DIF_TYPE": 4, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2, "DPI_LB_AW": 12}, DPI),
    ("sim_dif4_lb9",       {"DIF_TYPE": 4, "DPI_LB_AW": 9},                   DPI),
    ("sim_dif4_sync_rst",  {"DIF_TYPE": 4, "ASYNC_RST_EN": 0, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2}, DPI),
    ("sim_dif4_icg",       {"DIF_TYPE": 4, "ICG_EN": 1},                      ["regs_hclk_en", "regs_irq_icg", "dpi_irq_icg"] + DPI),
    # HDMI: the DPI driver with the TMDS encoder (the bench decodes every symbol)
    ("sim_dif5",           {"DIF_TYPE": 5},                                   ["smoke_regs", "regs_global", "regs_hclk_en", "bk_pix_double", "gpu_ext2"] + DPI + ["dpi_audio"]),
    ("sim_dif5_pclk_bil",  {"DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2, "DPI_LB_AW": 12}, DPI + ["dpi_audio"]),
    ("sim_dif5_sync_rst",  {"DIF_TYPE": 5, "ASYNC_RST_EN": 0, "DPI_PCLK_SEP": 1}, DPI),
    ("sim_dif5_noddc",     {"DIF_TYPE": 5, "DPI_DDC_EN": 0, "DPI_ISLAND_EN": 0}, ["dpi_regs", "dpi_ddc", "dpi_hdmi", "dpi_audio", "dpi_frame"]),
    ("sim_dif5_audio",     {"DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_AUDIO_EN": 1}, DPI + ["dpi_audio", "dpi_audio_edge", "dpi_audio_pkt", "dpi_audio_rand"]),
    ("sim_dif5_audio_1clk", {"DIF_TYPE": 5, "DPI_AUDIO_EN": 1},                ["dpi_regs", "dpi_hdmi", "dpi_audio", "dpi_audio_edge", "dpi_audio_pkt", "dpi_audio_rand", "dpi_frame"]),
    # HD line widths (DIM_W and DPI_LB_AW 11): one clock, and the Tang HDMI set-up
    ("sim_dif4_wide",      {"DIF_TYPE": 4, "DIM_W": 11, "DPI_LB_AW": 11},     DPI),
    ("sim_dif5_wide",      {"DIF_TYPE": 5, "DIM_W": 11, "DPI_LB_AW": 11, "DPI_PCLK_SEP": 1, "DPI_SCALER": 2,
                            "DPI_AUDIO_EN": 1},                               DPI + ["dpi_audio"]),
    ("sim_dif5_audio_srst", {"DIF_TYPE": 5, "DPI_AUDIO_EN": 1, "ASYNC_RST_EN": 0, "DPI_PCLK_SEP": 1}, ["dpi_hdmi", "dpi_audio", "dpi_audio_edge", "dpi_audio_pkt", "dpi_audio_rand"]),
    # Reduced and sized builds
    ("sim_minimal",        {"LUT_EN": 0, "GPU_EN": 0, "FRAME_NR": 1,
                            "VRAM_WORDS": 1000},                               SMOKE + ["regs_global", "regs_port", "gpu_absent"]),
    ("sim_lut1bank",       {"LUT_BANKS": 1},                                  ["smoke_regs", "smoke_lut", "regs_lut"]),
    ("sim_gpu0",           {"GPU_EN": 0},                                     ["gpu_absent", "regs_global", "bk_pix_double"]),
    ("sim_gpu_noxy",       {"GPU_XY_EN": 0},                                  ["smoke_gpu", "regs_global", "gpu_err", "gpu_fill_ops"] + GPU_FEAT),
    ("sim_gpu_nograd",     {"GPU_GRAD_EN": 0},                                ["smoke_gpu", "regs_global", "gpu_err"] + GPU_FEAT),
    ("sim_gpu_bare",       {"GPU_XY_EN": 0, "GPU_GRAD_EN": 0, "GPU_REMAP_EN": 0, "GPU_MPLANE_EN": 0,
                            "GPU_IMM_EN": 0},
                                                                              ["smoke_gpu", "regs_global", "gpu_err", "gpu_fill_ops", "gpu_copy_ops", "gpu_swaps", "gpu_expand"] + GPU_FEAT),
    ("sim_priv1",          {"PRIV_CHECK_EN": 1},                              ["smoke_regs", "smoke_vram_window", "regs_port", "regs_vram"]),
    ("sim_vram_small",     dict({"VRAM_WORDS": 1000}, **FX),                  SMOKE + ["regs_global", "regs_vram", "gpu_span", "gpu_expand", "gpu_texspan", "gpu_newkind_stress", "gpu_call", "gpu_xyclip", "gpu_texrect", "gpu_grad", "gpu_blend", "gpu_api"]),
    ("sim_vram_64k",       dict({"VRAM_WORDS": 65536}, **FX),                 ["gpu_span", "gpu_expand", "gpu_call", "gpu_tri", "gpu_a8_err"]),
    ("sim_dim4",           dict({"DIM_W": 4}, **FX),                          ["gpu_surfaces", "gpu_extremes", "regs_global", "gpu_span", "gpu_expand", "gpu_texspan", "bk_pix_double", "gpu_newkind_stress", "gpu_call", "gpu_xyclip", "gpu_texrect", "gpu_grad", "gpu_blend", "gpu_tri"]),
    ("sim_dim6",           dict({"DIM_W": 6}, **FX),                          ["gpu_surfaces", "gpu_extremes", "gpu_random", "gpu_span", "gpu_expand", "gpu_texspan", "gpu_newkind_stress", "gpu_call", "gpu_xyclip", "gpu_texrect", "gpu_grad", "gpu_blend", "gpu_tri"]),
    ("sim_dim16",          dict({"DIM_W": 16}, **FX),                         SMOKE + ["regs_global", "gpu_span", "gpu_expand", "gpu_texspan", "gpu_newkind_stress", "gpu_call", "gpu_xyclip", "gpu_texrect", "gpu_grad", "gpu_blend", "gpu_tri",
                                                                              "gpu_ext_tex", "gpu_ext_grad"]),
    # Registered VRAM read data, also with the BDI exported
    ("sim_rdreg",          {"VRAM_RD_REG_EN": 1},                             ALL),
    ("sim_dif0_rdreg",     {"VRAM_RD_REG_EN": 1, "DIF_TYPE": 0},              ["smoke_regs", "smoke_vram_window"] + REGS + BK),
    # Three-cycle VRAM macro: its read data not held between reads, with the
    # data register and the BDI exported (longest latency), with HDMI
    ("sim_rdlat3_poison",  {"VRAM_RD_LAT": 3, "VRAM_POISON": 1},              ALL),
    ("sim_dif0_rdlat3_rdreg", {"VRAM_RD_LAT": 3, "VRAM_RD_REG_EN": 1, "DIF_TYPE": 0}, ["smoke_regs", "smoke_vram_window"] + REGS + BK),
    # ... without the LUT: the pixel FIFO (RD_LAT + 4 = 8 entries) popped by the
    # driver itself, filled to its depth under back-pressure
    ("sim_dif0_lut0_rdlat3_rdreg", {"VRAM_RD_LAT": 3, "VRAM_RD_REG_EN": 1, "DIF_TYPE": 0, "LUT_EN": 0}, ["bk_stream", "bk_nobubble"]),
    ("sim_dif5_rdlat3",    {"VRAM_RD_LAT": 3, "DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_AUDIO_EN": 1}, DPI + ["dpi_audio", "bk_pix_double"]),
    # Both DBI PHYs at the widest width/height fields
    ("sim_dif3_dim16",     {"DIF_TYPE": 3, "DIM_W": 16},                      ["smoke_regs", "dbi_wide", "dbi_dfill", "dbi_refresh", "dbi_cmd"]),
]

# Clock-crossing sweep: the separate pixel clock at
# pclk/hclk 0.3, 1, 2.2 and 4.5 (PCLK_HALF in 100 ps, HCLK 10 ns; 49 rather
# than 50 so the two clocks drift instead of sharing every edge), with the
# arv_synchronizer jitter model (SYNC_JITTER), on the DPI and HDMI-audio builds
PCLK_RATIOS = [("r03", 167), ("r1", 49), ("r22", 23), ("r45", 11)]
for _r, _half in PCLK_RATIOS:
    SIM_ONLY_CONFIGS.append((f"sim_dif4_pclk_{_r}",
                             {"DIF_TYPE": 4, "DPI_PCLK_SEP": 1, "PCLK_HALF": _half, "SYNC_JITTER": 1}, DPI))
for _r, _half in PCLK_RATIOS:
    SIM_ONLY_CONFIGS.append((f"sim_dif5_audio_{_r}",
                             {"DIF_TYPE": 5, "DPI_PCLK_SEP": 1, "DPI_AUDIO_EN": 1, "PCLK_HALF": _half,
                              "SYNC_JITTER": 1}, DPI + ["dpi_audio", "dpi_audio_edge", "dpi_audio_pkt", "dpi_audio_rand"]))

# The VRAM macro's read data valid in its data cycle only (VRAM_POISON: random
# data in every other cycle) at the one- and two-cycle latencies, also with
# the BDI exported; the register-port U-mode checks with the BDI window
# exported (DIF_TYPE 0 and PRIV_CHECK_EN 1)
SIM_ONLY_CONFIGS += [
    ("sim_poison",         {"VRAM_POISON": 1},                                ALL),
    ("sim_rdlat2_poison",  {"VRAM_RD_LAT": 2, "VRAM_POISON": 1},              ALL),
    ("sim_dif0_poison",    {"DIF_TYPE": 0, "VRAM_POISON": 1},                 ["smoke_regs", "smoke_vram_window"] + REGS + BK),
    ("sim_dif0_priv1",     {"DIF_TYPE": 0, "PRIV_CHECK_EN": 1},               ["smoke_regs", "smoke_vram_window", "regs_port", "regs_vram"]),
    # Largest geometry and top of the largest VRAM, refreshed on the BDI stream
    ("sim_dif0_dim16",     {"DIF_TYPE": 0, "DIM_W": 16},                      ["regs_global", "bk_wide", "bk_scan", "bk_cursor_orient", "regs_cursor"]),
    ("sim_dif0_vram_max",  {"DIF_TYPE": 0, "VRAM_WORDS": 16777216},           ["bk_wide", "bk_hilo"]),
]

# Bench-infrastructure crosses
#  - the clock gate (ICG_EN) with the longer read latencies and the data
#    register, run-ahead, blending and triangles, the SPI and dual-PHY drivers,
#    HDMI with audio on its own pixel clock (the Tang HDMI build, gated);
#  - the VRAM and LUT macros on the free-running clock (MACRO_FREECLK), also at
#    the three-cycle latency with the data register and poisoned read data;
#  - synchroniser jitter on the deployed Tang builds (HDMI with audio, and the
#    RGB panel with the bilinear scaler, both with the synchronous reset) at the
#    four clock ratios, and on the DBI synchronisers (TE, scan line), also with
#    the synchronous reset.
_TANG_HDMI  = dict(DEPLOYED)["tang_hdmi"]
_TANG_PANEL = dict(DEPLOYED)["tang_panel"]
_GPU_VRAM   = ["smoke_gpu", "gpu_random", "gpu_rstream", "gpu_contention", "gpu_blend", "gpu_tri", "gpu_tritex",
               "gpu_texspan", "gpu_win_starve"]
_DBI_PHY    = ["smoke_regs", "smoke_refresh_8080", "smoke_refresh_spi", "regs_hclk_en",
               "regs_refresh_dbi", "bk_dbi"]
SIM_ONLY_CONFIGS += [
    ("sim_icg_rdlat2",     {"ICG_EN": 1, "VRAM_RD_LAT": 2},                   SMOKE + REGS + ["gpu_random", "gpu_contention", "gpu_fill_ops", "gpu_copy_ops", "gpu_call", "dbi_refresh", "bk_dbi"]),
    ("sim_icg_ultra_rdlat3_rdreg", dict(ULTRA, ICG_EN=1, VRAM_RD_LAT=3, VRAM_RD_REG_EN=1), ALL),
    ("sim_icg_dif0_rdlat3_rdreg", {"ICG_EN": 1, "DIF_TYPE": 0, "VRAM_RD_LAT": 3, "VRAM_RD_REG_EN": 1}, REGS + BK),
    ("sim_icg_dif1",       {"ICG_EN": 1, "DIF_TYPE": 1},                      _DBI_PHY + DBI + ["regs_irq_icg"]),
    ("sim_icg_dif3",       {"ICG_EN": 1, "DIF_TYPE": 3},                      _DBI_PHY + DBI + ["regs_irq_icg"]),
    # (dpi_ddc waits on hclk edges, which the gate stops: not in this list)
    ("sim_icg_tang_hdmi",  dict(_TANG_HDMI, ICG_EN=1),                        ["smoke_regs", "regs_global", "regs_irq", "regs_irq_icg", "dpi_irq_icg", "regs_hclk_en", "bk_pix_double", "gpu_ext2"] + DPI + ["dpi_audio", "dpi_audio_edge", "dpi_audio_pkt", "dpi_audio_rand"]),
    ("sim_icg_freeclk",    {"ICG_EN": 1, "MACRO_FREECLK": 1},                 SMOKE + REGS + _GPU_VRAM + ["dbi_refresh", "dbi_te", "bk_dbi"]),
    ("sim_icg_freeclk_ultra_rdlat3", dict(ULTRA, ICG_EN=1, MACRO_FREECLK=1, VRAM_RD_LAT=3, VRAM_RD_REG_EN=1, VRAM_POISON=1),
                                                                              SMOKE + REGS + GPU),
    ("sim_icg_freeclk_dif0_rdlat3", {"ICG_EN": 1, "MACRO_FREECLK": 1, "DIF_TYPE": 0, "VRAM_RD_LAT": 3, "VRAM_RD_REG_EN": 1},
                                                                              ["regs_refresh", "regs_hclk_en", "bk_stream", "bk_latch", "bk_frames", "bk_pix_double_stress"]),
    ("sim_icg_freeclk_tang_panel", dict(_TANG_PANEL, ICG_EN=1, MACRO_FREECLK=1), ["regs_hclk_en", "regs_lut_dpi"] + DPI),
    ("sim_dif3_jit",       {"DIF_TYPE": 3, "SYNC_JITTER": 1},                 ["smoke_refresh_8080", "smoke_refresh_spi"] + DBI),
    ("sim_dif3_srst_jit",  {"DIF_TYPE": 3, "ASYNC_RST_EN": 0, "SYNC_JITTER": 1}, ["dbi_regs", "dbi_refresh", "dbi_scan", "dbi_te", "dbi_irq"]),
]
for _r, _half in PCLK_RATIOS:
    SIM_ONLY_CONFIGS.append((f"sim_tang_hdmi_{_r}", dict(_TANG_HDMI, PCLK_HALF=_half, SYNC_JITTER=1),
                             DPI + ["dpi_audio", "dpi_audio_edge", "dpi_audio_pkt", "dpi_audio_rand", "dpi_ddc"]))
for _r, _half in PCLK_RATIOS:
    SIM_ONLY_CONFIGS.append((f"sim_tang_panel_{_r}", dict(_TANG_PANEL, PCLK_HALF=_half, SYNC_JITTER=1),
                             DPI + ["regs_hclk_en"]))
# An HD panel (1280 x 720 active) at one pixel per clock
SIM_ONLY_CONFIGS.append(("sim_dif4_hd", {"DIF_TYPE": 4, "DIM_W": 11, "DPI_LB_AW": 11}, ["dpi_hd"]))
# A power-of-two VRAM at the default DIM_W: a 1-bpp immediate source can reach
# 2^PA_W pixels (gpu_imm: ERR_CAUSE 5, no wrap)
SIM_ONLY_CONFIGS.append(("sim_vram_16k", {"VRAM_WORDS": 16384}, ["smoke_gpu", "gpu_imm"]))

# ERR_CAUSE 5 by stage F keeps the prefix (gpu_bnd_prefix, 2026-11-11): the
# default build in T1, these in T2: run-ahead, a two-cycle macro, the DPI
# refresh's contention, and a 1000-word VRAM (the immediate index crossing it)
SIM_ONLY_CONFIGS += [
    ("sim_bnd_ra",         {"GPU_RUNAHEAD_EN": 1},                            ["gpu_bnd_prefix"]),
    ("sim_bnd_rdlat2",     {"VRAM_RD_LAT": 2},                                ["gpu_bnd_prefix"]),
    ("sim_bnd_dif4",       {"DIF_TYPE": 4},                                   ["gpu_bnd_prefix"]),
    ("sim_bnd_small",      {"VRAM_WORDS": 1000},                              ["gpu_bnd_prefix"]),
]

# Simulation-only configs that also run in T2 (./run_all -tier T2, with the
# personas and the deployed builds): the Tang HDMI build gated, and under
# jitter at pclk/hclk 2.2
RELEASE_EXTRA = ["sim_icg_tang_hdmi", "sim_tang_hdmi_r22",
                 "classic_bil",                         # bilinear without blending (its GPU list below)
                 "sim_bnd_ra", "sim_bnd_rdlat2", "sim_bnd_dif4", "sim_bnd_small"]

# The random command stream with several seeds in one run (T2, and T3 with
# them): the key personas, the bare GPU and the shipped Tang HDMI build
RS_T2_SEEDS = 4
for _l in ("classic", "performance", "ultra", "essential", "tang_hdmi", "classic_bil"):
    SIM_ONLY_CONFIGS.append((f"sim_rs_{_l}", dict(dict(rtl_configs.CONFIGS)[_l], GPU_RS_SEEDS=RS_T2_SEEDS), ["gpu_rstream"]))
    RELEASE_EXTRA.append(f"sim_rs_{_l}")

# Shared configs that run a list of tests instead of every applicable one:
# vram_max's 16 M-word VRAM model makes the tests that compare the whole VRAM
# against the model run for tens of minutes each
# frame1 / frame4 / lut1bank / priv1 change one register-map feature: the
# tests that use it (found by grepping the stimuli for the feature's registers
# and parameter) instead of every test (about 230 runs fewer).
_FRAME_TESTS = ["smoke_regs", "smoke_refresh_8080", "regs_global", "regs_port",
                "regs_vram_contention", "bk_contention", "bk_latch", "bk_latch_lead0", "bk_frames",
                "bk_scan", "bk_pix_double", "dbi_refresh", "dbi_refresh_queued", "dbi_size_queued",
                "dbi_size_race", "gpu_surfaces", "gpu_win_starve", "regs_frame_num"]
_LUT_TESTS   = ["smoke_regs", "smoke_lut", "regs_global", "regs_port", "regs_lut", "bk_contention",
                "bk_latch", "bk_latch_lead0", "bk_pix_double", "bk_pix_double_stress", "bk_frames",
                "bk_lut", "bk_lut_rot", "bk_scan", "dbi_refresh", "dbi_size_race"]
_PRIV_TESTS  = ["smoke_regs", "smoke_vram_window", "regs_global", "regs_port", "regs_vram",
                "smoke_gpu", "gpu_api"]

_ALPHA_BIL   = ["gpu_mix5", "gpu_a8_copy", "gpu_a8_tex", "gpu_a8_err", "gpu_bil_basic", "gpu_bil_edges",
                "gpu_bil_mixd", "gpu_bil_cache", "gpu_bil_err", "gpu_blend_x", "gpu_retain", "gpu_causes"]

SHARED_TEST_LISTS = {
    "frame1":   _FRAME_TESTS,
    "frame4":   _FRAME_TESTS,
    "lut1bank": _LUT_TESTS,
    "priv1":    _PRIV_TESTS,
    "vram_max": SMOKE + ["regs_global", "regs_hclk_en", "regs_hclk_en_held", "regs_lut",
                         "regs_port", "regs_refresh_dbi", "regs_vram", "regs_vram_contention",
                         "gpu_api", "gpu_err", "gpu_fifo", "gpu_fifo_race",
                         "gpu_extremes", "gpu_flush_sync", "gpu_freeze", "gpu_abort",
                         "gpu_contention", "gpu_irq", "gpu_freeze_abort", "gpu_nofx_err",
                         "gpu_perf", "gpu_expand", "gpu_highmem", "gpu_ext_hilo",
                         "gpu_ext_list", "gpu_ext_tex"],
    # The DPI crosses appended to rtl_configs.py
    "dif5_ultra_rdreg": DPI + ["dpi_audio", "bk_pix_double"] + _GPU_VRAM,
    "dif4_perf":        DPI + _GPU_VRAM,
    "dif4_lut0":        DPI + ["regs_global", "regs_lut"],
    "dif4_frame1":      DPI + ["regs_global", "regs_frame_num", "bk_pix_double"],
    "dif5_frame4":      DPI + ["regs_global", "regs_frame_num"],
    "dif4_vram_small":  DPI + ["smoke_regs", "regs_global"],
    "dif5_vram_max":    ["smoke_regs", "dpi_regs", "dpi_frame", "regs_lut_dpi"],
    # Bilinear builds (2026-11-10): the GPU tests, the alpha and bilinear ones
    "classic_bil":      ["smoke_gpu"] + GPU + _ALPHA_BIL,
}

TB_TOP = "tb_belenos"

# Functional-coverage gate (bench/verilog/cover_monitor.v). Each run emits
# "COVERAGE HIT: <bin>" lines; run_sweep.py unions them across every
# (config, test) run and fails the sweep if a bin below was never hit.
MANDATORY_COVER_BINS = [
    # Register port: zero-wait OKAY, wait-stated transfer, two-cycle ERROR
    "r_okay", "r_wait_state", "r_hresp_err",
    # VRAM window: every access size, wait states, ERROR
    "v_byte", "v_half", "v_word", "v_wait_state", "v_hresp_err",
    # VRAM window: a read served by the read-ahead buffer; a write posted, and a
    # register-port transfer held behind it
    "v_pf_hit", "v_wb_post", "r_vw_hold",
    # VRAM macro written and read
    "vram_write", "vram_read",
    # LUT macro written and read
    "lut_write", "lut_read",
    # Display interfaces: a pixel reached each panel model
    "dbi_8080_pixel", "dbi_spi_pixel",
    # Clock request both ways
    "hclk_en_hi", "hclk_en_lo",
    # GPU with the registered VRAM read data: the next source word read ahead,
    # an entry dropped by a merge into its word
    "gpu_nw_rd", "gpu_ra_kill",
    # SET_EXT2 and the RGB gradient: a WAIT_REFR_DONE released by a frame end
    # and one ended by a flush, RESET_STATE, an RGB channel saturated
    "gpu_wait_rel", "gpu_wait_flush", "gpu_rst_state", "gpu_grgb_sat",
    # Lines: each octant walked, a Bresenham tie, the early exit, the box test,
    # the pattern phase wrapping
    *[f"gpu_line_oct{o}" for o in range(8)], "gpu_line_tie", "gpu_line_exit", "gpu_line_reject",
    "gpu_line_wrap",
    # VRAM arbiter: the GPU's starvation bound taken, an urgent refresh granted
    # over a waiting window
    "arb_gpu_first", "arb_bk_urgent",
    # DPI and HDMI: a frame on the RGB panel model, an underflow event; video
    # lines with and without the HDMI preamble, the AVI InfoFrame, audio clock
    # regeneration, audio samples, the audio InfoFrame, a two-packet island
    "dpi_frame", "dpi_underflow", "hdmi_vline", "dvi_vline", "hdmi_avi", "hdmi_acr",
    "hdmi_asp", "hdmi_aif", "hdmi_island2",
    # Hardware cursor: a cursor word returned, one with CL swap, the walk held
    # for a cursor line, a cursor read granted urgent
    "cur_ret", "cur_cl", "cur_wait", "cur_urgent",
    # RGB565A8: an A8 pixel's factor 0 / 256 / between, the A8 read-ahead entry
    # hit, the holder refilled; bilinear: 1, 2 or 4 taps a pixel (the drops are separable: never 3), the drops (weight,
    # box), each tap-cache entry hit and missed, an A8 companion straddle, an
    # entry dropped by a W write, alpha256 0 / 256 / between
    "gpu_a8_m0", "gpu_a8_m32", "gpu_a8_mid", "gpu_a8_rahit", "gpu_a8_refill",
    "gpu_bil_tap1", "gpu_bil_tap2", "gpu_bil_tap4", *[f"gpu_bil_hit{e}" for e in range(4)],
    *[f"gpu_bil_miss{e}" for e in range(4)], "gpu_bil_dropw", "gpu_bil_dropb", "gpu_bil_straddle",
    "gpu_bil_wdrop", "gpu_bil_a0", "gpu_bil_a256", "gpu_bil_amid",
]

# The random command stream (gpu_rstream, its own rs_* bins): every EXEC kind
# at every depth and with each feature it can take, the four flushes landing on
# FILL / COPY / COPY_TRANSP / EXPAND in flight or an idle engine, every
# ERR_CAUSE in the FIFO (1-3 in a list too, 4 in a list only), the cut
# commands, and the injections. RS_T1_BINS are reached by every seed of the
# default, ultra and Tang HDMI builds; the others need the sweep's union.
_RS_FEAT = {"fill": "clip remap blend grad list xy", "copy": "clip remap mask blend imm list xy",
            "copyt": "clip remap mask blend imm list xy", "span": "clip blend grad list xy",
            "expand": "clip remap blend imm list xy", "texspan": "clip remap blend list xy",
            "texrect": "clip remap blend list xy", "tri": "remap blend grad list xy",
            "tritex": "remap blend list xy", "line": "clip remap blend list xy",
            "lineaa": "clip blend list xy"}
RS_T1_BINS = ["rs_flush_mid", "rs_opnd_discarded", "rs_cut_queued", "rs_drop", "rs_list_flushed",
              "rs_abort_in_err", "rs_freeze", "rs_freeze_flush", "rs_bare_exec", "rs_fence_auto",
              "rs_fence_irq", "rs_reset_state", "rs_wait_flush", "rs_cut_op2",
              "rs_dc_nop", "rs_dc_opnd", "rs_dc_flush", "rs_dc_pend", "rs_flow_wr"]
RS_COVER_BINS = (RS_T1_BINS +
                 [f"rs_{k}_d{d}" for k in _RS_FEAT for d in (1, 2, 4, 8, 16) if k != "lineaa" or d == 16] +
                 [f"rs_{k}_{f}" for k, fl in _RS_FEAT.items() for f in fl.split()] +
                 [f"rs_fl_{f}_{k}" for f in ("clrerr", "abort", "gpuen", "clrabort")
                  for k in ("fill", "copy", "copyt", "expand", "idle")] +
                 [f"rs_err_c{c}_{x}" for c in (1, 2, 3) for x in ("fifo", "list")] +
                 ["rs_err_c4_list", "rs_err_c5_fifo", "rs_err_c6_fifo"] +
                 [f"rs_cut_op{o}" for o in (1, 4, 5, 6, 7)] +
                 ["rs_drop_misread", "rs_imm_flush", "rs_data_dropped"] +
                 [f"rs_fl_{f}_line" for f in ("clrerr", "abort", "gpuen")] +
                 ["rs_line_dash", "rs_line_phrst", "rs_err_c2_line", "rs_err_c4_line", "rs_cut_op8"] +
                 ["rs_dc_data", "rs_dc_arm", "rs_dc_err", "rs_dc_skip"] +
                 ["rs_a8_copy", "rs_a8_tex", "rs_mix5", "rs_err_c2_a8", "rs_err_c1_a8_mplane", "rs_err_c1_a8_imm",
                  "rs_bil", "rs_bil_a8", "rs_bil_tborder", "rs_bil_clamp", "rs_bil_wrap", "rs_err_c2_bil",
                  "rs_fl_abort_bil", "rs_fl_clr_bil"])
MANDATORY_COVER_BINS += RS_COVER_BINS

# Bins the default build cannot reach (run_all -fast reports them as expected
# absent; run_all -rtl_sweep requires them).
SWEEP_ONLY_COVER_BINS = [
    "dbi_spi_pixel",   # needs DIF_TYPE 1 or 3 (configs dif1, dif3)
    "gpu_nw_rd",       # need a read latency of 2 or more (rdreg, ultra_rdreg, full, rdlat*, sim_rdreg, sim_dif0_rdreg, sim_rdlat3_poison)
    "gpu_ra_kill",
    "dpi_frame",       # need DIF_TYPE 4 or 5 (the dif4*/dif5* configs, tang_*)
    "dpi_underflow",
    "hdmi_vline",      # need DIF_TYPE 5 (dvi_vline: islands off, or HDMI mode off)
    "dvi_vline",
    "hdmi_avi",
    "hdmi_acr",        # need DPI_AUDIO_EN 1
    "hdmi_asp",
    "hdmi_aif",
    "hdmi_island2",
    "cur_wait",        # need the BDI stream at full rate (DIF_TYPE 0: bk_cursor_bw)
    "cur_urgent",
    # need GPU_BLEND_EN / GPU_BILINEAR_EN (ultra in T1 runs only some tests)
    "gpu_a8_m0", "gpu_a8_m32", "gpu_a8_mid", "gpu_a8_rahit", "gpu_a8_refill",
    "gpu_bil_tap1", "gpu_bil_tap2", "gpu_bil_tap4", *[f"gpu_bil_hit{e}" for e in range(4)],
    *[f"gpu_bil_miss{e}" for e in range(4)], "gpu_bil_dropw", "gpu_bil_dropb", "gpu_bil_straddle",
    "gpu_bil_wdrop", "gpu_bil_a0", "gpu_bil_a256", "gpu_bil_amid",
]
SWEEP_ONLY_COVER_BINS += [b for b in RS_COVER_BINS if b not in RS_T1_BINS]   # rs_*: feature- or seed-dependent
