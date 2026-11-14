//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_tritex
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_tritex.v
// Module Description : Textured triangles (EXEC_TEXRECT [7] TRI): random
//                      triangles (any size, slivers, every winding, vertices
//                      in any order, partly outside the clip window) at every
//                      colour depth, a power-of-two texture with (u, v) at V0
//                      and random per-pixel / per-row steps, with and without
//                      transparency, SHADE and BOUND, FREE_PITCH (with BOUND,
//                      an explicit source pitch), texture swaps and DELTA
//                      set at random (both ignored), SET_ALPHA blending at
//                      16 bpp (as built). The image is checked against the
//                      model after each triangle, with its GPU_DONE; a few
//                      EXEC_TEXRECT without TRI keep their rectangle walk, a
//                      few TRI in address mode draw nothing (GPU_DONE), a
//                      few are frozen in the middle (no VRAM access while
//                      held). Then large textures: 1024 texels wide, a free
//                      pitch above 1024, a TEXBOX above 512 with texels
//                      landing in [512, TW) (skipped: the box acts as 512).
//                      Last, extreme triangles: vertices at the 12.4 limits,
//                      far off the surface, tall or flat, clipped around
//                      x, y < 0, flat and textured.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TT_P      = 96;                  // destination pitch (pixels)
localparam integer TT_D_LO   = 2000;
localparam integer TT_D_HI   = 7000;
localparam integer TT_S_LO   = 8000;
localparam integer TT_S_HI   = 9200;
localparam integer TT_N      = 160;

integer    tt_i, tt_mode, tt_bl, tt_ppw, tt_lw, tt_lh, tt_cx, tt_cy, tt_r, tt_k, tt_ntri, tt_g;
integer    tt_nfree, tt_nblend, tt_nadr, tt_nfrz;
reg        tt_bnd, tt_free;
reg [31:0] tt_flag;

function integer tt_rnd;
   input integer n;
   begin
      tt_rnd = ($random(gpu_seed) & 32'h7FFF_FFFF) % n;
   end
endfunction

function integer tt_srnd;                            // -n .. n
   input integer n;
   begin
      tt_srnd = tt_rnd(2 * n + 1) - n;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: textured triangles (TEXRECT TRI)  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0))
         tb_skip_finish("|   (needs triangles, x/y and affine blits)     |");
      if (VRAM_WORDS < TT_S_HI + 8)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_dispw(64);
      gpu_rgn_slo = TT_S_LO;
      gpu_rgn_shi = TT_S_HI;
      gpu_rgn_dlo = TT_D_LO;
      gpu_rgn_dhi = TT_D_HI;
      tt_ntri = 0;
      tt_nfree = 0; tt_nblend = 0; tt_nadr = 0; tt_nfrz = 0;

      for (tt_i = 0; tt_i < TT_N; tt_i = tt_i + 1) begin
         if ((tt_i % 20) == 0) begin
            gpu_wait_idle;
            tt_mode = tt_rnd(5);
            tt_bl   = gpu_bl(tt_mode);
            tt_ppw  = 32 >> tt_bl;
            gpu_preload_rand(TT_D_LO, TT_D_HI);
            gpu_preload_rand(TT_S_LO, TT_S_HI);
            gpu_model_init;
            gpu_set_mode(tt_mode);
            gpu_set_dispw(64);
            gpu_c_dst_xy(TT_P, (TT_D_LO + 16) * tt_ppw);   // rows 0 .. ~40 of the surface stay in the region
         end
         // clip window: the whole surface, or a random box
         if (tt_rnd(3) == 0) gpu_c_clip(0, 0, TT_P - 1, 39);
         else begin
            tt_cx = tt_rnd(60);
            tt_cy = tt_rnd(30);
            gpu_c_clip(tt_cx, tt_cy, tt_cx + tt_rnd(36), tt_cy + tt_rnd(10));
         end
         // texture: power of two up to 32 x 32 texels in the source region
         tt_lw   = tt_rnd(6);
         tt_lh   = tt_rnd(6);
         tt_free = (tt_rnd(4) == 0);                              // a free pitch: with BOUND here
         tt_bnd  = tt_free || (tt_rnd(4) == 0);
         if (tt_free) begin
            gpu_c_src(16'd32 + tt_rnd(16), TT_S_LO * tt_ppw + tt_rnd(tt_ppw));
            tt_nfree = tt_nfree + 1;
         end else
            gpu_c_src(16'd0, TT_S_LO * tt_ppw + tt_rnd(tt_ppw));
         gpu_c_transp($random(gpu_seed));
         gpu_c_tex(tt_lw, tt_lh, tt_rnd(2), tt_rnd(8), tt_free, tt_bnd, (tt_rnd(3) == 0) ? $random(gpu_seed) : 8'h00);
         if (tt_free)     gpu_c_texbox(1 + tt_rnd(32), 1 + tt_rnd(30));
         else if (tt_bnd) gpu_c_texbox(1 + tt_rnd(1 << tt_lw), 1 + tt_rnd(1 << tt_lh));
         if (GPU_BLEND_EN != 0) begin
            gpu_c_alpha((tt_bl == 4) && (tt_rnd(3) == 0), tt_rnd(256));
            if (gpu_m_aen) tt_nblend = tt_nblend + 1;
         end
         gpu_tt_delta = $random(gpu_seed);                        // ignored with TRI
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         if (tt_bnd) gpu_c_uv((tt_srnd(20) << 6) | tt_rnd(64), (tt_srnd(20) << 6) | tt_rnd(64));
         else        gpu_c_uv($random(gpu_seed), $random(gpu_seed));
         gpu_c_step(tt_srnd(3000), tt_srnd(3000));
         gpu_c_step_row(tt_srnd(3000), tt_srnd(3000));
         if (tt_rnd(10) == 0) begin                               // a plain affine blit in between
            gpu_c_size(1 + tt_rnd(12), 1 + tt_rnd(8));
            gpu_c_xy(tt_rnd(80), tt_rnd(32));
            gpu_c_texrect(0);
         end else begin
            // vertices (12.4) around the surface; some slivers
            tt_r  = (tt_rnd(3) == 0) ? 160 : (tt_rnd(2) ? 480 : 1200);
            tt_cx = 16 * tt_rnd(TT_P);
            tt_cy = 16 * tt_rnd(40);
            for (tt_k = 0; tt_k < 3; tt_k = tt_k + 1)
               gpu_c_vtx(tt_k, tt_cx + tt_srnd(tt_r), tt_cy + tt_srnd(tt_r / 2));
            if (tt_rnd(6) == 0)                                      // sliver: V2 near the V0-V1 line
               gpu_c_vtx(2, (gpu_tv_x[0] + gpu_tv_x[1]) / 2 + tt_srnd(3), (gpu_tv_y[0] + gpu_tv_y[1]) / 2 + tt_srnd(3));
            if (tt_rnd(15) == 0) begin                           // address mode: nothing drawn, GPU_DONE
               gpu_c_dst(16'd0, 32'd0);
               gpu_c_tritex;
               gpu_c_dst_xy(TT_P, (TT_D_LO + 16) * tt_ppw);
               tt_nadr = tt_nadr + 1;
            end else if (tt_rnd(12) == 0) begin                  // frozen in the middle
               gpu_mon_start;
               gpu_c_tritex;
               tt_g = 0;
               while ((gpu_mon_wr < 2) && (tt_g < 3000)) begin @(posedge free_clk); tt_g = tt_g + 1; end
               gpu_freeze(1'b1);
               reg_poll(GPU_STAT, GS_HELD, GS_HELD, 200);
               gpu_mon_noacc = 1'b1;
               reg_rd_val(IRQ_FLAG, tt_flag);                    // (a small triangle may be done already)
               repeat(150) @(posedge free_clk);
               gpu_mon_noacc = 1'b0;
               reg_rd_mask(IRQ_FLAG, tt_flag & IF_DONE, IF_DONE);   // no GPU_DONE while held
               gpu_freeze(1'b0);
               gpu_mon_stop;
               tt_nfrz = tt_nfrz + 1;
            end else
               gpu_c_tritex;
            tt_ntri = tt_ntri + 1;
         end
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);        // one GPU_DONE per EXEC
         gpu_check_touched("textured triangle");
         if (error != 0) tt_i = TT_N;
      end
      $display("       %0d textured triangles (%0d free pitch, %0d blended, %0d in address mode, %0d frozen)",
               tt_ntri, tt_nfree, tt_nblend, tt_nadr, tt_nfrz);
      gpu_check_all("textured triangles end");
      if (GPU_BLEND_EN != 0) gpu_c_alpha(1'b0, 8'd0);
      gpu_tt_delta = 14'h0000;

      // Large textures (16 bpp): words [12000, 14200) hold the texels
      if ((VRAM_WORDS >= 16000) && (GPU_DIM_MASK >= 63)) begin
         gpu_wait_idle;
         gpu_preload_rand(12000, 14200);
         gpu_preload_rand(TT_D_LO, TT_D_HI);
         gpu_model_init;
         gpu_set_mode(4);
         gpu_set_dispw(64);
         gpu_rgn_slo = 12000;
         gpu_rgn_shi = 14200;
         gpu_c_dst_xy(TT_P, (TT_D_LO + 16) * 2);
         gpu_c_noclip;
         for (tt_k = 0; tt_k < 3; tt_k = tt_k + 1) begin
            $display("--- %0s", (tt_k == 0) ? "a 1024 x 2 texture (log2 width 10)" :
                     (tt_k == 1) ? "a free pitch of 1100 texels" : "TEXBOX 700 x 3: texels from 505 on, [512, 700) skipped");
            case (tt_k)
              0: begin
                    gpu_c_src(16'd0, 2 * 12000);
                    gpu_c_tex(4'd10, 4'd1, 1'b0, 3'b000, 1'b0, 1'b0, 8'd0);
                    gpu_c_uv(16'd600 << 6, 16'd0);
                    gpu_c_step(16'd4096 + 16'd1000, 16'd30);
                    gpu_c_step_row(16'd700, 16'd400);
                 end
              1: begin
                    gpu_c_src(16'd1100, 2 * 12000 + 1);
                    gpu_c_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, 1'b1, 8'd0);
                    gpu_c_texbox(1090, 3);                         // acts as 512
                    gpu_c_uv(16'd480 << 6, 16'd0);
                    gpu_c_step(16'd1200, 16'd40);
                    gpu_c_step_row(16'd300, 16'd200);
                 end
              default: begin
                    gpu_c_src(16'd720, 2 * 12000 + 3);
                    gpu_c_tex(4'd0, 4'd0, 1'b1, 3'b000, 1'b1, 1'b1, 8'd0);
                    gpu_c_texbox(700, 3);
                    gpu_c_uv(16'd505 << 6, 16'd64);
                    gpu_c_step(16'd700, 16'd20);
                    gpu_c_step_row(16'd100, 16'd150);
                 end
            endcase
            gpu_c_transp($random(gpu_seed));
            gpu_c_vtx(0, 16 * 4, 16 * 2);
            gpu_c_vtx(1, 16 * 60, 16 * 5);
            gpu_c_vtx(2, 16 * 20, 16 * 14);
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_c_tritex;
            gpu_c_size(14'd40, 14'd3);                             // and an affine blit
            gpu_c_xy(2, 20);
            gpu_c_texrect(0);
            gpu_c_xy(0, 0);
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
            gpu_check_touched("large texture");
         end
         gpu_check_all("large textures end");
      end

      // Extreme triangles: vertices at the 12.4 limits (+-2048 pixels), far off
      // the surface, very tall or flat, either winding, clipped to a window at
      // and around x, y < 0; flat and textured, every depth
      if (GPU_DIM_MASK >= 63) begin
         $display("--- extreme triangles");
         gpu_rgn_slo = 0;
         gpu_rgn_shi = VRAM_WORDS;
         for (tt_k = 0; tt_k < 40; tt_k = tt_k + 1) begin
            gpu_wait_idle;
            if ((tt_k % 10) == 0) begin
               tt_mode = tt_rnd(5);
               tt_bl   = gpu_bl(tt_mode);
               tt_ppw  = 32 >> tt_bl;
               gpu_set_mode(tt_mode);
               gpu_c_dst_xy(TT_P, (TT_D_LO + 400) * tt_ppw);      // rows -8 .. 30 stay in the region
            end
            tt_cx = tt_rnd(40) - 8;
            tt_cy = tt_rnd(12) - 4;
            gpu_c_clip(tt_cx, tt_cy, tt_cx + tt_rnd(40), tt_cy + tt_rnd(14));
            for (tt_r = 0; tt_r < 3; tt_r = tt_r + 1)
               case (tt_rnd(6))
                 0: gpu_c_vtx(tt_r, tt_rnd(2) ? 32767 : -32768, tt_rnd(2) ? 32767 : -32768);
                 1: gpu_c_vtx(tt_r, tt_rnd(65536) - 32768, tt_rnd(2) ? 32767 : -32768);
                 2: gpu_c_vtx(tt_r, tt_rnd(2) ? 32767 : -32768, tt_rnd(65536) - 32768);
                 3: gpu_c_vtx(tt_r, 16 * (tt_cx + tt_rnd(40)) + tt_rnd(16), tt_rnd(65536) - 32768);   // tall
                 4: gpu_c_vtx(tt_r, tt_rnd(65536) - 32768, 16 * (tt_cy + tt_rnd(14)) + tt_rnd(16));   // flat
                 default: gpu_c_vtx(tt_r, 16 * tt_cx + tt_rnd(700) - 100, 16 * tt_cy + tt_rnd(300) - 50);
               endcase
            gpu_c_fill($random(gpu_seed));
            gpu_c_transp($random(gpu_seed));
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            if (tt_rnd(2))
               gpu_c_trifill(tt_rnd(16));
            else begin
               gpu_c_src(16'd0, TT_S_LO * tt_ppw);
               gpu_c_tex(4'd4, 4'd4, tt_rnd(2), 3'b000, 1'b0, 1'b0, 8'h00);
               gpu_c_uv($random(gpu_seed), $random(gpu_seed));
               gpu_c_step(tt_srnd(3000), tt_srnd(3000));
               gpu_c_step_row(tt_srnd(3000), tt_srnd(3000));
               gpu_c_tritex;
            end
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
            gpu_check_touched("extreme triangle");
         end
         gpu_check_all("extreme triangles end");
      end
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
