//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_setup
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_setup.v
// Module Description : GPU primitive set-up, between the decoder and the
//                      rectangle engine. In x/y mode it computes the start
//                      address origin + y * pitch + x and trims a rectangle to
//                      the clip window: the visible box, its first pixel for
//                      the swaps, the walk offsets (column, row) of the pixels
//                      left out, from which the source start, the texture start
//                      (u, v) and the gradient phase follow. An empty
//                      rectangle starts nothing (GPU_DONE only). One shared
//                      multiplier, one product per cycle; the gradient phase
//                      takes min(DIM_W, 14) cycles of division (its own
//                      restoring divider, or with triangles the triangle
//                      set-up's). In address mode nothing is
//                      trimmed; a triangle's box, its pixel centres within the
//                      vertex extents, is trimmed the same way; its edges are set
//                      up for the scan-line walk (blns_gpu_tri_setup, on the
//                      same multiplier and divider). With the mask plane, the offset K
//                      of the mask from the source (both untrimmed): the
//                      mask pixel of every source pixel is its address + K
//                      (an RGB565A8 source: its alpha byte, the same way).
//                      An immediate source (imm_i) is a surface at pixel 0
//                      with the rectangle's width as pitch: its start is the
//                      index of the first source pixel drawn (past the VRAM
//                      when it does not fit the pixel address).
//                      A line (x/y mode): its geometry from its start (the
//                      pen, held as the decoder moves it) and its end point
//                      (12.4): the Bresenham terms of the pixels
//                      holding them, or (AA, 16 bpp) the Wu slope by
//                      division (the gradient's restoring divider, its own
//                      with triangles) and the start position, the start
//                      address, the box test against the clip window, and
//                      the pattern phase: (phase + steps) mod LEN, a 2-bit
//                      restoring remainder; the phase is stream state, 0
//                      after a flush, a bound error, LINE_PATTERN or
//                      RESET_STATE.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_setup #(
    parameter                    GPU_XY_EN     = 1,    // x/y destinations and clip
    parameter                    GPU_GRAD_EN   = 1,    // gradient fill
    parameter              [0:0] TRI_USE       = 1'b0, // triangles built (blns_gpu: GPU_TRI_EN & GPU_XY_EN)
    parameter                    GPU_MPLANE_EN = 1,    // mask plane on copies (K)
    parameter                    GPU_BLEND_EN  = 0,    // alpha blending (anti-aliased lines)
    parameter              [0:0] LINE_USE      = 1'b0, // lines built (blns_gpu: GPU_LINE_EN & GPU_XY_EN)
    parameter                    GPU_RUNAHEAD_EN = 0,  // run-ahead (blns_gpu): the decoder does not wait for the engine
    parameter                    PA_W          = 21,   // pixel-address width
    parameter                    DIM_W         = 10,   // width/height field width
    parameter                    ASYNC_RST_EN  = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  abort_i,             // abandon the primitive
    input  wire                  start_i,             // decoder EXEC (1 cycle)
    input  wire                  eng_idle_i,          // the rectangle engine takes a new primitive
    input  wire                  freeze_i,            // debug freeze: no start, no completion
    output wire                  go_o,                // start the rectangle engine (1 cycle)
    output wire                  empty_done_o,        // trimmed away: completed without drawing (1 cycle)
    output wire                  busy_o,              // set-up running

// PRIMITIVE (stable while busy_o and while the engine runs)
    input  wire            [2:0] kind_i,              // 0 FILL, 1 COPY, 2 COPY_TRANSP, 3 EXPAND, 4 TEXSPAN, 5 TEXRECT
    input  wire                  tri_i,               // triangle (box already clipped)
    input  wire                  tri_empty_i,         // triangle: nothing to draw
    input  wire           [95:0] tri_v_i,             // {v2, v1, v0}, each {y, x} signed 12.4 (textured: (u, v) given at V0)
    input  wire                  xy_mode_i,           // destination in x/y mode
    input  wire           [15:0] xy_x_i,              // x of the first pixel (signed)
    input  wire           [15:0] xy_y_i,              // y of the first pixel (signed)
    input  wire           [47:0] clip_i,              // clip window {y0, x0, y1, x1}, signed, inclusive
    input  wire     [PA_W-1:0]   origin_i,            // x/y surface origin
    input  wire     [PA_W-1:0]   dst_base_i,          // address mode: destination first pixel
    input  wire           [15:0] dst_pitch_i,         // destination pitch (x/y mode: resolved)
    input  wire     [PA_W-1:0]   src_base_i,          // source first pixel
    input  wire                  imm_i,               // immediate source: base 0, pitch = the width
    input  wire     [PA_W-1:0]   msk_base_i,          // mask pixel of the source's first pixel (1 bpp)
    input  wire           [15:0] src_pitch_i,         // 0 = display width (EXPAND: the width)
    input  wire    [DIM_W-1:0]   disp_width_i,        // display width
    input  wire    [DIM_W-1:0]   width_i,             // pixels per run
    input  wire    [DIM_W-1:0]   height_i,            // runs
    input  wire            [2:0] dst_swap_i,          // {X, Y, CL}
    input  wire            [2:0] src_swap_i,          // {X, Y, CL}
    input  wire           [31:0] tex_uv_i,            // {u0, v0}, unsigned 10.6
    input  wire           [31:0] tex_step_i,          // {du, dv}, signed 5.11
    input  wire           [31:0] tex_rstep_i,         // {du', dv'}, signed 5.11
    input  wire           [48:0] grad_i,              // {RGB, dR, dG, dB, EN, STEP, AXIS, N}
    input  wire                  line_i,              // EXEC_FILL LINE
    input  wire                  line_start_i,        // ... a line starts (with start_i)
    input  wire            [3:0] line_opt_i,          // ... {PH_RST, OPAQUE, NO_LAST, AA}
    input  wire                  line_16_i,           // ... GFX_MODE 16 bpp at its start (AA drawn)
    input  wire           [31:0] line_p1_i,           // ... end point {y, x}, signed 12.4 (at start_i: the start, the pen before it)
    input  wire            [4:0] line_len_i,          // pattern length - 1
    input  wire                  ph_clr_i,            // the pattern phase to 0 (1 cycle)

// TO THE RECTANGLE ENGINE (registered, or with PASS_USE the decoder's registers; stable while it runs)
    output wire     [PA_W-1:0]   dst_base_o,          // destination first pixel
    output wire     [PA_W-1:0]   src_base_o,          // source first pixel
    output wire                  src_past_o,          // ... an immediate source index past 2^PA_W (src_base_o saturated)
    output wire     [PA_W-1:0]   msk_k_o,             // mask plane: mask pixel - source pixel
    output wire           [15:0] src_pitch_o,         // source pitch (EXPAND default resolved)
    output wire    [DIM_W-1:0]   width_o,             // pixels per run after trimming
    output wire    [DIM_W-1:0]   height_o,            // runs after trimming
    output wire           [20:0] tex_u0_o,            // u of the first pixel (10.11)
    output wire           [20:0] tex_v0_o,            // v of the first pixel (10.11)
    output wire           [11:0] grad_cnt0_o,         // gradient counter at the walk start
    output wire           [41:0] grad_val0_o,         // gradient value at the walk start (RGB: three 14-bit channels)
    output wire [3*(49+2*DIM_W)-1:0] tri_edges_o,     // triangle edges for the scan-line walk
    output wire          [3*36-1:0] tri_starts_o,     // their bounds at the first row
    output wire                  ln_aa_o,             // line: anti-aliased (Wu), else Bresenham
    output wire                  ln_xmaj_o,           // ... x is the major axis
    output wire                  ln_smaj_o,           // ... the major coordinate decreases
    output wire                  ln_smin_o,           // ... the minor coordinate decreases (AA: the slope is negative)
    output wire           [28:0] ln_g_o,              // ... {2d - 2D, 2d} (AA: the slope, signed, 1/2^16 px)
    output wire           [28:0] ln_e0_o,             // ... first error term 2d - D (AA: the first row position - 1/2 px, 1/2^16 px)
    output wire           [12:0] ln_p0_o,             // ... first major coordinate
    output wire           [12:0] ln_q0_o,             // ... first minor coordinate (AA: row)
    output wire           [12:0] ln_nm1_o,            // ... steps - 1
    output wire            [4:0] ln_ph_o              // ... pattern phase at its first step
);

//=============================================================================
// 1)  PARAMETERS AND STATES
//=============================================================================
localparam XY_USE     = (GPU_XY_EN     != 0);
localparam AFFINE_USE = XY_USE;                  // affine blits come with x/y
localparam GRAD_USE   = (GPU_GRAD_EN   != 0);

localparam AA_USE     = LINE_USE && (GPU_BLEND_EN != 0);   // anti-aliased lines
// Without x/y nothing is trimmed, and without run-ahead the decoder waits
// from S_LAT until the engine is idle: the engine's start values are the
// decoder's registers, not copies
localparam PASS_USE   = !XY_USE && (GPU_RUNAHEAD_EN == 0);
// Walk offsets: a rectangle's are in [0, 2^DIM_W - 2]; a textured triangle's
// (12.4, from its first box pixel to V0) 17-bit signed
localparam OFF_W      = TRI_USE ? 17 : DIM_W;
// Shared multiplier operands: without triangles and AA lines every term of
// mul_a fits max(13, DIM_W + 1) bits signed, without triangles every term of
// mul_b 17 bits
localparam MA_W       = (TRI_USE || AA_USE) ? 18 : ((DIM_W + 1 > 13) ? (DIM_W + 1) : 13);
localparam MB_W       = TRI_USE ? 18 : 17;

localparam [4:0] S_IDLE = 5'd0;
localparam [4:0] S_LAT  = 5'd10;                        // the decoder's EXEC fields are settled: latch
localparam [4:0] S_BOX  = 5'd1;                         // box registered: start address
localparam [4:0] S_SRC  = 5'd2;                         // source start
localparam [4:0] S_UC   = 5'd3;                         // u += col * du
localparam [4:0] S_VC   = 5'd4;                         // v += col * dv
localparam [4:0] S_UR   = 5'd5;                         // u += row * du'
localparam [4:0] S_VR   = 5'd6;                         // v += row * dv'
localparam [4:0] S_DIV  = 5'd7;                         // gradient: offset / N
localparam [4:0] S_GV   = 5'd8;                         // gradient value = quotient * STEP
localparam [4:0] S_GO   = 5'd9;                         // start the engine (when idle)
localparam [4:0] S_EMPTY = 5'd11;                       // trimmed away: complete when the engine is idle
localparam [4:0] S_TRI  = 5'd12;                        // triangle edges
localparam [4:0] S_LY   = 5'd13;                        // x/y mode: the box's y axis
localparam [4:0] S_GG   = 5'd14;                        // RGB gradient: green = quotient * dG
localparam [4:0] S_GB   = 5'd15;                        // RGB gradient: blue = quotient * dB
localparam [4:0] S_LN1  = 5'd16;                        // line: the phase remainder starts
localparam [4:0] S_LDIV = 5'd17;                        // AA line: the slope, 17 quotient bits
localparam [4:0] S_LMUL = 5'd18;                        // AA line: the first row, slope * d0
localparam [4:0] S_LADR = 5'd19;                        // line: start address
localparam [4:0] S_LPH  = 5'd20;                        // line: the phase remainder done

wire [4:0] state;
wire       st_idle = (state == S_IDLE);
wire       st_lat  = (state == S_LAT);
wire       st_box  = (state == S_BOX);
// (the states of a feature not built are never entered: their decodes are 0)
wire       st_src  = XY_USE & (state == S_SRC);
wire       st_uc   = XY_USE & (state == S_UC);
wire       st_vc   = XY_USE & (state == S_VC);
wire       st_ur   = XY_USE & (state == S_UR);
wire       st_vr   = XY_USE & (state == S_VR);
wire       st_div  = XY_USE & GRAD_USE & (state == S_DIV);
wire       st_gv   = XY_USE & GRAD_USE & (state == S_GV);
wire       st_go   = (state == S_GO);
wire       st_empty = XY_USE & (state == S_EMPTY);
wire       st_tri  = TRI_USE & (state == S_TRI);
wire       st_ly   = XY_USE & (state == S_LY);
wire       st_gg   = XY_USE & GRAD_USE & (state == S_GG);
wire       st_gb   = XY_USE & GRAD_USE & (state == S_GB);
wire       st_ln1  = LINE_USE & (state == S_LN1);
wire       st_ldiv = AA_USE & (state == S_LDIV);
wire       st_lmul = AA_USE & (state == S_LMUL);
wire       st_ladr = LINE_USE & (state == S_LADR);
wire       st_lph  = LINE_USE & (state == S_LPH);

//=============================================================================
// 2)  PRIMITIVE CLASS
//=============================================================================
wire       is_copy   = (kind_i == 3'd1) | (kind_i == 3'd2);
wire       is_exp    = (kind_i == 3'd3);
wire       is_tex    = kind_i[2];
wire       is_trect  = AFFINE_USE & kind_i[2] & kind_i[0];
wire       is_fillk  = (kind_i == 3'd0);
wire       xy_on     = XY_USE & xy_mode_i;
wire       ln_on     = LINE_USE & line_i;
wire       trim_on   = xy_on & ~tri_i & ~ln_on;          // a rectangle in x/y mode
wire       grad_on   = GRAD_USE & grad_i[17] & is_fillk & ~ln_on;

//=============================================================================
// 3)  CLIPPED BOX (one axis per cycle: x when latching, y the cycle after)
//=============================================================================
// Screen extents of the walk: runs along x (along y with CL), a swap reverses
// its axis. 18-bit signed arithmetic.
localparam [17:0] ONE18 = 18'd1;
wire [17:0] w18      = {{(18-DIM_W){1'b0}}, width_i};
wire [17:0] h18      = {{(18-DIM_W){1'b0}}, height_i};
wire        tri_on   = TRI_USE & tri_i;                  // a triangle: its box, no swaps
wire        cl_d     = dst_swap_i[0] & ~tri_on;
wire        y_d      = dst_swap_i[1] & ~tri_on;
wire        x_d      = dst_swap_i[2] & ~tri_on;
wire [17:0] x0       = {{2{xy_x_i[15]}}, xy_x_i};
wire [17:0] y0       = {{2{xy_y_i[15]}}, xy_y_i};
wire        box_on   = trim_on | (tri_on & xy_on);
wire        tex_tri  = tri_on & is_trect;
// The axis of this cycle (ax_y: a flop, 1 in S_LY, the cycle after S_LAT):
// its start, pixel count, swap, vertex coordinates (signed 12.4) and clip
// bounds
wire        ax_y;
wire [17:0] a_p0     = ax_y ? y0 : x0;
wire [17:0] a_n      = (ax_y ^ cl_d) ? h18 : w18;
wire        a_sw     = ax_y ? y_d : x_d;
wire [15:0] a_v0     = ax_y ? tri_v_i[31:16] : tri_v_i[15:0];
wire [15:0] a_v1     = ax_y ? tri_v_i[63:48] : tri_v_i[47:32];
wire [15:0] a_v2     = ax_y ? tri_v_i[95:80] : tri_v_i[79:64];
wire [11:0] a_c0     = ax_y ? clip_i[47:36] : clip_i[35:24];
wire [11:0] a_c1     = ax_y ? clip_i[23:12] : clip_i[11:0];
wire [17:0] av0      = {{2{a_v0[15]}}, a_v0};
wire [17:0] av1      = {{2{a_v1[15]}}, a_v1};
wire [17:0] av2      = {{2{a_v2[15]}}, a_v2};
wire [17:0] ac0      = {{6{a_c0[11]}}, a_c0};
wire [17:0] ac1      = {{6{a_c1[11]}}, a_c1};
// The walk's extent [lo, hi] = [bl + dl, bh + dh]: a rectangle from p0 over n
// pixels (a swap reverses it: dl = -(n - 1)), a triangle's box the pixels
// whose centre (16 p + 8) lies within the vertices' extents. The trim against
// [c0, c1] is computed from these terms in parallel: each candidate below is
// one sum (no carry chain waits for another), the compares select among them.
wire [17:0] a_nm1    = a_n - ONE18;
wire [17:0] d_r      = a_sw ? (18'd0 - a_nm1) : 18'd0;
wire [17:0] u_r      = a_sw ? 18'd0 : a_nm1;
// Triangle: the three vertex compares side by side, min / max selected once,
// each vertex's pixel bound computed before the select
wire        c01      = $signed(av0) < $signed(av1);
wire        c02      = $signed(av0) < $signed(av2);
wire        c12      = $signed(av1) < $signed(av2);
wire [17:0] v0_p7    = av0 + 18'd7;
wire [17:0] v1_p7    = av1 + 18'd7;
wire [17:0] v2_p7    = av2 + 18'd7;
wire [17:0] v0_m8    = av0 - 18'd8;
wire [17:0] v1_m8    = av1 - 18'd8;
wire [17:0] v2_m8    = av2 - 18'd8;
wire        mn0      =  c01 &  c02;                     // av0 the minimum
wire        mn1      = ~c01 &  c12;                     // av1
wire        mx0      = ~c01 & ~c02;                     // av0 the maximum
wire        mx1      =  c01 & ~c12;                     // av1
wire [17:0] amn_p7   = mn0 ? v0_p7 : mn1 ? v1_p7 : v2_p7;
wire [17:0] amx_m8   = mx0 ? v0_m8 : mx1 ? v1_m8 : v2_m8;
wire [17:0] lo_t     = {{4{amn_p7[17]}}, amn_p7[17:4]};
wire [17:0] hi_t     = {{4{amx_m8[17]}}, amx_m8[17:4]};
wire [17:0] bl       = tri_on ? lo_t  : a_p0;
wire [17:0] dl       = tri_on ? 18'd0 : d_r;
wire [17:0] bh       = tri_on ? hi_t  : a_p0;
wire [17:0] dh       = tri_on ? 18'd0 : u_r;
// lo_c: c0 > lo (the trimmed start is c0), hi_c: hi > c1 (the trimmed end is
// c1); |values| < 2^17: no sum overflows its 18 bits (19 for the clamp)
wire [17:0] x_lo     = bl + dl - ac0;
wire [17:0] x_hi     = ac1 - bh - dh;
wire        lo_c     = x_lo[17];
wire        hi_c     = x_hi[17];
// Count hi' - lo' + 1 (lo' / hi' the trimmed ends), empty when hi' < lo', and
// past DIM_MAX (a triangle only: at most 2^DIM_W - 1)
localparam [17:0] DIM_MAX = (18'd1 << DIM_W) - 18'd1;
localparam [18:0] DIM_MAX19 = {1'b0, DIM_MAX};
wire [17:0] g_ll     = bh + dh - bl - dl;
wire [17:0] g_lc     = bh + dh - ac0;
wire [17:0] g_cl     = ac1 - bl - dl;
wire [17:0] g_cc     = ac1 - ac0;
wire [17:0] t_ll     = bh + dh - bl - dl + ONE18;
wire [17:0] t_lc     = bh + dh - ac0 + ONE18;
wire [17:0] t_cl     = ac1 - bl - dl + ONE18;
wire [17:0] t_cc     = ac1 - ac0 + ONE18;
wire [18:0] o_ll     = {bh[17], bh} + {dh[17], dh} - {bl[17], bl} - {dl[17], dl} - DIM_MAX19;
wire [18:0] o_lc     = {bh[17], bh} + {dh[17], dh} - {ac0[17], ac0} - DIM_MAX19;
wire [18:0] o_cl     = {ac1[17], ac1} - {bl[17], bl} - {dl[17], dl} - DIM_MAX19;
wire [18:0] o_cc     = {ac1[17], ac1} - {ac0[17], ac0} - DIM_MAX19;
wire        a_empty  = hi_c ? (lo_c ? g_cc[17] : g_cl[17]) : (lo_c ? g_lc[17] : g_ll[17]);
wire [17:0] a_tn     = hi_c ? (lo_c ? t_cc : t_cl) : (lo_c ? t_lc : t_ll);
wire        a_ovr    = hi_c ? (lo_c ? ~o_cc[18] : ~o_cl[18]) : (lo_c ? ~o_lc[18] : ~o_ll[18]);
wire [17:0] a_tnc    = a_ovr ? DIM_MAX : a_tn;
// First pixel drawn, how far it is from the first pixel of the walk (>= 0);
// a textured triangle: (u, v) at V0, carried to the first box pixel's centre
// by its 12.4 offset from V0 (the products are then 16 times too large; the
// box is inside the 12-bit clip window: a_f in [-2048, 2047], 14 bits hold it)
wire [17:0] at_lo    = lo_c ? ac0 : (bl + dl);
wire [17:0] at_hi    = hi_c ? ac1 : (bh + dh);
wire [17:0] a_f      = a_sw ? at_hi : at_lo;
wire [17:0] d_lc     = ac0 - a_p0;
wire [17:0] d_ll     = bl + dl - a_p0;
wire [17:0] d_hc     = a_p0 - ac1;
wire [17:0] d_hl     = a_p0 - bh - dh;
wire [17:0] a_d      = a_sw ? (hi_c ? d_hc : d_hl) : (lo_c ? d_lc : d_ll);
wire [17:0] f_lc     = {ac0[13:0], 4'h8} - av0;
wire [17:0] f_ll     = {bl[13:0], 4'h0} + {dl[13:0], 4'h0} + 18'd8 - av0;
// (tri_on clears the swaps: a textured triangle starts at the low end of
// both axes, its offset is f_lc or f_ll)
wire [17:0] a_off    = tex_tri ? (lo_c ? f_lc : f_ll) : a_d;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_ax_y (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(st_lat & box_on & ~abort_i), .q_o(ax_y));

// The x axis, held for the y cycle. Kept for a box that is not empty only
// (else nothing reads them): the offset in OFF_W bits, the first pixel in
// the 12-bit clip window
wire [OFF_W-1:0] ox_qn;
wire [11:0] fx_a_q;
wire [DIM_W-1:0] tnx_q;
wire        ex_q;
arv_ipdff #(.WIDTH(OFF_W + 13 + DIM_W), .ARST_EN(ASYNC_RST_EN)) u_box_x (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_lat),
             .d_i({a_off[OFF_W-1:0], a_f[11:0], a_tnc[DIM_W-1:0], a_empty}), .q_o({ox_qn, fx_a_q, tnx_q, ex_q}));
wire [17:0] ox_q     = TRI_USE ? {{(18-OFF_W){ox_qn[OFF_W-1]}}, ox_qn} : {{(18-OFF_W){1'b0}}, ox_qn};

// Walk offsets: column (along the run) and row (run index); sizes along the
// run and across
wire [DIM_W-1:0] tny_c = a_tnc[DIM_W-1:0];
wire        empty    = box_on & (ex_q | a_empty);
wire [17:0] col_off  = tex_tri ? ox_q  : trim_on ? (cl_d ? a_off : ox_q) : 18'd0;
wire [17:0] row_off  = tex_tri ? a_off : trim_on ? (cl_d ? ox_q : a_off) : 18'd0;
wire [DIM_W-1:0] tw_nxt = box_on ? (cl_d ? tny_c : tnx_q) : width_i;
wire [DIM_W-1:0] th_nxt = box_on ? (cl_d ? tnx_q : tny_c) : height_i;

// The decoder writes the EXEC fields (kind, swaps, size, moved base) at the
// start: they are latched one cycle later
wire        go_in    = st_idle & start_i & ~abort_i;
wire        lat      = st_lat;
wire        box_lat  = (st_lat & ~box_on) | st_ly;      // the box registers: after the y axis
wire [OFF_W-1:0] col_qn;
wire [OFF_W-1:0] row_qn;
wire [11:0] fx_qn;
wire [11:0] fy_qn;
wire [DIM_W-1:0] tw_q;
wire [DIM_W-1:0] th_q;
wire        empty_q;

// (the first pixel: read for a box only, at S_BOX (the start address) and by
// the triangle set-up; address mode, a line do not read it)
arv_ipdff #(.WIDTH(2*OFF_W + 25), .ARST_EN(ASYNC_RST_EN)) u_box (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(box_lat),
             .d_i({col_off[OFF_W-1:0], row_off[OFF_W-1:0], fx_a_q, a_f[11:0], empty}), .q_o({col_qn, row_qn, fx_qn, fy_qn, empty_q}));
wire [17:0] col_q    = TRI_USE ? {{(18-OFF_W){col_qn[OFF_W-1]}}, col_qn} : {{(18-OFF_W){1'b0}}, col_qn};
wire [17:0] row_q    = TRI_USE ? {{(18-OFF_W){row_qn[OFF_W-1]}}, row_qn} : {{(18-OFF_W){1'b0}}, row_qn};
wire [17:0] fx_q     = {{6{fx_qn[11]}}, fx_qn};
wire [17:0] fy_q     = {{6{fy_qn[11]}}, fy_qn};
generate
    if (PASS_USE) begin : g_tsize_pass
        assign tw_q = width_i;                          // (box_on is 0: not trimmed)
        assign th_q = height_i;
        wire [2*DIM_W-1:0] tsize_unused = {tw_nxt, th_nxt};
    end else begin : g_tsize
        arv_ipdff #(.WIDTH(2*DIM_W), .ARST_EN(ASYNC_RST_EN)) u_tsize (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(box_lat),
             .d_i({tw_nxt, th_nxt}), .q_o({tw_q, th_q}));
    end
endgenerate

//=============================================================================
// 4)  SHARED MULTIPLIER (18 x 18 signed, one product per cycle)
//=============================================================================
// Source walk: the inner step is +-1 (CL: +-pitch), the outer +-pitch (CL: +-1)
wire [15:0] src_pitch_e = imm_i ? {{(16-DIM_W){1'b0}}, width_i} :
                          (src_pitch_i != 16'h0000) ? src_pitch_i :
                          is_exp ? {{(16-DIM_W){1'b0}}, width_i} : {{(16-DIM_W){1'b0}}, disp_width_i};
wire [PA_W-1:0] src_b  = imm_i ? {PA_W{1'b0}} : src_base_i;
wire        cl_s     = src_swap_i[0] & ~is_exp;
wire        y_s      = src_swap_i[1] & ~is_exp;
wire        x_s      = src_swap_i[2] & ~is_exp;
wire [17:0] s_mul_n  = cl_s ? col_q : row_q;           // steps of +-pitch (sign: Y swap)
wire [17:0] s_add_n  = cl_s ? row_q : col_q;           // steps of +-1 (sign: X swap)

wire     [15:0] spitch_q;

// The source pitch is resolved once (display width taken at the start)
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_spitch (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat), .d_i(src_pitch_e), .q_o(spitch_q));

wire [17:0] tex_du18  = {{2{tex_step_i[31]}},  tex_step_i[31:16]};
wire [17:0] tex_dv18  = {{2{tex_step_i[15]}},  tex_step_i[15:0]};
wire [17:0] tex_rdu18 = {{2{tex_rstep_i[31]}}, tex_rstep_i[31:16]};
wire [17:0] tex_rdv18 = {{2{tex_rstep_i[15]}}, tex_rstep_i[15:0]};
wire        grad_rgb  = grad_i[48];                         // per channel (16 bpp): steps dR, dG, dB
wire [17:0] grad_s18  = {{14{grad_i[16]}}, grad_i[16:13]};
wire [17:0] grad_r18  = {{8{grad_i[47]}}, grad_i[47:38]};
wire [17:0] grad_g18  = {{8{grad_i[37]}}, grad_i[37:28]};
wire [17:0] grad_b18  = {{8{grad_i[27]}}, grad_i[27:18]};
wire [17:0] quot_q;
wire        t_div_ld;                                    // gradient division on the triangle set-up's divider
wire        t_div_stp;
wire [17:0] t_div_dvd;
wire [13:0] t_quo;
wire [11:0] t_rem;

// One-hot OR-mux: the triangle set-up's operands are 0 unless it is busy,
// and it is busy only while this stage is in S_TRI (started from S_BOX, left
// when it is no longer busy; an abort clears both in the same cycle), a state
// that selects none of the terms below
wire [17:0] t_mul_a;                                     // triangle set-up operands (0 when idle)
wire [17:0] t_mul_b;
wire [17:0] l_mul_a;                                     // line operands (0 outside S_LMUL / S_LADR)
wire [17:0] l_mul_b;
wire [17:0] mul_a    = t_mul_a | l_mul_a          |
                       ({18{st_box}} & fy_q)      |
                       ({18{st_src}} & s_mul_n)   |
                       ({18{st_uc}}  & col_q)     |
                       ({18{st_vc}}  & col_q)     |
                       ({18{st_ur}}  & row_q)     |
                       ({18{st_vr}}  & row_q)     |
                       ({18{st_gv | st_gg | st_gb}} & quot_q);
wire [17:0] mul_b    = t_mul_b | l_mul_b          |
                       ({18{st_box}} & {2'b00, dst_pitch_i}) |
                       ({18{st_src}} & {2'b00, spitch_q}) |
                       ({18{st_uc}}  & tex_du18)  |
                       ({18{st_vc}}  & tex_dv18)  |
                       ({18{st_ur}}  & tex_rdu18) |
                       ({18{st_vr}}  & tex_rdv18) |
                       ({18{st_gv}}  & (grad_rgb ? grad_r18 : grad_s18)) |
                       ({18{st_gg}}  & grad_g18)  |
                       ({18{st_gb}}  & grad_b18);
// (the operands at their widths: their upper bits are sign copies)
wire signed [35:0] mul_s = $signed(mul_a[MA_W-1:0]) * $signed(mul_b[MB_W-1:0]);   // 36-bit context
wire [35:0] mul_p    = $unsigned(mul_s);

//=============================================================================
// 5)  RESULTS
//=============================================================================
wire [31:0] mul_p32  = mul_p[31:0];
wire [17:0] l_x18;                                       // line: x of the start (S_LADR)
wire [17:0] ax_q     = st_ladr ? l_x18 : fx_q;
wire [31:0] fx32     = {{14{ax_q[17]}}, ax_q};
wire [31:0] org32    = {{(32-PA_W){1'b0}}, origin_i};
wire [31:0] dst_xy   = org32 + mul_p32 + fx32;          // origin + y * pitch + x
wire [31:0] sb32     = {{(32-PA_W){1'b0}}, src_b};
wire [31:0] s_add32  = {14'h0000, s_add_n};
// base -+ product -+ offset as one sum: a swap's negation is the inverted
// operand plus a carry-in (-p = ~p + 1), no negate after the product
wire [31:0] src_st   = sb32 + (mul_p32 ^ {32{y_s}}) + (s_add32 ^ {32{x_s}}) + {30'd0, y_s & x_s, y_s ^ x_s};

wire [PA_W-1:0] dst_q;
wire [PA_W-1:0] src_q;
wire     [20:0] u_q;
wire     [20:0] v_q;
wire     [20:0] u0      = {tex_uv_i[31:16], 5'b00000};
wire     [20:0] v0      = {tex_uv_i[15:0],  5'b00000};

// Priority: latch (defaults) > the step of the state
wire [PA_W-1:0] dst_nxt = lat ? dst_base_i : dst_xy[PA_W-1:0];
// An immediate start past the pixel address range: saturated and flagged
// (src_past_o): the engine takes the index as past the VRAM whatever its
// depth, and its bound check stops the rectangle (ERR_CAUSE 5)
wire            src_ovf = imm_i & (src_st[31:PA_W] != {(32-PA_W){1'b0}});
wire [PA_W-1:0] src_nxt = lat ? src_b : src_ovf ? {PA_W{1'b1}} : src_st[PA_W-1:0];
wire            src_past;
wire signed [35:0] mul_s16 = mul_s >>> 4;
wire     [35:0] mul_s16u = $unsigned(mul_s16);
wire     [20:0] mul_t   = tex_tri ? mul_s16u[20:0] : mul_p[20:0];
wire     [20:0] u_nxt   = lat ? u0 : (u_q + mul_t[20:0]);
wire     [20:0] v_nxt   = lat ? v0 : (v_q + mul_t[20:0]);

// The engine reads dst, src, u and v the cycle after go_o (run-ahead keeps no
// copy of them): they change from S_LAT on only, a cycle after S_IDLE at the
// earliest. PASS_USE: only the S_LAT loads exist (no trim, no line); the
// decoder's values then, held until the engine is idle
generate
    if (PASS_USE) begin : g_start_pass
        assign dst_q    = dst_base_i;
        assign src_q    = src_b;
        assign src_past = 1'b0;
        assign u_q      = u0;
        assign v_q      = v0;
        wire [2*PA_W+42:0] start_unused = {dst_nxt, src_nxt, src_ovf, u_nxt, v_nxt};
    end else begin : g_start
        arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_dst (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | (st_box & xy_on) | st_ladr), .d_i(dst_nxt), .q_o(dst_q));
        arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_src (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | st_src), .d_i(src_nxt), .q_o(src_q));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_src_past (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | st_src), .d_i(~lat & src_ovf), .q_o(src_past));
        arv_ipdff #(.WIDTH(21), .ARST_EN(ASYNC_RST_EN)) u_u (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | st_uc | st_ur), .d_i(u_nxt), .q_o(u_q));
        arv_ipdff #(.WIDTH(21), .ARST_EN(ASYNC_RST_EN)) u_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | st_vc | st_vr), .d_i(v_nxt), .q_o(v_q));
    end
endgenerate

// Mask plane: K = mask base - source base, from the decoder's registers (the
// mask follows the trimmed source start, every swap and mirror through it).
// An RGB565A8 source (blending) takes its alpha plane's K the same way
wire [PA_W-1:0] k_q;
generate
    if ((GPU_MPLANE_EN != 0) || (GPU_BLEND_EN != 0)) begin : g_msk_k
        arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_k (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat), .d_i(msk_base_i - src_b), .q_o(k_q));
    end else begin : g_no_msk_k
        assign k_q = {PA_W{1'b0}};
        wire [PA_W-1:0] msk_unused = msk_base_i;           // GPU_MPLANE_EN = 0 and GPU_BLEND_EN = 0
    end
endgenerate

//=============================================================================
// 6)  GRADIENT PHASE: offset / N (DV_W cycles of division), quotient * STEP
//=============================================================================
// The offset is a trimmed walk offset (a gradient is an x/y rectangle, not a
// triangle): below the width / height, < 2^DV_W. S_DIV lasts DV_W cycles
// (d_cnt, loaded at S_BOX). Without triangles: a restoring divider, one
// quotient bit per cycle, the offset loaded at the top of its 18-bit dividend
// (the steps that would shift in its leading zeros are not made: the quotient
// and the remainder are the same); without AA lines too, at its widths (a
// 12-bit remainder, the DV_W-bit offset shifted out as the quotient shifts in). With triangles: the triangle set-up's
// divider (two bits per step, B = 16 N, the offset x 16 aligned to G_H
// steps), stepped in the first G_H cycles of S_DIV, then held to S_GB. The two
// uses are exclusive: the triangle set-up runs only while this stage is in
// S_TRI (started from S_BOX the cycle after, left when it is no longer busy;
// an abort clears both), and the gradient loads at S_BOX (the triangle set-up
// idle; a triangle reloads the divider before it divides) and steps in S_DIV
// only, which a triangle never reaches (need_g: an x/y rectangle).
localparam       DV_W    = (DIM_W < 14) ? DIM_W : 14;
localparam [31:0] DV_W_M1 = DV_W - 1;
localparam [4:0] DV_LAST = DV_W_M1[4:0];
localparam [31:0] G_H    = (DV_W + 1) / 2;              // two-bit steps (triangle builds)
localparam [4:0] G_H5    = G_H[4:0];
wire [11:0] grad_n   = (grad_i[11:0] == 12'h000) ? 12'h001 : grad_i[11:0];
wire [17:0] g_off    = grad_i[12] ? col_q : row_q;      // AXIS 1: along the run
wire  [4:0] d_cnt;
wire [17:0] d_rem;
wire        div_last = (d_cnt == DV_LAST);
// Priority: start (load the dividend) > a division step
wire        div_ld   = st_box;
// The AA line's division: loaded in S_LN1, 17 steps in S_LDIV (section 7b)
wire        l_div_ld;
wire  [4:0] cnt_nxt  = (div_ld | l_div_ld) ? 5'd0 : (d_cnt + 5'd1);
arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_dcnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(div_ld | st_div | l_div_ld | st_ldiv),
             .d_i(cnt_nxt), .q_o(d_cnt));
// The restoring divider of the gradient (no triangles) and of the AA line:
// one quotient bit per step; o_q / o_r its quotient and remainder registers
wire        o_ld     = (div_ld & ~TRI_USE) | l_div_ld;
wire        o_step   = (st_div & ~TRI_USE) | st_ldiv;
wire [15:0] o_b;                                         // divisor
wire [17:0] o_q0;                                        // the dividend loaded: quotient register
wire [17:0] o_r0;                                        // ... remainder register
wire [17:0] o_q;
wire [17:0] o_r;

generate
    if (TRI_USE) begin : g_div_tri
        // (dividend x 16) << (14 - 2 G_H): its 2 G_H bits below the
        // remainder's start (x 16 < 16 N)
        wire [31:0] g_x32 = {{(32-DV_W){1'b0}}, g_off[DV_W-1:0]} << (18 - 2*G_H);
        assign t_div_ld  = div_ld;
        assign t_div_stp = st_div & (d_cnt < G_H5);
        assign t_div_dvd = g_x32[17:0];
        assign quot_q    = {4'h0, t_quo};
        assign d_rem     = {6'h00, t_rem};
        wire [13:0] g_x_unused = g_x32[31:18];             // < 2^18
        wire        o_r_unused = o_r[17];                   // (the AA division: < 2^17)
    end else begin : g_div_own
        assign t_div_ld  = 1'b0;
        assign t_div_stp = 1'b0;
        assign t_div_dvd = 18'h00000;
        assign quot_q    = o_q;
        assign d_rem     = o_r;
        wire [25:0] t_res_unused = {t_quo, t_rem};          // no triangles
    end
    if (!TRI_USE && !AA_USE) begin : g_odiv_g
        // The gradient's alone: the remainder below N <= 4 095 (12 bits),
        // the offset's DV_W bits shifted out as the quotient's shift in (the
        // quotient read from S_GV, after the DV_W steps)
        wire       [11:0] o_r12;
        wire   [DV_W-1:0] o_qn;
        wire       [12:0] o_rs     = {o_r12, o_qn[DV_W-1]};
        wire              o_ge     = (o_rs >= {1'b0, grad_n});
        wire       [12:0] o_rn     = o_ge ? (o_rs - {1'b0, grad_n}) : o_rs;
        wire  [11+DV_W:0] o_nxt    = o_ld ? {12'h000, g_off[DV_W-1:0]} : {o_rn[11:0], o_qn[DV_W-2:0], o_ge};
        arv_ipdff #(.WIDTH(12 + DV_W), .ARST_EN(ASYNC_RST_EN)) u_div (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(o_ld | o_step),
             .d_i(o_nxt), .q_o({o_r12, o_qn}));
        assign o_q = {{(18-DV_W){1'b0}}, o_qn};
        assign o_r = {6'h00, o_r12};
        wire [52:0] o_unused = {o_rn[12], o_b, o_q0, o_r0};   // (o_rn < N: 12 bits)
    end else if (AA_USE) begin : g_odiv
        wire [17:0] o_rs     = {o_r[16:0], o_q[17]};
        wire        o_ge     = (o_rs >= {2'b00, o_b});
        wire [17:0] o_rn     = o_ge ? (o_rs - {2'b00, o_b}) : o_rs;
        wire [35:0] o_nxt    = o_ld ? {o_r0, o_q0} : {o_rn, o_q[16:0], o_ge};
        arv_ipdff #(.WIDTH(36), .ARST_EN(ASYNC_RST_EN)) u_div (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(o_ld | o_step),
             .d_i(o_nxt), .q_o({o_r, o_q}));
    end else begin : g_no_odiv
        assign o_q = 18'h00000;
        assign o_r = 18'h00000;
        wire [52:0] o_unused = {o_ld, o_step, o_b, o_q0, o_r0};   // triangles divide the gradient, no AA
    end
endgenerate

wire [11:0] gcnt_q;
wire [15:0] gval_q;
arv_ipdff #(.WIDTH(28), .ARST_EN(ASYNC_RST_EN)) u_gphase (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | st_gv),
             .d_i(lat ? 28'h0000000 : {d_rem[11:0], mul_p[15:0]}), .q_o({gcnt_q, gval_q}));
// RGB: each channel's start, quotient * step saturated to 14 bits (signed, 6
// fraction bits), shifted in red, green, blue
wire        g_hi     = ~mul_p[35] & (mul_p[34:13] != 22'h000000);
wire        g_lo     =  mul_p[35] & (mul_p[34:13] != 22'h3FFFFF);
wire [13:0] g_sat    = g_hi ? 14'h1FFF : g_lo ? 14'h2000 : mul_p[13:0];
wire [41:0] grgb_q;
wire [41:0] grgb_nxt = lat ? 42'h0 : {grgb_q[27:0], g_sat};
arv_ipdff #(.WIDTH(42), .ARST_EN(ASYNC_RST_EN)) u_grgb (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lat | st_gv | st_gg | st_gb),
             .d_i(grgb_nxt), .q_o(grgb_q));

//=============================================================================
// 7)  TRIANGLE EDGES
//=============================================================================
wire       tri_go    = tri_on & ~tri_empty_i;
wire       tri_busy;
wire       tri_degen;

generate
    if (TRI_USE) begin : g_tri
        blns_gpu_tri_setup #(
            .DIM_W        (DIM_W),
            .ASYNC_RST_EN (ASYNC_RST_EN)
        ) u_tri_setup (
        // CLOCK & RESET
            .hclk_i       (hclk_i),
            .hresetn_i    (hresetn_i),
        // CONTROL
            .start_i      (st_box & tri_go & ~empty_q & ~abort_i),
            .abort_i      (abort_i),
            .busy_o       (tri_busy),
            .degen_o      (tri_degen),
        // TRIANGLE
            .tri_v_i      (tri_v_i),
            .box_x_i      (fx_q[15:0]),
            .box_y_i      (fy_q[15:0]),
            .box_h_i      (th_q),
        // SHARED MULTIPLIER
            .mul_a_o      (t_mul_a),
            .mul_b_o      (t_mul_b),
            .mul_p_i      (mul_p),
        // GRADIENT DIVISION
            .gdiv_ld_i    (t_div_ld),
            .gdiv_step_i  (t_div_stp),
            .gdiv_dvd_i   (t_div_dvd),
            .gdiv_n_i     (grad_n),
            .gdiv_quo_o   (t_quo),
            .gdiv_rem_o   (t_rem),
        // EDGES
            .edges_o      (tri_edges_o),
            .starts_o     (tri_starts_o)
        );
    end else begin : g_no_tri
        assign tri_busy    = 1'b0;
        assign tri_degen   = 1'b0;
        assign t_mul_a     = 18'h00000;
        assign t_mul_b     = 18'h00000;
        assign tri_edges_o = {(3*(49+2*DIM_W)){1'b0}};
        assign tri_starts_o = {(3*36){1'b0}};
        assign t_quo       = 14'h0000;
        assign t_rem       = 12'h000;
        wire [19:0] t_div_unused = {t_div_ld, t_div_stp, t_div_dvd};   // no triangles
        wire [95:0] tri_v_unused = tri_v_i;              // no triangles (textured: V0 used)
    end
endgenerate


//=============================================================================
// 7b) LINES
//=============================================================================
// Latched at S_LAT from the pen and the end point (stable while busy).
// Bresenham: the pixels (a, b) = (x >> 4, y >> 4) holding the end points; the
// major axis x when |dx| >= |dy| (pixels), D, d the major and minor
// distances; the engine starts the error at 2d - D and adds 2d (2d - 2D on a
// minor step). AA (Wu, 16 bpp): the major axis from the 12.4 deltas; the
// slope G = |dQ| 2^16 / |dP| (17-bit quotient, 0 for a point), signed by dQ;
// the columns i = P >> 4 from i0 to i1; the start T0 = Q0 2^12 + floor(G d0
// / 16) - 2^15, d0 = s (16 i0 + 8 - P0) the travel to the first column
// centre; its row T0 >> 16. Steps: D + 1 (columns |i1 - i0| + 1), one less
// with NO_LAST. The start (the pen before the line) is read from line_p1_i
// at the line's start_i (line_start_i), before the decoder's move to the end
// point lands, into a register otherwise loaded at S_LAT and S_LMUL only (AA:
// l_w; else l_g, its pixel parts), and read back at S_LAT. The engine reads
// l_w and l_g at its walk load, the cycle after go_o: start_i comes in that
// cycle at the earliest, its write lands after it. Without run-ahead the
// engine reads l_g while it draws: the decoder waits for it before any
// start_i.
wire        lo_aa    = AA_USE & line_opt_i[0] & line_16_i;   // AA drawn (below 16 bpp: solid)
wire        lo_nl    = line_opt_i[1];
wire        lo_phr   = line_opt_i[3];
wire [31:0] l_pen0;                                      // the start, held from start_i to S_LAT
wire        l_pen_ld = go_in & ln_on & line_start_i;
wire [15:0] lx0      = l_pen0[15:0];
wire [15:0] ly0      = l_pen0[31:16];
wire [15:0] lx1      = line_p1_i[15:0];
wire [15:0] ly1      = line_p1_i[31:16];
wire [12:0] la0      = {lx0[15], lx0[15:4]};             // pixels (13-bit signed)
wire [12:0] lb0      = {ly0[15], ly0[15:4]};
wire [12:0] la1      = {lx1[15], lx1[15:4]};
wire [12:0] lb1      = {ly1[15], ly1[15:4]};
wire [12:0] sdx      = la1 - la0;
wire [12:0] sdy      = lb1 - lb0;
wire [12:0] adx      = sdx[12] ? (13'd0 - sdx) : sdx;
wire [12:0] ady      = sdy[12] ? (13'd0 - sdy) : sdy;
wire        s_xm     = (adx >= ady);
wire [12:0] s_dd     = s_xm ? adx : ady;                 // D
wire [12:0] s_d      = s_xm ? ady : adx;                 // d
wire [13:0] s_ea     = {s_d, 1'b0};                      // 2d
wire [13:0] s_eb     = {s_d, 1'b0} - {s_dd, 1'b0};       // 2d - 2D
wire [13:0] s_f0     = {s_d, 1'b0} - {1'b0, s_dd};       // 2d - D
// AA
wire [16:0] fdx      = {lx1[15], lx1} - {lx0[15], lx0};
wire [16:0] fdy      = {ly1[15], ly1} - {ly0[15], ly0};
wire [16:0] afx      = fdx[16] ? (17'd0 - fdx) : fdx;    // <= 65535
wire [16:0] afy      = fdy[16] ? (17'd0 - fdy) : fdy;
wire        a_xm     = (afx >= afy);
wire [15:0] a_p      = a_xm ? afx[15:0] : afy[15:0];     // divisor |dP|
wire [15:0] a_q      = a_xm ? afy[15:0] : afx[15:0];     // dividend |dQ| (<= |dP|)
wire        a_sp     = a_xm ? fdx[16] : fdy[16];
wire        a_sq     = a_xm ? fdy[16] : fdx[16];
wire  [3:0] a_pf0    = a_xm ? lx0[3:0] : ly0[3:0];      // P0's fraction
wire [15:0] a_qm0    = a_xm ? ly0 : lx0;
wire [12:0] a_i0     = a_xm ? la0 : lb0;
wire [12:0] a_i1     = a_xm ? la1 : lb1;
wire [12:0] a_ni     = a_sp ? (a_i0 - a_i1) : (a_i1 - a_i0);
wire  [4:0] a_d0     = a_sp ? ({1'b0, a_pf0} - 5'd8) : (5'd8 - {1'b0, a_pf0});
wire  [4:0] a_d0s    = a_sq ? (5'd0 - a_d0) : a_d0;      // sign of the slope folded in
// Selected
wire        c_xm     = lo_aa ? a_xm : s_xm;
wire        c_sm     = lo_aa ? a_sp : (s_xm ? sdx[12] : sdy[12]);
wire        c_sn     = lo_aa ? a_sq : (s_xm ? sdy[12] : sdx[12]);
wire [12:0] c_nr     = lo_aa ? a_ni : s_dd;
wire        c_nz     = lo_nl & (c_nr == 13'd0);          // no step
wire [12:0] c_nm1    = lo_nl ? (c_nr - 13'd1) : c_nr;
// Box test (the pixel box; AA: 2 pixels more across the major axis), against
// the clip window: no pixel drawn when it misses
wire [13:0] bx_lo    = {sdx[12] ? la1[12] : la0[12], sdx[12] ? la1 : la0};
wire [13:0] bx_hi    = {sdx[12] ? la0[12] : la1[12], sdx[12] ? la0 : la1};
wire [13:0] by_lo    = {sdy[12] ? lb1[12] : lb0[12], sdy[12] ? lb1 : lb0};
wire [13:0] by_hi    = {sdy[12] ? lb0[12] : lb1[12], sdy[12] ? lb0 : lb1};
wire [13:0] bx_m     = (lo_aa & ~a_xm) ? 14'd2 : 14'd0;
wire [13:0] by_m     = (lo_aa &  a_xm) ? 14'd2 : 14'd0;
wire [13:0] lc_x0    = {{2{clip_i[35]}}, clip_i[35:24]};
wire [13:0] lc_y0    = {{2{clip_i[47]}}, clip_i[47:36]};
wire [13:0] lc_x1    = {{2{clip_i[11]}}, clip_i[11:0]};
wire [13:0] lc_y1    = {{2{clip_i[23]}}, clip_i[23:12]};
wire        c_rej    = ($signed(bx_hi + bx_m) < $signed(lc_x0)) | ($signed(bx_lo - bx_m) > $signed(lc_x1)) |
                       ($signed(by_hi + by_m) < $signed(lc_y0)) | ($signed(by_lo - by_m) > $signed(lc_y1));
// The phase: stream state (0 after ph_clr_i); this line starts at l_ps
wire  [4:0] ph_q;
wire        l_pr_busy;                                   // the phase remainder runs

wire        l_lat    = st_lat & ln_on;
wire        l_aa;
wire        l_xm;
wire        l_sm;
wire        l_sn;
wire        l_zp;                                        // AA: a point (|dP| = 0), slope 0
wire        l_adv;                                       // the phase advances (x/y mode, a step)
wire        l_empty;                                     // nothing drawn: address mode, no step, box missed
wire [12:0] l_nm1;
wire [12:0] l_p0;
wire [12:0] l_q0;
wire  [4:0] l_ps;
wire  [4:0] l_d0s;
wire [15:0] l_qm0;
wire [28:0] l_g;
wire [31:0] l_w;                                         // AA: {|dQ|, |dP|}, then T0; else 2d - D
// AA: the slope from the divider (S_LMUL: the quotient, 17 bits), its row
// start; the slope magnitude times d0 (signed) on the shared multiplier
wire [16:0] l_gm     = o_q[16:0] & {17{~l_zp}};
wire [17:0] l_gs     = l_sn ? (18'd0 - {1'b0, l_gm}) : {1'b0, l_gm};
wire [28:0] l_t0     = {l_qm0[15], l_qm0, 12'h000} + mul_s16u[28:0] - 29'h0008000;   // + floor(G d0 / 16)
assign      l_x18    = {{5{l_xm ? l_p0[12] : l_q0[12]}}, l_xm ? l_p0 : l_q0};
wire [17:0] l_y18    = {{5{l_xm ? l_q0[12] : l_p0[12]}}, l_xm ? l_q0 : l_p0};
assign      l_mul_a  = ({18{st_lmul}} & {1'b0, l_gm}) | ({18{st_ladr}} & l_y18);
assign      l_mul_b  = ({18{st_lmul}} & {{13{l_d0s[4]}}, l_d0s}) | ({18{st_ladr}} & {2'b00, dst_pitch_i});

// The division: |dQ| 2^16 / |dP|, |dQ| <= |dP|: the remainder starts with
// |dQ| / 2 (its first step compares |dQ| itself), zeros shifted in
assign      l_div_ld = st_ln1 & l_aa;
assign      o_b      = st_ldiv ? l_w[15:0] : {4'h0, grad_n};
assign      o_q0     = l_div_ld ? {l_w[16], 17'h00000} : {g_off[DV_W-1:0], {(18-DV_W){1'b0}}};
assign      o_r0     = l_div_ld ? {3'b000, l_w[31:17]} : 18'h00000;
wire        l_dlast  = (d_cnt == 5'd16);

generate
    if (LINE_USE) begin : g_line
        arv_ipdff #(.WIDTH(5 + 2*13 + 5), .ARST_EN(ASYNC_RST_EN)) u_lgeo (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_lat),
             .d_i({c_xm, c_sm, c_sn, xy_on & ~c_nz, ~xy_on | c_nz | c_rej,
                   c_nm1, c_xm ? la0 : lb0, lo_phr ? 5'd0 : ph_q}),
             .q_o({l_xm, l_sm, l_sn, l_adv, l_empty, l_nm1, l_p0, l_ps}));
        if (AA_USE) begin : g_line_aa
            arv_ipdff #(.WIDTH(2 + 5 + 16), .ARST_EN(ASYNC_RST_EN)) u_laa (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_lat),
                 .d_i({lo_aa, lo_aa & (a_p == 16'h0000), a_d0s, a_qm0}), .q_o({l_aa, l_zp, l_d0s, l_qm0}));
            arv_ipdff #(.WIDTH(13), .ARST_EN(ASYNC_RST_EN)) u_lq0 (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_lat | st_lmul),
                 .d_i(st_lmul ? l_t0[28:16] : (c_xm ? lb0 : la0)), .q_o(l_q0));
            // (bit 28: a copy of bit 27 in both loads, not kept)
            wire [27:0] l_g28;
            arv_ipdff #(.WIDTH(28), .ARST_EN(ASYNC_RST_EN)) u_lg (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_lat | st_lmul),
                 .d_i(st_lmul ? {{10{l_gs[17]}}, l_gs} : {s_eb, s_ea}), .q_o(l_g28));
            assign l_g = {l_g28[27], l_g28};
            // Priority: the start (S_IDLE) / S_LAT / S_LMUL, exclusive
            arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_lw (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_pen_ld | l_lat | st_lmul),
                 .d_i(l_pen_ld ? line_p1_i : st_lmul ? {{3{l_t0[28]}}, l_t0} : lo_aa ? {a_q, a_p} : {{18{s_f0[13]}}, s_f0}),
                 .q_o(l_w));
            assign l_pen0 = l_w;
        end else begin : g_line_solid
            // Solid lines only: no slope, no row start; 2d - D in 14 bits;
            // the start's pixel parts held in l_g (its fractions unused)
            wire [13:0] lf0;
            arv_ipdff #(.WIDTH(13), .ARST_EN(ASYNC_RST_EN)) u_lq0 (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_lat),
                 .d_i(c_xm ? lb0 : la0), .q_o(l_q0));
            // (bit 28: a copy of bit 27 in both loads, not kept)
            wire [27:0] l_g28;
            arv_ipdff #(.WIDTH(28), .ARST_EN(ASYNC_RST_EN)) u_lg (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_pen_ld | l_lat),
                 .d_i(l_pen_ld ? {4'd0, line_p1_i[31:20], line_p1_i[15:4]} : {s_eb, s_ea}), .q_o(l_g28));
            assign l_g = {l_g28[27], l_g28};
            arv_ipdff #(.WIDTH(14), .ARST_EN(ASYNC_RST_EN)) u_lf0 (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l_lat), .d_i(s_f0), .q_o(lf0));
            assign l_aa   = 1'b0;
            assign l_zp   = 1'b0;
            assign l_d0s  = 5'd0;
            assign l_qm0  = 16'h0000;
            assign l_w    = {{18{lf0[13]}}, lf0};
            assign l_pen0 = {l_g[23:12], 4'h0, l_g[11:0], 4'h0};
            wire [99:0] aa_unused = {a_p, a_q, a_qm0, a_d0s, l_gs, l_t0};   // no AA without blending
        end

        // Phase: (l_ps + steps) mod LEN, loaded in S_LN1, two quotient bits a
        // step (7 steps, a 14-bit dividend), written unless a ph_clr_i or an
        // abort came since the line's start (the phase then stays 0)
        wire  [5:0] pr_len  = {1'b0, line_len_i} + 6'd1;
        wire [12:0] pr_n    = l_adv ? (l_nm1 + 13'd1) : 13'd0;
        wire [12:0] pr_dvd  = {8'h00, l_ps} + pr_n;
        wire  [4:0] pr_r;
        wire [13:0] pr_d;
        wire  [2:0] pr_c;
        wire        pr_b;
        wire        ph_live;
        wire  [5:0] pr_s1   = {pr_r, pr_d[13]};
        wire  [5:0] pr_1    = (pr_s1 >= pr_len) ? (pr_s1 - pr_len) : pr_s1;
        wire  [5:0] pr_s2   = {pr_1[4:0], pr_d[12]};
        wire  [5:0] pr_2    = (pr_s2 >= pr_len) ? (pr_s2 - pr_len) : pr_s2;
        wire        pr_last = pr_b & (pr_c == 3'd6);
        // Priority: abort > load > step
        wire        pr_b_nxt = ~abort_i & (st_ln1 | (pr_b & ~pr_last));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_pr_b (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(pr_b_nxt), .q_o(pr_b));
        wire [21:0] pr_nxt   = st_ln1 ? {5'd0, {1'b0, pr_dvd}, 3'd0} : {pr_2[4:0], pr_d[11:0], 2'b00, pr_c + 3'd1};
        arv_ipdff #(.WIDTH(22), .ARST_EN(ASYNC_RST_EN)) u_pr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_ln1 | pr_b),
             .d_i(pr_nxt), .q_o({pr_r, pr_d, pr_c}));
        // Priority: ph_clr_i / abort > the line's start (live) > its write
        wire        live_nxt = ~ph_clr_i & ~abort_i & ((go_in & ln_on) | (ph_live & ~pr_last));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_ph_live (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(live_nxt), .q_o(ph_live));
        arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_ph (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ph_clr_i | (pr_last & ph_live)),
             .d_i(ph_clr_i ? 5'd0 : pr_2[4:0]), .q_o(ph_q));
        assign l_pr_busy = pr_b;
        wire [1:0] pr_unused = {pr_1[5], pr_2[5]};             // < LEN <= 32
    end else begin : g_no_line
        assign l_aa    = 1'b0;
        assign l_xm    = 1'b0;
        assign l_sm    = 1'b0;
        assign l_sn    = 1'b0;
        assign l_zp    = 1'b0;
        assign l_adv   = 1'b0;
        assign l_empty = 1'b1;
        assign l_nm1   = 13'd0;
        assign l_p0    = 13'd0;
        assign l_q0    = 13'd0;
        assign l_ps    = 5'd0;
        assign l_d0s   = 5'd0;
        assign l_qm0   = 16'h0000;
        assign l_g     = 29'd0;
        assign l_w     = 32'd0;
        assign ph_q    = 5'd0;
        assign l_pr_busy = 1'b0;
        assign l_pen0  = 32'h00000000;
        wire [208:0] lu_unused = {line_i, ph_clr_i, line_16_i, line_len_i, lo_phr, s_ea, s_eb, s_f0, a_p, a_q, a_qm0,
                                  a_d0s, c_xm, c_sm, c_sn, c_nz, c_nm1, c_rej, ph_q, l_lat, l_adv, l_gs, l_t0,
                                  line_p1_i, l_pen_ld};   // GPU_LINE_EN = 0
    end
endgenerate

//=============================================================================
// 8)  SEQUENCE
//=============================================================================
wire       need_src = trim_on & (is_copy | is_exp) & ((col_q != 18'd0) | (row_q != 18'd0));
wire       need_uv  = (trim_on & is_tex & ((col_q != 18'd0) | (row_q != 18'd0))) | tex_tri;
wire       need_ur  = need_uv & is_trect;
wire       need_g   = trim_on & grad_on & (g_off != 18'd0);

// A triangle: its edges (nothing to draw: complete), then its (u, v)
wire       eng_take  = eng_idle_i & ~freeze_i;
wire       empty_b   = empty_q | (tri_i & ~tri_go);
wire [4:0] after_tri = tri_degen ? S_EMPTY :
                       need_uv   ? S_UC    : S_GO;
wire [4:0] after_box = empty_b  ? (eng_take ? S_IDLE : S_EMPTY) :
                       tri_go   ? S_TRI  :
                       need_src ? S_SRC  :
                       need_uv  ? S_UC   :
                       need_g   ? S_DIV  : S_GO;
wire [4:0] after_vc  = need_ur  ? S_UR   :
                       need_g   ? S_DIV  : S_GO;
wire [4:0] after_vr  = need_g   ? S_DIV  : S_GO;
wire [4:0] after_src = need_g   ? S_DIV  : S_GO;
// A line: the phase remainder (S_LN1 on), the slope (AA), the start address;
// it completes once the phase is written
wire [4:0] after_ln1 = l_empty  ? S_LPH  :
                       l_aa     ? S_LDIV : S_LADR;
wire [4:0] after_lph = l_empty  ? S_EMPTY : S_GO;

// Priority: abort > start > the sequence
wire       state_en  = abort_i | go_in | ~st_idle;
wire [4:0] state_nxt = abort_i             ? S_IDLE :
                       go_in               ? S_LAT  :
                       (st_lat & ln_on)    ? S_LN1  :
                       st_ln1              ? after_ln1 :
                       (st_ldiv & ~l_dlast) ? S_LDIV :
                       st_ldiv             ? S_LMUL :
                       st_lmul             ? S_LADR :
                       st_ladr             ? S_LPH  :
                       (st_lph & l_pr_busy) ? S_LPH :
                       st_lph              ? after_lph :
                       (st_lat & box_on)   ? S_LY   :
                       (st_lat | st_ly)    ? S_BOX  :
                       st_box              ? after_box :
                       (st_tri & tri_busy) ? S_TRI  :
                       st_tri              ? after_tri :
                       st_src              ? after_src :
                       st_uc               ? S_VC   :
                       st_vc               ? after_vc  :
                       st_ur               ? S_VR   :
                       st_vr               ? after_vr  :
                       (st_div & ~div_last) ? S_DIV  :
                       st_div              ? S_GV   :
                       (st_gv & grad_rgb)  ? S_GG   :
                       st_gg               ? S_GB   :
                       (st_gv | st_gb)     ? S_GO   :
                       (st_go    & ~eng_take) ? S_GO    :
                       (st_empty & ~eng_take) ? S_EMPTY :
                                             S_IDLE;

arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_state (                     // resets to S_IDLE (0)
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(state_en), .d_i(state_nxt), .q_o(state));

//=============================================================================
// 9)  OUTPUTS
//=============================================================================
assign go_o         = st_go & eng_take & ~abort_i;
assign empty_done_o = ((st_box & empty_b) | st_empty) & eng_take & ~abort_i;
assign busy_o       = ~st_idle;
assign dst_base_o   = dst_q;
assign src_base_o   = src_q;
assign src_past_o   = src_past;
assign msk_k_o      = k_q;
assign src_pitch_o  = spitch_q;
assign width_o      = tw_q;
assign height_o     = th_q;
assign tex_u0_o     = u_q;
assign tex_v0_o     = v_q;
assign grad_cnt0_o  = gcnt_q;
assign grad_val0_o  = grad_rgb ? grgb_q : {26'h0000000, gval_q};
assign ln_aa_o      = l_aa;
assign ln_xmaj_o    = l_xm;
assign ln_smaj_o    = l_sm;
assign ln_smin_o    = l_sn;
assign ln_g_o       = l_g;
assign ln_e0_o      = l_w[28:0];
assign ln_p0_o      = l_p0;
assign ln_q0_o      = l_q0;
assign ln_nm1_o     = l_nm1;
assign ln_ph_o      = l_ps;

//=============================================================================
// 10) LINT CLEANUP
//=============================================================================
wire [17-DIM_W:0] tn_hi_unused  = a_tnc[17:DIM_W];       // DIM_W bits used
wire [31-PA_W:0]  dst_hi_unused = dst_xy[31:PA_W];        // PA_W bits used
wire [31-PA_W:0]  src_hi_unused = src_st[31:PA_W];
wire        [3:0] mul_hi_unused = mul_p[35:32];
wire        [5:0] grad_r_unused = d_rem[17:12];
wire        [3:0] fxy_unused    = {fx_q[17:16], fy_q[17:16]};
wire              line_unused   = line_opt_i[2];                 // OPAQUE: the engine's
wire        [1:0] aa_unused     = {line_opt_i[0], line_16_i};    // AA: GPU_BLEND_EN = 0 (no AA lines)
wire        [2:0] feat_unused   = {xy_mode_i, grad_i[17], is_fillk};   // GPU_XY_EN / GPU_GRAD_EN = 0
wire        [7:0] tri_ext_unused = {amn_p7[3:0], amx_m8[3:0]};   // pixel units only
wire      [173:0] cand_unused   = {g_ll[16:0], g_lc[16:0], g_cl[16:0], g_cc[16:0], o_ll[17:0], o_lc[17:0],
                                   o_cl[17:0], o_cc[17:0], x_lo[16:0], x_hi[16:0]};   // the signs only
wire       [14:0] mul_t_unused  = mul_s16u[35:21];               // u, v are 21 bits
wire  [17-DV_W:0] g_off_unused  = g_off[17:DV_W];                // the offset < 2^DV_W
wire        [5:0] a_f_unused    = a_f[17:12];                    // a box's first pixel: in the clip window
wire [2*(18-OFF_W)-1:0] off_unused = {col_off[17:OFF_W], row_off[17:OFF_W]};   // < 2^DIM_W, a triangle's 17-bit signed
generate
    if (MA_W < 18) begin : g_ma_hi
        wire [17-MA_W:0] mul_a_unused = mul_a[17:MA_W];          // sign copies
    end
    if (MB_W < 18) begin : g_mb_hi
        wire [17-MB_W:0] mul_b_unused = mul_b[17:MB_W];          // sign copies
    end
endgenerate

endmodule // blns_gpu_setup

`default_nettype wire
