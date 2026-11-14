//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_frames
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_frames.v
// Module Description : Refresh frame selection (uarch §8 / §11, digest F.1),
//                      checked on the BDI pixel stream (DIF_TYPE = 0):
//                        - FRAMEn_PTR (n < FRAME_NR) hold PA_W-bit pixel
//                          addresses, FRAMEn_PTR for n >= FRAME_NR are RAZ/WI;
//                        - FRAME_SEL[1:0] selects the refresh frame: each
//                          implemented frame streams from its own, non-word-
//                          aligned base (16, 4 and 1 bpp), the reserved bits
//                          of FRAME_SEL do not affect the refresh;
//                        - FRAME_SEL values >= FRAME_NR are masked to
//                          FRAME_NR - 1.
//                      Run with FRAME_NR = 1, 2 (default) and 4. Skipped
//                      unless DIF_TYPE = 0.
//----------------------------------------------------------------------------

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    fr_i, fr_s, fr_m, fr_e;
integer    fr_base [0:3];
reg [31:0] fr_rd;
reg [64*8-1:0] fr_tag;
localparam [31:0] FR_PA_MASK = (32'h1 << (VRAM_AW + 5)) - 1;

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: REFRESH FRAME SELECTION       |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 1;
      bk_vram_rand(0, 1024);

      // Pointer registers: width and RAZ/WI above FRAME_NR
      for (fr_i = 0; fr_i < 4; fr_i = fr_i + 1) begin
         reg_wr(FRAME0_PTR + 4*fr_i, 32'hFFFF_FFFF);
         reg_rd(FRAME0_PTR + 4*fr_i, (fr_i < FRAME_NR) ? FR_PA_MASK : 32'h0);
      end

      // Distinct, non-aligned bases (pixel addresses), in 16 bpp units of
      // 200 words apart: frame n at word 200*n + n, plus a pixel offset
      for (fr_m = 0; fr_m < 3; fr_m = fr_m + 1) begin
         for (fr_i = 0; fr_i < 4; fr_i = fr_i + 1) begin
            fr_base[fr_i] = ((200*fr_i + 3) << (5 - ((fr_m == 0) ? 4 : (fr_m == 1) ? 2 : 0))) + 2*fr_i + 1;
            reg_wr(FRAME0_PTR + 4*fr_i, fr_base[fr_i]);
         end
         reg_wr(CTRL,      (fr_m == 0) ? 32'd4 : (fr_m == 1) ? 32'd2 : 32'd0);
         reg_wr(DISP_SIZE, (5 << 16) | 12);
         reg_wr(DISP_CFG,  0);
         reg_wr(LUT_CFG,   32'h0000_F100);
         for (fr_s = 0; fr_s < 4; fr_s = fr_s + 1) begin
            // reserved bits set: no effect on the refresh
            reg_wr(FRAME_SEL, ((3 - fr_s) << 12) | (((fr_s + 1) & 3) << 8) | fr_s);
            reg_rd_val(FRAME_SEL, fr_rd);
            fr_e = fr_s & (FRAME_NR - 1);
            bk_refresh(60);
            if (fr_rd[1:0] !== fr_e) begin
               $display("ERROR: FRAME_SEL[1:0] = %0d after writing %0d with FRAME_NR = %0d %t", fr_rd[1:0], fr_s, FRAME_NR, $time);
               error = error + 1;
            end
            bkr_build(fr_base[fr_e], (fr_m == 0) ? 3'd4 : (fr_m == 1) ? 3'd2 : 3'd0,
                      12, 5, 3'b000, 32'h0000_F100);
            $sformat(fr_tag, "FRAME_SEL %0d (FRAME_NR %0d) %0s", fr_s, FRAME_NR,
                     (fr_m == 0) ? "16 bpp" : (fr_m == 1) ? "4 bpp" : "1 bpp");
            bkr_check_bdi(fr_tag);
         end
      end

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
