//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_nofx_err
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_nofx_err.v
// Module Description : Commands of an absent GPU option are refused: without
//                      GPU_XY_EN, SET_DST [16] XY, SET_XY, SET_CLIP and the
//                      affine blit: EXEC_TEXRECT, SET_STEP_ROW, SET_TEXBOX,
//                      SET_TEX [13] BOUND; without GPU_GRAD_EN, SET_GRAD;
//                      without GPU_BLEND_EN, SET_ALPHA (SET_EXT sub 8),
//                      EXEC_EXPAND [3] MASK, an anti-aliased line, SET_SRC
//                      SRC_FMT 5 (RGB565A8) and SET_AUX SEL 4 ALPHA_PLANE;
//                      without bilinear (GPU_BILINEAR_EN, or no GPU_XY_EN),
//                      SET_AUX SEL 5 TEX_FILTER, and with it but without
//                      GPU_BLEND_EN a TEX_FILTER with [1] TBORDER;
//                      without triangles (GPU_TRI_EN, or no GPU_XY_EN),
//                      SET_V0..V2 (subs 9-11) and EXEC_FILL with [7] TRI;
//                      without GPU_REMAP_EN, SET_AUX REMAP_TABLE and a REMAP
//                      field of 1 or 2 (EXEC_FILL, EXEC_COPY, SET_TEX);
//                      without GPU_MPLANE_EN, SET_AUX MASK_PLANE and
//                      EXEC_COPY / COPY_TRANSP with [11] MPLANE; without
//                      lines (GPU_LINE_EN, or no GPU_XY_EN), EXEC_FILL [24]
//                      LINE and SET_AUX SEL 2 / 3 (none takes its operand:
//                      the word pushed behind it is a command).
//                      Each sets ERR with ERR_OPCODE = its opcode and
//                      ERR_CAUSE 2 (absent feature), stays at the FIFO head,
//                      the EXEC queued behind it never runs; CLEAR_ERR
//                      flushes, the record is kept and the decoder resumes.
//                      Then an undefined code (SET_EXT sub 14) overwrites the
//                      record with ERR_CAUSE 1 (invalid).
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tn_i, tn_n;
reg [31:0] tn_word [0:31];
reg [31:0] tn_exp;
reg [31:0] tn_cause;
reg  [3:0] tn_sub;

initial
   begin
      $display(" ===============================================");
      $display("|    GPU: commands of absent options invalid    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN != 0) && (GPU_GRAD_EN != 0) &&
          (GPU_BLEND_EN != 0) && (GPU_TRI_EN != 0) &&
          (GPU_REMAP_EN != 0) && (GPU_MPLANE_EN != 0) && (GPU_LINE_EN != 0) && (GPU_BILINEAR_EN != 0))
         tb_skip_finish("|          (every GPU option present)           |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, 4096);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      gpu_c_dst(16'd64, 32'd1000);
      gpu_c_size(14'd3, 14'd2);
      gpu_c_fill(32'h0000_ABCD);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      tn_n = 0;
      if (GPU_XY_EN == 0) begin
         tn_word[tn_n] = {OP_SET_DST, 11'h000, 1'b1, 16'd64};
         tn_word[tn_n + 1] = {OP_SET_EXT, 4'd3, 24'h001002};
         tn_word[tn_n + 2] = {OP_SET_EXT, 4'd4, 24'h000000};
         tn_n = tn_n + 3;
      end
      if (GPU_XY_EN == 0) begin                                    // affine blit
         tn_word[tn_n] = {OP_EXEC_TEXRECT, 28'h0};
         tn_word[tn_n + 1] = {OP_SET_EXT, 4'd5, 24'h0};
         tn_word[tn_n + 2] = {OP_SET_EXT, 4'd6, 24'h008008};
         tn_word[tn_n + 3] = {OP_SET_EXT, 4'd0, 10'h000, 1'b1, 13'h0033};
         tn_n = tn_n + 4;
      end
      if (GPU_GRAD_EN == 0) begin
         tn_word[tn_n] = {OP_SET_EXT, 4'd7, 6'h00, 1'b1, 4'd1, 1'b0, 12'd2};
         tn_n = tn_n + 1;
      end
      if (GPU_BLEND_EN == 0) begin
         tn_word[tn_n]     = {OP_SET_EXT, 4'd8, 24'h0000_FF};
         tn_word[tn_n + 1] = {OP_EXEC_EXP, 20'h00000, 8'h08};               // MASK
         tn_word[tn_n + 2] = {OP_SET_SRC, 8'h00, 4'd5, 16'd64};               // RGB565A8
         tn_word[tn_n + 3] = {OP_SET_EXT, EXT_SET_AUX, 4'd4, 20'h00000};    // ALPHA_PLANE
         tn_n = tn_n + 4;
         if ((GPU_LINE_EN != 0) && (GPU_XY_EN != 0)) begin
            tn_word[tn_n] = {OP_EXEC_FILL, 28'h101_0000};                   // an AA line
            tn_n = tn_n + 1;
         end
      end
      if ((GPU_LINE_EN == 0) || (GPU_XY_EN == 0)) begin
         tn_word[tn_n]     = {OP_EXEC_FILL, 28'h100_0000};                  // LINE (its operand: the EXEC behind)
         tn_word[tn_n + 1] = {OP_SET_EXT, EXT_SET_AUX, 4'd2, 20'h00000};    // LINE_PEN
         tn_word[tn_n + 2] = {OP_SET_EXT, EXT_SET_AUX, 4'd3, 20'h0001F};    // LINE_PATTERN
         tn_n = tn_n + 3;
      end
      if ((GPU_BILINEAR_EN == 0) || (GPU_XY_EN == 0)) begin
         tn_word[tn_n] = {OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00001};        // TEX_FILTER
         tn_n = tn_n + 1;
      end else if (GPU_BLEND_EN == 0) begin
         tn_word[tn_n] = {OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00003};        // TEX_FILTER TBORDER
         tn_n = tn_n + 1;
      end
      if ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0)) begin
         for (tn_sub = 4'd9; tn_sub <= 4'd11; tn_sub = tn_sub + 4'd1) begin
            tn_word[tn_n] = {OP_SET_EXT, tn_sub, 24'h0};
            tn_n = tn_n + 1;
         end
         tn_word[tn_n] = gpu_exec_word(OP_EXEC_FILL, 4'd12, 3'b000, 3'b000) | 32'h80;
         tn_n = tn_n + 1;
      end
      if (GPU_REMAP_EN == 0) begin
         tn_word[tn_n]     = {OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h00000};    // (its operand: the EXEC behind)
         tn_word[tn_n + 1] = gpu_exec_word(OP_EXEC_FILL, 4'd0, 3'b000, 3'b000) | 32'h1000;
         tn_word[tn_n + 2] = gpu_exec_word(OP_EXEC_COPY, 4'd0, 3'b000, 3'b000) | 32'h2000;
         tn_word[tn_n + 3] = {OP_SET_EXT, EXT_SET_TEX, 8'h00, 2'd1, 14'h0033};
         tn_n = tn_n + 4;
      end
      if (GPU_MPLANE_EN == 0) begin
         tn_word[tn_n]     = {OP_SET_EXT, EXT_SET_AUX, 4'd1, 20'h00000};
         tn_word[tn_n + 1] = gpu_exec_word(OP_EXEC_COPY, 4'd0, 3'b000, 3'b000) | 32'h800;
         tn_word[tn_n + 2] = gpu_exec_word(OP_EXEC_COPYT, 4'd0, 3'b000, 3'b000) | 32'h800;
         tn_n = tn_n + 3;
      end

      // Last: an undefined code (SET_EXT sub 14), cause 1, after the cause 2 words
      tn_word[tn_n] = {OP_SET_EXT, 4'd14, 24'h000000};
      tn_n = tn_n + 1;

      for (tn_i = 0; tn_i < tn_n; tn_i = tn_i + 1) begin
         tn_cause = (tn_i == tn_n - 1) ? 32'd1 : 32'd2;
         $display("--- word 0x%h: ERR_CAUSE %0d", tn_word[tn_i], tn_cause);
         gpu_src_fmt((tn_word[tn_i][31:28] == OP_EXEC_EXP) ? 4'h1 : 4'h0);   // EXPAND: a 1-bpp source (no cause 3)
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push(tn_word[tn_i]);
         gpu_push(gpu_exec_word(OP_EXEC_FILL, 4'd14, 3'b000, 3'b000));     // never runs
         repeat(20) @(posedge free_clk);
         tn_exp = (tn_word[tn_i][31:28] << 28) | (tn_cause << 25) | GS_ERR | GS_BUSY | (2 << 8) |
                  (GPU_FIFO_DEPTH - 2) | ((GPU_FIFO_DEPTH == 2) ? GS_FULL : 32'h0);
         reg_rd_mask(GPU_STAT, tn_exp, 32'hFFFF_FFFF);                     // ERR_CAUSE included
         reg_rd_mask(IRQ_FLAG, IF_ERR, IF_GPU_ALL);
         reg_wr(GPU_CTRL, 32'h1);                                           // CLEAR_ERR
         repeat(4) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, (tn_word[tn_i][31:28] << 28) | (tn_cause << 25) | GS_EMPTY | GPU_FIFO_DEPTH,
                     32'hFFFF_FFFF);                                        // record kept
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_c_fill($random(gpu_seed));
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_check_touched("after error exit");
      end

      gpu_check_all("nofx end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
