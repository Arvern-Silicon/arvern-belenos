//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_regs
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_regs.v
// Module Description : DBI driver register window (0x180-0x1FC): reset values,
//                      write masks, PHY_SEL writable only with DIF_TYPE 3
//                      (fixed 1 / 0 with DIF_TYPE 1 / 2), DIF_STATUS not set by a write,
//                      DIF_IRQ_FLAG not settable by a write, offsets 0x20-0x7C
//                      read 0 / write ignored with zero wait, LCD_ON and
//                      LCD_RESET driving lcd_on_o / lcd_reset_n_o, PARAM_LEVEL,
//                      STATUS.DIF_BUSY with only the TE interrupt armed, the
//                      write-only DIF_CMD, DIF_PARAM and DIF_DFILL reading 0, and a
//                      reset asserted in the middle of a command: every
//                      register and pin returns to its reset value and the
//                      next command is clean. The monitors of dbi_model_ext
//                      check the idle levels of an absent PHY all along.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    kk, mark;
reg [31:0] rd;
reg [31:0] phy_fix;          // PHY_SEL read value when not writable
reg [31:0] cfg_mask;
reg        phy;

task check_reset_state;
   begin
      reg_rd(DIF_CFG,      phy_fix);
      reg_rd(DIF_SYNC,     32'h0);
      reg_rd(DIF_STATUS,   32'h0);
      reg_rd(DIF_IRQ_EN,   32'h0);
      reg_rd(DIF_IRQ_FLAG, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h0000_0100);
      reg_rd_mask(STATUS,   32'h0, 32'h0000_0008);
      if (lcd_on      !== 1'b0) tb_error("lcd_on_o not 0 after reset");
      if (lcd_reset_n !== 1'b1) tb_error("lcd_reset_n_o not 1 after reset");
      if (lcd_cs_n    !== 1'b1) tb_error("lcd_cs_n_o not 1 after reset");
      if (spi_cs_n    !== 1'b1) tb_error("spi_cs_n_o not 1 after reset");
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|           DBI: REGISTERS AND PINS             |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      phy_fix  = (DIF_TYPE == 1) ? 32'h0000_0004 : 32'h0000_0000;
      cfg_mask = 32'h0000_1F03;
      phy      = (DIF_TYPE == 1) ? PHY_SPI : PHY_8080;

      // Reset values
      check_reset_state;

      // DIF_CFG write mask and PHY_SEL
      reg_wr(DIF_CFG, 32'hFFFF_FFFF);
      reg_rd(DIF_CFG, (DIF_TYPE == 1) ? 32'h0000_1F07 :      // RD_DIV only with the 8080 PHY
                      (DIF_TYPE == 2) ? 32'h0000_1FF3 : 32'h0000_1FF7);
      @(negedge free_clk);
      if (lcd_on      !== 1'b1) tb_error("lcd_on_o not 1 with LCD_ON = 1");
      if (lcd_reset_n !== 1'b0) tb_error("lcd_reset_n_o not 0 with LCD_RESET = 1");
      reg_wr(DIF_CFG, 32'h0000_0000);
      reg_rd(DIF_CFG, phy_fix);
      reg_wr(DIF_CFG, 32'h0000_0004);
      reg_rd(DIF_CFG, (DIF_TYPE == 2) ? 32'h0 : 32'h0000_0004);
      reg_wr(DIF_CFG, 32'h0000_0000);
      reg_rd(DIF_CFG, phy_fix);
      reg_wr(DIF_CFG, 32'h0000_0001);                  // LCD_ON only
      @(negedge free_clk);
      if ((lcd_on !== 1'b1) || (lcd_reset_n !== 1'b1)) tb_error("LCD_ON alone: pins wrong");
      reg_wr(DIF_CFG, 32'h0000_0002);                  // LCD_RESET only
      @(negedge free_clk);
      if ((lcd_on !== 1'b0) || (lcd_reset_n !== 1'b0)) tb_error("LCD_RESET alone: pins wrong");
      reg_wr(DIF_CFG, 32'h0000_1A00);                  // HW_WINDOW_EN, CLK_DIV 10
      reg_rd(DIF_CFG, 32'h0000_1A00 | phy_fix);
      reg_wr(DIF_CFG, 32'h0000_0000);

      // DIF_SYNC
      reg_wr(DIF_SYNC, 32'hFFFF_FFFF);
      reg_rd(DIF_SYNC, 32'h0001_83FF);
      reg_wr(DIF_SYNC, 32'h0000_0155);
      reg_rd(DIF_SYNC, 32'h0000_0155);
      reg_wr(DIF_SYNC, 32'h0000_0000);

      // DIF_IRQ_EN; TE armed alone makes STATUS.DIF_BUSY 1 (bdi_busy)
      reg_wr(DIF_IRQ_EN, 32'hFFFF_FFFF);
      reg_rd(DIF_IRQ_EN, 32'h0000_0007);
      reg_wr(DIF_IRQ_EN, 32'h0000_0002);
      reg_rd_mask(DIF_STATUS, 32'h0, ST_BUSY);
      reg_rd_mask(STATUS, 32'h0000_0008, 32'h0000_0008);
      reg_wr(DIF_IRQ_EN, 32'h0000_0005);
      reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0008);
      reg_wr(DIF_IRQ_EN, 32'h0000_0000);

      // DIF_IRQ_FLAG and DIF_STATUS (PARAM_OVFL W1C) cannot be set by software
      reg_wr(DIF_IRQ_FLAG, 32'hFFFF_FFFF);
      reg_rd(DIF_IRQ_FLAG, 32'h0);
      reg_wr(DIF_STATUS, 32'hFFFF_FFFF);
      reg_rd(DIF_STATUS, 32'h0);

      // Unused offsets 0x20-0x7C: read 0, write ignored, zero wait, no panel activity
      mark = lg_n;
      for (kk = 32'h1A0; kk < 32'h280; kk = kk + 4) begin   // and the second page 0x200-0x27C
         reg_wr(kk, 32'hFFFF_FFFF);
         if (ahb_last_waits != 0) tb_error("unused DIF offset: write with wait states");
         reg_rd(kk, 32'h0);
         if (ahb_last_waits != 0) tb_error("unused DIF offset: read with wait states");
      end
      reg_rd(DIF_CFG,    phy_fix);
      reg_rd(DIF_SYNC,   32'h0);
      reg_rd(DIF_IRQ_EN, 32'h0);
      reg_rd(DIF_STATUS, 32'h0);
      if (lg_n != mark) tb_error("unused DIF offsets caused panel activity");

      // The write-only registers read 0
      reg_rd(DIF_CMD,   32'h0);
      reg_rd(DIF_PARAM, 32'h0);
      reg_rd(DIF_DFILL, 32'h0);
      reg_rd(DIF_STATUS, 32'h0);                       // reads popped / queued nothing
      if (lg_n != mark) tb_error("reading DIF_CMD / DIF_PARAM / DIF_DFILL caused panel activity");

      // PARAM_LEVEL counts pushes
      for (kk = 1; kk <= 5; kk = kk + 1) begin
         reg_wr(DIF_PARAM, kk);
         reg_rd_mask(DIF_STATUS, kk << 8, ST_LEVEL | ST_PARAM_FULL | ST_BUSY);
      end

      // Reset in the middle of a command (CS low, waiting for parameters)
      dif_cfg(phy, 4'd2, 1'b1, 1'b1, 1'b0);
      reg_wr(DIF_SYNC, 32'h0001_0123);
      reg_wr(DIF_IRQ_EN, 32'h0000_0001);
      reg_wr(DIF_CMD, 32'h0000_0836);                  // 8 params, 5 in the FIFO
      repeat(800) @(posedge free_clk);
      if (((phy == PHY_8080) ? lcd_cs_n : spi_cs_n) !== 1'b0) tb_error("command not waiting with CS low before the reset");
      reg_rd_mask(DIF_STATUS, ST_BUSY, ST_BUSY | ST_LEVEL);
      @(negedge free_clk);
      hresetn = 1'b0;
      repeat(10) @(posedge free_clk);
      if (lcd_cs_n !== 1'b1)    tb_error("lcd_cs_n_o not released during reset");
      if (spi_cs_n !== 1'b1)    tb_error("spi_cs_n_o not released during reset");
      if (lcd_reset_n !== 1'b1) tb_error("lcd_reset_n_o not 1 during reset");
      @(negedge free_clk);
      hresetn = 1'b1;
      repeat(5) @(posedge free_clk);
      check_reset_state;

      // The next command is clean: FIFO empty, one frame
      dif_cfg(phy, 4'd0, 1'b0, 1'b1, 1'b0);
      mark = lg_n; exp_reset;
      exp_cmd(phy, 8'h29, 1'b1);
      exp_par(phy, 16'h00C3);
      reg_wr(DIF_PARAM, 32'h0000_00C3);
      reg_rd_mask(DIF_STATUS, 32'h0000_0100, ST_LEVEL);
      reg_wr(DIF_CMD, 32'h0000_0129);
      dif_wait_idle(200);
      dbi_check_log(mark, "command after a mid-operation reset");

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
