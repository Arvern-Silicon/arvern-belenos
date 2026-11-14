//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_refresh
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_size_race.v
// Module Description : DISP_SIZE written while a refresh is on its way: after the
//                      REFRESH write, during the window commands (CASET/PASET,
//                      HW_WINDOW_EN = 1, slow PHY clock). The frame must use one
//                      size throughout: the window bytes, the RAMWR pixel count
//                      and the pixels all from the size of the request; the new
//                      size applies to the next frame. Every PHY of the build.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    phy_i, kk, xx, yy, mark, nn, cnt;
reg        phy;
reg [15:0] pa, pb;
reg [23:0] lut_val [0:255];
reg [31:0] rd;
reg  [7:0] ix [0:3];

function [15:0] pix16;
   input integer x;
   input integer y;
   begin
      pix16 = ({x[4:0], y[4:0], 6'h00} ^ (x * 16'h1357) ^ (y * 16'h0BAD)) & 16'hFFFF;
   end
endfunction

function [7:0] pix8;
   input integer x;
   input integer y;
   begin
      pix8 = (x * 7 + y * 31 + 3) & 8'hFF;
   end
endfunction

task load16;
   input integer w;
   input integer h;
   begin
      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(LUT_CFG, 32'h0000_F000);
      for (yy = 0; yy < h; yy = yy + 1)
        for (xx = 0; xx < w; xx = xx + 1)
          if ((yy*w + xx) % 2 == 0) begin
             pa = pix16(xx, yy);
             pb = ((yy*w + xx + 1) < w*h) ? pix16((xx + 1) % w, yy + (xx + 1) / w) : 16'h0;
             vram_wr(2*(yy*w + xx), {pb, pa}, SZ_W);
          end
   end
endtask

task exp_frame16;
   input integer w;
   input integer h;
   begin
      for (yy = 0; yy < h; yy = yy + 1)
        for (xx = 0; xx < w; xx = xx + 1)
          exp_px(phy, pix16(xx, yy));
   end
endtask

task race;
   input integer w0;
   input integer h0;
   input integer w1;
   input integer h1;
   input [3:0]   dv;
   begin
      $display("INFO:  PHY %0s %0dx%0d, DISP_SIZE -> %0dx%0d during the window commands",
               (phy == PHY_8080) ? "8080" : "SPI", w0, h0, w1, h1);
      dif_cfg(phy, dv, 1'b1, 1'b1, 1'b0);
      reg_wr(DISP_SIZE, (h0 << 16) | w0);
      load16(w0, h0);
      mark = lg_n; exp_reset;
      exp_window(phy, w0, h0, 1'b1);
      exp_cmd(phy, 8'h2C, (phy == PHY_SPI));
      exp_frame16(w0, h0);
      reg_wr(REFRESH, 32'h0000_0001);
      // wait for the first window item on the bus, then change the size
      nn = 0;
      while ((lg_n - mark < 1) && (nn < 20000)) begin @(negedge free_clk); nn = nn + 1; end
      reg_wr(DISP_SIZE, (h1 << 16) | w1);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      dbi_check_log(mark, "size frozen for the frame");
      // the next frame uses the new size
      load16(w1, h1);
      mark = lg_n; exp_reset;
      exp_window(phy, w1, h1, 1'b1);
      exp_cmd(phy, 8'h2C, (phy == PHY_SPI));
      exp_frame16(w1, h1);
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      dbi_check_log(mark, "new size on the next frame");
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DBI: DISP_SIZE CHANGED MID-REQUEST     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);
      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            race(6, 4, 9, 3, (phy == PHY_8080) ? 4'd7 : 4'd1);
            race(9, 3, 4, 5, (phy == PHY_8080) ? 4'd7 : 4'd1);
         end
      end
      stimulus_done = 1'b1;
   end
