//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_scan
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_scan.v
// Module Description : Backend scan order and unpacking, checked on the BDI
//                      pixel stream (DIF_TYPE = 0, random back-pressure)
//                      against exact RGB888 values (uarch §8, digest F.2 /
//                      F.3): every DISP_CFG combination (CL/Y/X swaps) x
//                      every bpp x non-square sizes (incl. width 1, height 1,
//                      1x1, odd widths so that lines end mid-word), word-
//                      aligned and non-aligned frame bases (the X swap then
//                      walks backwards inside a word), CL swap at 16 bpp
//                      (every pixel a new word), a larger 1 bpp frame, and
//                      DISP_SIZE fields written as 0 (stored as 1, uarch §11
//                      / §13, also on bdi_width_o / bdi_height_o), frames
//                      ending in the last VRAM word. Exact pixel count and
//                      px_last are checked by the BDI model, and the number of
//                      VRAM reads per frame equals the number of word-address
//                      changes along the scan (uarch §8 fetch rule). Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    sc_c, sc_m, sc_s, sc_b;
integer    sc_w, sc_h, sc_base;
reg [64*8-1:0] sc_tag;

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: SCAN ORDER AND UNPACKING      |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 1;
      bkm_rdy_pct_low = 20;
      bk_vram_rand(0, 512);

      for (sc_c = 0; sc_c < 8; sc_c = sc_c + 1)
        for (sc_m = 0; sc_m < 5; sc_m = sc_m + 1)
          for (sc_s = 0; sc_s < 7; sc_s = sc_s + 1) begin
             case (sc_s)
               0 : begin sc_w = 5;  sc_h = 3;  end
               1 : begin sc_w = 3;  sc_h = 6;  end
               2 : begin sc_w = 1;  sc_h = 7;  end
               3 : begin sc_w = 9;  sc_h = 1;  end
               4 : begin sc_w = 1;  sc_h = 1;  end
               5 : begin sc_w = 13; sc_h = 4;  end
               default : begin sc_w = 37; sc_h = 3; end
             endcase
             // aligned base for even sizes, odd pixel offsets otherwise
             sc_base = (sc_s[0] ? 0 : (3 + 2*sc_c)) + (sc_m << 6);
             $sformat(sc_tag, "scan cfg %0d mode %0d %0dx%0d base %0d", sc_c, sc_m, sc_w, sc_h, sc_base);
             bk_frame(sc_tag, 0, sc_base, sc_m, sc_w, sc_h, sc_c, 32'h0000_7C40);
          end

      // CL swap at 16 bpp over a bigger frame, every combination
      for (sc_c = 1; sc_c < 8; sc_c = sc_c + 2)
         bk_frame("CL swap 16 bpp 24x20", 0, 1, 3'd4, 24, 20, sc_c, 32'h0000_F000);

      // Larger 1 bpp frame, unaligned base, X+Y swap and CL+X+Y
      bk_frame("1 bpp 64x40 X+Y", 0, 29, 3'd0, 64, 40, 3'b110, 32'h0000_E100);
      bk_frame("1 bpp 64x40 CL+X+Y", 0, 29, 3'd0, 64, 40, 3'b111, 32'h0000_E100);
      bk_frame("2 bpp 50x30 X", 0, 7, 3'd1, 50, 30, 3'b100, 32'h0000_0020);

      // A frame whose last word is VRAM word VRAM_WORDS-1 (no read beyond it)
      bk_vram_rand(VRAM_WORDS - 16, 16);
      for (sc_c = 0; sc_c < 8; sc_c = sc_c + 1)
         bk_frame("frame ending at the last VRAM word", 0, 2*VRAM_WORDS - 32, 3'd4, 8, 4, sc_c, 32'h0000_F000);
      bk_frame("1 bpp frame ending at the last VRAM word", 0, 32*VRAM_WORDS - 33*5, 3'd0, 33, 5, 3'b110, 32'h0000_F000);

      // DISP_SIZE fields written as 0 are stored as 1
      reg_wr(DISP_SIZE, 32'h0000_0000);
      reg_rd(DISP_SIZE, 32'h0001_0001);
      if ((bdi_width !== 1) || (bdi_height !== 1)) tb_error("bdi_width_o/bdi_height_o not 1/1 after DISP_SIZE 0");
      reg_wr(FRAME_SEL, 0);
      reg_wr(FRAME0_PTR, 5);
      reg_wr(CTRL, {29'h0, GFX_8BPP});
      reg_wr(DISP_CFG, 0);
      reg_wr(LUT_CFG, 32'h0000_F000);
      bk_refresh(1);
      bkr_build(5, 3'd3, 1, 1, 3'b000, 32'h0000_F000);
      bkr_check_bdi("DISP_SIZE 0x0 -> 1x1");

      reg_wr(DISP_SIZE, 32'h0005_0000);         // width 0 -> 1, height 5
      reg_rd(DISP_SIZE, 32'h0005_0001);
      if ((bdi_width !== 1) || (bdi_height !== 5)) tb_error("bdi_width_o/bdi_height_o not 1/5");
      bk_refresh(5);
      bkr_build(5, 3'd3, 1, 5, 3'b000, 32'h0000_F000);
      bkr_check_bdi("DISP_SIZE 0x5 -> 1x5");

      reg_wr(DISP_SIZE, 32'h0000_0006);         // width 6, height 0 -> 1
      reg_rd(DISP_SIZE, 32'h0001_0006);
      if ((bdi_width !== 6) || (bdi_height !== 1)) tb_error("bdi_width_o/bdi_height_o not 6/1");
      reg_wr(DISP_CFG, 3'b111);
      bk_refresh(6);
      bkr_build(5, 3'd3, 6, 1, 3'b111, 32'h0000_F000);
      bkr_check_bdi("DISP_SIZE 6x0 -> 6x1, CL+X+Y");

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
