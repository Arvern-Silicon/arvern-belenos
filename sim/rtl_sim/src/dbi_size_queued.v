//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_size_queued
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_size_queued.v
// Module Description : DISP_SIZE and refresh requests queued behind a frame.
//                      A monitor checks every frame: the pixels sent equal the
//                      window size the driver latched for it (CASET/PASET).
//                      1. PERIOD = 1 (requests continuously): a DISP_SIZE
//                         write reaches the frames that follow.
//                      2. TE sync with a PERIOD shorter than the TE period
//                         (every request queued behind the previous frame's
//                         TE wait), DISP_SIZE written at random times: every
//                         frame consistent, the last size reaches the panel.
//                      Every PHY of the build.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

`define SQ_ENG dut.G_DBI.u_dbi.blns_dbi_engine_inst

integer    phy_i, sq_frames, sq_bad, sq_cnt, sq_seed, kk, nn, f0;
reg        phy, sq_act, sq_te_run;
integer    sq_w, sq_h, sq_last_w, sq_last_h;

initial begin sq_frames = 0; sq_bad = 0; sq_act = 1'b0; sq_te_run = 1'b0; end

// Frame monitor: window latched by the driver vs pixels sent
always @(negedge free_clk)
  if (DIF_TYPE != 0) begin
     if (`SQ_ENG.refresh_active_o === 1'b1) begin
        if (!sq_act) begin
           sq_w   = `SQ_ENG.win_w;
           sq_h   = `SQ_ENG.win_h;
           sq_cnt = 0;
        end
        if ((`SQ_ENG.st_pix === 1'b1) && (`SQ_ENG.accept === 1'b1)) sq_cnt = sq_cnt + 1;
        sq_act = 1'b1;
     end else if (sq_act) begin
        sq_act    = 1'b0;
        sq_frames = sq_frames + 1;
        sq_last_w = sq_w;
        sq_last_h = sq_h;
        if (sq_cnt != sq_w * sq_h) begin
           if (sq_bad < 10)
              $display("ERROR: frame %0d: window %0dx%0d but %0d pixels sent %t", sq_frames, sq_w, sq_h, sq_cnt, $time);
           sq_bad = sq_bad + 1;
           error  = error + 1;
        end
     end
  end

// TE generator: one pulse every 600 cycles while sq_te_run
always begin
   @(negedge free_clk);
   if (sq_te_run) begin
      repeat(594) @(negedge free_clk);
      lcd_te = 1'b1;
      repeat(6) @(negedge free_clk);
      lcd_te = 1'b0;
   end
end

task wait_frames;
   input integer n;
   begin
      f0 = sq_frames;
      nn = 0;
      while ((sq_frames < f0 + n) && (nn < 200000)) begin @(negedge free_clk); nn = nn + 1; end
      if (sq_frames < f0 + n) tb_error("frames stopped");
   end
endtask

task chk_last;
   input integer w;
   input integer h;
   input [64*8-1:0] what;
   begin
      if ((sq_last_w != w) || (sq_last_h != h)) begin
         $display("ERROR: %0s: last frame %0dx%0d / expected %0dx%0d %t", what, sq_last_w, sq_last_h, w, h, $time);
         error = error + 1;
      end else
         $display("OK:    %0s: frames at %0dx%0d", what, w, h);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     DBI: DISP_SIZE WITH QUEUED REQUESTS       |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      sq_seed = `SEED;
      lcd_te  = 1'b0;
      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);
      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (phy == PHY_8080) ? "8080" : "SPI");
            dif_cfg(phy, (phy == PHY_8080) ? 4'd0 : 4'd1, 1'b1, 1'b1, 1'b0);

            // 1. PERIOD = 1
            reg_wr(DISP_SIZE, (2 << 16) | 4);
            reg_wr(REFRESH, (1 << 4) | 1);
            wait_frames(2);
            chk_last(4, 2, "PERIOD = 1, first size");
            reg_wr(DISP_SIZE, (2 << 16) | 6);
            wait_frames(4);
            chk_last(6, 2, "PERIOD = 1, DISP_SIZE written while running");
            reg_wr(REFRESH, 32'h0);
            dif_wait_idle(50000);

            // 2. TE sync, requests queued behind each TE wait
            reg_wr(DIF_SYNC, 32'h0001_0000);
            sq_te_run = 1'b1;
            reg_wr(DISP_SIZE, (2 << 16) | 5);
            reg_wr(REFRESH, (40 << 4) | 1);
            for (kk = 0; kk < 40; kk = kk + 1) begin
               repeat({$random(sq_seed)} % 700) @(posedge free_clk);
               reg_wr(DISP_SIZE, ((1 + {$random(sq_seed)} % 3) << 16) | (3 + {$random(sq_seed)} % 6));
            end
            reg_wr(DISP_SIZE, (3 << 16) | 7);
            wait_frames(3);
            chk_last(7, 3, "TE-paced queued frames, last DISP_SIZE");
            reg_wr(REFRESH, 32'h0);
            dif_wait_idle(50000);
            sq_te_run = 1'b0;
            reg_wr(DIF_SYNC, 32'h0);
            repeat(700) @(posedge free_clk);
         end
      end
      $display("INFO:  %0d frames checked, %0d inconsistent", sq_frames, sq_bad);
      stimulus_done = 1'b1;
   end
