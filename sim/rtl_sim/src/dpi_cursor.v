//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_cursor
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_cursor.v
// Module Description : Hardware cursor through the DPI driver (DIF_TYPE 4, and
//                      5: HDMI): the frame Belenos sends carries the cursor in
//                      source pixels (the captured stream against the
//                      reference of bk_ref.v), and the panel shows that frame
//                      scaled and placed (dpi_check_image: the cursor scaled
//                      with the image, never on the border): 1:1 centred,
//                      nearest x2, bilinear x2 (DPI_SCALER = 2), the cursor
//                      moved between frames, a CL-swapped frame, pixel
//                      doubling; DPI_CTRL.TEST bars show no cursor colour.
//                      Panel timing checked by the model.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"
`include "dpi_tasks.v"

localparam integer DQ_BLK = 256;           // shape block (the 16x8 frame is words 0-63)
localparam integer DQ_W   = 16;
localparam integer DQ_H   = 8;

reg     [31:0] dq_v;
integer        dq_i, dq_bad, dq_k;
reg     [64*8-1:0] dq_tag;

// The last complete frame sent against the reference (w x h panel stream)
task dq_check_src;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input [64*8-1:0] tag;
   begin
      bkr_build(0, 3'd4, w, h, cfg, 32'h0000_F000);
      dq_bad = 0;
      tb_checks = tb_checks + 1;
      if (dpi_src_len != bkr_n) begin
         $display("ERROR: %0s -- %0d pixels sent / expected %0d %t", tag, dpi_src_len, bkr_n, $time);
         error = error + 1;
      end
      for (dq_i = 0; (dq_i < bkr_n) && (dq_i < dpi_src_len); dq_i = dq_i + 1)
         if (dpi_src[dq_i] !== bkr_exp[dq_i]) begin
            if (dq_bad < 5) $display("ERROR: %0s -- pixel %0d = %06h, expected %06h %t", tag, dq_i, dpi_src[dq_i], bkr_exp[dq_i], $time);
            dq_bad = dq_bad + 1;
         end
      error = error + dq_bad;
      if (dq_bad == 0) $display("OK:    %0s -- %0d pixels sent, %0d under the cursor", tag, bkr_n, bkr_cur_n);
      if (bkr_cur_n == 0) tb_error("the cursor is not in the frame");
   end
endtask

task dq_scale;
   input integer iw, ih, stx, sty, fil;
   input [8*48-1:0] what;
   begin
      reg_wr(DPI_IMG_SIZE, (ih << 16) | iw);
      reg_wr(DPI_SCALE, (sty << 16) | stx);
      reg_rd_val(DIF_CFG, dq_v);
      reg_wr(DIF_CFG, fil ? (dq_v | 32'h0020_0000) : (dq_v & ~32'h0020_0000));
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(3);
      dpi_check_image(DQ_W, DQ_H, iw, ih, (40 - iw) / 2, (20 - ih) / 2, stx, sty, fil, 24'h203040, what);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     HARDWARE CURSOR THROUGH THE DPI DRIVER    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|      (needs the DPI driver: DIF_TYPE 4 or 5)  |");

      dpi_frame_fill(DQ_W, DQ_H, 3);
      bk_cursor_shape(DQ_BLK, 1);
      bk_cursor_cols(24'h123456, 24'hFEDCBA, 24'h0A0B0C);
      bk_cursor_set(1'b1, 5, 3, 2, 1, DQ_BLK);
      dpi_timing(dpi_div(0), 40, 4, 3, 8, 20, 1, 2, 3);
      reg_wr(DPI_BORDER, 32'h0020_3040);
      reg_rd_val(DIF_CFG, dq_v);
      reg_wr(DIF_CFG, dq_v | 32'h9);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(3);

      // 1:1, centred: the stream and the panel
      dq_check_src(DQ_W, DQ_H, 3'b000, "DPI stream, cursor at (5,3) hot (2,1)");
      dq_scale(DQ_W, DQ_H, 4096, 4096, 0, "panel 1:1 centred");
      if (DPI_SCALER != 0) begin
         dq_scale(32, 16, 2048, 2048, 0, "panel nearest x2");
         if (DPI_SCALER == 2)
            dq_scale(32, 16, 2048, 2048, 1, "panel bilinear x2");
         dq_scale(DQ_W, DQ_H, 4096, 4096, 0, "panel 1:1 again");
      end

      // Moved, then across the bottom-right corner
      for (dq_k = 0; dq_k < 2; dq_k = dq_k + 1) begin
         bk_cursor_set(1'b1, dq_k ? 11 : -20, dq_k ? 3 : -1, 0, 0, DQ_BLK);
         dpi_wait_frames(3);
         $sformat(dq_tag, "DPI stream, cursor moved to (%0d,%0d)", bkr_cur_x, bkr_cur_y);
         dq_check_src(DQ_W, DQ_H, 3'b000, dq_tag);
         dpi_check_image(DQ_W, DQ_H, DQ_W, DQ_H, (40 - DQ_W) / 2, (20 - DQ_H) / 2, 4096, 4096, 0, 24'h203040, "panel, cursor moved");
      end

      // CL swap (the column copy, a different shape) and pixel doubling of the source
      bk_cursor_set(1'b1, 3, 2, 0, 0, DQ_BLK);
      reg_wr(DISP_SIZE, (DQ_W << 16) | DQ_H);
      reg_wr(DISP_CFG, 32'h0000_0003);
      dpi_wait_frames(3);
      dq_check_src(DQ_H, DQ_W, 3'b011, "DPI stream, CL + Y swap");
      reg_wr(DISP_CFG, 32'h0000_0000);
      reg_wr(DISP_SIZE, (DQ_H << 16) | DQ_W);
      bkr_dbl = 1'b1;
      reg_wr(DISP_CFG, 32'h0000_0010);
      bk_cursor_set(1'b1, 4, 1, 0, 0, DQ_BLK);
      dpi_wait_frames(3);
      dq_check_src(DQ_W, DQ_H, 3'b000, "DPI stream, PIX_DOUBLE");
      bkr_dbl = 1'b0;
      reg_wr(DISP_CFG, 32'h0000_0000);
      dpi_wait_frames(2);

      // Test bars: the cursor is not shown
      reg_wr(DPI_CTRL, 32'h3);
      dpi_wait_frames(3);
      dq_bad = 0;
      tb_checks = tb_checks + 1;
      for (dq_i = 0; dq_i < 40 * 20; dq_i = dq_i + 1)
         if ((u_dpipanel.fb[(dq_i / 40)*u_dpipanel.W_MAX + (dq_i % 40)] === 24'h123456) ||
             (u_dpipanel.fb[(dq_i / 40)*u_dpipanel.W_MAX + (dq_i % 40)] === 24'hFEDCBA) ||
             (u_dpipanel.fb[(dq_i / 40)*u_dpipanel.W_MAX + (dq_i % 40)] === 24'h0A0B0C)) dq_bad = dq_bad + 1;
      if (dq_bad != 0) tb_error("a cursor colour on the panel with the test bars");
      else $display("OK:    test bars: no cursor colour on the panel");
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);

      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, dq_v);
      reg_wr(DIF_CFG, dq_v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
