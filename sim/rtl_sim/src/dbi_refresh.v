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
// File Name          : dbi_refresh.v
// Module Description : DBI driver refresh on every PHY of the build: manual
//                      refreshes of a 16 bpp frame with HW_WINDOW_EN = 1
//                      (CASET 0..w-1 / PASET 0..h-1, then 0x2C; one CS frame
//                      on 8080, three on SPI; also a 320 x 2 window, CASET
//                      end column 319, with the panel memory checked) and
//                      0 (0x2C only), and of an
//                      8 bpp SW-LUT frame whose 24-bit LUT colours check the
//                      RGB888 -> RGB565 truncation of the stream. Item by
//                      item comparison; 8080 pixel period exactly
//                      2(CLK_DIV+1) (CLK_DIV 0, 1, 3), no bubble between SPI
//                      pixel bytes. refresh_active (IRQ_FLAG.REFR_START /
//                      REFR_DONE through irq_o): rises only once the window
//                      commands are out and before any pixel, falls only
//                      after the last pixel left the PHY; STATUS bit 0 low
//                      during the window commands. A refresh never sets
//                      CMD_DONE.
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

// Manual refresh, wait for START to self-clear and the driver to go idle
task do_refresh;
   begin
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
   end
endtask

task refresh16;
   input integer w;
   input integer h;
   input         hwin;
   input [3:0]   dv;
   begin
      $display("INFO:  PHY %0s refresh 16 bpp %0dx%0d HW_WINDOW_EN %0d CLK_DIV %0d",
               (phy == PHY_8080) ? "8080" : "SPI", w, h, hwin, dv);
      dif_cfg(phy, dv, hwin, 1'b1, 1'b0);
      reg_wr(DISP_SIZE, (h << 16) | w);
      load16(w, h);
      mark = lg_n; exp_reset;
      if (hwin) exp_window(phy, w, h, 1'b1);
      exp_cmd(phy, 8'h2C, (phy == PHY_SPI) || !hwin);
      exp_frame16(w, h);
      reg_wr(DIF_IRQ_FLAG, 32'h7);
      do_refresh;
      dbi_check_log(mark, "refresh 16 bpp");
      reg_rd(DIF_IRQ_FLAG, 32'h0);                       // no CMD_DONE for a refresh
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|                 DBI: REFRESH                  |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);
      reg_wr(DIF_IRQ_EN, 32'h0000_0001);                 // CMD_DONE armed: must stay 0

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            refresh16(5, 3, 1'b1, 4'd0);
            refresh16(5, 3, 1'b0, 4'd0);
            refresh16(16, 12, 1'b1, 4'd0);
            // A landscape window: CASET end column 319 (high byte 1), and
            // the panel memory holds the frame
            refresh16(320, 2, 1'b1, 4'd0);
            nn = 0;
            for (yy = 0; yy < 2; yy = yy + 1)
              for (xx = 0; xx < 320; xx = xx + 1)
                if (((phy == PHY_8080) ? u_lcd8080.fb[yy*u_lcd8080.W + xx] : u_lcdspi.fb[yy*u_lcdspi.W + xx]) !== pix16(xx, yy))
                  nn = nn + 1;
            if (nn != 0) begin
               $display("ERROR: %0d panel pixels of the 320x2 refresh differ %t", nn, $time);
               error = error + 1;
            end
            refresh16(4, 3, 1'b1, 4'd1);
            if (phy == PHY_8080) refresh16(3, 2, 1'b1, 4'd3);

            // 8 bpp through the SW LUT: RGB888 -> RGB565 truncation
            if (LUT_EN != 0) begin
               $display("INFO:  PHY %0s refresh 8 bpp SW LUT 8x4", (phy == PHY_8080) ? "8080" : "SPI");
               for (kk = 0; kk < 256; kk = kk + 1) begin
                  lut_val[kk] = ((kk * 24'h9E3779) ^ (kk << 3) ^ 24'h5A5A5A) & 24'hFFFFFF;
                  reg_wr(LUT_BASE + 4*kk, {8'h00, lut_val[kk]});
               end
               reg_wr(CTRL, {29'h0, GFX_8BPP});
               reg_wr(LUT_CFG, 32'h0000_F001);           // SW_LUT_EN, bank 0
               reg_wr(DISP_SIZE, (4 << 16) | 8);
               for (yy = 0; yy < 4; yy = yy + 1)
                 for (xx = 0; xx < 8; xx = xx + 4)
                   vram_wr(yy*8 + xx, {pix8(xx+3,yy), pix8(xx+2,yy), pix8(xx+1,yy), pix8(xx,yy)}, SZ_W);
               dif_cfg(phy, 4'd0, 1'b1, 1'b1, 1'b0);
               mark = lg_n; exp_reset;
               exp_window(phy, 8, 4, 1'b1);
               exp_cmd(phy, 8'h2C, (phy == PHY_SPI));
               for (yy = 0; yy < 4; yy = yy + 1)
                 for (xx = 0; xx < 8; xx = xx + 1)
                   exp_px(phy, rgb565(lut_val[pix8(xx, yy)]));
               do_refresh;
               dbi_check_log(mark, "refresh 8 bpp SW LUT");
               reg_rd(DIF_IRQ_FLAG, 32'h0);
            end

            // refresh_active window: REFR_START / REFR_DONE edges
            dif_cfg(phy, (phy == PHY_8080) ? 4'd15 : 4'd3, 1'b1, 1'b1, 1'b0);
            reg_wr(DISP_SIZE, (2 << 16) | 3);
            load16(3, 2);
            reg_wr(IRQ_FLAG, 32'h3);
            reg_wr(IRQ_EN,   32'h0000_0002);             // REFR_START
            mark = lg_n;
            reg_wr(REFRESH, 32'h0000_0001);
            // during the window commands: not active
            nn = 0;
            while ((lg_n - mark < 2) && (nn < 20000)) begin @(negedge free_clk); nn = nn + 1; end
            reg_rd_mask(STATUS, 32'h0, 32'h1);
            reg_rd_mask(IRQ_FLAG, 32'h0, 32'h3);
            reg_rd_mask(DIF_STATUS, ST_BUSY, ST_BUSY);
            nn = 0;
            while ((irq !== 1'b1) && (nn < 50000)) begin @(negedge free_clk); nn = nn + 1; end
            cnt = lg_n - mark;
            if (irq !== 1'b1) tb_error("REFR_START never raised");
            // refresh_active rises as the PHY takes the last PASET parameter
            // (item 10), which may still be on the wire: after 9 or 10
            // completed items, never after a pixel.
            if ((cnt < 9) || (cnt > 10)) begin
               $display("ERROR: REFR_START raised after %0d panel items (expected 9..10: 0x2C handed over during window item 10) %t", cnt, $time);
               error = error + 1;
            end
            reg_rd_mask(STATUS, 32'h1, 32'h1);
            reg_rd_mask(DIF_STATUS, ST_REFR_BUSY, ST_REFR_BUSY);
            reg_wr(IRQ_EN,   32'h0000_0001);             // REFR_DONE
            repeat(2) @(negedge free_clk);
            if ((irq === 1'b1) && (lg_n - mark < 11)) tb_error("REFR_DONE already set before the 0x2C");
            nn = 0;
            while ((irq !== 1'b1) && (nn < 50000)) begin @(negedge free_clk); nn = nn + 1; end
            cnt = lg_n - mark;
            if (irq !== 1'b1) tb_error("REFR_DONE never raised");
            if (cnt != 11 + ((phy == PHY_SPI) ? 12 : 6)) begin
               $display("ERROR: REFR_DONE raised after %0d / %0d panel items %t", cnt, 11 + ((phy == PHY_SPI) ? 12 : 6), $time);
               error = error + 1;
            end
            reg_wr(IRQ_EN, 32'h0);
            reg_poll(REFRESH, 32'h1, 32'h0, 50000);
            dif_wait_idle(50000);
            reg_rd_mask(STATUS, 32'h0, 32'h1);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            reg_wr(IRQ_FLAG, 32'h3);
         end
      end

      if (HAS_8080 && (m8_px_pairs == 0)) tb_error("8080 pixel-period check never exercised");
      if (HAS_SPI  && (ms_px_bounds == 0)) tb_error("SPI pixel-byte check never exercised");
      $display("INFO:  pixel-rate checks: %0d 8080 pixel pairs, %0d SPI pixel-byte boundaries", m8_px_pairs, ms_px_bounds);
      if (m8_px_gap_bad != 0) tb_error("8080: refresh pixel period != 2(CLK_DIV+1)");
      if (ms_px_gap_bad != 0) tb_error("SPI: bubble between refresh pixel bytes");
      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
