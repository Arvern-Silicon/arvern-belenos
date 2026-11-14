//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_pclk_stop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_pclk_stop.v
// Module Description : DPI driver with its own pixel clock (DPI_PCLK_SEP =
//                      1) while that clock stops (a PLL losing lock), the
//                      bus side running:
//                       A. running, clock stopped: an UPDATE stays pending
//                          (UPDATE reads 1, staging writes ignored) and BUSY
//                          stays 1; the clock again: the update is taken and
//                          the image is exact with it;
//                       B. clock stopped, an UPDATE pending, DPI_EN cleared:
//                          BUSY stays 1, UPDATE reads 1 and staging writes
//                          are ignored (the pixel domain may still take the
//                          update); the clock again: BUSY falls, then UPDATE
//                          reads 0 and staging writes are accepted;
//                       C. stopped driver, clock stopped, DPI_EN set: UPDATE
//                          reads 1 and staging writes are ignored until the
//                          clock runs; then the driver runs with the values
//                          staged before, the image exact.
//----------------------------------------------------------------------------

`include "dpi_tasks.v"

reg     [31:0] v;
integer        k;

task pclk_stop;
   begin
      @(negedge dpi_pclk);
      dpi_pclk_stop = 1'b1;
   end
endtask

task pclk_run;
   begin
      dpi_pclk_stop = 1'b0;
   end
endtask

// A register reads `exp` (under mask) in every one of n reads spread over
// `cycles` hclk cycles
task reg_hold;
   input [31:0]  addr, mask, exp;
   input integer n, cycles;
   integer       i;
   begin
      for (i = 0; i < n; i = i + 1) begin
         repeat (cycles / n) @(posedge free_clk);
         reg_rd_mask(addr, exp, mask);
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: pixel clock stopped               |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DPI_PCLK_SEP == 0))
         tb_skip_finish("|   (needs the DPI driver with its own clock)   |");

      dpi_frame_fill(16, 8, 9);
      dpi_timing(dpi_div(1), 40, 3, 2, 6, 20, 2, 1, 2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(3);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "before the clock stops");

      //------------------------------------------------------------------
      $display("--- A. clock stopped while running: UPDATE stays pending");
      u_dpipanel.check = 1'b0;
      reg_wr(DPI_BORDER, 32'h0031_4159);
      pclk_stop;
      reg_wr(DPI_CTRL, 32'h1);
      reg_hold(DPI_CTRL, 32'h1, 32'h1, 10, 4000);            // pending
      reg_hold(DIF_STATUS, 32'h1, 32'h1, 4, 1000);           // BUSY
      reg_wr(DPI_BORDER, 32'h0026_5358);                     // ignored while pending
      reg_rd(DPI_BORDER, 32'h0031_4159);
      reg_wr(DPI_CTRL, 32'h1);                               // again: no effect
      reg_rd_mask(DPI_CTRL, 32'h1, 32'h1);
      pclk_run;
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h314159, "the update taken once the clock runs");
      reg_rd_mask(DIF_STATUS, 32'h1, 32'h1);

      //------------------------------------------------------------------
      $display("--- B. clock stopped, DPI_EN cleared: BUSY stays 1");
      u_dpipanel.check = 1'b0;
      pclk_stop;
      reg_wr(DPI_CTRL, 32'h1);                               // an update pending
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_hold(DIF_STATUS, 32'h1, 32'h1, 10, 4000);          // BUSY until the pixel side stops
      reg_rd_mask(DPI_CTRL, 32'h1, 32'h1);                   // UPDATE 1 until then: staging locked
      reg_wr(DPI_BORDER, 32'h0027_1828);                     // ignored
      reg_rd(DPI_BORDER, 32'h0031_4159);
      pclk_run;
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200 * PCLK_SLOW);
      reg_rd_mask(DPI_CTRL, 32'h0, 32'h1);                   // stopped: UPDATE reads 0
      reg_wr(DPI_BORDER, 32'h0027_1828);                     // accepted
      reg_rd(DPI_BORDER, 32'h0027_1828);

      //------------------------------------------------------------------
      $display("--- C. DPI_EN set with the clock stopped: UPDATE 1 until it runs");
      reg_wr(DPI_BORDER, 32'h0097_9323);                     // staged while stopped
      pclk_stop;
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h8);
      reg_hold(DPI_CTRL, 32'h1, 32'h1, 10, 4000);            // 1 until the driver runs
      reg_hold(DIF_STATUS, 32'h1, 32'h1, 2, 200);
      reg_wr(DPI_BORDER, 32'h0084_6264);                     // ignored until then
      reg_rd(DPI_BORDER, 32'h0097_9323);
      pclk_run;
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h979323, "started with the clock stopped");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);              // no UNDERFLOW
      reg_rd_val(DPI_FRAMES, v);
      if (v < 4) tb_error("DPI_FRAMES does not count after the clock came back");

      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      u_dpipanel.check = 1'b0;
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200 * PCLK_SLOW);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
