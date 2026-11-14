//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_lb_over
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_lb_over.v
// Module Description : DPI stream lines longer than the line buffer
//                      (2^DPI_LB_AW pixels; needs DIM_W > DPI_LB_AW):
//                        - a frame 2^DPI_LB_AW + 88 pixels wide shown 1:1:
//                          the panel shows the border past the line buffer
//                          (with the bilinear filter, from its last pixel,
//                          whose right neighbour is missing), UNDERFLOW set;
//                        - with DIM_W = 16 and a scaler: a 33 600-pixel line
//                          reduced 16 times onto a 2 100-pixel image (source
//                          positions up to 33 583), the border past the line
//                          buffer;
//                        - then a frame within the line buffer again: exact,
//                          no UNDERFLOW.
//                      Every stored panel pixel is checked.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT
`include "dpi_tasks.v"

localparam integer LO_LB = 1 << DPI_LB_AW;

reg [31:0] v;
integer    lo_x, lo_y, lo_sx, lo_sl, lo_bad, lo_w, lo_fil;
reg [23:0] lo_e;

// The panel's last frame: source line sl, image iw x ih at (0, 0), step stx
// (nearest unless fil at 1:1), border past the line buffer and the image
task lo_check;
   input integer sl, iw, ih, stx, fil;
   input [8*48-1:0] what;
   begin
      lo_bad = 0;
      tb_checks = tb_checks + 1;
      for (lo_y = 0; (lo_y < dpi_vact) && (lo_y < u_dpipanel.H_MAX); lo_y = lo_y + 1)
         for (lo_x = 0; (lo_x < dpi_hact) && (lo_x < u_dpipanel.W_MAX); lo_x = lo_x + 1) begin
            lo_sx = (lo_x * stx) >> 12;
            if (lo_sx > sl - 1) lo_sx = sl - 1;
            if ((lo_x >= iw) || (lo_y >= ih))
               lo_e = 24'h203040;
            else if ((((fil && (lo_sx < sl - 1)) ? lo_sx + 1 : lo_sx) >> DPI_LB_AW) != 0)
               lo_e = 24'h203040;                            // past the line buffer
            else
               lo_e = dpi_src[lo_y * sl + lo_sx];
            if (u_dpipanel.fb[lo_y * u_dpipanel.W_MAX + lo_x] !== lo_e) begin
               if (lo_bad < 5) $display("ERROR: %0s -- panel pixel (%0d,%0d) = %06h, expected %06h %t",
                                        what, lo_x, lo_y, u_dpipanel.fb[lo_y * u_dpipanel.W_MAX + lo_x], lo_e, $time);
               lo_bad = lo_bad + 1;
            end
         end
      if (lo_bad != 0) begin
         $display("ERROR: %0s -- %0d pixels differ", what, lo_bad);
         error = error + 1;
      end else
         $display("OK:    %0s (%0d x %0d panel)", what, dpi_hact, dpi_vact);
   end
endtask

task lo_show;
   input integer sl, iw, ih, stx, fil, uf;
   input [8*48-1:0] what;
   begin
      if (DPI_SCALER != 0) begin
         reg_wr(DPI_IMG_SIZE, (ih << 16) | iw);
         reg_wr(DPI_SCALE, (32'd4096 << 16) | stx);
         reg_wr(DPI_IMG_POS, 32'h0);
         reg_rd_val(DIF_CFG, v);
         reg_wr(DIF_CFG, fil ? (v | 32'h0020_0000) : (v & ~32'h0020_0000));
         reg_wr(DPI_CTRL, 32'h1);
      end
      dpi_wait_frames(3);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(1);
      lo_check(sl, iw, ih, stx, fil, what);
      reg_rd_mask(DIF_IRQ_FLAG, uf ? 32'h20 : 32'h0, 32'h20);   // UNDERFLOW: every frame with a cut line
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DPI: LINES LONGER THAN THE LINE BUFFER      |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DIM_W <= DPI_LB_AW) || (VRAM_WORDS < 38400))
         tb_skip_finish("| (needs DPI, DIM_W > DPI_LB_AW, 38 400 words)  |");

      // 1:1, a line LO_LB + 88 pixels long; the pixel clock at half the HCLK rate
      lo_w = LO_LB + 88;
      dpi_pclk_half = 2.0 * CLK_HALF;
      dpi_frame_fill(lo_w, 4, 5);
      dpi_timing(1, lo_w, 4, 2, 6, 4, 2, 1, 2);
      reg_wr(DPI_BORDER, 32'h0020_3040);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      u_dpipanel.check = 1'b1;
      lo_show(lo_w, lo_w, 4, 4096, 0, 1, "a line past the line buffer, 1:1");
      if (DPI_SCALER == 2)
         lo_show(lo_w, lo_w, 4, 4096, 1, 1, "a line past the line buffer, bilinear 1:1");

      // 33 600-pixel lines reduced 16 times (source positions above 2^15)
      if ((DIM_W >= 16) && (DPI_SCALER != 0)) begin
         dpi_pclk_half = 16.0 * CLK_HALF;
         dpi_frame_fill(33600, 2, 7);
         u_dpipanel.check = 1'b0;                          // a timing change: checked once taken
         dpi_timing(15, 2100, 4, 4, 200, 2, 1, 1, 2);
         reg_wr(DPI_CTRL, 32'h1);                          // UPDATE: taken at the next frame
         dpi_wait_frames(2);
         u_dpipanel.check = 1'b1;
         lo_show(33600, 2100, 2, 16'hFFFF, 0, 1, "a 33 600-pixel line reduced 16 times");
      end

      // within the line buffer again
      dpi_pclk_half = 2.0 * CLK_HALF;
      dpi_frame_fill(64, 4, 9);
      u_dpipanel.check = 1'b0;
      dpi_timing(1, 64, 4, 2, 6, 4, 2, 1, 2);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      lo_show(64, 64, 4, 4096, 0, 0, "a line within the line buffer");

      u_dpipanel.check = 1'b0;
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 20000);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
