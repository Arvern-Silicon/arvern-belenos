//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_call
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_call.v
// Module Description : CALL (opcode 0x7): command lists read from VRAM.
//                      Lists are built with the gpu_model command tasks
//                      while gpu_push is diverted into a capture buffer
//                      (the model runs at capture time), written to VRAM
//                      (backdoor or VRAM window) and started by a CALL.
//                      1. random self-contained lists (FILL, COPY,
//                         COPY_TRANSP, SPAN, EXPAND, TEXSPAN, FENCE) at
//                         various addresses / modes, operand bits above
//                         VRAM_AW set; the same words replayed through
//                         GPU_CMD on the pre-list image give the identical
//                         VRAM; a list longer than any FIFO.
//                      2. FIFO words pushed behind a running list wait for
//                         it (order-sensitive XOR on the list's last
//                         rectangle, state carried over), a second CALL
//                         queued, CALL N = 0 queued and idle.
//                      3. lists written through the VRAM window and called
//                         with no delay (first word written first / last)
//                         over a poisoned area; a list rewritten between two
//                         calls; list B written while list A runs.
//                      4. address wrap at the top of the VRAM (only when
//                         VRAM_WORDS = 2^VRAM_AW), invalid word just past
//                         the wrap.
//                      5-6. CALL in a list and invalid words (0x0, 0xE,
//                         SET_EXT 3 / 15): ERR, ERR_OPCODE, LIST kept,
//                         GPU_LIST = word address, decoder stopped, FIFO
//                         kept; exits CLEAR_ERR, ABORT + CLEAR_ERR,
//                         GPU_EN = 0; the GPU works afterwards.
//                      7. lists ending between a command and its operand:
//                         ERR, ERR_OPCODE 7, the FIFO words behind the CALL
//                         never consumed.
//                      8. ABORT / GPU_EN = 0 in a list rectangle (clean
//                         prefix, no GPU_DONE, rest of list and FIFO never
//                         run; the copies with CL swaps, slow enough to be
//                         caught), ABORT between two list rectangles.
//                      9. debug freeze: strict hold mid-list (no VRAM
//                         access, GPU_LIST and status stable), random freeze
//                         toggling with VRAM-window traffic.
//                      10. LIST / BUSY / GPU_LIST while a list runs,
//                         GPU_IDLE only at the end, one GPU_DONE per EXEC,
//                         FENCE 1 in lists, N = 1.
//                      11. the same list words executed at 8 and 16 bpp.
//                      12. a flush and a freeze on every cycle after a CALL.
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer CL_DPITCH  = 29;
localparam integer CL_SPITCH  = 12;
localparam integer CL_DISPW   = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer CL_WMAX    = (GPU_DIM_MASK >= 8)  ? 8  : GPU_DIM_MASK;
localparam integer CL_HMAX    = (GPU_DIM_MASK >= 6)  ? 6  : GPU_DIM_MASK;
localparam integer CL_BW      = (GPU_DIM_MASK >= 15) ? 15 : GPU_DIM_MASK;   // abandoned rectangle
localparam integer CL_BH      = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer CL_LA      = 8;               // list A: words [CL_LA, CL_LB)
localparam integer CL_LB      = 104;             // list B: words [CL_LB, CL_LB + CL_LEN)
localparam integer CL_LEN     = 96;
localparam integer CL_LALL    = 192;             // A + B as one area
localparam integer CL_SRC_LO  = 200;             // sources: words [CL_SRC_LO, CL_SRC_HI)
localparam integer CL_SRC_HI  = 300;
localparam integer CL_DST_LO  = 300;             // destinations: words [CL_DST_LO, CL_DST_HI)
localparam integer CL_DST_HI  = 900;
localparam integer CL_BG_LO   = 910;             // VRAM-window background traffic
localparam integer CL_BG_HI   = 990;
localparam integer CL_WRAP_OK = (VRAM_WORDS == (1 << VRAM_AW)) ? 1 : 0;
localparam  [31:0] CL_AMASK   = (VRAM_AW >= 32) ? 32'hFFFF_FFFF : ((32'h1 << VRAM_AW) - 32'h1);
localparam  [31:0] CL_GS_LIST    = 32'h0100_0000;
localparam  [31:0] CL_STMASK  = 32'h01FF_FFFF;   // GPU_STAT without ERR_OPCODE


//============================================================================
// Background VRAM-window manager (own v-port driver; region CL_BG only)
//============================================================================
reg        cl_bg_en, cl_bg_busy;
integer    cl_bg_seed, cl_bg_nw, cl_bg_nr, cl_bg_waits;
reg [31:0] cl_bg_addr, cl_bg_data, cl_bg_raw, cl_bg_exp, cl_bg_lane;
reg  [1:0] cl_bg_size;
reg        cl_bg_wr;
initial begin cl_bg_en = 1'b0; cl_bg_busy = 1'b0; cl_bg_nw = 0; cl_bg_nr = 0; end

always begin : cl_bg
   @(negedge free_clk);
   if (cl_bg_en) begin
      cl_bg_busy = 1'b1;
      cl_bg_wr   = $random(cl_bg_seed);
      cl_bg_size = {$random(cl_bg_seed)} % 3;
      cl_bg_addr = 4 * (CL_BG_LO + ({$random(cl_bg_seed)} % (CL_BG_HI - CL_BG_LO))) + ({$random(cl_bg_seed)} & 3);
      cl_bg_addr = (cl_bg_size == SZ_W) ? (cl_bg_addr & ~32'h3) : (cl_bg_size == SZ_H) ? (cl_bg_addr & ~32'h1) : cl_bg_addr;
      cl_bg_data = $random(cl_bg_seed);
      cl_bg_lane = (cl_bg_size == SZ_B) ? {4{cl_bg_data[7:0]}} : (cl_bg_size == SZ_H) ? {2{cl_bg_data[15:0]}} : cl_bg_data;
      while (v_hready !== 1'b1) @(negedge free_clk);
      v_hsel = 1'b1; v_haddr = cl_bg_addr; v_htrans = 2'b10; v_hwrite = cl_bg_wr;
      v_hsize = {1'b0, cl_bg_size}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
      if (cl_bg_wr) v_hwdata = cl_bg_lane;
      cl_bg_waits = 0;
      @(negedge free_clk);
      while (v_hready !== 1'b1) begin @(negedge free_clk); cl_bg_waits = cl_bg_waits + 1; end
      cl_bg_raw = v_hrdata;
      if (v_hresp !== 1'b0) begin
         $display("ERROR: background window access 0x%h got ERROR %t", cl_bg_addr, $time);
         error = error + 1;
      end
      @(posedge free_clk);
      if (cl_bg_wr) begin
         if (cl_bg_size == SZ_W) gpu_shadow[cl_bg_addr >> 2] = cl_bg_lane;
         else if (cl_bg_size == SZ_H) begin
            if (cl_bg_addr[1]) gpu_shadow[cl_bg_addr >> 2][31:16] = cl_bg_lane[15:0];
            else               gpu_shadow[cl_bg_addr >> 2][15:0]  = cl_bg_lane[15:0];
         end else
            case (cl_bg_addr[1:0])
              2'd0:    gpu_shadow[cl_bg_addr >> 2][ 7: 0] = cl_bg_lane[7:0];
              2'd1:    gpu_shadow[cl_bg_addr >> 2][15: 8] = cl_bg_lane[7:0];
              2'd2:    gpu_shadow[cl_bg_addr >> 2][23:16] = cl_bg_lane[7:0];
              default: gpu_shadow[cl_bg_addr >> 2][31:24] = cl_bg_lane[7:0];
            endcase
         cl_bg_nw = cl_bg_nw + 1;
      end else begin
         cl_bg_exp = gpu_shadow[cl_bg_addr >> 2];
         cl_bg_exp = (cl_bg_size == SZ_B) ? ((cl_bg_exp >> (8 * cl_bg_addr[1:0])) & 32'hFF) :
                     (cl_bg_size == SZ_H) ? ((cl_bg_exp >> (16 * cl_bg_addr[1])) & 32'hFFFF) : cl_bg_exp;
         cl_bg_raw = (cl_bg_size == SZ_B) ? ((cl_bg_raw >> (8 * cl_bg_addr[1:0])) & 32'hFF) :
                     (cl_bg_size == SZ_H) ? ((cl_bg_raw >> (16 * cl_bg_addr[1])) & 32'hFFFF) : cl_bg_raw;
         if (cl_bg_raw !== cl_bg_exp) begin
            $display("ERROR: background window read 0x%h = 0x%h / expected 0x%h %t", cl_bg_addr, cl_bg_raw, cl_bg_exp, $time);
            error = error + 1;
         end
         cl_bg_nr = cl_bg_nr + 1;
      end
      cl_bg_busy = 1'b0;
      repeat({$random(cl_bg_seed)} % 6) @(negedge free_clk);
   end
end

task cl_bg_pause;
   begin
      cl_bg_en = 1'b0;
      while (cl_bg_busy) @(negedge free_clk);
      @(negedge free_clk);
   end
endtask


//============================================================================
// Random helpers (list generator stream, independent of gpu_seed)
//============================================================================
integer    cl_gseed;

function integer cl_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      cl_rnd = (n <= 1) ? 0 : (($random(cl_gseed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] cl_r32;
   input dummy;
   begin
      cl_r32 = $random(cl_gseed);
   end
endfunction

// CALL operand: list address, optionally with random bits above VRAM_AW and
// [31:28] = EXEC_FILL (drawn if the operand were ever decoded as a command)
function [31:0] cl_opnd;
   input [31:0] a;
   input        hi;
   reg   [31:0] r;
   begin
      r = a & CL_AMASK;
      if (hi && (VRAM_AW < 28))
         r = ((r | (($random(cl_gseed) << VRAM_AW) & ~CL_AMASK)) & 32'h0FFF_FFFF) | 32'h8000_0000;
      cl_opnd = r;
   end
endfunction


//============================================================================
// Placement: pixel ranges for destinations and GFX-depth sources
//============================================================================
integer    cl_dlo, cl_dhi, cl_slo, cl_shi;
reg        cl_tex_ok;                   // TEXSPAN allowed in generated lists
reg        cl_fixed;                    // list words must not depend on GFX_MODE

task cl_regions;
   input integer bl;
   integer       ppw;
   begin
      ppw       = 32 >> bl;
      cl_dlo    = CL_DST_LO * ppw;
      cl_dhi    = CL_DST_HI * ppw;
      cl_slo    = CL_SRC_LO * ppw;
      cl_shi    = CL_SRC_HI * ppw;
      cl_tex_ok = 1'b1;
      cl_fixed  = 1'b0;
   end
endtask

// Top-left pixel of a rows x cols box inside [lo, hi)
function [31:0] cl_box;
   input integer lo;
   input integer hi;
   input integer rows;
   input integer cols;
   input integer pitch;
   integer       span;
   begin
      span   = (rows - 1) * pitch + cols + 1;
      cl_box = lo + cl_rnd(hi - lo - span);
   end
endfunction

// First pixel visited (base) of a w x h walk with swaps sw = {X, Y, CL} in the box at o
function [31:0] cl_corner;
   input [31:0] o;
   input integer pitch;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows      = sw[0] ? w : h;
      cols      = sw[0] ? h : w;
      cl_corner = o + (sw[1] ? (rows - 1) * pitch : 0) + (sw[2] ? cols - 1 : 0);
   end
endfunction

task cl_chk_dst;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < CL_DST_LO) || (gpu_word_of(pa, bl) >= CL_DST_HI))
         tb_error("destination pixel outside the destination area (test bug)");
   end
endtask

task cl_chk_src;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < CL_SRC_LO) || (gpu_word_of(pa, bl) >= CL_SRC_HI))
         tb_error("source pixel outside the source area (test bug)");
   end
endtask


//============================================================================
// Command models not in gpu_model (EXEC_SPAN / EXEC_EXPAND / SET_EXT / TEXSPAN)
//============================================================================
task cl_span;
   input integer delta;
   input  [13:0] width;
   reg    [13:0] d14;
   integer       kk;
   begin
      d14 = delta;
      gpu_push({OP_EXEC_SPAN, d14, width});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_m_w        = ((width & GPU_DIM_MASK) == 0) ? 1 : (width & GPU_DIM_MASK);
      gpu_m_h        = 1;
      gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
      for (kk = 0; kk < gpu_x_w; kk = kk + 1)
         cl_chk_dst(gpu_walk(gpu_x_dbase, gpu_x_dpitch, 3'b000, gpu_x_w, kk), gpu_x_bl);
      gpu_x_run;
   end
endtask

task cl_exp;
   input integer delta;
   input   [2:0] dsw;                    // {X, Y, CL}
   input         opaque;
   input   [1:0] sdep;
   reg    [13:0] d14;
   reg    [31:0] spa, dpa, vv, pm;
   integer       kk, sbl, spitch;
   begin
      d14 = delta;
      gpu_src_fmt({2'b00, sdep} + 4'd1);                 // SRC_FMT 1-4 = 1/2/4/8 bpp
      gpu_push({OP_EXEC_EXP, d14, 7'h00, dsw, 1'b0, opaque, 2'b00});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_x_setup(GPU_FILL, 4'd0, dsw, 3'b000);
      sbl    = sdep;
      spitch = (gpu_m_src_pitch == 16'h0) ? gpu_x_w : gpu_m_src_pitch;
      pm     = gpu_pmask(gpu_x_bl);
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         spa = (gpu_x_sbase + (kk / gpu_x_w) * spitch + (kk % gpu_x_w)) & GPU_PA_MASK;
         cl_chk_src(spa, sbl);
         vv  = gpu_get_px(spa, sbl);
         dpa = gpu_walk(gpu_x_dbase, gpu_x_dpitch, dsw, gpu_x_w, kk);
         cl_chk_dst(dpa, gpu_x_bl);
         gpu_touch_px(dpa, gpu_x_bl);
         if (vv !== 32'h0)
            gpu_set_px(dpa, gpu_x_bl, (gpu_x_fill + vv - 32'h1) & pm);
         else if (opaque)
            gpu_set_px(dpa, gpu_x_bl, gpu_x_transp & pm);
      end
   end
endtask

reg  [3:0] cl_lw, cl_lh;
reg        cl_ten, cl_free;
reg  [2:0] cl_tsw;
reg  [7:0] cl_shade;
reg [15:0] cl_u0, cl_v0, cl_du, cl_dv;

task cl_set_tex;
   input  [3:0] lw;
   input  [3:0] lh;
   input        ten;
   input  [2:0] dsw;
   input        free;
   input  [7:0] shade;
   begin
      gpu_push({OP_SET_EXT, 4'h0, shade, 3'b000, free, dsw, ten, lh, lw});
      cl_lw    = lw;
      cl_lh    = lh;
      cl_ten   = ten;
      cl_tsw   = dsw;
      cl_free  = free;
      cl_shade = shade;
   end
endtask

task cl_set_uv;
   input [15:0] u0;
   input [15:0] v0;
   begin
      gpu_push({OP_SET_EXT, 4'h1, 24'h0});
      gpu_push({u0, v0});
      cl_u0 = u0;
      cl_v0 = v0;
   end
endtask

task cl_set_step;
   input [15:0] du;
   input [15:0] dv;
   begin
      gpu_push({OP_SET_EXT, 4'h2, 24'h0});
      gpu_push({du, dv});
      cl_du = du;
      cl_dv = dv;
   end
endtask

task cl_tex;
   input integer delta;
   input  [13:0] n;
   reg    [13:0] d14;
   reg    [20:0] ua, va, dua, dva;
   reg    [31:0] spa, dpa, tt, pm;
   integer       kk, lw, lh, pitch, ui, vi;
   begin
      d14 = delta;
      gpu_src_fmt(4'h0);
      gpu_push({OP_EXEC_TEX, d14, n});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_m_w        = ((n & GPU_DIM_MASK) == 0) ? 1 : (n & GPU_DIM_MASK);
      gpu_m_h        = 1;
      gpu_x_setup(GPU_FILL, 4'd0, cl_tsw, 3'b000);
      pm    = gpu_pmask(gpu_x_bl);
      lw    = (cl_lw > 4'd10) ? 10 : cl_lw;
      lh    = (cl_lh > 4'd10) ? 10 : cl_lh;
      pitch = cl_free ? gpu_x_spitch : (1 << lw);
      ua    = {cl_u0, 5'b00000};
      va    = {cl_v0, 5'b00000};
      dua   = {{5{cl_du[15]}}, cl_du};
      dva   = {{5{cl_dv[15]}}, cl_dv};
      for (kk = 0; kk < gpu_x_w; kk = kk + 1) begin
         ui = ua[20:11];
         vi = va[20:11];
         if (!cl_free) begin
            ui = ui & ((1 << lw) - 1);
            vi = vi & ((1 << lh) - 1);
         end
         spa = (gpu_x_sbase + vi * pitch + ui) & GPU_PA_MASK;
         cl_chk_src(spa, gpu_x_bl);
         tt  = gpu_get_px(spa, gpu_x_bl);
         dpa = gpu_walk(gpu_x_dbase, gpu_x_dpitch, gpu_x_dsw, gpu_x_w, kk);
         cl_chk_dst(dpa, gpu_x_bl);
         gpu_touch_px(dpa, gpu_x_bl);
         if (!(cl_ten && (tt == (gpu_x_transp & pm))))
            gpu_set_px(dpa, gpu_x_bl, (tt + cl_shade) & pm);
         ua = ua + dua;
         va = va + dva;
      end
   end
endtask


//============================================================================
// List building: capture, random self-contained items, write, call
//============================================================================
reg [31:0] cl_words [0:GPU_CAP_MAX-1];
integer    cl_nw;
reg [31:0] cl_pre   [0:VRAM_WORDS-1];
reg [31:0] cl_post  [0:VRAM_WORDS-1];

task cl_begin;
   begin
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
   end
endtask

task cl_end;
   integer kk;
   begin
      gpu_cap_en = 1'b0;
      cl_nw      = gpu_cap_n;
      for (kk = 0; kk < gpu_cap_n; kk = kk + 1)
         cl_words[kk] = gpu_cap_buf[kk];
   end
endtask

function integer cl_isize;               // words of a generated item
   input integer kind;
   begin
      cl_isize = (kind == 0) ? 8 : (kind == 3) ? 6 : (kind == 5) ? 12 : 10;
   end
endfunction

// One item: every setting it uses is programmed by the item itself.
//   0 FILL, 1 COPY, 2 COPY_TRANSP, 3 two SPANs, 4 EXPAND, 5 TEXSPAN
task cl_item;
   input integer kind;
   integer       w, h, rows, cols, sdep, sbl, sppw, d1, bl;
   reg    [31:0] o, so, db, sb, pm;
   reg     [2:0] dsw, ssw;
   reg     [3:0] op;
   begin
      bl   = gpu_bl(gpu_m_mode);
      pm   = gpu_pmask(bl);
      w    = 1 + cl_rnd(CL_WMAX);
      h    = 1 + cl_rnd(CL_HMAX);
      dsw  = cl_rnd(8);
      ssw  = cl_rnd(8);
      op   = cl_rnd(16);
      rows = dsw[0] ? w : h;
      cols = dsw[0] ? h : w;
      sb   = 32'h0;
      case (kind)
        0, 1, 2: begin
           o  = cl_box(cl_dlo, cl_dhi, rows, cols, CL_DPITCH);
           db = cl_corner(o, CL_DPITCH, dsw, w, h);
           gpu_c_dst(CL_DPITCH, db);
           gpu_c_size(w, h);
           gpu_c_fill(cl_r32(0));
           if (kind != 0) begin
              so = cl_box(cl_slo, cl_shi, ssw[0] ? w : h, ssw[0] ? h : w, CL_SPITCH);
              sb = cl_corner(so, CL_SPITCH, ssw, w, h);
              gpu_c_src_fmt(CL_SPITCH, sb, 4'h0);
           end
           if ((kind == 2) && !cl_fixed)
              gpu_c_transp((cl_r32(0) & ~pm) | gpu_get_px(sb, bl));
           else
              gpu_c_transp(cl_r32(0));
           gpu_c_exec((kind == 0) ? GPU_FILL : (kind == 1) ? GPU_COPY : GPU_COPYT, op, dsw,
                      (kind == 0) ? 3'b000 : ssw);
        end
        3: begin
           o = cl_box(cl_dlo, cl_dhi, 1, 100, CL_DPITCH);
           gpu_c_dst(CL_DPITCH, o + 50);
           gpu_c_fill(cl_r32(0));
           cl_span(cl_rnd(41) - 20, w);
           cl_span(cl_rnd(41) - 20, 1 + cl_rnd(CL_WMAX));
        end
        4: begin
           sdep = cl_rnd(4);
           sbl  = sdep;
           sppw = 32 >> sbl;
           d1   = cl_rnd(17) - 8;
           gpu_c_src_fmt(16'd0, CL_SRC_LO * sppw + cl_rnd((CL_SRC_HI - CL_SRC_LO) * sppw - w * h - 1),
                         sdep + 1);
           gpu_c_size(w, h);
           gpu_c_fill(cl_r32(0));
           gpu_c_transp(cl_r32(0));
           o = cl_box(cl_dlo, cl_dhi, rows, cols, CL_DPITCH);
           gpu_c_dst(CL_DPITCH, cl_corner(o, CL_DPITCH, dsw, w, h) - d1);
           cl_exp(d1, dsw, cl_rnd(2), sdep);
        end
        default: begin
           gpu_c_src_fmt(16'd0, cl_slo + cl_rnd(cl_shi - cl_slo - 33), 4'h0);    // 8 x 4 texture
           gpu_c_transp(cl_rnd(4));
           cl_set_tex(4'd3, 4'd2, cl_rnd(2), dsw, 1'b0, cl_rnd(256));
           cl_set_uv(cl_r32(0), cl_r32(0));
           cl_set_step(cl_r32(0), cl_r32(0));
           o = cl_box(cl_dlo, cl_dhi, dsw[0] ? w : 1, dsw[0] ? 1 : w, CL_DPITCH);
           gpu_c_dst(CL_DPITCH, cl_corner(o, CL_DPITCH, dsw, w, 1));
           cl_tex(0, w);
        end
      endcase
   end
endtask

// Random items until fewer than 6 words are left below tmax (FENCE 0/1 now
// and then before an item; the last word is always an EXEC)
task cl_gen;
   input integer tmax;
   integer       kind;
   begin
      while ((tmax - gpu_cap_n) >= 6) begin
         if (((tmax - gpu_cap_n) >= 7) && (cl_rnd(8) == 0))
            gpu_c_fence(cl_rnd(2));
         kind = cl_rnd(cl_tex_ok ? 6 : 5);
         if (cl_isize(kind) > (tmax - gpu_cap_n))
            kind = ((tmax - gpu_cap_n) >= 8) ? 0 : 3;
         cl_item(kind);
      end
   end
endtask

// Write the captured list at word address a: 0 backdoor, 1 VRAM window first
// word first, 2 VRAM window first word last. The shadow follows.
task cl_write;
   input [31:0] a;
   input integer how;
   integer       kk, ix;
   reg    [31:0] wd;
   begin
      for (kk = 0; kk < cl_nw; kk = kk + 1) begin
         ix = (how == 2) ? (cl_nw - 1 - kk) : kk;
         wd = (a + ix) & CL_AMASK;
         if ((wd >= VRAM_WORDS) || ((wd >= CL_SRC_LO) && (wd < CL_BG_HI)))
            tb_error("command list outside the list areas (test bug)");
         else begin
            if (how == 0) vram_mem[wd] = cl_words[ix];
            else          vram_wr(4 * wd, cl_words[ix], SZ_W);
            gpu_shadow[wd] = cl_words[ix];
         end
      end
   end
endtask

// Fill [lo, lo + n) with EXEC_FILL op 14 words (stale content that draws if fetched)
task cl_poison;
   input integer lo;
   input integer n;
   integer       kk;
   begin
      for (kk = lo; kk < lo + n; kk = kk + 1) begin
         vram_mem[kk]   = gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000);
         gpu_shadow[kk] = gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000);
      end
   end
endtask

task cl_call;                            // through gpu_push (FREE-paced when gpu_push_wait)
   input [23:0] n;
   input [31:0] opnd;
   begin
      gpu_push({OP_CALL, 4'h0, n});
      gpu_push(opnd);
   end
endtask

task cl_call_now;                        // two GPU_CMD writes, nothing in between
   input [23:0] n;
   input [31:0] opnd;
   begin
      reg_wr(GPU_CMD, {OP_CALL, 4'h0, n});
      reg_wr(GPU_CMD, opnd);
   end
endtask

task cl_setup_mode;                      // idle GPU, mode, fresh sources / destinations, flags cleared
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      cl_regions(gpu_bl(mode));
      gpu_preload_rand(CL_SRC_LO, CL_DST_HI);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

task cl_idle_chk;                        // idle, list ended, FIFO empty, no error, image checked
   input [8*40-1:0] label;
   begin
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, CL_STMASK);
      reg_rd(GPU_LIST, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      gpu_check_touched(label);
   end
endtask

// A short list and a FIFO EXEC behind it (the GPU works normally)
task cl_works;
   input [8*40-1:0] label;
   begin
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_begin;
      cl_gen(30);
      cl_end;
      cl_write(CL_LB, 0);
      cl_call(cl_nw, cl_opnd(CL_LB, 1'b0));
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd6, gpu_x_dsw, 3'b000);
      cl_idle_chk(label);
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask


//============================================================================
// 1. Basic lists, equivalence with the FIFO
//============================================================================
task cl_basic;
   input integer mode;
   input integer a;
   input integer tmax;
   input integer how;
   input integer hi;
   integer       kk, nbad;
   begin
      cl_setup_mode(mode);
      cl_begin;
      cl_gen(tmax);
      cl_end;
      cl_write(a, how);
      repeat (4) @(posedge free_clk);                    // the last window write has landed
      for (kk = 0; kk < VRAM_WORDS; kk = kk + 1)
         cl_pre[kk] = vram_mem[kk];
      cl_call(cl_nw, cl_opnd(a, hi));
      $display("       mode %0d, %0d words at word 0x%h (%0s), operand high bits %0d",
               mode, cl_nw, a, (how == 0) ? "backdoor" : (how == 1) ? "window" : "window, reverse", hi);
      cl_idle_chk("list");
      // the same words through GPU_CMD, from the pre-list image
      for (kk = 0; kk < VRAM_WORDS; kk = kk + 1) begin
         cl_post[kk]  = vram_mem[kk];
         vram_mem[kk] = cl_pre[kk];
      end
      for (kk = 0; kk < cl_nw; kk = kk + 1)
         gpu_push(cl_words[kk]);
      gpu_wait_idle;
      nbad = 0;
      for (kk = 0; kk < VRAM_WORDS; kk = kk + 1)
         if (vram_mem[kk] !== cl_post[kk]) begin
            nbad = nbad + 1;
            if (nbad <= 4)
               $display("ERROR: GPU list vs FIFO -- word 0x%h = 0x%h through GPU_CMD / 0x%h through CALL %t",
                        kk, vram_mem[kk], cl_post[kk], $time);
            error = error + 1;
         end
      if (nbad == 0)
         $display("OK:    GPU list replayed through GPU_CMD -- identical VRAM");
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask


//============================================================================
// 2. FIFO words behind lists, queued CALLs, CALL N = 0
//============================================================================
integer cl_q_seen;

task cl_queue;
   integer    mode, na;
   reg [31:0] st;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      cl_poison(CL_LA, CL_LALL);
      cl_begin;
      cl_gen(CL_LEN);
      cl_end;
      na = cl_nw;
      cl_write(CL_LA, 0);
      cl_call(na, cl_opnd(CL_LA, 1'b1));
      // XOR over the list's last rectangle with the state the list left
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd5, gpu_x_dsw, 3'b000);
      reg_rd_val(GPU_STAT, st);
      if (st & CL_GS_LIST) begin
         cl_q_seen = cl_q_seen + 1;
         if (((st >> 8) & 32'hFF) < 3) begin
            $display("ERROR: GPU words pushed behind a running list -- USED = %0d / expected >= 3 %t",
                     (st >> 8) & 32'hFF, $time);
            error = error + 1;
         end
         if (!(st & GS_BUSY)) tb_error("GPU BUSY = 0 while LIST = 1");
      end
      // list B written through the window while A runs, queued
      cl_begin;
      cl_gen(CL_LEN);
      cl_end;
      cl_write(CL_LB, 1);
      cl_call(cl_nw, cl_opnd(CL_LB, 1'b0));
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd8, gpu_x_dsw, 3'b000);
      // CALL N = 0 queued (operand shaped as an EXEC_FILL), then one more EXEC
      cl_call(24'd0, cl_opnd(CL_LA + cl_rnd(CL_LEN), 1'b1));
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd6, gpu_x_dsw, 3'b000);
      $display("       mode %0d, lists of %0d and %0d words, FIFO EXECs between and after", mode, na, cl_nw);
      cl_idle_chk("FIFO behind lists");
      // CALL N = 0 while idle: nothing happens, the next word executes
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_call(24'd0, cl_opnd(cl_rnd(VRAM_WORDS), 1'b1));
      repeat(20) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, CL_STMASK);
      reg_rd(GPU_LIST, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE | IF_ERR | IF_OVFL);
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd7, gpu_x_dsw, 3'b000);
      cl_idle_chk("EXEC after CALL N = 0");
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE);
   end
endtask


//============================================================================
// 3. Lists written through the VRAM window, CALL with no delay
//============================================================================
task cl_race;
   input integer k;
   integer       mode, na;
   begin
      mode = (k == 0) ? 4 : (k == 1) ? 0 : cl_rnd(5);
      cl_setup_mode(mode);
      cl_poison(CL_LA, CL_LALL);
      // v1: first word written first
      cl_begin;
      cl_gen(CL_LEN);
      cl_end;
      cl_write(CL_LA, 1);
      cl_call_now(cl_nw, cl_opnd(CL_LA, k & 1));
      $display("       mode %0d: %0d words through the window, CALL right after the last write", mode, cl_nw);
      cl_idle_chk("window list v1");
      // v2 over a poisoned area, first word written last
      cl_poison(CL_LA, CL_LEN);
      cl_begin;
      cl_gen(30 + cl_rnd(CL_LEN - 30));
      cl_end;
      cl_write(CL_LA, 2);
      cl_call_now(cl_nw, cl_opnd(CL_LA, 1'b0));
      $display("       rewritten: %0d words, first word written last", cl_nw);
      cl_idle_chk("window list v2");
      // A runs while B is written through the window; CALL B right behind
      cl_poison(CL_LA, CL_LALL);
      cl_begin;
      cl_gen(CL_LEN);
      cl_end;
      na = cl_nw;
      cl_write(CL_LA, 0);
      cl_call_now(na, cl_opnd(CL_LA, 1'b0));
      cl_begin;
      cl_gen(CL_LEN);
      cl_end;
      cl_write(CL_LB, 1 + (k & 1));
      cl_call_now(cl_nw, cl_opnd(CL_LB, 1'b1));
      $display("       list B (%0d words) written while list A (%0d words) runs", cl_nw, na);
      cl_idle_chk("two lists in turn");
   end
endtask


//============================================================================
// 5-7. Invalid words and truncated lists
//============================================================================
// kind 0: bad = an invalid word inside the list (two never-run words after it)
// kind 1: bad = the last word, a command whose operand is missing
// exit 0 CLEAR_ERR, 1 ABORT then CLEAR_ERR, 2 GPU_EN = 0
// pre: items before the bad word; prek 1: SET_SIZE words instead of items
// a < 0: random address in list A
task cl_err_case;
   input integer kind;
   input  [31:0] bad;
   input   [3:0] eop;
   input integer exit;
   input integer pre;
   input integer prek;
   input integer a_in;
   input integer hi;
   integer       mode, ii, jj, guard, a;
   reg    [31:0] st, st2, exp_l;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      a = (a_in < 0) ? (CL_LA + cl_rnd(CL_LEN - 40)) : a_in;
      cl_begin;
      for (ii = 0; ii < pre; ii = ii + 1)
         if (prek == 1) gpu_c_size(1 + cl_rnd(CL_WMAX), 1 + cl_rnd(CL_HMAX));
         else           cl_item(cl_rnd(5));
      jj = gpu_cap_n;
      gpu_push(bad);
      if (kind == 0) begin
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
         gpu_push({OP_FENCE, 28'h100_0001});
      end
      cl_end;
      cl_write(a, 0);
      exp_l = (a + jj) & CL_AMASK;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_call(cl_nw, cl_opnd(a, hi));
      // two words behind the CALL: never consumed (nor taken as an operand)
      reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd15, 3'b000, 3'b000));
      reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      $display("--- %0s 0x%h at word 0x%h (list of %0d at 0x%h), exit %0s",
               (kind == 0) ? "invalid word" : "list ends after", bad, exp_l, cl_nw, a,
               (exit == 0) ? "CLEAR_ERR" : (exit == 1) ? "ABORT + CLEAR_ERR" : "GPU_EN=0");
      guard = 0;
      st    = 32'h0;
      while (!(st & GS_ERR) && (guard < 300)) begin
         reg_rd_val(GPU_STAT, st);
         guard = guard + 1;
      end
      if (!(st & GS_ERR)) tb_error("ERR not raised by the list");
      reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 2000);           // a rectangle before it completes
      repeat(50) @(posedge free_clk);
      reg_rd_val(GPU_STAT, st);
      // ERR_CAUSE: 1 (an invalid word, a CALL in the list), 4 (the list cut)
      if ((st & (32'hFE00_0000 | GS_ERR | CL_GS_LIST | GS_BUSY | GS_PRIM_BUSY)) !==
          ((eop << 28) | ((kind ? 32'd4 : 32'd1) << 25) | GS_ERR | CL_GS_LIST | GS_BUSY)) begin
         $display("ERROR: GPU_STAT 0x%h -- expected ERR_OPCODE %h, ERR_CAUSE %0d, ERR, LIST, BUSY, no PRIM_BUSY %t",
                  st, eop, kind ? 4 : 1, $time);
         error = error + 1;
      end else
         $display("OK:    GPU stopped: ERR, ERR_OPCODE %h, ERR_CAUSE %0d, LIST, BUSY", eop, kind ? 4 : 1);
      reg_rd(GPU_ERR, bad);                                   // the word (the cut command)
      if (((st >> 8) & 32'hFF) < 2) begin
         $display("ERROR: GPU FIFO words behind the CALL consumed (USED = %0d) %t", (st >> 8) & 32'hFF, $time);
         error = error + 1;
      end
      reg_rd(GPU_LIST, exp_l);
      reg_rd_mask(STATUS, 32'h6, 32'h6);
      reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR | IF_OVFL);
      repeat(100) @(posedge free_clk);                        // decoder stays stopped
      reg_rd(GPU_LIST, exp_l);
      reg_rd_val(GPU_STAT, st2);
      if (st2 !== st) begin
         $display("ERROR: GPU_STAT changed while stopped: 0x%h -> 0x%h %t", st, st2, $time);
         error = error + 1;
      end
      if (exit == 0)
         reg_wr(GPU_CTRL, 32'h1);
      else if (exit == 1) begin
         reg_wr(GPU_CTRL, 32'h2);
         repeat(4) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, (eop << 28) | GS_ERR | GS_EMPTY | GPU_FIFO_DEPTH, 32'hF000_0000 | CL_STMASK);
         reg_rd_mask(STATUS, 32'h4, 32'h4);
         reg_wr(GPU_CTRL, 32'h1);
      end else begin
         reg_wr(CTRL, mode);
         repeat(4) @(posedge free_clk);
         gpu_set_mode(mode);
      end
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, (eop << 28) | ((kind ? 32'd4 : 32'd1) << 25) | GS_EMPTY | GPU_FIFO_DEPTH,
                  32'hFE00_0000 | CL_STMASK);                 // the record kept
      reg_rd(GPU_ERR, bad);
      reg_rd(GPU_LIST, 32'h0);
      reg_rd_mask(STATUS, 32'h0, 32'h6);
      gpu_check_touched("before the bad word");
      cl_works("GPU after the error");
   end
endtask


//============================================================================
// 8. ABORT / GPU_EN = 0 in the middle of a list
//============================================================================
integer cl_between_hits;

task cl_abort_mid;
   input integer k;
   integer       mode, bl, ppw, nn, tot;
   reg     [3:0] cmd;
   reg     [2:0] sw;
   reg    [31:0] o, so;
   begin
      mode = ((k % 3) == 0) ? 0 : ((k % 3) == 1) ? 2 : 4;
      cmd  = (mode == 4) ? GPU_FILL : GPU_COPY;
      cl_setup_mode(mode);
      bl   = gpu_bl(mode);
      ppw  = 32 >> bl;
      $display("--- %0s in a list rectangle, mode %0d", (k < 3) ? "ABORT" : "GPU_EN=0", mode);
      cl_begin;
      o  = cl_box(cl_dlo, cl_dhi, CL_BH, CL_BW, CL_DPITCH);
      so = cl_box(cl_slo, cl_shi, CL_BH, CL_BW, CL_BW + 1);
      gpu_c_dst(CL_DPITCH, o);
      gpu_c_src(CL_BW + 1, so);
      sw = (mode == 4) ? 3'b000 : 3'b001;                       // copies: CL swaps, one pixel per token
      gpu_c_size(sw[0] ? CL_BH : CL_BW, sw[0] ? CL_BW : CL_BH);
      gpu_c_fill(cl_r32(0));
      gpu_c_transp(cl_r32(0));
      gpu_push(gpu_exec_word(cmd, 4'd5, sw, sw));                // modelled only up to the abandon
      gpu_x_setup(cmd, 4'd5, sw, sw);
      gpu_push({OP_SET_DST, 12'h0, 16'd17});                    // never executed
      gpu_push(cl_dlo + 7);
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      gpu_push({OP_FENCE, 28'h100_0001});
      cl_end;
      cl_write(CL_LA, 0);
      gpu_snapshot;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_call(cl_nw, cl_opnd(CL_LA, k & 1));
      reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      reg_wr(GPU_CMD, {OP_FENCE, 28'h100_0001});
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 200);
      repeat(60 + cl_rnd(100)) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, CL_GS_LIST | GS_BUSY | GS_PRIM_BUSY, CL_GS_LIST | GS_BUSY | GS_PRIM_BUSY);
      if (k < 3)
         reg_wr(GPU_CTRL, 32'h2);
      else begin
         reg_wr(CTRL, mode);
         reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));   // dropped
         reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
      end
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, CL_STMASK);
      reg_rd(GPU_LIST, 32'h0);
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR);
      repeat(300) @(posedge free_clk);                          // nothing else happens
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR);
      gpu_find_prefix(nn);
      tot = gpu_x_w * gpu_x_h;
      if ((nn <= 0) || (nn >= tot)) begin
         $display("ERROR: GPU abandoned list rectangle -- image is not a strict prefix (n = %0d of %0d) %t", nn, tot, $time);
         error = error + 1;
      end else
         $display("OK:    GPU list rectangle abandoned after %0d of %0d pixels (clean prefix)", nn, tot);
      gpu_check_touched("abandoned list rectangle");
      if (k >= 3) gpu_set_mode(mode);
      cl_works("new CALL after the abandon");
   end
endtask

task cl_abort_between;
   input integer k;
   integer       mode, ii, guard;
   reg    [31:0] st, o;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      $display("--- ABORT between two list rectangles, mode %0d", mode);
      cl_begin;
      o = cl_box(cl_dlo, cl_dhi, CL_BH, CL_BW, CL_DPITCH);
      gpu_c_dst(CL_DPITCH, o);
      gpu_c_size(CL_BW, CL_BH);
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);               // completes (modelled)
      for (ii = 0; ii < CL_LALL - 12; ii = ii + 1)
         gpu_push({OP_FENCE, 28'h0});                           // padding
      gpu_push({OP_SET_DST, 12'h0, 16'd23});                    // never executed
      gpu_push(cl_dlo + 3);
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      gpu_push({OP_FENCE, 28'h100_0001});
      cl_end;
      cl_write(CL_LA, 0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_call(cl_nw, cl_opnd(CL_LA, 1'b0));
      reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));   // flushed
      reg_wr(GPU_CMD, {OP_FENCE, 28'h100_0001});
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 200);
      guard = 0;
      st    = GS_PRIM_BUSY;
      while ((st & GS_PRIM_BUSY) && (guard < 1000)) begin
         reg_rd_val(GPU_STAT, st);
         guard = guard + 1;
      end
      if (st & CL_GS_LIST) begin
         reg_wr(GPU_CTRL, 32'h2);
         cl_between_hits = cl_between_hits + 1;
      end else begin
         $display("INFO:  list ended before the ABORT (GPU_STAT 0x%h)", st);
         gpu_wait_idle;
      end
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, CL_STMASK);
      reg_rd(GPU_LIST, 32'h0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      repeat(300) @(posedge free_clk);                          // second rectangle / FENCE 1 never run
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE | IF_ERR);
      gpu_check_touched("ABORT between list rectangles");
      cl_works("new CALL after the ABORT");
   end
endtask


//============================================================================
// 9. Debug freeze
//============================================================================
integer cl_held_list, cl_held_chk;

// Random items, then a CL_BW x CL_BH FILL op 5 last: the list runs long enough
task cl_gen_long;
   reg [31:0] o;
   begin
      cl_begin;
      cl_gen(CL_LEN - 6);
      o = cl_box(cl_dlo, cl_dhi, CL_BH, CL_BW, CL_DPITCH);
      gpu_c_dst(CL_DPITCH, o);
      gpu_c_size(CL_BW, CL_BH);
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      cl_end;
   end
endtask

task cl_freeze_strict;
   input integer k;
   integer       mode, t0, kk, nbad;
   reg    [31:0] st, s1, s2, l1, l2;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      cl_gen_long;
      cl_write(CL_LA, 0);
      cl_call(cl_nw, cl_opnd(CL_LA, 1'b1));
      repeat(20 + cl_rnd(150)) @(posedge free_clk);
      gpu_freeze(1'b1);
      t0 = gpu_cyc;
      st = 32'h0;
      while (!(st & GS_HELD) && (gpu_cyc - t0 < 100))
         reg_rd_val(GPU_STAT, st);
      if (!(st & GS_HELD)) begin
         $display("ERROR: GPU HELD not set 100 cycles after the freeze (list running) %t", $time);
         error = error + 1;
      end else begin
         gpu_mon_noacc = 1'b1;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         reg_rd_val(GPU_LIST, l1);
         reg_rd_val(GPU_STAT, s1);
         for (kk = 0; kk < VRAM_WORDS; kk = kk + 1)
            cl_post[kk] = vram_mem[kk];
         repeat(300) @(posedge free_clk);
         reg_rd_val(GPU_LIST, l2);
         reg_rd_val(GPU_STAT, s2);
         if (s1 & CL_GS_LIST) cl_held_list = cl_held_list + 1;
         if ((l1 !== l2) || (s1 !== s2)) begin
            $display("ERROR: GPU progressed while frozen: GPU_LIST 0x%h -> 0x%h, GPU_STAT 0x%h -> 0x%h %t", l1, l2, s1, s2, $time);
            error = error + 1;
         end else
            $display("OK:    GPU frozen mid-list: GPU_LIST 0x%h, GPU_STAT 0x%h stable", l1, s1);
         if ((s1 & CL_GS_LIST) && ((l1 < CL_LA) || (l1 > CL_LA + cl_nw))) begin
            $display("ERROR: GPU_LIST 0x%h outside the list [0x%h, 0x%h] %t", l1, CL_LA, CL_LA + cl_nw, $time);
            error = error + 1;
         end
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE | IF_IDLE | IF_ERR);
         nbad = 0;
         for (kk = 0; kk < VRAM_WORDS; kk = kk + 1)
            if (vram_mem[kk] !== cl_post[kk]) nbad = nbad + 1;
         if (nbad != 0) begin
            $display("ERROR: GPU %0d VRAM words changed while frozen %t", nbad, $time);
            error = error + 1;
         end
         gpu_mon_noacc = 1'b0;
      end
      gpu_freeze(1'b0);
      cl_idle_chk("frozen list");
   end
endtask

task cl_freeze_toggle;
   input integer k;
   integer       mode, tg;
   reg    [31:0] st, l1, l2;
   reg           dbgc;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      cl_gen_long;
      cl_write(CL_LB, 0);
      cl_bg_en = 1'b1;
      cl_call(cl_nw, cl_opnd(CL_LB, k & 1));
      reg_wr(DBG_CTRL, 32'h2);
      dbgc = 1'b1;
      for (tg = 0; tg < 30; tg = tg + 1) begin
         repeat(1 + cl_rnd(32)) @(negedge free_clk);
         if (k & 2)
            dbg_stoptime = ~dbg_stoptime;
         else begin
            dbg_stoptime = 1'b1;
            dbgc         = ~dbgc;
            reg_wr(DBG_CTRL, dbgc ? 32'h2 : 32'h0);
         end
         if (dbg_stoptime && dbgc) begin
            reg_rd_val(GPU_STAT, st);
            if ((st & GS_HELD) && (st & CL_GS_LIST)) begin
               reg_rd_val(GPU_LIST, l1);
               repeat(10) @(posedge free_clk);
               reg_rd_val(GPU_LIST, l2);
               if (l1 !== l2) begin
                  $display("ERROR: GPU_LIST moved while held: 0x%h -> 0x%h %t", l1, l2, $time);
                  error = error + 1;
               end
               cl_held_chk = cl_held_chk + 1;
            end
         end
      end
      @(negedge free_clk) dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      gpu_wait_idle;
      $display("       mode %0d, %0d words, freeze via %0s, window traffic %0d writes / %0d reads so far",
               mode, cl_nw, (k & 2) ? "dbg_stoptime" : "DBG_CTRL[1]", cl_bg_nw, cl_bg_nr);
      cl_bg_pause;
      cl_idle_chk("freeze toggling + contention");
   end
endtask


//============================================================================
// 10. Status while a list runs, GPU_DONE / GPU_IDLE, FENCE, N = 1
//============================================================================
localparam integer CL_NRECT = 12;

task cl_status;
   integer    mode, rr, cnt, guard, nlist, ndist;
   reg [31:0] f, s, l, lprev, o, so;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      cl_begin;
      gpu_c_size(CL_WMAX, CL_HMAX);
      so = cl_box(cl_slo, cl_shi, CL_HMAX, CL_WMAX, CL_SPITCH);
      gpu_c_src(CL_SPITCH, so);
      gpu_c_transp(cl_r32(0));
      for (rr = 0; rr < CL_NRECT; rr = rr + 1) begin
         o = cl_box(cl_dlo, cl_dhi, CL_HMAX, CL_WMAX, CL_DPITCH);
         gpu_c_dst(CL_DPITCH, o);
         gpu_c_fill(cl_r32(0));
         gpu_c_exec((rr % 2) ? GPU_COPY : GPU_FILL, (rr % 2) ? 4'd3 : 4'd5, 3'b000, 3'b000);
      end
      cl_end;
      cl_write(CL_LA, 0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_call(cl_nw, CL_LA);
      cnt   = 0;
      guard = 0;
      nlist = 0;
      ndist = 0;
      lprev = CL_LA;
      s     = GS_BUSY;
      while ((s & GS_BUSY) && (guard < 20000)) begin
         reg_rd_val(IRQ_FLAG, f);
         if (f & IF_DONE) begin
            reg_wr(IRQ_FLAG, IF_DONE);
            cnt = cnt + 1;
         end
         reg_rd_val(GPU_LIST, l);
         reg_rd_val(GPU_STAT, s);
         if ((f & IF_IDLE) && (s & GS_BUSY)) begin
            $display("ERROR: GPU_IDLE raised while the list still runs (GPU_STAT 0x%h) %t", s, $time);
            error = error + 1;
         end
         if (s & CL_GS_LIST) begin
            nlist = nlist + 1;
            if (!(s & GS_BUSY)) tb_error("GPU BUSY = 0 while LIST = 1");
            if ((l < CL_LA) || (l > CL_LA + cl_nw) || (l < lprev)) begin
               $display("ERROR: GPU_LIST 0x%h -- expected in [0x%h, 0x%h], not below 0x%h %t",
                        l, CL_LA, CL_LA + cl_nw, lprev, $time);
               error = error + 1;
            end
            if (l != lprev) ndist = ndist + 1;
            lprev = l;
         end
         guard = guard + 1;
      end
      reg_rd_val(IRQ_FLAG, f);
      if (f & IF_DONE) cnt = cnt + 1;
      if (!(f & IF_IDLE)) tb_error("no GPU_IDLE at the end of the list");
      if (guard >= 20000) tb_error("GPU never became idle while counting GPU_DONE");
      if (cnt != CL_NRECT) begin
         $display("ERROR: GPU_DONE events %0d / expected %0d (one per EXEC of the list) %t", cnt, CL_NRECT, $time);
         error = error + 1;
      end else
         $display("OK:    GPU_DONE once per EXEC of the list (%0d)", cnt);
      $display("       mode %0d: %0d samples with LIST = 1, GPU_LIST moved %0d times", mode, nlist, ndist);
      if ((nlist < 4) || (ndist < 2))
         tb_error("too few LIST / GPU_LIST samples while the list ran (test bug)");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_idle_chk("status list");
   end
endtask

task cl_fences;
   integer    mode, cnt, guard;
   reg [31:0] f, s, o;
   begin
      mode = cl_rnd(5);
      cl_setup_mode(mode);
      $display("--- FENCE 1 in lists, N = 1");
      // configuration-only list ending with FENCE 1: GPU_FENCE, no GPU_DONE
      cl_begin;
      gpu_c_fill(cl_r32(0));
      gpu_c_size(CL_WMAX, CL_HMAX);
      gpu_c_fence(1'b1);
      cl_end;
      cl_write(CL_LA, 0);
      cl_call(cl_nw, CL_LA);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_FENCE | IF_IDLE, IF_GPU_ALL);
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      repeat(20) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE | IF_FENCE);
      // configuration-only list without FENCE: no GPU_DONE (a CALL raises nothing)
      cl_begin;
      gpu_c_fill(cl_r32(0));
      gpu_c_transp(cl_r32(0));
      cl_end;
      cl_write(CL_LB, 0);
      cl_call(cl_nw, CL_LB);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // N = 1: FENCE 1 alone
      cl_begin;
      gpu_c_fence(1'b1);
      cl_end;
      cl_write(CL_LA + 50, 0);
      cl_call(24'd1, cl_opnd(CL_LA + 50, 1'b1));
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_FENCE | IF_IDLE, IF_GPU_ALL);
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // N = 1: one EXEC, state programmed through the FIFO
      o = cl_box(cl_dlo, cl_dhi, CL_HMAX, CL_WMAX, CL_DPITCH);
      gpu_c_dst(CL_DPITCH, o);
      gpu_c_size(CL_WMAX, CL_HMAX);
      gpu_c_fill(cl_r32(0));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_begin;
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      cl_end;
      cl_write(CL_LB + 50, 0);
      cl_call(24'd1, cl_opnd(CL_LB + 50, 1'b0));
      cl_idle_chk("N = 1 EXEC");
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // a rectangle then FENCE 1 as the last word: one GPU_DONE (the EXEC) and GPU_FENCE
      cl_begin;
      o = cl_box(cl_dlo, cl_dhi, CL_HMAX, CL_WMAX, CL_DPITCH);
      gpu_c_dst(CL_DPITCH, o);
      gpu_c_fill(cl_r32(0));
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      gpu_c_fence(1'b1);
      cl_end;
      cl_write(CL_LA, 0);
      cl_call(cl_nw, CL_LA);
      cnt   = 0;
      guard = 0;
      s     = GS_BUSY;
      while ((s & GS_BUSY) && (guard < 5000)) begin
         reg_rd_val(IRQ_FLAG, f);
         if (f & IF_DONE) begin
            reg_wr(IRQ_FLAG, IF_DONE);
            cnt = cnt + 1;
         end
         reg_rd_val(GPU_STAT, s);
         guard = guard + 1;
      end
      reg_rd_val(IRQ_FLAG, f);
      if (f & IF_DONE) cnt = cnt + 1;
      if (cnt != 1) begin
         $display("ERROR: GPU_DONE events %0d for EXEC + FENCE 1 / expected 1 %t", cnt, $time);
         error = error + 1;
      end else
         $display("OK:    EXEC + FENCE 1 at the end of a list: 1 GPU_DONE event");
      reg_rd_mask(IRQ_FLAG, IF_FENCE, IF_FENCE);
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_idle_chk("EXEC + FENCE 1 list");
   end
endtask



//============================================================================
// 12. Directed timing sweeps: a flush on every cycle after a CALL (a list
//     read in flight must be dropped, never fed to the next list), and a
//     freeze on every cycle after a CALL (no list read while held)
//============================================================================
task cl_abort_sweep;
   input integer d;
   integer       kk;
   begin
      cl_setup_mode(3);
      for (kk = 0; kk < 64; kk = kk + 1) begin              // list A: FENCE 0, read back to back
         vram_mem[CL_LA + kk]   = {OP_FENCE, 28'h0};
         gpu_shadow[CL_LA + kk] = {OP_FENCE, 28'h0};
      end
      cl_call_now(24'd64, cl_opnd(CL_LA, 1'b0));
      repeat (d) @(posedge free_clk);
      reg_wr(GPU_CTRL, 32'h2);                               // ABORT: list ended mid-stream
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_begin;
      cl_gen(24);
      cl_end;
      cl_write(CL_LB, 0);
      cl_call(cl_nw, cl_opnd(CL_LB, 1'b0));
      cl_idle_chk("list after a flush");
   end
endtask

task cl_freeze_sweep;
   input integer d;
   integer       h0;
   begin
      cl_setup_mode(3);
      cl_begin;
      cl_gen(24);
      cl_end;
      cl_write(CL_LA, 0);
      cl_call_now(cl_nw, cl_opnd(CL_LA, 1'b0));
      repeat (d) @(posedge free_clk);
      gpu_freeze(1'b1);
      repeat (3) @(posedge free_clk);                        // an access granted before the freeze completes
      h0 = gpu_mon_noacc_hits;
      gpu_mon_noacc = 1'b1;
      repeat (60) @(posedge free_clk);
      gpu_mon_noacc = 1'b0;
      if (gpu_mon_noacc_hits != h0) begin
         $display("ERROR: GPU VRAM access while frozen, freeze %0d cycles after the CALL %t", d, $time);
         error = error + 1;
      end
      gpu_freeze(1'b0);
      cl_idle_chk("list frozen at its start");
   end
endtask

//============================================================================
// 11. The same list words at 8 and 16 bpp
//============================================================================
reg [31:0] cl_first [0:CL_LEN-1];
integer    cl_k4;
reg [31:0] cl_o4;

task cl_modes;
   integer    mm, mode, kk, nfirst, nbad, gs;
   reg [23:0] fg;
   begin
      gs     = cl_gseed;
      fg     = gpu_m_fence;
      nfirst = 0;
      for (mm = 0; mm < 2; mm = mm + 1) begin
         mode = (mm == 0) ? 3 : 4;
         cl_setup_mode(mode);
         // pixel addresses valid at both depths: destinations 1200..1499,
         // GFX-depth sources 1500..1799 (no TEXSPAN, no source-dependent words)
         cl_dlo    = 1200;
         cl_dhi    = 1500;
         cl_slo    = 1500;
         cl_shi    = 1800;
         cl_tex_ok = 1'b0;
         cl_fixed  = 1'b1;
         cl_gseed  = gs;
         gpu_m_fence = fg;                                      // same FENCE tags
         cl_begin;
         cl_gen(CL_LEN);
         cl_end;
         if (mm == 0) begin
            nfirst = cl_nw;
            for (kk = 0; kk < cl_nw; kk = kk + 1) cl_first[kk] = cl_words[kk];
            cl_write(CL_LA, 1);                                 // written once
         end else begin
            nbad = (cl_nw != nfirst) ? 1 : 0;
            for (kk = 0; (kk < cl_nw) && (kk < nfirst); kk = kk + 1)
               if (cl_words[kk] !== cl_first[kk]) nbad = nbad + 1;
            if (nbad != 0) tb_error("list regenerated for 16 bpp differs from the 8 bpp one (test bug)");
         end
         cl_call(cl_nw, cl_opnd(CL_LA, mm));
         $display("       same %0d list words at %0d bpp", cl_nw, (mode == 3) ? 8 : 16);
         cl_idle_chk("list at 8 / 16 bpp");
      end
      cl_regions(gpu_bl(4));
   end
endtask


//============================================================================
integer cl_i;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: CALL (command lists in VRAM)      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed        = `SEED;
      cl_gseed        = gpu_seed ^ 32'h5A17_C0DE;
      cl_bg_seed      = gpu_seed ^ 32'h3C3C_9E37;
      cl_q_seen       = 0;
      cl_between_hits = 0;
      cl_held_list    = 0;
      cl_held_chk     = 0;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      reg_rd_mask(GPU_STAT, 32'h0, CL_GS_LIST);
      reg_rd(GPU_LIST, 32'h0);
      gpu_set_mode(4);
      cl_regions(4);
      gpu_set_dispw(CL_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("--- 1. random lists, equivalence with GPU_CMD");
      for (cl_i = 0; cl_i < 10; cl_i = cl_i + 1)
         cl_basic(cl_i % 5, ((cl_i % 2) ? CL_LB : CL_LA) + ((cl_i < 2) ? 0 : cl_rnd(40)),
                  (cl_i < 2) ? CL_LEN : 20 + cl_rnd(CL_LEN - 60), cl_i % 3, cl_i % 2);
      $display("--- 1b. one list of up to %0d words", CL_LALL);
      cl_basic(cl_rnd(5), CL_LA, CL_LALL, 0, 1);
      gpu_check_all("basic lists");

      //--------------------------------------------------------------
      $display("--- 2. FIFO words behind lists, queued CALL, CALL N = 0");
      for (cl_i = 0; cl_i < 3; cl_i = cl_i + 1)
         cl_queue;
      $display("       FIFO words seen waiting behind a running list: %0d time(s)", cl_q_seen);
      gpu_check_all("FIFO behind lists");

      //--------------------------------------------------------------
      $display("--- 3. lists written through the VRAM window, CALL with no delay");
      for (cl_i = 0; cl_i < 3; cl_i = cl_i + 1)
         cl_race(cl_i);
      gpu_check_all("window lists");

      //--------------------------------------------------------------
      $display("--- 4. lists at the top of the VRAM: one ending at VRAM_WORDS, one past it (ERR_CAUSE 6)");
      cl_setup_mode(cl_rnd(5));
      for (cl_k4 = 0; cl_k4 < 3; cl_k4 = cl_k4 + 1) begin
         vram_mem[VRAM_WORDS - 3 + cl_k4]   = {OP_FENCE, 28'h0};
         gpu_shadow[VRAM_WORDS - 3 + cl_k4] = {OP_FENCE, 28'h0};
      end
      cl_call(24'd3, cl_opnd(VRAM_WORDS - 3, 1'b1));
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      for (cl_k4 = 0; cl_k4 < 3; cl_k4 = cl_k4 + 1) begin             // draw if ever fetched
         vram_mem[VRAM_WORDS - 3 + cl_k4]   = {OP_EXEC_FILL, 28'h0E};
         gpu_shadow[VRAM_WORDS - 3 + cl_k4] = {OP_EXEC_FILL, 28'h0E};
      end
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      cl_o4 = cl_opnd(VRAM_WORDS - 3, 1'b1);
      cl_call(24'd4, cl_o4);
      repeat(30) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {4'h7, 3'd6, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_rd(GPU_ERR, cl_o4);
      reg_rd(GPU_LIST, 32'h0);                                         // never started
      reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR | IF_DONE);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_all("lists at the top of the VRAM");
      if (!CL_WRAP_OK)
         $display("       operand bits above VRAM_AW set throughout");

      //--------------------------------------------------------------
      $display("--- 5. CALL inside a list");
      cl_err_case(0, {OP_CALL, 4'h0, 24'd3},  4'h7, 0, 2, 0, -1, 1);
      cl_err_case(0, {OP_CALL, 4'h0, 24'd0},  4'h7, 1, 1, 0, -1, 0);
      cl_err_case(0, {OP_CALL, 4'hA, 24'h1F}, 4'h7, 2, 0, 0, -1, 1);

      //--------------------------------------------------------------
      $display("--- 6. invalid words inside a list");
      cl_err_case(0, 32'h0ABC_DEF1,            4'h0, 0, 1, 0, -1, 0);
      cl_err_case(0, 32'h0000_0000,            4'h0, 1, 2, 0, -1, 1);
      cl_err_case(0, {OP_SET_EXT, 4'hF, 24'h0}, 4'h6, 2, 1, 0, -1, 0);
      cl_err_case(0, {OP_SET_EXT, 4'hE, 24'h5}, 4'h6, 0, 0, 0, -1, 1);
      gpu_check_all("invalid words");

      //--------------------------------------------------------------
      $display("--- 7. lists ending between a command and its operand");
      cl_err_case(1, {OP_SET_SRC, 12'h0, 16'd33},  4'h7, 0, 1, 0, -1, 0);
      cl_err_case(1, {OP_SET_DST, 12'h0, 16'd31},  4'h7, 1, 2, 0, -1, 1);
      cl_err_case(1, {OP_SET_FILL, 28'h0},         4'h7, 2, 0, 0, -1, 0);     // N = 1
      cl_err_case(1, {OP_SET_TRANSP, 28'h0},       4'h7, 0, 1, 0, -1, 1);
      cl_err_case(1, {OP_SET_EXT, 4'h1, 24'h0},    4'h7, 1, 1, 0, -1, 0);
      cl_err_case(1, {OP_SET_EXT, 4'h2, 24'h0},    4'h7, 0, 2, 0, -1, 1);
      gpu_check_all("truncated lists");

      //--------------------------------------------------------------
      $display("--- 8. ABORT / GPU_EN = 0 in the middle of a list");
      for (cl_i = 0; cl_i < 6; cl_i = cl_i + 1)
         cl_abort_mid(cl_i);
      for (cl_i = 0; cl_i < 3; cl_i = cl_i + 1)
         cl_abort_between(cl_i);
      $display("       ABORT landed between list rectangles %0d time(s)", cl_between_hits);
      if (cl_between_hits == 0)
         tb_error("ABORT never landed between two list rectangles (test bug)");
      gpu_check_all("abort in lists");

      //--------------------------------------------------------------
      $display("--- 9. debug freeze in a list");
      for (cl_i = 0; cl_i < 3; cl_i = cl_i + 1)
         cl_freeze_strict(cl_i);
      if (cl_held_list == 0)
         tb_error("freeze never held mid-list (test bug)");
      if (gpu_mon_noacc_hits == 0) $display("OK:    GPU no VRAM access while held");
      for (cl_i = 0; cl_i < 4; cl_i = cl_i + 1)
         cl_freeze_toggle(cl_i);
      cl_bg_pause;
      $display("       held mid-list checks %0d, window writes %0d, reads %0d", cl_held_chk, cl_bg_nw, cl_bg_nr);
      if ((cl_held_chk == 0) || (cl_bg_nw == 0) || (cl_bg_nr == 0))
         tb_error("freeze never seen held mid-list, or no window traffic (test bug)");
      gpu_check_all("freeze in lists");

      //--------------------------------------------------------------
      $display("--- 10. status, GPU_LIST, GPU_DONE / GPU_IDLE while a list runs");
      cl_status;
      cl_status;
      cl_fences;
      gpu_check_all("status");

      //--------------------------------------------------------------
      $display("--- 11. same list words at 8 and 16 bpp");
      cl_modes;

      //--------------------------------------------------------------
      $display("--- 12. flush and freeze on every cycle after a CALL");
      for (cl_i = 0; cl_i < 20; cl_i = cl_i + 1)
         cl_abort_sweep(cl_i);
      for (cl_i = 0; cl_i < 12; cl_i = cl_i + 1)
         cl_freeze_sweep(cl_i);
      gpu_check_all("sweeps");

      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, CL_STMASK);
      reg_rd(GPU_LIST, 32'h0);
      gpu_check_all("call end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
