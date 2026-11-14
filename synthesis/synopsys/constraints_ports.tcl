#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    constraints_ports
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints_ports.tcl
# Module Description : Per-port input delay / output delay constraints and false paths for belenos.
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                  BOUNDARY TIMINGS (percent of CLOCK_PERIOD)                #
#                                                                            #
##############################################################################

# Budgets as a percentage of the clock period (input delay = external arrival,
# output delay = external requirement, so the IP keeps the rest of the period):
#   bus-side inputs (AHB managers, BDI driver, debug)   input  delay 20 %
#   bus-side outputs (AHB responses, BDI, irq, hclk_en) output delay 70 %
#     (the BDI outputs 0 % with a built-in driver: observation only)
#   SRAM macro read data (clock-to-q of the macro)      input  delay 20 %
#     (as ahb_sram_controller: the read data feeds hrdata combinationally,
#      so macro-in + bus-out must leave room for the read mux)
#   SRAM macro controls (macro setup + routing)         output delay 60 %
#   panel pins (registered, slow external interface)    output delay 50 %
set IN_BUS_DLY    [expr ($CLOCK_PERIOD/100) * 20]
set OUT_BUS_DLY   [expr ($CLOCK_PERIOD/100) * 70]
set IN_MACRO_DLY  [expr ($CLOCK_PERIOD/100) * 20]
set OUT_MACRO_DLY [expr ($CLOCK_PERIOD/100) * 60]
set OUT_PAD_DLY   [expr ($CLOCK_PERIOD/100) * 50]

proc blns_in {dly ports} {
    set_input_delay  $dly -max -clock "hclk" [get_ports $ports]
    set_input_delay  0    -min -clock "hclk" [get_ports $ports]
}
proc blns_out {dly ports} {
    set_output_delay $dly -add_delay -max -clock "hclk" [get_ports $ports]
    set_output_delay 0               -min -clock "hclk" [get_ports $ports]
}

#==========================#
#   AHB-LITE REGISTER PORT #
#==========================#
blns_in  $IN_BUS_DLY  {r_hsel_i r_haddr_i r_htrans_i r_hwrite_i r_hsize_i r_hprot_i r_hsmode_i r_hready_i r_hwdata_i}
blns_out $OUT_BUS_DLY {r_hrdata_o r_hreadyout_o r_hresp_o}

#==========================#
#   AHB-LITE VRAM WINDOW   #
#==========================#
blns_in  $IN_BUS_DLY  {v_hsel_i v_haddr_i v_htrans_i v_hwrite_i v_hsize_i v_hprot_i v_hsmode_i v_hready_i v_hwdata_i}
blns_out $OUT_BUS_DLY {v_hrdata_o v_hreadyout_o v_hresp_o}

#==========================#
#   VRAM AND LUT MACROS    #
#==========================#
blns_in  $IN_MACRO_DLY  {vram_dout_i lut_dout_i}
blns_out $OUT_MACRO_DLY {vram_cen_o vram_wen_o vram_addr_o vram_din_o lut_cen_o lut_wen_o lut_addr_o lut_din_o}

#==========================#
#   DEBUG / IRQ / CLOCK    #
#==========================#
blns_in  $IN_BUS_DLY  {dbg_stoptime_i}
blns_out $OUT_BUS_DLY {irq_o hclk_en_o}

#==========================#
#   BDI (DIF_TYPE = 0)     #
#==========================#
# With DIF_TYPE = 0 the BDI ports go to the exported driver: bus budgets. With
# a built-in driver the inputs are ignored and the outputs only observe the
# internal stream: an output delay of 0 (the whole period, a path still timed)
blns_in  $IN_BUS_DLY  {bdi_px_ready_i bdi_refresh_active_i bdi_reg_rdata_i bdi_reg_ready_i bdi_irq_i bdi_busy_i}
set BDI_OUT_DLY $OUT_BUS_DLY
if {[info exists RTL_PARAM_DIF_TYPE] && ($RTL_PARAM_DIF_TYPE != 0)} {
    set BDI_OUT_DLY 0
}
blns_out $BDI_OUT_DLY {bdi_px_valid_o bdi_px_data_o bdi_px_last_o bdi_refresh_trig_o bdi_width_o bdi_height_o
                       bdi_reg_sel_o bdi_reg_addr_o bdi_reg_wr_o bdi_reg_wdata_o}

#==========================#
#   PANEL PINS             #
#==========================#
blns_out $OUT_PAD_DLY {lcd_d_o lcd_d_oe_o lcd_cs_n_o lcd_rd_n_o lcd_wr_n_o lcd_dc_o
                       spi_sck_o spi_mosi_o spi_cs_n_o spi_dc_o lcd_reset_n_o lcd_on_o}


#==========================#
#   DPI / HDMI (DIF 4, 5)  #
#==========================#
# Panel pins, TMDS symbols and the line-buffer read port belong to the pixel
# domain (pclk with DPI_PCLK_SEP = 1, else hclk), with budgets in percent of
# its period; the line-buffer write port and the DDC pull-downs to hclk. The
# TMDS symbols go to an on-chip serialiser: a macro budget.
if {[info exists DPI_PCLK_SEP] && $DPI_PCLK_SEP} {
    set DPI_CLK "pclk"
    set DPI_PER $PCLK_PERIOD
} else {
    set DPI_CLK "hclk"
    set DPI_PER $CLOCK_PERIOD
}
proc dpi_in {clk dly ports} {
    set_input_delay  $dly -max -clock $clk [get_ports $ports]
    set_input_delay  0    -min -clock $clk [get_ports $ports]
}
proc dpi_out {clk dly ports} {
    set_output_delay $dly -add_delay -max -clock $clk [get_ports $ports]
    set_output_delay 0               -min -clock $clk [get_ports $ports]
}
dpi_out $DPI_CLK [expr ($DPI_PER/100) * 50] {dpi_de_o dpi_hs_o dpi_vs_o dpi_rgb_o dpi_clk_d0_o dpi_clk_d1_o}
dpi_out $DPI_CLK [expr ($DPI_PER/100) * 60] {tmds_o dpi_lb_raddr_o}
dpi_in  $DPI_CLK [expr ($DPI_PER/100) * 20] {dpi_lb_rdata_i}
blns_out $OUT_MACRO_DLY {dpi_lb_we_o dpi_lb_waddr_o dpi_lb_wdata_o}
blns_out $OUT_PAD_DLY   {ddc_scl_pd_o ddc_sda_pd_o}

#===============#
# FALSE PATHS   #
#===============#

# Asynchronous panel inputs: each enters through an arv_synchronizer, so there
# is no synchronous relationship to time up to the first stage (spi_miso_i has
# no load; it is listed so a future read path starts constrained).
set_false_path -from [get_ports {lcd_te_i spi_miso_i}]
# 8080 read data: also asynchronous, but sampled at the edge that raises RD, so
# its route to the first synchroniser stage is part of the read round trip that
# the RD low time must cover (programming_model.md, 8080 PHY): at most one hclk
# period from the pad, instead of an unbounded route. D[15:8] have no load.
set BLNS_D_SYNC [get_cells -hierarchical -filter "full_name =~ *blns_dbi_8080_inst*u_d_sync*meta_q* && is_sequential == true"]
if {[sizeof_collection $BLNS_D_SYNC] > 0} {
    blns_in 0 {lcd_d_i*}   ;# launched at the clock edge: the route alone gets the budget
    set_max_delay $CLOCK_PERIOD -from [get_ports {lcd_d_i*}] -to $BLNS_D_SYNC
    set_false_path -hold -from [get_ports {lcd_d_i*}]   ;# asynchronous: no hold relationship
} elseif {[info exists RTL_PARAM_DIF_TYPE] && (($RTL_PARAM_DIF_TYPE == 2) || ($RTL_PARAM_DIF_TYPE == 3))} {
    echo "Error: the 8080 read synchroniser (blns_dbi_8080 u_d_sync meta_q) was not found: lcd_d_i is unconstrained"
}
# The same for the DPI / HDMI driver: panel detect, DDC lines, I2S
set_false_path -from [get_ports {panel_detect_i ddc_scl_i ddc_sda_i i2s_bclk_i i2s_lrck_i i2s_sd_i}]

#===================#
# RESET (hresetn_i) #
#===================#
# How the reset is timed depends on the reset architecture (ASYNC_RST_EN, set in
# rtl_params.tcl and sourced via read.tcl; defaults to async if not present):
#   1 = asynchronous reset -> drives the flops' async clear/preset directly; its
#       assertion isn't timed against hclk and its deassertion is synchronized
#       outside the IP, so it stays a false path.
#   0 = synchronous reset  -> ordinary synchronous data on the flops' D-side mux,
#       so constrain it with an input delay and let STA time it (a false path
#       would leave those paths silently unconstrained).
set HRESETN_ASYNC 1
if {[info exists RTL_PARAM_ASYNC_RST_EN]} { set HRESETN_ASYNC $RTL_PARAM_ASYNC_RST_EN }
if {$HRESETN_ASYNC} {
    set_false_path -from [get_ports {hresetn_i dpi_presetn_i}]
} else {
    blns_in $IN_BUS_DLY {hresetn_i}
    dpi_in  $DPI_CLK [expr ($DPI_PER/100) * 20] {dpi_presetn_i}
}
