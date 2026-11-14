//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_dash
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_dash.v
// Module Description : Dashed lines (SET_AUX LINE_PATTERN, EXEC_FILL LINE
//                      [17] NO_LAST, [18] OPAQUE, [19] PH_RST) against the
//                      model of gpu_model.v:
//                       1. LEN 1, 2, 31, 32 and random patterns, the bits
//                          above LEN ignored;
//                       2. the phase carried from line to line: polylines
//                          and a closed rectangle with NO_LAST (the rhythm
//                          kept across the corners), PH_RST, the LINE_PATTERN
//                          word resetting it; a line of D = 0 with NO_LAST
//                          (no step: the phase kept); address-mode lines (no
//                          advance; PH_RST still resets it);
//                       3. OPAQUE: the gaps in the SET_TRANSP colour, ops 0,
//                          5 and 13-15 (whose key skips every gap pixel), at
//                          1, 8 and 16 bpp;
//                       4. remapped gap colours (GPU_REMAP_EN);
//                       5. a hand-checked LVGL-style dash: x mod P <
//                          dash_width from the first clipped x.
//                      Exact VRAM read / write counts per group.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer LD_P      = 89;
localparam integer LD_NR     = 64;
localparam integer LD_D_LO   = 1024;
localparam integer LD_D_HI   = LD_D_LO + (LD_P * LD_NR) / 2 + 8;
localparam integer LD_T_LO   = LD_D_HI + 64;
localparam integer LD_VMIN   = LD_T_LO + 128;

integer    ld_i, ld_j, ld_k, ld_m, ld_mode, ld_bl, ld_rd0, ld_wr0, ld_len;
integer    ld_x0, ld_y0, ld_x1, ld_y1;
reg [31:0] ld_org;
reg [31:0] ld_v;

function integer ld_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      ld_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task ld_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      ld_mode = mode;
      ld_bl   = gpu_bl(mode);
      ld_org  = LD_D_LO * (32 >> ld_bl) + 2;
      gpu_c_dst_xy(LD_P, ld_org);
      gpu_c_noclip;
   end
endtask

task ld_mon_begin;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      ld_rd0 = gpu_exp_rd;
      ld_wr0 = gpu_exp_wr;
      gpu_mon_start;
   end
endtask

task ld_mon_end;
   input [8*32-1:0] what;
   begin
      gpu_wait_idle;
      gpu_mon_stop;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      if ((gpu_mon_rd != gpu_exp_rd - ld_rd0) || (gpu_mon_wr != gpu_exp_wr - ld_wr0)) begin
         $display("ERROR: %0s: %0d reads / %0d writes, expected %0d / %0d %t", what,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - ld_rd0, gpu_exp_wr - ld_wr0, $time);
         error = error + 1;
      end
      gpu_check_touched(what);
   end
endtask

function [31:0] ld_vpx;
   input integer x;
   input integer y;
   begin
      ld_vpx = gpu_vram_px((ld_org + y * LD_P + x) & GPU_PA_MASK, ld_bl);
   end
endfunction

// A random pixel-centre line inside the surface, from the pen
task ld_rand_to;
   input  [3:0] op;
   input  [3:0] opt;
   begin
      gpu_c_line(16 * ld_rnd(LD_P) + 8, 16 * ld_rnd(LD_NR) + 8, op, opt);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: dashed lines                      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_LINE_EN == 0))
         tb_skip_finish("|          (lines absent)                       |");
      if (VRAM_WORDS < LD_VMIN)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(LD_P);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_dlo = LD_D_LO;
      gpu_rgn_dhi = LD_D_HI;
      gpu_c_reset_state;

      //--------------------------------------------------------------
      $display("--- 1. LEN 1, 2, 31, 32 and random patterns");
      for (ld_mode = 0; ld_mode < 8; ld_mode = ld_mode + 1) begin
         ld_set_mode(ld_mode);
         gpu_preload_rand(LD_D_LO, LD_D_HI);
         ld_mon_begin;
         for (ld_i = 0; ld_i < 12; ld_i = ld_i + 1) begin
            case (ld_i % 6)
              0: ld_len = 1;
              1: ld_len = 2;
              2: ld_len = 31;
              3: ld_len = 32;
              default: ld_len = 1 + ld_rnd(32);
            endcase
            gpu_c_pattern($random(gpu_seed), ld_len);                     // (bits above LEN set at random)
            gpu_c_fill($random(gpu_seed));
            gpu_c_pen(16 * ld_rnd(LD_P) + ld_rnd(16), 16 * ld_rnd(LD_NR) + ld_rnd(16));
            gpu_c_line(16 * ld_rnd(LD_P) + ld_rnd(16), 16 * ld_rnd(LD_NR) + ld_rnd(16), 4'd0, {2'b00, ld_rnd(2) == 0, 1'b0});
         end
         ld_mon_end("patterns");
      end

      //--------------------------------------------------------------
      $display("--- 2. the phase across lines, PH_RST, LINE_PATTERN, address mode");
      ld_set_mode(3);
      gpu_preload_rand(LD_D_LO, LD_D_HI);
      ld_mon_begin;
      gpu_c_pattern(32'h0000_0F3B, 13);
      gpu_c_fill(32'hC3);
      gpu_c_pen(16 * 4 + 8, 16 * 4 + 8);
      for (ld_i = 0; ld_i < 8; ld_i = ld_i + 1)                          // a polyline, NO_LAST joints
         ld_rand_to(4'd0, 4'b0010);
      gpu_c_line(16 * 4 + 8, 16 * 4 + 8, 4'd0, 4'b0010);                // closed
      // a focus rectangle: four NO_LAST sides, the rhythm across the corners
      gpu_c_pattern(32'h0000_0003, 4);
      gpu_c_pen(16 * 30 + 8, 16 * 20 + 8);
      gpu_c_line(16 * 70 + 8, 16 * 20 + 8, 4'd5, 4'b0010);
      gpu_c_line(16 * 70 + 8, 16 * 50 + 8, 4'd5, 4'b0010);
      gpu_c_line(16 * 30 + 8, 16 * 50 + 8, 4'd5, 4'b0010);
      gpu_c_line(16 * 30 + 8, 16 * 20 + 8, 4'd5, 4'b0010);
      // PH_RST at random, D = 0 with NO_LAST (no step), LINE_PATTERN mid-way
      gpu_c_pattern($random(gpu_seed), 7);
      for (ld_i = 0; ld_i < 16; ld_i = ld_i + 1) begin
         if (ld_i == 9) gpu_c_pattern($random(gpu_seed), 11);
         if (ld_i % 5 == 4) gpu_c_line(gpu_m_pen_x, gpu_m_pen_y, 4'd0, 4'b0010);
         else ld_rand_to(4'd0, {ld_rnd(3) == 0, 1'b0, ld_rnd(2) == 0, 1'b0});
      end
      ld_mon_end("phase across lines");
      // address mode: the phase not advanced, PH_RST resets it
      gpu_preload_rand(LD_D_LO, LD_D_HI);
      ld_mon_begin;
      gpu_c_pattern(32'h0000_00A5, 9);
      gpu_c_pen(16 * 2 + 8, 16 * 3 + 8);
      gpu_c_line(16 * 33 + 8, 16 * 9 + 8, 4'd0, 4'b0000);              // phase 32 mod 9 = 5
      gpu_c_dst(16'd0, ld_org);
      gpu_m_xy = 1'b0;
      gpu_c_line(16 * 50 + 8, 16 * 9 + 8, 4'd0, 4'b0000);              // address mode: no advance
      gpu_c_dst_xy(LD_P, ld_org);
      gpu_c_line(16 * 80 + 8, 16 * 40 + 8, 4'd0, 4'b0000);              // from phase 5
      gpu_c_dst(16'd0, ld_org);
      gpu_m_xy = 1'b0;
      gpu_c_line(16 * 20 + 8, 16 * 50 + 8, 4'd0, 4'b1000);              // PH_RST in address mode
      gpu_c_dst_xy(LD_P, ld_org);
      gpu_c_line(16 * 60 + 8, 16 * 55 + 8, 4'd0, 4'b0000);              // from phase 0
      ld_mon_end("phase and address mode");

      //--------------------------------------------------------------
      $display("--- 3. OPAQUE gaps, ops 0, 5, 13-15");
      for (ld_m = 0; ld_m < 3; ld_m = ld_m + 1) begin
         ld_set_mode((ld_m == 0) ? 0 : (ld_m == 1) ? 3 : 4);
         gpu_preload_rand(LD_D_LO, LD_D_HI);
         ld_mon_begin;
         for (ld_i = 0; ld_i < 15; ld_i = ld_i + 1) begin
            gpu_c_pattern($random(gpu_seed), 2 + ld_rnd(30));
            gpu_c_fill($random(gpu_seed));
            gpu_c_transp((ld_rnd(4) == 0) ? gpu_m_fill : $random(gpu_seed));
            gpu_c_pen(16 * ld_rnd(LD_P) + 8, 16 * ld_rnd(LD_NR) + 8);
            ld_k = ld_i % 5;
            ld_rand_to((ld_k == 0) ? 4'd0 : (ld_k == 1) ? 4'd5 : (4'd13 + ld_k - 2), 4'b0100);
         end
         ld_mon_end("OPAQUE gaps");
      end

      //--------------------------------------------------------------
      $display("--- 4. remapped gap colours");
      if (GPU_REMAP_EN != 0) begin
         ld_set_mode(3);
         gpu_preload_rand(LD_D_LO, LD_D_HI);
         gpu_preload_rand(LD_T_LO, LD_T_LO + 64);
         gpu_c_remap_table(LD_T_LO);
         ld_mon_begin;
         for (ld_i = 0; ld_i < 10; ld_i = ld_i + 1) begin
            gpu_c_pattern($random(gpu_seed), 3 + ld_rnd(20));
            gpu_c_fill($random(gpu_seed));
            gpu_c_transp($random(gpu_seed));
            gpu_k_rmp = (ld_i % 2) + 1;
            gpu_c_pen(16 * ld_rnd(LD_P) + 8, 16 * ld_rnd(LD_NR) + 8);
            ld_rand_to(4'd0, 4'b0100);
         end
         gpu_k_rmp = 2'd0;
         ld_mon_end("remapped gaps");
      end

      //--------------------------------------------------------------
      $display("--- 5. an LVGL-style dash: x mod P < dash_width from the first clipped x");
      ld_set_mode(3);
      for (ld_i = gpu_word_of(ld_org, ld_bl); ld_i <= gpu_word_of(ld_org + LD_P * 4, ld_bl); ld_i = ld_i + 1) begin
         vram_mem[ld_i]   = 32'h0;
         gpu_shadow[ld_i] = 32'h0;
      end
      // P = 7, dash_width 3, x from 10 to 60 (end exclusive): the pattern
      // rotated so that phase 0 is 10 mod 7 = 3: bit k = ((k + 3) mod 7) < 3
      ld_v = 32'h0;
      for (ld_k = 0; ld_k < 7; ld_k = ld_k + 1)
         if (((ld_k + 3) % 7) < 3) ld_v = ld_v | (32'h1 << ld_k);
      gpu_c_pattern(ld_v, 7);
      gpu_c_fill(32'h77);
      gpu_c_pen(16 * 10 + 8, 16 * 2 + 8);
      gpu_c_line(16 * 60 + 8, 16 * 2 + 8, 4'd0, 4'b1010);                // PH_RST, NO_LAST
      gpu_wait_idle;
      for (ld_k = 0; ld_k < LD_P; ld_k = ld_k + 1) begin
         ld_v = ld_vpx(ld_k, 2);
         if (ld_v !== (((ld_k >= 10) && (ld_k < 60) && ((ld_k % 7) < 3)) ? 32'h77 : 32'h0))
            tb_error("LVGL-style dash pixel");
      end
      gpu_check_touched("LVGL-style dash");

      gpu_c_pattern(32'hFFFF_FFFF, 32);
      gpu_check_all("dashed lines");
      stimulus_done = 1;
   end
