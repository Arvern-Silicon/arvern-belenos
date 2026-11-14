//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    filelist
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : filelist.f
// Module Description : RTL source file list for belenos.
//----------------------------------------------------------------------------

//=============================================================================
// Shared building blocks (arv_primitives)
//=============================================================================
-f ../../../arvern-ips/arv_primitives/rtl/verilog/filelist.f

//=============================================================================
// Belenos modules
//=============================================================================
blns_ahb_reg.v
blns_ahb_vram.v
blns_backend.v
blns_bk_color.v
blns_bk_cursor.v
blns_bk_fetch.v
blns_bk_fifo.v
blns_bk_hwcol.v
blns_dbi.v
blns_dpi.v
blns_dpi_regs.v
blns_dpi_bdi.v
blns_dpi_scan.v
blns_dpi_cdc.v
blns_tmds.v
blns_hdmi.v
blns_hdmi_i2s.v
blns_dbi_8080.v
blns_dbi_engine.v
blns_dbi_fifo.v
blns_dbi_spi.v
blns_gpu.v
blns_gpu_dec.v
blns_gpu_setup.v
blns_gpu_tri_setup.v
blns_gpu_px.v
blns_gpu_px_a.v
blns_gpu_px_fw.v
blns_gpu_px_l.v
blns_gpu_px_tc.v
blns_gpu_fifo.v
blns_gpu_list.v
blns_gpu_walk.v
blns_lut.v
blns_refresh.v
blns_regs.v
blns_vram_arb.v
belenos_core.v
belenos.v
