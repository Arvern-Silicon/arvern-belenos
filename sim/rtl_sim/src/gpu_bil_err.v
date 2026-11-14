//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_bil_err
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_bil_err.v
// Module Description : Bilinear errors and the TEX_FILTER setting (16 bpp,
//                      GPU_BILINEAR_EN and GPU_XY_EN; the SET_AUX causes of
//                      every build are in gpu_a8_err):
//                      - a tap's colour word past VRAM_WORDS (a free-pitch
//                        texture without BOUND whose right taps read past
//                        the end, also one past the pixel-address range),
//                        a destination past 2^VRAM_AW words (nothing written),
//                        and with RGB565A8 a tap's A8 word past it:
//                        ERR_CAUSE 5, GPU_ERR the EXEC, no GPU_DONE; the
//                        pixels before the faulting one drawn, it and the
//                        rest not;
//                      - BILINEAR / TBORDER kept through CLEAR_ERR, ABORT,
//                        GPU_EN = 0 and both bits; RESET_STATE: nearest,
//                        clamp;
//                      - a TEX_FILTER cut between its word and its operand
//                        by CLEAR_ERR or ABORT keeps what its word set (the
//                        operand, pushed after, discarded);
//                      - a TEX_FILTER pushed while the blit before it draws
//                        (decoded during the draw with run-ahead): the
//                        running blit keeps its filter, the next takes the
//                        new one.
//                      Each blit against gpu_model.v (the image of the
//                      touched words).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer BR_TLO  = 4096;
localparam integer BR_ALO  = 8192;
localparam integer BR_DLO  = 10240;
localparam  [31:0] BR_REC  = 32'hFE40_0000;

integer    br_i, br_k, br_n, br_w;
reg        br_bl;
reg        br_top = 1'b0;               // br_past: the texture at the top of the pixel-address range
reg [31:0] br_st, br_flag, br_xw;

function integer br_rnd;
   input integer n;
   begin
      br_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task br_fill;                            // a recovery fill against the model
   begin
      gpu_c_dst(16'd64, 2 * BR_DLO + 2 * ($random(gpu_seed) & 255));
      gpu_c_size(14'd3, 14'd2);
      gpu_c_fill($random(gpu_seed));
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("recovery fill");
   end
endtask

task br_expect;                          // stopped with this record; CLEAR_ERR; a fill runs
   input  [3:0] op;
   input  [2:0] cause;
   input [31:0] word;
   input [8*48-1:0] label;
   integer      guard;
   begin
      guard = 0;
      br_st = 32'h0;
      while (!(br_st & GS_ERR) && (guard < 400)) begin
         reg_rd_val(GPU_STAT, br_st);
         guard = guard + 1;
      end
      reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 4000);
      reg_rd_val(GPU_STAT, br_st);
      reg_rd_val(IRQ_FLAG, br_flag);
      if (((br_st & BR_REC) !== ({op, cause, 25'h0} | GS_ERR)) || !(br_flag & IF_ERR) || (br_flag & IF_DONE)) begin
         $display("ERROR: %0s -- GPU_STAT 0x%h, IRQ_FLAG 0x%h / expected ERR_OPCODE %h, ERR_CAUSE %0d, no GPU_DONE %t",
                  label, br_st, br_flag, op, cause, $time);
         error = error + 1;
      end else
         $display("OK:    %0s: ERR_OPCODE %h, ERR_CAUSE %0d", label, op, cause);
      reg_rd(GPU_ERR, word);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_flush_hint = 1'b0;
      repeat(4) @(posedge free_clk);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      br_fill;
   end
endtask

// A bilinear-able TEXRECT with the settings the GPU holds (no TEX_FILTER sent)
task br_blit;
   input [8*40-1:0] label;
   begin
      gpu_k_a8 = 1'b0;
      gpu_c_src(16'd0, 2 * BR_TLO + 64 + br_rnd(64));
      gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b1, 8'h00);
      gpu_c_texbox(5 + br_rnd(8), 5 + br_rnd(8));
      gpu_c_uv(br_rnd(256) - 16'd64, br_rnd(256) - 16'd64);
      gpu_c_step(16'd1500 + br_rnd(600), 16'd500);
      gpu_c_step_row(-16'sd500, 16'd1500 + br_rnd(600));
      gpu_c_size(14'd12, 14'd8);
      gpu_c_dst(16'd64, 2 * BR_DLO + 2 * 64 * 8 + 2 * br_rnd(512) + br_rnd(2));
      gpu_c_texrect(0);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched(label);
   end
endtask

// A span of n pixels whose pixel k - 1 has a tap past the VRAM (a8: its A8 word)
task br_past;
   input        a8;
   input integer k;
   input integer n;
   reg   [31:0] tb;
   integer      ii;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_c_tex_filter(1'b1, 1'b0);
      // pixel i at u = i + 3/4: taps x = i, i + 1 (fx = 8), v on a texel centre (one row)
      tb = br_top ? (GPU_PA_MASK + 1 - k) : a8 ? (2 * BR_TLO + 64) : (2 * VRAM_WORDS - k);
      gpu_k_a8 = a8;
      gpu_c_src(16'd1000, tb);
      if (a8) begin
         gpu_c_alpha_plane(4 * VRAM_WORDS - k);
         for (ii = 0; ii < k; ii = ii + 1) begin               // nonzero alphas before the fault
            vram_mem[(4 * VRAM_WORDS - k + ii) >> 2]   = vram_mem[(4 * VRAM_WORDS - k + ii) >> 2] |
                                                          (32'h80 << (8 * ((4 * VRAM_WORDS - k + ii) & 3)));
            gpu_shadow[(4 * VRAM_WORDS - k + ii) >> 2] = vram_mem[(4 * VRAM_WORDS - k + ii) >> 2];
         end
         gpu_c_alpha5(1'b0, 8'd0, br_rnd(2));
      end
      gpu_c_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, 1'b0, 8'h00);   // free pitch, no BOUND
      gpu_c_uv(16'd48, 16'd32);
      gpu_c_step(16'd2048, 16'd0);
      gpu_c_dst(16'd64, 2 * BR_DLO + 2 * br_rnd(256));
      gpu_oob_ok   = 1'b1;
      gpu_oob_stop = 1'b1;
      gpu_oob_hit  = 1'b0;
      gpu_wait_idle;
      gpu_c_texspan(0, n);
      gpu_k_a8 = 1'b0;
      if (!gpu_oob_hit) tb_error("gpu_bil_err: no tap reaches VRAM_WORDS (test bug)");
      gpu_oob_ok   = 1'b0;
      gpu_oob_stop = 1'b0;
      br_expect(OP_EXEC_TEX, 3'd5, {OP_EXEC_TEX, 14'd0, n[13:0]},
                a8 ? "bilinear A8 tap past the VRAM" : "bilinear tap past the VRAM");
   end
endtask

// A bilinear span whose destination is 2^VRAM_AW + 50 words (raw SET_DST
// and EXEC: the model rejects such an address): cause 5, nothing written
// (word 50 unchanged); the destination word's "past 2^VRAM_AW" bit in L
task br_dst_past;
   reg [31:0] w50;
   begin
      gpu_wait_idle;
      w50 = vram_mem[50];
      gpu_c_tex_filter(1'b1, 1'b0);
      gpu_k_a8 = 1'b0;
      gpu_c_src(16'd64, 2 * BR_TLO + 64);
      gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_c_uv(16'd40, 16'd40);
      gpu_c_step(16'd1500, 16'd700);
      gpu_wait_idle;
      gpu_push({OP_SET_DST, 12'h000, 16'd0});
      gpu_push(((1 << VRAM_AW) + 50) * 2);
      gpu_push({OP_EXEC_TEX, 14'd0, 14'd6});
      reg_poll(GPU_STAT, GS_ERR, GS_ERR, 200);
      reg_rd_mask(GPU_STAT, {OP_EXEC_TEX, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
      repeat(20) @(posedge free_clk);
      tb_checks = tb_checks + 1;
      if (vram_mem[50] !== w50) tb_error("bilinear span past 2^VRAM_AW: word 50 written");
      reg_wr(GPU_CTRL, 32'h1);                             // CLEAR_ERR
      gpu_c_tex_filter(1'b0, 1'b0);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   GPU: bilinear errors and TEX_FILTER state   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BILINEAR_EN == 0) || (GPU_XY_EN == 0))
         tb_skip_finish("|   (GPU_BILINEAR_EN / GPU_XY_EN = 0: absent)   |");
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;
      br_bl = (GPU_BLEND_EN != 0);
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);

      //--------------------------------------------------------------
      $display("--- 1. a tap past VRAM_WORDS: cause 5, the pixels before drawn");
      for (br_i = 0; br_i < 4; br_i = br_i + 1) br_past(1'b0, 2 + br_rnd(8), 12);
      if (br_bl)
         for (br_i = 0; br_i < 4; br_i = br_i + 1) br_past(1'b1, 2 + br_rnd(8), 12);
      // the first pixel's right tap one past the pixel-address range (its
      // carry out of the tap offset adder): cause 5, nothing drawn
      br_top = 1'b1;
      br_past(1'b0, 1, 12);
      br_top = 1'b0;
      br_dst_past;

      //--------------------------------------------------------------
      $display("--- 2. the filter kept through the flushes; RESET_STATE: nearest");
      for (br_k = 0; br_k < 4; br_k = br_k + 1) begin
         gpu_c_tex_filter(1'b1, br_bl && br_k[0]);
         gpu_wait_idle;
         gpu_flush(br_k);
         br_blit((br_k == 0) ? "filter after CLEAR_ERR" : (br_k == 1) ? "filter after ABORT" :
                 (br_k == 2) ? "filter after GPU_EN = 0" : "filter after CLEAR_ERR + ABORT");
      end
      gpu_c_reset_state;
      gpu_set_dispw(64);
      br_blit("after RESET_STATE: nearest");

      //--------------------------------------------------------------
      $display("--- 3. a TEX_FILTER cut by a flush keeps its word's effect");
      for (br_k = 0; br_k < 4; br_k = br_k + 1) begin
         gpu_wait_idle;
         gpu_push({OP_SET_EXT, EXT_SET_AUX, 4'd5, 18'h00000, br_bl && br_k[1], ~br_k[0]});
         gpu_m_bil   = ~br_k[0];
         gpu_m_tbord = br_bl && br_k[1];
         repeat(10) @(posedge free_clk);
         reg_wr(GPU_CTRL, br_k[1] ? 32'h2 : 32'h1);
         gpu_push(32'h0000_0003);                              // the operand: discarded
         br_blit("after a cut TEX_FILTER");
      end

      //--------------------------------------------------------------
      $display("--- 4. TEX_FILTER while the blit before it draws: old filter for it, new for the next");
      for (br_k = 0; br_k < 4; br_k = br_k + 1) begin
         gpu_c_tex_filter(br_k[0], 1'b0);
         gpu_k_a8 = 1'b0;
         gpu_c_src(16'd0, 2 * BR_TLO + 64);
         gpu_c_tex(4'd5, 4'd5, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
         gpu_c_uv(br_rnd(1024), br_rnd(1024));
         gpu_c_step(16'd1700, 16'd300);
         gpu_c_step_row(-16'sd300, 16'd1700);
         br_w = (GPU_DIM_MASK >= 60) ? 60 : GPU_DIM_MASK;
         gpu_c_size(br_w, 14'd8);
         gpu_c_dst(16'd64, 2 * BR_DLO + 2 * 64 * 8);
         gpu_wait_idle;
         gpu_c_texrect(0);                                        // A
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         gpu_c_tex_filter(~br_k[0], br_bl && br_k[1]);           // while A draws
         gpu_c_dst(16'd64, 2 * BR_DLO + 2 * 64 * 24);
         gpu_c_texrect(0);                                        // B
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("TEX_FILTER during a blit");
      end

      gpu_c_tex_filter(1'b0, 1'b0);
      gpu_check_all("gpu_bil_err end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
