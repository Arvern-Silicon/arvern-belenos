//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_hilo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_hilo.v
// Module Description : Refresh address paths from the top of a large VRAM
//                      back to the bottom, checked on the BDI pixel stream
//                      (DIF_TYPE = 0) against the backend reference:
//                        - a 16 bpp frame ending on the last VRAM word,
//                          with the hardware cursor (CURSOR_EN) on, its
//                          shape block just below the frame: the cursor
//                          address bits up to VRAM_AW - 1;
//                        - a 1 bpp frame of the tallest height with the
//                          largest line pitch (0xFFFF), Y swapped, ending on
//                          the last VRAM bit: the start-corner product
//                          (height - 1) x pitch takes its top bits;
//                        - then the same frames from word 0 with a small
//                          pitch, so every high address bit falls again;
//                        - a reset after the frames: REFR_PITCH and the
//                          frame configuration return to 0, and a frame
//                          from word 0 is exact after it.
//                      Every frame is compared pixel by pixel, with the
//                      VRAM-read count. Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer HB_DMAX = (1 << DIM_W) - 1;      // largest DISP_SIZE field

integer    hb_h, hb_px, hb_base, hb_words, hb_k, hb_cb;
reg [64*8-1:0] hb_tag;
reg     [31:0] hb_rd;

task hb_frame;
   input [64*8-1:0] tag;
   input integer    base, mode, w, h, cfg, pitch;
   begin
      reg_wr(REFR_PITCH, pitch);
      bkr_pitch = pitch;
      bk_frame(tag, 0, base, mode[2:0], w, h, cfg[2:0], 32'h0000_F000);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|  BACKEND: TOP OF THE VRAM, THEN WORD 0        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 0;
      hb_h = (HB_DMAX < 1023) ? HB_DMAX : 1023;

      for (hb_k = 0; hb_k < 2; hb_k = hb_k + 1) begin
         // 16 bpp, 64 x 16, pitch 0 (the frame width)
         hb_words = 64 * 16 / 2;
         hb_base  = (hb_k == 0) ? (VRAM_WORDS * 2 - 64 * 16) : 0;
         bk_vram_rand((hb_k == 0) ? (VRAM_WORDS - hb_words) : 0, hb_words);
         // the cursor: its block below the frame (128-word aligned), at the
         // top of the VRAM, then at word 1024
         hb_cb = (hb_k == 0) ? (((VRAM_WORDS - hb_words - 64) / 128) * 128) : 1024;
         if (CURSOR_EN != 0) begin
            bk_cursor_shape(hb_cb, 0);
            bk_cursor_cols(24'hFF0000, 24'h00FF00, 24'h0000FF);
            bk_cursor_set(1'b1, 20 + 10 * hb_k, 3, 2, 1, hb_cb);
         end
         $sformat(hb_tag, "16 bpp 64x16 from pixel %0d", hb_base);
         hb_frame(hb_tag, hb_base, GFX_16BPP, 64, 16, 3'b000, 0);
         if (CURSOR_EN != 0) bk_cursor_set(1'b0, 0, 0, 0, 0, 0);
         // 1 bpp, 8 x hb_h, Y swapped: pitch 0xFFFF at the top, 40 at word 0
         hb_px    = (hb_k == 0) ? ((hb_h - 1) * 65535 + 8) : ((hb_h - 1) * 40 + 8);
         hb_words = (hb_px + 31) / 32 + 1;
         hb_base  = (hb_k == 0) ? (VRAM_WORDS * 32 - hb_px) : 3;
         bk_vram_rand((hb_k == 0) ? (VRAM_WORDS - hb_words) : 0, hb_words);
         $sformat(hb_tag, "1 bpp 8x%0d Y swap pitch %0d from pixel %0d", hb_h, (hb_k == 0) ? 65535 : 40, hb_base);
         hb_frame(hb_tag, hb_base, GFX_1BPP, 8, hb_h, 3'b010, (hb_k == 0) ? 65535 : 40);
      end

      // A reset: the frame configuration (pitch included) returns to 0
      @(negedge free_clk);
      hresetn = 1'b0;
      repeat (20) @(posedge free_clk);                    // a synchronous reset needs clock edges
      @(negedge free_clk);
      hresetn = 1'b1;
      repeat (5) @(posedge free_clk);
      reg_rd(REFR_PITCH, 32'h0);
      bk_vram_rand(0, 64);
      hb_frame("16 bpp 16x8 from word 0 after a reset", 0, GFX_16BPP, 16, 8, 3'b000, 0);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
