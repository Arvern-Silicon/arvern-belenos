//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_wide
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_wide.v
// Module Description : Refresh at the largest geometry of the build, from the
//                      top of the VRAM, checked on the BDI pixel stream
//                      (DIF_TYPE = 0) against the backend reference:
//                        - one line of the widest DISP_SIZE width (up to
//                          65 535 pixels), one column of the tallest height,
//                          the same line walked with X and Y swapped, and a
//                          frame read with CL swap (one word per pixel);
//                        - each frame ends on the last VRAM word, so the
//                          refresh addresses reach the top of the VRAM;
//                        - a 1 bpp frame at the top of the VRAM (pixel
//                          addresses of VRAM_AW + 5 bits).
//                      Every frame is compared pixel by pixel, with the
//                      VRAM-read count. Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer WD_DMAX = (1 << DIM_W) - 1;      // largest DISP_SIZE field

integer    wd_k, wd_w, wd_h, wd_n, wd_px, wd_base, wd_words, wd_bpp;
reg  [2:0] wd_cfg, wd_mode;
reg [64*8-1:0] wd_tag;

initial
   begin
      $display(" ===============================================");
      $display("|     BACKEND: LARGEST GEOMETRY, TOP OF VRAM    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 0;

      for (wd_k = 0; wd_k < 5; wd_k = wd_k + 1) begin
         // the pixel budget: the reference log and the VRAM (16 bpp: two
         // pixels a word; CL swap reads one word per pixel)
         wd_n    = (2 * VRAM_WORDS < BKR_MAX) ? 2 * VRAM_WORDS : BKR_MAX - 1;
         wd_mode = (wd_k == 4) ? GFX_1BPP : GFX_16BPP;
         wd_bpp  = (wd_k == 4) ? 1 : 16;
         case (wd_k)
           0: begin wd_w = (WD_DMAX < wd_n) ? WD_DMAX : wd_n; wd_h = 1; wd_cfg = 3'b000; end
           1: begin wd_w = 1; wd_h = (WD_DMAX < wd_n) ? WD_DMAX : wd_n; wd_cfg = 3'b000; end
           2: begin wd_w = (WD_DMAX < wd_n) ? WD_DMAX : wd_n; wd_h = 1; wd_cfg = 3'b110; end
           3: begin wd_w = (WD_DMAX < 64) ? WD_DMAX : 64;
                    wd_h = ((wd_n / 2) / wd_w < WD_DMAX) ? (wd_n / 2) / wd_w : WD_DMAX;
                    wd_cfg = 3'b001; end
           default: begin wd_w = (WD_DMAX < 1024) ? WD_DMAX : 1024;
                    wd_h = ((BKR_MAX - 1) / wd_w < WD_DMAX) ? (BKR_MAX - 1) / wd_w : WD_DMAX;
                    if (wd_w * wd_h > 32 * VRAM_WORDS) wd_h = (32 * VRAM_WORDS) / wd_w;
                    wd_cfg = 3'b010; end
         endcase
         wd_px    = wd_w * wd_h;
         wd_words = (wd_px * wd_bpp + 31) / 32;
         // last pixel on the last bit of the VRAM
         wd_base  = (VRAM_WORDS * 32 / wd_bpp) - wd_px;
         bk_vram_rand(VRAM_WORDS - wd_words, wd_words);
         $sformat(wd_tag, "%0dx%0d %0d bpp DISP_CFG %b from pixel %0d", wd_w, wd_h, wd_bpp, wd_cfg, wd_base);
         bk_frame(wd_tag, 0, wd_base, wd_mode, wd_w, wd_h, wd_cfg, 32'h0000_F000);
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
