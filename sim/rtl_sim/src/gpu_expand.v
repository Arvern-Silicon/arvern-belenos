//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_expand
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_expand.v
// Module Description : EXEC_EXPAND (opcode 0xC): colour-expand copy of the
//                      SET_SIZE rectangle from a source read at SRC_DEPTH
//                      (1/2/4/8 bpp, pitch 0 = width) to the
//                      destination at GFX_MODE, after destination base +=
//                      DELTA. Source value 0 skipped or, with OPAQUE, the
//                      TRANSP colour; v >= 1 writes fill + v - 1 (low bpp
//                      bits). Every SRC_DEPTH x GFX_MODE 0..4 with OPAQUE
//                      off/on, the eight destination swap codes, source pitch
//                      0 / explicit, destination pitch explicit / 0, sub-word
//                      bases, fill near the top of the range, TRANSP with the
//                      upper bits set; text-like DELTA chains (+w, carriage
//                      returns down and up, X-swapped right-to-left); DELTA
//                      +8191 / -8192 (or the largest that fits the VRAM);
//                      state left behind (moved base, size, SRC, FILL, TRANSP
//                      seen by EXEC_FILL / COPY / COPY_TRANSP); op and source
//                      swaps of earlier EXECs do not leak; GPU_DONE per
//                      expand (flag and irq_o); no ERR; FREE-paced glyph
//                      bursts; pixel-address wrap when VRAM_WORDS = 2^VRAM_AW;
//                      the raster op of [11:8] (every op, 1 and 4 bpp).
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TE_DPITCH = 29;
localparam integer TE_DISPW  = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer TE_WMAX   = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer TE_SRC_LO = 40;               // source words [TE_SRC_LO, TE_SRC_HI)
localparam integer TE_SRC_HI = 280;
localparam integer TE_DST_LO = 300;              // matrix destination words
localparam integer TE_DST_HI = 990;

integer    te_rop;
integer    te_s, te_sbl, te_sppw, te_mode, te_bl, te_ppw, te_c, te_op, te_i, te_k, te_r, te_n;
integer    te_w, te_h, te_lh, te_p, te_d, te_delta, te_px, te_lo, te_cur, te_tgt;
integer    te_skipped, te_bgwr;
reg [31:0] te_pm, te_fill, te_transp, te_sb, te_d0, te_font, te_b, te_x;
reg [15:0] te_sp, te_pp;
reg  [2:0] te_dsw;

// Push one EXEC_EXPAND and model it
task te_exp;
   input integer delta;
   input   [2:0] dsw;                    // {X, Y, CL}
   input         opaque;
   input   [1:0] sdep;
   reg    [13:0] d14;
   reg    [31:0] spa, dpa, vv, pm, ee;
   integer       kk, sbl, spitch;
   begin
      d14 = delta;
      gpu_src_fmt({2'b00, sdep} + 4'd1);                 // SRC_FMT 1-4 = 1/2/4/8 bpp
      gpu_push({OP_EXEC_EXP, d14, 2'b00, gpu_exp_op, 1'b0, dsw, 1'b0, opaque, 2'b00});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_x_setup(GPU_FILL, 4'd0, dsw, 3'b000);
      sbl    = sdep;                              // 0..3 = 1, 2, 4, 8 bpp
      spitch = (gpu_m_src_pitch == 16'h0) ? gpu_x_w : gpu_m_src_pitch;
      pm     = gpu_pmask(gpu_x_bl);
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         spa = (gpu_x_sbase + (kk / gpu_x_w) * spitch + (kk % gpu_x_w)) & GPU_PA_MASK;
         vv  = gpu_get_px(spa, sbl);
         dpa = gpu_walk(gpu_x_dbase, gpu_x_dpitch, dsw, gpu_x_w, kk);
         gpu_touch_px(dpa, gpu_x_bl);
         if ((vv !== 32'h0) || opaque) begin            // the raster op on the expanded colour
            ee = (vv !== 32'h0) ? (gpu_x_fill + vv - 32'h1) : gpu_x_transp;
            gpu_set_px(dpa, gpu_x_bl,
                       gpu_exp_rop(gpu_exp_op, ee & pm, gpu_get_px(dpa, gpu_x_bl), gpu_x_fill & pm) & pm);
            if (vv === 32'h0) te_bgwr = te_bgwr + 1;
         end
         else
            te_skipped = te_skipped + 1;
      end
   end
endtask

// Glyph g of a packed font (pitch 0) at te_font, te_w x te_h source pixels
task te_glyph;
   input integer g;
   begin
      gpu_c_src(16'd0, te_font + g * te_w * te_h);
   end
endtask

task te_check_irq;
   input exp;
   begin
      @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b %t", irq, exp, $time);
         error = error + 1;
      end else
         $display("OK:    irq_o = %b", irq);
   end
endtask

task te_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR | 32'hF000_0000);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

task te_check_base;
   input [31:0] exp;
   begin
      if (gpu_m_dst_base !== (exp & GPU_PA_MASK))
         tb_error("expand chain did not end at the expected base (test bug)");
   end
endtask

// Random colour with the bits above the destination depth set
function [31:0] te_hi_color;
   input [31:0] rnd;
   input [31:0] pm;
   begin
      te_hi_color = rnd | (~pm & 32'hFFFF) | 32'hA5A5_0000;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: EXEC_EXPAND                       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed   = `SEED;
      te_skipped = 0;
      te_bgwr    = 0;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(TE_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("--- SRC_DEPTH 0..3 x GFX_MODE 0..4, OPAQUE off/on, swaps, pitches");
      for (te_s = 0; te_s < 4; te_s = te_s + 1) begin
         te_sbl  = te_s;
         te_sppw = 32 >> te_sbl;
         for (te_mode = 0; te_mode < 5; te_mode = te_mode + 1) begin
            gpu_set_mode(te_mode);
            te_bl  = gpu_bl(te_mode);
            te_ppw = 32 >> te_bl;
            te_pm  = gpu_pmask(te_bl);
            te_c   = te_s * 5 + te_mode;
            if (te_c % 2)
               gpu_preload_pal(TE_SRC_LO, TE_SRC_HI, te_sbl, 16'h0, 16'h1, $random(gpu_seed), gpu_pmask(te_sbl));
            else
               gpu_preload_rand(TE_SRC_LO, TE_SRC_HI);
            te_w  = 1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % TE_WMAX);
            te_h  = 1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % 6);
            if (((te_c / 2) % 2) == 0)
               te_sp = 16'd0;                                       // packed: pitch = width
            else if ((te_c % 5) == 3)
               te_sp = 16'd117;
            else
               te_sp = te_w + ($random(gpu_seed) & 15);
            te_sb = 48 * te_sppw + ($random(gpu_seed) & (te_sppw - 1));
            gpu_c_src(te_sp, te_sb);
            gpu_c_size(te_w, te_h);
            for (te_op = 0; te_op < 2; te_op = te_op + 1) begin
               gpu_preload_rand(TE_DST_LO, TE_DST_HI);
               te_fill = $random(gpu_seed);
               if ((te_c % 4) >= 2)                                 // fill + v - 1 wraps
                  te_fill = (te_fill & ~te_pm) | ((te_pm - ($random(gpu_seed) & 3)) & te_pm);
               gpu_c_fill(te_fill);
               gpu_c_transp(te_hi_color($random(gpu_seed), te_pm));
               te_dsw   = (te_c + 3 * te_op) & 7;
               te_delta = ($random(gpu_seed) & 31) - 16;
               te_d0    = 640 * te_ppw + ($random(gpu_seed) & (te_ppw - 1));
               gpu_c_dst(((te_c % 3) == 1) ? 16'd0 : TE_DPITCH, te_d0 - te_delta);
               te_exp(te_delta, te_dsw, te_op, te_s);
               gpu_wait_idle;
               te_no_err;
               $display("       src %0d bpp (SRC_DEPTH %0d) -> mode %0d, %0dx%0d, spitch %0d, dpitch %0d, sw %b, opaque %0d, delta %0d",
                        1 << te_sbl, te_s, te_mode, te_w, te_h, te_sp,
                        ((te_c % 3) == 1) ? 0 : TE_DPITCH, te_dsw, te_op, te_delta);
               gpu_check_touched("expand matrix");
            end
         end
         gpu_check_all("expand matrix");
      end
      $display("       skipped pixels so far: %0d", te_skipped);

      //--------------------------------------------------------------
      $display("--- raster op [11:8]: every op, 1 and 4 bpp sources, modes 0..4, OPAQUE off/on");
      for (te_rop = 0; te_rop < 16; te_rop = te_rop + 1) begin
         te_mode = te_rop % 5;
         gpu_set_mode(te_mode);
         te_bl   = gpu_bl(te_mode);
         te_ppw  = 32 >> te_bl;
         te_pm   = gpu_pmask(te_bl);
         te_s    = (te_rop % 2) ? 2 : 0;                            // 4 bpp (prince) or 1 bpp (text)
         te_sbl  = te_s;
         te_sppw = 32 >> te_sbl;
         gpu_preload_rand(TE_SRC_LO, TE_SRC_HI);
         gpu_preload_rand(TE_DST_LO, TE_DST_HI);
         te_w = 1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % TE_WMAX);
         te_h = 1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % 6);
         gpu_c_src(16'd0, 48 * te_sppw + ($random(gpu_seed) & (te_sppw - 1)));
         gpu_c_size(te_w, te_h);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(te_hi_color($random(gpu_seed), te_pm));
         te_dsw = te_rop & 7;
         te_d0  = 640 * te_ppw + ($random(gpu_seed) & (te_ppw - 1));
         gpu_c_dst(TE_DPITCH, te_d0);
         gpu_exp_op = te_rop;
         te_exp(0, te_dsw, (te_rop / 8) % 2, te_s);
         gpu_exp_op = 4'd0;
         gpu_wait_idle;
         te_no_err;
         $display("       op %0d: src %0d bpp -> mode %0d, %0dx%0d, sw %b, opaque %0d",
                  te_rop, 1 << te_sbl, te_mode, te_w, te_h, te_dsw, (te_rop / 8) % 2);
         gpu_check_touched("expand raster op");
      end
      gpu_check_all("expand raster op");

      //--------------------------------------------------------------
      $display("--- text: DELTA chains, carriage returns, right-to-left");
      for (te_i = 0; te_i < 4; te_i = te_i + 1) begin
         te_mode = (te_i == 0) ? 0 : (te_i == 1) ? 2 : (te_i == 2) ? 3 : 4;
         te_s    = (te_i == 2) ? 1 : 0;
         gpu_set_mode(te_mode);
         te_bl   = gpu_bl(te_mode);
         te_ppw  = 32 >> te_bl;
         te_pm   = gpu_pmask(te_bl);
         te_sbl  = te_s;
         te_sppw = 32 >> te_sbl;
         te_w    = 6;
         te_h    = 7;
         te_lh   = te_h + 1;
         if (te_s == 1)
            gpu_preload_pal(TE_SRC_LO, TE_SRC_HI, 1, 16'h0, 16'h1, 16'h2, 16'h3);
         else
            gpu_preload_rand(TE_SRC_LO, TE_SRC_HI);
         te_font = 50 * te_sppw + 3;
         te_p    = ((te_i % 2) && (TE_DISPW >= 30)) ? TE_DISPW : TE_DPITCH;
         te_pp   = ((te_i % 2) && (TE_DISPW >= 30)) ? 16'd0 : TE_DPITCH;
         te_b    = TE_DST_LO * te_ppw + te_lh * te_p + 2 + ($random(gpu_seed) & (te_ppw - 1));
         gpu_c_dst(te_pp, te_b);
         gpu_c_size(te_w, te_h);
         gpu_c_fill((te_i == 3) ? 32'h0000_FFFE : $random(gpu_seed));
         gpu_c_transp(te_hi_color($random(gpu_seed), te_pm));
         // line 1, left to right
         te_glyph(1); te_exp(0,             3'b000, te_i % 2, te_s);
         te_glyph(4); te_exp(te_w,          3'b000, te_i % 2, te_s);
         te_glyph(2); te_exp(te_w,          3'b000, te_i % 2, te_s);
         te_glyph(7); te_exp(te_w,          3'b000, te_i % 2, te_s);
         // carriage return to the next line
         te_glyph(3); te_exp(-3 * te_w + te_lh * te_p, 3'b000, te_i % 2, te_s);
         te_check_base(te_b + te_lh * te_p);
         te_glyph(0); te_exp(te_w,          3'b000, te_i % 2, te_s);
         te_glyph(5); te_exp(te_w,          3'b000, te_i % 2, te_s);
         // negative carriage return: line above line 1
         te_glyph(6); te_exp(-2 * te_w - 2 * te_lh * te_p, 3'b000, 1 - (te_i % 2), te_s);
         te_check_base(te_b - te_lh * te_p);
         te_glyph(2); te_exp(te_w,          3'b000, 1 - (te_i % 2), te_s);
         te_glyph(2); te_exp(te_w,          3'b000, 1 - (te_i % 2), te_s);
         te_glyph(1); te_exp(te_w,          3'b000, 1 - (te_i % 2), te_s);
         // line 3, right to left (X swap: base = top-right pixel of the glyph)
         te_glyph(7); te_exp(3 * te_lh * te_p + te_w - 1, 3'b100, te_i % 2, te_s);
         te_check_base(te_b + 2 * te_lh * te_p + 4 * te_w - 1);
         te_glyph(4); te_exp(-te_w,         3'b100, te_i % 2, te_s);
         te_glyph(3); te_exp(-te_w,         3'b100, te_i % 2, te_s);
         te_glyph(0); te_exp(-te_w,         3'b100, te_i % 2, te_s);
         te_check_base(te_b + 2 * te_lh * te_p + te_w - 1);
         gpu_wait_idle;
         te_no_err;
         $display("       mode %0d, SRC_DEPTH %0d, line pitch %0d (SET_DST pitch %0d), base 0x%h",
                  te_mode, te_s, te_p, te_pp, te_b);
         gpu_check_touched("expand text");
      end
      gpu_check_all("expand text");

      //--------------------------------------------------------------
      $display("--- extreme deltas +8191 / -8192 (largest that fits)");
      for (te_mode = 0; te_mode < 5; te_mode = te_mode + 1) begin
         gpu_set_mode(te_mode);
         te_bl  = gpu_bl(te_mode);
         te_ppw = 32 >> te_bl;
         te_px  = VRAM_WORDS * te_ppw;
         te_lo  = TE_SRC_HI * te_ppw;
         te_d   = (te_px - te_lo - 80) / 2;
         if (te_d > 8191) te_d = 8191;
         te_b   = te_lo + te_d + 18 + ($random(gpu_seed) & (te_ppw - 1));
         gpu_c_dst(16'd8, te_b);
         gpu_c_size(14'd4, 14'd2);
         gpu_c_src(16'd0, 48 * 32 + 5);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         te_exp(te_d,        3'b000, 1'b1, 2'd0);                // S + d
         te_exp(-(te_d + 1), 3'b000, 1'b0, 2'd0);                // S - 1
         te_exp(-(te_d + 1), 3'b000, 1'b1, 2'd0);                // S - 2 - d
         te_exp(te_d,        3'b000, 1'b1, 2'd0);                // S - 2
         gpu_wait_idle;
         te_no_err;
         $display("       mode %0d start 0x%h delta +%0d / -%0d", te_mode, te_b, te_d, te_d + 1);
         te_check_base(te_b - 2);
         gpu_check_touched("expand extreme deltas");
      end
      gpu_check_all("expand extreme deltas");

      //--------------------------------------------------------------
      $display("--- no leak of op / source swaps, state left behind");
      for (te_i = 0; te_i < 2; te_i = te_i + 1) begin
         te_mode = (te_i == 0) ? 2 : 4;
         te_s    = (te_i == 0) ? 1 : 0;
         gpu_set_mode(te_mode);
         te_bl   = gpu_bl(te_mode);
         te_ppw  = 32 >> te_bl;
         te_pm   = gpu_pmask(te_bl);
         te_sb   = 301;                                   // word 9/18/37/150 at 1/2/4/16 bpp: initial preload, never a destination
         te_b    = 640 * te_ppw + 3;
         gpu_preload_rand(TE_SRC_LO, TE_SRC_HI);
         gpu_c_dst(TE_DPITCH, te_b);
         gpu_c_src(16'd0, te_sb);
         gpu_c_size(14'd5, 14'd3);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(gpu_get_px(te_sb + 2, te_bl));       // a pixel the later COPY_TRANSP reads
         gpu_c_exec(GPU_FILL, 4'd5, 3'b100, 3'b000);        // XOR, X swap
         gpu_c_exec(GPU_COPY, 4'd9, 3'b011, 3'b110);        // op 9, src X|Y swaps
         te_exp(7, 3'b000, 1'b0, te_s);                     // S, source no swap, pitch = 5
         gpu_wait_idle;
         gpu_check_touched("expand after XOR/swapped EXECs");
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);        // SRC at GFX depth, pitch = DISP width
         gpu_c_exec(GPU_FILL, 4'd5, 3'b010, 3'b000);        // moved base, 5 x 3 kept, FILL kept
         gpu_c_exec(GPU_COPYT, 4'd0, 3'b000, 3'b000);       // TRANSP kept
         gpu_wait_idle;
         gpu_check_touched("COPY / FILL / COPY_TRANSP after expand");
         te_exp(-3, 3'b111, 1'b1, te_s);
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_c_exec(GPU_COPY, 4'd7, 3'b111, 3'b000);        // a COPY after the expand still swaps
         te_exp(TE_DPITCH * 4, 3'b001, 1'b0, te_s);
         gpu_wait_idle;
         te_no_err;
         gpu_check_touched("expand / EXEC interleave");
      end
      gpu_check_all("expand state");

      //--------------------------------------------------------------
      $display("--- GPU_DONE per expand, irq_o");
      gpu_set_mode(4);
      gpu_c_dst(TE_DPITCH, 32'd1300);
      gpu_c_src(16'd0, 48 * 16 + 1);
      gpu_c_size(14'd3, 14'd2);
      gpu_c_fill($random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, IF_DONE);
      te_check_irq(1'b0);
      for (te_k = 0; te_k < 4; te_k = te_k + 1) begin
         te_exp(20, te_k, te_k & 1, te_k);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         te_check_irq(1'b1);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         te_check_irq(1'b0);
      end
      gpu_c_src(16'd0, 48 * 16 + 9);                       // configuration: no GPU_DONE
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      te_check_irq(1'b0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, 32'h0);
      te_no_err;
      gpu_check_touched("expand GPU_DONE");

      //--------------------------------------------------------------
      $display("--- FREE-paced glyph bursts");
      for (te_i = 0; te_i < 2; te_i = te_i + 1) begin
         te_mode = (te_i == 0) ? 3 : 0;
         te_s    = (te_i == 0) ? 3 : 1;
         gpu_set_mode(te_mode);
         te_bl   = gpu_bl(te_mode);
         te_ppw  = 32 >> te_bl;
         te_pm   = gpu_pmask(te_bl);
         te_sbl  = (te_s == 3) ? 2 : te_s;
         te_sppw = 32 >> te_sbl;
         te_font = 48 * te_sppw + 1;
         gpu_preload_pal(TE_SRC_LO, TE_SRC_HI, te_sbl, 16'h0, 16'h1, $random(gpu_seed), gpu_pmask(te_sbl));
         te_lo   = TE_DST_LO * te_ppw + 300;
         te_cur  = te_lo + 200;
         gpu_c_dst(TE_DPITCH, te_cur);
         gpu_c_size(14'd5, 14'd4);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(te_hi_color($random(gpu_seed), te_pm));
         te_n = 0;
         for (te_k = 0; te_k < 3 * GPU_FIFO_DEPTH; te_k = te_k + 1) begin
            te_r = $random(gpu_seed) & 15;
            if (te_r == 0)
               gpu_c_fill($random(gpu_seed));
            else if (te_r == 1)
               gpu_c_size(1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % 8),
                          1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % 4));
            else if (te_r == 2)
               gpu_c_transp(te_hi_color($random(gpu_seed), te_pm));
            else begin
               gpu_c_src(16'd0, te_font + ($random(gpu_seed) & 7) * 40);
               te_tgt = te_lo + (($random(gpu_seed) & 32'h7FFF_FFFF) % 1500);
               te_dsw = $random(gpu_seed);
               te_exp(te_tgt - te_cur, te_dsw, $random(gpu_seed), te_s);
               te_cur = te_tgt;
               te_n   = te_n + 1;
            end
         end
         te_exp(te_w, 3'b000, 1'b1, te_s);                  // ends with an expand: GPU_DONE
         gpu_wait_idle;
         reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         $display("       mode %0d, SRC_DEPTH %0d, %0d glyphs", te_mode, te_s, te_n + 1);
         gpu_check_touched("FREE-paced glyph burst");
      end

      //--------------------------------------------------------------
      if (VRAM_WORDS == (1 << VRAM_AW)) begin
         $display("--- pixel-address wrap at PA_W (1 bpp)");
         gpu_set_mode(0);
         gpu_c_dst(16'd8, 32'd3);
         gpu_c_src(16'd0, 48 * 32 + 5);
         gpu_c_size(14'd4, 14'd1);
         gpu_c_fill(32'h1);
         gpu_c_transp(32'h0);
         te_exp(-8, 3'b000, 1'b1, 2'd0);                     // pixels -5 .. -2 (wrapped base)
         gpu_c_fill(32'h0);
         gpu_c_transp(32'h1);
         te_exp(3, 3'b000, 1'b1, 2'd0);                      // crosses the top: -2, -1, 0, 1
         te_exp(4, 3'b000, 1'b1, 2'd0);                      // back at 2
         gpu_wait_idle;
         te_no_err;
         te_check_base(32'd2);
         gpu_check_touched("expand address wrap");
      end

      te_no_err;
      gpu_check_all("expand end");
      $display("       skipped pixels: %0d, background writes: %0d", te_skipped, te_bgwr);
      if ((te_skipped == 0) || (te_bgwr == 0))
         tb_error("no skipped or no background pixel modelled (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
