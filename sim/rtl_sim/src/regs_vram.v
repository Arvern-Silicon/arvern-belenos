//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_vram
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_vram.v
// Module Description : VRAM-window port:
//                      - byte writes at every lane, half-words at both
//                        halves, words, also half-words at +1 / +3 and words
//                        at +1..+3 (address bits [0] / [1:0] ignored: the
//                        aligned half / word, OKAY), with distinct garbage on the inactive
//                        lanes of hwdata: only the addressed bytes change,
//                        the macro sees exactly those byte enables; reads of
//                        every size and lane return the macro data;
//                      - uncontended: writes zero wait, reads VWIN_RD_L;
//                      - a word index >= VRAM_WORDS (every size) and any
//                        size > word: two-cycle ERROR, no macro access;
//                      - PRIV_CHECK_EN: U-mode ERROR, S/M OKAY;
//                      - pipelined random mixes of sizes, lanes, reads and
//                        writes on a few words (read-after-write in the next
//                        cycle), INCR bursts (NONSEQ + SEQ) of words, halves
//                        and bytes, BUSY inside a burst, IDLE with hsel;
//                      - hsel = 0 ignored; an address phase held under
//                        fabric wait states makes exactly one access.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer VW_SLOTS = 6;

integer     w_i, w_k, w_l, w_n, w_s, w_wr0, w_rd0;
reg  [31:0] w_v, w_be, w_a, w_exp, w_mask, w_last;
reg  [31:0] w_slot [0:VW_SLOTS-1];       // word address of each slot
reg  [31:0] w_ref  [0:VW_SLOTS-1];       // expected contents
integer     w_pslot [0:PIPE_MAX-1];      // slot of each pipelined transfer
reg  [31:0] w_pexp  [0:PIPE_MAX-1];      // expected read data (full word)
reg  [31:0] w_pmask [0:PIPE_MAX-1];      // lanes compared

// VRAM macro monitor
integer     m_wr, m_rd;
reg   [3:0] m_wen;
reg  [31:0] m_addr, m_din;
initial begin m_wr = 0; m_rd = 0; end
always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (vram_cen === 1'b0)) begin
     if (vram_wen !== 4'hF) begin
        m_wr = m_wr + 1; m_wen = vram_wen; m_addr = vram_addr; m_din = vram_din;
     end else
        m_rd = m_rd + 1;
  end

function [31:0] lane_mask;
   input [2:0]  size;
   input [31:0] addr;
   begin
      lane_mask = (size == 3'b000) ? (32'hFF   << (8*addr[1:0])) :
                  (size == 3'b001) ? (32'hFFFF << (16*addr[1]))  : 32'hFFFF_FFFF;
   end
endfunction

// Pick a random size / lane access
task w_rand_acc;
   output [2:0]  size;
   output [31:0] off;
   reg    [1:0]  r;
   begin
      r = $random(tmp_seed);
      size = (r == 2'd3) ? 3'b010 : {1'b0, r[0]};
      off  = (size == 3'b000) ? ($random(tmp_seed) & 3) : (size == 3'b001) ? ($random(tmp_seed) & 2) : 0;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|             REGS: VRAM WINDOW PORT            |");
      $display(" ===============================================");
      @(posedge reset_done);

      // Slot addresses: first word, last word, and random words in between
      w_slot[0] = 0;
      w_slot[1] = VRAM_WORDS - 1;
      for (w_i = 2; w_i < VW_SLOTS; w_i = w_i + 1)
         w_slot[w_i] = ($random(tmp_seed) & 32'h7FFF_FFFF) % VRAM_WORDS;
      for (w_i = 0; w_i < VW_SLOTS; w_i = w_i + 1) begin
         w_ref[w_i] = $random(tmp_seed);
         vram_mem[w_slot[w_i]] = w_ref[w_i];
      end
      // resolve aliasing between slots (small VRAMs)
      for (w_i = 0; w_i < VW_SLOTS; w_i = w_i + 1)
         for (w_k = 0; w_k < w_i; w_k = w_k + 1)
            if (w_slot[w_k] == w_slot[w_i]) w_ref[w_k] = w_ref[w_i];

      //------------------------------------------------------------------
      // Every lane, one access at a time: data, byte enables, wait states
      //------------------------------------------------------------------
      for (w_s = 0; w_s < VW_SLOTS; w_s = w_s + 1) begin
         for (w_l = 0; w_l < 12; w_l = w_l + 1) begin
            // w_l 0..3: byte lanes, 4..5: halves, 6: word, 7..8: halves at
            // +1 / +3, 9..11: words at +1..+3
            w_a  = 4*w_slot[w_s] + ((w_l < 4) ? w_l : (w_l == 4) ? 0 : (w_l == 5) ? 2 : (w_l == 6) ? 0 :
                                    (w_l == 7) ? 1 : (w_l == 8) ? 3 : (w_l - 8));
            w_v  = $random(tmp_seed);
            w_mask = lane_mask((w_l < 4) ? 3'b000 : ((w_l < 6) || (w_l == 7) || (w_l == 8)) ? 3'b001 : 3'b010, w_a);
            vp_clear;
            vp_add(w_a, 1'b1, (w_l < 4) ? 3'b000 : ((w_l < 6) || (w_l == 7) || (w_l == 8)) ? 3'b001 : 3'b010, w_v, MACHINE, HART_MASTER, 2'b10, 0);
            vp_add(w_a, 1'b0, (w_l < 4) ? 3'b000 : ((w_l < 6) || (w_l == 7) || (w_l == 8)) ? 3'b001 : 3'b010, 32'h0, MACHINE, HART_MASTER, 2'b10, 2);
            vp_add(4*w_slot[w_s], 1'b0, 3'b010, 32'h0, MACHINE, HART_MASTER, 2'b10, 2);
            w_wr0 = m_wr;
            vp_run;
            repeat (2) @(posedge free_clk);
            w_ref[w_s] = (w_ref[w_s] & ~w_mask) | (w_v & w_mask);
            for (w_k = 0; w_k < VW_SLOTS; w_k = w_k + 1)
               if (w_slot[w_k] == w_slot[w_s]) w_ref[w_k] = w_ref[w_s];
            vp_chk(0, OK, 0, 0, 0);
            vp_chk(1, OK, w_ref[w_s], w_mask, 1);
            vp_chk(2, OK, w_ref[w_s], 32'hFFFF_FFFF, 1);
            if (m_wr != w_wr0 + 1) begin
               $display("ERROR: %0d macro writes for one window write %t", m_wr - w_wr0, $time);
               error = error + 1;
            end else if ((m_addr !== w_slot[w_s]) || (m_wen !== ~{w_mask[24], w_mask[16], w_mask[8], w_mask[0]}) ||
                         ((m_din & w_mask) !== (w_v & w_mask))) begin
               $display("ERROR: macro write addr 0x%h wen %b din 0x%h / expected addr 0x%h lanes 0x%h data 0x%h %t",
                        m_addr, m_wen, m_din, w_slot[w_s], w_mask, w_v & w_mask, $time);
               error = error + 1;
            end
            if (vram_mem[w_slot[w_s]] !== w_ref[w_s]) begin
               $display("ERROR: VRAM word 0x%h = 0x%h / expected 0x%h %t", w_slot[w_s], vram_mem[w_slot[w_s]], w_ref[w_s], $time);
               error = error + 1;
            end
         end
         // reads of every lane against a back-door value
         w_v = $random(tmp_seed);
         vram_mem[w_slot[w_s]] = w_v;
         for (w_k = 0; w_k < VW_SLOTS; w_k = w_k + 1)
            if (w_slot[w_k] == w_slot[w_s]) w_ref[w_k] = w_v;
         vp_clear;
         for (w_l = 0; w_l < 4; w_l = w_l + 1) vp_add(4*w_slot[w_s] + w_l, 1'b0, 3'b000, 0, MACHINE, HART_MASTER, 2'b10, 0);
         vp_add(4*w_slot[w_s] + 0, 1'b0, 3'b001, 0, MACHINE, HART_MASTER, 2'b10, 0);
         vp_add(4*w_slot[w_s] + 2, 1'b0, 3'b001, 0, MACHINE, HART_MASTER, 2'b10, 0);
         vp_add(4*w_slot[w_s],     1'b0, 3'b010, 0, MACHINE, HART_MASTER, 2'b10, 0);
         vp_run;
         for (w_l = 0; w_l < 4; w_l = w_l + 1) vp_chk(w_l, OK, w_v, 32'hFF << (8*w_l), -1);
         vp_chk(4, OK, w_v, 32'h0000_FFFF, -1);
         vp_chk(5, OK, w_v, 32'hFFFF_0000, -1);
         vp_chk(6, OK, w_v, 32'hFFFF_FFFF, -1);
      end
      $display("OK:    every lane written and read");

      //------------------------------------------------------------------
      // ERROR cases: out of range, size > word, privilege
      //------------------------------------------------------------------
      repeat (2) @(posedge free_clk);
      w_wr0 = m_wr; w_rd0 = m_rd;
      vp_clear;
      if (VRAM_WORDS < (1 << VRAM_AW)) begin
         for (w_k = 0; w_k < 2; w_k = w_k + 1) begin
            w_a = (w_k == 0) ? 4*VRAM_WORDS : 4*((1 << VRAM_AW) - 1);
            for (w_i = 0; w_i < 2; w_i = w_i + 1) begin
               vp_add(w_a + 0, w_i, 3'b010, 32'hDEAD_BEEF, MACHINE, HART_MASTER, 2'b10, 0);
               vp_add(w_a + 1, w_i, 3'b000, 32'hDEAD_BEEF, MACHINE, HART_MASTER, 2'b10, 0);
               vp_add(w_a + 3, w_i, 3'b000, 32'hDEAD_BEEF, MACHINE, HART_MASTER, 2'b10, 1);
               vp_add(w_a + 2, w_i, 3'b001, 32'hDEAD_BEEF, MACHINE, HART_MASTER, 2'b10, 0);
               vp_add(w_a + 0, w_i, 3'b010, 32'hDEAD_BEEF, SUPERVISOR, HART_MASTER, 2'b11, 0);
            end
         end
      end else
         $display("INFO:  VRAM_WORDS = 2^VRAM_AW: no out-of-range word");
      for (w_i = 0; w_i < 2; w_i = w_i + 1)
         for (w_k = 3; w_k < 8; w_k = w_k + 1)
            vp_add(4*w_slot[2], w_i, w_k, 32'hDEAD_BEEF, MACHINE, HART_MASTER, 2'b10, w_k & 1);
      if (PRIV_CHECK_EN != 0)
         for (w_i = 0; w_i < 2; w_i = w_i + 1) begin
            vp_add(4*w_slot[3],     w_i, 3'b010, 32'hDEAD_BEEF, USER,  HART_MASTER, 2'b10, 0);
            vp_add(4*w_slot[3] + 1, w_i, 3'b000, 32'hDEAD_BEEF, USER,  HART_MASTER, 2'b10, 0);
            vp_add(4*w_slot[3] + 2, w_i, 3'b001, 32'hDEAD_BEEF, 2'b10, HART_MASTER, 2'b10, 0);
         end
      vp_run;
      repeat (3) @(posedge free_clk);
      for (w_i = 0; w_i < vp_n; w_i = w_i + 1) vp_chk(w_i, ERROR, 0, 0, 1);
      if ((m_wr != w_wr0) || (m_rd != w_rd0)) begin
         $display("ERROR: VRAM macro accessed by ERROR transfers (%0d writes, %0d reads) %t", m_wr - w_wr0, m_rd - w_rd0, $time);
         error = error + 1;
      end
      for (w_i = 0; w_i < VW_SLOTS; w_i = w_i + 1)
         if (vram_mem[w_slot[w_i]] !== w_ref[w_i]) begin
            $display("ERROR: VRAM word 0x%h changed by an ERROR transfer %t", w_slot[w_i], $time);
            error = error + 1;
         end
      // ERROR followed by a pipelined access (kept), then cancelled
      vp_clear;
      vp_add(4*w_slot[2], 1'b1, 3'b011, 32'h0,         MACHINE, HART_MASTER, 2'b10, 0);
      vp_add(4*w_slot[2], 1'b1, 3'b010, 32'hC0DE_0001, MACHINE, HART_MASTER, 2'b10, 0);
      vp_add(4*w_slot[2], 1'b0, 3'b010, 32'h0,         MACHINE, HART_MASTER, 2'b10, 0);
      vp_run;
      vp_chk(0, ERROR, 0, 0, 1);
      vp_chk(1, OK, 0, 0, 0);
      vp_chk(2, OK, 32'hC0DE_0001, 32'hFFFF_FFFF, 1);
      vp_cancel_on_err = 1'b1;
      vp_clear;
      vp_add(4*w_slot[2], 1'b0, 3'b100, 32'h0,         MACHINE, HART_MASTER, 2'b10, 0);
      vp_add(4*w_slot[2], 1'b1, 3'b010, 32'hC0DE_0002, MACHINE, HART_MASTER, 2'b10, 0);
      vp_add(4*w_slot[2], 1'b0, 3'b010, 32'h0,         MACHINE, HART_MASTER, 2'b10, 0);
      vp_run;
      vp_cancel_on_err = 1'b0;
      vp_chk(0, ERROR, 0, 0, 1);
      if (!vp_cancelled[1]) tb_error("window: pipelined transfer after an ERROR not cancelled");
      vp_chk(2, OK, 32'hC0DE_0001, 32'hFFFF_FFFF, 1);
      w_ref[2] = 32'hC0DE_0001;
      for (w_k = 0; w_k < VW_SLOTS; w_k = w_k + 1) if (w_slot[w_k] == w_slot[2]) w_ref[w_k] = w_ref[2];
      if (PRIV_CHECK_EN != 0) begin
         vp_clear;
         vp_add(4*w_slot[3], 1'b1, 3'b010, 32'h5005_0001, SUPERVISOR, HART_MASTER, 2'b10, 0);
         vp_add(4*w_slot[3], 1'b0, 3'b010, 32'h0,         MACHINE,    HART_MASTER, 2'b10, 0);
         vp_run;
         vp_chk(0, OK, 0, 0, 0);
         vp_chk(1, OK, 32'h5005_0001, 32'hFFFF_FFFF, 1);
      end else begin
         vp_clear;
         vp_add(4*w_slot[3], 1'b1, 3'b010, 32'h5005_0001, USER, HART_MASTER, 2'b10, 0);
         vp_add(4*w_slot[3], 1'b0, 3'b010, 32'h0,         USER, HART_MASTER, 2'b10, 0);
         vp_run;
         vp_chk(0, OK, 0, 0, 0);
         vp_chk(1, OK, 32'h5005_0001, 32'hFFFF_FFFF, 1);
      end
      w_ref[3] = 32'h5005_0001;
      for (w_k = 0; w_k < VW_SLOTS; w_k = w_k + 1) if (w_slot[w_k] == w_slot[3]) w_ref[w_k] = w_ref[3];
      $display("OK:    ERROR cases");

      //------------------------------------------------------------------
      // Pipelined random mixes (reference model in issue order)
      //------------------------------------------------------------------
      for (w_n = 0; w_n < 6; w_n = w_n + 1) begin
         vp_clear;
         for (w_i = 0; w_i < 80; w_i = w_i + 1) begin
            w_s = ($random(tmp_seed) & 32'hFF) % 3;          // three slots: many hazards
            w_rand_acc(w_k, w_a);
            w_a = 4*w_slot[w_s] + w_a;
            w_v = $random(tmp_seed);
            w_mask = lane_mask(w_k, w_a);
            if ($random(tmp_seed) & 1) begin
               vp_add(w_a, 1'b1, w_k, w_v, MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b10,
                      ((w_n & 1) && (($random(tmp_seed) & 3) == 0)) ? 1 : 0);
               w_ref[w_s] = (w_ref[w_s] & ~w_mask) | (w_v & w_mask);
               for (w_l = 0; w_l < VW_SLOTS; w_l = w_l + 1) if (w_slot[w_l] == w_slot[w_s]) w_ref[w_l] = w_ref[w_s];
               w_pmask[vp_n-1] = 0;
            end else begin
               vp_add(w_a, 1'b0, w_k, 0, MACHINE, HART_MASTER, 2'b10,
                      ((w_n & 1) && (($random(tmp_seed) & 3) == 0)) ? 1 : 0);
               w_pexp[vp_n-1]  = w_ref[w_s];
               w_pmask[vp_n-1] = w_mask;
            end
         end
         vp_run;
         for (w_i = 0; w_i < vp_n; w_i = w_i + 1) vp_chk(w_i, OK, w_pexp[w_i], w_pmask[w_i], -1);
         repeat (2) @(posedge free_clk);
         for (w_i = 0; w_i < 3; w_i = w_i + 1)
            if (vram_mem[w_slot[w_i]] !== w_ref[w_i]) begin
               $display("ERROR: after pipelined mix %0d: VRAM word 0x%h = 0x%h / expected 0x%h %t", w_n, w_slot[w_i], vram_mem[w_slot[w_i]], w_ref[w_i], $time);
               error = error + 1;
            end
      end
      $display("OK:    pipelined random mixes");

      //------------------------------------------------------------------
      // INCR bursts (NONSEQ then SEQ), BUSY inside, IDLE with hsel
      //------------------------------------------------------------------
      if (VRAM_WORDS >= 16) begin
         w_a = 4 * (((($random(tmp_seed) & 32'hFFFF) % (VRAM_WORDS / 16))) * 16);   // 16-word aligned block
         // word burst write x8, read x8
         vp_clear;
         for (w_i = 0; w_i < 8; w_i = w_i + 1)
            vp_add(w_a + 4*w_i, 1'b1, 3'b010, 32'hB0B0_0000 + w_i, MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b11, 0);
         for (w_i = 0; w_i < 8; w_i = w_i + 1)
            vp_add(w_a + 4*w_i, 1'b0, 3'b010, 0, MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b11, 0);
         // half-word burst write x8 over words 8..11, with a BUSY in the middle
         for (w_i = 0; w_i < 8; w_i = w_i + 1) begin
            if (w_i == 4) vp_add(w_a + 32 + 2*w_i, 1'b1, 3'b001, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b01, 0);   // BUSY
            vp_add(w_a + 32 + 2*w_i, 1'b1, 3'b001, {2{16'hC100 + w_i[15:0]}} ^ (w_i[0] ? 32'h0000_FFFF : 32'hFFFF_0000), MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b11, 0);
         end
         // IDLE with hsel high (write, garbage): ignored
         vp_add(w_a + 32, 1'b1, 3'b010, 32'hFFFF_FFFF, MACHINE, HART_MASTER, 2'b00, 0);
         // byte burst write x8 over words 12..13
         for (w_i = 0; w_i < 8; w_i = w_i + 1)
            vp_add(w_a + 48 + w_i, 1'b1, 3'b000, {4{8'h70 + w_i[7:0]}} ^ ~(32'hFF << (8*w_i[1:0])), MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b11, 0);
         // read back words 8..13 as a word burst and as a byte burst
         for (w_i = 0; w_i < 6; w_i = w_i + 1)
            vp_add(w_a + 32 + 4*w_i, 1'b0, 3'b010, 0, MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b11, 0);
         for (w_i = 0; w_i < 8; w_i = w_i + 1)
            vp_add(w_a + 48 + w_i, 1'b0, 3'b000, 0, MACHINE, HART_MASTER, (w_i == 0) ? 2'b10 : 2'b11, 0);
         vp_run;
         for (w_i = 0; w_i < 8; w_i = w_i + 1) vp_chk(w_i, OK, 0, 0, 0);
         for (w_i = 0; w_i < 8; w_i = w_i + 1) vp_chk(8 + w_i, OK, 32'hB0B0_0000 + w_i, 32'hFFFF_FFFF, -1);
         for (w_i = 16; w_i < 26; w_i = w_i + 1) vp_chk(w_i, OK, 0, 0, 0);       // halves, BUSY, IDLE
         for (w_i = 26; w_i < 34; w_i = w_i + 1) vp_chk(w_i, OK, 0, 0, 0);       // bytes
         vp_chk(34, OK, {16'hC101, 16'hC100}, 32'hFFFF_FFFF, -1);
         vp_chk(35, OK, {16'hC103, 16'hC102}, 32'hFFFF_FFFF, -1);
         vp_chk(36, OK, {16'hC105, 16'hC104}, 32'hFFFF_FFFF, -1);
         vp_chk(37, OK, {16'hC107, 16'hC106}, 32'hFFFF_FFFF, -1);
         vp_chk(38, OK, 32'h7372_7170, 32'hFFFF_FFFF, -1);
         vp_chk(39, OK, 32'h7776_7574, 32'hFFFF_FFFF, -1);
         for (w_i = 0; w_i < 8; w_i = w_i + 1) vp_chk(40 + w_i, OK, {4{8'h70 + w_i[7:0]}}, 32'hFF << (8*w_i[1:0]), -1);
         $display("OK:    INCR bursts");
      end

      //------------------------------------------------------------------
      // hsel = 0 ignored; stalled address phase: one access
      //------------------------------------------------------------------
      repeat (2) @(posedge free_clk);
      w_wr0 = m_wr;
      @(negedge free_clk);
      v_hsel = 1'b0; v_haddr = 4*w_slot[4]; v_htrans = 2'b10; v_hwrite = 1'b1; v_hsize = 3'b010; v_hprot = 4'h3;
      @(posedge free_clk);
      v_htrans = 2'b00; v_hwrite = 1'b0; v_hwdata = 32'h1111_2222;
      repeat (3) @(posedge free_clk);
      if (m_wr != w_wr0) tb_error("window write with hsel = 0 reached the macro");
      @(negedge free_clk);
      v_force_stall = 1'b1;
      v_hsel = 1'b1; v_haddr = 4*w_slot[4]; v_htrans = 2'b10; v_hwrite = 1'b1; v_hsize = 3'b010;
      v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      repeat (4) @(negedge free_clk);
      v_force_stall = 1'b0;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0; v_hwdata = 32'h3333_4444;
      @(negedge free_clk);
      while (v_hready !== 1'b1) @(negedge free_clk);
      @(posedge free_clk);
      repeat (3) @(posedge free_clk);
      if (m_wr != w_wr0 + 1) begin
         $display("ERROR: stalled window write made %0d macro writes / expected 1 %t", m_wr - w_wr0, $time);
         error = error + 1;
      end
      vram_rd(4*w_slot[4], 32'h3333_4444, SZ_W);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
