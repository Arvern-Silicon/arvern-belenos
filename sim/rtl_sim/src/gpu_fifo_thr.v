//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_fifo_thr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_fifo_thr.v
// Module Description : GPU_FIFO_LOW (0x118) [16:0] THRESH (every build with a
//                      GPU): reset value depth / 2 (the event of gpu_sync);
//                      read-back of 0, a middle value, depth - 1, the depth
//                      and above (kept as the depth), [31:17] ignored. The
//                      event for 0, a middle value and depth - 1: once when
//                      FREE rises from THRESH to THRESH + 1 as the GPU
//                      drains a FIFO filled while frozen, not while FREE
//                      stays above; never with THRESH >= depth. A write
//                      re-arms: with FREE already above, the event the next
//                      cycle (IRQ_FLAG [10]); none at or below. THRESH kept
//                      through ABORT, CLEAR_ERR, GPU_EN = 0 and RESET_STATE;
//                      the flush's own rise of FREE fires as today. In every
//                      cycle the event equals a reference (FREE from the FIFO
//                      count and a pending marker, THRESH from the register
//                      writes, the re-arm), IRQ_FLAG [10] following it.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam [31:0] TH_FLOW = 32'h400;             // IRQ_FLAG [10] GPU_FIFO_LOW

`define TH_GPU dut.u_core.G_GPU.u_gpu

integer    th_i, th_k, th_n, th_nev, th_nbad, th_free;
integer    th_ref, th_ph;                        // reference THRESH; events in a phase
reg        th_above, th_on, th_pev, th_fl;
reg [31:0] th_st, th_v;

// The reference: the event when FREE goes from <= THRESH to > THRESH; a write
// (its value saturated at the depth, bits [31:17] ignored) applies the next
// cycle and clears "above"
function integer th_sat;
   input [31:0] v;
   begin
      th_sat = ((v & 32'h1FFFF) >= GPU_FIFO_DEPTH) ? GPU_FIFO_DEPTH : (v & 32'h1FFFF);
   end
endfunction

initial begin th_on = 1'b0; th_above = 1'b1; th_ref = GPU_FIFO_DEPTH / 2; th_nev = 0; th_nbad = 0; th_pev = 1'b0; end
initial begin @(posedge reset_done); @(posedge hclk); th_on = 1'b1; end
always @(posedge hclk)
   if ((GPU_EN != 0) && th_on) begin : th_mon
      reg ev, ev_exp, now, fl;
      th_free = (`TH_GPU.mrk_pend === 1'b1) ? 0 : GPU_FIFO_DEPTH - `TH_GPU.fifo_count;
      now     = th_free > th_ref;
      ev_exp  = now && !th_above;
      ev      = (`TH_GPU.fifo_low_evt_o === 1'b1);
      fl      = (dut.u_core.u_regs.flow_flag === 1'b1);
      if (ev) begin th_nev = th_nev + 1; th_ph = th_ph + 1; end
      if ((ev !== ev_exp) || (th_pev && !fl)) begin
         th_nbad = th_nbad + 1;
         if (th_nbad <= 4)
            $display("ERROR: GPU_FIFO_LOW event %b, expected %b (FREE %0d, THRESH %0d, above %b), flag %b %t",
                     ev, ev_exp, th_free, th_ref, th_above, fl, $time);
         error = error + 1;
      end
      th_pev   = ev;
      th_above = now && !(`TH_GPU.thr_wr === 1'b1);
      if (`TH_GPU.thr_wr === 1'b1) th_ref = th_sat(`TH_GPU.rb_wdata_i);
   end

task th_wr;
   input [31:0] v;
   begin
      reg_wr(GPU_FIFO_LOW, v);
      reg_rd(GPU_FIFO_LOW, th_sat(v));
   end
endtask

// Freeze, queue n fences (FREE = depth - n), set THRESH t (FREE at or below:
// no event), clear the flag, release: one event as FREE passes t + 1
// (never for t >= depth)
task th_drain;
   input integer n;
   input integer t;
   begin
      gpu_freeze(1'b1);
      for (th_i = 0; th_i < n; th_i = th_i + 1)
         reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h0});
      th_wr(t);
      repeat(2) @(posedge free_clk);
      reg_wr(IRQ_FLAG, TH_FLOW);
      reg_rd_mask(IRQ_FLAG, 32'h0, TH_FLOW);
      th_ph = 0;
      gpu_freeze(1'b0);
      gpu_wait_idle;
      repeat(4) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, (t < GPU_FIFO_DEPTH) ? TH_FLOW : 32'h0, TH_FLOW);
      $display("       THRESH %0d, FREE %0d -> %0d: %0d event(s)", t, GPU_FIFO_DEPTH - n, GPU_FIFO_DEPTH, th_ph);
      if (th_ph != ((t < GPU_FIFO_DEPTH) ? 1 : 0)) tb_error("gpu_fifo_thr: wrong number of events while draining");
   end
endtask

// A write with FREE = depth (the FIFO empty): the event the next cycle when
// t < depth (the re-arm), none otherwise
task th_rearm;
   input integer t;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, TH_FLOW);
      th_ph = 0;
      th_wr(t);
      repeat(3) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, (t < GPU_FIFO_DEPTH) ? TH_FLOW : 32'h0, TH_FLOW);
      if (th_ph != ((t < GPU_FIFO_DEPTH) ? 1 : 0)) tb_error("gpu_fifo_thr: wrong re-arm");
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: GPU_FIFO_LOW threshold            |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      $display("--- reset value: depth / 2 (%0d)", GPU_FIFO_DEPTH / 2);
      reg_rd(GPU_FIFO_LOW, GPU_FIFO_DEPTH / 2);
      gpu_model_init;
      gpu_set_mode(4);

      $display("--- read-back: saturated at the depth, [31:17] ignored");
      th_wr(32'h0);
      th_wr(GPU_FIFO_DEPTH / 2 + 1);
      th_wr(GPU_FIFO_DEPTH - 1);
      th_wr(GPU_FIFO_DEPTH);
      th_wr(GPU_FIFO_DEPTH + 5);
      th_wr(32'h0001_FFFF);
      th_wr(32'h0001_0000);
      th_wr(32'hFFFF_FFFF);
      th_wr(32'h0002_0003);                                   // THRESH 3
      th_wr(32'hFFFE_0000);                                   // THRESH 0

      $display("--- the event as the GPU drains, per THRESH");
      th_drain(GPU_FIFO_DEPTH / 2 + 2, GPU_FIFO_DEPTH / 2);   // the reset value: as gpu_sync
      th_drain(GPU_FIFO_DEPTH, 0);
      th_drain(GPU_FIFO_DEPTH - 1, 1);
      th_drain(3, GPU_FIFO_DEPTH - 3);
      th_drain(1, GPU_FIFO_DEPTH - 1);
      th_drain(GPU_FIFO_DEPTH, GPU_FIFO_DEPTH);
      th_drain(GPU_FIFO_DEPTH - 2, GPU_FIFO_DEPTH + 9);

      $display("--- a write re-arms");
      th_rearm(0);
      th_rearm(GPU_FIFO_DEPTH / 2);
      th_rearm(GPU_FIFO_DEPTH - 1);
      th_rearm(GPU_FIFO_DEPTH);
      th_rearm(32'h0001_0000);
      // at or below: none; the rise then fires
      gpu_freeze(1'b1);
      for (th_i = 0; th_i < 4; th_i = th_i + 1)
         reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h0});
      reg_wr(IRQ_FLAG, TH_FLOW);
      th_ph = 0;
      th_wr(GPU_FIFO_DEPTH - 4);                             // FREE = THRESH: none
      repeat(4) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, TH_FLOW);
      if (th_ph != 0) tb_error("gpu_fifo_thr: event at FREE = THRESH");
      gpu_freeze(1'b0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, TH_FLOW, TH_FLOW);

      $display("--- kept through ABORT, CLEAR_ERR, GPU_EN = 0 and RESET_STATE; the flush's rise fires");
      th_wr(2);
      for (th_k = 0; th_k < 4; th_k = th_k + 1) begin
         gpu_freeze(1'b1);
         for (th_i = 0; th_i < GPU_FIFO_DEPTH - 1; th_i = th_i + 1)
            reg_wr(GPU_CMD, {OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h0});
         reg_wr(IRQ_FLAG, TH_FLOW);
         th_ph = 0;
         case (th_k)
           0: reg_wr(GPU_CTRL, 32'h2);
           1: reg_wr(GPU_CTRL, 32'h1);
           2: begin reg_wr(CTRL, 32'h4); reg_wr(CTRL, 32'h14); end
           default: begin
              gpu_freeze(1'b0);
              gpu_wait_idle;
              reg_wr(GPU_CMD, {OP_SET_EXT, 4'hF, 8'h02, 16'h0000});   // RESET_STATE
           end
         endcase
         gpu_freeze(1'b0);
         gpu_wait_idle;
         reg_rd(GPU_FIFO_LOW, 32'h2);
         reg_rd_mask(IRQ_FLAG, TH_FLOW, TH_FLOW);
      end
      gpu_flush_hint = 1'b0;

      $display("INFO:  %0d GPU_FIFO_LOW events", th_nev);
      if (th_nev < 10) tb_error("gpu_fifo_thr: too few events (test bug)");
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
