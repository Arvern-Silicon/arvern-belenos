//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_fifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_fifo.v
// Module Description : DBI driver PARAM FIFO and command / DFILL slots, on
//                      every PHY of the build:
//                       A. FIFO full with no consumer: the 17th DIF_PARAM is
//                          dropped with zero wait (PARAM_FULL, level 16,
//                          PARAM_OVFL and CMD_OVFL set, both W1C) and a
//                          16-parameter command then sends the first 16.
//                       B. running command needing more parameters: a write
//                          to the full FIFO is dropped at once (PARAM_OVFL);
//                          writes after PARAM_FULL reads 0 lose none (20
//                          params).
//                       C. queued command needing more than the FIFO holds,
//                          behind a running DFILL: the 17th write is dropped
//                          at once (PARAM_OVFL), written again after
//                          PARAM_FULL reads 0, and the command sends all 17.
//                       D. queued command needing fewer than the FIFO holds:
//                          the 17th write is dropped at once (PARAM_OVFL);
//                          the parameters left over are the next command's
//                          first ones, in order.
//                       E. DFILL running, nothing queued: dropped, zero wait.
//                       F. DIF_CMD / DIF_DFILL into an occupied slot: zero
//                          wait, dropped, CMD_OVFL (IRQ through DIF_IRQ_EN),
//                          CMD_PENDING / DFILL_PENDING / DFILL_BUSY.
//                       G. delay sweep of a DIF_CMD write around the moment
//                          the slot empties: accepted xor CMD_OVFL, monotonic.
//                       H. queued command behind a refresh waiting for TE:
//                          a write to the full FIFO is dropped at once
//                          (PARAM_FULL, PARAM_OVFL), not held until a TE edge.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

localparam integer FW = 16;
localparam integer FH = 8;

integer    phy_i, kk, nn, mark, waits_max, cyc_wr, acc_first, h_cyc;
reg        phy;
reg  [3:0] div;
reg [31:0] rd;
reg [15:0] pv;
reg        accepted, ovfl, h_done;

function [15:0] pval;
   input integer i;
   begin
      pval = (i * 16'h0A13) ^ 16'hC35A;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        DBI: PARAM FIFO AND COMMAND SLOTS      |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(DISP_SIZE, (FH << 16) | FW);

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (phy == PHY_8080) ? "8080" : "SPI");

            //---------------------------------------------------------------
            // A. no consumer: drop
            dif_cfg(phy, 4'd0, 1'b0, 1'b1, 1'b0);
            mark = lg_n;
            for (kk = 0; kk < 16; kk = kk + 1) reg_wr(DIF_PARAM, {16'h0, pval(kk)});
            reg_rd_mask(DIF_STATUS, 32'h0000_1004, ST_LEVEL | ST_PARAM_FULL | ST_BUSY);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            reg_wr(DIF_PARAM, 32'h0000_DEAD);
            if (ahb_last_waits != 0) tb_error("A: DIF_PARAM to a full FIFO with no consumer waited");
            reg_rd_mask(DIF_STATUS, 32'h0000_1004 | ST_PARAM_OVFL, ST_LEVEL | ST_PARAM_FULL | ST_BUSY | ST_PARAM_OVFL);
            reg_rd(DIF_IRQ_FLAG, 32'h4);                  // a dropped parameter is a CMD_OVFL too
            reg_wr(DIF_STATUS, ~ST_PARAM_OVFL);           // other bits: no effect
            reg_rd_mask(DIF_STATUS, 32'h0000_1004 | ST_PARAM_OVFL, ST_LEVEL | ST_PARAM_FULL | ST_BUSY | ST_PARAM_OVFL);
            reg_wr(DIF_STATUS, ST_PARAM_OVFL);            // W1C
            reg_rd_mask(DIF_STATUS, 32'h0000_1004, ST_LEVEL | ST_PARAM_FULL | ST_BUSY | ST_PARAM_OVFL);
            reg_wr(DIF_IRQ_FLAG, 32'h4);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            if (lg_n != mark) tb_error("A: parameters sent without a command");
            exp_reset;
            exp_cmd(phy, 8'hE1, 1'b1);
            for (kk = 0; kk < 16; kk = kk + 1) exp_par(phy, pval(kk));
            reg_wr(DIF_CMD, 32'h0000_10E1);
            dif_wait_idle(400);
            reg_rd_mask(DIF_STATUS, 32'h0, ST_LEVEL | ST_PARAM_FULL);
            dbi_check_log(mark, "A: FIFO full, 17th dropped");
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            //---------------------------------------------------------------
            // B. running command consuming: writes wait, nothing lost
            div = (phy == PHY_8080) ? 4'd15 : 4'd3;
            dif_cfg(phy, div, 1'b0, 1'b1, 1'b0);
            mark = lg_n; exp_reset;
            exp_cmd(phy, 8'hE0, 1'b1);
            waits_max = 0;
            nn        = 0;
            for (kk = 0; kk < 16; kk = kk + 1) begin     // preload (as blns_dbi_cmd)
               exp_par(phy, pval(kk + 100));
               reg_wr(DIF_PARAM, {16'h0, pval(kk + 100)});
            end
            reg_wr(DIF_PARAM, 32'h0000_DEAD);            // to the full FIFO: dropped at once
            if (ahb_last_waits != 0) tb_error("B: DIF_PARAM to the full FIFO waited");
            reg_rd_mask(DIF_STATUS, ST_PARAM_OVFL | ST_PARAM_FULL, ST_PARAM_OVFL | ST_PARAM_FULL);
            reg_wr(DIF_STATUS, ST_PARAM_OVFL);
            reg_wr(DIF_CMD, 32'h0000_14E0);              // 20 params
            for (kk = 16; kk < 20; kk = kk + 1) begin
               exp_par(phy, pval(kk + 100));
               reg_rd_val(DIF_STATUS, rd);
               if (rd & ST_PARAM_FULL) nn = nn + 1;
               reg_poll(DIF_STATUS, ST_PARAM_FULL, 32'h0, 20000);
               reg_wr(DIF_PARAM, {16'h0, pval(kk + 100)});
               if (ahb_last_waits > waits_max) waits_max = ahb_last_waits;
            end
            if (waits_max != 0) tb_error("B: a DIF_PARAM write waited");
            if (nn == 0) tb_error("B: the FIFO was never full (no drain wait exercised)");
            dif_wait_idle(20000);
            reg_rd_mask(DIF_STATUS, 32'h0, ST_PARAM_OVFL);
            dbi_check_log(mark, "B: running command, writes after PARAM_FULL");
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            //---------------------------------------------------------------
            // C. queued command needing 17 behind a running DFILL
            dif_cfg(phy, 4'd0, 1'b0, 1'b1, 1'b0);
            mark = lg_n; exp_reset;
            exp_dfill(phy, FW, FH, 24'h12_34_56, 1'b0);
            reg_wr(DIF_DFILL, 32'h0012_3456);
            reg_rd_mask(DIF_STATUS, ST_BUSY | ST_DFILL_BUSY, ST_BUSY | ST_DFILL_BUSY | ST_DFILL_PEND);
            reg_wr(DIF_CMD, 32'h0000_11E2);              // 17 params, queued
            reg_rd_mask(DIF_STATUS, ST_CMD_PEND, ST_CMD_PEND);
            exp_cmd(phy, 8'hE2, 1'b1);
            for (kk = 0; kk < 16; kk = kk + 1) begin
               exp_par(phy, pval(kk + 200));
               reg_wr(DIF_PARAM, {16'h0, pval(kk + 200)});
            end
            reg_rd_mask(DIF_STATUS, 32'h0000_1004 | ST_DFILL_BUSY, ST_LEVEL | ST_PARAM_FULL | ST_DFILL_BUSY);
            exp_par(phy, pval(216));
            reg_wr(DIF_PARAM, 32'h0000_DEAD);            // the 17th: dropped at once
            if (ahb_last_waits != 0) tb_error("C: 17th DIF_PARAM (queued command needs it) waited");
            reg_rd_mask(DIF_STATUS, 32'h0000_1004 | ST_DFILL_BUSY | ST_PARAM_OVFL,
                        ST_LEVEL | ST_PARAM_FULL | ST_DFILL_BUSY | ST_PARAM_OVFL);
            reg_wr(DIF_STATUS, ST_PARAM_OVFL);
            reg_poll(DIF_STATUS, ST_PARAM_FULL, 32'h0, 20000);
            reg_wr(DIF_PARAM, {16'h0, pval(216)});       // written again
            dif_wait_idle(20000);
            reg_rd_mask(DIF_STATUS, 32'h0, ST_LEVEL | ST_PARAM_OVFL);
            reg_rd(DIF_IRQ_FLAG, 32'h5);                 // CMD_DONE, CMD_OVFL of the drop
            dbi_check_log(mark, "C: queued command, 17th dropped then written");
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            //---------------------------------------------------------------
            // D. queued command needing 2 with the FIFO full: the 17th write
            // dropped; the 14 parameters left over go out, in order, as the
            // first ones of the next command
            mark = lg_n; exp_reset;
            exp_dfill(phy, FW, FH, 24'h65_43_21, 1'b0);
            exp_cmd(phy, 8'hE3, 1'b1);
            exp_par(phy, pval(300)); exp_par(phy, pval(301));
            exp_cmd(phy, 8'h00, 1'b1);
            for (kk = 2; kk < 16; kk = kk + 1) exp_par(phy, pval(kk + 300));
            reg_wr(DIF_DFILL, 32'h0065_4321);
            reg_wr(DIF_CMD, 32'h0000_02E3);
            for (kk = 0; kk < 16; kk = kk + 1) reg_wr(DIF_PARAM, {16'h0, pval(kk + 300)});
            reg_wr(DIF_PARAM, 32'h0000_BEEF);
            if (ahb_last_waits != 0) tb_error("D: 17th DIF_PARAM with a queued 2-param command waited");
            reg_rd_mask(DIF_STATUS, ST_PARAM_OVFL, ST_PARAM_OVFL);
            reg_wr(DIF_STATUS, ST_PARAM_OVFL);
            dif_wait_idle(20000);
            reg_rd_val(DIF_STATUS, rd);
            if (rd[12:8] != 5'd14) tb_error("D: level after the 2-param command is not 14 (17th dropped)");
            // flush the FIFO leftovers with one command
            reg_wr(DIF_CMD, {16'h0, rd[15:8], 8'h00});
            dif_wait_idle(20000);
            reg_rd_mask(DIF_STATUS, 32'h0, ST_LEVEL);
            dbi_check_log(mark, "D: leftovers lead the next command");
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            //---------------------------------------------------------------
            // E. DFILL running, nothing queued: drop with zero wait
            mark = lg_n; exp_reset;
            exp_dfill(phy, FW, FH, 24'hFF_FF_FF, 1'b0);
            exp_cmd(phy, 8'hE4, 1'b1);
            for (kk = 0; kk < 16; kk = kk + 1) exp_par(phy, pval(kk + 400));
            reg_wr(DIF_DFILL, 32'h00FF_FFFF);
            for (kk = 0; kk < 16; kk = kk + 1) reg_wr(DIF_PARAM, {16'h0, pval(kk + 400)});
            reg_wr(DIF_PARAM, 32'h0000_DEAD);
            if (ahb_last_waits != 0) tb_error("E: DIF_PARAM to a full FIFO during a DFILL waited");
            reg_rd_mask(DIF_STATUS, 32'h0000_1004 | ST_DFILL_BUSY | ST_PARAM_OVFL,
                        ST_LEVEL | ST_PARAM_FULL | ST_DFILL_BUSY | ST_PARAM_OVFL);
            reg_wr(DIF_STATUS, ST_PARAM_OVFL);
            dif_wait_idle(20000);
            reg_wr(DIF_CMD, 32'h0000_10E4);
            dif_wait_idle(20000);
            dbi_check_log(mark, "E: DFILL running, 17th dropped");
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            //---------------------------------------------------------------
            // F. slot overflow
            reg_wr(DIF_IRQ_EN, 32'h0000_0004);           // CMD_OVFL
            reg_wr(IRQ_EN,     32'h0000_0100);
            mark = lg_n; exp_reset;
            exp_cmd(phy, 8'hB0, 1'b1); exp_par(phy, 16'h0042);   // X, waits for its param
            exp_dfill(phy, FW, FH, 24'h80_40_20, 1'b0);          // D1 (priority)
            exp_cmd(phy, 8'hB1, 1'b1);                           // Y
            reg_wr(DIF_CMD, 32'h0000_01B0);              // X
            repeat(40) @(posedge free_clk);
            reg_rd_mask(DIF_STATUS, ST_BUSY, ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND | ST_DFILL_BUSY);
            reg_wr(DIF_CMD, 32'h0000_00B1);              // Y queued
            if (ahb_last_waits != 0) tb_error("F: DIF_CMD into a free slot waited");
            reg_rd_mask(DIF_STATUS, ST_BUSY | ST_CMD_PEND, ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            reg_wr(DIF_CMD, 32'h0000_00B2);              // Z: dropped
            if (ahb_last_waits != 0) tb_error("F: DIF_CMD into an occupied slot waited");
            reg_rd(DIF_IRQ_FLAG, 32'h4);
            @(negedge free_clk);
            if (irq !== 1'b1) tb_error("F: irq_o not raised by CMD_OVFL");
            reg_wr(DIF_IRQ_FLAG, 32'h4);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            @(negedge free_clk);
            if (irq !== 1'b0) tb_error("F: irq_o still high after the CMD_OVFL W1C");
            reg_wr(DIF_DFILL, 32'h0080_4020);            // D1 queued
            if (ahb_last_waits != 0) tb_error("F: DIF_DFILL into a free slot waited");
            reg_rd_mask(DIF_STATUS, ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND, ST_BUSY | ST_CMD_PEND | ST_DFILL_PEND | ST_DFILL_BUSY);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            reg_wr(DIF_DFILL, 32'h0011_1111);            // D2: dropped
            if (ahb_last_waits != 0) tb_error("F: DIF_DFILL into an occupied slot waited");
            reg_rd(DIF_IRQ_FLAG, 32'h4);
            reg_wr(DIF_IRQ_FLAG, 32'h4);
            if (lg_n - mark != 1) tb_error("F: items other than X's command byte sent while X waits");
            reg_wr(DIF_PARAM, 32'h0000_0042);            // release X
            dif_wait_idle(20000);
            reg_rd(DIF_IRQ_FLAG, 32'h1);                 // CMD_DONE only, no new overflow
            dbi_check_log(mark, "F: slot overflow drops Z and D2");
            reg_wr(DIF_IRQ_FLAG, 32'h7);
            reg_wr(DIF_IRQ_EN, 32'h0);

            //---------------------------------------------------------------
            // G. delay sweep around the slot emptying
            acc_first = -1;
            for (nn = 0; nn < 24; nn = nn + 1) begin
               mark = lg_n;
               reg_wr(DIF_CMD, 32'h0000_01C0);           // X waits for 1 param
               repeat(20) @(posedge free_clk);
               reg_wr(DIF_CMD, 32'h0000_00C1);           // Y queued
               reg_wr(DIF_PARAM, 32'h0000_0001);         // X completes, Y starts
               repeat(nn) @(posedge free_clk);
               reg_wr(DIF_CMD, 32'h0000_00C2);           // Z
               if (ahb_last_waits != 0) tb_error("G: DIF_CMD waited");
               dif_wait_idle(400);
               reg_rd_val(DIF_IRQ_FLAG, rd);
               ovfl     = rd[2];
               accepted = 1'b0;
               for (kk = mark; kk < lg_n; kk = kk + 1)
                  if ((lg_kind[kk] == K_CMD) && (lg_data[kk][7:0] == 8'hC2)) accepted = 1'b1;
               if (accepted == ovfl) begin
                  $display("ERROR: G: delay %0d -- Z accepted %0d and CMD_OVFL %0d (exactly one expected) %t", nn, accepted, ovfl, $time);
                  error = error + 1;
               end
               if (accepted && (acc_first < 0)) acc_first = nn;
               if (!accepted && (acc_first >= 0)) begin
                  $display("ERROR: G: delay %0d -- Z dropped after being accepted at delay %0d %t", nn, acc_first, $time);
                  error = error + 1;
               end
               reg_wr(DIF_IRQ_FLAG, 32'h7);
            end
            $display("INFO:  G: Z first accepted with %0d idle cycles after the releasing DIF_PARAM", acc_first);
            if (acc_first < 0) tb_error("G: Z never accepted");

            //---------------------------------------------------------------
            // H. queued command behind a refresh waiting for a TE edge that
            // does not come: a write to the full FIFO is dropped at once
            // (PARAM_FULL), never held for the sync wait
            reg_wr(DISP_SIZE, (2 << 16) | 4);
            reg_wr(DIF_SYNC, 32'h0001_0000);             // TE sync, lcd_te low
            reg_wr(REFRESH, 32'h0000_0001);
            reg_poll(DIF_STATUS, ST_WAIT_SYNC, ST_WAIT_SYNC, 2000);
            reg_wr(DIF_CMD, 32'h0000_11E4);              // 17 params, queued behind the refresh
            for (kk = 0; kk < 16; kk = kk + 1) reg_wr(DIF_PARAM, {16'h0, pval(kk + 400)});
            h_done = 1'b0;
            fork
               begin
                  reg_wr(DIF_PARAM, {16'h0, pval(416)});
                  h_done = 1'b1;
               end
               begin
                  h_cyc = 0;
                  while (!h_done && (h_cyc < 3000)) begin @(posedge free_clk); h_cyc = h_cyc + 1; end
                  if (!h_done) begin
                     tb_error("H: DIF_PARAM held while the refresh waits for TE");
                     @(negedge free_clk); lcd_te = 1'b1;   // release the bus
                     repeat(6) @(posedge free_clk); lcd_te = 1'b0;
                  end
               end
            join
            reg_rd_mask(DIF_STATUS, ST_WAIT_SYNC | ST_PARAM_FULL | ST_CMD_PEND | ST_PARAM_OVFL,
                        ST_WAIT_SYNC | ST_PARAM_FULL | ST_CMD_PEND | ST_PARAM_OVFL);
            reg_wr(DIF_STATUS, ST_PARAM_OVFL);
            @(negedge free_clk); lcd_te = 1'b1;          // the frame, then the command
            repeat(6) @(posedge free_clk); lcd_te = 1'b0;
            reg_poll(DIF_STATUS, ST_PARAM_FULL, 32'h0, 20000);
            reg_wr(DIF_PARAM, {16'h0, pval(416)});       // the dropped one, again
            dif_wait_idle(20000);
            reg_rd_mask(DIF_IRQ_FLAG, 32'h5, 32'h5);       // CMD_DONE, CMD_OVFL of the drop
            reg_wr(DIF_IRQ_FLAG, 32'h7);
            reg_wr(DIF_SYNC, 32'h0);
            reg_wr(DISP_SIZE, (FH << 16) | FW);
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
