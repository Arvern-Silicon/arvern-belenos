//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_wide
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_wide.v
// Module Description : DBI driver with display sizes beyond 2047 (DIM_W of
//                      13 or more), on every PHY of the build, HW_WINDOW_EN
//                      = 1: a DIF_DFILL of 4100 x 1 and 1 x 4100 (CASET /
//                      PASET end 4099, high byte 0x10) and a 16 bpp refresh
//                      of 4100 x 1 and 1 x 4100 from the VRAM; with DIM_W 16
//                      on 8080 also a DFILL of 63489 x 1 and 1 x 63489
//                      (window end 0xF800). Every panel
//                      item is checked (window bytes, command, each pixel);
//                      the panel memory holds what fits in it (the rest is
//                      dropped by the model, not an anomaly).
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

`include "dbi_model_ext.v"

localparam integer WL = 4100;

integer    phy_i, case_i, kk, mark, w, h, nbad;
reg        phy;
reg [15:0] pa, pb;

function [15:0] pix16;
   input integer i;
   begin
      pix16 = ((i * 16'h2B5D) ^ (i >> 3) ^ 16'h9C31) & 16'hFFFF;
   end
endfunction

task wait_cmd_done;
   integer nn;
   begin
      nn = 0;
      while ((irq !== 1'b1) && (nn < 400000)) begin @(negedge free_clk); nn = nn + 1; end
      if (irq !== 1'b1) tb_error("CMD_DONE never rose after the DFILL");
      dif_wait_idle(1000);
      reg_wr(DIF_IRQ_FLAG, 32'h7);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DBI: SIZES BEYOND 2047 PIXELS          |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");
      if ((DIM_W < 13) || (VRAM_WORDS < WL / 2))
         tb_skip_finish("|     (DIM_W below 13 or VRAM too small)        |");

      reg_wr(IRQ_EN,     32'h0000_0100);
      reg_wr(DIF_IRQ_EN, 32'h0000_0001);
      reg_wr(CTRL,       {29'h0, GFX_16BPP});
      reg_wr(LUT_CFG,    32'h0000_F000);
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);
      for (kk = 0; kk < WL; kk = kk + 2) begin
         pa = pix16(kk); pb = pix16(kk + 1);
         vram_wr(2*kk, {pb, pa}, SZ_W);
      end
      u_lcd8080.wide_ok = 1'b1;
      u_lcdspi.wide_ok  = 1'b1;

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            dif_cfg(phy, 4'd0, 1'b1, 1'b1, 1'b0);
            for (case_i = 0; case_i < 2; case_i = case_i + 1) begin
               w = (case_i == 0) ? WL : 1;
               h = (case_i == 0) ? 1  : WL;
               reg_wr(DISP_SIZE, (h << 16) | w);

               // Display fill
               lg_n = 0; mark = 0; exp_reset;          // each operation from the log start
               exp_dfill(phy, w, h, 24'hC3_5A_A5, 1'b1);
               reg_wr(DIF_DFILL, 32'h00C3_5AA5);
               wait_cmd_done;
               dbi_check_log(mark, (case_i == 0) ? "DFILL 4100 x 1" : "DFILL 1 x 4100");

               // Refresh of the VRAM frame (the same pixels in both shapes)
               lg_n = 0; mark = 0; exp_reset;          // each operation from the log start
               exp_window(phy, w, h, 1'b1);
               exp_cmd(phy, 8'h2C, phy == PHY_SPI);
               for (kk = 0; kk < WL; kk = kk + 1) exp_px(phy, pix16(kk));
               reg_wr(REFRESH, 32'h0000_0001);
               reg_poll(REFRESH, 32'h1, 32'h0, 500000);
               dif_wait_idle(500000);
               dbi_check_log(mark, (case_i == 0) ? "refresh 4100 x 1" : "refresh 1 x 4100");
               nbad = 0;
               for (kk = 0; kk < 320; kk = kk + 1)
                 if (((phy == PHY_8080) ? ((case_i == 0) ? u_lcd8080.fb[kk] : u_lcd8080.fb[kk*u_lcd8080.W]) :
                                          ((case_i == 0) ? u_lcdspi.fb[kk]  : u_lcdspi.fb[kk*u_lcdspi.W])) !== pix16(kk))
                   nbad = nbad + 1;
               if (nbad != 0) begin
                  $display("ERROR: %0d panel pixels of the first 320 differ after the refresh %t", nbad, $time);
                  error = error + 1;
               end
               reg_wr(IRQ_FLAG, 32'h3);
            end
            // 8080: the largest widths and heights of a DIM_W 16 build, the
            // window end 0xF800 (upper bits 11 to 15 set)
            if ((phy == PHY_8080) && (DIM_W >= 16)) begin
               for (case_i = 0; case_i < 2; case_i = case_i + 1) begin
                  w = (case_i == 0) ? 63489 : 1;
                  h = (case_i == 0) ? 1     : 63489;
                  reg_wr(DISP_SIZE, (h << 16) | w);
                  lg_n = 0; mark = 0; exp_reset;          // the log restarts: room for 63500 items
                  exp_dfill(phy, w, h, 24'h5A_C3_3C, 1'b1);
                  reg_wr(DIF_DFILL, 32'h005A_C33C);
                  wait_cmd_done;
                  dbi_check_log(mark, (case_i == 0) ? "DFILL 63489 x 1" : "DFILL 1 x 63489");
               end
            end
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
