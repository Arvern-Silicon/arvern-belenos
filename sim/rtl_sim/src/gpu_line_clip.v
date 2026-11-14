//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_clip
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_clip.v
// Module Description : Line clipping: per pixel against the SET_CLIP window,
//                      the exact early exit and the set-up's box test:
//                       1. random lines across random windows (every edge,
//                          1 x 1, empty, the line on an edge), 8 octants, at
//                          1, 8 and 16 bpp; the pattern phase continuing
//                          through clipped steps; exact VRAM counts (a
//                          clipped pixel: no access);
//                       2. the box test: a line beside the window makes no
//                          VRAM access and completes within a few cycles;
//                       3. the early exit: a 4096-step line leaving the
//                          window at its start completes in far fewer
//                          cycles than its steps; one entering it late takes
//                          one cycle per step outside;
//                       4. end points at the 12-bit extremes (-2048,
//                          2047), the longest line (D = 4095) through a
//                          window, with a dash pattern (the phase after it
//                          checked by the next line).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer LC_P      = 95;
localparam integer LC_NR     = 72;
localparam integer LC_D_LO   = 1024;
localparam integer LC_D_HI   = LC_D_LO + (LC_P * LC_NR) / 2 + 8;
localparam integer LC_VMIN   = LC_D_HI + 64;

integer    lc_i, lc_k, lc_m, lc_bl, lc_rd0, lc_wr0, lc_cx0, lc_cy0, lc_cx1, lc_cy1;
integer    lc_t0, lc_dt;
reg [31:0] lc_org;

function integer lc_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      lc_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task lc_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      lc_bl  = gpu_bl(mode);
      lc_org = LC_D_LO * (32 >> lc_bl) + 7;
      gpu_c_dst_xy(LC_P, lc_org);
   end
endtask

task lc_mon_begin;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      lc_rd0 = gpu_exp_rd;
      lc_wr0 = gpu_exp_wr;
      gpu_mon_start;
   end
endtask

task lc_mon_end;
   input [8*32-1:0] what;
   begin
      gpu_wait_idle;
      gpu_mon_stop;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      if ((gpu_mon_rd != gpu_exp_rd - lc_rd0) || (gpu_mon_wr != gpu_exp_wr - lc_wr0)) begin
         $display("ERROR: %0s: %0d reads / %0d writes, expected %0d / %0d %t", what,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - lc_rd0, gpu_exp_wr - lc_wr0, $time);
         error = error + 1;
      end
      gpu_check_touched(what);
   end
endtask

// A random window inside the surface (kind: 0 any, 1 one pixel, 2 empty, 3 a
// row, 4 a column)
task lc_window;
   input integer kind;
   begin
      lc_cx0 = lc_rnd(LC_P - 2);
      lc_cy0 = lc_rnd(LC_NR - 2);
      lc_cx1 = lc_cx0 + lc_rnd(LC_P - lc_cx0);
      lc_cy1 = lc_cy0 + lc_rnd(LC_NR - lc_cy0);
      case (kind)
        1: begin lc_cx1 = lc_cx0; lc_cy1 = lc_cy0; end
        2: lc_cx1 = lc_cx0 - 1;
        3: lc_cy1 = lc_cy0;
        4: lc_cx1 = lc_cx0;
        default: ;
      endcase
      gpu_c_clip(lc_cx0, lc_cy0, lc_cx1, lc_cy1);
   end
endtask

// The cycles a single line takes, from its operand push to the GPU idle
task lc_time_line;
   input integer x1;
   input integer y1;
   output integer cyc;
   begin
      gpu_wait_idle;
      lc_t0 = gpu_cyc;
      gpu_c_line(x1, y1, 4'd0, 4'h0);
      gpu_wait_idle;
      cyc = gpu_cyc - lc_t0;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: line clipping                     |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_LINE_EN == 0))
         tb_skip_finish("|          (lines absent)                       |");
      if (VRAM_WORDS < LC_VMIN)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(LC_P);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_dlo = LC_D_LO;
      gpu_rgn_dhi = LC_D_HI;
      gpu_c_reset_state;

      //--------------------------------------------------------------
      $display("--- 1. random lines across random windows");
      for (lc_m = 0; lc_m < 3; lc_m = lc_m + 1) begin
         lc_set_mode((lc_m == 0) ? 0 : (lc_m == 1) ? 3 : 4);
         gpu_preload_rand(LC_D_LO, LC_D_HI);
         lc_mon_begin;
         for (lc_i = 0; lc_i < 40; lc_i = lc_i + 1) begin
            if (lc_i % 4 == 0) lc_window(lc_rnd(5));
            if (lc_i % 10 == 0) gpu_c_pattern($random(gpu_seed), 1 + lc_rnd(32));
            gpu_c_fill($random(gpu_seed));
            if (lc_i % 7 == 6)                                           // along a window edge
               gpu_c_pen(16 * lc_cx0 + 8, 16 * lc_rnd(LC_NR) + lc_rnd(16));
            else
               gpu_c_pen(16 * lc_rnd(LC_P) + lc_rnd(16), 16 * lc_rnd(LC_NR) + lc_rnd(16));
            gpu_c_line((lc_i % 7 == 6) ? (16 * lc_cx0 + 3) : (16 * lc_rnd(LC_P) + lc_rnd(16)),
                       16 * lc_rnd(LC_NR) + lc_rnd(16), (lc_i % 3 == 0) ? 4'd5 : 4'd0,
                       {1'b0, lc_rnd(3) == 0, lc_rnd(2) == 0, 1'b0});
         end
         lc_mon_end("clipped lines");
      end
      gpu_c_pattern(32'hFFFF_FFFF, 32);

      //--------------------------------------------------------------
      $display("--- 2. the box test: no access, a few cycles");
      lc_set_mode(3);
      gpu_c_clip(40, 30, 60, 50);
      lc_mon_begin;
      for (lc_i = 0; lc_i < 8; lc_i = lc_i + 1) begin
         case (lc_i % 4)
           0: gpu_c_pen(16 * 2 + 8, 16 * 2 + 8);                          // up-left of it
           1: gpu_c_pen(16 * 70 + 8, 16 * 2 + 8);
           2: gpu_c_pen(16 * 2 + 8, 16 * 60 + 8);
           default: gpu_c_pen(16 * 70 + 8, 16 * 60 + 8);
         endcase
         case (lc_i % 4)
           0: lc_time_line(16 * 38 + 8, 16 * 28 + 8, lc_dt);
           1: lc_time_line(16 * 90 + 8, 16 * 25 + 8, lc_dt);
           2: lc_time_line(16 * 39 + 8, 16 * 70 + 8, lc_dt);
           default: lc_time_line(16 * 61 + 8, 16 * 51 + 8, lc_dt);
         endcase
         if (lc_dt > 80) begin
            $display("ERROR: a line missing the window took %0d cycles %t", lc_dt, $time);
            error = error + 1;
         end
      end
      lc_mon_end("box test");
      if (gpu_mon_rd + gpu_mon_wr != 0) tb_error("a line missing the window accessed the VRAM");

      //--------------------------------------------------------------
      $display("--- 3. the early exit");
      gpu_c_dst_xy(16'd1, lc_org + 2100);                               // pitch 1: x in a few pixels only
      gpu_c_clip(-2048, -2048, -2000, 2047);
      lc_mon_begin;
      gpu_c_pen(-32768, 100);                                           // x -2048 .. 2047: 49 inside
      lc_time_line(32767, 2000, lc_dt);
      lc_mon_end("early exit");
      if (lc_dt > 400) begin
         $display("ERROR: a line leaving the window after 49 of 4096 steps took %0d cycles %t", lc_dt, $time);
         error = error + 1;
      end
      gpu_c_clip(1990, -2048, 2047, 2047);
      lc_mon_begin;
      gpu_c_pen(-32768, 100);                                           // enters after 4038 steps
      lc_time_line(32767, 2000, lc_dt);
      lc_mon_end("late entry");
      if ((lc_dt < 4038) || (lc_dt > 4600)) begin
         $display("ERROR: a line entering the window after 4038 steps took %0d cycles %t", lc_dt, $time);
         error = error + 1;
      end

      //--------------------------------------------------------------
      $display("--- 4. the 12-bit extremes, the longest line, its phase");
      gpu_c_dst_xy(16'd1, lc_org + 2100);
      gpu_c_clip(-20, -2048, 20, 2047);
      gpu_c_pattern(32'h0012_3457, 23);
      lc_mon_begin;
      gpu_c_pen(-32768, -32768);                                        // (-2048, -2048)
      gpu_c_line(32767, 32767, 4'd0, 4'b0000);                          // (2047, 2047): D = 4095
      gpu_c_pen(-32768, 32767);
      gpu_c_line(32767, -32768, 4'd5, 4'b0010);                         // and back, NO_LAST
      gpu_c_pen(-8, -32768);
      gpu_c_line(-8, 32767, 4'd0, 4'b0000);                             // y-major, 4096 steps
      gpu_c_pen(-2, -32768);
      gpu_c_line(-2, -32768 + 3, 4'd0, 4'b0010);                        // D = 0, NO_LAST: nothing
      gpu_c_dst_xy(LC_P, lc_org);
      gpu_c_noclip;
      gpu_c_pen(16 * 3 + 8, 16 * 5 + 8);
      gpu_c_line(16 * 80 + 8, 16 * 6 + 8, 4'd0, 4'b0000);               // the phase after them
      lc_mon_end("extremes and phase");

      gpu_c_pattern(32'hFFFF_FFFF, 32);
      gpu_check_all("clipped lines");
      stimulus_done = 1;
   end
