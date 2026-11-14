//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_vram_timing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_vram_timing.v
// Module Description : VRAM-window wait states per access pattern, pipelined
//                      as a CPU's back-to-back accesses (each address phase
//                      in the previous data phase): runs of word, half-word
//                      and byte writes and reads in address order, random
//                      words, a write then a read of the same word, a load /
//                      store copy, with and without a free cycle between the
//                      accesses; then the same under contention (a GPU fill
//                      and, when the build has one, an 8080 refresh). Every
//                      read is checked; an idle-VRAM pattern whose wait
//                      states differ from the documented ones is an error
//                      (L = VWIN_RD_L = VRAM_RD_LAT + 1, the wait states of a
//                      read the buffer misses: writes 0, runs in address
//                      order L - 1 per word, misses L, a load / store copy
//                      L - 2 per load; the contended ones are reported).
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer TM_W0  = 2048;                      // patterns: words 2048..2303
localparam integer TM_N   = 32;                        // accesses per pattern
localparam integer TM_GW0 = 8192;                      // GPU fill target
localparam integer TM_L   = VWIN_RD_L;                       // the window's read latency
localparam integer TM_L2  = (TM_L > 2) ? TM_L - 2 : 0;

integer     t_i, t_k, t_p, t_w, t_mx, t_c0, t_cnt, t_exp;
reg  [31:0] t_v, t_a;
reg  [31:0] t_ref  [0:255];                            // expected words TM_W0..
reg  [31:0] t_pexp [0:PIPE_MAX-1];
reg  [31:0] t_pmsk [0:PIPE_MAX-1];

function [31:0] t_lane;
   input [2:0]  size;
   input [31:0] addr;
   begin
      t_lane = (size == 3'b000) ? (32'hFF   << (8*addr[1:0])) :
               (size == 3'b001) ? (32'hFFFF << (16*addr[1]))  : 32'hFFFF_FFFF;
   end
endfunction

// Append one access to the pipe and to the reference
task t_add;
   input        wr;
   input [2:0]  size;
   input [31:0] addr;
   input integer gap;
   reg   [31:0] m, d;
   integer      s;
   begin
      s = (addr >> 2) - TM_W0;
      m = t_lane(size, addr);
      d = $random(tmp_seed);
      vp_add(addr, wr, size, d, MACHINE, HART_MASTER, 2'b10, gap);
      if (wr) begin
         t_ref[s]        = (t_ref[s] & ~m) | (d & m);
         t_pmsk[vp_n-1]  = 32'h0;
      end else begin
         t_pexp[vp_n-1]  = t_ref[s];
         t_pmsk[vp_n-1]  = m;
      end
   end
endtask

// Run the pipe; report the wait states of every access but the first
// (exp >= 0: their total must be exp), check the read data
task t_run;
   input [8*28-1:0] name;
   input integer    exp;
   begin
      vp_run;
      t_w = 0; t_mx = 0;
      for (t_i = 0; t_i < vp_n; t_i = t_i + 1) begin
         vp_chk(t_i, OK, t_pexp[t_i], t_pmsk[t_i], -1);
         if (t_i > 0) begin
            t_w = t_w + vp_waits[t_i];
            if (vp_waits[t_i] > t_mx) t_mx = vp_waits[t_i];
         end
      end
      $display("TIMING: L=%0d %0s first=%0d others=%0d (max %0d, %0d accesses) cycles=%0d",
               TM_L, name, vp_waits[0], t_w, t_mx, vp_n, vp_cyc);
      if ((exp >= 0) && (t_w != exp)) begin
         $display("ERROR: %0s: %0d wait states after the first / expected %0d %t", name, t_w, exp, $time);
         error = error + 1;
      end
      vp_clear;
   end
endtask

// Every pattern, idle (exp checked) or contended (reported)
task t_patterns;
   input contended;
   begin
      // writes in address order: words, half-words, bytes
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b1, 3'b010, 4*(TM_W0 + t_k), 0);
      t_run("wr word run", contended ? -1 : 0);
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b1, 3'b001, 4*TM_W0 + 2*t_k, 0);
      t_run("wr half run", contended ? -1 : 0);
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b1, 3'b000, 4*TM_W0 + t_k, 0);
      t_run("wr byte run", contended ? -1 : 0);
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b1, 3'b010, 4*(TM_W0 + ($random(tmp_seed) & 255)), 0);
      t_run("wr word random", contended ? -1 : 0);
      // reads in address order, back to back and with a free cycle
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b0, 3'b010, 4*(TM_W0 + 64 + t_k), 0);
      t_run("rd word run b2b", contended ? -1 : 31 * (TM_L - 1));
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b0, 3'b010, 4*(TM_W0 + 128 + t_k), 2);
      t_run("rd word run gap2", -1);
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b0, 3'b001, 4*(TM_W0 + 160) + 2*t_k, 0);
      t_run("rd half run b2b", contended ? -1 : 15 * (TM_L - 1));
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b0, 3'b000, 4*(TM_W0 + 192) + t_k, 0);
      t_run("rd byte run b2b", contended ? -1 : 7 * (TM_L - 1));
      // random word reads (the buffer misses)
      for (t_k = 0; t_k < TM_N; t_k = t_k + 1) t_add(1'b0, 3'b010, 4*(TM_W0 + 2*(($random(tmp_seed) & 127))), 0);
      t_run("rd word random", contended ? -1 : 31 * TM_L);
      // a write then a read of the same word, byte lanes then the word
      for (t_k = 0; t_k < TM_N/2; t_k = t_k + 1) begin
         t_add(1'b1, 3'b010, 4*(TM_W0 + t_k), 0);
         t_add(1'b0, 3'b010, 4*(TM_W0 + t_k), 0);
      end
      t_run("wr+rd same word", contended ? -1 : 16 * TM_L);
      for (t_k = 0; t_k < TM_N/2; t_k = t_k + 1) begin
         t_add(1'b1, 3'b000, 4*(TM_W0 + 16 + t_k/4) + (t_k & 3), 0);
         t_add(1'b0, 3'b010, 4*(TM_W0 + 16 + t_k/4), 0);
      end
      t_run("wr byte+rd word", contended ? -1 : 16 * TM_L);
      // a load / store copy in address order
      for (t_k = 0; t_k < TM_N/2; t_k = t_k + 1) begin
         t_add(1'b0, 3'b010, 4*(TM_W0 + 64 + t_k), 0);
         t_add(1'b1, 3'b010, 4*(TM_W0 + 224 + t_k), 0);
      end
      t_run("copy ld/st", contended ? -1 : 15 * TM_L2);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        REGS: VRAM-WINDOW WAIT STATES          |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (VRAM_WORDS < 16384)
         tb_skip_finish("|        (needs VRAM_WORDS >= 16384)            |");

      for (t_i = 0; t_i < 256; t_i = t_i + 1) begin
         t_ref[t_i] = $random(tmp_seed);
         vram_mem[TM_W0 + t_i] = t_ref[t_i];
      end
      vp_clear;

      // Idle VRAM
      t_patterns(1'b0);

      // Contention: a GPU fill and the refresh
      reg_wr(CTRL, {27'h0, (GPU_EN != 0) ? 2'b10 : 2'b00, GFX_16BPP});
      if (HAS_8080) begin
         reg_wr(DISP_SIZE,  (64 << 16) | 64);
         reg_wr(FRAME0_PTR, 32'h0);
         reg_wr(FRAME_SEL,  32'h0);
         reg_wr(DIF_CFG, 32'h0000_0001);               // LCD_ON, 8080, CLK_DIV 0
         reg_wr(REFRESH, (300 << 4) | 1);
      end
      if (GPU_EN != 0) begin
         reg_wr(GPU_CMD, {OP_SET_DST,  12'h000, 16'd256});
         reg_wr(GPU_CMD, 2*TM_GW0);
         reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd32, 14'd256});
         reg_wr(GPU_CMD, {OP_SET_FILL, 28'h0});
         reg_wr(GPU_CMD, 32'h0000_1234);
         for (t_i = 0; t_i < 6; t_i = t_i + 1) reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
      end
      repeat (50) @(posedge free_clk);
      t_patterns(1'b1);

      if (GPU_EN != 0) reg_poll(GPU_STAT, 32'h0030_0000, 32'h0, 20000);
      if (HAS_8080) begin
         reg_wr(REFRESH, 32'h0);
         reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 20000);
      end
      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
