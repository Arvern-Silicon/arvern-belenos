//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_cmd_refresh
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_cmd_refresh.v
// Module Description : Commands under back-to-back refresh (REFRESH.PERIOD = 1:
//                      every frame ends with the next request latched). A
//                      monitor records the order in which the engine starts
//                      its operations (F fill, R refresh, C command).
//                      1. A command written during a frame is sent after that
//                         frame, and the refresh goes on after it.
//                      2. Two commands written one after the other (each when
//                         the slot is free): a frame between them (C R C), so
//                         commands do not hold the refresh off either.
//                      3. A fill and a command written during a frame: the
//                         fill first, then the command, then the refresh.
//                      Every PHY of the build.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

`define CR_ENG dut.G_DBI.u_dbi.blns_dbi_engine_inst

localparam integer CR_NR = 256;

integer    phy_i, cr_n, cr_mark, cr_k, cr_r;
reg        phy;
reg  [7:0] cr_op [0:CR_NR-1];       // "F", "R", "C" in start order

initial cr_n = 0;

// Operation starts, in order
always @(posedge `CR_ENG.hclk_i)
  if ((DIF_TYPE >= 1) && (DIF_TYPE <= 3) && (cr_n < CR_NR)) begin
     if (`CR_ENG.start_dfill === 1'b1) begin cr_op[cr_n] = "F"; cr_n = cr_n + 1; end
     if (`CR_ENG.start_refr  === 1'b1) begin cr_op[cr_n] = "R"; cr_n = cr_n + 1; end
     if (`CR_ENG.start_cmd   === 1'b1) begin cr_op[cr_n] = "C"; cr_n = cr_n + 1; end
  end

// Wait for a frame in progress
task cr_wait_frame;
   integer nn;
   begin
      nn = 0;
      while ((`CR_ENG.refresh_active_o !== 1'b1) && (nn < 20000)) begin @(posedge free_clk); nn = nn + 1; end
      if (nn >= 20000) tb_error("no refresh frame in progress");
   end
endtask

// Wait until the command slot is free (bounded: a few frames)
task cr_cmd_wait;
   input [8*24-1:0] what;
   begin
      reg_poll(DIF_STATUS, ST_CMD_PEND, 32'h0, 3000);
      if (`CR_ENG.cmd_pend === 1'b1) begin
         $display("ERROR: %0s: the command is still queued under back-to-back refresh", what);
         error = error + 1;
      end
   end
endtask

// The operations started since cr_mark, as a string, against the expected
// prefix (more refreshes may follow it)
task cr_check;
   input [8*8-1:0]  exp;
   input integer    exp_n;
   input [8*24-1:0] what;
   reg   [8*8-1:0]  got;
   begin
      got = 0;
      for (cr_k = 0; (cr_k < exp_n) && (cr_mark + cr_k < cr_n); cr_k = cr_k + 1)
        got = {got[8*7-1:0], cr_op[cr_mark + cr_k]};
      if ((cr_n - cr_mark < exp_n) || (got != exp)) begin
         $display("ERROR: %0s: operations started %0s, expected %0s", what, got, exp);
         error = error + 1;
      end else
         $display("OK:    %0s: %0s", what, got);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DBI: COMMANDS UNDER BACK-TO-BACK REFRESH    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (4 << 16) | 8);
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (phy == PHY_8080) ? "8080" : "SPI");
            dif_cfg(phy, 4'd0, 1'b1, 1'b1, 1'b0);
            reg_wr(REFRESH, (32'd1 << 4) | 32'h1);       // PERIOD 1: requests continuously

            // 1. a command during a frame: sent after it, the refresh goes on
            cr_wait_frame;
            cr_mark = cr_n;
            reg_wr(DIF_CMD, 32'h0000_00C9);
            cr_cmd_wait("command during a frame");
            cr_wait_frame;
            repeat (2) begin
               while (`CR_ENG.refresh_active_o === 1'b1) @(posedge free_clk);
               cr_wait_frame;
            end
            cr_check("CR", 2, "command during a frame");

            // 2. two commands back to back: a frame between them
            cr_wait_frame;
            cr_mark = cr_n;
            reg_wr(DIF_CMD, 32'h0000_00CA);
            cr_cmd_wait("first of two commands");
            reg_wr(DIF_CMD, 32'h0000_00CB);
            cr_cmd_wait("second of two commands");
            cr_wait_frame;
            cr_check("CRCR", 4, "two commands");

            // 3. a fill and a command during a frame: fill, command, refresh
            while (`CR_ENG.refresh_active_o === 1'b1) @(posedge free_clk);
            cr_wait_frame;
            cr_mark = cr_n;
            reg_wr(DIF_DFILL, 32'h0012_3456);
            reg_wr(DIF_CMD,   32'h0000_00CC);
            if (`CR_ENG.refresh_active_o !== 1'b1)
               tb_error("case 3: the frame ended before the fill and the command were queued");
            cr_cmd_wait("fill and command");
            cr_wait_frame;
            cr_check("FCR", 3, "fill and command");

            reg_wr(REFRESH, 32'h0000_0000);
            dif_wait_idle(50000);
            reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
            reg_wr(DIF_IRQ_FLAG, 32'h7);
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
