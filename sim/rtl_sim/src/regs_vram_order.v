//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_vram_order
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_vram_order.v
// Module Description : VRAM-window posted writes and their order with the
//                      register port. One manager drives both ports on one
//                      AHB-Lite bus (sb_*: each address phase in the previous
//                      data phase, one HREADY: the data-phase owner's), so a
//                      register transfer follows a window write with no gap:
//                      1. (GPU_EN) a command list written through the window
//                         while a GPU FILL takes its aged cycles, its CALL
//                         pushed in the next transfer: the list's FILL draws
//                         the colour just written; then an image word
//                         uploaded and a GPU COPY of it pushed at once;
//                      2. (8080 or BDI model) a frame written through the
//                         window, last word first, then a manual REFRESH in
//                         the next transfer: the panel receives that frame;
//                      3. a pipelined mix of byte / half-word / word writes
//                         and reads on four words, with ERROR transfers
//                         between, under a GPU FILL and the refresh: every
//                         read returns the latest write of its lanes, every
//                         ERROR is two cycles and changes nothing;
//                      4. back-pressure: a write behind a posted one waits
//                         for its drain (no transfer lost under the GPU's
//                         aging and an urgent refresh).
//                      A register transfer held behind a posted write, and
//                      a posted write, must each have happened.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer SB_MAX  = 256;
localparam integer OR_LW   = 4096;                   // list (word address)
localparam integer OR_DW   = 4352;                   // list FILL target: 8 x 2 pixels
localparam integer OR_SW   = 4608;                   // uploaded source word
localparam integer OR_CW   = 4864;                   // COPY destination word
localparam integer OR_BG   = 8192;                   // background FILL
localparam integer OR_MW   = 2304;                   // section 3 words
localparam integer OR_FW   = (DIM_W >= 5) ? 16 : 8;  // frame: 16 x 8 pixels at 16 bpp, words 0..63 (8 x 8 with DIM_W 4)
localparam integer OR_FH   = 8;

// Shared-bus transfer list
reg         sb_port  [0:SB_MAX-1];                  // 0 register port, 1 window
reg         sb_wr    [0:SB_MAX-1];
reg  [31:0] sb_addr  [0:SB_MAX-1];
reg   [2:0] sb_size  [0:SB_MAX-1];
reg  [31:0] sb_wdata [0:SB_MAX-1];
reg  [31:0] sb_rdata [0:SB_MAX-1];
reg         sb_resp  [0:SB_MAX-1];
integer     sb_waits [0:SB_MAX-1];
reg         sb_shape [0:SB_MAX-1];
reg  [31:0] sb_exp   [0:SB_MAX-1];
reg  [31:0] sb_msk   [0:SB_MAX-1];
reg         sb_eerr  [0:SB_MAX-1];                  // ERROR expected
integer     sb_n;
reg         sb_on;
reg   [1:0] sb_own;                                 // data-phase owner: 0 register port, 1 window, 2 none

integer     o_i, o_k, o_s, o_held, o_post, o_hit_call, o_hit_ref, o_px0, o_bad;
reg  [31:0] o_v, o_a, o_m, o_col;
reg   [2:0] o_sz;
reg  [15:0] o_ph, o_pl;
reg  [31:0] o_ref [0:3];

initial begin
   sb_n   = 0;
   sb_on  = 1'b0;
   sb_own = 2'd2;
   o_held = 0;
   o_post = 0;
end

// One HREADY for both ports: the port without the data phase sees the
// owner's HREADYOUT
always @(*)
   if (sb_on) begin
      r_force_stall = (sb_own == 2'd1) & ~v_hreadyout;
      v_force_stall = (sb_own == 2'd0) & ~r_hreadyout;
   end

// Register transfers held behind a posted window write, posted writes
always @(posedge hclk)
   if (model_on) begin
      if ((dut.u_core.u_ahb_reg.dph_valid === 1'b1) && (dut.u_core.u_ahb_reg.rb_go === 1'b0)) o_held = o_held + 1;
      if (dut.u_core.u_ahb_vram.wb_v === 1'b1) o_post = o_post + 1;
   end

function [31:0] or_lane;
   input [2:0]  size;
   input [31:0] addr;
   begin
      or_lane = (size == 3'b000) ? (32'hFF   << (8*addr[1:0])) :
                (size == 3'b001) ? (32'hFFFF << (16*addr[1]))  : 32'hFFFF_FFFF;
   end
endfunction

task sb_add;
   input        port;
   input        wr;
   input [31:0] addr;
   input [2:0]  size;
   input [31:0] wdata;
   begin
      sb_port[sb_n] = port; sb_wr[sb_n] = wr; sb_addr[sb_n] = addr; sb_size[sb_n] = size;
      sb_wdata[sb_n] = wdata; sb_exp[sb_n] = 32'h0; sb_msk[sb_n] = 32'h0; sb_eerr[sb_n] = 1'b0;
      sb_n = sb_n + 1;
   end
endtask

task sb_idle;
   begin
      r_hsel = 1'b0; r_htrans = 2'b00; r_haddr = $random(tmp_seed);
      v_hsel = 1'b0; v_htrans = 2'b00; v_haddr = $random(tmp_seed);
   end
endtask

// Run the list: the address phase of transfer n+1 in the data phase of n,
// held while HREADY is low; ERROR shape checked
task sb_run;
   integer ai, ap, dp, w;
   reg     ap_v, dp_v, hr, hrs, acc, done, err1;
   begin
      ai = 0; ap = 0; dp = 0; w = 0; ap_v = 1'b0; dp_v = 1'b0; err1 = 1'b0;
      @(posedge free_clk);
      sb_on = 1'b1; sb_own = 2'd2;
      while ((ai < sb_n) || ap_v || dp_v) begin
         if (!ap_v) begin
            sb_idle;
            if (ai < sb_n) begin
               if (sb_port[ai]) begin
                  v_hsel = 1'b1; v_haddr = sb_addr[ai]; v_htrans = 2'b10; v_hwrite = sb_wr[ai];
                  v_hsize = sb_size[ai]; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
               end else begin
                  r_hsel = 1'b1; r_haddr = sb_addr[ai]; r_htrans = 2'b10; r_hwrite = sb_wr[ai];
                  r_hsize = sb_size[ai]; r_hprot = 4'h3; r_hsmode = 1'b0; r_hmaster = HART_MASTER;
               end
               ap = ai; ap_v = 1'b1; ai = ai + 1;
            end
         end
         @(negedge free_clk);
         hr   = (sb_own == 2'd0) ? r_hready : (sb_own == 2'd1) ? v_hready : 1'b1;
         hrs  = (sb_own == 2'd0) ? r_hresp  : (sb_own == 2'd1) ? v_hresp  : 1'b0;
         done = 1'b0;
         if (dp_v) begin
            if (hr === 1'b1) begin
               sb_rdata[dp] = sb_port[dp] ? v_hrdata : r_hrdata;
               sb_resp[dp]  = hrs;
               sb_waits[dp] = w;
               sb_shape[dp] = (hrs === 1'b1) ? (err1 && (w == 1)) : !err1;
               done = 1'b1;
            end else begin
               if (hrs === 1'b1) err1 = 1'b1;
               w = w + 1;
               if (w > AHB_MAX_WAIT) begin
                  $display("ERROR: sb_run -- transfer %0d hung %t", dp, $time);
                  error = error + 1;
                  done = 1'b1;
               end
            end
         end
         acc = ap_v && (hr === 1'b1);
         @(posedge free_clk);
         if (done) begin
            dp_v = 1'b0; sb_own = 2'd2;
         end
         if (acc) begin
            dp = ap; dp_v = 1'b1; ap_v = 1'b0; w = 0; err1 = 1'b0;
            sb_own = sb_port[dp] ? 2'd1 : 2'd0;
            if (sb_port[dp]) v_hwdata = sb_wr[dp] ? sb_wdata[dp] : $random(tmp_seed);
            else             r_hwdata = sb_wr[dp] ? sb_wdata[dp] : $random(tmp_seed);
         end
      end
      sb_idle;
      @(posedge free_clk);
      sb_on = 1'b0; sb_own = 2'd2;
      r_force_stall = 1'b0; v_force_stall = 1'b0;
      // responses
      for (o_i = 0; o_i < sb_n; o_i = o_i + 1) begin
         tb_checks = tb_checks + 1;
         if ((sb_resp[o_i] !== sb_eerr[o_i]) || !sb_shape[o_i]) begin
            $display("ERROR: sb transfer %0d (%0s %0s 0x%h): resp %b shape %b / expected resp %b %t", o_i,
                     sb_port[o_i] ? "window" : "register", sb_wr[o_i] ? "write" : "read", sb_addr[o_i],
                     sb_resp[o_i], sb_shape[o_i], sb_eerr[o_i], $time);
            error = error + 1;
         end else if (!sb_wr[o_i] && !sb_eerr[o_i] && ((sb_rdata[o_i] & sb_msk[o_i]) !== (sb_exp[o_i] & sb_msk[o_i]))) begin
            $display("ERROR: sb read %0d (0x%h): 0x%h / expected 0x%h (mask 0x%h) %t", o_i, sb_addr[o_i],
                     sb_rdata[o_i] & sb_msk[o_i], sb_exp[o_i] & sb_msk[o_i], sb_msk[o_i], $time);
            error = error + 1;
         end
      end
      sb_n = 0;
   end
endtask

// A background GPU FILL of n pixel pairs (16 bpp, one line)
// n pixels in one row; a DIM_W too small for n: rows of 2^DIM_W - 1 pixels
// (at most that many rows), so that the GPU still contends for the VRAM
localparam integer OR_WMAX = (1 << DIM_W) - 1;
task or_bg_fill;
   input integer n;
   integer w, h;
   begin
      w = (n <= OR_WMAX) ? n : OR_WMAX;
      h = (n + w - 1) / w;
      if (h > OR_WMAX) h = OR_WMAX;
      reg_wr(GPU_CMD, {OP_SET_DST,  12'h000, 16'd512});
      reg_wr(GPU_CMD, 2*OR_BG);
      reg_wr(GPU_CMD, {OP_SET_SIZE, h[13:0], w[13:0]});
      reg_wr(GPU_CMD, {OP_SET_FILL, 28'h0});
      reg_wr(GPU_CMD, 32'h0000_0F0F);
      reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   REGS: VRAM-WINDOW POSTED WRITES AND ORDER   |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (VRAM_WORDS < 16384)
         tb_skip_finish("|        (needs VRAM_WORDS >= 16384)            |");

      reg_wr(CTRL, {27'h0, (GPU_EN != 0) ? 2'b10 : 2'b00, GFX_16BPP});

      //------------------------------------------------------------------
      // 1. A list written through the window, then its CALL; an upload,
      //    then its COPY
      //------------------------------------------------------------------
      o_hit_call = 0;
      if (GPU_EN != 0) begin
         for (o_k = 0; o_k < 48; o_k = o_k + 1) begin
            o_col = {16'h0, 16'h1000 + o_k};
            or_bg_fill(256 + 2 * (o_k % 8));
            o_i = 0;                                                         // the FILL under way
            while ((dut.u_core.v_req[1] !== 1'b1) && (o_i < 200)) begin
               @(posedge hclk); o_i = o_i + 1;
            end
            o_s = o_held;
            for (o_i = 0; o_i < (o_k % 8); o_i = o_i + 1)                  // shift the phase
               sb_add(1'b1, 1'b1, 4*(OR_LW + 16 + o_i), 3'b010, 32'h0);
            sb_add(1'b1, 1'b1, 4*(OR_LW + 0), 3'b010, {OP_SET_DST, 12'h000, 16'd8});
            sb_add(1'b1, 1'b1, 4*(OR_LW + 1), 3'b010, 2*OR_DW);
            sb_add(1'b1, 1'b1, 4*(OR_LW + 2), 3'b010, {OP_SET_SIZE, 14'd2, 14'd8});
            sb_add(1'b1, 1'b1, 4*(OR_LW + 3), 3'b010, {OP_SET_FILL, 28'h0});
            sb_add(1'b1, 1'b1, 4*(OR_LW + 4), 3'b010, o_col);
            sb_add(1'b1, 1'b1, 4*(OR_LW + 5), 3'b010, {OP_EXEC_FILL, 28'h0});
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, {OP_CALL, 4'h0, 24'd6});
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, OR_LW);
            // an upload, then its copy
            sb_add(1'b1, 1'b1, 4*OR_SW, 3'b010, {o_col[15:0], ~o_col[15:0]});
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, {OP_SET_SRC, 12'h000, 16'd2});
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, 2*OR_SW);
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, {OP_SET_DST, 12'h000, 16'd2});
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, 2*OR_CW);
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, {OP_SET_SIZE, 14'd1, 14'd2});
            sb_add(1'b0, 1'b1, GPU_CMD, 3'b010, {OP_EXEC_COPY, 28'h0});
            sb_run;
            if (o_held > o_s) o_hit_call = o_hit_call + 1;
            reg_poll(GPU_STAT, 32'h0030_0000, 32'h0, 20000);
            for (o_i = 0; o_i < 8; o_i = o_i + 1)                           // 2 lines of 4 words
               if (vram_mem[OR_DW + o_i] !== {2{o_col[15:0]}}) begin
                  $display("ERROR: list %0d: FILL word %0d = 0x%h / expected 0x%h %t", o_k, o_i,
                           vram_mem[OR_DW + o_i], {2{o_col[15:0]}}, $time);
                  error = error + 1;
               end
            tb_checks = tb_checks + 1;
            if (vram_mem[OR_CW] !== {o_col[15:0], ~o_col[15:0]}) begin
               $display("ERROR: upload %0d: COPY wrote 0x%h / expected 0x%h %t", o_k, vram_mem[OR_CW],
                        {o_col[15:0], ~o_col[15:0]}, $time);
               error = error + 1;
            end
         end
         $display("OK:    48 lists and uploads written through the window, their CALL / COPY pushed at once (%0d held behind a posted write)",
                  o_hit_call);
      end

      //------------------------------------------------------------------
      // 2. A frame written through the window, then a manual refresh
      //------------------------------------------------------------------
      o_hit_ref = 0;
      if (HAS_8080 || (DIF_TYPE == 0)) begin
         reg_wr(DISP_SIZE,  (OR_FH << 16) | OR_FW);
         reg_wr(FRAME0_PTR, 32'h0);
         reg_wr(FRAME_SEL,  32'h0);
         if (HAS_8080) begin
            reg_wr(DIF_CFG, 32'h0000_0001);            // LCD_ON, 8080, CLK_DIV 0
         end else begin
            bm_auto = 1'b1; bm_rise_delay = 2; bm_fall_delay = 2; bm_exp_px = OR_FW*OR_FH;
         end
         for (o_k = 0; o_k < 12; o_k = o_k + 1) begin
            if (GPU_EN != 0) or_bg_fill(16 + 4 * o_k);
            o_px0 = HAS_8080 ? u_lcd8080.px_count : bm_px;
            o_s = o_held;
            for (o_i = OR_FW*OR_FH/2 - 1; o_i >= 0; o_i = o_i - 1) begin
               o_ph = 16'h4000 + o_k*64 + o_i;
               o_pl = 16'h2000 + o_k*64 + o_i;
               sb_add(1'b1, 1'b1, 4*o_i, 3'b010, {o_ph, o_pl});
            end
            sb_add(1'b0, 1'b1, REFRESH, 3'b010, 32'h0000_0001);
            sb_run;
            if (o_held > o_s) o_hit_ref = o_hit_ref + 1;
            if (HAS_8080) begin
               while (u_lcd8080.px_count < o_px0 + OR_FW*OR_FH) @(posedge free_clk);
               o_bad = 0;
               for (o_i = 0; o_i < OR_FW*OR_FH; o_i = o_i + 1)
               begin
                  o_ph = (o_i & 1) ? 16'h4000 + o_k*64 + o_i/2 : 16'h2000 + o_k*64 + o_i/2;
                  if (u_lcd8080.px_log[o_px0 + o_i] !== o_ph)
                     o_bad = o_bad + 1;
               end
            end else begin
               while (bm_px < o_px0 + OR_FW*OR_FH) @(posedge free_clk);
               o_bad = 0;
               for (o_i = 0; o_i < OR_FW*OR_FH; o_i = o_i + 1) begin
                  o_v = (o_i & 1) ? 16'h4000 + o_k*64 + o_i/2 : 16'h2000 + o_k*64 + o_i/2;
                  if (bm_px_log[o_px0 + o_i] !== {o_v[15:11], o_v[15:13], o_v[10:5], o_v[10:9], o_v[4:0], o_v[4:2]})
                     o_bad = o_bad + 1;
               end
            end
            tb_checks = tb_checks + 1;
            if (o_bad != 0) begin
               $display("ERROR: refresh %0d after the window writes: %0d pixels not the frame written %t", o_k, o_bad, $time);
               error = error + 1;
            end
            if (GPU_EN != 0) reg_poll(GPU_STAT, 32'h0030_0000, 32'h0, 20000);
            if (HAS_8080) reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 20000);
         end
         $display("OK:    12 frames written through the window, a refresh started at once: each sent as written (%0d held)", o_hit_ref);
      end

      //------------------------------------------------------------------
      // 3. Byte lanes, read after write, ERRORs, under contention
      //------------------------------------------------------------------
      for (o_i = 0; o_i < 4; o_i = o_i + 1) begin
         o_ref[o_i] = $random(tmp_seed);
         vram_mem[OR_MW + o_i] = o_ref[o_i];
      end
      if (HAS_8080 || (DIF_TYPE == 0)) reg_wr(REFRESH, (40 << 4) | 1);
      if (GPU_EN != 0) or_bg_fill(4000);
      for (o_k = 0; o_k < 6; o_k = o_k + 1) begin
         for (o_i = 0; o_i < 40; o_i = o_i + 1) begin
            o_s  = $random(tmp_seed) & 3;
            o_v  = $random(tmp_seed) & 3;
            o_sz = (o_v == 3) ? 3'b010 : {2'b00, o_v[0]};
            o_a  = 4*(OR_MW + o_s) + ((o_sz == 3'b000) ? ($random(tmp_seed) & 3) : (o_sz == 3'b001) ? ($random(tmp_seed) & 2) : 0);
            o_m  = or_lane(o_sz, o_a);
            if (($random(tmp_seed) & 15) == 0) begin
               sb_add(1'b1, $random(tmp_seed) & 1, 4*VRAM_WORDS, 3'b010, $random(tmp_seed));   // past the VRAM
               sb_eerr[sb_n-1] = 1'b1;
            end else if ($random(tmp_seed) & 1) begin
               o_v = $random(tmp_seed);
               sb_add(1'b1, 1'b1, o_a, o_sz, o_v);
               o_ref[o_s] = (o_ref[o_s] & ~o_m) | (o_v & o_m);
            end else begin
               sb_add(1'b1, 1'b0, o_a, o_sz, 32'h0);
               sb_exp[sb_n-1] = o_ref[o_s];
               sb_msk[sb_n-1] = o_m;
            end
         end
         sb_run;
      end
      while (dut.u_core.u_ahb_vram.wb_v === 1'b1) @(posedge hclk);
      for (o_i = 0; o_i < 4; o_i = o_i + 1) begin
         tb_checks = tb_checks + 1;
         if (vram_mem[OR_MW + o_i] !== o_ref[o_i]) begin
            $display("ERROR: word %0d = 0x%h / expected 0x%h %t", o_i, vram_mem[OR_MW + o_i], o_ref[o_i], $time);
            error = error + 1;
         end
      end
      $display("OK:    pipelined byte / half-word / word writes, reads and ERRORs under contention");

      //------------------------------------------------------------------
      // 4. Back-pressure: write runs while the GPU ages and the refresh runs
      //------------------------------------------------------------------
      for (o_i = 0; o_i < 128; o_i = o_i + 1) sb_add(1'b1, 1'b1, 4*(OR_MW + 64 + o_i), 3'b010, 32'hBEEF_0000 + o_i);
      sb_run;
      while (dut.u_core.u_ahb_vram.wb_v === 1'b1) @(posedge hclk);       // the last one made (backdoor check)
      for (o_i = 0; o_i < 128; o_i = o_i + 1) begin
         tb_checks = tb_checks + 1;
         if (vram_mem[OR_MW + 64 + o_i] !== 32'hBEEF_0000 + o_i) begin
            $display("ERROR: write run word %0d = 0x%h %t", o_i, vram_mem[OR_MW + 64 + o_i], $time);
            error = error + 1;
         end
      end
      $display("OK:    a 128-write run under contention: every write made once, in order");

      if (GPU_EN != 0) reg_poll(GPU_STAT, 32'h0030_0000, 32'h0, 40000);
      if (HAS_8080 || (DIF_TYPE == 0)) reg_wr(REFRESH, 32'h0);
      if (HAS_8080) reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 20000);

      $display("INFO:  %0d cycles with a posted write, %0d register cycles held behind one", o_post, o_held);
      if ((GPU_EN != 0) && (o_post == 0)) tb_error("no window write was posted (case not reached)");
      if ((GPU_EN != 0) && (o_held == 0)) tb_error("no register transfer was held behind a posted write (case not reached)");

      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
