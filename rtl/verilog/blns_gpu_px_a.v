//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_px_a
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_px_a.v
// Module Description : GPU pixel engine, stage A (address generation): one
//                      token per cycle from the walk (destination and source
//                      walkers, texture (u, v), triangle scan lines,
//                      gradient), with its destination word / bit, its source
//                      word / bit and a skip flag (outside the triangle, texel
//                      outside BOUND); a FILL along rows takes every pixel of
//                      its run in the destination word at once (no CL swap,
//                      gradient along the run or blending), a COPY every
//                      pixel of its run in its destination word and its
//                      source word (word-token COPY: no CL swap, not
//                      blended; one pixel when its source word is its
//                      destination word and the source trails the
//                      destination along the walk or runs the other way, so
//                      the image stays the one of a pixel-by-pixel copy),
//                      with the rotation that brings its source pixels to
//                      their destination slots (and whether their order is
//                      then reversed: a mirror, X swaps differing). With the
//                      mask plane, a copy token also stops at the end of its
//                      mask word and carries that word and its rotation; a
//                      palette remap takes one pixel per token. An RGB565A8
//                      source (blending, 16 bpp): one pixel per token, with
//                      the word and byte of its alpha (source + K, at 8 bpp)
//                      in the mask fields. Bilinear sampling (BIL_USE, 16
//                      bpp): the walk starts half a texel back, and each
//                      pixel takes 1 to 4 tokens, one per tap of weight
//                      not 0 (and, with BOUND and TBORDER, inside the box),
//                      with the tap's weight, its texel row's parity (the
//                      tap cache index) and the last tap's destination; the
//                      tap addresses are the pixel's texel plus offsets
//                      registered with it (dx, dy: +1 / +pitch, the wrap,
//                      or 0 for a clamp). A line:
//                      one pixel per token along the Bresenham walk, or
//                      (AA) two per step, rows r and r + 1 with their
//                      coverage; a pixel outside the clip window, in a gap
//                      of the pattern (not OPAQUE) or of coverage 0 is
//                      skipped, the walk ends past the window's far bound.
//                      The token waits in the A -> F register until F takes it.
//                      Also here: the colour depth latched at the start, the
//                      operation decoded for F and W, and the token A offers
//                      next (with RD_REG_EN the word after it) for the read
//                      ahead. The sequence (start, run, drain, abort) is in
//                      blns_gpu_px_fw.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_px_a #(
    parameter                    GPU_XY_EN     = 1,   // x/y destinations and clip
    parameter                    GPU_GRAD_EN   = 1,   // gradient fill
    parameter                    GPU_BLEND_EN  = 0,   // alpha blending at 16 bpp
    parameter              [0:0] TRI_USE       = 1'b0, // triangles built (blns_gpu: GPU_TRI_EN & GPU_XY_EN)
    parameter                    GPU_REMAP_EN  = 1,   // palette remap
    parameter                    GPU_MPLANE_EN = 1,   // mask plane on copies
    parameter                    GPU_IMM_EN    = 1,   // immediate source
    parameter              [0:0] LINE_USE      = 1'b0, // lines built (blns_gpu: GPU_LINE_EN & GPU_XY_EN)
    parameter              [0:0] BIL_USE       = 1'b0, // bilinear built (blns_gpu: GPU_BILINEAR_EN & GPU_XY_EN)
    parameter                    RUNAHEAD_EN   = 0,   // inputs from the run-ahead copy (blns_gpu): src_base_i read at the start only
    parameter                    RD_REG_EN     = 0,   // read data two cycles or more after the grant: the word after the next token's (nw_*)
    parameter                    FILL_PIPE     = 1,   // the fill colour varies per token (gradient, line gaps); 0: t1_fill_o = fill_i
    parameter                    VRAM_AW       = 16,  // VRAM word-address width
    parameter                    PA_W          = 21,  // pixel-address width (VRAM_AW + 5)
    parameter                    DIM_W         = 10,  // width/height field width
    parameter                    ASYNC_RST_EN  = 1'b1 // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  abort_i,             // abandon the rectangle
    input  wire                  freeze_i,            // hold between pixels
    input  wire            [2:0] gfx_mode_i,          // CTRL.GFX_MODE
    input  wire    [DIM_W-1:0]   disp_width_i,        // display width (default pitch)

// SEQUENCE (blns_gpu_px_fw)
    input  wire                  go_i,                // the rectangle starts
    input  wire                  a_init_i,            // walkers loaded
    input  wire                  a_run_i,             // one token per cycle
    input  wire                  a_abort_i,           // dropped: flush the buffer
    output wire                  a_last_emit_o,       // the last token leaves A

// RECTANGLE CONFIGURATION (stable while busy_o; dst_base_i, tex_u0_i and
// tex_v0_i read only as the walkers are loaded, the cycle after the start)
    input  wire            [2:0] kind_i,              // 0 = FILL, 1 = COPY, 2 = COPY_TRANSP, 3 = EXPAND, 4 = TEXSPAN, 5 = TEXRECT
    input  wire                  imm_i,               // immediate source (its words are not in the VRAM: no overlap)
    input  wire            [1:0] exp_depth_i,         // EXPAND source depth: 0/1/2/3 = 1/2/4/8 bpp
    input  wire                  exp_mask_i,          // EXPAND: the source is a coverage alpha (16 bpp)
    input  wire                  alpha_en_i,          // SET_ALPHA EN
    input  wire                  a8_i,                // RGB565A8 source (a copy or a texture)
    input  wire            [1:0] tex_filt_i,          // TEX_FILTER {TBORDER, BILINEAR}
    input  wire                  tri_i,               // FILL of the triangle (box: dst_base, width, height)
    input  wire [3*(49+2*DIM_W)-1:0] tri_e_i,         // triangle edges (blns_gpu_tri_setup)
    input  wire          [3*36-1:0] tri_s_i,         // their bounds at the first row, taken at the start
    input  wire           [21:0] tex_cfg_i,           // {SHADE, BOUND, FREE_PITCH, swaps, TRANSP_EN, log2 h, log2 w}
    input  wire           [20:0] tex_u0_i,            // u of the first pixel (10.11), at the walk load
    input  wire           [20:0] tex_v0_i,            // v of the first pixel (10.11), at the walk load
    input  wire           [31:0] tex_step_i,          // {du, dv}, signed 5.11
    input  wire           [31:0] tex_rstep_i,         // TEXRECT {du', dv'} per row, signed 5.11
    input  wire           [23:0] tex_box_i,           // BOUND texture box {TH, TW}, each clamped to 512 by blns_gpu
    input  wire           [48:0] grad_i,              // FILL gradient {RGB, dR, dG, dB, EN, STEP, AXIS, N}
    input  wire           [11:0] grad_cnt0_i,         // gradient counter at a walk / run start
    input  wire           [41:0] grad_val0_i,         // gradient value at a walk / run start (RGB: R, G, B)
    input  wire            [3:0] px_op_i,             // raster operation
    input  wire            [2:0] dst_swap_i,          // {X, Y, CL}
    input  wire            [2:0] src_swap_i,          // {X, Y, CL}
    input  wire     [PA_W-1:0]   src_base_i,          // source first pixel
    input  wire                  src_past_i,          // ... an immediate source index past 2^PA_W (read with src_base_i)
    input  wire           [15:0] src_pitch_i,         // source pitch (resolved by the set-up)
    input  wire     [PA_W-1:0]   dst_base_i,          // destination first pixel, at the walk load
    input  wire           [15:0] dst_pitch_i,         // 0 = display width
    input  wire    [DIM_W-1:0]   width_i,             // pixels per run (>= 1)
    input  wire    [DIM_W-1:0]   height_i,            // runs (>= 1)
    input  wire           [15:0] fill_i,              // fill colour
    input  wire            [1:0] rmp_mode_i,          // remap: 0 off, 1 SRC, 2 DST
    input  wire                  mpl_i,               // mask plane (a copy only)
    input  wire     [PA_W-1:0]   msk_k_i,             // mask pixel - source pixel (RGB565A8: alpha byte - source pixel)
    input  wire           [15:0] transp_i,            // transparent colour (a line's OPAQUE gaps)
    input  wire                  ln_i,                // a line (a FILL kind)
    input  wire                  ln_aa_i,             // ... anti-aliased
    input  wire                  ln_opq_i,            // ... OPAQUE: gaps drawn in transp_i
    input  wire                  ln_xmaj_i,           // ... x is the major axis
    input  wire                  ln_smaj_i,           // ... the major coordinate decreases
    input  wire                  ln_smin_i,           // ... the minor coordinate decreases (AA: negative slope)
    input  wire           [28:0] ln_g_i,              // ... {2d - 2D, 2d} (AA: the slope)
    input  wire           [47:0] ln_clip_i,           // ... clip window {y0, x0, y1, x1}
    input  wire           [31:0] ln_pat_i,            // ... pattern
    input  wire            [4:0] ln_len_i,            // ... its length - 1
    input  wire           [28:0] ln_e0_i,             // ... first error term (AA: row position), at the walk load
    input  wire           [12:0] ln_p0_i,             // ... first major coordinate, at the walk load
    input  wire           [12:0] ln_q0_i,             // ... first minor coordinate, at the walk load
    input  wire           [12:0] ln_nm1_i,            // ... steps - 1, at the walk load
    input  wire            [4:0] ln_ph_i,             // ... first pattern phase, at the walk load

// OPERATION (for F and W)
    output wire            [4:0] bpp_o,               // one-hot {16, 8, 4, 2, 1} bpp
    output wire            [4:0] src_bpp_o,           // source depth, one-hot
    output wire                  is_copy_o,           // not FILL
    output wire                  is_tex_o,            // TEXSPAN or TEXRECT
    output wire                  is_exp_o,            // EXPAND
    output wire                  mask_on_o,           // EXPAND coverage alpha, blended
    output wire                  blend_on_o,          // alpha blending
    output wire            [3:0] px_op_o,             // raster operation (0 when blending)
    output wire            [1:0] blk_op_o,            // blended constant: 0 none, ops 13/14/15 = 1/2/3 (S = 0 / ones / fill)
    output wire                  op_no_d_o,           // the operation reads no destination
    output wire                  need_src_o,          // the source is read
    output wire                  need_dst_o,          // the destination is read
    output wire                  transp_chk_o,        // a source equal to SET_TRANSP is skipped
    output wire                  rmp_on_o,            // remap: each pixel's colour through the table
    output wire                  rmp_dst_o,           // ... the destination's (DST)
    output wire                  mp_on_o,             // mask plane: a pixel drawn where its mask bit allows
    output wire                  aa_on_o,             // AA line: each token's alpha is its coverage
    output wire                  a8_on_o,             // RGB565A8: each token's alpha is its A8 byte
    output wire                  bil_on_o,            // bilinear: a token per tap, its pixel on the last one

// A -> F TOKEN
    output wire                  t1_v_o,              // valid
    output wire    [VRAM_AW:0]   t1_dwa_o,            // destination word (+ past 2^VRAM_AW)
    output wire            [4:0] t1_dboff_o,          // bit offset of its lowest pixel
    output wire            [5:0] t1_nbits_o,          // bits written
    output wire    [VRAM_AW:0]   t1_swa_o,            // source word (+ past 2^VRAM_AW)
    output wire            [4:0] t1_rot_o,            // source word rotation (right): the source bit offset of a one-pixel token
    output wire                  t1_word_o,           // word token: the rotated source word sits at the destination slots
    output wire                  t1_mir_o,            // ... once its pixel order is reversed (a mirror)
    output wire                  t1_skip_o,           // nothing drawn (triangle, BOUND)
    output wire           [15:0] t1_fill_o,           // fill colour (gradient applied)
    output wire  [VRAM_AW-1:0]   t1_mwa_o,            // mask word (RGB565A8: the A8 word)
    output wire                  t1_mhi_o,            // ... an A8 word past 2^VRAM_AW
    output wire            [4:0] t1_mrot_o,           // mask word rotation (right): its bits at the destination slots
                                                      // (RGB565A8: [1:0] the A8 byte)
    output wire            [7:0] t1_cov_o,            // AA line: coverage
    output wire           [10:0] t1_k_o,              // bilinear: the tap's weight (0 .. 1024)
    output wire                  t1_tlast_o,          // ... the pixel's last tap (its destination)
    output wire                  t1_ypar_o,           // ... the parity of the tap's texel row
    input  wire                  f_take_i,            // F takes the token

// NEXT TOKEN (read ahead by blns_gpu_px_fw)
    output wire                  nx_on_o,             // A has a token to offer when running
    output wire                  nx_skip_o,           // nothing drawn for it
    output wire    [VRAM_AW:0]   nx_dwa_o,            // its destination word
    output wire    [VRAM_AW:0]   nx_swa_o,            // its source word
    output wire                  nw_ok_o,             // the word after it may be read ahead
    output wire    [VRAM_AW:0]   nw_wa_o,             // ... that word
    output wire  [VRAM_AW-1:0]   nx_mwa_o,            // its A8 word (RGB565A8)
    output wire                  nx_mhi_o             // ... past 2^VRAM_AW
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================
localparam AFFINE_USE = (GPU_XY_EN     != 0);   // affine blits come with x/y
localparam GRAD_USE   = (GPU_GRAD_EN   != 0);
localparam BLEND_USE  = (GPU_BLEND_EN  != 0);
localparam RA_USE     = (RUNAHEAD_EN   != 0);
localparam REMAP_USE  = (GPU_REMAP_EN  != 0);
localparam MPLANE_USE = (GPU_MPLANE_EN != 0);
localparam IMM_USE    = (GPU_IMM_EN    != 0);
localparam WA_W       = VRAM_AW + 1;                   // word address + "past 2^VRAM_AW" bit

localparam [DIM_W-1:0] DIM_ONE = {{(DIM_W-1){1'b0}}, 1'b1};

// Sequence (blns_gpu_px_fw)
wire       go      = go_i;
wire       a_init  = a_init_i;
wire       a_run   = a_run_i;
wire       a_abort = a_abort_i;

//=============================================================================
// 2)  LATCHED AT START: COLOUR DEPTH AND DISPLAY WIDTH
//=============================================================================
wire       [4:0] bpp;                                 // one-hot {16, 8, 4, 2, 1} bpp
wire       [4:0] bpp_nxt = {gfx_mode_i[2], (gfx_mode_i == 3'd3), (gfx_mode_i == 3'd2),
                            (gfx_mode_i == 3'd1), (gfx_mode_i == 3'd0)};
wire [DIM_W-1:0] disp_w;

arv_ipdff #(.WIDTH(5), .RST_VAL(5'b00001), .ARST_EN(ASYNC_RST_EN)) u_bpp (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(go), .d_i(bpp_nxt), .q_o(bpp));
arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_disp_w (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(go), .d_i(disp_width_i), .q_o(disp_w));

wire             bpp_lt8 = bpp[0] | bpp[1] | bpp[2];

//=============================================================================
// 3)  KIND AND ACCESS REQUIREMENTS
//=============================================================================
wire       is_copy    = |kind_i;
wire       is_tex     = kind_i[2];                          // TEXSPAN or TEXRECT
wire       is_trect   = AFFINE_USE & kind_i[2] & kind_i[0];
wire       is_fillk   = (kind_i == 3'd0);
wire       is_exp     = ~kind_i[2] &  kind_i[1] &  kind_i[0];
wire       is_copyt   = ~kind_i[2] &  kind_i[1] & ~kind_i[0];
// Blending (16 bpp): constant alpha, or an EXPAND coverage mask; it reads the
// destination and uses raster op S. Ops 13-15 keep their constant as the
// blend source (blk_op: 0, ones, the fill colour) and their transparency
wire       ln_on      = LINE_USE & ln_i;
wire       aa_on      = BLEND_USE & LINE_USE & bpp[4] & ln_i & ln_aa_i;   // coverage alpha, as MASK
wire       mask_on    = (BLEND_USE & bpp[4] & is_exp & exp_mask_i) | aa_on;
// RGB565A8 (16 bpp; the palette modes copy as SRC_FMT 0): each pixel's alpha
// from the A8 plane; bilinear sampling (section 5c) blends each pixel with its
// taps' alpha
wire       a8_on      = BLEND_USE & bpp[4] & a8_i;
wire       bil_on;                                         // section 5c
wire       blend_on   = BLEND_USE & bpp[4] & (alpha_en_i | mask_on | a8_on | bil_on);
wire [3:0] px_op      = blend_on ? 4'd0 : px_op_i;
wire       op_hi_i    = (px_op_i == 4'd13) | (px_op_i == 4'd14) | (px_op_i == 4'd15);
wire [1:0] blk_op     = {2{blend_on & op_hi_i}} & px_op_i[1:0];

wire       op_hi      = (px_op == 4'd13) | (px_op == 4'd14) | (px_op == 4'd15);
wire       op_no_d    = (px_op == 4'd0)  | (px_op == 4'd1)  | op_hi;
// Op 2 (~D) reads no source, but a transparent copy and EXPAND (value 0) need
// it for their transparency
wire       need_src   = is_copy & ((px_op != 4'd2) | is_copyt | is_exp);
// Remap (palette depths): the colour the operation takes as S goes through the
// table, the source's (SRC) or the destination pixel's (DST, which then reads
// D); ops without S (2, 13-15) make no lookup
wire       rmp_on     = REMAP_USE & (rmp_mode_i != 2'd0) & ~bpp[4] & ~blend_on & (px_op != 4'd2) & ~op_hi;
wire       rmp_dst    = rmp_on & rmp_mode_i[1];
// Mask plane: COPY and COPY_TRANSP
wire       mp_on      = MPLANE_USE & mpl_i & ~kind_i[2] & (kind_i[1] ^ kind_i[0]);
wire       need_dst   = bpp_lt8 | ~op_no_d | blend_on | rmp_dst;
// Ops 13-15 skip a source pixel equal to SET_TRANSP, blended or not; EXPAND
// has its own transparency (value 0), so its ops 13-15 write 0, ones or the
// fill colour
wire       transp_chk = is_copyt | (op_hi_i & ~is_exp);

//=============================================================================
// 4)  A: WALK COUNTERS
//=============================================================================
wire             a_emit;                               // a token leaves A this cycle
wire             t1_free;                              // the A -> F register takes a token (section 6)
wire       [5:0] a_n;                                  // pixels in the token (section 5)
wire [DIM_W-1:0] col;
wire [DIM_W-1:0] row;
wire [DIM_W-1:0] a_rem;                                // pixels left in the run
wire      [31:0] a_rem32   = {{(32-DIM_W){1'b0}}, a_rem};
wire      [31:0] a_n32     = {26'h0000000, a_n};
wire [DIM_W-1:0] a_n_dim   = a_n32[DIM_W-1:0];         // a_n <= a_rem
wire             line_done;                            // a_rem == a_n (section 5, beside the a_n select)
wire             last_line = (row == (height_i - DIM_ONE));
wire             a_last    = line_done & last_line;
wire             ln_last;                              // a line's last token (section 5b)

// Triangle row walk (below): a row's run starts at its first pixel
wire             t_on;
wire             tr_load;                              // a row's run starts (its first column, length)
wire             tr_rowend;                            // the row is done
wire [DIM_W-1:0] tr_col0;
wire [DIM_W-1:0] tr_len;

// Priority: init > a triangle row start > token
wire             col_en    = a_init | tr_load | a_emit;
wire [DIM_W-1:0] col_nxt   = a_init ? {DIM_W{1'b0}} : tr_load ? tr_col0 :
                             line_done ? {DIM_W{1'b0}} : (col + a_n_dim);
wire             row_en    = a_init | (t_on ? tr_rowend : (a_emit & line_done));
wire [DIM_W-1:0] row_nxt   = a_init ? {DIM_W{1'b0}} : (row + DIM_ONE);
wire             rem_en    = a_init | tr_load | a_emit;
wire [DIM_W-1:0] rem_nxt   = (a_init | (a_emit & line_done)) ? width_i : tr_load ? tr_len : (a_rem - a_n_dim);

arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_col (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(col_en), .d_i(col_nxt), .q_o(col));
arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_row (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(row_en), .d_i(row_nxt), .q_o(row));
arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_a_rem (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rem_en), .d_i(rem_nxt), .q_o(a_rem));

//-----------------------------------------------------------------------------
// Triangle: scan lines over the box (set up by blns_gpu_tri_setup). Edge k
// bounds the rows FIRST..LAST: a rising edge the row's last pixel x, a falling
// one its first pixel -x (box-relative); x steps by SQ (+1 when the remainder,
// stepped by SR, reaches B) after each of those rows. A horizontal edge
// removes one row. Each row: one cycle for its bounds (and the steps), two
// more for a textured row's (u, v) at its first pixel, then a run of its
// pixels, whole destination words at a time for a FILL. With a gradient along
// the run, every pixel of the box row is walked (the gradient counts from the
// box's first column) and the pixels outside are skipped.
//-----------------------------------------------------------------------------
localparam       TEW      = 49 + 2*DIM_W;              // bits per edge
localparam [1:0] TR_ROW   = 2'd0;                      // row bounds
localparam [1:0] TR_U     = 2'd1;                      // textured: u at the first pixel
localparam [1:0] TR_V     = 2'd2;                      // textured: v
localparam [1:0] TR_RUN   = 2'd3;                      // the row's tokens

assign           t_on     = TRI_USE & tri_i;
wire             t_box    = t_on & GRAD_USE & grad_i[17] & grad_i[12] & is_fillk;  // gradient along the run
wire       [1:0] tr_st;
wire             tr_row   = (tr_st == TR_ROW);
wire             tr_run   = (tr_st == TR_RUN);
wire             tr_adv   = a_run & ~freeze_i;

wire [TEW-1:0]   te0      = tri_e_i[TEW-1:0];
wire [TEW-1:0]   te1      = tri_e_i[2*TEW-1:TEW];
wire [TEW-1:0]   te2      = tri_e_i[3*TEW-1:2*TEW];
wire      [15:0] tx0;
wire      [15:0] tx1;
wire      [15:0] tx2;
wire      [19:0] tr0;
wire      [19:0] tr1;
wire      [19:0] tr2;

// Edge k active on this row; its bound (17-bit signed, box-relative)
function act_f;
    input [TEW-1:0]   e;
    input [DIM_W-1:0] r;
    begin act_f = (e[TEW-1] ^ e[TEW-2]) & (r >= e[2*DIM_W-1:DIM_W]) & (r <= e[DIM_W-1:0]); end
endfunction
wire             ta0      = act_f(te0, row);
wire             ta1      = act_f(te1, row);
wire             ta2      = act_f(te2, row);
wire             tl0      = ~te0[TEW-1];                // left (falling) when active
wire             tl1      = ~te1[TEW-1];
wire             tl2      = ~te2[TEW-1];
wire             tdrop    = ((te0[TEW-1 -: 2] == 2'd3) & (te0[2*DIM_W-1:DIM_W] == row)) |
                            ((te1[TEW-1 -: 2] == 2'd3) & (te1[2*DIM_W-1:DIM_W] == row)) |
                            ((te2[TEW-1 -: 2] == 2'd3) & (te2[2*DIM_W-1:DIM_W] == row));
wire      [16:0] tw_m1    = {{(17-DIM_W){1'b0}}, width_i} - 17'd1;
wire      [16:0] tb0      = tl0 ? (17'd0 - {tx0[15], tx0}) : {tx0[15], tx0};
wire      [16:0] tb1      = tl1 ? (17'd0 - {tx1[15], tx1}) : {tx1[15], tx1};
wire      [16:0] tb2      = tl2 ? (17'd0 - {tx2[15], tx2}) : {tx2[15], tx2};
// first pixel = max(0, left bounds), last = min(width - 1, right bounds)
wire             tc0      = ta0 & tl0 & ($signed(tb0) > 17'sd0);
wire      [16:0] tlo0     = tc0 ? tb0 : 17'd0;
wire             tc1      = ta1 & tl1 & ($signed(tb1) > $signed(tlo0));
wire      [16:0] tlo1     = tc1 ? tb1 : tlo0;
wire             tc2      = ta2 & tl2 & ($signed(tb2) > $signed(tlo1));
wire      [16:0] t_xl     = tc2 ? tb2 : tlo1;
wire      [16:0] thi0     = (ta0 & ~tl0 & ($signed(tb0) < $signed(tw_m1))) ? tb0 : tw_m1;
wire      [16:0] thi1     = (ta1 & ~tl1 & ($signed(tb1) < $signed(thi0))) ? tb1 : thi0;
wire      [16:0] t_xr     = (ta2 & ~tl2 & ($signed(tb2) < $signed(thi1))) ? tb2 : thi1;
wire             t_empty  = tdrop | ($signed(t_xl) > $signed(t_xr));
wire      [16:0] t_n      = t_xr - t_xl + 17'd1;

// The row: a run of its pixels, or (gradient along the run, or nothing to
// draw ... with the gradient) the whole box row; an empty row takes one cycle
wire             tr_go    = t_on & tr_row & tr_adv;
assign           tr_load  = tr_go & (t_box | ~t_empty);
assign           tr_col0  = t_box ? {DIM_W{1'b0}} : t_xl[DIM_W-1:0];
assign           tr_len   = t_box ? width_i : t_n[DIM_W-1:0];
wire             tr_tex   = is_tex;
assign           tr_rowend = (tr_go & ~t_box & t_empty) | (t_on & tr_run & a_emit & line_done);
wire             tr_fin   = tr_rowend & last_line;

// Priority: start > row start > (u, v) > row end
wire       [1:0] tr_st_nxt = a_init  ? TR_ROW :
                             tr_load ? (tr_tex ? TR_U : TR_RUN) :
                             (tr_st == TR_U) ? TR_V :
                             (tr_st == TR_V) ? TR_RUN : TR_ROW;
wire             tr_st_en  = a_init | tr_load | (t_on & tr_adv & ((tr_st == TR_U) | (tr_st == TR_V))) | tr_rowend;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_tr_st (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tr_st_en), .d_i(tr_st_nxt), .q_o(tr_st));

// Gradient along the run: pixels outside the row's bounds are skipped
wire [DIM_W-1:0] tr_xl;
wire [DIM_W-1:0] tr_xr;
wire             tr_none;
arv_ipdff #(.WIDTH(2*DIM_W + 1), .ARST_EN(ASYNC_RST_EN)) u_tr_bnd (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tr_load),
             .d_i({t_xl[DIM_W-1:0], t_xr[DIM_W-1:0], t_empty}), .q_o({tr_xl, tr_xr, tr_none}));
wire             tri_out  = t_box & (tr_none | (col < tr_xl) | (col > tr_xr));

// Edge steps, after each active row: x += SQ + carry, r = (r + SR) mod B.
// Only active rows step: an edge bounding a single row has no valid SQ / SR.
// Fields: {kind[1:0], sq[14:0], sr / 16 [15:0], |dy| [15:0] (B = 16 |dy|), first, last}
function [35:0] step_f;                                 // {x, r}
    input [TEW-1:0] e;
    input    [15:0] x;
    input    [19:0] r;
    reg      [20:0] rs;
    reg             c;
    begin
        rs     = {1'b0, r} + {1'b0, e[TEW-18 -: 16], 4'h0};
        c      = (rs >= {1'b0, e[TEW-34 -: 16], 4'h0});
        step_f = {x + {e[TEW-3], e[TEW-3 -: 15]} + {15'h0000, c},
                  c ? (rs[19:0] - {e[TEW-34 -: 16], 4'h0}) : rs[19:0]};
    end
endfunction
wire      [35:0] ts0      = step_f(te0, tx0, tr0);
wire      [35:0] ts1      = step_f(te1, tx1, tr1);
wire      [35:0] ts2      = step_f(te2, tx2, tr2);
// Priority: start (the set-up's first-row values, taken as the engine starts,
// so the run-ahead copy does not hold them) > step
wire      [35:0] td0      = go ? tri_s_i[35:0]   : ts0;
wire      [35:0] td1      = go ? tri_s_i[71:36]  : ts1;
wire      [35:0] td2      = go ? tri_s_i[107:72] : ts2;
arv_ipdff #(.WIDTH(36), .ARST_EN(ASYNC_RST_EN)) u_te0 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(go | (tr_go & ta0)), .d_i(td0), .q_o({tx0, tr0}));
arv_ipdff #(.WIDTH(36), .ARST_EN(ASYNC_RST_EN)) u_te1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(go | (tr_go & ta1)), .d_i(td1), .q_o({tx1, tr1}));
arv_ipdff #(.WIDTH(36), .ARST_EN(ASYNC_RST_EN)) u_te2 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(go | (tr_go & ta2)), .d_i(td2), .q_o({tx2, tr2}));

//=============================================================================
// 5)  A: ADDRESS WALKERS
//=============================================================================
wire [31:0]     disp_w32    = {{(32-DIM_W){1'b0}}, disp_w};
wire [31:0]     src_str32   = (src_pitch_i == 16'h0000) ? disp_w32 : {16'h0000, src_pitch_i};
wire [31:0]     dst_str32   = (dst_pitch_i == 16'h0000) ? disp_w32 : {16'h0000, dst_pitch_i};
wire [PA_W-1:0] src_stride  = src_str32[PA_W-1:0];
wire [PA_W-1:0] dst_stride  = dst_str32[PA_W-1:0];

wire [PA_W-1:0] src_pa;
wire [PA_W-1:0] src_nl_pa;                              // first pixel of the source's next line
wire [PA_W-1:0] dst_pa_w;
wire [PA_W-1:0] dst_nl_pa;
// run-ahead: not a texture (its base, below); the mask follows the source walk
wire            src_step    = RA_USE ? (a_emit & (need_src | mp_on) & ~is_tex) : (a_emit & (need_src | mp_on));
wire            src_carry;                              // the source walk carries past 2^PA_W
wire            dst_carry;

blns_gpu_walk #(
    .PA_W         (PA_W),
    .ASYNC_RST_EN (ASYNC_RST_EN)
) u_walk_src (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .init_i       (a_init),
    .base_i       (src_base_i),
    .step_i       (src_step),
    .step_n_i     (a_n),                               // a source step: the token's pixels
    .line_done_i  (line_done),
    .stride_i     (src_stride),
    .cl_swap_i    (src_swap_i[0] & ~is_exp),
    .y_swap_i     (src_swap_i[1] & ~is_exp),
    .x_swap_i     (src_swap_i[2] & ~is_exp),
// ADDRESS
    .addr_o       (src_pa),
    .next_line_o  (src_nl_pa),
    .carry_o      (src_carry)
);

blns_gpu_walk #(
    .PA_W         (PA_W),
    .ASYNC_RST_EN (ASYNC_RST_EN)
) u_walk_dst (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .init_i       (a_init),
    .base_i       (dst_base_i),
    .step_i       (a_emit),
    .step_n_i     (a_n),
    .line_done_i  (line_done),
    .stride_i     (dst_stride),
    .cl_swap_i    (dst_swap_i[0]),
    .y_swap_i     (dst_swap_i[1]),
    .x_swap_i     (dst_swap_i[2]),
// ADDRESS
    .addr_o       (dst_pa_w),
    .next_line_o  (dst_nl_pa),
    .carry_o      (dst_carry)
);
wire [PA_W+1:0] walk_unused   = {dst_nl_pa, src_nl_pa[0], dst_carry};

// Triangle: first pixel of the box row + column (no swaps)
wire [PA_W-1:0] tr_rowpa;
wire [PA_W-1:0] tr_rowpa_nxt = a_init ? dst_base_i : (tr_rowpa + dst_stride);
arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_tr_rowpa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_init | tr_rowend), .d_i(tr_rowpa_nxt), .q_o(tr_rowpa));
// The pixel (box row + column) kept in a register, so that the destination
// word of the token A offers (read ahead) starts at a flop: loaded as a row
// starts with its first pixel (the sum for each candidate first column, beside
// the bound compares that pick t_xl), stepped by the token's pixels (col +
// a_n stays inside the box row)
wire [PA_W+DIM_W-1:0] tr_b0_w = {{PA_W{1'b0}}, tb0[DIM_W-1:0]};
wire [PA_W+DIM_W-1:0] tr_b1_w = {{PA_W{1'b0}}, tb1[DIM_W-1:0]};
wire [PA_W+DIM_W-1:0] tr_b2_w = {{PA_W{1'b0}}, tb2[DIM_W-1:0]};
wire [PA_W-1:0] tr_s0       = tr_rowpa + tr_b0_w[PA_W-1:0];
wire [PA_W-1:0] tr_s1       = tr_rowpa + tr_b1_w[PA_W-1:0];
wire [PA_W-1:0] tr_s2       = tr_rowpa + tr_b2_w[PA_W-1:0];
wire [PA_W-1:0] tr_dpa;
wire [PA_W-1:0] tr_dpa_ld   = (t_box | ~(tc0 | tc1 | tc2)) ? tr_rowpa : tc2 ? tr_s2 : tc1 ? tr_s1 : tr_s0;
wire [PA_W-1:0] tr_dpa_nxt  = tr_load ? tr_dpa_ld : (tr_dpa + {{(PA_W-6){1'b0}}, a_n});
arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_tr_dpa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tr_load | (t_on & a_emit)), .d_i(tr_dpa_nxt), .q_o(tr_dpa));
wire [PA_W-1:0] ln_pa;                                 // a line's pixel (section 5b)
wire            ln_skip;                               // ... skipped
wire            ln_gap;                                // ... a pattern gap (OPAQUE: drawn in transp_i)
wire      [7:0] ln_cov;                                // ... AA coverage
wire [PA_W-1:0] dst_pa      = t_on ? tr_dpa : ln_on ? ln_pa : dst_pa_w;

//-----------------------------------------------------------------------------
// Texture: (u, v) accumulators (10.11), stepped with each token; TEXRECT moves
// to the next row's start after a row's last texel. The texel of (u, v),
// base + (v & vmask) * pitch + (u & umask), is registered; the product works
// on registered values only: the texel one step further, taken by a plain
// step, so no product follows the token handshake. After a jump (start, next
// row, a triangle row's u and v) the token waits one cycle while the product
// gives the texel of the new (u, v).
//-----------------------------------------------------------------------------
wire        [3:0] tex_l2w_f = (tex_cfg_i[3:0] > 4'd10) ? 4'd10 : tex_cfg_i[3:0];
wire        [3:0] tex_l2h_f = (tex_cfg_i[7:4] > 4'd10) ? 4'd10 : tex_cfg_i[7:4];
wire              tex_free  = tex_cfg_i[12];
wire              tex_bound = AFFINE_USE & tex_cfg_i[13];

wire       [20:0] tex_u;
wire       [20:0] tex_v;
wire       [20:0] tex_du    = {{5{tex_step_i[31]}}, tex_step_i[31:16]};
wire       [20:0] tex_dv    = {{5{tex_step_i[15]}}, tex_step_i[15:0]};
wire       [20:0] tex_ru;
wire       [20:0] tex_rv;
wire       [20:0] tex_rdu   = {{5{tex_rstep_i[31]}}, tex_rstep_i[31:16]};
wire       [20:0] tex_rdv   = {{5{tex_rstep_i[15]}}, tex_rstep_i[15:0]};
wire       [20:0] tex_ru_nx = tex_ru + tex_rdu;
wire       [20:0] tex_rv_nx = tex_rv + tex_rdv;
wire              tex_step  = a_emit & is_tex;
wire              tex_nrow  = tex_step & is_trect & line_done;
// A textured triangle: R holds (u, v) at the box row's first column (stepped
// by (du', dv') per row); a row starts at R + first pixel * (du, dv), u then v
// (mod 2^21: the value stepping from the box's first column gives)
wire              tex_tri   = t_on & is_tex;
wire              tex_tu    = tex_tri & (tr_st == TR_U) & tr_adv;
wire              tex_tv    = tex_tri & (tr_st == TR_V) & tr_adv;
wire       [16:0] tex_xl17  = {{(17-DIM_W){1'b0}}, col};            // the row's first pixel
wire       [15:0] tex_sd    = tex_tv ? tex_step_i[15:0] : tex_step_i[31:16];
wire signed [32:0] tex_xp   = $signed(tex_xl17) * $signed(tex_sd);
wire       [32:0] tex_xpu   = $unsigned(tex_xp);
wire       [20:0] tex_xd    = tex_xpu[20:0];
wire              tex_uv_en = a_init | (tex_tri ? (tex_tu | tex_tv | tex_step) : tex_step);
wire              tex_r_en  = a_init | (tex_tri ? tr_rowend : tex_nrow);
// Priority: init > row start (u, then v) > next texel
// (bilinear: the walk starts at (u0 - 1/2, v0 - 1/2), the taps' origin; the
// triangle rows follow from it)
wire       [20:0] tex_u0    = bil_on ? (tex_u0_i - 21'd1024) : tex_u0_i;
wire       [20:0] tex_v0    = bil_on ? (tex_v0_i - 21'd1024) : tex_v0_i;
wire       [20:0] tex_u_nxt = a_init ? tex_u0 :
                              tex_tu ? (tex_ru + tex_xd) : tex_tv ? tex_u :
                              tex_nrow ? tex_ru_nx : (tex_u + tex_du);
wire       [20:0] tex_v_nxt = a_init ? tex_v0 :
                              tex_tv ? (tex_rv + tex_xd) : tex_tu ? tex_v :
                              tex_nrow ? tex_rv_nx : (tex_v + tex_dv);
wire       [20:0] tex_ru_d  = a_init ? tex_u0 : tex_ru_nx;
wire       [20:0] tex_rv_d  = a_init ? tex_v0 : tex_rv_nx;

arv_ipdff #(.WIDTH(42), .ARST_EN(ASYNC_RST_EN)) u_tex_uv (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tex_uv_en), .d_i({tex_u_nxt, tex_v_nxt}), .q_o({tex_u, tex_v}));
arv_ipdff #(.WIDTH(42), .ARST_EN(ASYNC_RST_EN)) u_tex_ruv (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tex_r_en), .d_i({tex_ru_d, tex_rv_d}), .q_o({tex_ru, tex_rv}));

wire        [9:0] tex_ui    = tex_u[20:11];
wire        [9:0] tex_vi    = tex_v[20:11];
wire       [10:0] tex_wpow  = 11'd1 << tex_l2w_f;
wire       [10:0] tex_hpow  = 11'd1 << tex_l2h_f;
wire       [10:0] tex_wm1   = tex_wpow - 11'd1;
wire       [10:0] tex_hm1   = tex_hpow - 11'd1;
wire        [9:0] tex_umask = tex_free ? 10'h3FF : tex_wm1[9:0];
wire        [9:0] tex_vmask = tex_free ? 10'h3FF : tex_hm1[9:0];
wire       [15:0] tex_pitch = tex_free ? src_str32[15:0] : {5'b00000, tex_wpow};

// tex_ok: tex_pa belongs to the registered (u, v)
wire              tex_ok;
wire              tex_plain = tex_step & ~a_init & ~tex_tu & ~tex_tv & ~tex_nrow;
wire              tex_jump  = tex_uv_en & ~tex_plain;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_tex_ok (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(~tex_jump), .q_o(tex_ok));

// The texel of (u, v) + (du, dv), or of (u, v) itself after a jump
wire       [20:0] tex_au    = tex_ok ? (tex_u + tex_du) : tex_u;
wire       [20:0] tex_av    = tex_ok ? (tex_v + tex_dv) : tex_v;
// (bilinear: the first tap's texel, its coordinates clamped to the box with
// BOUND and without TBORDER: x0 = -1 -> 0, y0 = -1 -> 0)
wire        [9:0] tex_ax    = tex_au[20:11];
wire        [9:0] tex_ay    = tex_av[20:11];
wire              bil_clamp;                             // section 5c
wire        [9:0] tex_ax0   = tex_ax & {10{~(bil_clamp & tex_ax[9])}};
wire        [9:0] tex_ay0   = tex_ay & {10{~(bil_clamp & tex_ay[9])}};
wire       [25:0] tex_row   = {16'h0000, tex_ay0 & tex_vmask} * {10'h000, tex_pitch};
// Run-ahead: the base is the source walker's address, which a texture does not
// step (src_base_i is read at the start only)
wire   [PA_W-1:0] tex_base  = RA_USE ? src_pa : src_base_i;
wire       [31:0] tex_sum   = {{(32-PA_W){1'b0}}, tex_base} + {6'h00, tex_row} +
                              {22'h000000, tex_ax0 & tex_umask};
wire   [PA_W-1:0] tex_pa;                                // texel of the current (u, v)
wire              tex_hi;                                // texel past the pixel-address range
arv_ipdff #(.WIDTH(PA_W+1), .ARST_EN(ASYNC_RST_EN)) u_tex_pa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~tex_ok | tex_plain),
             .d_i({|tex_sum[31:PA_W], tex_sum[PA_W-1:0]}), .q_o({tex_hi, tex_pa}));
// BOUND: u, v signed; the texel is inside when 0 <= u < TW and 0 <= v < TH
// (run-ahead: the copy holds the box clamped)
wire        [9:0] tex_tw    = tex_box_i[9:0];
wire        [9:0] tex_th    = tex_box_i[21:12];
wire              tex_in    = ~tex_ui[9] & ({1'b0, tex_ui[8:0]} < tex_tw) &
                              ~tex_vi[9] & ({1'b0, tex_vi[8:0]} < tex_th);
wire              bil_skip;                              // bilinear: the pixel is skipped (section 5c)
wire              tex_oob   = bil_on ? bil_skip : (tex_bound & ~tex_in);

// Source depth: the EXPAND depth (1/2/4/8 bpp), else the colour depth
wire        [4:0] src_bpp   = is_exp ? {1'b0, (exp_depth_i == 2'd3), (exp_depth_i == 2'd2),
                                        (exp_depth_i == 2'd1), (exp_depth_i == 2'd0)}
                                     : bpp;
wire [PA_W-1:0]   tap_pa;                                // bilinear: the tap's texel (section 5c)
wire              tap_hi;
wire [PA_W-1:0]   src_rd_pa = is_tex ? (bil_on ? tap_pa : tex_pa) : src_pa;

// Word address = pa >> (5 - log2 bpp); bit offset = (pa mod ppw) << log2 bpp.
// The top bit flags a word past 2^VRAM_AW (pixel-address bits above the slice):
// every VRAM_WORDS check then sees it out of range.
wire               src_past;                             // an immediate index past 2^PA_W (below)
wire               src_hi    = (is_tex     &  (tex_hi | tap_hi))                   | src_past |
                               (src_bpp[1] &  src_rd_pa[VRAM_AW+4])                |
                               (src_bpp[2] & |src_rd_pa[VRAM_AW+4:VRAM_AW+3])      |
                               (src_bpp[3] & |src_rd_pa[VRAM_AW+4:VRAM_AW+2])      |
                               (src_bpp[4] & |src_rd_pa[VRAM_AW+4:VRAM_AW+1]);
wire               dst_hi    = (bpp[1] &  dst_pa[VRAM_AW+4])                       |
                               (bpp[2] & |dst_pa[VRAM_AW+4:VRAM_AW+3])             |
                               (bpp[3] & |dst_pa[VRAM_AW+4:VRAM_AW+2])             |
                               (bpp[4] & |dst_pa[VRAM_AW+4:VRAM_AW+1]);
wire    [WA_W-1:0] src_waddr = {src_hi,
                               ({VRAM_AW{src_bpp[0]}} & src_rd_pa[VRAM_AW+4:5]) |
                               ({VRAM_AW{src_bpp[1]}} & src_rd_pa[VRAM_AW+3:4]) |
                               ({VRAM_AW{src_bpp[2]}} & src_rd_pa[VRAM_AW+2:3]) |
                               ({VRAM_AW{src_bpp[3]}} & src_rd_pa[VRAM_AW+1:2]) |
                               ({VRAM_AW{src_bpp[4]}} & src_rd_pa[VRAM_AW  :1])};
wire    [WA_W-1:0] dst_waddr = {dst_hi,
                               ({VRAM_AW{bpp[0]}} & dst_pa[VRAM_AW+4:5]) |
                               ({VRAM_AW{bpp[1]}} & dst_pa[VRAM_AW+3:4]) |
                               ({VRAM_AW{bpp[2]}} & dst_pa[VRAM_AW+2:3]) |
                               ({VRAM_AW{bpp[3]}} & dst_pa[VRAM_AW+1:2]) |
                               ({VRAM_AW{bpp[4]}} & dst_pa[VRAM_AW  :1])};
wire         [4:0] src_boff  = ({5{src_bpp[0]}} &  src_rd_pa[4:0])         |
                               ({5{src_bpp[1]}} & {src_rd_pa[3:0], 1'b0})  |
                               ({5{src_bpp[2]}} & {src_rd_pa[2:0], 2'b00}) |
                               ({5{src_bpp[3]}} & {src_rd_pa[1:0], 3'b000})|
                               ({5{src_bpp[4]}} & {src_rd_pa[0],   4'h0});
// The source as the read ahead and the word-token limits see it (nx_swa_o,
// nw_wa_o, s_slot, wc_ovl, the A8 word nx_mwa_o): without the bilinear tap
// offset. F reads ahead neither the source nor the A8 word of a bilinear
// token (la_tok, ma_want: ~bil_on) and the limits are a copy's, so these
// equal src_rd_pa's wherever they are used; the tap's priority encode and
// offset adder feed the A -> F register only, not the port request.
wire [PA_W-1:0]    src_la_pa;
wire    [WA_W-1:0] src_la_wa;
generate
    if (BIL_USE) begin : g_la_pa
        assign src_la_pa = is_tex ? tex_pa : src_pa;
        wire   src_la_hi = (is_tex     &  tex_hi)                          | src_past |
                           (src_bpp[1] &  src_la_pa[VRAM_AW+4])           |
                           (src_bpp[2] & |src_la_pa[VRAM_AW+4:VRAM_AW+3]) |
                           (src_bpp[3] & |src_la_pa[VRAM_AW+4:VRAM_AW+2]) |
                           (src_bpp[4] & |src_la_pa[VRAM_AW+4:VRAM_AW+1]);
        assign src_la_wa = {src_la_hi,
                            ({VRAM_AW{src_bpp[0]}} & src_la_pa[VRAM_AW+4:5]) |
                            ({VRAM_AW{src_bpp[1]}} & src_la_pa[VRAM_AW+3:4]) |
                            ({VRAM_AW{src_bpp[2]}} & src_la_pa[VRAM_AW+2:3]) |
                            ({VRAM_AW{src_bpp[3]}} & src_la_pa[VRAM_AW+1:2]) |
                            ({VRAM_AW{src_bpp[4]}} & src_la_pa[VRAM_AW  :1])};
    end else begin : g_no_la_pa
        assign src_la_pa = src_rd_pa;                     // (no tap offset)
        assign src_la_wa = src_waddr;
        wire [PA_W-6:0] la_unused = src_la_pa[PA_W-1:5];  // (s_slot: the low bits)
    end
endgenerate

// Immediate source: its index past 2^PA_W, from the set-up (a trimmed start
// past it) or the source walk carrying past it, flags every word after as
// past the VRAM, whatever the depth (the index does not wrap: ERR_CAUSE 5)
generate
    if (IMM_USE) begin : g_imm_past
        wire imm_past;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_imm_past (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_init | (src_step & src_carry)),
             .d_i(a_init ? src_past_i : 1'b1), .q_o(imm_past));
        assign src_past = imm_i & imm_past;
    end else begin : g_no_imm_past
        assign src_past = 1'b0;
        wire [1:0] past_unused = {src_past_i, src_carry};   // GPU_IMM_EN = 0
    end
endgenerate

//-----------------------------------------------------------------------------
// FILL gradient: the fill value + STEP every N lines (AXIS 0) or pixels along
// the run (AXIS 1); the walk / each run starts at the set-up's phase. RGB (16
// bpp): each channel + its own step, 14-bit saturating accumulators with 6
// fraction bits, the channel saturated to its range
//-----------------------------------------------------------------------------
wire        grad_en     = GRAD_USE & grad_i[17] & is_fillk & ~ln_on;   // (a line's slot holds no gradient)
wire [11:0] grad_n      = (grad_i[11:0] == 12'h000) ? 12'h001 : grad_i[11:0];
wire [15:0] grad_step   = {{12{grad_i[16]}}, grad_i[16:13]};
wire        grad_axis   = grad_i[12];
wire [11:0] grad_cnt;
wire [41:0] grad_val;
wire        grad_rgb    = grad_i[48];
wire        grad_ev     = (t_on & ~t_box) ? tr_rowend : (a_emit & (grad_axis ? ~line_done : line_done));
wire        grad_wrap   = (grad_cnt == (grad_n - 12'h001));
wire        grad_rst    = a_init | (a_emit & grad_axis & line_done);
wire        grad_en_ff  = grad_rst | grad_ev;
// Priority: walk / run start (the set-up's phase) > wrap > count
wire [11:0] grad_cnt_d  = grad_rst ? grad_cnt0_i : grad_wrap ? 12'h000 : (grad_cnt + 12'h001);
// Channel accumulator + step, saturated to 14 bits
function [13:0] g_acc;
    input [13:0] acc;
    input  [9:0] step;
    reg   [14:0] sum;
    begin
        sum   = {acc[13], acc} + {{5{step[9]}}, step};
        g_acc = (sum[14] == sum[13]) ? sum[13:0] : (sum[14] ? 14'h2000 : 14'h1FFF);
    end
endfunction
wire [41:0] grad_stp    = grad_rgb ? {g_acc(grad_val[41:28], grad_i[47:38]),
                                      g_acc(grad_val[27:14], grad_i[37:28]),
                                      g_acc(grad_val[13:0],  grad_i[27:18])} :
                                     {26'h0000000, grad_val[15:0] + grad_step};
wire [41:0] grad_val_d  = grad_rst ? grad_val0_i : grad_wrap ? grad_stp : grad_val;

arv_ipdff #(.WIDTH(54), .ARST_EN(ASYNC_RST_EN)) u_grad (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(grad_en_ff), .d_i({grad_cnt_d, grad_val_d}), .q_o({grad_cnt, grad_val}));

// A channel: the fill's value + the accumulator's whole part (its bits
// [13:6]), saturated to 0 .. max (5 or 6 bits)
function [5:0] g_chan;
    input  [5:0] base;
    input  [7:0] whole;
    input        six;
    reg    [8:0] sum;
    reg          over;
    begin
        sum    = {3'b000, base} + {whole[7], whole};
        over   = (sum[7:6] != 2'b00) | (~six & sum[5]);
        g_chan = sum[8] ? 6'h00 : over ? {six, 5'h1F} : sum[5:0];
    end
endfunction
wire  [5:0] grad_r      = g_chan({1'b0, fill_i[15:11]}, grad_val[41:34], 1'b0);
wire  [5:0] grad_g      = g_chan(fill_i[10:5],          grad_val[27:20], 1'b1);
wire  [5:0] grad_b      = g_chan({1'b0, fill_i[4:0]},   grad_val[13:6],  1'b0);
wire [15:0] fill_eff    = ~grad_en ? fill_i :
                          grad_rgb ? {grad_r[4:0], grad_g, grad_b[4:0]} : (fill_i + grad_val[15:0]);

//-----------------------------------------------------------------------------
// Whole-word FILL: the token takes the run's pixels up to the end of the
// destination word (down to its start with the X swap)
//-----------------------------------------------------------------------------
wire        wf_on       = is_fillk & ~(dst_swap_i[0] & ~t_on) & ~(grad_en & grad_axis) & ~blend_on & ~rmp_on & ~ln_on;
wire        x_swap      = dst_swap_i[2] & ~t_on;          // a triangle has no swaps
wire  [4:0] dst_slot    = ({5{bpp[0]}} &  dst_pa[4:0])          |
                          ({5{bpp[1]}} & {1'b0,   dst_pa[3:0]}) |
                          ({5{bpp[2]}} & {2'b00,  dst_pa[2:0]}) |
                          ({5{bpp[3]}} & {3'b000, dst_pa[1:0]}) |
                          ({5{bpp[4]}} & {4'h0,   dst_pa[0]});
wire  [4:0] ppw_m1      = {bpp[0], bpp[0] | bpp[1], bpp[0] | bpp[1] | bpp[2], ~bpp[4], 1'b1};
wire  [5:0] wd_left     = x_swap ? ({1'b0, dst_slot} + 6'd1) : ({1'b0, ppw_m1 - dst_slot} + 6'd1);
wire [31:0] wd_left32   = {26'h0000000, wd_left};
wire [31:0] a_n_wf      = (wd_left32 < a_rem32) ? wd_left32 : a_rem32;

//-----------------------------------------------------------------------------
// Word-token COPY: the token takes the run's pixels up to the end of its
// destination word and of its source word (down to their starts with the X
// swap), the source limit dropped when no source is read (op 2). One pixel
// when its source word is its destination word and the source trails the
// destination along the walk (pixels read before an earlier one of the token
// is written would differ from a pixel-by-pixel copy), and when that word is
// walked both ways (a mirror). Its source word is rotated right by (source -
// destination slot) * bpp: its pixels land on their destination slots (the
// same for every pixel: equal X swaps). A mirror (X swaps differing) is
// rotated by (source + destination slot + 1) * bpp, then its pixel order
// reversed: source slot s - i lands on destination slot d + i (or s + i on
// d - i), whatever the token's length.
//-----------------------------------------------------------------------------
wire        is_cpk      = ~kind_i[2] & (kind_i[1] ^ kind_i[0]);   // COPY or COPY_TRANSP
wire        wc_on       = is_cpk & ~dst_swap_i[0] & ~src_swap_i[0] & ~blend_on & ~rmp_on;
wire        wc_mir      = dst_swap_i[2] ^ src_swap_i[2];   // a mirror
wire        nw_dn       = src_swap_i[2] & ~is_exp;
wire  [4:0] s_slot      = ({5{src_bpp[0]}} &  src_la_pa[4:0])          |
                          ({5{src_bpp[1]}} & {1'b0,   src_la_pa[3:0]}) |
                          ({5{src_bpp[2]}} & {2'b00,  src_la_pa[2:0]}) |
                          ({5{src_bpp[3]}} & {3'b000, src_la_pa[1:0]}) |
                          ({5{src_bpp[4]}} & {4'h0,   src_la_pa[0]});
wire  [4:0] s_ppw_m1    = {src_bpp[0], src_bpp[0] | src_bpp[1], src_bpp[0] | src_bpp[1] | src_bpp[2], ~src_bpp[4], 1'b1};
wire  [5:0] s_left      = nw_dn ? ({1'b0, s_slot} + 6'd1) : ({1'b0, s_ppw_m1 - s_slot} + 6'd1);
wire [31:0] s_left32    = {26'h0000000, s_left};
// Mask plane: the token's mask bits, from the mask pixel of its first source
// pixel (source + K; its bit: a 5-bit add) to the end of the mask word along
// the source walk
wire  [4:0] m_slot      = src_pa[4:0] + msk_k_i[4:0];
wire  [5:0] m_left      = nw_dn ? ({1'b0, m_slot} + 6'd1) : (6'd32 - {1'b0, m_slot});
wire [31:0] m_left32    = {26'h0000000, m_left};
// min(run, destination word, source word, mask word): the compares side by
// side, the source and mask limits dropped when not used
wire        wc_rd       = (a_rem32 <= wd_left32) & ((a_rem32 <= s_left32) | ~need_src) & ((a_rem32 <= m_left32) | ~mp_on);
wire        wc_ds       = ((wd_left32 <= s_left32) | ~need_src) & ((wd_left32 <= m_left32) | ~mp_on);
wire        wc_sm       = (s_left32 <= m_left32) | ~mp_on;
wire [31:0] a_n_wc      = wc_rd ? a_rem32 : wc_ds ? wd_left32 : (need_src & wc_sm) ? s_left32 : m_left32;
wire        wc_ovl      = need_src & ~imm_i & (src_la_wa == dst_waddr) &
                          (wc_mir | (x_swap ? (s_slot > dst_slot) : (s_slot < dst_slot)));
assign      a_n         = wf_on ? a_n_wf[5:0] : (wc_on & ~wc_ovl) ? a_n_wc[5:0] : 6'd1;
// The token ends the run (a_rem == a_n) from the compares a_n selects with,
// not after it: a word FILL when the run ends in the word, a word COPY when
// the run is the shortest of its limits (wc_rd), else one pixel
assign      line_done   = wf_on ? (a_rem32 <= wd_left32) : (wc_on & ~wc_ovl) ? wc_rd : (a_rem == DIM_ONE);
wire  [4:0] dst_boff    = ({5{bpp[0]}} &  dst_slot)               |
                          ({5{bpp[1]}} & {dst_slot[3:0], 1'b0})   |
                          ({5{bpp[2]}} & {dst_slot[2:0], 2'b00})  |
                          ({5{bpp[3]}} & {dst_slot[1:0], 3'b000}) |
                          ({5{bpp[4]}} & {dst_slot[0],   4'h0});
wire  [4:0] px_bits     = bpp;                           // bits per pixel (one-hot {16, 8, 4, 2, 1})
wire  [4:0] a_rot       = ~wc_on ? src_boff : wc_mir ? (src_boff + dst_boff + px_bits) : (src_boff - dst_boff);
// The mask word rotated right by (mask bit - destination slot) brings each
// token pixel's mask bit to its destination slot; a mirror reverses the
// mask word first: (31 - mask bit - destination slot)
wire  [4:0] a_mrot      = (wc_on & wc_mir) ? ~(m_slot + dst_slot) : (m_slot - dst_slot);
// (RGB565A8: the alpha byte of the source pixel or the texel, at 8 bpp)
wire [PA_W-1:0] msk_src = (BLEND_USE & a8_on & is_tex) ? src_rd_pa : src_pa;
wire [PA_W-1:0] msk_pa  = msk_src + msk_k_i;
wire  [4:0] a_n_m1      = a_n[4:0] - 5'd1;               // a_n <= 32
wire  [4:0] lo_slot     = x_swap ? (dst_slot - a_n_m1) : dst_slot;
wire  [4:0] lo_boff     = ({5{bpp[0]}} &  lo_slot)               |
                          ({5{bpp[1]}} & {lo_slot[3:0], 1'b0})   |
                          ({5{bpp[2]}} & {lo_slot[2:0], 2'b00})  |
                          ({5{bpp[3]}} & {lo_slot[1:0], 3'b000}) |
                          ({5{bpp[4]}} & {lo_slot[0],   4'h0});
// bits written: a_n pixels from the lowest one
wire  [5:0] a_nbits     = ({6{bpp[0]}} &  a_n)                   |
                          ({6{bpp[1]}} & {a_n[4:0], 1'b0})       |
                          ({6{bpp[2]}} & {a_n[3:0], 2'b00})      |
                          ({6{bpp[3]}} & {a_n[2:0], 3'b000})     |
                          ({6{bpp[4]}} & {a_n[1:0], 4'h0});


//-----------------------------------------------------------------------------
// 5b) LINE WALK: one token per step (Bresenham), two per step with AA (row r
// then r + 1). The registers hold the token A offers: its pixel (address,
// major / minor coordinates) and, computed a step ahead from the next
// coordinates, whether it is skipped (outside the clip window, a pattern gap
// without OPAQUE, coverage 0), its pattern bit (the gap colour) and whether
// the walk ends at it (a coordinate past the window's far bound: the token
// is skipped and the last). Bresenham: the error E (2d - D first) + 2d, a
// minor step when E > 0 (the minor decreasing: E >= 0), then E - 2D; the
// next step's choice from a flop (lw_dg). AA: T the row position - 1/2 px
// (1/2^16 px), r = T >> 16, coverage 255 - f then f, f = T[15:8]; T + G at
// the second token, the row change (-1, 0, 1) from the carry out of its
// fraction. The address steps (major, major + minor, ...) are loaded with
// the walk.
//-----------------------------------------------------------------------------
generate
    if (LINE_USE) begin : g_lwalk
        wire              lw_xm   = ln_xmaj_i;
        wire              lw_sm   = ln_smaj_i;
        wire              lw_sn   = ln_smin_i;
        // (AA only with blending: the set-up never sets ln_aa_i without it,
        // and its row, coverage and third address step are then not built)
        wire              lw_aa   = BLEND_USE & ln_aa_i;
        // the clip bounds along the major (p) and minor (q) axes
        wire       [12:0] c_pl    = {lw_xm ? ln_clip_i[35] : ln_clip_i[47], lw_xm ? ln_clip_i[35:24] : ln_clip_i[47:36]};
        wire       [12:0] c_ph    = {lw_xm ? ln_clip_i[11] : ln_clip_i[23], lw_xm ? ln_clip_i[11:0]  : ln_clip_i[23:12]};
        wire       [12:0] c_ql    = {lw_xm ? ln_clip_i[47] : ln_clip_i[35], lw_xm ? ln_clip_i[47:36] : ln_clip_i[35:24]};
        wire       [12:0] c_qh    = {lw_xm ? ln_clip_i[23] : ln_clip_i[11], lw_xm ? ln_clip_i[23:12] : ln_clip_i[11:0]};
        wire   [PA_W-1:0] lw_pa;
        wire       [12:0] lw_p;
        wire       [12:0] lw_q;
        wire       [28:0] lw_e;
        wire       [12:0] lw_k;                          // steps left after this one
        wire        [4:0] lw_ph;
        wire        [7:0] lw_cov;
        wire              lw_hf;                         // AA: the row r + 1 token
        wire              lw_dg;                         // Bresenham: the next step is a minor step
        wire              lw_drp;                        // AA: the row change at the next step: +1
        wire              lw_drz;                        // ... 0 (else -1)
        wire              lw_skp;
        wire              lw_pb;
        wire              lw_ex;
        wire   [PA_W-1:0] k_maj;
        wire   [PA_W-1:0] k_dg;                          // Bresenham: major + minor; AA: major - minor
        wire   [PA_W-1:0] k_m2;                          // AA: major - 2 minor
        wire              lw_step = a_emit & ln_on;
        wire              lw_ld   = a_init & ln_on;
        // Address steps: the major unit (1 or the stride) and the minor one
        wire   [PA_W-1:0] u_maj   = lw_xm ? {{(PA_W-1){1'b0}}, 1'b1} : dst_stride;
        wire   [PA_W-1:0] u_min   = lw_xm ? dst_stride : {{(PA_W-1){1'b0}}, 1'b1};
        wire   [PA_W-1:0] s_maj   = lw_sm ? ({PA_W{1'b0}} - u_maj) : u_maj;
        // (the minor step: Bresenham signed, AA -1 row: k_dg = major - minor)
        wire   [PA_W-1:0] s_mn    = (lw_sn | lw_aa) ? ({PA_W{1'b0}} - u_min) : u_min;
        arv_ipdff #(.WIDTH(3*PA_W), .ARST_EN(ASYNC_RST_EN)) u_lw_k (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lw_ld),
             .d_i({s_maj, s_maj + s_mn, s_maj + s_mn + s_mn}), .q_o({k_maj, k_dg, k_m2}));
        // The next token
        wire       [15:0] e16     = lw_e[15:0];
        wire       [15:0] e_add   = lw_dg ? {{2{ln_g_i[27]}}, ln_g_i[27:14]} : {2'b00, ln_g_i[13:0]};
        wire       [15:0] e_nx    = e16 + e_add;
        wire       [28:0] t_gs    = {{11{ln_g_i[17]}}, ln_g_i[17:0]};
        wire       [28:0] t_nx    = lw_e + t_gs;
        wire              t_c16   = t_nx[16] ^ lw_e[16] ^ t_gs[16];   // carry out of the fraction
        wire              ph_wrap = (lw_ph == ln_len_i);
        wire        [4:0] ph_inc  = ph_wrap ? 5'd0 : (lw_ph + 5'd1);
        wire              aa_h0   = lw_aa & ~lw_hf;      // row r -> r + 1 (same column)
        wire              aa_h1   = lw_aa &  lw_hf;      // -> the next column
        wire       [12:0] p_inc   = lw_sm ? (lw_p - 13'd1) : (lw_p + 13'd1);
        wire       [12:0] q_mn    = lw_sn ? (lw_q - 13'd1) : (lw_q + 13'd1);
        wire       [12:0] q_aa    = lw_drp ? lw_q : lw_drz ? (lw_q - 13'd1) : (lw_q - 13'd2);
        // Priority: load > step
        wire       [12:0] p_nx    = lw_ld ? ln_p0_i : aa_h0 ? lw_p : p_inc;
        wire       [12:0] q_nx    = lw_ld ? ln_q0_i : aa_h0 ? (lw_q + 13'd1) : aa_h1 ? q_aa : lw_dg ? q_mn : lw_q;
        wire        [4:0] ph_nx   = lw_ld ? ln_ph_i : aa_h0 ? lw_ph : ph_inc;
        wire              hf_nx   = ~lw_ld & aa_h0;
        wire       [28:0] le_nx   = lw_ld ? ln_e0_i : lw_aa ? (aa_h0 ? t_nx : lw_e) : {{13{e_nx[15]}}, e_nx};
        wire        [7:0] cov_nx  = lw_ld ? ~ln_e0_i[15:8] : aa_h0 ? lw_e[15:8] : ~lw_e[15:8];
        wire       [12:0] k_nx    = lw_ld ? ln_nm1_i : aa_h0 ? lw_k : (lw_k - 13'd1);
        wire              dg_e    = lw_ld ? ln_e0_i[15] : e_nx[15];        // the error sign (16-bit)
        wire              dg_z    = lw_ld ? (ln_e0_i[15:0] == 16'h0000) : (e_nx == 16'h0000);
        wire              dg_nx   = ~dg_e & (~dg_z | lw_sn);              // E > 0, or E >= 0 when decreasing
        wire              gs_neg  = ln_g_i[17];
        wire              gs_one  = ln_g_i[16] & ~ln_g_i[17];             // G = 1 (2^16)
        wire   [PA_W-1:0] pa_add  = aa_h0 ? u_min : (aa_h1 ? (lw_drp ? k_maj : lw_drz ? k_dg : k_m2) :
                                                     (lw_dg ? k_dg : k_maj));
        wire   [PA_W-1:0] pa_nx   = lw_ld ? dst_base_i : (lw_pa + pa_add);
        // Skip, pattern bit and end of the next token, from its coordinates
        wire              q_lo    = $signed(q_nx) < $signed(c_ql);
        wire              q_hi    = $signed(q_nx) > $signed(c_qh);
        wire              p_lo    = $signed(p_nx) < $signed(c_pl);
        wire              p_hi    = $signed(p_nx) > $signed(c_ph);
        wire              pb_nx   = ln_pat_i[ph_nx];
        wire              ex_nx   = (lw_sm ? p_lo : p_hi) |
                                    (lw_aa ? (lw_sn ? (hf_nx & q_lo) : (~hf_nx & q_hi)) : (lw_sn ? q_lo : q_hi));
        wire              skp_nx  = p_lo | p_hi | q_lo | q_hi | (~pb_nx & ~ln_opq_i) | (lw_aa & (cov_nx == 8'h00));
        wire              lw_en   = lw_ld | lw_step;
        arv_ipdff #(.WIDTH(PA_W + 3*13 + 29 + 5 + 8 + 4), .ARST_EN(ASYNC_RST_EN)) u_lw (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lw_en),
             .d_i({pa_nx, p_nx, q_nx, k_nx, le_nx, ph_nx, cov_nx, hf_nx, skp_nx, pb_nx, ex_nx}),
             .q_o({lw_pa, lw_p, lw_q, lw_k, lw_e, lw_ph, lw_cov, lw_hf, lw_skp, lw_pb, lw_ex}));
        // (lw_dg: the Bresenham choice of the next step; lw_drp / lw_drz: the
        // AA row change, taken at the row r token)
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_lw_dg (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lw_en & ~lw_aa), .d_i(dg_nx), .q_o(lw_dg));
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_lw_dr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lw_step & aa_h0),
             .d_i({(~gs_neg & t_c16) | gs_one, gs_neg ? t_c16 : (~t_c16 & ~gs_one)}), .q_o({lw_drp, lw_drz}));
        assign ln_pa     = lw_pa;
        assign ln_last   = lw_ex | ((lw_k == 13'd0) & (lw_hf | ~lw_aa));
        assign ln_skip   = lw_skp;
        assign ln_gap    = ~lw_pb;
        assign ln_cov    = lw_cov;
        wire [12:0] e_unused = lw_e[28:16];               // Bresenham: 16 bits (AA: the row above)
        wire        g_unused = ln_g_i[28];
    end else begin : g_no_lwalk
        assign ln_pa     = {PA_W{1'b0}};
        assign ln_last   = 1'b0;
        assign ln_skip   = 1'b0;
        assign ln_gap    = 1'b0;
        assign ln_cov    = 8'h00;
        wire [208:0] ln_unused = {ln_i, ln_aa_i, ln_opq_i, ln_xmaj_i, ln_smaj_i, ln_smin_i, ln_g_i, ln_clip_i,
                                  ln_pat_i, ln_len_i, ln_e0_i, ln_p0_i, ln_q0_i, ln_nm1_i, ln_ph_i, transp_i};   // GPU_LINE_EN = 0
    end
endgenerate

//-----------------------------------------------------------------------------
// 5c) BILINEAR TAPS (BIL_USE; TEXSPAN, TEXRECT and textured triangles at 16
// bpp; without blending not with TRANSP_EN: nearest). The walk holds (u - 1/2,
// v - 1/2): x0 = its integer part, fx = (its top 8 fraction bits + 4) >> 3
// (0 .. 32), likewise y0, fy; taps T00, T01, T10, T11 at (x0 + j, y0 + i), of
// weight (32 - fx or fx) * (32 - fy or fy). Registered with the texel of
// (u, v) (one step ahead, the same enable), for the next pixel: its taps (the
// weight-0 ones dropped, with BOUND and TBORDER those outside the box), the
// offsets of the taps from the first one, dx (+1, -umask at a wrapping last
// column, 0 when the two columns are clamped to one) and dy (+pitch, the wrap
// back to row 0, 0), dx + dy, the parity of both texel rows, and the BOUND
// skip on (floor(u), floor(v)) = (x0, y0) + (the fraction >= 1/2). With BOUND
// and without TBORDER the taps are clamped to the box (the first one's texel
// takes x0 = -1 -> 0: tex_ax0). A pixel takes one token per tap, in order, A
// holding the walk until its last; no tap left (or skipped): one skipped
// token. The freeze holds between pixels only.
//-----------------------------------------------------------------------------
wire              tap_mid;                               // a pixel's taps under way: A holds the walk
wire              tap_end;                               // the token is its pixel's last
wire       [10:0] tap_k;
wire              tap_ypar;
wire              a_tok;                                 // a token leaves A (section 6)
generate
    if (BIL_USE) begin : g_bil
        assign      bil_on    = tex_filt_i[0] & is_tex & bpp[4] & (BLEND_USE | ~tex_cfg_i[8]);
        wire        tb_on     = bil_on & tex_bound & tex_filt_i[1];
        assign      bil_clamp = bil_on & tex_bound & ~tex_filt_i[1];
        // The next pixel's taps, from (tex_au, tex_av)
        wire  [8:0] fx_s      = {1'b0, tex_au[10:3]} + 9'd4;
        wire  [8:0] fy_s      = {1'b0, tex_av[10:3]} + 9'd4;
        wire  [5:0] fx_n      = fx_s[8:3];
        wire  [5:0] fy_n      = fy_s[8:3];
        wire  [9:0] x1        = tex_ax + 10'd1;
        wire  [9:0] y1        = tex_ay + 10'd1;
        wire        x1_out    = (x1 == tex_tw);              // x0 + 1 = TW (x0 = TW - 1: the box's last column)
        wire        y1_out    = (y1 == tex_th);
        wire  [9:0] x1c       = (bil_clamp & x1_out) ? tex_ax : x1;
        wire  [9:0] y1c       = (bil_clamp & y1_out) ? tex_ay : y1;
        wire        cx_eq     = (x1c == tex_ax0);            // both columns one texel (clamped)
        wire        cy_eq     = (y1c == tex_ay0);
        wire        x_wr      = ((tex_ax0 & tex_umask) == tex_umask);   // the last column: x0 + 1 wraps to 0
        wire        y_wr      = ((tex_ay0 & tex_vmask) == tex_vmask);
        // dy of a wrap: back to row 0, pitch - 2^log2 h * pitch (10 with FREE_PITCH)
        wire  [3:0] l2h_e     = tex_free ? 4'd10 : tex_l2h_f;
        wire [31:0] p32       = {16'h0000, tex_pitch};
        wire [31:0] dy_wr32   = p32 - (p32 << l2h_e);
        wire [31:0] um32      = {22'h000000, tex_umask};
        wire [31:0] dx32      = cx_eq ? 32'd0 : x_wr ? (32'd0 - um32) : 32'd1;
        wire [31:0] dy32      = cy_eq ? 32'd0 : y_wr ? dy_wr32 : p32;
        wire [31:0] dxy32     = dx32 + dy32;
        // The taps kept, the BOUND skip on (floor(u), floor(v))
        wire        c0        = (fx_n != 6'd32) & ~(tb_on & tex_ax[9]);
        wire        c1        = (fx_n != 6'd0)  & ~(tb_on & x1_out);
        wire        r0        = (fy_n != 6'd32) & ~(tb_on & tex_ay[9]);
        wire        r1        = (fy_n != 6'd0)  & ~(tb_on & y1_out);
        wire  [3:0] tm_n      = {c1 & r1, c0 & r1, c1 & r0, c0 & r0};    // {T11, T10, T01, T00}
        wire  [9:0] fu        = tex_ax + {9'h000, tex_au[10]};
        wire  [9:0] fv        = tex_ay + {9'h000, tex_av[10]};
        wire        b_in      = ~fu[9] & ({1'b0, fu[8:0]} < tex_tw) & ~fv[9] & ({1'b0, fv[8:0]} < tex_th);
        wire  [1:0] yp_n      = {y1c[0] & tex_vmask[0], tex_ay0[0] & tex_vmask[0]};
        wire [PA_W:0] b_dx;
        wire [PA_W:0] b_dy;
        wire [PA_W:0] b_dxy;
        wire  [5:0] b_fx;
        wire  [5:0] b_fy;
        wire  [3:0] b_tm;
        wire        b_oob;
        wire  [1:0] b_yp;
        arv_ipdff #(.WIDTH(3*(PA_W+1) + 19), .ARST_EN(ASYNC_RST_EN)) u_bil_px (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~tex_ok | tex_plain),
             .d_i({dx32[PA_W:0], dy32[PA_W:0], dxy32[PA_W:0], fx_n, fy_n, tm_n, tex_bound & ~b_in, yp_n}),
             .q_o({b_dx, b_dy, b_dxy, b_fx, b_fy, b_tm, b_oob, b_yp}));
        assign      bil_skip  = b_oob | (b_tm == 4'h0);
        // Tap sequencer: the taps done of this pixel (priority: init > token)
        wire  [3:0] tap_dn;
        wire  [3:0] t_rem     = b_tm & ~tap_dn;
        wire  [3:0] t_cur     = t_rem & ~(t_rem - 4'd1);      // the lowest left: 00, 01, 10, 11
        wire        t_last    = ((t_rem & ~t_cur) == 4'h0);
        assign      tap_end   = ~bil_on | t_last | b_oob;
        assign      tap_mid   = bil_on & (tap_dn != 4'h0);
        wire  [3:0] tap_dn_nxt = (a_init | tap_end) ? 4'h0 : (tap_dn | t_cur);
        arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_tap_dn (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_init | a_tok),
             .d_i(tap_dn_nxt), .q_o(tap_dn));
        // The tap's texel: the first one's + its offset (a carry past 2^PA_W:
        // past the VRAM)
        wire        t_c1      = t_cur[1] | t_cur[3];         // column x0 + 1
        wire        t_r1      = t_cur[2] | t_cur[3];         // row y0 + 1
        wire [PA_W:0] t_off   = t_cur[3] ? b_dxy : t_cur[2] ? b_dy : t_cur[1] ? b_dx : {(PA_W+1){1'b0}};
        wire [PA_W:0] t_sum   = {1'b0, tex_pa} + t_off;
        assign      tap_pa    = t_sum[PA_W-1:0];
        assign      tap_hi    = bil_on & t_sum[PA_W];
        wire  [5:0] t_wx      = t_c1 ? b_fx : (6'd32 - b_fx);
        wire  [5:0] t_wy      = t_r1 ? b_fy : (6'd32 - b_fy);
        wire [11:0] t_k12     = {6'h00, t_wx} * {6'h00, t_wy};
        assign      tap_k     = t_k12[10:0];                 // <= 1024
        assign      tap_ypar  = t_r1 ? b_yp[1] : b_yp[0];
        wire        k_unused  = t_k12[11];
        wire [36-PA_W:0] b_unused = {dx32[31:PA_W+1] | dy32[31:PA_W+1] | dxy32[31:PA_W+1], fx_s[2:0], fy_s[2:0]};
        wire  [5:0] tex_a_unused = {tex_au[2:0], tex_av[2:0]};   // fractions below the weights: carries only
    end else begin : g_no_bil
        assign      bil_on    = 1'b0;
        assign      bil_clamp = 1'b0;
        assign      bil_skip  = 1'b0;
        assign      tap_end   = 1'b1;
        assign      tap_mid   = 1'b0;
        assign      tap_pa    = {PA_W{1'b0}};
        assign      tap_hi    = 1'b0;
        assign      tap_k     = 11'd0;
        assign      tap_ypar  = 1'b0;
        wire  [1:0] filt_unused = tex_filt_i;                // GPU_BILINEAR_EN = 0
        wire [21:0] tex_a_unused = {tex_au[10:0], tex_av[10:0]};   // fractions: carries only
    end
endgenerate

//=============================================================================
// 6)  A -> F TOKEN
//=============================================================================
wire               t1_v;
wire               f_take    = f_take_i;                 // F takes the token (blns_gpu_px_fw)
assign             t1_free   = ~t1_v | f_take;
// A token per cycle; the walk steps with a pixel's last one (bilinear: its
// last tap, the freeze not holding the taps after its first)
assign             a_tok     = a_run & (~freeze_i | tap_mid) & t1_free & (~t_on | tr_run) & (tex_ok | ~is_tex);
assign             a_emit    = a_tok & tap_end;

wire    [WA_W-1:0] t1_dwa;
wire         [4:0] t1_dboff;
wire         [5:0] t1_nbits;
wire    [WA_W-1:0] t1_swa;
wire         [4:0] t1_rot;
wire               t1_skip;
wire        [15:0] t1_fill;
wire               t1_word;
wire               t1_mir;

// Priority: drop (abort) > new token > taken
wire               t1_v_nxt  = ~a_abort & ~abort_i & (a_tok | (t1_v & ~f_take));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_t1_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(t1_v_nxt), .q_o(t1_v));
arv_ipdff #(.WIDTH(2*WA_W + 17), .ARST_EN(ASYNC_RST_EN)) u_t1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok),
             .d_i({dst_waddr, lo_boff, a_nbits, src_waddr, a_rot, tri_out | (is_tex & tex_oob) | (ln_on & ln_skip)}),
             .q_o({t1_dwa, t1_dboff, t1_nbits, t1_swa, t1_rot, t1_skip}));
generate
    // The fill colour per token (gradient, a line's OPAQUE gaps); without
    // either it is fill_i, constant while the engine is busy
    if (FILL_PIPE != 0) begin : g_t1_fill
        arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_t1_fill (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i((ln_on & ln_gap) ? transp_i : fill_eff), .q_o(t1_fill));
    end else begin : g_no_t1_fill
        assign t1_fill = fill_i;
        wire [16:0] fill_unused = {fill_eff, ln_gap};        // = fill_i; no lines
    end
endgenerate
generate
    if (BLEND_USE && LINE_USE) begin : g_t1_cov
        wire [7:0] t1_cov;
        arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_t1_cov (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i(ln_cov), .q_o(t1_cov));
        assign t1_cov_o = t1_cov;
    end else begin : g_no_t1_cov
        assign t1_cov_o = 8'h00;
        wire [7:0] cov_unused = ln_cov;                       // no AA lines
    end
endgenerate
generate
    if (BLEND_USE) begin : g_t1_msk_a8
        // The mask word, or an RGB565A8 pixel's A8 word (address / 4: a past
        // flag for the address bits above the VRAM) and byte
        wire [VRAM_AW-1:0] t1_mwa;
        wire         [4:0] t1_mrot;
        wire               t1_mhi;
        wire [VRAM_AW-1:0] mwa_d   = a8_on ? msk_pa[VRAM_AW+1:2] : msk_pa[PA_W-1:5];
        wire         [4:0] mrot_d  = a8_on ? {3'b000, msk_pa[1:0]} : a_mrot;
        arv_ipdff #(.WIDTH(VRAM_AW + 5), .ARST_EN(ASYNC_RST_EN)) u_t1_m (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i({mwa_d, mrot_d}), .q_o({t1_mwa, t1_mrot}));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_t1_mhi (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i(a8_on & |msk_pa[PA_W-1:VRAM_AW+2]), .q_o(t1_mhi));
        assign t1_mwa_o  = t1_mwa;
        assign t1_mhi_o  = t1_mhi;
        assign t1_mrot_o = t1_mrot;
        // (the token A offers next: read ahead by F, never a bilinear one:
        // its A8 word from src_la_pa, off the tap's offset adder)
        wire [PA_W-1:0] msk_la = (BIL_USE != 0) ? (((a8_on & is_tex) ? src_la_pa : src_pa) + msk_k_i) : msk_pa;
        assign nx_mwa_o  = a8_on ? msk_la[VRAM_AW+1:2] : msk_la[PA_W-1:5];
        assign nx_mhi_o  = a8_on & |msk_la[PA_W-1:VRAM_AW+2];
        wire      [1:0] msk_la_unused = msk_la[1:0];         // the A8 byte: t1_mrot
    end else if (MPLANE_USE) begin : g_t1_msk
        wire [VRAM_AW-1:0] t1_mwa;
        wire         [4:0] t1_mrot;
        arv_ipdff #(.WIDTH(VRAM_AW + 5), .ARST_EN(ASYNC_RST_EN)) u_t1_m (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i({msk_pa[PA_W-1:5], a_mrot}), .q_o({t1_mwa, t1_mrot}));
        assign t1_mwa_o  = t1_mwa;
        assign t1_mhi_o  = 1'b0;
        assign t1_mrot_o = t1_mrot;
        assign nx_mwa_o  = {VRAM_AW{1'b0}};
        assign nx_mhi_o  = 1'b0;
        wire   [4:0] msk_pa_unused = msk_pa[4:0];             // the bit: m_slot
    end else begin : g_no_t1_msk
        assign t1_mwa_o  = {VRAM_AW{1'b0}};
        assign t1_mhi_o  = 1'b0;
        assign t1_mrot_o = 5'd0;
        assign nx_mwa_o  = {VRAM_AW{1'b0}};
        assign nx_mhi_o  = 1'b0;
        wire [PA_W+4:0] msk_unused = {msk_pa, a_mrot};      // GPU_MPLANE_EN = 0
    end
endgenerate

// word token flags (a copy in word tokens, and a mirror)
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_t1_w (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i({wc_on, wc_on & wc_mir}), .q_o({t1_word, t1_mir}));
// bilinear: the tap's weight, last-tap flag and texel row parity
generate
    if (BIL_USE) begin : g_t1_bil
        wire [10:0] t1_k;
        wire        t1_tlast;
        wire        t1_ypar;
        arv_ipdff #(.WIDTH(13), .ARST_EN(ASYNC_RST_EN)) u_t1_bil (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_tok), .d_i({tap_k, tap_end, tap_ypar}), .q_o({t1_k, t1_tlast, t1_ypar}));
        assign t1_k_o     = t1_k;
        assign t1_tlast_o = t1_tlast;
        assign t1_ypar_o  = t1_ypar;
    end else begin : g_no_t1_bil
        assign t1_k_o     = 11'd0;
        assign t1_tlast_o = 1'b1;
        assign t1_ypar_o  = 1'b0;
        wire [11:0] tap_unused = {tap_k, tap_ypar};
    end
endgenerate

//=============================================================================
// 7)  NEXT TOKEN (READ AHEAD BY F AND W)
//=============================================================================
// The token A offers next (the A -> F register's input): its words, read ahead
// by blns_gpu_px_fw in an idle port cycle
wire               nx_on     = (~t_on | tr_run) & (tex_ok | ~is_tex);
wire               nx_skip   = tri_out | (is_tex & tex_oob) | (ln_on & ln_skip);

// RD_REG_EN: the word after the next token's, a source walked along the run
// (s_left: the next token's pixels in its source word, section 5). Without
// it nothing reads them: 0 (the source walker's next line unused)
wire               nw_ok;
wire    [WA_W-1:0] nw_wa;
generate
    if (RD_REG_EN != 0) begin : g_nw
        wire        nw_src = ~is_tex & ~(src_swap_i[0] & ~is_exp);
        wire        nw_run = a_rem32 > {26'h0000000, s_left};
        // ... or, the run ending in this word and another line to come, the
        // first word of the next line
        wire        nl_hi  = (src_bpp[1] &  src_nl_pa[VRAM_AW+4])           |
                             (src_bpp[2] & |src_nl_pa[VRAM_AW+4:VRAM_AW+3]) |
                             (src_bpp[3] & |src_nl_pa[VRAM_AW+4:VRAM_AW+2]) |
                             (src_bpp[4] & |src_nl_pa[VRAM_AW+4:VRAM_AW+1]);
        wire [WA_W-1:0] nl_wa = {nl_hi,
                                 ({VRAM_AW{src_bpp[0]}} & src_nl_pa[VRAM_AW+4:5]) |
                                 ({VRAM_AW{src_bpp[1]}} & src_nl_pa[VRAM_AW+3:4]) |
                                 ({VRAM_AW{src_bpp[2]}} & src_nl_pa[VRAM_AW+2:3]) |
                                 ({VRAM_AW{src_bpp[3]}} & src_nl_pa[VRAM_AW+1:2]) |
                                 ({VRAM_AW{src_bpp[4]}} & src_nl_pa[VRAM_AW  :1])};
        assign      nw_wa  = ~nw_run ? nl_wa :
                             nw_dn   ? (src_la_wa - {{(WA_W-1){1'b0}}, 1'b1}) : (src_la_wa + {{(WA_W-1){1'b0}}, 1'b1});
        assign      nw_ok  = nw_src & (nw_run | ~last_line);
    end else begin : g_no_nw
        assign      nw_wa  = {WA_W{1'b0}};
        assign      nw_ok  = 1'b0;
        wire [PA_W-2:0] nl_unused = src_nl_pa[PA_W-1:1];  // RD_REG_EN = 0 (bit 0: walk_unused)
    end
endgenerate

//=============================================================================
// 8)  SEQUENCE
//=============================================================================
// The last token issued: the sequence (blns_gpu_px_fw) drains F and W
wire       a_last_emit = ln_on ? (a_emit & ln_last) : ((a_emit & a_last & ~t_on) | tr_fin);

//=============================================================================
// 9)  OUTPUTS
//=============================================================================
assign a_last_emit_o = a_last_emit;

assign bpp_o         = bpp;
assign src_bpp_o     = src_bpp;
assign is_copy_o     = is_copy;
assign is_tex_o      = is_tex;
assign is_exp_o      = is_exp;
assign mask_on_o     = mask_on;
assign blend_on_o    = blend_on;
assign px_op_o       = px_op;
assign op_no_d_o     = op_no_d;
assign need_src_o    = need_src;
assign need_dst_o    = need_dst;
assign transp_chk_o  = transp_chk;
assign blk_op_o      = blk_op;
assign rmp_on_o      = rmp_on;
assign rmp_dst_o     = rmp_dst;
assign mp_on_o       = mp_on;
assign aa_on_o       = aa_on;
assign a8_on_o       = a8_on;
assign bil_on_o      = bil_on;

assign t1_v_o        = t1_v;
assign t1_dwa_o      = t1_dwa;
assign t1_dboff_o    = t1_dboff;
assign t1_nbits_o    = t1_nbits;
assign t1_swa_o      = t1_swa;
assign t1_rot_o      = t1_rot;
assign t1_word_o     = t1_word;
assign t1_mir_o      = t1_mir;
assign t1_skip_o     = t1_skip;
assign t1_fill_o     = t1_fill;

assign nx_on_o       = nx_on;
assign nx_skip_o     = nx_skip;
assign nx_dwa_o      = dst_waddr;
assign nx_swa_o      = src_la_wa;
assign nw_ok_o       = nw_ok;
assign nw_wa_o       = nw_wa;

//=============================================================================
// 10) LINT CLEANUP
//=============================================================================
wire [31:0] str_unused     = {src_str32[31:16] | dst_str32[31:16], dst_str32[15:0]};
wire  [1:0] tex_m1_unused  = {tex_wm1[10], tex_hm1[10]};
wire  [2:0] tex_swap_unused = tex_cfg_i[11:9];           // used by the decoder
wire [16-DIM_W:0] t_hi_unused = {t_xl[16:DIM_W] | t_xr[16:DIM_W] | t_n[16:DIM_W]};   // a run fits the box row
wire [11:0] tex_xp_unused  = tex_xpu[32:21];             // (u, v) are 21 bits
wire  [1:0] feat_unused    = {grad_i[17], is_fillk};      // GPU_GRAD_EN = 0
wire  [1:0] grad_c_unused  = {grad_r[5], grad_b[5]};      // 5-bit channels
wire        mask_unused    = exp_mask_i;                 // GPU_BLEND_EN = 0
wire  [2:0] alpha_unused   = {alpha_en_i, a8_i, ln_aa_i}; // GPU_BLEND_EN = 0 (AA lines need blending)
wire  [1:0] rmp_mp_unused  = {rmp_mode_i[0], mpl_i};     // GPU_REMAP_EN = 0, GPU_MPLANE_EN = 0
wire        tri_unused     = tri_i;                      // no triangles
wire        bound_unused   = tex_in | tex_cfg_i[13];     // GPU_XY_EN = 0 (no affine blit)
wire [25:0] a_n_unused     = a_n_wf[31:6];               // at most 32 pixels
wire [3*DIM_W-1:0] tr_col_unused = {tr_b0_w[PA_W+DIM_W-1:PA_W], tr_b1_w[PA_W+DIM_W-1:PA_W],
                                     tr_b2_w[PA_W+DIM_W-1:PA_W]};   // the column fits the pixel address
wire  [8:0] tex_fw_unused  = {tex_cfg_i[21:14], tex_cfg_i[8]};   // SHADE, TRANSP_EN: used by W
wire [25:0] a_n_wc_unused  = a_n_wc[31:6];               // at most 32 pixels
wire [31-DIM_W:0] a_n32_unused = a_n32[31:DIM_W];         // a_n <= a_rem
wire  [3:0] tex_box_unused = {tex_box_i[23:22], tex_box_i[11:10]};   // 0: clamped by blns_gpu

endmodule // blns_gpu_px_a

`default_nettype wire
