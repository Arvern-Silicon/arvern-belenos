//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_bil_full
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_bil_full.v
// Module Description : DPI bilinear scaler with full-range colours: a 16 x 8
//                      frame at 16 bpp of random RGB565 words, then of black
//                      and white checkerboards and saturated red / green /
//                      blue, each enlarged at steps with every fractional
//                      phase (x2.5, x1.5 across and x1.7 down, uneven
//                      factors), the filter on, then the same frame with the
//                      filter off again; every panel pixel checked against
//                      the rule of the programming guide (DPI_SCALER 2).
//----------------------------------------------------------------------------
`include "dpi_tasks.v"

reg [31:0] v;
integer    bf_k, bf_x, bf_y;
reg [15:0] bf_p0, bf_p1;

task bf_scale;
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
      dpi_check_image(16, 8, iw, ih, (40 - iw) / 2, (20 - ih) / 2, stx, sty, fil, 24'h203040, what);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);
   end
endtask

// The 16 x 8 frame: kind 0 random words, 1 a black / white checkerboard,
// 2 / 3 / 4 saturated red / green / blue against black, by columns
task bf_fill;
   input integer kind;
   begin
      for (bf_y = 0; bf_y < 8; bf_y = bf_y + 1)
         for (bf_x = 0; bf_x < 16; bf_x = bf_x + 2) begin
            case (kind)
              0: begin bf_p0 = $random; bf_p1 = $random; end
              1: begin bf_p0 = ((bf_x + bf_y) & 1) ? 16'hFFFF : 16'h0000; bf_p1 = ~bf_p0; end
              2: begin bf_p0 = 16'hF800; bf_p1 = 16'h0000; end
              3: begin bf_p0 = 16'h07E0; bf_p1 = 16'h0000; end
              default: begin bf_p0 = 16'h001F; bf_p1 = (bf_y & 1) ? 16'hFFFF : 16'h0000; end
            endcase
            vram_wr((bf_y * 16 + bf_x) * 2, {bf_p1, bf_p0}, SZ_W);
         end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: BILINEAR, FULL-RANGE COLOURS      |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DPI_SCALER != 2))
         tb_skip_finish("|   (needs the DPI driver with DPI_SCALER 2)    |");

      dpi_frame_fill(16, 8, 3);
      dpi_timing(dpi_div(0), 40, 4, 3, 8, 20, 1, 2, 3);
      reg_wr(DPI_BORDER, 32'h0020_3040);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);

      for (bf_k = 0; bf_k < 5; bf_k = bf_k + 1) begin
         $display("--- frame kind %0d (0 random, 1 checkerboard, 2..4 saturated R / G / B)", bf_k);
         bf_fill(bf_k);
         bf_scale(40, 20, 1638, 1638, 1, "bilinear x2.5");
         bf_scale(24, 14, 2731, 2410, 1, "bilinear x1.5 across, x1.7 down");
         bf_scale(37, 13, 1800, 2600, 1, "bilinear, uneven factors");
         bf_scale(37, 13, 1800, 2600, 0, "the same, filter off");
      end

      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
