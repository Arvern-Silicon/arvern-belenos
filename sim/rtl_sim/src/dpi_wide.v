//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_wide
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_wide.v
// Module Description : DPI driver at an HD line width (DIM_W and DPI_LB_AW
//                      at least 11): a 1280 x 4 frame at 16 bpp shown 1:1 on
//                      a 1300 x 12 panel, then (with a scaler) a 640 x 4
//                      frame scaled x2 to 1280 x 8, nearest and, with
//                      DPI_SCALER 2, bilinear; every panel pixel checked
//                      against the frame Belenos sent, no UNDERFLOW. The
//                      pixel clock runs at half the HCLK rate (CLK_DIV 1, or
//                      the separate pixel clock), the rate one source pixel
//                      per HCLK sustains.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT
`include "dpi_tasks.v"

reg [31:0] v;

initial
   begin
      $display(" ===============================================");
      $display("|               DPI: WIDE LINES                 |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DIM_W < 11) || (DPI_LB_AW < 11))
         tb_skip_finish("|  (needs DPI with DIM_W, DPI_LB_AW >= 11)      |");

      dpi_pclk_half = 2.0 * CLK_HALF;                        // separate pixel clock: half the HCLK rate
      dpi_frame_fill(1280, 4, 5);
      dpi_timing(1, 1300, 4, 2, 6, 12, 2, 1, 2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(3);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(1);
      dpi_check_image(1280, 4, 1280, 4, 10, 4, 4096, 4096, 0, 24'h0, "1280 x 4, 1:1");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);              // no UNDERFLOW

      if (DPI_SCALER != 0) begin
         dpi_frame_fill(640, 4, 9);
         reg_wr(DPI_IMG_SIZE, (8 << 16) | 1280);
         reg_wr(DPI_SCALE, (2048 << 16) | 2048);
         reg_wr(DPI_CTRL, 32'h1);
         dpi_wait_frames(3);
         reg_wr(DIF_IRQ_FLAG, 32'h78);
         dpi_wait_frames(1);
         dpi_check_image(640, 4, 1280, 8, 10, 2, 2048, 2048, 0, 24'h0, "640 x 4 scaled to 1280 x 8, nearest");
         reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);
         if (DPI_SCALER == 2) begin
            reg_rd_val(DIF_CFG, v);
            reg_wr(DIF_CFG, v | 32'h0020_0000);               // bilinear
            reg_wr(DPI_CTRL, 32'h1);
            dpi_wait_frames(3);
            reg_wr(DIF_IRQ_FLAG, 32'h78);
            dpi_wait_frames(1);
            dpi_check_image(640, 4, 1280, 8, 10, 2, 2048, 2048, 1, 24'h0, "640 x 4 scaled to 1280 x 8, bilinear");
            reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);
         end
      end
      u_dpipanel.check = 1'b0;
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
