//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_irq_icg
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_irq_icg.v
// Module Description : DPI events made on the stop edge raise irq_o under the
//                      bench clock gate (BLNS_ICG_EN = 1) with no bus access:
//                      the driver is stopped at every hclk phase across the
//                      line that ends with the SCANLINE event (LINE; the
//                      other event toggles cross the same way). Whenever the
//                      pixel domain made the event, irq_o must follow with
//                      no bus access.
//----------------------------------------------------------------------------
`define VERY_LONG_TIMEOUT
`include "dpi_tasks.v"

localparam [31:0] QD_DIF = 32'h100;

integer qd_k, qd_n, qd_hit;
reg     qd_t0;

// The pixel-domain event toggles (backdoor: which attempt made the event)
wire    qd_sl = dut.G_DPI.u_dpi.sl_p;
wire [12:0] qd_vcnt = dut.G_DPI.u_dpi.u_dpi_scan.vcnt;
wire [12:0] qd_hcnt = dut.G_DPI.u_dpi.u_dpi_scan.hcnt;

// One attempt: start, wait for the line before the event, stop k hclk cycles
// into it; then, if the event was made, irq_o must rise with no bus access
task qd_try;
   input integer k;
   input [8*24-1:0] what;
   integer c;
   begin
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_wr(IRQ_FLAG, QD_DIF);
      reg_wr(IRQ_EN, QD_DIF);
      reg_wr(DIF_CFG, 32'h0000_0009);                         // LCD_ON, DPI_EN, CLK_DIV 0
      c = 0;
      while (!((qd_vcnt == 13'd4) && (qd_hcnt == 13'd0)) && (c < 200000)) begin
         @(posedge hclk); c = c + 1;
      end
      @(posedge hclk);
      qd_t0 = qd_sl;
      repeat (k) @(posedge hclk);
      reg_wr(DIF_CFG, 32'h0000_0001);                         // stop
      c = 0;
      while ((irq !== 1'b1) && (c < 3000)) begin @(negedge free_clk); c = c + 1; end
      if (qd_sl !== qd_t0) begin
         qd_hit = qd_hit + 1;
         if (irq !== 1'b1) begin
            $display("ERROR: %0s at stop delay %0d -- the event was made, irq_o = %b (hclk_en_o = %b) %t",
                     what, k, irq, hclk_en, $time);
            error = error + 1;
         end
      end
      reg_poll(DIF_STATUS, 32'h1, 32'h0, 20000);              // stopped
      reg_wr(IRQ_EN, 32'h0);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DPI STOP-EDGE EVENTS UNDER THE CLOCK GATE   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (ICG_EN == 0)
         tb_skip_finish("|      (needs the bench clock gate: ICG_EN)     |");
      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      // LINE: SCANLINE 5, the event at the end of line 4 (the line toggle
      // moves when line 5 starts)
      dpi_timing(0, 40, 2, 3, 5, 20, 1, 2, 2);
      reg_wr(DIF_SYNC, 5);
      reg_wr(DIF_IRQ_EN, 32'h10);
      // the line in hclk cycles, measured: the stops sweep it
      reg_wr(DIF_CFG, 32'h0000_0009);
      qd_n = 0;
      while (!((qd_vcnt == 13'd4) && (qd_hcnt == 13'd0)) && (qd_n < 200000)) begin @(posedge hclk); qd_n = qd_n + 1; end
      qd_n = 0;
      while ((qd_vcnt == 13'd4) && (qd_n < 200000)) begin @(posedge hclk); qd_n = qd_n + 1; end
      reg_wr(DIF_CFG, 32'h0000_0001);
      reg_poll(DIF_STATUS, 32'h1, 32'h0, 20000);
      $display("LINE: a line lasts %0d hclk cycles", qd_n);
      qd_hit = 0;
      for (qd_k = 0; qd_k < qd_n + 12; qd_k = qd_k + 1)
         qd_try(qd_k, "LINE on the stop edge");
      $display("LINE: %0d of the stops made the event", qd_hit);
      if (qd_hit == 0) tb_error("LINE: no stop made the event");

      reg_wr(DIF_IRQ_EN, 32'h0);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
