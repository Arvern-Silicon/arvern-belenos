//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_lut_dpi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_lut_dpi.v
// Module Description : LUT window under a DPI refresh: the DPI driver takes
//                      a pixel in every cycle while a line buffer is free, so
//                      the backend asks for the LUT in every cycle. A 1000 x 4
//                      frame (as wide as the line buffer when it keeps fewer
//                      pixels, DPI_LB_AW 9: the rest of a line is dropped)
//                      at 8 bpp through the programmable LUT streams
//                      while 150 pipelined window accesses read and write
//                      LUT entries the frame does not use: every window read
//                      returns its entry, no window access waits more than
//                      LUT_WAIT_MAX states (the fairness slot of blns_lut),
//                      every streamed pixel is its LUT colour, the panel
//                      image matches the stream, no UNDERFLOW.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT
`include "regs_tasks.v"
`include "dpi_tasks.v"

// a long line fill: the backend asks for the LUT LD_W cycles in a row; at most
// the line buffer's 2^DPI_LB_AW pixels, the panel shows no more of a line
localparam integer LD_W         = (DPI_LB_AW >= 10) ? 1000 : (1 << DPI_LB_AW);
localparam integer LD_H         = 4;
localparam integer LUT_WAIT_MAX = 8;

integer     ld_i, ld_k, ld_b, ld_max, ld_bad;
reg  [31:0] ld_v;
reg  [31:0] ld_ref [0:255];
integer     ld_pidx [0:PIPE_MAX-1];
reg  [31:0] ld_store [0:PIPE_MAX-1];

// Longest run of cycles in which the backend asks for the LUT
integer     ld_run, ld_run_max;
initial begin ld_run = 0; ld_run_max = 0; end
always @(posedge hclk)
  if (dut.u_core.G_LUT.u_lut.bk_lreq_i === 1'b1) begin
     ld_run = ld_run + 1;
     if (ld_run > ld_run_max) ld_run_max = ld_run;
  end else
     ld_run = 0;

function [7:0] ld_idx;                                     // frame pixel -> LUT index (0..199)
   input integer x, y;
   begin
      ld_idx = (x + 8*y) % 200;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        LUT WINDOW UNDER A DPI REFRESH         |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (LUT_EN == 0) || (VRAM_WORDS < 1000))
         tb_skip_finish("|   (needs the DPI driver and the LUT)          |");

      for (ld_i = 0; ld_i < 256; ld_i = ld_i + 1) begin
         ld_ref[ld_i]  = {8'h00, ld_i[7:0], ~ld_i[7:0], ld_i[7:0] ^ 8'h5A};
         lut_mem[ld_i] = ld_ref[ld_i][23:0];
      end
      for (ld_i = 0; ld_i < LD_W*LD_H; ld_i = ld_i + 4)
         vram_wr(ld_i, {ld_idx((ld_i+3) % LD_W, (ld_i+3) / LD_W), ld_idx((ld_i+2) % LD_W, (ld_i+2) / LD_W),
                        ld_idx((ld_i+1) % LD_W, (ld_i+1) / LD_W), ld_idx(ld_i % LD_W, ld_i / LD_W)}, SZ_W);
      reg_wr(CTRL,       {29'h0, GFX_8BPP});
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(DISP_SIZE,  (LD_H << 16) | LD_W);
      reg_wr(LUT_CFG,    32'h0000_F001);                     // SW_LUT_EN, bank 0
      dpi_pclk_half = 2.0 * CLK_HALF;
      dpi_timing(1, LD_W + 10, 3, 2, 6, 8, 2, 1, 2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, ld_v);
      reg_wr(DIF_CFG, ld_v | 32'h9);                         // LCD_ON, DPI_EN
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);

      // window accesses on entries 200..249 while the frames stream: 40 bursts
      // of 12, every other one started inside a line fill (the backend asking
      // for the LUT in every cycle)
      ld_max = 0;
      for (ld_b = 0; ld_b < 40; ld_b = ld_b + 1) begin
         repeat (50 + ($random(tmp_seed) & 255)) @(posedge free_clk);
         if (ld_b % 2 == 0)                                  // every other burst inside a line fill
            while (ld_run < 20) @(posedge free_clk);
         rp_clear;
         for (ld_i = 0; ld_i < 12; ld_i = ld_i + 1) begin
            ld_k = 200 + ((12*ld_b + ld_i) % 50);
            if (ld_i % 3 == 0) begin
               ld_v = $random(tmp_seed);
               rp_w(LUT_BASE + 4*ld_k, ld_v, 0);
               ld_ref[ld_k] = ld_v & 32'h00FF_FFFF;
               ld_pidx[rp_n-1] = -1;
            end else begin
               rp_r(LUT_BASE + 4*ld_k, 0);
               ld_pidx[rp_n-1] = ld_k;
               ld_store[rp_n-1] = ld_ref[ld_k];
            end
         end
         rp_run;
         for (ld_i = 0; ld_i < rp_n; ld_i = ld_i + 1) begin
            if (ld_pidx[ld_i] >= 0) rp_chk(ld_i, OK, ld_store[ld_i], 32'hFFFF_FFFF, -1);
            else                    rp_chk(ld_i, OK, 0, 0, -1);
            if (rp_waits[ld_i] > ld_max) ld_max = rp_waits[ld_i];
         end
      end
      if (ld_max > LUT_WAIT_MAX) begin
         $display("ERROR: LUT window under a DPI refresh: %0d wait states, at most %0d expected %t", ld_max, LUT_WAIT_MAX, $time);
         error = error + 1;
      end else
         $display("OK:    LUT window under a DPI refresh: at most %0d wait states", ld_max);
      $display("INFO:  the backend asked for the LUT up to %0d cycles in a row", ld_run_max);

      // the stream: every pixel its LUT colour; the panel image
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(2);
      ld_bad = 0;
      for (ld_i = 0; ld_i < LD_W*LD_H; ld_i = ld_i + 1)
         if (dpi_src[ld_i] !== ld_ref[ld_idx(ld_i % LD_W, ld_i / LD_W)][23:0]) begin
            if (ld_bad < 5) $display("ERROR: streamed pixel %0d = %06h, LUT colour %06h %t",
                                     ld_i, dpi_src[ld_i], ld_ref[ld_idx(ld_i % LD_W, ld_i / LD_W)][23:0], $time);
            ld_bad = ld_bad + 1;
         end
      if (ld_bad != 0) error = error + 1;
      else $display("OK:    %0d streamed pixels are their LUT colours", LD_W*LD_H);
      dpi_check_image(LD_W, LD_H, LD_W, LD_H, 5, 2, 4096, 4096, 0, 24'h0, "LUT frame on the panel");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);              // no UNDERFLOW

      u_dpipanel.check = 1'b0;
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, ld_v);
      reg_wr(DIF_CFG, ld_v & ~32'h8);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
