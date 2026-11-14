//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_hclk_en_held
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_hclk_en_held.v
// Module Description : Clock request during an address phase held by fabric
//                      wait states (contract §12: hclk_en_o includes r-port
//                      and v-port activity, "address or data phase"). With
//                      hsel and htrans = NONSEQ presented while hready is held
//                      low (another subordinate's data phase), hclk_en_o must
//                      be 1 in every cycle of the address phase, on each port;
//                      the held transfer is then taken once.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

integer h_k, h_bad;

initial
   begin
      $display(" ===============================================");
      $display("|   REGS: CLOCK REQUEST, HELD ADDRESS PHASE     |");
      $display(" ===============================================");
      @(posedge reset_done);

      reg_wr(DISP_CFG, 32'h5);
      vram_wr(32'h80, 32'h0BAD_F00D, SZ_W);
      repeat (10) @(posedge free_clk);

      // r-port
      @(negedge free_clk);
      r_force_stall = 1'b1;
      r_hsel = 1'b1; r_haddr = DISP_CFG; r_htrans = 2'b10; r_hwrite = 1'b0; r_hsize = 3'b010;
      r_hprot = 4'h3; r_hsmode = 1'b0; r_hmaster = HART_MASTER;
      h_bad = 0;
      for (h_k = 0; h_k < 6; h_k = h_k + 1) begin
         @(negedge free_clk); #2;
         if (hclk_en !== 1'b1) h_bad = h_bad + 1;
      end
      if (h_bad != 0) begin
         $display("ERROR: hclk_en_o low in %0d of 6 cycles of an r-port address phase held by hready = 0 %t", h_bad, $time);
         error = error + 1;
      end
      r_force_stall = 1'b0;
      @(posedge free_clk);
      r_hsel = 1'b0; r_htrans = 2'b00;
      @(negedge free_clk);
      while (r_hready !== 1'b1) @(negedge free_clk);
      if (r_hrdata !== 32'h5) tb_error("held r-port read not taken / wrong data");
      repeat (10) @(posedge free_clk);

      // v-port
      @(negedge free_clk);
      v_force_stall = 1'b1;
      v_hsel = 1'b1; v_haddr = 32'h80; v_htrans = 2'b10; v_hwrite = 1'b0; v_hsize = 3'b010;
      v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      h_bad = 0;
      for (h_k = 0; h_k < 6; h_k = h_k + 1) begin
         @(negedge free_clk); #2;
         if (hclk_en !== 1'b1) h_bad = h_bad + 1;
      end
      if (h_bad != 0) begin
         $display("ERROR: hclk_en_o low in %0d of 6 cycles of a v-port address phase held by hready = 0 %t", h_bad, $time);
         error = error + 1;
      end
      v_force_stall = 1'b0;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00;
      @(negedge free_clk);
      while (v_hready !== 1'b1) @(negedge free_clk);
      if (v_hrdata !== 32'h0BAD_F00D) tb_error("held v-port read not taken / wrong data");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
