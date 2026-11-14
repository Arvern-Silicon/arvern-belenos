//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    submit
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : submit.f
// Module Description : Simulation submit file (testbench + RTL sources).
//----------------------------------------------------------------------------

//=============================================================================
// Testbench related
//=============================================================================

+incdir+.
+define+BLNS_TRACE_CLK=tb_belenos.free_clk
ili9341_8080_model.v
ili9341_spi_model.v
dpi_panel_model.v
tmds_rx_model.v
ddc_eeprom_model.v
i2s_src_model.v
probes_gpu.v
tb_belenos.v

//=============================================================================
// Belenos graphic controller
//=============================================================================

+incdir+../../rtl/verilog/
-f ../../rtl/verilog/filelist.f
