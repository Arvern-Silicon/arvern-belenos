//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_flush
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_flush.v
// Module Description : The pattern phase is stream state, the pen a setting:
//                       1. CLEAR_ERR, ABORT, both, GPU_EN = 0 then 1 and
//                          RESET_STATE on an idle GPU: the next line starts
//                          at phase 0; the pen kept (RESET_STATE: (0, 0));
//                       2. CLEAR_ERR while a line draws: it completes, the
//                          next line starts at phase 0;
//                       3. ABORT and GPU_EN = 0 while a long line draws: a
//                          prefix of its pixels, no GPU_DONE, the pen at its
//                          end point, the next line from phase 0;
//                       4. a line cut between its word and its operand by a
//                          flush: nothing drawn, the pen unchanged, the
//                          operand pushed after the flush discarded;
//                       5. the debug freeze while a line draws: no VRAM
//                          access while held, the exact image.
//                      Run in both run-ahead settings (the lines after the
//                      flush draw the same pixels).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer LF_P      = 1;               // pitch 1 at 8 bpp: a long line in few words
localparam integer LF_D_LO   = 2000;
localparam integer LF_D_HI   = LF_D_LO + 4200 / 4 + 8;
localparam integer LF_VMIN   = LF_D_HI + 16;

integer    lf_i, lf_k, lf_cls, lf_nd, lf_t;
reg [31:0] lf_org;
reg [31:0] lf_st;

task lf_init;
   begin
      gpu_wait_idle;
      gpu_preload_rand(LF_D_LO, LF_D_HI);
      gpu_model_init;
      gpu_set_mode(3);
      gpu_set_dispw(64);
      lf_org = LF_D_LO * 4 + 2100;
      gpu_c_dst_xy(LF_P, lf_org);                                       // pixel (x, y): lf_org + x + y
      gpu_c_clip(-2048, -2048, 2047, 2047);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

// A short line from the pen whose image shows the phase it starts at
task lf_probe;
   input  [8*32-1:0] what;
   begin
      gpu_c_fill($random(gpu_seed));
      gpu_c_line(gpu_m_pen_x + 16 * 40, gpu_m_pen_y, 4'd0, 4'h0);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched(what);
   end
endtask

// The flush kinds of gpu_flush: 0 CLEAR_ERR, 1 ABORT, 2 GPU_EN 0 then 1, 3 both
task lf_flush_now;
   input integer kind;
   begin
      case (kind)
        0:       reg_wr(GPU_CTRL, 32'h1);
        1:       reg_wr(GPU_CTRL, 32'h2);
        3:       reg_wr(GPU_CTRL, 32'h3);
        default: begin
                    reg_wr(CTRL, {29'h0, gpu_m_mode});
                    reg_wr(CTRL, 32'h10 | gpu_m_mode);
                 end
      endcase
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: line flushes and the phase        |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_LINE_EN == 0))
         tb_skip_finish("|          (lines absent)                       |");
      if (VRAM_WORDS < LF_VMIN)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_push_wait = 1'b1;
      gpu_c_reset_state;
      lf_init;
      gpu_rgn_dlo = LF_D_LO;
      gpu_rgn_dhi = LF_D_HI;

      //--------------------------------------------------------------
      $display("--- 1. flushes of an idle GPU: the phase 0, the pen kept");
      for (lf_k = 0; lf_k < 5; lf_k = lf_k + 1) begin
         lf_init;
         gpu_c_pattern(32'h0000_0B5D, 11);
         gpu_c_fill($random(gpu_seed));
         gpu_c_pen(-16 * 60, 3);
         gpu_c_line(-16 * 60 + 16 * 25 + 5, 3, 4'd0, 4'h0);              // 26 steps: phase 4
         gpu_wait_idle;
         if (lf_k == 4) begin
            gpu_c_reset_state;                                          // pen (0, 0), solid pattern
            lf_init;
         end else begin
            gpu_flush(lf_k);
            gpu_m_lph = 0;
            gpu_wait_idle;
         end
         lf_probe((lf_k == 4) ? "after RESET_STATE" : "after a flush of an idle GPU");
      end

      //--------------------------------------------------------------
      $display("--- 2. CLEAR_ERR while a line draws: it completes");
      lf_init;
      gpu_c_pattern(32'h0000_0B5D, 11);
      gpu_c_fill($random(gpu_seed));
      gpu_c_pen(-32768, 8);
      gpu_c_line(32767, 8, 4'd0, 4'h0);                                 // 4096 steps
      lf_st = 32'h0;
      while ((lf_st & GS_PRIM_BUSY) == 0) reg_rd_val(GPU_STAT, lf_st);
      repeat(200) @(posedge free_clk);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_m_lph = 0;
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE);
      lf_probe("a line through CLEAR_ERR");

      //--------------------------------------------------------------
      $display("--- 3. ABORT / GPU_EN = 0 while a line draws: a prefix, no GPU_DONE");
      for (lf_k = 1; lf_k <= 3; lf_k = lf_k + 1) begin
         lf_init;
         gpu_c_pattern(32'h0000_0B5D, 11);
         gpu_c_fill($random(gpu_seed) | 32'h1);                         // (XOR: every pixel changes)
         gpu_c_pen(-16 * 500, 8);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_rec_begin;
         gpu_c_line(16 * 499 + 8, 8 + 16 * 3, 4'd5, 4'h0);              // XOR, 1000 steps
         gpu_rec_end;
         lf_st = 32'h0;
         while ((lf_st & GS_PRIM_BUSY) == 0) reg_rd_val(GPU_STAT, lf_st);
         repeat(50 + 150 * lf_k) @(posedge free_clk);
         lf_flush_now(lf_k);
         gpu_m_lph = 0;
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
         gpu_rec_prefix(1'b0, lf_cls, lf_nd);
         if (lf_cls != 1) begin
            $display("ERROR: an abandoned line drew %0d pixels (class %0d): not a part of it %t", lf_nd, lf_cls, $time);
            error = error + 1;
         end
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         lf_probe("after an abandoned line");                           // from its end point, phase 0
      end

      //--------------------------------------------------------------
      $display("--- 4. a line cut between its word and its operand");
      lf_init;
      gpu_c_fill($random(gpu_seed));
      gpu_c_pen(16 * 3, 16 * 2);
      gpu_wait_idle;
      gpu_push(gpu_line_word(4'd0, 4'h0));                              // no operand yet
      repeat(20) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_BUSY, GS_BUSY | GS_ERR);                 // waiting for the operand
      reg_wr(GPU_CTRL, 32'h1);                                          // CLEAR_ERR
      gpu_m_lph = 0;
      gpu_push(32'h7FFF_7FFF);                                          // its operand: discarded
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_BUSY | GS_EMPTY | GS_ERR);
      lf_probe("after a cut line: the pen unchanged");

      //--------------------------------------------------------------
      $display("--- 5. debug freeze while a line draws");
      lf_init;
      gpu_c_pattern(32'h0000_0B5D, 11);
      gpu_c_fill($random(gpu_seed));
      gpu_c_pen(-32768, 8);
      gpu_c_line(32767, 8 + 16 * 2, 4'd0, 4'h0);
      repeat(300) @(posedge free_clk);
      gpu_freeze(1'b1);
      lf_st = 32'h0;
      while ((lf_st & GS_HELD) == 0) reg_rd_val(GPU_STAT, lf_st);
      gpu_mon_noacc = 1'b1;
      repeat(500) @(posedge free_clk);
      gpu_mon_noacc = 1'b0;
      gpu_freeze(1'b0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE);
      gpu_check_touched("a line through the freeze");

      gpu_c_pattern(32'hFFFF_FFFF, 32);
      gpu_check_all("line flushes");
      stimulus_done = 1;
   end
