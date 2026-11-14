//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_irq_icg
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_irq_icg.v
// Module Description : Every interrupt source raises irq_o under the bench
//                      clock gate (BLNS_ICG_EN = 1) with no bus access while
//                      software waits, as a CPU in WFI would: each source
//                      alone in IRQ_EN, the event started by register writes,
//                      then only the irq_o pin watched; once it is high the
//                      clock request must fall (nothing else keeps the
//                      clock running, so the event was not seen by chance;
//                      GPU_ERR: the GPU stays busy in its error state).
//                      Sources: GPU_IDLE, GPU_DONE, GPU_FENCE, GPU_ERR,
//                      GPU_OVFL, GPU_FIFO_LOW (GPU_EN); REFR_START,
//                      REFR_DONE, FRAME_CNT_DONE of a manual refresh (the BDI
//                      model with DIF_TYPE = 0, the DBI driver with 1-3);
//                      DIF from the DBI driver's CMD_DONE, CMD_OVFL and TE
//                      (DIF_TYPE 1-3) and the DPI driver's VBLANK (4, 5). An
//                      armed TE interrupt and a running DPI driver keep the
//                      clock running (their own busy): there only the pin is
//                      checked.
//----------------------------------------------------------------------------
`include "gpu_model.v"
`include "regs_tasks.v"
`include "dpi_tasks.v"

localparam [31:0] QI_RDONE = 32'h001;
localparam [31:0] QI_RSTRT = 32'h002;
localparam [31:0] QI_FCNT  = 32'h004;
localparam [31:0] QI_DIF   = 32'h100;
localparam [31:0] QI_FLOW  = 32'h400;
localparam [31:0] QI_ALL   = 32'h7F7;

integer     qi_k;

// The event has been started: wait for irq_o with no bus access, then for the
// clock request to fall (sampled while the free clock is low)
task qi_wait;
   input [8*24-1:0] what;
   input integer    max_cyc;
   input            idle_after;           // nothing keeps the clock once the event is in
   integer k;
   begin
      k = 0;
      while ((irq !== 1'b1) && (k < max_cyc)) begin
         @(negedge free_clk);
         k = k + 1;
      end
      if (irq !== 1'b1) begin
         $display("ERROR: %0s -- irq_o = %b after %0d cycles without bus access (hclk_en_o = %b) %t",
                  what, irq, k, hclk_en, $time);
         error = error + 1;
      end else if (idle_after) begin
         k = 0;
         while ((hclk_en !== 1'b0) && (k < 5000)) begin
            @(negedge free_clk);
            #2;
            k = k + 1;
         end
         if (hclk_en !== 1'b0) begin
            $display("ERROR: %0s -- irq_o raised, but hclk_en_o stays high: the wait proves nothing %t", what, $time);
            error = error + 1;
         end else
            $display("OK:    %0s raises irq_o with the clock gated", what);
      end else
         $display("OK:    %0s raises irq_o with no bus access", what);
   end
endtask

// One source alone in IRQ_EN, every flag clear
task qi_arm;
   input [31:0] bits;
   begin
      reg_wr(IRQ_FLAG, QI_ALL);
      reg_wr(IRQ_EN, bits);
      reg_rd_mask(IRQ_FLAG, 32'h0, bits);
   end
endtask

task qi_done;
   input [31:0] bits;
   begin
      reg_rd_mask(IRQ_FLAG, bits, bits);
      reg_wr(IRQ_FLAG, bits);
      reg_wr(IRQ_EN, 32'h0);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   IRQ SOURCES UNDER THE CLOCK GATE (NO POLL)  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (ICG_EN == 0)
         tb_skip_finish("|      (needs the bench clock gate: ICG_EN)     |");

      if (GPU_EN != 0) begin
         gpu_seed = `SEED;
         gpu_model_init;
         gpu_set_mode(4);
         gpu_set_dispw(64);

         $display("--- GPU_IDLE: a configuration command");
         qi_arm(IF_IDLE);
         gpu_c_fill(32'h0000_1111);
         qi_wait("GPU_IDLE", 500, 1'b1);
         qi_done(IF_IDLE);

         $display("--- GPU_DONE: an EXEC");
         gpu_c_size(14'd8, 14'd2);
         gpu_wait_idle;
         qi_arm(IF_DONE);
         gpu_c_exec(GPU_FILL, 4'd3, 3'b000, 3'b000);
         qi_wait("GPU_DONE", 2000, 1'b1);
         qi_done(IF_DONE);

         $display("--- GPU_FENCE: a FENCE with IRQ");
         qi_arm(IF_FENCE);
         gpu_c_fence(1'b1);
         qi_wait("GPU_FENCE", 500, 1'b1);
         qi_done(IF_FENCE);

         $display("--- GPU_ERR: an invalid opcode");
         qi_arm(IF_ERR);
         gpu_push(32'h0000_0000);
         qi_wait("GPU_ERR", 500, 1'b0);
         qi_done(IF_ERR);
         reg_wr(GPU_CTRL, 32'h1);                      // CLEAR_ERR
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, QI_ALL);

         $display("--- GPU_OVFL: a command pushed with GPU_EN = 0");
         qi_arm(IF_OVFL);
         reg_wr(CTRL, 32'h4);
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
         qi_wait("GPU_OVFL", 500, 1'b1);
         qi_done(IF_OVFL);
         gpu_set_mode(4);

         $display("--- GPU_FIFO_LOW: the FIFO drains below half");
         gpu_c_size(14'd40, 14'd20);
         gpu_wait_idle;
         qi_arm(QI_FLOW);
         // two long fills ahead (with run-ahead the second one is set up while
         // the first draws and holds the decoder), then the FIFO filled (each
         // push waits for a free word)
         gpu_push_wait = 1'b1;
         gpu_c_exec(GPU_FILL, 4'd3, 3'b000, 3'b000);
         gpu_c_exec(GPU_FILL, 4'd3, 3'b000, 3'b000);
         for (qi_k = 0; qi_k < GPU_FIFO_DEPTH; qi_k = qi_k + 1)
            gpu_c_fill(32'h0000_2222);
         gpu_push_wait = 1'b0;
         qi_wait("GPU_FIFO_LOW", 40000, 1'b1);
         qi_done(QI_FLOW);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, QI_ALL);
      end

      if ((DIF_TYPE <= 3) && (VRAM_WORDS >= 64)) begin
         // A small 16 bpp frame at pixel 0
         reg_wr(CTRL,       {27'h0, (GPU_EN != 0), 1'b0, GFX_16BPP});
         reg_wr(DISP_SIZE,  (32'd2 << 16) | 32'd4);
         reg_wr(FRAME0_PTR, 32'h0000_0000);
         reg_wr(FRAME_SEL,  32'h0000_0000);
         if (DIF_TYPE == 0) begin
            bm_exp_px = 8;
            bm_auto   = 1'b1;
         end else
            reg_wr(DIF_CFG, 32'h0000_0001);           // LCD_ON, no window, CLK_DIV 0

         $display("--- REFR_START / REFR_DONE / FRAME_CNT_DONE: a manual refresh each");
         qi_arm(QI_RSTRT);
         reg_wr(REFRESH, 32'h0000_0001);
         qi_wait("REFR_START", 5000, 1'b1);
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 5000);
         qi_done(QI_RSTRT);

         qi_arm(QI_RDONE);
         reg_wr(REFRESH, 32'h0000_0001);
         qi_wait("REFR_DONE", 5000, 1'b1);
         qi_done(QI_RDONE);

         reg_wr(FRAME_CNT, 32'd1);
         qi_arm(QI_FCNT);
         reg_wr(REFRESH, 32'h0000_0001);
         qi_wait("FRAME_CNT_DONE", 5000, 1'b1);
         qi_done(QI_FCNT);
         reg_rd(FRAME_CNT, 32'h0);
         if (DIF_TYPE == 0) bm_auto = 1'b0;
      end

      if (HAS_DBI) begin
         $display("--- DIF: the DBI driver's CMD_DONE");
         reg_wr(DIF_IRQ_FLAG, 32'h7);
         reg_wr(DIF_IRQ_EN, 32'h1);
         qi_arm(QI_DIF);
         reg_wr(DIF_CMD, 32'h0000_0000);              // NOP, no parameter
         qi_wait("DIF (CMD_DONE)", 2000, 1'b1);
         reg_rd_mask(IRQ_FLAG, QI_DIF, QI_DIF);
         reg_wr(DIF_IRQ_FLAG, 32'h1);
         reg_rd_mask(IRQ_FLAG, 32'h0, QI_DIF);
         reg_wr(DIF_IRQ_EN, 32'h0);
         reg_wr(IRQ_EN, 32'h0);

         $display("--- DIF: the DBI driver's CMD_OVFL (a parameter written to the full FIFO)");
         reg_wr(DIF_IRQ_EN, 32'h4);
         qi_arm(QI_DIF);
         for (qi_k = 0; qi_k < 17; qi_k = qi_k + 1)
            reg_wr(DIF_PARAM, 32'h0000_0000);
         qi_wait("DIF (CMD_OVFL)", 200, 1'b1);
         reg_wr(DIF_CMD, 32'h0000_1000);              // drain: a NOP with the 16 parameters
         reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 5000);
         reg_wr(DIF_STATUS, 32'h80);
         reg_wr(DIF_IRQ_FLAG, 32'h7);
         reg_rd_mask(IRQ_FLAG, 32'h0, QI_DIF);
         reg_wr(DIF_IRQ_EN, 32'h0);
         reg_wr(IRQ_EN, 32'h0);

         $display("--- DIF: the DBI driver's TE (the armed TE interrupt keeps the clock)");
         reg_wr(DIF_IRQ_EN, 32'h2);
         qi_arm(QI_DIF);
         repeat(20) @(posedge free_clk);
         lcd_te = 1'b1;
         qi_wait("DIF (TE)", 200, 1'b0);
         lcd_te = 1'b0;
         reg_wr(DIF_IRQ_FLAG, 32'h7);
         reg_wr(DIF_IRQ_EN, 32'h0);
         reg_wr(IRQ_EN, 32'h0);
      end

      if (DIF_TYPE >= 4) begin
         $display("--- DIF: the DPI driver's VBLANK (the running driver keeps the clock)");
         dpi_timing(2, 40, 2, 3, 5, 20, 1, 2, 2);
         reg_wr(DIF_IRQ_FLAG, 32'h78);
         reg_wr(DIF_IRQ_EN, 32'h08);
         qi_arm(QI_DIF);
         reg_wr(DIF_CFG, 32'h0000_0209);              // LCD_ON, DPI_EN, CLK_DIV 2
         qi_wait("DIF (DPI VBLANK)", 100000, 1'b0);
         reg_wr(DIF_CFG, 32'h0000_0201);
         reg_wr(DIF_IRQ_EN, 32'h0);
         reg_wr(IRQ_EN, 32'h0);
         reg_poll(DIF_STATUS, 32'h1, 32'h0, 20000);   // stopped
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
