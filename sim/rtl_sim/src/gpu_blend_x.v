//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_blend_x
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_blend_x.v
// Module Description : Blending combined with the other features, checked
//                      against the shared model (gpu_model.v blends every
//                      kind from the spec formula), 16 bpp (GFX_MODE 4..7):
//                      - blended EXEC_TEXRECT (BOUND, TEXBOX, row step,
//                        TRANSP_EN, SHADE, FREE_PITCH, texture swaps) and
//                        blended textured triangles;
//                      - blended FILL, COPY, COPY_TRANSP, SPAN, EXPAND and
//                        EXPAND MASK in x/y mode with clip windows (negative
//                        coordinates and bounds), DELTA moves, every raster
//                        op (13..15 blend their constant with their key);
//                      - blended copies through the mask plane (INV);
//                      - blended immediate copies and immediate EXPAND MASK;
//                      - blended gradient rectangles, spans and triangles
//                        (plain and per channel);
//                      - alpha 0, 255 and random; SET_ALPHA EN off between
//                        (raster ops again); OPAQUE with MASK (no effect).
//                      The reserved command bits are set at random.
//                      Each primitive's touched words are read through the
//                      VRAM window; the whole VRAM is compared at the end.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer BX_DISPW  = 64;
localparam integer BX_SRC_LO = 1000;             // sources, textures: words [BX_SRC_LO, BX_SRC_HI)
localparam integer BX_SRC_HI = 3000;
localparam integer BX_MSK_W  = 3000;             // mask plane: words [3000, 3400)
localparam integer BX_DST_W  = 9000;             // x/y origin (16 bpp pixel 2 * BX_DST_W)
localparam integer BX_ADR_W  = 20000;            // address-mode destinations: words [20000, 30000)
localparam integer BX_N      = 160;

integer    bx_i, bx_kind, bx_mode, bx_x, bx_y, bx_w, bx_h, bx_n, bx_sdep, bx_k;
integer    bx_cnt [0:15];
reg        bx_xy, bx_ok, bx_opq;
integer    bx_nmo = 0;                   // EXPAND MASK with OPAQUE drawn
reg [31:0] bx_caps;
reg [15:0] bx_c [0:3];

function integer bx_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      bx_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task bx_alpha;                           // A 255, 0 or random (mostly random), EN mostly on
   integer r;
   begin
      r = bx_rnd(10);
      gpu_c_alpha(bx_rnd(8) != 0, (r == 0) ? 8'd255 : (r == 1) ? 8'd0 : (r == 2) ? 8'd1 : (r == 3) ? 8'd254 : bx_rnd(256));
   end
endtask

// Destination: x/y mode (origin, position, clip window with negative values)
// or address mode
task bx_dest;
   integer x0, y0, x1, y1;
   begin
      if (bx_xy) begin
         gpu_c_dst_xy(16'd128, 2 * BX_DST_W + 2 * bx_rnd(400));
         bx_x = bx_rnd(40) - 10;
         bx_y = bx_rnd(20) - 5;
         gpu_c_xy(bx_x, bx_y);
         if (bx_rnd(4) == 0)
            gpu_c_noclip;
         else begin
            x0 = bx_x + bx_rnd(6) - 3;
            y0 = bx_y + bx_rnd(4) - 2;
            x1 = x0 + 2 + bx_rnd(bx_w + 2);
            y1 = y0 + 1 + bx_rnd(bx_h + 2);
            gpu_c_clip(x0, y0, x1, y1);
         end
      end else
         gpu_c_dst(16'd90 + bx_rnd(60), 2 * BX_ADR_W + 2 * bx_rnd(9000) + bx_rnd(2));
   end
endtask

task bx_grad;                            // gradient on FILL / SPAN / TRI (when built)
   begin
      if ((GPU_GRAD_EN != 0) && bx_rnd(2)) begin
         if (bx_rnd(2))
            gpu_c_grad_rgb(1 + bx_rnd(3), bx_rnd(2), bx_rnd(512) - 256, bx_rnd(512) - 256, bx_rnd(512) - 256, 1'b1);
         else
            gpu_c_grad(1 + bx_rnd(4), bx_rnd(2), bx_rnd(16) - 8, 1'b1);
      end else if (GPU_GRAD_EN != 0)
         gpu_c_grad(0, 1'b0, 0, 1'b0);
   end
endtask

task bx_grad_off;
   begin
      if (GPU_GRAD_EN != 0) gpu_c_grad(0, 1'b0, 0, 1'b0);
   end
endtask

task bx_tex;                             // texture state (BOUND only in x/y builds)
   reg bnd, fre;
   begin
      bnd = bx_xy && bx_rnd(2);
      fre = bx_rnd(3) == 0;
      gpu_c_tex(3 + bx_rnd(3), 3 + bx_rnd(3), bx_rnd(2), bx_rnd(8), fre, bnd, bx_rnd(4));
      gpu_c_uv((bx_rnd(10) << 6) + bx_rnd(64), (bx_rnd(10) << 6) + bx_rnd(64));
      // a free-pitch texture without BOUND does not wrap: steps >= 0 there
      gpu_c_step(bx_rnd(3000) - ((fre && !bnd) ? 0 : 1000), bx_rnd(2000) - ((fre && !bnd) ? 0 : 1000));
      if (bx_xy) begin
         gpu_c_step_row(bx_rnd(2000) - ((fre && !bnd) ? 0 : 1000), bx_rnd(3000) - ((fre && !bnd) ? 0 : 1000));
         gpu_c_texbox(4 + bx_rnd(20), 4 + bx_rnd(20));
      end
   end
endtask

task bx_src;                             // copy / texture source (16 bpp), pitch 40..80
   begin
      gpu_c_src_fmt(16'd40 + bx_rnd(40), 2 * (BX_SRC_LO + 20 + bx_rnd(800)) + bx_rnd(2), 4'h0);
   end
endtask

task bx_vtx;                             // a triangle around the x/y position
   begin
      gpu_c_vtx(0, 16 * bx_x + bx_rnd(32) - 16, 16 * bx_y + bx_rnd(32) - 16);
      gpu_c_vtx(1, 16 * (bx_x + bx_w + bx_rnd(6)) + bx_rnd(16), 16 * (bx_y + bx_rnd(4)) + bx_rnd(16));
      gpu_c_vtx(2, 16 * (bx_x + bx_rnd(bx_w)) + bx_rnd(16), 16 * (bx_y + bx_h + bx_rnd(4)) + bx_rnd(16));
   end
endtask

task bx_one;
   input integer kind;
   reg   [2:0] dsw, ssw;
   reg   [3:0] op;
   begin
      bx_w = 2 + bx_rnd(14);
      bx_h = 1 + bx_rnd(8);
      dsw  = bx_rnd(8);
      ssw  = bx_rnd(8);
      op   = bx_rnd(16);
      gpu_c_size(bx_w, bx_h);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp({16'h0, bx_c[bx_rnd(4)]});
      bx_dest;
      bx_alpha;
      case (kind)
        0: begin                                                 // FILL (gradient)
              bx_grad;
              gpu_c_exec_xy(GPU_FILL, op, dsw, 3'b000);
              bx_grad_off;
           end
        1: begin                                                 // COPY
              bx_src;
              gpu_c_exec_xy(GPU_COPY, op, dsw, ssw);
           end
        2: begin                                                 // COPY_TRANSP
              bx_src;
              gpu_c_exec_xy(GPU_COPYT, op, dsw, ssw);
           end
        3: begin                                                 // SPAN (gradient), DELTA
              bx_grad;
              gpu_c_span(bx_rnd(9) - 4, bx_w);
              gpu_c_span(bx_rnd(9) - 4, bx_w);
              bx_grad_off;
           end
        4, 5: begin                                              // EXPAND (5: MASK), DELTA
              bx_sdep = bx_rnd(4);
              gpu_c_src_fmt(16'd0, ((BX_SRC_LO + bx_rnd(800)) << (5 - bx_sdep)) + bx_rnd(32 >> bx_sdep),
                            4'd1 + bx_sdep);
              gpu_exp_mask = (kind == 5);
              gpu_exp_op   = bx_rnd(16);
              bx_opq = bx_rnd(2);
              if (gpu_exp_mask && bx_opq && (gpu_m_mode >= 3'd4)) bx_nmo = bx_nmo + 1;
              gpu_c_expand(bx_rnd(5) - 2, dsw, bx_opq, bx_sdep);          // (OPAQUE: no effect with MASK)
              gpu_exp_mask = 1'b0;
              gpu_exp_op   = 4'd0;
           end
        6: begin                                                 // TEXSPAN
              bx_src;
              bx_tex;
              gpu_c_texspan(bx_rnd(5) - 2, bx_w);
           end
        7: begin                                                 // TEXRECT
              bx_src;
              bx_tex;
              gpu_c_texrect(bx_xy ? (bx_rnd(5) - 2) : 0);
           end
        8: begin                                                 // flat triangle (gradient)
              bx_vtx;
              bx_grad;
              gpu_c_trifill(op);
              bx_grad_off;
           end
        9: begin                                                 // textured triangle
              bx_src;
              bx_tex;
              bx_vtx;
              gpu_tt_delta = $random(gpu_seed);                  // ignored with TRI
              gpu_c_tritex;
              gpu_tt_delta = 14'h0000;
           end
        10: begin                                                // COPY through the mask plane
              bx_src;
              gpu_c_mask_plane(32 * BX_MSK_W + bx_rnd(256), bx_rnd(2));
              gpu_k_mpl = 1'b1;
              gpu_c_exec_xy(bx_rnd(2) ? GPU_COPY : GPU_COPYT, op, dsw, ssw);
              gpu_k_mpl = 1'b0;
           end
        11: begin                                                // immediate COPY / COPY_TRANSP
              bx_n = (bx_w * bx_h + 1) / 2 + bx_rnd(3) - 1;      // exact, short or long
              for (bx_k = 0; bx_k < bx_n; bx_k = bx_k + 1)
                 gpu_imm_buf[bx_k] = {bx_c[bx_rnd(4)], bx_c[bx_rnd(4)]};
              gpu_c_imm(4'h0, bx_n);
              if (bx_caps[1] && bx_rnd(2)) begin
                 gpu_c_mask_plane(32 * BX_MSK_W + bx_rnd(256), bx_rnd(2));
                 gpu_k_mpl = 1'b1;
              end
              gpu_c_exec_xy(bx_rnd(2) ? GPU_COPY : GPU_COPYT, op, dsw, 3'b000);
              gpu_k_mpl = 1'b0;
           end
        default: begin                                           // immediate EXPAND MASK / EXPAND
              bx_sdep = bx_rnd(4);
              bx_n = (bx_w * bx_h * (1 << bx_sdep) + 31) / 32;
              for (bx_k = 0; bx_k < bx_n; bx_k = bx_k + 1)
                 gpu_imm_buf[bx_k] = $random(gpu_seed);
              gpu_c_imm(4'd1 + bx_sdep, bx_n);
              gpu_exp_mask = bx_rnd(3) != 0;
              gpu_exp_op   = bx_rnd(16);
              bx_opq = bx_rnd(2);
              if (gpu_exp_mask && bx_opq && (gpu_m_mode >= 3'd4)) bx_nmo = bx_nmo + 1;
              gpu_c_expand(0, dsw, bx_opq, bx_sdep);
              gpu_exp_mask = 1'b0;
              gpu_exp_op   = 4'd0;
           end
      endcase
   end
endtask

function bx_built;                       // the kind runs in this build
   input integer kind;
   begin
      case (kind)
        7:       bx_built = (GPU_XY_EN != 0);
        8, 9:    bx_built = (GPU_TRI_EN != 0) && (GPU_XY_EN != 0);
        10:      bx_built = bx_caps[1];
        11, 12:  bx_built = (GPU_IMM_EN != 0) && bx_caps[2];
        default: bx_built = 1'b1;
      endcase
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: blending with every feature (x/y, clip, |");
      $display("|  textures, triangles, mask plane, immediate)  |");
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
      bx_c[0] = $random(gpu_seed);
      bx_c[1] = $random(gpu_seed);
      bx_c[2] = $random(gpu_seed);
      bx_c[3] = $random(gpu_seed);
      gpu_preload_pal(BX_SRC_LO, BX_SRC_HI, 4, bx_c[0], bx_c[1], bx_c[2], bx_c[3]);
      gpu_model_init;
      gpu_set_dispw(BX_DISPW);
      reg_rd_val(BLNS_CFG2, bx_caps);
      bx_caps = (bx_caps >> 8) & 32'h7;                          // [0] REMAP, [1] MPLANE, [2] IMM
      for (bx_k = 0; bx_k < 16; bx_k = bx_k + 1) bx_cnt[bx_k] = 0;
      for (bx_i = 0; bx_i < BX_N; bx_i = bx_i + 1) begin
         bx_kind = bx_rnd(13);
         if (bx_built(bx_kind)) begin
            bx_mode = 4 + bx_rnd(4);                             // modes 5..7 are 16 bpp too
            if (gpu_m_mode != bx_mode) gpu_set_mode(bx_mode);
            bx_xy = (GPU_XY_EN != 0) && ((bx_kind == 7) || (bx_kind == 8) || (bx_kind == 9) || bx_rnd(3) != 0);
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            bx_one(bx_kind);
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            reg_rd_mask(IRQ_FLAG, 32'h0, IF_ERR | IF_OVFL);
            gpu_check_touched("blended primitive");
            bx_cnt[bx_kind] = bx_cnt[bx_kind] + 1;
         end
      end
      gpu_c_alpha(1'b0, 8'd0);
      gpu_check_all("gpu_blend_x end");
      $display("INFO:  FILL %0d COPY %0d COPY_T %0d SPAN %0d EXPAND %0d MASK %0d TEXSPAN %0d TEXRECT %0d TRI %0d TRITEX %0d MPLANE %0d IMM %0d IMM_EXP %0d",
               bx_cnt[0], bx_cnt[1], bx_cnt[2], bx_cnt[3], bx_cnt[4], bx_cnt[5], bx_cnt[6], bx_cnt[7],
               bx_cnt[8], bx_cnt[9], bx_cnt[10], bx_cnt[11], bx_cnt[12]);
      $display("INFO:  %0d EXPAND MASK with OPAQUE", bx_nmo);
      $display("INFO:  %0d command words pushed with reserved bits set", gpu_rsv_n);
      if (gpu_rsv_n == 0) tb_error("no reserved bit was ever set (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
