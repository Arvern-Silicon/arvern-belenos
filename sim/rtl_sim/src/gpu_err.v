//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_err
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_err.v
// Module Description : Invalid GPU opcodes: each of 0x0, 0x7,
//                      SET_EXT (0x6) with a reserved sub-command
//                      ([27:24] = 0xF) sets ERR and ERR_OPCODE, the
//                      word stays at the FIFO head (USED counts it and the
//                      words queued behind it, BUSY = 1), STATUS[2], one
//                      GPU_ERR event (cleared by W1C while ERR stays 1, it
//                      does not come back), queued words are not executed.
//                      The three exits, rotated over the opcodes:
//                      GPU_CTRL.CLEAR_ERR (flush, ERR cleared), CTRL.GPU_EN=0
//                      (flush, ERR cleared), GPU_CTRL.ABORT (flush, ERR kept,
//                      then CLEAR_ERR). ERR_OPCODE keeps its value after the
//                      clear; the decoder resumes with the next command.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    te_i, te_exit, te_q;
reg  [3:0] te_op;
reg [31:0] te_exp;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: invalid opcodes and ERR exits     |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
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
      reg_rd_mask(GPU_STAT, 32'h0, 32'hF040_0000);       // ERR_OPCODE 0 after reset

      for (te_i = 0; te_i < 6; te_i = te_i + 1) begin
         te_op   = (te_i % 2 == 0) ? 4'h0 : 4'h6;          // 0x0, or SET_EXT sub 0xF (reserved)
         te_exit = te_i % 3;
         te_q    = (te_i % 3) + 1;                        // words queued behind it
         $display("--- opcode 0x%h, exit %0s, %0d words queued behind", te_op,
                  (te_exit == 0) ? "CLEAR_ERR" : (te_exit == 1) ? "GPU_EN=0" : "ABORT", te_q);
         gpu_push({te_op, 28'hFAB_CDEF});                 // SET_EXT sub-command 0xF: reserved
         // queued EXECs that must never run (all-ones fill on the dst)
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
         if (te_q > 1) gpu_push(gpu_exec_word(GPU_FILL, 4'd13, 3'b000, 3'b000));
         if (te_q > 2) gpu_push({OP_FENCE, 28'h100_0001});
         repeat(20) @(posedge free_clk);
         te_exp = (te_op << 28) | GS_ERR | GS_BUSY | ((te_q + 1) << 8) | (GPU_FIFO_DEPTH - te_q - 1) | ((te_q + 1 == GPU_FIFO_DEPTH) ? GS_FULL : 32'h0);
         reg_rd_mask(GPU_STAT, te_exp, 32'hF0FF_FFFF);
         reg_rd_mask(STATUS, 32'h6, 32'h6);
         reg_rd_mask(IRQ_FLAG, IF_ERR, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_ERR);                        // W1C while ERR = 1
         repeat(20) @(posedge free_clk);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);        // one event only
         reg_rd_mask(GPU_STAT, te_exp, 32'hF0FF_FFFF);    // still stuck

         if (te_exit == 0)
            reg_wr(GPU_CTRL, 32'h1);
         else if (te_exit == 1) begin
            reg_wr(CTRL, 32'h4);
            reg_wr(CTRL, 32'h14);
         end else begin
            reg_wr(GPU_CTRL, 32'h2);                      // ABORT: flush, ERR kept
            repeat(4) @(posedge free_clk);
            reg_rd_mask(GPU_STAT, (te_op << 28) | GS_ERR | GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
            reg_rd_mask(STATUS, 32'h4, 32'h4);
            reg_wr(GPU_CTRL, 32'h1);
         end
         repeat(4) @(posedge free_clk);
         // ERR cleared, FIFO empty, ERR_OPCODE kept
         reg_rd_mask(GPU_STAT, (te_op << 28) | GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
         reg_rd_mask(STATUS, 32'h0, 32'h6);
         // the decoder resumes
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_c_fill($random(gpu_seed));
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_check_touched("after error exit");
      end

      gpu_check_all("err end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
