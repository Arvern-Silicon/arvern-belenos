//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_ext2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_ext2.v
// Module Description : SET_EXT2 codes. WAIT_REFR_DONE: the commands after it
//                      wait for the end of a frame sent to the panel (the one
//                      in progress, else the next), with GPU_STAT.WAIT and
//                      BUSY set and no GPU_IDLE meanwhile; a frame ending in
//                      the cycle the wait reaches the decoder counts, one
//                      ending before does not (bench-driven frames,
//                      DIF_TYPE = 0); CLEAR_ERR, ABORT and GPU_EN = 0 end it
//                      (the commands behind it flushed; ABORT also in ERR, a
//                      wait armed behind a rectangle past the VRAM); a debug freeze over
//                      the frame end holds it until released; inside a CALL
//                      list; with run-ahead, the primitive before it still
//                      draws. RESET_STATE: every setting back to its reset
//                      value (decoder registers read through the hierarchy),
//                      then a FILL with the defaults; with run-ahead, the
//                      settings decoded while a gradient FILL draws do not
//                      reach it. Frames: bench-driven at DIF_TYPE = 0, a
//                      manual refresh of a one-line display with DBI, the
//                      first frame of a DPI run (stopped after it) with DPI.
//                      The RESET_STATE register probes and the arming-edge
//                      cycle read from the hierarchy are micro-architectural
//                      regression checks; gpu_retain checks the reset values
//                      and what RESET_STATE keeps through the drawing.
//----------------------------------------------------------------------------
`include "gpu_model.v"

`define EX_GPU dut.u_core.G_GPU.u_gpu
`define EX_DEC dut.u_core.G_GPU.u_gpu.u_dec

localparam integer EX_DISPW = (DIF_TYPE == 0) ? 16 : 64;   // one-line display: short refreshes
localparam integer EX_W0    = 2000;             // destination words [2000, 3000)
localparam integer EX_LIST  = 1000;             // command list words

integer    ex_cyc, ex_done_n, ex_done_cyc, ex_wr_n, ex_first_wr, ex_arm_cyc;
reg        ex_watch;
integer    ex_k, ex_d, ex_n0, ex_w0, ex_hit, ex_miss;
reg [23:0] ex_n24;

initial begin
   ex_cyc = 0; ex_done_n = 0; ex_done_cyc = -1; ex_wr_n = 0; ex_first_wr = -1; ex_arm_cyc = -1; ex_watch = 1'b0;
end

// Frames ended, GPU VRAM writes, the first write and the arming cycle once watched
always @(posedge free_clk) begin
   ex_cyc = ex_cyc + 1;
   if (dut.u_core.u_regs.refr_done_evt_o === 1'b1) begin
      ex_done_n   = ex_done_n + 1;
      ex_done_cyc = ex_cyc;
   end
   if ((GPU_EN != 0) && (`EX_GPU.dma_vgnt === 1'b1) && (`EX_GPU.dma_vwe === 1'b1)) begin
      ex_wr_n = ex_wr_n + 1;
      if (ex_watch && (ex_first_wr < 0)) ex_first_wr = ex_cyc;
   end
   if ((GPU_EN != 0) && ex_watch && (ex_arm_cyc < 0) && (`EX_DEC.refr_armed === 1'b1)) ex_arm_cyc = ex_cyc - 1;
end

// DPI: a frame is the first one of a run, which stops once it has ended
task ex_dpi_start;
   begin
      reg_wr(DIF_CFG, 32'h0000_0008);
   end
endtask

task ex_dpi_stop;
   begin
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 4000);
   end
endtask

// A frame: started (bench-driven, a manual refresh or a DPI run), ended after
// 'hold' cycles (bench-driven) or when the PHY is done; returns once it has ended
task ex_frame;
   input integer hold;
   integer n;
   begin
      n = ex_done_n;
      if (DIF_TYPE == 0) begin
         @(posedge free_clk);
         bdi_refresh_active_drv = 1'b1;
         repeat(hold) @(posedge free_clk);
         bdi_refresh_active_drv = 1'b0;
      end else if (HAS_DPI)
         ex_dpi_start;
      else
         reg_wr(REFRESH, 32'h0000_0001);
      while (ex_done_n == n) @(posedge free_clk);
      if (HAS_DPI) ex_dpi_stop;
      repeat(3) @(posedge free_clk);
   end
endtask

task ex_watch_on;
   begin
      ex_watch    = 1'b1;
      ex_first_wr = -1;
      ex_arm_cyc  = -1;
   end
endtask

// A small FILL, modelled, into word w (16 bpp)
task ex_fill;
   input integer w;
   input [15:0] c;
   begin
      gpu_c_fill(c);
      gpu_c_size(14'd2, 14'd1);
      gpu_c_dst(16'd0, 2 * w);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
   end
endtask

// Waiting: nothing written, WAIT and BUSY set, no GPU_IDLE
task ex_still_waiting;
   input [8*24-1:0] what;
   input integer    wr0;
   begin
      if (ex_wr_n != wr0) begin
         $display("ERROR: %0s: %0d GPU writes while waiting for a frame end %t", what, ex_wr_n - wr0, $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, GS_WAIT | GS_BUSY, GS_WAIT | GS_BUSY | GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_IDLE | IF_ERR);
   end
endtask

task ex_released;
   input [8*24-1:0] what;
   begin
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_WAIT | GS_ERR);
      if ((ex_first_wr >= 0) && (ex_first_wr <= ex_done_cyc)) begin
         $display("ERROR: %0s: first write at cycle %0d, the frame ended at %0d %t", what, ex_first_wr, ex_done_cyc, $time);
         error = error + 1;
      end
      ex_watch = 1'b0;
      gpu_check_all(what);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

// Every decoder setting at its reset value
task ex_check_reset;
   begin
      if ((`EX_DEC.src_pitch !== 16'h0) || (`EX_DEC.src_fmt !== 4'h0) || (`EX_DEC.src_base !== 0) ||
          (`EX_DEC.dst_pitch !== 16'h0) || (`EX_DEC.xy_pitch_q !== 16'h0) || (`EX_DEC.xy_mode !== 1'b0) ||
          (`EX_DEC.origin !== 0) || (`EX_DEC.cur_x !== 16'h0) || (`EX_DEC.cur_y !== 16'h0) ||
          (`EX_DEC.dst_base !== 0) || (`EX_DEC.clip !== 48'h800800_7FF7FF) || (`EX_DEC.tex_rstep !== 32'h0) ||
          (`EX_DEC.tex_box !== 24'h0) || (`EX_DEC.grad !== 19'h0) || (`EX_DEC.grad_rgb !== 30'h0) ||
          (`EX_DEC.tri_v0 !== 32'h0) || (`EX_DEC.tri_v1 !== 32'h0) || (`EX_DEC.tri_v2 !== 32'h0) ||
          (`EX_DEC.alpha !== 9'h0) || (`EX_DEC.fill !== 16'h0) || (`EX_DEC.transp !== 16'h0) ||
          (`EX_DEC.tex_cfg !== 22'h0) || (`EX_DEC.tex_uv !== 32'h0) || (`EX_DEC.tex_step !== 32'h0) ||
          (`EX_DEC.width !== 1) || (`EX_DEC.height !== 1)) begin
         $display("ERROR: RESET_STATE: a setting is not at its reset value (fill %h size %0dx%0d grad %h clip %h tex_cfg %h) %t",
                  `EX_DEC.fill, `EX_DEC.width, `EX_DEC.height, `EX_DEC.grad, `EX_DEC.clip, `EX_DEC.tex_cfg, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   GPU: SET_EXT2 WAIT_REFR_DONE, RESET_STATE   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_mode(4);
      reg_wr(DISP_SIZE, 32'h0001_0000 | EX_DISPW);
      gpu_m_dispw = EX_DISPW;
      if (DIF_TYPE == 1)      reg_wr(DIF_CFG, 32'h0000_1005);  // SPI, LCD_ON, HW window
      else if (HAS_DBI)       reg_wr(DIF_CFG, 32'h0000_1001);  // 8080, LCD_ON, HW window
      if (HAS_DPI) begin                                       // a 64 x 1 panel
         reg_wr(DPI_H_ACT, EX_DISPW); reg_wr(DPI_H_BLANK, 2 | (2 << 10) | (2 << 20));
         reg_wr(DPI_V_ACT, 1);        reg_wr(DPI_V_BLANK, 1 | (1 << 10) | (1 << 20));
      end
      reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
      // DIF_TYPE 0: the bench drives bdi_refresh_active_i; like an external
      // driver it holds bdi_busy_i, which keeps the clock requested (ICG builds)
      if (DIF_TYPE == 0) bdi_busy_drv = 1'b1;

      //--------------------------------------------------------------
      $display("--- 1. WAIT_REFR_DONE, no frame in progress: waits for the next one");
      ex_watch_on;
      ex_w0 = ex_wr_n;
      gpu_c_wait_refr;
      ex_fill(EX_W0, 16'h1234);
      repeat(300) @(posedge free_clk);
      ex_still_waiting("no frame yet", ex_w0);
      ex_frame(60);
      ex_released("released by the frame end");

      //--------------------------------------------------------------
      $display("--- 2. WAIT_REFR_DONE reached during a frame: released at its end");
      ex_n0 = ex_done_n;
      if (DIF_TYPE == 0) begin
         @(posedge free_clk);
         bdi_refresh_active_drv = 1'b1;
      end else if (HAS_DPI)
         ex_dpi_start;
      else
         reg_wr(REFRESH, 32'h0000_0001);
      repeat(5) @(posedge free_clk);
      ex_watch_on;
      gpu_c_wait_refr;
      ex_fill(EX_W0 + 2, 16'h2345);
      if (DIF_TYPE == 0) begin
         repeat(100) @(posedge free_clk);
         ex_still_waiting("frame in progress", ex_wr_n);
         bdi_refresh_active_drv = 1'b0;
      end
      while (ex_done_n == ex_n0) @(posedge free_clk);
      if (HAS_DPI) ex_dpi_stop;
      ex_released("released at the end of the frame in progress");

      //--------------------------------------------------------------
      if (DIF_TYPE == 0) begin
         $display("--- 3. a frame ending around the cycle the wait reaches the decoder");
         ex_hit  = 0;
         ex_miss = 0;
         for (ex_d = 0; ex_d < 24; ex_d = ex_d + 1) begin
            @(posedge free_clk);
            bdi_refresh_active_drv = 1'b1;
            repeat(10) @(posedge free_clk);
            ex_watch_on;
            ex_n0 = ex_done_n;
            fork                                                       // the frame ends d cycles into the push
               gpu_c_wait_refr;
               begin
                  repeat(ex_d) @(posedge free_clk);
                  bdi_refresh_active_drv = 1'b0;
               end
            join
            while (ex_done_n == ex_n0) @(posedge free_clk);
            repeat(20) @(posedge free_clk);
            if (ex_arm_cyc < 0) tb_error("the wait never armed (test bug)");
            reg_rd_val(GPU_STAT, ex_k);
            if ((ex_done_cyc >= ex_arm_cyc) != ((ex_k & GS_WAIT) == 0)) begin
               $display("ERROR: frame end at cycle %0d, wait armed at %0d: GPU_STAT 0x%h %t", ex_done_cyc, ex_arm_cyc, ex_k, $time);
               error = error + 1;
            end
            if ((ex_k & GS_WAIT) != 0) begin
               ex_miss = ex_miss + 1;
               ex_frame(10);
            end else
               ex_hit = ex_hit + 1;
            gpu_wait_idle;
            ex_watch = 1'b0;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
         end
         $display("       %0d released by that frame, %0d waited for the next", ex_hit, ex_miss);
         if ((ex_hit == 0) || (ex_miss == 0))
            tb_error("the sweep did not span the arming cycle (test bug)");
      end

      //--------------------------------------------------------------
      if (DIF_TYPE == 0) begin
         $display("--- 3b. a frame ending while the rectangle before the wait draws counts");
         ex_w0 = gpu_exp_wr;
         gpu_c_fill(16'h1357);
         gpu_c_size(14'd32, 14'd16);
         gpu_c_dst(16'd64, 2 * (EX_W0 + 400));
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         ex_k  = gpu_exp_wr - ex_w0;                                    // its writes
         ex_n0 = ex_wr_n;
         gpu_c_wait_refr;
         ex_fill(EX_W0 + 30, 16'h2468);
         repeat(20) @(posedge free_clk);                                // the FILL is drawing
         if (ex_wr_n - ex_n0 >= ex_k) tb_error("the FILL ended before the frame (test bug)");
         ex_frame(5);
         repeat(600) @(posedge free_clk);
         if (ex_wr_n - ex_n0 != ex_k + 1) begin
            $display("ERROR: frame end during the rectangle before the wait: %0d writes / expected %0d (the wait ignored that frame) %t",
                     ex_wr_n - ex_n0, ex_k + 1, $time);
            error = error + 1;
         end
         gpu_wait_idle;
         gpu_check_all("frame end during the rectangle before the wait");
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
      end

      //--------------------------------------------------------------
      $display("--- 4. CLEAR_ERR, ABORT, GPU_EN = 0 end the wait (the commands behind it flushed)");
      for (ex_k = 0; ex_k < 3; ex_k = ex_k + 1) begin
         gpu_c_wait_refr;
         gpu_push(32'h4000_0000);                                     // SET_FILL, then its operand
         gpu_push(32'h0000_5A5A);
         gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000));     // not modelled: must not run
         repeat(50) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_WAIT, GS_WAIT);
         if (ex_k == 0)      reg_wr(GPU_CTRL, 32'h1);
         else if (ex_k == 1) reg_wr(GPU_CTRL, 32'h2);
         else begin
            reg_wr(CTRL, 32'h0);
            gpu_set_mode(4);
         end
         repeat(5) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_EMPTY, GS_WAIT | GS_BUSY | GS_EMPTY | GS_ERR);
         gpu_check_all("wait flushed");
         ex_fill(EX_W0 + 4 + 2 * ex_k, 16'h3456 + ex_k);              // runs at once
         gpu_wait_idle;
         gpu_check_all("after a flushed wait");
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
      end

      //--------------------------------------------------------------
      $display("--- 5. a debug freeze over the frame end: released after the freeze");
      ex_watch_on;
      ex_w0 = ex_wr_n;
      gpu_c_wait_refr;
      ex_fill(EX_W0 + 12, 16'h4567);
      repeat(50) @(posedge free_clk);
      gpu_freeze(1);
      ex_frame(30);
      repeat(50) @(posedge free_clk);
      if (ex_wr_n != ex_w0) begin
         $display("ERROR: written while frozen %t", $time);
         error = error + 1;
      end
      gpu_freeze(0);
      ex_released("released after a freeze");

      //--------------------------------------------------------------
      $display("--- 6. WAIT_REFR_DONE inside a CALL list");
      gpu_wait_idle;
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_c_wait_refr;
      ex_fill(EX_W0 + 14, 16'h5678);
      gpu_c_fence(1'b1);
      gpu_cap_en = 1'b0;
      for (ex_k = 0; ex_k < gpu_cap_n; ex_k = ex_k + 1) begin
         vram_mem[EX_LIST + ex_k]   = gpu_cap_buf[ex_k];
         gpu_shadow[EX_LIST + ex_k] = gpu_cap_buf[ex_k];
      end
      ex_n24 = gpu_cap_n;
      ex_watch_on;
      ex_w0 = ex_wr_n;
      gpu_push({OP_CALL, 4'h0, ex_n24});
      gpu_push(EX_LIST);
      repeat(300) @(posedge free_clk);
      ex_still_waiting("in a list", ex_w0);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_FENCE);
      ex_frame(40);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_FENCE, IF_FENCE);
      ex_released("released in a list");

      //--------------------------------------------------------------
      if (GPU_RUNAHEAD_EN != 0) begin
         $display("--- 7. run-ahead: the FILL before the wait draws, the one after waits");
         ex_w0 = gpu_exp_wr;
         gpu_c_fill(16'h6789);
         gpu_c_size(14'd32, 14'd8);
         gpu_c_dst(16'd64, 2 * (EX_W0 + 100));
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         ex_k  = gpu_exp_wr - ex_w0;                                    // its writes
         ex_n0 = ex_wr_n;
         gpu_c_wait_refr;
         ex_fill(EX_W0 + 16, 16'h789A);
         repeat(1000) @(posedge free_clk);
         if (ex_wr_n - ex_n0 != ex_k) begin
            $display("ERROR: run-ahead + wait: %0d writes / expected %0d (the FILL before the wait only) %t",
                     ex_wr_n - ex_n0, ex_k, $time);
            error = error + 1;
         end
         reg_rd_mask(GPU_STAT, GS_WAIT, GS_WAIT);
         ex_watch_on;
         ex_frame(20);
         ex_released("run-ahead + wait");
      end

      //--------------------------------------------------------------
      $display("--- 8. RESET_STATE: every setting back to its reset value");
      gpu_push({OP_SET_SRC, 8'h0, 4'h0, 16'h0123});  gpu_push(32'h0000_0456);
      gpu_push({OP_SET_DST, 12'h0, 16'h0077});       gpu_push(32'h0000_0789);
      gpu_push({OP_SET_SIZE, 14'd5, 14'd6});
      gpu_push({OP_SET_FILL, 28'h0});                gpu_push(32'h0000_ABCD);
      gpu_push({OP_SET_TRANSP, 28'h0});              gpu_push(32'h0000_1357);
      gpu_push({OP_SET_EXT, EXT_SET_TEX, 24'h12_1F33});
      gpu_push({OP_SET_EXT, EXT_SET_UV, 24'h0});     gpu_push(32'h1234_5678);
      gpu_push({OP_SET_EXT, EXT_SET_STEP, 24'h0});   gpu_push(32'h0101_0202);
      if (GPU_XY_EN != 0) begin
         gpu_push({OP_SET_DST, 11'h0, 1'b1, 16'h0040}); gpu_push(32'h0000_0100);     // x/y mode
         gpu_push({OP_SET_EXT, EXT_SET_XY, 24'h005_007});
         gpu_push({OP_SET_EXT, EXT_SET_CLIP, 24'h001_002}); gpu_push(32'h0030_0040);
      end
      if (GPU_XY_EN != 0) begin                                         // affine blit
         gpu_push({OP_SET_EXT, 4'h5, 24'h0});        gpu_push(32'h0303_0404);    // SET_STEP_ROW
         gpu_push({OP_SET_EXT, 4'h6, 24'h010_020});                               // SET_TEXBOX
      end
      if (GPU_GRAD_EN != 0) begin
         gpu_push({OP_SET_EXT, EXT_SET_GRGB, 24'h0}); gpu_push(32'h0123_4567);
         gpu_push({OP_SET_EXT, EXT_SET_GRAD, 5'h00, 19'h7_3003});
      end
      if (GPU_BLEND_EN != 0)
         gpu_push({OP_SET_EXT, 4'h8, 24'h0001_80});                               // SET_ALPHA
      if ((GPU_TRI_EN != 0) && (GPU_XY_EN != 0)) begin
         gpu_push({OP_SET_EXT, 4'h9, 24'h0}); gpu_push(32'h0010_0020);
         gpu_push({OP_SET_EXT, 4'hA, 24'h0}); gpu_push(32'h0030_0040);
         gpu_push({OP_SET_EXT, 4'hB, 24'h0}); gpu_push(32'h0050_0060);
      end
      gpu_wait_idle;
      if ((`EX_DEC.fill !== 16'hABCD) || (`EX_DEC.width !== 6)) tb_error("settings not taken (test bug)");
      gpu_c_reset_state;
      gpu_wait_idle;
      ex_check_reset;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      // a FILL with the defaults: 1 x 1 pixel of colour 0 at pixel address 0
      vram_mem[0]   = 32'hFFFF_FFFF;
      gpu_shadow[0] = 32'hFFFF_FFFF;
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_all("FILL after RESET_STATE");
      if (vram_mem[0] !== 32'hFFFF_0000) begin
         $display("ERROR: FILL after RESET_STATE: word 0 = 0x%h / expected 0xFFFF0000 %t", vram_mem[0], $time);
         error = error + 1;
      end

      //--------------------------------------------------------------
      if ((GPU_RUNAHEAD_EN != 0) && (GPU_GRAD_EN != 0)) begin
         $display("--- 9. run-ahead: settings decoded while a gradient FILL draws do not reach it");
         for (ex_k = 0; ex_k < 2; ex_k = ex_k + 1) begin
            gpu_c_grad_rgb(1, 1'b1, 40, -20, 70, 1'b1);
            gpu_c_fill(16'h4208);
            gpu_c_size(14'd40, 14'd12);
            gpu_c_dst(16'd64, 2 * (EX_W0 + 200));
            gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
            gpu_c_grad_rgb(2, 1'b0, -300, 300, -300, 1'b1);            // decoded while it draws
            if (ex_k) gpu_c_reset_state;
            gpu_c_fill(16'h0F0F);
            gpu_c_size(14'd3, 14'd2);
            gpu_c_dst(16'd64, 2 * (EX_W0 + 800));
            gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
            gpu_wait_idle;
            gpu_check_all(ex_k ? "run-ahead + RESET_STATE" : "run-ahead + SET_GRAD_RGB");
         end
      end

      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);

      //--------------------------------------------------------------
      $display("--- 10. an ABORT in ERR ends a wait armed before the error (WAIT clear, ERR kept)");
      gpu_c_size(14'd4, 14'd1);
      gpu_c_dst(16'd0, 2 * VRAM_WORDS);                               // its first word past the VRAM
      gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000));         // ERR_CAUSE 5: nothing written
      gpu_c_wait_refr;                                                 // armed behind it
      repeat(100) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_ERR | GS_WAIT, GS_ERR | GS_WAIT);
      reg_wr(GPU_CTRL, 32'h2);                                         // ABORT
      repeat(5) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_ERR | GS_EMPTY, GS_WAIT | GS_BUSY | GS_EMPTY | GS_ERR);
      reg_wr(GPU_CTRL, 32'h1);                                         // CLEAR_ERR
      repeat(5) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_WAIT | GS_BUSY | GS_EMPTY | GS_ERR);
      gpu_check_all("wait ended by an ABORT in ERR");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
