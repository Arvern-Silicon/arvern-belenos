//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_scale
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_scale.v
// Module Description : DPI driver scaling, checked pixel by pixel against the
//                      frame Belenos sent: nearest neighbour x1.5 / x2,
//                      reductions by 2, 1.5 and 3 (skipped source lines
//                      freed early) and a reduction past the frame's last
//                      line (clamped); with DPI_SCALER = 2 bilinear x2.5, and a mix (bilinear
//                      across, nearest down for a step above 1.0); a
//                      reduction by 8 with an odd vertical step from a
//                      24-line frame, then 1:1 again. The new image is
//                      taken at a frame start (UPDATE). Panel timing checked
//                      by the model, no UNDERFLOW.
//----------------------------------------------------------------------------

`include "dpi_tasks.v"

reg [31:0] v;
integer    sc_sn;                                     // source lines of the frame

task scale;
   input integer iw, ih, stx, sty, fil;
   input [8*48-1:0] what;
   begin
      reg_wr(DPI_IMG_SIZE, (ih << 16) | iw);
      reg_wr(DPI_SCALE, (sty << 16) | stx);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, fil ? (v | 32'h0020_0000) : (v & ~32'h0020_0000));
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(3);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(1);
      dpi_check_image(16, sc_sn, iw, ih, (40 - iw) / 2, (20 - ih) / 2, stx, sty, fil, 24'h203040, what);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|               DPI: SCALING                    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DPI_SCALER == 0))
         tb_skip_finish("|      (needs the DPI driver with a scaler)     |");

      sc_sn = 8;
      dpi_frame_fill(16, sc_sn, 3);
      dpi_timing(dpi_div(0), 40, 4, 3, 8, 20, 1, 2, 3);
      reg_wr(DPI_BORDER, 32'h0020_3040);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);

      scale(24, 16, 2731, 2048, 0, "nearest x1.5 / x2");
      scale(8, 4, 8192, 8192, 0, "nearest reduction by 2");
      scale(10, 5, 6144, 6144, 0, "nearest reduction by 1.5");
      scale(5, 3, 12288, 12288, 0, "nearest reduction by 3");
      scale(8, 6, 8192, 8192, 0, "reduction by 2 past the last line");
      scale(37, 13, 1800, 2600, 0, "nearest, uneven factors");
      if (DPI_SCALER == 2) begin
         scale(40, 20, 1638, 1638, 1, "bilinear x2.5");
         scale(40, 4, 1638, 8192, 1, "bilinear across, nearest down");
         scale(16, 8, 4096, 4096, 1, "bilinear at 1:1");
      end else begin
         reg_wr(DIF_CFG, v | 32'h0020_0009);
         reg_rd_mask(DIF_CFG, 32'h0, 32'h0020_0000);           // FILTER not writable
      end
      // A step of 8 lines (odd: 8 + 1/4096) inside a frame of more than 8
      // lines, the last image line clamped to the frame's last (the source
      // streams 8 lines per panel line: a pixel clock 4 times slower), then
      // 1:1 on the 8-line frame again
      sc_sn = 24;
      dpi_frame_fill(16, sc_sn, 3);
      dpi_timing(dpi_div(3), 40, 4, 3, 8, 20, 1, 2, 3);
      scale(24, 4, 4096, 32769, 0, "nearest reduction by 8, odd step");
      sc_sn = 8;
      dpi_frame_fill(16, sc_sn, 3);
      scale(16, 8, 4096, 4096, 0, "back to 1:1 from the 8-line frame");

      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
