//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_a8_tex
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_a8_tex.v
// Module Description : RGB565A8 textures (SET_SRC SRC_FMT 5, SET_AUX
//                      ALPHA_PLANE; GPU_BLEND_EN): the alpha of the texel at
//                      address base + v * pitch + u is the byte at the alpha
//                      pointer + v * pitch + u. Against gpu_model.v, at
//                      16 bpp (modes 4..7): EXEC_TEXSPAN, EXEC_TEXRECT
//                      (GPU_XY_EN) and textured triangles (GPU_TRI_EN), with
//                      power-of-two textures (the texel and its alpha wrap
//                      together), free-pitch textures, BOUND with boxes
//                      smaller and larger than the texture (a skipped pixel
//                      reads neither), TRANSP_EN (the key on the raw texel
//                      first, then the alpha), the texture swaps, SET_ALPHA
//                      EN (alpha o A), MIX5 on and off, odd alpha offsets,
//                      icon-like, edge and random alpha planes, x/y and
//                      address destinations, clip windows. Each blit: the
//                      image (window read of the touched words) and the
//                      allowed words (texels and A8 words of the pixels the
//                      walk reads, the destination words of the pixels it
//                      visits). Palette modes: SRC_FMT 5 acts as 0 and no A8
//                      word is read.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer AT_TLO  = 4096;               // textures: words [4096, 6144)
localparam integer AT_TSZ  = 2048;
localparam integer AT_ALO  = 8192;               // A8 planes: words [8192, 9728)
localparam integer AT_ASZ  = 1536;
localparam integer AT_DLO  = 10240;              // destinations: words [10240, 14336)
localparam integer AT_DSZ  = 4096;
localparam integer AT_DP   = 128;                // destination pitch
localparam integer AT_N    = 160;

integer    at_i, at_k, at_kind, at_w, at_h, at_x, at_y, at_lw, at_lh, at_pf, at_r;
integer    at_cnt [0:3];
integer    at_nm5, at_nen, at_nkey, at_nbnd, at_nfree, at_a0;
reg        at_xy, at_bnd, at_fre, at_ten;
reg [31:0] at_tb, at_ab, at_t;

function integer at_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      at_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task at_plane_fill;                      // 0 random, 1 icon-like, 2 the rule's edges
   input integer kind;
   integer       ww, bb, r;
   reg    [31:0] vv;
   reg     [7:0] b;
   begin
      for (ww = AT_ALO; ww < AT_ALO + AT_ASZ; ww = ww + 1) begin
         vv = 32'h0;
         for (bb = 0; bb < 4; bb = bb + 1) begin
            r = at_rnd(12);
            case (kind)
              0:       b = $random(gpu_seed);
              1:       b = (at_rnd(8) == 0) ? at_rnd(256) : (at_rnd(2) ? 8'd255 : 8'd0);
              default: b = (r == 0) ? 8'd0 : (r == 1) ? 8'd3 : (r == 2) ? 8'd4 : (r == 3) ? 8'd251 :
                           (r == 4) ? 8'd252 : (r == 5) ? 8'd253 : (r == 6) ? 8'd254 : 8'd255;
            endcase
            vv = vv | (b << (8 * bb));
         end
         vram_mem[ww]   = vv;
         gpu_shadow[ww] = vv;
      end
   end
endtask

task at_dest;
   integer x0, y0, x1, y1;
   begin
      if (at_xy) begin
         gpu_c_dst_xy(AT_DP, 2 * AT_DLO + 2 * AT_DP * 4 + 40);
         at_x = at_rnd(40) - 8;
         at_y = at_rnd(12) - 3;
         gpu_c_xy(at_x, at_y);
         if (at_rnd(3) == 0)
            gpu_c_noclip;
         else begin
            x0 = at_x + at_rnd(6) - 3;
            y0 = at_y + at_rnd(4) - 2;
            gpu_c_clip(x0, y0, x0 + 2 + at_rnd(at_w + 2), y0 + 1 + at_rnd(at_h + 2));
         end
      end else
         gpu_c_dst(AT_DP, 2 * AT_DLO + 2 * AT_DP * 4 + 2 * at_rnd(AT_DP * 20) + at_rnd(2));
   end
endtask

// The texture: power of two (lw, lh 2..5) or free pitch; BOUND (x/y builds);
// its alpha plane at an odd or even offset
task at_tex;
   reg [15:0] du, dv;
   begin
      at_bnd = (GPU_XY_EN != 0) && at_rnd(2);
      at_fre = at_rnd(3) == 0;
      at_ten = at_rnd(3) == 0;
      at_lw  = 2 + at_rnd(4);
      at_lh  = 2 + at_rnd(4);
      at_pf  = at_fre ? (16 + at_rnd(48)) : 0;
      at_tb  = 2 * AT_TLO + 64 + at_rnd(256);
      at_ab  = 4 * AT_ALO + 64 + at_rnd(256);
      gpu_k_a8 = 1'b1;
      gpu_c_src(at_pf, at_tb);
      gpu_c_alpha_plane(at_ab);
      // a key present in the texture now and then
      at_t = at_rnd(2) ? gpu_get_px(at_tb + at_rnd(16), 4) : $random(gpu_seed);
      gpu_c_transp(at_t);
      gpu_c_tex(at_lw, at_lh, at_ten, at_rnd(8), at_fre, at_bnd, 8'h00);
      gpu_c_uv((at_rnd(10) << 6) + at_rnd(64) - (at_bnd ? 16'd200 : 16'd0), (at_rnd(10) << 6) + at_rnd(64) - (at_bnd ? 16'd120 : 16'd0));
      // a free-pitch texture without BOUND does not wrap: steps >= 0 there
      du = at_rnd(3000) - ((at_fre && !at_bnd) ? 0 : 1000);
      dv = at_rnd(2000) - ((at_fre && !at_bnd) ? 0 : 1000);
      gpu_c_step(du, dv);
      if (GPU_XY_EN != 0) begin
         gpu_c_step_row(at_rnd(2000) - ((at_fre && !at_bnd) ? 0 : 1000), at_rnd(3000) - ((at_fre && !at_bnd) ? 0 : 1000));
         gpu_c_texbox(2 + at_rnd(at_fre ? 20 : 40), 2 + at_rnd(at_fre ? 20 : 40));
      end
      if (at_bnd) at_nbnd = at_nbnd + 1;
      if (at_fre) at_nfree = at_nfree + 1;
      if (at_ten) at_nkey = at_nkey + 1;
   end
endtask

task at_alpha;
   integer r;
   reg [7:0] a;
   begin
      r = at_rnd(8);
      a = (r == 0) ? 8'd0 : (r == 1) ? 8'd255 : (r == 2) ? 8'd128 : at_rnd(256);
      gpu_c_alpha5(at_rnd(3) == 0, a, at_rnd(3) != 0);
      if (gpu_m_mix5) at_nm5 = at_nm5 + 1;
      if (gpu_m_aen)  at_nen = at_nen + 1;
   end
endtask

task at_one;
   input integer kind;
   integer       ww;
   begin
      at_w = 2 + at_rnd(16);
      at_h = 1 + at_rnd(8);
      gpu_c_size(at_w, at_h);
      at_plane_fill(at_rnd(3));
      at_dest;
      at_alpha;
      at_tex;
      gpu_wait_idle;
      gpu_alw_clear;
      gpu_alw_start;
      case (kind)
        0: gpu_c_texspan(at_rnd(5) - 2, at_w);
        1: gpu_c_texrect(at_xy ? (at_rnd(5) - 2) : 0);
        default: begin
              gpu_c_vtx(0, 16 * at_x + at_rnd(32) - 16, 16 * at_y + at_rnd(32) - 16);
              gpu_c_vtx(1, 16 * (at_x + at_w + at_rnd(6)) + at_rnd(16), 16 * (at_y + at_rnd(4)) + at_rnd(16));
              gpu_c_vtx(2, 16 * (at_x + at_rnd(at_w)) + at_rnd(16), 16 * (at_y + at_h + at_rnd(4)) + at_rnd(16));
              gpu_alw_clear;                                 // (the vertices pushed: no access)
              gpu_c_tritex;
           end
      endcase
      gpu_wait_idle;
      gpu_alw_stop;
      gpu_k_a8 = 1'b0;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_ERR | IF_OVFL);
      gpu_check_touched("RGB565A8 texture");
      at_cnt[kind] = at_cnt[kind] + 1;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: RGB565A8 textures                 |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BLEND_EN == 0))
         tb_skip_finish("|      (GPU_BLEND_EN = 0: no RGB565A8 source)   |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;
      gpu_rsv_seed = `SEED ^ 32'h0A8_7E7;
      gpu_push_wait = 1'b1;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      at_nm5 = 0; at_nen = 0; at_nkey = 0; at_nbnd = 0; at_nfree = 0;
      for (at_k = 0; at_k < 4; at_k = at_k + 1) at_cnt[at_k] = 0;
      at_a0 = gpu_a8_nrd;
      for (at_i = 0; (at_i < AT_N) && (error == 0); at_i = at_i + 1) begin
         at_kind = at_rnd(3);
         if ((at_kind == 1) && (GPU_XY_EN == 0)) at_kind = 0;
         if ((at_kind == 2) && ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0))) at_kind = (GPU_XY_EN != 0) ? 1 : 0;
         if (gpu_m_mode < 3'd4 || at_rnd(10) == 0) gpu_set_mode(4 + at_rnd(4));
         at_xy = (GPU_XY_EN != 0) && ((at_kind == 2) || at_rnd(3) != 0);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         at_one(at_kind);
      end
      $display("       TEXSPAN %0d TEXRECT %0d textured TRI %0d: %0d MIX5, %0d EN, %0d keyed, %0d BOUND, %0d free pitch; %0d A8 word reads (model)",
               at_cnt[0], at_cnt[1], at_cnt[2], at_nm5, at_nen, at_nkey, at_nbnd, at_nfree, gpu_a8_nrd - at_a0);
      if (gpu_a8_nrd == at_a0) tb_error("no A8 word read (test bug)");

      $display("--- palette modes: SRC_FMT 5 acts as 0, no A8 word read");
      for (at_k = 0; (at_k < 4) && (error == 0); at_k = at_k + 1) begin
         gpu_set_mode(at_k);
         at_a0 = gpu_a8_nrd;
         at_w = 12; at_h = 3;
         gpu_c_size(at_w, at_h);
         at_xy = 1'b0;
         gpu_c_dst(AT_DP, (AT_DLO << (5 - at_k)) + AT_DP * 4 + at_rnd(64));
         gpu_c_alpha5(1'b1, 8'd90, 1'b1);
         gpu_k_a8 = 1'b1;
         gpu_c_src(16'd0, (AT_TLO << (5 - at_k)) + at_rnd(64));
         gpu_c_alpha_plane(AT_ALO * 4 + at_rnd(64));
         gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
         gpu_c_uv(16'd0, 16'd0);
         gpu_c_step(16'd1500, 16'd300);
         for (at_i = AT_ALO; at_i < AT_ALO + AT_ASZ; at_i = at_i + 1) gpu_alw[at_i] = 1'b0;
         gpu_wait_idle;
         gpu_alw_start;
         gpu_c_texspan(0, at_w);
         gpu_wait_idle;
         gpu_alw_stop;
         gpu_k_a8 = 1'b0;
         if (gpu_a8_nrd != at_a0) tb_error("model read the A8 plane in a palette mode (model bug)");
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("palette texture, SRC_FMT 5");
      end
      gpu_set_mode(4);
      gpu_c_alpha(1'b0, 8'd0);
      gpu_c_src_fmt(16'd0, 32'h0, 4'h0);
      gpu_check_all("gpu_a8_tex end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
