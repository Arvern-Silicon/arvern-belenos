//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_ext_hilo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_ext_hilo.v
// Module Description : GPU address paths from the top of the VRAM back to
//                      the bottom: the same work is drawn first in a region
//                      at the top of the VRAM, then in a region at word 0,
//                      so that every high address bit (sources, textures,
//                      remap table, mask plane, command list, destinations,
//                      the walkers and the read-ahead entries) rises and
//                      falls again. Per region: FILL, COPY with a remap
//                      table and a mask plane, COPY_TRANSP, EXPAND, TEXSPAN /
//                      TEXRECT, a command list and a line (pitches up to
//                      65 535 pixels), at 1, 8 and 16 bpp, and at 16 bpp an
//                      RGB565A8 and a bilinear TEXRECT (blending, bilinear
//                      builds) from the region's last words; the
//                      top pass ends with a FILL on the last VRAM word and
//                      FILL / COPY addresses past 2^VRAM_AW words (cause 5).
//                      Checked against the model (touched words through the
//                      VRAM window, then both regions through the backdoor).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer HL_SZ  = 16384;                   // region size in words
localparam integer HL_SRC = 1024;                    // sources, textures: [+1024, +5632)
localparam integer HL_MSK = 6144;                    // mask plane: [+6144, +6400)
localparam integer HL_RMP = 6656;                    // remap table (a multiple of 64)
localparam integer HL_LST = 7168;                    // command list: [+7168, +8192)
localparam integer HL_DST = 8192;                    // destinations: [+8192, +16384)

integer    hl_k, hl_i, hl_mode, hl_bl, hl_nbad, hl_pass, hl_b, hl_t;
reg [31:0] hl_caps;

function integer hl_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      hl_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] hl_px;                   // a pixel of word w at the current depth
   input integer w;
   begin
      hl_px = (w << (5 - hl_bl)) + hl_rnd(32 >> hl_bl);
   end
endfunction

task hl_check_rgn;                       // a region through the backdoor
   input integer    lo;
   input integer    hi;
   input [8*40-1:0] label;
   integer          ww;
   begin
      hl_nbad = 0;
      tb_checks = tb_checks + 1;
      for (ww = lo; ww < hi; ww = ww + 1)
         if (vram_mem[ww] !== gpu_shadow[ww]) begin
            hl_nbad = hl_nbad + 1;
            if (hl_nbad <= 6)
               $display("ERROR: GPU %0s -- backdoor word 0x%h = 0x%h / expected 0x%h %t",
                        label, ww, vram_mem[ww], gpu_shadow[ww], $time);
         end
      error = error + hl_nbad;
      if (hl_nbad == 0) $display("OK:    GPU %0s -- the region matches the model", label);
   end
endtask

// One 1 x 1 FILL (c = 0: destination) or COPY (c = 1: source) at word
// 2^VRAM_AW + 50, raw commands (the model rejects such an address): cause 5,
// nothing written; the "past 2^VRAM_AW" bit of the word addresses rises
task hl_alias;
   input integer m;                      // GFX_MODE 1..4 (2..16 bpp)
   input integer c;
   reg    [31:0] pa, w50, w200;
   begin
      gpu_set_mode(m);
      gpu_wait_idle;
      pa   = ((1 << VRAM_AW) + 50) * (32 >> m);
      w50  = vram_mem[50];
      w200 = vram_mem[200];
      gpu_push({OP_SET_SIZE, 14'd1, 14'd1});
      if (c == 0) begin
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(pa);
         gpu_push({OP_SET_FILL, 28'h0});
         gpu_push(32'hBEEF_BEEF);
         gpu_push({OP_EXEC_FILL, 28'h0});
      end else begin
         gpu_push({OP_SET_SRC, 12'h000, 16'd0});
         gpu_push(pa);
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(200 * (32 >> m));
         gpu_push({OP_EXEC_COPY, 28'h0});
      end
      reg_poll(GPU_STAT, GS_ERR, GS_ERR, 100);
      reg_rd_mask(GPU_STAT, {(c == 0) ? OP_EXEC_FILL : OP_EXEC_COPY, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
      repeat(20) @(posedge free_clk);
      tb_checks = tb_checks + 1;
      if ((vram_mem[50] !== w50) || (vram_mem[200] !== w200)) begin
         $display("ERROR: mode %0d %s past 2^VRAM_AW words: word 50 0x%h (was 0x%h), word 200 0x%h (was 0x%h) %t",
                  m, (c == 0) ? "FILL" : "COPY", vram_mem[50], w50, vram_mem[200], w200, $time);
         error = error + 1;
      end
      reg_wr(GPU_CTRL, 32'h1);                             // CLEAR_ERR
   end
endtask

// One pass of work in the region [b, b + HL_SZ)
task hl_region;
   input integer b;
   begin
      for (hl_k = 0; hl_k < 24; hl_k = hl_k + 1) begin
         hl_mode = (hl_k % 3 == 0) ? 0 : (hl_k % 3 == 1) ? 3 : 4;
         hl_bl   = gpu_bl(hl_mode);
         gpu_set_mode(hl_mode);
         $display("--- region 0x%h, %0d bpp, case %0d", b, 1 << hl_bl, hl_k / 3);
         gpu_c_size(4 + hl_rnd(12), 1 + hl_rnd(6));
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         gpu_c_src_fmt(16'd64 + hl_rnd(64), hl_px(b + HL_SRC + hl_rnd(4096)), 4'h0);
         if ((GPU_XY_EN != 0) && hl_rnd(2)) begin
            gpu_c_dst_xy(16'd128, hl_px(b + HL_DST + hl_rnd(5000)));
            gpu_c_xy(hl_rnd(40), hl_rnd(10));
            gpu_c_noclip;
         end else
            gpu_c_dst(16'd100 + hl_rnd(100), hl_px(b + HL_DST + hl_rnd(5000)));
         case (hl_k / 3)
           0: gpu_c_exec_xy(GPU_FILL, hl_rnd(16), hl_rnd(8), 3'b000);
           1: begin
                 gpu_k_rmp = (hl_caps[0] && (hl_bl < 4)) ? 2'd1 + hl_rnd(2) : 2'd0;
                 if (gpu_k_rmp != 2'd0) gpu_c_remap_table(b + HL_RMP);
                 gpu_k_mpl = hl_caps[1];
                 if (gpu_k_mpl) gpu_c_mask_plane(32 * (b + HL_MSK) + 2048 + hl_rnd(256), hl_rnd(2));
                 gpu_c_exec_xy(GPU_COPY, hl_rnd(13), hl_rnd(8), hl_rnd(8));
                 gpu_k_rmp = 2'd0;
                 gpu_k_mpl = 1'b0;
              end
           2: gpu_c_exec_xy(GPU_COPYT, hl_rnd(13), hl_rnd(8), hl_rnd(8));
           3: begin
                 gpu_c_src_fmt(16'd0, (b + HL_SRC + hl_rnd(4096)) << 5, 4'd1);
                 gpu_c_expand(0, hl_rnd(8), hl_rnd(2), 2'd0);
              end
           4: begin
                 gpu_c_tex(4'd5, 4'd4, hl_rnd(2), hl_rnd(8), 1'b0, 1'b0, 8'h00);
                 gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                 gpu_c_step(hl_rnd(4000) - 2000, hl_rnd(4000) - 2000);
                 if (gpu_m_xy) begin
                    gpu_c_step_row(hl_rnd(4000) - 2000, hl_rnd(4000) - 2000);
                    gpu_c_texrect(0);
                 end else
                    gpu_c_texspan(0, 14'd20);
              end
           6: if ((GPU_LINE_EN != 0) && (GPU_XY_EN != 0)) begin   // a line, a pitch up to 2 048 words
                 gpu_c_dst_xy(16'd1024 + hl_rnd(2048 * (32 >> hl_bl) - 1025), hl_px(b + HL_DST + hl_rnd(500)));
                 gpu_c_noclip;
                 gpu_c_pen(16 * hl_rnd(30) + 8, 16 * hl_rnd(3) + 8);
                 gpu_c_line(16 * hl_rnd(40) + 8, 16 * hl_rnd(3) + 8, hl_rnd(16),
                            ((GPU_BLEND_EN != 0) && (hl_mode == 4) && hl_rnd(2)) ? 4'b0001 : 4'b0000);
              end else
                 gpu_c_exec_xy(GPU_FILL, hl_rnd(16), hl_rnd(8), 3'b000);
           7: if ((hl_mode == 4) && (GPU_XY_EN != 0) && ((GPU_BLEND_EN != 0) || (GPU_BILINEAR_EN != 0))) begin
                 // an RGB565A8 and / or bilinear TEXRECT: the texture in
                 // the source area or in [+HL_SZ - 2 112, +HL_SZ - 576), its
                 // alpha plane in the region's last 576 words (the A8,
                 // tap-cache and alpha read-ahead word addresses at the top
                 // of the VRAM)
                 for (hl_i = 0; hl_i < 4; hl_i = hl_i + 1) begin   // both texture places, twice
                    hl_t = hl_i[0] ? (b + HL_SZ - 1600 - hl_rnd(512)) : (b + HL_SRC + hl_rnd(3000));
                    gpu_c_dst_xy(16'd100, hl_px(b + HL_DST + hl_rnd(2500)));
                    gpu_c_xy(hl_rnd(40), hl_rnd(4));
                    gpu_c_noclip;
                    gpu_c_src_fmt(16'd64 + hl_rnd(64), 2 * hl_t + hl_rnd(2), 4'h0);
                    gpu_k_a8 = (GPU_BLEND_EN != 0) && hl_rnd(2);
                    if (gpu_k_a8) begin
                       gpu_c_alpha_plane(4 * (b + HL_SZ - 576) + hl_rnd(64));
                       gpu_c_alpha5(1'b0, 8'hFF, hl_rnd(2));
                    end
                    if (GPU_BILINEAR_EN != 0) gpu_c_tex_filter(hl_rnd(4) != 0, 1'b0);
                    // (32 x 16, power of two: the rows wrap inside it)
                    gpu_c_tex(4'd5, 4'd4, 1'b0, hl_rnd(8), 1'b0, 1'b0, 8'h00);
                    gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                    gpu_c_step(hl_rnd(4000) - 2000, hl_rnd(4000) - 2000);
                    gpu_c_step_row(hl_rnd(4000) - 2000, hl_rnd(4000) - 2000);
                    gpu_c_texrect(0);
                    if (GPU_BILINEAR_EN != 0) gpu_c_tex_filter(1'b0, 1'b0);
                    if (gpu_k_a8) gpu_c_alpha5(1'b0, 8'h00, 1'b0);
                    gpu_k_a8 = 1'b0;
                    gpu_wait_idle;
                    gpu_check_touched("region RGB565A8 / bilinear");
                 end
              end else
                 gpu_c_exec_xy(GPU_FILL, hl_rnd(16), hl_rnd(8), 3'b000);
           default: begin                                        // a command list in the region
                 gpu_wait_idle;
                 gpu_cap_n  = 0;
                 gpu_cap_en = 1'b1;
                 for (hl_i = 0; hl_i < 6; hl_i = hl_i + 1) begin
                    gpu_c_dst(16'd90, hl_px(b + HL_DST + hl_rnd(5000)));
                    gpu_c_size(1 + hl_rnd(8), 1 + hl_rnd(4));
                    gpu_c_fill($random(gpu_seed));
                    gpu_c_exec(hl_rnd(2) ? GPU_FILL : GPU_COPY, hl_rnd(13), hl_rnd(8), 3'b000);
                 end
                 gpu_cap_en = 1'b0;
                 for (hl_i = 0; hl_i < gpu_cap_n; hl_i = hl_i + 1) begin
                    vram_mem[b + HL_LST + hl_i]   = gpu_cap_buf[hl_i];
                    gpu_shadow[b + HL_LST + hl_i] = gpu_cap_buf[hl_i];
                 end
                 gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
                 gpu_push(b + HL_LST);
              end
         endcase
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("region pass");
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: top of the VRAM, then back to word 0    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 2 * HL_SZ)
         tb_skip_finish("|      (VRAM below 32 K words: no high region)  |");
      gpu_seed = `SEED;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;
      gpu_preload_rand(0, HL_SZ);
      gpu_preload_rand(VRAM_WORDS - HL_SZ, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      reg_rd_val(BLNS_CFG2, hl_caps);
      hl_caps = (hl_caps >> 8) & 32'h3;                          // [0] REMAP, [1] MPLANE
      // the top region: its base keeps the remap table a multiple of 64 words
      hl_b = ((VRAM_WORDS - HL_SZ) / 64) * 64;
      hl_region(hl_b);
      $display("--- a FILL ending on the last VRAM word");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 2 * VRAM_WORDS - 64 * 3 - 8);
      gpu_c_size(14'd8, 14'd4);
      gpu_c_fill(32'h0000_5EED);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("last VRAM word");
      hl_check_rgn(hl_b, VRAM_WORDS, "top region");
      $display("--- pixel addresses past 2^VRAM_AW words at 2..16 bpp");
      for (hl_k = 1; hl_k <= 4; hl_k = hl_k + 1)
         for (hl_i = 0; hl_i < 2; hl_i = hl_i + 1)
            hl_alias(hl_k, hl_i);
      // the same work at the bottom: every high bit falls again
      hl_region(0);
      hl_check_rgn(0, HL_SZ, "bottom region");
      hl_check_rgn(hl_b, VRAM_WORDS, "top region after the bottom pass");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
