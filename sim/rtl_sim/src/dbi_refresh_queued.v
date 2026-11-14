//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_refresh_queued
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_refresh_queued.v
// Module Description : Manual REFRESH.START written while a frame is being
//                      sent: the driver queues the request, and START clears
//                      only when that queued frame is done, not at the end
//                      of the frame in progress. Also with a second request
//                      written during the queued frame, and with a request
//                      written while the driver is idle.
//----------------------------------------------------------------------------
`include "dbi_model_ext.v"

`define RQ_REFR tb_belenos.dut.u_core.u_regs.u_refresh

integer done_cnt;
integer case_i;
reg     cnt_on;

always @(posedge `RQ_REFR.hclk_i)
   if (cnt_on & `RQ_REFR.refr_done_evt_o) done_cnt = done_cnt + 1;

// Write START, wait for the frame it starts or joins, write START again after
// `extra` frames have started, then expect START to clear on frame `want`.
task wait_active;
   begin
      while (`RQ_REFR.refresh_active_i !== 1'b1) @(posedge free_clk);
      repeat (20) @(posedge free_clk);
   end
endtask

task check_start_clear;
   input integer want;
   input [8*24-1:0] what;
   begin
      reg_poll(REFRESH, 32'h1, 32'h0, 200000);
      if (done_cnt !== want) begin
         $display("ERROR: %0s: START cleared after %0d frame(s) done, expected %0d", what, done_cnt, want);
         error = error + 1;
      end else
         $display("PASS:  %0s: START cleared after %0d frame(s) done", what, done_cnt);
      dif_wait_idle(200000);
      cnt_on = 1'b0;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DBI: MANUAL REFRESH WHILE BUSY         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");
      cnt_on = 1'b0;
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);
      dif_cfg(HAS_8080 ? PHY_8080 : PHY_SPI, 4'd0, 1'b0, 1'b1, 1'b0);
      reg_wr(DISP_SIZE, (12 << 16) | 16);
      reg_wr(CTRL, {29'h0, GFX_16BPP});

      // 1. idle driver: START clears on its own frame
      done_cnt = 0; cnt_on = 1'b1;
      reg_wr(REFRESH, 32'h0000_0001);
      check_start_clear(1, "idle request");

      // 2. request written while frame A is sent: START clears on frame B
      reg_wr(REFRESH, 32'h0000_0001);
      wait_active;
      done_cnt = 0; cnt_on = 1'b1;
      reg_wr(REFRESH, 32'h0000_0001);
      check_start_clear(2, "queued request");

      // 3. as 2, plus a third request written while the queued frame B is sent
      reg_wr(REFRESH, 32'h0000_0001);
      wait_active;
      done_cnt = 0; cnt_on = 1'b1;
      reg_wr(REFRESH, 32'h0000_0001);
      while (done_cnt == 0) @(posedge free_clk);
      wait_active;
      reg_wr(REFRESH, 32'h0000_0001);
      check_start_clear(3, "request during queued");

      // 4. a second request once the driver has taken the first (its window commands
      //    are going out) but before that frame has started: two frames, START
      //    clears on the second
      dif_cfg(HAS_8080 ? PHY_8080 : PHY_SPI, 4'd7, 1'b1, 1'b1, 1'b0);
      done_cnt = 0; cnt_on = 1'b1;
      reg_wr(REFRESH, 32'h0000_0001);
      while (`RQ_REFR.refresh_active_i === 1'b1) @(posedge free_clk);
      repeat (12) @(posedge free_clk);         // the driver is sending CASET/PASET
      if (`RQ_REFR.refresh_active_i === 1'b1)
         tb_error("case 4: the frame started before the second request");
      reg_wr(REFRESH, 32'h0000_0001);
      check_start_clear(2, "request while taken");

      repeat (20) @(posedge free_clk);         // hclk stops once idle with the clock gate
      stimulus_done = 1'b1;
   end
