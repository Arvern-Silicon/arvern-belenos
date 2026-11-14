#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    belenos_dpi.sdc
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Clock-crossing constraints of the DPI / HDMI driver with DPI_PCLK_SEP = 1
# (doc/integration_guide.md, "Separate pixel clock"). Source it after
# the clocks are defined, with:
#   BLNS        hierarchical path of the belenos instance, e.g. "u_soc/belenos_inst"
#   PCLK        name of the clock on dpi_pclk_i
#   PCLK_PERIOD its period (ns)
# (the hclk_i side needs no variable: the paths are given by their cells)
#
# Do not cut the two clocks apart with set_clock_groups -asynchronous (or
# set_false_path between them) instead: the registers below cross without a
# synchroniser and are only safe when their data reach the other domain
# within about one pixel clock. The synchronisers (arv_synchronizer) need the
# tool's usual synchroniser constraint and are not listed.
#
# Written in SDC as Vivado and Gowin read it (set_max_delay -datapath_only,
# hierarchical cell patterns). For Synopsys Design Compiler and PrimeTime use
# belenos_dpi_dc.sdc, the same paths in their dialect (leaf flip-flops,
# -ignore_clock_latency in PrimeTime); the Belenos synthesis flow sources that one. Quartus
# has no -datapath_only: use set_max_delay with set_min_delay -1000 on the
# same paths, or set_net_delay, there.
#----------------------------------------------------------------------------

# The generate block G_DPI may be named G_DPI.u_dpi, G_DPI_u_dpi or G_DPI/u_dpi
# after elaboration, depending on the tool: adjust the pattern if needed.
set BLNS_DPI "${BLNS}/G_DPI*u_dpi"

# hclk_i -> dpi_pclk_i: held stable while the pixel domain may read them
#   in blns_dpi_regs:
#   u_st_*      staged configuration (writes ignored while the pixel domain
#               may take it: from the enable until it runs, and while an
#               UPDATE is pending)
#   u_hdmi_fld  DPI_HDMI fields (copied at a start, an UPDATE (locked) or
#               when AVI rises, stable then)
#   u_pkt0 / u_pkt  DPI_PKT0-7 (read while GP is set and by a packet still sent
#                   when it clears; not written while GP is set)
#   u_aud_cfg   DPI_AUD (read while AUD is set there; writes ignored then)
#   in blns_dpi_bdi:
#   u_sz        frame size snapshot (announced by a toggle)
#   u_tag       line-buffer bank tags (stable while the bank is full)
set_max_delay -datapath_only -to [get_clocks $PCLK] $PCLK_PERIOD -from [get_cells -hierarchical [list \
    "${BLNS_DPI}/u_dpi_regs/*u_st_*" "${BLNS_DPI}/u_dpi_regs/*u_hdmi_fld*" \
    "${BLNS_DPI}/u_dpi_regs/*u_aud_cfg*" "${BLNS_DPI}/u_dpi_regs/*u_pkt*" \
    "${BLNS_DPI}/u_dpi_bdi/u_sz*" "${BLNS_DPI}/u_dpi_bdi/*u_tag*"]]

# dpi_pclk_i -> hclk_i: snapshots taken on a synchronised toggle, in
# blns_dpi_cdc (every other crossing there goes through arv_synchronizer)
#   u_line      LINE / VBLANK into DPI_STATUS
#   u_cts_h     the measured CTS into DPI_AUD_STAT
set_max_delay -datapath_only -from [get_clocks $PCLK] $PCLK_PERIOD -to [get_cells -hierarchical [list \
    "${BLNS_DPI}/u_dpi_cdc/u_line*" "${BLNS_DPI}/u_dpi_cdc/*u_cts_h*"]]
