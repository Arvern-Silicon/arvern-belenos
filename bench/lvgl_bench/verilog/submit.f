//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    submit (lvgl_bench)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : submit.f
// Module Description : LVGL benchmark bench file list: the bench, Belenos,
//                      and the aRVern core from the arvern repository
//                      checked out next to this one (a dependency of this
//                      bench only, not of the IP). Paths are relative to
//                      this file (sim/rtl_sim/bin/flatten_filelist.py).
//----------------------------------------------------------------------------

//=============================================================================
// Testbench related
//=============================================================================

+incdir+.
+incdir+../../verilog/
../../verilog/dpi_panel_model.v
lb_ahb_mem.v
tb_lvgl_bench.v

//=============================================================================
// aRVern RISC-V core (sibling repository)
//=============================================================================

+incdir+../../../../arvern/rtl/verilog/
-f ../../../../arvern/rtl/verilog/filelist.f

//=============================================================================
// Belenos graphic controller
//=============================================================================

+incdir+../../../rtl/verilog/
-f ../../../rtl/verilog/filelist.f
