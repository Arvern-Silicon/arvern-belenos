//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_hd
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_hd.v
// Module Description : DPI driver at an HD panel size: a 1280 x 720 active
//                      area (blanking timed by the panel model), a 320 x 180
//                      frame scaled 4x to fill it, checked pixel by pixel;
//                      DIF_STATUS LINE read in the last lines of the frame
//                      and the SCANLINE flag on line 700. Needs DIM_W and
//                      DPI_LB_AW of 11 or more.
//----------------------------------------------------------------------------

`define VERY_LONG_TIMEOUT
`include "dpi_tasks.v"

reg     [31:0] v;
integer        k, n_hi;

initial
   begin
      $display(" ===============================================");
      $display("|               DPI: HD PANEL                   |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DIM_W < 11) || (DPI_LB_AW < 11) || (DPI_SCALER == 0) || (VRAM_WORDS < 28800))
         tb_skip_finish("| (needs DPI with a scaler, DIM_W, LB_AW >= 11)  |");

      dpi_frame_fill(320, 180, 3);
      dpi_timing(dpi_div(0), 1280, 16, 32, 32, 720, 3, 5, 20);
      reg_wr(DPI_IMG_SIZE, (720 << 16) | 1280);
      reg_wr(DPI_SCALE, (1024 << 16) | 1024);                // 4x
      reg_wr(DIF_SYNC, 700);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);

      // LINE in the last lines (the high bits of the line counter)
      while (u_dpipanel.vline != 10) @(posedge free_clk);  // in the active lines
      while (u_dpipanel.vline < 690) @(posedge free_clk);
      reg_wr(DIF_IRQ_FLAG, 32'h10);
      n_hi = 0;
      for (k = 0; k < 40; k = k + 1) begin
         repeat (600) @(posedge free_clk);
         reg_rd_val(DIF_STATUS, v);
         if ((v[28:16] + 1 < u_dpipanel.vline) || (v[28:16] > u_dpipanel.vline + 1)) begin
            $display("ERROR: DIF_STATUS LINE %0d, the panel in line %0d %t", v[28:16], u_dpipanel.vline, $time);
            error = error + 1;
         end
         if ((v[28:16] >= 700) && (v[28:16] < 720)) n_hi = n_hi + 1;
      end
      if (n_hi == 0) tb_error("LINE never read in active lines 700 to 719");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h10, 32'h10);             // SCANLINE 700 reached

      dpi_wait_frames(1);
      dpi_check_image(320, 180, 1280, 720, 0, 0, 1024, 1024, 0, 24'h0, "320 x 180 scaled 4x to 1280 x 720");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);              // no UNDERFLOW
      if (u_dpipanel.blank_checks == 0) tb_error("panel model made no blanking measurement");
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");

      u_dpipanel.check = 1'b0;
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000 * PCLK_SLOW);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
