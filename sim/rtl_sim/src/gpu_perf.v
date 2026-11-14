//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_perf
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_perf.v
// Module Description : GPU access pattern and best-case throughput:
//                      VRAM reads / writes per rectangle
//                      from the engine's word buffering (source read once per
//                      source word for COPY* except COPY op 2; destination
//                      read once per word below 8 bpp or for an op not in
//                      {0,1,13,14,15}, except FILL tokens covering whole
//                      bytes; transparent pixels not written), whole-pixel
//                      byte enables for 16 bpp writes, and the cycles per
//                      pixel measured on the VRAM port as the slope between a
//                      16- and a 48-pixel rectangle, against the figures of
//                      the performance table (doc/gpu_commands.md) both ways:
//                      at least the figure (a primitive is never faster than
//                      documented) and at most it, one cycle of tolerance;
//                      at a read latency of 2 the latency-2 figures; above
//                      2 the latency-2 figure as the floor, and the ceiling
//                      only for the rows that read no VRAM (FILL ops 0, 1,
//                      13-15, triangles, the per-rectangle overhead): the
//                      specification gives no figure for the others there.
//                      FILL, COPY, COPY_TRANSP rows at 8 and 16 bpp, 8-pixel
//                      rows below 8 bpp (a word per row), EXPAND, TEXSPAN,
//                      blending (latency 1; above: the floor), the first
//                      access after the push (6 for a copy, 10 for a fill),
//                      a 48 x 32 triangle (480 cycles), 16 queued 8 x 8
//                      triangles (916 with run-ahead, 1352 without, the
//                      bench's pushes included: 3 %), two queued FILLs (11
//                      cycles between them, 8 with run-ahead), three FILLs
//                      with their settings (52, 38 with run-ahead);
//                      gradient FILLs (GPU_GRAD_EN): a step per line (as a
//                      plain FILL) and along the run (a pixel per cycle),
//                      per channel too, at 8 and 16 bpp.
//                      Copies along long rows (12 words of pixels, two rows)
//                      at every depth: aligned, one pixel off, an operation
//                      reading D, keyed (no pixel / every pixel transparent),
//                      mirrored, one-pixel scrolls either way (the scroll
//                      right also walked reversed, the X swap on both sides),
//                      CL swaps (destination columns, source columns, both
//                      sides, and destination columns with
//                      an operation reading D); access counts
//                      checked (but for the scrolls), cycles per pixel from
//                      the slope against a run a third as long, against the
//                      documented rows (tw_exp: the port's bound for
//                      word-token COPY, a read and a write per destination
//                      word, plus a destination read for an operation using
//                      D or, below 8 bpp, a run off by a part of a byte;
//                      the one-pixel-per-token rows: the scroll right by 1,
//                      the CL swaps). With GPU_REMAP_EN /
//                      GPU_MPLANE_EN, the same long rows at every depth for
//                      COPY with REMAP SRC and DST (the table word held, or
//                      read for every pixel), with MPLANE, and with both,
//                      and 8-bpp TEXSPAN with SET_TEX REMAP: access counts
//                      checked (table and mask words included), cycles per
//                      pixel against rp_exp (one pixel per token for a
//                      remap, plus its table reads; word tokens plus a mask
//                      read every 32 pixels for the mask plane).
//                      RGB565A8 copies (alpha 255 / 0 / partial / an edge,
//                      MIX5), a nearest RGB565A8 TEXRECT and bilinear
//                      TEXRECTs (zoom-in, rotated, zoom-out, texel-aligned;
//                      opaque and RGB565A8) at the end (tq_*).
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer tp_span1, tp_span2, tp_cpp_x2, tp_lat, tp_gap, tp_k;
localparam integer TP_L = VRAM_RD_LAT + VRAM_RD_REG_EN;   // the read latency seen by the GPU

// A measured span difference d (cycles, for npx more pixels) against the
// documented cycles per pixel x 1000 at the latency of the build: lo at least
// (a primitive is never faster than its documented figure), hi at most (0 =
// none: above a latency of 2 the specification gives no figure for the
// operations that read VRAM); one cycle of tolerance either way, and the
// rounding of the x 1000 figures. ok = 0: out of bounds.
function tp_in;
   input integer d;
   input integer npx;
   input integer lo;
   input integer hi;
   begin
      tp_in = ((1000 * d) >= (lo * npx - 1000 - npx)) &&
              ((hi == 0) || ((1000 * d) <= (hi * npx + 1000 + npx)));
   end
endfunction

// Bounds of a row from its figures at latency 1 and 2 (x 1000) and whether it
// reads VRAM: at latency 1 and 2 its figure both ways; above, the latency-2
// figure as the floor, the same as the ceiling only when it reads nothing
task tp_bounds;
   input integer f1;
   input integer f2;
   input         rd;
   output integer lo;
   output integer hi;
   begin
      lo = (TP_L <= 1) ? f1 : f2;
      hi = (TP_L <= 2) ? lo : (rd ? 0 : f2);
   end
endtask

integer tp_lo, tp_hi;

// One measurement: rectangle 8 x h, returns the access span in cycles
task tp_run;
   input  [2:0] mode;
   input  [3:0] cmd;
   input  [3:0] op;
   input integer h;
   input        be_chk;
   output integer span;
   integer      t0;
   begin
      gpu_c_size(14'd8, h);
      gpu_wait_idle;
      gpu_exp_rd = 0;
      gpu_exp_wr = 0;
      gpu_mon_bl     = gpu_bl(mode);
      gpu_mon_be_chk = be_chk;
      gpu_mon_start;
      gpu_c_exec(cmd, op, 3'b000, 3'b000);
      t0 = gpu_cyc;
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_mon_be_chk = 1'b0;
      span = (gpu_mon_n > 0) ? (gpu_mon_t[gpu_mon_n - 1] - gpu_mon_t[0] + 1) : 0;
      tp_lat = (gpu_mon_n > 0) ? (gpu_mon_t[0] - t0) : -1;
      if ((gpu_mon_rd != gpu_exp_rd) || (gpu_mon_wr != gpu_exp_wr)) begin
         $display("ERROR: GPU mode %0d cmd %h op %0d 8x%0d: %0d reads / %0d writes, expected %0d / %0d %t",
                  mode, cmd, op, h, gpu_mon_rd, gpu_mon_wr, gpu_exp_rd, gpu_exp_wr, $time);
         error = error + 1;
      end
   end
endtask

// EXPAND (1 bpp source, 8 x h) or TEXSPAN (one run of 8 h texels, du = 1):
// access span only (reported)
task tp_run_k;
   input        texk;
   input integer h;
   output integer span;
   integer      t0;
   begin
      gpu_wait_idle;
      gpu_mon_start;
      t0 = gpu_cyc;
      if (texk) begin
         gpu_c_size(14'd8 * h, 14'd1);
         gpu_c_texspan(0, 8 * h);
      end else begin
         gpu_c_size(14'd8, h);
         gpu_c_expand(0, 3'b000, 1'b1, 2'd0);
      end
      gpu_wait_idle;
      gpu_mon_stop;
      span = (gpu_mon_n > 0) ? (gpu_mon_t[gpu_mon_n - 1] - gpu_mon_t[0] + 1) : 0;
   end
endtask

task tp_case_k;
   input        texk;
   begin
      tp_run_k(texk, 2, tp_span1);
      tp_run_k(texk, 6, tp_span2);
      tp_cpp_x2 = (2 * (tp_span2 - tp_span1)) / 32;
      tp_bounds(1000, texk ? 1500 : 1000, 1'b1, tp_lo, tp_hi);   // 1; TEXSPAN 1.5 at latency 2
      if (texk && (GPU_DIM_MASK < 48))                            // the 48-texel span does not fit
         $display("INFO:  GPU mode 4 TEXSPAN (du = 1): spans %0d / %0d (DIM_W too small for the measurement)",
                  tp_span1, tp_span2);
      else if (!tp_in(tp_span2 - tp_span1, 32, tp_lo, tp_hi)) begin
         $display("ERROR: GPU mode 4 %0s: %0d cycles for 32 pixels more, expected %0d.%03d%0s cycles/pixel (spans %0d / %0d) %t",
                  texk ? "TEXSPAN (du = 1)" : "EXPAND 1 bpp opaque", tp_span2 - tp_span1, tp_lo / 1000, tp_lo % 1000,
                  (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2, $time);
         error = error + 1;
      end else
         $display("OK:    GPU mode 4 %0s: %0d.%0d cycles/pixel, %0d.%03d%0s expected (spans %0d / %0d)",
                  texk ? "TEXSPAN (du = 1)" : "EXPAND 1 bpp opaque", tp_cpp_x2 / 2, 5 * (tp_cpp_x2 % 2),
                  tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2);
   end
endtask

// Copies along long rows (word-token COPY): two rows of w1 and w2 pixels (w2
// = 12 words of pixels, w1 a third of it), cycles per pixel from the slope;
// sources at slot ss (TW_SLO: never 0; TW_KLO: all 0 = the key), destination
// at slot ds, pitch 512; ovl != 0: the source is the destination moved by ovl
// pixels (a scroll; access counts then not modelled exactly). exp: most
// cycles per pixel x 1000, 0 = report only.
localparam integer TW_SLO = 4096;
localparam integer TW_KLO = 6144;
localparam integer TW_DLO = 12288;
integer tw_w1, tw_w2, tw_s1, tw_s2, tw_cpp;

task tw_run;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   input integer w;
   input        cnt;
   output integer span;
   begin
      gpu_c_size(w, 14'd2);
      gpu_wait_idle;
      gpu_exp_rd = 0;
      gpu_exp_wr = 0;
      gpu_mon_start;
      gpu_c_exec(cmd, op, dsw, ssw);
      gpu_wait_idle;
      gpu_mon_stop;
      span = (gpu_mon_n > 0) ? (gpu_mon_t[gpu_mon_n - 1] - gpu_mon_t[0] + 1) : 0;
      if (cnt && ((gpu_mon_rd != gpu_exp_rd) || (gpu_mon_wr != gpu_exp_wr))) begin
         $display("ERROR: GPU long-row copy cmd %h op %0d %0d x 2 swaps %b -> %b: %0d reads / %0d writes, expected %0d / %0d %t",
                  cmd, op, w, ssw, dsw, gpu_mon_rd, gpu_mon_wr, gpu_exp_rd, gpu_exp_wr, $time);
         error = error + 1;
      end
   end
endtask

task tw_case;
   input integer bl;
   input  [3:0] cmd;
   input  [3:0] op;
   input integer ss;
   input integer ds;
   input  [2:0] dsw;
   input  [2:0] ssw;
   input        key;
   input integer ovl;
   input integer c;                     // the row of tw_exp (-1: report only)
   integer      ppw;
   reg   [31:0] db, sb;
   begin
      ppw   = 32 >> bl;
      tw_w2 = 12 * ppw;
      if (tw_w2 > GPU_DIM_MASK) tw_w2 = GPU_DIM_MASK;
      tw_w1 = tw_w2 / 3;
      if (tw_w1 < 1) tw_w1 = 1;
      gpu_wait_idle;
      gpu_set_mode(bl);
      db = TW_DLO * ppw + ds + (dsw[2] ? tw_w2 : 0);
      sb = (ovl != 0) ? (db + ovl) : ((key ? TW_KLO : TW_SLO) * ppw + ss + (ssw[2] ? tw_w2 : 0));
      gpu_c_dst(16'd512, db);
      gpu_c_src(16'd512, sb);
      gpu_c_transp(32'h0000_0000);
      tw_run(cmd, op, dsw, ssw, tw_w1, ovl == 0, tw_s1);
      tw_run(cmd, op, dsw, ssw, tw_w2, ovl == 0, tw_s2);
      tw_cpp = (1000 * (tw_s2 - tw_s1)) / (2 * (tw_w2 - tw_w1));
      tp_bounds(tw_exp(bl, c, 1), tw_exp(bl, c, 2), 1'b1, tp_lo, tp_hi);
      if ((c < 0) || (tw_w2 != 12 * ppw))
         $display("INFO:  GPU long rows %2d bpp cmd %h op %2d slots %0d -> %0d swaps %b -> %b%0s%0s: %0d.%03d cycles/pixel (spans %0d / %0d)",
                  1 << bl, cmd, op, ss, ds, ssw, dsw, key ? " all keyed" : "",
                  (ovl > 0) ? " scroll -1" : (ovl < 0) ? " scroll +1" : "",
                  tw_cpp / 1000, tw_cpp % 1000, tw_s1, tw_s2);
      else if (!tp_in(tw_s2 - tw_s1, 2 * (tw_w2 - tw_w1), tp_lo, tp_hi)) begin
         $display("ERROR: GPU long rows %2d bpp cmd %h op %2d slots %0d -> %0d swaps %b -> %b%0s%0s: %0d.%03d cycles/pixel, expected %0d.%03d%0s (spans %0d / %0d) %t",
                  1 << bl, cmd, op, ss, ds, ssw, dsw, key ? " all keyed" : "",
                  (ovl > 0) ? " scroll -1" : (ovl < 0) ? " scroll +1" : "",
                  tw_cpp / 1000, tw_cpp % 1000, tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "",
                  tw_s1, tw_s2, $time);
         error = error + 1;
      end else
         $display("OK:    GPU long rows %2d bpp cmd %h op %2d slots %0d -> %0d swaps %b -> %b%0s%0s: %0d.%03d cycles/pixel, %0d.%03d%0s expected (spans %0d / %0d)",
                  1 << bl, cmd, op, ss, ds, ssw, dsw, key ? " all keyed" : "",
                  (ovl > 0) ? " scroll -1" : (ovl < 0) ? " scroll +1" : "",
                  tw_cpp / 1000, tw_cpp % 1000, tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "", tw_s1, tw_s2);
   end
endtask

// Most cycles per pixel x 1000 of long-row case c at depth bl (0 = report
// only), from the port's bound: per destination word one source word read (two
// when the slots differ, one token per source word), a destination read when
// the token does not cover whole bytes or the operation uses D, one write;
// a read latency of 2 makes a destination read cost two cycles
function integer tw_exp;
   input integer bl;
   input integer c;
   input integer l;                     // read latency, 1 or 2
   integer       ppw, lat2, aw, pw;
   begin
      ppw  = 32 >> bl;
      lat2 = (l == 2);
      aw   = (2000 + ppw - 1) / ppw;                           // read + write per word
      pw   = ((lat2 ? 4000 : 3000) + ppw - 1) / ppw;           // ... and a destination read
      case (c)
        0:       tw_exp = aw;                                  // aligned
        1, 6:    tw_exp = (bl >= 3) ? aw : pw;                 // one pixel off: half-byte tokens below 8 bpp
        2:       tw_exp = pw;                                  // OR
        3:       tw_exp = (bl >= 3) ? aw : pw;                 // keyed: below 8 bpp the destination read
        4:       tw_exp = aw;                                  // every pixel keyed: source reads only, every other cycle
        5, 12:   tw_exp = (bl >= 3) ? aw : lat2 ? ((5000 + ppw - 1) / ppw) : pw;   // mirror, the reversed scroll (slots
                                                                           // apart: half-byte tokens below 8 bpp;
                                                                           // latency 2: 5 cycles per word)
        // the documented one-pixel-per-token rows: 2 + l / ppw below 8 bpp
        7:       tw_exp = (bl >= 3) ? (4000 + 1000 * l) : (2000 + (1000 * l + ppw - 1) / ppw);   // scroll right by 1
        8:       tw_exp = (bl == 4) ? 1500 : (bl == 3) ? 1250 :
                          ((1000 + 1000 * l) + (1000 + ppw - 1) / ppw);       // CL swap on the destination
        9:       tw_exp = (bl >= 3) ? 2000 : (2000 + (1000 * l + ppw - 1) / ppw);   // CL swap on the source
        10:      tw_exp = (bl >= 3) ? 2000 : (2000 + 1000 * l);              // CL swap on both sides
        11:      tw_exp = (bl == 4) ? (2000 + 500 * l) : (bl == 3) ? (2000 + 250 * l) :
                          (2000 + (1000 * l + ppw - 1) / ppw);                // CL swap on the destination, op OR
        default: tw_exp = 0;
      endcase
      if ((bl == 4) && (tw_exp != 0) && (c != 2) && (c < 7)) tw_exp = 1000;   // 16 bpp: a source word per pixel pair
   end
endfunction

// Palette remap and mask plane along long rows (as tw_case: two rows of w1
// and w2 pixels, destination slot 0, pitch 512, cycles per pixel from the
// slope). Sources of one index (RP_ULO: after the first pixel every lookup
// finds its table word held) or of two indices in different table words,
// alternating (RP_ALO: every pixel reads its table word; 4 and 8 bpp, where
// the table has more than one word); the table the identity, so a
// destination keeps the pattern it was preloaded with through both runs; the
// mask plane all ones (every pixel drawn), each of its rows starting a mask
// word. Case c: 0 SRC, table word held; 1 SRC, a table read per pixel; 2 DST,
// held; 3 DST, a read per pixel; 4 mask plane; 5 mask plane and SRC (held).
localparam integer RP_ULO = 8192;                  // one index: words [8192, 8704)
localparam integer RP_ALO = 8704;                  // alternating: words [8704, 9216)
localparam integer RP_TLO = 9216;                  // the table (64 words, a multiple of 64)
localparam integer RP_MLO = 9280;                  // the mask: two rows of 512 bits
integer rp_cpp;

// Words [lo, hi) with pixels a, b, a, b, ... at depth bl (backdoor, both copies)
task rp_fill;
   input integer lo;
   input integer hi;
   input integer bl;
   input  [15:0] a;
   input  [15:0] b;
   integer       ww, pp;
   reg    [31:0] vv;
   begin
      vv = 32'h0;
      for (pp = 0; pp < (32 >> bl); pp = pp + 1)
         vv = vv | (((pp & 1) ? b : a) & gpu_pmask(bl)) << (pp << bl);
      for (ww = lo; ww < hi; ww = ww + 1) begin
         vram_mem[ww]   = vv;
         gpu_shadow[ww] = vv;
      end
   end
endtask

// Most cycles per pixel x 1000 of case c at depth bl, for the runs w1, w2 of
// tw_w1, tw_w2, at a read latency L of 1 or 2 (the port: one access a cycle,
// one read in flight). A remap takes one pixel per token, so per destination
// word (ppw pixels) of a copy along rows:
//   c 0  one cycle per pixel (the source word read ahead, the write from the
//        slot, in the same cycles); below 8 bpp the destination word is read
//        when W reaches it (op S: no read ahead): L cycles
//   c 1  1 + L per pixel (the table read, its data merged as it arrives); the
//        source read and the write do not overlap them: 2 cycles, 1 at L = 2
//        (the write takes the cycle the table read leaves); below 8 bpp the
//        destination read, L
//   c 2  2 per pixel (the destination pixel registered, then the lookup in
//        the word held); the destination is read ahead, the source read and
//        the write fit in the first cycles
//   c 3  2 + L per pixel (registered, read, merged); at L = 2 one more cycle
//        per word
//   c 4  word tokens, as COPY_TRANSP (tw_exp: 2 cycles per word, 2 + L below
//        8 bpp where the destination is read); plus, per mask word (one every
//        32 pixels of a row, the rows starting a word), its read and the
//        token waiting for its data: 2 cycles (5 at 8 bpp and L = 2, where it
//        also breaks the source read ahead)
//   c 5  c 0 plus 1 + 2 L per mask word (one pixel per token: the mask read
//        waits for the source read ahead in flight)
// At 16 bpp the remap has no effect: a plain copy, word tokens, 2 cycles per
// word (w1 and w2 then fall in one mask word per row).
function integer rp_exp;
   input integer bl;
   input integer c;
   input integer l;                     // read latency, 1 or 2
   integer       ppw, d, cw, m, dw, dm;
   begin
      ppw = 32 >> bl;
      d   = (bl < 3) ? 1 : 0;
      dw  = tw_w2 - tw_w1;
      dm  = (tw_w2 + 31) / 32 - (tw_w1 + 31) / 32;   // mask words per row, w2 - w1
      m   = 0;
      case (c)
        0:       cw = ppw + d * l;
        1:       cw = (1 + l) * ppw + (3 - l) + d * l;
        2:       cw = 2 * ppw;
        3:       cw = (2 + l) * ppw + (l - 1);
        4:       begin cw = 2 + d * l; m = ((l == 2) && (bl == 3)) ? 5 : 2; end
        default: begin cw = ppw + d * l; m = 1 + 2 * l; end
      endcase
      if (bl == 4) cw = 2;
      rp_exp = (1000 * cw * dw + 1000 * m * dm * ppw + ppw * dw - 1) / (ppw * dw);
   end
endfunction

task rp_case;
   input integer bl;
   input integer c;
   integer       ppw;
   reg     [1:0] md;
   reg           mpl, alt;
   integer       dpat;
   reg    [31:0] sb, db;
   begin
      md    = (c == 0) || (c == 1) || (c == 5) ? 2'd1 : (c == 2) || (c == 3) ? 2'd2 : 2'd0;
      mpl   = (c >= 4);
      alt   = (c == 1);
      dpat  = (c == 2) ? 1 : (c == 3) ? 2 : 0;
      ppw   = 32 >> bl;
      tw_w2 = 12 * ppw;
      if (tw_w2 > GPU_DIM_MASK) tw_w2 = GPU_DIM_MASK;
      tw_w1 = tw_w2 / 3;
      if (tw_w1 < 1) tw_w1 = 1;
      tp_bounds(rp_exp(bl, c, 1), rp_exp(bl, c, 2), 1'b1, tp_lo, tp_hi);
      gpu_wait_idle;
      gpu_set_mode(bl);
      sb = (alt ? RP_ALO : RP_ULO) * ppw;
      db = TW_DLO * ppw;
      if (dpat != 0) rp_fill(TW_DLO, TW_DLO + 2 * 512 / ppw + 1, bl, 16'h0001, (dpat == 2) ? 16'h0005 : 16'h0001);
      gpu_c_dst(16'd512, db);
      gpu_c_src(16'd512, sb);
      if (md != 2'd0) gpu_c_remap_table(RP_TLO);
      if (mpl)        gpu_c_mask_plane(RP_MLO * 32, 1'b0);
      gpu_k_rmp = md;
      gpu_k_mpl = mpl;
      tw_run(GPU_COPY, 4'd0, 3'b000, 3'b000, tw_w1, 1'b1, tw_s1);
      tw_run(GPU_COPY, 4'd0, 3'b000, 3'b000, tw_w2, 1'b1, tw_s2);
      gpu_k_rmp = 2'd0;
      gpu_k_mpl = 1'b0;
      rp_cpp = (1000 * (tw_s2 - tw_s1)) / (2 * (tw_w2 - tw_w1));
      if (tw_w2 != 12 * ppw)
         $display("INFO:  GPU long rows %2d bpp COPY remap %0d%0s%0s%0s: %0d.%03d cycles/pixel (spans %0d / %0d)",
                  1 << bl, md, mpl ? " mask plane" : "", alt ? " alternating source" : "",
                  (dpat == 2) ? " alternating destination" : "", rp_cpp / 1000, rp_cpp % 1000, tw_s1, tw_s2);
      else if (!tp_in(tw_s2 - tw_s1, 2 * (tw_w2 - tw_w1), tp_lo, tp_hi)) begin
         $display("ERROR: GPU long rows %2d bpp COPY remap %0d%0s%0s%0s: %0d.%03d cycles/pixel, expected %0d.%03d%0s (spans %0d / %0d) %t",
                  1 << bl, md, mpl ? " mask plane" : "", alt ? " alternating source" : "",
                  (dpat == 2) ? " alternating destination" : "", rp_cpp / 1000, rp_cpp % 1000,
                  tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "", tw_s1, tw_s2, $time);
         error = error + 1;
      end else
         $display("OK:    GPU long rows %2d bpp COPY remap %0d%0s%0s%0s: %0d.%03d cycles/pixel, %0d.%03d%0s expected (spans %0d / %0d)",
                  1 << bl, md, mpl ? " mask plane" : "", alt ? " alternating source" : "",
                  (dpat == 2) ? " alternating destination" : "", rp_cpp / 1000, rp_cpp % 1000,
                  tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "", tw_s1, tw_s2);
   end
endtask

// TEXSPAN at 8 bpp (du = 1 texel, 16 and 48 pixels) with SET_TEX REMAP md, a
// texture of one index or alternating (the destination of one index). At most:
// 1 cycle per pixel (1.25 at L = 2: a texel word read every 4 pixels) as
// without remap when the table word is held; one cycle more per pixel when
// each texel reads its table word, or for DST (the destination pixel
// registered first)
task rp_tex;
   input   [1:0] md;
   input         alt;
   begin
      tp_bounds(1000 + ((alt || (md == 2'd2)) ? 1000 : 0), 1250 + ((alt || (md == 2'd2)) ? 1000 : 0), 1'b1, tp_lo, tp_hi);
      gpu_wait_idle;
      gpu_set_mode(3);
      rp_fill(TW_DLO, TW_DLO + 16, 3, 16'h0001, 16'h0001);      // DST: the table word held
      gpu_c_src(16'd0, (alt ? RP_ALO : RP_ULO) * 4);
      gpu_c_dst(16'd512, TW_DLO * 4);
      gpu_c_remap_table(RP_TLO);
      gpu_k_trmp = md;
      gpu_c_tex(4'd6, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_k_trmp = 2'd0;
      gpu_c_step(16'h0800, 16'h0000);
      gpu_c_uv(16'h0000, 16'h0000);
      tp_run_k(1'b1, 2, tp_span1);
      gpu_c_uv(16'h0000, 16'h0000);
      tp_run_k(1'b1, 6, tp_span2);
      rp_cpp = (1000 * (tp_span2 - tp_span1)) / 32;
      if (GPU_DIM_MASK < 48)
         $display("INFO:  GPU 8 bpp TEXSPAN (du = 1) remap %0d%0s: %0d.%03d cycles/pixel (spans %0d / %0d)",
                  md, alt ? " alternating texture" : "", rp_cpp / 1000, rp_cpp % 1000, tp_span1, tp_span2);
      else if (!tp_in(tp_span2 - tp_span1, 32, tp_lo, tp_hi)) begin
         $display("ERROR: GPU 8 bpp TEXSPAN (du = 1) remap %0d%0s: %0d.%03d cycles/pixel, expected %0d.%03d%0s (spans %0d / %0d) %t",
                  md, alt ? " alternating texture" : "", rp_cpp / 1000, rp_cpp % 1000, tp_lo / 1000, tp_lo % 1000,
                  (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2, $time);
         error = error + 1;
      end else
         $display("OK:    GPU 8 bpp TEXSPAN (du = 1) remap %0d%0s: %0d.%03d cycles/pixel, %0d.%03d%0s expected (spans %0d / %0d)",
                  md, alt ? " alternating texture" : "", rp_cpp / 1000, rp_cpp % 1000, tp_lo / 1000, tp_lo % 1000,
                  (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2);
   end
endtask

task tp_case;
   input  [2:0] mode;
   input  [3:0] cmd;
   input  [3:0] op;
   input integer f1;                    // documented cycles per pixel x 1000, latency 1 (0 = report only)
   input integer f2;                    // ... latency 2
   input        rd;                     // the rectangle reads VRAM
   input integer fa;                    // first access, cycles after the EXEC push (0 = report only)
   input        be_chk;
   begin
      gpu_set_mode(mode);
      tp_run(mode, cmd, op, 2, be_chk, tp_span1);
      tp_run(mode, cmd, op, 6, be_chk, tp_span2);
      tp_cpp_x2 = (2 * (tp_span2 - tp_span1)) / 32;      // x2 to show halves
      tp_bounds(f1, f2, rd, tp_lo, tp_hi);
      if (f1 == 0)
         $display("INFO:  GPU mode %0d cmd %h op %2d: %0d.%0d cycles/pixel (spans %0d / %0d, first access %0d cycles after the EXEC push)",
                  mode, cmd, op, tp_cpp_x2 / 2, 5 * (tp_cpp_x2 % 2), tp_span1, tp_span2, tp_lat);
      else if (!tp_in(tp_span2 - tp_span1, 32, tp_lo, tp_hi)) begin
         $display("ERROR: GPU mode %0d cmd %h op %2d: %0d cycles for 32 pixels more, expected %0d.%03d%0s cycles/pixel (spans %0d / %0d) %t",
                  mode, cmd, op, tp_span2 - tp_span1, tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "",
                  tp_span1, tp_span2, $time);
         error = error + 1;
      end else
         $display("OK:    GPU mode %0d cmd %h op %2d: %0d.%0d cycles/pixel, %0d.%03d%0s expected (spans %0d / %0d, first access %0d cycles after the EXEC push)",
                  mode, cmd, op, tp_cpp_x2 / 2, 5 * (tp_cpp_x2 % 2), tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "",
                  tp_span1, tp_span2, tp_lat);
      if ((fa != 0) && (tp_lat != fa)) begin
         $display("ERROR: GPU mode %0d cmd %h op %2d: first access %0d cycles after the EXEC push, %0d documented %t",
                  mode, cmd, op, tp_lat, fa, $time);
         error = error + 1;
      end
   end
endtask

// A line of n steps from (2, 2), 12.4 pixel centres: horizontal, vertical
// (steep) or AA at a slope of 1/3 (a third of the steps cross a row); returns
// the access span; the set-up latency (push of the operand to the first
// access) in tp_lat
task tp_line;
   input  [2:0] mode;
   input  [3:0] op;
   input  [3:0] opt;
   input        steep;
   input integer n;
   output integer span;
   integer      t0;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      gpu_c_dst_xy(16'd64, 32'd40000);
      gpu_c_pen(16 * 2 + 8, 16 * 2 + 8);
      gpu_wait_idle;
      gpu_exp_rd = 0;
      gpu_exp_wr = 0;
      gpu_mon_start;
      t0 = gpu_cyc;
      if (steep) gpu_c_line(16 * 2 + 8 + (opt[0] ? (16 * n) / 3 : 0), 16 * (2 + n - 1) + 8, op, opt);
      else       gpu_c_line(16 * (2 + n - 1) + 8, 16 * 2 + 8 + (opt[0] ? (16 * n) / 3 : 0), op, opt);
      gpu_wait_idle;
      gpu_mon_stop;
      span   = (gpu_mon_n > 0) ? (gpu_mon_t[gpu_mon_n - 1] - gpu_mon_t[0] + 1) : 0;
      tp_lat = (gpu_mon_n > 0) ? (gpu_mon_t[0] - t0) : -1;
      if ((gpu_mon_rd != gpu_exp_rd) || (gpu_mon_wr != gpu_exp_wr)) begin
         $display("ERROR: GPU line mode %0d op %0d: %0d reads / %0d writes, expected %0d / %0d %t",
                  mode, op, gpu_mon_rd, gpu_mon_wr, gpu_exp_rd, gpu_exp_wr, $time);
         error = error + 1;
      end
   end
endtask

// One line row: the slope between 16 and 48 steps against the documented
// cycles per step x 1000 (f1 at latency 1, f2 at 2; rd: it reads VRAM); a
// shallow AA line: per pixel drawn (coverage 0: none), f1 / 2 per step
integer tp_nd1;
task tp_line_case;
   input  [2:0] mode;
   input  [3:0] op;
   input  [3:0] opt;
   input        steep;
   input integer f1;
   input integer f2;
   input        rd;
   begin
      tp_line(mode, op, opt, steep, 16, tp_span1);
      tp_nd1 = gpu_ln_ndrawn;
      tp_line(mode, op, opt, steep, 48, tp_span2);
      tp_bounds(f1, f2, rd, tp_lo, tp_hi);
      if (opt[0] && !steep) begin                               // the pixels drawn instead of the steps
         tp_lo = (tp_lo * (gpu_ln_ndrawn - tp_nd1)) / 64;
         tp_hi = (tp_hi * (gpu_ln_ndrawn - tp_nd1)) / 64;
      end
      tp_cpp_x2 = (2000 * (tp_span2 - tp_span1)) / 32;
      if (!tp_in(tp_span2 - tp_span1, 32, tp_lo, tp_hi)) begin
         $display("ERROR: GPU line mode %0d op %0d %0s%0s: %0d cycles for 32 steps more, expected %0d.%03d%0s cycles/step (spans %0d / %0d) %t",
                  mode, op, opt[0] ? "AA " : "", steep ? "steep" : "shallow", tp_span2 - tp_span1, tp_lo / 1000, tp_lo % 1000,
                  (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2, $time);
         error = error + 1;
      end else
         $display("OK:    GPU line mode %0d op %0d %0s%0s: %0d.%03d cycles/step, %0d.%03d%0s expected (spans %0d / %0d, first access %0d cycles after the push)",
                  mode, op, opt[0] ? "AA " : "", steep ? "steep" : "shallow", tp_cpp_x2 / 2000, (tp_cpp_x2 % 2000) / 2,
                  tp_lo / 1000, tp_lo % 1000, (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2, tp_lat);
   end
endtask

//----------------------------------------------------------------------------
// RGB565A8 copies and bilinear sampling (raw command words; after the model's
// last check): cycles per pixel as the slope between a 16 x 8 and a 48 x 8
// rectangle, against the measured figures of doc/gpu_commands.md (at a read
// latency of 1 both ways; above, the latency-1 figure as the floor). The
// texture is a free-pitch 128-texel-wide image in words [TQ_TW, +4096), its
// A8 plane in words [TQ_AW, +2048) (one word in three partial), the
// destination at TQ_DW, pitch 64.
//----------------------------------------------------------------------------
localparam integer TQ_TW = 16384;
localparam integer TQ_AW = 21000;
localparam integer TQ_DW = 24000;
integer tq_clk = 0;
integer tq_i, tq_t0;
// The texture and A8 plane data: a xorshift32 stream, not $random(seed), whose
// sequence is the simulator's own (Icarus and Verilator differ), so that the
// data, and with it the cycle count of the alpha rows, is the same in both
reg [31:0] tq_rs;
function [31:0] tq_xs;
   input [31:0] x;
   reg   [31:0] y;
   begin
      y     = x ^ (x << 13);
      y     = y ^ (y >> 17);
      tq_xs = y ^ (y << 5);
   end
endfunction
always @(posedge hclk) tq_clk = tq_clk + 1;

task tq_check;
   input [8*28-1:0] name;
   input integer c1;
   input integer c2;
   input integer f1;                     // the latency-1 figure, x 1000
   integer lo, hi;
   begin
      lo = f1;
      hi = (TP_L <= 1) ? f1 : 0;
      if (!tp_in(c2 - c1, 256, lo, hi)) begin
         $display("ERROR: GPU %0s: %0d cycles for 256 pixels, documented %0d / 1000 per pixel %t", name, c2 - c1, f1, $time);
         error = error + 1;
      end else
         $display("OK:    GPU %0s: %0d.%03d cycles/pixel (documented %0d.%03d)", name, (c2 - c1) / 256,
                  ((c2 - c1) * 1000 / 256) % 1000, f1 / 1000, f1 % 1000);
   end
endtask

// A W x 8 TEXRECT from the texture, BOUND (a 120 x 120 box), FREE_PITCH:
// cycles from the EXEC to idle
task tq_tex;
   input [15:0] du, dv, rdu, rdv, u0, v0;
   input        a8, bil;
   input integer w;
   output integer cyc;
   begin
      reg_wr(GPU_CMD, {OP_SET_SRC, 8'h00, (a8 ? 4'h5 : 4'h0), 16'd128}); reg_wr(GPU_CMD, 2 * TQ_TW);
      reg_wr(GPU_CMD, {OP_SET_DST, 11'h000, 1'b1, 16'd64});            reg_wr(GPU_CMD, 2 * TQ_DW);
      reg_wr(GPU_CMD, {OP_SET_EXT, 4'h3, 24'h0});                      // SET_XY (0, 0)
      reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd8, w[13:0]});
      reg_wr(GPU_CMD, {OP_SET_EXT, 4'h0, 8'h00, 2'b00, 1'b1, 1'b1, 3'b000, 1'b0, 4'd7, 4'd7});
      reg_wr(GPU_CMD, {OP_SET_EXT, 4'h1, 24'h0}); reg_wr(GPU_CMD, {u0, v0});
      reg_wr(GPU_CMD, {OP_SET_EXT, 4'h2, 24'h0}); reg_wr(GPU_CMD, {du, dv});
      reg_wr(GPU_CMD, {OP_SET_EXT, 4'h5, 24'h0}); reg_wr(GPU_CMD, {rdu, rdv});
      reg_wr(GPU_CMD, {OP_SET_EXT, 4'h6, 12'd120, 12'd120});
      if (GPU_BILINEAR_EN != 0) begin
         reg_wr(GPU_CMD, {OP_SET_EXT, 4'hD, 4'h5, 18'h0, (GPU_BLEND_EN != 0), bil}); reg_wr(GPU_CMD, 32'h0);
      end
      if (GPU_BLEND_EN != 0) begin
         reg_wr(GPU_CMD, {OP_SET_EXT, 4'h8, 14'h0, 1'b1, 1'b0, 8'h00});    // MIX5, EN 0
         reg_wr(GPU_CMD, {OP_SET_EXT, 4'hD, 4'h4, 20'h0}); reg_wr(GPU_CMD, 4 * TQ_AW);
      end
      gpu_wait_idle;
      @(posedge hclk) tq_t0 = tq_clk;
      reg_wr(GPU_CMD, {OP_EXEC_TEXRECT, 28'h0});
      gpu_wait_idle;
      cyc = tq_clk - tq_t0;
   end
endtask

task tq_tex_case;
   input [8*28-1:0] name;
   input [15:0] du, dv, rdu, rdv, u0, v0;
   input        a8, bil;
   input integer f1;
   integer c1, c2;
   begin
      tq_tex(du, dv, rdu, rdv, u0, v0, a8, bil, 16, c1);
      tq_tex(du, dv, rdu, rdv, u0, v0, a8, bil, 48, c2);
      tq_check(name, c1, c2, f1);
   end
endtask

// An RGB565A8 COPY W x 8 along rows, the A8 plane all a (a = 1: every other
// word opaque, the others the bytes 0, 0, 0x80, 0xFF: an image edge), MIX5
task tq_copy_case;
   input [8*28-1:0] name;
   input [31:0] a;
   input integer f1;
   integer c1, c2, k, w;
   begin
      for (k = 0; k < 2; k = k + 1) begin
         w = k ? 48 : 16;
         for (tq_i = 0; tq_i < 1024; tq_i = tq_i + 1)
            vram_mem[TQ_AW + tq_i] = (a == 32'h1) ? ((tq_i & 1) ? 32'hFFFF_FFFF : 32'hFF80_0000) : a;
         reg_wr(GPU_CMD, {OP_SET_SRC, 8'h00, 4'h5, 16'd64}); reg_wr(GPU_CMD, 2 * TQ_TW);
         reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, 16'd64});    reg_wr(GPU_CMD, 2 * TQ_DW);
         reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd8, w[13:0]});
         reg_wr(GPU_CMD, {OP_SET_EXT, 4'h8, 14'h0, 1'b1, 1'b0, 8'h00});
         reg_wr(GPU_CMD, {OP_SET_EXT, 4'hD, 4'h4, 20'h0}); reg_wr(GPU_CMD, 4 * TQ_AW);
         gpu_wait_idle;
         @(posedge hclk) tq_t0 = tq_clk;
         reg_wr(GPU_CMD, {GPU_COPY, 28'h0});
         gpu_wait_idle;
         if (k) c2 = tq_clk - tq_t0; else c1 = tq_clk - tq_t0;
      end
      tq_check(name, c1, c2, f1);
   end
endtask

// The A8 plane: one word in three partial (random), the others opaque
task tq_a8_fill;
   begin
      for (tq_i = 0; tq_i < 2048; tq_i = tq_i + 1)
         if (tq_i % 3)
            vram_mem[TQ_AW + tq_i] = 32'hFFFF_FFFF;
         else begin
            tq_rs = tq_xs(tq_rs);
            vram_mem[TQ_AW + tq_i] = tq_rs;
         end
   end
endtask

task tq_all;
   begin
      tq_rs = 32'd3;
      for (tq_i = 0; tq_i < 4096; tq_i = tq_i + 1) begin
         tq_rs = tq_xs(tq_rs);
         vram_mem[TQ_TW + tq_i] = tq_rs;
      end
      tq_a8_fill;
      gpu_set_mode(4);
      if (GPU_BLEND_EN != 0) begin
         $display("--- RGB565A8 copies along rows (MIX5): cycles/pixel");
         tq_copy_case("RGB565A8 COPY, alpha 255", 32'hFFFF_FFFF, 1500);
         tq_copy_case("RGB565A8 COPY, alpha 0",   32'h0000_0000, 1500);
         tq_copy_case("RGB565A8 COPY, partial",   32'h8080_8080, 2250);
         tq_copy_case("RGB565A8 COPY, an edge",   32'h0000_0001, 1625);
         tq_a8_fill;
      end
      if ((GPU_BLEND_EN != 0) && (GPU_XY_EN != 0))              // EXEC_TEXRECT, SET_XY, BOUND: GPU_XY_EN
         tq_tex_case("RGB565A8 TEXRECT nearest",  16'd2048, 16'd0, 16'd0, 16'd2048, 16'h0120, 16'h0120, 1, 0, 1750);
      if ((GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0)) begin
         $display("--- bilinear TEXRECT (BOUND, free pitch): cycles/pixel");
         tq_tex_case("bilinear zoom-in 2x",       16'd1024, 16'd0,    16'd0,     16'd1024, 16'h0110, 16'h0110, 0, 1, 4500);
         tq_tex_case("bilinear 1:1 rotated 30",   16'd1774, 16'd1024, -16'd1024, 16'd1774, 16'h0400, 16'h0110, 0, 1, 5336);
         tq_tex_case("bilinear zoom-out 2:1",     16'd4096, 16'd0,    16'd0,     16'd4096, 16'h0110, 16'h0110, 0, 1, 6000);
         tq_tex_case("bilinear texel-aligned",    16'd2048, 16'd0,    16'd0,     16'd2048, 16'h0120, 16'h0120, 0, 1, 1500);
         if (GPU_BLEND_EN != 0) begin
            tq_tex_case("bilinear RGB565A8 zoom-in", 16'd1024, 16'd0,    16'd0,     16'd1024, 16'h0110, 16'h0110, 1, 1, 5555);
            tq_tex_case("bilinear RGB565A8 rot 30",  16'd1774, 16'd1024, -16'd1024, 16'd1774, 16'h0400, 16'h0110, 1, 1, 8266);
            tq_tex_case("bilinear RGB565A8 zoom-out",16'd4096, 16'd0,    16'd0,     16'd4096, 16'h0110, 16'h0110, 1, 1, 10000);
            tq_tex_case("bilinear RGB565A8 aligned", 16'd2048, 16'd0,    16'd0,     16'd2048, 16'h0120, 16'h0120, 1, 1, 2492);
         end
      end
   end
endtask


initial
   begin
      $display(" ===============================================");
      $display("|        GPU: access pattern and throughput     |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_pal(0, 8192, 4, 16'h1111, 16'h2222, 16'h3333, 16'h4444);
      gpu_model_init;
      gpu_set_dispw(64);
      gpu_set_mode(4);
      gpu_c_src(16'd64, 32'd1000);
      gpu_c_dst(16'd64, 32'd40000);
      gpu_c_fill(32'h0000_A5A5);
      gpu_c_transp(32'h0000_0000);                       // never matches (no 0 pixel at 16 bpp)

      $display("--- specified best-case cycles per pixel");
      //       mode  cmd        op     lat 1 lat 2 reads first be
      tp_case(3'd4, GPU_FILL,  4'd0,   500,  500, 0,    10,  1'b1);   // a destination word per cycle
      tp_case(3'd4, GPU_FILL,  4'd1,   500,  500, 0,    10,  1'b1);
      tp_case(3'd4, GPU_FILL,  4'd13,  500,  500, 0,    10,  1'b1);
      tp_case(3'd4, GPU_FILL,  4'd14,  500,  500, 0,    10,  1'b1);
      tp_case(3'd4, GPU_FILL,  4'd15,  500,  500, 0,    10,  1'b1);
      tp_case(3'd7, GPU_FILL,  4'd0,   500,  500, 0,    10,  1'b1);
      tp_case(3'd3, GPU_FILL,  4'd0,   250,  250, 0,    10,  1'b1);
      tp_case(3'd4, GPU_FILL,  4'd3,  1000, 1000, 1,     0,  1'b0);   // FILL with an op using D
      tp_case(3'd4, GPU_COPY,  4'd0,  1000, 1000, 1,     6,  1'b1);   // a source and a destination word / 2 cycles
      tp_case(3'd4, GPU_COPY,  4'd1,  1000, 1000, 1,     6,  1'b1);
      tp_case(3'd4, GPU_COPY,  4'd13, 1000, 1000, 1,     6,  1'b1);
      tp_case(3'd4, GPU_COPYT, 4'd0,  1000, 1000, 1,     6,  1'b1);
      tp_case(3'd5, GPU_COPY,  4'd0,  1000, 1000, 1,     6,  1'b1);
      tp_case(3'd3, GPU_COPY,  4'd0,   500,  500, 1,     6,  1'b1);
      tp_case(3'd4, GPU_COPY,  4'd2,  1000, 1000, 1,     6,  1'b0);   // op 2: no source read
      tp_case(3'd4, GPU_COPY,  4'd3,  1500, 2000, 1,     6,  1'b0);   // an op using D: 1.5, 2 at latency 2
      tp_case(3'd4, GPU_COPY,  4'd7,  1500, 2000, 1,     6,  1'b0);
      tp_case(3'd4, GPU_COPY,  4'd12, 1500, 2000, 1,     6,  1'b0);
      tp_case(3'd3, GPU_COPY,  4'd5,   750, 1000, 1,     6,  1'b0);   // 0.75 at 8 bpp, 1 at latency 2
      // below 8 bpp the 8-pixel rows are one word each: a word per row
      tp_case(3'd0, GPU_FILL,  4'd0,   125,  125, 0,    10,  1'b0);   // a write per row
      tp_case(3'd2, GPU_FILL,  4'd14,  125,  125, 0,    10,  1'b0);
      tp_case(3'd1, GPU_FILL,  4'd3,   250,  250, 1,     0,  1'b0);   // a read and a write per row
      tp_case(3'd2, GPU_COPY,  4'd0,   250,  250, 1,     6,  1'b0);   // a source and a destination word
      tp_case(3'd0, GPU_COPY,  4'd5,   375,  500, 1,     6,  1'b0);   // ... and the destination read

      $display("--- other cases (access counts checked, cycles reported)");
      tp_case(3'd4, GPU_COPYT, 4'd2,     0,    0, 1,     0,  1'b0);

      gpu_set_mode(4);
      gpu_c_src(16'd0, 32'd1000);
      tp_case_k(1'b0);
      gpu_c_tex(4'd6, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_c_step(16'h0800, 16'h0000);
      gpu_c_uv(16'h0000, 16'h0000);
      tp_case_k(1'b1);
      gpu_c_src(16'd64, 32'd1000);

      if ((GPU_TRI_EN != 0) && (GPU_XY_EN != 0)) begin             // no VRAM read: the figures at every latency
         $display("--- triangle fill (48 x 32 right triangle, 16 bpp)");
         gpu_wait_idle;
         gpu_set_mode(4);
         gpu_c_dst_xy(16'd64, 32'd60000);
         gpu_c_clip(-2048, -2048, 2047, 2047);
         gpu_c_vtx(0, 0, 0);
         gpu_c_vtx(1, 768, 0);
         gpu_c_vtx(2, 0, 512);
         gpu_mon_start;
         gpu_c_trifill(4'd0);                                      // modelled (the push, then zero time)
         tp_lat = gpu_cyc;
         gpu_wait_idle;
         gpu_mon_stop;
         tp_gap = gpu_cyc - tp_lat;                                // documented: 480 (seen through GPU_STAT polls)
         if (GPU_DIM_MASK < 48)
            $display("INFO:  GPU triangle 48 x 32: %0d cycles (DIM_W too small: the box is clamped)", tp_gap);
         else if ((tp_gap < 476) || (tp_gap > 484)) begin
            $display("ERROR: GPU triangle 48 x 32: %0d cycles from the EXEC push to idle, 480 documented %t", tp_gap, $time);
            error = error + 1;
         end else
            $display("OK:    GPU triangle 48 x 32 (box 1536 pixels): %0d cycles from the EXEC push to idle (480 documented), %0d VRAM writes",
                     tp_gap, gpu_mon_wr);
         $display("--- 16 queued 8 x 8 triangles (16 bpp)");
         gpu_wait_idle;
         gpu_push_wait = 1'b1;                                     // 112 words: wait for FIFO room
         gpu_mon_start;
         tp_lat = gpu_cyc;
         for (tp_k = 0; tp_k < 16; tp_k = tp_k + 1) begin
            gpu_c_vtx(0, tp_k * 128, 0);
            gpu_c_vtx(1, tp_k * 128 + 128, 0);
            gpu_c_vtx(2, tp_k * 128, 128);
            gpu_c_trifill(4'd0);
         end
         gpu_wait_idle;
         gpu_mon_stop;
         gpu_push_wait = 1'b0;
         // documented: 916 with run-ahead, 1352 without (the pushes of the bench's CPU
         // included: 3 % either way)
         tp_gap = gpu_cyc - tp_lat;
         tp_lo  = (GPU_RUNAHEAD_EN != 0) ? 916 : 1352;
         if ((100 * tp_gap < 97 * tp_lo) || (100 * tp_gap > 103 * tp_lo)) begin
            $display("ERROR: GPU 16 triangles 8 x 8: %0d cycles from the first push to idle, %0d documented %t", tp_gap, tp_lo, $time);
            error = error + 1;
         end else
            $display("OK:    GPU 16 triangles 8 x 8 (36 pixels each): %0d cycles from the first push to idle (%0d documented), %0d VRAM writes",
                     tp_gap, tp_lo, gpu_mon_wr);
      end

      if (GPU_BLEND_EN != 0) begin
         $display("--- blending (alpha 128, 16 bpp)");
         gpu_set_mode(4);
         gpu_c_dst(16'd64, 32'd40000);
         gpu_c_src(16'd64, 32'd1000);
         gpu_c_alpha(1'b1, 8'd128);                                // modelled (shared blend)
         for (tp_k = 0; tp_k < 2; tp_k = tp_k + 1) begin
            gpu_c_size(14'd8, 14'd2);
            gpu_wait_idle;
            gpu_mon_start;
            gpu_c_exec((tp_k == 0) ? GPU_FILL : GPU_COPY, 4'd0, 3'b000, 3'b000);
            gpu_wait_idle;
            gpu_mon_stop;
            tp_span1 = gpu_mon_t[gpu_mon_n - 1] - gpu_mon_t[0] + 1;
            gpu_c_size(14'd8, 14'd6);
            gpu_wait_idle;
            gpu_mon_start;
            gpu_c_exec((tp_k == 0) ? GPU_FILL : GPU_COPY, 4'd0, 3'b000, 3'b000);
            gpu_wait_idle;
            gpu_mon_stop;
            tp_span2 = gpu_mon_t[gpu_mon_n - 1] - gpu_mon_t[0] + 1;
            tp_cpp_x2 = (2 * (tp_span2 - tp_span1)) / 32;
            // documented at latency 1 (ultra): FILL 1, COPY 2; a longer latency is never faster
            tp_lo = (tp_k == 0) ? 1000 : 2000;
            tp_hi = (TP_L <= 1) ? tp_lo : 0;
            if (!tp_in(tp_span2 - tp_span1, 32, tp_lo, tp_hi)) begin
               $display("ERROR: GPU mode 4 blended %0s: %0d cycles for 32 pixels more, expected %0d.%03d%0s cycles/pixel (spans %0d / %0d) %t",
                        (tp_k == 0) ? "FILL" : "COPY", tp_span2 - tp_span1, tp_lo / 1000, tp_lo % 1000,
                        (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2, $time);
               error = error + 1;
            end else
               $display("OK:    GPU mode 4 blended %0s: %0d.%0d cycles/pixel, %0d.%03d%0s expected (spans %0d / %0d)",
                        (tp_k == 0) ? "FILL" : "COPY", tp_cpp_x2 / 2, 5 * (tp_cpp_x2 % 2), tp_lo / 1000, tp_lo % 1000,
                        (tp_hi == 0) ? " or more" : "", tp_span1, tp_span2);
         end
         gpu_c_alpha(1'b0, 8'd0);                                  // blending off
         gpu_wait_idle;
      end

      if (GPU_GRAD_EN != 0) begin
         $display("--- gradient fills (FILL op 0, 8 x 2 and 8 x 6): no VRAM read, the figures at every latency");
         //       mode  cmd        op     lat 1 lat 2 reads first be
         gpu_c_grad(1, 1'b0, 1, 1'b1);                             // a step per line: whole words, as a plain FILL
         tp_case(3'd4, GPU_FILL,  4'd0,   500,  500, 0,    10,  1'b1);
         tp_case(3'd3, GPU_FILL,  4'd0,   250,  250, 0,    10,  1'b1);
         gpu_c_grad(1, 1'b1, 1, 1'b1);                             // a step per pixel along the run: a pixel per cycle
         tp_case(3'd4, GPU_FILL,  4'd0,  1000, 1000, 0,    11,  1'b1);
         tp_case(3'd3, GPU_FILL,  4'd0,  1000, 1000, 0,    13,  1'b1);
         gpu_c_grad(4, 1'b1, 1, 1'b1);                             // a step every 4 pixels: still a pixel per cycle
         tp_case(3'd4, GPU_FILL,  4'd0,  1000, 1000, 0,    11,  1'b1);
         gpu_c_grad_rgb(1, 1'b0, 6, 0, -6, 1'b1);                  // per channel, per line
         tp_case(3'd4, GPU_FILL,  4'd0,   500,  500, 0,    10,  1'b1);
         gpu_c_grad_rgb(1, 1'b1, 6, 0, -6, 1'b1);                  // per channel, along the run
         tp_case(3'd4, GPU_FILL,  4'd0,  1000, 1000, 0,    11,  1'b1);
         gpu_c_grad(0, 1'b0, 0, 1'b0);                             // plain fills again
         gpu_wait_idle;
         gpu_set_mode(4);
      end

      if ((GPU_LINE_EN != 0) && (GPU_XY_EN != 0)) begin
         $display("--- lines: cycles per step");
         //            mode  op    opt    steep lat 1 lat 2 reads
         tp_line_case(3'd4, 4'd0, 4'h0, 1'b0, 1000, 1000, 1'b0);   // one token a step, words merged
         tp_line_case(3'd4, 4'd0, 4'h0, 1'b1, 1000, 1000, 1'b0);   // a write per step
         tp_line_case(3'd3, 4'd0, 4'h0, 1'b0, 1000, 1000, 1'b0);
         tp_line_case(3'd3, 4'd0, 4'h0, 1'b1, 1000, 1000, 1'b0);
         tp_line_case(3'd4, 4'd5, 4'h0, 1'b0, 1000, 1250, 1'b1);   // XOR: a read per word
         tp_line_case(3'd4, 4'd5, 4'h0, 1'b1, 2000, 2000, 1'b1);   // ... per step
         tp_line_case(3'd0, 4'd0, 4'h0, 1'b0, 1031, 1063, 1'b1);   // 1 bpp: a read per byte
         tp_line_case(3'd0, 4'd0, 4'h0, 1'b1, 2000, 3000, 1'b1);
         if (GPU_BLEND_EN != 0) begin
            tp_line_case(3'd4, 4'd0, 4'h1, 1'b0, 4000, 4500, 1'b1);   // AA: two blended pixels a step (2 a pixel drawn)
            tp_line_case(3'd4, 4'd0, 4'h1, 1'b1, 3000, 3344, 1'b1);   // ... a word for both half the time
         end
         gpu_wait_idle;
         gpu_set_mode(4);
         gpu_c_dst(16'd64, 32'd40000);                             // address mode again
      end

      gpu_check_touched("perf, before the long rows");
      $display("--- copies along long rows (word-token COPY): cycles/pixel at every depth");
      for (tp_k = 0; tp_k < 5; tp_k = tp_k + 1) begin
         gpu_wait_idle;
         gpu_preload_pal(TW_SLO, TW_SLO + 1024, tp_k, 16'h1111, 16'h3333, 16'h5555, 16'h7777);   // never 0
         gpu_preload_pal(TW_KLO, TW_KLO + 1024, tp_k, 16'h0000, 16'h0000, 16'h0000, 16'h0000);   // all 0
         //       mode cmd        op  slots  dsw     ssw     key ovl  row
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b000, 3'b000, 0,  0,   0);    // aligned
         tw_case(tp_k, GPU_COPY,  0,  1, 0,  3'b000, 3'b000, 0,  0,   1);    // one pixel off
         tw_case(tp_k, GPU_COPY,  4,  0, 0,  3'b000, 3'b000, 0,  0,   2);    // OR (reads D)
         tw_case(tp_k, GPU_COPYT, 0,  0, 0,  3'b000, 3'b000, 0,  0,   3);    // keyed, no key hit
         tw_case(tp_k, GPU_COPYT, 0,  0, 0,  3'b000, 3'b000, 1,  0,   4);    // keyed, all transparent
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b100, 3'b000, 0,  0,   5);    // mirror
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b000, 3'b000, 0,  1,   6);    // scroll left 1 px
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b000, 3'b000, 0, -1,   7);    // scroll right 1 px (one pixel per token)
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b100, 3'b100, 0, -1,   12);   // ... walked reversed (X swap both sides)
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b001, 3'b000, 0,  0,   8);    // CL swap: destination columns
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b000, 3'b001, 0,  0,   9);    // CL swap: source columns
         tw_case(tp_k, GPU_COPY,  0,  0, 0,  3'b001, 3'b001, 0,  0,   10);   // CL swap both sides
         tw_case(tp_k, GPU_COPY,  4,  0, 0,  3'b001, 3'b000, 0,  0,   11);   // CL swap, OR (reads D)
      end
      gpu_c_src(16'd64, 32'd1000);
      gpu_c_dst(16'd64, 32'd40000);
      gpu_c_fill(32'h0000_A5A5);
      gpu_c_transp(32'h0000_0000);

      if ((GPU_REMAP_EN != 0) || (GPU_MPLANE_EN != 0)) begin
         $display("--- palette remap and mask plane along long rows: cycles/pixel");
         for (tp_k = 0; tp_k < 64; tp_k = tp_k + 1) begin           // the identity table
            vram_mem[RP_TLO + tp_k]   = {tp_k[5:0], 2'd3, tp_k[5:0], 2'd2, tp_k[5:0], 2'd1, tp_k[5:0], 2'd0};
            gpu_shadow[RP_TLO + tp_k] = vram_mem[RP_TLO + tp_k];
         end
         for (tp_k = RP_MLO; tp_k < RP_MLO + 64; tp_k = tp_k + 1) begin   // the mask: all ones
            vram_mem[tp_k]   = 32'hFFFF_FFFF;
            gpu_shadow[tp_k] = 32'hFFFF_FFFF;
         end
         for (tp_k = 0; tp_k < 5; tp_k = tp_k + 1) begin
            gpu_wait_idle;
            rp_fill(RP_ULO, RP_ULO + 512, tp_k, 16'h0001, 16'h0001);
            rp_fill(RP_ALO, RP_ALO + 512, tp_k, 16'h0001, 16'h0005);
            if (GPU_REMAP_EN != 0) begin
               rp_case(tp_k, 0);                                   // SRC, the table word held
               if ((tp_k == 2) || (tp_k == 3)) rp_case(tp_k, 1);   // SRC, a table read per pixel
               rp_case(tp_k, 2);                                   // DST, the table word held
               if ((tp_k == 2) || (tp_k == 3)) rp_case(tp_k, 3);   // DST, a table read per pixel
            end
            if (GPU_MPLANE_EN != 0)
               rp_case(tp_k, 4);                                   // mask plane
            if ((GPU_REMAP_EN != 0) && (GPU_MPLANE_EN != 0))
               rp_case(tp_k, 5);                                   // both
         end
         if (GPU_REMAP_EN != 0) begin
            rp_tex(2'd0, 1'b0);
            rp_tex(2'd1, 1'b0);
            rp_tex(2'd1, 1'b1);
            rp_tex(2'd2, 1'b0);
         end
         gpu_c_src(16'd64, 32'd1000);
         gpu_c_dst(16'd64, 32'd40000);
         gpu_check_touched("perf, remap and mask plane");
      end

      $display("--- transparent pixels: not written");
      gpu_set_mode(4);
      gpu_c_transp(32'h0000_A5A5);                       // = fill colour
      tp_run(3'd4, GPU_FILL, 4'd13, 2, 1'b1, tp_span1);   // no access at all
      tp_run(3'd4, GPU_FILL, 4'd15, 2, 1'b1, tp_span1);
      tp_run(3'd4, GPU_FILL, 4'd0,  2, 1'b1, tp_span1);   // op 0: transparency ignored
      gpu_preload_pal(500, 600, 4, 16'h7777, 16'h7777, 16'h7777, 16'h7777);
      gpu_c_src(16'd64, 32'd1000);
      gpu_c_transp(32'h0000_7777);                       // every source pixel transparent
      tp_run(3'd4, GPU_COPYT, 4'd0,  2, 1'b1, tp_span1);   // source reads only
      tp_run(3'd4, GPU_COPY,  4'd14, 2, 1'b1, tp_span1);
      tp_run(3'd4, GPU_COPY,  4'd3,  2, 1'b0, tp_span1);   // op 3: transparency ignored
      gpu_c_transp(32'h0000_0000);

      $display("--- per-rectangle overhead (two queued 16-pixel FILLs)");
      gpu_c_size(14'd8, 14'd2);
      gpu_wait_idle;
      gpu_freeze(1'b1);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_c_exec(GPU_FILL, 4'd1, 3'b000, 3'b000);
      gpu_mon_start;
      @(negedge free_clk) dbg_stoptime = 1'b0;
      gpu_wait_idle;
      gpu_mon_stop;
      reg_wr(DBG_CTRL, 32'h0);
      if (gpu_mon_n == 16) begin
         tp_gap = gpu_mon_t[8] - gpu_mon_t[7];
         if (tp_gap != ((GPU_RUNAHEAD_EN != 0) ? 8 : 11)) begin              // no VRAM read: every latency
            $display("ERROR: GPU back-to-back 16-pixel FILLs: %0d cycles between them, %0d documented %t",
                     tp_gap, (GPU_RUNAHEAD_EN != 0) ? 8 : 11, $time);
            error = error + 1;
         end else
            $display("OK:    GPU back-to-back 16-pixel FILLs: rectangle 1 span %0d, rectangle 2 span %0d, gap between them %0d cycles (documented)",
                     gpu_mon_t[7] - gpu_mon_t[0] + 1, gpu_mon_t[15] - gpu_mon_t[8] + 1, tp_gap);
      end else begin
         $display("ERROR: GPU two queued FILLs: %0d accesses, expected 16 %t", gpu_mon_n, $time);
         error = error + 1;
      end

      // The 15 words are queued with the GPU frozen: they need a FIFO of 16 words or more
      if (GPU_FIFO_DEPTH >= 16) begin
         $display("--- three queued 16-pixel FILLs, each after SET_DST and SET_FILL (15 FIFO words)");
         gpu_wait_idle;
         gpu_freeze(1'b1);
         for (tp_k = 0; tp_k < 3; tp_k = tp_k + 1) begin
            gpu_c_dst(16'd64, 32'd40000 + 32'd256 * tp_k);
            gpu_c_fill(32'h0000_1111 * (tp_k + 1));
            gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         end
         gpu_mon_start;
         @(negedge free_clk) dbg_stoptime = 1'b0;
         gpu_wait_idle;
         gpu_mon_stop;
         reg_wr(DBG_CTRL, 32'h0);
         if ((gpu_mon_n == 24) && ((gpu_mon_t[23] - gpu_mon_t[0] + 1) != ((GPU_RUNAHEAD_EN != 0) ? 38 : 52))) begin
            $display("ERROR: GPU three FILLs with their SET_DST / SET_FILL: %0d cycles from the first write to the last, %0d documented %t",
                     gpu_mon_t[23] - gpu_mon_t[0] + 1, (GPU_RUNAHEAD_EN != 0) ? 38 : 52, $time);
            error = error + 1;
         end else if (gpu_mon_n == 24)
            $display("OK:    GPU three FILLs with their SET_DST / SET_FILL: %0d cycles from the first write to the last (documented; gaps %0d and %0d)",
                     gpu_mon_t[23] - gpu_mon_t[0] + 1, gpu_mon_t[8] - gpu_mon_t[7], gpu_mon_t[16] - gpu_mon_t[15]);
         else begin
            $display("ERROR: GPU three queued FILLs: %0d accesses, expected 24 %t", gpu_mon_n, $time);
            error = error + 1;
         end
         gpu_check_touched("queued FILLs with settings");
      end else
         $display("NOTE:  GPU_FIFO_AW = %0d: the 15-word queued-FILL measurement needs a 16-word FIFO, skipped", GPU_FIFO_AW);

      gpu_check_touched("perf");
      gpu_check_all("perf end");
      // The 48 x 8 rectangles need DIM_W >= 6
      if ((VRAM_WORDS >= 38400) && ((GPU_BLEND_EN != 0) || ((GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0)))) begin
         if (DIM_W >= 6) tq_all;
         else $display("NOTE:  DIM_W = %0d: the RGB565A8 and bilinear measurements need 48-pixel rectangles, skipped", DIM_W);
      end
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
