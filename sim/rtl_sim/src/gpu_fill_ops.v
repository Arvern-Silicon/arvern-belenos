//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_fill_ops
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_fill_ops.v
// Module Description : EXEC_FILL with all 16 PX_OPs at every GFX_MODE (0..7,
//                      modes 5-7 = 16 bpp) on a random background, sub-word
//                      destination base, odd pitch. Each op runs twice: with
//                      TRANSP != fill and TRANSP == fill (ops 13/14/15 then
//                      write nothing; the other ops ignore transparency).
//                      Random bits above bpp in the fill colour must be
//                      ignored. Every rectangle is checked through the VRAM
//                      window against the reference model (gpu_model.v).
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tf_mode, tf_op, tf_tr, tf_sub, tf_ppw, tf_w0, tf_w1;
reg [31:0] tf_base, tf_fill;
localparam integer TF_PITCH = 37;
localparam integer TF_W     = 5;
localparam integer TF_H     = 3;

initial
   begin
      $display(" ===============================================");
      $display("|             GPU: FILL x PX_OP x MODE          |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_dispw(64);

      for (tf_mode = 0; tf_mode < 8; tf_mode = tf_mode + 1) begin
         gpu_set_mode(tf_mode);
         tf_ppw = 32 >> gpu_bl(tf_mode);
         for (tf_op = 0; tf_op < 16; tf_op = tf_op + 1)
            for (tf_tr = 0; tf_tr < 2; tf_tr = tf_tr + 1) begin
               tf_sub  = $random(gpu_seed) & (tf_ppw - 1);
               tf_base = 512 * tf_ppw + tf_sub + TF_PITCH + 2;
               tf_w0   = gpu_word_of(tf_base, gpu_bl(tf_mode)) - 4;
               tf_w1   = gpu_word_of(tf_base + TF_H * TF_PITCH + TF_W, gpu_bl(tf_mode)) + 4;
               gpu_preload_rand(tf_w0, tf_w1);
               tf_fill = $random(gpu_seed);
               gpu_c_dst(TF_PITCH, tf_base);
               gpu_c_size(TF_W, TF_H);
               gpu_c_fill(tf_fill);
               gpu_c_transp(tf_tr ? tf_fill : ~tf_fill);
               gpu_c_exec(GPU_FILL, tf_op, 3'b000, 3'b000);
               gpu_wait_idle;
               reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
               $display("       mode %0d op %0d transp-hit %0d sub %0d", tf_mode, tf_op, tf_tr, tf_sub);
               gpu_check_touched("fill");
            end
      end
      gpu_check_all("fill_ops end");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
