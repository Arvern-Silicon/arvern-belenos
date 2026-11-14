//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_lut
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_lut.v
// Module Description : Backend colour path through the programmable LUT,
//                      checked on the BDI pixel stream (DIF_TYPE = 0, random
//                      back-pressure) against exact RGB888 values (uarch §5,
//                      §8, digest F.4):
//                        - SW_LUT_EN = 1 at 1/2/4/8 bpp, LUT index
//                          {REFR_BANK, value zero-extended to 8 bits}, entry
//                          RGB888 verbatim, both banks with LUT_BANKS = 2;
//                        - 16 bpp (modes 4..7) ignores SW_LUT_EN;
//                        - entries written through the LUT window (0x800 /
//                          0xC00) are the ones the backend reads;
//                        - palette double-buffering: bank 1 rewritten through
//                          the window while a bank-0 frame streams (the frame
//                          stays exact), then REFR_BANK flipped;
//                        - LUT_EN = 0: SW_LUT_EN has no effect (hardware
//                          palettes); LUT_BANKS = 1: the refresh reads bank 0
//                          whatever REFR_BANK (spec question, see notes).
//                      Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    lt_i;
integer    lt_m;
integer    lt_b;
reg [31:0] lt_v;

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: PROGRAMMABLE LUT PATH         |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 1;
      bk_lut_rand;

      // Every value of every bpp, both banks: value ramps in VRAM
      for (lt_i = 0; lt_i < 64; lt_i = lt_i + 1)
         vram_mem[lt_i] = ((4*lt_i+3) << 24) | ((4*lt_i+2) << 16) | ((4*lt_i+1) << 8) | (4*lt_i);
      for (lt_b = 0; lt_b < 2; lt_b = lt_b + 1) begin
         lt_v = 32'h0000_F001 | (lt_b << 1);
         bk_frame("LUT 8 bpp", 0, 0, 3'd3, 32, 8, 3'b000, lt_v);
      end
      bk_vram_rand(64, 64);
      for (lt_b = 0; lt_b < 2; lt_b = lt_b + 1)
         for (lt_m = 0; lt_m < 3; lt_m = lt_m + 1) begin
            lt_v = 32'h0000_A561 | (lt_b << 1);
            bk_frame("LUT 1/2/4 bpp", 0, 64 << (5 - lt_m), lt_m, 32, 4, 3'b000, lt_v);
         end
      bk_frame("LUT 8 bpp random", 0, 64*4, 3'd3, 16, 16, 3'b000, 32'h0000_0003);

      // 16 bpp ignores SW_LUT_EN
      for (lt_m = 4; lt_m < 8; lt_m = lt_m + 1)
         bk_frame("16 bpp with SW_LUT_EN", 0, 64*2, lt_m, 8, 8, 3'b000, 32'h0000_0003);

      // Entries written through the LUT window
      if (LUT_EN != 0) begin
         for (lt_i = 0; lt_i < 16; lt_i = lt_i + 1) begin
            reg_wr(LUT_BASE + 4*lt_i,          32'hAB00_0000 | (lt_i * 32'h0011_1111));
            reg_wr(LUT_BASE + 32'h400 + 4*lt_i, 32'h0000_0000 | (lt_i * 32'h0010_2030) ^ 32'h00C3_3C0F);
         end
         vram_mem[0] = 32'h7654_3210;
         vram_mem[1] = 32'hFEDC_BA98;
         bk_frame("LUT window bank 0, 4 bpp", 0, 0, 3'd2, 16, 1, 3'b000, 32'h0000_0001);
         if (lut_mem[5] !== 24'h55_5555) tb_error("LUT window write not in the LUT model");
         bk_frame("LUT window bank 1, 4 bpp", 0, 0, 3'd2, 16, 1, 3'b000, 32'h0000_0003);
      end

      // Double-buffering: bank 1 rewritten while a bank-0 frame streams slowly
      bk_vram_rand(0, 128);
      bk_config(0, 0, 3'd3, 32, 16, 3'b000, 32'h0000_0001);
      bkm_rdy_mode    = 2;
      bkm_rdy_gap     = 12;
      bkm_exp_n       = 32*16;
      lt_b            = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bkm_wait_active(500);
      for (lt_i = 0; lt_i < 64; lt_i = lt_i + 1)
         reg_wr(LUT_BASE + 32'h400 + 4*lt_i, $random(bkm_seed));
      if (bkm_frames != lt_b)
         $display("NOTE:  double-buffer frame finished before the bank-1 writes ended");
      bkm_wait_frames(lt_b + 1, 40000);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      bkr_build(0, 3'd3, 32, 16, 3'b000, 32'h0000_0001);
      bkr_check_bdi("bank-0 frame during bank-1 window writes");
      bkm_rdy_mode = 1;
      bk_frame("flipped to bank 1", 0, 0, 3'd3, 32, 16, 3'b000, 32'h0000_0003);

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
