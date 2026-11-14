//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_bil_edges
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_bil_edges.v
// Module Description : Bilinear sampling at the texture edges, against
//                      gpu_model.v (16 bpp; GPU_BILINEAR_EN and GPU_XY_EN):
//                      - SET_TEX BOUND with TBORDER 1 (blend builds: the taps
//                        outside the box transparent, not read) and 0 (clamp:
//                        the edge texel read twice), along each box edge and
//                        through each corner: spans in u and v over
//                        [-1.5, TW + 1.5) in 1/8 texel steps, so x0 = -1 and
//                        x0 + 1 = TW, the BOUND pixel skip on floor(u) and
//                        every weight near the edge occur; boxes smaller and
//                        larger than a power-of-two texture, free pitch;
//                      - power-of-two wrap seams without BOUND (u across
//                        2^lw, v across 2^lh, the taps wrapping);
//                      - keyed taps (TRANSP_EN, blend builds: alpha 0; the
//                        no-blend build samples nearest), SET_ALPHA EN per
//                        tap (A 0, 1, 128, 255 and random), MIX5, RGB565A8
//                        taps;
//                      - rotated blits over the box (TEXRECT, row steps).
//                      Each blit: the image, the allowed words (a tap
//                      dropped outside the box reads nothing).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer BE_TLO  = 4096;
localparam integer BE_ALO  = 8192;
localparam integer BE_DLO  = 10240;
localparam integer BE_DP   = 128;

integer    be_i, be_k, be_w, be_h, be_tw, be_th, be_nb0, be_nc0;
reg        be_bl, be_tb;
reg        be_fk = 1'b0;                 // be_tex: key texel (0, 0), TRANSP_EN
reg [31:0] be_t;
reg [15:0] be_u0, be_v0, be_du, be_dv;

function integer be_rnd;
   input integer n;
   begin
      be_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task be_run;
   input integer kind;                   // 0 TEXSPAN of be_w, 1 TEXRECT
   input [8*40-1:0] label;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_alw_clear;
      gpu_alw_start;
      if (kind == 0) gpu_c_texspan(0, be_w);
      else           gpu_c_texrect(0);
      gpu_wait_idle;
      gpu_alw_stop;
      gpu_k_a8 = 1'b0;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched(label);
   end
endtask

// The texture (a power of two lw x lh, or free pitch pf), its source format,
// the key, the blend settings
task be_tex;
   input  [3:0] lw;
   input  [3:0] lh;
   input        free;
   input        bound;
   input        ten;
   begin
      gpu_k_a8 = be_bl && be_rnd(2);
      gpu_c_src(free ? (16'd20 + be_rnd(30)) : 16'd0, 2 * BE_TLO + 64 + be_rnd(128));
      if (gpu_k_a8) gpu_c_alpha_plane(4 * BE_ALO + 64 + be_rnd(128));
      if (be_fk) gpu_c_transp(gpu_get_px(gpu_m_src_base, 4));
      else       gpu_c_transp(be_rnd(2) ? gpu_get_px(gpu_m_src_base + be_rnd(8), 4) : $random(gpu_seed));
      if (be_bl) begin
         be_k = be_rnd(8);
         gpu_c_alpha5(be_rnd(3) == 0, (be_k == 0) ? 8'd0 : (be_k == 1) ? 8'd1 : (be_k == 2) ? 8'd128 :
                                      (be_k == 3) ? 8'd255 : be_rnd(256), be_rnd(2));
      end
      gpu_c_tex(lw, lh, ten | be_fk, 3'b000, free, bound, 8'h00);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: bilinear sampling at the edges    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BILINEAR_EN == 0) || (GPU_XY_EN == 0))
         tb_skip_finish("|   (GPU_BILINEAR_EN / GPU_XY_EN = 0: absent)   |");
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;
      be_bl = (GPU_BLEND_EN != 0);
      gpu_preload_rand(0, VRAM_WORDS);
      for (be_i = BE_ALO; be_i < BE_ALO + 1024; be_i = be_i + 1)       // alphas: mostly 0 / 255
         if (be_rnd(3) != 0) begin
            be_t = {be_rnd(2) ? 8'hFF : 8'h00, be_rnd(2) ? 8'hFF : 8'h00, be_rnd(2) ? 8'hFF : 8'h00, be_rnd(2) ? 8'hFF : 8'h00};
            vram_mem[be_i] = be_t;
         end
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);

      //--------------------------------------------------------------
      $display("--- 1. BOUND: spans across each box edge and corner, TBORDER and clamp");
      for (be_i = 0; (be_i < 48) && (error == 0); be_i = be_i + 1) begin
         be_tb = be_bl && be_i[0];
         gpu_c_tex_filter(1'b1, be_tb);
         be_tw = 1 + be_rnd(12);
         be_th = 1 + be_rnd(12);
         // 0 / 1: power of two, box smaller / larger; 2: free pitch
         be_k  = be_i % 3;
         // the first two corner spans (TBORDER, clamp) key texel (0, 0), which
         // they sample: a keyed tap whatever the seed
         be_fk = be_bl && ((be_i == 6) || (be_i == 7));
         be_tex(4'd3, 4'd3, be_k == 2, 1'b1, be_rnd(4) == 0);
         be_fk = 1'b0;
         gpu_c_texbox(be_tw, be_th);
         be_w = 8 * (be_tw + 3) + be_rnd(8);
         if (be_w > GPU_DIM_MASK) be_w = GPU_DIM_MASK;
         gpu_c_dst(BE_DP, 2 * BE_DLO + 2 * BE_DP * 4 + 2 * be_rnd(BE_DP * 8) + be_rnd(2));
         // along u (v inside, or at the top / bottom edge: a corner) or along v
         case ((be_i / 2) % 4)
           0: begin be_u0 = -16'sd96; be_v0 = 16'd32 + 64 * be_rnd(be_th);              be_du = 16'd256; be_dv = 16'd0;   end
           1: begin be_u0 = -16'sd96; be_v0 = be_rnd(2) ? 16'd16 : (64 * be_th - 16);   be_du = 16'd256; be_dv = 16'd0;   end
           2: begin be_u0 = 16'd32 + 64 * be_rnd(be_tw); be_v0 = -16'sd96;              be_du = 16'd0;   be_dv = 16'd256; end
           default: begin be_u0 = -16'sd96 + be_rnd(16); be_v0 = -16'sd96 + be_rnd(16); be_du = 16'd256; be_dv = 16'd256; end
         endcase
         if (be_dv != 0) be_w = 8 * (be_th + 3) + be_rnd(8);
         if (be_w > GPU_DIM_MASK) be_w = GPU_DIM_MASK;
         gpu_c_uv(be_u0, be_v0);
         gpu_c_step(be_du, be_dv);
         be_nb0 = gpu_bil_nborder;
         be_nc0 = gpu_bil_nclamp;
         be_run(0, be_tb ? "BOUND TBORDER edge" : "BOUND clamp edge");
         if (gpu_x_bilx && (be_tb ? (gpu_bil_nborder == be_nb0) : (gpu_bil_nclamp == be_nc0)))   // (nearest: no-blend key)
            tb_error("edge span with no tap outside the box (test bug)");
      end
      $display("       %0d taps dropped outside the box, %0d clamped, %0d BOUND-skipped pixels",
               gpu_bil_nborder, gpu_bil_nclamp, gpu_bil_nbskip);

      $display("--- 2. rotated blits over the box");
      for (be_i = 0; (be_i < 24) && (error == 0); be_i = be_i + 1) begin
         be_tb = be_bl && be_rnd(2);
         gpu_c_tex_filter(1'b1, be_tb);
         be_tw = 2 + be_rnd(14);
         be_th = 2 + be_rnd(14);
         be_tex(4'd4, 4'd4, be_rnd(3) == 0, 1'b1, be_rnd(4) == 0);
         gpu_c_texbox(be_tw, be_th);
         be_w = 4 + be_rnd(20); be_h = 4 + be_rnd(14);
         if (be_w > GPU_DIM_MASK) be_w = GPU_DIM_MASK;
         if (be_h > GPU_DIM_MASK) be_h = GPU_DIM_MASK;
         gpu_c_size(be_w, be_h);
         gpu_c_dst(BE_DP, 2 * BE_DLO + 2 * BE_DP * 4 + 2 * be_rnd(BE_DP * 4) + be_rnd(2));
         gpu_c_uv(-16'sd128 + be_rnd(128), -16'sd128 + be_rnd(128));
         be_du = 1100 + be_rnd(900); be_dv = 300 + be_rnd(900);
         gpu_c_step(be_du, be_dv);
         gpu_c_step_row(-be_dv, be_du);
         be_run(1, "rotated bilinear over the box");
      end

      $display("--- 3. power-of-two wrap seams (no BOUND)");
      for (be_i = 0; (be_i < 24) && (error == 0); be_i = be_i + 1) begin
         gpu_c_tex_filter(1'b1, 1'b0);
         be_k = 1 + be_rnd(4);
         be_tex(be_k, (be_i < 4) ? 4'd0 : (1 + be_rnd(4)), 1'b0, 1'b0, be_rnd(4) == 0);
         be_w = 48;
         gpu_c_dst(BE_DP, 2 * BE_DLO + 2 * BE_DP * 4 + 2 * be_rnd(BE_DP * 8) + be_rnd(2));
         // from just before the seam, across it, in u, v or both, both directions
         be_u0 = ((1 << be_k) << 6) - 16'd80 + be_rnd(32);
         be_v0 = (be_i < 4) ? be_rnd(64) : (16'd1024 - 16'd80 + be_rnd(32));
         gpu_c_uv(be_u0, be_v0);
         be_du = be_rnd(2) ? (16'd200 + be_rnd(300)) : -(16'sd200 + be_rnd(300));
         be_dv = be_rnd(2) ? (16'd200 + be_rnd(300)) : 16'd0;
         gpu_c_step(be_du, be_dv);
         be_run(0, "bilinear wrap seam");
      end

      gpu_c_tex_filter(1'b0, 1'b0);
      if (be_bl) gpu_c_alpha(1'b0, 8'd0);
      $display("       keyed taps %0d; alpha256 0 %0d, 256 %0d, between %0d", gpu_bil_nkey, gpu_bil_na0,
               gpu_bil_na256, gpu_bil_nmid);
      if (be_bl && (gpu_bil_nkey == 0)) tb_error("no keyed tap (test bug)");
      gpu_check_all("gpu_bil_edges end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
