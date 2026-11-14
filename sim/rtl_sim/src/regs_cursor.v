//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_cursor
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_cursor.v
// Module Description : Hardware cursor registers 0x058-0x06C: reset values
//                      0; write masks with all-zero / all-one / alternating /
//                      random patterns, written in one pass and read back in
//                      a second (decode aliasing): CURSOR_CTRL [0] EN, [12:8]
//                      HOT_X, [20:16] HOT_Y; CURSOR_POS all 32 bits as
//                      written; CURSOR_ADDR [VRAM_AW-1:7] (none below 8 VRAM
//                      address bits); CURSOR_COL1-3 [23:0]; BLNS_CFG [18]
//                      CURSOR. Without CURSOR_EN all six read 0 and ignore
//                      writes.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam [31:0] RC_ADDR_M = (VRAM_AW > 7) ? (((32'h1 << VRAM_AW) - 1) & 32'hFFFF_FF80) : 32'h0;

reg  [31:0] rc_pat [0:5];
reg  [31:0] rc_wv  [0:5];
reg  [31:0] rc_off [0:5];
reg  [31:0] rc_msk [0:5];
reg  [31:0] rc_rd;
integer     rc_i, rc_p;

initial
   begin
      $display(" ===============================================");
      $display("|        HARDWARE CURSOR REGISTERS              |");
      $display(" ===============================================");
      @(posedge reset_done);

      rc_off[0] = CURSOR_CTRL; rc_msk[0] = 32'h001F_1F01;
      rc_off[1] = CURSOR_POS;  rc_msk[1] = 32'hFFFF_FFFF;
      rc_off[2] = CURSOR_ADDR; rc_msk[2] = RC_ADDR_M;
      rc_off[3] = CURSOR_COL1; rc_msk[3] = 32'h00FF_FFFF;
      rc_off[4] = CURSOR_COL2; rc_msk[4] = 32'h00FF_FFFF;
      rc_off[5] = CURSOR_COL3; rc_msk[5] = 32'h00FF_FFFF;
      if (CURSOR_EN == 0)
         for (rc_i = 0; rc_i < 6; rc_i = rc_i + 1) rc_msk[rc_i] = 32'h0;

      // BLNS_CFG [18]
      reg_rd(BLNS_CFG, BLNS_CFG_EXP);
      reg_rd_val(BLNS_CFG, rc_rd);
      if (rc_rd[18] !== (CURSOR_EN != 0)) tb_error("BLNS_CFG.CURSOR does not match CURSOR_EN");

      // Reset values
      for (rc_i = 0; rc_i < 6; rc_i = rc_i + 1) reg_rd(rc_off[rc_i], 32'h0);

      // Write masks: every register written, then every one read back
      rc_pat[0] = 32'h0000_0000;
      rc_pat[1] = 32'hFFFF_FFFF;
      rc_pat[2] = 32'h5555_5555;
      rc_pat[3] = 32'hAAAA_AAAA;
      for (rc_p = 0; rc_p < 8; rc_p = rc_p + 1) begin
         for (rc_i = 0; rc_i < 6; rc_i = rc_i + 1) begin
            rc_wv[rc_i] = (rc_p < 4) ? (rc_pat[rc_p] ^ (rc_i[0] ? 32'hFFFF_0000 : 32'h0)) : $random(tmp_seed);
            reg_wr(rc_off[rc_i], rc_wv[rc_i]);
         end
         for (rc_i = 0; rc_i < 6; rc_i = rc_i + 1)
            reg_rd(rc_off[rc_i], rc_wv[rc_i] & rc_msk[rc_i]);
      end

      // Negative positions read back as written (16 bits each, signed)
      reg_wr(CURSOR_POS, 32'h8000_FFE1);
      reg_rd(CURSOR_POS, 32'h8000_FFE1 & rc_msk[1]);

      // The neighbours are untouched
      reg_rd(LUT_ROT, 32'h0);
      reg_rd(32'h070, 32'h0);
      for (rc_i = 0; rc_i < 6; rc_i = rc_i + 1) reg_wr(rc_off[rc_i], 32'h0);
      for (rc_i = 0; rc_i < 6; rc_i = rc_i + 1) reg_rd(rc_off[rc_i], 32'h0);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
