//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_timing_max
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_timing_max.v
// Module Description : DPI timing at the field limits (needs a scaler: the
//                      image is placed with DPI_IMG_POS):
//                        - H: 4 095 active pixels, porches and sync of
//                          1 023 (an H total of 7 164) with 2 active lines,
//                          the image at x = 3 000;
//                        - V: 4 095 active lines, porches and sync of 1 023
//                          (a V total of 7 164) with 8-pixel lines, the image
//                          at y = 3 000;
//                        - V: a total of 1 098 lines;
//                        - then a small panel with the image at (10, 4).
//                      The panel model checks every line and frame of the
//                      timing; the stored panel pixels are checked against
//                      the image rule.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT
`include "dpi_tasks.v"

reg [31:0] v;
integer    tm_x, tm_y, tm_bad;
reg [23:0] tm_e;

task tm_check;
   input integer iw, ih, x0, y0;
   input [8*48-1:0] what;
   begin
      tm_bad = 0;
      tb_checks = tb_checks + 1;
      for (tm_y = 0; (tm_y < dpi_vact) && (tm_y < u_dpipanel.H_MAX); tm_y = tm_y + 1)
         for (tm_x = 0; (tm_x < dpi_hact) && (tm_x < u_dpipanel.W_MAX); tm_x = tm_x + 1) begin
            tm_e = dpi_expect(tm_x, tm_y, 16, 8, iw, ih, x0, y0, 4096, 4096, 0, 24'h203040);
            if (u_dpipanel.fb[tm_y * u_dpipanel.W_MAX + tm_x] !== tm_e) begin
               if (tm_bad < 5) $display("ERROR: %0s -- panel pixel (%0d,%0d) = %06h, expected %06h %t",
                                        what, tm_x, tm_y, u_dpipanel.fb[tm_y * u_dpipanel.W_MAX + tm_x], tm_e, $time);
               tm_bad = tm_bad + 1;
            end
         end
      if (tm_bad != 0) begin
         $display("ERROR: %0s -- %0d pixels differ", what, tm_bad);
         error = error + 1;
      end else
         $display("OK:    %0s (%0d x %0d panel)", what, dpi_hact, dpi_vact);
   end
endtask

// New timing and image position, taken at a frame start, then checked
task tm_set;
   input integer ha, hf, hw, hb, va, vf, vw, vb, x0, y0;
   input [8*48-1:0] what;
   begin
      u_dpipanel.check = 1'b0;
      dpi_timing(dpi_div(0), ha, hf, hw, hb, va, vf, vw, vb);
      reg_wr(DPI_IMG_SIZE, (8 << 16) | 16);
      reg_wr(DPI_IMG_POS, (y0 << 16) | x0);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      tm_check(16, 8, x0, y0, what);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: TIMING AT THE FIELD LIMITS        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DPI_SCALER == 0))
         tb_skip_finish("|      (needs the DPI driver with a scaler)     |");

      dpi_frame_fill(16, 8, 3);
      dpi_timing(dpi_div(0), 40, 4, 3, 8, 20, 1, 2, 3);
      reg_wr(DPI_BORDER, 32'h0020_3040);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      dpi_wait_frames(2);

      tm_set(4095, 1023, 1023, 1023, 2, 1, 1, 1, 3000, 0, "H total 7 164, image at x = 3 000");
      tm_set(8, 1, 1, 1, 4095, 1023, 1023, 1023, 0, 3000, "V total 7 164, image at y = 3 000");
      tm_set(40, 4, 3, 8, 1050, 16, 16, 16, 10, 4, "V total 1 098, image at (10, 4)");
      tm_set(40, 4, 3, 8, 20, 1, 2, 3, 10, 4, "small panel again, image at (10, 4)");

      u_dpipanel.check = 1'b0;
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200000);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
