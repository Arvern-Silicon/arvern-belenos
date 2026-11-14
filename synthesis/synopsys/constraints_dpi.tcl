#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    constraints_dpi
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_dpi.tcl
# Module Description : The pixel clock of the DPI / HDMI driver (DIF_TYPE 4 / 5
#                      with DPI_PCLK_SEP = 1) and its clock crossings: the
#                      synchroniser first stages here, the crossings without
#                      a synchroniser from the IP's own constraint file in the
#                      Synopsys dialect, rtl/constraints/belenos_dpi_dc.sdc
#                      (the one an integrator sources in a DC / PrimeTime
#                      flow), so this flow checks that file.
#
#                      hclk and pclk are not cut apart: the crossings listed
#                      here get their budget, the synchroniser first stages
#                      are false paths, and any other path between the two
#                      clocks is timed as a synchronous one, so an
#                      unsynchronised crossing missing from the list shows up
#                      as a violation instead of passing unseen.
#----------------------------------------------------------------------------

# Pixel clock period: 74.25 MHz (720p60) unless the library setup sets it
if {![info exists PCLK_PERIOD]} {
    set PCLK_PERIOD 13.468
}

create_clock -name     "pclk"                                 \
             -period   "$PCLK_PERIOD"                         \
             -waveform "0 [expr $PCLK_PERIOD/2]"              \
             [get_ports dpi_pclk_i]

# The driver instance (generate block G_DPI of belenos, the top here)
set DPI "*G_DPI*u_dpi"

proc dpi_cells {pat} {
    return [get_cells -hierarchical -filter "full_name =~ $pat && is_sequential == true"]
}

#=============================#
#   SYNCHRONISER FIRST STAGES #
#=============================#
# Every arv_synchronizer of the driver (blns_dpi_cdc, the panel-detect and DDC
# filters of blns_dpi_regs, the I2S inputs of blns_hdmi): no synchronous
# relationship up to the first stage.
set_false_path -to [dpi_cells "${DPI}/*meta_q*"]

#=============================#
#   CROSSINGS, HELD STABLE    #
#=============================#
# hclk -> pclk (staged configuration, DPI_HDMI fields, DPI_PKT0-7, DPI_AUD,
# frame size, bank tags) and pclk -> hclk (LINE / VBLANK, CTS snapshots): a
# maximum delay of one pixel-clock period each (rtl/constraints/belenos_dpi_dc.sdc)
set BLNS ""
set PCLK "pclk"
source -echo -verbose ../../rtl/constraints/belenos_dpi_dc.sdc
