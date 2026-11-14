//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_err
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_err.v
// Module Description : Errors of the line commands, in every GPU build:
//                       1. without lines (GPU_LINE_EN = 0 or no GPU_XY_EN):
//                          EXEC_FILL [24] LINE and SET_AUX SEL 2 / 3 refused
//                          with ERR_CAUSE 2, their operand pushed behind them
//                          (the pushed stream stays in step: the next command
//                          runs after CLEAR_ERR); as a list's last word: cause
//                          2, not 4;
//                       2. with lines: SET_AUX SEL 6-15 (cause 1), LINE with
//                          TRI (cause 1; 2 without triangles), AA without
//                          GPU_BLEND_EN (cause 2), REMAP 3 (cause 1), REMAP
//                          1 / 2 without GPU_REMAP_EN (cause 2); as a list's
//                          last word each refused without its operand reports
//                          its own cause, a valid or REMAP 3 LINE word cause
//                          4; GPU_ERR the EXEC word;
//                       3. EXEC_FILL [19:16] without [24]: ignored (a plain
//                          FILL);
//                       4. ERR_CAUSE 5: a line reaching VRAM_WORDS draws the
//                          pixels before it; the pattern phase is 0 after it
//                          (the next line drawn from phase 0), the pen at the
//                          faulting line's end point.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer LE_LST    = 400;             // command lists: words [400, 500)
localparam integer LE_D_LO   = 600;
localparam integer LE_P      = 40;

integer    le_i, le_k, le_nd;
reg [31:0] le_w;
reg        le_line;

// The GPU must be in ERR with this record; CLEAR_ERR; a 2-pixel fill at VRAM
// word 100 must then run (16 bpp, address mode)
task le_expect;
   input  [3:0] op;
   input  [2:0] cause;
   input [31:0] word;
   input [31:0] list;                    // GPU_LIST expected (0: from the FIFO)
   reg   [31:0] c;
   begin
      repeat(40) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_rd(GPU_ERR, word);
      if (list != 0) reg_rd(GPU_LIST, list);
      reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR);
      reg_wr(GPU_CTRL, 32'h1);                                   // CLEAR_ERR
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_EMPTY, 32'hFE7F_0000);   // record kept
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      c = $random(gpu_seed);
      gpu_c_dst(16'd0, 32'd200);                                 // pixel 200 = word 100 (16 bpp)
      gpu_c_size(14'd2, 14'd1);
      gpu_c_fill({16'h0000, c[15:0]});
      gpu_push({OP_EXEC_FILL, 28'h0});
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      if (vram_mem[100] !== {c[15:0], c[15:0]}) begin
         $display("ERROR: no recovery after ERR_CAUSE %0d: word 100 = 0x%h / expected 0x%h %t",
                  cause, vram_mem[100], {c[15:0], c[15:0]}, $time);
         error = error + 1;
      end
      gpu_shadow[100] = vram_mem[100];
   end
endtask

// A refused word from the FIFO, its operand pushed behind it (opnd)
task le_word;
   input [31:0] w;
   input        opnd;
   input  [2:0] cause;
   begin
      $display("--- 0x%h: ERR_CAUSE %0d", w, cause);
      gpu_push(w);
      if (opnd) gpu_push(32'h4123_4567);                         // (a SET_FILL if decoded as a command)
      le_expect(w[31:28], cause, w, 32'h0);
   end
endtask

// A list of SET_SIZE then w as its last word: the record of cause (opcode op)
task le_list_last;
   input [31:0] w;
   input  [3:0] op;
   input  [2:0] cause;
   begin
      $display("--- list ending with 0x%h: ERR_CAUSE %0d", w, cause);
      vram_mem[LE_LST]       = {OP_SET_SIZE, 14'd1, 14'd1};
      vram_mem[LE_LST + 1]   = w;
      gpu_shadow[LE_LST]     = vram_mem[LE_LST];
      gpu_shadow[LE_LST + 1] = vram_mem[LE_LST + 1];
      gpu_push({OP_CALL, 4'h0, 24'd2});
      gpu_push(LE_LST);
      le_expect(op, cause, w, LE_LST + 1);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: line command errors               |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 1000)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(LE_P);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      le_line = (GPU_LINE_EN != 0) && (GPU_XY_EN != 0);

      //--------------------------------------------------------------
      if (!le_line) begin
         $display("=== 1. lines absent");
         le_word({OP_EXEC_FILL, 28'h100_0000}, 1'b1, 3'd2);
         le_word({OP_EXEC_FILL, 28'h10F_0005}, 1'b1, 3'd2);                 // with options
         le_word({OP_SET_EXT, EXT_SET_AUX, 4'd2, 20'h00000}, 1'b1, 3'd2);    // LINE_PEN
         le_word({OP_SET_EXT, EXT_SET_AUX, 4'd3, 20'h0001F}, 1'b1, 3'd2);    // LINE_PATTERN
         le_list_last({OP_EXEC_FILL, 28'h100_0000}, OP_EXEC_FILL, 3'd2);
         le_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd3, 20'h00000}, OP_SET_EXT, 3'd2);
      end else begin
         $display("=== 2. line command errors");
         for (le_k = 6; le_k < 16; le_k = le_k + 3)
            le_word({OP_SET_EXT, EXT_SET_AUX, le_k[3:0], 20'h00000}, 1'b1, 3'd1);   // reserved SEL
         le_word({OP_EXEC_FILL, 28'h100_0080}, 1'b1, (GPU_TRI_EN != 0) ? 3'd1 : 3'd2);   // LINE + TRI
         le_word({OP_EXEC_FILL, 28'h100_3000}, 1'b1, 3'd1);                 // REMAP 3
         if (GPU_BLEND_EN == 0) le_word({OP_EXEC_FILL, 28'h101_0000}, 1'b1, 3'd2);   // AA
         if (GPU_REMAP_EN == 0) le_word({OP_EXEC_FILL, 28'h100_1000}, 1'b1, 3'd2);
         le_list_last({OP_EXEC_FILL, 28'h100_0000}, OP_CALL, 3'd4);          // a list cut after the word
         le_list_last({OP_EXEC_FILL, 28'h100_3000}, OP_CALL, 3'd4);          // REMAP 3: takes its operand
         le_list_last({OP_EXEC_FILL, 28'h100_0080}, OP_EXEC_FILL, (GPU_TRI_EN != 0) ? 3'd1 : 3'd2);
         if (GPU_BLEND_EN == 0) le_list_last({OP_EXEC_FILL, 28'h101_0000}, OP_EXEC_FILL, 3'd2);
         le_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd2, 20'h00000}, OP_CALL, 3'd4);   // LINE_PEN cut
         le_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd9, 20'h00000}, OP_SET_EXT, 3'd1);
      end

      //--------------------------------------------------------------
      $display("=== 3. EXEC_FILL [19:16] without LINE: a plain FILL");
      gpu_preload_rand(LE_D_LO, LE_D_LO + 64);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(LE_P);
      gpu_c_dst(16'd0, 2 * LE_D_LO + 3);
      gpu_c_size(14'd9, 14'd3);
      gpu_c_fill($random(gpu_seed));
      gpu_push({OP_EXEC_FILL, 8'h00, 4'hF, 16'h0000});
      gpu_d_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("FILL with [19:16] set");

      //--------------------------------------------------------------
      if (le_line) begin
         $display("=== 4. ERR_CAUSE 5: the pixels before it, the phase to 0, the pen moved");
         gpu_model_init;
         gpu_set_mode(4);
         gpu_set_dispw(LE_P);
         gpu_oob_ok  = 1'b1;
         gpu_rgn_dhi = 32'h7FFF_FFFF;                                   // (pixels past the VRAM: the fault)
         gpu_rec_begin;
         gpu_c_dst_xy(LE_P, (VRAM_WORDS - 6) * 2 + 1);                  // rows 0-2 below the end of the VRAM
         gpu_c_noclip;
         gpu_c_pattern(32'h0000_0D6B, 13);
         gpu_c_fill($random(gpu_seed));
         gpu_c_pen(16 * 3 + 8, 16 * 0 + 8);
         gpu_c_line(16 * 30 + 8, 16 * 4 + 8, 4'd0, 4'h0);                // crosses the end at row 1
         repeat(200) @(posedge free_clk);
         gpu_rec_end;
         reg_rd_mask(GPU_STAT, {OP_EXEC_FILL, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_rd(GPU_ERR, {OP_EXEC_FILL, 3'b000, 1'b1, 24'h00_0000});
         // the image: the pixels before the first one past the VRAM, none after
         le_nd = gpu_rec_n;
         for (le_i = gpu_rec_n - 1; le_i >= 0; le_i = le_i - 1)
            if ((gpu_rec_pa[le_i] >> 1) >= VRAM_WORDS) le_nd = le_i;
         for (le_i = 0; le_i < gpu_rec_n; le_i = le_i + 1)
            if ((gpu_rec_pa[le_i] >> 1) < VRAM_WORDS)
               if (gpu_vram_px(gpu_rec_pa[le_i], 4) !== ((le_i < le_nd) ? gpu_rec_new[le_i] : gpu_rec_old[le_i]))
                  tb_error("ERR_CAUSE 5: a pixel of the line differs (drawn after the fault, or not before it)");
         for (le_i = 0; le_i < gpu_rec_n; le_i = le_i + 1)
            if ((gpu_rec_pa[le_i] >> 1) < VRAM_WORDS) gpu_set_px(gpu_rec_pa[le_i], 4, gpu_vram_px(gpu_rec_pa[le_i], 4));
         gpu_oob_ok  = 1'b0;
         gpu_rgn_dhi = VRAM_WORDS;
         reg_wr(GPU_CTRL, 32'h1);                                       // CLEAR_ERR
         gpu_m_lph = 0;                                                 // (the fault set it to 0)
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_preload_rand(LE_D_LO, LE_D_LO + 400);
         gpu_model_init;
         gpu_set_mode(4);
         gpu_set_dispw(LE_P);
         gpu_c_dst_xy(LE_P, 2 * LE_D_LO + 1);
         gpu_c_fill($random(gpu_seed));
         gpu_c_line(16 * 2 + 8, 16 * 12 + 8, 4'd0, 4'h0);               // from (30, 4), phase 0
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("after ERR_CAUSE 5");
      end

      gpu_check_all("line errors");
      stimulus_done = 1;
   end
