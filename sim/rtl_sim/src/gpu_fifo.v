//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_fifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_fifo.v
// Module Description : GPU register block and command FIFO: GPU_STAT
//                      after reset (EMPTY, FREE = depth,
//                      ERR_OPCODE 0), GPU_CMD / GPU_CTRL / 0x10C read 0,
//                      BLNS_CFG GPU bit, BLNS_CFG2 FIFO_AW; HELD only with DBG_CTRL[1] AND
//                      dbg_stoptime (also when frozen idle); while frozen
//                      nothing is consumed: FREE / USED / EMPTY / FULL walked
//                      word by word up to GPU_FIFO_DEPTH, a push to the full
//                      FIFO is dropped with GPU_OVFL; push with CTRL.GPU_EN=0
//                      dropped with GPU_OVFL; after release exactly the
//                      queued words execute. Run with GPU_FIFO_DEPTH 4/16/32.
//                      A dropped push puts the stream out of step: a dropped
//                      SET_FILL word makes its operand a command (the EXEC
//                      after it becomes that command's operand); a dropped
//                      operand makes the next command the operand. CLEAR_ERR
//                      and ABORT do not repair it (they discard the next
//                      word as the operand owed), GPU_EN = 0 then 1 does: the
//                      next word is decoded as a command.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tq_k;
reg [31:0] tq_exp;

function [31:0] tq_stat;
   input integer used;
   begin
      tq_stat = ((used == 0) ? GS_EMPTY : GS_BUSY) | ((used == GPU_FIFO_DEPTH) ? GS_FULL : 32'h0) |
                (used << 8) | (GPU_FIFO_DEPTH - used);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: registers, FIFO, overflow         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, 4096);
      gpu_model_init;

      $display("--- reset values and register block");
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_rd(GPU_CMD,  32'h0);
      reg_rd(GPU_CTRL, 32'h0);
      reg_rd(32'h10C,  32'h0);
      reg_wr(32'h10C,  32'hFFFF_FFFF);
      reg_rd(32'h10C,  32'h0);
      reg_rd_mask(BLNS_CFG, 32'h2_0000, 32'h2_0000);                 // GPU
      reg_rd_mask(BLNS_CFG2, GPU_FIFO_AW, 32'hF);                    // FIFO_AW
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);

      gpu_set_mode(4);
      gpu_set_dispw(64);
      gpu_c_dst(16'd64, 32'd2000);
      gpu_c_size(14'd4, 14'd2);
      gpu_c_fill(32'h0000_7E57);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      $display("--- freeze needs DBG_CTRL[1] and dbg_stoptime");
      reg_wr(DBG_CTRL, 32'h2);
      repeat(5) @(posedge free_clk);
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_wr(DBG_CTRL, 32'h1);
      @(negedge free_clk) dbg_stoptime = 1'b1;
      repeat(5) @(posedge free_clk);
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      gpu_push({OP_FENCE, 28'h0});                       // consumed: not frozen
      repeat(10) @(posedge free_clk);
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_wr(DBG_CTRL, 32'h2);
      repeat(5) @(posedge free_clk);
      reg_rd(GPU_STAT, GS_HELD | GS_EMPTY | GPU_FIFO_DEPTH);   // frozen while idle
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      $display("--- frozen: fill the FIFO word by word");
      for (tq_k = 1; tq_k <= GPU_FIFO_DEPTH; tq_k = tq_k + 1) begin
         if (tq_k < GPU_FIFO_DEPTH) gpu_push({OP_FENCE, 28'h0});
         else                       gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000));
         reg_rd(GPU_STAT, GS_HELD | tq_stat(tq_k));
      end
      reg_rd(STATUS, 32'h0000_0002);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      $display("--- push to the full FIFO: dropped, GPU_OVFL");
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      reg_rd(GPU_STAT, GS_HELD | tq_stat(GPU_FIFO_DEPTH));
      reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      $display("--- release: the queued words execute, not the dropped one");
      gpu_mon_start;
      dbg_stoptime = 1'b0;
      gpu_wait_idle;
      gpu_mon_stop;
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_exp_rd = 0;
      gpu_exp_wr = 0;
      gpu_x_run;
      if ((gpu_mon_wr != gpu_exp_wr) || (gpu_mon_rd != 0)) begin
         $display("ERROR: GPU accesses after release: %0d writes / %0d reads, expected %0d / 0 %t", gpu_mon_wr, gpu_mon_rd, gpu_exp_wr, $time);
         error = error + 1;
      end
      gpu_check_touched("FIFO content executed");
      reg_wr(DBG_CTRL, 32'h0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      $display("--- push with CTRL.GPU_EN = 0: dropped, GPU_OVFL");
      reg_wr(CTRL, 32'h4);
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_set_mode(4);
      repeat(20) @(posedge free_clk);
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);

      $display("--- FIFO full again (frozen), then GPU_EN = 0 flushes");
      gpu_freeze(1'b1);
      for (tq_k = 1; tq_k <= GPU_FIFO_DEPTH; tq_k = tq_k + 1)
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      reg_rd(GPU_STAT, GS_HELD | tq_stat(GPU_FIFO_DEPTH));
      reg_wr(CTRL, 32'h4);
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF07F_FFFF);
      gpu_set_mode(4);
      gpu_freeze(1'b0);
      repeat(20) @(posedge free_clk);
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);

      $display("--- a dropped SET_FILL word: its operand is decoded as a command");
      gpu_c_dst(16'd64, 32'd3000);
      gpu_c_size(14'd5, 14'd2);
      gpu_c_fill(32'h0000_1111);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_freeze(1'b1);
      for (tq_k = 1; tq_k <= GPU_FIFO_DEPTH; tq_k = tq_k + 1)
         gpu_push({OP_FENCE, 28'h0});
      gpu_push({OP_SET_FILL, 28'h0});                              // dropped
      reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
      gpu_freeze(1'b0);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tq_exp = gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_push({OP_SET_TRANSP, 12'h000, 16'h2222});                // the colour, taken as SET_TRANSP
      gpu_push(tq_exp);                                            // the EXEC, taken as its operand
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE | IF_ERR);               // nothing drawn
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_all("dropped command word");
      gpu_m_transp = tq_exp[15:0];
      gpu_c_fill({16'h0, tq_exp[15:0]});                           // equal to the new SET_TRANSP: op 14 skips
      gpu_c_exec(GPU_FILL, 4'd14, 3'b000, 3'b000);
      gpu_c_fill(32'h0000_3333);
      gpu_c_dst(16'd64, 32'd3100);
      gpu_c_exec(GPU_FILL, 4'd14, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_all("the misread SET_TRANSP");

      for (tq_k = 0; tq_k < 4; tq_k = tq_k + 1) begin
         $display("--- a dropped SET_FILL operand, then %0s", (tq_k == 0) ? "nothing" : (tq_k == 1) ? "CLEAR_ERR" :
                  (tq_k == 2) ? "ABORT" : "GPU_EN = 0, 1");
         gpu_c_dst(16'd64, 32'd3200 + 100 * tq_k);
         gpu_c_size(14'd6, 14'd3);
         gpu_c_fill(32'h0000_4444);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_freeze(1'b1);
         for (tq_exp = 1; tq_exp < GPU_FIFO_DEPTH; tq_exp = tq_exp + 1)
            gpu_push({OP_FENCE, 28'h0});
         gpu_push({OP_SET_FILL, 28'h0});                           // the last free word
         gpu_push(32'h0000_5555);                                  // its operand: dropped
         reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
         gpu_freeze(1'b0);
         repeat(GPU_FIFO_DEPTH + 20) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_BUSY | GS_EMPTY, GS_BUSY | GS_EMPTY | GS_ERR);   // waits for the operand
         case (tq_k)
           1: reg_wr(GPU_CTRL, 32'h1);
           2: reg_wr(GPU_CTRL, 32'h2);
           3: begin
                 reg_wr(CTRL, 32'h4);
                 gpu_set_mode(4);
              end
           default: ;
         endcase
         gpu_flush_hint = 1'b0;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tq_exp = {OP_SET_SIZE, 14'd2, 14'd9};
         gpu_push(tq_exp);                                         // SET_SIZE 9 x 2
         gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000));
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         // the model: 0 the SET_SIZE word is the fill colour; 1, 2 it is the
         // operand owed, discarded; 3 decoded as a command
         case (tq_k)
           0:       gpu_m_fill = tq_exp[15:0];
           3:       begin gpu_m_w = 9; gpu_m_h = 2; end
           default: ;
         endcase
         gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_x_run;
         reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
         gpu_check_all((tq_k == 3) ? "GPU_EN 0 -> 1 resynchronised" : "still out of step");
      end

      gpu_check_all("fifo end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
