//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_call_kinds
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_call_kinds.v
// Module Description : Command lists carrying every command kind ("every
//                      command is valid in a list"): random lists of FILL
//                      (gradient), COPY with palette remap (SRC / DST) and
//                      the mask plane, COPY_TRANSP, SPAN, EXPAND (MASK),
//                      TEXSPAN, EXEC_TEXRECT, flat and textured triangles,
//                      SET_ALPHA blending, SET_AUX REMAP_TABLE / MASK_PLANE,
//                      RESET_STATE and FENCE, in x/y and address mode, at
//                      2, 8 and 16 bpp (as built). The lists are built with
//                      the model's command tasks (the model runs when they
//                      are captured), written to VRAM and run by a CALL;
//                      then GPU_LIST, LIST, GPU_FENCE and the whole VRAM are
//                      checked. The reserved command bits are set at random.
//                      Last, a list of about 3000 words.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer CK_LST    = 4000;             // lists: words [4000, 7100)
localparam integer CK_SRC_LO = 1000;             // sources, textures: words [1000, 2800)
localparam integer CK_MSK_W  = 3000;             // mask plane: words [3000, 3200)
localparam integer CK_RMP_W  = 3264;             // remap table: words [3264, 3328)
localparam integer CK_DST_W  = 9000;             // destinations: words [9000, 30000)
localparam integer CK_NL     = 24;               // lists

integer    ck_l, ck_i, ck_k, ck_bl, ck_mode, ck_x, ck_y, ck_w, ck_h, ck_ni, ck_sdep;
integer    ck_cnt [0:11];
reg        ck_xy;
reg [31:0] ck_caps, ck_tag;
reg [15:0] ck_c [0:3];

function integer ck_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      ck_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] ck_px;                   // a pixel of word w at the list's depth
   input integer w;
   begin
      ck_px = (w << (5 - ck_bl)) + ck_rnd(32 >> ck_bl);
   end
endfunction

task ck_dest;
   input   force_xy;
   integer x0, y0;
   begin
      ck_xy = force_xy || ((GPU_XY_EN != 0) && (ck_rnd(3) != 0));
      if (ck_xy) begin
         gpu_c_dst_xy(16'd128, ck_px(CK_DST_W + ck_rnd(8000)));
         ck_x = ck_rnd(40) - 8;
         ck_y = ck_rnd(20) - 4;
         gpu_c_xy(ck_x, ck_y);
         x0 = ck_x + ck_rnd(6) - 3;
         y0 = ck_y + ck_rnd(4) - 2;
         if (ck_rnd(3) == 0) gpu_c_noclip;
         else                gpu_c_clip(x0, y0, x0 + 2 + ck_rnd(ck_w + 2), y0 + 1 + ck_rnd(ck_h + 2));
      end else
         gpu_c_dst(16'd100 + ck_rnd(50), ck_px(CK_DST_W + ck_rnd(8000)));
   end
endtask

task ck_src;
   begin
      gpu_c_src_fmt(16'd40 + ck_rnd(40), ck_px(CK_SRC_LO + 400 + ck_rnd(600)), 4'h0);
   end
endtask

task ck_tex;
   reg bnd, fre;
   begin
      bnd = ck_xy && ck_rnd(2);
      fre = ck_rnd(3) == 0;
      gpu_c_tex(2 + ck_rnd(4), 2 + ck_rnd(4), ck_rnd(2), ck_rnd(8), fre, bnd, ck_rnd(4));
      gpu_c_uv((ck_rnd(8) << 6) + ck_rnd(64), (ck_rnd(8) << 6) + ck_rnd(64));
      gpu_c_step(ck_rnd(3000) - ((fre && !bnd) ? 0 : 1000), ck_rnd(2000) - ((fre && !bnd) ? 0 : 1000));
      if (ck_xy) begin
         gpu_c_step_row(ck_rnd(2000) - ((fre && !bnd) ? 0 : 1000), ck_rnd(3000) - ((fre && !bnd) ? 0 : 1000));
         gpu_c_texbox(4 + ck_rnd(20), 4 + ck_rnd(20));
      end
   end
endtask

task ck_vtx;
   begin
      gpu_c_vtx(0, 16 * ck_x + ck_rnd(32) - 16, 16 * ck_y + ck_rnd(32) - 16);
      gpu_c_vtx(1, 16 * (ck_x + ck_w + ck_rnd(6)) + ck_rnd(16), 16 * (ck_y + ck_rnd(4)) + ck_rnd(16));
      gpu_c_vtx(2, 16 * (ck_x + ck_rnd(ck_w)) + ck_rnd(16), 16 * (ck_y + ck_h + ck_rnd(4)) + ck_rnd(16));
   end
endtask

// One self-contained item (it sets every setting it uses, except alpha,
// which carries over as the model knows it)
task ck_item;
   input integer kind;
   reg   [2:0] dsw, ssw;
   reg   [3:0] op;
   begin
      ck_w = 2 + ck_rnd(14);
      ck_h = 1 + ck_rnd(7);
      dsw  = ck_rnd(8);
      ssw  = ck_rnd(8);
      op   = ck_rnd(16);
      gpu_c_size(ck_w, ck_h);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp({16'h0, ck_c[ck_rnd(4)]});
      ck_dest((kind >= 6) && (kind <= 8));
      case (kind)
        0: begin                                                 // FILL, gradient, remap
              if (GPU_GRAD_EN != 0) gpu_c_grad(ck_rnd(3), ck_rnd(2), ck_rnd(16) - 8, ck_rnd(2));
              gpu_k_rmp = (ck_caps[0] && (ck_bl < 4)) ? ck_rnd(3) : 2'd0;
              if (gpu_k_rmp != 2'd0) gpu_c_remap_table(CK_RMP_W);
              gpu_c_exec_xy(GPU_FILL, op, dsw, 3'b000);
              gpu_k_rmp = 2'd0;
              if (GPU_GRAD_EN != 0) gpu_c_grad(0, 1'b0, 0, 1'b0);
           end
        1: begin                                                 // COPY: remap, mask plane
              ck_src;
              gpu_k_rmp = (ck_caps[0] && (ck_bl < 4)) ? ck_rnd(3) : 2'd0;
              if (gpu_k_rmp != 2'd0) gpu_c_remap_table(CK_RMP_W | ck_rnd(64));
              gpu_k_mpl = ck_caps[1] && ck_rnd(2);
              if (gpu_k_mpl) gpu_c_mask_plane(32 * CK_MSK_W + 2048 + ck_rnd(1024), ck_rnd(2));
              gpu_c_exec_xy(GPU_COPY, op, dsw, ssw);
              gpu_k_rmp = 2'd0;
              gpu_k_mpl = 1'b0;
           end
        2: begin                                                 // COPY_TRANSP
              ck_src;
              gpu_k_mpl = ck_caps[1] && ck_rnd(2);
              if (gpu_k_mpl) gpu_c_mask_plane(32 * CK_MSK_W + 2048 + ck_rnd(1024), ck_rnd(2));
              gpu_c_exec_xy(GPU_COPYT, op, dsw, ssw);
              gpu_k_mpl = 1'b0;
           end
        3: begin                                                 // SPAN
              if (GPU_GRAD_EN != 0) gpu_c_grad(ck_rnd(3), ck_rnd(2), ck_rnd(16) - 8, ck_rnd(2));
              gpu_c_span(ck_rnd(9) - 4, ck_w);
              if (GPU_GRAD_EN != 0) gpu_c_grad(0, 1'b0, 0, 1'b0);
           end
        4: begin                                                 // EXPAND (MASK)
              ck_sdep = ck_rnd(4);
              gpu_c_src_fmt(16'd0, ((CK_SRC_LO + ck_rnd(800)) << (5 - ck_sdep)) + ck_rnd(32 >> ck_sdep),
                            4'd1 + ck_sdep);
              gpu_exp_mask = (GPU_BLEND_EN != 0) && (ck_rnd(2) != 0);   // (absent without blending: refused)
              gpu_exp_op   = ck_rnd(16);
              gpu_c_expand(ck_rnd(5) - 2, dsw, ck_rnd(2), ck_sdep);
              gpu_exp_mask = 1'b0;
              gpu_exp_op   = 4'd0;
           end
        5: begin                                                 // TEXSPAN
              ck_src;
              ck_tex;
              gpu_c_texspan(ck_rnd(5) - 2, ck_w);
           end
        6: begin                                                 // TEXRECT
              ck_src;
              ck_tex;
              gpu_c_texrect(ck_xy ? (ck_rnd(5) - 2) : 0);
           end
        7: begin                                                 // flat triangle
              ck_vtx;
              gpu_c_trifill(op);
           end
        8: begin                                                 // textured triangle
              ck_src;
              ck_tex;
              ck_vtx;
              gpu_c_tritex;
           end
        9: gpu_c_reset_state;                                    // the items after it set what they use
        10: gpu_c_alpha(ck_rnd(4) != 0, ck_rnd(256));            // SET_ALPHA (blends at 16 bpp)
        default: begin                                           // FENCE
              ck_tag = $random(gpu_seed) & 32'hFF_FFFF;
              gpu_push({OP_FENCE, 4'h0, ck_tag[23:0]});
           end
      endcase
   end
endtask

function ck_built;
   input integer kind;
   begin
      case (kind)
        6:       ck_built = (GPU_XY_EN != 0);
        7, 8:    ck_built = (GPU_XY_EN != 0) && (GPU_TRI_EN != 0);
        10:      ck_built = (GPU_BLEND_EN != 0);
        default: ck_built = 1'b1;
      endcase
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: command lists of every command kind     |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;
      gpu_rsv_seed = `SEED ^ 32'h1157_C0DE;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;                 // FREE checked before each push (any FIFO depth)
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      reg_rd_val(BLNS_CFG2, ck_caps);
      ck_caps = (ck_caps >> 8) & 32'h3;                          // [0] REMAP, [1] MPLANE
      for (ck_k = 0; ck_k < 12; ck_k = ck_k + 1) ck_cnt[ck_k] = 0;
      ck_tag = 32'h0;
      for (ck_l = 0; ck_l < CK_NL; ck_l = ck_l + 1) begin
         ck_mode = (ck_l % 3 == 0) ? 1 : (ck_l % 3 == 1) ? 3 : 4 + ck_rnd(4);
         ck_bl   = gpu_bl(ck_mode);
         gpu_set_mode(ck_mode);
         ck_c[0] = $random(gpu_seed);
         ck_c[1] = $random(gpu_seed);
         ck_c[2] = $random(gpu_seed);
         ck_c[3] = $random(gpu_seed);
         gpu_preload_pal(CK_SRC_LO, CK_SRC_LO + 1800, ck_bl, ck_c[0], ck_c[1], ck_c[2], ck_c[3]);
         gpu_wait_idle;
         gpu_cap_n  = 0;
         gpu_cap_en = 1'b1;
         ck_ni = 3 + ck_rnd(8);
         for (ck_i = 0; ck_i < ck_ni; ck_i = ck_i + 1) begin
            ck_k  = ck_rnd(12);
            if (ck_built(ck_k) && (gpu_cap_n < 900)) begin
               ck_item(ck_k);
               ck_cnt[ck_k] = ck_cnt[ck_k] + 1;
            end
         end
         gpu_cap_en = 1'b0;
         for (ck_i = 0; ck_i < gpu_cap_n; ck_i = ck_i + 1) begin
            vram_mem[CK_LST + ck_i]   = gpu_cap_buf[ck_i];
            gpu_shadow[CK_LST + ck_i] = gpu_cap_buf[ck_i];
         end
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         $display("--- list %0d: %0d words at %0d bpp", ck_l, gpu_cap_n, 1 << ck_bl);
         gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
         gpu_push(CK_LST);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR | 32'h0100_0000);    // no error, LIST ended
         reg_rd(GPU_LIST, 32'h0);
         reg_rd(GPU_FENCE, ck_tag);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_ERR | IF_OVFL);
         gpu_check_all("list of every kind");
      end
      // a long list (N above 2048 words: the high bits of the list counters)
      gpu_set_mode(3);
      ck_bl = 3;
      gpu_wait_idle;
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      while (gpu_cap_n < 3000) begin
         gpu_c_dst(16'd64, ck_px(CK_DST_W + ck_rnd(8000)));
         gpu_c_size(1 + ck_rnd(6), 1 + ck_rnd(2));
         gpu_c_fill($random(gpu_seed));
         gpu_c_exec(GPU_FILL, ck_rnd(16), ck_rnd(8), 3'b000);
      end
      ck_tag = 32'h00_7A11;
      gpu_push({OP_FENCE, 4'h0, ck_tag[23:0]});
      gpu_cap_en = 1'b0;
      for (ck_i = 0; ck_i < gpu_cap_n; ck_i = ck_i + 1) begin
         vram_mem[CK_LST + ck_i]   = gpu_cap_buf[ck_i];
         gpu_shadow[CK_LST + ck_i] = gpu_cap_buf[ck_i];
      end
      $display("--- a long list: %0d words", gpu_cap_n);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
      gpu_push(CK_LST);
      reg_poll(GPU_STAT, 32'h0100_0000, 32'h0100_0000, 200);     // LIST
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR | 32'h0100_0000);
      reg_rd(GPU_LIST, 32'h0);
      reg_rd(GPU_FENCE, ck_tag);
      gpu_check_all("long list");

      $display("INFO:  FILL %0d COPY %0d COPY_T %0d SPAN %0d EXPAND %0d TEXSPAN %0d TEXRECT %0d TRI %0d TRITEX %0d RESET_STATE %0d SET_ALPHA %0d FENCE %0d",
               ck_cnt[0], ck_cnt[1], ck_cnt[2], ck_cnt[3], ck_cnt[4], ck_cnt[5], ck_cnt[6], ck_cnt[7],
               ck_cnt[8], ck_cnt[9], ck_cnt[10], ck_cnt[11]);
      $display("INFO:  %0d command words with reserved bits set", gpu_rsv_n);
      if (GPU_BLEND_EN != 0) gpu_c_alpha(1'b0, 8'd0);
      gpu_wait_idle;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
