//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      smoke_refresh_8080
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : smoke_refresh_8080.v
// Module Description : Smoke test of a manual refresh over the 8080 PHY at
//                      16 bpp: an 8x4 frame written through the VRAM window,
//                      DIF_CFG = LCD_ON | HW_WINDOW_EN, REFRESH.START with
//                      PERIOD 0; once START self-clears and the driver is idle
//                      the ILI9341 8080 model must hold the 32 RGB565 pixels at
//                      their (x, y) inside the CASET/PASET window, with no
//                      protocol anomaly, and IRQ_FLAG.REFR_DONE set. A second
//                      refresh with DIF_SYNC.SCAN_SYNC_EN must poll the panel
//                      (Get_Scanline 0x45, scanning model) until the scan
//                      crosses SCANLINE before sending the frame. Skipped
//                      without the 8080 PHY (DIF_TYPE 2 or 3).
//----------------------------------------------------------------------------

localparam integer RF_W = 8;
localparam integer RF_H = 4;

integer    rx, ry;
reg [15:0] rexp;

function [15:0] rf_pix;                       // test pattern, RGB565
   input integer x;
   input integer y;
   begin
      rf_pix = {x[4:0], y[2:0], 3'b101, x[2:0], y[1:0]} ^ 16'h5A00;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|             SMOKE: REFRESH OVER 8080          |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_8080)
         tb_skip_finish("|       (DIF_TYPE has no 8080 PHY: 2 or 3)      |");

      // Frame 0 at pixel 0, 16 bpp: pixel (x,y) in word (y*W + x)/2, LSB first
      for (ry = 0; ry < RF_H; ry = ry + 1)
         for (rx = 0; rx < RF_W; rx = rx + 2)
            vram_wr(2*(ry*RF_W + rx), {rf_pix(rx+1, ry), rf_pix(rx, ry)}, SZ_W);

      reg_wr(CTRL,       {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE,  (RF_H << 16) | RF_W);
      reg_wr(FRAME0_PTR, 32'h0000_0000);
      reg_wr(FRAME_SEL,  32'h0000_0000);
      reg_wr(DIF_CFG,    32'h0000_1001);            // HW_WINDOW_EN, LCD_ON, 8080, CLK_DIV 0
      reg_rd_mask(DIF_CFG, 32'h0000_1001, 32'h0000_1F07);

      // Manual refresh
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH,    32'h0000_0001, 32'h0000_0000, 2000);
      reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 2000);
      reg_rd_mask(IRQ_FLAG, 32'h0000_0003, 32'h0000_0003);   // REFR_START, REFR_DONE

      // Panel model checks
      if (lcd_on !== 1'b1)                tb_error("lcd_on_o not driven high by DIF_CFG.LCD_ON");
      if (u_lcd8080.anomaly_count != 0)   tb_error("8080 panel model saw protocol anomalies");
      if (u_lcd8080.px_count != RF_W*RF_H) begin
         $display("ERROR: 8080 panel received %0d pixels / expected %0d %t", u_lcd8080.px_count, RF_W*RF_H, $time);
         error = error + 1;
      end
      if ((u_lcd8080.sc !== 0) || (u_lcd8080.ec !== RF_W-1) || (u_lcd8080.sp !== 0) || (u_lcd8080.ep !== RF_H-1)) begin
         $display("ERROR: 8080 panel window SC=%0d EC=%0d SP=%0d EP=%0d / expected 0..%0d x 0..%0d %t",
                  u_lcd8080.sc, u_lcd8080.ec, u_lcd8080.sp, u_lcd8080.ep, RF_W-1, RF_H-1, $time);
         error = error + 1;
      end
      for (ry = 0; ry < RF_H; ry = ry + 1)
         for (rx = 0; rx < RF_W; rx = rx + 1) begin
            rexp = rf_pix(rx, ry);
            if (u_lcd8080.fb[ry*u_lcd8080.W + rx] !== rexp) begin
               $display("ERROR: 8080 panel pixel (%0d,%0d) = 0x%h / expected 0x%h %t", rx, ry, u_lcd8080.fb[ry*u_lcd8080.W + rx], rexp, $time);
               error = error + 1;
            end
         end
      if (error == 0)
         $display("OK:    8080 panel holds the %0dx%0d frame", RF_W, RF_H);

      // Second refresh synchronised on the panel scanline (Get_Scanline
      // polling): the panel scans 330 lines of 500 ns; the refresh must start
      // once the scan crosses the line 20 lines ahead of the current one.
      u_lcd8080.scan_period = 500;
      u_lcd8080.scanline    = 10'd100;
      u_lcd8080.scan_auto   = 1'b1;
      // With synchroniser jitter a bus bit that changed in the cycle before
      // its sampling edge may be taken an edge late: the panel's data
      // changes as RD falls, so the 1-cycle read strobe of CLK_DIV 0 has no
      // margin there (the doc requires the panel's access time to fit in the
      // RD low time); CLK_DIV 1 gives a 3-cycle strobe
      if (SYNC_JITTER != 0) reg_wr(DIF_CFG, 32'h0000_1101);
      reg_wr(DIF_SYNC, 32'h0000_8000 | 32'd120);    // SCAN_SYNC_EN, SCANLINE 120
      reg_wr(REFRESH,  32'h0000_0001);
      reg_poll(REFRESH,    32'h0000_0001, 32'h0000_0000, 4000);
      reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 4000);
      if (u_lcd8080.rd_count < 3)       tb_error("8080 panel: no Get_Scanline read before the synchronised refresh");
      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies (scanline refresh)");
      if (u_lcd8080.px_count != 2*RF_W*RF_H) begin
         $display("ERROR: 8080 panel received %0d pixels after two frames / expected %0d %t", u_lcd8080.px_count, 2*RF_W*RF_H, $time);
         error = error + 1;
      end
      if (u_lcd8080.scanline < 10'd120)
         tb_error("8080 panel: synchronised refresh finished before the scan reached SCANLINE");
      if (error == 0)
         $display("OK:    scanline-synchronised refresh after %0d panel reads", u_lcd8080.rd_count);
      u_lcd8080.scan_auto = 1'b0;

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
