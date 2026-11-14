//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_highmem
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_highmem.v
// Module Description : GPU work at the top of a large VRAM (the high bits of
//                      every GPU address path): the sources, textures, remap
//                      table, mask plane, command list and destinations in
//                      the top 64 K words, FILL / COPY (remap, mask plane) /
//                      COPY_TRANSP / EXPAND / TEXSPAN / TEXRECT, a list run
//                      from the top, a FILL ending on the last VRAM word, at
//                      1, 8 and 16 bpp. Checked against the model (touched
//                      words through the VRAM window, then the top region
//                      through the backdoor: the whole VRAM compare would
//                      take too long).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer HM_TOP = VRAM_WORDS - 65536;      // the region: words [HM_TOP, VRAM_WORDS)
localparam integer HM_SRC = HM_TOP + 1024;           // sources, textures: [+1024, +9216)
localparam integer HM_MSK = HM_TOP + 10240;          // mask plane: [+10240, +10496)
localparam integer HM_RMP = HM_TOP + 11264;          // remap table (a multiple of 64)
localparam integer HM_LST = HM_TOP + 12288;          // command list: [+12288, +16384)
localparam integer HM_DST = HM_TOP + 20480;          // destinations: [+20480, VRAM_WORDS)

integer    hm_k, hm_i, hm_mode, hm_bl, hm_nbad;
reg [31:0] hm_caps;

function integer hm_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      hm_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] hm_px;                   // a pixel of word w at the current depth
   input integer w;
   begin
      hm_px = (w << (5 - hm_bl)) + hm_rnd(32 >> hm_bl);
   end
endfunction

task hm_check_top;                       // the top region through the backdoor
   input [8*40-1:0] label;
   integer          ww;
   begin
      hm_nbad = 0;
      for (ww = HM_TOP; ww < VRAM_WORDS; ww = ww + 1)
         if (vram_mem[ww] !== gpu_shadow[ww]) begin
            hm_nbad = hm_nbad + 1;
            if (hm_nbad <= 6)
               $display("ERROR: GPU %0s -- backdoor word 0x%h = 0x%h / expected 0x%h %t",
                        label, ww, vram_mem[ww], gpu_shadow[ww], $time);
         end
      error = error + hm_nbad;
      if (hm_nbad == 0) $display("OK:    GPU %0s -- the top 64 K words match the model", label);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: work at the top of a large VRAM         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 1048576)
         tb_skip_finish("|      (VRAM below 1 M words: nothing high)     |");
      gpu_seed = `SEED;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;
      gpu_preload_rand(HM_TOP, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      reg_rd_val(BLNS_CFG2, hm_caps);
      hm_caps = (hm_caps >> 8) & 32'h3;                          // [0] REMAP, [1] MPLANE
      for (hm_k = 0; hm_k < 18; hm_k = hm_k + 1) begin
         hm_mode = (hm_k % 3 == 0) ? 0 : (hm_k % 3 == 1) ? 3 : 4;
         hm_bl   = gpu_bl(hm_mode);
         gpu_set_mode(hm_mode);
         $display("--- %0d bpp, case %0d", 1 << hm_bl, hm_k / 3);
         gpu_c_size(4 + hm_rnd(12), 1 + hm_rnd(6));
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         gpu_c_src_fmt(16'd64 + hm_rnd(64), hm_px(HM_SRC + hm_rnd(4096)), 4'h0);
         if ((GPU_XY_EN != 0) && hm_rnd(2)) begin
            gpu_c_dst_xy(16'd128, hm_px(HM_DST + hm_rnd(30000)));
            gpu_c_xy(hm_rnd(40), hm_rnd(10));
            gpu_c_noclip;
         end else
            gpu_c_dst(16'd100 + hm_rnd(100), hm_px(HM_DST + hm_rnd(30000)));
         case (hm_k / 3)
           0: gpu_c_exec_xy(GPU_FILL, hm_rnd(16), hm_rnd(8), 3'b000);
           1: begin
                 gpu_k_rmp = (hm_caps[0] && (hm_bl < 4)) ? 2'd1 + hm_rnd(2) : 2'd0;
                 if (gpu_k_rmp != 2'd0) gpu_c_remap_table(HM_RMP);
                 gpu_k_mpl = hm_caps[1];
                 if (gpu_k_mpl) gpu_c_mask_plane(32 * HM_MSK + 2048 + hm_rnd(256), hm_rnd(2));
                 gpu_c_exec_xy(GPU_COPY, hm_rnd(13), hm_rnd(8), hm_rnd(8));
                 gpu_k_rmp = 2'd0;
                 gpu_k_mpl = 1'b0;
              end
           2: gpu_c_exec_xy(GPU_COPYT, hm_rnd(13), hm_rnd(8), hm_rnd(8));
           3: begin
                 gpu_c_src_fmt(16'd0, (HM_SRC + hm_rnd(4096)) << 5, 4'd1);
                 gpu_c_expand(0, hm_rnd(8), hm_rnd(2), 2'd0);
              end
           4: begin
                 gpu_c_tex(4'd5, 4'd4, hm_rnd(2), hm_rnd(8), 1'b0, 1'b0, 8'h00);
                 gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                 gpu_c_step(hm_rnd(4000) - 2000, hm_rnd(4000) - 2000);
                 if (gpu_m_xy) begin
                    gpu_c_step_row(hm_rnd(4000) - 2000, hm_rnd(4000) - 2000);
                    gpu_c_texrect(0);
                 end else
                    gpu_c_texspan(0, 14'd20);
              end
           default: begin                                        // a list at the top
                 gpu_wait_idle;
                 gpu_cap_n  = 0;
                 gpu_cap_en = 1'b1;
                 for (hm_i = 0; hm_i < 6; hm_i = hm_i + 1) begin
                    gpu_c_dst(16'd90, hm_px(HM_DST + hm_rnd(30000)));
                    gpu_c_size(1 + hm_rnd(8), 1 + hm_rnd(4));
                    gpu_c_fill($random(gpu_seed));
                    gpu_c_exec(hm_rnd(2) ? GPU_FILL : GPU_COPY, hm_rnd(13), hm_rnd(8), 3'b000);
                 end
                 gpu_cap_en = 1'b0;
                 for (hm_i = 0; hm_i < gpu_cap_n; hm_i = hm_i + 1) begin
                    vram_mem[HM_LST + hm_i]   = gpu_cap_buf[hm_i];
                    gpu_shadow[HM_LST + hm_i] = gpu_cap_buf[hm_i];
                 end
                 gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
                 gpu_push(HM_LST);
              end
         endcase
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("top of the VRAM");
      end
      $display("--- a FILL ending on the last VRAM word");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 2 * VRAM_WORDS - 64 * 3 - 8);
      gpu_c_size(14'd8, 14'd4);
      gpu_c_fill(32'h0000_5EED);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("last VRAM word");
      hm_check_top("gpu_highmem end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
