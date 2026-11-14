//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_vram_prefetch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_vram_prefetch.v
// Module Description : VRAM-window read-ahead buffer. A run of word reads:
//                      the first waits, every next one is served from the
//                      buffer with no wait state; pipelined (each address
//                      phase in the previous data phase, as a CPU's
//                      back-to-back loads), one per cycle of the window's
//                      read latency past the first (VWIN_RD_L: VRAM_RD_LAT
//                      + 1, the window or the arbiter registering the
//                      data). A word read again,
//                      and the other bytes and half-words of the word last
//                      read, are served with no wait state. A window write, a
//                      GPU fill and a write at the same moment as the read
//                      ahead's grant to the buffered word drop it: the next
//                      read returns the new data. No read ahead past the last
//                      VRAM word. Every read is checked against the data
//                      written; the bench also checks every read the buffer
//                      serves against the VRAM model (cover_monitor.v).
//----------------------------------------------------------------------------

localparam integer PB_W0   = 64;                                  // first word of the run
localparam integer PB_N    = 16;                                  // words in the run
localparam integer PB_MISS = VWIN_RD_L;                           // wait states of a read the buffer misses
localparam integer PB_NEXT = (PB_MISS > 2) ? PB_MISS - 2 : 0;     // ... of the next word of a run
localparam integer PB_PIPE = VWIN_RD_L - 1;                       // ... of the next word, pipelined

integer    pb_i;
integer    pb_w1;
integer    pb_wn;
integer    pb_b;
reg [31:0] pb_val;

function [31:0] pb_pat;
   input integer i;
   begin
      pb_pat = 32'hA500_0000 ^ (i * 32'h0001_0203);
   end
endfunction

// Read and check the data and the wait states: at most exp_waits (< 0: any;
// a miss can wait a cycle more when a read ahead was just granted)
task pb_rd;
   input  [31:0] addr;
   input  [31:0] exp_data;
   input   [1:0] size;
   input integer exp_waits;
   input [8*24-1:0] what;
   begin
      vram_rd(addr, exp_data, size);
      if ((exp_waits >= 0) && (ahb_last_waits > exp_waits)) begin
         $display("ERROR: read-ahead %0s -- address 0x%h: %0d wait states / expected at most %0d %t",
                  what, addr, ahb_last_waits, exp_waits, $time);
         error = error + 1;
      end
   end
endtask

// A pipelined run of n word reads from word index i0 (each address phase
// during the previous data phase): the data checked; w1 = wait states of the
// first read, wn = of all the others
task pb_pipe;
   input  integer i0;
   input  integer n;
   output integer w1;
   output integer wn;
   integer k;
   begin
      w1 = 0;
      wn = 0;
      @(negedge free_clk);
      while (v_hready !== 1'b1) @(negedge free_clk);
      for (k = 0; k <= n; k = k + 1) begin
         if (k < n) begin
            v_hsel = 1'b1; v_haddr = 4 * (PB_W0 + i0 + k); v_htrans = 2'b10; v_hwrite = 1'b0;
            v_hsize = {1'b0, SZ_W}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
         end else begin
            v_hsel = 1'b0; v_htrans = 2'b00;
         end
         // The cycle ends at the next rising edge: read k - 1 completes and
         // read k's address is taken when hready is high
         #1;
         while (v_hready !== 1'b1) begin
            if (k == 1) w1 = w1 + 1;
            else if (k > 1) wn = wn + 1;
            @(negedge free_clk);
            #1;
         end
         if ((k > 0) && (v_hrdata !== pb_pat(i0 + k - 1))) begin
            $display("ERROR: pipelined read-ahead run -- word %0d: 0x%h / expected 0x%h %t",
                     i0 + k - 1, v_hrdata, pb_pat(i0 + k - 1), $time);
            error = error + 1;
         end
         @(negedge free_clk);
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        REGS: VRAM-WINDOW READ-AHEAD BUFFER    |");
      $display(" ===============================================");
      @(posedge reset_done);

      // Background
      for (pb_i = 0; pb_i < 2 * PB_N; pb_i = pb_i + 1)
         vram_wr(4 * (PB_W0 + pb_i), pb_pat(pb_i), SZ_W);

      // A run of word reads
      pb_rd(4 * PB_W0, pb_pat(0), SZ_W, PB_MISS + 1, "run, first word");
      for (pb_i = 1; pb_i < PB_N; pb_i = pb_i + 1)
         pb_rd(4 * (PB_W0 + pb_i), pb_pat(pb_i), SZ_W, PB_NEXT, "run, next word");
      $display("OK:    a run of %0d word reads: %0d wait state(s) after the first", PB_N, PB_NEXT);

      // The same, pipelined
      pb_pipe(PB_N, PB_N, pb_w1, pb_wn);
      if (pb_wn > PB_PIPE * (PB_N - 1)) begin
         $display("ERROR: pipelined run of %0d word reads: %0d wait states after the first / expected at most %0d %t",
                  PB_N, pb_wn, PB_PIPE * (PB_N - 1), $time);
         error = error + 1;
      end else
         $display("OK:    a pipelined run of %0d word reads: %0d wait state(s) for the first, %0d for the %0d others",
                  PB_N, pb_w1, pb_wn, PB_N - 1);

      // The word last read, again
      pb_rd(4 * (PB_W0 + PB_N - 1), pb_pat(PB_N - 1), SZ_W, -1, "word read again (miss)");
      pb_rd(4 * (PB_W0 + 3), pb_pat(3) & 32'hFFFF, SZ_H, PB_MISS, "half-word, new word");
      pb_rd(4 * (PB_W0 + 3), pb_pat(3) & 32'hFFFF, SZ_H, 0, "same half-word again");
      pb_rd(4 * (PB_W0 + 3) + 2, pb_pat(3) >> 16, SZ_H, 0, "upper half-word");

      // A run of byte reads: the bytes after the first of a word, and the next word
      pb_rd(4 * (PB_W0 + 8), pb_pat(8) & 32'hFF, SZ_B, PB_MISS, "bytes, first");
      for (pb_i = 8; pb_i < 12; pb_i = pb_i + 1)
         for (pb_b = (pb_i == 8) ? 1 : 0; pb_b < 4; pb_b = pb_b + 1)
            pb_rd(4 * (PB_W0 + pb_i) + pb_b, (pb_pat(pb_i) >> (8 * pb_b)) & 32'hFF, SZ_B,
                  (pb_b == 0) ? PB_NEXT : 0, "bytes, next");
      $display("OK:    byte runs served by the buffer");

      // A window write to the buffered word drops it
      pb_rd(4 * (PB_W0 + 20), pb_pat(20), SZ_W, -1, "before a window write");
      repeat (4) @(posedge free_clk);
      vram_wr(4 * (PB_W0 + 21), 32'h1357_9BDF, SZ_W);
      pb_rd(4 * (PB_W0 + 21), 32'h1357_9BDF, SZ_W, PB_MISS, "after a window write");
      $display("OK:    a window write drops the buffered word");

      // A GPU fill over the buffered word drops it
      if ((GPU_EN != 0) && (VRAM_WORDS >= 2048)) begin
         pb_rd(4 * (PB_W0 + 22), pb_pat(22), SZ_W, -1, "before a GPU fill");
         repeat (4) @(posedge free_clk);
         reg_wr(CTRL, 32'h0000_0010 | {29'h0, GFX_16BPP});
         reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, 16'd8});
         reg_wr(GPU_CMD, 2 * (PB_W0 + 23));                     // the pixel pair of word 23
         reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd1, 14'd2});
         reg_wr(GPU_CMD, {OP_SET_FILL, 28'h000_0000});
         reg_wr(GPU_CMD, 32'h0000_7E0F);
         reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h000_0000});
         reg_poll(GPU_STAT, 32'h0021_0000, 32'h0001_0000, 200);
         pb_rd(4 * (PB_W0 + 23), 32'h7E0F_7E0F, SZ_W, PB_MISS, "after a GPU fill");
         $display("OK:    a GPU fill drops the buffered word");
      end

      // The last VRAM word: no read ahead past it, the word kept
      if (VRAM_WORDS >= 2) begin
         vram_wr(4 * (VRAM_WORDS - 1), 32'h2468_ACE0, SZ_W);
         pb_rd(4 * (VRAM_WORDS - 1), 32'h2468_ACE0, SZ_W, PB_MISS, "last word");
         pb_rd(4 * (VRAM_WORDS - 1), 32'h2468_ACE0, SZ_W, 0, "last word again");
         $display("OK:    the last VRAM word kept, no read ahead past it");
      end

      // Writes from every requester against a read run: the bench checks every
      // read the buffer serves against the VRAM model
      for (pb_i = 0; pb_i < 64; pb_i = pb_i + 1) begin
         if (pb_i % 3 == 0) vram_wr(4 * (PB_W0 + (pb_i % 30) + 1), pb_pat(pb_i + 100), SZ_W);
         vram_rd_val(4 * (PB_W0 + (pb_i % 30)), SZ_W, pb_val);
      end

      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
