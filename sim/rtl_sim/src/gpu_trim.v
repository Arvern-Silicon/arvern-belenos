//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_trim
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_trim.v
// Module Description : Rectangles in x/y mode against a clip window, the image
//                      checked against the model after each: every kind (FILL
//                      with and without a gradient on either axis, COPY,
//                      COPY_TRANSP with source swaps, EXPAND at every source
//                      depth, TEXSPAN, TEXRECT with and without BOUND), every
//                      destination swap, every colour depth; positions around
//                      the window's edges (inside, straddling one or two
//                      edges, fully outside), windows from one pixel to the
//                      whole range. A fully clipped rectangle raises GPU_DONE
//                      and touches nothing.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TR_P      = 48;                  // destination pitch (pixels)
localparam integer TR_DST_LO = 600;
localparam integer TR_DST_HI = 1400;
localparam integer TR_SRC_LO = 1500;
localparam integer TR_SRC_HI = 2300;
localparam integer TR_N      = 240;

integer    tr_i, tr_kind, tr_mode, tr_bl, tr_ppw, tr_w, tr_h, tr_x, tr_y, tr_sdep, tr_lw, tr_lh;
integer    tr_cx0, tr_cy0, tr_cx1, tr_cy1, tr_nfull, tr_npart, tr_nin, tr_cl0;
reg  [2:0] tr_dsw, tr_ssw;
reg [31:0] tr_org, tr_f;
reg        tr_bnd;

function integer tr_rnd;
   input integer n;
   begin
      tr_rnd = ($random(gpu_seed) & 32'h7FFF_FFFF) % n;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|    GPU: rectangles trimmed to the clip window |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (GPU_XY_EN == 0)
         tb_skip_finish("|          (GPU_XY_EN = 0: no clip window)      |");
      if (VRAM_WORDS < TR_SRC_HI + 8)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_dispw(64);
      gpu_rgn_slo = TR_SRC_LO;
      gpu_rgn_shi = TR_SRC_HI;
      gpu_rgn_dlo = TR_DST_LO;
      gpu_rgn_dhi = TR_DST_HI;
      tr_nfull = 0;
      tr_npart = 0;
      tr_nin   = 0;

      for (tr_i = 0; tr_i < TR_N; tr_i = tr_i + 1) begin
         if ((tr_i % 24) == 0) begin
            gpu_wait_idle;
            tr_mode = tr_rnd(5);
            tr_bl  = gpu_bl(tr_mode);
            tr_ppw = 32 >> tr_bl;
            gpu_preload_rand(TR_DST_LO, TR_DST_HI);
            gpu_preload_rand(TR_SRC_LO, TR_SRC_HI);
            gpu_model_init;                                   // resets the model's mode: before the mode
            gpu_set_mode(tr_mode);
            gpu_set_dispw(64);
            tr_org = (TR_DST_LO + 8) * tr_ppw + tr_rnd(tr_ppw);   // rows 0 .. 22 stay in the region
            gpu_c_dst_xy(TR_P, tr_org);
            gpu_c_transp($random(gpu_seed));                  // the init cleared the model's TRANSP, not the register
         end
         // window: whole range, one pixel, or a random box inside the surface
         case (tr_rnd(6))
           0:       begin tr_cx0 = -2048; tr_cy0 = -2048; tr_cx1 = 2047; tr_cy1 = 2047; end
           1:       begin tr_cx0 = 3 + tr_rnd(20); tr_cy0 = 1 + tr_rnd(4); tr_cx1 = tr_cx0; tr_cy1 = tr_cy0; end
           default: begin tr_cx0 = tr_rnd(20); tr_cy0 = tr_rnd(4); tr_cx1 = tr_cx0 + tr_rnd(24); tr_cy1 = tr_cy0 + tr_rnd(5); end
         endcase
         if (tr_cx0 > 40) tr_cx0 = 40;
         if (tr_cx1 > 40) tr_cx1 = 40;
         if (tr_cy1 > 6)  tr_cy1 = 6;
         gpu_c_clip(tr_cx0, tr_cy0, tr_cx1, tr_cy1);
         tr_kind = tr_rnd((GPU_XY_EN != 0) ? 7 : 6);
         if ((tr_kind == 1) && (GPU_GRAD_EN == 0)) tr_kind = 0;
         tr_w   = 1 + tr_rnd(14);
         tr_h   = 1 + tr_rnd(6);
         tr_dsw = tr_rnd(8);
         tr_ssw = tr_rnd(8);
         if (tr_dsw[0] && (tr_w > 6)) tr_w = 6;                         // CL: runs along y
         if (tr_dsw[0] && (tr_h > 14)) tr_h = 14;
         tr_x   = tr_cx0 - 4 + tr_rnd(tr_cx1 - tr_cx0 + 12);
         tr_y   = tr_cy0 - 3 + tr_rnd(tr_cy1 - tr_cy0 + 8);
         if (tr_x < 0) tr_x = 0;
         if (tr_y < 0) tr_y = 0;
         if (tr_x > 44) tr_x = 44;
         if (tr_y > 6)  tr_y = 6;
         if (tr_dsw[2] && (tr_x < (tr_dsw[0] ? tr_h : tr_w))) tr_x = (tr_dsw[0] ? tr_h : tr_w);   // stay on the surface
         if (tr_dsw[1] && (tr_y < (tr_dsw[0] ? tr_w : tr_h))) tr_y = (tr_dsw[0] ? tr_w : tr_h);
         gpu_c_size(tr_w, tr_h);
         gpu_c_xy(tr_x, tr_y);
         tr_f = $random(gpu_seed);
         gpu_c_fill(tr_f);
         tr_cl0 = gpu_exp_clip;
         case (tr_kind)
           0: gpu_c_exec_xy(GPU_FILL, (tr_rnd(3) == 0) ? 4'd0 : tr_rnd(16), tr_dsw, 3'b000);
           1: begin                                                         // gradient, either axis
                 gpu_c_grad(1 + tr_rnd(4), tr_rnd(2), tr_rnd(16) - 8, 1'b1);
                 gpu_c_exec_xy(GPU_FILL, 4'd0, tr_dsw, 3'b000);
                 gpu_c_grad(0, 1'b0, 0, 1'b0);
              end
           2, 3: begin                                                      // COPY / COPY_TRANSP, source swaps
                 gpu_c_src(16'd32, (TR_SRC_LO + 8) * tr_ppw + 16 * 32 + 16 + tr_rnd(tr_ppw));
                 gpu_c_transp($random(gpu_seed));
                 gpu_c_exec_xy((tr_kind == 2) ? GPU_COPY : GPU_COPYT, tr_rnd(16), tr_dsw, tr_ssw);
              end
           4: begin                                                         // EXPAND, packed source
                 tr_sdep = tr_rnd(4);
                 gpu_c_src(16'd0, (TR_SRC_LO + 8) * (32 >> tr_sdep) + tr_rnd(32 >> tr_sdep));
                 gpu_c_transp($random(gpu_seed));
                 gpu_c_expand(0, tr_dsw, tr_rnd(2), tr_sdep);
              end
           5: begin                                                         // TEXSPAN (one run)
                 gpu_c_size(tr_w, 1);
                 gpu_c_src(16'd0, (TR_SRC_LO + 8) * tr_ppw + tr_rnd(tr_ppw));
                 gpu_c_transp($random(gpu_seed));
                 gpu_c_tex(tr_rnd(5), tr_rnd(5), tr_rnd(2), tr_dsw, 1'b0, 1'b0, $random(gpu_seed));
                 gpu_c_step(tr_rnd(8193) - 4096, tr_rnd(8193) - 4096);
                 gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                 gpu_c_texspan(0, tr_w);
              end
           default: begin                                                   // TEXRECT, with or without BOUND
                 tr_lw  = tr_rnd(5);
                 tr_lh  = tr_rnd(5);
                 tr_bnd = tr_rnd(2);
                 gpu_c_src(16'd0, (TR_SRC_LO + 8) * tr_ppw + tr_rnd(tr_ppw));
                 gpu_c_transp($random(gpu_seed));
                 gpu_c_tex(tr_lw, tr_lh, tr_rnd(2), tr_dsw, 1'b0, tr_bnd, $random(gpu_seed));
                 gpu_c_texbox(1 + tr_rnd(1 << tr_lw), 1 + tr_rnd(1 << tr_lh));
                 gpu_c_step(tr_rnd(8193) - 4096, tr_rnd(8193) - 4096);
                 gpu_c_step_row(tr_rnd(8193) - 4096, tr_rnd(8193) - 4096);
                 if (tr_bnd) gpu_c_uv(((tr_rnd(41) - 20) << 6) | tr_rnd(64), ((tr_rnd(41) - 20) << 6) | tr_rnd(64));
                 else        gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                 gpu_c_texrect(0);
              end
         endcase
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE);                         // a clipped-away one too
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         if (gpu_exp_clip == tr_cl0) tr_nin = tr_nin + 1;
         else if (gpu_exp_clip - tr_cl0 == tr_w * ((tr_kind == 5) ? 1 : tr_h)) tr_nfull = tr_nfull + 1;
         else tr_npart = tr_npart + 1;
         gpu_check_touched("trimmed rectangle");
         if (error != 0) tr_i = TR_N;
      end
      $display("       %0d rectangles: %0d inside, %0d partly clipped, %0d fully clipped",
               TR_N, tr_nin, tr_npart, tr_nfull);
      if ((tr_nin == 0) || (tr_npart == 0) || (tr_nfull == 0))
         tb_error("trim mix lacks an inside, a partly or a fully clipped case (test bug)");
      gpu_check_all("trim end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
