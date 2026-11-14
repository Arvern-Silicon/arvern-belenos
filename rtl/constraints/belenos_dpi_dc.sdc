#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    belenos_dpi_dc.sdc
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Clock-crossing constraints of the DPI / HDMI driver with DPI_PCLK_SEP = 1
# (doc/integration_guide.md, "Separate pixel clock"), in the dialect of
# Synopsys Design Compiler and PrimeTime: the same paths as belenos_dpi.sdc
# (the Vivado / Gowin form). Source it after the clocks are defined, with:
#   BLNS        hierarchical path of the belenos instance followed by "/",
#               e.g. "u_soc/belenos_inst/"; "" when belenos is the top
#   PCLK        name of the clock on dpi_pclk_i
#   PCLK_PERIOD its period (ns)
# The Belenos synthesis flow sources it (synthesis/synopsys/constraints_dpi.tcl).
#
# Do not cut the two clocks apart with set_clock_groups -asynchronous (or
# set_false_path between them) instead: the registers below cross without a
# synchroniser and are only safe when their data reach the other domain
# within about one pixel clock. The synchronisers (arv_synchronizer) need the
# tool's usual synchroniser constraint and are not listed.
#
# The budget is the data path alone (what -datapath_only gives in the other
# dialect): Design Compiler times with ideal clocks, so a plain set_max_delay
# gives it; PrimeTime, after clock-tree synthesis, adds -ignore_clock_latency
# (Design Compiler L-2016 rejects that option). The start and end points are the leaf flip-flops of the
# arv_ipdff instances named below. Each list is checked: an empty one (a
# changed hierarchy) is an error, not a silently unconstrained crossing.
#----------------------------------------------------------------------------

set BLNS_DPI "${BLNS}*G_DPI*u_dpi"

set blns_dpi_opt [list]
if {[info exists synopsys_program_name] && ($synopsys_program_name eq "pt_shell")} {
    lappend blns_dpi_opt -ignore_clock_latency
}

proc blns_dpi_seq {pats} {
    set c [list]
    foreach p $pats {
        set s [get_cells -hierarchical -quiet -filter "full_name =~ $p && is_sequential == true"]
        if {[sizeof_collection $s] == 0} {
            echo "Error: belenos_dpi_dc.sdc: no flip-flop matches $p"
        }
        set c [add_to_collection $c $s]
    }
    return $c
}

# hclk_i -> dpi_pclk_i: held stable while the pixel domain may read them
#   in blns_dpi_regs:
#   u_st_*      staged configuration (writes ignored while the pixel domain
#               may take it: from the enable until it runs, and while an
#               UPDATE is pending)
#   u_hdmi_fld  DPI_HDMI fields (copied at a start, an UPDATE (locked) or
#               when AVI rises, stable then)             (DIF_TYPE 5, HDMI)
#   u_pkt0 / u_pkt  DPI_PKT0-7 (read while GP is set and by a packet still sent
#                   when it clears; not written while GP is set)
#   u_aud_cfg   DPI_AUD (read while AUD is set there; writes ignored then)
#                                                        (DPI_AUDIO_EN)
#   in blns_dpi_bdi:
#   u_sz        frame size snapshot (announced by a toggle)
#   u_tag       line-buffer bank tags (stable while the bank is full)
set blns_dpi_h2p [list "${BLNS_DPI}/u_dpi_regs/*u_st_*" "${BLNS_DPI}/u_dpi_bdi/u_sz/*" \
                       "${BLNS_DPI}/u_dpi_bdi/*u_tag/*"]
if {[sizeof_collection [get_cells -hierarchical -quiet -filter "full_name =~ ${BLNS_DPI}/u_dpi_regs/*u_hdmi_fld*"]] > 0} {
    lappend blns_dpi_h2p "${BLNS_DPI}/u_dpi_regs/*u_hdmi_fld*"
}
if {[sizeof_collection [get_cells -hierarchical -quiet -filter "full_name =~ ${BLNS_DPI}/u_dpi_regs/*u_aud_cfg*"]] > 0} {
    lappend blns_dpi_h2p "${BLNS_DPI}/u_dpi_regs/*u_aud_cfg*" "${BLNS_DPI}/u_dpi_regs/*u_pkt*"
}
eval set_max_delay $PCLK_PERIOD $blns_dpi_opt -to [get_clocks $PCLK] -from [blns_dpi_seq $blns_dpi_h2p]

# dpi_pclk_i -> hclk_i: snapshots taken on a synchronised toggle, in
# blns_dpi_cdc (every other crossing there goes through arv_synchronizer)
#   u_line      LINE / VBLANK into DPI_STATUS
#   u_cts_h     the measured CTS into DPI_AUD_STAT       (DPI_AUDIO_EN)
set blns_dpi_p2h [list "${BLNS_DPI}/u_dpi_cdc/u_line/*"]
if {[sizeof_collection [get_cells -hierarchical -quiet -filter "full_name =~ ${BLNS_DPI}/u_dpi_cdc/*u_cts_h*"]] > 0} {
    lappend blns_dpi_p2h "${BLNS_DPI}/u_dpi_cdc/*u_cts_h*"
}
eval set_max_delay $PCLK_PERIOD $blns_dpi_opt -from [get_clocks $PCLK] -to [blns_dpi_seq $blns_dpi_p2h]
