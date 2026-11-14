//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_phy_sel
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_phy_sel.v
// Module Description : DBI driver runtime PHY selection (DIF_TYPE 3 only).
//                      DIF_CFG.PHY_SEL written while an operation runs reads
//                      back at once but takes effect at the next operation:
//                      a held 8080 command finishes on 8080 and the command
//                      queued behind it goes out on SPI; a running SPI DFILL
//                      finishes on SPI and the next refresh goes out on 8080.
//                      The unselected PHY never asserts its CS (CS low cycle
//                      counters of dbi_model_ext; the monitors also check the
//                      two CS are never low together).
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    kk, xx, yy, mark, cs8, css;
reg [15:0] pa, pb;

function [15:0] pix16;
   input integer x;
   input integer y;
   begin
      pix16 = 16'h0F0F ^ (x * 16'h0303) ^ (y * 16'h5000);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|            DBI: RUNTIME PHY SELECT            |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 3)
         tb_skip_finish("|      (PHY_SEL is writable only with DIF_TYPE 3)    |");

      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (2 << 16) | 4);
      reg_wr(FRAME0_PTR, 32'h0);
      for (kk = 0; kk < 8; kk = kk + 2)
         vram_wr(2*kk, {pix16((kk+1) % 4, (kk+1) / 4), pix16(kk % 4, kk / 4)}, SZ_W);

      // 1. 8080 command held; PHY_SEL -> SPI; queued command goes to SPI
      dif_cfg(PHY_8080, 4'd1, 1'b0, 1'b1, 1'b0);
      mark = lg_n; exp_reset;
      exp_cmd(PHY_8080, 8'hD0, 1'b1); exp_par(PHY_8080, 16'h1234); exp_par(PHY_8080, 16'h5678);
      exp_cmd(PHY_SPI,  8'hD1, 1'b1); exp_par(PHY_SPI,  16'h009A);
      css = ms_cs_lo_cyc;
      reg_wr(DIF_CMD, 32'h0000_02D0);
      reg_wr(DIF_PARAM, 32'h0000_1234);
      repeat(30) @(posedge free_clk);
      dif_cfg(PHY_SPI, 4'd1, 1'b0, 1'b1, 1'b0);
      reg_rd_mask(DIF_CFG, 32'h4, 32'h4);
      reg_wr(DIF_CMD, 32'h0000_01D1);                   // queued
      repeat(30) @(posedge free_clk);
      if (lcd_cs_n !== 1'b0) tb_error("1: held 8080 command lost CS after the PHY_SEL write");
      if (ms_cs_lo_cyc != css) tb_error("1: SPI CS asserted while the 8080 command runs");
      reg_wr(DIF_PARAM, 32'h0000_5678);                 // finishes the 8080 command
      reg_wr(DIF_PARAM, 32'h0000_009A);                 // for the SPI command
      dif_wait_idle(5000);
      dbi_check_log(mark, "1: switch to SPI while busy");

      // 2. SPI DFILL running; PHY_SEL -> 8080; the next refresh goes to 8080
      dif_cfg(PHY_SPI, 4'd0, 1'b0, 1'b1, 1'b0);
      mark = lg_n; exp_reset;
      exp_dfill(PHY_SPI, 4, 2, 24'hE0_10_F0, 1'b0);
      exp_cmd(PHY_8080, 8'h2C, 1'b1);
      for (yy = 0; yy < 2; yy = yy + 1)
        for (xx = 0; xx < 4; xx = xx + 1)
          exp_px(PHY_8080, pix16(xx, yy));
      cs8 = m8_cs_lo_cyc;
      reg_wr(DIF_DFILL, 32'h00E0_10F0);
      repeat(20) @(posedge free_clk);
      dif_cfg(PHY_8080, 4'd0, 1'b0, 1'b1, 1'b0);
      reg_rd_mask(DIF_CFG, 32'h0, 32'h4);
      reg_rd_mask(DIF_STATUS, ST_DFILL_BUSY, ST_DFILL_BUSY);
      if (spi_cs_n !== 1'b0) tb_error("2: running SPI DFILL lost CS after the PHY_SEL write");
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      dbi_check_log(mark, "2: switch to 8080 while busy");

      // 3. idle switches: each operation only on its PHY
      cs8 = m8_cs_lo_cyc; css = ms_cs_lo_cyc;
      dif_cfg(PHY_SPI, 4'd0, 1'b1, 1'b1, 1'b0);
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      if (m8_cs_lo_cyc != cs8) tb_error("3: 8080 CS asserted during an SPI refresh");
      if (ms_cs_lo_cyc == css) tb_error("3: no SPI activity for the SPI refresh");
      cs8 = m8_cs_lo_cyc; css = ms_cs_lo_cyc;
      dif_cfg(PHY_8080, 4'd0, 1'b1, 1'b1, 1'b0);
      reg_wr(DIF_DFILL, 32'h0012_3456);
      dif_wait_idle(50000);
      if (ms_cs_lo_cyc != css) tb_error("3: SPI CS asserted during an 8080 DFILL");
      if (m8_cs_lo_cyc == cs8) tb_error("3: no 8080 activity for the 8080 DFILL");

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
