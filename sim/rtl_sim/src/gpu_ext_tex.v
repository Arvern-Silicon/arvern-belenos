//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_ext_tex
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_ext_tex.v
// Module Description : Texture operand extremes, against the model:
//                        - SET_TEXBOX boxes above 512 (TW 896, TH 2 528:
//                          acting as 512), then 448 x 480, then 5 x 3, each
//                          drawn by a BOUND TEXRECT, so that every box bit and
//                          the clamped copies rise and fall;
//                        - with a VRAM of 1 M words or more: FREE_PITCH
//                          textures at 1 bpp with pitches 0xF800, 0xFFFF and
//                          2 048 and rows up to 1 023 (texel offsets up to
//                          2^26 pixels), then a small pitch again;
//                        - with VRAM_WORDS = 2^VRAM_AW: a texel past the
//                          pixel-address range (ERR_CAUSE 5, nothing
//                          written);
//                        - with triangles and DIM_W >= 13: textured triangles
//                          about 4 000 pixels wide (row bounds above 2 048),
//                          two shapes, every vertex rotation and winding;
//                          a sliver 4 096 rows tall (first row 4 096 rows
//                          below the box top for its bottom edge).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

integer    et_k, et_i, et_p, et_v, et_b, et_x;
integer    et_tx [0:2];
integer    et_ty [0:2];
reg [31:0] et_st;

function integer et_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      et_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function integer et_srnd;                // uniform in (-n, n)
   input integer n;
   begin
      et_srnd = et_rnd(2 * n - 1) - (n - 1);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: texture operand extremes                |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_XY_EN == 0))
         tb_skip_finish("|      (no GPU x/y mode: no texture blit)       |");
      if (VRAM_WORDS < 38400)
         tb_skip_finish("|        (VRAM below 38 400 words)              |");
      gpu_seed = `SEED;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;
      gpu_preload_rand(0, 38400);
      gpu_model_init;
      gpu_set_dispw(64);

      //------------------------------------------------------------------
      $display("--- TEXBOX 896 x 2528, 448 x 480, 5 x 3 (BOUND, 16 bpp)");
      gpu_set_mode(4);
      gpu_rgn_slo = 12000;
      gpu_rgn_shi = 30000;
      gpu_c_dst_xy(16'd96, 2 * 4000);
      gpu_c_noclip;
      for (et_k = 0; et_k < 6; et_k = et_k + 1) begin
         gpu_c_src(16'd1100, 2 * 12000 + et_rnd(2));
         gpu_c_tex(4'd0, 4'd0, et_rnd(2), 3'b000, 1'b1, 1'b1, 8'd0);
         case (et_k % 3)
           0: gpu_c_texbox(896, 2528);
           1: gpu_c_texbox(448, 480);
           default: gpu_c_texbox(5, 3);
         endcase
         gpu_c_transp($random(gpu_seed));
         gpu_c_uv(((et_k % 3 == 2) ? 0 : (300 + et_rnd(150))) << 6, ((et_k % 3 == 2) ? 0 : et_rnd(8)) << 6);
         gpu_c_step(16'd2048 + et_rnd(800), et_srnd(400));
         gpu_c_step_row(et_srnd(600), 16'd2048 + et_rnd(400));
         gpu_c_size(14'd24, 14'd3);
         gpu_c_xy(et_rnd(40), et_rnd(8));
         gpu_c_texrect(0);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("TEXBOX extremes");
      end

      //------------------------------------------------------------------
      if (VRAM_WORDS >= 1048576) begin
         $display("--- FREE_PITCH 0xF800 / 0xFFFF / 2048 at 1 bpp, rows up to 1023, then pitch 40");
         gpu_preload_rand(38400, (VRAM_WORDS < 2200000) ? VRAM_WORDS : 2200000);
         gpu_model_init;
         gpu_set_mode(0);
         gpu_rgn_slo = 0;
         gpu_rgn_shi = VRAM_WORDS;
         gpu_c_dst_xy(16'd256, 32 * 4000);
         gpu_c_noclip;
         for (et_k = 0; et_k < 8; et_k = et_k + 1) begin
            case (et_k % 4)
              0: et_p = 16'hF800 + et_rnd(2048);
              1: et_p = 16'hFFFF;
              2: et_p = 2048;
              default: et_p = 40;
            endcase
            et_v = (et_k % 4 == 3) ? et_rnd(16) : (1000 + et_rnd(23));
            gpu_c_src(et_p, 32 * 100 + et_rnd(64));
            gpu_c_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, 1'b0, 8'd0);
            gpu_c_uv(et_rnd(900) << 6, et_v << 6);
            gpu_c_step(16'd2048 + et_rnd(2000), 16'd0);
            gpu_c_step_row(16'd0, -16'sd2048 * (1 + et_rnd(3)));
            gpu_c_size(14'd40, 14'd4);
            gpu_c_xy(et_rnd(100), et_rnd(8));
            gpu_c_texrect(0);
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            gpu_check_touched("free pitch extremes");
         end
      end

      //------------------------------------------------------------------
      if (VRAM_WORDS == (1 << VRAM_AW)) begin
         $display("--- a texel past the pixel-address range: cause 5, nothing written");
         gpu_set_mode(0);
         gpu_snapshot;
         gpu_c_dst_xy(16'd256, 32 * 4000);
         gpu_c_src(16'd2048, VRAM_WORDS * 32 - 1000);
         gpu_c_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, 1'b0, 8'd0);
         gpu_c_uv(16'd0, 16'd3 << 6);
         gpu_c_step(16'd0, 16'd0);
         gpu_c_step_row(16'd0, 16'd0);
         gpu_c_size(14'd1, 14'd1);
         gpu_c_xy(5, 1);
         gpu_c_texrect(0);
         reg_poll(GPU_STAT, GS_ERR, GS_ERR, 2000);
         reg_rd_mask(GPU_STAT, {OP_EXEC_TEXRECT, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_wr(GPU_CTRL, 32'h1);                          // CLEAR_ERR
         gpu_wait_idle;
         gpu_restore;
         gpu_check_touched("texel past the range");
         // and a plain texel again: the high sum bits fall
         gpu_c_src(16'd40, 32 * 100);
         gpu_c_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, 1'b0, 8'd0);
         gpu_c_uv(16'd3 << 6, 16'd3 << 6);
         gpu_c_size(14'd8, 14'd2);
         gpu_c_texrect(0);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("texel after the past-range one");
      end

      //------------------------------------------------------------------
      if ((GPU_TRI_EN != 0) && (DIM_W >= 13)) begin
         $display("--- textured triangles about 4 000 pixels wide, every rotation and winding");
         gpu_set_mode(0);
         gpu_rgn_slo = 0;
         gpu_rgn_shi = VRAM_WORDS;
         // a 4 160-pixel-wide surface at 1 bpp (130 words a row), x = 0 at pixel 2 080
         gpu_c_dst_xy(16'd4160, 32 * 20000 + 2080);
         gpu_c_clip(-2048, 0, 2047, 30);
         gpu_c_src(16'd0, 32 * 100);
         for (et_k = 0; et_k < 12; et_k = et_k + 1) begin
            // two shapes whose left edges cross the box (one long left edge;
            // two left edges meeting at the middle), each vertex rotation and
            // both windings
            et_x = 16 * 2000;
            if (et_k < 6) begin
               et_tx[0] = -et_x;                         et_ty[0] = 16 * 1;
               et_tx[1] =  et_x;                         et_ty[1] = 16 * 2;
               et_tx[2] =  et_x - 16 * et_rnd(64);       et_ty[2] = 16 * (20 + et_rnd(8));
            end else begin
               et_tx[0] = -et_x;                         et_ty[0] = 16 * 1;
               et_tx[1] =  16 * et_srnd(40);             et_ty[1] = 16 * (12 + et_rnd(4));
               et_tx[2] =  et_x;                         et_ty[2] = 16 * (24 + et_rnd(4));
            end
            et_b = et_k % 3;                             // rotation
            et_i = ((et_k / 3) % 2) ? 2 : 1;             // winding: V1 / V2 order
            gpu_c_vtx(0, et_tx[et_b],           et_ty[et_b]);
            gpu_c_vtx(et_i, et_tx[(et_b + 1) % 3], et_ty[(et_b + 1) % 3]);
            gpu_c_vtx(3 - et_i, et_tx[(et_b + 2) % 3], et_ty[(et_b + 2) % 3]);
            gpu_c_tex(4'd5, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
            gpu_c_uv($random(gpu_seed), $random(gpu_seed));
            gpu_c_step(et_srnd(3000), et_srnd(3000));
            gpu_c_step_row(et_srnd(3000), et_srnd(3000));
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_c_tritex;
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
            gpu_check_touched("wide triangle");
         end
         $display("--- a sliver 4 096 rows tall: apex at y = -2048, horizontal bottom edge at y = 2047.94");
         // 1 bpp, a 32-pixel pitch (one word a row), y = -2048 at word 10 000
         gpu_c_dst_xy(16'd32, 32 * (10000 + 2048) + 16);
         gpu_c_noclip;
         for (et_k = 0; et_k < 2; et_k = et_k + 1) begin
            gpu_c_vtx(0, 0, -32768);
            gpu_c_vtx(1 + et_k, -16 * 2, 32767);
            gpu_c_vtx(2 - et_k,  16 * 2, 32767);
            gpu_c_fill($random(gpu_seed));
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_c_trifill(4'd0);
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
            gpu_check_touched("4 096-row sliver");
         end
      end
      gpu_check_all("gpu_ext_tex end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
