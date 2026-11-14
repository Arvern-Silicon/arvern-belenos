//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_blend
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_blend.v
// Module Description : Blend unit, part 1 (16 bpp, GFX_MODE 4..7):
//                      SET_EXT sub 8 SET_ALPHA ([7:0] A, [8] EN, no operand)
//                      and EXEC_EXPAND [3] MASK with the 8 bpp source depth 3.
//                      Blended pixel, per channel (R5, G6, B5):
//                        out = d + (((s - d) * a + 128) >>> 8),
//                      a = A (255 -> 256: out = s). The walks are modelled
//                      in this file (bl_*), the blend arithmetic is the
//                      shared model's (gpu_blend565, gpu_a_mask), checked
//                      first against hand-computed values. Covered:
//                      - reset EN = 0; SET_ALPHA takes no operand, no ERR;
//                      - FILL / SPAN / COPY / COPY_TRANSP / TEXSPAN at
//                        A = 0 / 1 / 128 / 254 / 255 / random, modes 4..7,
//                        random destination, swaps, pitch 0 / explicit;
//                      - every RGB565 channel extreme over every other, both
//                        directions, eight alphas, with model-free oracles;
//                      - raster ops while blending (all 16 ops of FILL,
//                        COPY, COPY_TRANSP): 0..12 blend S, 13..15 blend
//                        their constant (0, ones, the fill colour) and keep
//                        the SET_TRANSP key; EXPAND MASK and EXPAND under
//                        SET_ALPHA EN (OPAQUE 0 / 1) with ops 13..15;
//                      - EN = 0 restores raster ops; re-enable;
//                      - result depends on the old destination (RMW);
//                      - palette modes 0..3: SET_ALPHA and MASK no effect;
//                      - EXPAND MASK at A1 / A2 / A4 / A8, SET_ALPHA off / on
//                        (alpha_eff = (am * A + 127) / 255, 0 skips, 255
//                        opaque), packed glyphs (pitch 0) and DELTA chains,
//                        the eight destination swaps, all-zero masks and
//                        A = 0 (no VRAM write at all, GPU_DONE raised);
//                      - EXPAND without MASK at source depth 3 = 8 bpp;
//                      - GPU_CTRL.ABORT / CTRL.GPU_EN = 0 mid-blend: clean
//                        prefix of the walk, then a full redraw;
//                      - debug freeze toggled mid-blend with VRAM-window
//                        traffic: final image equals the model.
//                      A pixel-granular VRAM write monitor flags any GPU write
//                      to a pixel the model skips (transparent source or
//                      texel, mask alpha 0); MASK cases also check the exact
//                      write count. Touched words are read through the VRAM
//                      window, the whole VRAM is compared through the
//                      backdoor. EXEC_TEXRECT, textured triangles, x/y
//                      clipping, the mask plane, the immediate source and
//                      gradients under blending: gpu_blend_x.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam  [3:0] BL_OP_SET_EXT = 4'h6;
localparam  [3:0] BL_OP_SPAN    = 4'hB;
localparam  [3:0] BL_OP_EXP     = 4'hC;
localparam  [3:0] BL_OP_TEX     = 4'hD;
localparam  [3:0] BL_OP_FENCE   = 4'hF;
localparam  [3:0] BL_EXT_TEX    = 4'h0;
localparam  [3:0] BL_EXT_UV     = 4'h1;
localparam  [3:0] BL_EXT_STEP   = 4'h2;
localparam  [3:0] BL_EXT_ALPHA  = 4'h8;

localparam integer BL_DPITCH = 29;
localparam integer BL_SPITCH = 41;
localparam integer BL_DISPW  = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer BL_WMAX   = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer BL_NSP    = (GPU_DIM_MASK >= 24) ? 24 : GPU_DIM_MASK;    // TEXSPAN in the matrix
localparam integer BL_NMAX   = (GPU_DIM_MASK >= 200) ? 200 : GPU_DIM_MASK;  // long TEXSPAN
localparam integer BL_EW     = (GPU_DIM_MASK >= 16) ? 16 : GPU_DIM_MASK;    // large rectangles
localparam integer BL_EH     = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer BL_SRC_LO = 40;               // sources / textures: words [BL_SRC_LO, BL_SRC_HI)
localparam integer BL_SRC_HI = 280;
localparam integer BL_A_LO   = 300;              // destination region A: words [BL_A_LO, BL_B_LO)
localparam integer BL_B_LO   = 580;              // destination region B: words [BL_B_LO, BL_D_HI)
localparam integer BL_D_HI   = 860;
localparam integer BL_BG_LO  = 880;              // VRAM-window background traffic: words [BL_BG_LO, BL_BG_HI)
localparam integer BL_BG_HI  = 990;
localparam integer BL_BLK    = 13 * BL_DPITCH;   // block spacing of the palette-mode section
localparam integer BL_MAXP   = 512;
localparam integer BL_WLMAX  = 4096;


//============================================================================
// Reference model state
//============================================================================
reg        bl_m_aen;                     // SET_ALPHA EN
reg  [7:0] bl_m_a;                       // SET_ALPHA A
reg  [3:0] bl_t_lw, bl_t_lh;             // SET_TEX
reg        bl_t_ten, bl_t_free;
reg  [2:0] bl_t_sw;
reg  [7:0] bl_t_shade;
reg [15:0] bl_t_u0, bl_t_v0, bl_t_du, bl_t_dv;

// Context of the EXEC being modelled
integer    bl_x_bl, bl_x_w, bl_x_h, bl_x_dp, bl_x_sp, bl_x_a;
reg [31:0] bl_x_db, bl_x_sb;
reg [15:0] bl_x_fill, bl_x_tr;
reg        bl_x_blend;

// Pixel statistics
integer    bl_n_bl, bl_n_op, bl_n_skip, bl_n_tr, bl_n_mz, bl_n_plain, bl_exp_nwr;
integer    bl_strict, bl_late, bl_none, bl_held_chk;

initial begin
   bl_m_aen   = 1'b0;
   bl_m_a     = 8'h00;
   bl_t_lw    = 4'd0;
   bl_t_lh    = 4'd0;
   bl_t_ten   = 1'b0;
   bl_t_free  = 1'b0;
   bl_t_sw    = 3'b000;
   bl_t_shade = 8'h00;
   bl_t_u0    = 16'h0;
   bl_t_v0    = 16'h0;
   bl_t_du    = 16'h0;
   bl_t_dv    = 16'h0;
   bl_n_bl    = 0;
   bl_n_op    = 0;
   bl_n_skip  = 0;
   bl_n_tr    = 0;
   bl_n_mz    = 0;
   bl_n_plain = 0;
   bl_exp_nwr = 0;
   bl_strict  = 0;
   bl_late    = 0;
   bl_none    = 0;
   bl_held_chk = 0;
end


//============================================================================
// Blend arithmetic: gpu_blend565, gpu_a_const, gpu_a_mask of the shared
// model (gpu_model.v), from the formula of the specification
//============================================================================


//============================================================================
// Helpers
//============================================================================
function integer bl_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      bl_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

// First pixel visited of a w x h walk with swaps sw = {X, Y, CL}, given the
// top-left pixel o of its bounding box (CL: w is the vertical run).
function [31:0] bl_first;
   input [31:0] o;
   input integer pitch;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows     = sw[0] ? w : h;
      cols     = sw[0] ? h : w;
      bl_first = o + (sw[1] ? (rows - 1) * pitch : 0) + (sw[2] ? (cols - 1) : 0);
   end
endfunction

function [31:0] bl_vpx;                  // pixel of the VRAM model (backdoor)
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   integer      off;
   begin
      wd     = pa >> (5 - bl);
      off    = (pa & ((32 >> bl) - 1)) << bl;
      bl_vpx = (wd < VRAM_WORDS) ? ((vram_mem[wd] >> off) & gpu_pmask(bl)) : 32'hxxxx_xxxx;
   end
endfunction

// Backdoor pixel load into both copies (GPU idle)
task bl_px_load;
   input [31:0] pa;
   input integer bl;
   input [31:0] val;
   reg   [31:0] wd;
   begin
      gpu_set_px(pa, bl, val);
      wd = pa >> (5 - bl);
      vram_mem[wd] = gpu_shadow[wd];
   end
endtask

task bl_rgn_src;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < BL_SRC_LO) || (gpu_word_of(pa, bl) >= BL_SRC_HI))
         tb_error("gpu_blend: source pixel outside the source region (test bug)");
   end
endtask

task bl_rgn_dst;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < BL_A_LO) || (gpu_word_of(pa, bl) >= BL_D_HI))
         tb_error("gpu_blend: destination pixel outside the regions (test bug)");
   end
endtask

task bl_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR | 32'hF000_0000);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask


//============================================================================
// Pixel-granular VRAM write monitor (16 bpp): every GPU write must hit a
// pixel the model writes. Window traffic in [BL_BG_LO, BL_BG_HI) is ignored
// while bl_wmon_bg is set.
//============================================================================
reg        bl_wok [0:2*VRAM_WORDS-1];
integer    bl_wl  [0:BL_WLMAX-1];
integer    bl_wln, bl_wi;
reg        bl_wl_ovf;
reg        bl_wmon_en, bl_wmon_bg;
integer    bl_wmon_n, bl_wmon_bad;

initial begin
   bl_wmon_en  = 1'b0;
   bl_wmon_bg  = 1'b0;
   bl_wmon_n   = 0;
   bl_wmon_bad = 0;
   bl_wln      = 0;
   bl_wl_ovf   = 1'b0;
   for (bl_wi = 0; bl_wi < 2 * VRAM_WORDS; bl_wi = bl_wi + 1)
      bl_wok[bl_wi] = 1'b0;
end

task bl_wmon_err;
   input integer half;
   begin
      bl_wmon_bad = bl_wmon_bad + 1;
      if (bl_wmon_bad <= 6)
         $display("ERROR: GPU wrote pixel %0d of word 0x%h (wen %b) that the model skips or never visits %t",
                  half, vram_addr, vram_wen, $time);
      error = error + 1;
   end
endtask

always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && bl_wmon_en && (vram_wen !== 4'hF) &&
      !(bl_wmon_bg && ({{(32-VRAM_AW){1'b0}}, vram_addr} >= BL_BG_LO) &&
                      ({{(32-VRAM_AW){1'b0}}, vram_addr} <  BL_BG_HI))) begin
     bl_wmon_n = bl_wmon_n + 1;
     if ((vram_wen[1:0] !== 2'b11) && (bl_wok[{vram_addr, 1'b0}] !== 1'b1)) bl_wmon_err(0);
     if ((vram_wen[3:2] !== 2'b11) && (bl_wok[{vram_addr, 1'b1}] !== 1'b1)) bl_wmon_err(1);
  end

task bl_wok_mark;
   input [31:0] pa;                      // 16 bpp pixel address
   begin
      if ((pa < 2 * VRAM_WORDS) && (bl_wok[pa] !== 1'b1)) begin
         bl_wok[pa] = 1'b1;
         if (bl_wln < BL_WLMAX) begin
            bl_wl[bl_wln] = pa;
            bl_wln        = bl_wln + 1;
         end else
            bl_wl_ovf = 1'b1;
      end
   end
endtask

task bl_wmon_start;
   integer kk;
   begin
      if (bl_wl_ovf) begin
         for (kk = 0; kk < 2 * VRAM_WORDS; kk = kk + 1)
            bl_wok[kk] = 1'b0;
      end else
         for (kk = 0; kk < bl_wln; kk = kk + 1)
            bl_wok[bl_wl[kk]] = 1'b0;
      bl_wln      = 0;
      bl_wl_ovf   = 1'b0;
      bl_wmon_n   = 0;
      bl_exp_nwr  = 0;
      bl_wmon_en  = 1'b1;
   end
endtask

// GPU idle: stop the monitor; exact = the write count must equal the
// model's: one write per word of consecutively written pixels
task bl_wmon_stop;
   input exact;
   begin
      bl_wmon_en = 1'b0;
      if (exact && (bl_wmon_n != bl_exp_nwr)) begin
         $display("ERROR: GPU made %0d VRAM writes / %0d pixels written by the model %t",
                  bl_wmon_n, bl_exp_nwr, $time);
         error = error + 1;
      end
   end
endtask

// End of a checked group: idle, monitor, no error, touched words
task bl_check;
   input [8*40-1:0] label;
   input            exact;
   begin
      gpu_wait_idle;
      bl_wmon_stop(exact);
      bl_no_err;
      gpu_check_touched(label);
   end
endtask


//============================================================================
// Walk record of one EXEC (abandon prefix)
//============================================================================
reg [31:0] bl_rpa  [0:BL_MAXP-1];
reg [31:0] bl_rold [0:BL_MAXP-1];
reg [31:0] bl_rnew [0:BL_MAXP-1];
reg        bl_rwr  [0:BL_MAXP-1];
integer    bl_rn, bl_rbl;
reg        bl_rec;
initial begin bl_rec = 1'b0; bl_rn = 0; bl_rbl = 4; end

task bl_rec_px;
   input [31:0] pa;
   input        wr;
   input [31:0] val;
   begin
      if (bl_rec) begin
         if (bl_rn >= BL_MAXP)
            tb_error("gpu_blend: walk record overflow (test bug)");
         else begin
            bl_rpa[bl_rn]  = pa;
            bl_rold[bl_rn] = gpu_get_px(pa, bl_rbl);
            bl_rnew[bl_rn] = val & gpu_pmask(bl_rbl);
            bl_rwr[bl_rn]  = wr;
            bl_rn          = bl_rn + 1;
         end
      end
   end
endtask

// Classify the recorded walk against VRAM after an abandon (GPU settled):
// cls 0 nothing drawn, 1 strict prefix, 2 whole walk, -1 not a prefix. The
// shadow is rebuilt from the old image plus the drawn prefix.
task bl_prefix_check;
   input          done;
   output integer cls;
   output integer ndrawn;
   integer        kk, maxd, minu, nbad;
   reg     [31:0] got;
   begin
      maxd = -1;
      minu = bl_rn;
      nbad = 0;
      for (kk = 0; kk < bl_rn; kk = kk + 1) begin
         got = bl_vpx(bl_rpa[kk], bl_rbl);
         if (bl_rwr[kk] && (bl_rnew[kk] != bl_rold[kk])) begin
            if (got === bl_rnew[kk]) begin
               if (kk > maxd) maxd = kk;
            end else if (got === bl_rold[kk]) begin
               if (kk < minu) minu = kk;
            end else begin
               nbad = nbad + 1;
               if (nbad <= 4)
                  $display("ERROR: abandoned blend pixel %0d (0x%h) = 0x%h, neither old 0x%h nor new 0x%h %t",
                           kk, bl_rpa[kk], got, bl_rold[kk], bl_rnew[kk], $time);
            end
         end else if (got !== bl_rold[kk]) begin
            nbad = nbad + 1;
            if (nbad <= 4)
               $display("ERROR: abandoned blend pixel %0d (0x%h) = 0x%h, expected unchanged 0x%h (%0s) %t",
                        kk, bl_rpa[kk], got, bl_rold[kk], bl_rwr[kk] ? "same value" : "skipped", $time);
         end
      end
      ndrawn = maxd + 1;
      if (nbad != 0) begin
         error = error + nbad;
         cls   = -1;
      end else if (maxd > minu) begin
         $display("ERROR: abandoned blend is not a prefix: pixel %0d drawn after undrawn pixel %0d (of %0d) %t",
                  maxd, minu, bl_rn, $time);
         error = error + 1;
         cls   = -1;
      end else if (minu == bl_rn)
         cls = 2;
      else if (maxd < 0)
         cls = 0;
      else
         cls = 1;
      if (done && (cls != 2)) begin
         $display("ERROR: GPU_DONE raised for an abandoned blend (%0d drawn, first undrawn %0d of %0d) %t",
                  ndrawn, minu, bl_rn, $time);
         error = error + 1;
      end
      for (kk = 0; kk < bl_rn; kk = kk + 1)
         gpu_set_px(bl_rpa[kk], bl_rbl, bl_rold[kk]);
      if (cls < 0) begin
         for (kk = 0; kk < bl_rn; kk = kk + 1)
            gpu_set_px(bl_rpa[kk], bl_rbl, bl_vpx(bl_rpa[kk], bl_rbl));
      end else
         for (kk = 0; kk < ndrawn; kk = kk + 1)
            if (bl_rwr[kk]) gpu_set_px(bl_rpa[kk], bl_rbl, bl_rnew[kk]);
   end
endtask


//============================================================================
// Model: context, one pixel, commands
//============================================================================
integer bl_lw;                           // word of the last written pixel (-1: none)
initial bl_lw = -1;
reg [3:0] bl_exp_op;                     // raster op of bl_exp (blended EXPANDs only)
initial bl_exp_op = 4'd0;

task bl_ctx;
   begin
      bl_lw      = -1;
      bl_x_bl    = gpu_bl(gpu_m_mode);
      bl_x_w     = gpu_m_w;
      bl_x_h     = gpu_m_h;
      bl_x_dp    = (gpu_m_dst_pitch == 16'h0) ? gpu_m_dispw : gpu_m_dst_pitch;
      bl_x_sp    = (gpu_m_src_pitch == 16'h0) ? gpu_m_dispw : gpu_m_src_pitch;
      bl_x_db    = gpu_m_dst_base;
      bl_x_sb    = gpu_m_src_base;
      bl_x_fill  = gpu_m_fill;
      bl_x_tr    = gpu_m_transp;
      bl_x_blend = bl_m_aen && (bl_x_bl == 4);
      bl_x_a     = gpu_a_const(bl_m_a);
      if (bl_rec) begin
         bl_rn  = 0;
         bl_rbl = bl_x_bl;
      end
   end
endtask

// One destination pixel: skipped, written plain (val, low bpp bits), or
// blended with alpha a (256 = opaque) over the current destination
task bl_apply;
   input [31:0] pa;
   input        skip;
   input [31:0] val;
   input        blend;
   input integer a;
   reg   [31:0] dd, rr;
   begin
      bl_rgn_dst(pa, bl_x_bl);
      gpu_touch_px(pa, bl_x_bl);
      if (skip) begin
         bl_n_skip = bl_n_skip + 1;
         bl_rec_px(pa, 1'b0, 32'h0);
      end else begin
         dd = gpu_get_px(pa, bl_x_bl);
         if (!blend) begin
            rr         = val & gpu_pmask(bl_x_bl);
            bl_n_plain = bl_n_plain + 1;
         end else if (a >= 256) begin
            rr         = val & 32'hFFFF;
            bl_n_op    = bl_n_op + 1;
         end else begin
            rr         = {16'h0, gpu_blend565(val[15:0], dd[15:0], a)};
            bl_n_bl    = bl_n_bl + 1;
         end
         bl_rec_px(pa, 1'b1, rr);
         gpu_set_px(pa, bl_x_bl, rr);
         if (bl_x_bl == 4) bl_wok_mark(pa);
         if ((pa >> (5 - bl_x_bl)) != bl_lw) bl_exp_nwr = bl_exp_nwr + 1;   // one write per word of consecutive pixels
         bl_lw = pa >> (5 - bl_x_bl);
      end
   end
endtask

task bl_move;
   input [13:0] d14;
   begin
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
   end
endtask

task bl_c_alpha;
   input       en;
   input [7:0] a;
   begin
      gpu_c_alpha(en, a);                // (the shared model's state too)
      bl_m_aen = en;
      bl_m_a   = a;
   end
endtask

task bl_c_tex;
   input  [3:0] lw;
   input  [3:0] lh;
   input        ten;
   input  [2:0] sw;                      // {X, Y, CL}
   input        free;
   input  [7:0] shade;
   begin
      gpu_push({BL_OP_SET_EXT, BL_EXT_TEX, shade, 3'b000, free, sw, ten, lh, lw});
      bl_t_lw    = lw;
      bl_t_lh    = lh;
      bl_t_ten   = ten;
      bl_t_sw    = sw;
      bl_t_free  = free;
      bl_t_shade = shade;
   end
endtask

task bl_c_uv;
   input [15:0] u0;                      // unsigned 10.6
   input [15:0] v0;
   begin
      gpu_push({BL_OP_SET_EXT, BL_EXT_UV, 24'h0});
      gpu_push({u0, v0});
      bl_t_u0 = u0;
      bl_t_v0 = v0;
   end
endtask

task bl_c_step;
   input [15:0] du;                      // signed 5.11
   input [15:0] dv;
   begin
      gpu_push({BL_OP_SET_EXT, BL_EXT_STEP, 24'h0});
      gpu_push({du, dv});
      bl_t_du = du;
      bl_t_dv = dv;
   end
endtask

// The blend source of a raster op: S for ops 0..12, the constant of 13..15
function [31:0] bl_konst;
   input  [3:0] op;
   input [31:0] ss;
   begin
      case (op)
        4'd13:   bl_konst = 32'h0000_0000;
        4'd14:   bl_konst = 32'h0000_FFFF;
        4'd15:   bl_konst = {16'h0, bl_x_fill};
        default: bl_konst = ss;
      endcase
   end
endfunction

// FILL / COPY / COPY_TRANSP. Blending (EN, 16 bpp): ops 0..12 blend S, ops
// 13..15 their constant (0, ones, the fill colour); COPY_TRANSP and ops
// 13..15 skip S == TRANSP. Otherwise the shared raster-op model.
task bl_c_exec;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   reg   [31:0] spa, dpa, ss;
   reg          sk;
   integer      kk;
   begin
      if (!(bl_m_aen && (gpu_bl(gpu_m_mode) == 4))) begin
         if (bl_rec || bl_wmon_en)
            tb_error("gpu_blend: plain EXEC with record / write monitor on (test bug)");
         gpu_c_exec(cmd, op, dsw, ssw);
      end else begin
         gpu_push(gpu_exec_word(cmd, op, dsw, ssw));
         bl_ctx;
         for (kk = 0; kk < bl_x_w * bl_x_h; kk = kk + 1) begin
            dpa = gpu_walk(bl_x_db, bl_x_dp, dsw, bl_x_w, kk);
            if (cmd == GPU_FILL)
               ss = {16'h0, bl_x_fill};
            else begin
               spa = gpu_walk(bl_x_sb, bl_x_sp, ssw, bl_x_w, kk);
               bl_rgn_src(spa, 4);
               ss  = gpu_get_px(spa, 4);
            end
            sk = ((cmd == GPU_COPYT) || (op >= 4'd13)) && (ss[15:0] == bl_x_tr);
            if (sk) bl_n_tr = bl_n_tr + 1;
            bl_apply(dpa, sk, bl_konst(op, ss), 1'b1, bl_x_a);
         end
      end
   end
endtask

// EXEC_SPAN: move, width x 1, FILL op 0 (blended with EN at 16 bpp)
task bl_span;
   input integer delta;
   input  [13:0] width;
   reg    [13:0] d14;
   integer       kk;
   begin
      d14 = delta;
      gpu_push({BL_OP_SPAN, d14, width});
      bl_move(d14);
      gpu_m_w = ((width & GPU_DIM_MASK) == 0) ? 1 : (width & GPU_DIM_MASK);
      gpu_m_h = 1;
      bl_ctx;
      for (kk = 0; kk < bl_x_w; kk = kk + 1)
         bl_apply(gpu_walk(bl_x_db, bl_x_dp, 3'b000, bl_x_w, kk), 1'b0, {16'h0, bl_x_fill},
                  bl_x_blend, bl_x_a);
   end
endtask

// EXEC_TEXSPAN (no BOUND): move, N x 1, texel + SHADE, TRANSP_EN skips;
// blended with EN at 16 bpp (source = texel + SHADE)
task bl_tex;
   input integer delta;
   input  [13:0] n;
   reg    [13:0] d14;
   reg    [20:0] ua, va, dua, dva;
   reg    [31:0] spa, dpa, tt, pm;
   integer       kk, lw, lh, pitch, ui, vi;
   begin
      d14 = delta;
      gpu_src_fmt(4'h0);
      gpu_push({BL_OP_TEX, d14, n});
      bl_move(d14);
      gpu_m_w = ((n & GPU_DIM_MASK) == 0) ? 1 : (n & GPU_DIM_MASK);
      gpu_m_h = 1;
      bl_ctx;
      pm    = gpu_pmask(bl_x_bl);
      lw    = (bl_t_lw > 4'd10) ? 10 : bl_t_lw;
      lh    = (bl_t_lh > 4'd10) ? 10 : bl_t_lh;
      pitch = bl_t_free ? bl_x_sp : (1 << lw);
      ua    = {bl_t_u0, 5'b00000};
      va    = {bl_t_v0, 5'b00000};
      dua   = {{5{bl_t_du[15]}}, bl_t_du};
      dva   = {{5{bl_t_dv[15]}}, bl_t_dv};
      for (kk = 0; kk < bl_x_w; kk = kk + 1) begin
         ui = ua[20:11];
         vi = va[20:11];
         if (!bl_t_free) begin
            ui = ui & ((1 << lw) - 1);
            vi = vi & ((1 << lh) - 1);
         end
         spa = (bl_x_sb + vi * pitch + ui) & GPU_PA_MASK;
         bl_rgn_src(spa, bl_x_bl);
         tt  = gpu_get_px(spa, bl_x_bl);
         dpa = gpu_walk(bl_x_db, bl_x_dp, bl_t_sw, bl_x_w, kk);
         if (bl_t_ten && (tt == (bl_x_tr & pm))) begin
            bl_n_tr = bl_n_tr + 1;
            bl_apply(dpa, 1'b1, 32'h0, 1'b0, 0);
         end else
            bl_apply(dpa, 1'b0, (tt + bl_t_shade) & pm, bl_x_blend, bl_x_a);
         ua = ua + dua;
         va = va + dva;
      end
   end
endtask

// EXEC_EXPAND: source depth 0/1/2/3 = 1/2/4/8 bpp, pitch 0 = width, no
// source swaps, raster op bl_exp_op (blended EXPANDs only). 16 bpp with MASK:
// coverage alpha, fill colour (ops 13..15: their constant), 0 skips.
// Otherwise the ramp: v >= 1 -> fill + v - 1, v = 0 -> skip or TRANSP
// (OPAQUE); blended with A under SET_ALPHA EN at 16 bpp (ops 13..15: their
// constant at the pixels drawn).
task bl_exp;
   input integer delta;
   input   [2:0] dsw;                    // {X, Y, CL}
   input         opaque;
   input   [1:0] sdep;
   input         mask;
   reg    [13:0] d14;
   reg    [31:0] spa, dpa, vv;
   reg           m16;
   integer       kk, sbl, spitch, ae;
   begin
      d14 = delta;
      gpu_src_fmt({2'b00, sdep} + 4'd1);                 // SRC_FMT 1-4 = 1/2/4/8 bpp
      gpu_push({BL_OP_EXP, d14, 2'b00, bl_exp_op, 1'b0, dsw, mask, opaque, 2'b00});
      bl_move(d14);
      bl_ctx;
      sbl    = sdep;
      spitch = (gpu_m_src_pitch == 16'h0) ? bl_x_w : gpu_m_src_pitch;
      m16    = (bl_x_bl == 4);
      if ((bl_exp_op != 4'd0) && !(m16 && (mask || bl_m_aen)))
         tb_error("gpu_blend: EXPAND raster op modelled only when blended (test bug)");
      if (m16 && mask && opaque)
         tb_error("gpu_blend: EXPAND MASK + OPAQUE not in this model (gpu_blend_x covers it; test bug)");
      for (kk = 0; kk < bl_x_w * bl_x_h; kk = kk + 1) begin
         spa = (bl_x_sb + (kk / bl_x_w) * spitch + (kk % bl_x_w)) & GPU_PA_MASK;
         bl_rgn_src(spa, sbl);
         vv  = gpu_get_px(spa, sbl);
         dpa = gpu_walk(bl_x_db, bl_x_dp, dsw, bl_x_w, kk);
         if (m16 && mask) begin
            ae = gpu_a_mask(vv, sdep, bl_m_aen, bl_m_a);
            if (ae == 0) bl_n_mz = bl_n_mz + 1;
            bl_apply(dpa, ae == 0, bl_konst(bl_exp_op, {16'h0, bl_x_fill}), 1'b1, ae);
         end else if (m16 && bl_m_aen) begin
            if (vv != 32'h0)
               bl_apply(dpa, 1'b0, bl_konst(bl_exp_op, (bl_x_fill + vv - 32'h1) & 32'hFFFF), 1'b1, bl_x_a);
            else if (opaque)
               bl_apply(dpa, 1'b0, bl_konst(bl_exp_op, {16'h0, bl_x_tr}), 1'b1, bl_x_a);
            else
               bl_apply(dpa, 1'b1, 32'h0, 1'b0, 0);
         end else if (vv != 32'h0)
            bl_apply(dpa, 1'b0, bl_x_fill + vv - 32'h1, 1'b0, 0);
         else if (opaque)
            bl_apply(dpa, 1'b0, {16'h0, bl_x_tr}, 1'b0, 0);
         else
            bl_apply(dpa, 1'b1, 32'h0, 1'b0, 0);
      end
   end
endtask

// Mask / ramp source at source depth sdep in the whole source region
task bl_mask_src;
   input [1:0] sdep;
   begin
      case (sdep)
        2'd0:    gpu_preload_rand(BL_SRC_LO, BL_SRC_HI);
        2'd1:    gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 1, 16'h0, 16'h1, 16'h2, 16'h3);
        2'd2:    gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 2, 16'h0, 16'hF, $random(gpu_seed), $random(gpu_seed));
        default: gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 3, 16'h0, 16'hFF, $random(gpu_seed), $random(gpu_seed));
      endcase
   end
endtask

// Free-pitch texture coordinates for an n-pixel span (stays within 41 x 6)
task bl_free_uv;
   input integer n;
   integer       lu, lv;
   begin
      lu = (28 * 2048) / n;
      if (lu > 32767) lu = 32767;
      lv = (3 * 2048) / n;
      if (lv > 32767) lv = 32767;
      if (bl_rnd(2))
         bl_c_uv(((2 + bl_rnd(2)) << 6) | bl_rnd(64), (bl_rnd(2) << 6) | bl_rnd(64));
      else
         bl_c_uv(((30 + bl_rnd(2)) << 6) | bl_rnd(64), (bl_rnd(2) << 6) | bl_rnd(64));
      if (bl_t_u0[15:6] >= 10'd30) bl_c_step(-bl_rnd(lu + 1), bl_rnd(lv + 1));
      else                         bl_c_step( bl_rnd(lu + 1), bl_rnd(lv + 1));
   end
endtask


//============================================================================
// Background VRAM-window manager (own v-port driver; region BL_BG only)
//============================================================================
reg        bl_bg_en, bl_bg_busy;
integer    bl_bg_seed, bl_bg_nw, bl_bg_nr;
reg [31:0] bl_bg_addr, bl_bg_data, bl_bg_raw, bl_bg_exp, bl_bg_lane;
reg  [1:0] bl_bg_size;
reg        bl_bg_wr;
initial begin bl_bg_en = 1'b0; bl_bg_busy = 1'b0; bl_bg_nw = 0; bl_bg_nr = 0; end

always begin : bl_bg
   @(negedge free_clk);
   if (bl_bg_en) begin
      bl_bg_busy = 1'b1;
      bl_bg_wr   = $random(bl_bg_seed);
      bl_bg_size = {$random(bl_bg_seed)} % 3;
      bl_bg_addr = 4 * (BL_BG_LO + ({$random(bl_bg_seed)} % (BL_BG_HI - BL_BG_LO))) + ({$random(bl_bg_seed)} & 3);
      bl_bg_addr = (bl_bg_size == SZ_W) ? (bl_bg_addr & ~32'h3) : (bl_bg_size == SZ_H) ? (bl_bg_addr & ~32'h1) : bl_bg_addr;
      bl_bg_data = $random(bl_bg_seed);
      bl_bg_lane = (bl_bg_size == SZ_B) ? {4{bl_bg_data[7:0]}} : (bl_bg_size == SZ_H) ? {2{bl_bg_data[15:0]}} : bl_bg_data;
      while (v_hready !== 1'b1) @(negedge free_clk);
      v_hsel = 1'b1; v_haddr = bl_bg_addr; v_htrans = 2'b10; v_hwrite = bl_bg_wr;
      v_hsize = {1'b0, bl_bg_size}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
      if (bl_bg_wr) v_hwdata = bl_bg_lane;
      @(negedge free_clk);
      while (v_hready !== 1'b1) @(negedge free_clk);
      bl_bg_raw = v_hrdata;
      if (v_hresp !== 1'b0) begin
         $display("ERROR: background window access 0x%h got ERROR %t", bl_bg_addr, $time);
         error = error + 1;
      end
      @(posedge free_clk);
      if (bl_bg_wr) begin
         if (bl_bg_size == SZ_W) gpu_shadow[bl_bg_addr >> 2] = bl_bg_lane;
         else if (bl_bg_size == SZ_H) begin
            if (bl_bg_addr[1]) gpu_shadow[bl_bg_addr >> 2][31:16] = bl_bg_lane[15:0];
            else               gpu_shadow[bl_bg_addr >> 2][15:0]  = bl_bg_lane[15:0];
         end else
            case (bl_bg_addr[1:0])
              2'd0:    gpu_shadow[bl_bg_addr >> 2][ 7: 0] = bl_bg_lane[7:0];
              2'd1:    gpu_shadow[bl_bg_addr >> 2][15: 8] = bl_bg_lane[7:0];
              2'd2:    gpu_shadow[bl_bg_addr >> 2][23:16] = bl_bg_lane[7:0];
              default: gpu_shadow[bl_bg_addr >> 2][31:24] = bl_bg_lane[7:0];
            endcase
         bl_bg_nw = bl_bg_nw + 1;
      end else begin
         bl_bg_exp = gpu_shadow[bl_bg_addr >> 2];
         bl_bg_exp = (bl_bg_size == SZ_B) ? ((bl_bg_exp >> (8 * bl_bg_addr[1:0])) & 32'hFF) :
                     (bl_bg_size == SZ_H) ? ((bl_bg_exp >> (16 * bl_bg_addr[1])) & 32'hFFFF) : bl_bg_exp;
         bl_bg_raw = (bl_bg_size == SZ_B) ? ((bl_bg_raw >> (8 * bl_bg_addr[1:0])) & 32'hFF) :
                     (bl_bg_size == SZ_H) ? ((bl_bg_raw >> (16 * bl_bg_addr[1])) & 32'hFFFF) : bl_bg_raw;
         if (bl_bg_raw !== bl_bg_exp) begin
            $display("ERROR: background window read 0x%h = 0x%h / expected 0x%h %t", bl_bg_addr, bl_bg_raw, bl_bg_exp, $time);
            error = error + 1;
         end
         bl_bg_nr = bl_bg_nr + 1;
      end
      bl_bg_busy = 1'b0;
      repeat({$random(bl_bg_seed)} % 6) @(negedge free_clk);
   end
end

task bl_bg_pause;
   begin
      bl_bg_en = 1'b0;
      while (bl_bg_busy) @(negedge free_clk);
      @(negedge free_clk);
   end
endtask


//============================================================================
// 0. Model self-test against hand-computed values
//============================================================================
task bl_st16;
   input [15:0]     got;
   input [15:0]     exp;
   input [8*40-1:0] label;
   begin
      if (got !== exp) begin
         $display("ERROR: blend model self-test %0s = 0x%h / expected 0x%h (test bug)", label, got, exp);
         error = error + 1;
      end
   end
endtask

task bl_sti;
   input integer    got;
   input integer    exp;
   input [8*40-1:0] label;
   begin
      if (got != exp) begin
         $display("ERROR: blend model self-test %0s = %0d / expected %0d (test bug)", label, got, exp);
         error = error + 1;
      end
   end
endtask

task bl_selftest;
   integer mm;
   begin
      bl_st16(gpu_blend565(16'hFFFF, 16'h0000, 128), 16'h8410, "FFFF over 0000, a 128");
      bl_st16(gpu_blend565(16'h0000, 16'hFFFF, 128), 16'h8410, "0000 over FFFF, a 128");
      bl_st16(gpu_blend565(16'hFFFF, 16'h0000, 129), 16'h8410, "FFFF over 0000, a 129");
      bl_st16(gpu_blend565(16'hFFFF, 16'h0000,   1), 16'h0000, "FFFF over 0000, a 1");
      bl_st16(gpu_blend565(16'h0000, 16'hFFFF,   1), 16'hFFFF, "0000 over FFFF, a 1");
      bl_st16(gpu_blend565(16'hFFFF, 16'h0000, 254), 16'hFFFF, "FFFF over 0000, a 254");
      bl_st16(gpu_blend565(16'h0000, 16'hFFFF, 254), 16'h0000, "0000 over FFFF, a 254");
      bl_st16(gpu_blend565(16'hF800, 16'h001F, 128), 16'h8010, "F800 over 001F, a 128");
      bl_st16(gpu_blend565(16'h1234, 16'h5678,   0), 16'h5678, "a 0 keeps the destination");
      bl_st16(gpu_blend565(16'h1234, 16'h5678, 256), 16'h1234, "a 256 writes the source");
      bl_sti(gpu_a_const(8'd255), 256, "A 255 counts as 256");
      bl_sti(gpu_a_const(8'd254), 254, "A 254");
      bl_sti(gpu_a_mask(32'd1,   2'd0, 1'b0, 8'd0),   256, "A1 v 1");
      bl_sti(gpu_a_mask(32'd0,   2'd0, 1'b0, 8'd0),     0, "A1 v 0");
      bl_sti(gpu_a_mask(32'd2,   2'd1, 1'b0, 8'd0),   170, "A2 v 2");
      bl_sti(gpu_a_mask(32'd3,   2'd1, 1'b0, 8'd0),   256, "A2 v 3");
      bl_sti(gpu_a_mask(32'd8,   2'd2, 1'b0, 8'd0),   136, "A4 v 8");
      bl_sti(gpu_a_mask(32'd8,   2'd2, 1'b1, 8'd128),  68, "A4 v 8, A 128");
      bl_sti(gpu_a_mask(32'd200, 2'd3, 1'b1, 8'd0),     0, "A8 v 200, A 0");
      bl_sti(gpu_a_mask(32'd255, 2'd3, 1'b1, 8'd1),     1, "A8 v 255, A 1");
      bl_sti(gpu_a_mask(32'd1,   2'd3, 1'b1, 8'd127),   0, "A8 v 1, A 127");
      bl_sti(gpu_a_mask(32'd2,   2'd3, 1'b1, 8'd127),   1, "A8 v 2, A 127");
      bl_sti(gpu_a_mask(32'd254, 2'd3, 1'b1, 8'd127), 127, "A8 v 254, A 127");
      for (mm = 0; mm < 255; mm = mm + 1)
         bl_sti(gpu_a_mask(mm, 2'd3, 1'b1, 8'd255), mm, "A8 v m, A 255 = m");
      bl_sti(gpu_a_mask(32'd255, 2'd3, 1'b1, 8'd255), 256, "A8 v 255, A 255");
      if (error == 0) $display("OK:    blend reference model self-test");
   end
endtask


//============================================================================
// 1. Reset (EN = 0), SET_ALPHA has no operand and raises no ERR
//============================================================================
task bl_sec_reset;
   reg [31:0] o;
   begin
      $display("--- reset: EN = 0; SET_ALPHA without operand");
      gpu_set_mode(4);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      o = BL_A_LO * 2 + 40;
      gpu_c_size(6, 3);
      gpu_c_dst(BL_DPITCH, o);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp(32'h0);
      bl_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);           // XOR: no SET_ALPHA yet, raster op applies
      gpu_wait_idle;
      bl_no_err;
      gpu_check_touched("reset: plain XOR fill at 16 bpp");
      // SET_ALPHA immediately followed by an EXEC: an operand would swallow it
      gpu_c_dst(BL_DPITCH, o + 4 * BL_DPITCH);
      bl_wmon_start;
      bl_c_alpha(1'b1, 8'd128);
      bl_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      bl_c_alpha(1'b1, 8'd200);
      bl_c_exec(GPU_FILL, 4'd0, 3'b001, 3'b000);
      bl_check("SET_ALPHA then EXEC (no operand)", 1'b0);
   end
endtask


//============================================================================
// 2. Constant alpha: FILL / SPAN / COPY / COPY_TRANSP / TEXSPAN
//============================================================================
task bl_const_case;
   input integer kind;                   // 0 FILL, 1 SPAN, 2 COPY, 3 COPY_TRANSP, 4 TEXSPAN
   input   [7:0] a;
   input integer mode;
   integer    w, h, n, sp, pitch, spp, spitch, delta;
   reg [31:0] o, so, tb, tr, fl;
   reg  [2:0] dsw, ssw;
   reg  [3:0] op;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      bl_c_alpha(1'b1, a);
      w     = 1 + bl_rnd(BL_WMAX);
      h     = 1 + bl_rnd(6);
      dsw   = $random(gpu_seed);
      ssw   = $random(gpu_seed);
      sp    = (bl_rnd(3) == 0) ? 0 : BL_DPITCH;
      pitch = (sp == 0) ? BL_DISPW : sp;
      o     = BL_A_LO * 2 + 40 + bl_rnd(2);
      fl    = $random(gpu_seed);
      gpu_c_fill(fl);
      gpu_c_size(w, h);
      bl_wmon_start;
      case (kind)
        0: begin
           op = $random(gpu_seed);
           gpu_c_transp(~fl);
           gpu_c_dst(sp, bl_first(o, pitch, dsw, w, h));
           bl_c_exec(GPU_FILL, op, dsw, 3'b000);
           $display("       FILL A %0d mode %0d %0dx%0d op %0d sw %b pitch %0d", a, mode, w, h, op, dsw, sp);
        end
        1: begin
           delta = bl_rnd(32) - 16;
           gpu_c_dst(sp, o - delta);
           bl_span(delta, w);
           bl_span(pitch, 1 + bl_rnd(BL_WMAX));
           bl_span(pitch + 3, 1 + bl_rnd(BL_WMAX));
           bl_span(-2, 1 + bl_rnd(BL_WMAX));
           $display("       SPAN A %0d mode %0d widths ..%0d pitch %0d", a, mode, w, sp);
        end
        2, 3: begin
           op     = (kind == 2) ? bl_rnd(13) : $random(gpu_seed);
           tr     = $random(gpu_seed);
           if (kind == 2) begin
              gpu_preload_rand(BL_SRC_LO, BL_SRC_HI);
              gpu_c_transp(tr);
           end else begin
              gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, tr, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
              gpu_c_transp(tr | 32'hA5A5_0000);
           end
           spp    = bl_rnd(2) ? 0 : BL_SPITCH;
           spitch = (spp == 0) ? BL_DISPW : spp;
           so     = BL_SRC_LO * 2 + 2 + bl_rnd(2);
           gpu_c_src(spp, bl_first(so, spitch, ssw, w, h));
           gpu_c_dst(sp, bl_first(o, pitch, dsw, w, h));
           bl_c_exec((kind == 2) ? GPU_COPY : GPU_COPYT, op, dsw, ssw);
           $display("       %0s A %0d mode %0d %0dx%0d op %0d dsw %b ssw %b spitch %0d dpitch %0d",
                    (kind == 2) ? "COPY" : "COPY_TRANSP", a, mode, w, h, op, dsw, ssw, spp, sp);
        end
        default: begin
           n     = 1 + bl_rnd(BL_NSP);
           tr    = $random(gpu_seed);
           gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, tr, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
           gpu_c_transp(tr);
           tb    = BL_SRC_LO * 2 + 16 + bl_rnd(2);
           delta = bl_rnd(32) - 16;
           gpu_c_dst(sp, bl_first(o, pitch, dsw, n, 1) - delta);
           if (bl_rnd(2)) begin
              gpu_c_src(16'd117, tb);                       // pitch ignored with FREE_PITCH 0
              bl_c_tex(4'd4, 4'd3, 1'b1, dsw, 1'b0, 8'd0);
              bl_c_uv($random(gpu_seed), $random(gpu_seed));
              bl_c_step($random(gpu_seed), $random(gpu_seed));
           end else begin
              gpu_c_src(BL_SPITCH, tb);
              bl_c_tex($random(gpu_seed), $random(gpu_seed), 1'b1, dsw, 1'b1, 8'd0);
              bl_free_uv(n);
           end
           bl_tex(delta, n);
           $display("       TEXSPAN A %0d mode %0d N %0d sw %b free %0d pitch %0d", a, mode, n, dsw, bl_t_free, sp);
        end
      endcase
      bl_check("constant alpha", 1'b0);
   end
endtask

task bl_sec_const;
   integer rep, ai, kind;
   reg [7:0] a;
   begin
      $display("--- constant alpha: FILL / SPAN / COPY / COPY_TRANSP / TEXSPAN x A x mode 4..7");
      for (rep = 0; rep < 2; rep = rep + 1)
         for (ai = 0; ai < 6; ai = ai + 1)
            for (kind = 0; kind < 5; kind = kind + 1) begin
               a = (ai == 0) ? 8'd0 : (ai == 1) ? 8'd1 : (ai == 2) ? 8'd128 :
                   (ai == 3) ? 8'd254 : (ai == 4) ? 8'd255 : $random(gpu_seed);
               bl_const_case(kind, a, 4 + ((rep * 3 + ai + kind) % 4));
            end
      // TEXSPAN with SHADE: blended source = texel + SHADE (assumption, see notes)
      $display("--- TEXSPAN with SHADE under blending (source = texel + SHADE)");
      gpu_set_mode(4);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, 16'h1234, $random(gpu_seed), $random(gpu_seed), 16'hFFF0);
      gpu_c_transp(16'h1234);
      gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 40);
      gpu_c_src(16'd0, BL_SRC_LO * 2 + 16);
      bl_c_alpha(1'b1, 8'd96);
      bl_c_tex(4'd4, 4'd3, 1'b1, 3'b000, 1'b0, 8'h2D);
      bl_c_uv($random(gpu_seed), $random(gpu_seed));
      bl_c_step($random(gpu_seed), $random(gpu_seed));
      bl_wmon_start;
      bl_tex(0, BL_NSP);
      bl_c_alpha(1'b1, 8'd255);
      bl_tex(2 * BL_DPITCH, BL_NSP);
      bl_check("TEXSPAN + SHADE blended", 1'b0);
      gpu_check_all("constant alpha");
   end
endtask


//============================================================================
// 3. Channel extremes: 8 x 8 COPY, source column c over destination row r
//============================================================================
function [15:0] bl_ev;
   input integer i;
   begin
      case (i)
        0: bl_ev = 16'h0000;
        1: bl_ev = 16'hFFFF;
        2: bl_ev = 16'hF800;
        3: bl_ev = 16'h07E0;
        4: bl_ev = 16'h001F;
        5: bl_ev = 16'h07FF;
        6: bl_ev = 16'hF81F;
        default: bl_ev = 16'hFFE0;
      endcase
   end
endfunction

task bl_xchk;                            // model-free oracle on one pixel
   input [31:0]     pa;
   input [15:0]     exp;
   input [8*40-1:0] label;
   reg   [31:0]     got;
   begin
      got = bl_vpx(pa, 4);
      if (got[15:0] !== exp) begin
         $display("ERROR: extremes %0s: pixel 0x%h = 0x%h / expected 0x%h %t", label, pa, got, exp, $time);
         error = error + 1;
      end
   end
endtask

task bl_sec_extremes;
   integer    ai, r, c, nbad;
   reg  [7:0] a;
   reg [31:0] so, o;
   begin
      $display("--- channel extremes, both directions");
      gpu_set_mode(4);
      so = BL_SRC_LO * 2 + 16;                             // word aligned
      o  = BL_A_LO * 2 + 40;
      for (ai = 0; ai < 8; ai = ai + 1) begin
         a = (ai == 0) ? 8'd0 : (ai == 1) ? 8'd1 : (ai == 2) ? 8'd2 : (ai == 3) ? 8'd127 :
             (ai == 4) ? 8'd128 : (ai == 5) ? 8'd129 : (ai == 6) ? 8'd254 : 8'd255;
         gpu_wait_idle;
         for (r = 0; r < 8; r = r + 1)
            for (c = 0; c < 8; c = c + 1) begin
               bl_px_load(so + r * 8 + c, 4, bl_ev(c));
               bl_px_load(o + r * BL_DPITCH + c, 4, bl_ev(r));
            end
         gpu_c_src(16'd8, so);
         gpu_c_dst(BL_DPITCH, o);
         gpu_c_size(8, 8);
         bl_c_alpha(1'b1, a);
         bl_wmon_start;
         bl_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
         $display("       A %0d", a);
         bl_check("channel extremes", 1'b0);
         nbad = error;
         for (r = 0; r < 8; r = r + 1)
            for (c = 0; c < 8; c = c + 1) begin
               if (a == 8'd0)   bl_xchk(o + r * BL_DPITCH + c, bl_ev(r), "A 0 keeps the destination");
               if (a == 8'd255) bl_xchk(o + r * BL_DPITCH + c, bl_ev(c), "A 255 writes the source");
            end
         if (a == 8'd128) begin
            bl_xchk(o + 0 * BL_DPITCH + 1, 16'h8410, "FFFF over 0000, A 128");
            bl_xchk(o + 1 * BL_DPITCH + 0, 16'h8410, "0000 over FFFF, A 128");
            bl_xchk(o + 4 * BL_DPITCH + 2, 16'h8010, "F800 over 001F, A 128");
         end
         if (a == 8'd1) begin
            bl_xchk(o + 0 * BL_DPITCH + 1, 16'h0000, "FFFF over 0000, A 1");
            bl_xchk(o + 1 * BL_DPITCH + 0, 16'hFFFF, "0000 over FFFF, A 1");
         end
         if (a == 8'd254) begin
            bl_xchk(o + 0 * BL_DPITCH + 1, 16'hFFFF, "FFFF over 0000, A 254");
            bl_xchk(o + 1 * BL_DPITCH + 0, 16'h0000, "0000 over FFFF, A 254");
         end
         if (error == nbad) $display("OK:    channel extremes A %0d: model-free oracles", a);
      end
      gpu_check_all("channel extremes");
   end
endtask


//============================================================================
// 4. Raster ops while blending: 0..12 blend S, 13..15 their constant
//============================================================================
task bl_sec_rop;
   integer    op, k;
   reg [31:0] o, so, tr, fl;
   reg  [7:0] a;
   begin
      $display("--- raster ops while blending: 0..12 as S, 13..15 constant (FILL, COPY, COPY_TRANSP x 16 ops)");
      gpu_wait_idle;
      gpu_set_mode(5);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      // TRANSP never equals a source pixel (bit 0 differs): ops 13..15 cannot skip
      tr = $random(gpu_seed) | 32'h1;
      gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, $random(gpu_seed) & 32'hFFFE, $random(gpu_seed) & 32'hFFFE,
                      $random(gpu_seed) & 32'hFFFE, $random(gpu_seed) & 32'hFFFE);
      gpu_c_size(5, 3);
      bl_wmon_start;
      for (k = 0; k < 2; k = k + 1)
         for (op = 0; op < 16; op = op + 1) begin
            a  = (op % 3 == 0) ? 8'd255 : (1 + bl_rnd(254));
            bl_c_alpha(1'b1, a);
            o  = ((k == 0) ? BL_A_LO : BL_B_LO) * 2 + 20 + op * 6 + 4 * BL_DPITCH * (op / 8);
            gpu_c_dst(BL_DPITCH, o);
            if (k == 0) begin
               fl = $random(gpu_seed);
               gpu_c_fill(fl);
               gpu_c_transp(~fl);                           // ops 13..15: FILL S never transparent
               bl_c_exec(GPU_FILL, op, 3'b000, 3'b000);
            end else begin
               gpu_c_transp(tr);
               gpu_c_src(BL_SPITCH, BL_SRC_LO * 2 + 4 + op * 5);
               bl_c_exec(GPU_COPY, op, 3'b000, 3'b000);
            end
         end
      bl_check("FILL / COPY ops 0..15 blended", 1'b0);
      // COPY_TRANSP: transparent pixels skipped whatever the op
      tr = $random(gpu_seed);
      gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, tr, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
      gpu_c_transp(tr);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      bl_wmon_start;
      for (op = 0; op < 16; op = op + 1) begin
         a = (op % 4 == 1) ? 8'd255 : $random(gpu_seed);
         bl_c_alpha(1'b1, a);
         gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 20 + op * 6 + 4 * BL_DPITCH * (op / 8));
         gpu_c_src(BL_SPITCH, BL_SRC_LO * 2 + 4 + op * 5);
         bl_c_exec(GPU_COPYT, op, 3'b000, 3'b000);
      end
      bl_check("COPY_TRANSP ops 0..15 blended", 1'b0);
      gpu_check_all("raster ops blended");
   end
endtask


//============================================================================
// 5. EN = 0 restores plain writes; re-enable
//============================================================================
task bl_sec_disable;
   reg [31:0] o;
   reg  [3:0] op;
   begin
      $display("--- SET_ALPHA EN = 0 restores raster ops");
      gpu_wait_idle;
      gpu_set_mode(4);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      gpu_preload_rand(BL_SRC_LO, BL_SRC_HI);
      bl_c_alpha(1'b1, 8'd77);
      bl_c_alpha(1'b0, $random(gpu_seed));
      o = BL_A_LO * 2 + 40;
      gpu_c_size(7, 4);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));
      gpu_c_dst(BL_DPITCH, o);
      op = 1 + bl_rnd(12);
      bl_c_exec(GPU_FILL, op, 3'b000, 3'b000);
      gpu_c_dst(BL_DPITCH, o + 8 * BL_DPITCH);             // Y swap: rows 8 .. 5
      gpu_c_src(BL_SPITCH, BL_SRC_LO * 2 + 10);
      bl_c_exec(GPU_COPY, 4'd3, 3'b010, 3'b000);
      gpu_c_dst(BL_DPITCH, o + 10 * BL_DPITCH);
      bl_span(0, 9);                                       // plain fill colour
      gpu_c_src(16'd0, BL_SRC_LO * 2 + 16);
      bl_c_tex(4'd4, 4'd3, 1'b0, 3'b000, 1'b0, 8'h00);
      bl_c_uv($random(gpu_seed), $random(gpu_seed));
      bl_c_step($random(gpu_seed), $random(gpu_seed));
      bl_tex(BL_DPITCH, 10);                               // plain texels
      gpu_c_src(16'd0, BL_SRC_LO * 32);
      gpu_c_size(6, 4);
      gpu_c_dst(BL_DPITCH, o + 13 * BL_DPITCH);
      bl_exp(0, 3'b000, 1'b1, 2'd0, 1'b0);                // ramp, no MASK
      gpu_wait_idle;
      bl_no_err;
      gpu_check_touched("EN = 0: plain writes, raster ops");
      // re-enable, then disable again around the same XOR fill
      gpu_c_size(7, 4);
      gpu_c_dst(BL_DPITCH, o + 18 * BL_DPITCH);
      bl_wmon_start;
      bl_c_alpha(1'b1, 8'd77);
      bl_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      bl_check("EN = 1 again: blended", 1'b0);
      gpu_c_dst(BL_DPITCH, o + 23 * BL_DPITCH);
      bl_c_alpha(1'b0, 8'd77);
      bl_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      gpu_wait_idle;
      bl_no_err;
      gpu_check_touched("EN = 0 again: XOR");
      gpu_check_all("EN = 0");
   end
endtask


//============================================================================
// 6. The result depends on the old destination (read-modify-write)
//============================================================================
reg [31:0] bl_dd [0:31];                 // background 1
reg [31:0] bl_dr [0:31];                 // result over background 1

task bl_sec_dstdep;
   integer    k, ndiff;
   reg [31:0] o, fl, pa;
   begin
      $display("--- destination read: same blended FILL over two backgrounds");
      gpu_wait_idle;
      gpu_set_mode(4);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      o  = BL_A_LO * 2 + 40;
      fl = $random(gpu_seed);
      gpu_c_size(8, 4);
      gpu_c_fill(fl);
      gpu_c_dst(BL_DPITCH, o);
      bl_c_alpha(1'b1, 8'd128);
      for (k = 0; k < 32; k = k + 1)
         bl_dd[k] = gpu_get_px(o + (k / 8) * BL_DPITCH + (k % 8), 4);
      bl_wmon_start;
      bl_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      bl_check("blend over background 1", 1'b0);
      for (k = 0; k < 32; k = k + 1) begin
         pa       = o + (k / 8) * BL_DPITCH + (k % 8);
         bl_dr[k] = bl_vpx(pa, 4);
         bl_px_load(pa, 4, ~bl_dd[k]);                     // background 2 = inverted background 1
      end
      bl_wmon_start;
      bl_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      bl_check("blend over background 2", 1'b0);
      ndiff = 0;
      for (k = 0; k < 32; k = k + 1)
         if (bl_vpx(o + (k / 8) * BL_DPITCH + (k % 8), 4) !== bl_dr[k]) ndiff = ndiff + 1;
      if (ndiff == 0) begin
         $display("ERROR: blended FILL gave the same image over two different backgrounds %t", $time);
         error = error + 1;
      end else
         $display("OK:    blended FILL depends on the destination (%0d of 32 pixels differ)", ndiff);
      gpu_check_all("destination read");
   end
endtask


//============================================================================
// 7. Palette modes: SET_ALPHA and MASK have no effect
//============================================================================
task bl_sec_palette;
   integer    mode, bl, ppw, w, h, n, sdep;
   reg [31:0] pm, tr, o;
   reg  [2:0] sw, ssw;
   begin
      $display("--- palette modes 0..3: SET_ALPHA EN and MASK ignored");
      gpu_mon_be_chk = 1'b0;
      for (mode = 0; mode < 4; mode = mode + 1) begin
         gpu_wait_idle;
         gpu_set_mode(mode);
         bl  = gpu_bl(mode);
         ppw = 32 >> bl;
         pm  = gpu_pmask(bl);
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         gpu_preload_rand(BL_SRC_LO, BL_SRC_HI);
         bl_c_alpha(1'b1, (mode == 3) ? 8'd128 : $random(gpu_seed));
         w   = 1 + bl_rnd(BL_WMAX);
         h   = 1 + bl_rnd(6);
         o   = BL_A_LO * ppw + 40 + bl_rnd(ppw);
         gpu_c_size(w, h);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         // FILL and COPY with raster ops
         sw  = $random(gpu_seed);
         gpu_c_dst(BL_DPITCH, bl_first(o, BL_DPITCH, sw, w, h));
         bl_c_exec(GPU_FILL, $random(gpu_seed), sw, 3'b000);
         sw  = $random(gpu_seed);
         ssw = $random(gpu_seed);
         gpu_c_src(BL_SPITCH, bl_first(BL_SRC_LO * ppw + 16, BL_SPITCH, ssw, w, h));
         gpu_c_dst(BL_DPITCH, bl_first(o + BL_BLK, BL_DPITCH, sw, w, h));
         bl_c_exec(GPU_COPY, $random(gpu_seed), sw, ssw);
         gpu_wait_idle;
         // COPY_TRANSP
         tr  = $random(gpu_seed);
         gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, bl, tr, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
         gpu_c_transp(tr);
         gpu_c_src(BL_SPITCH, BL_SRC_LO * ppw + 16);
         gpu_c_dst(BL_DPITCH, o + 2 * BL_BLK);
         bl_c_exec(GPU_COPYT, bl_rnd(13), 3'b000, 3'b000);
         // SPAN
         gpu_c_dst(BL_DPITCH, o + 3 * BL_BLK);
         bl_span(0, 1 + bl_rnd(BL_WMAX));
         bl_span(BL_DPITCH + 1, 1 + bl_rnd(BL_WMAX));
         // TEXSPAN (TRANSP_EN, SHADE)
         n   = 1 + bl_rnd(BL_NSP);
         sw  = $random(gpu_seed) & 3'b110;
         gpu_c_src(16'd0, BL_SRC_LO * ppw + 16);
         gpu_c_dst(BL_DPITCH, o + 3 * BL_BLK + 4 * BL_DPITCH + (sw[2] ? n - 1 : 0));
         bl_c_tex(4'd4, 4'd3, 1'b1, sw, 1'b0, $random(gpu_seed));
         bl_c_uv($random(gpu_seed), $random(gpu_seed));
         bl_c_step($random(gpu_seed), $random(gpu_seed));
         bl_tex(0, n);
         gpu_wait_idle;
         // EXPAND with MASK: the ramp (source depth 3 = 8 bpp)
         sdep = bl_rnd(4);
         bl_mask_src(sdep);
         sw   = $random(gpu_seed);
         gpu_c_src(16'd0, (BL_SRC_LO + 8) * (32 >> sdep) + bl_rnd(32 >> sdep));
         gpu_c_size(w, h);
         gpu_c_dst(BL_DPITCH, bl_first(o + 4 * BL_BLK, BL_DPITCH, sw, w, h) - 5);
         bl_exp(5, sw, bl_rnd(2), sdep, 1'b1);
         gpu_wait_idle;
         bl_no_err;
         $display("       mode %0d, A %0d, %0dx%0d, EXPAND MASK source depth %0d", mode, bl_m_a, w, h, sdep);
         gpu_check_touched("palette mode, SET_ALPHA on");
      end
      gpu_check_all("palette modes");
      gpu_mon_be_chk = 1'b1;
   end
endtask


//============================================================================
// 8. EXPAND MASK at 16 bpp
//============================================================================
task bl_mask_case;
   input  [1:0] sdep;
   input        aen;
   input  [7:0] a;
   input  [2:0] dsw;
   integer      w, h, sppw, sp, dp, pitch, delta;
   reg   [31:0] o, sb;
   begin
      gpu_wait_idle;
      gpu_set_mode(4 + bl_rnd(4));
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      bl_mask_src(sdep);
      w     = 1 + bl_rnd(BL_WMAX);
      h     = 1 + bl_rnd(8);
      sppw  = 32 >> sdep;
      sp    = bl_rnd(2) ? 0 : w + bl_rnd(16);
      sb    = (BL_SRC_LO + 8) * sppw + bl_rnd(sppw);
      dp    = (bl_rnd(3) == 0) ? 0 : BL_DPITCH;
      pitch = (dp == 0) ? BL_DISPW : dp;
      o     = BL_A_LO * 2 + 40 + bl_rnd(2);
      delta = bl_rnd(64) - 32;
      gpu_c_src(sp, sb);
      gpu_c_size(w, h);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));
      gpu_c_dst(dp, bl_first(o, pitch, dsw, w, h) - delta);
      bl_c_alpha(aen, a);
      bl_wmon_start;
      bl_exp(delta, dsw, 1'b0, sdep, 1'b1);
      $display("       A%0d mask, SET_ALPHA EN %0d A %0d, %0dx%0d, sw %b, spitch %0d, dpitch %0d",
               1 << sdep, aen, a, w, h, dsw, sp, dp);
      bl_check("EXPAND MASK", 1'b1);
   end
endtask

task bl_sec_mask;
   integer    sd, ai, rep, k, w, h;
   reg  [7:0] a;
   reg  [2:0] sw;
   reg [31:0] b, sb;
   begin
      $display("--- EXPAND MASK A1 / A2 / A4 / A8, SET_ALPHA off / on");
      for (rep = 0; rep < 2; rep = rep + 1)
         for (sd = 0; sd < 4; sd = sd + 1)
            for (ai = 0; ai < 4; ai = ai + 1) begin
               a = (ai == 2) ? 8'd255 : (ai == 3) ? 8'd0 : $random(gpu_seed);
               bl_mask_case(sd, ai != 0, a, $random(gpu_seed));
            end
      $display("--- EXPAND MASK, the eight destination swaps");
      for (k = 0; k < 8; k = k + 1)
         bl_mask_case(k % 4, k / 4, $random(gpu_seed), k);

      $display("--- EXPAND MASK A8, A = 127 (alpha_eff 0 / 1 / 127)");
      gpu_wait_idle;
      gpu_set_mode(4);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 3, 16'd1, 16'd2, 16'd254, 16'd255);
      gpu_c_src(16'd0, (BL_SRC_LO + 8) * 4);
      gpu_c_size(BL_WMAX, 5);
      gpu_c_fill($random(gpu_seed));
      gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 40);
      bl_c_alpha(1'b1, 8'd127);
      bl_wmon_start;
      bl_exp(0, 3'b000, 1'b0, 2'd3, 1'b1);
      bl_check("EXPAND MASK A8, A 127", 1'b1);

      $display("--- packed glyph chains (pitch 0, DELTA +w), A4 and A8");
      for (k = 0; k < 4; k = k + 1) begin
         gpu_wait_idle;
         gpu_set_mode(4 + k);
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         sd = (k % 2) ? 3 : 2;
         bl_mask_src(sd);
         w  = (BL_WMAX >= 6) ? 6 : BL_WMAX;
         h  = 7;
         sb = (BL_SRC_LO + 8) * (32 >> sd) + 3;
         b  = BL_A_LO * 2 + 40 + 9 * BL_DPITCH;
         gpu_c_size(w, h);
         gpu_c_fill($random(gpu_seed));
         gpu_c_dst(BL_DPITCH, b);
         bl_c_alpha(k / 2, $random(gpu_seed));
         bl_wmon_start;
         gpu_c_src(16'd0, sb + 1 * w * h); bl_exp(0, 3'b000, 1'b0, sd, 1'b1);
         gpu_c_src(16'd0, sb + 4 * w * h); bl_exp(w, 3'b000, 1'b0, sd, 1'b1);
         gpu_c_src(16'd0, sb + 2 * w * h); bl_exp(w, 3'b000, 1'b0, sd, 1'b1);
         gpu_c_src(16'd0, sb + 7 * w * h); bl_exp(w, 3'b000, 1'b0, sd, 1'b1);
         gpu_c_src(16'd0, sb + 3 * w * h); bl_exp(-3 * w + (h + 1) * BL_DPITCH, 3'b000, 1'b0, sd, 1'b1);
         gpu_c_src(16'd0, sb + 0 * w * h); bl_exp(w, 3'b000, 1'b0, sd, 1'b1);
         // right to left on the line above (X swap: base = top-right pixel)
         gpu_c_src(16'd0, sb + 5 * w * h); bl_exp(-2 * (h + 1) * BL_DPITCH + 3 * w - 1, 3'b100, 1'b0, sd, 1'b1);
         gpu_c_src(16'd0, sb + 6 * w * h); bl_exp(-w, 3'b100, 1'b0, sd, 1'b1);
         $display("       glyph chain mode %0d, A%0d, SET_ALPHA EN %0d A %0d", 4 + k, 1 << sd, bl_m_aen, bl_m_a);
         bl_check("EXPAND MASK glyph chain", 1'b1);
      end

      $display("--- all-zero mask and A = 0: no VRAM write, GPU_DONE raised");
      for (k = 0; k < 4; k = k + 1) begin
         gpu_wait_idle;
         gpu_set_mode(4);
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         sd = k;
         if (k < 2)
            gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, sd, 16'h0, 16'h0, 16'h0, 16'h0);
         else
            bl_mask_src(sd);
         gpu_c_src(16'd0, (BL_SRC_LO + 8) * (32 >> sd) + 1);
         gpu_c_size(BL_WMAX, 6);
         gpu_c_fill($random(gpu_seed));
         sw = $random(gpu_seed);
         gpu_c_dst(BL_DPITCH, bl_first(BL_A_LO * 2 + 40, BL_DPITCH, sw, BL_WMAX, 6));
         if (k < 2) bl_c_alpha(k, 8'd200);                 // zero coverage
         else       bl_c_alpha(1'b1, 8'd0);                // coverage, but A = 0
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         bl_wmon_start;
         bl_exp(0, sw, 1'b0, sd, 1'b1);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         if (bl_exp_nwr != 0) tb_error("gpu_blend: zero-alpha EXPAND expected to write (test bug)");
         $display("       A%0d mask, %0s: %0d VRAM writes", 1 << sd, (k < 2) ? "zero coverage" : "A = 0", bl_wmon_n);
         bl_check("EXPAND MASK alpha 0: no write", 1'b1);
      end
      gpu_check_all("EXPAND MASK");
   end
endtask


//============================================================================
// 9. EXPAND without MASK: source depth 3 = 8 bpp ramp
//============================================================================
task bl_sec_exp8;
   integer    mode, bl, ppw, w, h, k, sp;
   reg [31:0] pm, o, fl;
   reg  [2:0] sw;
   begin
      $display("--- EXPAND without MASK, source depth 3 = 8 bpp, modes 0..4");
      gpu_mon_be_chk = 1'b0;
      bl_c_alpha(1'b0, $random(gpu_seed));
      for (mode = 0; mode < 5; mode = mode + 1)
         for (k = 0; k < 2; k = k + 1) begin
            gpu_wait_idle;
            gpu_set_mode(mode);
            bl  = gpu_bl(mode);
            ppw = 32 >> bl;
            pm  = gpu_pmask(bl);
            gpu_preload_rand(BL_A_LO, BL_D_HI);
            gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 3, 16'h0, 16'h1, $random(gpu_seed), 16'hFF);
            w   = 1 + bl_rnd(BL_WMAX);
            h   = 1 + bl_rnd(6);
            sp  = k ? 0 : w + bl_rnd(16);
            sw  = $random(gpu_seed);
            o   = BL_A_LO * ppw + 40 + bl_rnd(ppw);
            fl  = $random(gpu_seed);
            if (k) fl = (fl & ~pm) | ((pm - bl_rnd(4)) & pm);      // fill + v - 1 wraps
            gpu_c_src(sp, (BL_SRC_LO + 8) * 4 + bl_rnd(4));
            gpu_c_size(w, h);
            gpu_c_fill(fl);
            gpu_c_transp($random(gpu_seed) | 32'hA5A5_0000);
            gpu_c_dst(BL_DPITCH, bl_first(o, BL_DPITCH, sw, w, h) + 7);
            bl_exp(-7, sw, k, 2'd3, 1'b0);
            gpu_wait_idle;
            bl_no_err;
            $display("       mode %0d, %0dx%0d, spitch %0d, sw %b, opaque %0d", mode, w, h, sp, sw, k);
            gpu_check_touched("EXPAND 8 bpp source, no MASK");
         end
      gpu_check_all("EXPAND 8 bpp source");
      gpu_mon_be_chk = 1'b1;
   end
endtask



//============================================================================
// 9b. Blended ops 13..15: constant blend source, SET_TRANSP key kept
//============================================================================
task bl_sec_konst;
   integer    op, k, i, sd, w, h;
   reg [31:0] o, fl, tr, c1, c2, c3;
   reg  [7:0] a;
   reg  [3:0] ops [0:3];
   begin
      $display("--- blended ops 13..15: constant S, SET_TRANSP key (FILL, COPY, COPY_TRANSP, EXPAND)");
      ops[0] = 4'd13; ops[1] = 4'd14; ops[2] = 4'd15; ops[3] = bl_rnd(13);
      // FILL: S = 0 / ones / fill; a fill colour equal to TRANSP draws nothing
      for (k = 0; k < 2; k = k + 1) begin
         gpu_wait_idle;
         gpu_set_mode(4 + bl_rnd(4));
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         bl_wmon_start;
         for (i = 0; i < 4; i = i + 1) begin
            a  = (i == 1) ? 8'd255 : (1 + bl_rnd(254));
            bl_c_alpha(1'b1, a);
            gpu_c_size(1 + bl_rnd(BL_WMAX), 1 + bl_rnd(4));
            gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 20 + i * 7 + 6 * BL_DPITCH * k);
            fl = $random(gpu_seed);
            gpu_c_fill(fl);
            gpu_c_transp((k == 1) ? fl : ~fl);                // k = 1: every pixel transparent
            bl_c_exec(GPU_FILL, ops[i], 3'b000, 3'b000);
         end
         bl_check("blended FILL ops 13..15", 1'b0);
      end
      // COPY and COPY_TRANSP: S = the constant where the source is not TRANSP
      for (k = 0; k < 2; k = k + 1) begin
         gpu_wait_idle;
         gpu_set_mode(4 + bl_rnd(4));
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         tr = $random(gpu_seed);
         c1 = tr ^ 32'h0001; c2 = $random(gpu_seed); c3 = $random(gpu_seed);
         gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, tr, c1, c2, c3);
         gpu_c_transp(tr);
         bl_wmon_start;
         for (i = 0; i < 4; i = i + 1) begin
            a  = (i == 2) ? 8'd255 : $random(gpu_seed);
            bl_c_alpha(1'b1, a);
            gpu_c_size(1 + bl_rnd(BL_WMAX), 1 + bl_rnd(4));
            gpu_c_fill($random(gpu_seed));
            gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 20 + i * 7 + 6 * BL_DPITCH * (i / 2));
            gpu_c_src(BL_SPITCH, BL_SRC_LO * 2 + 4 + i * 5 + bl_rnd(3));
            bl_c_exec(k ? GPU_COPYT : GPU_COPY, ops[i], 3'b000, 3'b000);
         end
         bl_check(k ? "blended COPY_TRANSP ops 13..15" : "blended COPY ops 13..15", 1'b0);
      end
      // EXPAND MASK: S = the constant, alpha = the coverage (x A with EN)
      for (k = 0; k < 8; k = k + 1) begin
         gpu_wait_idle;
         gpu_set_mode(4 + bl_rnd(4));
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         sd = k % 4;
         bl_mask_src(sd);
         w  = 1 + bl_rnd(BL_WMAX);
         h  = 1 + bl_rnd(6);
         gpu_c_src(0, (BL_SRC_LO + 8) * (32 >> sd));
         gpu_c_size(w, h);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 40);
         bl_c_alpha(k >= 4, 1 + bl_rnd(255));
         bl_exp_op = ops[k % 4];
         bl_wmon_start;
         bl_exp(0, 3'b000, 1'b0, sd[1:0], 1'b1);
         $display("       A%0d mask, op %0d, SET_ALPHA EN %0d", 1 << sd, bl_exp_op, k >= 4);
         bl_check("blended EXPAND MASK ops 13..15", 1'b1);
      end
      // EXPAND without MASK under SET_ALPHA EN: value 0 skipped (OPAQUE: TRANSP
      // drawn), the others take the ramp (ops 0..12) or the constant
      for (k = 0; k < 8; k = k + 1) begin
         gpu_wait_idle;
         gpu_set_mode(4 + bl_rnd(4));
         gpu_preload_rand(BL_A_LO, BL_D_HI);
         gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 3, 16'h0, 16'h1, $random(gpu_seed), 16'hFF);
         w  = 1 + bl_rnd(BL_WMAX);
         h  = 1 + bl_rnd(6);
         gpu_c_src(0, (BL_SRC_LO + 8) * 4);
         gpu_c_size(w, h);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         gpu_c_dst(BL_DPITCH, BL_A_LO * 2 + 40);
         bl_c_alpha(1'b1, (k == 3) ? 8'd255 : (1 + bl_rnd(254)));
         bl_exp_op = ops[k % 4];
         bl_wmon_start;
         bl_exp(0, 3'b000, k >= 4, 2'd3, 1'b0);
         $display("       ramp, op %0d, opaque %0d", bl_exp_op, k >= 4);
         bl_check("blended EXPAND ops 13..15", 1'b0);
      end
      bl_exp_op = 4'd0;
      bl_c_alpha(1'b0, 8'd0);
      gpu_check_all("blended ops 13..15");
   end
endtask


//============================================================================
// 10. ABORT / GPU_EN = 0 in the middle of a blended EXEC
//============================================================================
task bl_abort_case;
   input integer kind;                   // 0 FILL, 1 COPY, 2 EXPAND MASK, 3 TEXSPAN
   input integer how;                    // 0 GPU_CTRL.ABORT, 1 CTRL.GPU_EN = 0
   integer    mode, tot, wmin, wmax, wt, t0, cls, nd, delta, ii, sp, pitch, n2;
   reg [31:0] tr, flag, oa, ob, sb, tb, base;
   reg  [2:0] sw, ssw;
   reg  [1:0] sdep;
   reg  [3:0] op;
   reg  [7:0] a;
   reg        dec;
   begin
      mode  = 4 + bl_rnd(4);
      gpu_wait_idle;
      gpu_set_mode(mode);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      oa    = BL_A_LO * 2 + 8 + bl_rnd(2);
      ob    = BL_B_LO * 2 + 8 + bl_rnd(2);
      delta = bl_rnd(32) - 16;
      a     = 64 + bl_rnd(192);
      sw    = $random(gpu_seed);
      ssw   = $random(gpu_seed);
      op    = $random(gpu_seed);
      sdep  = bl_rnd(4);
      sp    = 0;
      pitch = BL_DPITCH;
      tb    = BL_SRC_LO * 2 + 16 + bl_rnd(2);
      bl_c_alpha(1'b1, a);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      if (kind == 3) begin
         tot   = BL_NMAX;
         tr    = $random(gpu_seed);
         gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, tr, $random(gpu_seed), $random(gpu_seed), 16'hFFFE);
         ii    = bl_rnd(4);
         sw    = (ii == 0) ? 3'b000 : (ii == 1) ? 3'b100 : (ii == 2) ? 3'b001 : 3'b011;
         pitch = sw[0] ? 2 : BL_DPITCH;
         base  = oa + (sw[0] ? (sw[1] ? 2 * (tot - 1) : 0) : (sw[2] ? tot - 1 : 0));
         gpu_c_transp(tr);
         gpu_c_dst(pitch, base - delta);
         gpu_c_src(16'd117, tb);
         bl_c_tex(4'd5, 4'd3, 1'b1, sw, 1'b0, 8'h00);
         bl_c_uv($random(gpu_seed), $random(gpu_seed));
         bl_c_step($random(gpu_seed), $random(gpu_seed));
      end else begin
         tot = BL_EW * BL_EH;
         gpu_c_size(BL_EW, BL_EH);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         if (kind == 1) begin
            gpu_preload_rand(BL_SRC_LO, BL_SRC_HI);
            sp = BL_EW + 4;
            gpu_c_src(sp, bl_first(tb, sp, ssw, BL_EW, BL_EH));
         end else if (kind == 2) begin
            bl_mask_src(sdep);
            sp = bl_rnd(2) ? 0 : BL_EW + bl_rnd(16);
            sb = (BL_SRC_LO + 8) * (32 >> sdep) + bl_rnd(32 >> sdep);
            gpu_c_src(sp, sb);
         end
         gpu_c_dst(BL_DPITCH, bl_first(oa, BL_DPITCH, sw, BL_EW, BL_EH) - ((kind == 2) ? delta : 0));
      end
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // the EXEC to abandon, recorded pixel by pixel
      bl_wmon_start;
      bl_rec = 1'b1;
      case (kind)
        0:       bl_c_exec(GPU_FILL, op, sw, 3'b000);
        1:       bl_c_exec(GPU_COPY, op, sw, ssw);
        2:       bl_exp(delta, sw, 1'b0, sdep, 1'b1);
        default: bl_tex(delta, tot);
      endcase
      bl_rec = 1'b0;
      t0     = gpu_cyc;
      // queued complete commands that the flush must drop
      dec = (tot >= 60);
      if (dec) begin
         gpu_push({BL_OP_FENCE, 28'h100_0001});
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      end
      wmin = dec ? 30 : 3;
      wmax = (tot * 6) / 10;                                     // the walk takes at least one cycle per pixel
      if (wmax <= wmin) wmax = wmin + 1;
      wt   = wmin + bl_rnd(wmax - wmin);
      while (gpu_cyc < t0 + wt) @(posedge free_clk);
      if (how == 0)
         reg_wr(GPU_CTRL, 32'h2);
      else begin
         reg_wr(CTRL, mode);                                       // GPU_EN = 0
         reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));   // dropped
         reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
      end
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH,
                  GS_EMPTY | GS_FULL | GS_PRIM_BUSY | GS_BUSY | GS_ERR | GS_HELD | 32'hFFFF);
      reg_rd_val(IRQ_FLAG, flag);
      if (!(flag & IF_IDLE) || (flag & IF_ERR)) begin
         $display("ERROR: IRQ_FLAG = 0x%h after the abandon (GPU_IDLE expected, no GPU_ERR) %t", flag, $time);
         error = error + 1;
      end
      bl_wmon_stop(1'b0);
      bl_prefix_check(flag[4], cls, nd);
      if (cls == 1) begin
         $display("OK:    blended %0s %0s mode %0d A %0d: abandoned after %0d of %0d pixels (clean prefix)",
                  (kind == 0) ? "FILL" : (kind == 1) ? "COPY" : (kind == 2) ? "EXPAND MASK" : "TEXSPAN",
                  (how == 0) ? "ABORT" : "GPU_EN=0", mode, a, nd, tot);
         bl_strict = bl_strict + 1;
      end else if (cls == 2) begin
         $display("INFO:  blended kind %0d mode %0d: the whole walk was drawn before the abandon (GPU_DONE %0d)",
                  kind, mode, flag[4]);
         bl_late = bl_late + 1;
      end else if (cls == 0) begin
         $display("INFO:  blended kind %0d mode %0d: nothing drawn before the abandon", kind, mode);
         bl_none = bl_none + 1;
      end
      if (how == 1) gpu_set_mode(mode);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // a full EXEC in region B; SET_ALPHA / SET_TEX re-sent (gpu_retain checks that they survive)
      bl_c_alpha(1'b1, a);
      bl_wmon_start;
      if (kind == 3) begin
         n2   = (BL_NMAX >= 120) ? 120 : BL_NMAX;
         base = ob + (bl_t_sw[0] ? (bl_t_sw[1] ? 2 * (n2 - 1) : 0) : (bl_t_sw[2] ? n2 - 1 : 0));
         gpu_c_dst(pitch, base);
         gpu_c_src(16'd0, tb + bl_rnd(4));
         bl_c_tex(bl_t_lw, bl_t_lh, bl_t_ten, bl_t_sw, bl_t_free, bl_t_shade);
         bl_c_uv($random(gpu_seed), $random(gpu_seed));
         bl_c_step(bl_t_du, bl_t_dv);
         bl_tex(0, n2);
      end else begin
         gpu_c_size(BL_EW, BL_EH);
         gpu_c_dst(BL_DPITCH, bl_first(ob, BL_DPITCH, sw, BL_EW, BL_EH));
         case (kind)
           0:       bl_c_exec(GPU_FILL, op, sw, 3'b000);
           1:       bl_c_exec(GPU_COPY, op, sw, ssw);
           default: begin
              gpu_c_src(sp, sb + 17);
              bl_exp(0, sw, 1'b0, sdep, 1'b1);
           end
         endcase
      end
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      bl_check("blended EXEC after the abandon", (kind == 2));
      gpu_check_all("blend abandon + restart");
   end
endtask


//============================================================================
// 11. Debug freeze toggled mid-blend, VRAM-window traffic
//============================================================================
task bl_freeze_case;
   input integer k;
   integer    mode, n, tg, sp;
   reg [31:0] tr, st, o, base;
   reg  [2:0] sw, ssw;
   reg  [1:0] sdep;
   reg  [7:0] a;
   reg        dbgc;
   begin
      mode = 4 + bl_rnd(4);
      gpu_wait_idle;
      gpu_set_mode(mode);
      gpu_preload_rand(BL_A_LO, BL_D_HI);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      a    = 32 + bl_rnd(224);
      bl_c_alpha(1'b1, a);
      sw   = $random(gpu_seed);
      ssw  = $random(gpu_seed);
      sdep = bl_rnd(4);
      o    = BL_A_LO * 2 + 8 + bl_rnd(2);
      if ((k % 4) == 3) begin
         n  = BL_NMAX;
         tr = $random(gpu_seed);
         gpu_preload_pal(BL_SRC_LO, BL_SRC_HI, 4, tr, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
         sw = bl_rnd(2) ? 3'b100 : 3'b000;
         gpu_c_transp(tr);
         gpu_c_dst(BL_DPITCH, BL_B_LO * 2 + 8 + (sw[2] ? n - 1 : 0));
         gpu_c_src(16'd0, BL_SRC_LO * 2 + 16 + bl_rnd(2));
         bl_c_tex(4'd4, 4'd3, 1'b1, sw, 1'b0, 8'h00);
         bl_c_uv($random(gpu_seed), $random(gpu_seed));
         bl_c_step($random(gpu_seed), $random(gpu_seed));
      end else begin
         gpu_c_size(BL_EW, BL_EH);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed));
         if ((k % 4) == 1) begin
            gpu_preload_rand(BL_SRC_LO, BL_SRC_HI);
            gpu_c_src(BL_EW + 4, bl_first(BL_SRC_LO * 2 + 16, BL_EW + 4, ssw, BL_EW, BL_EH));
         end else if ((k % 4) == 2) begin
            bl_mask_src(sdep);
            sp = bl_rnd(2) ? 0 : BL_EW + bl_rnd(16);
            gpu_c_src(sp, (BL_SRC_LO + 8) * (32 >> sdep) + bl_rnd(32 >> sdep));
         end
         gpu_c_dst(BL_DPITCH, bl_first(o, BL_DPITCH, sw, BL_EW, BL_EH));
      end
      gpu_wait_idle;
      gpu_mon_be_chk = 1'b0;
      bl_wmon_bg     = 1'b1;
      bl_bg_en       = 1'b1;
      bl_wmon_start;
      case (k % 4)
        0:       bl_c_exec(GPU_FILL, $random(gpu_seed), sw, 3'b000);
        1:       bl_c_exec(GPU_COPY, $random(gpu_seed), sw, ssw);
        2:       bl_exp(0, sw, 1'b0, sdep, 1'b1);
        default: bl_tex(0, n);
      endcase
      // freeze toggled while the rectangle runs; no push while frozen
      reg_wr(DBG_CTRL, 32'h2);
      dbgc = 1'b1;
      for (tg = 0; tg < 30; tg = tg + 1) begin
         repeat(1 + bl_rnd(8)) @(negedge free_clk);
         if (k & 4)
            dbg_stoptime = ~dbg_stoptime;
         else begin
            dbg_stoptime = 1'b1;
            dbgc         = ~dbgc;
            reg_wr(DBG_CTRL, dbgc ? 32'h2 : 32'h0);
         end
         if (dbg_stoptime && dbgc) begin
            reg_rd_val(GPU_STAT, st);
            if ((st & GS_HELD) && (st & GS_PRIM_BUSY)) begin       // held mid-rectangle: no GPU_DONE yet
               reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
               bl_held_chk = bl_held_chk + 1;
            end
         end
      end
      @(negedge free_clk) dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      $display("       blended %0s mode %0d A %0d, freeze via %0s, window traffic %0d writes / %0d reads so far",
               ((k % 4) == 0) ? "FILL" : ((k % 4) == 1) ? "COPY" : ((k % 4) == 2) ? "EXPAND MASK" : "TEXSPAN",
               mode, a, (k & 4) ? "dbg_stoptime" : "DBG_CTRL[1]", bl_bg_nw, bl_bg_nr);
      bl_bg_pause;
      bl_wmon_stop(1'b0);
      // each hold writes the partly merged word: at most one more write per freeze
      if (((k % 4) == 2) && ((bl_wmon_n < bl_exp_nwr) || (bl_wmon_n > bl_exp_nwr + 30))) begin
         $display("ERROR: GPU made %0d VRAM writes, %0d to %0d expected (model, plus a write per freeze) %t",
                  bl_wmon_n, bl_exp_nwr, bl_exp_nwr + 30, $time);
         error = error + 1;
      end
      bl_wmon_bg     = 1'b0;
      gpu_mon_be_chk = 1'b1;
      bl_no_err;
      gpu_check_touched("blend + freeze + window traffic");
   end
endtask


//============================================================================
// Main
//============================================================================
integer bl_k;
reg [31:0] bl_old, bl_src, bl_xw;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: BLEND (SET_ALPHA, EXPAND MASK)    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (GPU_BLEND_EN == 0)
         tb_skip_finish("|        (GPU_BLEND_EN = 0: feature absent)       |");
      gpu_seed   = `SEED;
      bl_bg_seed = `SEED + 17;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait  = 1'b1;
      gpu_mon_bl     = 4;
      gpu_mon_be_chk = 1'b1;
      gpu_set_dispw(BL_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      bl_selftest;
      bl_sec_reset;
      bl_sec_const;
      bl_sec_extremes;
      bl_sec_rop;
      bl_sec_disable;
      bl_sec_dstdep;
      bl_sec_palette;
      bl_sec_mask;
      bl_sec_exp8;
      bl_sec_konst;

      $display("--- ABORT / GPU_EN = 0 in the middle of a blended EXEC");
      for (bl_k = 0; bl_k < 16; bl_k = bl_k + 1)
         bl_abort_case(bl_k % 4, (bl_k / 4) % 2);
      $display("       abandoned: %0d strict prefixes, %0d complete, %0d nothing drawn", bl_strict, bl_late, bl_none);
      if (bl_strict == 0)
         tb_error("no blended EXEC was abandoned mid-walk (test ineffective)");

      $display("--- debug freeze toggled mid-blend, VRAM-window traffic");
      bl_bg_en = 1'b0;
      for (bl_k = 0; bl_k < 8; bl_k = bl_k + 1)
         bl_freeze_case(bl_k);
      $display("       held mid-rectangle checks: %0d", bl_held_chk);

      bl_no_err;
      gpu_check_all("blend end");

      // Blended COPY whose second source pixel is past the VRAM: the first one
      // is drawn (blended), then the error (cause 5) abandons the rest
      $display("--- blended COPY reaching past the VRAM: the pixel before the fault is drawn");
      gpu_set_mode(4);
      gpu_wait_idle;
      bl_old = vram_mem[50];
      bl_src = vram_mem[VRAM_WORDS-1] >> 16;
      bl_c_alpha(1'b1, 8'h80);
      gpu_c_src(16'd0, 2 * VRAM_WORDS - 1);
      gpu_c_dst(16'd0, 32'd100);
      gpu_c_size(14'd2, 14'd1);
      gpu_push({4'h9, 28'h0});                             // EXEC_COPY, op 0, outside the model
      reg_poll(GPU_STAT, GS_ERR, GS_ERR, 200);
      repeat(40) @(posedge free_clk);
      bl_xw = {bl_old[31:16], gpu_blend565(bl_src[15:0], bl_old[15:0], gpu_a_const(8'h80))};
      if (vram_mem[50] !== bl_xw) begin
         $display("ERROR: word 50 = 0x%h, expected 0x%h (pixel 100 blended, 101 kept) %t", vram_mem[50], bl_xw, $time);
         error = error + 1;
      end else
         $display("OK:    pixel before the fault drawn, blended");
      reg_wr(GPU_CTRL, 32'h1);                             // CLEAR_ERR
      bl_c_alpha(1'b0, 8'h00);
      $display("       pixels: %0d blended, %0d opaque (alpha 256), %0d plain, %0d skipped (%0d transparent, %0d mask alpha 0)",
               bl_n_bl, bl_n_op, bl_n_plain, bl_n_skip, bl_n_tr, bl_n_mz);
      if ((bl_n_bl == 0) || (bl_n_op == 0) || (bl_n_tr == 0) || (bl_n_mz == 0) || (bl_n_plain == 0))
         tb_error("a pixel class was never modelled (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
