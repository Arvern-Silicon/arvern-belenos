//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_ext_grad
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_ext_grad.v
// Module Description : Long gradients, against the model: x/y FILLs about
//                      4 000 pixels wide (or tall) starting at x (or y) =
//                      -2048 with N from 1 025 to 4 095, the clip window
//                      keeping only their last pixels, so that the
//                      gradient starts 2 000 to 4 090 steps in (the
//                      set-up's division by N with a remainder above 2 048),
//                      along the run and along the lines, plain and RGB
//                      (16 bpp); then a short gradient again. Needs DIM_W
//                      >= 13 (a rectangle 4 095 wide).
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    eg_k, eg_n, eg_w, eg_c, eg_ax, eg_bl, eg_mode;

function integer eg_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      eg_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: long gradients                          |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_XY_EN == 0) || (GPU_GRAD_EN == 0))
         tb_skip_finish("|   (no GPU x/y mode or no gradient: nothing)   |");
      if ((DIM_W < 13) || (VRAM_WORDS < 38400))
         tb_skip_finish("|   (DIM_W below 13 or VRAM below 38 400)       |");
      gpu_seed = `SEED;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;
      gpu_preload_rand(0, 38400);
      gpu_model_init;
      gpu_set_dispw(64);
      for (eg_k = 0; eg_k < 16; eg_k = eg_k + 1) begin
         eg_mode = (eg_k % 4 == 3) ? 4 : (eg_k % 4 == 2) ? 3 : 0;
         eg_bl   = gpu_bl(eg_mode);
         gpu_set_mode(eg_mode);
         eg_ax = (eg_k / 4) % 2;                           // 0: per line, 1: along the run
         eg_n  = (eg_k < 8) ? (1025 + eg_rnd(3071)) : 4095 - eg_rnd(4);
         eg_w  = 4095;
         eg_c  = 2040 + eg_rnd(6);                         // the first kept pixel / line
         $display("--- %0d bpp, AXIS %0d, N %0d, start %0d steps in", 1 << eg_bl, eg_ax, eg_n, eg_c + 2048);
         gpu_c_fill($random(gpu_seed));
         if ((eg_bl == 4) && eg_rnd(2))
            gpu_c_grad_rgb(eg_n, eg_ax, eg_rnd(1024) - 512, eg_rnd(1024) - 512, eg_rnd(1024) - 512, 1'b1);
         else
            gpu_c_grad(eg_n, eg_ax, eg_rnd(16) - 8, 1'b1);
         if (eg_ax) begin
            // a run 4 095 pixels wide from x = -2048, 3 lines; x >= eg_c kept
            gpu_c_dst_xy(16'd128, 32'd4000 << (5 - eg_bl));
            gpu_c_clip(eg_c, 0, 2047, 2);
            gpu_c_size(eg_w, 14'd3);
            gpu_c_xy(-2048, 0);
         end else begin
            // 4 095 lines from y = -2048, 5 pixels wide; y >= eg_c kept
            gpu_c_dst_xy(16'd32, 32'd2000 << (5 - eg_bl));        // only y >= 2040 is drawn
            gpu_c_clip(0, eg_c, 4, 2047);
            gpu_c_size(14'd5, eg_w);
            gpu_c_xy(0, -2048);
         end
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("long gradient");
      end
      $display("--- a short gradient again");
      gpu_set_mode(4);
      gpu_c_noclip;
      gpu_c_grad(3, 1'b1, 1, 1'b1);
      gpu_c_dst_xy(16'd64, 32'd2000 << 1);
      gpu_c_size(14'd20, 14'd2);
      gpu_c_xy(3, 1);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("short gradient");
      gpu_check_all("gpu_ext_grad end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
