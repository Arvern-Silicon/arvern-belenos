//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_scan
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_scan.v
// Module Description : DBI driver scanline synchronisation (DIF_SYNC.
//                      SCAN_SYNC_EN). 8080 PHY, CLK_DIV 0, 1, 3 and 15: the panel
//                      model returns a test-given scanline sequence, one value
//                      per Get_Scanline poll (0x45, dummy read, GTS[9:8] from
//                      D[1:0], GTS[7:0] from D[7:0]); the refresh must start
//                      right after the first poll (never the first one) whose
//                      value crosses SCANLINE with respect to the previous
//                      poll (frame wrap included). Sequences straddle SCANLINE
//                      strictly, use values above 255 so a GTS[9:8]/[7:0]
//                      mix-up changes the outcome, start exactly on SCANLINE
//                      (no start), wrap. A scan that never crosses: WAIT_SYNC
//                      = 1, refresh not active, released by clearing
//                      SCAN_SYNC_EN. Slow polls (CLK_DIV 15) on a free-running
//                      scan still start. SCAN wins over TE on 8080. A poll
//                      reading SCANLINE itself crosses it (previous <
//                      SCANLINE <= current), also through the wrap. With
//                      HW_WINDOW_EN = 0 the refresh after the polls is 0x2C
//                      and the pixels. SPI PHY: SCAN_SYNC_EN is ignored.
//                      The whole refresh (polls, window, pixels) is one CS
//                      frame on 8080. The 8080 monitor checks every read's
//                      timing and the bus driven again exactly 2*CLK_DIV+1
//                      cycles after the last RD rise.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

localparam integer SW = 3;
localparam integer SH = 2;

integer    kk, xx, yy, mark, nn, np, exp_np, first_ix, poll0, div_i;
reg  [3:0] div;
reg  [9:0] sl;
reg [31:0] rd;
reg [15:0] pa, pb;
reg        started;
reg        scan_hw = 1'b1;                // HW_WINDOW_EN of scan_run

function [15:0] pix16;
   input integer x;
   input integer y;
   begin
      pix16 = 16'h8421 ^ (x * 16'h1111) ^ (y * 16'h0F0F);
   end
endfunction

// Expected panel items after the polls: window + 0x2C + pixels, same CS frame
task exp_after_polls;
   input phy;
   begin
      if (scan_hw) exp_window(phy, SW, SH, 1'b0);
      exp_cmd(phy, 8'h2C, (phy == PHY_SPI) && scan_hw);
      for (yy = 0; yy < SH; yy = yy + 1)
        for (xx = 0; xx < SW; xx = xx + 1)
          exp_px(phy, pix16(xx, yy));
   end
endtask

// Count 0x45 polls in the log from `from`; index of the first non-poll item
task count_polls;
   input  integer from;
   output integer polls;
   output integer first_other;
   integer        ii;
   begin
      polls = 0;
      ii    = from;
      while ((ii + 3 < lg_n) && (lg_kind[ii] == K_CMD) && (lg_data[ii][7:0] == 8'h45) &&
             (lg_kind[ii+1] == K_RD) && (lg_kind[ii+2] == K_RD) && (lg_kind[ii+3] == K_RD)) begin
         polls = polls + 1;
         ii    = ii + 4;
      end
      first_other = ii;
   end
endtask

// Reference: poll index after which the refresh starts (-1 = never)
function integer ref_start;
   input [9:0]   s;
   input integer n;
   integer       ii;
   begin
      ref_start = -1;
      for (ii = 1; (ii < n) && (ref_start < 0); ii = ii + 1)
        if (crossing(scan_seq[ii-1], scan_seq[ii], s)) ref_start = ii;
   end
endfunction

// One stepped-sequence run: scan_seq[0..n-1] must already be loaded
task scan_run;
   input [9:0]      s;
   input integer    n;
   input [3:0]      dv;
   input [40*8-1:0] what;
   begin
      // With synchroniser jitter CLK_DIV 0 reads have no margin for a bit
      // taken an edge late (see smoke_refresh_8080): CLK_DIV 1 instead
      dif_cfg(PHY_8080, ((SYNC_JITTER != 0) && (dv == 4'd0)) ? 4'd1 : dv, scan_hw, 1'b1, 1'b0);
      exp_np       = ref_start(s, n) + 1;
      scan_seq_n   = n;
      scan_seq_idx = 0;
      scan_seq_en  = 1'b1;
      poll0        = poll_nr;
      reg_wr(DIF_SYNC, 32'h0000_8000 | s);
      mark = lg_n;
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      scan_seq_en = 1'b0;
      count_polls(mark, np, first_ix);
      if (np != exp_np) begin
         $display("ERROR: %0s (CLK_DIV %0d) -- refresh started after %0d polls / expected %0d %t", what, dv, np, exp_np, $time);
         error = error + 1;
      end else
         $display("OK:    %0s (CLK_DIV %0d) -- started after poll %0d", what, dv, np);
      for (kk = 0; (kk < np) && (kk < n); kk = kk + 1)
        if (poll_gts[poll0 + kk] !== scan_seq[kk]) begin
           $display("ERROR: %0s -- poll %0d read GTS 0x%h / model 0x%h (bench) %t", what, kk, poll_gts[poll0 + kk], scan_seq[kk], $time);
           error = error + 1;
        end
      if (frames_in(mark, lg_n) != 1) begin
         $display("ERROR: %0s -- refresh spread over %0d CS frames / expected 1 %t", what, frames_in(mark, lg_n), $time);
         error = error + 1;
      end
      exp_reset;
      exp_after_polls(PHY_8080);
      dbi_check_log(first_ix, what);
      reg_wr(DIF_SYNC, 32'h0);
      reg_wr(IRQ_FLAG, 32'h3);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|          DBI: SCANLINE SYNCHRONISATION        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (SH << 16) | SW);
      reg_wr(FRAME0_PTR, 32'h0);
      for (kk = 0; kk < SW*SH; kk = kk + 2) begin
         pa = pix16(kk % SW, kk / SW);
         pb = pix16((kk + 1) % SW, (kk + 1) / SW);
         vram_wr(2*kk, {pb, pa}, SZ_W);
      end

      if (HAS_8080) begin
         for (div_i = 0; div_i < 4; div_i = div_i + 1) begin
            div = (div_i == 0) ? 4'd0 : (div_i == 1) ? 4'd1 : (div_i == 2) ? 4'd3 : 4'd15;

            // a. plain straddle, values above 255
            scan_seq[0] = 10'h105; scan_seq[1] = 10'h111; scan_seq[2] = 10'h120;
            scan_seq[3] = 10'h13F; scan_seq[4] = 10'h010;
            scan_run(10'h12C, 5, div, "a: straddle 0x120 -> 0x13F");

            // b. first poll exactly on SCANLINE, then a full wrap
            scan_seq[0] = 10'h12C; scan_seq[1] = 10'h130; scan_seq[2] = 10'h13A;
            scan_seq[3] = 10'h005; scan_seq[4] = 10'h100; scan_seq[5] = 10'h140;
            scan_run(10'h12C, 6, div, "b: first poll on SCANLINE");

            // c. crossing through the frame wrap (SCANLINE above the last value)
            scan_seq[0] = 10'h100; scan_seq[1] = 10'h130; scan_seq[2] = 10'h002;
            scan_seq[3] = 10'h050;
            scan_run(10'h13E, 4, div, "c: wrap, SCANLINE near the end");

            // c2. crossing through the frame wrap (SCANLINE near 0)
            scan_seq[0] = 10'h100; scan_seq[1] = 10'h13F; scan_seq[2] = 10'h003;
            scan_seq[3] = 10'h050;
            scan_run(10'h001, 4, div, "c2: wrap, SCANLINE near 0");

            // d. GTS[9:8] matters: a [7:0]-only compare would start one poll early
            scan_seq[0] = 10'h020; scan_seq[1] = 10'h110; scan_seq[2] = 10'h135;
            scan_seq[3] = 10'h010;
            scan_run(10'h12C, 4, div, "d: GTS[9:8] significant");
         end

         // e. never crosses: WAIT_SYNC, not active, release by clearing the enable
         dif_cfg(PHY_8080, 4'd1, 1'b1, 1'b1, 1'b0);
         scan_seq[0] = 10'h0C8; scan_seq_n = 1; scan_seq_idx = 0; scan_seq_en = 1'b1;
         reg_wr(DIF_SYNC, 32'h0000_8000 | 10'h0C8);
         mark = lg_n;
         reg_wr(REFRESH, 32'h0000_0001);
         repeat(3000) @(posedge free_clk);
         reg_rd_mask(DIF_STATUS, ST_BUSY | ST_WAIT_SYNC, ST_BUSY | ST_WAIT_SYNC);
         reg_rd_mask(STATUS, 32'h0, 32'h1);
         reg_rd_mask(IRQ_FLAG, 32'h0, 32'h3);
         count_polls(mark, np, first_ix);
         if (np < 10) tb_error("e: the engine is not polling while waiting");
         if (first_ix + 4 < lg_n) tb_error("e: something else than polls sent while waiting");
         reg_wr(DIF_SYNC, 32'h0000_0000 | 10'h0C8);   // clear SCAN_SYNC_EN
         reg_poll(REFRESH, 32'h1, 32'h0, 50000);
         dif_wait_idle(50000);
         scan_seq_en = 1'b0;
         reg_rd_mask(DIF_STATUS, 32'h0, ST_WAIT_SYNC);
         count_polls(mark, np, first_ix);
         exp_reset; exp_after_polls(PHY_8080);
         dbi_check_log(first_ix, "e: released by clearing SCAN_SYNC_EN");
         if (frames_in(mark, lg_n) != 1) tb_error("e: released refresh not one CS frame");
         reg_wr(IRQ_FLAG, 32'h3);

         // f. a poll reading SCANLINE itself crosses it: then held, then
         // past it, then through the wrap onto SCANLINE
         scan_seq[0] = 10'h100; scan_seq[1] = 10'h12C; scan_seq[2] = 10'h12C; scan_seq[3] = 10'h12C;
         scan_run(10'h12C, 4, 4'd0, "f1: poll reads SCANLINE, then holds");
         scan_seq[0] = 10'h100; scan_seq[1] = 10'h12C; scan_seq[2] = 10'h130; scan_seq[3] = 10'h130;
         scan_run(10'h12C, 4, 4'd0, "f2: poll reads SCANLINE, then passes");
         scan_seq[0] = 10'h120; scan_seq[1] = 10'h13A; scan_seq[2] = 10'h005; scan_seq[3] = 10'h010;
         scan_run(10'h005, 4, 4'd1, "f3: wrap onto SCANLINE");

         // f5. scanlines above 511 (GTS[9] set), SCANLINE 0x2A0
         scan_seq[0] = 10'h0A0; scan_seq[1] = 10'h280; scan_seq[2] = 10'h29F; scan_seq[3] = 10'h2A0;
         scan_seq[4] = 10'h3FF;
         scan_run(10'h2A0, 5, 4'd0, "f5: scanlines above 511");

         // f4. HW_WINDOW_EN = 0: polls, then 0x2C and the pixels
         scan_hw = 1'b0;
         scan_seq[0] = 10'h105; scan_seq[1] = 10'h111; scan_seq[2] = 10'h13F; scan_seq[3] = 10'h010;
         scan_run(10'h12C, 4, 4'd0, "f4: no hardware window");
         scan_seq[0] = 10'h020; scan_seq[1] = 10'h110; scan_seq[2] = 10'h135; scan_seq[3] = 10'h010;
         scan_run(10'h12C, 4, 4'd3, "f4: no hardware window, CLK_DIV 3");
         scan_hw = 1'b1;

         // g. slow polls (CLK_DIV 15) on a free-running scan still start
         dif_cfg(PHY_8080, 4'd15, 1'b1, 1'b1, 1'b0);
         u_lcd8080.scan_period = 70;                   // 7 cycles per line
         u_lcd8080.scan_total  = 330;
         u_lcd8080.scanline    = 10'd10;
         u_lcd8080.scan_auto   = 1'b1;
         reg_wr(DIF_SYNC, 32'h0000_8000 | 10'd200);
         mark = lg_n;
         reg_wr(REFRESH, 32'h0000_0001);
         reg_poll(REFRESH, 32'h1, 32'h0, 50000);
         dif_wait_idle(50000);
         u_lcd8080.scan_auto = 1'b0;
         count_polls(mark, np, first_ix);
         $display("INFO:  g: free-running scan, CLK_DIV 15: started after %0d polls", np);
         if (np < 2) tb_error("g: started on the first poll");
         exp_reset; exp_after_polls(PHY_8080);
         dbi_check_log(first_ix, "g: slow polls, free-running scan");
         reg_wr(DIF_SYNC, 32'h0);
         reg_wr(IRQ_FLAG, 32'h3);

         // h. SCAN wins over TE on 8080: TE edges during the polls do not start it
         scan_seq[0] = 10'h100; scan_seq[1] = 10'h101; scan_seq[2] = 10'h102; scan_seq[3] = 10'h103;
         scan_seq[4] = 10'h104; scan_seq[5] = 10'h105; scan_seq[6] = 10'h106; scan_seq[7] = 10'h140;
         scan_seq_n = 8; scan_seq_idx = 0; scan_seq_en = 1'b1;
         dif_cfg(PHY_8080, 4'd3, 1'b1, 1'b1, 1'b0);
         reg_wr(DIF_SYNC, 32'h0001_8000 | 10'h12C);    // SCAN + TE
         mark = lg_n; poll0 = poll_nr;
         reg_wr(REFRESH, 32'h0000_0001);
         while (poll_nr - poll0 < 2) @(negedge free_clk);
         for (kk = 0; kk < 3; kk = kk + 1) begin
            lcd_te = 1'b1; repeat(6) @(posedge free_clk);
            lcd_te = 1'b0; repeat(6) @(posedge free_clk);
         end
         reg_poll(REFRESH, 32'h1, 32'h0, 50000);
         dif_wait_idle(50000);
         scan_seq_en = 1'b0;
         count_polls(mark, np, first_ix);
         if (np != 8) begin
            $display("ERROR: h: SCAN + TE on 8080 -- started after %0d polls / expected 8 (TE ignored) %t", np, $time);
            error = error + 1;
         end
         exp_reset; exp_after_polls(PHY_8080);
         dbi_check_log(first_ix, "h: SCAN wins over TE");
         reg_wr(DIF_SYNC, 32'h0);
         reg_wr(IRQ_FLAG, 32'h3);
      end

      // SPI: SCAN_SYNC_EN ignored, the refresh starts at once
      if (HAS_SPI) begin
         dif_cfg(PHY_SPI, 4'd0, 1'b1, 1'b1, 1'b0);
         reg_wr(DIF_SYNC, 32'h0000_8000 | 10'h12C);
         mark = lg_n; exp_reset;
         exp_window(PHY_SPI, SW, SH, 1'b1);
         exp_cmd(PHY_SPI, 8'h2C, 1'b1);
         for (yy = 0; yy < SH; yy = yy + 1)
           for (xx = 0; xx < SW; xx = xx + 1)
             exp_px(PHY_SPI, pix16(xx, yy));
         reg_wr(REFRESH, 32'h0000_0001);
         reg_rd_mask(DIF_STATUS, 32'h0, ST_WAIT_SYNC);
         reg_poll(REFRESH, 32'h1, 32'h0, 5000);
         dif_wait_idle(5000);
         dbi_check_log(mark, "SPI: SCAN_SYNC_EN ignored");
         if (lcd_rd_n !== 1'b1) tb_error("SPI refresh drove the 8080 RD strobe");
         reg_wr(DIF_SYNC, 32'h0);
      end

      if (HAS_8080 && (m8_ta_n < 20)) tb_error("8080 read-to-write turnaround measured too rarely");
      $display("INFO:  %0d 8080 read-to-write turnarounds measured", m8_ta_n);
      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
