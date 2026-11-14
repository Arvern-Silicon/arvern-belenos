//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_prio
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_prio.v
// Module Description : DBI driver arbitration on every PHY of the build. The
//                      engine is held by a command whose single parameter is
//                      missing (CS low); meanwhile a command (NPARAM 0), a
//                      manual refresh trigger and a DFILL are queued. Once the
//                      parameter is supplied the panel must see: the held
//                      command, the DFILL, the refresh, the queued command
//                      (DFILL > refresh > command). Second part: with the
//                      engine held, the PERIOD timer fires many refresh
//                      triggers; REFRESH is cleared before the release and
//                      exactly one refresh follows (trigger latched one deep).
//                      STATUS.DIF_BUSY covers the pending trigger.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

localparam integer PW = 3;
localparam integer PH = 2;

integer    phy_i, kk, xx, yy, mark, nn;
reg        phy;
reg [15:0] pa, pb;

function [15:0] pix16;
   input integer x;
   input integer y;
   begin
      pix16 = 16'hF000 ^ (x * 16'h0421) ^ (y * 16'h3003);
   end
endfunction

task exp_refresh;
   begin
      exp_cmd(phy, 8'h2C, 1'b1);
      for (yy = 0; yy < PH; yy = yy + 1)
        for (xx = 0; xx < PW; xx = xx + 1)
          exp_px(phy, pix16(xx, yy));
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DBI: PRIORITY AND TRIGGER LATCH        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (PH << 16) | PW);
      reg_wr(FRAME0_PTR, 32'h0);
      for (kk = 0; kk < PW*PH; kk = kk + 2) begin
         pa = pix16(kk % PW, kk / PW);
         pb = pix16((kk + 1) % PW, (kk + 1) / PW);
         vram_wr(2*kk, {pb, pa}, SZ_W);
      end

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (phy == PHY_8080) ? "8080" : "SPI");
            dif_cfg(phy, 4'd1, 1'b0, 1'b1, 1'b0);

            // 1. DFILL > refresh > command
            mark = lg_n; exp_reset;
            exp_cmd(phy, 8'hC8, 1'b1); exp_par(phy, 16'h0077);
            exp_dfill(phy, PW, PH, 24'h31_62_C4, 1'b0);
            exp_refresh;
            exp_cmd(phy, 8'hC9, 1'b1);
            reg_wr(DIF_CMD, 32'h0000_01C8);             // held: its parameter is missing
            repeat(50) @(posedge free_clk);
            reg_wr(DIF_CMD, 32'h0000_00C9);             // queued command
            reg_wr(REFRESH, 32'h0000_0001);             // refresh trigger
            repeat(10) @(posedge free_clk);
            reg_wr(DIF_DFILL, 32'h0031_62C4);           // queued DFILL
            reg_rd_mask(DIF_STATUS, ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND,
                                    ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND | ST_DFILL_BUSY | ST_REFR_BUSY);
            reg_rd_mask(STATUS, 32'h0000_0008, 32'h0000_0009);
            if (lg_n - mark != 1) tb_error("items sent while the engine is held");
            reg_wr(DIF_PARAM, 32'h0000_0077);           // release
            reg_poll(REFRESH, 32'h1, 32'h0, 50000);
            dif_wait_idle(50000);
            dbi_check_log(mark, "priority DFILL > refresh > command");

            // 2. refresh trigger latched one deep
            mark = lg_n; exp_reset;
            exp_cmd(phy, 8'hCA, 1'b1); exp_par(phy, 16'h0011);
            exp_refresh;
            reg_wr(DIF_CMD, 32'h0000_01CA);             // held
            repeat(20) @(posedge free_clk);
            reg_wr(REFRESH, (32'd64 << 4) | 32'h1);     // PERIOD 64 cycles
            repeat(1500) @(posedge free_clk);           // ~20 triggers
            reg_wr(REFRESH, 32'h0000_0000);
            reg_rd_mask(STATUS, 32'h0000_0008, 32'h0000_0009);
            if (lg_n - mark != 1) tb_error("items sent while the engine is held (period mode)");
            reg_wr(DIF_PARAM, 32'h0000_0011);           // release
            dif_wait_idle(50000);
            repeat(2000) @(posedge free_clk);
            dif_wait_idle(50000);
            reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0009);
            dbi_check_log(mark, "refresh trigger latched one deep");
            reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
            reg_wr(DIF_IRQ_FLAG, 32'h7);
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
