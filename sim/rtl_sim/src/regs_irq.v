//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_irq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_irq.v
// Module Description : Interrupt flags and irq_o, with the BDI
//                      inputs driven by the bench (DIF_TYPE = 0):
//                      - REFR_START / REFR_DONE on the rising / falling edge
//                        of bdi_refresh_active_i, STATUS.REFRESH_ACTIVE;
//                      - FRAME_CNT_DONE on a refresh done taking FRAME_CNT
//                        1 -> 0;
//                      - GPU sources (GPU_EN): GPU_OVFL (push with
//                        CTRL.GPU_EN = 0), GPU_ERR (invalid opcode),
//                        GPU_IDLE (BUSY falling), GPU_DONE (an EXEC),
//                        GPU_FENCE (FENCE with IRQ) and neither for a FENCE
//                        without IRQ / configuration commands;
//                      - DIF = bdi_irq_i level, not W1C; STATUS.DIF_BUSY;
//                      - W1C per bit, writing 0 clears nothing, a sub-word
//                        W1C is an ERROR and clears nothing, debugger W1C;
//                      - irq_o = |(IRQ_FLAG & IRQ_EN) for every bit alone;
//                      - set wins over a simultaneous W1C: the flag edge is
//                        calibrated through irq_o, then the W1C completion is
//                        swept across it cycle by cycle;
//                      - a FRAME_CNT write in the cycle a frame ends wins (no
//                        decrement, no FRAME_CNT_DONE), swept the same way
//                        with 1 and 0 written; writing 0 raises nothing.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam [31:0] F_RDONE = 32'h001;
localparam [31:0] F_RSTRT = 32'h002;
localparam [31:0] F_FCNT  = 32'h004;
localparam [31:0] F_GDONE = 32'h010;
localparam [31:0] F_GIDLE = 32'h020;
localparam [31:0] F_GOVFL = 32'h040;
localparam [31:0] F_GERR  = 32'h080;
localparam [31:0] F_DIF   = 32'h100;
localparam [31:0] F_GFENCE = 32'h200;
localparam [31:0] F_ALL   = 32'h3F7;

reg  [31:0] q_en;            // shadow of IRQ_EN
reg  [31:0] q_flag;          // expected IRQ_FLAG
reg  [31:0] q_rd;
integer     q_b, q_d, q_m, q_g, q_k, q_exp, q_t0;
reg         q_seen;

// Read IRQ_FLAG and check it and irq_o against the expectation
task q_chk;
   input [31:0] exp;
   begin
      reg_rd(IRQ_FLAG, exp);
      @(negedge free_clk);
      if (irq !== (|(exp & q_en))) begin
         $display("ERROR: irq_o = %b with IRQ_FLAG 0x%h IRQ_EN 0x%h %t", irq, exp, q_en, $time);
         error = error + 1;
      end
   end
endtask

task q_set_en;
   input [31:0] v;
   begin
      reg_wr(IRQ_EN, v);
      q_en = v & F_ALL;
   end
endtask

// Drive bdi_refresh_active_i at a posedge, then let it settle
task q_active;
   input v;
   begin
      @(posedge free_clk);
      bdi_refresh_active_drv = v;
      repeat (4) @(posedge free_clk);
   end
endtask

// Calibrate: edges from driving `active` (at a posedge) to the flag flop
// update, observed through irq_o with only that flag enabled
task q_calib;
   input        v;       // new active level
   input [31:0] flag;
   output integer m;
   integer k;
   begin
      q_set_en(flag);
      @(posedge free_clk);
      bdi_refresh_active_drv = v;
      m = -1;
      for (k = 0; (k < 10) && (m < 0); k = k + 1) begin
         @(negedge free_clk);
         if (irq === 1'b1) m = k;          // flop updated at edge k after the drive edge
         @(posedge free_clk);
      end
      if (m < 0) begin
         $display("ERROR: calibration: irq_o never rose for flag 0x%h %t", flag, $time);
         error = error + 1;
         m = 1;
      end else
         $display("INFO:  flag 0x%h visible on irq_o %0d edge(s) after the active edge", flag, m);
      repeat (3) @(posedge free_clk);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        REGS: INTERRUPT FLAGS AND irq_o        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|   (DIF_TYPE != 0: BDI inputs not drivable)    |");

      // keep the clock requested (ICG builds): an external driver holds busy
      bdi_busy_drv = 1'b1;
      q_en = 0;

      q_chk(32'h0);
      if (irq !== 1'b0) tb_error("irq_o high out of reset");

      //------------------------------------------------------------------
      // REFR_START / REFR_DONE, STATUS.REFRESH_ACTIVE
      //------------------------------------------------------------------
      reg_rd_mask(STATUS, 32'h0000_0008, 32'h0000_0009);           // DIF_BUSY (busy_i), not active
      q_active(1'b1);
      reg_rd_mask(STATUS, 32'h0000_0001, 32'h0000_0001);
      q_chk(F_RSTRT);
      q_active(1'b0);
      reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0001);
      q_chk(F_RSTRT | F_RDONE);
      // W1C: 0 clears nothing; byte W1C is an ERROR; one bit at a time
      reg_wr(IRQ_FLAG, 32'h0);
      q_chk(F_RSTRT | F_RDONE);
      ahb_write_x(PORT_R, IRQ_FLAG, 32'h0000_00FF, SZ_B, MACHINE, HART_MASTER, ERROR);
      ahb_write_x(PORT_R, IRQ_FLAG, 32'h0000_FFFF, SZ_H, MACHINE, HART_MASTER, ERROR);
      q_chk(F_RSTRT | F_RDONE);
      reg_wr(IRQ_FLAG, F_RSTRT);
      q_chk(F_RDONE);
      ahb_write_x(PORT_R, IRQ_FLAG, F_RDONE, SZ_W, SUPERVISOR, HART_MASTER, OK);   // S-mode W1C
      q_chk(32'h0);

      //------------------------------------------------------------------
      // FRAME_CNT_DONE
      //------------------------------------------------------------------
      reg_wr(FRAME_CNT, 32'h2);
      q_active(1'b1); q_active(1'b0);
      reg_rd(FRAME_CNT, 32'h1);
      q_chk(F_RSTRT | F_RDONE);
      q_active(1'b1);
      q_chk(F_RSTRT | F_RDONE);                  // only the falling edge counts
      reg_rd(FRAME_CNT, 32'h1);
      q_active(1'b0);
      reg_rd(FRAME_CNT, 32'h0);
      q_chk(F_RSTRT | F_RDONE | F_FCNT);
      reg_wr(IRQ_FLAG, F_FCNT);
      q_active(1'b1); q_active(1'b0);            // FRAME_CNT = 0: no new event
      reg_rd(FRAME_CNT, 32'h0);
      q_chk(F_RSTRT | F_RDONE);
      reg_wr(IRQ_FLAG, F_ALL);
      q_chk(32'h0);

      //------------------------------------------------------------------
      // DIF: level of bdi_irq_i, not W1C; STATUS.DIF_BUSY = bdi_busy_i
      //------------------------------------------------------------------
      @(posedge free_clk); bdi_irq_drv = 1'b1; repeat (3) @(posedge free_clk);
      q_chk(F_DIF);
      reg_wr(IRQ_FLAG, F_DIF);
      q_chk(F_DIF);
      q_set_en(F_DIF);
      q_chk(F_DIF);
      if (irq !== 1'b1) tb_error("irq_o not set by the DIF level");
      @(posedge free_clk); bdi_irq_drv = 1'b0;
      // irq_o follows the level: no W1C needed
      repeat (3) @(negedge free_clk);
      if (irq !== 1'b0) tb_error("irq_o still high after bdi_irq_i fell");
      q_chk(32'h0);
      q_set_en(32'h0);
      @(posedge free_clk); bdi_busy_drv = 1'b0; repeat (3) @(posedge free_clk);
      reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0008);
      @(posedge free_clk); bdi_busy_drv = 1'b1; repeat (3) @(posedge free_clk);
      reg_rd_mask(STATUS, 32'h0000_0008, 32'h0000_0008);

      //------------------------------------------------------------------
      // GPU sources
      //------------------------------------------------------------------
      if (GPU_EN != 0) begin
         // push while CTRL.GPU_EN = 0: dropped, GPU_OVFL
         reg_wr(CTRL, 32'h0000_0004);
         reg_wr(GPU_CMD, 32'hF000_0001);
         repeat (4) @(posedge free_clk);
         q_chk(F_GOVFL);
         reg_wr(IRQ_FLAG, F_GOVFL);
         q_chk(32'h0);
         reg_wr(CTRL, 32'h0000_0014);
         // configuration command: IDLE but no DONE
         reg_wr(GPU_CMD, {OP_SET_SIZE, 28'h0004_004});
         repeat (20) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, 32'h0001_0000, 32'h0031_0000);
         q_chk(F_GIDLE);
         reg_wr(IRQ_FLAG, F_GIDLE);
         // FENCE without IRQ: neither DONE nor FENCE
         reg_wr(GPU_CMD, 32'hF000_0000);
         repeat (20) @(posedge free_clk);
         q_chk(F_GIDLE);
         reg_wr(IRQ_FLAG, F_GIDLE);
         // FENCE with IRQ: GPU_FENCE, no GPU_DONE
         reg_wr(GPU_CMD, 32'hF100_0001);
         repeat (20) @(posedge free_clk);
         q_chk(F_GFENCE | F_GIDLE);
         reg_wr(IRQ_FLAG, F_GFENCE | F_GIDLE);
         q_chk(32'h0);
         // invalid opcode: GPU_ERR, STATUS.GPU_ERR / GPU_BUSY; CLEAR_ERR -> IDLE
         reg_wr(GPU_CMD, 32'h0000_0000);                 // 0x0: invalid
         repeat (10) @(posedge free_clk);
         q_chk(F_GERR);
         reg_rd_mask(STATUS, 32'h0000_0006, 32'h0000_0006);
         reg_wr(GPU_CTRL, 32'h0000_0001);
         repeat (10) @(posedge free_clk);
         reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0006);
         q_chk(F_GERR | F_GIDLE);                  // ERR stays until W1C
         reg_wr(IRQ_FLAG, F_GERR);
         q_chk(F_GIDLE);
         reg_wr(IRQ_FLAG, F_GIDLE);
         q_chk(32'h0);
      end

      //------------------------------------------------------------------
      // irq_o per bit: set every available flag, enable one bit at a time
      //------------------------------------------------------------------
      q_flag = F_RSTRT | F_RDONE | F_DIF;
      reg_wr(FRAME_CNT, 32'h1);
      q_active(1'b1); q_active(1'b0);
      q_flag = q_flag | F_FCNT;
      @(posedge free_clk); bdi_irq_drv = 1'b1; repeat (3) @(posedge free_clk);
      if (GPU_EN != 0) begin
         reg_wr(GPU_CMD, 32'h8000_0000);                 // EXEC_FILL: DONE + IDLE
         reg_wr(GPU_CMD, 32'hF100_0001);                 // FENCE with IRQ
         repeat (40) @(posedge free_clk);
         reg_wr(GPU_CMD, 32'h0000_0000);                 // ERR
         repeat (10) @(posedge free_clk);
         reg_wr(CTRL, 32'h0000_0004);                    // GPU_EN = 0: flush, OVFL on push
         reg_wr(GPU_CMD, 32'h3000_0000);
         repeat (10) @(posedge free_clk);
         q_flag = q_flag | F_GDONE | F_GIDLE | F_GERR | F_GOVFL | F_GFENCE;
      end
      q_chk(q_flag);
      for (q_b = 0; q_b < 10; q_b = q_b + 1) begin
         if (((32'h1 << q_b) & F_ALL) != 0) begin
            q_set_en(32'h1 << q_b);
            q_chk(q_flag);
            q_set_en(F_ALL & ~(32'h1 << q_b));
            q_chk(q_flag);
         end
      end
      // clear one flag at a time with every enable on
      q_set_en(F_ALL);
      for (q_b = 0; q_b < 10; q_b = q_b + 1) begin
         if ((q_b != 8) && (((32'h1 << q_b) & q_flag) != 0)) begin   // DIF is a level
            reg_wr(IRQ_FLAG, 32'h1 << q_b);
            q_flag = q_flag & ~(32'h1 << q_b);
            q_chk(q_flag);
         end
      end
      @(posedge free_clk); bdi_irq_drv = 1'b0; repeat (3) @(posedge free_clk);
      q_flag = 0;
      q_chk(32'h0);
      if (GPU_EN != 0) reg_wr(CTRL, 32'h0);

      //------------------------------------------------------------------
      // Set wins over a simultaneous W1C
      //------------------------------------------------------------------
      // One W1C through rp_run with gap q_g: the write data phase completes
      // at pipe edge 3 + q_g (edge 1 = the first posedge of rp_run). The
      // event is driven at edge q_d and reaches the flag at edge q_d + q_m.
      for (q_k = 0; q_k < 3; q_k = q_k + 1) begin
         // q_k = 0: REFR_START (rise), 1: REFR_DONE (fall), 2: FRAME_CNT_DONE (fall)
         if (q_k == 0) q_calib(1'b1, F_RSTRT, q_m);
         else if (q_k == 1) begin q_active(1'b1); q_calib(1'b0, F_RDONE, q_m); end
         else begin
            reg_wr(FRAME_CNT, 32'h1);
            q_active(1'b1); q_calib(1'b0, F_FCNT, q_m);
         end
         q_set_en(32'h0);
         q_g = 6;
         for (q_d = 3 + q_g - q_m - 2; q_d <= 3 + q_g - q_m + 2; q_d = q_d + 1) begin
            // flag = 1 from a previous event, active at the level before the event
            if (q_k == 0) begin
               q_active(1'b0); q_active(1'b1); q_active(1'b0);
            end else begin
               if (q_k == 2) reg_wr(FRAME_CNT, 32'h1);
               q_active(1'b1); q_active(1'b0);
               if (q_k == 2) reg_wr(FRAME_CNT, 32'h1);
               q_active(1'b1);
            end
            reg_rd_val(IRQ_FLAG, q_rd);
            if ((q_k == 0 && !(q_rd & F_RSTRT)) || (q_k == 1 && !(q_rd & F_RDONE)) || (q_k == 2 && !(q_rd & F_FCNT)))
               tb_error("set-wins setup: flag not set before the sweep");
            rp_clear;
            rp_add(IRQ_FLAG, 1'b1, 3'b010, (q_k == 0) ? F_RSTRT : (q_k == 1) ? F_RDONE : F_FCNT,
                   MACHINE, HART_MASTER, 2'b10, q_g);
            fork
               rp_run;
               begin
                  repeat (q_d) @(posedge free_clk);
                  bdi_refresh_active_drv = (q_k == 0);
               end
            join
            repeat (4) @(posedge free_clk);
            rp_chk(0, OK, 0, 0, 0);
            q_exp = ((q_d + q_m) >= (3 + q_g)) ? 1 : 0;
            reg_rd_val(IRQ_FLAG, q_rd);
            q_rd = (q_k == 0) ? (q_rd & F_RSTRT) : (q_k == 1) ? (q_rd & F_RDONE) : (q_rd & F_FCNT);
            if ((q_rd != 0) !== (q_exp != 0)) begin
               $display("ERROR: set-vs-W1C (flag %0d): event edge %0d, W1C edge %0d: flag %0d / expected %0d%s %t",
                        q_k, q_d + q_m, 3 + q_g, (q_rd != 0), q_exp,
                        ((q_d + q_m) == (3 + q_g)) ? " (simultaneous: set must win)" : "", $time);
               error = error + 1;
            end else
               $display("OK:    set-vs-W1C (flag %0d): event edge %0d, W1C edge %0d -> flag %0d", q_k, q_d + q_m, 3 + q_g, q_exp);
            reg_wr(IRQ_FLAG, F_ALL);
         end
         q_active(1'b0);
         reg_wr(IRQ_FLAG, F_ALL);
      end
      q_set_en(32'h0);
      q_chk(32'h0);

      //------------------------------------------------------------------
      // FRAME_CNT write against a frame end, cycle by cycle
      //------------------------------------------------------------------
      // FRAME_CNT = 1 and a frame running; the write of q_b (1 or 0)
      // completes at pipe edge 3 + q_g, the frame end (REFR_DONE) at edge
      // q_d + q_m. Earlier frame end: the decrement (1 -> 0, FRAME_CNT_DONE),
      // then the write. Same cycle: the write wins, no event. Later: the
      // write, then the decrement of the written value.
      q_active(1'b1); q_calib(1'b0, F_RDONE, q_m);
      q_set_en(32'h0);
      q_g = 6;
      for (q_b = 1; q_b >= 0; q_b = q_b - 1) begin
         for (q_d = 3 + q_g - q_m - 2; q_d <= 3 + q_g - q_m + 2; q_d = q_d + 1) begin
            reg_wr(FRAME_CNT, 32'h1);
            q_active(1'b1);
            reg_wr(IRQ_FLAG, F_ALL);
            rp_clear;
            rp_add(FRAME_CNT, 1'b1, 3'b010, q_b, MACHINE, HART_MASTER, 2'b10, q_g);
            fork
               rp_run;
               begin
                  repeat (q_d) @(posedge free_clk);
                  bdi_refresh_active_drv = 1'b0;
               end
            join
            repeat (4) @(posedge free_clk);
            rp_chk(0, OK, 0, 0, 0);
            if ((q_d + q_m) < (3 + q_g))       begin q_exp = q_b;                     q_t0 = 1;                end
            else if ((q_d + q_m) == (3 + q_g)) begin q_exp = q_b;                     q_t0 = 0;                end
            else                               begin q_exp = (q_b != 0) ? q_b - 1 : 0; q_t0 = (q_b == 1) ? 1 : 0; end
            reg_rd(FRAME_CNT, q_exp);
            reg_rd_mask(IRQ_FLAG, q_t0 ? F_FCNT : 32'h0, F_FCNT | F_RSTRT);
            reg_rd_mask(IRQ_FLAG, F_RDONE, F_RDONE);
            $display("%0s FRAME_CNT write of %0d: frame end edge %0d, write edge %0d -> FRAME_CNT %0d, FRAME_CNT_DONE %0d",
                     "OK:   ", q_b, q_d + q_m, 3 + q_g, q_exp, q_t0);
         end
      end
      // A write of 0 with no frame end raises nothing
      reg_wr(FRAME_CNT, 32'h1);
      reg_wr(IRQ_FLAG, F_ALL);
      reg_wr(FRAME_CNT, 32'h0);
      repeat (4) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'h0);
      reg_rd(IRQ_FLAG, 32'h0);
      // and a frame ending with FRAME_CNT = 0 neither
      q_active(1'b1); q_active(1'b0);
      reg_rd(FRAME_CNT, 32'h0);
      reg_rd_mask(IRQ_FLAG, F_RDONE | F_RSTRT, F_FCNT | F_RDONE | F_RSTRT);
      reg_wr(IRQ_FLAG, F_ALL);
      q_chk(32'h0);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
