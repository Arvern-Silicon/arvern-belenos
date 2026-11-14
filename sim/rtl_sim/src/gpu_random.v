//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_random
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_random.v
// Module Description : Seeded random rectangles: random GFX_MODE (0..7),
//                      DISP_WIDTH, command (FILL / COPY / COPY_TRANSP), PX_OP,
//                      DST and SRC swaps, size, pitches (incl. 0 = DISP_WIDTH
//                      and occasionally a pitch shorter than the row), sub-word
//                      bases (start corner), fill / transparent colours (often
//                      a colour present in a palette-drawn source), state
//                      re-use with a single EXEC word, and batches of up to 4
//                      rectangles queued behind each other (FREE checked
//                      before each push). After each batch every touched word
//                      is read through the VRAM window and compared with the
//                      reference model; at the end the whole VRAM is compared
//                      and GPU_OVFL / GPU_ERR must never have been raised.
//                      About one batch in four is not pushed but written as a
//                      command list through the VRAM window and started by a
//                      CALL (own seed stream: the rectangles of a seed do not
//                      depend on it). The reserved bits of the copies, the
//                      remap and mask-plane SET_AUX words and SET_EXT2 are set
//                      at random (own seed): they must be ignored.
//                      With VRAM_WORDS >= 38400, about one iteration in four
//                      is followed by 1-3 rectangles of the newer kinds in
//                      x/y mode under a random clip window (FILL / COPY /
//                      COPY_TRANSP, gradient FILL / SPAN, TEXRECT with or
//                      without BOUND) in words [34000, 38300), drawn from a
//                      third seed stream: the rectangles above stay those
//                      of the seed; the gradient, clip and x/y mode are
//                      switched off afterwards.
//                      With the palette remap or the mask plane built
//                      (BLNS_CFG2), about one iteration in three is followed
//                      by 1-4 FILL / COPY / COPY_TRANSP queued back to back
//                      with random REMAP modes, tables, MPLANE, INV, mask bit
//                      offsets and swaps (mirrors included), in words
//                      [16000, 19900), from a fourth seed stream.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer TR_ITER    = 60;
localparam integer TR_LIST_LO = 16;             // command lists: words [16, 64)

integer    tr_it, tr_b, tr_nb, tr_bl, tr_ppw, tr_rows, tr_cols, tr_x0, tr_y0;
integer    tr_w, tr_h, tr_sp, tr_dp, tr_spe, tr_dpe, tr_r;
reg  [2:0] tr_mode, tr_dsw, tr_ssw;
reg  [3:0] tr_cmd, tr_op;
reg [31:0] tr_sorg, tr_dorg, tr_sbase, tr_dbase, tr_pix;
integer    tr_npx;
integer    tr_lseed, tr_nl, tr_k;
reg        tr_list;
reg [23:0] tr_n24;

// Newer kinds (x/y + clip, gradient, TEXRECT): own seed stream and VRAM area
localparam integer TN_EN     = ((VRAM_WORDS >= 38400) && (GPU_XY_EN != 0)) ? 1 : 0;
localparam integer TN_SRC_LO = 34000;           // sources / textures: words [34000, 34800)
localparam integer TN_SRC_HI = 34800;
localparam integer TN_DST_LO = 34900;           // x/y surface: words [34900, 38300)
localparam integer TN_DST_HI = 38300;
localparam integer TN_P      = 64;              // surface pitch
localparam integer TN_WMAX   = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
integer    tn_seed, tn_nx, tn_npx;

// Remap and mask plane: own seed stream and VRAM area
localparam integer TX_SRC_LO = 16000;           // sources: words [16000, 17500)
localparam integer TX_SRC_HI = 17500;
localparam integer TX_MSK_LO = 17500;           // mask plane: words [17500, 17700)
localparam integer TX_MSK_HI = 17700;
localparam integer TX_TAB_LO = 17728;           // four tables: words [17728, 17984)
localparam integer TX_DST_LO = 18000;           // destinations: words [18000, 19900)
localparam integer TX_P      = 64;
localparam integer TX_WMAX   = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
integer    tx_seed, tx_nx, tx_ncmd;
reg [31:0] tx_caps;

function integer tx_rnd;                        // uniform in [0, n), remap / mask stream
   input integer n;
   begin
      tx_rnd = (n <= 1) ? 0 : (($random(tx_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task tx_extra;
   integer    kk, nr, ppw, bl, w, h, x0, y0, rr;
   reg [31:0] v, sorg, dorg, sb, db;
   reg  [3:0] cmd, op;
   reg  [2:0] dsw, ssw;
   begin
      bl   = gpu_bl(tr_mode);
      ppw  = 32 >> bl;
      for (kk = TX_SRC_LO; kk < TX_TAB_LO + 256; kk = kk + 1) begin   // GPU idle here
         v              = $random(tx_seed);
         vram_mem[kk]   = v;
         gpu_shadow[kk] = v;
      end
      nr   = 1 + tx_rnd(4);
      sorg = TX_SRC_LO * ppw + tx_rnd(ppw);
      dorg = TX_DST_LO * ppw + tx_rnd(ppw);
      $display("       + %0d remap / mask-plane rectangle(s)", nr);
      for (kk = 0; kk < nr; kk = kk + 1) begin
         rr  = tx_rnd(4);
         cmd = (rr == 0) ? GPU_FILL : (rr == 1) ? GPU_COPYT : GPU_COPY;
         op  = tx_rnd(2) ? 4'd0 : tx_rnd(16);
         dsw = tx_rnd(8);
         ssw = (tx_rnd(3) == 0) ? (dsw ^ 3'b100) : tx_rnd(4) ? dsw : tx_rnd(8);   // mirrors now and then
         w   = 1 + tx_rnd(TX_WMAX);
         h   = 1 + tx_rnd(4);
         x0  = tx_rnd(16);
         y0  = tx_rnd(4);
         sb  = tr_corner(sorg, TX_P, x0, y0, ssw, w, h);
         db  = tr_corner(dorg, TX_P, x0, y0, dsw, w, h);
         gpu_c_size(w, h);
         gpu_c_src(TX_P, sb);
         gpu_c_dst(TX_P, db);
         gpu_c_fill($random(tx_seed));
         if (tx_rnd(2)) gpu_c_transp(gpu_get_px(sb, bl));
         else           gpu_c_transp($random(tx_seed));
         gpu_k_rmp = 2'd0;
         gpu_k_mpl = 1'b0;
         if (tx_caps[0] && tx_rnd(4)) begin
            gpu_k_rmp = 1 + tx_rnd(2);
            gpu_c_remap_table(TX_TAB_LO + 64 * tx_rnd(4));
         end
         if (tx_caps[1] && (cmd != GPU_FILL) && tx_rnd(2)) begin
            gpu_k_mpl = 1'b1;
            gpu_c_mask_plane(TX_MSK_LO * 32 + (sb - sorg) + tx_rnd(32), tx_rnd(2));
         end
         $display("         %0s op %0d %0dx%0d swaps %b -> %b REMAP %0d%0s",
                  (cmd == GPU_FILL) ? "FILL" : (cmd == GPU_COPY) ? "COPY" : "COPY_TRANSP", op, w, h,
                  ssw, dsw, gpu_k_rmp, gpu_k_mpl ? (gpu_m_minv ? " MPLANE INV" : " MPLANE") : "");
         gpu_c_exec(cmd, op, dsw, ssw);
         gpu_k_rmp = 2'd0;
         gpu_k_mpl = 1'b0;
         tx_ncmd   = tx_ncmd + 1;
      end
      gpu_wait_idle;
      gpu_check_touched("random remap / mask");
      tx_nx = tx_nx + 1;
   end
endtask

function integer tn_rnd;                        // uniform in [0, n), new-kind stream
   input integer n;
   begin
      tn_rnd = (n <= 1) ? 0 : (($random(tn_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task tn_extra;
   integer    kind, nr, kk, ppw, bl, w, h, lw, lh;
   reg [31:0] v, org, sb;
   reg  [3:0] cmd, op;
   reg  [2:0] sw;
   reg        bnd;
   begin
      bl   = gpu_bl(tr_mode);
      ppw  = 32 >> bl;
      gpu_rgn_slo = TN_SRC_LO;
      gpu_rgn_shi = TN_SRC_HI;
      gpu_rgn_dlo = TN_DST_LO;
      gpu_rgn_dhi = TN_DST_HI;
      for (kk = TN_SRC_LO; kk < TN_SRC_HI; kk = kk + 1) begin    // GPU idle here
         v              = $random(tn_seed);
         vram_mem[kk]   = v;
         gpu_shadow[kk] = v;
      end
      org  = (TN_DST_LO + 40) * ppw + 4 * TN_P + tn_rnd(ppw);
      kind = tn_rnd(3);
      if ((kind == 1) && (GPU_GRAD_EN == 0))   kind = 0;            // absent features: x/y kind
      if ((kind == 2) && (GPU_XY_EN == 0))     kind = 0;
      nr   = 1 + tn_rnd(3);
      gpu_c_dst_xy(TN_P, org);
      gpu_c_clip(tn_rnd(8), tn_rnd(4), 30 + tn_rnd(10), 10 + tn_rnd(6));   // inside the surface
      $display("       + %0d new-kind rectangle(s): %0s, clip (%0d,%0d)-(%0d,%0d)", nr,
               (kind == 0) ? "x/y FILL/COPY/COPY_TRANSP" : (kind == 1) ? "gradient FILL/SPAN" : "TEXRECT",
               gpu_m_cx0, gpu_m_cy0, gpu_m_cx1, gpu_m_cy1);
      for (kk = 0; kk < nr; kk = kk + 1) begin
         w  = 1 + tn_rnd(TN_WMAX);
         h  = 1 + tn_rnd(TN_WMAX);
         sw = tn_rnd(8);
         gpu_c_size(w, h);
         gpu_c_xy(-6 + tn_rnd(52), -4 + tn_rnd(24));
         gpu_c_fill($random(tn_seed));
         case (kind)
           0 : begin
                  sb  = (TN_SRC_LO + 8) * ppw + 13 * 32 + 13;
                  cmd = (tn_rnd(3) == 0) ? GPU_FILL : tn_rnd(2) ? GPU_COPY : GPU_COPYT;
                  op  = tn_rnd(16);
                  gpu_c_src(16'd32, sb);
                  if (tn_rnd(2)) gpu_c_transp(gpu_get_px(sb, bl));
                  else           gpu_c_transp($random(tn_seed));
                  gpu_c_exec_xy(cmd, op, sw, tn_rnd(8));
               end
           1 : begin
                  gpu_c_grad(tn_rnd(6), tn_rnd(2), tn_rnd(16) - 8, 1'b1);
                  if (tn_rnd(3) == 0) gpu_c_span(tn_rnd(9) - 4, w);
                  else                gpu_c_exec_xy(GPU_FILL, tn_rnd(13), sw, 3'b000);
               end
           default : begin
                  lw  = tn_rnd(5);
                  lh  = tn_rnd(5);
                  bnd = tn_rnd(2);
                  gpu_c_src(16'd0, (TN_SRC_LO + 8) * ppw + tn_rnd(ppw));
                  gpu_c_transp($random(tn_seed));
                  gpu_c_tex(lw, lh, tn_rnd(2), sw, 1'b0, bnd, $random(tn_seed));
                  gpu_c_texbox(1 + tn_rnd(1 << lw), 1 + tn_rnd(1 << lh));
                  gpu_c_step(tn_rnd(8193) - 4096, tn_rnd(8193) - 4096);      // +-2 texels
                  gpu_c_step_row(tn_rnd(8193) - 4096, tn_rnd(8193) - 4096);
                  if (bnd) gpu_c_uv(((tn_rnd(41) - 20) << 6) | tn_rnd(64), ((tn_rnd(41) - 20) << 6) | tn_rnd(64));
                  else     gpu_c_uv($random(tn_seed), $random(tn_seed));
                  gpu_c_texrect(tn_rnd(5) - 2);
               end
         endcase
         tn_npx = tn_npx + w * h;
      end
      if (GPU_GRAD_EN != 0) gpu_c_grad(0, 1'b0, 0, 1'b0);
      gpu_c_noclip;
      gpu_wait_idle;
      gpu_check_touched("random new kinds");
      gpu_rgn_slo = 0;
      gpu_rgn_shi = VRAM_WORDS;
      gpu_rgn_dlo = 0;
      gpu_rgn_dhi = VRAM_WORDS;
      tn_nx = tn_nx + 1;
   end
endtask

function [31:0] tr_corner;
   input [31:0] org;
   input integer pitch;
   input integer x0;
   input integer y0;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows = sw[0] ? w : h;
      cols = sw[0] ? h : w;
      tr_corner = org + (y0 + (sw[1] ? rows - 1 : 0)) * pitch + x0 + (sw[2] ? cols - 1 : 0);
   end
endfunction

function integer tr_pitch;              // random pitch for a surface
   input integer minp;
   integer      r;
   begin
      r = $random(gpu_seed) & 15;
      if (r < 3)       tr_pitch = 0;                                  // DISP_WIDTH
      else if (r == 3) tr_pitch = 1 + ($random(gpu_seed) & 7);        // overlapping rows
      else             tr_pitch = minp + ($random(gpu_seed) & 127);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: seeded random rectangles          |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;                   // reserved / ignored command bits set at random
      gpu_rsv_seed = `SEED ^ 32'h5EED_0BAD;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tr_npx = 0;
      tr_lseed = `SEED ^ 32'h1D57_CA11;
      tr_nl    = 0;
      tn_seed  = `SEED ^ 32'h7E57_C11B;
      tn_nx    = 0;
      tn_npx   = 0;
      tx_seed  = `SEED ^ 32'h4E3A_9A11;
      tx_nx    = 0;
      tx_ncmd  = 0;
      reg_rd_val(BLNS_CFG2, tx_caps);
      tx_caps = tx_caps >> 8;                                        // [0] REMAP, [1] MPLANE

      for (tr_it = 0; tr_it < TR_ITER; tr_it = tr_it + 1) begin
         tr_mode = $random(gpu_seed);
         tr_bl   = gpu_bl(tr_mode);
         tr_ppw  = 32 >> tr_bl;
         gpu_set_mode(tr_mode);
         gpu_set_dispw(8 + ($random(gpu_seed) & 255));
         tr_nb = 1 + ($random(gpu_seed) & 3);
         tr_list = (($random(tr_lseed) & 3) == 0);
         $display("--- iteration %0d: mode %0d, DISP_WIDTH %0d, %0d rectangle(s)%0s", tr_it, tr_mode, gpu_m_dispw, tr_nb,
                  tr_list ? " in a CALL list" : "");
         if (tr_list) begin
            gpu_cap_n  = 0;
            gpu_cap_en = 1'b1;
         end
         for (tr_b = 0; tr_b < tr_nb; tr_b = tr_b + 1) begin
            tr_r = $random(gpu_seed) & 7;
            if ((tr_r != 0) || (tr_b == 0) || (tr_it == 0)) begin     // new state (else: re-exec)
               tr_w   = 1 + ($random(gpu_seed) % 12); if (tr_w < 1) tr_w = -tr_w + 1;
               tr_h   = 1 + ($random(gpu_seed) % 8);  if (tr_h < 1) tr_h = -tr_h + 1;
               tr_dsw = $random(gpu_seed);
               tr_ssw = $random(gpu_seed);
               tr_sp  = tr_pitch(16);
               tr_dp  = tr_pitch(16);
               tr_spe = (tr_sp == 0) ? gpu_m_dispw : tr_sp;
               tr_dpe = (tr_dp == 0) ? gpu_m_dispw : tr_dp;
               // surfaces: source in words [1000, 15000), destination in [20000, 37000)
               if (tr_b == 0)                                        // backdoor preload only while idle
                  tr_sorg = (1000 + ($random(gpu_seed) & 4095)) * tr_ppw + ($random(gpu_seed) & (tr_ppw - 1));
               tr_dorg = (20000 + ($random(gpu_seed) & 4095)) * tr_ppw + ($random(gpu_seed) & (tr_ppw - 1)) + 4 * tr_b * tr_ppw * 600;
               tr_x0   = $random(gpu_seed) & 15;
               tr_y0   = $random(gpu_seed) & 3;
               tr_sbase = tr_corner(tr_sorg, tr_spe, tr_x0, tr_y0, tr_ssw, tr_w, tr_h);
               tr_dbase = tr_corner(tr_dorg, tr_dpe, tr_x0, tr_y0, tr_dsw, tr_w, tr_h);
               if (($random(gpu_seed) & 1) && (tr_b == 0))
                  gpu_preload_pal(gpu_word_of(tr_sorg, tr_bl), gpu_word_of(tr_sorg, tr_bl) + (20 * tr_spe + 40) / tr_ppw + 2,
                                  tr_bl, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
               gpu_c_src(tr_sp, tr_sbase);
               gpu_c_dst(tr_dp, tr_dbase);
               gpu_c_size(tr_w, tr_h);
               gpu_c_fill($random(gpu_seed));
               tr_pix = gpu_get_px(tr_sbase, tr_bl);
               if ($random(gpu_seed) & 1) gpu_c_transp({$random(gpu_seed)} << 16 | tr_pix);
               else                       gpu_c_transp($random(gpu_seed));
            end
            tr_r   = $random(gpu_seed) & 3;
            tr_cmd = (tr_r == 0) ? GPU_FILL : (tr_r == 1) ? GPU_COPY : GPU_COPYT;
            tr_op  = $random(gpu_seed);
            tr_dsw = (($random(gpu_seed) & 3) == 0) ? $random(gpu_seed) : tr_dsw;
            if (tr_dsw != gpu_x_dsw) begin
               // swaps changed without a new base: recompute the corner
               tr_dbase = tr_corner(tr_dorg, tr_dpe, tr_x0, tr_y0, tr_dsw, gpu_m_w, gpu_m_h);
               gpu_c_dst(tr_dp, tr_dbase);
            end
            $display("       %0s op %0d %0dx%0d dst sw %b pitch %0d base 0x%h, src sw %b pitch %0d base 0x%h",
                     (tr_cmd == GPU_FILL) ? "FILL" : (tr_cmd == GPU_COPY) ? "COPY" : "COPY_TRANSP", tr_op,
                     gpu_m_w, gpu_m_h, tr_dsw, gpu_m_dst_pitch, gpu_m_dst_base, tr_ssw, gpu_m_src_pitch, gpu_m_src_base);
            gpu_c_exec(tr_cmd, tr_op, tr_dsw, tr_ssw);
            tr_npx = tr_npx + gpu_m_w * gpu_m_h;
         end
         if (tr_list) begin
            gpu_cap_en = 1'b0;
            for (tr_k = 0; tr_k < gpu_cap_n; tr_k = tr_k + 1) begin
               vram_wr(4 * (TR_LIST_LO + tr_k), gpu_cap_buf[tr_k], SZ_W);
               gpu_shadow[TR_LIST_LO + tr_k] = gpu_cap_buf[tr_k];
            end
            tr_n24 = gpu_cap_n;
            gpu_push({OP_CALL, 4'h0, tr_n24});
            gpu_push(TR_LIST_LO);
            tr_nl = tr_nl + 1;
         end
         gpu_wait_idle;
         gpu_check_touched("random batch");
         if (TN_EN && (($random(tn_seed) & 3) == 0))
            tn_extra;
         if ((tx_caps[1:0] != 2'b00) && (tx_rnd(3) == 0))
            tx_extra;
      end

      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
      $display("       %0d pixels in total, %0d batches through CALL lists, %0d new-kind groups (%0d pixels), %0d remap / mask groups (%0d rectangles)",
               tr_npx, tr_nl, tn_nx, tn_npx, tx_nx, tx_ncmd);
      reg_rd(GPU_LIST, 32'h0);
      gpu_check_all("random end");
      $display("INFO:  %0d command words pushed with reserved bits set", gpu_rsv_n);
      if (gpu_rsv_n == 0) tb_error("no reserved bit was ever set (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
