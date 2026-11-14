//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_retain
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_retain.v
// Module Description : The GPU settings table (doc/gpu_commands.md, GPU
//                      settings) through the flushes. The model never
//                      re-sends a setting after a flush (gpu_flush_resend 0):
//                      1. every setting set to a value other than its reset
//                         value (source pitch, SRC_FMT and base, destination
//                         pitch, base, x/y mode, origin and position, size,
//                         fill and transparent colours, clip window, texture
//                         configuration, start, step, row step and box,
//                         gradient with its RGB steps, alpha and MIX5,
//                         vertices, the remap table, mask-plane and alpha-
//                         plane pointers and INV, the texture filter
//                         (BILINEAR, TBORDER), as built), then CLEAR_ERR, ABORT, GPU_EN = 0, an error
//                         cleared by CLEAR_ERR, an error with ABORT then
//                         CLEAR_ERR; then FILL, COPY (remap, mask plane),
//                         COPY_TRANSP, TEXRECT / TEXSPAN (bilinear when
//                         built), TRI, textured TRI, an RGB565A8 copy (blend
//                         builds, 16 bpp), EXPAND, SPAN without sending any setting again,
//                         compared with the model (x/y and address mode,
//                         8 and 16 bpp);
//                      2. a command cut between its word and its operand by
//                         ABORT / CLEAR_ERR (decoder waiting), or queued
//                         behind an error (CLEAR_ERR; ABORT, then CLEAR_ERR):
//                         the operand pushed after the flush is discarded,
//                         the word's settings are kept when it was decoded
//                         (SET_SRC pitch and SRC_FMT, SET_SRC IMM: the arm
//                         cleared, SET_DST pitch and x/y mode, SET_CLIP
//                         x0 / y0, SET_AUX MASK_PLANE INV), the operand's are
//                         lost, a cut CALL runs nothing; across the modes
//                         (an address-mode SET_DST word cut in x/y mode,
//                         an x/y one in address mode: the origin, position
//                         and base of the last operand) and with pitch 0
//                         (the frame width at the word, also after a
//                         display width change and after RESET_STATE);
//                      3. RESET_STATE: the reset values, seen through the
//                         drawing (address mode at 0, whole clip window, no
//                         gradient, no blend, 1 x 1 texture at the source
//                         base, zero-area triangle, pointers 0), and what it
//                         keeps: the error record, GPU_FENCE, the command
//                         list it runs in, the immediate-source arm;
//                      4. the immediate source disarmed by each flush (the
//                         next copy reads the VRAM);
//                      5. a FENCE flushed before the decoder reached it
//                         (ABORT, CLEAR_ERR in ERR, GPU_EN = 0) never
//                         updates GPU_FENCE;
//                      6. a flush landing in the middle of a FILL, COPY,
//                         EXPAND, TEXSPAN, TEXRECT, TRI, textured TRI
//                         (after its first VRAM writes): CLEAR_ERR, ABORT,
//                         GPU_EN = 0, CLEAR_ERR + ABORT, an error behind it
//                         cleared by CLEAR_ERR, or by ABORT then CLEAR_ERR;
//                         the primitive completes (CLEAR_ERR, GPU_DONE) or
//                         leaves a strict prefix of its walk, then every
//                         command kind is drawn with the settings kept. The
//                         error lands mid-primitive with run-ahead only
//                         (checked): without it the decoder reaches the word
//                         when the primitive is done (a whole walk).
//                      The documented reserved and ignored command bits are
//                      set at random throughout (gpu_rsv_en).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer RT_DISPW  = 64;
localparam integer RT_SRC_LO = 1000;             // sources, textures: words [RT_SRC_LO, RT_SRC_HI)
localparam integer RT_SRC_HI = 3000;
localparam integer RT_MSK_W  = 3000;             // mask plane: words [3000, 3200)
localparam integer RT_RMP_W  = 3264;             // remap table: words [3264, 3328)
localparam integer RT_LST_W  = 3400;             // command list: words [3400, 3600)
localparam integer RT_DST_W  = 8000;             // destinations: words [8000, 30000)
localparam integer RT_A8_W   = 4000;             // alpha plane: words [4000, 4800)
localparam integer RT_RS_W   = 400;              // RESET_STATE destinations near pixel 0: words [400, 900)

integer    rt_k, rt_r, rt_kind, rt_mode, rt_bl, rt_x, rt_y, rt_w, rt_h, rt_n, rt_i, rt_c;
integer    rt_cut, rt_scn, rt_nfl, rt_prim;
reg        rt_big = 1'b0;                 // larger rectangles (section 6: a flush lands mid-primitive)
reg        rt_errbusy = 1'b0;             // the poll that first saw ERR also saw PRIM_BUSY
reg        rt_xy, rt_fmt, rt_ok;
reg  [3:0] rt_sfmt;
reg [31:0] rt_w32, rt_st, rt_caps, rt_stray, rt_fence, rt_v;
reg [15:0] rt_c0, rt_c1, rt_c2, rt_c3;

function integer rt_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      rt_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] rt_px;                   // first pixel of word w at log2 bpp bl
   input integer w;
   input integer bl;
   begin
      rt_px = w << (5 - bl);
   end
endfunction

task rt_no_err;
   input [8*40-1:0] label;
   begin
      reg_rd_val(GPU_STAT, rt_st);
      if (rt_st & GS_ERR) begin
         $display("ERROR: GPU %0s -- ERR set, GPU_STAT 0x%h %t", label, rt_st, $time);
         error = error + 1;
         reg_wr(GPU_CTRL, 32'h1);
      end
   end
endtask

task rt_wait_err;
   integer guard;
   begin
      guard = 0;
      rt_st = 32'h0;
      while (!(rt_st & GS_ERR) && (guard < 3000)) begin       // (behind a primitive: at its end)
         reg_rd_val(GPU_STAT, rt_st);
         guard = guard + 1;
      end
      if (!(rt_st & GS_ERR)) tb_error("gpu_retain: the invalid word raised no ERR");
      rt_errbusy = ((rt_st & GS_PRIM_BUSY) != 0);                // the primitive before it still drawing
   end
endtask

// The flush of a round, on an idle GPU (kinds 4 and 5: through an error)
task rt_flush;
   input integer kind;
   begin
      case (kind)
        0, 1, 2: gpu_flush(kind);
        default: begin
                    gpu_push(32'h0123_4567);                      // opcode 0: ERR_CAUSE 1
                    rt_wait_err;
                    if (kind == 5) begin
                       reg_wr(GPU_CTRL, 32'h2);
                       repeat(8) @(posedge free_clk);
                       reg_rd_mask(GPU_STAT, GS_ERR, GS_ERR);        // ABORT keeps ERR
                    end
                    gpu_flush(0);
                    repeat(4) @(posedge free_clk);
                    reg_rd_mask(GPU_STAT, {4'h0, 3'd1, 25'h0} | GS_EMPTY, 32'hFE40_0000 | GS_EMPTY);
                 end
      endcase
      repeat(4) @(posedge free_clk);
   end
endtask

function [8*24-1:0] rt_kname;
   input integer kind;
   begin
      case (kind)
        0:       rt_kname = "CLEAR_ERR";
        1:       rt_kname = "ABORT";
        2:       rt_kname = "GPU_EN = 0";
        3:       rt_kname = "CLEAR_ERR + ABORT";
        4:       rt_kname = "ERR, CLEAR_ERR";
        default: rt_kname = "ERR, ABORT, CLEAR_ERR";
      endcase
   end
endfunction

// The source region in a 4-colour palette at the round's depth (keys hit)
task rt_src_pal;
   begin
      rt_c0 = $random(gpu_seed);
      rt_c1 = $random(gpu_seed);
      rt_c2 = $random(gpu_seed);
      rt_c3 = $random(gpu_seed);
      gpu_preload_pal(RT_SRC_LO, RT_SRC_HI, rt_bl, rt_c0, rt_c1, rt_c2, rt_c3);
   end
endtask

//----------------------------------------------------------------------------
// 1. Every setting to a non-reset value, a flush, then commands that use them
//----------------------------------------------------------------------------
task rt_program;                         // rt_xy, rt_fmt (EXPAND source) chosen by the caller
   integer      sdep;
   begin
      rt_w = rt_big ? (24 + rt_rnd(16)) : (5 + rt_rnd(8));
      rt_h = rt_big ? (10 + rt_rnd(8))  : (3 + rt_rnd(6));
      if (rt_w > GPU_DIM_MASK) rt_w = GPU_DIM_MASK;
      if (rt_h > GPU_DIM_MASK) rt_h = GPU_DIM_MASK;
      rt_sfmt = rt_fmt ? (4'd1 + rt_rnd(4)) : 4'd0;
      if (rt_big)                                                // swapped walks stay inside the VRAM
         gpu_c_src_fmt(16'd40 + rt_rnd(20), rt_px(RT_SRC_LO + 900 + rt_rnd(100), rt_bl) + rt_rnd(8), rt_sfmt);
      else
         gpu_c_src_fmt(16'd40 + rt_rnd(40), rt_px(RT_SRC_LO + 8 + rt_rnd(400), rt_bl) + rt_rnd(8), rt_sfmt);
      if (rt_xy) begin
         gpu_c_dst_xy(16'd100 + rt_rnd(40), rt_px(RT_DST_W + 200 + rt_rnd(2000), rt_bl) + rt_rnd(16));
         rt_x = 4 + rt_rnd(20);
         rt_y = 2 + rt_rnd(10);
         gpu_c_xy(rt_x, rt_y);
         gpu_c_clip(rt_x + rt_rnd(3) - 1, rt_y + rt_rnd(3) - 1, rt_x + rt_w - 2 + rt_rnd(3), rt_y + rt_h - 1 - rt_rnd(2));
      end else
         gpu_c_dst(16'd100 + rt_rnd(40), rt_px(RT_DST_W + 200 + rt_rnd(2000), rt_bl) + rt_rnd(16));
      gpu_c_size(rt_w, rt_h);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp({16'h0, rt_c1});
      gpu_c_tex(4'd4, 4'd4, 1'b1, rt_rnd(8), 1'b0, rt_xy, rt_bl == 4 ? rt_rnd(4) : 8'd1 + rt_rnd(3));
      gpu_c_uv(((2 + rt_rnd(6)) << 6) + rt_rnd(64), ((1 + rt_rnd(6)) << 6) + rt_rnd(64));   // 10.6
      gpu_c_step(16'd400 + rt_rnd(1600), rt_rnd(800) - 400);
      if (rt_xy) begin
         gpu_c_step_row(rt_rnd(800) - 400, 16'd500 + rt_rnd(1500));
         gpu_c_texbox(9 + rt_rnd(6), 9 + rt_rnd(6));
      end
      if (GPU_GRAD_EN != 0) begin
         if ((rt_bl == 4) && rt_rnd(2))
            gpu_c_grad_rgb(1 + rt_rnd(3), rt_rnd(2), rt_rnd(256) - 128, rt_rnd(256) - 128, rt_rnd(256) - 128, 1'b1);
         else
            gpu_c_grad(1 + rt_rnd(3), rt_rnd(2), rt_rnd(15) - 7, 1'b1);
      end
      if (GPU_BLEND_EN != 0) gpu_c_alpha5(1'b1, 8'd1 + rt_rnd(254), rt_rnd(2));
      if (GPU_BLEND_EN != 0) gpu_c_alpha_plane(4 * RT_A8_W + rt_rnd(256));
      if ((GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0)) gpu_c_tex_filter(rt_rnd(4) != 0, (GPU_BLEND_EN != 0) && rt_rnd(2));
      if ((GPU_TRI_EN != 0) && rt_xy) begin
         gpu_c_vtx(0, 16 * rt_x + rt_rnd(16), 16 * rt_y + rt_rnd(16));
         gpu_c_vtx(1, 16 * (rt_x + rt_w) + rt_rnd(16), 16 * rt_y + 8 + rt_rnd(16));
         gpu_c_vtx(2, 16 * (rt_x + 2) + rt_rnd(16), 16 * (rt_y + rt_h) + rt_rnd(16));
      end
      if (rt_caps[0]) gpu_c_remap_table(RT_RMP_W | rt_rnd(64));
      if (rt_caps[1]) gpu_c_mask_plane(rt_px(RT_MSK_W, 0) + rt_rnd(64), rt_rnd(2));
   end
endtask

task rt_draw;
   begin
      // FILL: gradient, alpha, clip, x/y position, size, fill colour
      gpu_c_exec_xy(GPU_FILL, rt_rnd(13), 3'b000, 3'b000);
      if (!rt_fmt) begin
         // COPY: the source surface, remap table (8 bpp), mask plane and INV
         gpu_k_rmp = (rt_caps[0] && (rt_bl < 4)) ? 2'd1 : 2'd0;
         gpu_k_mpl = rt_caps[1];
         gpu_c_exec_xy(GPU_COPY, 4'd0, rt_rnd(8), 3'b000);
         gpu_k_rmp = 2'd0;
         gpu_k_mpl = 1'b0;
         // COPY_TRANSP: the transparent colour
         gpu_c_exec_xy(GPU_COPYT, rt_rnd(13), 3'b000, rt_rnd(8));
         if (rt_xy) begin
            gpu_c_texrect(0);                                    // texture state, texture box, row step
            if (GPU_TRI_EN != 0) begin
               gpu_c_trifill(rt_rnd(13));                        // the vertices
               gpu_c_tritex;
            end
         end else
            gpu_c_texspan(0, rt_w);                              // texture state (size N x 1)
         if ((GPU_BLEND_EN != 0) && (rt_bl == 4)) begin         // RGB565A8: the alpha-plane pointer, MIX5
            gpu_k_a8 = 1'b1;
            gpu_c_exec_xy(GPU_COPY, 4'd0, rt_rnd(8), 3'b000);
            gpu_k_a8 = 1'b0;
         end
      end else
         gpu_c_expand(0, rt_rnd(8), rt_rnd(2), rt_sfmt - 4'd1);  // SRC_FMT, source pitch and base
      gpu_c_span(rt_rnd(5) - 2, rt_w);                           // DELTA moves x / the base
   end
endtask

task rt_round;
   input integer kind;
   begin
      gpu_set_mode(rt_mode);
      rt_bl = gpu_bl(rt_mode);
      rt_src_pal;
      rt_program;
      gpu_wait_idle;
      rt_no_err("programming");
      gpu_check_touched("before the flush");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      rt_flush(kind);
      $display("--- %0s, %0s mode, %0d bpp%0s: every setting kept", rt_kname(kind),
               rt_xy ? "x/y" : "address", 1 << rt_bl, rt_fmt ? ", EXPAND source" : "");
      rt_draw;
      gpu_wait_idle;
      rt_no_err("after the flush");
      gpu_check_touched("settings kept");
   end
endtask

//----------------------------------------------------------------------------
// 2. A command cut between its word and its operand
//   cut 0 SET_SRC (pitch, SRC_FMT), 1 SET_SRC IMM, 2 SET_DST address mode,
//   3 SET_DST x/y mode, 4 SET_CLIP, 5 SET_AUX MASK_PLANE, 6 CALL; across the
//   modes: 7 an address-mode SET_DST word in x/y mode, 8 an x/y SET_DST word
//   in address mode (the origin, position (0, 0) and pitch-0 width of the
//   last SET_DST operand); pitch 0: 9 an x/y SET_DST word after a display
//   width change, 10 after RESET_STATE (the frame width at the word)
//   scenario 0 ABORT, 1 CLEAR_ERR with the decoder waiting for the operand;
//   2 the word queued behind an error, CLEAR_ERR; 3 the same, ABORT then
//   CLEAR_ERR (the discard armed by the CLEAR_ERR)
//----------------------------------------------------------------------------
reg [31:0] rt_cw;
reg [15:0] rt_p2;
reg  [3:0] rt_f2;
reg        rt_inv2;
integer    rt_x0n, rt_y0n;

task rt_cut_case;
   input integer cut;
   input integer scn;
   reg           decoded;
   begin
      gpu_set_mode(4);
      rt_bl = 4;
      rt_xy = (cut == 3) || (cut == 4) || (cut == 7) || (cut == 9);
      rt_fmt = 1'b0;
      rt_caps_save;
      rt_src_pal;
      rt_program;
      gpu_wait_idle;
      gpu_check_touched("cut: set-up");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      rt_p2   = 16'd60 + rt_rnd(60);
      if (((cut == 2) || (cut == 3) || (cut == 7) || (cut == 8)) && (rt_rnd(3) == 0)) rt_p2 = 16'd0;
      if ((cut == 9) || (cut == 10)) rt_p2 = 16'd0;
      if (cut == 9) begin                                        // the width changes after the operand
         gpu_set_dispw(RT_DISPW + 3 + rt_rnd(9));
         rt_p2 = 16'd0;
      end
      if (cut == 10) begin                                       // pitch-0 width, origin, position reset
         gpu_c_reset_state;
         gpu_wait_idle;
      end
      rt_f2   = 4'd1 + rt_rnd(4);
      rt_inv2 = ~gpu_m_minv;
      rt_x0n  = gpu_m_cx0 + 1 + rt_rnd(2);
      rt_y0n  = gpu_m_cy0 - 1;
      case (cut)
        0: rt_cw = {OP_SET_SRC, 8'h00, rt_f2, rt_p2};
        1: rt_cw = {OP_SET_SRC, 7'h00, 1'b1, 4'h0, rt_p2};
        2: rt_cw = {OP_SET_DST, 12'h000, rt_p2};
        3, 8, 9, 10: rt_cw = {OP_SET_DST, 11'h000, 1'b1, rt_p2};
        7: rt_cw = {OP_SET_DST, 12'h000, rt_p2};
        4: rt_cw = {OP_SET_EXT, EXT_SET_CLIP, rt_y0n[11:0], rt_x0n[11:0]};
        5: rt_cw = {OP_SET_EXT, EXT_SET_AUX, 4'd1, 3'b000, rt_inv2, 16'h0000};
        default: rt_cw = {OP_CALL, 4'h0, 24'd5};
      endcase
      if (scn < 2) begin
         gpu_push(rt_cw);
         repeat(12) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_EMPTY | GS_BUSY, GS_EMPTY | GS_BUSY | GS_ERR);   // waiting for the operand
         reg_wr(GPU_CTRL, (scn == 0) ? 32'h2 : 32'h1);
         decoded = 1'b1;
      end else begin
         gpu_freeze(1);
         gpu_push(32'h0000_0000);                                // ERR_CAUSE 1
         gpu_push(rt_cw);
         gpu_freeze(0);
         rt_wait_err;
         if (scn == 3) begin
            reg_wr(GPU_CTRL, 32'h2);
            repeat(8) @(posedge free_clk);
            reg_rd_mask(GPU_STAT, GS_ERR, GS_ERR);
         end
         reg_wr(GPU_CTRL, 32'h1);
         decoded = 1'b0;                                         // flushed before the decoder read it
      end
      gpu_k_imm = 1'b0;
      gpu_flush_hint = 1'b0;
      repeat(5) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, 32'h0, GS_BUSY | GS_ERR);            // BUSY does not wait for the discard
      $display("--- cut %0s (%0s): the operand pushed after the flush is discarded",
               (cut == 0) ? "SET_SRC" : (cut == 1) ? "SET_SRC IMM" : (cut == 2) ? "SET_DST" :
               (cut == 3) ? "SET_DST XY" : (cut == 4) ? "SET_CLIP" : (cut == 5) ? "SET_AUX MASK_PLANE" :
               (cut == 6) ? "CALL" : (cut == 7) ? "SET_DST (address) in x/y mode" :
               (cut == 8) ? "SET_DST XY in address mode" : (cut == 9) ? "SET_DST XY pitch 0, width changed" :
               "SET_DST XY pitch 0 after RESET_STATE",
               (scn == 0) ? "ABORT, decoder waiting" : (scn == 1) ? "CLEAR_ERR, decoder waiting" :
               (scn == 2) ? "queued behind an error, CLEAR_ERR" : "queued behind an error, ABORT, CLEAR_ERR");
      gpu_push(rt_stray);                                        // the operand: discarded
      if (cut == 10) gpu_c_size(rt_w, rt_h);                     // (RESET_STATE: 1 x 1)
      gpu_wait_idle;
      rt_no_err("after the cut");
      gpu_check_all("cut: operand discarded");
      // the model: the word's settings when it was decoded, never the operand's
      if (decoded)
         case (cut)
           0: begin gpu_m_src_pitch = rt_p2; gpu_m_src_fmt = rt_f2; end
           1: begin gpu_m_src_pitch = rt_p2; gpu_m_src_fmt = 4'h0; end
           2: begin gpu_m_dst_pitch = rt_p2; gpu_m_xy = 1'b0; end
           3, 8, 9, 10: begin                                   // pitch 0: the frame width at the word
                 gpu_m_dst_pitch = rt_p2;
                 gpu_m_xy        = 1'b1;
                 gpu_m_xyp       = (rt_p2 == 16'd0) ? gpu_m_dispw : rt_p2;
              end
           7: begin gpu_m_dst_pitch = rt_p2; gpu_m_xy = 1'b0; end
           4: begin gpu_m_cx0 = gpu_sx12(rt_x0n[11:0]); gpu_m_cy0 = gpu_sx12(rt_y0n[11:0]); end
           5: gpu_m_minv = rt_inv2;
           default: ;
         endcase
      // what the settings now give
      case (cut)
        0: if (decoded) gpu_c_expand(0, 3'b000, 1'b0, rt_f2 - 4'd1);
           else         gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);
        1: gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);         // the VRAM source: the arm cleared
        5: begin
              gpu_k_mpl = 1'b1;
              gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);
              gpu_k_mpl = 1'b0;
           end
        default: gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
      endcase
      gpu_wait_idle;
      rt_no_err("after the cut command");
      gpu_check_all("cut: the word's settings kept");
      if (cut == 9) gpu_set_dispw(RT_DISPW);
      rt_caps_restore;
   end
endtask

reg [31:0] rt_caps_sv;
task rt_caps_save;                       // the cut cases program only what they need
   begin
      rt_caps_sv = rt_caps;
      if (rt_cut != 5) rt_caps = rt_caps & ~32'h2;
      if (rt_cut == 5) rt_caps = rt_caps & ~32'h1;
   end
endtask

task rt_caps_restore;
   begin
      rt_caps = rt_caps_sv;
   end
endtask

//----------------------------------------------------------------------------
// 3. RESET_STATE
//----------------------------------------------------------------------------
task rt_reset_values;
   begin
      $display("--- RESET_STATE: the reset values, through the drawing");
      gpu_set_mode(4);
      rt_bl = 4;
      rt_xy = (GPU_XY_EN != 0);
      rt_fmt = 1'b0;
      rt_src_pal;
      rt_program;
      gpu_wait_idle;
      gpu_check_touched("RESET_STATE: set-up");
      gpu_c_reset_state;
      // address mode at pixel 0 (pitch 0 = the frame width), 1 x 1, fill 0
      gpu_c_exec(GPU_FILL, 4'd1, 3'b000, 3'b000);                // op 1: NOT 0 at pixel 0
      gpu_wait_idle;
      gpu_check_touched("RESET_STATE: destination, size, fill");
      // only the destination and size sent again: no gradient, no blend
      gpu_c_dst(16'd0, rt_px(RT_RS_W, 4));
      gpu_c_size(14'd9, 14'd4);
      gpu_c_exec(GPU_FILL, 4'd1, 3'b000, 3'b000);
      // source pitch 0 and base 0 (pixel 0), SRC_FMT 0; pointers 0
      gpu_c_dst(16'd0, rt_px(RT_RS_W + 100, 4));
      if (rt_caps[1]) gpu_k_mpl = 1'b1;
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_k_mpl = 1'b0;
      gpu_c_dst(16'd0, rt_px(RT_RS_W + 200, 4));
      gpu_c_exec(GPU_COPYT, 4'd0, 3'b000, 3'b000);              // transparent colour 0
      gpu_c_dst(16'd0, rt_px(RT_RS_W + 300, 4));
      gpu_c_texspan(0, 14'd7);                                   // the 1 x 1 texture at pixel 0
      if (GPU_XY_EN != 0) begin
         gpu_c_dst_xy(16'd0, rt_px(RT_RS_W + 400, 4) + 40);
         gpu_c_xy(-30, 1);                                       // the whole clip window: drawn
         gpu_c_size(14'd8, 14'd2);
         gpu_c_exec_xy(GPU_FILL, 4'd1, 3'b000, 3'b000);
         gpu_c_texrect(0);                                       // row step 0, no BOUND
         if (GPU_TRI_EN != 0) begin
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_c_trifill(4'd1);                                 // vertices 0: zero area
            gpu_wait_idle;
            reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
         end
      end
      gpu_wait_idle;
      rt_no_err("after RESET_STATE");
      gpu_check_touched("RESET_STATE: the reset values");
   end
endtask

task rt_reset_kept;
   integer guard;
   begin
      $display("--- RESET_STATE keeps the error record and GPU_FENCE");
      gpu_set_mode(4);
      rt_fence = 24'h00_0000 | ($random(gpu_seed) & 24'hFFFFFF);
      gpu_push({OP_FENCE, 4'h0, rt_fence[23:0]});
      gpu_wait_idle;
      reg_rd(GPU_FENCE, rt_fence & 32'hFF_FFFF);
      gpu_push(32'h0BAD_C0DE);                                   // opcode 0: ERR_CAUSE 1
      rt_wait_err;
      reg_wr(GPU_CTRL, 32'h1);
      gpu_c_reset_state;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, {4'h0, 3'd1, 25'h0}, 32'hFE40_0000);
      reg_rd(GPU_ERR, 32'h0BAD_C0DE);
      reg_rd(GPU_FENCE, rt_fence & 32'hFF_FFFF);

      if (GPU_IMM_EN != 0) begin
         $display("--- RESET_STATE keeps the immediate-source arm");
         gpu_preload_rand(RT_RS_W, RT_RS_W + 500);
         gpu_c_imm(4'h0, 6);
         for (rt_i = 0; rt_i < 6; rt_i = rt_i + 1) gpu_imm_buf[rt_i] = $random(gpu_seed);
         gpu_c_reset_state;
         gpu_c_dst(16'd0, rt_px(RT_RS_W + 50, 4));
         gpu_c_size(14'd4, 14'd3);
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);             // takes the immediate data
         gpu_wait_idle;
         rt_no_err("immediate copy after RESET_STATE");
         gpu_check_touched("RESET_STATE keeps the arm");
      end

      $display("--- RESET_STATE in a command list: the list goes on");
      gpu_c_dst(16'd0, rt_px(RT_RS_W + 250, 4));
      gpu_c_size(14'd6, 14'd2);
      gpu_c_fill(32'h0000_1357);
      gpu_wait_idle;
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_c_reset_state;
      gpu_c_dst(16'd0, rt_px(RT_RS_W + 300, 4));
      gpu_c_size(14'd5, 14'd3);
      gpu_c_fill(32'h0000_2468);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_push({OP_FENCE, 4'h0, 24'h00_A5A5});
      gpu_cap_en = 1'b0;
      for (rt_i = 0; rt_i < gpu_cap_n; rt_i = rt_i + 1) begin
         vram_mem[RT_LST_W + rt_i]   = gpu_cap_buf[rt_i];
         gpu_shadow[RT_LST_W + rt_i] = gpu_cap_buf[rt_i];
      end
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
      gpu_push(RT_LST_W);
      gpu_wait_idle;
      rt_no_err("list with RESET_STATE");
      reg_rd(GPU_FENCE, 32'h00_A5A5);
      reg_rd(GPU_LIST, 32'h0);
      gpu_check_all("RESET_STATE in a list");
   end
endtask

//----------------------------------------------------------------------------
// 4. The immediate source disarmed by each flush
//----------------------------------------------------------------------------
task rt_imm_disarm;
   input integer kind;
   begin
      $display("--- SET_SRC IMM, then %0s: the next copy reads the VRAM", rt_kname(kind));
      gpu_set_mode(3);
      rt_bl = 3;
      gpu_c_src_fmt(16'd50, rt_px(RT_SRC_LO + 40, 3) + 3, 4'h0);
      gpu_c_dst(16'd77, rt_px(RT_DST_W + 9000, 3) + 1);
      gpu_c_size(14'd7, 14'd5);
      gpu_c_imm(4'h0, 9);
      gpu_wait_idle;
      rt_flush(kind);
      if (gpu_k_imm) tb_error("gpu_retain: the model kept the arm (test bug)");
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);                // no data words: a VRAM copy
      gpu_wait_idle;
      rt_no_err("copy after the disarm");
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | GS_BUSY);
      gpu_check_touched("immediate source disarmed");
   end
endtask

//----------------------------------------------------------------------------
// 5. A FENCE flushed before the decoder reached it
//----------------------------------------------------------------------------
task rt_fence_flushed;
   input integer kind;                   // 0 ABORT, 1 CLEAR_ERR in ERR, 2 GPU_EN = 0
   reg   [23:0] old, nw;
   begin
      $display("--- FENCE flushed by %0s: GPU_FENCE unchanged", (kind == 0) ? "ABORT" :
               (kind == 1) ? "CLEAR_ERR in ERR" : "GPU_EN = 0");
      gpu_set_mode(4);
      old = $random(gpu_seed);
      nw  = ~old;
      gpu_push({OP_FENCE, 4'h0, old});
      gpu_wait_idle;
      reg_rd(GPU_FENCE, {8'h0, old});
      gpu_c_dst(16'd128, rt_px(RT_DST_W + 12000, 4));
      gpu_c_size(14'd120, 14'd30);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_snapshot;
      gpu_x_setup(GPU_FILL, 4'd5, 3'b000, 3'b000);
      if (kind == 1) begin
         gpu_freeze(1);
         gpu_push(32'h0000_0000);
         gpu_push({OP_FENCE, 4'h0, nw});
         gpu_freeze(0);
         rt_wait_err;
         reg_wr(GPU_CTRL, 32'h1);
      end else begin
         gpu_push(gpu_exec_word(GPU_FILL, 4'd5, 3'b000, 3'b000));
         gpu_push({OP_FENCE, 4'h1, nw});                         // with IRQ
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         repeat(40) @(posedge free_clk);
         if (kind == 0) reg_wr(GPU_CTRL, 32'h2);
         else begin
            reg_wr(CTRL, 32'h4);
            reg_wr(CTRL, 32'h14);
         end
      end
      gpu_flush_hint = 1'b0;
      gpu_wait_idle;
      repeat(50) @(posedge free_clk);
      reg_rd(GPU_FENCE, {8'h0, old});
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FENCE);
      if (kind != 1) begin
         gpu_find_prefix(rt_n);
         if ((rt_n < 0) || (rt_n >= gpu_x_w * gpu_x_h)) begin
            $display("ERROR: GPU abandoned FILL before the FENCE -- %0d of %0d pixels (not a strict prefix) %t",
                     rt_n, gpu_x_w * gpu_x_h, $time);
            error = error + 1;
         end
         gpu_check_touched("FILL abandoned before the FENCE");
      end
      gpu_push({OP_FENCE, 4'h0, nw});                            // a FENCE reached updates it
      gpu_wait_idle;
      reg_rd(GPU_FENCE, {8'h0, nw});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

//----------------------------------------------------------------------------
// 6. A flush landing in the middle of a primitive, then the settings drawn
//   kind 0 CLEAR_ERR, 1 ABORT, 2 GPU_EN = 0, 3 CLEAR_ERR and ABORT together,
//   4 an error decoded behind the primitive, CLEAR_ERR; 5 the same, ABORT
//   then CLEAR_ERR. prim 0 FILL, 1 COPY, 2 EXPAND, 3 TEXSPAN, 4 TEXRECT,
//   5 TRI, 6 textured TRI. The flush comes after the primitive's first VRAM
//   writes: ABORT / GPU_EN = 0 leave a strict prefix of its walk (no
//   GPU_DONE), CLEAR_ERR lets it complete; then every command kind is drawn
//   with the settings kept, nothing sent again.
//----------------------------------------------------------------------------
integer    rt_cls, rt_nd, rt_nw, rt_trg, rt_try;
reg        rt_hit, rt_retry;

function [8*16-1:0] rt_pname;
   input integer prim;
   begin
      case (prim)
        0:       rt_pname = "FILL";
        1:       rt_pname = "COPY";
        2:       rt_pname = "EXPAND";
        3:       rt_pname = "TEXSPAN";
        4:       rt_pname = "TEXRECT";
        5:       rt_pname = "TRI";
        default: rt_pname = "textured TRI";
      endcase
   end
endfunction

task rt_mid;
   input integer kind;
   input integer prim;
   integer       kk, last;
   begin
      rt_mode = rt_rnd(2) ? 4 : 3;
      gpu_set_mode(rt_mode);
      rt_bl  = gpu_bl(rt_mode);
      rt_xy  = (prim >= 4) || ((prim != 3) && (GPU_XY_EN != 0) && rt_rnd(2));
      rt_fmt = (prim == 2);
      rt_big = 1'b1;
      rt_src_pal;
      rt_program;
      rt_big = 1'b0;
      if (GPU_BLEND_EN != 0) gpu_c_alpha(1'b1, 8'd160 + rt_rnd(95));   // a blend that changes the pixels
      gpu_wait_idle;
      rt_no_err("mid-primitive: programming");
      gpu_check_touched("mid-primitive: set-up");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_mon_start;
      gpu_rec_begin;
      case (prim)
        0: gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
        1: gpu_c_exec_xy(GPU_COPY, 4'd0, rt_rnd(8), 3'b000);
        2: gpu_c_expand(0, rt_rnd(8), 1'b1, rt_sfmt - 4'd1);
        3: gpu_c_texspan(0, rt_w);
        4: gpu_c_texrect(0);
        5: gpu_c_trifill(4'd0);
        default: gpu_c_tritex;
      endcase
      gpu_rec_end;
      if ((kind == 4) || (kind == 5)) gpu_push(32'h0123_4567);   // opcode 0: ERR_CAUSE 1, behind it
      // destination words written by the walk: the flush after a quarter of them at most
      rt_nw = 0;
      last  = -1;
      for (kk = 0; kk < gpu_rec_n; kk = kk + 1)
         if (gpu_rec_wr[kk] && (gpu_word_of(gpu_rec_pa[kk], gpu_rec_bl) != last)) begin
            rt_nw = rt_nw + 1;
            last  = gpu_word_of(gpu_rec_pa[kk], gpu_rec_bl);
         end
      // Too few words (clipped, outside the box): draw another. The flush lands a
      // few cycles after the trigger write, while the write buffer, the write-back
      // slot and the pixels being merged still hold up to about 3 more words: with
      // 8 words or more a strict prefix is left (with 4, the last pixel could be
      // merged on the flush edge and the whole walk drawn)
      rt_retry = (rt_nw < 8);
      if (rt_retry) begin
         if ((kind == 4) || (kind == 5)) begin rt_wait_err; reg_wr(GPU_CTRL, 32'h1); end
         gpu_mon_stop;
         gpu_wait_idle;
         rt_no_err("mid-primitive: too small, drawn whole");
         gpu_check_touched("mid-primitive: too small, drawn whole");
      end else begin
      rt_trg = 1 + rt_rnd(rt_nw / 4);
      gpu_wait_wr(rt_trg, rt_hit);
      case (kind)
        0:       reg_wr(GPU_CTRL, 32'h1);
        1:       reg_wr(GPU_CTRL, 32'h2);
        2:       begin reg_wr(CTRL, {29'h0, gpu_m_mode}); reg_wr(CTRL, 32'h10 | gpu_m_mode); end
        3:       reg_wr(GPU_CTRL, 32'h3);
        default: begin
                    rt_wait_err;
                    if (kind == 5) reg_wr(GPU_CTRL, 32'h2);
                    reg_wr(GPU_CTRL, 32'h1);
                 end
      endcase
      gpu_mon_stop;
      gpu_k_imm      = 1'b0;
      gpu_flush_hint = 1'b0;
      gpu_wait_idle;
      reg_rd_val(IRQ_FLAG, rt_v);
      if (!rt_hit) begin
         $display("ERROR: GPU %0s: %0d writes of %0d before it ended, %0d awaited (test bug: the flush cannot land in its middle) %t",
                  rt_pname(prim), gpu_mon_wr, rt_nw, rt_trg, $time);
         error = error + 1;
      end
      gpu_rec_prefix(rt_v[4], rt_cls, rt_nd);
      // the error behind the primitive: with run-ahead decoded while it draws (checked);
      // without it the decoder reaches the word only once the primitive is done, so
      // ERR, ABORT, CLEAR_ERR then finds a whole walk
      if (((kind == 4) || (kind == 5)) && (GPU_RUNAHEAD_EN != 0) && !rt_errbusy) begin
         $display("ERROR: GPU %0s: the error behind it seen with the primitive done (test bug: not mid-primitive) %t",
                  rt_pname(prim), $time);
         error = error + 1;
      end
      if (((kind == 0) || (kind == 4) || ((kind == 5) && (GPU_RUNAHEAD_EN == 0))) ? (rt_cls != 2) : (rt_cls != 1)) begin
         $display("ERROR: GPU %0s, %0s after %0d writes: class %0d (%0d of %0d pixels), expected %0s %t",
                  rt_pname(prim), rt_kname(kind), rt_trg, rt_cls, rt_nd, gpu_rec_n,
                  ((kind == 0) || (kind == 4) || ((kind == 5) && (GPU_RUNAHEAD_EN == 0))) ? "the whole walk" : "a strict prefix",
                  $time);
         error = error + 1;
      end else
         $display("--- %0s mid-%0s (%0s mode, %0d bpp): %0d of %0d pixels, then every setting kept", rt_kname(kind),
                  rt_pname(prim), rt_xy ? "x/y" : "address", 1 << rt_bl, rt_nd, gpu_rec_n);
      if (((kind == 0) || (kind == 4)) && !rt_v[4]) begin
         $display("ERROR: GPU %0s completed under %0s without GPU_DONE %t", rt_pname(prim), rt_kname(kind), $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | GS_BUSY | GS_ERR);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("flushed primitive");
      rt_draw;
      gpu_wait_idle;
      rt_no_err("after the mid-primitive flush");
      gpu_check_touched("mid-primitive flush: settings kept");
      end
   end
endtask


initial
   begin
      $display(" ===============================================");
      $display("|  GPU: settings kept through the flushes       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;                   // reserved / ignored command bits set at random
      gpu_rsv_seed = `SEED ^ 32'h5EED_0BAD;
      gpu_flush_resend = 1'b0;                 // nothing re-sent after a flush
      gpu_push_wait    = 1'b1;                 // FREE checked before each push (any FIFO depth)
      gpu_preload_rand(0, VRAM_WORDS);
      for (rt_i = RT_LST_W; rt_i < RT_LST_W + 200; rt_i = rt_i + 1) begin   // stale list words draw
         vram_mem[rt_i] = gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000);
      end
      gpu_model_init;
      gpu_set_dispw(RT_DISPW);
      reg_rd_val(BLNS_CFG2, rt_caps);
      rt_caps = (rt_caps >> 8) & 32'h3;                          // [0] REMAP, [1] MPLANE
      rt_stray = gpu_exec_word(GPU_FILL, 4'd2, 3'b000, 3'b000);  // decoded as a command: NOT D

      // 1. every setting through every flush
      rt_r = 0;
      for (rt_kind = 0; rt_kind < 6; rt_kind = rt_kind + 1)
         if (rt_kind != 3)
            for (rt_k = 0; rt_k < 4; rt_k = rt_k + 1) begin
               rt_xy   = (GPU_XY_EN != 0) && !rt_k[0];
               rt_fmt  = rt_k[1];
               rt_mode = rt_rnd(2) ? 4 : 3;
               rt_round(rt_kind);
               rt_r = rt_r + 1;
            end
      gpu_check_all("settings through the flushes");

      // 2. cut commands
      for (rt_cut = 0; rt_cut < 11; rt_cut = rt_cut + 1)
         if (!((rt_cut == 1) && (GPU_IMM_EN == 0)) && !(((rt_cut == 3) || (rt_cut == 4) || (rt_cut >= 7)) && (GPU_XY_EN == 0)) &&
             !((rt_cut == 5) && !rt_caps[1]))
            for (rt_scn = 0; rt_scn < 4; rt_scn = rt_scn + 1)
               rt_cut_case(rt_cut, rt_scn);

      // 3. RESET_STATE
      rt_reset_values;
      rt_reset_kept;

      // 4. the immediate source disarmed
      if (GPU_IMM_EN != 0)
         for (rt_kind = 0; rt_kind < 6; rt_kind = rt_kind + 1)
            if (rt_kind != 3) rt_imm_disarm(rt_kind);

      // 5. flushed fences
      for (rt_kind = 0; rt_kind < 3; rt_kind = rt_kind + 1)
         rt_fence_flushed(rt_kind);

      // 6. a flush in the middle of each primitive kind
      for (rt_kind = 0; rt_kind < 6; rt_kind = rt_kind + 1)
         for (rt_prim = 0; rt_prim < 7; rt_prim = rt_prim + 1)
            if (!((rt_prim >= 4) && (GPU_XY_EN == 0)) && !((rt_prim >= 5) && (GPU_TRI_EN == 0))) begin
               rt_retry = 1'b1;
               for (rt_try = 0; (rt_try < 32) && rt_retry; rt_try = rt_try + 1)   // a small one is cheap
                  rt_mid(rt_kind, rt_prim);
               if (rt_retry) tb_error("gpu_retain: no primitive large enough for a flush in its middle (test bug)");
            end

      gpu_check_all("gpu_retain end");
      $display("INFO:  %0d settings rounds", rt_r);
      $display("INFO:  %0d command words pushed with reserved bits set", gpu_rsv_n);
      if (gpu_rsv_n == 0) tb_error("no reserved bit was ever set (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
