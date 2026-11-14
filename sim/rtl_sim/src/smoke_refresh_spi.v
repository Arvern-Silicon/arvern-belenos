//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      smoke_refresh_spi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : smoke_refresh_spi.v
// Module Description : Smoke test of a manual refresh over the SPI PHY at
//                      16 bpp: an 8x4 frame written through the VRAM window,
//                      DIF_CFG = LCD_ON | HW_WINDOW_EN (| PHY_SEL with
//                      DIF_TYPE 3), REFRESH.START with PERIOD 0; once START
//                      self-clears and the driver is idle the ILI9341 4-line
//                      serial model must hold the 32 RGB565 pixels at their
//                      (x, y) inside the CASET/PASET window, with no protocol
//                      anomaly, and IRQ_FLAG.REFR_DONE set. Needs the SPI PHY
//                      (DIF_TYPE 1 or 3, its requires in run_config.json).
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
      $display("|             SMOKE: REFRESH OVER SPI           |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_SPI)
         tb_skip_finish("|       (DIF_TYPE has no SPI PHY: 1 or 3)       |");

      // Frame 0 at pixel 0, 16 bpp: pixel (x,y) in word (y*W + x)/2, LSB first
      for (ry = 0; ry < RF_H; ry = ry + 1)
         for (rx = 0; rx < RF_W; rx = rx + 2)
            vram_wr(2*(ry*RF_W + rx), {rf_pix(rx+1, ry), rf_pix(rx, ry)}, SZ_W);

      reg_wr(CTRL,       {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE,  (RF_H << 16) | RF_W);
      reg_wr(FRAME0_PTR, 32'h0000_0000);
      reg_wr(FRAME_SEL,  32'h0000_0000);
      reg_wr(DIF_CFG,    32'h0000_1005);            // HW_WINDOW_EN, PHY_SEL = SPI, LCD_ON, CLK_DIV 0
      reg_rd_mask(DIF_CFG, 32'h0000_1005, 32'h0000_1F07);  // PHY_SEL reads 1 at DIF_TYPE 1 and 3
      
      // Manual refresh
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH,    32'h0000_0001, 32'h0000_0000, 4000);
      reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 4000);
      reg_rd_mask(IRQ_FLAG, 32'h0000_0003, 32'h0000_0003);   // REFR_START, REFR_DONE

      // Panel model checks
      if (lcd_on !== 1'b1)                tb_error("lcd_on_o not driven high by DIF_CFG.LCD_ON");
      if (u_lcdspi.anomaly_count != 0)   tb_error("SPI panel model saw protocol anomalies");
      if (u_lcdspi.px_count != RF_W*RF_H) begin
         $display("ERROR: SPI panel received %0d pixels / expected %0d %t", u_lcdspi.px_count, RF_W*RF_H, $time);
         error = error + 1;
      end
      if ((u_lcdspi.sc !== 0) || (u_lcdspi.ec !== RF_W-1) || (u_lcdspi.sp !== 0) || (u_lcdspi.ep !== RF_H-1)) begin
         $display("ERROR: SPI panel window SC=%0d EC=%0d SP=%0d EP=%0d / expected 0..%0d x 0..%0d %t",
                  u_lcdspi.sc, u_lcdspi.ec, u_lcdspi.sp, u_lcdspi.ep, RF_W-1, RF_H-1, $time);
         error = error + 1;
      end
      for (ry = 0; ry < RF_H; ry = ry + 1)
         for (rx = 0; rx < RF_W; rx = rx + 1) begin
            rexp = rf_pix(rx, ry);
            if (u_lcdspi.fb[ry*u_lcdspi.W + rx] !== rexp) begin
               $display("ERROR: SPI panel pixel (%0d,%0d) = 0x%h / expected 0x%h %t", rx, ry, u_lcdspi.fb[ry*u_lcdspi.W + rx], rexp, $time);
               error = error + 1;
            end
         end
      if (error == 0)
         $display("OK:    SPI panel holds the %0dx%0d frame", RF_W, RF_H);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
