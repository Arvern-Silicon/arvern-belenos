//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_texrect
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_texrect.v
// Module Description : EXEC_TEXRECT (opcode 0xE, affine blit) with SET_EXT 5
//                      SET_STEP_ROW and 6 SET_TEXBOX, SET_TEX [13] BOUND:
//                      the SET_SIZE W x H rectangle at the destination (base
//                      or x moved by DELTA first), walked with the SET_TEX
//                      swaps; pixel c of run r reads the texel at
//                      (u0 + r*du' + c*du, v0 + r*dv' + c*dv) (10.11
//                      accumulators, integer part as EXEC_TEXSPAN).
//                      1. GFX_MODE 0..4 x 8 cases: identity, scale up / down,
//                         rotations 30 / 135 degrees, shear, random steps
//                         (power-of-two wrap), FREE_PITCH, 1-texel texture;
//                         the eight swap codes, TRANSP_EN, SHADE, pitch
//                         explicit / 0.
//                      2. du' = dv' = 0 (or anything) and H = 1 equals
//                         EXEC_TEXSPAN with the same settings (VRAM compared
//                         pixel by pixel between the two destinations).
//                      3. BOUND: TEXBOX smaller than the texture, rotated and
//                         scaled blits whose corners start outside (signed
//                         u0 / v0 / steps), mirrored, FREE_PITCH, TEXBOX
//                         above 512 (= 512): out-of-box texels skipped with no
//                         read (allowed-word VRAM monitor; a blit entirely
//                         outside the box makes no VRAM access at all).
//                      3b. BOUND with a power-of-two texture and a box
//                         larger than it (texels in [size, box): wrapped at
//                         the texture size) and smaller (texels in [box,
//                         size): skipped, no read).
//                      4. x/y destination + clip + BOUND: both skip reasons
//                         in one blit.
//                      5. EXEC_TEXSPAN with BOUND (same SET_TEX bit).
//                      6. state: size kept, base / x moved, restart from
//                         (u0, v0), STEP_ROW kept, TEXSPAN after TEXRECT.
//                      7. GPU_DONE once per blit (W1C polling, a queued
//                         series), none while it runs.
//                      8. ABORT / GPU_EN = 0 mid-blit, after the blit's first
//                         VRAM writes (a third of them at most): a strict
//                         prefix of the walk (the destination 0, every texel
//                         above 0), no GPU_DONE, queued words flushed; a new
//                         blit drawn fully afterwards.
//                      9. debug freeze mid-blit: no VRAM access while held,
//                         freeze toggled at random, identical final image,
//                         GPU_DONE once.
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer TQ_SRC_LO   = 40;             // textures: words [40, 280)
localparam integer TQ_SRC_HI   = 280;
localparam integer TQ_DST_LO   = 300;            // destinations: words [300, 990)
localparam integer TQ_DST_HI   = 990;
localparam integer TQ_DPITCH   = 29;
localparam integer TQ_SPITCH   = 41;
localparam integer TQ_DISPW    = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer TQ_WMAX     = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer TQ_HMAX     = (GPU_DIM_MASK >= 10) ? 10 : GPU_DIM_MASK;
localparam integer TQ_TEXSPAN_BOUND = 1;         // 0: skip section 5 (BOUND with EXEC_TEXSPAN)

// 5.11 rotation steps
localparam  [15:0] TQ_C30  = 16'd1774;           // cos 30
localparam  [15:0] TQ_S30  = 16'd1024;           // sin 30
localparam  [15:0] TQ_C45  = 16'd1448;           // cos 45 = sin 45
localparam  [15:0] TQ_ONE  = 16'h0800;

integer    tq_mode, tq_bl, tq_ppw, tq_c, tq_i, tq_k, tq_n, tq_w, tq_h, tq_delta, tq_p;
integer    tq_cls, tq_nd, tq_t0, tq_wt, tq_cnt, tq_cl0, tq_bd0, tq_rd0;
integer    tq_strict, tq_late, tq_none, tq_held, tq_cu, tq_cv;
reg [31:0] tq_pm, tq_tb, tq_org, tq_a, tq_b, tq_tr, tq_flag, tq_st, tq_pa, tq_pb;
reg [15:0] tq_u0, tq_v0, tq_du, tq_dv, tq_dur, tq_dvr, tq_pp, tq_sp;
reg  [3:0] tq_lw, tq_lh;
reg  [2:0] tq_sw;
reg  [7:0] tq_sh;
reg        tq_te, tq_fp, tq_dbgc;

function integer tq_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      tq_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] tq_hi_color;             // random colour with the bits above the depth set
   input [31:0] rnd;
   input [31:0] pm;
   begin
      tq_hi_color = rnd | (~pm & 32'hFFFF) | 32'hA5A5_0000;
   end
endfunction

function [15:0] tq_neg;                  // two's complement of a 5.11 / 10.6 value
   input [15:0] v;
   begin
      tq_neg = 16'h0 - v;
   end
endfunction

// Base (first pixel visited) of a w x h walk whose top-left pixel is org
function [31:0] tq_corner;
   input [31:0] org;
   input integer pitch;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows = sw[0] ? w : h;
      cols = sw[0] ? h : w;
      tq_corner = org + (sw[1] ? rows - 1 : 0) * pitch + (sw[2] ? cols - 1 : 0);
   end
endfunction

// 10.6 start (u0, v0) putting the centre pixel of a w x h blit on texel (cu, cv)
task tq_centre;
   input integer cu;
   input integer cv;
   input integer w;
   input integer h;
   integer       a, b;
   begin
      a     = cu * 2048 - (w / 2) * gpu_sx16(tq_du) - (h / 2) * gpu_sx16(tq_dur);
      b     = cv * 2048 - (w / 2) * gpu_sx16(tq_dv) - (h / 2) * gpu_sx16(tq_dvr);
      tq_u0 = a >>> 5;
      tq_v0 = b >>> 5;
   end
endtask

task tq_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      tq_mode = mode;
      tq_bl   = gpu_bl(mode);
      tq_ppw  = 32 >> tq_bl;
      tq_pm   = gpu_pmask(tq_bl);
   end
endtask

task tq_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

task tq_check_irq;
   input exp;
   begin
      @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b %t", irq, exp, $time);
         error = error + 1;
      end
   end
endtask

// Steps + row steps + start in one go (model and push)
task tq_affine;
   input [15:0] du;
   input [15:0] dv;
   input [15:0] dur;
   input [15:0] dvr;
   input [15:0] u0;
   input [15:0] v0;
   begin
      tq_du  = du;
      tq_dv  = dv;
      tq_dur = dur;
      tq_dvr = dvr;
      gpu_c_step(du, dv);
      gpu_c_step_row(dur, dvr);
      gpu_c_uv(u0, v0);
   end
endtask

// Poll IRQ_FLAG until the GPU is idle, clearing and counting GPU_DONE
task tq_poll_done;
   output integer cnt;
   reg   [31:0] f, s;
   integer      guard;
   begin
      cnt   = 0;
      guard = 0;
      s     = GS_BUSY;
      while ((s & GS_BUSY) && (guard < 20000)) begin
         reg_rd_val(IRQ_FLAG, f);
         if (f & IF_DONE) begin
            reg_wr(IRQ_FLAG, IF_DONE);
            cnt = cnt + 1;
         end
         reg_rd_val(GPU_STAT, s);
         guard = guard + 1;
      end
      reg_rd_val(IRQ_FLAG, f);
      if (f & IF_DONE) begin
         reg_wr(IRQ_FLAG, IF_DONE);
         cnt = cnt + 1;
      end
      if (guard >= 20000) tb_error("GPU never became idle while counting GPU_DONE");
   end
endtask

// Compare the VRAM pixels of two n-pixel walks (backdoor)
task tq_cmp_walks;
   input [31:0] a;
   input [31:0] b;
   input integer pitch;
   input  [2:0] sw;
   input integer n;
   integer      kk, nbad;
   reg   [31:0] pa, pb;
   begin
      nbad = 0;
      for (kk = 0; kk < n; kk = kk + 1) begin
         pa = gpu_walk(a, pitch, sw, n, kk);
         pb = gpu_walk(b, pitch, sw, n, kk);
         if (gpu_vram_px(pa, tq_bl) !== gpu_vram_px(pb, tq_bl)) begin
            nbad = nbad + 1;
            if (nbad <= 4)
               $display("ERROR: TEXRECT H=1 pixel %0d = 0x%h, TEXSPAN pixel = 0x%h %t",
                        kk, gpu_vram_px(pa, tq_bl), gpu_vram_px(pb, tq_bl), $time);
         end
      end
      error = error + nbad;
      if (nbad == 0) $display("OK:    TEXRECT H=1 equals TEXSPAN over %0d pixels", n);
   end
endtask

// One modelled blit in address mode at the top-left org (base = first pixel)
task tq_blit;
   input [31:0] org;
   input [15:0] pitch;
   input integer delta;
   integer      pe;
   begin
      pe = (pitch == 16'h0) ? gpu_m_dispw : pitch;
      gpu_c_dst(pitch, tq_corner(org, pe, gpu_t_sw, gpu_m_w, gpu_m_h) - delta);
      gpu_c_texrect(delta);
   end
endtask


//============================================================================
// 8. ABORT / GPU_EN = 0 in the middle of a blit
//============================================================================
task tq_abort_case;
   input integer k;
   integer    how, tot, wt, cls, nd, nw, last, trg, kk;
   reg [31:0] flag, org, c0, c1, c2, c3;
   reg        dec, bnd, hit;
   begin
      how = k % 2;
      bnd = (k / 2) % 2;
      tq_set_mode(tq_rnd(5));
      // the destination 0, every texel colour above 0 (no SHADE): each pixel
      // drawn changes, so the image shows exactly how far the walk got
      for (wt = TQ_DST_LO; wt < TQ_DST_HI; wt = wt + 1) begin
         vram_mem[wt]   = 32'h0;
         gpu_shadow[wt] = 32'h0;
      end
      // c0 the transparent colour, the other three never c0 (1 bpp: nothing transparent)
      c0 = 1 + tq_rnd(tq_pm);
      c1 = 1 + tq_rnd(tq_pm);
      c2 = 1 + tq_rnd(tq_pm);
      c3 = tq_pm;
      if ((tq_bl != 0) && (c1 == c0)) c1 = (c0 % tq_pm) + 1;
      if ((tq_bl != 0) && (c2 == c0)) c2 = (c0 % tq_pm) + 1;
      if ((tq_bl != 0) && (c3 == c0)) c3 = (c0 % tq_pm) + 1;
      gpu_preload_pal(TQ_SRC_LO, TQ_SRC_HI, tq_bl, c0, c1, c2, c3);
      tq_tr = (tq_bl == 0) ? 32'h0 : c0;
      tot = TQ_WMAX * TQ_HMAX;
      org = (TQ_DST_LO + 20) * tq_ppw + tq_rnd(tq_ppw);
      gpu_c_transp(tq_tr);
      gpu_c_size(TQ_WMAX, TQ_HMAX);
      gpu_c_src(16'd0, 48 * tq_ppw + tq_rnd(tq_ppw));
      tq_sw = $random(gpu_seed);
      gpu_c_tex(4'd4, 4'd3, 1'b1, tq_sw, 1'b0, bnd, 8'h00);
      gpu_c_texbox(13, 6);
      if (bnd) begin
         tq_du = TQ_C30; tq_dv = TQ_S30; tq_dur = tq_neg(TQ_S30); tq_dvr = TQ_C30;
         tq_centre(6, 3, TQ_WMAX, TQ_HMAX);
         tq_affine(tq_du, tq_dv, tq_dur, tq_dvr, tq_u0, tq_v0);
      end else
         tq_affine($random(gpu_seed), $random(gpu_seed), $random(gpu_seed), $random(gpu_seed),
                   $random(gpu_seed), $random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_mon_start;
      gpu_rec_begin;
      tq_blit(org, TQ_DPITCH, tq_rnd(9) - 4);
      gpu_rec_end;
      dec = (tot >= 60) && !bnd;                                      // BOUND: out-of-box pixels may take 1 cycle
      if (dec) begin                                                  // queued words the flush drops
         gpu_push({OP_FENCE, 28'h100_0001});
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      end
      // the destination words the walk writes: the abandon after a third of them at most
      nw   = 0;
      last = -1;
      for (kk = 0; kk < gpu_rec_n; kk = kk + 1)
         if (gpu_rec_wr[kk] && (gpu_word_of(gpu_rec_pa[kk], gpu_rec_bl) != last)) begin
            nw   = nw + 1;
            last = gpu_word_of(gpu_rec_pa[kk], gpu_rec_bl);
         end
      if (nw < 3) tb_error("gpu_texrect: an abandoned blit writing fewer than 3 words (test bug)");
      trg = 1 + tq_rnd(nw / 3);
      gpu_wait_wr(trg, hit);
      if (!hit) begin
         $display("ERROR: TEXRECT ended after %0d of the %0d writes awaited (test bug) %t", gpu_mon_wr, trg, $time);
         error = error + 1;
      end
      if (how == 0)
         reg_wr(GPU_CTRL, 32'h2);                                     // ABORT
      else
         reg_wr(CTRL, tq_mode);                                       // GPU_EN = 0
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH,
                  GS_EMPTY | GS_FULL | GS_PRIM_BUSY | GS_BUSY | GS_ERR | GS_HELD | 32'hFFFF);
      reg_rd_val(IRQ_FLAG, flag);
      if (!(flag & IF_IDLE) || (flag & IF_ERR)) begin
         $display("ERROR: IRQ_FLAG = 0x%h after the abandon (GPU_IDLE expected, no GPU_ERR) %t", flag, $time);
         error = error + 1;
      end
      gpu_mon_stop;
      gpu_rec_prefix(flag[4], cls, nd);
      if (cls == 1) begin
         $display("OK:    TEXRECT %0s mode %0d sw %b%0s: abandoned after %0d writes, %0d of %0d recorded pixels (clean prefix, no GPU_DONE)",
                  (how == 0) ? "ABORT" : "GPU_EN=0", tq_mode, tq_sw, bnd ? " BOUND" : "", trg, nd, gpu_rec_n);
         tq_strict = tq_strict + 1;
      end else begin
         $display("ERROR: TEXRECT %0s mode %0d sw %b%0s after %0d of %0d writes: class %0d (%0d of %0d pixels), a strict prefix expected %t",
                  (how == 0) ? "ABORT" : "GPU_EN=0", tq_mode, tq_sw, bnd ? " BOUND" : "", trg, nw, cls, nd, gpu_rec_n, $time);
         error = error + 1;
         if (cls == 2) tq_late = tq_late + 1;
         if (cls == 0) tq_none = tq_none + 1;
      end
      if (how == 1) gpu_set_mode(tq_mode);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // a new blit, drawn fully (texture state re-sent after GPU_EN = 0)
      gpu_c_tex(gpu_t_lw, gpu_t_lh, gpu_t_ten, gpu_t_sw, gpu_t_free, gpu_t_bound, $random(gpu_seed));
      gpu_c_texbox(gpu_t_tw, gpu_t_th);
      tq_affine(tq_du, tq_dv, tq_dur, tq_dvr, gpu_t_u0, gpu_t_v0);
      gpu_c_size(TQ_WMAX, TQ_HMAX);
      tq_blit((TQ_DST_LO + 400) * tq_ppw + 3, TQ_DPITCH, 0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("blit after abandon");
      gpu_check_all("abandon + new blit");
   end
endtask


//============================================================================
// 9. Debug freeze in the middle of a blit
//============================================================================
task tq_freeze_case;
   input integer k;
   integer    tg, h0;
   reg [31:0] st;
   begin
      tq_set_mode((k == 0) ? 4 : (k == 1) ? 1 : 3);
      gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
      gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
      gpu_c_size(TQ_WMAX, TQ_HMAX);
      gpu_c_src(TQ_SPITCH, 48 * tq_ppw + 2 * TQ_SPITCH + 5);
      gpu_c_transp(gpu_get_px(48 * tq_ppw + 2 * TQ_SPITCH + 7, tq_bl));
      gpu_c_tex(4'd0, 4'd0, 1'b1, (k == 1) ? 3'b101 : 3'b000, 1'b1, 1'b1, $random(gpu_seed));
      gpu_c_texbox(24, 4);
      tq_du = TQ_C45; tq_dv = tq_neg(TQ_C45); tq_dur = TQ_C45; tq_dvr = TQ_C45;
      tq_centre(12, 2, TQ_WMAX, TQ_HMAX);
      tq_affine(tq_du, tq_dv, tq_dur, tq_dvr, tq_u0, tq_v0);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tq_blit((TQ_DST_LO + 30) * tq_ppw + 1, TQ_DPITCH, 0);
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
      repeat(5 + tq_rnd(20)) @(posedge free_clk);
      if (k == 0) begin                                               // strict hold
         reg_wr(DBG_CTRL, 32'h2);
         @(negedge free_clk) dbg_stoptime = 1'b1;
         reg_poll(GPU_STAT, GS_HELD, GS_HELD, 100);
         reg_rd_val(GPU_STAT, st);
         h0 = gpu_mon_noacc_hits;
         gpu_mon_noacc = 1'b1;
         repeat(300) @(posedge free_clk);
         gpu_mon_noacc = 1'b0;
         if (gpu_mon_noacc_hits == h0) $display("OK:    TEXRECT held 300 cycles: no VRAM access");
         if (st & GS_PRIM_BUSY) begin
            reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);                     // held mid-blit: no GPU_DONE yet
            tq_held = tq_held + 1;
         end
         @(negedge free_clk) dbg_stoptime = 1'b0;
         reg_wr(DBG_CTRL, 32'h0);
      end else begin                                                  // toggled at random
         reg_wr(DBG_CTRL, 32'h2);
         tq_dbgc = 1'b1;
         for (tg = 0; tg < 30; tg = tg + 1) begin
            repeat(1 + tq_rnd(24)) @(negedge free_clk);
            if (k == 1)
               dbg_stoptime = ~dbg_stoptime;
            else begin
               dbg_stoptime = 1'b1;
               tq_dbgc      = ~tq_dbgc;
               reg_wr(DBG_CTRL, tq_dbgc ? 32'h2 : 32'h0);
            end
            if (dbg_stoptime && tq_dbgc) begin
               reg_rd_val(GPU_STAT, st);
               if ((st & GS_HELD) && (st & GS_PRIM_BUSY)) begin
                  reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
                  tq_held = tq_held + 1;
               end
            end
         end
         @(negedge free_clk) dbg_stoptime = 1'b0;
         reg_wr(DBG_CTRL, 32'h0);
      end
      tq_poll_done(tq_cnt);
      if (tq_cnt != 1) begin
         $display("ERROR: %0d GPU_DONE for one frozen / released blit %t", tq_cnt, $time);
         error = error + 1;
      end
      tq_no_err;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("blit across a freeze");
   end
endtask


initial
   begin
      $display(" ===============================================");
      $display("|        GPU: EXEC_TEXRECT (affine blit)        |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (GPU_XY_EN == 0)
         tb_skip_finish("|          (x/y or affine blit absent)          |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(TQ_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_slo = TQ_SRC_LO;
      gpu_rgn_shi = TQ_SRC_HI;
      gpu_rgn_dlo = TQ_DST_LO;
      gpu_rgn_dhi = TQ_DST_HI;
      tq_strict = 0;
      tq_late   = 0;
      tq_none   = 0;
      tq_held   = 0;

      //--------------------------------------------------------------
      $display("--- 1. GFX_MODE 0..4 x 8 cases: rotation, scale, shear, wrap, FREE_PITCH, swaps, TRANSP_EN, SHADE");
      for (tq_mode = 0; tq_mode < 5; tq_mode = tq_mode + 1) begin
         tq_set_mode(tq_mode);
         for (tq_c = 0; tq_c < 8; tq_c = tq_c + 1) begin
            gpu_wait_idle;
            tq_te = tq_c % 2;
            tq_sh = ((tq_c % 3) == 0) ? 8'hFF : $random(gpu_seed);
            tq_tr = tq_hi_color($random(gpu_seed), tq_pm);
            gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
            if (tq_te) gpu_preload_pal(TQ_SRC_LO, TQ_SRC_HI, tq_bl, tq_tr, $random(gpu_seed), tq_pm, $random(gpu_seed));
            else       gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
            tq_w  = 1 + tq_rnd(TQ_WMAX);
            tq_h  = 1 + tq_rnd(TQ_HMAX);
            tq_fp = 1'b0;
            tq_sp = 16'd0;
            tq_lw = 4'd3;
            tq_lh = 4'd3;
            tq_u0 = $random(gpu_seed);
            tq_v0 = $random(gpu_seed);
            case (tq_c)
              0 : begin                                            // identity
                     tq_du = TQ_ONE; tq_dv = 16'h0; tq_dur = 16'h0; tq_dvr = TQ_ONE;
                  end
              1 : begin                                            // scale x 2 / x 1/2, anisotropic
                     tq_lw = 4'd4; tq_lh = 4'd2;
                     tq_du = (tq_mode % 2) ? 16'h0400 : 16'h1000;
                     tq_dv = 16'h0;
                     tq_dur = 16'h0;
                     tq_dvr = (tq_mode % 2) ? 16'h1000 : 16'h0300;
                  end
              2 : begin                                            // rotation 30
                     tq_lw = 4'd4; tq_lh = 4'd4;
                     tq_du = TQ_C30; tq_dv = TQ_S30; tq_dur = tq_neg(TQ_S30); tq_dvr = TQ_C30;
                  end
              3 : begin                                            // rotation 135
                     tq_lw = 4'd3; tq_lh = 4'd4;
                     tq_du = tq_neg(TQ_C45); tq_dv = TQ_C45; tq_dur = tq_neg(TQ_C45); tq_dvr = tq_neg(TQ_C45);
                  end
              4 : begin                                            // FREE_PITCH, u in [2, 32], v in [0, 6)
                     tq_fp  = 1'b1;
                     tq_sp  = (tq_mode % 2) ? TQ_SPITCH : 16'd0;
                     tq_lw  = $random(gpu_seed);                   // ignored
                     tq_lh  = $random(gpu_seed);
                     tq_u0  = ((2 + tq_rnd(3)) << 6) | tq_rnd(64);
                     tq_v0  = tq_rnd(64);
                     tq_du  = tq_rnd(2049);
                     tq_dv  = tq_rnd(200);
                     tq_dur = tq_rnd(512);
                     tq_dvr = tq_rnd(1100);
                  end
              5 : begin                                            // shear
                     tq_lw = 4'd5; tq_lh = 4'd3;
                     tq_du = TQ_ONE; tq_dv = 16'h0; tq_dur = 16'h0200; tq_dvr = TQ_ONE;
                  end
              6 : begin                                            // anything (wrap)
                     tq_lw = $random(gpu_seed) & 4'h3; tq_lh = 1 + ($random(gpu_seed) & 4'h3);
                     tq_du = $random(gpu_seed); tq_dv = $random(gpu_seed);
                     tq_dur = $random(gpu_seed); tq_dvr = $random(gpu_seed);
                  end
              default : begin                                      // 1-texel texture
                     tq_lw = 4'd0; tq_lh = 4'd0;
                     tq_du = $random(gpu_seed); tq_dv = $random(gpu_seed);
                     tq_dur = $random(gpu_seed); tq_dvr = $random(gpu_seed);
                  end
            endcase
            tq_sw    = (tq_c + tq_mode) & 7;
            tq_pp    = ((tq_c % 3) == 1) ? 16'd0 : TQ_DPITCH;
            tq_delta = tq_rnd(33) - 16;
            tq_tb    = 48 * tq_ppw + tq_rnd(tq_ppw);
            gpu_c_transp(tq_tr);
            gpu_c_src(tq_sp, tq_tb);
            gpu_c_size(tq_w, tq_h);
            gpu_c_tex(tq_lw, tq_lh, tq_te, tq_sw, tq_fp, 1'b0, tq_sh);
            tq_affine(tq_du, tq_dv, tq_dur, tq_dvr, tq_u0, tq_v0);
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            tq_blit(640 * tq_ppw / 2 + tq_rnd(tq_ppw), tq_pp, tq_delta);
            gpu_wait_idle;
            reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
            tq_no_err;
            $display("       mode %0d case %0d: %0dx%0d lw %0d lh %0d free %0d, uv %h/%h step %h/%h row %h/%h, sw %b, transp %0d, shade %h, dpitch %0d, delta %0d",
                     tq_mode, tq_c, tq_w, tq_h, tq_lw, tq_lh, tq_fp, tq_u0, tq_v0, tq_du, tq_dv, tq_dur, tq_dvr,
                     tq_sw, tq_te, tq_sh, tq_pp, tq_delta);
            gpu_check_touched("texrect matrix");
         end
         gpu_check_all("texrect matrix");
      end
      $display("       %0d texels written, %0d transparent, %0d shade wraps", gpu_t_nwr, gpu_t_ntr, gpu_t_nwrap);

      //--------------------------------------------------------------
      $display("--- 2. H = 1 equals EXEC_TEXSPAN (du' / dv' irrelevant)");
      for (tq_mode = 0; tq_mode < 5; tq_mode = tq_mode + 1) begin
         tq_set_mode(tq_mode);
         gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
         gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
         tq_n  = TQ_WMAX;
         tq_sw = (tq_mode * 3) & 7;
         tq_p  = tq_sw[0] ? 2 : TQ_DPITCH;
         tq_a  = (TQ_DST_LO + 20) * tq_ppw + 20 + tq_rnd(tq_ppw);
         tq_b  = tq_a + 14 * TQ_DPITCH;
         gpu_c_src(16'd0, 48 * tq_ppw + tq_rnd(tq_ppw));
         gpu_c_tex(4'd3, 4'd2, 1'b0, tq_sw, 1'b0, 1'b0, $random(gpu_seed));
         gpu_c_step($random(gpu_seed), $random(gpu_seed));
         gpu_c_step_row((tq_mode == 0) ? 16'h0 : $random(gpu_seed), (tq_mode == 0) ? 16'h0 : $random(gpu_seed));
         gpu_c_uv($random(gpu_seed), $random(gpu_seed));
         gpu_c_size(tq_n, 14'd1);
         gpu_c_dst(tq_p, tq_a);
         gpu_c_texrect(0);
         gpu_c_dst(tq_p, tq_b);
         gpu_c_texspan(0, tq_n);
         gpu_wait_idle;
         tq_no_err;
         tq_cmp_walks(tq_a, tq_b, tq_p, tq_sw, tq_n);
         gpu_check_touched("texrect H=1 / texspan");
      end
      gpu_check_all("texrect H=1");

      //--------------------------------------------------------------
      $display("--- 3. BOUND: TEXBOX, corners outside, no read outside the box");
      for (tq_i = 0; tq_i < 10; tq_i = tq_i + 1) begin
         tq_set_mode((tq_i < 5) ? tq_i : (tq_i == 9) ? 4 : (tq_i % 2) ? 3 : 4);
         gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
         gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
         tq_tr = tq_hi_color($random(gpu_seed), tq_pm);
         tq_te = (tq_i % 3) == 2;
         if (tq_te) gpu_preload_pal(TQ_SRC_LO, TQ_SRC_HI, tq_bl, tq_tr, $random(gpu_seed), $random(gpu_seed), tq_pm);
         tq_w  = TQ_WMAX;
         tq_h  = TQ_HMAX;
         tq_sw = (tq_i * 5) & 7;
         tq_fp = 1'b0;
         tq_sp = 16'd0;
         tq_tb = 48 * tq_ppw + 3 * TQ_SPITCH + 7 + tq_rnd(tq_ppw);     // poison around the box
         case (tq_i % 7)
           0 : begin                                               // identity, start at (-3.5, -2.25)
                  tq_lw = 4'd4; tq_lh = 4'd3; tq_cu = 11; tq_cv = 7;
                  tq_du = TQ_ONE; tq_dv = 16'h0; tq_dur = 16'h0; tq_dvr = TQ_ONE;
                  tq_u0 = tq_neg(16'h00E0); tq_v0 = tq_neg(16'h0090);
               end
           1 : begin                                               // rotation 30 about the box centre
                  tq_lw = 4'd4; tq_lh = 4'd3; tq_cu = 12; tq_cv = 8;
                  tq_du = TQ_C30; tq_dv = TQ_S30; tq_dur = tq_neg(TQ_S30); tq_dvr = TQ_C30;
                  tq_centre(tq_cu / 2, tq_cv / 2, tq_w, tq_h);
               end
           2 : begin                                               // FREE_PITCH, rotation -45
                  tq_fp = 1'b1; tq_sp = TQ_SPITCH; tq_lw = 4'hF; tq_lh = 4'hF; tq_cu = 20; tq_cv = 5;
                  tq_du = TQ_C45; tq_dv = tq_neg(TQ_C45); tq_dur = TQ_C45; tq_dvr = TQ_C45;
                  tq_centre(10, 2, tq_w, tq_h);
               end
           3 : begin                                               // mirrored: negative steps from u > TW
                  tq_lw = 4'd4; tq_lh = 4'd4; tq_cu = 9; tq_cv = 10;
                  tq_du = tq_neg(16'h0C00); tq_dv = 16'h0100; tq_dur = 16'h0080; tq_dvr = tq_neg(TQ_ONE);
                  tq_u0 = (16'd12 << 6) | tq_rnd(64); tq_v0 = (16'd11 << 6) | tq_rnd(64);
               end
           4 : begin                                               // scale down x 2, FREE_PITCH 0 pitch
                  tq_fp = 1'b1; tq_sp = 16'd0; tq_lw = 4'd0; tq_lh = 4'd0; tq_cu = 14; tq_cv = 4;
                  tq_du = 16'h1000; tq_dv = 16'h0; tq_dur = 16'h0; tq_dvr = 16'h1000;
                  tq_u0 = tq_neg(16'h0040); tq_v0 = tq_neg(16'h0020);
               end
           5 : begin                                               // TEXBOX above 512 = 512: only u, v < 0 skipped
                  tq_lw = 4'd3; tq_lh = 4'd3; tq_cu = 2048; tq_cv = 1536;
                  tq_du = TQ_ONE >> 1; tq_dv = 16'h0; tq_dur = 16'h0; tq_dvr = TQ_ONE >> 1;
                  tq_u0 = tq_neg(16'h0080); tq_v0 = tq_neg(16'h0040);
               end
           default : begin                                         // shear + scale, random start near the box
                  tq_lw = 4'd5; tq_lh = 4'd2; tq_cu = 1 + tq_rnd(31); tq_cv = 1 + tq_rnd(4);
                  tq_du = 16'h0600; tq_dv = 16'h0040; tq_dur = 16'h0300; tq_dvr = 16'h0500;
                  tq_u0 = (tq_rnd(20) << 6) - 16'd320; tq_v0 = tq_rnd(64) - 16'd96;
               end
         endcase
         gpu_c_transp(tq_tr);
         gpu_c_src(tq_sp, tq_tb);
         gpu_c_size(tq_w, tq_h);
         gpu_c_tex(tq_lw, tq_lh, tq_te, tq_sw, tq_fp, 1'b1, $random(gpu_seed));
         gpu_c_texbox(tq_cu, tq_cv);
         tq_affine(tq_du, tq_dv, tq_dur, tq_dvr, tq_u0, tq_v0);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tq_bd0 = gpu_t_nbnd;
         tq_rd0 = gpu_t_nrd;
         gpu_alw_clear;
         gpu_alw_start;
         gpu_mon_start;
         tq_blit((TQ_DST_LO + 300) * tq_ppw + tq_rnd(tq_ppw), TQ_DPITCH, tq_rnd(9) - 4);
         gpu_wait_idle;
         gpu_mon_stop;
         gpu_alw_stop;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         tq_no_err;
         $display("       mode %0d case %0d: box %0dx%0d free %0d sw %b transp %0d uv %h/%h: %0d of %0d texels outside the box, %0d VRAM accesses",
                  tq_mode, tq_i % 7, tq_cu, tq_cv, tq_fp, tq_sw, tq_te, tq_u0, tq_v0,
                  gpu_t_nbnd - tq_bd0, tq_w * tq_h, gpu_mon_n);
         if ((tq_i % 7 != 5) && (gpu_t_nbnd == tq_bd0))
            tb_error("BOUND case with no texel outside the box (test bug)");
         gpu_check_touched("texrect BOUND");
      end
      gpu_check_all("texrect BOUND");
      // entirely outside the box: no VRAM access at all
      tq_set_mode(4);
      gpu_c_src(16'd0, 48 * 2 + 3 * TQ_SPITCH);
      gpu_c_size(TQ_WMAX, TQ_HMAX);
      gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b1, 8'h00);
      gpu_c_texbox(8, 8);
      tq_affine(TQ_C30, TQ_S30, tq_neg(TQ_S30), TQ_C30, tq_neg(16'd100 << 6), 16'd2 << 6);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_mon_start;
      tq_blit((TQ_DST_LO + 300) * 2, TQ_DPITCH, 0);
      gpu_wait_idle;
      gpu_mon_stop;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      if (gpu_mon_n != 0) begin
         $display("ERROR: blit entirely outside the texture box: %0d VRAM accesses %t", gpu_mon_n, $time);
         error = error + 1;
      end else
         $display("OK:    blit entirely outside the texture box: no VRAM access, GPU_DONE");
      gpu_check_all("texrect outside the box");

      //--------------------------------------------------------------
      // BOUND with a power-of-two texture (FREE_PITCH 0) and a box larger than
      // the texture (texels in [texture size, box) are read at the wrapped
      // coordinate, gpu_t_bwrap), then a box smaller than the texture (texels in
      // [box, texture size) skipped, no read): either reading of BOUND is tested
      $display("--- 3b. BOUND: a box larger than the texture, then smaller");
      for (tq_i = 0; tq_i < 6; tq_i = tq_i + 1) begin
         tq_set_mode((tq_i % 3 == 0) ? 4 : (tq_i % 3 == 1) ? 3 : 1);
         gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
         gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
         tq_tb = 48 * tq_ppw + 3 * TQ_SPITCH + 7 + tq_rnd(tq_ppw);
         tq_cl0 = gpu_t_nbwrap;
         tq_bd0 = gpu_t_nbcut;
         gpu_c_src(16'd0, tq_tb);
         gpu_c_size(TQ_WMAX, TQ_HMAX);
         if (tq_i < 3) begin                                     // 8 x 8 texture, 21 x 18 box
            gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b1, 8'h00);
            gpu_c_texbox(21, 18);
            tq_affine(16'h1400, 16'h0000, 16'h0000, 16'h1000, 16'h0020, 16'h0010);   // du 2.5, dv' 2: past the box too
         end else begin                                          // 16 x 16 texture, 6 x 5 box
            gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b1, 8'h00);
            gpu_c_texbox(6, 5);
            tq_affine(TQ_ONE + 16'h0100, 16'h0000, 16'h0000, TQ_ONE + 16'h0080, 16'h0010, 16'h0008);
         end
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_alw_clear;
         gpu_alw_start;
         tq_blit((TQ_DST_LO + 300) * tq_ppw + tq_rnd(tq_ppw), TQ_DPITCH, 0);
         gpu_wait_idle;
         gpu_alw_stop;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         tq_no_err;
         $display("       mode %0d: box %0dx%0d, texture %0dx%0d: %0d in-box texels past the texture size, %0d texture texels outside the box",
                  tq_mode, gpu_t_tw, gpu_t_th, 1 << gpu_t_lw, 1 << gpu_t_lh, gpu_t_nbwrap - tq_cl0, gpu_t_nbcut - tq_bd0);
         if ((tq_i < 3) ? (gpu_t_nbwrap == tq_cl0) : (gpu_t_nbcut == tq_bd0))
            tb_error("gpu_texrect: BOUND box case without texels in the range it is about (test bug)");
         gpu_check_touched("texrect BOUND box vs texture");
      end
      gpu_check_all("texrect BOUND box vs texture");

      //--------------------------------------------------------------
      $display("--- 4. x/y destination + clip + BOUND: both skip reasons in one blit");
      for (tq_i = 0; tq_i < 4; tq_i = tq_i + 1) begin
         tq_set_mode((tq_i == 0) ? 4 : (tq_i == 1) ? 3 : (tq_i == 2) ? 2 : 0);
         gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
         gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
         tq_org = (TQ_DST_LO + 40) * tq_ppw + 2 * TQ_DPITCH + 5;
         tq_cl0 = gpu_exp_clip;
         tq_bd0 = gpu_t_nbnd;
         gpu_c_dst_xy(TQ_DPITCH, tq_org);
         gpu_c_clip(1, 1, 14, 8);
         gpu_c_src(TQ_SPITCH, 48 * tq_ppw + 2 * TQ_SPITCH + 3);
         gpu_c_size(TQ_WMAX, TQ_HMAX);
         tq_sw = (tq_i * 3) & 7;
         gpu_c_tex(4'd0, 4'd0, 1'b0, tq_sw, 1'b1, 1'b1, $random(gpu_seed));
         gpu_c_texbox(16, 4);
         tq_du = TQ_C30; tq_dv = tq_neg(TQ_S30); tq_dur = TQ_S30; tq_dvr = TQ_C30;
         tq_centre(8, 2, TQ_WMAX, TQ_HMAX);
         tq_affine(tq_du, tq_dv, tq_dur, tq_dvr, tq_u0, tq_v0);
         // footprint top-left at (-2..0, -1..0): first pixel at the swapped corner
         tq_w = tq_sw[0] ? TQ_HMAX : TQ_WMAX;                           // columns
         tq_h = tq_sw[0] ? TQ_WMAX : TQ_HMAX;                           // rows
         gpu_c_xy(-2 + tq_rnd(3) + (tq_sw[2] ? tq_w - 1 : 0), -1 + tq_rnd(2) + (tq_sw[1] ? tq_h - 1 : 0));
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_alw_clear;
         gpu_alw_start;
         gpu_c_texrect(tq_rnd(3));                                     // DELTA moves x
         gpu_wait_idle;
         gpu_alw_stop;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         tq_no_err;
         $display("       mode %0d sw %b at (%0d,%0d): %0d clipped, %0d outside the box",
                  tq_mode, gpu_t_sw, gpu_m_x, gpu_m_y, gpu_exp_clip - tq_cl0, gpu_t_nbnd - tq_bd0);
         if ((gpu_exp_clip == tq_cl0) || (gpu_t_nbnd == tq_bd0))
            tb_error("x/y + clip + BOUND blit lacks a clipped or an out-of-box pixel (test bug)");
         gpu_check_touched("texrect x/y + clip + BOUND");
      end
      gpu_c_noclip;
      gpu_check_all("texrect x/y + clip + BOUND");

      //--------------------------------------------------------------
      if (TQ_TEXSPAN_BOUND) begin
         $display("--- 5. EXEC_TEXSPAN with BOUND");
         tq_set_mode(3);
         gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
         gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
         gpu_c_src(16'd0, 48 * 4 + 3 * TQ_SPITCH);
         gpu_c_dst(TQ_DPITCH, (TQ_DST_LO + 20) * 4 + 2);
         gpu_c_tex(4'd4, 4'd2, 1'b0, 3'b000, 1'b0, 1'b1, $random(gpu_seed));
         gpu_c_texbox(10, 3);
         for (tq_k = 0; tq_k < 6; tq_k = tq_k + 1) begin
            gpu_c_uv(((tq_k - 2) << 6) | tq_rnd(64), ((tq_k % 5) - 1) << 6);
            gpu_c_step((tq_k % 2) ? 16'h0C00 : tq_neg(16'h0600), 16'h0100 * (tq_k % 3));
            gpu_c_texspan(TQ_DPITCH, TQ_WMAX);
         end
         gpu_wait_idle;
         tq_no_err;
         gpu_check_touched("texspan BOUND");
         gpu_check_all("texspan BOUND");
      end

      //--------------------------------------------------------------
      $display("--- 6. state: size kept, base / x moved, restart from (u0, v0), STEP_ROW kept");
      tq_set_mode(4);
      gpu_preload_rand(TQ_SRC_LO, TQ_SRC_HI);
      gpu_preload_rand(TQ_DST_LO, TQ_DST_HI);
      tq_a = (TQ_DST_LO + 100) * 2 + 3;
      gpu_c_src(16'd0, 48 * 2 + 1);
      gpu_c_dst(TQ_DPITCH, tq_a);
      gpu_c_size(14'd5, 14'd4);
      gpu_c_fill($random(gpu_seed));
      gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b0, 8'h03);
      tq_affine(16'h0A00, 16'h0100, 16'hFF00, 16'h0900, $random(gpu_seed), $random(gpu_seed));
      gpu_c_texrect(7);                                               // base + 7
      gpu_c_texrect(6 * TQ_DPITCH);                                   // again from (u0, v0), 5 x 4 kept
      gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b000, 3'b000);                  // FILL: 5 x 4 at the moved base
      gpu_c_step(16'h0400, 16'h0000);                                 // new step, row step kept
      gpu_c_texrect(-12 * TQ_DPITCH + 6);
      gpu_c_texspan(5 * TQ_DPITCH, 14'd7);                            // size -> 7 x 1
      gpu_c_texrect(TQ_DPITCH);                                       // 7 x 1
      gpu_c_size(14'd3, 14'd3);
      gpu_c_dst_xy(TQ_DPITCH, tq_a + 20 * TQ_DPITCH);
      gpu_c_texrect(2);                                               // at (2, 0)
      gpu_c_texrect(4);                                               // at (6, 0)
      if (gpu_m_x != 6) tb_error("x after two TEXRECT DELTAs (test bug)");
      gpu_c_xy(1, 4);
      gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b110, 1'b0, 1'b0, 8'h00);         // X|Y swaps
      gpu_c_texrect(10);                                              // first pixel (11, 4): bottom-right
      gpu_wait_idle;
      tq_no_err;
      gpu_check_touched("texrect state");
      gpu_check_all("texrect state");

      //--------------------------------------------------------------
      $display("--- 7. GPU_DONE once per blit, none while it runs");
      tq_set_mode(4);
      gpu_c_src(16'd0, 48 * 2 + 1);
      gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      tq_affine(16'h0800, 16'h0, 16'h0, 16'h0800, 16'h0, 16'h0);
      gpu_c_size(TQ_WMAX, TQ_HMAX);
      gpu_c_dst(TQ_DPITCH, (TQ_DST_LO + 20) * 2);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, IF_DONE);
      tq_check_irq(1'b0);
      gpu_c_texrect(1);
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
      tq_check_irq(1'b0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      tq_check_irq(1'b1);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tq_check_irq(1'b0);
      reg_wr(IRQ_EN, 32'h0);
      for (tq_k = 0; tq_k < 3; tq_k = tq_k + 1)                       // a queued series
         gpu_c_texrect(TQ_DPITCH);
      tq_poll_done(tq_cnt);
      if (tq_cnt != 3) begin
         $display("ERROR: %0d GPU_DONE for 3 queued blits %t", tq_cnt, $time);
         error = error + 1;
      end else
         $display("OK:    3 GPU_DONE for 3 queued blits");
      gpu_c_tex(4'd2, 4'd2, 1'b1, 3'b000, 1'b1, 1'b1, 8'h00);          // configuration words: no GPU_DONE
      gpu_c_texbox(3, 3);
      gpu_c_step_row(16'h0100, 16'h0200);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tq_no_err;
      gpu_check_touched("texrect GPU_DONE");

      //--------------------------------------------------------------
      $display("--- 8. ABORT / GPU_EN = 0 mid-blit");
      for (tq_k = 0; tq_k < 8; tq_k = tq_k + 1)
         tq_abort_case(tq_k);
      $display("       strict prefixes %0d, whole walk %0d, nothing drawn %0d", tq_strict, tq_late, tq_none);
      if (tq_strict != 8) tb_error("gpu_texrect: an abandon not landing mid-blit");

      //--------------------------------------------------------------
      $display("--- 9. debug freeze mid-blit");
      for (tq_k = 0; tq_k < 3; tq_k = tq_k + 1)
         tq_freeze_case(tq_k);
      $display("       %0d held-mid-blit checks", tq_held);

      tq_no_err;
      gpu_check_all("texrect end");
      $display("       %0d texels read, %0d outside the box, %0d transparent, %0d written",
               gpu_t_nrd, gpu_t_nbnd, gpu_t_ntr, gpu_t_nwr);
      if ((gpu_t_ntr == 0) || (gpu_t_nbnd == 0) || (gpu_t_nwrap == 0))
         tb_error("no transparent, out-of-box or shade-wrapped texel modelled (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
