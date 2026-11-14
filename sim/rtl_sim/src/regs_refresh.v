//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_refresh
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_refresh.v
// Module Description : Refresh pacing, observed
//                      on bdi_refresh_trig_o with the bench BDI driver model
//                      (DIF_TYPE = 0):
//                      - period mode: the first trigger exactly PERIOD
//                        cycles after the REFRESH write, then exactly PERIOD
//                        cycles between two triggers, each pulse one cycle
//                        wide, for several periods, with and without frames
//                        in flight; START = 0 stops the triggers; PERIOD 1
//                        requests in every cycle; a REFRESH write restarts
//                        the count (same and new PERIOD);
//                      - manual mode (PERIOD = 0): exactly one trigger per
//                        START write, START reads 1 until the refresh done
//                        (falling edge of bdi_refresh_active_i), then 0; a
//                        refresh done without a pending START changes nothing;
//                      - FRAME_CNT counts refresh done down to 0 and raises
//                        FRAME_CNT_DONE once, in period mode with frames;
//                      - DBG_CTRL[0] & dbg_stoptime_i: the period timer holds
//                        (the interval containing a freeze of F cycles is
//                        PERIOD + F), FRAME_CNT holds; stoptime alone,
//                        DBG_CTRL[0] alone or DBG_CTRL[1] change nothing;
//                        a frame ending during the freeze is not counted
//                        (FRAME_CNT unchanged after the release, no
//                        FRAME_CNT_DONE) but REFR_START / REFR_DONE and
//                        FRAME_NUM count it; a manual START is served
//                        while frozen.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

integer     f_i, f_n0, f_p, f_k, f_t0, f_t1, f_iv, f_bad;
reg  [31:0] f_rd;

// REFRESH write completion edges and trigger edges on one cycle count: the
// write's address phase is seen on the bus, its zero-wait data phase ends
// at the next edge, where the register takes the value
integer     f_cyc, f_wr_cyc, f_tr_n;
integer     f_tr_cyc [0:63];
reg         f_aph;
initial begin f_cyc = 0; f_wr_cyc = -1; f_tr_n = 0; f_aph = 1'b0; end
always @(posedge hclk) begin
   f_cyc = f_cyc + 1;
   if (f_aph && (r_hready === 1'b1)) begin f_wr_cyc = f_cyc; f_aph = 1'b0; end
   if ((r_hsel_d === 1'b1) && (r_htrans_d[1] === 1'b1) && (r_hwrite_d === 1'b1) &&
       (r_haddr_d[11:0] == REFRESH[11:0]) && (r_hready === 1'b1)) f_aph = 1'b1;
   if ((hresetn_d === 1'b1) && (bdi_refresh_trig === 1'b1)) begin
      if (f_tr_n < 64) f_tr_cyc[f_tr_n] = f_cyc;
      f_tr_n = f_tr_n + 1;
   end
end

// The first trigger after the last REFRESH write comes exactly p cycles after it
task f_chk_first;
   input integer p;
   begin
      if ((f_tr_n < 1) || (f_tr_cyc[0] - f_wr_cyc != p)) begin
         $display("ERROR: first refresh trigger %0d cycles after the REFRESH write / expected PERIOD %0d %t",
                  (f_tr_n < 1) ? -1 : f_tr_cyc[0] - f_wr_cyc, p, $time);
         error = error + 1;
      end
   end
endtask

// Reset the trigger recorder between hclk edges
task f_rec_reset;
   begin
      @(negedge free_clk);
      bm_trig_n    = 0;
      bm_trig_wide = 0;
      f_tr_n       = 0;
   end
endtask

// Wait (bounded) until at least n triggers were recorded
task f_wait_trig;
   input integer n;
   input integer max_cycles;
   integer k;
   begin
      k = 0;
      while ((bm_trig_n < n) && (k < max_cycles)) begin
         @(posedge free_clk);
         k = k + 1;
      end
      if (bm_trig_n < n) begin
         $display("ERROR: %0d refresh triggers after %0d cycles / expected %0d %t", bm_trig_n, k, n, $time);
         error = error + 1;
      end
   end
endtask

// Check that the recorded intervals [first, last) all equal p
task f_chk_intervals;
   input integer first;
   input integer last;
   input integer p;
   input integer stretch_idx;     // interval index that may be p + stretch (-1: none)
   input integer stretch;
   integer k, iv, e;
   begin
      for (k = first; (k < last) && (k + 1 < bm_trig_n) && (k + 1 < 256); k = k + 1) begin
         iv = bm_trig_cyc[k+1] - bm_trig_cyc[k];
         e  = (k == stretch_idx) ? (p + stretch) : p;
         if (iv != e) begin
            $display("ERROR: refresh trigger interval %0d = %0d cycles / expected %0d (PERIOD %0d) %t", k, iv, e, p, $time);
            error = error + 1;
         end
      end
      if (bm_trig_wide != 0) begin
         $display("ERROR: bdi_refresh_trig_o high for more than one cycle (%0d times) %t", bm_trig_wide, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|            REGS: REFRESH PACING               |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|   (DIF_TYPE != 0: BDI inputs not drivable)    |");

      reg_wr(CTRL,      {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, 32'h0002_0004);              // 4 x 2 frame
      bm_exp_px = 8;

      //------------------------------------------------------------------
      // Period mode, no frames
      //------------------------------------------------------------------
      for (f_k = 0; f_k < 6; f_k = f_k + 1) begin
         f_p = (f_k == 0) ? 2 : (f_k == 1) ? 3 : (f_k == 2) ? 7 : (f_k == 3) ? 50 : (f_k == 4) ? 333 : 16;
         f_rec_reset;
         f_t0 = bm_cyc;
         reg_wr(REFRESH, (f_p << 4) | 1);
         f_wait_trig(8, 12 * f_p + 50);
         f_chk_intervals(0, 7, f_p, -1, 0);
         f_chk_first(f_p);
         reg_rd(REFRESH, (f_p << 4) | 1);
         // START = 0 stops the triggers
         reg_wr(REFRESH, f_p << 4);
         repeat (2) @(posedge free_clk);
         f_n0 = bm_trig_n;
         repeat (3 * f_p + 10) @(posedge free_clk);
         if (bm_trig_n != f_n0) begin
            $display("ERROR: %0d refresh triggers after START = 0 (PERIOD %0d) %t", bm_trig_n - f_n0, f_p, $time);
            error = error + 1;
         end
      end
      $display("OK:    period mode intervals");

      // PERIOD = 1: a request in every cycle, from the cycle after the write
      // until the write of START = 0
      f_rec_reset;
      reg_wr(REFRESH, (1 << 4) | 1);
      repeat (20) @(posedge free_clk);
      @(negedge free_clk);
      f_t0 = f_cyc;
      f_chk_first(1);
      for (f_i = 0; (f_i < f_tr_n - 1) && (f_i < 63); f_i = f_i + 1)
         if (f_tr_cyc[f_i+1] != f_tr_cyc[f_i] + 1) begin
            $display("ERROR: PERIOD 1: no request in cycle %0d after the write %t", f_tr_cyc[f_i] + 1 - f_wr_cyc, $time);
            error = error + 1;
         end
      if (f_tr_cyc[f_tr_n - 1] != f_t0) tb_error("PERIOD 1: requests stopped while START = 1");
      reg_wr(REFRESH, 32'h0);
      repeat (4) @(posedge free_clk);
      if (f_tr_cyc[f_tr_n - 1] != f_wr_cyc)
         tb_error("PERIOD 1: requests after the write of START = 0");

      // A REFRESH write restarts the count: a new PERIOD, then the same
      // PERIOD again, each written part-way through an interval
      for (f_k = 0; f_k < 2; f_k = f_k + 1) begin
         f_rec_reset;
         reg_wr(REFRESH, (40 << 4) | 1);
         f_wait_trig(2, 200);
         repeat (13) @(posedge free_clk);
         f_rec_reset;
         f_p = (f_k == 0) ? 25 : 40;
         reg_wr(REFRESH, (f_p << 4) | 1);
         f_wait_trig(4, 400);
         f_chk_first(f_p);
         f_chk_intervals(0, 3, f_p, -1, 0);
         reg_wr(REFRESH, 32'h0);
      end
      $display("OK:    first request, PERIOD 1, restart on a REFRESH write");

      //------------------------------------------------------------------
      // Period mode with frames (driver model): intervals unchanged, flags
      //------------------------------------------------------------------
      bm_auto = 1'b1; bm_rise_delay = 3; bm_fall_delay = 2;
      reg_wr(IRQ_FLAG, 32'h1F7);
      reg_wr(FRAME_CNT, 32'd3);
      f_rec_reset;
      f_n0 = bm_frames;
      reg_wr(REFRESH, (60 << 4) | 1);
      f_wait_trig(7, 600);
      f_chk_intervals(0, 6, 60, -1, 0);
      repeat (60) @(posedge free_clk);
      reg_wr(REFRESH, 32'h0);
      repeat (80) @(posedge free_clk);
      if (bm_frames - f_n0 < 6) begin
         $display("ERROR: %0d frames framed by the model / expected >= 6 %t", bm_frames - f_n0, $time);
         error = error + 1;
      end
      if (bm_px_bad_last != 0) tb_error("bdi_px_last_o not on pixel width x height");
      reg_rd(FRAME_CNT, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h7, 32'h7);           // REFR_DONE, REFR_START, FRAME_CNT_DONE
      reg_wr(IRQ_FLAG, 32'h1F7);

      // Short period: triggers keep their period while frames run longer
      reg_wr(DISP_SIZE, 32'h0008_0008);            // 64-pixel frame
      bm_exp_px = 64;
      f_rec_reset;
      reg_wr(REFRESH, (10 << 4) | 1);
      f_wait_trig(12, 400);
      reg_wr(REFRESH, 32'h0);
      f_chk_intervals(0, 11, 10, -1, 0);
      repeat (300) @(posedge free_clk);
      if (bm_px_bad_last != 0) tb_error("bdi_px_last_o not on pixel width x height (8x8)");
      bm_auto = 1'b0;
      reg_wr(DISP_SIZE, 32'h0002_0004);
      bm_exp_px = 8;
      $display("OK:    period mode with frames");

      //------------------------------------------------------------------
      // Manual mode
      //------------------------------------------------------------------
      reg_wr(IRQ_FLAG, 32'h1F7);
      bm_auto = 1'b1; bm_rise_delay = 20; bm_fall_delay = 15;
      f_rec_reset;
      f_n0 = bm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      reg_rd(REFRESH, 32'h0000_0001);                // pending, before active
      @(posedge free_clk);
      while (bdi_refresh_active_drv !== 1'b1) @(posedge free_clk);
      repeat (3) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0001);                // while active
      bm_wait_frames(f_n0 + 1, 400);
      repeat (3) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0000);                // self-cleared at refresh done
      repeat (200) @(posedge free_clk);
      if (bm_trig_n != 1) begin
         $display("ERROR: manual refresh: %0d triggers / expected 1 %t", bm_trig_n, $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h3);
      // a second START: one more trigger
      reg_wr(REFRESH, 32'h0000_0001);
      bm_wait_frames(f_n0 + 2, 400);
      repeat (200) @(posedge free_clk);
      if (bm_trig_n != 2) begin
         $display("ERROR: manual refresh: %0d triggers after two START writes / expected 2 %t", bm_trig_n, $time);
         error = error + 1;
      end
      reg_rd(REFRESH, 32'h0);
      // START self-clear exactly at the falling edge: poll while active falls
      reg_wr(REFRESH, 32'h0000_0001);
      @(posedge free_clk);
      while (bm_state != 3) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0001);                // last pixel taken, active still high
      bm_wait_frames(f_n0 + 3, 400);
      repeat (3) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0);
      bm_auto = 1'b0;

      // No driver answer: START stays pending, one trigger only. From here
      // the test toggles bdi_refresh_active_i itself and, like an external
      // driver, holds bdi_busy_i so the clock stays requested (ICG builds;
      // set after the edge, so the model's last update does not override it).
      @(negedge free_clk);
      bdi_busy_drv = 1'b1;
      f_rec_reset;
      reg_wr(REFRESH, 32'h0000_0001);
      repeat (300) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0001);
      if (bm_trig_n != 1) begin
         $display("ERROR: manual refresh without answer: %0d triggers / expected 1 %t", bm_trig_n, $time);
         error = error + 1;
      end
      // A rewrite while the request is pending is queued: its trigger follows
      // the rise of the first frame, START clears at the end of the second
      reg_wr(REFRESH, 32'h0000_0001);
      repeat (50) @(posedge free_clk);
      if (bm_trig_n != 1) tb_error("queued START triggered before the first frame started");
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (10) @(posedge free_clk);
      if (bm_trig_n != 2) tb_error("queued START not triggered at the first frame's start");
      reg_rd(REFRESH, 32'h0000_0001);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (4) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0001);                // second frame still requested
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (10) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0001);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (4) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0000);
      if (bm_trig_n != 2) tb_error("extra trigger after the queued frame");
      // a refresh done with nothing pending changes nothing
      f_n0 = bm_trig_n;
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (5) @(posedge free_clk);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(REFRESH, 32'h0000_0000);
      if (bm_trig_n != f_n0) tb_error("refresh trigger without START");
      // START cleared by software while pending
      reg_wr(REFRESH, 32'h0000_0001);
      repeat (10) @(posedge free_clk);
      reg_wr(REFRESH, 32'h0000_0000);
      reg_rd(REFRESH, 32'h0000_0000);
      $display("OK:    manual mode");

      //------------------------------------------------------------------
      // Debug freeze of the period timer
      //------------------------------------------------------------------
      // f_k: 0 = DBG_CTRL 1 + stoptime (freeze), 1 = DBG_CTRL 0 + stoptime,
      //      2 = DBG_CTRL 2 + stoptime, 3 = DBG_CTRL 1 without stoptime,
      //      4 = DBG_CTRL 1 + stoptime longer than the period
      for (f_k = 0; f_k < 5; f_k = f_k + 1) begin
         f_p = 40;
         reg_wr(DBG_CTRL, (f_k == 1) ? 0 : (f_k == 2) ? 2 : 1);
         f_rec_reset;
         reg_wr(REFRESH, (f_p << 4) | 1);
         f_wait_trig(3, 400);
         // freeze inside interval 2 (between triggers 2 and 3)
         @(posedge free_clk);
         while (bm_trig_n < 3) @(posedge free_clk);
         repeat (11) @(posedge free_clk);
         f_iv = (f_k == 4) ? 97 : 23;
         if (f_k != 3) dbg_stoptime = 1'b1;
         repeat (f_iv) @(posedge free_clk);
         dbg_stoptime = 1'b0;
         f_wait_trig(7, 800);
         reg_wr(REFRESH, 32'h0);
         f_chk_intervals(0, 6, f_p, 2, ((f_k == 0) || (f_k == 4)) ? f_iv : 0);
      end
      reg_wr(DBG_CTRL, 32'h0);
      $display("OK:    debug freeze of the period timer");

      //------------------------------------------------------------------
      // Debug freeze of FRAME_CNT
      //------------------------------------------------------------------
      reg_wr(IRQ_FLAG, 32'h1F7);
      reg_wr(DBG_CTRL, 32'h1);
      reg_wr(FRAME_CNT, 32'd5);
      @(posedge free_clk); dbg_stoptime = 1'b1;
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (5) @(posedge free_clk);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'd5);                       // holds during the freeze
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h7);            // REFR_START / REFR_DONE still raised
      @(posedge free_clk); dbg_stoptime = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'd5);                       // the frozen frame is not counted later
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h7);
      // normal counting resumes
      reg_wr(FRAME_CNT, 32'd1);
      @(posedge free_clk); dbg_stoptime = 1'b1;
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (5) @(posedge free_clk);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'd1);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h4);             // no FRAME_CNT_DONE while frozen
      @(posedge free_clk); dbg_stoptime = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'd1);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h4);             // nor after the release
      // While frozen: FRAME_NUM counts the frames, a manual START is served
      // (one trigger, START clears at the end of its frame), the timer and
      // FRAME_CNT stay
      reg_wr(IRQ_FLAG, 32'h1F7);
      reg_rd_val(FRAME_NUM, f_rd);
      f_n0 = f_rd;
      @(posedge free_clk); dbg_stoptime = 1'b1; repeat (3) @(posedge free_clk);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (5) @(posedge free_clk);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(FRAME_NUM, (f_n0 + 1) & 32'hFFFF);
      f_rec_reset;
      bm_auto = 1'b1; bm_rise_delay = 5; bm_fall_delay = 3;
      f_k = bm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bm_wait_frames(f_k + 1, 400);
      repeat (5) @(posedge free_clk);
      bm_auto = 1'b0;
      @(negedge free_clk);
      bdi_busy_drv = 1'b1;
      if (bm_trig_n != 1) begin
         $display("ERROR: manual START while frozen: %0d triggers / expected 1 %t", bm_trig_n, $time);
         error = error + 1;
      end
      reg_rd(REFRESH, 32'h0);
      reg_rd(FRAME_NUM, (f_n0 + 2) & 32'hFFFF);
      reg_rd(FRAME_CNT, 32'd1);
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h7);
      // the timer holds while frozen: no trigger with START = 1 and PERIOD 5
      f_rec_reset;
      reg_wr(REFRESH, (5 << 4) | 1);
      repeat (60) @(posedge free_clk);
      if (bm_trig_n != 0) tb_error("refresh timer requested a frame while frozen");
      reg_wr(REFRESH, 32'h0);
      @(posedge free_clk); dbg_stoptime = 1'b0; repeat (5) @(posedge free_clk);
      reg_wr(FRAME_CNT, 32'd1);
      reg_wr(IRQ_FLAG, 32'h1F7);
      // stoptime without DBG_CTRL[0]: counts
      reg_wr(DBG_CTRL, 32'h2);
      @(posedge free_clk); dbg_stoptime = 1'b1;
      @(posedge free_clk); bdi_refresh_active_drv = 1'b1; repeat (5) @(posedge free_clk);
      @(posedge free_clk); bdi_refresh_active_drv = 1'b0; repeat (5) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'd0);
      reg_rd_mask(IRQ_FLAG, 32'h4, 32'h4);
      @(posedge free_clk); dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      reg_wr(IRQ_FLAG, 32'h1F7);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
