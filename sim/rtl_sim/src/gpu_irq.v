//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_irq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_irq.v
// Module Description : GPU events and status:
//                      no GPU_IDLE out of reset or on GPU_EN; configuration
//                      commands and FENCE raise no GPU_DONE; EXEC raises
//                      GPU_DONE; FENCE writes its TAG to GPU_FENCE and, with
//                      [24] IRQ, raises GPU_FENCE; GPU_IDLE once per falling
//                      edge of BUSY; decoder waiting for an operand word keeps
//                      BUSY with EMPTY = 1; PRIM_BUSY and STATUS[1] during a
//                      rectangle; GPU_OVFL and GPU_ERR flags; IRQ_EN masks
//                      each flag onto irq_o; W1C clears one flag only.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    ti_b;

task ti_check_irq;
   input exp;
   begin
      @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b %t", irq, exp, $time);
         error = error + 1;
      end else
         $display("OK:    irq_o = %b", irq);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: events, IRQ flags, status         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_model_init;

      $display("--- no event out of reset, nor when enabling the GPU");
      repeat(20) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      gpu_set_mode(4);
      gpu_set_dispw(64);
      repeat(20) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      reg_rd_mask(STATUS, 32'h0, 32'h6);
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_wr(IRQ_EN, IF_GPU_ALL);
      ti_check_irq(1'b0);

      $display("--- configuration commands: GPU_IDLE, no GPU_DONE");
      gpu_c_dst(16'd0, 32'd100);
      gpu_c_src(16'd0, 32'd5000);
      gpu_c_size(14'd8, 14'd4);
      gpu_c_fill(32'h0000_1111);
      gpu_c_transp(32'h0000_2222);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      ti_check_irq(1'b1);
      reg_wr(IRQ_FLAG, IF_IDLE);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      ti_check_irq(1'b0);
      repeat(50) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);          // no re-fire while idle

      $display("--- FENCE TAG / IRQ");
      reg_rd(GPU_FENCE, 32'h0);                           // reset
      gpu_c_fence(1'b0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_c_fence(1'b1);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE | IF_FENCE, IF_GPU_ALL);
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      reg_wr(IRQ_FLAG, IF_FENCE);                         // W1C one bit only
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_IDLE);
      // the full 24-bit tag, in order through a burst
      gpu_push({OP_FENCE, 4'h0, 24'hA5C3F0});
      gpu_push({OP_FENCE, 4'h0, 24'hFFFFFF});
      gpu_push({OP_FENCE, 4'h1, 24'h000001});
      gpu_wait_idle;
      reg_rd(GPU_FENCE, 32'h0000_0001);
      reg_rd_mask(IRQ_FLAG, IF_IDLE | IF_FENCE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_m_fence = 24'h000001;

      $display("--- operand wait: BUSY with EMPTY");
      gpu_push({OP_SET_FILL, 28'h0});
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_BUSY | GS_EMPTY, GS_BUSY | GS_EMPTY | GS_PRIM_BUSY | GS_FULL | 32'hFF00);
      reg_rd_mask(STATUS, 32'h2, 32'h2);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      gpu_push(32'h0000_3333);
      gpu_m_fill = 16'h3333;
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      $display("--- EXEC: PRIM_BUSY, STATUS[1], GPU_DONE, GPU_IDLE");
      gpu_c_size(14'd40, 14'd20);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_c_exec(GPU_FILL, 4'd3, 3'b000, 3'b000);
      reg_rd_mask(GPU_STAT, GS_BUSY | GS_PRIM_BUSY, GS_BUSY | GS_PRIM_BUSY);
      reg_rd_mask(STATUS, 32'h2, 32'h2);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hFFFF_FFFF);
      reg_rd_mask(STATUS, 32'h0, 32'h6);
      reg_rd_mask(IRQ_FLAG, IF_IDLE | IF_DONE, IF_GPU_ALL);
      gpu_check_touched("exec");

      $display("--- IRQ_EN masks each GPU flag");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, 32'h0);
      // raise DONE + IDLE + FENCE
      gpu_c_size(14'd2, 14'd2);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_c_fence(1'b1);
      gpu_wait_idle;
      // raise OVFL: push with CTRL.GPU_EN = 0 (dropped)
      reg_wr(CTRL, 32'h4);
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | GS_BUSY | 32'hFF00);
      gpu_set_mode(4);
      // raise ERR: invalid opcode, then CLEAR_ERR
      gpu_push(32'h0000_0000);
      repeat(10) @(posedge free_clk);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_GPU_ALL, IF_GPU_ALL);
      ti_check_irq(1'b0);
      for (ti_b = 4; ti_b < 10; ti_b = ti_b + ((ti_b == 7) ? 2 : 1)) begin
         reg_wr(IRQ_EN, 32'h1 << ti_b);
         ti_check_irq(1'b1);
         reg_wr(IRQ_EN, ~(32'h1 << ti_b) & IF_GPU_ALL);
         reg_wr(IRQ_FLAG, ~(32'h1 << ti_b) & IF_GPU_ALL);  // clear the others
         ti_check_irq(1'b0);
         reg_wr(IRQ_EN, IF_GPU_ALL);
         ti_check_irq(1'b1);
         reg_wr(IRQ_FLAG, 32'h1 << ti_b);
         ti_check_irq(1'b0);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
         // raise all five again for the next bit
         reg_wr(IRQ_EN, 32'h0);
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_c_fence(1'b1);
         gpu_wait_idle;
         reg_wr(CTRL, 32'h4);
         gpu_push(32'h8000_000E);
         gpu_set_mode(4);
         gpu_push(32'h0000_0000);
         repeat(10) @(posedge free_clk);
         reg_wr(GPU_CTRL, 32'h1);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_GPU_ALL, IF_GPU_ALL);
      end
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, 32'h0);

      gpu_check_touched("end");
      gpu_check_all("irq end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
