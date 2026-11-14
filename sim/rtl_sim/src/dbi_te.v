//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_te
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_te.v
// Module Description : DBI driver TE synchronisation (DIF_SYNC.TE_SYNC_EN) on
//                      every PHY of the build. A refresh waits (WAIT_SYNC = 1,
//                      nothing sent, refresh not active) until a rising edge
//                      of lcd_te_i, then sends window + 0x2C + pixels, all
//                      after the edge. TE already high when the wait starts
//                      does not start it (a new edge is needed). Clearing
//                      TE_SYNC_EN releases the wait. On SPI, SCAN_SYNC_EN +
//                      TE_SYNC_EN uses TE (scanline ignored). A TE pulse while
//                      idle is not remembered: the refresh after it waits for
//                      a new edge. CS stays high on both PHYs during every
//                      wait. On 8080,
//                      switching to scanline sync during the TE wait polls
//                      the scanline before the frame.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

localparam integer TW = 3;
localparam integer TH = 2;

integer    phy_i, kk, xx, yy, mark, te_cyc, f_first, cs8, css;
reg        phy;
reg [15:0] pa, pb;

function [15:0] pix16;
   input integer x;
   input integer y;
   begin
      pix16 = 16'h1248 ^ (x * 16'h2121) ^ (y * 16'h4005);
   end
endfunction

task exp_refresh;
   begin
      exp_window(phy, TW, TH, 1'b1);
      exp_cmd(phy, 8'h2C, phy == PHY_SPI);
      for (yy = 0; yy < TH; yy = yy + 1)
        for (xx = 0; xx < TW; xx = xx + 1)
          exp_px(phy, pix16(xx, yy));
   end
endtask

task te_pulse;
   begin
      @(negedge free_clk);
      lcd_te = 1'b1;
      te_cyc = dbi_cyc;
      repeat(6) @(posedge free_clk);
      lcd_te = 1'b0;
      repeat(6) @(posedge free_clk);
   end
endtask

// Refresh waiting: check nothing was sent and the status
task check_waiting;
   input [40*8-1:0] what;
   begin
      cs8 = m8_cs_lo_cyc; css = ms_cs_lo_cyc;
      repeat(600) @(posedge free_clk);
      if ((m8_cs_lo_cyc != cs8) || (ms_cs_lo_cyc != css)) begin
         $display("ERROR: %0s -- CS low for %0d cycles while waiting for TE %t", what,
                  m8_cs_lo_cyc - cs8 + ms_cs_lo_cyc - css, $time);
         error = error + 1;
      end
      if (lg_n != mark) begin
         $display("ERROR: %0s -- %0d panel items sent while waiting for TE %t", what, lg_n - mark, $time);
         error = error + 1;
      end
      reg_rd_mask(DIF_STATUS, ST_BUSY | ST_WAIT_SYNC, ST_BUSY | ST_WAIT_SYNC);
      reg_rd_mask(STATUS, 32'h0, 32'h1);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h3);
   end
endtask

task finish_refresh;
   input [40*8-1:0] what;
   begin
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      reg_rd_mask(DIF_STATUS, 32'h0, ST_WAIT_SYNC);
      exp_reset; exp_refresh;
      dbi_check_log(mark, what);
      reg_wr(IRQ_FLAG, 32'h3);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|            DBI: TE SYNCHRONISATION            |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (TH << 16) | TW);
      reg_wr(FRAME0_PTR, 32'h0);
      for (kk = 0; kk < TW*TH; kk = kk + 2) begin
         pa = pix16(kk % TW, kk / TW);
         pb = pix16((kk + 1) % TW, (kk + 1) / TW);
         vram_wr(2*kk, {pb, pa}, SZ_W);
      end

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (phy == PHY_8080) ? "8080" : "SPI");
            dif_cfg(phy, 4'd1, 1'b1, 1'b1, 1'b0);

            // a. wait for a TE rising edge
            reg_wr(DIF_SYNC, 32'h0001_0000);
            mark = lg_n;
            reg_wr(REFRESH, 32'h0000_0001);
            check_waiting("a: TE low");
            te_pulse;
            finish_refresh("a: refresh after the TE edge");
            if (lg_cyc[mark] <= te_cyc) tb_error("a: refresh items before the TE rising edge");

            // b. TE already high when the wait starts: no start without a new edge
            @(negedge free_clk); lcd_te = 1'b1;
            repeat(20) @(posedge free_clk);
            mark = lg_n;
            reg_wr(REFRESH, 32'h0000_0001);
            check_waiting("b: TE held high");
            @(negedge free_clk); lcd_te = 1'b0;
            repeat(6) @(posedge free_clk);
            if (lg_n != mark) tb_error("b: TE falling edge started the refresh");
            te_pulse;
            finish_refresh("b: refresh after a new TE edge");
            if (lg_cyc[mark] <= te_cyc) tb_error("b: refresh items before the new TE rising edge");

            // c. release by clearing TE_SYNC_EN
            mark = lg_n;
            reg_wr(REFRESH, 32'h0000_0001);
            check_waiting("c: TE low");
            reg_wr(DIF_SYNC, 32'h0000_0000);
            finish_refresh("c: released by clearing TE_SYNC_EN");

            // d. SPI: SCAN + TE uses TE
            if (phy == PHY_SPI) begin
               reg_wr(DIF_SYNC, 32'h0001_8000 | 10'h100);
               mark = lg_n;
               reg_wr(REFRESH, 32'h0000_0001);
               check_waiting("d: SPI SCAN + TE, TE low");
               te_pulse;
               finish_refresh("d: SPI SCAN + TE refresh after TE");
               if (lg_cyc[mark] <= te_cyc) tb_error("d: refresh items before the TE rising edge");
            end

            // e. TE edge while idle is not remembered: the refresh after it
            // waits for a new edge
            reg_wr(DIF_SYNC, 32'h0001_0000);
            te_pulse;
            repeat(20) @(posedge free_clk);
            mark = lg_n;
            reg_wr(REFRESH, 32'h0000_0001);
            check_waiting("e: TE pulse while idle");
            te_pulse;
            finish_refresh("e: refresh after a new TE edge");
            if (lg_cyc[mark] <= te_cyc) tb_error("e: refresh items before the new TE rising edge");
            reg_wr(DIF_SYNC, 32'h0);

            // f. 8080: switching to scanline sync during the TE wait polls the
            // scanline before the frame (not an unsynchronised frame)
            if (phy == PHY_8080) begin
               reg_wr(DIF_SYNC, 32'h0001_0000);
               mark = lg_n;
               reg_wr(REFRESH, 32'h0000_0001);
               check_waiting("f: TE low");
               u_lcd8080.scan_period = 70;                  // free-running scan
               u_lcd8080.scan_total  = 330;
               u_lcd8080.scanline    = 10'd10;
               u_lcd8080.scan_auto   = 1'b1;
               reg_wr(DIF_SYNC, 32'h0001_8000 | 10'd200);
               reg_poll(REFRESH, 32'h1, 32'h0, 200000);
               dif_wait_idle(200000);
               reg_wr(IRQ_FLAG, 32'h3);
               f_first = -1;
               for (kk = mark; kk < lg_n; kk = kk + 1)
                  if ((f_first < 0) && (lg_kind[kk] == K_CMD)) f_first = lg_data[kk][7:0];
               if (f_first != 8'h45)
                  $display("ERROR: f: first command after the switch 0x%h / expected a scanline poll (0x45) %t", f_first, $time);
               if (f_first != 8'h45) error = error + 1;
               u_lcd8080.scan_auto = 1'b0;
               reg_wr(DIF_SYNC, 32'h0);
            end
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
