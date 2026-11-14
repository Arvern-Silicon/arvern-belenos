//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_absent
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_absent.v
// Module Description : Build without the GPU (BLNS_GPU_EN=0; skipped
//                      otherwise): offsets 0x100-0x11C are unmapped (OKAY,
//                      zero wait, read 0, write ignored), BLNS_CFG [17] GPU
//                      = 0 and BLNS_CFG2 = 0,
//                      CTRL[4] reads 0, a command sequence written to GPU_CMD
//                      (with CTRL[4] written 1) does not touch VRAM, STATUS
//                      GPU bits and the GPU IRQ flags stay 0, irq_o stays low.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tb_k;
reg [31:0] tb_off;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: absent (GPU_EN = 0 build)         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN != 0)
         tb_skip_finish("|          (GPU_EN = 1: GPU present)            |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;

      reg_rd_mask(BLNS_CFG, 32'h0, 32'h2_0000);
      reg_rd(BLNS_CFG2, 32'h0);
      reg_wr(CTRL, 32'h0000_0014);
      reg_rd(CTRL, 32'h0000_0004);
      reg_wr(IRQ_EN, IF_GPU_ALL);
      reg_wr(DBG_CTRL, 32'h2);

      for (tb_k = 0; tb_k < 8; tb_k = tb_k + 1) begin
         tb_off = GPU_CMD + 4 * tb_k;
         reg_rd(tb_off, 32'h0);
         if (ahb_last_waits != 0) begin
            $display("ERROR: offset 0x%h read took %0d wait states %t", tb_off, ahb_last_waits, $time);
            error = error + 1;
         end
         reg_wr(tb_off, 32'hFFFF_FFFF);
         if (ahb_last_waits != 0) begin
            $display("ERROR: offset 0x%h write took %0d wait states %t", tb_off, ahb_last_waits, $time);
            error = error + 1;
         end
         reg_rd(tb_off, 32'h0);
      end

      gpu_mon_start;
      reg_wr(GPU_CMD, {OP_SET_DST, 28'h0});
      reg_wr(GPU_CMD, 32'd100);
      reg_wr(GPU_CMD, {OP_SET_FILL, 28'h0});
      reg_wr(GPU_CMD, 32'h0000_FFFF);
      reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
      reg_wr(GPU_CMD, {OP_FENCE, 28'h100_0001});
      reg_wr(GPU_CMD, 32'h7000_0000);
      reg_wr(GPU_CTRL, 32'h3);
      @(negedge free_clk) dbg_stoptime = 1'b1;
      repeat(50) @(posedge free_clk);
      gpu_mon_stop;
      if (gpu_mon_n != 0) begin
         $display("ERROR: %0d VRAM accesses without a GPU %t", gpu_mon_n, $time);
         error = error + 1;
      end
      reg_rd(GPU_STAT, 32'h0);
      reg_rd_mask(STATUS, 32'h0, 32'h6);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      @(negedge free_clk);
      if (irq !== 1'b0) begin
         $display("ERROR: irq_o = %b without a GPU %t", irq, $time);
         error = error + 1;
      end
      dbg_stoptime = 1'b0;
      gpu_check_all("absent end");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
