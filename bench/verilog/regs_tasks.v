//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    regs_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_tasks.v
// Module Description : Bench helpers of the regs_* tests, `included by each
//                      regs_* stimulus file (inside tb_belenos):
//                        - rp_* / vp_*: pipelined, cycle-sampling AHB-Lite
//                          managers for the register and VRAM-window ports
//                          (regs_ahb_pipe_r.vh / regs_ahb_pipe_v.vh);
//                        - bm_*: a BDI display-driver model for DIF_TYPE = 0
//                          (records bdi_refresh_trig_o, optionally frames a
//                          refresh: raise bdi_refresh_active_i, take every
//                          pixel up to bdi_px_last_o, drop active), driving
//                          the bench's bdi_*_drv inputs and holding
//                          bdi_busy_i while a frame is pending or active;
//                        - bm_cyc: hclk cycle counter.
//----------------------------------------------------------------------------

localparam integer PIPE_MAX = 600;

`include "regs_ahb_pipe_r.vh"
`include "regs_ahb_pipe_v.vh"

//============================================================================
// hclk cycle counter and refresh-trigger recorder (every DIF_TYPE)
//============================================================================
integer bm_cyc;
integer bm_trig_n;
integer bm_trig_cyc [0:255];
integer bm_trig_wide;              // trigger high on two consecutive cycles
reg     bm_trig_q;

initial begin
   bm_cyc       = 0;
   bm_trig_n    = 0;
   bm_trig_wide = 0;
   bm_trig_q    = 1'b0;
end

always @(posedge hclk) begin
   bm_cyc = bm_cyc + 1;
   if (hresetn_d === 1'b1) begin
      if (bdi_refresh_trig === 1'b1) begin
         if (bm_trig_n < 256) bm_trig_cyc[bm_trig_n] = bm_cyc;
         bm_trig_n = bm_trig_n + 1;
         if (bm_trig_q) bm_trig_wide = bm_trig_wide + 1;
      end
      bm_trig_q = (bdi_refresh_trig === 1'b1);
   end
end

//============================================================================
// BDI driver model (DIF_TYPE = 0 only; bm_auto = 1 enables it)
//============================================================================
reg         bm_auto;
reg         bm_busy_hold;           // extra bdi_busy_i request while bm_auto
integer     bm_rise_delay;          // cycles from the trigger to active rising
integer     bm_fall_delay;          // cycles from the last pixel to active falling
reg         bm_pending;
integer     bm_lost;                // triggers received while one was pending
integer     bm_frames;              // frames completed (active fell)
integer     bm_px;                  // pixels taken in total
integer     bm_px_frame;            // pixels taken in the current frame
integer     bm_px_bad_last;         // frames whose px_last count was wrong
integer     bm_exp_px;              // expected pixels per frame (0 = not checked)
integer     bm_state;
integer     bm_cnt;
reg  [23:0] bm_px_log [0:4095];

initial begin
   bm_auto        = 1'b0;
   bm_busy_hold   = 1'b0;
   bm_rise_delay  = 3;
   bm_fall_delay  = 2;
   bm_pending     = 1'b0;
   bm_lost        = 0;
   bm_frames      = 0;
   bm_px          = 0;
   bm_px_frame    = 0;
   bm_px_bad_last = 0;
   bm_exp_px      = 0;
   bm_state       = 0;
   bm_cnt         = 0;
end

always @(posedge hclk)
  if ((hresetn_d === 1'b1) && bm_auto && (DIF_TYPE == 0)) begin
     if (bdi_refresh_trig === 1'b1) begin
        if (bm_pending) bm_lost = bm_lost + 1;
        bm_pending = 1'b1;
     end
     case (bm_state)
       0: if (bm_pending) begin
             bm_pending = 1'b0;
             bm_cnt     = bm_rise_delay;
             bm_state   = 1;
          end
       1: if (bm_cnt <= 0) begin
             bdi_refresh_active_drv <= 1'b1;
             bm_px_frame = 0;
             bm_state    = 2;
          end else bm_cnt = bm_cnt - 1;
       2: if ((bdi_px_valid === 1'b1) && (bdi_px_ready_d === 1'b1) && (bdi_refresh_active_d === 1'b1)) begin
             if (bm_px < 4096) bm_px_log[bm_px] = bdi_px_data;
             bm_px       = bm_px + 1;
             bm_px_frame = bm_px_frame + 1;
             if (bdi_px_last === 1'b1) begin
                if ((bm_exp_px != 0) && (bm_px_frame != bm_exp_px)) bm_px_bad_last = bm_px_bad_last + 1;
                bm_cnt   = bm_fall_delay;
                bm_state = 3;
             end
          end
       3: if (bm_cnt <= 0) begin
             bdi_refresh_active_drv <= 1'b0;
             bm_frames = bm_frames + 1;
             bm_state  = 0;
          end else bm_cnt = bm_cnt - 1;
     endcase
     // like a real driver, request the clock while a frame is pending or
     // being sent (ICG builds)
     bdi_busy_drv <= bm_busy_hold | bm_pending | (bm_state != 0);
  end

// Wait for n hclk cycles
task bm_wait;
   input integer n;
   integer k;
   begin
      for (k = 0; k < n; k = k + 1) @(posedge hclk);
   end
endtask

// Wait until the model has completed n frames in total (bounded)
task bm_wait_frames;
   input integer n;
   input integer max_cycles;
   integer k;
   begin
      k = 0;
      while ((bm_frames < n) && (k < max_cycles)) begin
         @(posedge free_clk);
         k = k + 1;
      end
      if (bm_frames < n) begin
         $display("ERROR: BDI model -- %0d frames after %0d cycles / expected %0d %t", bm_frames, k, n, $time);
         error = error + 1;
      end
   end
endtask
