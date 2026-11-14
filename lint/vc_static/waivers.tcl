#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    waivers.tcl
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : waivers.tcl
# Module Description : Scoped VC Static lint waivers for belenos.
#----------------------------------------------------------------------------
# A waiver here says "this rule is right in general, and wrong about THIS
# instance". Prefer fixing the RTL; prefer a scoped waiver over disabling the
# rule globally in rules.tcl.
#
# Every entry must carry a one-line reason. `vc_lint.tcl` runs
# `waive_hdl -not_applied` after the check and run_vclint reports the count as
# `stale=` -- a non-zero stale count means a waiver matched nothing and should
# be removed or re-scoped.
# ---------------------------------------------------------------------------
# The aRVern *_unused sink-wire convention (shared with the core, see
# arvern/lint/vc_static/waivers.tcl). A wire whose name ends in _unused exists
# precisely to document a signal that is deliberately not consumed -- an
# unloaded net is the intended state, not a finding.
#
# Scope note: waives by signal name only, so it covers every tag that can fire
# on such a net (CONN_NET_UNLOADED, CONN_INTERNAL_NET_UNLOADED,
# CONN_PORT_UNLOADED). Nothing without the suffix is waived.
# ---------------------------------------------------------------------------
waive_hdl -add unused_sink_wires \
          -comment "Deliberate *_unused sink wires: unloaded by design (aRVern convention)" \
          -filter {Signal=~*_unused*}

# ---------------------------------------------------------------------------
# arv_synchronizer's SECOND stage carries no reset under ASYNC_RST_EN=0, by
# design: a synchronous reset is a 2:1 mux on the D pin, and a mux in the
# meta_q -> sync_q path eats into the metastability settling window (MTBF is
# exponential in that time). The reset mux is kept on the first stage only.
# Belenos synchronises its panel inputs in the DBI driver (lcd_te_i, the 8080
# read data lcd_d_i: instances u_te_sync, u_d_sync),
# which exists only when DIF_TYPE != 0.
#
# CONDITIONAL on the reset style and on the driver being present: in async
# builds both stages have a real async reset and this rule never fires, and
# without the driver there is no synchronizer -- an unconditional waiver would
# be reported stale there.
# ---------------------------------------------------------------------------
set BLNS_DIF_PRESENT [expr {![info exists RTL_PARAM_DIF_TYPE] || $RTL_PARAM_DIF_TYPE != 0}]
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0 && $BLNS_DIF_PRESENT} {
    waive_hdl -add sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q: unreset by design under ASYNC_RST_EN=0 -- a reset mux in the meta->sync path would degrade MTBF" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*_sync*/sync_q*}
}
# The DPI driver's clock crossings (g_sep) exist only with DIF_TYPE 4 or 5 and
# DPI_PCLK_SEP = 1: registered there only, or it is reported stale elsewhere.
set BLNS_DPI_SEP [expr {[info exists RTL_PARAM_DIF_TYPE] && ($RTL_PARAM_DIF_TYPE == 4 || $RTL_PARAM_DIF_TYPE == 5) &&
                        [info exists RTL_PARAM_DPI_PCLK_SEP] && $RTL_PARAM_DPI_PCLK_SEP == 1}]
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0 && $BLNS_DPI_SEP} {
    waive_hdl -add dpi_sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q of the DPI crossings (DPI_PCLK_SEP=1): unreset by design under ASYNC_RST_EN=0, as above" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*g_sep.u_?2?/sync_q*}
}

# ---------------------------------------------------------------------------
# arv_ipdff with a non-zero RST_VAL: bits that reset to 1 infer an async SET
# and bits that reset to 0 an async RESET, both from the one hresetn_i -- the
# normal implementation of a flop with a non-zero reset value. Belenos always
# has some: DISP_SIZE width/height (1), LUT_CFG HW_FG (0xF), the VRAM
# arbiter's round-robin pointer, the GPU rectangle size (1) and latched bpp.
# ---------------------------------------------------------------------------
waive_hdl -add dff_nonzero_rstval_setreset \
          -comment "arv_ipdff with non-zero RST_VAL (DISP_SIZE, LUT_CFG, arbiter pointer, GPU size/bpp): mixed set/reset from one reset is by design" \
          -tag CODING_TREE_SETRST_ORIG \
          -filter {Module=~arv_*dff*}

# A parameter of the configuration linted: its override, else the RTL default
proc blns_param {name dflt} {
    upvar #0 RTL_PARAM_$name v
    if {[info exists v]} { return $v } else { return $dflt }
}

# ---------------------------------------------------------------------------
# Netlist deadloop false positives in the DIF_TYPE=0 build with the VRAM read
# register (VRAM_RD_REG_EN=1, drv_hw_ra_dif0): the check reports the GPU
# command FIFO count's upper bits as unaffected by any input, and the
# backend fetch's last-word valid enable as affecting no output. Both are
# false:
# - the FIFO count reaches DEPTH when the engine is frozen and words are
#   pushed (sim gpu_fifo_race in this configuration: every push to the full
#   FIFO is dropped with GPU_OVFL);
# - lw_valid gates the same-word compare (lwv_n -> nf_n -> u_no_fetch ->
#   need_fetch -> vreq_o): a 1 bpp frame reads each word once (sim bk_stream
#   in this configuration, exact data).
#
# CONDITIONAL on that combination: every other configuration lints clean, and
# an unconditional waiver would be reported stale there.
# ---------------------------------------------------------------------------
if {[blns_param DIF_TYPE 2] == 0 && [blns_param VRAM_RD_REG_EN 0] != 0} {
    waive_hdl -add gpu_fifo_cnt_deadloop \
              -comment "GPU command FIFO count upper bits are reachable (a frozen engine fills the FIFO to DEPTH): netlist deadloop false positive in the DIF_TYPE=0, VRAM_RD_REG_EN=1 build" \
              -filter {Tag=~CONN_NET_FANIN_DEADLOOP && Node=~*u_gpu/u_fifo/count_nxt*}
    waive_hdl -add bk_lw_valid_deadloop \
              -comment "Backend fetch lw_valid gates the same-word compare (need_fetch -> vreq_o): netlist deadloop false positive in the DIF_TYPE=0, VRAM_RD_REG_EN=1 build" \
              -filter {Tag=~CONN_NET_FANOUT_DEADLOOP && Node=~*blns_bk_fetch_inst/u_lw_valid/en_i*}
}

# ---------------------------------------------------------------------------
# GPU command FIFO storage: the word and tag arrays (mem, tag_mem) without
# reset by design, so that an FPGA maps them to LUT RAM. The pointers and the
# count are reset; an entry is written before it is read and the head (word
# and tag) reads 0 while the FIFO is empty. Present only with the GPU
# (GPU_EN = 1).
# ---------------------------------------------------------------------------
if {[blns_param GPU_EN 1] != 0} {
    waive_hdl -add gpu_fifo_storage_no_reset \
              -comment "blns_gpu_fifo mem, tag_mem: RAM-style storage arrays, unreset by design (flush moves pointers only)" \
              -tag {CODING_FF_NO_RST_SET CODING_RST_ASYNC_FF} \
              -filter {Signal=~*u_gpu/u_fifo/*mem*}
}

# ---------------------------------------------------------------------------
# DBI driver's pixel FIFO storage (blns_dbi_fifo mem): no reset, as the GPU
# command FIFO's; an entry is written before it is read and the head reads 0
# while the FIFO is empty. Present only with the DBI driver (DIF_TYPE 1-3).
# ---------------------------------------------------------------------------
if {[blns_param DIF_TYPE 2] >= 1 && [blns_param DIF_TYPE 2] <= 3} {
    waive_hdl -add dbi_fifo_storage_no_reset \
              -comment "blns_dbi_fifo mem: RAM-style storage array, unreset by design (an entry is written before it is read)" \
              -tag {CODING_FF_NO_RST_SET CODING_RST_ASYNC_FF} \
              -filter {Signal=~*blns_dbi_fifo_inst/mem*}
}

# ---------------------------------------------------------------------------
# Flops with a constant input in some configurations, by design: the logic is
# shared by every build and a parameter ties its input; synthesis removes the
# flop (a constant register). Each is registered only where it is constant, or
# it is reported stale elsewhere.
# ---------------------------------------------------------------------------
# - belenos_core u_gpu_busy_q: the GPU's busy, 0 without the GPU
if {[blns_param GPU_EN 1] == 0} {
    waive_hdl -add const_ff_gpu_busy_q \
              -comment "u_gpu_busy_q: the GPU's busy, tied to 0 with GPU_EN=0 (flop removed by synthesis)" \
              -filter {Tag=~SYN_FF_CONST_INP && Signal=~*u_core/u_gpu_busy_q/*}
}
# - blns_gpu_setup u_ax_y: the y cycle of an affine blit, 0 without x/y
if {[blns_param GPU_EN 1] != 0 && [blns_param GPU_XY_EN 1] == 0} {
    waive_hdl -add const_ff_ax_y \
              -comment "u_ax_y: the affine blit's y cycle, tied to 0 with GPU_XY_EN=0 (no affine blit; flop removed by synthesis)" \
              -filter {Tag=~SYN_FF_CONST_INP && Signal=~*u_setup/u_ax_y/*}
}
# - blns_ahb_vram u_rd_ret: the returned read, 0 with the arbiter's read register
if {[blns_param VRAM_RD_REG_EN 0] != 0} {
    waive_hdl -add const_ff_rd_ret \
              -comment "u_rd_ret: the read landed in the buffer, tied to 0 with VRAM_RD_REG_EN=1 (the read completes from the arbiter's register; flop removed by synthesis)" \
              -filter {Tag=~SYN_FF_CONST_INP && Signal=~*u_ahb_vram/u_rd_ret/*}
}
# - blns_dpi_cdc u_prst_sync: the pixel-domain reset synchroniser, its data
#   input is 1 by construction (released by dpi_presetn_i, ASYNC_RST_EN = 1)
if {$BLNS_DPI_SEP && [blns_param ASYNC_RST_EN 1] != 0} {
    waive_hdl -add const_ff_prst_sync \
              -comment "u_prst_sync: reset synchroniser, async_i = 1 by design (cleared by dpi_presetn_i, released on hclk_i)" \
              -filter {Tag=~SYN_FF_CONST_INP && Signal=~*u_dpi_cdc/g_sep.u_prst_sync/*}
}
# - blns_hdmi u_pend, u_ovr1: the audio packets' pending bits and the audio
#   sample subpackets' symbol bits, 0 without audio (data islands on)
if {[blns_param DIF_TYPE 2] == 5 && [blns_param DPI_AUDIO_EN 0] == 0 && [blns_param DPI_ISLAND_EN 1] != 0} {
    waive_hdl -add const_ff_hdmi_pend \
              -comment "blns_hdmi u_pend: the audio packets' pending bits, tied to 0 with DPI_AUDIO_EN=0 (flop bits removed by synthesis)" \
              -filter {Tag=~SYN_FF_CONST_INP && Signal=~*g_hdmi.u_hdmi/u_pend/*}
    waive_hdl -add const_ff_hdmi_ovr1 \
              -comment "blns_hdmi u_ovr1: the audio sample subpackets' symbol bits, tied to 0 with DPI_AUDIO_EN=0 (flop bits removed by synthesis)" \
              -filter {Tag=~SYN_FF_CONST_INP && Signal=~*g_hdmi.u_hdmi/u_ovr1/*}
}
