#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    constraints
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : constraints.tcl
# Module Description : Clock and path groups for the belenos synthesis flow (hclk, and the
#                      DPI pixel clock with DPI_PCLK_SEP = 1).
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

# Clock period can be set by the library setup file (setup_*.tcl).
# If not already defined, use the default value below.
if {![info exists CLOCK_PERIOD]} {
    #set CLOCK_PERIOD 50.0; #  20 MHz
    #set CLOCK_PERIOD 40.0; #  25 MHz
    #set CLOCK_PERIOD 25.0; #  40 MHz
    #set CLOCK_PERIOD 20.0; #  50 MHz
    set CLOCK_PERIOD 15.0; #  66 MHz
    #set CLOCK_PERIOD 12.5; #  80 MHz
    #set CLOCK_PERIOD 10.0; # 100 MHz
    #set CLOCK_PERIOD  8.0; # 125 MHz
}


create_clock -name     "hclk"                                 \
             -period   "$CLOCK_PERIOD"                        \
             -waveform "0 [expr $CLOCK_PERIOD/2]" \
             [get_ports hclk_i]

# The DPI / HDMI driver with its own pixel clock (DIF_TYPE 4 / 5, DPI_PCLK_SEP = 1):
# the pixel clock and the crossings (constraints_dpi.tcl)
set DPI_PCLK_SEP 0
if {[info exists RTL_PARAM_DIF_TYPE] && [info exists RTL_PARAM_DPI_PCLK_SEP]} {
    if {($RTL_PARAM_DIF_TYPE == 4 || $RTL_PARAM_DIF_TYPE == 5) && $RTL_PARAM_DPI_PCLK_SEP} {
        set DPI_PCLK_SEP 1
    }
}
if {$DPI_PCLK_SEP} {
    source -echo -verbose ./constraints_dpi.tcl
}


##############################################################################
#                                                                            #
#                          CREATE PATH GROUPS                                #
#                                                                            #
##############################################################################

group_path -name REGOUT      -to   [all_outputs]
group_path -name REGIN       -from [remove_from_collection [all_inputs] [get_ports {hclk_i dpi_pclk_i}]]
group_path -name FEEDTHROUGH -from [remove_from_collection [all_inputs] [get_ports {hclk_i dpi_pclk_i}]] -to [all_outputs]


##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################

source -echo -verbose ./constraints_ports.tcl
