#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    report_area
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : report_area.tcl
# Module Description : Reporting helper: area breakdown by hierarchy (NAND2 equivalents).
#----------------------------------------------------------------------------

##############################################################################
#                                                                            #
#                         CUSTOM AREA ANALYSIS SCRIPT                        #
#                                                                            #
#  Detailed area breakdown with NAND2 equivalents for each belenos block.   #
#  Every row is a leaf of the breakdown (a parent row excludes the children #
#  reported on their own rows), so the rows sum to the design TOTAL; the    #
#  remainder (belenos / belenos_core local logic, DFT) is "Top-level glue". #
#  A block absent from the configuration (generate-disabled) reports 0.     #
#                                                                            #
#  Usage: source report_area.tcl                                            #
#         (after synthesis and standard area reports are generated)         #
#                                                                            #
##############################################################################

##############################################################################
#                            CONFIGURATION                                   #
##############################################################################

# Output file
set AREA_REPORT_FILE "./results/report.area_analysis.txt"

# Block instance paths, relative to the top. Generate-block prefixes are part
# of the cell name (G_GPU.u_gpu). A key may list several paths (summed).
array set BLNS_PATH {
    ahb_reg     {u_core/u_ahb_reg}
    regs        {u_core/u_regs}
    refresh     {u_core/u_regs/u_refresh}
    ahb_vram    {u_core/u_ahb_vram}
    vram_arb    {u_core/u_vram_arb}
    gpu         {u_core/G_GPU.u_gpu}
    gpu_fifo    {u_core/G_GPU.u_gpu/u_fifo}
    gpu_list    {u_core/G_GPU.u_gpu/u_list}
    gpu_dec     {u_core/G_GPU.u_gpu/u_dec}
    gpu_setup   {u_core/G_GPU.u_gpu/u_setup}
    gpu_px      {u_core/G_GPU.u_gpu/u_px}
    gpu_walk    {u_core/G_GPU.u_gpu/u_px/u_px_a/u_walk_src
                 u_core/G_GPU.u_gpu/u_px/u_px_a/u_walk_dst}
    backend     {u_core/u_backend}
    bk_fetch    {u_core/u_backend/blns_bk_fetch_inst}
    bk_color    {u_core/u_backend/g_lut.blns_bk_color_inst
                 u_core/u_backend/g_no_lut.blns_bk_hwcol_inst}
    bk_fifo     {u_core/u_backend/blns_bk_fifo_raw_inst
                 u_core/u_backend/g_lut.blns_bk_fifo_out_inst}
    bk_cursor   {u_core/u_backend/g_cursor.blns_bk_cursor_inst}
    lut         {u_core/G_LUT.u_lut}
    dbi         {G_DBI.u_dbi}
    dbi_engine  {G_DBI.u_dbi/blns_dbi_engine_inst}
    dbi_fifo    {G_DBI.u_dbi/blns_dbi_engine_inst/blns_dbi_fifo_inst}
    dbi_8080    {G_DBI.u_dbi/g_8080.blns_dbi_8080_inst}
    dbi_spi     {G_DBI.u_dbi/g_spi.blns_dbi_spi_inst}
}


##############################################################################
#                          HELPER PROCEDURES                                 #
##############################################################################

# Hierarchical area of the instances at `paths` (absent paths are skipped).
# Returns {found total combinational noncombinational flops}.
proc blns_block_area {top paths} {
    set found 0
    set tot   0.0
    set comb  0.0
    set seq   0.0
    set flops 0
    foreach p $paths {
        current_design $top
        set c [get_cells -quiet $p]
        if {[sizeof_collection $c] == 0} { continue }
        incr found
        current_design [get_attribute [index_collection $c 0] ref_name]
        redirect -variable rpt {report_area}
        if {[regexp {Total cell area:\s+([0-9.eE+-]+)}       $rpt -> v]} { set tot  [expr {$tot  + $v}] }
        if {[regexp {Combinational area:\s+([0-9.eE+-]+)}    $rpt -> v]} { set comb [expr {$comb + $v}] }
        if {[regexp {Noncombinational area:\s+([0-9.eE+-]+)} $rpt -> v]} { set seq  [expr {$seq  + $v}] }
        set flops [expr {$flops + [sizeof_collection [all_registers -cells]]}]
    }
    current_design $top
    return [list $found $tot $comb $seq $flops]
}

# a - b - c ... element-wise on the {total comb seq flops} part of block results.
proc blns_sub {a args} {
    set r [lrange $a 1 end]
    foreach b $args {
        set nr {}
        foreach x $r y [lrange $b 1 end] { lappend nr [expr {$x - $y}] }
        set r $nr
    }
    return [concat [lindex $a 0] $r]
}


##############################################################################
#                          AREA ANALYSIS                                     #
##############################################################################

if {[info exists NAND2_NAME]} {

    set nand2_area [get_attribute [get_lib_cell $LIB_WC_NAME/$NAND2_NAME] area]

    current_design $DESIGN_NAME
    redirect -variable top_rpt {report_area}
    regexp {Total cell area:\s+([0-9.eE+-]+)}       $top_rpt -> top_area
    regexp {Combinational area:\s+([0-9.eE+-]+)}    $top_rpt -> top_comb
    regexp {Noncombinational area:\s+([0-9.eE+-]+)} $top_rpt -> top_seq
    set top_buf 0.0
    regexp {Buf/Inv area:\s+([0-9.eE+-]+)}          $top_rpt -> top_buf
    set seq_cells_count [sizeof_collection [all_registers -cells]]

    foreach key [array names BLNS_PATH] {
        set B($key) [blns_block_area $DESIGN_NAME $BLNS_PATH($key)]
    }

    # Leaf rows: {label key-result}
    set rows {}
    lappend rows [list "AHB register port"   $B(ahb_reg)]
    lappend rows [list "Register bank"       [blns_sub $B(regs) $B(refresh)]]
    lappend rows [list "Refresh timing"      $B(refresh)]
    lappend rows [list "AHB VRAM window"     $B(ahb_vram)]
    lappend rows [list "VRAM arbiter"        $B(vram_arb)]
    lappend rows [list "GPU command FIFO"    $B(gpu_fifo)]
    lappend rows [list "GPU decoder"         $B(gpu_dec)]
    lappend rows [list "GPU set-up"          $B(gpu_setup)]
    lappend rows [list "GPU pixel engine"    [blns_sub $B(gpu_px) $B(gpu_walk)]]
    lappend rows [list "GPU walkers"         $B(gpu_walk)]
    lappend rows [list "GPU control"         [blns_sub $B(gpu) $B(gpu_fifo) $B(gpu_dec) $B(gpu_setup) $B(gpu_px)]]
    lappend rows [list "Backend fetch"       $B(bk_fetch)]
    lappend rows [list "Backend colour"      $B(bk_color)]
    lappend rows [list "Backend FIFOs"       $B(bk_fifo)]
    lappend rows [list "Hardware cursor"     $B(bk_cursor)]
    lappend rows [list "Backend control"     [blns_sub $B(backend) $B(bk_fetch) $B(bk_color) $B(bk_fifo) $B(bk_cursor)]]
    lappend rows [list "Colour LUT"          $B(lut)]
    lappend rows [list "DBI engine"          [blns_sub $B(dbi_engine) $B(dbi_fifo)]]
    lappend rows [list "DBI param FIFO"      $B(dbi_fifo)]
    lappend rows [list "DBI 8080 PHY"        $B(dbi_8080)]
    lappend rows [list "DBI SPI PHY"         $B(dbi_spi)]
    lappend rows [list "DBI control"         [blns_sub $B(dbi) $B(dbi_engine) $B(dbi_8080) $B(dbi_spi)]]

    # Top-level glue = TOTAL - every block instance above (top-level instances only,
    # so nothing is subtracted twice).
    set top_res [list 1 $top_area $top_comb $top_seq $seq_cells_count]
    set glue [blns_sub $top_res $B(ahb_reg) $B(regs) $B(ahb_vram) $B(vram_arb) \
                                $B(gpu) $B(backend) $B(lut) $B(dbi)]
    lappend rows [list "Top-level glue"      $glue]

    # Group subtotals (instance totals)
    set groups {}
    lappend groups [list "Bus ports + register bank" [expr {[lindex $B(ahb_reg) 1] + [lindex $B(regs) 1] + [lindex $B(ahb_vram) 1] + [lindex $B(vram_arb) 1]}]]
    lappend groups [list "GPU"                       [lindex $B(gpu) 1]]
    lappend groups [list "Backend + LUT"             [expr {[lindex $B(backend) 1] + [lindex $B(lut) 1]}]]
    lappend groups [list "DBI display driver"        [lindex $B(dbi) 1]]

    # Presence check: a configured block whose path did not resolve would
    # silently land in the glue row, so list what was found.
    set present {}
    set absent  {}
    foreach key [lsort [array names BLNS_PATH]] {
        if {[lindex $B($key) 0] > 0} { lappend present $key } else { lappend absent $key }
    }

    set row_sum 0.0
    foreach r $rows { set row_sum [expr {$row_sum + [lindex [lindex $r 1] 1]}] }

    proc n2 {a} { upvar nand2_area nand2_area; return [expr {round($a / $nand2_area)}] }
    proc pc {a} { upvar top_area top_area; return [format "%.1f%%" [expr {100.0 * $a / $top_area}]] }

    set top_nand2_eq  [n2 $top_area]
    set comb_nand2_eq [n2 $top_comb]
    set seq_nand2_eq  [n2 $top_seq]
    set buf_nand2_eq  [n2 $top_buf]

    ##########################################################################
    #                    WRITE TO DEDICATED REPORT FILE                     #
    ##########################################################################

    set fp [open $AREA_REPORT_FILE w]

    puts $fp "================================================================================"
    puts $fp "                         COMPREHENSIVE AREA ANALYSIS"
    puts $fp "================================================================================"
    puts $fp "Design:              $DESIGN_NAME"
    if {[info exists RTL_CONFIG_LABEL]} {
        puts $fp "RTL config:          $RTL_CONFIG_LABEL"
    }
    puts $fp "Analysis Date:       [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    puts $fp "Reference Gate:      $NAND2_NAME (area: $nand2_area)"
    puts $fp "================================================================================"
    puts $fp ""
    puts $fp ""

    puts $fp "================================================================================"
    puts $fp "                              AREA BREAKDOWN BY MODULE"
    puts $fp "================================================================================"
    puts $fp ""

    puts $fp [format "%-25s | %-12s | %-12s | %-10s | %s" "Module" "Area" "NAND2 Equiv" "Percent" "Flops"]
    puts $fp [string repeat "-" 80]
    foreach r $rows {
        set res [lindex $r 1]
        set a   [lindex $res 1]
        puts $fp [format "%-25s | %12d | %12d | %10s | %6d" [lindex $r 0] [expr {round($a)}] [n2 $a] [pc $a] [lindex $res 4]]
    }
    puts $fp [string repeat "-" 80]
    puts $fp [format "%-25s | %12d | %12d | %10s | %6d" "TOTAL ($DESIGN_NAME)" [expr {round($top_area)}] $top_nand2_eq [pc $top_area] $seq_cells_count]
    puts $fp "================================================================================"
    puts $fp ""

    puts $fp "AREA SUMMARY:"
    puts $fp [format "  - Total area:              %d" [expr {round($top_area)}]]
    puts $fp [format "  - Total NAND2 equivalent:  %d gates" $top_nand2_eq]
    puts $fp [format "  - Total kGates:            %.1f" [expr {$top_nand2_eq / 1000.0}]]
    puts $fp [format "  - Combinational:           %d gates (%s, buf/inv %d gates)" $comb_nand2_eq [pc $top_comb] $buf_nand2_eq]
    puts $fp [format "  - Sequential:              %d gates (%s)" $seq_nand2_eq [pc $top_seq]]
    puts $fp [format "  - Sequential cells (flops):%d" $seq_cells_count]
    puts $fp [format "  - Reference gate:          %s" $NAND2_NAME]
    puts $fp [format "  - Reference gate area:     %.6f" $nand2_area]
    puts $fp ""

    puts $fp "BLOCK GROUPS (instance totals):"
    foreach g $groups {
        puts $fp [format "  - %-26s %7d NAND2 (%s)" [lindex $g 0] [n2 [lindex $g 1]] [pc [lindex $g 1]]]
    }
    puts $fp ""

    puts $fp "CONSISTENCY:"
    puts $fp [format "  - Sum of module rows:      %d (TOTAL %d)" [expr {round($row_sum)}] [expr {round($top_area)}]]
    puts $fp "  - Blocks instantiated:     $present"
    if {[llength $absent] > 0} {
        puts $fp "  - Not in this config:      $absent"
    } else {
        puts $fp "  - Not in this config:      (none)"
    }
    puts $fp ""
    puts $fp "================================================================================"

    close $fp

    ##########################################################################
    #                  APPEND TO STANDARD AREA REPORT                       #
    ##########################################################################

    set fp [open "./results/report.area" a]
    puts $fp ""
    puts $fp [format "NAND2 equivalent cell area: %-22s --> %d" $DESIGN_NAME $top_nand2_eq]
    foreach r $rows {
        puts $fp [format "NAND2 equivalent cell area: %-22s --> %d" [lindex $r 0] [n2 [lindex [lindex $r 1] 1]]]
    }
    puts $fp [format "NAND2 equivalent combinational                     --> %d" $comb_nand2_eq]
    puts $fp [format "NAND2 equivalent sequential                        --> %d" $seq_nand2_eq]
    puts $fp [format "Sequential cells (flop count)                      --> %d" $seq_cells_count]
    close $fp

    ##########################################################################
    #                 STORE CONSOLE OUTPUT IN VARIABLE                     #
    ##########################################################################

    set ::AREA_ANALYSIS ""
    append ::AREA_ANALYSIS "     +===============================================================================+\n"
    append ::AREA_ANALYSIS "     |                               AREA BREAKDOWN BY MODULE                        |\n"
    append ::AREA_ANALYSIS "     |===============================================================================|\n"
    append ::AREA_ANALYSIS [format "     | Design:              %-56s |\n" $DESIGN_NAME]
    append ::AREA_ANALYSIS [format "     | Reference Gate:      %-12s (area: %-36s |\n" $NAND2_NAME $nand2_area)]
    append ::AREA_ANALYSIS "     |===============================================================================|\n"
    append ::AREA_ANALYSIS "     |                                                                               |\n"
    append ::AREA_ANALYSIS "     |           Module          |     Area     |  NAND2 Equiv |    Percent          |\n"
    append ::AREA_ANALYSIS "     |---------------------------+--------------+--------------+---------------------|\n"
    foreach r $rows {
        set a [lindex [lindex $r 1] 1]
        append ::AREA_ANALYSIS [format "     | %-25s | %12d | %12d | %10s          |\n" [lindex $r 0] [expr {round($a)}] [n2 $a] [pc $a]]
    }
    append ::AREA_ANALYSIS "     |---------------------------+--------------+--------------+---------------------|\n"
    append ::AREA_ANALYSIS [format "     | %-25s | %12d | %12d | %10s          |\n" "TOTAL ($DESIGN_NAME)" [expr {round($top_area)}] $top_nand2_eq [pc $top_area]]
    append ::AREA_ANALYSIS [format "     | %-25s | %12d | %12d | %10s          |\n" "  combinational" [expr {round($top_comb)}] $comb_nand2_eq [pc $top_comb]]
    append ::AREA_ANALYSIS [format "     | %-25s | %12d | %12d | %10s          |\n" "  sequential"    [expr {round($top_seq)}]  $seq_nand2_eq  [pc $top_seq]]
    append ::AREA_ANALYSIS [format "     | %-25s | %12d | %-12s | %10s          |\n" "Sequential cells"      $seq_cells_count "(flops)"        "n/a"]
    append ::AREA_ANALYSIS "     +===============================================================================+\n"

    ##########################################################################
    #                 COMBINE AREA_ANALYSIS AND RTL_CONFIG                  #
    ##########################################################################

    # Source report utilities
    source ./report_utils.tcl

    # Combine AREA_ANALYSIS and RTL_CONFIG side by side
    set ::AREA_ANALYSIS [combine_reports_side_by_side $::AREA_ANALYSIS $::RTL_CONFIG 86 3]

    puts ""
    puts "      ================================================================================"
    puts "      Area analysis complete!"
    puts "      Report saved to: $AREA_REPORT_FILE"
    puts "      ================================================================================"
    puts ""
}
