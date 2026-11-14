//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      smoke_lut
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : smoke_lut.v
// Module Description : Smoke test of the LUT window (0x800-0xFFC): entries of
//                      bank 0 (and bank 1 with LUT_BANKS = 2) written and read
//                      back as {8'h00, RGB888}, checked against the LUT model;
//                      bank 1 is RAZ/WI with LUT_BANKS = 1. Skipped without
//                      the LUT.
//----------------------------------------------------------------------------

initial
   begin
      $display(" ===============================================");
      $display("|                   SMOKE: LUT                  |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (LUT_EN == 0)
         tb_skip_finish("|         (LUT_EN = 0: no LUT to access)        |");

      // Bank 0: first, an inner and the last entry; the top byte is not stored
      reg_wr(LUT_BASE + 4*0,   32'hFF12_3456);
      reg_wr(LUT_BASE + 4*1,   32'h00AB_CDEF);
      reg_wr(LUT_BASE + 4*255, 32'h0080_0001);
      reg_rd(LUT_BASE + 4*0,   32'h0012_3456);
      reg_rd(LUT_BASE + 4*1,   32'h00AB_CDEF);
      reg_rd(LUT_BASE + 4*255, 32'h0080_0001);

      @(posedge free_clk);
      if (lut_mem[0]   !== 24'h12_3456) tb_error("LUT model entry 0 differs from the window write");
      if (lut_mem[255] !== 24'h80_0001) tb_error("LUT model entry 255 differs from the window write");

      // Bank 1 (0xC00-0xFFC)
      reg_wr(LUT_BASE + 32'h400 + 4*0,   32'h0055_AA55);
      reg_wr(LUT_BASE + 32'h400 + 4*255, 32'h0001_0203);
      if (LUT_BANKS == 2) begin
         reg_rd(LUT_BASE + 32'h400 + 4*0,   32'h0055_AA55);
         reg_rd(LUT_BASE + 32'h400 + 4*255, 32'h0001_0203);
         @(posedge free_clk);
         if (lut_mem[256] !== 24'h55_AA55) tb_error("LUT model entry 256 differs from the window write");
      end else begin
         reg_rd(LUT_BASE + 32'h400 + 4*0,   32'h0000_0000);
         reg_rd(LUT_BASE + 32'h400 + 4*255, 32'h0000_0000);
         @(posedge free_clk);
         if (lut_mem[256] !== 24'h00_0000) tb_error("LUT bank 1 written with LUT_BANKS = 1");
      end

      // Bank 0 untouched by the bank 1 writes
      reg_rd(LUT_BASE + 4*0,   32'h0012_3456);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
