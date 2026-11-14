//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_tri
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_tri.v
// Module Description : Flat triangle fill: SET_EXT 9/10/11 SET_V0..V2 (operand
//                      {y, x}, signed 12.4, command bits [23:0] random and
//                      ignored) and EXEC_FILL [7] TRI, in x/y mode, against a
//                      reference rasterizer written in this file (tr_*):
//                      pixel centre (16px+8, 16py+8), 64-bit edge functions,
//                      top-left rule.
//                       1. directed triangles with hand-counted pixel sets;
//                       2. random triangles 0..60 px with sub-pixel, half-
//                          pixel and pixel-centre vertices, in all six vertex
//                          orders (both windings), at 1/2/4/8/16 bpp, random
//                          EXEC destination swaps (ignored by TRI);
//                       3. the 16 raster ops at GFX_MODE 0..7, transparency
//                          hit and miss;
//                       4. meshes drawn with XOR (op 5, all-ones fill) onto
//                          zero: grids of quads split in two triangles and
//                          closed fans; the image must be exactly the outer
//                          rectangle (no hole = no double draw, no gap);
//                       5. thin and degenerate triangles (zero area: nothing
//                          drawn, one GPU_DONE);
//                       6. clip window (partial, outside, one row / column,
//                          inverted) and negative coordinates;
//                       7. large triangles, 4096-pixel-long slivers with
//                          vertices at -2048.0 / 2047.9375;
//                       8. SET_GRAD with TRI: the walk is the pixel box
//                          (centres within the vertices' x / y ranges)
//                          clipped; AXIS 0: i = py - first walk row, AXIS 1:
//                          i = px - first walk column (empty apex rows,
//                          clipped top rows / left columns counted from the
//                          window);
//                       9. TRI in address mode draws nothing (one
//                          GPU_DONE); a rectangle after a TRI; SET_XY does
//                          not move a TRI;
//                      10. triangles in CALL lists, GPU_DONE counted once per
//                          triangle, GPU_DONE only at completion;
//                      11. ABORT / GPU_EN = 0 mid-triangle: nothing outside
//                          the triangle, queued words flushed, then a new
//                          triangle drawn exactly;
//                      12. debug freeze toggled mid-triangle: no VRAM access
//                          and no GPU_DONE while held, exact final image;
//                      13. SET_ALPHA blending of a TRI at 16 bpp (A 255, 0,
//                          random, with a gradient, op 5 blends S, ops
//                          13..15 their constant (15 with a gradient: its
//                          value) with the SET_TRANSP key), no effect at
//                          8 bpp.
//                      The clipped walk box is at most 2^DIM_W - 1 pixels:
//                      with DIM_W < 8 the triangles shrink (sections 4 and 7
//                      and the timing-dependent counts are left out).
//                      The destination region is compared with the model
//                      through the backdoor after every step; some steps are
//                      read back through the VRAM window; the whole VRAM is
//                      compared at the end.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

// Surface: pitch TR_P (odd), TR_NR rows, pixel x in [TR_X0, TR_XM], y in
// [TR_Y0, TR_YM] (negative coordinates included), in words [TR_D_LO, TR_D_HI)
localparam integer TR_P      = 163;
localparam integer TR_NR     = 160;
localparam integer TR_X0     = -48;
localparam integer TR_Y0     = -48;
localparam integer TR_XM     = TR_X0 + TR_P - 1;
localparam integer TR_YM     = TR_Y0 + TR_NR - 1;
localparam integer TR_NPX    = TR_P * TR_NR;
localparam integer TR_D_LO   = 1024;
localparam integer TR_D_HI   = TR_D_LO + TR_NPX / 2 + 4;
localparam integer TR_L_LO   = 300;              // command lists: words [TR_L_LO, TR_D_LO)
localparam integer TR_VMIN   = TR_D_HI + 16;
localparam  [3:0]  TR_EXT_V0 = 4'd9;             // SET_V0, SET_V1 = 10, SET_V2 = 11
localparam [31:0]  TR_GS_LIST = 32'h0100_0000;
localparam  [3:0]  TR_EXT_ALPHA = 4'd8;          // SET_ALPHA: [7:0] A, [8] EN
// The clipped walk box is at most 2^DIM_W - 1 pixels wide and high: with a
// small DIM_W (TR_SMALL) the triangles shrink to TR_SMAX and the meshes, the
// large triangles and the timing-dependent counts are left out.
localparam integer TR_DIMMAX = GPU_DIM_MASK;
localparam integer TR_SMALL  = (GPU_DIM_MASK < 255) ? 1 : 0;
localparam integer TR_SMAX   = (GPU_DIM_MASK >= 62) ? 60 : (GPU_DIM_MASK - 2);
localparam integer TR_SMIN   = (TR_SMAX >= 20) ? 10 : (TR_SMAX / 2);
localparam integer TR_NBIG   = TR_SMALL ? ((TR_SMAX * TR_SMAX) / 6) : 500;


//============================================================================
// Reference rasterizer state
//============================================================================
integer    tr_vx [0:2];                  // vertices as programmed (12.4)
integer    tr_vy [0:2];
integer    tr_ox [0:2];                  // oriented: E(v0, v1, v2) > 0
integer    tr_oy [0:2];
integer    tr_gx [0:2];                  // triangle being generated
integer    tr_gy [0:2];
reg        tr_deg;
integer    tr_bx0, tr_bx1, tr_by0, tr_by1;
integer    tr_ytop;                      // first row holding a covered pixel (self-checks)
integer    tr_wx0, tr_wy0;               // start of the walk: box start, clipped
reg        tr_rsw;                       // random destination swaps in the TRI EXEC word
reg        tr_aen;                       // SET_ALPHA EN (model of this test only)
integer    tr_a;                         // SET_ALPHA A
integer    tr_ncov;                      // pixels covered inside the clip window (last TRI)
integer    tr_nall;                      // pixels covered, no clip (tr_g_count)
integer    tr_bl, tr_ppw;
reg [31:0] tr_pm;
integer    tr_org;
reg        tr_cnt_en;
reg  [7:0] tr_cnt [0:TR_NPX-1];
integer    tr_mx [0:63];
integer    tr_my [0:63];
integer    tr_fx [0:31];
integer    tr_fy [0:31];
integer    tr_sp [0:3];
integer    tr_sn;
integer    tr_nmid, tr_nheld, tr_nnone, tr_nlate;
integer    tr_i, tr_j, tr_k, tr_m, tr_n, tr_c, tr_mode, tr_t, tr_s;
integer    tr_gn, tr_gs, tr_ky, tr_cx0, tr_cy0, tr_cx1, tr_cy1;
reg  [3:0] tr_op;
reg [31:0] tr_f, tr_r;

initial begin tr_cnt_en = 1'b0; tr_rsw = 1'b0; tr_aen = 1'b0; tr_a = 0; tr_nmid = 0; tr_nheld = 0; tr_nnone = 0; tr_nlate = 0; end


//============================================================================
// Helpers
//============================================================================
function integer tr_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      tr_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function integer tr_fdiv;                // floor(a / b), b > 0
   input integer a;
   input integer b;
   begin
      tr_fdiv = (a >= 0) ? (a / b) : -((b - 1 - a) / b);
   end
endfunction

function integer tr_snap;                // 0 any, 1 multiple of 1/2 px, 2 pixel centre
   input integer v;
   input integer sty;
   begin
      tr_snap = (sty == 1) ? (v & -8) : (sty == 2) ? ((v & -16) | 8) : v;
   end
endfunction

// Edge function E(a, b, q) = (bx-ax)*(qy-ay) - (by-ay)*(qx-ax), 64-bit
function signed [63:0] tr_e;
   input integer ax;
   input integer ay;
   input integer bx;
   input integer by;
   input integer qx;
   input integer qy;
   reg signed [63:0] dx, dy, rx, ry;
   begin
      dx   = bx - ax;
      dy   = by - ay;
      rx   = qx - ax;
      ry   = qy - ay;
      tr_e = dx * ry - dy * rx;
   end
endfunction

// q is on the inner side of the oriented edge a->b, or on a top / left edge:
//   top  : by == ay and bx > ax (horizontal, third vertex below it)
//   left : by <  ay (the edge goes up the screen, the interior is on its right)
function tr_eok;
   input integer ax;
   input integer ay;
   input integer bx;
   input integer by;
   input integer qx;
   input integer qy;
   reg signed [63:0] e;
   begin
      e      = tr_e(ax, ay, bx, by, qx, qy);
      tr_eok = (e > 64'sd0) || ((e == 64'sd0) && ((by < ay) || ((by == ay) && (bx > ax))));
   end
endfunction

function tr_in;                          // pixel (px, py) covered by the prepared triangle
   input integer px;
   input integer py;
   integer       cx, cy;
   begin
      cx    = 16 * px + 8;
      cy    = 16 * py + 8;
      tr_in = !tr_deg &&
              tr_eok(tr_ox[0], tr_oy[0], tr_ox[1], tr_oy[1], cx, cy) &&
              tr_eok(tr_ox[1], tr_oy[1], tr_ox[2], tr_oy[2], cx, cy) &&
              tr_eok(tr_ox[2], tr_oy[2], tr_ox[0], tr_oy[0], cx, cy);
   end
endfunction

// Orientation (swap v1 / v2 when E(v0, v1, v2) < 0), degenerate flag, walk
// box: the pixels whose centre lies within the vertices' x and y ranges
task tr_prep;
   reg signed [63:0] a;
   integer           k, mnx, mxx, mny, mxy;
   begin
      a      = tr_e(tr_vx[0], tr_vy[0], tr_vx[1], tr_vy[1], tr_vx[2], tr_vy[2]);
      tr_deg = (a == 64'sd0);
      tr_ox[0] = tr_vx[0];
      tr_oy[0] = tr_vy[0];
      if (a < 64'sd0) begin
         tr_ox[1] = tr_vx[2]; tr_oy[1] = tr_vy[2];
         tr_ox[2] = tr_vx[1]; tr_oy[2] = tr_vy[1];
      end else begin
         tr_ox[1] = tr_vx[1]; tr_oy[1] = tr_vy[1];
         tr_ox[2] = tr_vx[2]; tr_oy[2] = tr_vy[2];
      end
      mnx = tr_vx[0]; mxx = tr_vx[0];
      mny = tr_vy[0]; mxy = tr_vy[0];
      for (k = 1; k < 3; k = k + 1) begin
         if (tr_vx[k] < mnx) mnx = tr_vx[k];
         if (tr_vx[k] > mxx) mxx = tr_vx[k];
         if (tr_vy[k] < mny) mny = tr_vy[k];
         if (tr_vy[k] > mxy) mxy = tr_vy[k];
      end
      tr_bx0 = tr_fdiv(mnx + 7, 16);             // first centre 16px+8 >= min x
      tr_bx1 = tr_fdiv(mxx - 8, 16);             // last centre <= max x
      tr_by0 = tr_fdiv(mny + 7, 16);
      tr_by1 = tr_fdiv(mxy - 8, 16);
      if (tr_bx0 < -2048) tr_bx0 = -2048;
      if (tr_by0 < -2048) tr_by0 = -2048;
      if (tr_bx1 >  2047) tr_bx1 =  2047;
      if (tr_by1 >  2047) tr_by1 =  2047;
   end
endtask

task tr_find_ytop;                       // first row with a covered pixel (no clip)
   integer px, py, fnd;
   begin
      tr_ytop = 4096;
      fnd     = 0;
      if (!tr_deg)
         for (py = tr_by0; (py <= tr_by1) && (fnd == 0); py = py + 1)
            for (px = tr_bx0; (px <= tr_bx1) && (fnd == 0); px = px + 1)
               if (tr_in(px, py)) begin
                  fnd     = 1;
                  tr_ytop = py;
               end
   end
endtask

task tr_g_load;                          // prepare the generated triangle (dry run)
   integer k;
   begin
      for (k = 0; k < 3; k = k + 1) begin
         tr_vx[k] = tr_gx[k];
         tr_vy[k] = tr_gy[k];
      end
      tr_prep;
   end
endtask

task tr_g_count;                         // tr_nall = pixels covered by tr_g (no clip)
   integer px, py;
   begin
      tr_g_load;
      tr_nall = 0;
      if (!tr_deg)
         for (py = tr_by0; py <= tr_by1; py = py + 1)
            for (px = tr_bx0; px <= tr_bx1; px = px + 1)
               if (tr_in(px, py)) tr_nall = tr_nall + 1;
   end
endtask

task tr_g_ytop;
   begin
      tr_g_load;
      tr_find_ytop;
   end
endtask

function integer tr_pidx;                // index of a surface pixel in tr_cnt
   input integer px;
   input integer py;
   begin
      tr_pidx = (py - TR_Y0) * TR_P + (px - TR_X0);
   end
endfunction

// Surface pixel coordinates of a pixel address (diagnostics)
task tr_pa2xy;
   input  [31:0] pa;
   output integer px;
   output integer py;
   integer        rel;
   begin
      rel = pa - tr_org;
      py  = tr_fdiv(rel - TR_X0, TR_P);
      px  = rel - py * TR_P;
   end
endtask


//============================================================================
// Model of one covered pixel and of a whole TRI
//============================================================================
task tr_px;
   input integer px;
   input integer py;
   input   [3:0] op;
   input         gen;
   reg    [31:0] pa, ss, dd, rr;
   integer       gn, gv;
   reg           thit;
   begin
      tr_ncov = tr_ncov + 1;
      if ((px < TR_X0) || (px > TR_XM) || (py < TR_Y0) || (py > TR_YM)) begin
         $display("ERROR: TRI model -- drawn pixel (%0d, %0d) outside the test surface (test bug) %t", px, py, $time);
         error = error + 1;
      end else begin
         if (tr_cnt_en) tr_cnt[tr_pidx(px, py)] = tr_cnt[tr_pidx(px, py)] + 8'd1;
         pa = (gpu_m_dst_base + py * gpu_m_xyp + px) & GPU_PA_MASK;
         if (gen) begin
            gn = (gpu_m_gn == 0) ? 1 : gpu_m_gn;
            gv = ((gpu_m_gaxis ? (px - tr_wx0) : (py - tr_wy0)) / gn) * gpu_m_gstep;
            ss = (gpu_m_fill + gv) & tr_pm;
         end else
            ss = gpu_m_fill & tr_pm;
         thit = (op >= 4'd13) && (ss == (gpu_m_transp & tr_pm));
         gpu_touch_px(pa, tr_bl);
         if (!thit) begin
            dd = gpu_get_px(pa, tr_bl);
            case (op)
              4'd0:  rr = ss;
              4'd1:  rr = ~ss;
              4'd2:  rr = ~dd;
              4'd3:  rr = ss & dd;
              4'd4:  rr = ss | dd;
              4'd5:  rr = ss ^ dd;
              4'd6:  rr = ~(ss & dd);
              4'd7:  rr = ~(ss | dd);
              4'd8:  rr = ~(ss ^ dd);
              4'd9:  rr = ~ss & dd;
              4'd10: rr = ss & ~dd;
              4'd11: rr = ~ss | dd;
              4'd12: rr = ss | ~dd;
              4'd13: rr = 32'h0;
              4'd14: rr = 32'hFFFF_FFFF;
              default: rr = ss;                       // the fill colour (gradient applied)
            endcase
            if (tr_aen && (tr_bl == 4))                // blending: S (ops 0..12) or the constant (13..15)
               rr = tr_blend((op >= 4'd13) ? rr[15:0] : ss[15:0], dd[15:0], (tr_a == 255) ? 256 : tr_a);
            gpu_set_px(pa, tr_bl, rr & tr_pm);
         end
      end
   end
endtask

// RGB565 blend: the shared model's gpu_blend565 (from the spec formula)
function [31:0] tr_blend;
   input [15:0]  sv;
   input [15:0]  dv;
   input integer al;
   begin
      tr_blend = {16'h0, gpu_blend565(sv, dv, al)};
   end
endfunction

task tr_c_alpha;                         // SET_ALPHA (SET_EXT sub 8)
   input integer a;
   input         en;
   reg     [7:0] af;
   begin
      af = a;
      gpu_c_alpha(en, af);               // (the shared model's state too)
      tr_aen = en;
      tr_a   = af;
   end
endtask

// TRI with the current model state (x/y mode only; clip window; gradient:
// i = py - first walk row (AXIS 0) or px - first walk column (AXIS 1), the
// walk being the box intersected with the clip window)
task tr_model;
   input [3:0] op;
   integer     px, py, xa, xb, ya, yb;
   begin
      tr_bl   = gpu_bl(gpu_m_mode);
      tr_ppw  = 32 >> tr_bl;
      tr_pm   = gpu_pmask(tr_bl);
      tr_prep;
      tr_ncov = 0;
      xa = (tr_bx0 > gpu_m_cx0) ? tr_bx0 : gpu_m_cx0;
      xb = (tr_bx1 < gpu_m_cx1) ? tr_bx1 : gpu_m_cx1;
      ya = (tr_by0 > gpu_m_cy0) ? tr_by0 : gpu_m_cy0;
      yb = (tr_by1 < gpu_m_cy1) ? tr_by1 : gpu_m_cy1;
      tr_wx0 = xa;
      tr_wy0 = ya;
      if (gpu_m_xy && !tr_deg) begin
         if (((xb - xa + 1) > TR_DIMMAX) || ((yb - ya + 1) > TR_DIMMAX)) begin
            $display("ERROR: TRI model -- clipped walk %0d x %0d beyond 2^DIM_W - 1 (test bug) %t",
                     xb - xa + 1, yb - ya + 1, $time);
            error = error + 1;
         end
         for (py = ya; py <= yb; py = py + 1)
            for (px = xa; px <= xb; px = px + 1)
               if (tr_in(px, py)) tr_px(px, py, op, gpu_m_gen);
      end
   end
endtask


//============================================================================
// Commands
//============================================================================
task tr_c_vtx;                           // SET_Vk, random command bits [23:0]
   input integer k;
   input integer x;
   input integer y;
   reg    [15:0] xf, yf;
   reg    [31:0] junk;
   reg     [3:0] sub;
   begin
      if ((x < -32768) || (x > 32767) || (y < -32768) || (y > 32767)) begin
         $display("ERROR: TRI model -- vertex (%0d, %0d) beyond 12.4 (test bug) %t", x, y, $time);
         error = error + 1;
      end
      xf   = x;
      yf   = y;
      junk = $random(gpu_seed);
      sub  = TR_EXT_V0 + k;
      gpu_push({OP_SET_EXT, sub, junk[23:0]});
      gpu_push({yf, xf});
      tr_vx[k] = gpu_sx16(xf);
      tr_vy[k] = gpu_sx16(yf);
   end
endtask

task tr_c_exec;                          // EXEC_FILL with TRI (destination swaps ignored)
   input [3:0] op;
   reg   [2:0] sw;
   begin
      sw = tr_rsw ? $random(gpu_seed) : 3'b000;
      gpu_push({OP_EXEC_FILL, 20'h00000, 1'b1, sw, op});
      tr_model(op);
   end
endtask

task tr_set_g;
   input integer x0;
   input integer y0;
   input integer x1;
   input integer y1;
   input integer x2;
   input integer y2;
   begin
      tr_gx[0] = x0; tr_gy[0] = y0;
      tr_gx[1] = x1; tr_gy[1] = y1;
      tr_gx[2] = x2; tr_gy[2] = y2;
   end
endtask

// Draw tr_g in vertex order perm (0-2 rotations, 3-5 reversed winding); the
// SET_V words are pushed in a random rotation of V0, V1, V2.
task tr_draw_g;
   input integer perm;
   input   [3:0] op;
   integer       o0, o1, o2, po;
   begin
      case (perm)
        0:       begin o0 = 0; o1 = 1; o2 = 2; end
        1:       begin o0 = 1; o1 = 2; o2 = 0; end
        2:       begin o0 = 2; o1 = 0; o2 = 1; end
        3:       begin o0 = 0; o1 = 2; o2 = 1; end
        4:       begin o0 = 2; o1 = 1; o2 = 0; end
        default: begin o0 = 1; o1 = 0; o2 = 2; end
      endcase
      po = tr_rnd(3);
      if (po == 0) begin
         tr_c_vtx(0, tr_gx[o0], tr_gy[o0]);
         tr_c_vtx(1, tr_gx[o1], tr_gy[o1]);
         tr_c_vtx(2, tr_gx[o2], tr_gy[o2]);
      end else if (po == 1) begin
         tr_c_vtx(1, tr_gx[o1], tr_gy[o1]);
         tr_c_vtx(2, tr_gx[o2], tr_gy[o2]);
         tr_c_vtx(0, tr_gx[o0], tr_gy[o0]);
      end else begin
         tr_c_vtx(2, tr_gx[o2], tr_gy[o2]);
         tr_c_vtx(0, tr_gx[o0], tr_gy[o0]);
         tr_c_vtx(1, tr_gx[o1], tr_gy[o1]);
      end
      tr_c_exec(op);
   end
endtask

// Random triangle: vertices in pixels [xlo, xhi] x [ylo, yhi], box sx x sy
// (smin..smax px), all sub-pixel, on half pixels or on pixel centres
task tr_gen;
   input integer xlo;
   input integer xhi;
   input integer ylo;
   input integer yhi;
   input integer smin;
   input integer smax;
   integer       sx, sy, bx, by, k, sty;
   begin
      sx  = smin + tr_rnd(smax - smin + 1);
      sy  = smin + tr_rnd(smax - smin + 1);
      bx  = xlo + tr_rnd(xhi - xlo - sx + 1);
      by  = ylo + tr_rnd(yhi - ylo - sy + 1);
      sty = tr_rnd(3);
      for (k = 0; k < 3; k = k + 1) begin
         tr_gx[k] = tr_snap(16 * bx + tr_rnd(16 * sx + 1), sty);
         tr_gy[k] = tr_snap(16 * by + tr_rnd(16 * sy + 1), sty);
      end
   end
endtask

// Large triangle: three corners of an s x s box (the fourth one left out at
// random), each moved inwards by up to s/8 px, sub-pixel positions
task tr_gen_corner;
   input integer xlo;
   input integer xhi;
   input integer ylo;
   input integer yhi;
   input integer smin;
   input integer smax;
   integer       sz, lx, rx, ty, by, om, k, n, j;
   begin
      sz = smin + tr_rnd(smax - smin + 1);
      lx = 16 * (xlo + tr_rnd(xhi - xlo - sz + 1));
      ty = 16 * (ylo + tr_rnd(yhi - ylo - sz + 1));
      rx = lx + 16 * sz;
      by = ty + 16 * sz;
      j  = 2 * sz;
      om = tr_rnd(4);
      n  = 0;
      for (k = 0; k < 4; k = k + 1)
         if (k != om) begin
            tr_gx[n] = ((k == 0) || (k == 3)) ? (lx + tr_rnd(j + 1)) : (rx - tr_rnd(j + 1));
            tr_gy[n] = ((k == 0) || (k == 1)) ? (ty + tr_rnd(j + 1)) : (by - tr_rnd(j + 1));
            n = n + 1;
         end
   end
endtask

task tr_gen_big;                         // constructed large triangle of at least nmin pixels
   input integer xlo;
   input integer xhi;
   input integer ylo;
   input integer yhi;
   input integer smin;
   input integer smax;
   input integer nmin;
   integer       tries;
   begin
      tries   = 0;
      tr_nall = 0;
      while ((tr_nall < nmin) && (tries < 200)) begin
         tr_gen_corner(xlo, xhi, ylo, yhi, smin, smax);
         tr_g_count;
         tries = tries + 1;
      end
      if (tr_nall < nmin) tb_error("no large enough random triangle found (test bug)");
   end
endtask

task tr_show;
   input [8*28-1:0] label;
   begin
      $display("       %0s: mode %0d V (%0d,%0d) (%0d,%0d) (%0d,%0d) /16, %0d px drawn",
               label, gpu_m_mode, tr_vx[0], tr_vy[0], tr_vx[1], tr_vy[1], tr_vx[2], tr_vy[2], tr_ncov);
   end
endtask


//============================================================================
// Surface, background, waits, checks
//============================================================================
task tr_wait_idle;
   begin
      reg_poll(GPU_STAT, GS_BUSY, 32'h0, 1000000);
   end
endtask

task tr_clear;                           // idle, GPU flags cleared
   begin
      tr_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

// x/y surface at GFX_MODE mode, origin at a random sub-word position, no clip
task tr_surf;
   input integer mode;
   begin
      tr_wait_idle;
      gpu_set_mode(mode);
      tr_bl  = gpu_bl(mode);
      tr_ppw = 32 >> tr_bl;
      tr_pm  = gpu_pmask(tr_bl);
      tr_org = TR_D_LO * tr_ppw + tr_rnd(tr_ppw) - TR_Y0 * TR_P - TR_X0;
      gpu_c_dst_xy(TR_P, tr_org);
      gpu_c_noclip;
   end
endtask

task tr_bg_rand;
   begin
      tr_wait_idle;
      gpu_preload_rand(TR_D_LO, TR_D_HI);
   end
endtask

task tr_bg_zero;
   integer ww;
   begin
      tr_wait_idle;
      for (ww = TR_D_LO; ww < TR_D_HI; ww = ww + 1) begin
         vram_mem[ww]   = 32'h0;
         gpu_shadow[ww] = 32'h0;
      end
   end
endtask

task tr_untouch;
   integer ww;
   begin
      for (ww = 0; ww < VRAM_WORDS; ww = ww + 1)
         gpu_touch[ww] = 1'b0;
   end
endtask

task tr_cnt_clear;
   integer ii;
   begin
      for (ii = 0; ii < TR_NPX; ii = ii + 1)
         tr_cnt[ii] = 8'd0;
   end
endtask

// GPU idle; exactly one GPU_DONE (and no ERR / OVFL) since the last clear
task tr_done1;
   input [8*28-1:0] label;
   reg   [31:0]     f;
   begin
      tr_wait_idle;
      reg_rd_val(IRQ_FLAG, f);
      if ((f & (IF_DONE | IF_ERR | IF_OVFL)) !== IF_DONE) begin
         $display("ERROR: %0s -- IRQ_FLAG = 0x%h, expected GPU_DONE without GPU_ERR / GPU_OVFL %t", label, f, $time);
         error = error + 1;
      end
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      repeat(20) @(posedge free_clk);
      reg_rd_val(IRQ_FLAG, f);
      if (f & IF_DONE) begin
         $display("ERROR: %0s -- a second GPU_DONE after the triangle %t", label, $time);
         error = error + 1;
      end
   end
endtask

task tr_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

// Backdoor compare of the destination region with the model (GPU idle)
task tr_cmp;
   input [8*40-1:0] label;
   integer          ww, kk, nbad, shown, px, py;
   reg       [31:0] va, vb;
   begin
      nbad  = 0;
      shown = 0;
      for (ww = TR_D_LO; ww < TR_D_HI; ww = ww + 1)
         if (vram_mem[ww] !== gpu_shadow[ww]) begin
            nbad = nbad + 1;
            for (kk = 0; kk < tr_ppw; kk = kk + 1) begin
               va = (vram_mem[ww]   >> (kk << tr_bl)) & tr_pm;
               vb = (gpu_shadow[ww] >> (kk << tr_bl)) & tr_pm;
               if ((va !== vb) && (shown < 6)) begin
                  tr_pa2xy(ww * tr_ppw + kk, px, py);
                  $display("ERROR: GPU %0s -- pixel (%0d, %0d) = 0x%h / expected 0x%h (covered by the last TRI: %0d) %t",
                           label, px, py, va, vb, tr_in(px, py), $time);
                  shown = shown + 1;
               end
            end
         end
      if (nbad == 0)
         $display("OK:    GPU %0s", label);
      else begin
         $display("ERROR: GPU %0s -- %0d words differ from the model", label, nbad);
         error = error + 1;
         for (ww = TR_D_LO; ww < TR_D_HI; ww = ww + 1)       // no cascade into the next checks
            gpu_shadow[ww] = vram_mem[ww];
      end
   end
endtask

task tr_self_n;                          // model self-check: pixel count of tr_g
   input integer n;
   begin
      tr_g_count;
      if (tr_nall != n) begin
         $display("ERROR: TRI model -- %0d pixels covered, %0d counted by hand (test bug) %t", tr_nall, n, $time);
         error = error + 1;
      end
   end
endtask

// Mesh check: the model counts and the VRAM image (XOR of all-ones onto 0)
// must both be exactly the pixels whose centre is in [x0, x1) x [y0, y1)
task tr_box_check;
   input [8*24-1:0] label;
   input integer    x0;
   input integer    y0;
   input integer    x1;
   input integer    y1;
   integer          px, py, ex, nm, nh, nin;
   reg       [31:0] v, pa;
   begin
      nm  = 0;
      nh  = 0;
      nin = 0;
      for (py = TR_Y0; py <= TR_YM; py = py + 1)
         for (px = TR_X0; px <= TR_XM; px = px + 1) begin
            ex  = ((16 * px + 8) >= x0) && ((16 * px + 8) < x1) && ((16 * py + 8) >= y0) && ((16 * py + 8) < y1);
            nin = nin + ex;
            if (tr_cnt[tr_pidx(px, py)] != ex) begin
               nm = nm + 1;
               if (nm <= 4)
                  $display("ERROR: TRI model -- %0s pixel (%0d, %0d) covered %0d times, expected %0d (test bug) %t",
                           label, px, py, tr_cnt[tr_pidx(px, py)], ex, $time);
            end
            pa = (tr_org + py * TR_P + px) & GPU_PA_MASK;
            v  = gpu_vram_px(pa, tr_bl);
            if (v !== (ex ? tr_pm : 32'h0)) begin
               nh = nh + 1;
               if (nh <= 6)
                  $display("ERROR: GPU %0s -- pixel (%0d, %0d) = 0x%h: %0s %t", label, px, py, v,
                           ex ? "missing (gap) or drawn twice (hole)" : "drawn outside the mesh", $time);
            end
         end
      error = error + nm + nh;
      if ((nm == 0) && (nh == 0))
         $display("OK:    GPU %0s -- %0d pixels, each drawn exactly once, no gap", label, nin);
   end
endtask

task tr_list_write;                      // captured words at word address a
   input integer a;
   input integer how;                    // 0 backdoor, 1 VRAM window
   integer       kk;
   begin
      if (a + gpu_cap_n > TR_D_LO) tb_error("command list overlaps the surface (test bug)");
      for (kk = 0; kk < gpu_cap_n; kk = kk + 1) begin
         if (how == 0) vram_mem[a + kk] = gpu_cap_buf[kk];
         else          vram_wr(4 * (a + kk), gpu_cap_buf[kk], SZ_W);
         gpu_shadow[a + kk] = gpu_cap_buf[kk];
      end
   end
endtask

task tr_poll_done;                       // count GPU_DONE events (W1C) until idle
   output integer cnt;
   reg   [31:0]   f, s;
   integer        guard;
   begin
      cnt   = 0;
      guard = 0;
      s     = GS_BUSY;
      while ((s & GS_BUSY) && (guard < 200000)) begin
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
      if (guard >= 200000) tb_error("GPU never became idle while counting GPU_DONE");
   end
endtask


//============================================================================
// Meshes (XOR with an all-ones fill onto a zero surface)
//============================================================================
task tr_grid;
   input integer mode;
   input integer nx;
   input integer ny;
   input integer ctr;                    // 1: every vertex on a pixel centre
   integer       cw, ch, x0, y0, i, j, k, a, b, c, d, pmax, dx, dy;
   begin
      tr_surf(mode);
      tr_bg_zero;
      tr_clear;
      gpu_c_fill(32'hFFFF_FFFF);
      if (ctr) begin
         cw = 16 * (6 + tr_rnd(7));
         ch = 16 * (6 + tr_rnd(7));
         x0 = 16 * (-44 + tr_rnd(8)) + 8;
         y0 = 16 * (-44 + tr_rnd(8)) + 8;
      end else begin
         cw = 96 + tr_rnd(129);
         ch = 96 + tr_rnd(129);
         x0 = -44 * 16 + tr_rnd(128);
         y0 = -44 * 16 + tr_rnd(128);
      end
      pmax = ((cw < ch) ? cw : ch) / 6;
      for (j = 0; j <= ny; j = j + 1)
         for (i = 0; i <= nx; i = i + 1) begin
            k  = j * (nx + 1) + i;
            dx = ((i > 0) && (i < nx)) ? (tr_rnd(2 * pmax + 1) - pmax) : 0;
            dy = ((j > 0) && (j < ny)) ? (tr_rnd(2 * pmax + 1) - pmax) : 0;
            if (ctr) begin
               dx = (dx / 16) * 16;
               dy = (dy / 16) * 16;
            end
            tr_mx[k] = x0 + i * cw + dx;
            tr_my[k] = y0 + j * ch + dy;
         end
      tr_cnt_clear;
      tr_cnt_en = 1'b1;
      for (j = 0; j < ny; j = j + 1)
         for (i = 0; i < nx; i = i + 1) begin
            a = j * (nx + 1) + i;
            b = a + 1;
            c = a + nx + 2;
            d = a + nx + 1;
            if (tr_rnd(2)) begin
               tr_set_g(tr_mx[a], tr_my[a], tr_mx[b], tr_my[b], tr_mx[c], tr_my[c]);
               tr_draw_g(tr_rnd(6), 4'd5);
               tr_set_g(tr_mx[a], tr_my[a], tr_mx[c], tr_my[c], tr_mx[d], tr_my[d]);
               tr_draw_g(tr_rnd(6), 4'd5);
            end else begin
               tr_set_g(tr_mx[a], tr_my[a], tr_mx[b], tr_my[b], tr_mx[d], tr_my[d]);
               tr_draw_g(tr_rnd(6), 4'd5);
               tr_set_g(tr_mx[b], tr_my[b], tr_mx[c], tr_my[c], tr_mx[d], tr_my[d]);
               tr_draw_g(tr_rnd(6), 4'd5);
            end
         end
      tr_cnt_en = 1'b0;
      tr_wait_idle;
      tr_no_err;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      $display("       grid %0d x %0d cells of %0d x %0d /16 from (%0d, %0d), mode %0d%0s",
               nx, ny, cw, ch, x0, y0, mode, ctr ? ", vertices on pixel centres" : "");
      tr_cmp("TRI grid mesh vs model");
      tr_box_check("TRI grid mesh", x0, y0, x0 + nx * cw, y0 + ny * ch);
   end
endtask

// Sorted distinct points strictly inside (lo, hi) on one side of the fan box
task tr_side;
   input integer lo;
   input integer hi;
   input integer ctr;
   integer       m, k, v, j, t, dup;
   begin
      tr_sn = 0;
      m     = tr_rnd(4);
      for (k = 0; k < m; k = k + 1) begin
         v   = lo + 1 + tr_rnd(hi - lo - 1);
         if (ctr) v = (v & -16) | 8;
         dup = (v <= lo) || (v >= hi);
         for (j = 0; j < tr_sn; j = j + 1)
            if (tr_sp[j] == v) dup = 1;
         if (!dup) begin
            tr_sp[tr_sn] = v;
            j = tr_sn;
            while ((j > 0) && (tr_sp[j - 1] > tr_sp[j])) begin
               t            = tr_sp[j];
               tr_sp[j]     = tr_sp[j - 1];
               tr_sp[j - 1] = t;
               j            = j - 1;
            end
            tr_sn = tr_sn + 1;
         end
      end
   end
endtask

// Closed fan around C covering the box [x0, x1] x [y0, y1]: the boundary
// points (4 corners + random side points) in order around the box.
//   vrt 0: C inside, 1: C inside on a pixel centre, 2: C on the top side
//   (degenerate triangles), 3: C at the top-left corner.
task tr_fan;
   input integer mode;
   input integer vrt;
   input integer ctr;
   integer       x0, y0, x1, y1, cx, cy, n, i, k;
   begin
      tr_surf(mode);
      tr_bg_zero;
      tr_clear;
      gpu_c_fill(32'hFFFF_FFFF);
      x0 = 16 * (-44 + tr_rnd(40)) + (ctr ? 8 : tr_rnd(16));
      y0 = 16 * (-44 + tr_rnd(40)) + (ctr ? 8 : tr_rnd(16));
      x1 = x0 + 16 * (30 + tr_rnd(31)) + (ctr ? 0 : tr_rnd(16));
      y1 = y0 + 16 * (30 + tr_rnd(31)) + (ctr ? 0 : tr_rnd(16));
      n  = 0;
      tr_fx[n] = x0; tr_fy[n] = y0; n = n + 1;
      tr_side(x0, x1, ctr);
      for (k = 0; k < tr_sn; k = k + 1) begin tr_fx[n] = tr_sp[k]; tr_fy[n] = y0; n = n + 1; end
      tr_fx[n] = x1; tr_fy[n] = y0; n = n + 1;
      tr_side(y0, y1, ctr);
      for (k = 0; k < tr_sn; k = k + 1) begin tr_fx[n] = x1; tr_fy[n] = tr_sp[k]; n = n + 1; end
      tr_fx[n] = x1; tr_fy[n] = y1; n = n + 1;
      tr_side(x0, x1, ctr);
      for (k = tr_sn - 1; k >= 0; k = k - 1) begin tr_fx[n] = tr_sp[k]; tr_fy[n] = y1; n = n + 1; end
      tr_fx[n] = x0; tr_fy[n] = y1; n = n + 1;
      tr_side(y0, y1, ctr);
      for (k = tr_sn - 1; k >= 0; k = k - 1) begin tr_fx[n] = x0; tr_fy[n] = tr_sp[k]; n = n + 1; end
      case (vrt)
        0: begin
           cx = x0 + 1 + tr_rnd(x1 - x0 - 1);
           cy = y0 + 1 + tr_rnd(y1 - y0 - 1);
        end
        1: begin
           cx = 16 * (tr_fdiv(x0, 16) + 1 + tr_rnd(tr_fdiv(x1, 16) - tr_fdiv(x0, 16) - 1)) + 8;
           cy = 16 * (tr_fdiv(y0, 16) + 1 + tr_rnd(tr_fdiv(y1, 16) - tr_fdiv(y0, 16) - 1)) + 8;
        end
        2: begin
           cx = x0 + 1 + tr_rnd(x1 - x0 - 1);
           cy = y0;
        end
        default: begin
           cx = x0;
           cy = y0;
        end
      endcase
      if ((cx < x0) || (cx > x1) || (cy < y0) || (cy > y1)) tb_error("fan centre outside its box (test bug)");
      tr_cnt_clear;
      tr_cnt_en = 1'b1;
      for (i = 0; i < n; i = i + 1) begin
         tr_set_g(cx, cy, tr_fx[i], tr_fy[i], tr_fx[(i + 1) % n], tr_fy[(i + 1) % n]);
         tr_draw_g(tr_rnd(6), 4'd5);
      end
      tr_cnt_en = 1'b0;
      tr_wait_idle;
      tr_no_err;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      $display("       fan of %0d triangles around (%0d, %0d) /16, box (%0d, %0d)-(%0d, %0d), mode %0d, variant %0d%0s",
               n, cx, cy, x0, y0, x1, y1, mode, vrt, ctr ? ", pixel centres" : "");
      tr_cmp("TRI fan vs model");
      tr_box_check("TRI fan", x0, y0, x1, y1);
   end
endtask


//============================================================================
// ABORT / GPU_EN = 0 mid-triangle
//============================================================================
// After the abandon: every pixel the triangle does not cover is unchanged,
// every covered pixel is old or new (XOR all-ones: new = ~old). The shadow
// then takes the abandoned image.
task tr_abort_classify;
   input          done;
   output integer nnew;
   output integer nold;
   integer        ww, kk, nbad, px, py;
   reg     [31:0] o, n, v;
   begin
      nnew = 0;
      nold = 0;
      nbad = 0;
      for (ww = TR_D_LO; ww < TR_D_HI; ww = ww + 1) begin
         for (kk = 0; kk < tr_ppw; kk = kk + 1) begin
            o = (gpu_save[ww]   >> (kk << tr_bl)) & tr_pm;
            n = (gpu_shadow[ww] >> (kk << tr_bl)) & tr_pm;
            v = (vram_mem[ww]   >> (kk << tr_bl)) & tr_pm;
            if (o == n) begin
               if (v !== o) begin
                  nbad = nbad + 1;
                  if (nbad <= 4) begin
                     tr_pa2xy(ww * tr_ppw + kk, px, py);
                     $display("ERROR: abandoned TRI -- pixel (%0d, %0d) outside the triangle = 0x%h, expected unchanged 0x%h %t",
                              px, py, v, o, $time);
                  end
               end
            end else if (v === n)
               nnew = nnew + 1;
            else if (v === o)
               nold = nold + 1;
            else begin
               nbad = nbad + 1;
               if (nbad <= 4) begin
                  tr_pa2xy(ww * tr_ppw + kk, px, py);
                  $display("ERROR: abandoned TRI -- pixel (%0d, %0d) = 0x%h, neither old 0x%h nor new 0x%h %t",
                           px, py, v, o, n, $time);
               end
            end
         end
         gpu_shadow[ww] = vram_mem[ww];
      end
      error = error + nbad;
      if (done && (nold > 0)) begin
         $display("ERROR: GPU_DONE raised for an abandoned triangle (%0d of %0d pixels drawn) %t", nnew, nnew + nold, $time);
         error = error + 1;
      end
   end
endtask

task tr_abort_case;
   input integer how;                    // 0 GPU_CTRL.ABORT, 1 CTRL.GPU_EN = 0
   integer    mode, t0, wt, nnew, nold;
   reg [31:0] flag;
   begin
      mode = 1 + tr_rnd(4);
      tr_surf(mode);
      tr_bg_rand;
      gpu_c_xy(TR_XM - 4, TR_YM - 4);                              // queued rectangle: outside the triangle
      gpu_c_size(14'd3, 14'd3);
      gpu_c_fill(32'hFFFF_FFFF);
      tr_gen_big(TR_X0, 100, TR_Y0, 100, TR_SMALL ? TR_SMIN : 40, TR_SMAX, TR_NBIG);
      tr_clear;
      gpu_snapshot;
      tr_draw_g(tr_rnd(6), 4'd5);
      t0 = gpu_cyc;
      gpu_push({OP_FENCE, 28'h100_0001});                           // must be flushed
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));    // must be flushed
      wt = 30 + tr_rnd(40 + tr_by1 - tr_by0);                        // set-up ~57 cycles, then >= 2 per row
      while (gpu_cyc < t0 + wt) @(posedge free_clk);
      if (how == 0)
         reg_wr(GPU_CTRL, 32'h2);
      else
         reg_wr(CTRL, mode);                                       // GPU_EN = 0
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH,
                  GS_EMPTY | GS_FULL | GS_PRIM_BUSY | GS_BUSY | GS_ERR | GS_HELD | TR_GS_LIST | 32'hFFFF);
      reg_rd_val(IRQ_FLAG, flag);
      if (!(flag & IF_IDLE) || (flag & (IF_ERR | IF_OVFL))) begin
         $display("ERROR: IRQ_FLAG = 0x%h after the abandoned TRI (GPU_IDLE expected, no GPU_ERR / GPU_OVFL) %t", flag, $time);
         error = error + 1;
      end
      tr_abort_classify(flag[4], nnew, nold);
      if ((nnew > 0) && (nold > 0)) begin
         tr_nmid = tr_nmid + 1;
         $display("OK:    TRI %0s mode %0d after %0d cycles: %0d of %0d pixels drawn, nothing else, no GPU_DONE",
                  (how == 0) ? "ABORT" : "GPU_EN=0", mode, wt, nnew, nnew + nold);
      end else if (nold == 0) begin
         tr_nlate = tr_nlate + 1;
         $display("INFO:  TRI %0s mode %0d after %0d cycles: the whole triangle was drawn (GPU_DONE %0d)",
                  (how == 0) ? "ABORT" : "GPU_EN=0", mode, wt, flag[4]);
      end else begin
         tr_nnone = tr_nnone + 1;
         $display("INFO:  TRI %0s mode %0d after %0d cycles: nothing drawn",
                  (how == 0) ? "ABORT" : "GPU_EN=0", mode, wt);
      end
      if (how == 1) gpu_set_mode(mode);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // the GPU takes new commands: a new triangle drawn exactly
      gpu_c_dst_xy(TR_P, tr_org);
      gpu_c_fill($random(gpu_seed));
      tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
      tr_draw_g(tr_rnd(6), 4'd2);
      tr_done1("TRI after the abandon");
      tr_cmp("TRI after the abandon");
   end
endtask


//============================================================================
// Debug freeze toggled mid-triangle
//============================================================================
task tr_freeze_case;
   input integer k;
   integer    mode, tg, tw;
   reg [31:0] st;
   reg        dbgc;
   begin
      mode = tr_rnd(5);
      tr_surf(mode);
      tr_bg_rand;
      gpu_c_fill((k & 2) ? 32'hFFFF_FFFF : $random(gpu_seed));
      if (TR_SMALL) tr_gen_big(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX, TR_NBIG);
      else          tr_gen_big(TR_X0, TR_XM, TR_Y0, TR_YM, 50, 60, 700);
      tr_clear;
      tr_draw_g(tr_rnd(6), (k & 2) ? 4'd5 : 4'd2);                // pushed before any freeze
      dbgc = 1'b0;
      if (k & 1) begin
         reg_wr(DBG_CTRL, 32'h2);
         dbgc = 1'b1;
      end
      for (tg = 0; tg < 20; tg = tg + 1) begin
         repeat(1 + tr_rnd(10)) @(negedge free_clk);
         if (k & 1)
            dbg_stoptime = ~dbg_stoptime;
         else begin
            dbg_stoptime = 1'b1;
            dbgc         = ~dbgc;
            reg_wr(DBG_CTRL, dbgc ? 32'h2 : 32'h0);
         end
         if (dbg_stoptime && dbgc) begin
            st = 32'h0;
            tw = gpu_cyc;
            while (!(st & GS_HELD) && (gpu_cyc - tw < 100)) reg_rd_val(GPU_STAT, st);
            if (!(st & GS_HELD)) begin
               $display("ERROR: GPU HELD not set 100 cycles after the freeze (TRI) %t", $time);
               error = error + 1;
            end else begin
               if (st & GS_PRIM_BUSY) begin
                  reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);           // held mid-triangle: no GPU_DONE yet
                  tr_nheld = tr_nheld + 1;
               end
               gpu_mon_noacc = 1'b1;                               // no VRAM access while held
               repeat(20) @(posedge free_clk);
               gpu_mon_noacc = 1'b0;
            end
         end
      end
      @(negedge free_clk) dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      tr_done1("TRI under freeze");
      tr_show("TRI under freeze");
      tr_cmp("TRI with freeze toggled");
   end
endtask


//============================================================================
// Test
//============================================================================
initial
   begin
      $display(" ===============================================");
      $display("|        GPU: flat triangle fill (TRI)          |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0) || (GPU_GRAD_EN == 0))
         tb_skip_finish("|      (triangles, x/y or gradient absent)      |");
      if (VRAM_WORDS < TR_VMIN)
         tb_skip_finish("|      (VRAM too small for the TRI surface)     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(64);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("--- 1. directed triangles (8 bpp, op 2 = not D)");
      tr_surf(3);
      tr_bg_rand;
      tr_clear;
      tr_set_g(0, 0, 160, 0, 0, 160);                    // hypotenuse x+y = 10 excluded: 45
      tr_self_n(45);
      tr_draw_g(0, 4'd2);
      tr_done1("TRI 1a");
      tr_cmp("TRI (0,0)(10,0)(0,10): 45 px");
      tr_set_g(1600, 0, 1760, 0, 1760, 160);             // diagonal = left edge, included: 55
      tr_self_n(55);
      tr_draw_g(3, 4'd2);
      tr_done1("TRI 1b");
      tr_cmp("TRI (100,0)(110,0)(110,10): 55 px");
      tr_set_g(8, 328, 72, 328, 8, 392);                 // vertices on pixel centres: 10
      tr_self_n(10);
      tr_draw_g(1, 4'd2);
      tr_done1("TRI 1c");
      tr_cmp("TRI on pixel centres (top + left): 10 px");
      tr_set_g(1608, 328, 1672, 328, 1672, 392);         // 10
      tr_self_n(10);
      tr_draw_g(5, 4'd2);
      tr_done1("TRI 1d");
      tr_cmp("TRI on pixel centres (top + diag): 10 px");
      tr_set_g(808, 648, 872, 712, 744, 712);            // apex on a centre, flat bottom: 12
      tr_self_n(12);
      tr_draw_g(2, 4'd2);
      tr_done1("TRI 1e");
      tr_cmp("TRI apex on a centre, flat bottom: 12 px");
      tr_set_g(1282, 1282, 1296, 1284, 1284, 1296);      // around the centre of pixel (80, 80): 1
      tr_self_n(1);
      tr_draw_g(4, 4'd2);
      tr_done1("TRI 1f");
      tr_cmp("TRI around one pixel centre: 1 px");
      tr_set_g(1290, 1290, 1300, 1290, 1290, 1300);      // between centres: 0
      tr_self_n(0);
      tr_draw_g(0, 4'd2);
      tr_done1("TRI 1g");
      tr_cmp("TRI between pixel centres: 0 px");
      if (!TR_SMALL) begin
         tr_set_g(-32, -32, -400, -24, -100, -500);      // negative coordinates
         tr_draw_g(1, 4'd2);
         tr_done1("TRI 1h");
         tr_show("negative coordinates");
         tr_cmp("TRI with negative coordinates");
      end
      tr_no_err;
      gpu_check_touched("TRI directed (VRAM window)");

      //--------------------------------------------------------------
      $display("--- 2. random triangles in all six vertex orders, 1/2/4/8/16 bpp, random EXEC swaps");
      tr_rsw = 1'b1;
      for (tr_mode = 0; tr_mode < 5; tr_mode = tr_mode + 1) begin
         tr_surf(tr_mode);
         tr_bg_rand;
         tr_clear;
         for (tr_i = 0; tr_i < 4; tr_i = tr_i + 1) begin
            tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, 0, TR_SMAX);
            for (tr_k = 0; tr_k < 6; tr_k = tr_k + 1) begin
               if (tr_k % 2) begin
                  gpu_c_fill(32'hFFFF_FFFF);
                  tr_draw_g(tr_k, 4'd5);
               end else
                  tr_draw_g(tr_k, 4'd2);
               tr_done1("random TRI");
               if (tr_k == 0) tr_show("random TRI");
               tr_cmp("random TRI, one vertex order");
            end
         end
         tr_untouch;
      end

      //--------------------------------------------------------------
      $display("--- 3. 16 raster ops x transparency at GFX_MODE 0..7");
      for (tr_mode = 0; tr_mode < 8; tr_mode = tr_mode + 1) begin
         tr_surf(tr_mode);
         tr_bg_rand;
         tr_clear;
         for (tr_c = 0; tr_c < 16; tr_c = tr_c + 1) begin
            tr_op = tr_c;
            for (tr_t = 0; tr_t < 2; tr_t = tr_t + 1) begin
               tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, 4, (TR_SMAX < 24) ? TR_SMAX : 24);
               tr_f = $random(gpu_seed);
               gpu_c_fill(tr_f);
               gpu_c_transp(tr_t ? tr_f : ~tr_f);
               tr_draw_g(tr_rnd(6), tr_op);
            end
            tr_wait_idle;
            tr_cmp("TRI raster op (transparency miss, hit)");
         end
         tr_no_err;
         $display("       mode %0d: 16 ops x 2 checked", tr_mode);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tr_untouch;
      end
      tr_rsw = 1'b0;

      //--------------------------------------------------------------
      $display("--- 4. meshes with XOR onto zero: no hole, no gap");
      if (TR_SMALL)
         $display("       (skipped: DIM_W too small for the meshes)");
      else begin
         tr_grid(0, 6, 5, 0);
         tr_grid(3, 6, 5, 1);
         tr_grid(4, 5, 6, 0);
         tr_grid(1, 6, 6, 1);
         tr_grid(2, 4, 4, 0);
         gpu_check_touched("TRI grid (VRAM window)");
         tr_fan(3, 0, 0);
         tr_fan(2, 1, 1);
         tr_fan(0, 0, 1);
         tr_fan(4, 2, 0);
         tr_fan(3, 2, 1);
         tr_fan(1, 3, 0);
         tr_fan(3, 1, 0);
         tr_untouch;
      end

      //--------------------------------------------------------------
      $display("--- 5. thin and degenerate triangles");
      tr_surf(3);
      tr_bg_rand;
      tr_clear;
      for (tr_i = 0; tr_i < 8; tr_i = tr_i + 1) begin
         tr_gen(-40, 100, -40, 100, TR_SMIN, TR_SMAX);
         if (tr_i < 4) begin                              // sliver at v1
            tr_gx[2] = tr_gx[1] + tr_rnd(25) - 12;
            tr_gy[2] = tr_gy[1] + tr_rnd(25) - 12;
         end else begin                                   // needle: v2 near the middle of v0-v1
            tr_gx[2] = (tr_gx[0] + tr_gx[1]) / 2 + tr_rnd(5) - 2;
            tr_gy[2] = (tr_gy[0] + tr_gy[1]) / 2 + tr_rnd(5) - 2;
         end
         tr_draw_g(tr_rnd(6), 4'd2);
         tr_done1("thin TRI");
         tr_show("thin TRI");
         tr_cmp("thin TRI");
      end
      for (tr_i = 0; tr_i < 10; tr_i = tr_i + 1) begin
         tr_m = 16 * tr_rnd(40) + tr_rnd(16);
         tr_n = 16 * tr_rnd(40) + tr_rnd(16);
         case (tr_i)
           0: tr_set_g(tr_m, tr_n, tr_m, tr_n, tr_m, tr_n);                         // one point
           1: tr_set_g(tr_m, tr_n, tr_m, tr_n, tr_m + 300, tr_n + 77);               // v1 = v0
           2: tr_set_g(tr_m, tr_n, (tr_m & -16) | 8, (tr_n & -16) | 8, (tr_m & -16) | 8, (tr_n & -16) | 8);
           3: tr_set_g(tr_m, tr_n, tr_m + 113, tr_n + 57, tr_m + 226, tr_n + 114);   // collinear, v2 beyond
           4: tr_set_g(tr_m, tr_n, tr_m + 226, tr_n - 114, tr_m + 113, tr_n - 57);   // collinear, midpoint last
           5: tr_set_g(8, 16 * tr_rnd(40) + 8, 600, 16 * 5 + 8, 0, 0);               // fixed below
           6: tr_set_g(0, 0, 0, 0, 0, 0);                                            // fixed below
           7: tr_set_g(8, 8, 520, 264, 1032, 520);                                   // slope 1/2 through centres
           8: tr_set_g(-648, -8, -8, -328, 632, -648);                               // slope -1/2, negative coordinates
           default: tr_set_g(tr_m, tr_n, tr_m, tr_n + 400, tr_m, tr_n + 31);         // vertical, sub-pixel x
         endcase
         if (tr_i == 5) tr_set_g(8, 16 * 7 + 8, 600, 16 * 7 + 8, 1000, 16 * 7 + 8);  // horizontal through centres
         if (tr_i == 6) tr_set_g(16 * 9 + 8, 8, 16 * 9 + 8, 900, 16 * 9 + 8, 300);   // vertical through centres
         tr_self_n(0);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tr_draw_g(tr_rnd(6), 4'd2);
         tr_done1("degenerate TRI");
         tr_show("degenerate TRI");
         tr_cmp("degenerate TRI: nothing drawn");
      end
      tr_untouch;

      //--------------------------------------------------------------
      $display("--- 6. clip window and negative coordinates");
      for (tr_i = 0; tr_i < 16; tr_i = tr_i + 1) begin
         if (tr_i % 4 == 0) begin
            tr_mode = tr_rnd(5);
            tr_surf(tr_mode);
            tr_bg_rand;
            tr_clear;
         end
         tr_cx0 = TR_X0 + tr_rnd(80);
         tr_cy0 = TR_Y0 + tr_rnd(80);
         tr_cx1 = tr_cx0 + tr_rnd(TR_XM - tr_cx0 + 1);
         tr_cy1 = tr_cy0 + tr_rnd(TR_YM - tr_cy0 + 1);
         if (tr_i == 5) tr_cx1 = tr_cx0;                                  // one column
         if (tr_i == 6) tr_cy1 = tr_cy0;                                  // one row
         if (tr_i == 7) tr_cx1 = tr_cx0 - 1 - tr_rnd(5);                  // inverted: nothing
         if ((tr_i == 10) || (tr_i == 11)) begin                          // negative quadrant, no clip
            tr_cx0 = -2048; tr_cy0 = -2048; tr_cx1 = 2047; tr_cy1 = 2047;
         end
         gpu_c_clip(tr_cx0, tr_cy0, tr_cx1, tr_cy1);
         if ((tr_i == 8) || (tr_i == 9)) begin                            // fully outside the window
            gpu_c_clip(20, TR_Y0, TR_XM, TR_YM);
            tr_gen(-60, 10, -60, 123, 5, TR_SMAX);
         end else if ((tr_i == 10) || (tr_i == 11))
            tr_gen(TR_X0, -1, TR_Y0, -1, 5, (TR_SMAX < 47) ? TR_SMAX : 47);
         else
            tr_gen(-60, 126, -60, 123, 5, TR_SMAX);
         tr_draw_g(tr_rnd(6), 4'd2);
         tr_done1("clipped TRI");
         $display("       clip (%0d, %0d)-(%0d, %0d)", gpu_m_cx0, gpu_m_cy0, gpu_m_cx1, gpu_m_cy1);
         tr_show("clipped TRI");
         tr_cmp("clipped TRI");
      end
      gpu_c_noclip;
      tr_untouch;


      //--------------------------------------------------------------
      $display("--- 7. large triangles, 4096-pixel slivers at the coordinate limits");
      if (TR_SMALL)
         $display("       (skipped: DIM_W too small for large triangles)");
      else begin
         tr_surf(3);
         tr_bg_rand;
         tr_clear;
         tr_set_g(-46 * 16 + 3, -40 * 16 + 5, 110 * 16 + 11, -20 * 16, -10 * 16 + 7, 108 * 16 + 2);
         tr_draw_g(0, 4'd2);
         tr_done1("large TRI");
         tr_show("large TRI");
         tr_cmp("large TRI, 8 bpp");
         tr_surf(4);
         tr_bg_rand;
         tr_clear;
         tr_set_g(-47 * 16 + 9, 110 * 16 + 1, 112 * 16 + 15, 104 * 16 + 6, 40 * 16 + 3, -47 * 16 + 12);
         tr_draw_g(3, 4'd2);
         tr_done1("large TRI");
         tr_show("large TRI");
         tr_cmp("large TRI, 16 bpp");
         tr_surf(3);
         tr_bg_rand;
         tr_clear;
         gpu_c_clip(TR_X0, TR_Y0, TR_XM, TR_YM);
         tr_set_g(-32768, -157, 32767, 331, -32768, 487);    // x from -2048.0 to 2047.9375
         tr_draw_g(tr_rnd(6), 4'd2);
         tr_done1("horizontal sliver");
         tr_show("horizontal sliver");
         tr_cmp("TRI horizontal 4096-px sliver, clipped");
         tr_set_g(-157, -32768, 487, -32768, 331, 32767);    // y from -2048.0 to 2047.9375
         tr_draw_g(tr_rnd(6), 4'd2);
         tr_done1("vertical sliver");
         tr_show("vertical sliver");
         tr_cmp("TRI vertical 4096-px sliver, clipped");
         gpu_c_noclip;
         tr_untouch;
      end

      //--------------------------------------------------------------
      $display("--- 8. gradient with TRI: i from the first row / column of the clipped walk");
      for (tr_m = 0; tr_m < 4; tr_m = tr_m + 1) begin
         tr_surf(tr_m + 1);
         tr_bg_rand;
         tr_clear;
         for (tr_c = 0; tr_c < 8; tr_c = tr_c + 1) begin
            tr_gn = 1 + tr_rnd(4);
            tr_gs = tr_rnd(16) - 8;
            if (tr_gs == 0) tr_gs = 3;
            tr_ky = -40 + tr_rnd(60);                                      // top vertex row
            tr_k  = 16 * (-18 + tr_rnd(TR_XM - TR_X0 - 60)) + tr_rnd(16);  // apex / top x
            tr_s  = 16 * (2 + tr_rnd((TR_SMAX - 6) / 2)) + tr_rnd(16);     // half width
            tr_t  = 16 * (4 + tr_rnd(TR_SMAX - 8)) + tr_rnd(16);           // height
            case (tr_c)
              0: tr_set_g(tr_k, 16 * tr_ky + 12, tr_k + tr_s, 16 * tr_ky + 12 + tr_t, tr_k - tr_s, 16 * tr_ky + 12 + tr_t);
              1: tr_set_g((tr_k & -16) | 8, 16 * tr_ky + 8, tr_k + tr_s, 16 * tr_ky + 8 + tr_t, tr_k - tr_s, 16 * tr_ky + 8 + tr_t);
              2: tr_set_g(tr_k - tr_s, 16 * tr_ky + 8, tr_k + tr_s, 16 * tr_ky + 8, tr_k + tr_rnd(16), 16 * tr_ky + 8 + tr_t);
              3: tr_set_g(tr_k - tr_s, 16 * tr_ky + 9, tr_k + tr_s, 16 * tr_ky + 9, tr_k - tr_rnd(16), 16 * tr_ky + 9 + tr_t);
              default: tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, (TR_SMAX < 50) ? TR_SMAX : 50);
            endcase
            tr_g_ytop;                                                     // dry run: box, first covered row
            if (((tr_c == 0) || (tr_c == 1) || (tr_c == 3)) && (tr_ytop <= tr_ky))
               tb_error("gradient case: the top vertex row should hold no pixel (test bug)");
            if ((tr_c == 1) && (tr_by0 != tr_ky))
               tb_error("gradient case: the walk should start on the empty apex row (test bug)");
            if ((tr_c == 2) && (tr_ytop != tr_ky))
               tb_error("gradient case: the top edge row should hold pixels (test bug)");
            if (tr_c == 4) gpu_c_clip(TR_X0, tr_by0 + 2 + tr_rnd(3), TR_XM, TR_YM);   // top walk rows clipped
            if (tr_c == 7) gpu_c_clip(tr_bx0 + 2 + tr_rnd(3), TR_Y0, TR_XM, TR_YM);   // left walk columns clipped
            if (tr_c == 5) begin
               tr_gn = 0;
               tr_gs = tr_rnd(2) ? -8 : 7;
            end
            gpu_c_grad(tr_gn, tr_c >= 6, tr_gs, 1'b1);
            if (tr_c % 2) gpu_c_fill($random(gpu_seed));
            tr_draw_g(tr_rnd(6), (tr_c % 2) ? 4'd5 : 4'd0);
            tr_done1("gradient TRI");
            $display("       gradient AXIS %0d N %0d STEP %0d: walk from row %0d / column %0d, first covered row %0d",
                     tr_c >= 6, tr_gn, tr_gs, tr_wy0, tr_wx0, tr_ytop);
            tr_show("gradient TRI");
            tr_cmp("gradient TRI");
            if ((tr_c == 4) || (tr_c == 7)) gpu_c_noclip;
         end
         gpu_c_grad(0, 1'b0, 0, 1'b0);
         gpu_c_fill($random(gpu_seed));
         tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
         tr_draw_g(tr_rnd(6), 4'd0);
         tr_done1("TRI after SET_GRAD EN = 0");
         tr_cmp("TRI after SET_GRAD EN = 0");
      end
      tr_untouch;

      //--------------------------------------------------------------
      $display("--- 9. address mode, rectangle after TRI, SET_XY");
      tr_surf(3);
      tr_bg_rand;
      tr_clear;
      gpu_c_dst(16'd77, TR_D_LO * 4 + 1003);                              // address mode
      tr_gen(0, 60, 0, 60, TR_SMIN, TR_SMAX);
      tr_draw_g(0, 4'd2);                                                 // modelled: nothing
      tr_done1("TRI in address mode");
      tr_no_err;
      tr_cmp("TRI in address mode: nothing drawn");
      gpu_check_all("TRI in address mode");
      gpu_c_size(14'd5, 14'd3);
      gpu_c_exec(GPU_FILL, 4'd2, 3'b000, 3'b000);
      tr_done1("rectangle after address TRI");
      tr_cmp("address-mode rectangle after a TRI");
      tr_surf(4);
      tr_bg_rand;
      tr_clear;
      gpu_c_xy(-7, 13);
      gpu_c_size(14'd6, 14'd4);
      tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
      tr_draw_g(tr_rnd(6), 4'd2);
      tr_done1("TRI before a rectangle");
      gpu_c_exec_xy(GPU_FILL, 4'd2, 3'b000, 3'b000);                      // SET_XY / SET_SIZE kept
      tr_done1("x/y rectangle after TRI");
      tr_cmp("x/y rectangle after a TRI");
      for (tr_i = 0; tr_i < 4; tr_i = tr_i + 1) begin
         gpu_c_xy(tr_rnd(200) - 100, tr_rnd(200) - 100);
         tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
         tr_draw_g(tr_rnd(6), 4'd2);
         tr_done1("TRI after SET_XY");
         $display("       SET_XY (%0d, %0d)", gpu_m_x, gpu_m_y);
         tr_cmp("TRI after SET_XY: relative to the origin");
      end
      tr_untouch;

      //--------------------------------------------------------------
      $display("--- 10. CALL lists, GPU_DONE once per triangle, only at completion");
      tr_surf(3);
      tr_bg_rand;
      tr_clear;
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      for (tr_i = 0; tr_i < 4; tr_i = tr_i + 1) begin
         if (TR_SMALL) tr_gen_big(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX, TR_NBIG);
         else          tr_gen_big(TR_X0, TR_XM, TR_Y0, TR_YM, 25, 60, 200);
         gpu_c_fill((tr_i % 2) ? 32'hFFFF_FFFF : $random(gpu_seed));
         tr_draw_g(tr_rnd(6), (tr_i % 2) ? 4'd5 : 4'd2);
      end
      gpu_cap_en = 1'b0;
      tr_n = gpu_cap_n;
      tr_list_write(TR_L_LO, 0);
      gpu_push({OP_CALL, 4'h0, tr_n[23:0]});
      gpu_push(TR_L_LO);
      tr_poll_done(tr_k);
      if (tr_k != 4) begin
         $display("ERROR: CALL list of 4 triangles: %0d GPU_DONE events, expected 4 %t", tr_k, $time);
         error = error + 1;
      end else
         $display("OK:    CALL list of 4 triangles (%0d words): 4 GPU_DONE events", tr_n);
      reg_rd_mask(GPU_STAT, 32'h0, TR_GS_LIST | GS_ERR);
      tr_no_err;
      tr_cmp("TRI list of 4 (CALL, backdoor list)");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_c_clip(-20, -10, 90, 80);
      gpu_c_grad(2, 1'b0, 3, 1'b1);
      gpu_c_fill($random(gpu_seed));
      tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
      tr_draw_g(tr_rnd(6), 4'd0);
      gpu_c_grad(0, 1'b0, 0, 1'b0);
      gpu_c_noclip;
      gpu_c_fill(32'hFFFF_FFFF);
      tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
      tr_draw_g(tr_rnd(6), 4'd5);                                         // last list word: the TRI EXEC
      gpu_cap_en = 1'b0;
      tr_n = gpu_cap_n;
      tr_list_write(TR_L_LO + 100, 1);
      gpu_push({OP_CALL, 4'h0, tr_n[23:0]});
      gpu_push(TR_L_LO + 100);
      tr_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_rd_mask(GPU_STAT, 32'h0, TR_GS_LIST | GS_ERR);
      tr_cmp("TRI list, clip + gradient (window)");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      if (!TR_SMALL) begin                                                // GPU_DONE only at completion
         tr_gen_big(TR_X0, TR_XM, TR_Y0, TR_YM, 50, 60, 700);
         tr_draw_g(tr_rnd(6), 4'd2);
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
         tr_done1("large TRI, DONE at the end");
         tr_cmp("large TRI, GPU_DONE only at completion");
      end
      tr_untouch;

      //--------------------------------------------------------------
      $display("--- 11. ABORT / GPU_EN = 0 in the middle of a triangle");
      for (tr_i = 0; tr_i < 6; tr_i = tr_i + 1)
         tr_abort_case(tr_i % 2);
      if ((tr_nmid == 0) && !TR_SMALL)
         tb_error("no ABORT / GPU_EN = 0 landed in the middle of a triangle");
      $display("       abandon: %0d mid-triangle, %0d before any pixel, %0d after the last", tr_nmid, tr_nnone, tr_nlate);
      tr_untouch;

      //--------------------------------------------------------------
      $display("--- 12. debug freeze toggled during a triangle");
      for (tr_i = 0; tr_i < 4; tr_i = tr_i + 1)
         tr_freeze_case(tr_i);
      if ((tr_nheld == 0) && !TR_SMALL)
         tb_error("the freeze never held the GPU in the middle of a triangle (test timing)");
      else
         $display("OK:    held mid-triangle %0d times without GPU_DONE or VRAM access", tr_nheld);
      tr_untouch;

      //--------------------------------------------------------------
      $display("--- 13. blending (SET_ALPHA) with TRI at 16 bpp, no effect at 8 bpp");
      tr_surf(4);
      tr_bg_rand;
      tr_clear;
      tr_c_alpha(255, 1'b1);
      repeat(10) @(posedge free_clk);
      reg_rd_val(GPU_STAT, tr_f);
      tr_j = (tr_f & GS_ERR) ? 0 : 1;                                     // SET_ALPHA accepted
      if (tr_j == 0) begin
         $display("ERROR: SET_ALPHA (SET_EXT sub 8) rejected, ERR_OPCODE %0d: blending section skipped %t", tr_f[31:28], $time);
         error = error + 1;
         reg_wr(GPU_CTRL, 32'h1);
         tr_aen = 1'b0;
      end
      // 6..9: ops 13..15 blend their constant (15: the gradient value) and
      // skip a fill colour equal to SET_TRANSP (9: every pixel)
      for (tr_i = 0; (tr_i < 10) && tr_aen; tr_i = tr_i + 1) begin
         tr_c_alpha((tr_i == 0) ? 255 : (tr_i == 1) ? 0 : tr_rnd(256), 1'b1);
         if ((tr_i == 4) || (tr_i == 8)) gpu_c_grad(1 + tr_rnd(3), 1'b0, tr_rnd(16) - 8, 1'b1);
         tr_k = $random(gpu_seed);
         gpu_c_fill(tr_k);
         gpu_c_transp((tr_i == 9) ? tr_k : ~tr_k);
         tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
         tr_draw_g(tr_rnd(6), (tr_i == 5) ? 4'd5 : (tr_i == 6) ? 4'd13 : (tr_i == 7) ? 4'd14 :
                              (tr_i >= 8) ? 4'd15 : 4'd0);                 // op 5 blends S too
         tr_done1("blended TRI");
         $display("       SET_ALPHA A %0d%0s, op %0d", tr_a, ((tr_i == 4) || (tr_i == 8)) ? " with a gradient" : "",
                  (tr_i == 5) ? 5 : (tr_i == 6) ? 13 : (tr_i == 7) ? 14 : (tr_i >= 8) ? 15 : 0);
         tr_cmp("blended TRI (16 bpp)");
         if ((tr_i == 4) || (tr_i == 8)) gpu_c_grad(0, 1'b0, 0, 1'b0);
      end
      tr_surf(3);
      tr_bg_rand;
      tr_clear;
      gpu_c_fill($random(gpu_seed));
      tr_gen(TR_X0, TR_XM, TR_Y0, TR_YM, TR_SMIN, TR_SMAX);
      tr_draw_g(tr_rnd(6), 4'd5);
      tr_done1("TRI, SET_ALPHA at 8 bpp");
      tr_cmp("TRI with SET_ALPHA at 8 bpp: plain op");
      if (tr_j) tr_c_alpha(0, 1'b0);
      tr_wait_idle;
      tr_untouch;

      tr_wait_idle;
      tr_no_err;
      gpu_check_all("TRI end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
