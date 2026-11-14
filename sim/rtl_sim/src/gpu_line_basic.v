//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_basic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_basic.v
// Module Description : Solid lines (EXEC_FILL [24] LINE, SET_AUX LINE_PEN)
//                      against the closed-form model of gpu_model.v:
//                       1. hand-checked pixel sets (horizontal, vertical,
//                          diagonal, a 2:1 slope with exact halves) and both
//                          directions drawing the same pixels (XOR twice
//                          leaves nothing);
//                       2. random lines in all 8 octants at every GFX_MODE,
//                          sub-pixel end points (the pixels holding them),
//                          D = 0, NO_LAST; exact VRAM read / write counts,
//                          one GPU_DONE per line;
//                       3. the 16 raster ops at 1, 8 and 16 bpp, the ops
//                          13-15 key hit and miss;
//                       4. polylines (2 words per vertex, NO_LAST joints: XOR
//                          visits every joint pixel once);
//                       5. address mode: nothing drawn, one GPU_DONE, the pen
//                          moved (the next x/y line starts there);
//                       6. palette remap SRC / DST (GPU_REMAP_EN) and SET_ALPHA
//                          blending at 16 bpp (GPU_BLEND_EN);
//                       7. pitch 0 (the frame width) and RESET_STATE (pen at
//                          (0, 0)).
//                      The touched words are compared with the model through
//                      the VRAM window after each step, the whole VRAM at
//                      the end.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer LB_P      = 97;              // surface pitch (odd)
localparam integer LB_NR     = 80;              // rows
localparam integer LB_D_LO   = 1024;            // destination words (16 bpp worst case)
localparam integer LB_D_HI   = LB_D_LO + (LB_P * LB_NR) / 2 + 8;
localparam integer LB_T_LO   = LB_D_HI + 64;    // remap table (64 words)
localparam integer LB_VMIN   = LB_T_LO + 128;

integer    lb_i, lb_j, lb_k, lb_m, lb_n, lb_mode, lb_bl;
integer    lb_x0, lb_y0, lb_x1, lb_y1, lb_rd0, lb_wr0, lb_nd;
integer    lb_ndone;
reg  [3:0] lb_op;
reg  [3:0] lb_opt;
reg [31:0] lb_org;
reg [31:0] lb_v;

function integer lb_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      lb_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task lb_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      lb_mode = mode;
      lb_bl   = gpu_bl(mode);
      lb_org  = LB_D_LO * (32 >> lb_bl) + 3;
      gpu_c_dst_xy(LB_P, lb_org);
      gpu_c_noclip;
   end
endtask

// Monitors around a group of lines: flags cleared, counters armed
task lb_mon_begin;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      lb_rd0   = gpu_exp_rd;
      lb_wr0   = gpu_exp_wr;
      lb_ndone = 0;
      gpu_mon_start;
   end
endtask

task lb_mon_end;
   input        counts;
   input [8*32-1:0] what;
   begin
      gpu_wait_idle;
      gpu_mon_stop;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      if (counts && ((gpu_mon_rd != gpu_exp_rd - lb_rd0) || (gpu_mon_wr != gpu_exp_wr - lb_wr0))) begin
         $display("ERROR: %0s: %0d reads / %0d writes, expected %0d / %0d %t", what,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - lb_rd0, gpu_exp_wr - lb_wr0, $time);
         error = error + 1;
      end
      gpu_check_touched(what);
   end
endtask

// A line from (x0, y0) to (x1, y1), pixel coordinates (the pixel centres)
task lb_line_px;
   input integer x0;
   input integer y0;
   input integer x1;
   input integer y1;
   input  [3:0] op;
   input  [3:0] opt;
   begin
      gpu_c_pen(16 * x0 + 8, 16 * y0 + 8);
      gpu_c_line(16 * x1 + 8, 16 * y1 + 8, op, opt);
   end
endtask

// One GPU_DONE per line: n lines since the flag was cleared, one at a time
task lb_line_done;
   input integer x1;
   input integer y1;
   input  [3:0] op;
   input  [3:0] opt;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_DONE);
      gpu_c_line(x1, y1, op, opt);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE);
   end
endtask

// The VRAM pixel at (x, y) of the surface
function [31:0] lb_vpx;
   input integer x;
   input integer y;
   begin
      lb_vpx = gpu_vram_px((lb_org + y * LB_P + x) & GPU_PA_MASK, lb_bl);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: solid lines                       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_LINE_EN == 0))
         tb_skip_finish("|          (lines absent)                       |");
      if (VRAM_WORDS < LB_VMIN)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(LB_P);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_dlo = LB_D_LO;
      gpu_rgn_dhi = LB_D_HI;
      gpu_c_reset_state;

      //--------------------------------------------------------------
      $display("--- 1. hand-checked pixel sets, both directions");
      lb_set_mode(3);                                                  // 8 bpp
      gpu_preload_rand(LB_D_LO, LB_D_HI);
      for (lb_i = gpu_word_of(lb_org, lb_bl); lb_i <= gpu_word_of(lb_org + LB_P * 8, lb_bl); lb_i = lb_i + 1) begin
         vram_mem[lb_i]   = 32'h0;                                     // rows 0-7 to 0
         gpu_shadow[lb_i] = 32'h0;
      end
      gpu_c_fill(32'hFF);
      lb_line_px(1, 1, 9, 1, 4'd5, 4'h0);                              // horizontal: 9 pixels
      lb_line_px(0, 3, 4, 5, 4'd5, 4'h0);                              // 2:1, halves at x = 1, 3: down
      gpu_wait_idle;
      for (lb_i = 0; lb_i < 12; lb_i = lb_i + 1) begin
         lb_v = lb_vpx(lb_i, 1);
         if (lb_v !== (((lb_i >= 1) && (lb_i <= 9)) ? 32'hFF : 32'h0)) tb_error("horizontal line pixel");
      end
      // (0,3) (1,3) (2,4) (3,4) (4,5): the halves at x = 1 and 3 toward the smaller y
      if ((lb_vpx(0, 3) !== 32'hFF) || (lb_vpx(1, 3) !== 32'hFF) || (lb_vpx(1, 4) !== 32'h0) ||
          (lb_vpx(2, 4) !== 32'hFF) || (lb_vpx(3, 4) !== 32'hFF) || (lb_vpx(3, 5) !== 32'h0) ||
          (lb_vpx(4, 5) !== 32'hFF))
         tb_error("2:1 line: exact halves toward the smaller coordinate");
      lb_line_px(4, 5, 0, 3, 4'd5, 4'h0);                              // the other way: XOR clears it
      lb_line_px(9, 1, 1, 1, 4'd5, 4'h0);
      gpu_wait_idle;
      for (lb_i = 0; lb_i < 12; lb_i = lb_i + 1)
         for (lb_j = 0; lb_j < 7; lb_j = lb_j + 1)
            if (lb_vpx(lb_i, lb_j) !== 32'h0) tb_error("reversed line: not the same pixel set");
      gpu_check_touched("hand-checked lines");
      // every direction twice with XOR: the set is direction-free
      lb_mon_begin;
      for (lb_i = 0; lb_i < 40; lb_i = lb_i + 1) begin
         lb_x0 = lb_rnd(LB_P); lb_y0 = lb_rnd(LB_NR);
         lb_x1 = lb_rnd(LB_P); lb_y1 = lb_rnd(LB_NR);
         lb_line_px(lb_x0, lb_y0, lb_x1, lb_y1, 4'd5, 4'h0);
         lb_line_px(lb_x1, lb_y1, lb_x0, lb_y0, 4'd5, 4'h0);
      end
      lb_mon_end(1'b1, "XOR both directions");

      //--------------------------------------------------------------
      $display("--- 2. random lines, 8 octants, every GFX_MODE, sub-pixel end points, NO_LAST");
      for (lb_mode = 0; lb_mode < 8; lb_mode = lb_mode + 1) begin
         lb_set_mode(lb_mode);
         gpu_preload_rand(LB_D_LO, LB_D_HI);
         lb_mon_begin;
         for (lb_i = 0; lb_i < 24; lb_i = lb_i + 1) begin
            gpu_c_fill($random(gpu_seed));
            lb_x0 = lb_rnd(16 * LB_P); lb_y0 = lb_rnd(16 * LB_NR);
            case (lb_i % 4)
              0: begin lb_x1 = lb_x0; lb_y1 = lb_y0; end                // D = 0
              1: begin lb_x1 = lb_rnd(16 * LB_P); lb_y1 = lb_y0 + lb_rnd(16) - 8; end
              default: begin lb_x1 = lb_rnd(16 * LB_P); lb_y1 = lb_rnd(16 * LB_NR); end
            endcase
            if (lb_y1 < 0) lb_y1 = 0;
            if (lb_y1 >= 16 * LB_NR) lb_y1 = 16 * LB_NR - 1;
            lb_opt = {2'b00, lb_rnd(2) == 1, 1'b0};                       // NO_LAST
            gpu_c_pen(lb_x0, lb_y0);
            if ((lb_i % 8) == 3) lb_line_done(lb_x1, lb_y1, 4'd0, lb_opt);
            else                 gpu_c_line(lb_x1, lb_y1, lb_rnd(3) == 0 ? 4'd5 : 4'd0, lb_opt);
         end
         lb_mon_end(1'b1, "random lines");
      end

      //--------------------------------------------------------------
      $display("--- 3. the 16 raster ops, the ops 13-15 key");
      for (lb_m = 0; lb_m < 3; lb_m = lb_m + 1) begin
         lb_set_mode((lb_m == 0) ? 0 : (lb_m == 1) ? 3 : 4);
         gpu_preload_rand(LB_D_LO, LB_D_HI);
         lb_mon_begin;
         for (lb_k = 0; lb_k < 16; lb_k = lb_k + 1) begin
            gpu_c_fill($random(gpu_seed));
            gpu_c_transp((lb_rnd(2) == 0) ? gpu_m_fill : $random(gpu_seed));
            lb_line_px(lb_rnd(LB_P), lb_rnd(LB_NR), lb_rnd(LB_P), lb_rnd(LB_NR), lb_k[3:0], {2'b00, lb_rnd(2) == 1, 1'b0});
         end
         lb_mon_end(1'b1, "raster ops");
      end

      //--------------------------------------------------------------
      $display("--- 4. polylines: 2 words per vertex, NO_LAST joints");
      lb_set_mode(3);
      for (lb_i = gpu_word_of(lb_org, lb_bl); lb_i <= gpu_word_of(lb_org + LB_P * LB_NR, lb_bl); lb_i = lb_i + 1) begin
         vram_mem[lb_i]   = 32'h0;
         gpu_shadow[lb_i] = 32'h0;
      end
      gpu_c_fill(32'h01);
      lb_mon_begin;
      gpu_c_pen(16 * 5 + 8, 16 * 5 + 8);
      lb_x0 = 5; lb_y0 = 5;
      for (lb_i = 0; lb_i < 12; lb_i = lb_i + 1) begin
         lb_x1 = lb_rnd(LB_P); lb_y1 = lb_rnd(LB_NR);
         if (lb_i == 11) begin lb_x1 = 5; lb_y1 = 5; end                // closed
         gpu_c_line(16 * lb_x1 + 8, 16 * lb_y1 + 8, 4'd5, 4'b0010);      // NO_LAST on every segment
      end
      lb_mon_end(1'b1, "closed polyline");                              // (XOR: every joint pixel once)

      //--------------------------------------------------------------
      $display("--- 5. address mode: nothing drawn, one GPU_DONE, the pen moved");
      lb_set_mode(4);
      gpu_preload_rand(LB_D_LO, LB_D_HI);
      gpu_c_dst(16'd0, lb_org);
      gpu_m_xy = 1'b0;
      lb_mon_begin;
      gpu_c_pen(16 * 3 + 8, 16 * 3 + 8);
      lb_line_done(16 * 40 + 8, 16 * 20 + 8, 4'd0, 4'h0);              // the pen at (40, 20)
      gpu_wait_idle;
      gpu_mon_stop;
      if ((gpu_mon_rd != 0) || (gpu_mon_wr != 0)) tb_error("a line in address mode accessed the VRAM");
      gpu_c_dst_xy(LB_P, lb_org);
      lb_mon_begin;
      gpu_c_line(16 * 60 + 8, 16 * 30 + 8, 4'd0, 4'h0);                // from (40, 20)
      lb_mon_end(1'b1, "after an address-mode line");

      //--------------------------------------------------------------
      $display("--- 6. remap, blending");
      if (GPU_REMAP_EN != 0) begin
         lb_set_mode(3);
         gpu_preload_rand(LB_D_LO, LB_D_HI);
         gpu_preload_rand(LB_T_LO, LB_T_LO + 64);
         gpu_c_remap_table(LB_T_LO);
         lb_mon_begin;
         for (lb_i = 0; lb_i < 12; lb_i = lb_i + 1) begin
            gpu_c_fill($random(gpu_seed));
            gpu_k_rmp = (lb_i % 2) + 1;                                  // SRC, DST
            lb_line_px(lb_rnd(LB_P), lb_rnd(LB_NR), lb_rnd(LB_P), lb_rnd(LB_NR), (lb_i % 3 == 2) ? 4'd5 : 4'd0, 4'h0);
         end
         gpu_k_rmp = 2'd0;
         lb_mon_end(1'b1, "remapped lines");
      end
      if (GPU_BLEND_EN != 0) begin
         lb_set_mode(4);
         gpu_preload_rand(LB_D_LO, LB_D_HI);
         lb_mon_begin;
         for (lb_i = 0; lb_i < 12; lb_i = lb_i + 1) begin
            gpu_c_alpha(1'b1, (lb_i == 0) ? 8'd255 : (lb_i == 1) ? 8'd0 : $random(gpu_seed));
            gpu_c_fill($random(gpu_seed));
            gpu_c_transp($random(gpu_seed));
            lb_line_px(lb_rnd(LB_P), lb_rnd(LB_NR), lb_rnd(LB_P), lb_rnd(LB_NR), (lb_i % 4 == 3) ? 4'd15 : 4'd0, 4'h0);
         end
         gpu_c_alpha(1'b0, 8'd0);
         lb_mon_end(1'b1, "blended lines");
      end

      //--------------------------------------------------------------
      $display("--- 7. pitch 0, RESET_STATE");
      lb_set_mode(3);
      gpu_c_dst_xy(16'd0, lb_org);                                      // the frame width: LB_P
      lb_mon_begin;
      lb_line_px(2, 2, 50, 40, 4'd0, 4'h0);
      lb_mon_end(1'b1, "pitch 0");
      gpu_c_pen(16 * 7, 16 * 9);
      gpu_c_reset_state;                                                // pen (0, 0), solid pattern
      lb_set_mode(3);
      gpu_c_fill(32'h5A);
      lb_mon_begin;
      gpu_c_line(16 * 30 + 4, 16 * 12 + 15, 4'd0, 4'h0);                // from (0, 0)
      lb_mon_end(1'b1, "after RESET_STATE");

      gpu_check_all("lines");
      stimulus_done = 1;
   end
