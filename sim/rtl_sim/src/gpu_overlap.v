//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_overlap
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_overlap.v
// Module Description : COPY and COPY_TRANSP whose source overlaps its own
//                      destination: the image must be the one of a copy done
//                      pixel by pixel in walk order (each source pixel read
//                      after every earlier pixel was written). Source offsets
//                      of zero, one pixel, one row and a few words either way,
//                      the same or another pitch, every raster operation,
//                      every destination and source swap, every colour depth;
//                      a quarter of the copies with a short destination pitch
//                      (a few pixels: column walks come back to a word a few
//                      pixels later); first, long rows whose destination is
//                      one word ahead of the source along the walk, at 16
//                      and 8 bpp; then, at every depth, source and
//                      destination less than a word apart either way (one
//                      pixel, half a word, a word less a pixel) with equal X
//                      swaps and mirrored (word-token COPY: the source
//                      leading the destination takes whole tokens, trailing
//                      it one pixel). The image checked against the model
//                      after each copy.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer OV_P      = 32;                  // pitch (pixels)
localparam integer OV_LO     = 2000;
localparam integer OV_HI     = 2600;
localparam integer OV_N      = 200;

integer    ov_i, ov_mode, ov_bl, ov_ppw, ov_w, ov_h, ov_d, ov_sp, ov_dp, ov_cmd, ov_n0, ov_k;
reg  [2:0] ov_dsw, ov_ssw;
reg [31:0] ov_db, ov_sb;

function integer ov_rnd;
   input integer n;
   begin
      ov_rnd = ($random(gpu_seed) & 32'h7FFF_FFFF) % n;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|   GPU: copies overlapping their destination   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < OV_HI + 8)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_dispw(64);
      ov_n0 = 0;

      // Fixed cases: long rows whose destination is one word (and one word plus
      // a pixel) ahead of the source along the walk, forward and with the X
      // swap, at 16 and 8 bpp: every source word after the first is written by
      // the pixels of the word before it, before they read it
      for (ov_k = 0; ov_k < 8; ov_k = ov_k + 1) begin
         gpu_wait_idle;
         ov_mode = (ov_k < 4) ? 4 : 3;
         ov_bl   = gpu_bl(ov_mode);
         ov_ppw  = 32 >> ov_bl;
         gpu_check_all("before the next case");        // no stray write absorbed by the re-init
         gpu_preload_rand(OV_LO, OV_HI);
         gpu_model_init;
         gpu_set_mode(ov_mode);
         gpu_set_dispw(64);
         ov_dsw  = ov_k[1] ? 3'b100 : 3'b000;
         ov_d    = (ov_k[0] ? (ov_ppw + 1) : ov_ppw) * (ov_k[1] ? -1 : 1);
         ov_sb   = (OV_LO + 280) * ov_ppw;
         ov_db   = ov_sb + ov_d;
         gpu_c_size(24, 3);
         gpu_c_dst(OV_P, ov_db);
         gpu_c_src(OV_P, ov_sb);
         gpu_c_exec(GPU_COPY, 4'd0, ov_dsw, ov_dsw);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("overlapping copy, one word ahead");
      end

      // Source and destination less than a word apart, either way, at every
      // depth (one-pixel horizontal scrolls, half a word, a word less a pixel):
      // X swaps equal on both sides (word tokens where the source leads the
      // destination along the walk, one pixel where it trails it) or a mirror
      for (ov_k = 0; ov_k < 90; ov_k = ov_k + 1) begin
         if ((ov_k % 18) == 0) begin
            gpu_wait_idle;
            ov_mode = ov_k / 18;
            ov_bl   = gpu_bl(ov_mode);
            ov_ppw  = 32 >> ov_bl;
            gpu_check_all("before the next block");       // no stray write absorbed by the re-init
            gpu_preload_rand(OV_LO, OV_HI);
            gpu_model_init;
            gpu_set_mode(ov_mode);
            gpu_set_dispw(64);
         end
         case ((ov_k % 18) / 3)
           0:       ov_d = 1;
           1:       ov_d = -1;
           2:       ov_d = (ov_ppw > 2) ? ov_ppw / 2 : 1;
           3:       ov_d = (ov_ppw > 2) ? -(ov_ppw / 2) : -1;
           4:       ov_d = ov_ppw - 1;
           default: ov_d = 1 - ov_ppw;
         endcase
         ov_dsw = ((ov_k % 3) != 0) ? 3'b100 : 3'b000;
         ov_ssw = ((ov_k % 3) == 2) ? 3'b000 : ov_dsw;
         ov_w   = 2 * ov_ppw + 3;
         if (ov_w > GPU_DIM_MASK) ov_w = GPU_DIM_MASK;
         ov_db  = (OV_LO + 280) * ov_ppw + ov_rnd(ov_ppw);
         ov_sb  = ov_db + ov_d;
         gpu_c_size(ov_w, 2);
         gpu_c_dst(OV_P, ov_db);
         gpu_c_src(OV_P, ov_sb);
         gpu_c_transp($random(gpu_seed));
         gpu_c_exec(ov_rnd(4) ? GPU_COPY : GPU_COPYT, ov_rnd(16), ov_dsw, ov_ssw);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("overlapping copy, less than a word apart");
         if (error != 0) ov_k = 90;
      end

      for (ov_i = 0; ov_i < OV_N; ov_i = ov_i + 1) begin
         if ((ov_i % 20) == 0) begin
            gpu_wait_idle;
            ov_mode = ov_rnd(5);
            ov_bl   = gpu_bl(ov_mode);
            ov_ppw  = 32 >> ov_bl;
            gpu_check_all("before the next block");       // no stray write absorbed by the re-init
            gpu_preload_rand(OV_LO, OV_HI);
            gpu_model_init;
            gpu_set_mode(ov_mode);
            gpu_set_dispw(64);
         end
         ov_w   = 1 + ov_rnd(12);
         ov_h   = 1 + ov_rnd(6);
         ov_dsw = ov_rnd(8);
         ov_ssw = ov_rnd(8);
         if (ov_rnd(2)) ov_ssw = ov_dsw;                                // the memmove case
         // destination in the middle of the region: every swap stays inside
         ov_db  = (OV_LO + 280) * ov_ppw + ov_rnd(ov_ppw);
         case (ov_rnd(6))
           0:       ov_d = 0;
           1:       ov_d = ov_rnd(2) ? 1 : -1;
           2:       ov_d = ov_rnd(2) ? OV_P : -OV_P;
           3:       ov_d = (ov_rnd(2) ? 1 : -1) * (OV_P + 1);
           4:       ov_d = ov_rnd(4 * ov_ppw + 1) - 2 * ov_ppw;
           default: ov_d = ov_rnd(2 * OV_P + 1) - OV_P;
         endcase
         ov_sb  = ov_db + ov_d;
         ov_sp  = ov_rnd(4) ? OV_P : (OV_P - 1 + ov_rnd(3));
         ov_dp  = ov_rnd(4) ? OV_P : (3 + ov_rnd(14));                  // short pitch: words revisited
         gpu_c_size(ov_w, ov_h);
         gpu_c_dst(ov_dp, ov_db);
         gpu_c_src(ov_sp, ov_sb);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         ov_cmd = ov_rnd(4) ? GPU_COPY : GPU_COPYT;
         if (ov_d == 0) ov_n0 = ov_n0 + 1;
         gpu_c_exec(ov_cmd, ov_rnd(16), ov_dsw, ov_ssw);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("overlapping copy");
         if (error != 0) ov_i = OV_N;
      end
      $display("       %0d overlapping copies (%0d onto themselves)", OV_N, ov_n0);
      gpu_check_all("overlap end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
