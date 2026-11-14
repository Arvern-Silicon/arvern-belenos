//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_api
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_api.v
// Module Description : Error record and VRAM bounds. Every ERR_CAUSE with its
//                      ERR_OPCODE and GPU_ERR word: 1 invalid (opcode 0,
//                      SET_EXT sub 14, SET_AUX with a reserved selector,
//                      REMAP 3, SET_EXT2 code 0x12), 2 absent (SET_SRC IMM without GPU_IMM_EN,
//                      the commands of an absent option, SET_AUX MASK_PLANE
//                      with a PITCH), 3 format (SET_SRC
//                      SRC_FMT 6-15 (5 without blending: 2), SET_DST DST_FMT 1-7, EXPAND with SRC_FMT
//                      0, COPY / TEXSPAN with SRC_FMT 1-4), 4 list cut, 5 a
//                      rectangle reaching VRAM_WORDS (write and read side:
//                      the pixels before it drawn, no access at or past it,
//                      the rectangle abandoned), 6 a CALL whose list does not
//                      fit (nothing of it runs). After each, CLEAR_ERR and a
//                      fill that must run; GPU_ERR keeps the word until that
//                      fill's EXEC. A rectangle running past the VRAM while
//                      the decoder stops on a later invalid word reports cause
//                      5 (program order); ABORT, then CLEAR_ERR, swept across
//                      the cycle of a bound fault: either the fault's record
//                      (cause 5) with its interrupt, or no record (the one
//                      before kept) and no interrupt; ERR only with the record
//                      (ABORT: exactly with it). With run-ahead, a CALL that
//                      does not fit decoded in the cycle of a rectangle's bound
//                      fault: cause 5 with the rectangle's opcode and word.
//                      A FILL walking left from the word at VRAM_WORDS draws
//                      nothing (its first access faults). A texel address past
//                      the pixel-address range faults (no wrap).
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    ta_vw, ta_d, ta_k, ta_hit, ta_miss, ta_f, ta_coin;
reg [31:0] ta_w, ta_flag, ta_stat;

`define TA_DEC dut.u_core.G_GPU.u_gpu.u_dec
initial ta_coin = 0;
always @(posedge free_clk)
   if (`TA_DEC.call_bad & `TA_DEC.bound_evt) ta_coin = ta_coin + 1;

// The GPU must be in ERR with this record; then CLEAR_ERR, and a 2-pixel fill
// at VRAM word 100 must run
task ta_expect;
   input  [3:0] op;
   input  [2:0] cause;
   input        chk_word;
   input [31:0] word;
   reg   [31:0] c;
   begin
      repeat(30) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_ERR, 32'hFE40_0000);
      if (chk_word) reg_rd(GPU_ERR, word);
      reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR);
      reg_rd_mask(STATUS, 32'h4, 32'h4);
      reg_wr(GPU_CTRL, 32'h1);                                   // CLEAR_ERR
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_EMPTY, 32'hFE7F_0000);  // record kept
      if (chk_word) reg_rd(GPU_ERR, word);                       // until the next EXEC
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      c = $random(gpu_seed);
      gpu_push({OP_SET_DST, 12'h000, 16'd0});
      gpu_push(32'd200);                                         // pixel 200 = word 100 (16 bpp)
      gpu_push({OP_SET_SIZE, 14'd1, 14'd2});
      gpu_push({OP_SET_FILL, 28'h0});
      gpu_push({16'h0000, c[15:0]});
      gpu_push({OP_EXEC_FILL, 28'h0});
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_rd(GPU_ERR, {OP_EXEC_FILL, 28'h0});                    // the last EXEC
      if (vram_mem[100] !== {c[15:0], c[15:0]}) begin
         $display("ERROR: no recovery after ERR_CAUSE %0d: word 100 = 0x%h / expected 0x%h %t",
                  cause, vram_mem[100], {c[15:0], c[15:0]}, $time);
         error = error + 1;
      end
      gpu_shadow[100] = vram_mem[100];
   end
endtask

// One word that is refused at once, followed by its operand when its opcode
// takes one (as software pushes it: flushed with the queue by CLEAR_ERR)
task ta_word;
   input [31:0] w;
   input  [2:0] cause;
   begin
      $display("--- 0x%h: ERR_CAUSE %0d", w, cause);
      gpu_push(w);
      if ((w[31:28] == OP_SET_SRC) || (w[31:28] == OP_SET_DST) || (w[31:28] == OP_SET_FILL) ||
          (w[31:28] == OP_SET_TRANSP) || (w[31:28] == OP_CALL) ||
          ((w[31:28] == OP_SET_EXT) && ((w[27:24] == 4'd1) || (w[27:24] == 4'd2) || (w[27:24] == 4'd4) ||
                                        (w[27:24] == 4'd5) || (w[27:24] == 4'd9) || (w[27:24] == 4'd10) ||
                                        (w[27:24] == 4'd11) || (w[27:24] == 4'd12) || (w[27:24] == 4'd13))))
         gpu_push(32'h0000_0000);
      ta_expect(w[31:28], cause, 1'b1, w);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     GPU: error record and VRAM bounds         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 300)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      ta_vw    = VRAM_WORDS;
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_rd(GPU_ERR, 32'h0);
      reg_rd_mask(GPU_STAT, 32'h0, 32'hFE40_0000);

      //--------------------------------------------------------------
      // 1 invalid
      ta_word(32'h0000_0000, 3'd1);
      ta_word({OP_SET_EXT, 4'd14, 24'h00_0000}, 3'd1);
      ta_word({OP_SET_EXT, 4'd13, 24'h60_0000}, 3'd1);            // SET_AUX: reserved selectors (6-15)
      ta_word({OP_SET_EXT, 4'd13, 24'hF0_0000}, 3'd1);
      ta_word({OP_EXEC_COPY, 28'h000_3000}, 3'd1);                // REMAP 3: reserved
      ta_word({OP_SET_EXT, 4'd0, 8'h00, 2'd3, 14'h0000}, 3'd1);   // SET_TEX REMAP 3
      ta_word({OP_SET_EXT, 4'd15, 24'h12_3456}, 3'd1);           // SET_EXT2: no code yet
      // 2 absent
      if (GPU_IMM_EN == 0) ta_word({OP_SET_SRC, 7'h00, 1'b1, 4'h0, 16'd0}, 3'd2);   // IMM (gpu_imm when built)
      if (GPU_BLEND_EN == 0) ta_word({OP_SET_EXT, 4'd8, 24'h0000_FF}, 3'd2);
      if (GPU_BLEND_EN == 0) begin                                      // EXPAND MASK (SRC_FMT 1: no cause 3)
         gpu_src_fmt(4'h1);
         ta_word({OP_EXEC_EXP, 28'h000_0008}, 3'd2);
         gpu_src_fmt(4'h0);
      end
      if ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0)) ta_word({OP_SET_EXT, 4'd9, 24'h0}, 3'd2);
      if (GPU_XY_EN == 0) ta_word({OP_SET_DST, 11'h000, 1'b1, 16'd0}, 3'd2);
      if (GPU_XY_EN == 0) ta_word({OP_EXEC_TEXRECT, 28'h0}, 3'd2);       // affine blit
      if (GPU_GRAD_EN == 0) ta_word({OP_SET_EXT, 4'd7, 24'h0}, 3'd2);
      if (GPU_GRAD_EN == 0) ta_word({OP_SET_EXT, 4'd12, 24'h0}, 3'd2);   // SET_GRAD_RGB
      ta_word({OP_SET_EXT, 4'd13, 4'd1, 4'h0, 16'd1}, 3'd2);              // MASK_PLANE PITCH: not built
      if (GPU_REMAP_EN == 0) ta_word({OP_SET_EXT, 4'd13, 24'h00_0000}, 3'd2);
      if (GPU_REMAP_EN == 0) ta_word({OP_EXEC_FILL, 28'h000_1000}, 3'd2);
      if (GPU_MPLANE_EN == 0) ta_word({OP_SET_EXT, 4'd13, 24'h10_0000}, 3'd2);
      if (GPU_MPLANE_EN == 0) ta_word({OP_EXEC_COPY, 28'h000_0800}, 3'd2);
      // 3 format: on the SET word
      ta_word({OP_SET_SRC, 8'h00, 4'd6, 16'd0}, 3'd3);
      if (GPU_BLEND_EN == 0) ta_word({OP_SET_SRC, 8'h00, 4'd5, 16'd0}, 3'd2);   // RGB565A8: absent without blending
      ta_word({OP_SET_SRC, 8'h00, 4'd7, 16'd0}, 3'd3);
      ta_word({OP_SET_SRC, 8'h00, 4'd15, 16'd0}, 3'd3);
      ta_word({OP_SET_DST, 8'h00, 3'd1, 1'b0, 16'd0}, 3'd3);
      ta_word({OP_SET_DST, 8'h00, 3'd7, 1'b0, 16'd0}, 3'd3);
      // 3 format: on the EXEC, the source format set before
      $display("--- EXPAND with SRC_FMT 0, COPY / TEXSPAN with SRC_FMT 1-4: ERR_CAUSE 3");
      gpu_push({OP_SET_SRC, 8'h00, 4'd0, 16'd0});
      gpu_push(32'd400);
      ta_w = {OP_EXEC_EXP, 14'd0, 7'h00, 3'b000, 1'b0, 1'b0, 2'b00};
      gpu_push(ta_w);
      ta_expect(OP_EXEC_EXP, 3'd3, 1'b1, ta_w);
      gpu_push({OP_SET_SRC, 8'h00, 4'd2, 16'd0});
      gpu_push(32'd400);
      ta_w = gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_push(ta_w);
      ta_expect(ta_w[31:28], 3'd3, 1'b1, ta_w);
      gpu_push({OP_SET_SRC, 8'h00, 4'd4, 16'd0});
      gpu_push(32'd400);
      ta_w = {OP_EXEC_TEX, 14'd0, 14'd4};
      gpu_push(ta_w);
      ta_expect(OP_EXEC_TEX, 3'd3, 1'b1, ta_w);
      gpu_push({OP_SET_SRC, 8'h00, 4'd0, 16'd0});                 // back to the destination format
      gpu_push(32'd400);
      gpu_m_src_fmt = 4'h0;

      // 4 list cut: a 1-word list holding a command that needs an operand
      $display("--- list ending between a command and its operand: ERR_CAUSE 4");
      vram_mem[120]   = {OP_SET_FILL, 28'h0};
      gpu_shadow[120] = vram_mem[120];
      gpu_push({OP_CALL, 4'h0, 24'd1});
      gpu_push(32'd120);
      ta_expect(OP_CALL, 3'd4, 1'b1, {OP_SET_FILL, 28'h0});

      //--------------------------------------------------------------
      // 5 / 6: VRAM bounds (only past a non-power-of-two VRAM_WORDS)
      if (ta_vw < (1 << VRAM_AW)) begin
         $display("--- FILL across VRAM_WORDS (%0d): the pixels before it, then ERR_CAUSE 5", ta_vw);
         vram_mem[ta_vw - 3] = 32'h1111_1111;  gpu_shadow[ta_vw - 3] = 32'h1111_1111;
         vram_mem[ta_vw - 2] = 32'h2222_2222;  gpu_shadow[ta_vw - 2] = 32'h2222_2222;
         vram_mem[ta_vw - 1] = 32'h3333_3333;  gpu_shadow[ta_vw - 1] = 32'h3333_3333;
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(2 * (ta_vw - 2));
         gpu_push({OP_SET_SIZE, 14'd1, 14'd8});
         gpu_push({OP_SET_FILL, 28'h0});
         gpu_push(32'h0000_5A5A);
         ta_w = {OP_EXEC_FILL, 28'h0};
         gpu_push(ta_w);
         repeat(30) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, 32'h0, GS_PRIM_BUSY);               // abandoned
         if ((vram_mem[ta_vw - 2] !== 32'h5A5A_5A5A) || (vram_mem[ta_vw - 1] !== 32'h5A5A_5A5A) ||
             (vram_mem[ta_vw - 3] !== 32'h1111_1111)) begin
            $display("ERROR: FILL across VRAM_WORDS: words 0x%h 0x%h 0x%h / expected 11111111 5a5a5a5a 5a5a5a5a %t",
                     vram_mem[ta_vw - 3], vram_mem[ta_vw - 2], vram_mem[ta_vw - 1], $time);
            error = error + 1;
         end
         gpu_shadow[ta_vw - 2] = vram_mem[ta_vw - 2];
         gpu_shadow[ta_vw - 1] = vram_mem[ta_vw - 1];
         ta_expect(OP_EXEC_FILL, 3'd5, 1'b1, ta_w);

         $display("--- COPY reading across VRAM_WORDS: ERR_CAUSE 5 on the read");
         vram_mem[140] = 32'h0;  gpu_shadow[140] = 32'h0;
         vram_mem[141] = 32'h7777_7777;  gpu_shadow[141] = 32'h7777_7777;
         gpu_push({OP_SET_SRC, 12'h000, 16'd0});
         gpu_push(2 * (ta_vw - 1));
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(32'd280);                                      // word 140
         gpu_push({OP_SET_SIZE, 14'd1, 14'd4});
         ta_w = gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_push(ta_w);
         repeat(30) @(posedge free_clk);
         if ((vram_mem[140] !== vram_mem[ta_vw - 1]) || (vram_mem[141] !== 32'h7777_7777)) begin
            $display("ERROR: COPY across VRAM_WORDS: words 140/141 = 0x%h 0x%h / expected 0x%h 77777777 %t",
                     vram_mem[140], vram_mem[141], vram_mem[ta_vw - 1], $time);
            error = error + 1;
         end
         gpu_shadow[140] = vram_mem[140];
         ta_expect(ta_w[31:28], 3'd5, 1'b1, ta_w);

         $display("--- FILL running past VRAM_WORDS, an invalid word behind it: ERR_CAUSE 5");
         // 8 x 8 at the 32-word pitch: rows 0-6 inside, row 7 at VRAM_WORDS
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(2 * (ta_vw - 7 * 32));
         gpu_push({OP_SET_SIZE, 14'd8, 14'd8});
         gpu_push({OP_SET_FILL, 28'h0});
         gpu_push(32'h0000_6B6B);
         ta_w = {OP_EXEC_FILL, 28'h0};
         gpu_push(ta_w);
         gpu_push(32'h0000_0000);                                // invalid, decoded while it draws
         repeat(300) @(posedge free_clk);
         ta_expect(OP_EXEC_FILL, 3'd5, 1'b1, ta_w);
         for (ta_k = ta_vw - 7 * 32; ta_k < ta_vw; ta_k = ta_k + 1)
            gpu_shadow[ta_k] = vram_mem[ta_k];

         // Walking left from the word at VRAM_WORDS: the first access faults, so
         // nothing is drawn (the words merged after it belong to the rest)
         for (ta_k = 4; ta_k <= 8; ta_k = ta_k + 4) begin
            $display("--- FILL %0d x 1 walking left (X swap) from word VRAM_WORDS: ERR_CAUSE 5, nothing drawn", ta_k);
            for (ta_d = 1; ta_d <= 4; ta_d = ta_d + 1) begin
               vram_mem[ta_vw - ta_d]   = 32'hC0DE_0000 | ta_d;
               gpu_shadow[ta_vw - ta_d] = vram_mem[ta_vw - ta_d];
            end
            gpu_push({OP_SET_DST, 12'h000, 16'd0});
            gpu_push(2 * ta_vw + 1);
            gpu_push({OP_SET_SIZE, 14'd1, ta_k[13:0]});
            gpu_push({OP_SET_FILL, 28'h0});
            gpu_push(32'h0000_BEEF);
            ta_w = gpu_exec_word(GPU_FILL, 4'd0, 3'b100, 3'b000);
            gpu_push(ta_w);
            repeat(30) @(posedge free_clk);
            for (ta_d = 1; ta_d <= 4; ta_d = ta_d + 1)
               if (vram_mem[ta_vw - ta_d] !== (32'hC0DE_0000 | ta_d)) begin
                  $display("ERROR: FILL walking left from VRAM_WORDS: word VRAM_WORDS-%0d = 0x%h, written after the faulting access %t",
                           ta_d, vram_mem[ta_vw - ta_d], $time);
                  error = error + 1;
               end
            ta_expect(ta_w[31:28], 3'd5, 1'b1, ta_w);
         end

         // A texel address past the pixel-address range (free pitch, base at the
         // top): cause 5, not a wrap onto the start of the VRAM
         $display("--- EXEC_TEXSPAN with a texel address past 2^PA_W: ERR_CAUSE 5, nothing drawn");
         vram_mem[500] = 32'h7E57_0500;  gpu_shadow[500] = vram_mem[500];
         vram_mem[501] = 32'h7E57_0501;  gpu_shadow[501] = vram_mem[501];
         gpu_push({OP_SET_SRC, 8'h00, 4'h0, 16'd16});
         gpu_push(GPU_PA_MASK);
         gpu_push({OP_SET_EXT, EXT_SET_TEX, 8'h00, 2'b00, 1'b0, 1'b1, 3'b000, 1'b0, 4'h0, 4'h0});
         gpu_push({OP_SET_EXT, EXT_SET_UV, 24'h0});
         gpu_push({16'h0000, 16'h0040});                         // u 0, v 1.0
         gpu_push({OP_SET_EXT, EXT_SET_STEP, 24'h0});
         gpu_push({16'h0800, 16'h0000});                         // du 1.0, dv 0
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(32'd1000);                                     // words 500-501
         ta_w = {OP_EXEC_TEX, 14'd0, 14'd4};
         gpu_push(ta_w);
         repeat(30) @(posedge free_clk);
         if ((vram_mem[500] !== 32'h7E57_0500) || (vram_mem[501] !== 32'h7E57_0501)) begin
            $display("ERROR: texel past 2^PA_W: words 500/501 = 0x%h 0x%h, drawn from a wrapped address %t",
                     vram_mem[500], vram_mem[501], $time);
            error = error + 1;
         end
         ta_expect(OP_EXEC_TEX, 3'd5, 1'b1, ta_w);

         // A known record first (an invalid word: cause 1), then the fault and
         // the flush; ta_f 0: ABORT (abandons the rectangle), 1: CLEAR_ERR (lets
         // it finish: a flush before the fault leaves it to fault after)
         for (ta_f = 0; ta_f < 2; ta_f = ta_f + 1) begin
            $display("--- %0s swept across a bound fault: the fault's record with its interrupt, or neither",
                     ta_f ? "CLEAR_ERR" : "ABORT");
            ta_hit  = 0;
            ta_miss = 0;
            for (ta_d = 0; ta_d < 40; ta_d = ta_d + 1) begin
               gpu_push(32'h0000_0000);
               repeat(30) @(posedge free_clk);
               reg_rd_mask(GPU_STAT, {4'h0, 3'd1, 25'h0} | GS_ERR, 32'hFE40_0000);
               reg_wr(GPU_CTRL, 32'h1);                          // CLEAR_ERR
               repeat(4) @(posedge free_clk);
               reg_wr(IRQ_FLAG, IF_GPU_ALL);
               gpu_push({OP_SET_DST, 12'h000, 16'd0});
               gpu_push(2 * (ta_vw - 2));
               gpu_push({OP_SET_SIZE, 14'd1, 14'd8});
               gpu_push({OP_SET_FILL, 28'h0});
               gpu_push(32'h0000_3C3C);
               gpu_push({OP_EXEC_FILL, 28'h0});
               repeat(ta_d) @(posedge free_clk);
               reg_wr(GPU_CTRL, ta_f ? 32'h1 : 32'h2);
               repeat(30) @(posedge free_clk);
               reg_rd_val(IRQ_FLAG, ta_flag);
               reg_rd_val(GPU_STAT, ta_stat);
               if ((ta_flag & IF_ERR) != 0) begin
                  ta_hit = ta_hit + 1;
                  if ((ta_stat & 32'hFE00_0000) != {OP_EXEC_FILL, 3'd5, 25'h0}) begin
                     $display("ERROR: %0s %0d cycles after the EXEC: GPU_ERR interrupt, GPU_STAT 0x%h without the fault's record (cause 5) %t",
                              ta_f ? "CLEAR_ERR" : "ABORT", ta_d, ta_stat, $time);
                     error = error + 1;
                  end
                  if (!ta_f && ((ta_stat & GS_ERR) == 0)) begin
                     $display("ERROR: ABORT %0d cycles after the EXEC: GPU_ERR interrupt without ERR (GPU_STAT 0x%h) %t",
                              ta_d, ta_stat, $time);
                     error = error + 1;
                  end
               end else begin
                  ta_miss = ta_miss + 1;
                  if (((ta_stat & 32'hFE00_0000) != {4'h0, 3'd1, 25'h0}) || ((ta_stat & GS_ERR) != 0)) begin
                     $display("ERROR: %0s %0d cycles after the EXEC: no interrupt, but GPU_STAT 0x%h is not the record before, ERR clear (cause 1) %t",
                              ta_f ? "CLEAR_ERR" : "ABORT", ta_d, ta_stat, $time);
                     error = error + 1;
                  end
               end
               if ((ta_stat & GS_ERR) != 0)
                  reg_wr(GPU_CTRL, 32'h1);                       // CLEAR_ERR
               repeat(4) @(posedge free_clk);
               reg_wr(IRQ_FLAG, IF_GPU_ALL);
               gpu_shadow[ta_vw - 2] = vram_mem[ta_vw - 2];
               gpu_shadow[ta_vw - 1] = vram_mem[ta_vw - 1];
            end
            $display("       %0d faults recorded, %0d flushed with no record", ta_hit, ta_miss);
            if ((ta_hit == 0) || (ta_miss == 0)) begin
               $display("ERROR: the %0s sweep did not span the fault (%0d faults, %0d with no record) %t",
                        ta_f ? "CLEAR_ERR" : "ABORT", ta_hit, ta_miss, $time);
               error = error + 1;
            end
         end

         $display("--- CALL whose list does not fit: ERR_CAUSE 6, nothing of it runs");
         vram_mem[ta_vw - 2]   = {OP_SET_FILL, 28'h0};       gpu_shadow[ta_vw - 2] = vram_mem[ta_vw - 2];
         vram_mem[ta_vw - 1]   = 32'h0000_ABCD;              gpu_shadow[ta_vw - 1] = vram_mem[ta_vw - 1];
         gpu_push({OP_CALL, 4'h0, 24'd3});                   // one word past the end
         gpu_push(ta_vw - 2);
         ta_expect(OP_CALL, 3'd6, 1'b1, ta_vw - 2);
         reg_rd(GPU_LIST, 32'h0);                            // never started
         // the same list with N = 2 fits
         gpu_push({OP_CALL, 4'h0, 24'd2});
         gpu_push(ta_vw - 2);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);

         // Run-ahead: a CALL whose list does not fit, decoded while a rectangle
         // before it runs past the VRAM; its operand swept across the cycle of the
         // fault. The rectangle comes first: cause 5 with its own opcode and word
         if (GPU_RUNAHEAD_EN != 0) begin
            $display("--- run-ahead: a CALL that does not fit, its operand swept across a FILL's bound fault: ERR_CAUSE 5");
            ta_coin = 0;
            for (ta_d = 0; ta_d < 300; ta_d = ta_d + 1) begin
               gpu_push({OP_SET_DST, 12'h000, 16'd0});
               gpu_push(2 * (ta_vw - 7 * 32));
               gpu_push({OP_SET_SIZE, 14'd8, 14'd64});           // rows 0-6 inside, row 7 at VRAM_WORDS
               gpu_push({OP_SET_FILL, 28'h0});
               gpu_push({16'h0000, ta_d[15:0]});
               ta_w = {OP_EXEC_FILL, 28'h0};
               gpu_push(ta_w);
               gpu_push({OP_CALL, 4'h0, 24'd4});
               repeat(ta_d) @(posedge free_clk);
               gpu_push(ta_vw - 2);
               reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 2000);
               reg_rd_val(GPU_STAT, ta_stat);
               reg_rd_val(GPU_ERR, ta_flag);
               if (((ta_stat & 32'hFE40_0000) != ({OP_EXEC_FILL, 3'd5, 25'h0} | GS_ERR)) || (ta_flag !== ta_w)) begin
                  $display("ERROR: operand %0d cycles after the CALL: GPU_STAT 0x%h GPU_ERR 0x%h / expected cause 5, ERR_OPCODE 8, GPU_ERR 0x%h %t",
                           ta_d, ta_stat, ta_flag, ta_w, $time);
                  error = error + 1;
               end
               ta_expect(OP_EXEC_FILL, 3'd5, 1'b1, ta_w);
               for (ta_k = ta_vw - 7 * 32; ta_k < ta_vw; ta_k = ta_k + 1)
                  gpu_shadow[ta_k] = vram_mem[ta_k];
            end
            $display("       %0d sweep points with the CALL error in the cycle of the fault", ta_coin);
            if (ta_coin == 0) begin
               $display("ERROR: the sweep never put the CALL error in the cycle of the bound fault %t", $time);
               error = error + 1;
            end
         end
      end else
         $display("INFO:  VRAM_WORDS = 2^VRAM_AW: no address past the VRAM, bounds not tested");

      gpu_check_all("api end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
