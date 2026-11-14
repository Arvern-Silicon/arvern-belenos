//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_aa
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_aa.v
// Module Description : Anti-aliased lines (EXEC_FILL LINE [16] AA, Wu) against
//                      the integer model of gpu_model.v, at 16 bpp in a
//                      GPU_BLEND_EN build:
//                       1. random lines in every direction, sub-pixel end
//                          points, slopes 0, 1 and -1 exactly, points, short
//                          and long lines, NO_LAST; bit-exact image, exact
//                          VRAM counts (coverage 0: no access);
//                       2. with SET_ALPHA (A 255, 128, random, 0): coverage x
//                          A / 255; the 16 raster ops (ops 13-15 blend their
//                          constant, their SET_TRANSP key);
//                       3. dashed AA lines (both pixels of a step follow its
//                          bit), OPAQUE gaps blended in the transparent colour;
//                       4. clip window across the lines; end points at
//                          -2048 / 2047.9375 (the rows -2049 and 2048 never
//                          drawn, nothing wraps); long sloped lines (minor
//                          deltas above 1 024 and 2 048 pixels);
//                       5. the palette modes: AA ignored, the solid line
//                          drawn (1, 4 and 8 bpp).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer LA_P      = 101;             // surface pitch (odd)
localparam integer LA_NR     = 70;
localparam integer LA_D_LO   = 1024;
localparam integer LA_D_HI   = LA_D_LO + (LA_P * LA_NR) / 2 + 8;
localparam integer LA_VMIN   = LA_D_HI + 64;

integer    la_i, la_k, la_m, la_mode, la_bl, la_rd0, la_wr0;
integer    la_x0, la_y0, la_x1, la_y1, la_n;
reg [31:0] la_org;

function integer la_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      la_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task la_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      la_mode = mode;
      la_bl   = gpu_bl(mode);
      la_org  = LA_D_LO * (32 >> la_bl) + 1;
      gpu_c_dst_xy(LA_P, la_org);
      gpu_c_noclip;
   end
endtask

task la_mon_begin;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      la_rd0 = gpu_exp_rd;
      la_wr0 = gpu_exp_wr;
      gpu_mon_start;
   end
endtask

task la_mon_end;
   input [8*32-1:0] what;
   begin
      gpu_wait_idle;
      gpu_mon_stop;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      if ((gpu_mon_rd != gpu_exp_rd - la_rd0) || (gpu_mon_wr != gpu_exp_wr - la_wr0)) begin
         $display("ERROR: %0s: %0d reads / %0d writes, expected %0d / %0d %t", what,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - la_rd0, gpu_exp_wr - la_wr0, $time);
         error = error + 1;
      end
      gpu_check_touched(what);
   end
endtask

// A random 12.4 line inside the surface (kind: 0 any, 1 short, 2 slope +-1 /
// 0 exactly, 3 a point)
task la_rand_line;
   input integer kind;
   begin
      la_x0 = la_rnd(16 * (LA_P - 4)) + 32;
      la_y0 = la_rnd(16 * (LA_NR - 4)) + 32;
      case (kind)
        1: begin la_x1 = la_x0 + la_rnd(64) - 32; la_y1 = la_y0 + la_rnd(64) - 32; end
        2: begin
              la_n  = la_rnd(16 * 30);
              la_x1 = la_x0 + ((la_rnd(2) == 0) ? la_n : -la_n);
              case (la_rnd(3))
                0: la_y1 = la_y0;
                1: la_y1 = la_y0 + (la_x1 - la_x0);
                default: la_y1 = la_y0 - (la_x1 - la_x0);
              endcase
              if (la_rnd(2) == 0) begin la_n = la_x1; la_x1 = la_y1 - la_y0 + la_x0; la_y1 = la_n - la_x0 + la_y0; end
           end
        3: begin la_x1 = la_x0; la_y1 = la_y0; end
        default: begin la_x1 = la_rnd(16 * (LA_P - 4)) + 32; la_y1 = la_rnd(16 * (LA_NR - 4)) + 32; end
      endcase
      if (la_x1 < 32) la_x1 = 32;
      if (la_y1 < 32) la_y1 = 32;
      if (la_x1 > 16 * (LA_P - 2)) la_x1 = 16 * (LA_P - 2);
      if (la_y1 > 16 * (LA_NR - 2)) la_y1 = 16 * (LA_NR - 2);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: anti-aliased lines                |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_LINE_EN == 0) || (GPU_BLEND_EN == 0))
         tb_skip_finish("|          (anti-aliased lines absent)          |");
      if (VRAM_WORDS < LA_VMIN)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(LA_P);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_dlo = LA_D_LO;
      gpu_rgn_dhi = LA_D_HI;
      gpu_c_reset_state;

      //--------------------------------------------------------------
      $display("--- 1. random AA lines, every direction, NO_LAST");
      la_set_mode(4);
      for (la_m = 0; la_m < 4; la_m = la_m + 1) begin
         gpu_preload_rand(LA_D_LO, LA_D_HI);
         la_mon_begin;
         for (la_i = 0; la_i < 20; la_i = la_i + 1) begin
            gpu_c_fill($random(gpu_seed));
            la_rand_line(la_m);
            gpu_c_pen(la_x0, la_y0);
            gpu_c_line(la_x1, la_y1, 4'd0, {2'b00, la_rnd(3) == 0, 1'b1});
         end
         la_mon_end((la_m == 0) ? "AA lines" : (la_m == 1) ? "short AA lines" :
                    (la_m == 2) ? "AA slopes 0, +-1" : "AA points");
      end
      // a polyline: NO_LAST on every segment, from the pen
      gpu_preload_rand(LA_D_LO, LA_D_HI);
      la_mon_begin;
      gpu_c_pen(16 * 10 + 3, 16 * 10 + 11);
      for (la_i = 0; la_i < 10; la_i = la_i + 1) begin
         la_rand_line(0);
         gpu_c_line(la_x1, la_y1, 4'd0, 4'b0011);
      end
      la_mon_end("AA polyline");

      //--------------------------------------------------------------
      $display("--- 2. SET_ALPHA, raster ops");
      gpu_preload_rand(LA_D_LO, LA_D_HI);
      la_mon_begin;
      for (la_i = 0; la_i < 24; la_i = la_i + 1) begin
         gpu_c_alpha(1'b1, (la_i % 4 == 0) ? 8'd255 : (la_i % 4 == 1) ? 8'd128 : (la_i % 4 == 2) ? 8'd0 : $random(gpu_seed));
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp((la_rnd(3) == 0) ? gpu_m_fill : $random(gpu_seed));
         la_rand_line(0);
         gpu_c_pen(la_x0, la_y0);
         gpu_c_line(la_x1, la_y1, la_rnd(16), 4'b0001);
      end
      gpu_c_alpha(1'b0, 8'd0);
      for (la_i = 0; la_i < 16; la_i = la_i + 1) begin
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp((la_rnd(3) == 0) ? gpu_m_fill : $random(gpu_seed));
         la_rand_line(0);
         gpu_c_pen(la_x0, la_y0);
         gpu_c_line(la_x1, la_y1, la_i, 4'b0001);
      end
      la_mon_end("AA with SET_ALPHA and ops");

      //--------------------------------------------------------------
      $display("--- 3. dashed AA lines, OPAQUE gaps");
      gpu_preload_rand(LA_D_LO, LA_D_HI);
      la_mon_begin;
      for (la_i = 0; la_i < 16; la_i = la_i + 1) begin
         if (la_i % 4 == 0) gpu_c_pattern($random(gpu_seed), 1 + la_rnd(32));
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         la_rand_line(0);
         gpu_c_pen(la_x0, la_y0);
         gpu_c_line(la_x1, la_y1, 4'd0, {la_rnd(4) == 0, la_rnd(2) == 0, 1'b0, 1'b1});
      end
      gpu_c_pattern(32'hFFFF_FFFF, 32);
      la_mon_end("dashed AA lines");

      //--------------------------------------------------------------
      $display("--- 4. clip window, the 12.4 extremes");
      gpu_preload_rand(LA_D_LO, LA_D_HI);
      la_mon_begin;
      for (la_i = 0; la_i < 16; la_i = la_i + 1) begin
         la_x0 = la_rnd(LA_P - 10); la_y0 = la_rnd(LA_NR - 10);
         gpu_c_clip(la_x0, la_y0, la_x0 + la_rnd(40), la_y0 + la_rnd(30));
         gpu_c_fill($random(gpu_seed));
         la_rand_line(la_rnd(3));
         gpu_c_pen(la_x0 - 16 * la_rnd(2), la_y0);
         gpu_c_line(la_x1, la_y1, 4'd0, 4'b0001);
      end
      la_mon_end("clipped AA lines");
      // a surface whose rows -2048 .. 2047 hold the extremes: pitch 1 and
      // the origin in the middle of the region (x = 0 only: one column)
      gpu_preload_rand(LA_D_LO, LA_D_HI);
      gpu_c_dst_xy(16'd1, la_org + 2100);
      gpu_c_clip(-2048, -2048, 2047, 2047);
      la_mon_begin;
      gpu_c_fill($random(gpu_seed));
      gpu_c_pen(-8, -32768);                                            // (-0.5, -2048.0) to (-0.5, 2047.9375)
      gpu_c_line(-8, 32767, 4'd0, 4'b0001);
      gpu_c_clip(-8, -2048, 8, 2047);                                   // (pitch 1: x near 0 only)
      gpu_c_pen(-32768, -32768 + 3);                                    // x from -2048 to 2047 at the top row
      gpu_c_line(32767, -32768 + 9, 4'd0, 4'b0001);
      // long sloped lines across the column: minor deltas of 562.5, 1 250
      // and 3 548 pixels (the divider's remainder start |dQ| / 2, 12.4,
      // through its upper bits)
      gpu_c_pen(-20000, -1000);
      gpu_c_line(20000, 8000, 4'd0, 4'b0001);
      gpu_c_pen(-20000, -18000);
      gpu_c_line(20000, 2000, 4'd0, 4'b0001);
      gpu_c_pen(-32768, -32768 + 5);
      gpu_c_line(32767, 24005, 4'd0, 4'b0001);
      gpu_c_clip(-2048, -2048, 2047, 2047);
      gpu_c_pen(-32768, 32767);
      gpu_c_line(-32768 + 20, 32767 - 7, 4'd0, 4'b0001);
      la_mon_end("AA at the 12.4 extremes");
      la_set_mode(4);

      //--------------------------------------------------------------
      $display("--- 5. the palette modes: the solid line");
      for (la_m = 0; la_m < 3; la_m = la_m + 1) begin
         la_set_mode((la_m == 0) ? 0 : (la_m == 1) ? 2 : 3);
         gpu_preload_rand(LA_D_LO, LA_D_HI);
         la_mon_begin;
         for (la_i = 0; la_i < 12; la_i = la_i + 1) begin
            gpu_c_fill($random(gpu_seed));
            la_rand_line(0);
            gpu_c_pen(la_x0, la_y0);
            gpu_c_line(la_x1, la_y1, (la_i % 3 == 0) ? 4'd5 : 4'd0, 4'b0001);
         end
         la_mon_end("AA in a palette mode");
      end

      gpu_check_all("AA lines");
      stimulus_done = 1;
   end
