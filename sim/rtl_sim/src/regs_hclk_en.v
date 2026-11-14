//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_hclk_en
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_hclk_en.v
// Module Description : Clock request hclk_en_o, sampled
//                      while hclk is low (where the ICG latch is
//                      transparent):
//                      - during reset: 0 in both reset styles (the reset
//                        generator, here the bench, requests the clock);
//                      - 0 when every term is idle;
//                      - 1 in every cycle of an r-port or v-port address
//                        phase sampled with hready high and of a data phase,
//                        wait states included (monitor), and in every cycle
//                        of an address phase held by fabric wait states; the
//                        held transfer is then taken (also under the ICG);
//                      - 1 while REFRESH.START = 1 (period and manual);
//                      - 1 while bdi_busy_i (DIF_TYPE = 0) / while the DBI
//                        driver is busy (TE interrupt armed, DIF_TYPE 1-3) /
//                        while the DPI driver runs or DETECT is armed
//                        (DIF_TYPE 4);
//                      - 1 while the GPU runs a long fill, which completes
//                        even with the bench ICG (BLNS_ICG_EN = 1);
//                      - with bdi_refresh_active_i (backend busy): reported;
//                      - a frame ending with REFRESH.START = 0 and no bus
//                        access raises REFR_DONE (clock kept for that edge).
//----------------------------------------------------------------------------
`include "regs_tasks.v"

integer     h_i, h_lo, h_bad;
reg  [31:0] h_rd;
reg         h_mon;                 // bus-activity monitor enabled
integer     h_mon_err;
reg         h_rdp, h_vdp;          // data phase pending

initial begin h_mon = 1'b0; h_mon_err = 0; h_rdp = 1'b0; h_vdp = 1'b0; end

// Data-phase tracking (sampled at the DUT clock edge, from the DUT-side inputs)
always @(posedge free_clk) begin
   if (r_hready === 1'b1) h_rdp <= (r_hsel_d === 1'b1) && (r_htrans_d[1] === 1'b1);
   if (v_hready === 1'b1) h_vdp <= (v_hsel_d === 1'b1) && (v_htrans_d[1] === 1'b1);
end

always @(negedge free_clk)
  if (h_mon && (hresetn_d === 1'b1)) begin
     // an address phase counts in the cycle it is sampled (hready high);
     // one held by fabric wait states is reported separately
     if ((((r_hsel_d === 1'b1) && (r_htrans_d[1] === 1'b1) && (r_hready === 1'b1)) || h_rdp ||
          ((v_hsel_d === 1'b1) && (v_htrans_d[1] === 1'b1) && (v_hready === 1'b1)) || h_vdp) && (hclk_en !== 1'b1)) begin
        if (h_mon_err < 10)
           $display("ERROR: hclk_en_o = %b during bus activity (r addr %b data %b, v addr %b data %b) %t",
                    hclk_en, r_hsel_d & r_htrans_d[1], h_rdp, v_hsel_d & v_htrans_d[1], h_vdp, $time);
        h_mon_err = h_mon_err + 1;
        error = error + 1;
     end
  end

// Sample hclk_en for n cycles (low phase); expect a constant value
task h_expect;
   input        val;
   input integer n;
   input [64*8-1:0] what;
   integer k, bad;
   begin
      bad = 0;
      // Contract §12: the clock request stays high for exactly one cycle after
      // the last bus activity (so a register write reaches the blocks that
      // copy it); an idle expectation starts after that trailing cycle.
      if (val == 1'b0) @(negedge free_clk);
      for (k = 0; k < n; k = k + 1) begin
         @(negedge free_clk);
         #2;
         if (hclk_en !== val) bad = bad + 1;
      end
      if (bad != 0) begin
         $display("ERROR: hclk_en_o != %b in %0d of %0d cycles: %0s %t", val, bad, n, what, $time);
         error = error + 1;
      end else
         $display("OK:    hclk_en_o = %b: %0s", val, what);
   end
endtask

// Reset phase check
initial begin
   #150;                                   // inside the reset pulse (23 .. 223 ns)
   if (hresetn !== 1'b0) $display("WARNING: reset not asserted at the reset sample point");
   if (hclk_en !== 1'b0) begin
      $display("ERROR: hclk_en_o = %b during reset %t", hclk_en, $time);
      error = error + 1;
   end
end

initial
   begin
      $display(" ===============================================");
      $display("|        REGS: CLOCK REQUEST hclk_en_o          |");
      $display(" ===============================================");
      @(posedge reset_done);

      h_expect(1'b0, 20, "idle after reset");

      //------------------------------------------------------------------
      // Bus activity (monitor on)
      //------------------------------------------------------------------
      h_mon = 1'b1;
      reg_wr(DISP_CFG, 32'h1);
      reg_rd(DISP_CFG, 32'h1);
      vram_wr(32'h40, 32'h1234_5678, SZ_W);
      vram_rd(32'h40, 32'h1234_5678, SZ_W);
      ahb_write_x(PORT_R, CTRL, 32'h0, SZ_B, MACHINE, HART_MASTER, ERROR);
      if (LUT_EN != 0) reg_rd(LUT_BASE, 32'h0);
      rp_clear;
      for (h_i = 0; h_i < 10; h_i = h_i + 1) begin rp_w(DISP_CFG, h_i & 7, h_i & 1); rp_r(DISP_CFG, 0); end
      vp_clear;
      for (h_i = 0; h_i < 10; h_i = h_i + 1) begin vp_add(32'h40, h_i & 1, 3'b010, h_i, MACHINE, HART_MASTER, (h_i == 0) ? 2'b10 : 2'b11, 0); end
      fork rp_run; vp_run; join
      // address phases held by fabric wait states
      @(negedge free_clk);
      r_force_stall = 1'b1; v_force_stall = 1'b1;
      r_hsel = 1'b1; r_haddr = DISP_CFG; r_htrans = 2'b10; r_hwrite = 1'b0; r_hsize = 3'b010; r_hprot = 4'h3;
      for (h_i = 0; h_i < 6; h_i = h_i + 1) begin
         @(negedge free_clk);
         if (hclk_en !== 1'b1) tb_error("hclk_en_o low while an r-port address phase is held by hready = 0");
      end
      r_force_stall = 1'b0;
      @(posedge free_clk);
      r_hsel = 1'b0; r_htrans = 2'b00;
      @(negedge free_clk);
      while (r_hready !== 1'b1) @(negedge free_clk);
      if (r_hrdata !== 32'h0000_0001) tb_error("held r-port read not taken / wrong data");
      v_hsel = 1'b1; v_haddr = 32'h40; v_htrans = 2'b10; v_hwrite = 1'b0; v_hsize = 3'b010; v_hprot = 4'h3;
      for (h_i = 0; h_i < 6; h_i = h_i + 1) begin
         @(negedge free_clk);
         if (hclk_en !== 1'b1) tb_error("hclk_en_o low while a v-port address phase is held by hready = 0");
      end
      v_force_stall = 1'b0;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00;
      @(negedge free_clk);
      while (v_hready !== 1'b1) @(negedge free_clk);
      if (v_hrdata !== 32'h0000_0009) tb_error("held v-port read not taken / wrong data");
      repeat (4) @(posedge free_clk);
      h_mon = 1'b0;
      if (h_mon_err == 0) $display("OK:    hclk_en_o high in every bus-activity cycle");
      h_expect(1'b0, 20, "idle after bus traffic");

      //------------------------------------------------------------------
      // REFRESH.START
      //------------------------------------------------------------------
      if (DIF_TYPE == 0) bm_auto = 1'b0;            // nobody answers: START stays pending
      if (HAS_DBI) reg_wr(DIF_CFG, 32'h0000_0001);
      reg_wr(REFRESH, (5000 << 4) | 1);             // period mode
      h_expect(1'b1, 200, "REFRESH.START = 1 (period mode)");
      reg_wr(REFRESH, 32'h0);
      if (HAS_DBI) reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 4000);
      h_expect(1'b0, 20, "START cleared");
      if (DIF_TYPE == 0) begin
         reg_wr(REFRESH, 32'h1);                    // manual, never answered
         h_expect(1'b1, 200, "REFRESH.START = 1 (manual, pending)");
         reg_wr(REFRESH, 32'h0);
         h_expect(1'b0, 20, "manual START cleared");
      end

      //------------------------------------------------------------------
      // Display-interface busy
      //------------------------------------------------------------------
      if (DIF_TYPE == 0) begin
         @(posedge free_clk); bdi_busy_drv = 1'b1;
         h_expect(1'b1, 50, "bdi_busy_i = 1");
         @(posedge free_clk); bdi_busy_drv = 1'b0;
         repeat (2) @(posedge free_clk);
         h_expect(1'b0, 20, "bdi_busy_i = 0");
         // backend busy = refresh active (reported: clock gated when it rises)
         @(posedge free_clk); bdi_refresh_active_drv = 1'b1;
         repeat (10) @(negedge free_clk);
         $display("INFO:  hclk_en_o = %b 10 cycles after bdi_refresh_active_i rose with nothing else running (ICG_EN = %0d)", hclk_en, ICG_EN);
         if ((ICG_EN == 0) && (hclk_en !== 1'b1)) tb_error("hclk_en_o low while the backend is busy (refresh active)");
         @(posedge free_clk); bdi_busy_drv = 1'b1;  // make sure the fall is seen
         repeat (4) @(posedge free_clk);
         @(posedge free_clk); bdi_refresh_active_drv = 1'b0;
         repeat (10) @(posedge free_clk);
         @(posedge free_clk); bdi_busy_drv = 1'b0;
         reg_wr(IRQ_FLAG, 32'h1F7);
         h_expect(1'b0, 20, "refresh active fallen");
      end else if (HAS_DPI) begin
         reg_wr(DIF_IRQ_EN, 32'h40);                // DETECT armed: driver busy
         h_expect(1'b1, 50, "DPI driver busy (DETECT interrupt armed)");
         reg_wr(DIF_IRQ_EN, 32'h0);
         h_expect(1'b0, 20, "DPI driver idle");
         reg_wr(DPI_H_ACT, 64); reg_wr(DPI_H_BLANK, 2 | (2 << 10) | (2 << 20));
         reg_wr(DPI_V_ACT, 16); reg_wr(DPI_V_BLANK, 1 | (1 << 10) | (1 << 20));
         reg_wr(DIF_CFG, 32'h0000_0008);
         h_expect(1'b1, 50, "DPI driver running (DPI_EN)");
         reg_wr(DIF_CFG, 32'h0);
         reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 4000);
         h_expect(1'b0, 20, "DPI driver stopped");
      end else begin
         reg_wr(DIF_IRQ_EN, 32'h2);                 // TE armed: driver busy
         h_expect(1'b1, 50, "DBI driver busy (TE interrupt armed)");
         reg_wr(DIF_IRQ_EN, 32'h0);
         h_expect(1'b0, 20, "DBI driver idle");
      end

      //------------------------------------------------------------------
      // End of a frame with REFRESH.START = 0 and no bus access: the clock
      // stays requested for the edge that records it (REFR_DONE interrupt)
      //------------------------------------------------------------------
      reg_wr(IRQ_FLAG, 32'h1F7);
      reg_wr(IRQ_EN, 32'h1);                        // REFR_DONE
      if (DIF_TYPE == 0) begin
         @(posedge free_clk); bdi_busy_drv = 1'b1;
         @(posedge free_clk); bdi_refresh_active_drv = 1'b1;
         repeat (10) @(posedge free_clk);
         bdi_busy_drv = 1'b0;                       // the backend keeps the clock
         repeat (10) @(posedge free_clk);
         bdi_refresh_active_drv = 1'b0;             // falls with nothing else running
      end else if (HAS_DPI) begin
         reg_wr(CTRL, {29'h0, GFX_16BPP});
         reg_wr(DISP_SIZE, (16 << 16) | 64);
         reg_wr(DIF_CFG, 32'h0000_0008);            // the panel paces the frames
         reg_poll(STATUS, 32'h1, 32'h1, 4000);
      end else begin
         reg_wr(CTRL, {29'h0, GFX_16BPP});
         reg_wr(DISP_SIZE, (16 << 16) | 64);
         reg_wr(DIF_CFG, 32'h0000_0001);
         reg_wr(REFRESH, (300 << 4) | 1);
         reg_poll(STATUS, 32'h1, 32'h1, 4000);      // a frame runs
         reg_wr(REFRESH, 32'h0);
         reg_rd_mask(STATUS, 32'h1, 32'h1);         // still running
      end
      h_lo = 0;
      while ((irq !== 1'b1) && (h_lo < 100000)) begin @(posedge free_clk); h_lo = h_lo + 1; end
      if (irq !== 1'b1) tb_error("no REFR_DONE irq: frame end, START=0");
      else $display("OK:    REFR_DONE interrupt at the end of a frame with START = 0, no bus access");
      reg_rd_mask(IRQ_FLAG, 32'h1, 32'h1);
      reg_wr(IRQ_EN, 32'h0);
      reg_wr(IRQ_FLAG, 32'h1F7);
      if (DIF_TYPE != 0) begin
         reg_wr(CTRL, 32'h0);
         if (HAS_DPI) reg_wr(DIF_CFG, 32'h0);
         reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 4000);
      end
      h_expect(1'b0, 20, "idle after the frame");

      //------------------------------------------------------------------
      // GPU busy: a long fill runs to completion without bus traffic
      //------------------------------------------------------------------
      if ((GPU_EN != 0) && (VRAM_WORDS >= 4096)) begin
         vram_mem[4095] = 32'h0;
         reg_wr(CTRL,    {27'h0, 2'b10, GFX_16BPP});
         reg_wr(GPU_CMD, {OP_SET_DST,  12'h000, 16'd64});
         reg_wr(GPU_CMD, 32'd0);
         reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd128, 14'd64});
         reg_wr(GPU_CMD, {OP_SET_FILL, 28'h0});
         reg_wr(GPU_CMD, 32'h0000_A55A);
         reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
         h_expect(1'b1, 2000, "GPU fill running");
         h_lo = 0;
         while ((hclk_en !== 1'b0) && (h_lo < 20000)) begin @(negedge free_clk); #2; h_lo = h_lo + 1; end
         if (vram_mem[4095] !== 32'hA55A_A55A) tb_error("hclk_en_o dropped before the GPU fill completed");
         reg_rd_mask(GPU_STAT, 32'h0, 32'h0030_0000);
         h_expect(1'b0, 20, "GPU idle");
         reg_wr(CTRL, 32'h0);
         h_expect(1'b0, 20, "CTRL.GPU_EN = 0");
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
