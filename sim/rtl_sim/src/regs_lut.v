//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_lut
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_lut.v
// Module Description : LUT window 0x800-0xFFC:
//                      - every entry of both banks written with random
//                        32-bit words (pipelined), read back as
//                        {8'h00, RGB888}, checked against the LUT macro
//                        model and the macro write port (lut_din / addr);
//                      - LUT_BANKS = 1: bank 1 reads 0, its writes neither
//                        reach the macro nor alias into bank 0;
//                      - LUT_EN = 0: the whole window RAZ/WI, no macro access;
//                      - non-word sizes: ERROR, no macro access;
//                      - contention (8080 PHY): a refresh at 8 bpp through
//                        the programmable LUT (SW_LUT_EN, REFR_BANK) while
//                        the window reads and writes other entries; every
//                        panel pixel and every window read is checked.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer LC_W = 16;
localparam integer LC_H = 4;

integer     l_i, l_k, l_b, l_wr0, l_rd0, l_nb, l_x, l_y;
reg  [31:0] l_v;
reg  [31:0] l_ref [0:511];
reg  [23:0] l_e;
reg  [15:0] l_exp;
integer     l_pidx [0:PIPE_MAX-1];
reg  [31:0] l_store [0:PIPE_MAX-1];

// LUT macro monitor
integer     lm_wr, lm_rd;
reg   [8:0] lm_addr;
reg  [23:0] lm_din;
initial begin lm_wr = 0; lm_rd = 0; end
always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (lut_cen === 1'b0)) begin
     if (lut_wen === 1'b0) begin lm_wr = lm_wr + 1; lm_addr = lut_addr; lm_din = lut_din; end
     else                        lm_rd = lm_rd + 1;
  end

// Gray LUT entry for the contention frame (order-independent RGB888)
function [23:0] gray;
   input [7:0] v;
   begin
      gray = {v, v, v};
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|               REGS: LUT WINDOW                |");
      $display(" ===============================================");
      @(posedge reset_done);

      l_nb = (LUT_EN == 0) ? 0 : LUT_BANKS;

      //------------------------------------------------------------------
      // LUT_EN = 0: RAZ/WI, no macro access
      //------------------------------------------------------------------
      if (LUT_EN == 0) begin
         repeat (2) @(posedge free_clk);
         l_wr0 = lm_wr; l_rd0 = lm_rd;
         for (l_b = 0; l_b < 2; l_b = l_b + 1) begin
            rp_clear;
            for (l_i = 0; l_i < 256; l_i = l_i + 1) begin
               rp_w(LUT_BASE + 32'h400*l_b + 4*l_i, 32'hFFFF_FFFF, 0);
               rp_r(LUT_BASE + 32'h400*l_b + 4*l_i, 0);
            end
            rp_run;
            for (l_i = 0; l_i < rp_n; l_i = l_i + 1) rp_chk(l_i, OK, 32'h0, rp_wr[l_i] ? 0 : 32'hFFFF_FFFF, 0);
         end
         repeat (3) @(posedge free_clk);
         if ((lm_wr != l_wr0) || (lm_rd != l_rd0)) tb_error("LUT macro accessed with LUT_EN = 0");
         repeat (5) @(posedge free_clk);
         stimulus_done = 1;
      end
   end

initial
   begin
      @(posedge reset_done);
      if (LUT_EN != 0) begin
      //------------------------------------------------------------------
      // Every entry: pipelined writes, then pipelined reads
      //------------------------------------------------------------------
      for (l_i = 0; l_i < 512; l_i = l_i + 1) l_ref[l_i] = 0;
      for (l_b = 0; l_b < 2; l_b = l_b + 1) begin
         repeat (2) @(posedge free_clk);
         l_wr0 = lm_wr;
         rp_clear;
         for (l_i = 0; l_i < 256; l_i = l_i + 1) begin
            l_v = $random(tmp_seed);
            rp_w(LUT_BASE + 32'h400*l_b + 4*l_i, l_v, (l_i % 7 == 3) ? 1 : 0);
            if (l_b < l_nb) l_ref[256*l_b + l_i] = l_v & 32'h00FF_FFFF;
         end
         rp_run;
         for (l_i = 0; l_i < rp_n; l_i = l_i + 1) rp_chk(l_i, OK, 0, 0, -1);
         repeat (3) @(posedge free_clk);
         if (lm_wr != l_wr0 + ((l_b < l_nb) ? 256 : 0)) begin
            $display("ERROR: bank %0d: %0d LUT macro writes / expected %0d %t", l_b, lm_wr - l_wr0, (l_b < l_nb) ? 256 : 0, $time);
            error = error + 1;
         end
         if (l_b < l_nb) begin
            if ((lm_addr !== (256*l_b + 255)) || (lm_din !== l_ref[256*l_b + 255][23:0]))
               tb_error("last LUT macro write: wrong address or data");
         end
      end
      for (l_i = 0; l_i < 512; l_i = l_i + 1)
         if ((l_i < 256*l_nb) && (lut_mem[l_i] !== l_ref[l_i][23:0])) begin
            $display("ERROR: LUT model entry %0d = 0x%h / expected 0x%h %t", l_i, lut_mem[l_i], l_ref[l_i][23:0], $time);
            error = error + 1;
         end else if ((l_i >= 256*l_nb) && (lut_mem[l_i] !== 24'h0)) begin
            $display("ERROR: LUT model entry %0d written with LUT_BANKS = 1 %t", l_i, $time);
            error = error + 1;
         end
      for (l_b = 0; l_b < 2; l_b = l_b + 1) begin
         rp_clear;
         for (l_i = 0; l_i < 256; l_i = l_i + 1)
            rp_add(LUT_BASE + 32'h400*l_b + 4*l_i, 1'b0, 3'b010, 0, (l_i & 1) ? SUPERVISOR : MACHINE, HART_MASTER, 2'b10, (l_i % 5 == 1) ? 1 : 0);
         rp_run;
         for (l_i = 0; l_i < rp_n; l_i = l_i + 1) rp_chk(l_i, OK, l_ref[256*l_b + l_i], 32'hFFFF_FFFF, -1);
      end
      // back-door entries read through the window
      lut_mem[17] = 24'hABCDEF;
      reg_rd(LUT_BASE + 4*17, 32'h00AB_CDEF);
      l_ref[17] = 32'h00AB_CDEF;
      $display("OK:    every LUT entry");

      // write -> read of the same entry, alternated, pipelined
      rp_clear;
      for (l_i = 0; l_i < 32; l_i = l_i + 1) begin
         l_k = ($random(tmp_seed) & 32'hFF) + 256 * (($random(tmp_seed) & 1) % l_nb);
         l_v = $random(tmp_seed);
         rp_w(LUT_BASE + 4*l_k, l_v, 0);
         l_pidx[rp_n-1] = -1;
         l_ref[l_k] = l_v & 32'h00FF_FFFF;
         rp_r(LUT_BASE + 4*l_k, 0);
         l_pidx[rp_n-1] = l_k;
         rp_w(CTRL, 32'h3, 0);
         l_pidx[rp_n-1] = -1;
      end
      rp_run;
      // expected data in issue order: recompute
      for (l_i = 0; l_i < rp_n; l_i = l_i + 1)
         if (l_pidx[l_i] >= 0) rp_chk(l_i, OK, rp_wdata[l_i-1] & 32'h00FF_FFFF, 32'hFFFF_FFFF, -1);
         else                  rp_chk(l_i, OK, 0, 0, -1);
      reg_wr(CTRL, 32'h0);

      //------------------------------------------------------------------
      // Non-word sizes: ERROR, no macro access
      //------------------------------------------------------------------
      repeat (2) @(posedge free_clk);
      l_wr0 = lm_wr; l_rd0 = lm_rd;
      rp_clear;
      for (l_i = 0; l_i < 4; l_i = l_i + 1) begin
         rp_add(LUT_BASE + 4*20 + l_i, 1'b1, 3'b000, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
         rp_add(LUT_BASE + 4*20 + l_i, 1'b0, 3'b000, 32'h0,         MACHINE, HART_MASTER, 2'b10, 0);
      end
      rp_add(LUT_BASE + 32'h400 + 4*20 + 2, 1'b1, 3'b001, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
      rp_add(LUT_BASE + 4*20,               1'b1, 3'b011, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b10, 0);
      rp_run;
      for (l_i = 0; l_i < rp_n; l_i = l_i + 1) rp_chk(l_i, ERROR, 0, 0, 1);
      repeat (3) @(posedge free_clk);
      if ((lm_wr != l_wr0) || (lm_rd != l_rd0)) tb_error("LUT macro accessed by a non-word transfer");
      reg_rd(LUT_BASE + 4*20, l_ref[20]);

      //------------------------------------------------------------------
      // Contention with the backend: 8 bpp refresh through the LUT
      //------------------------------------------------------------------
      if (HAS_8080) begin
         l_b = l_nb - 1;                                    // refresh bank (1 when present)
         for (l_i = 0; l_i < LC_W*LC_H; l_i = l_i + 1) begin
            l_ref[256*l_b + l_i] = gray(8'h03 + 3*l_i);
            lut_mem[256*l_b + l_i] = gray(8'h03 + 3*l_i);
         end
         // frame: pixel (x, y) = index x + LC_W*y, 4 pixels per word, LSB first
         for (l_i = 0; l_i < LC_W*LC_H/4; l_i = l_i + 1)
            vram_wr(4*l_i, (((4*l_i+3) & 255) << 24) | (((4*l_i+2) & 255) << 16) | (((4*l_i+1) & 255) << 8) | ((4*l_i) & 255), SZ_W);
         reg_wr(CTRL,      {29'h0, GFX_8BPP});
         reg_wr(DISP_SIZE, (LC_H << 16) | LC_W);
         reg_wr(LUT_CFG,   32'h0000_F001 | (l_b << 1));     // SW_LUT_EN, REFR_BANK
         reg_wr(DIF_CFG,   32'h0000_0001);                  // LCD_ON, 8080, CLK_DIV 0
         reg_wr(REFRESH,   32'h1);
         // hammer the window on entries the frame does not use
         rp_clear;
         for (l_i = 0; l_i < 150; l_i = l_i + 1) begin
            l_k = 256*(1 - l_b) + 100 + (l_i % 50);
            if (l_nb == 1) l_k = 100 + (l_i % 50);
            if (l_i % 3 == 0) begin
               l_v = $random(tmp_seed);
               rp_w(LUT_BASE + 4*l_k, l_v, 0);
               l_ref[l_k] = l_v & 32'h00FF_FFFF;
               l_pidx[rp_n-1] = -1;
            end else begin
               rp_r(LUT_BASE + 4*l_k, 0);
               l_pidx[rp_n-1] = l_k;
               l_store[rp_n-1] = l_ref[l_k];
            end
         end
         rp_run;
         for (l_i = 0; l_i < rp_n; l_i = l_i + 1)
            if (l_pidx[l_i] >= 0) rp_chk(l_i, OK, l_store[l_i], 32'hFFFF_FFFF, -1);
            else                  rp_chk(l_i, OK, 0, 0, -1);
         l_k = 0;
         for (l_i = 0; l_i < rp_n; l_i = l_i + 1) if (rp_waits[l_i] > l_k) l_k = rp_waits[l_i];
         $display("INFO:  LUT window under refresh: max %0d wait states", l_k);
         reg_poll(REFRESH, 32'h1, 32'h0, 4000);
         reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 4000);
         if (u_lcd8080.px_count != LC_W*LC_H) begin
            $display("ERROR: panel received %0d pixels / expected %0d %t", u_lcd8080.px_count, LC_W*LC_H, $time);
            error = error + 1;
         end
         for (l_y = 0; l_y < LC_H; l_y = l_y + 1)
            for (l_x = 0; l_x < LC_W; l_x = l_x + 1) begin
               l_e   = gray(8'h03 + 3*(l_x + LC_W*l_y));
               l_exp = {l_e[23:19], l_e[15:10], l_e[7:3]};
               if (u_lcd8080.px_log[l_x + LC_W*l_y] !== l_exp) begin
                  $display("ERROR: panel pixel %0d (%0d,%0d) = 0x%h / expected 0x%h %t", l_x + LC_W*l_y, l_x, l_y,
                           u_lcd8080.px_log[l_x + LC_W*l_y], l_exp, $time);
                  error = error + 1;
               end
            end
         if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel protocol anomalies");
         $display("OK:    LUT window and backend LUT reads in contention");
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
      end
   end

