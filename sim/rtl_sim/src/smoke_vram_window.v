//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      smoke_vram_window
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : smoke_vram_window.v
// Module Description : Smoke test of the VRAM-window port: byte, half-word
//                      and word writes read back in every size, checked
//                      against the VRAM model too; a model back-door write
//                      read through the window; the last populated word; an
//                      out-of-range word (ERROR, only when VRAM_WORDS <
//                      2^VRAM_AW); and, with PRIV_CHECK_EN, a U-mode access
//                      (ERROR).
//----------------------------------------------------------------------------

reg [31:0] base;
reg [31:0] last;

initial
   begin
      $display(" ===============================================");
      $display("|               SMOKE: VRAM WINDOW              |");
      $display(" ===============================================");
      @(posedge reset_done);

      base = (VRAM_WORDS > 64) ? 32'h0000_0100 : 32'h0000_0000;

      // Word write, read back in every size
      vram_wr(base + 0, 32'h4433_2211, SZ_W);
      vram_rd(base + 0, 32'h4433_2211, SZ_W);
      vram_rd(base + 0, 32'h0000_2211, SZ_H);
      vram_rd(base + 2, 32'h0000_4433, SZ_H);
      vram_rd(base + 0, 32'h0000_0011, SZ_B);
      vram_rd(base + 1, 32'h0000_0022, SZ_B);
      vram_rd(base + 2, 32'h0000_0033, SZ_B);
      vram_rd(base + 3, 32'h0000_0044, SZ_B);

      // Byte writes into the same word
      vram_wr(base + 1, 32'h0000_00AA, SZ_B);
      vram_wr(base + 3, 32'h0000_00BB, SZ_B);
      vram_rd(base + 0, 32'hBB33_AA11, SZ_W);

      // Half-word writes
      if (VRAM_WORDS > 1) begin
         vram_wr(base + 4, 32'h0000_CAFE, SZ_H);
         vram_wr(base + 6, 32'h0000_F00D, SZ_H);
         vram_rd(base + 4, 32'hF00D_CAFE, SZ_W);
         vram_rd(base + 6, 32'h0000_F00D, SZ_H);
      end

      // The VRAM model holds what the window wrote
      @(posedge free_clk);
      if (vram_mem[base >> 2] !== 32'hBB33_AA11)
         tb_error("VRAM model word differs from the window write");

      // Back-door write, read through the window
      vram_mem[(base >> 2) + 1] = 32'h1234_5678;
      vram_rd(base + 4, 32'h1234_5678, SZ_W);

      // Last populated word
      last = (VRAM_WORDS - 1) * 4;
      vram_wr(last, 32'hA5A5_5A5A, SZ_W);
      vram_rd(last, 32'hA5A5_5A5A, SZ_W);

      // Beyond the populated depth: ERROR, only when such words are addressable
      if (VRAM_WORDS < (1 << VRAM_AW)) begin
         ahb_write_x(PORT_V, VRAM_WORDS * 4, 32'hDEAD_BEEF, SZ_W, MACHINE, HART_MASTER, ERROR);
         ahb_read_x (PORT_V, VRAM_WORDS * 4, 32'h0, 32'h0,  SZ_W, MACHINE, HART_MASTER, 1'b0, ERROR);
         vram_rd(last, 32'hA5A5_5A5A, SZ_W);
      end else begin
         $display("INFO:  VRAM_WORDS = 2^VRAM_AW, no out-of-range word to check");
      end

      // Privilege: U-mode denied only with PRIV_CHECK_EN
      if (PRIV_CHECK_EN != 0) begin
         ahb_write_x(PORT_V, base, 32'h0, SZ_W, USER, HART_MASTER, ERROR);
         ahb_read_x (PORT_V, base, 32'h0, 32'h0, SZ_W, USER, HART_MASTER, 1'b0, ERROR);
         vram_rd(base + 0, 32'hBB33_AA11, SZ_W);
      end else begin
         ahb_read_x (PORT_V, base, 32'hBB33_AA11, 32'hFFFF_FFFF, SZ_W, USER, HART_MASTER, 1'b1, OK);
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
