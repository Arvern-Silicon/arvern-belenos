//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_bil_mixd
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_bil_mixd.v
// Module Description : Bilinear pixels with and without a destination read
//                      in one destination word (blend builds with
//                      GPU_BILINEAR_EN): an interior pixel (every tap opaque,
//                      alpha256 = 256: written without reading D) and an
//                      edge pixel (a tap outside the box with TBORDER:
//                      alpha256 < 256, D read):
//                      - the interior pixel first: the word written, read
//                        again, written (2 writes, 1 read); the edge pixel
//                        first: 1 read, 1 write; both rules (MIX5); counts
//                        stated here, not taken from the model;
//                      - random edge blits (TEXSPAN / TEXRECT over a box
//                        with TBORDER, SRC_FMT 0 and 5): the image, the
//                        destination reads and the writes exact against the
//                        model's one-word destination buffer.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer BM_TLO  = 4096;               // textures: words [4096, 6144)
localparam integer BM_ALO  = 8192;               // A8 planes: words [8192, 9216)
localparam integer BM_DLO  = 10240;              // destinations: words [10240, 14336)
localparam integer BM_DP   = 128;

integer    bm_i, bm_k, bm_w, bm_h, bm_drd, bm_wr, bm_orw, bm_d0, bm_w0;
reg        bm_on;
reg [31:0] bm_t;

initial begin bm_on = 1'b0; bm_drd = 0; bm_wr = 0; bm_orw = 0; end
always @(posedge hclk)
   if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && !gpu_mon_wp && bm_on) begin
      if (vram_wen !== 4'hF) bm_wr = bm_wr + 1;
      else if ((vram_addr >= BM_DLO) && (vram_addr < BM_DLO + 4096)) bm_drd = bm_drd + 1;
      else if (!((vram_addr >= BM_TLO) && (vram_addr < BM_TLO + 2048)) &&
               !((vram_addr >= BM_ALO) && (vram_addr < BM_ALO + 1024))) bm_orw = bm_orw + 1;
   end

function integer bm_rnd;
   input integer n;
   begin
      bm_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

// Run a prepared blit; the D reads / writes against the model's
task bm_run;
   input integer kind;
   input [8*40-1:0] label;
   begin
      gpu_wait_idle;
      bm_d0 = gpu_exp_drd;
      bm_w0 = gpu_exp_wr;
      bm_drd = 0; bm_wr = 0; bm_orw = 0;
      bm_on = 1'b1;
      if (kind == 0) gpu_c_texspan(0, bm_w);
      else           gpu_c_texrect(0);
      gpu_wait_idle;
      bm_on = 1'b0;
      gpu_k_a8 = 1'b0;
      if ((bm_drd != gpu_exp_drd - bm_d0) || (bm_wr != gpu_exp_wr - bm_w0) || (bm_orw != 0)) begin
         $display("ERROR: GPU bilinear %0s: %0d D reads / %0d writes / %0d other, expected %0d / %0d / 0 %t",
                  label, bm_drd, bm_wr, bm_orw, gpu_exp_drd - bm_d0, gpu_exp_wr - bm_w0, $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched(label);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: bilinear D and no-D pixels in one word  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BILINEAR_EN == 0) || (GPU_XY_EN == 0) || (GPU_BLEND_EN == 0))
         tb_skip_finish("|  (no bilinear with blending in this build)    |");
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);

      //--------------------------------------------------------------
      $display("--- 1. one destination word: interior then edge, edge then interior");
      // 16 x 16 texture, box 4 x 4, TBORDER: u = 1.5 (texel centre: one tap,
      // alpha256 256), u = 3.75 (taps x = 3 and 4, x = 4 outside: alpha256 192)
      for (bm_k = 0; bm_k < 4; bm_k = bm_k + 1) begin
         gpu_c_tex_filter(1'b1, 1'b1);
         gpu_c_alpha5(1'b0, 8'd0, bm_k[1]);
         gpu_k_a8 = 1'b0;
         gpu_c_src(16'd0, 2 * BM_TLO + 64);
         gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b1, 8'h00);
         gpu_c_texbox(4, 4);
         gpu_c_dst(BM_DP, 2 * BM_DLO + 2 * BM_DP * 4 + 2 * bm_rnd(64));   // an even pixel
         gpu_c_uv(bm_k[0] ? 16'd240 : 16'd96, 16'd96);                   // 3.75 / 1.5, v 1.5
         gpu_c_step(bm_k[0] ? -16'sd4608 : 16'd4608, 16'd0);              // -/+ 2.25 texels
         bm_w = 2;
         bm_run(0, bm_k[0] ? "edge then interior" : "interior then edge");
         if ((bm_drd != 1) || (bm_wr != (bm_k[0] ? 1 : 2))) begin
            $display("ERROR: GPU bilinear one word, %0s%0s: %0d D reads / %0d writes, expected 1 / %0d %t",
                     bm_k[0] ? "edge first" : "interior first", bm_k[1] ? ", MIX5" : "", bm_drd, bm_wr,
                     bm_k[0] ? 1 : 2, $time);
            error = error + 1;
         end
      end

      //--------------------------------------------------------------
      $display("--- 2. random edge blits: D reads and writes exact");
      for (bm_i = 0; (bm_i < 60) && (error == 0); bm_i = bm_i + 1) begin
         gpu_c_tex_filter(1'b1, bm_rnd(4) != 0);
         gpu_c_alpha5(bm_rnd(4) == 0, bm_rnd(2) ? 8'd255 : bm_rnd(256), bm_rnd(2));
         gpu_k_a8 = bm_rnd(2);
         gpu_c_src(16'd0, 2 * BM_TLO + 64 + bm_rnd(64));
         if (gpu_k_a8) gpu_c_alpha_plane(4 * BM_ALO + 64 + bm_rnd(64));
         gpu_c_tex(4'd4, 4'd4, bm_rnd(4) == 0, 3'b000, 1'b0, 1'b1, 8'h00);
         gpu_c_transp(gpu_get_px(gpu_m_src_base + bm_rnd(8), 4));
         gpu_c_texbox(2 + bm_rnd(14), 2 + bm_rnd(14));
         gpu_c_dst(BM_DP, 2 * BM_DLO + 2 * BM_DP * 4 + 2 * bm_rnd(BM_DP * 4) + bm_rnd(2));
         gpu_c_uv(-16'sd96 + bm_rnd(200), -16'sd96 + bm_rnd(200));
         gpu_c_step(16'd200 + bm_rnd(3000), bm_rnd(1200) - 600);
         if (bm_rnd(2)) begin
            bm_w = 8 + bm_rnd(40);
            bm_run(0, "random bilinear edge span");
         end else begin
            bm_w = 4 + bm_rnd(20); bm_h = 2 + bm_rnd(8);
            gpu_c_size(bm_w, bm_h);
            gpu_c_step_row(bm_rnd(1200) - 600, 16'd200 + bm_rnd(3000));
            bm_run(1, "random bilinear edge blit");
         end
      end
      gpu_c_tex_filter(1'b0, 1'b0);
      gpu_c_alpha(1'b0, 8'd0);
      gpu_check_all("gpu_bil_mixd end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
