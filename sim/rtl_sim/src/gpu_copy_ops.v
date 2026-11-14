//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_copy_ops
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_copy_ops.v
// Module Description : EXEC_COPY and EXEC_COPY_TRANSP with all 16 PX_OPs at
//                      every GFX_MODE (0..7). Source drawn from a 4-colour
//                      palette, TRANSP = one of the colours, so transparent
//                      pixels occur in COPY_TRANSP (any op) and in COPY with
//                      ops 13/14/15; COPY op 2 does not read the source.
//                      Source and destination at different sub-word offsets
//                      and pitches, random destination background. Checked
//                      through the VRAM window against gpu_model.v.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tc_mode, tc_op, tc_cmd, tc_ppw, tc_bl;
reg [31:0] tc_sbase, tc_dbase;
reg [15:0] tc_c0, tc_c1, tc_c2, tc_c3;
localparam integer TC_SPITCH = 23;
localparam integer TC_DPITCH = 41;
localparam integer TC_W      = 6;
localparam integer TC_H      = 3;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: COPY/COPY_TRANSP x PX_OP x MODE   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_dispw(64);

      for (tc_mode = 0; tc_mode < 8; tc_mode = tc_mode + 1) begin
         gpu_set_mode(tc_mode);
         tc_bl  = gpu_bl(tc_mode);
         tc_ppw = 32 >> tc_bl;
         for (tc_cmd = 0; tc_cmd < 2; tc_cmd = tc_cmd + 1)
            for (tc_op = 0; tc_op < 16; tc_op = tc_op + 1) begin
               tc_sbase = 200 * tc_ppw + ($random(gpu_seed) & (tc_ppw - 1)) + 3;
               tc_dbase = 900 * tc_ppw + ($random(gpu_seed) & (tc_ppw - 1)) + 5;
               tc_c0 = $random(gpu_seed); tc_c1 = $random(gpu_seed);
               tc_c2 = $random(gpu_seed); tc_c3 = $random(gpu_seed);
               gpu_preload_pal(gpu_word_of(tc_sbase, tc_bl) - 2,
                               gpu_word_of(tc_sbase + TC_H * TC_SPITCH + TC_W, tc_bl) + 2,
                               tc_bl, tc_c0, tc_c1, tc_c2, tc_c3);
               gpu_preload_rand(gpu_word_of(tc_dbase, tc_bl) - 2,
                                gpu_word_of(tc_dbase + TC_H * TC_DPITCH + TC_W, tc_bl) + 2);
               gpu_c_src(TC_SPITCH, tc_sbase);
               gpu_c_dst(TC_DPITCH, tc_dbase);
               gpu_c_size(TC_W, TC_H);
               gpu_c_fill($random(gpu_seed));
               gpu_c_transp({$random(gpu_seed), tc_c1});
               gpu_exp_transp = 0;
               gpu_c_exec(tc_cmd ? GPU_COPYT : GPU_COPY, tc_op, 3'b000, 3'b000);
               gpu_wait_idle;
               reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
               $display("       mode %0d %0s op %0d transparent pixels %0d", tc_mode,
                        tc_cmd ? "COPY_TRANSP" : "COPY", tc_op, gpu_exp_transp);
               gpu_check_touched("copy");
            end
      end
      gpu_check_all("copy_ops end");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
