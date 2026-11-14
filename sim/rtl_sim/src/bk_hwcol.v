//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_hwcol
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_hwcol.v
// Module Description : Backend colour path with the hardware palettes, checked
//                      on the BDI pixel stream (DIF_TYPE = 0, BDI model with
//                      random back-pressure) against the exact RGB888 values
//                      (uarch §0 / §8, digest F.3 / F.4):
//                        - 16 bpp RGB565 expansion, GFX_MODE 4 and 5..7;
//                        - 8 bpp RGB332 (top bits repeated), all 256 values;
//                        - 4 bpp CGA, all 16 indices;
//                        - 2 bpp, all 8 HW_PALETTE values x all 4 pixel
//                          values, HW_BG for value 0;
//                        - 1 bpp, HW_BG / HW_FG over all 16 CGA indices.
//                      The LUT model holds random entries and SW_LUT_EN = 0,
//                      so any use of the LUT shows. Skipped unless
//                      DIF_TYPE = 0.
//----------------------------------------------------------------------------

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    hc_i;
reg [31:0] hc_lc;

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: HARDWARE COLOUR PALETTES      |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 1;
      bk_lut_rand;

      // 16 bpp: random RGB565, modes 4..7
      bk_vram_rand(0, 64);
      bk_frame("16 bpp mode 4", 0, 0, 3'd4, 16, 8, 3'b000, 32'h0000_F000);
      bk_frame("16 bpp mode 5", 0, 0, 3'd5, 16, 8, 3'b000, 32'h0000_F000);
      bk_frame("16 bpp mode 6", 0, 0, 3'd6, 16, 8, 3'b000, 32'h0000_F000);
      bk_frame("16 bpp mode 7", 0, 0, 3'd7, 16, 8, 3'b000, 32'h0000_F000);
      // full-scale corners
      vram_mem[0] = 32'hFFFF_0000;
      vram_mem[1] = 32'h001F_F800;
      vram_mem[2] = 32'h07E0_0821;
      vram_mem[3] = 32'h8410_7BEF;
      bk_frame("16 bpp corners", 0, 0, 3'd4, 8, 1, 3'b000, 32'h0000_F000);

      // 8 bpp RGB332: the reference itself, at hand-computed values (each
      // field widened by repeating its top bits, then to RGB888)
      if (bkr_color(3'd3, 16'h0024, 32'h0) !== 24'h212400) tb_error("bk_ref RGB332 0x24");
      if (bkr_color(3'd3, 16'h0001, 32'h0) !== 24'h000052) tb_error("bk_ref RGB332 0x01");
      if (bkr_color(3'd3, 16'h0092, 32'h0) !== 24'h9492AD) tb_error("bk_ref RGB332 0x92");
      if (bkr_color(3'd3, 16'h00FF, 32'h0) !== 24'hFFFFFF) tb_error("bk_ref RGB332 0xFF");
      // 8 bpp RGB332: values 0..255 in pixel order
      for (hc_i = 0; hc_i < 64; hc_i = hc_i + 1)
         vram_mem[hc_i] = ((4*hc_i+3) << 24) | ((4*hc_i+2) << 16) | ((4*hc_i+1) << 8) | (4*hc_i);
      bk_frame("8 bpp RGB332 all values", 0, 0, 3'd3, 32, 8, 3'b000, 32'h0000_F000);

      // 4 bpp CGA: indices 0..15, then random
      vram_mem[0] = 32'h7654_3210;
      vram_mem[1] = 32'hFEDC_BA98;
      bk_frame("4 bpp CGA all indices", 0, 0, 3'd2, 16, 1, 3'b000, 32'h0000_F000);
      bk_vram_rand(0, 16);
      bk_frame("4 bpp CGA random", 0, 0, 3'd2, 16, 8, 3'b000, 32'h0000_F000);

      // 2 bpp: every palette, values 0..3, BG varied
      vram_mem[0] = 32'h1B1B_E4E4;
      for (hc_i = 0; hc_i < 8; hc_i = hc_i + 1) begin
         hc_lc = (((hc_i + 3) & 15) << 8) | (hc_i << 4);
         bk_frame("2 bpp HW palette", 0, 0, 3'd1, 16, 1, 3'b000, hc_lc);
      end
      bk_vram_rand(0, 8);
      bk_frame("2 bpp random palette 6", 0, 0, 3'd1, 16, 8, 3'b000, 32'h0000_9E60);

      // 1 bpp: BG / FG over all 16 indices
      vram_mem[0] = 32'h5A3C_96A5;
      for (hc_i = 0; hc_i < 16; hc_i = hc_i + 1) begin
         hc_lc = ((15 - hc_i) << 12) | (hc_i << 8);
         bk_frame("1 bpp BG/FG", 0, 0, 3'd0, 32, 1, 3'b000, hc_lc);
      end

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
