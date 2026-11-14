//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_mix5
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_mix5.v
// Module Description : SET_ALPHA [9] MIX5, LVGL's blend rule, in every blend
//                      at 16 bpp (GFX_MODE 4..7), against the shared model
//                      (gpu_model.v: factor 8 m, m = (alpha + 4) >> 3, the
//                      result d + floor((s - d) 8 m / 256), coverage x A as
//                      (c A) >> 8). The model's arithmetic is checked first
//                      against hand-computed values (the spec harness's
//                      hw() formula, equal to LVGL's lv_color_16_16_mix) and
//                      against LVGL's packed 0x07E0F81F mix written here on
//                      random triples. Then:
//                      - blended FILL, COPY, COPY_TRANSP, SPAN, EXPAND,
//                        EXPAND MASK (A1 / A2 / A4 / A8), TEXSPAN, TEXRECT,
//                        flat and textured triangles, copies through the
//                        mask plane, immediate copies and EXPAND MASK,
//                        anti-aliased lines, in x/y mode with clip windows
//                        and in address mode, every raster op, MIX5 mostly
//                        on, A at the rule's edges (0, 1, 3, 4, 251, 252,
//                        253, 254, 255) and random, EN on and off;
//                      - MIX5 with EN = 0 acts on MASK and AA lines only;
//                      - MIX5 back to 0: today's rounding (a value the two
//                        rules draw differently); RESET_STATE clears MIX5
//                        (an EXPAND MASK after it rounds);
//                      - palette modes: MIX5 has no effect.
//                      The reserved command bits (SET_ALPHA [23:10] too)
//                      are set at random. Each primitive's touched words
//                      are read through the VRAM window; the whole VRAM is
//                      compared at the end.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer MX_DISPW  = 64;
localparam integer MX_SRC_LO = 1000;             // sources, textures: words [MX_SRC_LO, MX_SRC_HI)
localparam integer MX_SRC_HI = 3000;
localparam integer MX_MSK_W  = 3000;             // mask plane: words [3000, 3400)
localparam integer MX_DST_W  = 9000;             // x/y origin (16 bpp pixel 2 * MX_DST_W)
localparam integer MX_ADR_W  = 20000;            // address-mode destinations: words [20000, 30000)
localparam integer MX_N      = 160;

integer    mx_i, mx_kind, mx_mode, mx_x, mx_y, mx_w, mx_h, mx_n, mx_sdep, mx_k;
integer    mx_cnt [0:15];
integer    mx_nst, mx_j, mx_s, mx_d, mx_a;
reg [15:0] mx_v, mx_l;
reg [31:0] mx_t;
reg        mx_xy, mx_ok, mx_opq;
integer    mx_nmo = 0;                   // EXPAND MASK with OPAQUE drawn
reg [31:0] mx_caps;
reg [15:0] mx_c [0:3];

function integer mx_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      mx_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task mx_alpha;                           // A at the rule's edges or random, EN mostly on, MIX5 mostly on
   integer r;
   reg [7:0] a;
   begin
      r = mx_rnd(14);
      case (r)
        0: a = 8'd0;   1: a = 8'd1;   2: a = 8'd3;   3: a = 8'd4;   4: a = 8'd251;
        5: a = 8'd252; 6: a = 8'd253; 7: a = 8'd254; 8: a = 8'd255;
        default: a = mx_rnd(256);
      endcase
      gpu_c_alpha5(mx_rnd(8) != 0, a, mx_rnd(6) != 0);
   end
endtask

// Destination: x/y mode (origin, position, clip window with negative values)
// or address mode
task mx_dest;
   integer x0, y0, x1, y1;
   begin
      if (mx_xy) begin
         gpu_c_dst_xy(16'd128, 2 * MX_DST_W + 2 * mx_rnd(400));
         mx_x = mx_rnd(40) - 10;
         mx_y = mx_rnd(20) - 5;
         gpu_c_xy(mx_x, mx_y);
         if (mx_rnd(4) == 0)
            gpu_c_noclip;
         else begin
            x0 = mx_x + mx_rnd(6) - 3;
            y0 = mx_y + mx_rnd(4) - 2;
            x1 = x0 + 2 + mx_rnd(mx_w + 2);
            y1 = y0 + 1 + mx_rnd(mx_h + 2);
            gpu_c_clip(x0, y0, x1, y1);
         end
      end else
         gpu_c_dst(16'd90 + mx_rnd(60), 2 * MX_ADR_W + 2 * mx_rnd(9000) + mx_rnd(2));
   end
endtask

task mx_grad;                            // gradient on FILL / SPAN / TRI (when built)
   begin
      if ((GPU_GRAD_EN != 0) && mx_rnd(2)) begin
         if (mx_rnd(2))
            gpu_c_grad_rgb(1 + mx_rnd(3), mx_rnd(2), mx_rnd(512) - 256, mx_rnd(512) - 256, mx_rnd(512) - 256, 1'b1);
         else
            gpu_c_grad(1 + mx_rnd(4), mx_rnd(2), mx_rnd(16) - 8, 1'b1);
      end else if (GPU_GRAD_EN != 0)
         gpu_c_grad(0, 1'b0, 0, 1'b0);
   end
endtask

task mx_grad_off;
   begin
      if (GPU_GRAD_EN != 0) gpu_c_grad(0, 1'b0, 0, 1'b0);
   end
endtask

task mx_tex;                             // texture state (BOUND only in x/y builds)
   reg bnd, fre;
   begin
      bnd = mx_xy && mx_rnd(2);
      fre = mx_rnd(3) == 0;
      gpu_c_tex(3 + mx_rnd(3), 3 + mx_rnd(3), mx_rnd(2), mx_rnd(8), fre, bnd, mx_rnd(4));
      gpu_c_uv((mx_rnd(10) << 6) + mx_rnd(64), (mx_rnd(10) << 6) + mx_rnd(64));
      // a free-pitch texture without BOUND does not wrap: steps >= 0 there
      gpu_c_step(mx_rnd(3000) - ((fre && !bnd) ? 0 : 1000), mx_rnd(2000) - ((fre && !bnd) ? 0 : 1000));
      if (mx_xy) begin
         gpu_c_step_row(mx_rnd(2000) - ((fre && !bnd) ? 0 : 1000), mx_rnd(3000) - ((fre && !bnd) ? 0 : 1000));
         gpu_c_texbox(4 + mx_rnd(20), 4 + mx_rnd(20));
      end
   end
endtask

task mx_src;                             // copy / texture source (16 bpp), pitch 40..80
   begin
      gpu_c_src_fmt(16'd40 + mx_rnd(40), 2 * (MX_SRC_LO + 20 + mx_rnd(800)) + mx_rnd(2), 4'h0);
   end
endtask

task mx_vtx;                             // a triangle around the x/y position
   begin
      gpu_c_vtx(0, 16 * mx_x + mx_rnd(32) - 16, 16 * mx_y + mx_rnd(32) - 16);
      gpu_c_vtx(1, 16 * (mx_x + mx_w + mx_rnd(6)) + mx_rnd(16), 16 * (mx_y + mx_rnd(4)) + mx_rnd(16));
      gpu_c_vtx(2, 16 * (mx_x + mx_rnd(mx_w)) + mx_rnd(16), 16 * (mx_y + mx_h + mx_rnd(4)) + mx_rnd(16));
   end
endtask

task mx_mask_expand;                     // an EXPAND MASK of random depth at the destination
   begin
      mx_sdep = mx_rnd(4);
      gpu_c_src_fmt(16'd0, ((MX_SRC_LO + mx_rnd(800)) << (5 - mx_sdep)) + mx_rnd(32 >> mx_sdep), 4'd1 + mx_sdep);
      gpu_exp_mask = 1'b1;
      gpu_exp_op   = mx_rnd(16);
      gpu_c_expand(0, mx_rnd(8), 1'b0, mx_sdep);
      gpu_exp_mask = 1'b0;
      gpu_exp_op   = 4'd0;
   end
endtask

task mx_one;
   input integer kind;
   reg   [2:0] dsw, ssw;
   reg   [3:0] op;
   begin
      mx_w = 2 + mx_rnd(14);
      mx_h = 1 + mx_rnd(8);
      dsw  = mx_rnd(8);
      ssw  = mx_rnd(8);
      op   = mx_rnd(16);
      gpu_c_size(mx_w, mx_h);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp({16'h0, mx_c[mx_rnd(4)]});
      mx_dest;
      mx_alpha;
      case (kind)
        0: begin                                                 // FILL (gradient)
              mx_grad;
              gpu_c_exec_xy(GPU_FILL, op, dsw, 3'b000);
              mx_grad_off;
           end
        1: begin                                                 // COPY
              mx_src;
              gpu_c_exec_xy(GPU_COPY, op, dsw, ssw);
           end
        2: begin                                                 // COPY_TRANSP
              mx_src;
              gpu_c_exec_xy(GPU_COPYT, op, dsw, ssw);
           end
        3: begin                                                 // SPAN (gradient), DELTA
              mx_grad;
              gpu_c_span(mx_rnd(9) - 4, mx_w);
              gpu_c_span(mx_rnd(9) - 4, mx_w);
              mx_grad_off;
           end
        4, 5: begin                                              // EXPAND (5: MASK), DELTA
              mx_sdep = mx_rnd(4);
              gpu_c_src_fmt(16'd0, ((MX_SRC_LO + mx_rnd(800)) << (5 - mx_sdep)) + mx_rnd(32 >> mx_sdep),
                            4'd1 + mx_sdep);
              gpu_exp_mask = (kind == 5);
              gpu_exp_op   = mx_rnd(16);
              mx_opq = mx_rnd(2);
              if (gpu_exp_mask && mx_opq && (gpu_m_mode >= 3'd4)) mx_nmo = mx_nmo + 1;
              gpu_c_expand(mx_rnd(5) - 2, dsw, mx_opq, mx_sdep);          // (OPAQUE: no effect with MASK)
              gpu_exp_mask = 1'b0;
              gpu_exp_op   = 4'd0;
           end
        6: begin                                                 // TEXSPAN
              mx_src;
              mx_tex;
              gpu_c_texspan(mx_rnd(5) - 2, mx_w);
           end
        7: begin                                                 // TEXRECT
              mx_src;
              mx_tex;
              gpu_c_texrect(mx_xy ? (mx_rnd(5) - 2) : 0);
           end
        8: begin                                                 // flat triangle (gradient)
              mx_vtx;
              mx_grad;
              gpu_c_trifill(op);
              mx_grad_off;
           end
        9: begin                                                 // textured triangle
              mx_src;
              mx_tex;
              mx_vtx;
              gpu_tt_delta = $random(gpu_seed);                  // ignored with TRI
              gpu_c_tritex;
              gpu_tt_delta = 14'h0000;
           end
        10: begin                                                // COPY through the mask plane
              mx_src;
              gpu_c_mask_plane(32 * MX_MSK_W + mx_rnd(256), mx_rnd(2));
              gpu_k_mpl = 1'b1;
              gpu_c_exec_xy(mx_rnd(2) ? GPU_COPY : GPU_COPYT, op, dsw, ssw);
              gpu_k_mpl = 1'b0;
           end
        11: begin                                                // immediate COPY / COPY_TRANSP
              mx_n = (mx_w * mx_h + 1) / 2 + mx_rnd(3) - 1;      // exact, short or long
              for (mx_k = 0; mx_k < mx_n; mx_k = mx_k + 1)
                 gpu_imm_buf[mx_k] = {mx_c[mx_rnd(4)], mx_c[mx_rnd(4)]};
              gpu_c_imm(4'h0, mx_n);
              if (mx_caps[1] && mx_rnd(2)) begin
                 gpu_c_mask_plane(32 * MX_MSK_W + mx_rnd(256), mx_rnd(2));
                 gpu_k_mpl = 1'b1;
              end
              gpu_c_exec_xy(mx_rnd(2) ? GPU_COPY : GPU_COPYT, op, dsw, 3'b000);
              gpu_k_mpl = 1'b0;
           end
        13: begin                                                // anti-aliased line (x/y)
              gpu_c_pen(16 * mx_x + mx_rnd(16), 16 * mx_y + mx_rnd(16));
              gpu_c_line(16 * (mx_x + mx_rnd(mx_w + 4)) + mx_rnd(16), 16 * (mx_y + mx_rnd(mx_h + 4)) + mx_rnd(16),
                         (mx_rnd(3) == 0) ? mx_rnd(16) : 4'd0, {2'b00, mx_rnd(2) == 0, 1'b1});
           end
        default: begin                                           // immediate EXPAND MASK / EXPAND
              mx_sdep = mx_rnd(4);
              mx_n = (mx_w * mx_h * (1 << mx_sdep) + 31) / 32;
              for (mx_k = 0; mx_k < mx_n; mx_k = mx_k + 1)
                 gpu_imm_buf[mx_k] = $random(gpu_seed);
              gpu_c_imm(4'd1 + mx_sdep, mx_n);
              gpu_exp_mask = mx_rnd(3) != 0;
              gpu_exp_op   = mx_rnd(16);
              mx_opq = mx_rnd(2);
              if (gpu_exp_mask && mx_opq && (gpu_m_mode >= 3'd4)) mx_nmo = mx_nmo + 1;
              gpu_c_expand(0, dsw, mx_opq, mx_sdep);
              gpu_exp_mask = 1'b0;
              gpu_exp_op   = 4'd0;
           end
      endcase
   end
endtask

function mx_built;                       // the kind runs in this build
   input integer kind;
   begin
      case (kind)
        7:       mx_built = (GPU_XY_EN != 0);
        13:      mx_built = (GPU_XY_EN != 0) && (GPU_LINE_EN != 0);
        8, 9:    mx_built = (GPU_TRI_EN != 0) && (GPU_XY_EN != 0);
        10:      mx_built = mx_caps[1];
        11, 12:  mx_built = (GPU_IMM_EN != 0) && mx_caps[2];
        default: mx_built = 1'b1;
      endcase
   end
endfunction

// LVGL 9.6.0 lv_color_16_16_mix (misc/lv_color.c), the packed 0x07E0F81F form
// with its shortcuts: the reference the MIX5 rule must equal (spec 2.1)
function [15:0] mx_lv_mix;
   input [15:0] c1;
   input [15:0] c2;
   input  [7:0] mix;
   reg   [31:0] m, bg, fg, r;
   begin
      if (mix == 8'd255)    mx_lv_mix = c1;
      else if (mix == 8'd0) mx_lv_mix = c2;
      else if (c1 == c2)    mx_lv_mix = c1;
      else begin
         m  = (mix + 4) >> 3;
         bg = ({16'h0, c2} | ({16'h0, c2} << 16)) & 32'h07E0_F81F;
         fg = ({16'h0, c1} | ({16'h0, c1} << 16)) & 32'h07E0_F81F;
         r  = ((((fg - bg) * m) >> 5) + bg) & 32'h07E0_F81F;
         mx_lv_mix = r[31:16] | r[15:0];
      end
   end
endfunction

task mx_st16;                            // model self-test, 16-bit result
   input [15:0] got;
   input [15:0] exp;
   input [8*48-1:0] what;
   begin
      mx_nst = mx_nst + 1;
      tb_checks = tb_checks + 1;
      if (got !== exp) begin
         $display("ERROR: GPU model MIX5 self-test %0s: 0x%h, expected 0x%h %t", what, got, exp, $time);
         error = error + 1;
      end
   end
endtask

task mx_sti;
   input integer got;
   input integer exp;
   input [8*48-1:0] what;
   begin
      mx_nst = mx_nst + 1;
      tb_checks = tb_checks + 1;
      if (got != exp) begin
         $display("ERROR: GPU model MIX5 self-test %0s: %0d, expected %0d %t", what, got, exp, $time);
         error = error + 1;
      end
   end
endtask

// The MIX5 blend of the model: factor of alpha a, rounding 0
function [15:0] mx_m5;
   input [15:0] s;
   input [15:0] d;
   input  [7:0] a;
   integer      f;
   begin
      f = gpu_a_fac(a, 1'b1);
      mx_m5 = (f == 0) ? d : (f >= 256) ? s : gpu_blend565r(s, d, f, 0);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: MIX5 blend rule (LVGL) in every blend   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BLEND_EN == 0))
         tb_skip_finish("|          (GPU_BLEND_EN = 0: feature absent)       |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;                   // reserved / ignored command bits set at random
      gpu_rsv_seed = `SEED ^ 32'h5EED_0BAD;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;                 // FREE checked before each push (any FIFO depth)
      gpu_preload_rand(0, VRAM_WORDS);
      mx_c[0] = $random(gpu_seed);
      mx_c[1] = $random(gpu_seed);
      mx_c[2] = $random(gpu_seed);
      mx_c[3] = $random(gpu_seed);
      gpu_preload_pal(MX_SRC_LO, MX_SRC_HI, 4, mx_c[0], mx_c[1], mx_c[2], mx_c[3]);
      gpu_model_init;
      gpu_set_dispw(MX_DISPW);
      reg_rd_val(BLNS_CFG2, mx_caps);
      mx_caps = (mx_caps >> 8) & 32'h7;                          // [0] REMAP, [1] MPLANE, [2] IMM
      //--------------------------------------------------------------
      $display("--- 0. model self-test: MIX5 arithmetic against hand-computed values");
      mx_nst = 0;
      // (spec harness mix.c hw(): out = d + floor((s - d) m / 32) per field)
      mx_st16(mx_m5(16'hFFFF, 16'h0000, 8'd128), 16'h7BEF, "FFFF over 0000, 128");
      mx_st16(mx_m5(16'h0000, 16'hFFFF, 8'd128), 16'h7BEF, "0000 over FFFF, 128");
      mx_st16(mx_m5(16'hFFFF, 16'h0000, 8'd3),   16'h0000, "alpha 3: m = 0, skipped");
      mx_st16(mx_m5(16'hFFFF, 16'h0000, 8'd4),   16'h0020, "FFFF over 0000, 4 (m = 1)");
      mx_st16(mx_m5(16'h0000, 16'hFFFF, 8'd4),   16'hF7BE, "0000 over FFFF, 4 (floor)");
      mx_st16(mx_m5(16'hFFFF, 16'h0000, 8'd251), 16'hF7BE, "FFFF over 0000, 251 (m = 31)");
      mx_st16(mx_m5(16'h0000, 16'hFFFF, 8'd251), 16'h0020, "0000 over FFFF, 251");
      mx_st16(mx_m5(16'hFFFF, 16'h0000, 8'd252), 16'hFFFF, "252: m = 32, s");
      mx_st16(mx_m5(16'hF800, 16'h001F, 8'd128), 16'h780F, "F800 over 001F, 128");
      mx_st16(mx_m5(16'h1234, 16'h5678, 8'd100), 16'h34B6, "1234 over 5678, 100");
      mx_st16(mx_m5(16'hABCD, 16'h1357, 8'd200), 16'h83AF, "ABCD over 1357, 200");
      mx_st16(mx_m5(16'h07E0, 16'hF81F, 8'd60),  16'hB9F7, "07E0 over F81F, 60");
      mx_sti(gpu_a_fac(3, 1'b1), 0,     "factor of 3");
      mx_sti(gpu_a_fac(4, 1'b1), 8,     "factor of 4");
      mx_sti(gpu_a_fac(251, 1'b1), 248, "factor of 251");
      mx_sti(gpu_a_fac(252, 1'b1), 256, "factor of 252");
      mx_sti(gpu_a_fac(255, 1'b0), 256, "factor of 255, rounding rule");
      mx_sti(gpu_a_fac(254, 1'b0), 254, "factor of 254, rounding rule");
      mx_sti(gpu_a_comb(252, 8'd255, 1'b1), 251, "252 o 255 (MIX5)");
      mx_sti(gpu_a_comb(253, 8'd255, 1'b1), 252, "253 o 255 (MIX5)");
      mx_sti(gpu_a_comb(200, 8'd253, 1'b1), 197, "200 o 253 (MIX5)");
      mx_sti(gpu_a_comb(255, 8'd1, 1'b1),   0,   "255 o 1 (MIX5)");
      mx_sti(gpu_a_comb(200, 8'd253, 1'b0), 198, "200 o 253 (rounding)");
      mx_sti(gpu_a_comb(255, 8'd1, 1'b0),   1,   "255 o 1 (rounding)");
      mx_sti(gpu_a_comb(128, 8'd128, 1'b0), 64,  "128 o 128 (rounding)");
      mx_sti(gpu_a_mask5(32'h3, 2'd1, 1'b0, 8'd0, 1'b1), 256,   "A2 coverage 3 (255): opaque");
      mx_sti(gpu_a_mask5(32'h1, 2'd2, 1'b0, 8'd0, 1'b1), 16,    "A4 coverage 1 (17): m 2");
      mx_sti(gpu_a_mask5(32'hFC, 2'd3, 1'b1, 8'd255, 1'b1), 248, "A8 252 o 255: m 31");
      mx_sti(gpu_a_mask5(32'h80, 2'd3, 1'b1, 8'd128, 1'b0), 64, "A8 128 o 128, rounding rule");
      // MIX5 = 0 is today's rounding: gpu_blend565 itself
      mx_st16(gpu_blend565r(16'hFFFF, 16'h0000, 128, 128), gpu_blend565(16'hFFFF, 16'h0000, 128), "rounding rule = gpu_blend565");
      // LVGL's packed mix on random triples (and every alpha of a random pair)
      for (mx_j = 0; mx_j < 20000; mx_j = mx_j + 1) begin
         mx_s = $random(gpu_seed); mx_d = $random(gpu_seed); mx_a = $random(gpu_seed);
         if (mx_j < 256) mx_a = mx_j;
         if (mx_j % 97 == 0) mx_d = mx_s;
         mx_v = mx_m5(mx_s[15:0], mx_d[15:0], mx_a[7:0]);
         mx_l = mx_lv_mix(mx_s[15:0], mx_d[15:0], mx_a[7:0]);
         if (mx_v !== mx_l) begin
            if (error < 6)
               $display("ERROR: GPU model MIX5 0x%h over 0x%h alpha %0d: 0x%h, LVGL 0x%h %t", mx_s[15:0], mx_d[15:0],
                        mx_a[7:0], mx_v, mx_l, $time);
            error = error + 1;
         end
      end
      tb_checks = tb_checks + 1;
      $display("       %0d hand-checked values, 20000 triples against LVGL's mix", mx_nst);

      for (mx_k = 0; mx_k < 16; mx_k = mx_k + 1) mx_cnt[mx_k] = 0;
      for (mx_i = 0; mx_i < MX_N; mx_i = mx_i + 1) begin
         mx_kind = mx_rnd(14);
         if (mx_built(mx_kind)) begin
            mx_mode = 4 + mx_rnd(4);                             // modes 5..7 are 16 bpp too
            if (gpu_m_mode != mx_mode) gpu_set_mode(mx_mode);
            mx_xy = (GPU_XY_EN != 0) && ((mx_kind == 7) || (mx_kind == 8) || (mx_kind == 9) || (mx_kind == 13) || mx_rnd(3) != 0);
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            mx_one(mx_kind);
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            reg_rd_mask(IRQ_FLAG, 32'h0, IF_ERR | IF_OVFL);
            gpu_check_touched("blended primitive");
            mx_cnt[mx_kind] = mx_cnt[mx_kind] + 1;
         end
      end
      //--------------------------------------------------------------
      $display("--- MIX5 with EN = 0: plain copies unchanged, EXPAND MASK under the rule");
      gpu_set_mode(4);
      gpu_c_alpha5(1'b0, 8'd77, 1'b1);
      gpu_c_dst(16'd128, 2 * MX_ADR_W + 2 * mx_rnd(4000));
      gpu_c_size(14'd13, 14'd5);
      mx_src;
      gpu_c_exec(GPU_COPY, 4'd5, 3'b000, 3'b000);           // a raster op: no blending
      mx_mask_expand;
      gpu_wait_idle;
      gpu_check_touched("MIX5 with EN = 0");

      $display("--- MIX5 back to 0: the rounding rule (alpha 128 over FFFF draws 7BEF / 8410)");
      if (GPU_GRAD_EN != 0) gpu_c_grad(0, 1'b0, 0, 1'b0);    // (no gradient, no key)
      gpu_c_transp(32'h1234);
      gpu_c_dst(16'd128, 2 * MX_ADR_W);
      gpu_c_size(14'd4, 14'd1);
      gpu_c_alpha(1'b0, 8'd0);
      gpu_c_fill(32'hFFFF);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);           // FFFF
      gpu_c_fill(32'h0000);
      gpu_c_alpha5(1'b1, 8'd128, 1'b1);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);           // 0000 over FFFF, 128, MIX5: 7BEF
      gpu_c_dst(16'd128, 2 * MX_ADR_W + 4);
      gpu_c_alpha(1'b0, 8'd0);
      gpu_c_fill(32'hFFFF);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_c_fill(32'h0000);
      gpu_c_alpha(1'b1, 8'd128);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);           // the rounding rule: 8410
      gpu_wait_idle;
      gpu_check_touched("MIX5 then the rounding rule");
      vram_rd_val(4 * MX_ADR_W, SZ_W, mx_t);                // (model-free: the two rules' values)
      if (mx_t !== 32'h7BEF_7BEF) tb_error("MIX5 0000 over FFFF at 128 is not 7BEF");
      vram_rd_val(4 * MX_ADR_W + 8, SZ_W, mx_t);
      if (mx_t !== 32'h8410_8410) tb_error("rounding rule 0000 over FFFF at 128 is not 8410");

      $display("--- RESET_STATE clears MIX5: EXPAND MASK rounds again");
      gpu_c_alpha5(1'b0, 8'd0, 1'b1);
      gpu_c_reset_state;
      gpu_set_dispw(MX_DISPW);
      gpu_c_dst(16'd128, 2 * MX_ADR_W + 2 * mx_rnd(4000));
      gpu_c_size(14'd11, 14'd4);
      mx_mask_expand;
      gpu_wait_idle;
      gpu_check_touched("EXPAND MASK after RESET_STATE");

      $display("--- palette modes: MIX5 has no effect");
      for (mx_k = 0; mx_k < 4; mx_k = mx_k + 1) begin
         gpu_set_mode(mx_k);
         gpu_c_alpha5(1'b1, mx_rnd(256), 1'b1);
         gpu_c_dst(16'd128, (MX_ADR_W << (5 - mx_k)) + mx_rnd(4000));
         gpu_c_size(14'd9, 14'd3);
         gpu_c_src_fmt(16'd40, (MX_SRC_LO + 20) << (5 - mx_k), 4'h0);
         gpu_c_exec(GPU_COPY, mx_rnd(16), mx_rnd(8), mx_rnd(8));
         mx_mask_expand;
         gpu_wait_idle;
         gpu_check_touched("palette mode, MIX5 set");
      end
      gpu_set_mode(4);
      gpu_c_alpha(1'b0, 8'd0);
      gpu_check_all("gpu_mix5 end");
      $display("INFO:  LINE %0d FILL %0d COPY %0d COPY_T %0d SPAN %0d EXPAND %0d MASK %0d TEXSPAN %0d TEXRECT %0d TRI %0d TRITEX %0d MPLANE %0d IMM %0d IMM_EXP %0d",
               mx_cnt[13], mx_cnt[0], mx_cnt[1], mx_cnt[2], mx_cnt[3], mx_cnt[4], mx_cnt[5], mx_cnt[6], mx_cnt[7],
               mx_cnt[8], mx_cnt[9], mx_cnt[10], mx_cnt[11], mx_cnt[12]);
      $display("INFO:  %0d EXPAND MASK with OPAQUE", mx_nmo);
      $display("INFO:  %0d command words pushed with reserved bits set", gpu_rsv_n);
      if (gpu_rsv_n == 0) tb_error("no reserved bit was ever set (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
