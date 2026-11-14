#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    synthesis
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : synthesis.tcl
# Module Description : Top-level Design Compiler synthesis flow: read RTL, compile, DFT insertion, reports, netlist dump.
#----------------------------------------------------------------------------

#=============================================================================#
#                                Configuration                                #
#=============================================================================#

# Enable/Disable DC_ULTRA option
set WITH_DC_ULTRA 1

# Enable/Disable DFT insertion
set WITH_DFT      1


#=============================================================================#
#                           Read technology library                           #
#=============================================================================#
source -echo -verbose ./library.tcl


#=============================================================================#
#                               Read design RTL                               #
#=============================================================================#
source -echo -verbose ./read.tcl

# Dissolve the arv_ipdff register-primitive wrappers up front
#
# Every flop of the design is an arv_ipdff instance whose body is
# "else if (en_i) q_o <= d_i". Left as a boundary, DC maps each one to the larger
# native load-enable scan cell before merging context; flattening it here lets DC
# pick the best cell per flop from the full library. arv_synchronizer instances
# keep their boundary. Modules instantiated more than once (the TMDS encoders)
# must be uniquified first: ungroup needs a unique parent.
current_design $DESIGN_NAME
uniquify
set _dff_cells [get_cells -quiet -hierarchical -filter "ref_name =~ arv_ipdff*"]
set _n_dff     [sizeof_collection $_dff_cells]
if {$_n_dff > 0} {
    ungroup -flatten $_dff_cells
}
puts "arv_ipdff: early-ungrouped $_n_dff register-primitive instances (pre-compile)."


#=============================================================================#
#                           Set design constraints                            #
#=============================================================================#
source -echo -verbose ./constraints.tcl


#=============================================================================#
#              Set operating conditions & wire-load models                    #
#=============================================================================#

# Set operating conditions
set_operating_conditions -max $LIB_WC_OPCON -max_library $LIB_WC_NAME \
	                     -min $LIB_BC_OPCON -min_library $LIB_BC_NAME

# Set wire-load models
set_wire_load_mode top
set_wire_load_model -name $LIB_WIRE_LOAD -max -library $LIB_WC_NAME
set_wire_load_model -name $LIB_WIRE_LOAD -min -library $LIB_BC_NAME


#=============================================================================#
#                                Synthesize                                   #
#=============================================================================#

# Prevent assignment statements in the Verilog netlist.
set_fix_multiple_port_nets -all -buffer_constants

# Configuration
current_design $DESIGN_NAME
uniquify
set_max_area  0.0
set_flatten false
set_structure true -timing true -boolean true

# Verify constraints before synthesis
redirect -tee -file ./results/report.check_timing_pre {check_timing}

# Synthesis
if {$WITH_DC_ULTRA} {
    if {$WITH_DFT} {
        compile_ultra -scan -no_autoungroup
    } else {
        compile_ultra       -no_autoungroup
    }

    # Area optimization (run after compile)
    optimize_netlist -area

    # Check if timing met after area optimization
    if {[sizeof_collection [get_timing_paths -slack_lesser_than 0.0 -max_paths 1]] > 0} {
        puts "WARNING: Timing violated after area optimization. Re-optimizing for timing..."
        compile_ultra -incremental
    }

} else {
    if {$WITH_DFT} {
        compile -scan -map_effort high -area_effort high
    } else {
        compile       -map_effort high -area_effort high
    }
}


#=============================================================================#
#                                DFT Insertion                                #
#=============================================================================#
if {$WITH_DFT} {

    # hclk_i clocks every flop, except the DPI pixel domain when it has a clock of
    # its own (DIF_TYPE 4 or 5 with DPI_PCLK_SEP=1): dpi_pclk_i, reset by
    # dpi_presetn_i (the I2S bit clock is sampled as data, not a clock).
    set_dft_signal -view existing_dft -type ScanClock   -port hclk_i        -timing [list 45 55]
    set _dft_pclk 0
    if {[info exists RTL_PARAM_DIF_TYPE] && [info exists RTL_PARAM_DPI_PCLK_SEP]} {
        set _dft_pclk [expr {($RTL_PARAM_DIF_TYPE == 4 || $RTL_PARAM_DIF_TYPE == 5) && $RTL_PARAM_DPI_PCLK_SEP}]
    }
    if {$_dft_pclk} {
        set_dft_signal -view existing_dft -type ScanClock   -port dpi_pclk_i    -timing [list 45 55]
    }

    # Reset style. With ASYNC_RST_EN=1 hresetn_i drives real async reset pins, so
    # it is declared Reset and DFT controls it directly. With ASYNC_RST_EN=0 it
    # reaches the flops through the D-side mux instead: declaring it Reset makes
    # DRC treat it as a clock feeding data pins (D10 on every flop it touches).
    # It is held INACTIVE as a test-mode constant instead, and the reset path is
    # ordinary scan-testable datapath logic.
    set _dft_arst 1
    if {[info exists RTL_PARAM_ASYNC_RST_EN]} { set _dft_arst $RTL_PARAM_ASYNC_RST_EN }
    set _dft_rst [list hresetn_i]
    if {$_dft_pclk} { lappend _dft_rst dpi_presetn_i }
    foreach _p $_dft_rst {
        if {$_dft_arst} {
            set_dft_signal -view existing_dft -type Reset    -port $_p   -active 0
        } else {
            puts "DFT: synchronous reset (ASYNC_RST_EN=0) -- $_p held inactive as a test-mode constant."
            set_dft_signal -view spec         -type Constant -port $_p   -active_state 1
            set_dft_signal -view existing_dft -type Constant -port $_p   -active_state 1
        }
    }

    # DFT Configuration
    set_dft_insertion_configuration -preserve_design_name true
    set_scan_configuration -style multiplexed_flip_flop
    # One clock per chain: a chain crossing from pclk to hclk would put a scan-only
    # path (lockup latch to SI) under the hclk timing
    set_scan_configuration -clock_mixing no_mix
    set_scan_configuration -chain_count 3

    # DFT Test Protocol Creation
    create_test_protocol

    # DFT Design Rule Check
    redirect -tee -file ./results/report.dft_drc           {dft_drc}
    redirect      -file ./results/report.dft_drc_verbose   {dft_drc -verbose}
    redirect      -file ./results/report.dft_drc_coverage  {dft_drc -coverage_estimate}
    redirect      -file ./results/report.dft_scan_config   {report_scan_configuration}
    redirect      -file ./results/report.dft_insert_config {report_dft_insertion_configuration}

    # Preview DFT insertion
    redirect -tee -file ./results/report.dft_preview       {preview_dft}
    redirect      -file ./results/report.dft_preview_all   {preview_dft -show all -test_points all}

    # DFT insertion
    insert_dft

    # DFT Incremental Compile
    if {$WITH_DC_ULTRA} {
	    compile_ultra -scan -incremental
    } else {
	    compile       -scan -incremental
    }

    # DFT Coverage estimate
    redirect      -file ./results/report.dft_drc_coverage  {dft_drc -coverage_estimate}
}

#=============================================================================#
#                            Reports generation                               #
#=============================================================================#


redirect -file ./results/report.timing         {check_timing}
redirect -file ./results/report.constraints    {report_constraints -all_violators -verbose}
redirect -file ./results/report.paths.min      {report_timing -path_type end  -delay_type min -max_paths 200 -nworst 2}
redirect -file ./results/report.full_paths.min {report_timing -path_type full -delay_type min -max_paths 5   -nworst 2}

foreach grp {FEEDTHROUGH REGIN REGOUT hclk} {
    redirect -file ./results/report.paths.max.$grp      {report_timing -path_type end  -delay_type max -max_paths 200 -nworst 2 -group $grp}
    redirect -file ./results/report.full_paths.max.$grp {report_timing -path_type full -delay_type max -max_paths 5   -nworst 2 -group $grp}
}

redirect -file ./results/report.refs           {report_reference}
redirect -file ./results/report.area           {report_area}
redirect -file ./results/report.full_area      {report_area -hierarchy}

# Generate RTL configuration report
source ./report_rtl_config.tcl

# Run custom timing analysis
source ./report_timing.tcl

# Run custom area analysis
source ./report_area.tcl


#=============================================================================#
#          Dump gate level netlist, final DDC file and Test protocol          #
#=============================================================================#
current_design $DESIGN_NAME

# UCN-4 is a cosmetic self-inconsistency in DC's built-in 'verilog' name rule:
# '_' is both the replacement character and a restricted character. The netlist
# names it produces are still legal/unique Verilog, so suppress the benign warning.
suppress_message UCN-4
change_name -rules verilog -hierarchy

write -hierarchy -format verilog -output "./results/$DESIGN_NAME.gate.v"
write -hierarchy -format ddc     -output "./results/$DESIGN_NAME.ddc"

if {$WITH_DFT} {
    write_test_protocol          -output "./results/$DESIGN_NAME.spf"
}


#=============================================================================#
#                          Final Summary Display                              #
#=============================================================================#

# Display timing and area analysis summaries
# (RTL_CONFIG is combined with AREA_ANALYSIS, TIMING_HISTOGRAM is combined with TIMING_ANALYSIS)
puts $TIMING_ANALYSIS$AREA_ANALYSIS

if {$::env(NO_QUIT) == 0} {
    quit
}
