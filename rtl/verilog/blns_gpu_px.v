//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_px
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_px.v
// Module Description : GPU pixel engine: one primitive at a time (a
//                      rectangle, a triangle's box), a pipeline of three stages joined by
//                      valid / ready registers, A -> F -> W:
//                      A  address generation, one token per cycle (the
//                         destination and source words / bits of one pixel,
//                         or of a run of pixels in one word): blns_gpu_px_a;
//                      F  the source word (cache, read ahead, write buffer or
//                         a read) and W the pixel function, the write buffer
//                         and its write-back slot, with the VRAM port and the
//                         sequence (start, run, drain, abort):
//                         blns_gpu_px_fw.
//                      The stages meet at the A -> F token register (in A),
//                      the token A offers next (read ahead by F and W) and the
//                      sequence states. Bilinear sampling (BIL_USE) adds a
//                      stage L between F and W (blns_gpu_px_l) and the tap
//                      cache in F (blns_gpu_px_tc). Each submodule's header
//                      describes its stage; the commands: doc/gpu_commands.md.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_px #(
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
    parameter                    RD_REG_EN     = 0,   // read data two cycles or more after the grant (second read-ahead entries): RD_LAT > 1
    parameter                    RD_LAT        = 1,   // read data exactly RD_LAT cycles after the grant (1-4)
    parameter                    VRAM_WORDS    = 38400, // VRAM depth in 32-bit words
    parameter                    VRAM_AW       = 16,  // VRAM word-address width
    parameter                    PA_W          = 21,  // pixel-address width (VRAM_AW + 5)
    parameter                    DIM_W         = 10,  // width/height field width
    parameter                    RB_W          = 10,  // remap table base width: max(VRAM_AW - 6, 1)
    parameter                    ASYNC_RST_EN  = 1'b1 // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  abort_i,             // abandon the rectangle
    input  wire                  freeze_i,            // hold between pixels
    input  wire                  start_i,             // start a rectangle (set-up go)
    input  wire            [2:0] gfx_mode_i,          // CTRL.GFX_MODE
    input  wire    [DIM_W-1:0]   disp_width_i,        // display width (default pitch)

// RECTANGLE CONFIGURATION (stable while busy_o; dst_base_i, tex_u0_i and
// tex_v0_i read only as the walkers are loaded, the cycle after the start)
    input  wire            [2:0] kind_i,              // 0 = FILL, 1 = COPY, 2 = COPY_TRANSP, 3 = EXPAND, 4 = TEXSPAN, 5 = TEXRECT
    input  wire                  imm_i,               // immediate source (COPY / COPY_TRANSP / EXPAND)
    input  wire           [31:0] imm_word_i,          // ... the GPU FIFO head
    input  wire                  imm_avail_i,         // ... is an immediate data word
    input  wire                  imm_short_i,         // ... no more data words for this rectangle
    output wire                  imm_pop_o,           // ... the head word taken
    input  wire            [1:0] exp_depth_i,         // EXPAND source depth: 0/1/2/3 = 1/2/4/8 bpp
    input  wire                  exp_opaque_i,        // EXPAND: source 0 writes the background
    input  wire                  exp_mask_i,          // EXPAND: the source is a coverage alpha (16 bpp)
    input  wire            [8:0] alpha_i,             // SET_ALPHA {EN, A}
    input  wire                  mix5_i,              // SET_ALPHA MIX5: LVGL's blend rule
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
    input  wire                  src_past_i,          // ... an immediate source index past 2^PA_W
    input  wire           [15:0] src_pitch_i,         // source pitch (resolved by the set-up)
    input  wire     [PA_W-1:0]   dst_base_i,          // destination first pixel, at the walk load
    input  wire           [15:0] dst_pitch_i,         // 0 = display width
    input  wire    [DIM_W-1:0]   width_i,             // pixels per run (>= 1)
    input  wire    [DIM_W-1:0]   height_i,            // runs (>= 1)
    input  wire           [15:0] fill_i,              // fill colour
    input  wire           [15:0] transp_i,            // transparent colour
    input  wire            [1:0] rmp_mode_i,          // remap: 0 off, 1 SRC, 2 DST
    input  wire     [RB_W-1:0]   rmp_base_i,          // remap table word address / 64
    input  wire                  mpl_i,               // mask plane (a copy only)
    input  wire                  msk_inv_i,           // ... drawn where the mask bit is 0
    input  wire     [PA_W-1:0]   msk_k_i,             // ... mask pixel - source pixel (RGB565A8: alpha byte - source pixel)
    input  wire                  ln_i,                // a line (a FILL kind): blns_gpu_px_a
    input  wire                  ln_aa_i,             // ... anti-aliased
    input  wire                  ln_opq_i,            // ... OPAQUE gaps
    input  wire                  ln_xmaj_i,           // ... x major
    input  wire                  ln_smaj_i,           // ... major decreasing
    input  wire                  ln_smin_i,           // ... minor decreasing (AA: negative slope)
    input  wire           [28:0] ln_g_i,              // ... error steps (AA: slope)
    input  wire           [47:0] ln_clip_i,           // ... clip window
    input  wire           [31:0] ln_pat_i,            // ... pattern
    input  wire            [4:0] ln_len_i,            // ... its length - 1
    input  wire           [28:0] ln_e0_i,             // ... first error term (AA: row position), at the walk load
    input  wire           [12:0] ln_p0_i,             // ... first major coordinate, at the walk load
    input  wire           [12:0] ln_q0_i,             // ... first minor coordinate, at the walk load
    input  wire           [12:0] ln_nm1_i,            // ... steps - 1, at the walk load
    input  wire            [4:0] ln_ph_i,             // ... first pattern phase, at the walk load

// VRAM REQUESTER
    output wire                  vreq_o,              // request: up while a demand access waits (its access may change; a read ahead may be withdrawn)
    output wire                  vwe_o,               // 1 = write
    output wire            [3:0] vbe_o,               // byte enables
    output wire  [VRAM_AW-1:0]   vaddr_o,             // word address
    output wire  [VRAM_AW-1:0]   vwaddr_o,            // ... of a write (= vaddr_o with vwe_o), from a flop
    output wire           [31:0] vwdata_o,            // write data
    input  wire                  vgnt_i,              // access issued this cycle
    input  wire                  vrvalid_i,           // read data valid: exactly RD_LAT cycles after the grant, in order
    input  wire           [31:0] vrdata_i,            // read data

// STATUS
    output wire                  busy_o,              // rectangle running
    output wire                  done_o,              // rectangle completed (1 cycle)
    output wire                  held_o,              // frozen: nothing in flight
    output wire                  bound_o              // an access at or past VRAM_WORDS (1 cycle)
);

//=============================================================================
// 1)  PARAMETERS AND STAGE SIGNALS
//=============================================================================
localparam WA_W       = VRAM_AW + 1;                   // word address + "past 2^VRAM_AW" bit
// The fill colour varies per token with a gradient or a line's OPAQUE gaps;
// without both it is the rectangle's, not carried through t1 / t2
localparam FILL_PIPE  = ((GPU_GRAD_EN != 0) || LINE_USE) ? 1 : 0;

// pragma translate_off
generate
    if ((RD_LAT < 1) || (RD_LAT > 4) || ((RD_REG_EN != 0) != (RD_LAT > 1))) begin : CHECK_RD_LAT
        initial $fatal(1, "blns_gpu_px: RD_LAT (%0d) must be 1..4 and RD_REG_EN (%0d) = (RD_LAT > 1).", RD_LAT, RD_REG_EN);
    end
    if ((PA_W != VRAM_AW + 5) || (RB_W != ((VRAM_AW > 6) ? (VRAM_AW - 6) : 1))) begin : CHECK_WIDTHS
        initial $fatal(1, "blns_gpu_px: PA_W (%0d) must be VRAM_AW + 5, RB_W (%0d) max(VRAM_AW - 6, 1) (VRAM_AW %0d).", PA_W, RB_W, VRAM_AW);
    end
endgenerate
// pragma translate_on

// Sequence (blns_gpu_px_fw -> blns_gpu_px_a)
wire                  go;                               // the rectangle starts
wire                  a_init;                           // walkers loaded
wire                  a_run;                            // one token per cycle
wire                  a_abort;                          // dropped: flush the buffer
wire                  a_last_emit;                      // the last token leaves A

// Operation (blns_gpu_px_a -> blns_gpu_px_fw)
wire            [4:0] bpp;                              // one-hot {16, 8, 4, 2, 1} bpp
wire            [4:0] src_bpp;                          // source depth, one-hot
wire                  is_copy;
wire                  is_tex;
wire                  is_exp;
wire                  mask_on;
wire                  blend_on;
wire            [3:0] px_op;
wire            [1:0] blk_op;
wire                  op_no_d;
wire                  need_src;
wire                  need_dst;
wire                  transp_chk;
wire                  rmp_on;
wire                  rmp_dst;
wire                  mp_on;
wire                  aa_on;
wire                  a8_on;                            // RGB565A8: each pixel's alpha from its A8 byte
wire                  bil_on;                           // bilinear: tap tokens

// A -> F token
wire                  t1_v;
wire       [WA_W-1:0] t1_dwa;
wire            [4:0] t1_dboff;
wire            [5:0] t1_nbits;
wire       [WA_W-1:0] t1_swa;
wire            [4:0] t1_rot;
wire                  t1_word;
wire                  t1_mir;
wire                  t1_skip;
wire           [15:0] t1_fill;
wire    [VRAM_AW-1:0] t1_mwa;
wire                  t1_mhi;                           // ... an A8 word past 2^VRAM_AW
wire            [4:0] t1_mrot;
wire            [7:0] t1_cov;
wire           [10:0] t1_k;                             // bilinear: the tap's weight
wire                  t1_tlast;                         // ... its pixel's last tap
wire                  t1_ypar;                          // ... its texel row parity
wire                  f_take;                           // F takes the token

// The token A offers next, the word after it (read ahead)
wire                  nx_on;
wire                  nx_skip;
wire       [WA_W-1:0] nx_dwa;
wire       [WA_W-1:0] nx_swa;
wire                  nw_ok;
wire       [WA_W-1:0] nw_wa;
wire    [VRAM_AW-1:0] nx_mwa;                           // ... its A8 word (RGB565A8, read ahead)
wire                  nx_mhi;

//=============================================================================
// 2)  A: ADDRESS GENERATION
//=============================================================================
blns_gpu_px_a #(
    .GPU_XY_EN     (GPU_XY_EN),
    .GPU_GRAD_EN   (GPU_GRAD_EN),
    .GPU_BLEND_EN  (GPU_BLEND_EN),
    .TRI_USE       (TRI_USE),
    .GPU_REMAP_EN  (GPU_REMAP_EN),
    .GPU_MPLANE_EN (GPU_MPLANE_EN),
    .GPU_IMM_EN    (GPU_IMM_EN),
    .LINE_USE      (LINE_USE),
    .BIL_USE       (BIL_USE),
    .RUNAHEAD_EN   (RUNAHEAD_EN),
    .RD_REG_EN     (RD_REG_EN),
    .FILL_PIPE     (FILL_PIPE),
    .VRAM_AW       (VRAM_AW),
    .PA_W          (PA_W),
    .DIM_W         (DIM_W),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_px_a (
// CLOCK & RESET
    .hclk_i           (hclk_i),
    .hresetn_i        (hresetn_i),
// CONTROL
    .abort_i          (abort_i),
    .freeze_i         (freeze_i),
    .gfx_mode_i       (gfx_mode_i),
    .disp_width_i     (disp_width_i),
// SEQUENCE
    .go_i             (go),
    .a_init_i         (a_init),
    .a_run_i          (a_run),
    .a_abort_i        (a_abort),
    .a_last_emit_o    (a_last_emit),
// RECTANGLE CONFIGURATION
    .kind_i           (kind_i),
    .imm_i            (imm_i),
    .exp_depth_i      (exp_depth_i),
    .exp_mask_i       (exp_mask_i),
    .alpha_en_i       (alpha_i[8]),
    .a8_i             (a8_i),
    .tex_filt_i       (tex_filt_i),
    .tri_i            (tri_i),
    .tri_e_i          (tri_e_i),
    .tri_s_i          (tri_s_i),
    .tex_cfg_i        (tex_cfg_i),
    .tex_u0_i         (tex_u0_i),
    .tex_v0_i         (tex_v0_i),
    .tex_step_i       (tex_step_i),
    .tex_rstep_i      (tex_rstep_i),
    .tex_box_i        (tex_box_i),
    .grad_i           (grad_i),
    .grad_cnt0_i      (grad_cnt0_i),
    .grad_val0_i      (grad_val0_i),
    .px_op_i          (px_op_i),
    .dst_swap_i       (dst_swap_i),
    .src_swap_i       (src_swap_i),
    .src_base_i       (src_base_i),
    .src_past_i       (src_past_i),
    .src_pitch_i      (src_pitch_i),
    .dst_base_i       (dst_base_i),
    .dst_pitch_i      (dst_pitch_i),
    .width_i          (width_i),
    .height_i         (height_i),
    .fill_i           (fill_i),
    .rmp_mode_i       (rmp_mode_i),
    .mpl_i            (mpl_i),
    .msk_k_i          (msk_k_i),
    .transp_i         (transp_i),
    .ln_i             (ln_i),
    .ln_aa_i          (ln_aa_i),
    .ln_opq_i         (ln_opq_i),
    .ln_xmaj_i        (ln_xmaj_i),
    .ln_smaj_i        (ln_smaj_i),
    .ln_smin_i        (ln_smin_i),
    .ln_g_i           (ln_g_i),
    .ln_clip_i        (ln_clip_i),
    .ln_pat_i         (ln_pat_i),
    .ln_len_i         (ln_len_i),
    .ln_e0_i          (ln_e0_i),
    .ln_p0_i          (ln_p0_i),
    .ln_q0_i          (ln_q0_i),
    .ln_nm1_i         (ln_nm1_i),
    .ln_ph_i          (ln_ph_i),
// OPERATION
    .bpp_o            (bpp),
    .src_bpp_o        (src_bpp),
    .is_copy_o        (is_copy),
    .is_tex_o         (is_tex),
    .is_exp_o         (is_exp),
    .mask_on_o        (mask_on),
    .blend_on_o       (blend_on),
    .px_op_o          (px_op),
    .blk_op_o         (blk_op),
    .op_no_d_o        (op_no_d),
    .need_src_o       (need_src),
    .need_dst_o       (need_dst),
    .transp_chk_o     (transp_chk),
    .rmp_on_o         (rmp_on),
    .rmp_dst_o        (rmp_dst),
    .mp_on_o          (mp_on),
    .aa_on_o          (aa_on),
    .a8_on_o          (a8_on),
    .bil_on_o         (bil_on),
// A -> F TOKEN
    .t1_v_o           (t1_v),
    .t1_dwa_o         (t1_dwa),
    .t1_dboff_o       (t1_dboff),
    .t1_nbits_o       (t1_nbits),
    .t1_swa_o         (t1_swa),
    .t1_rot_o         (t1_rot),
    .t1_word_o        (t1_word),
    .t1_mir_o         (t1_mir),
    .t1_skip_o        (t1_skip),
    .t1_fill_o        (t1_fill),
    .t1_mwa_o         (t1_mwa),
    .t1_mhi_o         (t1_mhi),
    .t1_mrot_o        (t1_mrot),
    .t1_cov_o         (t1_cov),
    .t1_k_o           (t1_k),
    .t1_tlast_o       (t1_tlast),
    .t1_ypar_o        (t1_ypar),
    .f_take_i         (f_take),
// NEXT TOKEN
    .nx_on_o          (nx_on),
    .nx_skip_o        (nx_skip),
    .nx_dwa_o         (nx_dwa),
    .nx_swa_o         (nx_swa),
    .nw_ok_o          (nw_ok),
    .nw_wa_o          (nw_wa),
    .nx_mwa_o         (nx_mwa),
    .nx_mhi_o         (nx_mhi)
);

//=============================================================================
// 3)  F, W, VRAM PORT AND SEQUENCE
//=============================================================================
blns_gpu_px_fw #(
    .RD_REG_EN     (RD_REG_EN),
    .RD_LAT        (RD_LAT),
    .VRAM_WORDS    (VRAM_WORDS),
    .VRAM_AW       (VRAM_AW),
    .RB_W          (RB_W),
    .GPU_BLEND_EN  (GPU_BLEND_EN),
    .GPU_REMAP_EN  (GPU_REMAP_EN),
    .GPU_MPLANE_EN (GPU_MPLANE_EN),
    .GPU_IMM_EN    (GPU_IMM_EN),
    .BIL_USE       (BIL_USE),
    .FILL_PIPE     (FILL_PIPE),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_px_fw (
// CLOCK & RESET
    .hclk_i           (hclk_i),
    .hresetn_i        (hresetn_i),
// CONTROL
    .abort_i          (abort_i),
    .freeze_i         (freeze_i),
    .start_i          (start_i),
// SEQUENCE
    .go_o             (go),
    .a_init_o         (a_init),
    .a_run_o          (a_run),
    .a_abort_o        (a_abort),
    .a_last_emit_i    (a_last_emit),
// RECTANGLE CONFIGURATION
    .exp_opaque_i     (exp_opaque_i),
    .alpha_i          (alpha_i),
    .mix5_i           (mix5_i),
    .tex_tr_en_i      (tex_cfg_i[8]),
    .tex_shade_i      (tex_cfg_i[21:14]),
    .transp_i         (transp_i),
    .rmp_base_i       (rmp_base_i),
    .msk_inv_i        (msk_inv_i),
    .imm_i            (imm_i),
    .imm_word_i       (imm_word_i),
    .imm_avail_i      (imm_avail_i),
    .imm_short_i      (imm_short_i),
    .imm_pop_o        (imm_pop_o),
// OPERATION
    .bpp_i            (bpp),
    .src_bpp_i        (src_bpp),
    .is_copy_i        (is_copy),
    .is_tex_i         (is_tex),
    .is_exp_i         (is_exp),
    .mask_on_i        (mask_on),
    .blend_on_i       (blend_on),
    .px_op_i          (px_op),
    .blk_op_i         (blk_op),
    .op_no_d_i        (op_no_d),
    .need_src_i       (need_src),
    .need_dst_i       (need_dst),
    .transp_chk_i     (transp_chk),
    .rmp_on_i         (rmp_on),
    .rmp_dst_i        (rmp_dst),
    .mp_on_i          (mp_on),
    .aa_on_i          (aa_on),
    .a8_on_i          (a8_on),
    .bil_on_i         (bil_on),
// A -> F TOKEN
    .t1_v_i           (t1_v),
    .t1_dwa_i         (t1_dwa),
    .t1_dboff_i       (t1_dboff),
    .t1_nbits_i       (t1_nbits),
    .t1_swa_i         (t1_swa),
    .t1_rot_i         (t1_rot),
    .t1_word_i        (t1_word),
    .t1_mir_i         (t1_mir),
    .t1_skip_i        (t1_skip),
    .t1_fill_i        (t1_fill),
    .t1_mwa_i         (t1_mwa),
    .t1_mhi_i         (t1_mhi),
    .t1_mrot_i        (t1_mrot),
    .t1_cov_i         (t1_cov),
    .t1_k_i           (t1_k),
    .t1_tlast_i       (t1_tlast),
    .t1_ypar_i        (t1_ypar),
    .f_take_o         (f_take),
// NEXT TOKEN
    .nx_on_i          (nx_on),
    .nx_skip_i        (nx_skip),
    .nx_dwa_i         (nx_dwa),
    .nx_swa_i         (nx_swa),
    .nw_ok_i          (nw_ok),
    .nw_wa_i          (nw_wa),
    .nx_mwa_i         (nx_mwa),
    .nx_mhi_i         (nx_mhi),
// VRAM REQUESTER
    .vreq_o           (vreq_o),
    .vwe_o            (vwe_o),
    .vbe_o            (vbe_o),
    .vaddr_o          (vaddr_o),
    .vwaddr_o         (vwaddr_o),
    .vwdata_o         (vwdata_o),
    .vgnt_i           (vgnt_i),
    .vrvalid_i        (vrvalid_i),
    .vrdata_i         (vrdata_i),
// STATUS
    .busy_o           (busy_o),
    .done_o           (done_o),
    .held_o           (held_o),
    .bound_o          (bound_o)
);

endmodule // blns_gpu_px

`default_nettype wire
