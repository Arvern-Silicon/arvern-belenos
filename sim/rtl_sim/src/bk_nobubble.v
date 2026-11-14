//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_nobubble
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_nobubble.v
// Module Description : No-bubble streaming (uarch §13 "Backend": with the
//                      driver always ready and no VRAM contention, the stream
//                      has no bubble, 1 pixel/cycle, after the first pixel;
//                      spec §6 "one pixel ahead"). DIF_TYPE = 0, BDI ready
//                      held at 1, no other VRAM or LUT master active: every
//                      GFX_MODE 0..7, HW palettes and SW LUT, all 8 DISP_CFG
//                      swap combinations, sizes with lines ending mid-word,
//                      width 1 and height 1, aligned and non-aligned bases.
//                      Each pixel must be taken exactly one cycle after the
//                      previous one, data exact. The rise-to-first-pixel
//                      latency is reported and checked against the BDI
//                      contract (DIM_W + 4 cycles plus the read latency).
//                      Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    nb_m, nb_c, nb_s, nb_l, nb_i, nb_w, nb_h, nb_b, nb_bub, nb_lat, nb_maxlat;
reg [31:0] nb_lut;
reg [64*8-1:0] nb_tag;

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: NO-BUBBLE STREAMING           |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 0;
      bk_vram_rand(0, 2048);
      bk_lut_rand;
      nb_maxlat = 0;

      for (nb_m = 0; nb_m < 8; nb_m = nb_m + 1)
        for (nb_l = 0; nb_l < 2; nb_l = nb_l + 1)
          for (nb_c = 0; nb_c < 8; nb_c = nb_c + 1)
            for (nb_s = 0; nb_s < 3; nb_s = nb_s + 1)
              if ((nb_l == 0) || ((nb_m < 4) && (LUT_EN != 0))) begin
                 case (nb_s)
                   0 : begin nb_w = 19; nb_h = 6;  nb_b = 0;  end
                   1 : begin nb_w = 1;  nb_h = 23; nb_b = 5;  end
                   default : begin nb_w = 40; nb_h = 1; nb_b = 13; end
                 endcase
                 nb_lut = nb_l ? 32'h0000_0003 : 32'h0000_9E40;
                 $sformat(nb_tag, "mode %0d %0s cfg %0d %0dx%0d", nb_m, nb_l ? "LUT" : "HW", nb_c, nb_w, nb_h);
                 bk_frame(nb_tag, 0, nb_b, nb_m, nb_w, nb_h, nb_c, nb_lut);
                 nb_bub = 0;
                 for (nb_i = 1; (nb_i < bkm_n) && (nb_i < BKM_LOG); nb_i = nb_i + 1)
                    if (bkm_cyc[nb_i] != bkm_cyc[nb_i-1] + 1) nb_bub = nb_bub + 1;
                 nb_lat = bkm_cyc[0] - bkm_rise_cyc;
                 if (nb_lat > nb_maxlat) nb_maxlat = nb_lat;
                 if (nb_bub != 0) begin
                    $display("ERROR: %0s -- %0d bubbles with ready held at 1 (first pixel %0d cycles after the rise, last %0d) %t",
                             nb_tag, nb_bub, nb_lat, bkm_cyc[bkm_n-1] - bkm_cyc[0], $time);
                    error = error + 1;
                 end
              end
      $display("INFO:  max refresh_active rise -> first pixel latency: %0d cycles", nb_maxlat);
      if (nb_maxlat > DIM_W + 4 + VRAM_RD_LAT + VRAM_RD_REG_EN)
         tb_error("first pixel later than the BDI contract (DIM_W + 4 cycles + the VRAM read latency)");

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
