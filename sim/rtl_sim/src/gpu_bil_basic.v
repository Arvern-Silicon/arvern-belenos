//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_bil_basic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_bil_basic.v
// Module Description : Bilinear texture sampling (SET_AUX SEL 5 TEX_FILTER
//                      BILINEAR; GPU_BILINEAR_EN and GPU_XY_EN; skipped
//                      otherwise) against gpu_model.v at 16 bpp. The model's
//                      tap MAC and blend (gpu_bil_px) is checked first
//                      against values of the spec harness's hw() formula
//                      (bilt.c; the rounding variant of the pinned
//                      decisions). Then:
//                      - one pixel per (fx, fy) in {0, 1, 7, 8, 16, 24, 31,
//                        32}^2: 1, 2 or 4 taps (weight-0 taps dropped);
//                      - texel-aligned starts (one tap), 90-degree turns,
//                        zoom-in (du = 1/2, 1/4) and zoom-out (du = 2, 3);
//                      - random affine blits (TEXSPAN, TEXRECT, textured
//                        triangles with GPU_TRI_EN), power-of-two textures
//                        (seamless wrap) and free pitch, texture swaps;
//                      - blend builds: MIX5 on / off, SRC_FMT 0 (opaque:
//                        alpha256 256, no destination read) and 5 (A8 taps),
//                        SET_ALPHA EN; no-blend builds: the straight colour
//                        (P + 512) >> 10, TRANSP_EN falls back to nearest;
//                      - BILINEAR 0 again: nearest; palette modes: nearest.
//                      Each blit: the image (window read of the touched
//                      words), only the texel, A8 and destination words of
//                      the walk accessed; taps per pixel counted (1 / 2 / 4
//                      all seen).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer BB_TLO  = 4096;               // textures: words [4096, 6144)
localparam integer BB_ALO  = 8192;               // A8 planes: words [8192, 9728)
localparam integer BB_DLO  = 10240;              // destinations: words [10240, 14336)
localparam integer BB_DP   = 128;

integer    bb_i, bb_j, bb_k, bb_n, bb_x, bb_y, bb_w, bb_h, bb_nst, bb_fx, bb_fy, bb_kind;
integer    bb_fv [0:7];
reg        bb_bl, bb_xy;
reg [31:0] bb_r, bb_tb, bb_ab;

function integer bb_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      bb_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task bb_vec;                             // a hand-checked value of the tap MAC and blend
   input [63:0] c;
   input [31:0] a;
   input integer fx;
   input integer fy;
   input [15:0] d;
   input        mix5;
   input        blend;
   input integer a256;
   input [15:0] o;
   begin
      bb_nst = bb_nst + 1;
      tb_checks = tb_checks + 1;
      bb_r = gpu_bil_px(c, a, fx, fy, d, mix5, blend);
      if ((bb_r[31:23] != a256) || (bb_r[15:0] !== o)) begin
         $display("ERROR: GPU model bilinear self-test %0d: alpha256 %0d out 0x%h, expected %0d / 0x%h %t",
                  bb_nst, bb_r[31:23], bb_r[15:0], a256, o, $time);
         error = error + 1;
      end
   end
endtask

task bb_preload;
   integer ww, bb;
   reg [31:0] v;
   begin
      gpu_preload_rand(BB_TLO, BB_TLO + 2048);
      gpu_preload_rand(BB_DLO, BB_DLO + 4096);
      for (ww = BB_ALO; ww < BB_ALO + 1536; ww = ww + 1) begin     // alphas: mostly 0 / 255
         v = $random(gpu_seed);
         if (bb_rnd(3) != 0)
            for (bb = 0; bb < 4; bb = bb + 1) v[8*bb +: 8] = bb_rnd(2) ? 8'hFF : 8'h00;
         vram_mem[ww]   = v;
         gpu_shadow[ww] = v;
      end
   end
endtask

// The texture and its source format (fmt5: RGB565A8, blend builds)
task bb_src;
   input        fmt5;
   input [15:0] pf;
   begin
      bb_tb = 2 * BB_TLO + 64 + bb_rnd(256);
      bb_ab = 4 * BB_ALO + 64 + bb_rnd(256);
      gpu_k_a8 = fmt5 && bb_bl;
      gpu_c_src(pf, bb_tb);
      if (gpu_k_a8) gpu_c_alpha_plane(bb_ab);
   end
endtask

// Run a prepared blit (kind 0 TEXSPAN of w, 1 TEXRECT, 2 textured triangle)
// with the allowed-word monitor, then check the image
task bb_run;
   input integer kind;
   input [8*40-1:0] label;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_alw_clear;
      gpu_alw_start;
      case (kind)
        0:       gpu_c_texspan(0, bb_w);
        1:       gpu_c_texrect(0);
        default: gpu_c_tritex;
      endcase
      gpu_wait_idle;
      gpu_alw_stop;
      gpu_k_a8 = 1'b0;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_ERR | IF_OVFL | IF_DONE);
      gpu_check_touched(label);
   end
endtask

// One pixel (TEXSPAN of 1) at 5-bit weights (fx, fy): u' fraction f8 = 8 fx - 4
task bb_one_w;
   input integer fx;
   input integer fy;
   input        fmt5;
   input        mix5;
   integer      f8x, f8y, tx, ty;
   reg   [15:0] u0, v0;
   begin
      f8x = (fx == 0) ? 0 : (8 * fx - 4);
      f8y = (fy == 0) ? 0 : (8 * fy - 4);
      tx  = bb_rnd(14);
      ty  = bb_rnd(14);
      // u0 (10.6) = (x0 + 1/2 + f8 / 256) texels
      u0  = (tx * 2048 + 1024 + 8 * f8x) >> 5;
      v0  = (ty * 2048 + 1024 + 8 * f8y) >> 5;
      bb_w = 1;
      gpu_c_dst(BB_DP, 2 * BB_DLO + 2 * bb_rnd(BB_DP * 20) + bb_rnd(2));
      if (bb_bl) gpu_c_alpha5(1'b0, 8'd0, mix5);
      bb_src(fmt5, 16'd0);
      gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_c_uv(u0, v0);
      gpu_c_step(16'h0, 16'h0);
      bb_run(0, "bilinear weights");
   end
endtask

// A random affine blit
task bb_rand;
   input integer kind;
   reg          fr, ten, fmt5;
   reg   [15:0] du, dv, dur, dvr;
   integer      r;
   begin
      bb_w = 2 + bb_rnd(14);
      bb_h = 1 + bb_rnd(8);
      gpu_c_size(bb_w, bb_h);
      bb_xy = (kind == 2) || bb_rnd(2);
      if (bb_xy) begin
         gpu_c_dst_xy(BB_DP, 2 * BB_DLO + 2 * BB_DP * 4 + 40);
         bb_x = bb_rnd(40) - 8;
         bb_y = bb_rnd(12) - 3;
         gpu_c_xy(bb_x, bb_y);
         if (bb_rnd(3) == 0) gpu_c_noclip;
         else gpu_c_clip(bb_x + bb_rnd(4) - 2, bb_y + bb_rnd(3) - 1, bb_x + 2 + bb_rnd(bb_w + 2), bb_y + 1 + bb_rnd(bb_h + 2));
      end else
         gpu_c_dst(BB_DP, 2 * BB_DLO + 2 * BB_DP * 4 + 2 * bb_rnd(BB_DP * 20) + bb_rnd(2));
      r = bb_rnd(8);
      if (bb_bl) gpu_c_alpha5(bb_rnd(4) == 0, (r == 0) ? 8'd255 : (r == 1) ? 8'd128 : bb_rnd(256), bb_rnd(2));
      fr   = bb_rnd(3) == 0;
      ten  = bb_rnd(4) == 0;
      fmt5 = bb_rnd(2);
      bb_src(fmt5, fr ? (16'd24 + bb_rnd(40)) : 16'd0);
      gpu_c_transp(bb_rnd(2) ? gpu_get_px(bb_tb + bb_rnd(16), 4) : $random(gpu_seed));
      gpu_c_tex(2 + bb_rnd(4), 2 + bb_rnd(4), ten, bb_rnd(8), fr, 1'b0, 8'h00);
      case (bb_rnd(4))
        0: begin du = 16'd1024; dv = 16'd0; dur = 16'd0; dvr = 16'd1024; end      // zoom-in 2x
        1: begin du = 16'd4096; dv = 16'd0; dur = 16'd0; dvr = 16'd4096; end      // zoom-out 2:1
        default: begin
              // a free-pitch texture without BOUND does not wrap: steps >= 0 there
              du  = bb_rnd(3000) - (fr ? 0 : 1000);
              dv  = bb_rnd(2000) - (fr ? 0 : 1000);
              dur = bb_rnd(2000) - (fr ? 0 : 1000);
              dvr = bb_rnd(3000) - (fr ? 0 : 1000);
           end
      endcase
      gpu_c_uv((bb_rnd(8) << 6) + bb_rnd(64) + 64, (bb_rnd(8) << 6) + bb_rnd(64) + 64);
      gpu_c_step(du, dv);
      gpu_c_step_row(dur, dvr);
      if (kind == 2) begin
         gpu_c_vtx(0, 16 * bb_x + bb_rnd(32) - 16, 16 * bb_y + bb_rnd(32) - 16);
         gpu_c_vtx(1, 16 * (bb_x + bb_w + bb_rnd(6)) + bb_rnd(16), 16 * (bb_y + bb_rnd(4)) + bb_rnd(16));
         gpu_c_vtx(2, 16 * (bb_x + bb_rnd(bb_w)) + bb_rnd(16), 16 * (bb_y + bb_h + bb_rnd(4)) + bb_rnd(16));
      end
      bb_run(kind, "random bilinear blit");
      gpu_c_noclip;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: bilinear sampling                 |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BILINEAR_EN == 0) || (GPU_XY_EN == 0))
         tb_skip_finish("|   (GPU_BILINEAR_EN / GPU_XY_EN = 0: absent)   |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;
      gpu_rsv_seed = `SEED ^ 32'h0B11_BA51;
      gpu_push_wait = 1'b1;
      bb_bl = (GPU_BLEND_EN != 0);
      bb_preload;
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      reg_rd_val(BLNS_CFG2, bb_r);
      if (bb_r[12] !== 1'b1) tb_error("BLNS_CFG2.BILINEAR is 0 in a bilinear build");

      //--------------------------------------------------------------
      $display("--- 0. model self-test: the tap MAC and blend against hand-computed values");
      bb_nst = 0;
      // (spec harness bilt.c hw(): MIX5; the rounding variant: Pm = (P + 2) >> 2, r = 128)
      bb_vec(64'h0000_0000_0000_FFFF, 32'hFFFFFFFF, 16, 16, 16'h1234, 1'b1, 1'b1, 256, 16'h39E7);
      bb_vec(64'hFFFF_001F_07E0_F800, 32'hFFFFFFFF, 8, 24, 16'h0000, 1'b1, 1'b1, 256, 16'h59F7);
      bb_vec(64'hFFFF_001F_07E0_F800, 32'hFFFFFFFF, 8, 24, 16'h0000, 1'b0, 1'b1, 256, 16'h6217);
      bb_vec(64'hFFFF_001F_07E0_F800, 32'hFFFFFFFF, 8, 24, 16'h0000, 1'b1, 1'b0, 256, 16'h6217);
      bb_vec(64'h9BDF_2468_1357_ABCD, 32'hFF8000FF, 13, 4, 16'h5555, 1'b1, 1'b1, 155, 16'h7C50);
      bb_vec(64'h9BDF_2468_1357_ABCD, 32'hFF8000FF, 13, 4, 16'h5555, 1'b0, 1'b1, 155, 16'h8471);
      bb_vec(64'hFFFF_FFFF_FFFF_FFFF, 32'h00000000, 10, 10, 16'h4321, 1'b1, 1'b1, 0, 16'h4321);
      bb_vec(64'h0000_0000_0000_8410, 32'h00000003, 0, 0, 16'h7777, 1'b1, 1'b1, 3, 16'h7756);
      bb_vec(64'h0000_0000_0000_8410, 32'h00000004, 0, 0, 16'h7777, 1'b1, 1'b1, 4, 16'h7756);
      bb_vec(64'hDEF0_9ABC_5678_1234, 32'hFFFFFFFF, 32, 32, 16'hFFFF, 1'b1, 1'b1, 256, 16'hDEF0);
      bb_vec(64'hDEF0_9ABC_5678_1234, 32'hCBCAC9C8, 0, 32, 16'h0F0F, 1'b0, 1'b1, 203, 16'h7B99);
      bb_vec(64'hF800_001F_F81F_07E0, 32'hFFFFFFFF, 1, 1, 16'h0000, 1'b0, 1'b0, 256, 16'h0F62);
      $display("       %0d hand-checked values", bb_nst);

      //--------------------------------------------------------------
      bb_fv[0] = 0; bb_fv[1] = 1; bb_fv[2] = 7; bb_fv[3] = 8; bb_fv[4] = 16; bb_fv[5] = 24; bb_fv[6] = 31; bb_fv[7] = 32;
      gpu_c_tex_filter(1'b1, 1'b0);
      $display("--- 1. every weight pair (fx, fy) in {0, 1, 7, 8, 16, 24, 31, 32}^2");
      for (bb_k = 0; bb_k < (bb_bl ? 3 : 1); bb_k = bb_k + 1)        // SRC_FMT 0 / MIX5 off, on; SRC_FMT 5
         for (bb_i = 0; bb_i < 8; bb_i = bb_i + 1)
            for (bb_j = 0; bb_j < 8; bb_j = bb_j + 1)
               bb_one_w(bb_fv[bb_i], bb_fv[bb_j], bb_k == 2, bb_k >= 1);
      $display("       taps per pixel: 1 %0d, 2 %0d, 4 %0d", gpu_bil_ntap[1], gpu_bil_ntap[2], gpu_bil_ntap[4]);
      if ((gpu_bil_ntap[1] == 0) || (gpu_bil_ntap[2] == 0) || (gpu_bil_ntap[4] == 0) || (gpu_bil_ntap[3] != 0))
         tb_error("taps per pixel: 1, 2 and 4 expected, 3 never (test bug)");

      $display("--- 2. texel-aligned starts and 90-degree turns: one tap per pixel");
      for (bb_k = 0; bb_k < 4; bb_k = bb_k + 1) begin
         bb_n = gpu_bil_ntap[1];
         bb_w = 8; bb_h = 5;
         gpu_c_size(bb_w, bb_h);
         gpu_c_dst(BB_DP, 2 * BB_DLO + 2 * BB_DP * 8 + 2 * bb_rnd(64));
         bb_src(bb_k[0], 16'd0);
         gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
         gpu_c_uv(16'd32 + 64 * bb_rnd(8), 16'd32 + 64 * bb_rnd(8));               // texel centres
         case (bb_k)
           0: begin gpu_c_step(16'd2048, 16'd0);     gpu_c_step_row(16'd0, 16'd2048);     end   // 0 degrees
           1: begin gpu_c_step(16'd0, 16'd2048);     gpu_c_step_row(-16'sd2048, 16'd0);   end   // 90
           2: begin gpu_c_step(-16'sd2048, 16'd0);   gpu_c_step_row(16'd0, -16'sd2048);   end   // 180
           default: begin gpu_c_step(16'd0, -16'sd2048); gpu_c_step_row(16'd2048, 16'd0); end  // 270
         endcase
         bb_run(1, "texel-aligned bilinear");
         if (gpu_bil_ntap[1] - bb_n != bb_w * bb_h) tb_error("texel-aligned blit not one tap per pixel (test bug)");
      end

      $display("--- 3. zoom-in and zoom-out");
      for (bb_k = 0; bb_k < 8; bb_k = bb_k + 1) begin
         bb_w = 15; bb_h = 6;
         gpu_c_size(bb_w, bb_h);
         gpu_c_dst(BB_DP, 2 * BB_DLO + 2 * BB_DP * 8 + 2 * bb_rnd(64));
         if (bb_bl) gpu_c_alpha5(1'b0, 8'd0, bb_rnd(2));
         bb_src(bb_rnd(2), 16'd0);
         gpu_c_tex(4'd5, 4'd5, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
         gpu_c_uv(bb_rnd(2048), bb_rnd(2048));
         bb_r = (bb_k % 4 == 0) ? 512 : (bb_k % 4 == 1) ? 1024 : (bb_k % 4 == 2) ? 4096 : 6144;   // 1/4, 1/2, 2, 3
         gpu_c_step(bb_r[15:0], 16'd0);
         gpu_c_step_row(16'd0, bb_r[15:0]);
         bb_run(1, "bilinear zoom");
      end

      $display("--- 4. random affine blits");
      for (bb_i = 0; (bb_i < 120) && (error == 0); bb_i = bb_i + 1) begin
         bb_kind = bb_rnd(3);
         if ((bb_kind == 2) && (GPU_TRI_EN == 0)) bb_kind = 1;
         if (bb_rnd(10) == 0) gpu_set_mode(4 + bb_rnd(4));
         bb_rand(bb_kind);
      end
      $display("       alpha256 0 %0d, 256 %0d, between %0d; keyed taps %0d",
               gpu_bil_na0, gpu_bil_na256, gpu_bil_nmid, gpu_bil_nkey);

      $display("--- 5. BILINEAR 0 again: nearest");
      gpu_c_tex_filter(1'b0, 1'b0);
      for (bb_i = 0; bb_i < 6; bb_i = bb_i + 1) bb_rand(bb_rnd(2));
      $display("--- 6. palette modes: nearest with BILINEAR");
      gpu_c_tex_filter(1'b1, 1'b0);
      for (bb_k = 0; bb_k < 4; bb_k = bb_k + 1) begin
         gpu_set_mode(bb_k);
         if (bb_bl) gpu_c_alpha(1'b0, 8'd0);
         bb_w = 12;
         gpu_c_dst(BB_DP, (BB_DLO << (5 - bb_k)) + BB_DP * 4 + bb_rnd(64));
         gpu_k_a8 = 1'b0;
         gpu_c_src(16'd0, (BB_TLO << (5 - bb_k)) + bb_rnd(64));
         gpu_c_tex(4'd3, 4'd3, bb_rnd(2), 3'b000, 1'b0, 1'b0, bb_rnd(4));
         gpu_c_uv(bb_rnd(512), bb_rnd(512));
         gpu_c_step(16'd700, 16'd300);
         bb_run(0, "palette mode, BILINEAR set");
      end
      gpu_set_mode(4);
      gpu_c_tex_filter(1'b0, 1'b0);
      if (bb_bl) gpu_c_alpha(1'b0, 8'd0);
      gpu_check_all("gpu_bil_basic end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
