//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_cursor_orient
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_cursor_orient.v
// Module Description : Hardware cursor in source-frame coordinates under every
//                      scan order, on the BDI pixel stream (DIF_TYPE = 0,
//                      random back-pressure), against the reference of
//                      bk_ref.v:
//                        - the 8 DISP_CFG combinations x positions inside,
//                          across each edge and corner, off-screen and
//                          negative, with a hotspot, on landscape, portrait
//                          and odd sizes, 1, 8 and 16 bpp;
//                        - the column copy (+64) is the one read with CL: its
//                          block holds a different shape there;
//                        - pixel doubling: even and odd sizes, every swap, the
//                          cursor across the odd last line / column (sent
//                          once), a 1-pixel source frame;
//                        - the VRAM reads of every frame: one per word change
//                          of the scan, two per panel scan line crossing the
//                          cursor (a doubled line read again).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer CO_BLK = 768;           // shape block: rows and a different column copy

integer    co_c, co_s, co_p, co_w, co_h, co_x, co_y, co_m, co_d, co_hx, co_hy;
reg [64*8-1:0] co_tag;

function co_fits;
   input integer w;
   input integer h;
   begin
      co_fits = (w < (1 << DIM_W)) && (h < (1 << DIM_W));
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|     HARDWARE CURSOR: ORIENTATIONS, DOUBLING   |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en          = 1'b1;
      bk_chk_reads    = 1'b1;
      bkm_rdy_mode    = 1;
      bkm_rdy_pct_low = 15;
      bk_vram_rand(0, 768);
      bk_cursor_shape(CO_BLK, 1);
      bk_cursor_cols(24'hF0F0F0, 24'h0F0F0F, 24'h808080);

      for (co_d = 0; co_d < 2; co_d = co_d + 1) begin
         bkr_dbl = co_d;
         for (co_s = 0; co_s < 4; co_s = co_s + 1)
           for (co_c = 0; co_c < 8; co_c = co_c + 1)
             for (co_p = 0; co_p < 9; co_p = co_p + 1) begin
                case (co_s)                     // DISP_SIZE (the source frame is half with doubling)
                  0 : begin co_w = 40; co_h = 26; co_m = 4; end
                  1 : begin co_w = 23; co_h = 41; co_m = 3; end
                  2 : begin co_w = 61; co_h = 35; co_m = 0; end
                  default : begin co_w = 37; co_h = 3; co_m = 4; end
                endcase
                // positions in the source frame (sw x sh)
                case (co_p)
                  0 : begin co_x = 4;   co_y = 2;   co_hx = 0;  co_hy = 0;  end
                  1 : begin co_x = -9;  co_y = 3;   co_hx = 0;  co_hy = 0;  end
                  2 : begin co_x = ((bkr_dbl ? (co_w+1)/2 : co_w)) - 7; co_y = 1; co_hx = 0; co_hy = 0; end
                  3 : begin co_x = 2;   co_y = -17; co_hx = 0;  co_hy = 0;  end
                  4 : begin co_x = 5;   co_y = ((bkr_dbl ? (co_h+1)/2 : co_h)) - 2; co_hx = 0; co_hy = 0; end
                  5 : begin co_x = -20; co_y = -25; co_hx = 0;  co_hy = 0;  end
                  6 : begin co_x = 50;  co_y = 50;  co_hx = 31; co_hy = 31; end
                  7 : begin co_x = 6;   co_y = 9;   co_hx = 13; co_hy = 4;  end
                  default : begin co_x = -40; co_y = 3; co_hx = 0; co_hy = 0; end
                endcase
                bk_cursor_set(1'b1, co_x, co_y, co_hx, co_hy, CO_BLK);
                $sformat(co_tag, "%0scfg %0d %0dx%0d mode %0d at (%0d,%0d) hot (%0d,%0d)", bkr_dbl ? "PIX_DOUBLE " : "",
                         co_c, co_w, co_h, co_m, co_x, co_y, co_hx, co_hy);
                if (co_fits(co_w, co_h))
                   bk_frame(co_tag, 0, 3 + co_c, co_m, co_w, co_h, co_c, 32'h0000_F000);
             end
      end

      // Doubling: a 1x1 source frame and a 2x2 panel, every swap
      bkr_dbl = 1'b1;
      for (co_c = 0; co_c < 8; co_c = co_c + 1) begin
         bk_cursor_set(1'b1, -31 + co_c, 0, 0, 0, CO_BLK);
         $sformat(co_tag, "PIX_DOUBLE cfg %0d 1x1 panel", co_c);
         bk_frame(co_tag, 0, 7, 3'd4, 1, 1, co_c, 32'h0000_F000);
         $sformat(co_tag, "PIX_DOUBLE cfg %0d 2x3 panel", co_c);
         bk_frame(co_tag, 0, 7, 3'd4, 2, 3, co_c, 32'h0000_F000);
      end
      bkr_dbl = 1'b0;

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
