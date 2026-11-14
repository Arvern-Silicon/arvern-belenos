//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_swaps
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_swaps.v
// Module Description : Rectangle walk: all 8 DST x 8 SRC swap
//                      combinations of EXEC_COPY and the 8 DST combinations of
//                      EXEC_FILL, at 16, 8 and 2 bpp, on a non-square
//                      rectangle (CL swap: the width is the vertical run) with
//                      sub-word bases. Software passes the start corner as the
//                      surface base (the first pixel visited). Random source
//                      data, so every combination yields a distinct image.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    ts_mi, ts_mode, ts_bl, ts_ppw, ts_d, ts_s, ts_fill;
reg [31:0] ts_sorg, ts_dorg, ts_sbase, ts_dbase;
localparam integer TS_SPITCH = 29;
localparam integer TS_DPITCH = 33;
localparam integer TS_W      = 5;
localparam integer TS_H      = 3;

// Start-corner pixel address of a TS_W x TS_H rectangle at (x0, y0) of a
// surface (origin, pitch) walked with swaps sw = {X, Y, CL}
function [31:0] ts_corner;
   input [31:0] org;
   input integer pitch;
   input integer x0;
   input integer y0;
   input  [2:0] sw;
   integer      rows, cols;
   begin
      rows = sw[0] ? TS_W : TS_H;
      cols = sw[0] ? TS_H : TS_W;
      ts_corner = org + (y0 + (sw[1] ? rows - 1 : 0)) * pitch + x0 + (sw[2] ? cols - 1 : 0);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: 8 DST x 8 SRC swap combinations   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_dispw(64);

      for (ts_mi = 0; ts_mi < 3; ts_mi = ts_mi + 1) begin
         ts_mode = (ts_mi == 0) ? 4 : (ts_mi == 1) ? 3 : 1;
         gpu_set_mode(ts_mode);
         ts_bl  = gpu_bl(ts_mode);
         ts_ppw = 32 >> ts_bl;
         ts_sorg = 300 * ts_ppw + 1;
         ts_dorg = 800 * ts_ppw + 3;
         for (ts_fill = 0; ts_fill < 2; ts_fill = ts_fill + 1)
            for (ts_d = 0; ts_d < 8; ts_d = ts_d + 1)
               for (ts_s = 0; ts_s < (ts_fill ? 1 : 8); ts_s = ts_s + 1) begin
                  gpu_preload_rand(300 - 2, 300 + (8 * TS_SPITCH) / ts_ppw + 4);
                  gpu_preload_rand(800 - 2, 800 + (8 * TS_DPITCH) / ts_ppw + 4);
                  ts_sbase = ts_corner(ts_sorg, TS_SPITCH, 2, 1, ts_s);
                  ts_dbase = ts_corner(ts_dorg, TS_DPITCH, 1, 2, ts_d);
                  gpu_c_src(TS_SPITCH, ts_sbase);
                  gpu_c_dst(TS_DPITCH, ts_dbase);
                  gpu_c_size(TS_W, TS_H);
                  if (ts_fill) begin
                     gpu_c_fill($random(gpu_seed));
                     gpu_c_exec(GPU_FILL, 4'd5, ts_d, 3'b000);
                  end else
                     gpu_c_exec(GPU_COPY, 4'd0, ts_d, ts_s);
                  gpu_wait_idle;
                  $display("       mode %0d %0s dst {X,Y,CL}=%b src {X,Y,CL}=%b", ts_mode,
                           ts_fill ? "FILL" : "COPY", ts_d[2:0], ts_s[2:0]);
                  gpu_check_touched("swap");
               end
      end
      gpu_check_all("swaps end");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
