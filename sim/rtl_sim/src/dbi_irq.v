//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_irq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_irq.v
// Module Description : DBI driver interrupts on every PHY of the build:
//                      DIF_IRQ_FLAG CMD_DONE / TE / CMD_OVFL are raw flags
//                      (set whatever DIF_IRQ_EN), cleared bit by bit by W1C;
//                      bdi_irq = |(FLAG & EN) is what IRQ_FLAG.DIF reads (a
//                      level, not cleared by a W1C of IRQ_FLAG) and drives
//                      irq_o through IRQ_EN.DIF. TE flag on each rising edge of
//                      lcd_te_i, not on the falling edge. STATUS.DIF_BUSY
//                      while a command runs and with only the TE interrupt
//                      armed. With the ICG model (BLNS_ICG_EN=1) the TE flag
//                      is checked only with DIF_IRQ_EN.TE = 1 (the clock may
//                      be gated otherwise).
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    phy_i;
reg        phy;

task te_edge;
   input val;
   begin
      @(negedge free_clk);
      lcd_te = val;
      repeat(8) @(posedge free_clk);
   end
endtask

task chk_irq;
   input             exp;
   input [40*8-1:0]  what;
   begin
      repeat(2) @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b -- %0s %t", irq, exp, what, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|               DBI: INTERRUPTS                 |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(IRQ_EN, 32'h0000_0100);                    // DIF -> irq_o

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            $display("INFO:  PHY %0s", (phy == PHY_8080) ? "8080" : "SPI");
            dif_cfg(phy, 4'd0, 1'b0, 1'b1, 1'b0);
            reg_wr(DIF_IRQ_EN, 32'h0);

            // CMD_DONE raw flag, enable gating, IRQ_FLAG.DIF level
            reg_wr(DIF_CMD, 32'h0000_0000);
            dif_wait_idle(1000);
            reg_rd(DIF_IRQ_FLAG, 32'h1);
            reg_rd_mask(IRQ_FLAG, 32'h0, 32'h100);
            chk_irq(1'b0, "CMD_DONE set, not enabled");
            reg_wr(DIF_IRQ_EN, 32'h1);
            reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
            chk_irq(1'b1, "CMD_DONE enabled");
            reg_wr(IRQ_FLAG, 32'h100);                  // DIF is not W1C
            reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
            reg_wr(IRQ_EN, 32'h0);
            chk_irq(1'b0, "IRQ_EN.DIF cleared");
            reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
            reg_wr(IRQ_EN, 32'h100);
            chk_irq(1'b1, "IRQ_EN.DIF set again");
            reg_wr(DIF_IRQ_FLAG, 32'h6);                // other bits: no effect
            reg_rd(DIF_IRQ_FLAG, 32'h1);
            reg_wr(DIF_IRQ_FLAG, 32'h1);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            reg_rd_mask(IRQ_FLAG, 32'h0, 32'h100);
            chk_irq(1'b0, "CMD_DONE cleared");

            // STATUS.DIF_BUSY while a command waits for its parameter
            reg_wr(DIF_CMD, 32'h0000_0101);
            repeat(10) @(posedge free_clk);
            reg_rd_mask(STATUS, 32'h8, 32'h8);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            reg_wr(DIF_PARAM, 32'h0);
            dif_wait_idle(1000);
            reg_rd_mask(STATUS, 32'h0, 32'h8);
            reg_wr(DIF_IRQ_FLAG, 32'h7);

            // CMD_OVFL raw flag
            reg_wr(DIF_IRQ_EN, 32'h0);
            reg_wr(DIF_CMD, 32'h0000_0102);             // waits
            reg_wr(DIF_CMD, 32'h0000_0003);             // queued
            reg_wr(DIF_CMD, 32'h0000_0004);             // dropped
            reg_rd_mask(DIF_IRQ_FLAG, 32'h4, 32'h4);
            chk_irq(1'b0, "CMD_OVFL set, not enabled");
            reg_wr(DIF_IRQ_EN, 32'h4);
            chk_irq(1'b1, "CMD_OVFL enabled");
            reg_wr(DIF_IRQ_FLAG, 32'h4);
            chk_irq(1'b0, "CMD_OVFL cleared");
            reg_wr(DIF_PARAM, 32'h0);
            dif_wait_idle(1000);
            reg_wr(DIF_IRQ_FLAG, 32'h7);
            reg_wr(DIF_IRQ_EN, 32'h0);

            // TE: armed alone keeps DIF_BUSY; flag on the rising edge only
            reg_wr(DIF_IRQ_EN, 32'h2);
            reg_rd_mask(STATUS, 32'h8, 32'h8);
            reg_rd_mask(DIF_STATUS, 32'h0, ST_BUSY);
            te_edge(1'b1);
            reg_rd(DIF_IRQ_FLAG, 32'h2);
            chk_irq(1'b1, "TE edge, TE enabled");
            reg_wr(DIF_IRQ_FLAG, 32'h2);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            te_edge(1'b0);
            reg_rd(DIF_IRQ_FLAG, 32'h0);                // falling edge: nothing
            chk_irq(1'b0, "TE falling edge");
            te_edge(1'b1);
            reg_rd(DIF_IRQ_FLAG, 32'h2);
            reg_wr(DIF_IRQ_FLAG, 32'h2);
            te_edge(1'b0);
            if (ICG_EN == 0) begin
               reg_wr(DIF_IRQ_EN, 32'h0);
               reg_rd_mask(STATUS, 32'h0, 32'h8);
               te_edge(1'b1);
               reg_rd(DIF_IRQ_FLAG, 32'h2);             // raw flag, not enabled
               chk_irq(1'b0, "TE flag, not enabled");
               reg_wr(DIF_IRQ_EN, 32'h2);
               chk_irq(1'b1, "TE enabled afterwards");
               reg_wr(DIF_IRQ_FLAG, 32'h2);
               te_edge(1'b0);
            end
            reg_wr(DIF_IRQ_EN, 32'h0);
            reg_wr(DIF_IRQ_FLAG, 32'h7);
            reg_rd(DIF_IRQ_FLAG, 32'h0);
            chk_irq(1'b0, "all cleared");
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
