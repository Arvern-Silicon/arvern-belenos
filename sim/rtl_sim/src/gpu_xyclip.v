//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_xyclip
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_xyclip.v
// Module Description : x/y destinations (SET_DST [16] XY, SET_EXT 3 SET_XY)
//                      and the clip window (SET_EXT 4 SET_CLIP):
//                      1. reset clip = no clipping: an EXEC right after
//                         SET_DST XY draws at the origin (position (0, 0)),
//                         negative coordinates and x / y = -2048 / 2047 draw
//                         at origin + y * pitch + x; an explicit full-range
//                         clip gives the same.
//                      2. FILL / COPY / COPY_TRANSP x GFX_MODE 0..4 x the
//                         eight destination swaps x 16 clip relations (inside,
//                         each edge cut, inner window, outside on each side,
//                         1 x 1 in / out, empty, clip = surface with the
//                         rectangle across x / y < 0 or past the surface,
//                         tight): exact VRAM read / write counts (clipped
//                         pixels: no source read, no write), every access on
//                         a word of an unclipped pixel, GPU_DONE per EXEC.
//                      3. EXEC_SPAN rows: SET_XY per row, DELTA = dx (both
//                         signs) moves x, clipped on four sides.
//                      4. EXEC_EXPAND strings: one SET_SRC + EXEC_EXPAND per
//                         glyph, DELTA = advance (+w, -w with X swap, +h with
//                         CL), first / last glyphs and top / bottom rows cut.
//                      5. EXEC_TEXSPAN rows with SET_XY, swaps, clip.
//                      6. pitch 0 = frame width, with PIX_DOUBLE ceil(W/2);
//                         the frame width is the one at SET_XY time (start
//                         address and line step checked separately).
//                      7. address mode is never clipped (FILL, COPY,
//                         COPY_TRANSP, SPAN, EXPAND, TEXSPAN under a 1 x 1
//                         and an empty clip).
//                      8. x/y and address destinations mixed in one queued
//                         stream and in a CALL list (SET_DST without XY back
//                         to address mode, DELTA moving the base there; SET_DST
//                         XY back at (0, 0)).
//                      9. rectangles entirely outside the clip, every EXEC
//                         kind, far coordinates (the computed address would
//                         be outside the VRAM): no VRAM access at all,
//                         GPU_DONE; walk time reported.
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer XC_SRC_LO = 40;               // sources / textures / fonts: words [40, 280)
localparam integer XC_SRC_HI = 280;
localparam integer XC_DST_LO = 300;              // destinations: words [300, 990)
localparam integer XC_DST_HI = 990;
localparam integer XC_LIST   = 8;                // command lists: words [8, 40)
localparam integer XC_P      = 24;               // x/y surface pitch
localparam integer XC_SW     = 20;               // surface width / height (clip = surface)
localparam integer XC_SH     = 10;
localparam integer XC_SPITCH = 16;               // COPY source pitch
localparam integer XC_WMAX   = (GPU_DIM_MASK >= 8) ? 8 : GPU_DIM_MASK;
localparam integer XC_HMAX   = (GPU_DIM_MASK >= 6) ? 6 : GPU_DIM_MASK;
localparam integer XC_GW     = (GPU_DIM_MASK >= 5) ? 5 : GPU_DIM_MASK;   // glyph
localparam integer XC_GH     = (GPU_DIM_MASK >= 7) ? 7 : GPU_DIM_MASK;
localparam integer XC_DISPW  = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;

integer    xc_mode, xc_bl, xc_ppw, xc_c, xc_r, xc_i, xc_k, xc_n, xc_rel;
integer    xc_w, xc_h, xc_cols, xc_rows, xc_rx, xc_ry, xc_x, xc_y;
integer    xc_x0, xc_y0, xc_x1, xc_y1, xc_t0, xc_dx, xc_wd, xc_cur;
integer    xc_rd0, xc_wr0, xc_cl0, xc_nclip, xc_ndraw, xc_nfull, xc_npart;
integer    xc_sbl, xc_sppw, xc_s, xc_gl, xc_pw, xc_ww;
reg [31:0] xc_pm, xc_org, xc_sb, xc_font, xc_b, xc_st, xc_f;
reg  [3:0] xc_cmd, xc_op;
reg  [2:0] xc_dsw, xc_ssw;
reg [23:0] xc_n24;
reg        xc_opq;

function integer xc_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      xc_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] xc_hi_color;             // random colour with the bits above the depth set
   input [31:0] rnd;
   input [31:0] pm;
   begin
      xc_hi_color = rnd | (~pm & 32'hFFFF) | 32'hA5A5_0000;
   end
endfunction

// Base (first pixel visited) of a w x h rectangle whose top-left is at org
function [31:0] xc_corner;
   input [31:0] org;
   input integer pitch;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows = sw[0] ? w : h;
      cols = sw[0] ? h : w;
      xc_corner = org + (sw[1] ? rows - 1 : 0) * pitch + (sw[2] ? cols - 1 : 0);
   end
endfunction

task xc_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      xc_mode = mode;
      xc_bl   = gpu_bl(mode);
      xc_ppw  = 32 >> xc_bl;
      xc_pm   = gpu_pmask(xc_bl);
      xc_org  = XC_DST_LO * xc_ppw + 100 + xc_rnd(xc_ppw);     // x/y surface origin
   end
endtask

task xc_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

// Monitors around one EXEC: idle, flags cleared, counters / allowed words armed
task xc_mon_begin;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      xc_rd0 = gpu_exp_rd;
      xc_wr0 = gpu_exp_wr;
      xc_cl0 = gpu_exp_clip;
      gpu_alw_clear;
      gpu_alw_start;
      gpu_mon_start;
   end
endtask

// counts: 1 = compare the read / write counts with the model (FILL / COPY /
// COPY_TRANSP), 0 = allowed words only. Expects GPU_DONE.
task xc_mon_end;
   input        counts;
   input [8*24-1:0] what;
   begin
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_alw_stop;
      if (counts && ((gpu_mon_rd != gpu_exp_rd - xc_rd0) || (gpu_mon_wr != gpu_exp_wr - xc_wr0))) begin
         $display("ERROR: %0s: %0d reads / %0d writes, expected %0d / %0d (%0d clipped pixels) %t", what,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - xc_rd0, gpu_exp_wr - xc_wr0, gpu_exp_clip - xc_cl0, $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      xc_nclip = xc_nclip + gpu_exp_clip - xc_cl0;
   end
endtask

// Random clip relation rel against the rectangle footprint (xc_rx, xc_ry,
// xc_cols, xc_rows); 13 and 14 move the rectangle and clip to the surface.
task xc_relation;
   input integer rel;
   begin
      xc_x0 = xc_rx - 1;
      xc_y0 = xc_ry - 1;
      xc_x1 = xc_rx + xc_cols;
      xc_y1 = xc_ry + xc_rows;
      case (rel)
        0  : ;                                                       // inside
        1  : xc_x0 = xc_rx + 1 + xc_rnd(xc_cols - 1);                // left edge cut
        2  : xc_x1 = xc_rx + xc_cols - 2 - xc_rnd(xc_cols - 1);      // right edge cut
        3  : xc_y0 = xc_ry + 1 + xc_rnd(xc_rows - 1);                // top edge cut
        4  : xc_y1 = xc_ry + xc_rows - 2 - xc_rnd(xc_rows - 1);      // bottom edge cut
        5  : begin                                                   // window inside the rectangle
                xc_x0 = xc_rx + xc_rnd(xc_cols);
                xc_y0 = xc_ry + xc_rnd(xc_rows);
                xc_x1 = xc_x0 + xc_rnd(3);
                xc_y1 = xc_y0 + xc_rnd(3);
             end
        6  : begin xc_x1 = xc_rx - 1; xc_x0 = xc_x1 - 9; end         // outside left
        7  : begin xc_x0 = xc_rx + xc_cols; xc_x1 = xc_x0 + 9; end   // outside right
        8  : begin xc_y1 = xc_ry - 1; xc_y0 = xc_y1 - 9; end         // outside above
        9  : begin xc_y0 = xc_ry + xc_rows; xc_y1 = xc_y0 + 9; end   // outside below
        10 : begin                                                   // 1 x 1 inside
                xc_x0 = xc_rx + xc_rnd(xc_cols);
                xc_y0 = xc_ry + xc_rnd(xc_rows);
                xc_x1 = xc_x0;
                xc_y1 = xc_y0;
             end
        11 : begin                                                   // 1 x 1 just outside a corner
                xc_x0 = xc_rx + xc_cols;
                xc_y0 = xc_ry - 1;
                xc_x1 = xc_x0;
                xc_y1 = xc_y0;
             end
        12 : begin xc_x0 = xc_rx + 1; xc_x1 = xc_rx; end             // empty: x1 = x0 - 1
        13 : begin                                                   // surface; across x < 0, y < 0
                xc_rx = -1 - xc_rnd(3);
                xc_ry = -1 - xc_rnd(2);
                xc_x0 = 0; xc_y0 = 0; xc_x1 = XC_SW - 1; xc_y1 = XC_SH - 1;
             end
        14 : begin                                                   // surface; past right / bottom
                xc_rx = XC_SW - xc_cols + 1 + xc_rnd(3);
                xc_ry = XC_SH - xc_rows + 1 + xc_rnd(2);
                xc_x0 = 0; xc_y0 = 0; xc_x1 = XC_SW - 1; xc_y1 = XC_SH - 1;
             end
        default : begin                                              // tight: the rectangle itself
                xc_x0 = xc_rx;
                xc_y0 = xc_ry;
                xc_x1 = xc_rx + xc_cols - 1;
                xc_y1 = xc_ry + xc_rows - 1;
             end
      endcase
   end
endtask

// First pixel visited of the footprint under swaps dsw
task xc_first;
   input [2:0] dsw;
   begin
      xc_x = xc_rx + (dsw[2] ? xc_cols - 1 : 0);
      xc_y = xc_ry + (dsw[1] ? xc_rows - 1 : 0);
   end
endtask

// Write a captured command list to VRAM at word XC_LIST (backdoor + shadow)
task xc_list_write;
   integer kk;
   begin
      if (XC_LIST + gpu_cap_n > XC_SRC_LO)
         tb_error("command list overflows its area (test bug)");
      for (kk = 0; kk < gpu_cap_n; kk = kk + 1) begin
         vram_mem[XC_LIST + kk]   = gpu_cap_buf[kk];
         gpu_shadow[XC_LIST + kk] = gpu_cap_buf[kk];
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: x/y destinations and clip window  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (GPU_XY_EN == 0)
         tb_skip_finish("|          (x/y or affine blit absent)          |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(XC_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_slo = XC_SRC_LO;
      gpu_rgn_shi = XC_SRC_HI;
      gpu_rgn_dlo = XC_DST_LO;
      gpu_rgn_dhi = XC_DST_HI;
      xc_nclip = 0;
      xc_ndraw = 0;
      xc_nfull = 0;
      xc_npart = 0;

      //--------------------------------------------------------------
      // (must run before any SET_CLIP: the reset value is checked)
      $display("--- 1. reset clip = none: position (0, 0) after SET_DST XY, negative and extreme coordinates");
      xc_set_mode(0);                                                    // 1 bpp: 2048 pixels = 64 words
      xc_org = 600 * 32 + 5;
      for (xc_i = 0; xc_i < 2; xc_i = xc_i + 1) begin
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         if (xc_i == 1) begin
            gpu_c_clip(16, 3, 2, 1);                                      // anything, then
            gpu_c_noclip;                                                 // explicitly the full range
         end
         gpu_c_fill($random(gpu_seed));
         gpu_c_dst_xy(XC_P, xc_org);
         gpu_c_size(14'd2, 14'd2);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                   // at (0, 0): no SET_XY yet
         gpu_c_fill($random(gpu_seed));
         gpu_c_xy(-3, -1);
         gpu_c_size(XC_WMAX, (GPU_DIM_MASK >= 3) ? 3 : GPU_DIM_MASK);
         gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b000, 3'b000);                   // XOR across x < 0, y < 0
         xc_w = (GPU_DIM_MASK >= 7) ? 7 : GPU_DIM_MASK;
         gpu_c_xy(2047 - (xc_w - 1), 2);
         gpu_c_size(xc_w, 14'd2);
         gpu_c_exec_xy(GPU_FILL, 4'd1, 3'b000, 3'b000);                   // x up to 2047
         gpu_c_xy(-2048 + (xc_w - 1), 1);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b100, 3'b000);                   // X swap: down to x = -2048
         gpu_c_src(16'd0, 48 * 32 + 3);
         gpu_c_dst_xy(16'd1, xc_org);                                     // pitch 1: y moves one pixel
         gpu_c_size(14'd3, 14'd1);
         gpu_c_xy(0, 2047);
         gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_c_xy(1, -2048);
         gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_c_fill($random(gpu_seed));
         gpu_c_xy(2, -2046);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b011, 3'b000);                   // CL + Y: run up to y = -2048
         gpu_wait_idle;
         xc_no_err;
         gpu_check_touched((xc_i == 0) ? "reset clip" : "explicit full-range clip");
      end
      gpu_check_all("no clipping");

      //--------------------------------------------------------------
      $display("--- 2. FILL / COPY / COPY_TRANSP: modes x swaps x clip relations, exact access counts");
      for (xc_mode = 0; xc_mode < 5; xc_mode = xc_mode + 1) begin
         xc_set_mode(xc_mode);
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         if (xc_mode % 2) gpu_preload_pal(XC_SRC_LO, XC_SRC_HI, xc_bl, $random(gpu_seed), $random(gpu_seed), xc_pm, 16'h0);
         else             gpu_preload_rand(XC_SRC_LO, XC_SRC_HI);
         gpu_c_dst_xy(XC_P, xc_org);
         for (xc_c = 0; xc_c < 16; xc_c = xc_c + 1) begin
            xc_rel  = (xc_c + 3 * xc_mode) % 16;
            xc_cmd  = ((xc_c % 3) == 0) ? GPU_FILL : ((xc_c % 3) == 1) ? GPU_COPY : GPU_COPYT;
            xc_op   = ((xc_c % 4) == 0) ? 4'd0 : $random(gpu_seed);
            xc_dsw  = (xc_c + xc_mode) & 7;
            xc_ssw  = $random(gpu_seed);
            xc_w    = 1 + xc_rnd(XC_WMAX);
            xc_h    = 1 + xc_rnd(XC_HMAX);
            if (xc_rel == 5) begin                                        // room for an inner window
               if (xc_w < 3) xc_w = (XC_WMAX >= 3) ? 3 : XC_WMAX;
               if (xc_h < 3) xc_h = (XC_HMAX >= 3) ? 3 : XC_HMAX;
            end
            xc_cols = xc_dsw[0] ? xc_h : xc_w;
            xc_rows = xc_dsw[0] ? xc_w : xc_h;
            xc_rx   = -2 + xc_rnd(XC_SW - xc_cols + 5);
            xc_ry   = -2 + xc_rnd(XC_SH - xc_rows + 5);
            xc_relation(xc_rel);
            xc_first(xc_dsw);
            xc_sb   = xc_corner(48 * xc_ppw + 2 + xc_rnd(xc_ppw), XC_SPITCH, xc_ssw, xc_w, xc_h);
            gpu_c_clip(xc_x0, xc_y0, xc_x1, xc_y1);
            gpu_c_size(xc_w, xc_h);
            gpu_c_src(XC_SPITCH, xc_sb);
            gpu_c_fill($random(gpu_seed));
            if (xc_rnd(2)) gpu_c_transp(gpu_get_px(xc_sb, xc_bl) | 32'hA5A5_0000 | (~xc_pm & 32'hFFFF));
            else           gpu_c_transp(xc_hi_color($random(gpu_seed), xc_pm));
            gpu_c_xy(xc_x, xc_y);
            xc_mon_begin;
            gpu_c_exec_xy(xc_cmd, xc_op, xc_dsw, xc_ssw);
            xc_mon_end(1'b1, "clip matrix");
            if (gpu_exp_clip - xc_cl0 == 0)                xc_ndraw = xc_ndraw + 1;
            else if (gpu_exp_clip - xc_cl0 == xc_w * xc_h) xc_nfull = xc_nfull + 1;
            else                                           xc_npart = xc_npart + 1;
            $display("       mode %0d rel %2d %0s op %0d %0dx%0d sw %b at (%0d,%0d), clip (%0d,%0d)-(%0d,%0d): %0d of %0d clipped",
                     xc_mode, xc_rel, (xc_cmd == GPU_FILL) ? "FILL" : (xc_cmd == GPU_COPY) ? "COPY" : "COPYT",
                     xc_op, xc_w, xc_h, xc_dsw, xc_x, xc_y, xc_x0, xc_y0, xc_x1, xc_y1,
                     gpu_exp_clip - xc_cl0, xc_w * xc_h);
            gpu_check_touched("clip matrix");
         end
         xc_no_err;
         gpu_check_all("clip matrix");
      end
      $display("       rectangles: %0d unclipped, %0d partly clipped, %0d fully clipped", xc_ndraw, xc_npart, xc_nfull);
      if ((xc_ndraw == 0) || (xc_npart == 0) || (xc_nfull == 0))
         tb_error("clip matrix lacks an unclipped, partial or fully clipped case (test bug)");

      //--------------------------------------------------------------
      $display("--- 3. EXEC_SPAN rows: SET_XY per row, DELTA = dx");
      for (xc_i = 0; xc_i < 3; xc_i = xc_i + 1) begin
         xc_set_mode((xc_i == 0) ? 3 : (xc_i == 1) ? 4 : 1);
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         gpu_c_dst_xy(XC_P, xc_org);
         gpu_c_clip(3, 1, XC_SW - 4, XC_SH - 2);
         gpu_c_fill($random(gpu_seed));
         xc_mon_begin;
         for (xc_y = -1; xc_y <= XC_SH; xc_y = xc_y + 1) begin
            xc_cur = ((xc_y % 2) == 0) ? -6 + xc_rnd(4) : XC_SW + 2 - xc_rnd(4);
            gpu_c_xy(xc_cur, xc_y);
            if ((xc_y % 3) == 0) gpu_c_fill($random(gpu_seed));
            gpu_c_span(0, 1 + xc_rnd(XC_WMAX));
            for (xc_k = 0; xc_k < 3; xc_k = xc_k + 1) begin               // rightwards on even rows
               xc_dx = ((xc_y % 2) == 0) ? 2 + xc_rnd(8) : -(2 + xc_rnd(8));
               xc_wd = 1 + xc_rnd(XC_WMAX);
               if ((xc_cur + xc_dx < -8) || (xc_cur + xc_dx + xc_wd > XC_SW + 10)) xc_dx = -xc_dx;
               xc_cur = xc_cur + xc_dx;
               gpu_c_span(xc_dx, xc_wd);
            end
            if (gpu_m_x != xc_cur)
               tb_error("span chain did not end at the expected x (test bug)");
         end
         xc_mon_end(1'b1, "span rows");
         xc_no_err;
         $display("       mode %0d: %0d span pixels clipped so far", xc_mode, xc_nclip);
         gpu_check_touched("span rows");
      end
      gpu_check_all("span rows");

      //--------------------------------------------------------------
      $display("--- 4. EXEC_EXPAND strings: one SET_SRC + EXEC_EXPAND per glyph");
      for (xc_i = 0; xc_i < 8; xc_i = xc_i + 1) begin
         xc_s    = xc_i % 4;
         xc_sbl  = xc_s;
         xc_sppw = 32 >> xc_sbl;
         xc_set_mode((xc_i * 3) % 5);
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         gpu_preload_pal(XC_SRC_LO, XC_SRC_HI, xc_sbl, 16'h0, 16'h0, 16'h1, gpu_pmask(xc_sbl));
         xc_font = 48 * xc_sppw + xc_rnd(xc_sppw);
         xc_dsw  = (xc_i < 4) ? ((xc_i % 2) ? 3'b100 : 3'b000) : ((xc_i % 2) ? 3'b011 : 3'b001);
         xc_opq  = xc_i % 3 == 1;
         xc_n    = xc_dsw[0] ? 4 : 6;                                      // glyphs
         xc_cols = xc_dsw[0] ? XC_GH : XC_GW;                              // advance
         xc_rows = xc_dsw[0] ? XC_GW : XC_GH;
         gpu_c_dst_xy(XC_P, xc_org);
         gpu_c_clip(0, 3, XC_SW - 1, 2 + xc_rows - 2);                     // first / last row of the line cut
         gpu_c_size(XC_GW, XC_GH);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(xc_hi_color($random(gpu_seed), xc_pm));
         xc_dx = xc_dsw[2] ? -xc_cols : xc_cols;
         xc_x  = xc_dsw[2] ? (-3 + xc_n * xc_cols - 1) : -3;               // first glyph's first pixel
         gpu_c_xy(xc_x - xc_dx, 2 + (xc_dsw[1] ? xc_rows - 1 : 0));
         xc_mon_begin;
         for (xc_k = 0; xc_k < xc_n; xc_k = xc_k + 1) begin
            xc_gl = xc_rnd(8);
            gpu_c_src(16'd0, xc_font + xc_gl * XC_GW * XC_GH);
            gpu_c_expand(xc_dx, xc_dsw, xc_opq, xc_s);
         end
         xc_mon_end(1'b0, "expand string");
         if (gpu_m_x != xc_x + (xc_n - 1) * xc_dx)
            tb_error("expand chain did not end at the expected x (test bug)");
         xc_no_err;
         $display("       src %0d bpp -> mode %0d, sw %b, opaque %0d, %0d glyphs, %0d accesses",
                  1 << xc_sbl, xc_mode, xc_dsw, xc_opq, xc_n, gpu_alw_n);
         gpu_check_touched("expand string");
      end
      gpu_check_all("expand strings");

      //--------------------------------------------------------------
      $display("--- 5. EXEC_TEXSPAN rows with SET_XY, swaps, clip");
      for (xc_i = 0; xc_i < 5; xc_i = xc_i + 1) begin
         xc_set_mode(xc_i);
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         gpu_preload_rand(XC_SRC_LO, XC_SRC_HI);
         gpu_c_dst_xy(XC_P, xc_org);
         gpu_c_clip(2, 0, XC_SW - 3, XC_SH - 1);
         gpu_c_src(16'd0, 48 * xc_ppw + xc_rnd(xc_ppw));
         gpu_c_transp(gpu_get_px(48 * xc_ppw, xc_bl));
         xc_mon_begin;
         for (xc_k = 0; xc_k < 8; xc_k = xc_k + 1) begin
            xc_dsw = (xc_k + xc_i) & 7;
            gpu_c_tex(4'd3, 4'd3, xc_k % 2, xc_dsw, 1'b0, 1'b0, $random(gpu_seed));
            gpu_c_uv($random(gpu_seed), $random(gpu_seed));
            gpu_c_step($random(gpu_seed) & 16'h8FFF, $random(gpu_seed) & 16'h87FF);
            gpu_c_xy(-3 + xc_rnd(XC_SW + 6), -2 + xc_rnd(XC_SH + 4));
            gpu_c_texspan(xc_rnd(5) - 2, 1 + xc_rnd(XC_WMAX + 3));
         end
         xc_mon_end(1'b0, "texspan rows");
         xc_no_err;
         gpu_check_touched("texspan rows");
      end
      gpu_check_all("texspan rows");

      //--------------------------------------------------------------
      $display("--- 6. pitch 0 = frame width at SET_XY time, PIX_DOUBLE ceil(W/2)");
      xc_ww = (XC_DISPW % 2) ? XC_DISPW : XC_DISPW - 1;                    // odd frame width W
      xc_pw = (xc_ww + 1) / 2;
      xc_set_mode(4);
      gpu_preload_rand(XC_DST_LO, XC_DST_HI);
      gpu_set_dispw(xc_ww);
      gpu_c_noclip;
      gpu_c_dst_xy(16'd0, xc_org);
      gpu_c_fill($random(gpu_seed));
      gpu_c_size(14'd3, 14'd4);
      gpu_c_xy(2, 1);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                       // pitch W
      gpu_wait_idle;
      gpu_check_touched("x/y pitch 0 = W");
      reg_wr(DISP_CFG, 32'h10);                                            // PIX_DOUBLE
      gpu_m_dispw = xc_pw;
      gpu_c_xy(3, 6);
      gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b001, 3'b000);                       // pitch ceil(W/2), CL
      gpu_wait_idle;
      gpu_check_touched("x/y pitch 0 = ceil(W/2)");
      // frame width changed between SET_XY and the EXEC: the one at SET_XY counts
      $display("       (implementer: pitch 0 in x/y mode = the frame width at the time of SET_XY)");
      gpu_c_xy(1, 9);                                                      // latched: ceil(W/2)
      reg_wr(DISP_CFG, 32'h0);
      gpu_m_dispw = xc_ww;
      gpu_c_size(14'd4, 14'd1);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                       // start address only
      gpu_wait_idle;
      gpu_check_touched("SET_XY-time width: start address");
      gpu_c_xy(10, 1);                                                     // latched: W
      reg_wr(DISP_CFG, 32'h10);
      gpu_m_dispw = xc_pw;
      gpu_c_size(14'd2, 14'd4);
      gpu_c_exec_xy(GPU_FILL, 4'd1, 3'b000, 3'b000);                       // line step too
      gpu_wait_idle;
      gpu_check_touched("SET_XY-time width: line step");
      reg_wr(DISP_CFG, 32'h0);
      gpu_m_dispw = xc_ww;
      gpu_set_dispw(XC_DISPW);
      xc_no_err;
      gpu_check_all("pitch 0");

      //--------------------------------------------------------------
      $display("--- 7. address mode is never clipped");
      for (xc_i = 0; xc_i < 2; xc_i = xc_i + 1) begin
         xc_set_mode((xc_i == 0) ? 4 : 2);
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         gpu_preload_pal(XC_SRC_LO, XC_SRC_HI, 1, 16'h0, 16'h1, 16'h2, 16'h3);
         xc_k = gpu_exp_clip;
         if (xc_i == 0) gpu_c_clip(5, 5, 5, 5);                            // 1 x 1
         else           gpu_c_clip(5, 5, 4, 5);                            // empty
         xc_b = (XC_DST_LO + 40) * xc_ppw + xc_rnd(xc_ppw);
         gpu_c_dst(XC_P, xc_b);
         gpu_c_src(XC_SPITCH, 48 * xc_ppw + 1);
         gpu_c_size(XC_WMAX, XC_HMAX);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(xc_hi_color($random(gpu_seed), xc_pm));
         xc_mon_begin;
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
         xc_mon_end(1'b1, "address FILL");
         xc_mon_begin;
         gpu_c_dst(XC_P, xc_b + 8 * XC_P);
         gpu_c_exec_xy(GPU_COPY, 4'd6, 3'b100, 3'b000);
         xc_mon_end(1'b1, "address COPY");
         xc_mon_begin;
         gpu_c_exec_xy(GPU_COPYT, 4'd0, 3'b000, 3'b000);
         xc_mon_end(1'b1, "address COPY_TRANSP");
         xc_mon_begin;
         gpu_c_span(-2 * XC_P, XC_WMAX);
         gpu_c_span(XC_P + 3, 2);
         xc_mon_end(1'b1, "address SPAN");
         gpu_c_size(XC_GW, XC_GH);
         gpu_c_src(16'd0, 48 * 16 + 7);                                     // 2-bit glyph
         xc_mon_begin;
         gpu_c_expand(16 * XC_P, 3'b010, 1'b1, 2'd1);
         xc_mon_end(1'b0, "address EXPAND");
         gpu_c_src(16'd0, 48 * xc_ppw + 2);
         gpu_c_tex(4'd2, 4'd2, 1'b0, 3'b000, 1'b0, 1'b0, 8'h01);
         gpu_c_uv($random(gpu_seed), $random(gpu_seed));
         gpu_c_step($random(gpu_seed), $random(gpu_seed));
         xc_mon_begin;
         gpu_c_texspan(XC_P, XC_WMAX);
         xc_mon_end(1'b0, "address TEXSPAN");
         if (gpu_exp_clip != xc_k)
            tb_error("address-mode pixel modelled as clipped (test bug)");
         xc_no_err;
         gpu_check_touched("address mode, clip set");
      end
      gpu_check_all("address mode not clipped");

      //--------------------------------------------------------------
      $display("--- 8. x/y and address destinations mixed: queued stream, then a CALL list");
      for (xc_i = 0; xc_i < 2; xc_i = xc_i + 1) begin
         xc_set_mode((xc_i == 0) ? 3 : 4);
         gpu_preload_rand(XC_DST_LO, XC_DST_HI);
         gpu_preload_rand(XC_SRC_LO, XC_SRC_HI);
         xc_b = (XC_DST_LO + 400) * xc_ppw + 1;                             // address-mode area, past the surface
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         if (xc_i == 1) begin
            gpu_cap_n  = 0;
            gpu_cap_en = 1'b1;
         end
         gpu_c_dst_xy(XC_P, xc_org);
         gpu_c_clip(1, 1, XC_SW - 2, XC_SH - 2);
         gpu_c_size(14'd4, 14'd3);
         gpu_c_fill($random(gpu_seed));
         gpu_c_xy(-1, 0);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // clipped at x 0 and y 0
         gpu_c_dst(16'd5, xc_b);                                           // address mode
         gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b000, 3'b000);                    // not clipped
         gpu_c_span(7, 3);                                                 // base moves, not x
         gpu_c_dst_xy(XC_P, xc_org);                                       // back at (0, 0)
         gpu_c_fill($random(gpu_seed));
         gpu_c_size(14'd3, 14'd3);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // at (0, 0): row 0 / col 0 clipped
         gpu_c_src(XC_SPITCH, 48 * xc_ppw + 2);
         gpu_c_xy(XC_SW - 2, XC_SH - 2);
         gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);                    // only (SW-2, SH-2) drawn
         gpu_c_span(-4, 3);                                                // x moves by -4 on row SH-2
         gpu_c_xy(5, 4);
         gpu_c_span(0, 2);
         gpu_c_dst(XC_P, xc_b + 10 * XC_P);                                // address mode again
         gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b001, 3'b000);                    // 2 x 1, CL
         gpu_c_fence(1'b1);
         if (xc_i == 1) begin
            gpu_cap_en = 1'b0;
            xc_list_write;
            xc_n24 = gpu_cap_n;
            gpu_push({OP_CALL, 4'h0, xc_n24});
            gpu_push(XC_LIST);
            $display("       %0d words in the list", gpu_cap_n);
         end
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_FENCE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         xc_no_err;
         gpu_check_touched((xc_i == 0) ? "mixed stream" : "mixed CALL list");
      end
      gpu_check_all("mixed destinations");

      //--------------------------------------------------------------
      $display("--- 9. entirely outside the clip, far coordinates: no VRAM access at all");
      xc_set_mode(4);
      gpu_c_dst_xy(XC_P, xc_org);
      gpu_c_clip(0, 0, XC_SW - 1, XC_SH - 1);
      gpu_c_size(XC_WMAX, XC_HMAX);
      gpu_c_fill($random(gpu_seed));
      gpu_c_src(XC_SPITCH, 48 * 2);
      gpu_c_tex(4'd2, 4'd2, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_c_uv(16'h0, 16'h0);
      gpu_c_step(16'h0800, 16'h0000);
      gpu_c_step_row(16'h0000, 16'h0800);
      for (xc_k = 0; xc_k < 7; xc_k = xc_k + 1) begin
         xc_x = (xc_k % 2) ? -2000 : 1900;
         xc_y = (xc_k % 3) ? 1500 : -1800;                                 // address far outside the VRAM
         gpu_c_xy(xc_x, xc_y);
         gpu_c_size(XC_WMAX, XC_HMAX);
         xc_mon_begin;
         xc_t0 = gpu_cyc;
         case (xc_k)
           0 : gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b000, 3'b000);
           1 : gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b111, 3'b000);
           2 : gpu_c_exec_xy(GPU_COPYT, 4'd0, 3'b000, 3'b000);
           3 : gpu_c_span(1, XC_WMAX);
           4 : begin
                  gpu_c_src(16'd0, 48 * 16);
                  gpu_c_expand(-1, 3'b000, 1'b1, 2'd1);
               end
           5 : gpu_c_texspan(2, XC_WMAX);
           default : gpu_c_texrect(-3);
         endcase
         gpu_wait_idle;
         xc_t0 = gpu_cyc - xc_t0;
         xc_mon_end(1'b0, "outside the clip");
         if (gpu_mon_n != 0) begin
            $display("ERROR: kind %0d at (%0d,%0d) entirely outside the clip: %0d VRAM accesses %t", xc_k, gpu_m_x, xc_y, gpu_mon_n, $time);
            error = error + 1;
         end else
            $display("OK:    kind %0d at (%0d,%0d) entirely outside the clip: no VRAM access, GPU_DONE, %0d cycles to idle for %0d pixels",
                     xc_k, gpu_m_x, xc_y, xc_t0, gpu_m_w * gpu_m_h);
         gpu_c_src(XC_SPITCH, 48 * 2);
      end
      xc_no_err;
      gpu_check_all("outside the clip");

      xc_no_err;
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
      $display("       %0d clipped walk positions in total", xc_nclip);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
