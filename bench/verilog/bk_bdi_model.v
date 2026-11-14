//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    bk_bdi_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_bdi_model.v
// Module Description : BDI display-driver model for DIF_TYPE = 0 (`included
//                      by the bk_ tests into tb_belenos). Drives the bench
//                      regs bdi_refresh_active_drv (bdi_refresh_active_i) and
//                      bdi_px_ready_drv (bdi_px_ready_i), which reach the DUT
//                      1 ns after a rising clock edge like every bench input.
//                      The handshake is sampled on the falling edge before
//                      the rising edge that takes it.
//
//                      Frame control: a frame starts (active rises) either
//                      bkm_start_delay cycles after a bdi_refresh_trig_o pulse
//                      (bkm_auto_trig = 1; one trigger is remembered while a
//                      frame runs) or on bkm_go(); active falls bkm_end_delay
//                      cycles after the handshake of the last pixel, or after
//                      bkm_abort_at handshakes (abort, if > 0).
//
//                      Busy: with bkm_busy_en = 1, bdi_busy_drv (bdi_busy_i)
//                      is high from bkm_busy_lead DUT clock edges before the
//                      edge at which active rises until active falls (a driver
//                      acting on its own timing keeps the clock request,
//                      the BDI guide).
//
//                      Ready: bkm_rdy_mode 0 = always 1; 1 = random, low with
//                      probability bkm_rdy_pct_low %; 2 = bursts (low for
//                      0..bkm_rdy_gap cycles, then high for 1..bkm_rdy_gap
//                      cycles); bkm_hold = 1 forces ready low.
//
//                      Captured per frame (reset when active rises):
//                        bkm_px[n], bkm_lst[n], bkm_cyc[n]  data, last, cycle
//                        bkm_n                               handshakes
//                      bkm_vreads: VRAM read cycles while the DUT sees active
//                      (reset when active rises);
//                      bkm_frames counts completed frames (active falls),
//                      bkm_trigs counts trigger pulses, bkm_rise_cyc /
//                      bkm_fall_cyc the cycles of the last active edges.
//
//                      Online checks (each failure increments `error`):
//                        - px_valid / px_last / px_data never X while active
//                        - px_valid low whenever refresh_active is low
//                          (including the cycle refresh_active falls)
//                        - px_last on exactly the bkm_exp_n-th handshake
//                          (bkm_exp_n = 0: not checked) and never without
//                          px_valid being taken
//                        - px_valid low after the last pixel of a frame
//                          until refresh_active falls
//                      bkm_drop() drops active at the next rising edge
//                      (abort of a frame by the driver).
//----------------------------------------------------------------------------

localparam integer BKM_LOG = 65536;

reg       [23:0] bkm_px  [0:BKM_LOG-1];
reg              bkm_lst [0:BKM_LOG-1];
integer          bkm_cyc [0:BKM_LOG-1];

reg              bkm_en;
reg              bkm_auto_trig;
integer          bkm_start_delay;
integer          bkm_end_delay;
integer          bkm_abort_at;
integer          bkm_rdy_mode;
integer          bkm_rdy_pct_low;
integer          bkm_rdy_gap;
reg              bkm_hold;
reg              bkm_busy_en;
integer          bkm_busy_lead;
integer          bkm_exp_n;

integer          bkm_n;
integer          bkm_frames;
integer          bkm_trigs;
integer          bkm_cycle;
integer          bkm_rise_cyc;
integer          bkm_fall_cyc;
integer          bkm_errs;
integer          bkm_vreads;
integer          bkm_seed;

// internal
integer          bkm_state;          // 0 idle, 1 start delay, 2 active, 3 tail
integer          bkm_cnt;
integer          bkm_burst;
reg              bkm_burst_lvl;
reg              bkm_trig_pend;
reg              bkm_trig_q;
reg              bkm_go_req;
reg              bkm_drop_req;
reg              bkm_aborted;        // frame ended by bkm_abort_at / bkm_drop
reg              bkm_done_seen;      // last (or abort count) handshake seen this frame
reg              bkm_hs_last;        // sampled: handshake of a pixel flagged last
reg              bkm_hs;             // sampled: handshake this cycle

initial
  begin
     bkm_en          = 1'b0;
     bkm_auto_trig   = 1'b1;
     bkm_start_delay = 2;
     bkm_end_delay   = 1;
     bkm_abort_at    = 0;
     bkm_rdy_mode    = 0;
     bkm_rdy_pct_low = 30;
     bkm_rdy_gap     = 6;
     bkm_hold        = 1'b0;
     bkm_busy_en     = 1'b1;
     bkm_busy_lead   = 1;
     bkm_exp_n       = 0;
     bkm_n           = 0;
     bkm_frames      = 0;
     bkm_trigs       = 0;
     bkm_cycle       = 0;
     bkm_rise_cyc    = 0;
     bkm_fall_cyc    = 0;
     bkm_errs        = 0;
     bkm_vreads      = 0;
     bkm_seed        = `SEED;
     bkm_state       = 0;
     bkm_cnt         = 0;
     bkm_burst       = 0;
     bkm_burst_lvl   = 1'b1;
     bkm_trig_pend   = 1'b0;
     bkm_trig_q      = 1'b0;
     bkm_go_req      = 1'b0;
     bkm_drop_req    = 1'b0;
     bkm_aborted     = 1'b0;
     bkm_done_seen   = 1'b0;
     bkm_hs_last     = 1'b0;
     bkm_hs          = 1'b0;
  end

task bkm_fail;
   input [80*8-1:0] msg;
   begin
      bkm_errs = bkm_errs + 1;
      if (bkm_errs <= 20)
        $display("ERROR: BDI model -- %0s (frame %0d, pixel %0d, cycle %0d) %t", msg, bkm_frames, bkm_n, bkm_cycle, $time);
      error = error + 1;
   end
endtask

// Sample the stream on the falling edge (handshake taken at the next rising edge)
always @(negedge free_clk)
  begin
     bkm_hs      = 1'b0;
     bkm_hs_last = 1'b0;
     if (bkm_en && (hresetn === 1'b1))
       begin
          if (bdi_px_valid === 1'bx)
            bkm_fail("bdi_px_valid_o is X");
          if ((bdi_refresh_active_d === 1'b1) && bkm_done_seen && !bkm_aborted && (bdi_px_valid === 1'b1))
            bkm_fail("bdi_px_valid_o high after the last pixel of the frame");
          if ((bdi_refresh_active_d !== 1'b1) && (bdi_px_valid === 1'b1))
            bkm_fail("bdi_px_valid_o high while bdi_refresh_active_i is low");
          if ((bdi_refresh_active_d === 1'b1) && (bdi_px_valid === 1'b1) && (bdi_px_ready_d === 1'b1))
            begin
               if ((^bdi_px_data === 1'bx) || (bdi_px_last === 1'bx))
                 bkm_fail("bdi_px_data_o / bdi_px_last_o X during a handshake");
               if (bkm_n < BKM_LOG)
                 begin
                    bkm_px[bkm_n]  = bdi_px_data;
                    bkm_lst[bkm_n] = bdi_px_last;
                    bkm_cyc[bkm_n] = bkm_cycle;
                 end
               bkm_n  = bkm_n + 1;
               bkm_hs = 1'b1;
               if (bdi_px_last === 1'b1)
                 begin
                    bkm_hs_last = 1'b1;
                    if ((bkm_exp_n > 0) && (bkm_n != bkm_exp_n))
                      bkm_fail("bdi_px_last_o on the wrong pixel");
                 end
               else if ((bkm_exp_n > 0) && (bkm_n == bkm_exp_n))
                 bkm_fail("bdi_px_last_o missing on the final pixel");
            end
       end
  end

// Refresh trigger: one DUT clock cycle wide (sampled on the DUT clock)
always @(negedge hclk)
  if (bkm_en && (hresetn === 1'b1))
    begin
       if (bdi_refresh_trig === 1'b1)
         begin
            if (bkm_trig_q)
              bkm_fail("bdi_refresh_trig_o high for more than one cycle");
            bkm_trigs     = bkm_trigs + 1;
            bkm_trig_pend = 1'b1;
         end
       bkm_trig_q = (bdi_refresh_trig === 1'b1);
    end

// VRAM reads seen by the macro while the DUT sees refresh_active high
// (all of them are the backend's when no other master is active)
always @(posedge hclk)
  begin
     if ((bdi_refresh_active_d === 1'b1) && (vram_cen === 1'b0) && (vram_wen === 4'hF))
       bkm_vreads = bkm_vreads + 1;
  end

// Drive active / ready right after the rising edge
always @(posedge free_clk)
  begin
     bkm_cycle = bkm_cycle + 1;
     if (bkm_en && (hresetn === 1'b1))
       begin
          // Frame control
          case (bkm_state)
            0 : if (bkm_go_req || (bkm_auto_trig && bkm_trig_pend))
                  begin
                     if (bkm_go_req) bkm_go_req    = 1'b0;
                     else            bkm_trig_pend = 1'b0;
                     bkm_cnt   = bkm_start_delay;
                     bkm_state = 1;
                  end
            default : ;
          endcase
          if (bkm_state == 1)
            begin
               if (bkm_cnt <= 0)
                 begin
                    bkm_n           = 0;
                    bkm_done_seen   = 1'b0;
                    bkm_aborted     = 1'b0;
                    bkm_rise_cyc    = bkm_cycle;
                    bkm_vreads      = 0;
                    bdi_refresh_active_drv = 1'b1;
                    bkm_state       = 2;
                 end
               else
                 bkm_cnt = bkm_cnt - 1;
            end
          else if (bkm_state == 2)
            begin
               if (bkm_drop_req)
                 begin
                    bkm_drop_req  = 1'b0;
                    bkm_done_seen = 1'b1;
                    bkm_aborted   = 1'b1;
                    bkm_cnt       = 0;
                    bkm_state     = 3;
                 end
               else if (bkm_hs && (bkm_hs_last || ((bkm_abort_at > 0) && (bkm_n >= bkm_abort_at))))
                 begin
                    bkm_done_seen = 1'b1;
                    bkm_aborted   = !bkm_hs_last;
                    bkm_cnt       = bkm_aborted ? 0 : bkm_end_delay;
                    bkm_state     = 3;
                 end
            end
          if (bkm_state == 3)
            begin
               if (bkm_cnt <= 0)
                 begin
                    bdi_refresh_active_drv = 1'b0;
                    bkm_fall_cyc    = bkm_cycle;
                    bkm_frames      = bkm_frames + 1;
                    bkm_state       = 0;
                 end
               else
                 bkm_cnt = bkm_cnt - 1;
            end

          // Busy (clock request) while a self-started frame is pending or running
          bdi_busy_drv = bkm_busy_en && (((bkm_state == 1) && (bkm_cnt + 1 <= bkm_busy_lead)) ||
                                           (bkm_state == 2) || (bkm_state == 3));

          // Ready
          if (bkm_hold)
            bdi_px_ready_drv = 1'b0;
          else if (bkm_rdy_mode == 1)
            bdi_px_ready_drv = (({$random(bkm_seed)} % 100) >= bkm_rdy_pct_low);
          else if (bkm_rdy_mode == 2)
            begin
               if (bkm_burst <= 0)
                 begin
                    bkm_burst_lvl = ~bkm_burst_lvl;
                    bkm_burst     = bkm_burst_lvl ? (1 + ({$random(bkm_seed)} % bkm_rdy_gap))
                                                  : ({$random(bkm_seed)} % (bkm_rdy_gap + 1));
                 end
               if (bkm_burst > 0)
                 bkm_burst = bkm_burst - 1;
               bdi_px_ready_drv = bkm_burst_lvl;
            end
          else
            bdi_px_ready_drv = 1'b1;
       end
  end

// Start a frame without a trigger (active rises bkm_start_delay cycles later)
task bkm_go;
   begin
      @(negedge free_clk);
      bkm_go_req = 1'b1;
   end
endtask

// Drop active at the next rising edge (frame abort)
task bkm_drop;
   begin
      @(negedge free_clk);
      bkm_drop_req = 1'b1;
   end
endtask

// Wait until bkm_frames reaches nr (bounded)
task bkm_wait_frames;
   input integer nr;
   input integer max_cycles;
   integer       cc;
   begin
      cc = 0;
      while ((bkm_frames < nr) && (cc < max_cycles)) begin
         @(posedge free_clk);
         cc = cc + 1;
      end
      if (bkm_frames < nr) begin
         $display("ERROR: BDI model -- frame %0d not completed within %0d cycles (%0d pixels taken) %t", nr, max_cycles, bkm_n, $time);
         error = error + 1;
      end
      @(negedge free_clk);
   end
endtask

// Wait until the current frame has taken nr pixels (bounded)
task bkm_wait_pixels;
   input integer nr;
   input integer max_cycles;
   integer       cc;
   begin
      cc = 0;
      while ((bkm_n < nr) && (cc < max_cycles)) begin
         @(posedge free_clk);
         cc = cc + 1;
      end
      if (bkm_n < nr) begin
         $display("ERROR: BDI model -- %0d pixels not reached within %0d cycles (%0d taken) %t", nr, max_cycles, bkm_n, $time);
         error = error + 1;
      end
   end
endtask

// Wait until refresh_active is high
task bkm_wait_active;
   input integer max_cycles;
   integer       cc;
   begin
      cc = 0;
      while ((bdi_refresh_active_drv !== 1'b1) && (cc < max_cycles)) begin
         @(posedge free_clk);
         cc = cc + 1;
      end
      if (bdi_refresh_active_drv !== 1'b1) begin
         $display("ERROR: BDI model -- refresh_active never raised within %0d cycles %t", max_cycles, $time);
         error = error + 1;
      end
   end
endtask
