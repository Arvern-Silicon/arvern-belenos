#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    report_rtl_config
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : report_rtl_config.tcl
# Module Description : Reporting helper: echo the active RTL parameter configuration.
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                      RTL CONFIGURATION REPORT SCRIPT                       #
#                                                                            #
#  Builds ::RTL_CONFIG, a formatted box of the RTL parameters used during    #
#  synthesis (printed next to the area analysis).                            #
#                                                                            #
#  Usage: source report_rtl_config.tcl                                       #
#         (after rtl_params.tcl has been sourced by read.tcl)                #
#                                                                            #
##############################################################################

# Check if rtl_params.tcl was sourced
if {![info exists RTL_PARAM_DIF_TYPE] ||
    ![info exists RTL_PARAM_GPU_EN]   || ![info exists RTL_PARAM_LUT_EN]} {
    puts "Warning: RTL parameters not loaded - skipping configuration report"
    set ::RTL_CONFIG ""
    return
}

proc rtl_cfg_line {name value} {
    append ::RTL_CONFIG [format "     |                      %-27s : %-46s |\n" $name $value]
}

set _cfg_label "default"
if {[info exists RTL_CONFIG_LABEL]} { set _cfg_label $RTL_CONFIG_LABEL }

# Build RTL configuration report
set ::RTL_CONFIG ""
append ::RTL_CONFIG "     +===================================================================================================+\n"
append ::RTL_CONFIG "     |                                            RTL CONFIGURATION                                      |\n"
append ::RTL_CONFIG "     |===================================================================================================|\n"
append ::RTL_CONFIG [format "     | Design:              %-75s  |\n" $DESIGN_NAME]
append ::RTL_CONFIG [format "     | Config:              %-75s  |\n" "$_cfg_label (sim/rtl_sim/bin/rtl_configs.py)"]
append ::RTL_CONFIG "     |===================================================================================================|\n"
append ::RTL_CONFIG "     |                                                                                                   |\n"

array set dif_desc {
    0 "BDI: none (BDI exported for an external driver)"
    1 "DBI_SPI: MIPI-DBI SPI"
    2 "DBI_PAR: MIPI-DBI 8080-16"
    3 "DBI_PAR_SPI: MIPI-DBI 8080-16 + SPI (PHY_SEL)"
}

# VRAM section
append ::RTL_CONFIG "     | VIDEO MEMORY:                                                                                     |\n"
rtl_cfg_line "VRAM depth (VRAM_WORDS)"   [format "%d x 32-bit words (%d KiB)" $RTL_PARAM_VRAM_WORDS [expr {($RTL_PARAM_VRAM_WORDS * 4) / 1024}]]
rtl_cfg_line "VRAM address (VRAM_AW)"    "$RTL_PARAM_VRAM_AW-bit word address"
rtl_cfg_line "Dimension fields (DIM_W)"  "$RTL_PARAM_DIM_W-bit width/height"
rtl_cfg_line "Frame pointers (FRAME_NR)" $RTL_PARAM_FRAME_NR

# Engines section
append ::RTL_CONFIG "     | ENGINES:                                                                                          |\n"
if {$RTL_PARAM_GPU_EN} {
    rtl_cfg_line "GPU (GPU_EN)"          "Enabled, 16-entry command FIFO"
} else {
    rtl_cfg_line "GPU (GPU_EN)"          "Not present"
}
if {$RTL_PARAM_LUT_EN} {
    rtl_cfg_line "Colour LUT (LUT_EN)"   "Enabled, $RTL_PARAM_LUT_BANKS bank(s)"
} else {
    rtl_cfg_line "Colour LUT (LUT_EN)"   "Not present (hardware colour only)"
}

# Display interface section
append ::RTL_CONFIG "     | DISPLAY INTERFACE:                                                                                |\n"
set _dif_str [expr {[info exists dif_desc($RTL_PARAM_DIF_TYPE)] ? $dif_desc($RTL_PARAM_DIF_TYPE) : "Unknown ($RTL_PARAM_DIF_TYPE)"}]
rtl_cfg_line "Display driver (DIF_TYPE)" $_dif_str

# Other configuration
append ::RTL_CONFIG "     | OTHER CONFIGURATION:                                                                              |\n"
rtl_cfg_line "Privilege check"           [expr {$RTL_PARAM_PRIV_CHECK_EN ? "U-mode accesses denied (ERROR)" : "Disabled"}]
if {[info exists RTL_PARAM_VRAM_RD_LAT]} {
    rtl_cfg_line "VRAM macro read latency"   "$RTL_PARAM_VRAM_RD_LAT cycle(s)"
}
if {[info exists RTL_PARAM_VRAM_RD_REG_EN]} {
    rtl_cfg_line "VRAM read data"            [expr {$RTL_PARAM_VRAM_RD_REG_EN ? "Registered (one more read cycle)" : "Direct"}]
}
if {[info exists RTL_PARAM_ASYNC_RST_EN]} {
    rtl_cfg_line "Reset architecture"        [expr {$RTL_PARAM_ASYNC_RST_EN == 1 ? "Asynchronous (active-low)" : "Synchronous"}]
}

append ::RTL_CONFIG "     +===================================================================================================+\n"

puts ""
puts "================================================================================"
puts "RTL configuration report generated"
puts "================================================================================"
puts ""
