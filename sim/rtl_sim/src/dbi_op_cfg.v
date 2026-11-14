//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_op_cfg
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_op_cfg.v
// Module Description : DIF_CFG.CLK_DIV, RD_DIV and HW_WINDOW_EN are taken at
//                      the start of each DBI operation. On every PHY of the
//                      build, DIF_CFG is rewritten while an operation runs;
//                      the protocol monitors keep the old dividers until the
//                      operation is over, so a strobe or SCK phase at the new
//                      length is an error. Then the next operation must run
//                      at the new values:
//                      1. a command with 8 parameters, CLK_DIV 2 -> 5 once CS
//                         is low; the next command at CLK_DIV 5;
//                      2. a refresh (8 x 4 pixels), CLK_DIV 1 -> 4 once CS
//                         is low; the next refresh at CLK_DIV 4;
//                      3. (8080) a refresh with scanline sync and
//                         HW_WINDOW_EN 1, RD_DIV 2 -> 6 and HW_WINDOW_EN 1 -> 0
//                         at the first read strobe: the polls keep RD_DIV 2
//                         and the frame keeps its CASET / PASET; the next
//                         refresh polls at RD_DIV 6 without a window.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    oc_phy_i, oc_c0, oc_p0;
reg        oc_phy;

// DIF_CFG written behind the monitors' back (they keep the old dividers)
task oc_cfg_raw;
   input        phy_sel;
   input  [3:0] div;
   input  [3:0] rd_div;
   input        hw_win;
   begin
      reg_wr(DIF_CFG, {19'h0, hw_win, div, rd_div, 1'b0, phy_sel, 1'b0, 1'b1});
   end
endtask

// The operation must still be running after the DIF_CFG write
task oc_check_busy;
   input [40*8-1:0] what;
   begin
      reg_rd_mask(DIF_STATUS, ST_BUSY, ST_BUSY);
   end
endtask

task oc_wait_cs;
   input phy;
   begin
      if (phy == PHY_8080) wait (lcd_cs_n === 1'b0);
      else                 wait (spi_cs_n === 1'b0);
   end
endtask

task oc_refresh;
   begin
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      reg_wr(IRQ_FLAG, 32'h3);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DBI: SETTINGS TAKEN PER OPERATION (CFG)     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (4 << 16) | 8);
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);

      for (oc_phy_i = 0; oc_phy_i < 2; oc_phy_i = oc_phy_i + 1) begin
         oc_phy = oc_phy_i;
         if (((oc_phy == PHY_8080) && HAS_8080) || ((oc_phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (oc_phy == PHY_8080) ? "8080" : "SPI");

            // 1. command
            dif_cfg(oc_phy, 4'd2, 1'b0, 1'b1, 1'b0);
            for (oc_c0 = 0; oc_c0 < 8; oc_c0 = oc_c0 + 1)
              reg_wr(DIF_PARAM, 32'h0000_0010 + oc_c0);
            reg_wr(DIF_CMD, 32'h0000_08B6);
            oc_wait_cs(oc_phy);
            oc_cfg_raw(oc_phy, 4'd5, 4'd0, 1'b0);
            oc_check_busy("command");
            dif_wait_idle(50000);
            dbi_div = 5; dbi_rdiv = 5;
            reg_wr(DIF_PARAM, 32'h0000_0055);
            reg_wr(DIF_CMD, 32'h0000_013A);
            dif_wait_idle(50000);
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            // 2. refresh
            dif_cfg(oc_phy, 4'd1, 1'b0, 1'b1, 1'b0);
            reg_wr(REFRESH, 32'h0000_0001);
            oc_wait_cs(oc_phy);
            oc_cfg_raw(oc_phy, 4'd4, 4'd0, 1'b0);
            oc_check_busy("refresh");
            reg_poll(REFRESH, 32'h1, 32'h0, 50000);
            dif_wait_idle(50000);
            reg_wr(IRQ_FLAG, 32'h3);
            dbi_div = 4; dbi_rdiv = 4;
            oc_refresh;

            // 3. read divider and window (8080)
            if (oc_phy == PHY_8080) begin
               dif_cfg_rd(PHY_8080, 4'd1, 4'd2, 1'b1, 1'b1, 1'b0);
               scan_seq[0] = 10'h010; scan_seq[1] = 10'h020; scan_seq[2] = 10'h030;
               scan_seq[3] = 10'h040; scan_seq[4] = 10'h050;
               scan_seq_n   = 5;
               scan_seq_idx = 0;
               scan_seq_en  = 1'b1;
               reg_wr(DIF_SYNC, 32'h0000_8000 | 32'h035);
               oc_c0 = u_lcd8080.cmd_count;
               oc_p0 = poll_nr;
               reg_wr(REFRESH, 32'h0000_0001);
               wait (lcd_rd_n === 1'b0);
               oc_cfg_raw(PHY_8080, 4'd1, 4'd6, 1'b0);
               oc_check_busy("refresh with scanline sync");
               reg_poll(REFRESH, 32'h1, 32'h0, 50000);
               dif_wait_idle(50000);
               reg_wr(IRQ_FLAG, 32'h3);
               // 4 x 0x45, then 0x2A, 0x2B, 0x2C
               if ((poll_nr - oc_p0 != 4) || (u_lcd8080.cmd_count - oc_c0 != 7)) begin
                  $display("ERROR: settings changed during the polls: %0d polls, %0d commands / expected 4, 7 (window kept)",
                           poll_nr - oc_p0, u_lcd8080.cmd_count - oc_c0);
                  error = error + 1;
               end
               dbi_div = 1; dbi_rdiv = 6;
               scan_seq_idx = 0;
               oc_c0 = u_lcd8080.cmd_count;
               oc_p0 = poll_nr;
               oc_refresh;
               // 4 x 0x45, then 0x2C
               if ((poll_nr - oc_p0 != 4) || (u_lcd8080.cmd_count - oc_c0 != 5)) begin
                  $display("ERROR: next refresh: %0d polls, %0d commands / expected 4, 5 (no window)",
                           poll_nr - oc_p0, u_lcd8080.cmd_count - oc_c0);
                  error = error + 1;
               end
               scan_seq_en = 1'b0;
               reg_wr(DIF_SYNC, 32'h0);
            end
         end
      end

      dif_cfg(HAS_8080 ? PHY_8080 : PHY_SPI, 4'd0, 1'b0, 1'b0, 1'b0);
      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");

      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
