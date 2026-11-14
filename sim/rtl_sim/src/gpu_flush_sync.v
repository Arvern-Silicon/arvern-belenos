//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_flush_sync
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_flush_sync.v
// Module Description : A flush (ABORT, CLEAR_ERR) in the middle of a pushed
//                      command keeps the decoder in step with the pushed
//                      stream: the command is dropped and its operand,
//                      pushed after the flush, is discarded, whether the
//                      command was decoded (waiting for its operand), still
//                      queued, or queued with its operand. GPU_STAT.BUSY is
//                      0 while the decoder waits for the word to discard.
//                      CTRL.GPU_EN = 0 resets the stream: the next word is a
//                      command. Each case ends with a stray word that draws
//                      when decoded as a command, then a checked fill. The
//                      six cases run with SET_FILL, then (gradient built)
//                      with SET_GRAD_RGB, then (remap or mask plane built)
//                      with SET_AUX as the command. Last, a SET_AUX with a
//                      reserved selector (ERR_CAUSE 1, in every build): its
//                      operand, pushed after CLEAR_ERR, is discarded.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    fs_k;
integer    fs_c;
integer    fs_set;
reg [31:0] fs_caps;
reg [31:0] fs_cmd;
reg [31:0] fs_stray;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: flush keeps the stream in step    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 32'd40000);
      gpu_c_size(14'd12, 14'd6);
      gpu_c_fill(32'h0000_0F0F);
      gpu_wait_idle;
      gpu_check_all("flush_sync set-up");
      // decoded as a command, this operand is an EXEC_FILL op 2, NOT D (caught by the image check)
      fs_stray = gpu_exec_word(GPU_FILL, 4'd2, 3'b000, 3'b000);
      reg_rd_val(BLNS_CFG2, fs_caps);
      fs_caps = fs_caps >> 8;                                        // [0] REMAP, [1] MPLANE

      for (fs_k = 0; fs_k < 18; fs_k = fs_k + 1) begin
         fs_c   = fs_k % 6;
         fs_set = fs_k / 6;
         if (((fs_set == 1) && (GPU_GRAD_EN == 0)) || ((fs_set == 2) && (fs_caps[1:0] == 2'b00)))
            fs_k = fs_k + 5;                                         // not built: the next set
         else begin
            fs_cmd = (fs_set == 0) ? {OP_SET_FILL, 28'h0} : (fs_set == 1) ? {OP_SET_EXT, EXT_SET_GRGB, 24'h0} :
                     {OP_SET_EXT, EXT_SET_AUX, fs_caps[0] ? 4'd0 : 4'd1, 20'h00000};
            if (fs_c == 0) $display("=== the command: %0s", (fs_set == 0) ? "SET_FILL" : (fs_set == 1) ? "SET_GRAD_RGB" : "SET_AUX");
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            case (fs_c)
               0: begin
                  $display("--- ABORT while the decoder waits for the operand");
                  gpu_push(fs_cmd);
                  repeat(10) @(posedge free_clk);
                  reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY);
                  reg_wr(GPU_CTRL, 32'h2);
               end
               1: begin
                  $display("--- CLEAR_ERR while the decoder waits for the operand");
                  gpu_push(fs_cmd);
                  repeat(10) @(posedge free_clk);
                  reg_wr(GPU_CTRL, 32'h1);
               end
               2: begin
                  $display("--- ABORT with the command queued (held), operand not pushed");
                  gpu_freeze(1);
                  gpu_push(fs_cmd);
                  reg_wr(GPU_CTRL, 32'h2);
                  gpu_freeze(0);
               end
               3: begin
                  $display("--- CLEAR_ERR after an error, command queued behind it, operand not pushed");
                  gpu_freeze(1);
                  gpu_push(32'h6F00_0000);                              // SET_EXT2 code 0: invalid
                  gpu_push(fs_cmd);
                  gpu_freeze(0);
                  repeat(10) @(posedge free_clk);
                  reg_rd_mask(GPU_STAT, GS_ERR, GS_ERR);
                  reg_wr(GPU_CTRL, 32'h1);
               end
               4: begin
                  $display("--- ABORT with the command and its operand queued (held)");
                  gpu_push(fs_cmd);
                  repeat(10) @(posedge free_clk);
                  gpu_freeze(1);
                  gpu_push(32'h0000_1111);                              // flushed with the queue
                  reg_wr(GPU_CTRL, 32'h2);
                  gpu_freeze(0);
               end
               5: begin
                  $display("--- GPU_EN = 0 while the decoder waits for the operand: the next word is a command");
                  gpu_push(fs_cmd);
                  repeat(10) @(posedge free_clk);
                  reg_wr(CTRL, 32'h0);
                  gpu_set_mode(4);
                  gpu_c_dst(16'd64, 32'd40000);
                  gpu_c_size(14'd12, 14'd6);
               end
            endcase
            repeat(5) @(posedge free_clk);
            reg_rd_mask(GPU_STAT, 32'h0, GS_BUSY | GS_ERR);
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            if (fs_c < 4)
               gpu_push(fs_stray);                                      // the dropped command's operand
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            gpu_check_all("after the flush");
            gpu_c_fill(32'h0000_1000 + fs_k);
            gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
            gpu_wait_idle;
            reg_rd_mask(IRQ_FLAG, 32'h0, IF_ERR);
            gpu_check_all("fill after the flush");
         end
      end

      $display("--- SET_AUX with a reserved selector: ERR_CAUSE 1, its operand discarded after CLEAR_ERR");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push({OP_SET_EXT, EXT_SET_AUX, 4'd9, 20'h00000});
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {OP_SET_EXT, 3'd1, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_wr(GPU_CTRL, 32'h1);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      repeat(5) @(posedge free_clk);
      gpu_push(fs_stray);                                            // the operand: discarded
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_all("after the reserved SET_AUX");
      gpu_c_fill(32'h0000_2000);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_ERR);
      gpu_check_all("fill after the reserved SET_AUX");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
