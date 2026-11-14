//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_sync
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_sync.v
// Module Description : FENCE [25] AUTO and IRQ_FLAG [10] GPU_FIFO_LOW (every
//                      build with a GPU): AUTO sets GPU_FENCE + 1 (the
//                      tag field ignored, IRQ honoured, 24-bit wrap, mixed
//                      with tagged fences); a list holding AUTO fences called
//                      again and again: GPU_FENCE never goes back; GPU_FIFO_LOW
//                      once when FREE rises above half the depth (the GPU
//                      frozen while the FIFO fills, then released), not
//                      while it stays below, W1C, onto irq_o through
//                      IRQ_EN [10]; again after a refill, and on ABORT from
//                      above half. The exact edge: FREE held at depth / 2
//                      (two words popped from depth / 2 - 2, the GPU then
//                      drawing) leaves it clear, FREE at depth / 2 + 1
//                      (from depth / 2 - 1) raises it, read while the GPU
//                      draws; and in every cycle of the test the event
//                      fires exactly when FREE goes from depth / 2 or less
//                      to above depth / 2, IRQ_FLAG [10] rising in the
//                      next cycle (VRAM_WORDS >= 1000: the GPU must draw
//                      long rectangles).
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer SY_LLO  = 16;                 // command list words [16, 20); fills at words [32, 72)
localparam [31:0]  IF_FLOW = 32'h400;

integer    sy_i, sy_n, sy_dec;
reg [31:0] sy_st, sy_t, sy_exp;
reg [23:0] sy_prev;
reg        sy_mono = 1'b0;

`define SY_DEC dut.u_core.G_GPU.u_gpu.u_dec
`define SY_GPU dut.u_core.G_GPU.u_gpu

// In every cycle: GPU_FIFO_LOW fires exactly when FREE rises from depth / 2 or
// less to above depth / 2, and IRQ_FLAG [10] rises in the next cycle only then
integer    sy_free, sy_pfree, sy_nev, sy_ncr, sy_mbad;
reg        sy_pcross, sy_pflag;
reg        sy_mon_on = 1'b0;
initial begin sy_pfree = GPU_FIFO_DEPTH; sy_pcross = 1'b0; sy_pflag = 1'b0; sy_nev = 0; sy_ncr = 0; sy_mbad = 0; end
initial begin @(posedge reset_done); @(posedge hclk); sy_mon_on = 1'b1; end
always @(posedge hclk)
   if ((GPU_EN != 0) && sy_mon_on) begin : sy_edge_mon
      reg up_cross, ev, fl;
      sy_free = GPU_FIFO_DEPTH - `SY_GPU.fifo_count;
      up_cross = (sy_free > GPU_FIFO_DEPTH / 2) && (sy_pfree <= GPU_FIFO_DEPTH / 2);
      ev      = (`SY_GPU.fifo_low_evt_o === 1'b1);
      fl      = (dut.u_core.u_regs.flow_flag === 1'b1);
      if (up_cross) sy_ncr = sy_ncr + 1;
      if (ev)    sy_nev = sy_nev + 1;
      if ((ev !== up_cross) || (sy_pcross && !fl) || (fl && !sy_pflag && !sy_pcross)) begin
         sy_mbad = sy_mbad + 1;
         if (sy_mbad <= 4)
            $display("ERROR: GPU_FIFO_LOW event %b, flag %b (before %b), FREE %0d -> %0d (depth %0d) %t",
                     ev, fl, sy_pflag, sy_pfree, sy_free, GPU_FIFO_DEPTH, $time);
         error = error + 1;
      end
      sy_pfree  = sy_free;
      sy_pcross = up_cross;
      sy_pflag  = fl;
   end

// While sy_mono: GPU_FENCE never moves back (no wrap in that phase)
initial sy_dec = 0;
always @(posedge hclk)
   if (sy_mono && (GPU_EN != 0)) begin
      if (`SY_DEC.fence_o < sy_prev) begin
         if (sy_dec < 4)
            $display("ERROR: GPU_FENCE went back from 0x%h to 0x%h %t", sy_prev, `SY_DEC.fence_o, $time);
         sy_dec = sy_dec + 1;
         error  = error + 1;
      end
      sy_prev = `SY_DEC.fence_o;
   end

task sy_irq_chk;
   input exp;
   begin
      @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b %t", irq, exp, $time);
         error = error + 1;
      end
   end
endtask

// Freeze the GPU, push n FENCE AUTO words, check no FIFO_LOW yet; release
task sy_fill;
   input integer n;
   integer       ii;
   begin
      reg_wr(DBG_CTRL, 32'h2);
      @(negedge free_clk) dbg_stoptime = 1'b1;
      repeat(4) @(posedge free_clk);
      for (ii = 0; ii < n; ii = ii + 1)
         reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h5A5A5A});
      reg_rd_mask(GPU_STAT, n << 8, 32'hFF00);              // USED
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FLOW);
   end
endtask

task sy_release;
   begin
      @(negedge free_clk) dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      gpu_wait_idle;
   end
endtask

// The exact edge. With the GPU frozen: FILL A (one EXEC word), FENCE, FILL B,
// FENCE, then FENCE fillers; released, A draws (USED = n - 1; a FENCE does not
// pass a busy engine); A done, two words pop (FENCE, B) and B draws.
// late = 0: n = depth / 2 + 3, FREE during B = depth / 2: no event;
// late = 1: n = depth / 2 + 2, FREE during B = depth / 2 + 1: the event
task sy_edge;
   input integer late;
   integer       n, g;
   begin
      n = GPU_FIFO_DEPTH / 2 + (late ? 2 : 3);
      $display("--- FIFO_LOW edge: FREE %0d -> %0d while the GPU draws: %0s", GPU_FIFO_DEPTH - n + 1,
               GPU_FIFO_DEPTH - n + 3, late ? "raised" : "not raised");
      gpu_set_mode(4);
      gpu_c_dst(16'd0, 32'd200);
      gpu_c_size((GPU_DIM_MASK >= 32) ? 14'd32 : GPU_DIM_MASK, (GPU_DIM_MASK >= 24) ? 14'd24 : GPU_DIM_MASK);
      gpu_c_fill(32'h0000_3C5A);
      gpu_wait_idle;
      reg_wr(DBG_CTRL, 32'h2);
      @(negedge free_clk) dbg_stoptime = 1'b1;
      repeat(4) @(posedge free_clk);
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);                // A (op 5 reads D: slow)
      reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h00E001});
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);                // B
      reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h00E002});
      for (g = 4; g < n; g = g + 1)
         reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h00E003});
      reg_rd_mask(GPU_STAT, n << 8, 32'hFF00);
      reg_wr(IRQ_FLAG, IF_FLOW);
      @(negedge free_clk) dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      // A draws
      reg_rd_mask(GPU_STAT, ((n - 1) << 8) | (GPU_FIFO_DEPTH - n + 1) | GS_PRIM_BUSY, 32'hFFFF | GS_PRIM_BUSY);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FLOW);
      // B draws: FREE = depth - n + 3
      g = 0;
      sy_st = 32'h0;
      while ((sy_st[15:8] != n - 3) && (g < 2000)) begin reg_rd_val(GPU_STAT, sy_st); g = g + 1; end
      if (!(sy_st & GS_PRIM_BUSY) || (sy_st[7:0] != GPU_FIFO_DEPTH - n + 3)) begin
         $display("ERROR: GPU_STAT 0x%h: FILL B drawing with FREE = %0d expected (test bug or a pop too many) %t",
                  sy_st, GPU_FIFO_DEPTH - n + 3, $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG, late ? IF_FLOW : 32'h0, IF_FLOW);
      reg_rd_mask(GPU_STAT, GS_PRIM_BUSY | ((n - 3) << 8), GS_PRIM_BUSY | 32'hFF00);   // still B
      gpu_wait_idle;
      reg_rd(GPU_FENCE, 32'h00E003);                             // (n > 4: the fillers ran last)
      reg_wr(IRQ_FLAG, IF_FLOW);
      gpu_check_touched("FIFO_LOW edge fills");
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: FENCE AUTO and GPU_FIFO_LOW       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      //--------------------------------------------------------------
      $display("--- FENCE AUTO: GPU_FENCE + 1, the tag ignored, IRQ, 24-bit wrap");
      reg_wr(IRQ_FLAG, IF_GPU_ALL | IF_FLOW);
      reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h000010});
      for (sy_i = 0; sy_i < 3; sy_i = sy_i + 1)
         reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b0, 8'h00, sy_i[15:0] ^ 16'hBEEF});
      gpu_wait_idle;
      reg_rd(GPU_FENCE, 32'h0000_0013);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FENCE);
      reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b1, 24'h000777});   // AUTO with IRQ
      gpu_wait_idle;
      reg_rd(GPU_FENCE, 32'h0000_0014);
      reg_rd_mask(IRQ_FLAG, IF_FENCE, IF_FENCE);
      reg_wr(IRQ_FLAG, IF_FENCE);
      reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'hFFFFFF});
      reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b0, 24'hFFFFFF});
      gpu_wait_idle;
      reg_rd(GPU_FENCE, 32'h0);
      // through the model task
      gpu_m_fence = 24'h0;
      for (sy_i = 0; sy_i < 5; sy_i = sy_i + 1) gpu_c_fence_auto(sy_i[0]);
      gpu_wait_idle;
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});

      //--------------------------------------------------------------
      if (VRAM_WORDS < 72)
         $display("--- (VRAM_WORDS < 72: the list of AUTO fences not run)");
      else begin
      $display("--- a list of AUTO fences replayed: GPU_FENCE never goes back");
      // list: FILL a few pixels, FENCE AUTO, FILL, FENCE AUTO
      gpu_c_dst(16'd64, 32'd64);
      gpu_c_size(14'd8, 14'd2);
      gpu_c_fill(32'h0000_1234);
      sy_t = {OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h000001};
      vram_wr(4 * SY_LLO,       gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000), SZ_W);
      vram_wr(4 * (SY_LLO + 1), sy_t, SZ_W);
      vram_wr(4 * (SY_LLO + 2), gpu_exec_word(GPU_FILL, 4'd5, 3'b000, 3'b000), SZ_W);
      vram_wr(4 * (SY_LLO + 3), sy_t, SZ_W);
      reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h000100});
      gpu_wait_idle;
      sy_prev = 24'h000100;
      sy_mono = 1'b1;
      sy_exp  = 32'h100;
      for (sy_i = 0; sy_i < 6; sy_i = sy_i + 1) begin
         gpu_push({OP_CALL, 4'h0, 24'd4});
         gpu_push(SY_LLO);
         sy_exp = sy_exp + 2;
         if (sy_i[0]) begin
            gpu_push({OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h0});       // between the calls
            sy_exp = sy_exp + 1;
         end
      end
      gpu_wait_idle;
      sy_mono = 1'b0;
      reg_rd(GPU_FENCE, sy_exp);
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      end

      //--------------------------------------------------------------
      $display("--- GPU_FIFO_LOW: FREE rising above half the FIFO (%0d words)", GPU_FIFO_DEPTH);
      reg_wr(IRQ_EN, 32'hFFFF_FFFF);
      reg_rd(IRQ_EN, 32'h0000_07F7);
      reg_wr(IRQ_EN, IF_FLOW);
      reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FLOW);
      sy_irq_chk(1'b0);
      reg_rd_val(GPU_FENCE, sy_t);
      sy_n = GPU_FIFO_DEPTH / 2 + 2;
      sy_fill(sy_n);
      sy_irq_chk(1'b0);
      sy_release;
      reg_rd_mask(IRQ_FLAG, IF_FLOW, IF_FLOW);
      sy_irq_chk(1'b1);
      reg_rd(GPU_FENCE, (sy_t + sy_n) & 32'h00FF_FFFF);
      reg_wr(IRQ_FLAG, IF_FLOW);                                 // W1C
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FLOW);
      sy_irq_chk(1'b0);
      repeat(50) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FLOW);                     // no re-fire while low

      $display("--- below half all along: no event; refilled: one again");
      sy_fill(GPU_FIFO_DEPTH / 2 - 1);
      sy_release;
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FLOW);
      sy_fill(GPU_FIFO_DEPTH);
      sy_release;
      reg_rd_mask(IRQ_FLAG, IF_FLOW, IF_FLOW);
      reg_wr(IRQ_FLAG, IF_FLOW);

      $display("--- ABORT from above half: the FIFO emptied raises it");
      sy_fill(GPU_FIFO_DEPTH / 2 + 1);
      reg_wr(GPU_CTRL, 32'h2);
      repeat(4) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, IF_FLOW, IF_FLOW);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | 32'hFF00);
      sy_release;
      reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
      reg_wr(IRQ_EN, 32'h0);
      sy_irq_chk(1'b0);

      //--------------------------------------------------------------
      if (VRAM_WORDS < 1000)
         $display("--- (VRAM_WORDS < 1000: no rectangle long enough for the exact FIFO_LOW edge)");
      else
         for (sy_i = 0; sy_i < 2; sy_i = sy_i + 1)
            sy_edge(sy_i);
      $display("INFO:  %0d GPU_FIFO_LOW events, %0d FREE crossings of depth / 2", sy_nev, sy_ncr);
      // 3 events before the exact-edge part, at least 1 more in it (not run below 1000 words)
      if (sy_nev < ((VRAM_WORDS < 1000) ? 3 : 4)) tb_error("gpu_sync: too few GPU_FIFO_LOW events (test bug)");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
