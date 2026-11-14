//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_cursor_basic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_cursor_basic.v
// Module Description : Hardware cursor on the BDI pixel stream (DIF_TYPE = 0,
//                      random back-pressure), against the reference of
//                      bk_ref.v (the shape over the source-frame pixels of
//                      the box, read from the VRAM block): shape decode (2
//                      bpp LSB first, 0 transparent, 1-3 the RGB888 colours,
//                      no LUT), CURSOR_CTRL.EN off and on, the hotspot (the
//                      shape's top-left at POS - HOT), every GFX_MODE with the
//                      hardware tables and the SW LUT (both banks) under it,
//                      the cursor at each edge and corner, wholly off-screen
//                      and at negative positions, a frame smaller than the
//                      cursor, two shape blocks (CURSOR_ADDR), REFR_PITCH.
//                      Every frame also checks the VRAM reads: one per word
//                      change of the scan plus two per scan line crossing
//                      the cursor.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer CB_BLK0 = 640;          // shape blocks (128-word aligned), frames below
localparam integer CB_BLK1 = 768;

integer    cb_m, cb_l, cb_p, cb_w, cb_h, cb_x, cb_y, cb_hx, cb_hy;
reg [31:0] cb_lut;
reg [64*8-1:0] cb_tag;

function cb_fits;
   input integer w;
   input integer h;
   begin
      cb_fits = (w < (1 << DIM_W)) && (h < (1 << DIM_W));
   end
endfunction

task cb_frame;
   input [64*8-1:0] tag;
   input integer    base;
   input      [2:0] mode;
   input integer    w;
   input integer    h;
   input      [2:0] cfg;
   input     [31:0] lutcfg;
   begin
      if (cb_fits(w, h)) bk_frame(tag, 0, base, mode, w, h, cfg, lutcfg);
      else $display("NOTE:  %0s -- %0dx%0d does not fit DIM_W %0d: skipped", tag, w, h, DIM_W);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        HARDWARE CURSOR: SHAPE, COLOURS, EN    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en          = 1'b1;
      bk_chk_reads    = 1'b1;
      bkm_rdy_mode    = 1;
      bkm_rdy_pct_low = 20;
      bk_vram_rand(0, 640);
      bk_lut_rand;
      bk_cursor_shape(CB_BLK0, 0);
      bk_cursor_shape(CB_BLK1, 0);
      bk_cursor_cols(24'hFF0000, 24'h00FF00, 24'h0000FF);

      // EN = 0: nothing shows, no cursor read
      bk_cursor_set(1'b0, 10, 8, 0, 0, CB_BLK0);
      cb_frame("EN = 0", 1, 3'd4, 40, 30, 3'b000, 32'h0000_F000);
      // EN = 1, hotspot 0
      bk_cursor_set(1'b1, 10, 8, 0, 0, CB_BLK0);
      cb_frame("EN = 1 at (10,8)", 1, 3'd4, 40, 30, 3'b000, 32'h0000_F000);
      // the hotspot moves the shape, not the position
      bk_cursor_set(1'b1, 10, 8, 5, 7, CB_BLK0);
      cb_frame("hotspot (5,7)", 1, 3'd4, 40, 30, 3'b000, 32'h0000_F000);
      bk_cursor_set(1'b1, 40, 29, 31, 31, CB_BLK0);
      cb_frame("hotspot (31,31) at (40,29)", 1, 3'd4, 40, 30, 3'b000, 32'h0000_F000);
      // the second block
      bk_cursor_set(1'b1, 3, 2, 0, 0, CB_BLK1);
      cb_frame("CURSOR_ADDR block 1", 1, 3'd4, 40, 30, 3'b000, 32'h0000_F000);
      // other colours (applied at once)
      bk_cursor_cols(24'h123456, 24'hFEDCBA, 24'h000001);
      cb_frame("colours changed", 1, 3'd4, 40, 30, 3'b000, 32'h0000_F000);

      // Every GFX_MODE, hardware tables and the SW LUT (both banks)
      for (cb_m = 0; cb_m < 8; cb_m = cb_m + 1)
        for (cb_l = 0; cb_l < 2; cb_l = cb_l + 1)
          if ((cb_l == 0) || ((cb_m < 4) && (LUT_EN != 0))) begin
             cb_lut = cb_l ? ((cb_m[0] && (LUT_BANKS == 2)) ? 32'h0000_0003 : 32'h0000_0001) : 32'h0000_9E40;
             if (cb_l) bk_cursor_set(1'b1, 20 - cb_m, 3 + cb_m, 2, 1, CB_BLK0);
             else      bk_cursor_set(1'b1, 7 + cb_m, 11 - cb_m, 0, 3, CB_BLK1);
             $sformat(cb_tag, "mode %0d %0s", cb_m, cb_l ? "SW LUT" : "HW tables");
             cb_frame(cb_tag, 2 + cb_m, cb_m, 35, 27, 3'b000, cb_lut);
          end

      // Edges, corners, off-screen, negative positions (16 bpp 40x30)
      for (cb_p = 0; cb_p < 14; cb_p = cb_p + 1) begin
         case (cb_p)
           0  : begin cb_x = -10; cb_y =   5; end      // left edge
           1  : begin cb_x =  25; cb_y =   5; end      // right edge
           2  : begin cb_x =   4; cb_y = -20; end      // top edge
           3  : begin cb_x =   4; cb_y =  12; end      // bottom edge
           4  : begin cb_x = -31; cb_y = -31; end      // the corner pixel only
           5  : begin cb_x =  39; cb_y =  29; end      // the last pixel only
           6  : begin cb_x = -32; cb_y =   0; end      // just off on the left
           7  : begin cb_x =  40; cb_y =   0; end      // just off on the right
           8  : begin cb_x =   0; cb_y =  30; end      // just off below
           9  : begin cb_x = -32768; cb_y = -32768; end
           10 : begin cb_x =  32767; cb_y =  32767; end
           11 : begin cb_x =  -5; cb_y =  -7; end
           12 : begin cb_x =  20; cb_y = -31; end
           default : begin cb_x = 0; cb_y = 0; end
         endcase
         bk_cursor_set(1'b1, cb_x, cb_y, 0, 0, CB_BLK0);
         $sformat(cb_tag, "position (%0d,%0d)", cb_x, cb_y);
         cb_frame(cb_tag, 0, 3'd4, 40, 30, 3'b000, 32'h0000_F000);
      end
      // the hotspot takes the box past the left / top edges
      bk_cursor_set(1'b1, 3, 2, 20, 30, CB_BLK0);
      cb_frame("hotspot past the top-left corner", 0, 3'd4, 40, 30, 3'b000, 32'h0000_F000);

      // A frame smaller than the cursor, 1x1 and 1-pixel lines
      bk_cursor_set(1'b1, -3, -2, 0, 0, CB_BLK1);
      cb_frame("frame 20x12, cursor larger", 0, 3'd4, 20, 12, 3'b000, 32'h0000_F000);
      bk_cursor_set(1'b1, 0, 0, 0, 0, CB_BLK1);
      cb_frame("frame 1x1", 0, 3'd4, 1, 1, 3'b000, 32'h0000_F000);
      cb_frame("frame 1x9", 0, 3'd3, 1, 9, 3'b000, 32'h0000_F000);
      cb_frame("frame 9x1", 0, 3'd3, 9, 1, 3'b000, 32'h0000_F000);

      // REFR_PITCH: the cursor is relative to the frame sent
      bkr_pitch = 64;
      reg_wr(REFR_PITCH, 32'd64);
      bk_cursor_set(1'b1, 30, 4, 0, 0, CB_BLK0);
      cb_frame("REFR_PITCH 64, frame 50x20", 5, 3'd3, 50, 20, 3'b000, 32'h0000_F000);
      bkr_pitch = 0;
      reg_wr(REFR_PITCH, 32'd0);

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
