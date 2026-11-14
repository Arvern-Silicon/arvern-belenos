//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_dec
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_dec.v
// Module Description : GPU command decoder: decodes one word per cycle from
//                      the FIFO, or from a command list (CALL), and owns the
//                      settings (surfaces, size, colours, texture, clip,
//                      gradient, vertices, remap, mask and alpha plane
//                      pointers, line pen and pattern, texture filter, blend
//                      rule), the EXEC
//                      fields, the stream bookkeeping (operand owed, the
//                      immediate source's tagged data in the pushed stream,
//                      the DISCARD resynchronisation and its marker)
//                      and the error record. An EXEC starts the set-up stage;
//                      the decoder waits on stall_i (the set-up, and
//                      the engine too without run-ahead). An invalid word
//                      stops it (ERR) until CLEAR_ERR or GPU_EN = 0.
//                      Command semantics: doc/gpu_commands.md.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_dec #(
    parameter                   GPU_XY_EN     = 1,    // SET_DST XY, SET_XY, SET_CLIP, EXEC_TEXRECT, SET_STEP_ROW, SET_TEXBOX, BOUND valid
    parameter                   GPU_GRAD_EN   = 1,    // SET_GRAD valid
    parameter                   GPU_BLEND_EN  = 0,    // SET_ALPHA valid
    parameter             [0:0] TRI_USE       = 1'b0, // triangles built (blns_gpu: GPU_TRI_EN & GPU_XY_EN): SET_V0..V2 and EXEC_FILL TRI valid
    parameter                   GPU_REMAP_EN  = 1,    // SET_AUX REMAP_TABLE, REMAP fields valid
    parameter                   GPU_MPLANE_EN = 1,    // SET_AUX MASK_PLANE, EXEC_COPY MPLANE valid
    parameter                   GPU_IMM_EN    = 1,    // SET_SRC [20] IMM valid
    parameter             [0:0] LINE_USE      = 1'b0, // lines built (blns_gpu: GPU_LINE_EN & GPU_XY_EN): EXEC_FILL LINE, SET_AUX SEL 2 / 3 valid
    parameter             [0:0] BIL_USE       = 1'b0, // bilinear built (blns_gpu: GPU_BILINEAR_EN & GPU_XY_EN): SET_AUX SEL 5 valid
    parameter                   PA_W          = 21,   // pixel-address width
    parameter                   VRAM_WORDS    = 38400, // VRAM depth in 32-bit words
    parameter                   VRAM_AW       = 16,   // VRAM word-address width
    parameter                   DIM_W         = 10,   // width/height field width
    parameter                   RB_W          = 10,   // remap table base width: max(VRAM_AW - 6, 1)
    parameter                   ASYNC_RST_EN  = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                 hclk_i,               // clock
    input  wire                 hresetn_i,            // active-low reset

// CONTROL
    input  wire                 gpu_en_i,             // 0 = idle, leave ERR
    input  wire                 freeze_i,             // hold (no word decoded)
    input  wire                 flush_i,              // FIFO flushed this cycle
    input  wire                 clear_err_i,          // GPU_CTRL.CLEAR_ERR write
    input  wire                 discard_i,            // GPU_CTRL.DISCARD write with GPU_EN = 1 (1 cycle)
    input  wire                 bound_err_i,          // a rectangle access past VRAM_WORDS
    input  wire                 refr_done_i,          // a frame sent to the panel ended (1 cycle)
    input  wire   [DIM_W-1:0]   disp_width_i,         // frame width (pitch 0 for SET_XY)

// FIFO
    input  wire          [31:0] head_i,               // FIFO head word
    input  wire                 empty_i,              // FIFO empty
    output wire                 pop_o,                // consume the head word
    input  wire                 push_i,               // a word pushed into the FIFO
    input  wire          [31:0] push_data_i,          // the pushed word
    output wire                 push_tag_o,           // ... is immediate data (stored with it)
    output wire                 push_owed_o,          // immediate data words still to be pushed
    output wire                 push_part_o,          // the pushed stream is partial (operand or data owed, immediate source armed)
    input  wire                 head_tag_i,           // the FIFO head is immediate data
    input  wire                 head_mrk_i,           // the FIFO head is a discard marker
    input  wire                 head_cut_i,           // ... cutting an immediate rectangle (its data owed)
    input  wire                 imm_busy_i,           // an immediate-source rectangle is not done
    input  wire                 imm_eng_i,            // the engine still draws an immediate rectangle

// COMMAND LIST
    input  wire                 list_active_i,        // the list is the word source
    input  wire          [31:0] list_head_i,          // list head word
    input  wire                 list_empty_i,         // no list word buffered
    input  wire                 list_last_i,          // the list head is its last word
    output wire                 list_pop_o,           // consume the list head word
    output wire                 call_start_o,         // start a list (1 cycle, N > 0)
    output wire   [VRAM_AW-1:0] call_addr_o,          // list word address
    output wire          [23:0] call_n_o,             // list length in words

// DMA
    input  wire                 stall_i,              // the decoder waits: set-up running (and the engine, without run-ahead)
    input  wire                 px_busy_i,            // the pixel engine is drawing (FENCE waits)
    input  wire          [31:0] bound_word_i,         // the EXEC of the rectangle the engine draws
    output wire                 exec_start_o,         // start a primitive (1 cycle; a line: at its operand)
    output wire           [2:0] exec_kind_o,          // 0 = FILL, 1 = COPY, 2 = COPY_TRANSP, 3 = EXPAND, 4 = TEXSPAN
    output wire           [1:0] exp_depth_o,          // EXPAND source depth: 0/1/2/3 = 1/2/4/8 bpp
    output wire                 exp_opaque_o,         // EXPAND: source 0 writes the background
    output wire                 exp_mask_o,           // EXPAND: the source is a coverage alpha (16 bpp)
    output wire           [8:0] alpha_o,              // SET_ALPHA {EN, A}
    output wire                 mix5_o,               // SET_ALPHA [9] MIX5: LVGL's blend rule
    output wire                 a8_o,                 // the EXEC's source is RGB565A8 (SRC_FMT 5: a copy or a texture)
    output wire           [1:0] tex_filt_o,           // SET_AUX TEX_FILTER {TBORDER, BILINEAR}
    output wire                 tri_o,                // EXEC_FILL TRI: the triangle of v0..v2
    output wire                 tri_empty_o,          // TRI: nothing to draw (address mode, outside the clip)
    output wire          [95:0] tri_v_o,              // SET_V0..V2 {v2, v1, v0}, each {y, x} signed 12.4
    output wire                 line_o,               // EXEC_FILL LINE: the line from the pen to its operand
    output wire                 line_start_o,         // ... a line starts (with exec_start_o, the pen still its start)
    output wire           [3:0] line_opt_o,           // ... {PH_RST, OPAQUE, NO_LAST, AA}
    output wire          [31:0] line_p1_o,            // ... the pen {y, x} signed 12.4: its start at exec_start_o, its end point after
    output wire          [31:0] line_pat_o,           // LINE_PATTERN: the pattern
    output wire           [4:0] line_len_o,           // ... its length - 1
    output wire                 line_phclr_o,         // the pattern phase to 0 (LINE_PATTERN word, RESET_STATE; 1 cycle)
    output wire          [21:0] tex_cfg_o,            // SET_TEX {SHADE, BOUND, FREE_PITCH, swaps, TRANSP_EN, log2 h, log2 w}
    output wire          [31:0] tex_uv_o,             // SET_UV {u0, v0}, unsigned 10.6
    output wire          [31:0] tex_step_o,           // SET_STEP {du, dv}, signed 5.11
    output wire          [31:0] tex_rstep_o,          // SET_STEP_ROW {du', dv'}, signed 5.11
    output wire          [23:0] tex_box_o,            // SET_TEXBOX {TH, TW}, each clamped to 512
    output wire                 xy_mode_o,            // destination in x/y mode
    output wire          [15:0] xy_x_o,               // x of the first pixel (signed)
    output wire          [15:0] xy_y_o,               // y of the first pixel (signed)
    output wire          [47:0] clip_o,               // SET_CLIP {y0, x0, y1, x1}, signed, inclusive
    output wire          [48:0] grad_o,               // {RGB, SET_GRAD_RGB {dR, dG, dB}, SET_GRAD {EN, STEP, AXIS, N}}
    output wire           [3:0] px_op_o,              // raster operation
    output wire           [2:0] dst_swap_o,           // {X, Y, CL}
    output wire           [2:0] src_swap_o,           // {X, Y, CL}
    output wire    [PA_W-1:0]   src_base_o,           // source base pixel address
    output wire          [15:0] src_pitch_o,          // source pitch (0 = display width)
    output wire    [PA_W-1:0]   dst_base_o,           // destination base pixel address (address mode)
    output wire    [PA_W-1:0]   origin_o,             // x/y mode: the surface origin
    output wire          [15:0] dst_pitch_o,          // destination pitch (0 = display width)
    output wire   [DIM_W-1:0]   width_o,              // rectangle width (>= 1)
    output wire   [DIM_W-1:0]   height_o,             // rectangle height (>= 1)
    output wire          [15:0] fill_o,               // fill colour
    output wire          [15:0] transp_o,             // transparent colour
    output wire           [1:0] rmp_mode_o,           // REMAP of the EXEC (texture: SET_TEX's): 0 off, 1 SRC, 2 DST
    output wire    [RB_W-1:0]   rmp_base_o,           // SET_AUX REMAP_TABLE: table word address / 64
    output wire                 mpl_o,                // EXEC_COPY MPLANE
    output wire    [PA_W-1:0]   msk_base_o,           // SET_AUX MASK_PLANE: mask pixel of the source's first pixel
                                                      // (an RGB565A8 EXEC: ALPHA_PLANE, the alpha byte of that pixel)
    output wire                 msk_inv_o,            // ... INV: draw where the mask bit is 0
    output wire                 imm_o,                // the EXEC's source is the immediate data
    output wire                 imm_go_o,             // an EXEC with the immediate source taken (1 cycle)
    output wire                 mrk_drop_o,           // a marker abandons the immediate rectangle (1 cycle)

// STATUS / EVENTS
    output wire                 err_o,                // decoder in error
    output wire                 opnd_wait_o,          // command popped, operand word pending
    output wire                 refr_wait_o,          // WAIT_REFR_DONE: waiting for the end of a frame
    output wire           [3:0] err_opcode_o,         // opcode of the last invalid word
    output wire           [2:0] err_cause_o,          // 1 invalid, 2 absent, 3 format, 4 list cut, 5/6 bounds (rectangle / CALL)
    output wire          [31:0] err_word_o,           // the offending word (bounds: the rectangle's EXEC)
    output wire                 err_evt_o,            // entered error (1 cycle)
    output wire          [23:0] fence_o,              // TAG of the last FENCE reached
    output wire                 fence_irq_o           // FENCE with [24] IRQ reached (1 cycle)
);

//=============================================================================
// 1)  OPCODES AND STATES
//=============================================================================
localparam [3:0] OP_SET_SRC    = 4'h1;
localparam [3:0] OP_SET_DST    = 4'h2;
localparam [3:0] OP_SET_SIZE   = 4'h3;
localparam [3:0] OP_SET_FILL   = 4'h4;
localparam [3:0] OP_SET_TRANSP = 4'h5;
localparam [3:0] OP_SET_EXT    = 4'h6;
localparam [3:0] OP_CALL       = 4'h7;
localparam [3:0] OP_EXEC_FILL  = 4'h8;
localparam [3:0] OP_EXEC_COPY  = 4'h9;
localparam [3:0] OP_EXEC_COPYT = 4'hA;
localparam [3:0] OP_EXEC_SPAN  = 4'hB;
localparam [3:0] OP_EXEC_EXP   = 4'hC;
localparam [3:0] OP_EXEC_TEX   = 4'hD;
localparam [3:0] OP_EXEC_TRECT = 4'hE;
localparam [3:0] OP_FENCE      = 4'hF;

localparam [1:0] ST_CMD        = 2'd0;          // decode a command word
localparam [1:0] ST_OPND       = 2'd1;          // waiting for an operand word
localparam [1:0] ST_ERR        = 2'd2;          // invalid opcode at the FIFO head

localparam [4:0] TGT_SRC       = 5'd0;          // operand target
localparam [4:0] TGT_DST       = 5'd1;
localparam [4:0] TGT_FILL      = 5'd2;
localparam [4:0] TGT_TRANSP    = 5'd3;
localparam [4:0] TGT_UV        = 5'd4;
localparam [4:0] TGT_STEP      = 5'd5;
localparam [4:0] TGT_CALL      = 5'd6;
localparam [4:0] TGT_CLIP      = 5'd7;
localparam [4:0] TGT_RSTEP     = 5'd8;
localparam [4:0] TGT_V0        = 5'd9;
localparam [4:0] TGT_V1        = 5'd10;
localparam [4:0] TGT_V2        = 5'd11;
localparam [4:0] TGT_SKIP      = 5'd12;         // the operand of a flushed command: discarded
localparam [4:0] TGT_GRGB      = 5'd13;
localparam [4:0] TGT_RMP       = 5'd14;
localparam [4:0] TGT_MSK       = 5'd15;
localparam [4:0] TGT_LINE      = 5'd16;         // EXEC_FILL LINE: the end point
localparam [4:0] TGT_PEN       = 5'd17;
localparam [4:0] TGT_PAT       = 5'd18;
localparam [4:0] TGT_A8        = 5'd19;         // SET_AUX ALPHA_PLANE: the pointer
localparam [4:0] TGT_FILT      = 5'd20;         // SET_AUX TEX_FILTER: its operand, ignored

localparam [3:0] EXT_TEX       = 4'h0;          // SET_EXT sub-commands ([27:24])
localparam [3:0] EXT_UV        = 4'h1;
localparam [3:0] EXT_STEP      = 4'h2;
localparam [3:0] EXT_XY        = 4'h3;
localparam [3:0] EXT_CLIP      = 4'h4;
localparam [3:0] EXT_RSTEP     = 4'h5;
localparam [3:0] EXT_TEXBOX    = 4'h6;
localparam [3:0] EXT_GRAD      = 4'h7;
localparam [3:0] EXT_ALPHA     = 4'h8;
localparam [3:0] EXT_V0        = 4'h9;
localparam [3:0] EXT_V1        = 4'hA;
localparam [3:0] EXT_V2        = 4'hB;
localparam [3:0] EXT_GRGB      = 4'hC;
localparam [3:0] EXT_AUX       = 4'hD;
localparam [3:0] EXT_EXT2      = 4'hF;

localparam [7:0] X2_WAIT_REFR  = 8'h01;         // SET_EXT2 codes ([23:16])
localparam [7:0] X2_RESET      = 8'h02;

localparam [3:0] AUX_RMP       = 4'd0;          // SET_AUX selectors ([23:20])
localparam [3:0] AUX_MSK       = 4'd1;
localparam [3:0] AUX_PEN       = 4'd2;
localparam [3:0] AUX_PAT       = 4'd3;
localparam [3:0] AUX_A8        = 4'd4;
localparam [3:0] AUX_FILT      = 4'd5;

localparam       SZ_W          = (DIM_W < 14) ? DIM_W : 14;
localparam       XY_USE        = (GPU_XY_EN     != 0);
localparam       AFFINE_USE    = XY_USE;                   // affine blits come with x/y
localparam       GRAD_USE      = (GPU_GRAD_EN   != 0);
localparam       BLEND_USE     = (GPU_BLEND_EN  != 0);
localparam       REMAP_USE     = (GPU_REMAP_EN  != 0);
localparam       MPLANE_USE    = (GPU_MPLANE_EN != 0);
localparam       IMM_USE       = (GPU_IMM_EN    != 0);

//=============================================================================
// 2)  DECODE
//=============================================================================
wire  [1:0] state;
wire  [4:0] tgt;

// Word source: the list while one is active, the FIFO otherwise. Immediate
// data and a discard marker at the FIFO head are not a command: the decoder
// sees no word
wire        head_dat  = IMM_USE & head_tag_i;
wire [31:0] head      = list_active_i ? list_head_i  : head_i;
wire        empty     = list_active_i ? list_empty_i : (empty_i | head_dat | head_mrk_i);

// The commands followed by an operand word, by encoding: one list for the
// decoder (gated there by the features built) and the pushed stream
// (EXEC_FILL [24] LINE in every build)
function opnd_cmd;
    input [7:0] c;                                     // word [31:24]: opcode, SET_EXT sub-command / LINE
    begin
        opnd_cmd = (c[7:4] == OP_SET_SRC)  | (c[7:4] == OP_SET_DST) | (c[7:4] == OP_SET_FILL) |
                   (c[7:4] == OP_SET_TRANSP) | (c[7:4] == OP_CALL) | ((c[7:4] == OP_EXEC_FILL) & c[0]) |
                   ((c[7:4] == OP_SET_EXT) &
                    ((c[3:0] == EXT_UV)  | (c[3:0] == EXT_STEP) | (c[3:0] == EXT_CLIP) |
                     (c[3:0] == EXT_RSTEP) | (c[3:0] == EXT_V0) | (c[3:0] == EXT_V1) |
                     (c[3:0] == EXT_V2)  | (c[3:0] == EXT_GRGB) | (c[3:0] == EXT_AUX)));
    end
endfunction

wire  [3:0] opcode    = head[31:28];
wire        is_src    = (opcode == OP_SET_SRC);
wire        is_dst    = (opcode == OP_SET_DST);
wire        is_size   = (opcode == OP_SET_SIZE);
wire        is_fill   = (opcode == OP_SET_FILL);
wire        is_transp = (opcode == OP_SET_TRANSP);
wire        is_efill  = (opcode == OP_EXEC_FILL);
wire        is_ecopy  = (opcode == OP_EXEC_COPY);
wire        is_ecopyt = (opcode == OP_EXEC_COPYT);
wire        is_span   = (opcode == OP_EXEC_SPAN);
wire        is_expand = (opcode == OP_EXEC_EXP);
wire        is_tex    = (opcode == OP_EXEC_TEX);
wire        is_trect  = (opcode == OP_EXEC_TRECT) & AFFINE_USE;
wire        is_fence  = (opcode == OP_FENCE);
wire        is_ext    = (opcode == OP_SET_EXT);
wire  [3:0] ext_sub   = head[27:24];
wire        is_call   = (opcode == OP_CALL) & ~list_active_i;   // no CALL inside a list
wire        is_settex = is_ext & (ext_sub == EXT_TEX);
wire        is_setuv  = is_ext & (ext_sub == EXT_UV);
wire        is_setstp = is_ext & (ext_sub == EXT_STEP);
// Commands of an absent feature are invalid
wire        is_setxy  = is_ext & (ext_sub == EXT_XY) & XY_USE;
wire        is_setclip= is_ext & (ext_sub == EXT_CLIP) & XY_USE;
wire        is_rstep  = is_ext & (ext_sub == EXT_RSTEP) & AFFINE_USE;
wire        is_texbox = is_ext & (ext_sub == EXT_TEXBOX) & AFFINE_USE;
wire        is_setgrad= is_ext & (ext_sub == EXT_GRAD) & GRAD_USE;
wire        is_setgrgb= is_ext & (ext_sub == EXT_GRGB) & GRAD_USE;
wire        is_alpha  = is_ext & (ext_sub == EXT_ALPHA) & BLEND_USE;
wire        is_setv0  = is_ext & (ext_sub == EXT_V0) & TRI_USE;
wire        is_setv1  = is_ext & (ext_sub == EXT_V1) & TRI_USE;
wire        is_setv2  = is_ext & (ext_sub == EXT_V2) & TRI_USE;
wire        is_ext2   = is_ext & (ext_sub == EXT_EXT2);
wire        is_wait   = is_ext2 & (head[23:16] == X2_WAIT_REFR);
wire        is_rstate = is_ext2 & (head[23:16] == X2_RESET);
wire        is_trifil = is_efill & head[7] & TRI_USE;
wire        is_tritex = is_trect & head[7] & TRI_USE;        // EXEC_TEXRECT [7] TRI: textured triangle
wire        tri_bad   = (is_efill | (opcode == OP_EXEC_TRECT)) & head[7] & ~TRI_USE;
wire        xy_bad    = is_dst & head[16] & ~XY_USE;
wire        bound_bad = is_settex & head[13] & ~AFFINE_USE;
wire        imm_bad   = is_src & head[20] & ~IMM_USE;        // immediate source: not built
wire        mask_bad  = is_expand & head[3] & ~BLEND_USE;      // EXPAND MASK: not built
// EXEC_FILL [24] LINE: the end point follows ([16] AA needs blending; TRI and
// LINE together are invalid). Refused for either, it takes no operand
wire        is_line   = is_efill & head[24];
wire        line_abs  = is_line & (~LINE_USE | (head[16] & ~BLEND_USE));
wire        line_inv  = is_line & head[7];
wire        line_ok   = is_line & ~line_abs & ~line_inv;
// Immediate source: armed by SET_SRC words from GPU_CMD only; the EXEC that
// takes it comes from GPU_CMD too (a list carries no data: SET_SRC IMM, or a
// copy / EXPAND while armed, in a list are invalid); a copy reads it without
// SRC swaps (invalid otherwise)
wire        imm_arm;
wire        is_srcx   = is_ecopy | is_ecopyt | is_expand;
wire        imm_exec  = IMM_USE & imm_arm & is_srcx & ~list_active_i;
wire        imm_inv   = IMM_USE & ((is_src & head[20] & list_active_i) |
                                   (imm_arm & is_srcx & list_active_i) |
                                   (imm_exec & (is_ecopy | is_ecopyt) & (head[10:8] != 3'b000)));
// SET_AUX [23:20] SEL: 0 REMAP_TABLE, 1 MASK_PLANE ([15:0] PITCH: 0 only, the
// source pitch), 2 LINE_PEN, 3 LINE_PATTERN, 4 ALPHA_PLANE ([15:0] PITCH: 0
// only, blending), 5 TEX_FILTER ([0] BILINEAR, [1] TBORDER: blending), 6-15
// reserved. REMAP fields: EXEC_FILL / COPY / COPY_TRANSP / EXPAND [13:12],
// SET_TEX [15:14] (3 reserved); EXEC_COPY / COPY_TRANSP [11] MPLANE
wire        is_aux    = is_ext & (ext_sub == EXT_AUX);
wire  [3:0] aux_sel   = head[23:20];
wire        aux_rmp   = is_aux & (aux_sel == AUX_RMP);
wire        aux_msk   = is_aux & (aux_sel == AUX_MSK);
wire        aux_pen   = is_aux & (aux_sel == AUX_PEN);
wire        aux_pat   = is_aux & (aux_sel == AUX_PAT);
wire        aux_a8    = is_aux & (aux_sel == AUX_A8);
wire        aux_filt  = is_aux & (aux_sel == AUX_FILT);
wire        aux_rsv   = is_aux & (aux_sel[3] | (aux_sel[2] & aux_sel[1]));
wire        aux_absent = (aux_rmp & ~REMAP_USE) | (aux_msk & (~MPLANE_USE | (head[15:0] != 16'h0000))) |
                         ((aux_pen | aux_pat) & ~LINE_USE) |
                         (aux_a8 & (~BLEND_USE | (head[15:0] != 16'h0000))) |
                         (aux_filt & (~BIL_USE | (head[1] & ~BLEND_USE)));
wire        rmp_fld   = is_efill | is_ecopy | is_ecopyt | is_expand;
wire  [1:0] rmp_f     = is_settex ? head[15:14] : head[13:12];
wire        rmp_rsv   = (rmp_fld | is_settex) & (rmp_f == 2'd3);
wire        rmp_bad   = (rmp_fld | is_settex) & (rmp_f[1] ^ rmp_f[0]) & ~REMAP_USE;
wire        mpl_bad   = (is_ecopy | is_ecopyt) & head[11] & ~MPLANE_USE;
// Defined commands of an absent feature (ERR_CAUSE 2, the others are 1)
wire        ext_absent = is_ext & ((((ext_sub == EXT_XY) | (ext_sub == EXT_CLIP)) & ~XY_USE) |
                                   (((ext_sub == EXT_RSTEP) | (ext_sub == EXT_TEXBOX)) & ~AFFINE_USE) |
                                   (((ext_sub == EXT_GRAD) | (ext_sub == EXT_GRGB)) & ~GRAD_USE) |
                                   ((ext_sub == EXT_ALPHA) & ~BLEND_USE) |
                                   (((ext_sub == EXT_V0) | (ext_sub == EXT_V1) | (ext_sub == EXT_V2)) & ~TRI_USE));
// Formats: SET_SRC [19:16] SRC_FMT (0 = the destination's, 1-4 = 1/2/4/8 bpp for
// EXPAND, 5 = RGB565A8 for the copies and textures: blending, else absent),
// SET_DST [19:17] DST_FMT (0 = GFX_MODE); the others are not built
wire  [3:0] src_fmt;
wire        src_a8_w     = (head[19:16] == 4'd5);       // SET_SRC word: RGB565A8
wire        src_a8_abs   = is_src & src_a8_w & ~BLEND_USE;
wire        fmt_a8       = BLEND_USE & (src_fmt == 4'd5);   // the setting: RGB565A8
wire        src_fmt_bad  = is_src & (head[19:16] > 4'd4) & ~src_a8_w;
wire        dst_fmt_bad  = is_dst & (head[19:17] != 3'd0);
wire        exec_fmt_bad = (is_expand & ((src_fmt == 4'd0) | fmt_a8)) |
                           ((is_ecopy | is_ecopyt | is_tex | (opcode == OP_EXEC_TRECT)) & (src_fmt != 4'd0) & ~fmt_a8);
wire        absent    = ext_absent | ((opcode == OP_EXEC_TRECT) & ~AFFINE_USE) |
                        tri_bad | xy_bad | bound_bad | imm_bad | aux_absent | rmp_bad | mpl_bad | mask_bad | line_abs |
                        src_a8_abs;
// An RGB565A8 copy takes neither the mask plane nor the immediate source (one
// auxiliary word holder; no alpha in the pushed data): invalid
wire        a8_inv    = fmt_a8 & (is_ecopy | is_ecopyt) & (head[11] | imm_exec);
wire        fmt_bad   = src_fmt_bad | dst_fmt_bad | exec_fmt_bad;
wire        is_exec   = is_efill | is_ecopy | is_ecopyt;
wire        has_opnd  = opnd_cmd(head[31:24]) & ~ext_absent & ~aux_absent & ~aux_rsv &
                        ~((opcode == OP_CALL) & list_active_i) & ~(is_line & ~line_ok);
wire        is_valid  = has_opnd | is_size | is_exec | is_span | is_expand | is_tex | is_trect |
                        is_settex | is_setxy | is_texbox | is_setgrad | is_alpha | is_fence |
                        is_wait | is_rstate;
wire        cmd_ok    = is_valid & ~absent & ~fmt_bad & ~rmp_rsv & ~imm_inv & ~line_inv & ~a8_inv;

wire        st_cmd    = (state == ST_CMD);
wire        st_opnd   = (state == ST_OPND);
wire        st_err    = (state == ST_ERR);

// A list must not end between a command and its operand: its last word then
// stops the decoder as an invalid word (ERR_OPCODE = CALL)
wire        list_cut  = list_active_i & list_last_i & has_opnd;

// The triangle box is registered from the vertices and the clip window: a TRI
// waits one cycle after either changes
wire        can_run   = gpu_en_i & ~flush_i & ~freeze_i & ~stall_i & ~empty;
// WAIT_REFR_DONE stays at the head until a frame ends after the decoder reached
// it (one ending in that very cycle counts)
wire        refr_seen;
wire        cmd_go    = can_run & st_cmd & ~(is_fence & px_busy_i) & ~(is_wait & ~refr_seen) &
                        ~(imm_exec & (imm_busy_i | imm_eng_i));   // one immediate rectangle at a time
wire        cmd_pop   = cmd_go  & cmd_ok & ~list_cut;
wire        cmd_bad   = cmd_go  & (~cmd_ok | list_cut);
wire        opnd_pop  = can_run & st_opnd;

//=============================================================================
// 3)  STATE
//=============================================================================
// The pushed stream: set when the next word pushed is an operand. A flush drops
// the command in progress; the decoder then discards that operand when it comes.
// DISCARD clears it (and the immediate source's state below): the next word
// pushed is a command; the marker queued at the cut (blns_gpu), or the flush
// of the same write, brings the decoder back in step
wire        push_has  = opnd_cmd(push_data_i[31:24]);
wire        push_owed;
wire        owed_en   = ~gpu_en_i | push_i;
wire        owed_nxt  = gpu_en_i & ~discard_i & ~push_owed & push_has;

wire        push_dat;                                  // the pushed word is immediate data
wire        push_arm;                                  // the immediate source armed in the pushed stream
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_push_owed (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((owed_en & ~push_dat) | discard_i), .d_i(owed_nxt), .q_o(push_owed));

// Immediate data in the pushed stream: a pushed SET_SRC IMM's operand is N,
// held until the next EXEC_COPY / COPY_TRANSP / EXPAND pushed (another
// SET_SRC disarms it); the N words pushed after that EXEC are data (not
// parsed). A flush disarms (in ERR only the CLEAR_ERR: an ABORT leaves the
// stream bookkeeping to it, as the decoder's own arm); GPU_EN = 0 and DISCARD
// also drop the data still owed (the words a flush leaves owed are pushed
// tagged, and the decoder drops them).
generate
    if (IMM_USE) begin : g_push_imm
        wire        p_act;                                 // data words owed
        wire        p_nsel;                                // the next operand pushed is N
        wire        p_arm;                                 // N held, waiting for the EXEC
        wire [23:0] p_cnt;
        wire        p_cmd    = push_i & ~p_act & ~push_owed;
        wire        p_opnd   = push_i & ~p_act &  push_owed;
        wire        p_src    = p_cmd & (push_data_i[31:28] == OP_SET_SRC);
        wire        p_exec   = p_cmd & p_arm & ((push_data_i[31:28] == OP_EXEC_COPY) |
                                                (push_data_i[31:28] == OP_EXEC_COPYT) |
                                                (push_data_i[31:28] == OP_EXEC_EXP));
        wire        p_n      = p_opnd & p_nsel;
        wire        p_dpush  = push_i & p_act;
        wire        p_flush  = (clear_err_i & st_err) | (flush_i & ~st_err);   // flush_go without GPU_EN
        wire        p_last   = (p_cnt == 24'd1);
        // Priority: GPU_EN = 0 / DISCARD > flush > the pushed word (DISCARD
        // never comes with a push)
        wire        p_act_nxt  = gpu_en_i & ~discard_i & (p_exec ? (p_cnt != 24'd0) : (p_act & ~(p_dpush & p_last)));
        wire        p_nsel_nxt = gpu_en_i & ~discard_i & ~p_flush & (p_src ? push_data_i[20] : (p_nsel & ~p_opnd));
        wire        p_arm_nxt  = gpu_en_i & ~discard_i & ~p_flush & (p_n | (p_arm & ~p_src & ~p_exec));
        wire [23:0] p_cnt_nxt  = p_n ? push_data_i[23:0] : (p_cnt - 24'd1);
        arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_p_st (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({p_act_nxt, p_nsel_nxt, p_arm_nxt}), .q_o({p_act, p_nsel, p_arm}));
        arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_p_cnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(p_n | p_dpush), .d_i(p_cnt_nxt), .q_o(p_cnt));
        assign push_dat    = p_act;
        assign push_arm    = p_arm;
        assign push_owed_o = p_act;
    end else begin : g_no_push_imm
        assign push_dat    = 1'b0;
        assign push_arm    = 1'b0;
        assign push_owed_o = 1'b0;
    end
endgenerate

// Priority: GPU_EN = 0 > flush (CLEAR_ERR in ERR; ABORT / CLEAR_ERR otherwise) > decode.
// A rectangle running past the VRAM is recorded even in ERR (it precedes the word
// that stopped the decoder); a flush in the same cycle abandons it unrecorded.
wire        flush_go  = gpu_en_i & ((clear_err_i & st_err) | (flush_i & ~st_err));
wire        bound_evt = bound_err_i & gpu_en_i & ~flush_go;
wire        call_bad;                                  // CALL list past VRAM_WORDS
wire        err_go    = bound_evt | cmd_bad | call_bad;
// (a DISCARD in the flush's write: the operand owed is not pushed, no skip)
wire        skip_go   = flush_go & push_owed & ~discard_i;

// A DISCARD marker at the FIFO head (behind a list: the CALL before it runs
// first) is popped whatever the decoder does, but in ERR (CLEAR_ERR flushes
// it): the command waiting for its operand (a cut one's skip too) is dropped,
// the immediate source disarmed (also when SET_SRC IMM armed it, its N owed),
// the immediate rectangle whose data it cut abandoned. It touches nothing the
// set-up or the engine reads, so it does not wait for them
wire        mrk_pop   = head_mrk_i & ~list_active_i & gpu_en_i & ~flush_i & ~freeze_i & ~st_err;

wire        state_en  = ~gpu_en_i | flush_go | err_go | (cmd_pop & has_opnd) | opnd_pop | mrk_pop;
wire  [1:0] state_nxt = ~gpu_en_i                ? ST_CMD  :
                        skip_go                  ? ST_OPND :
                        flush_go                 ? ST_CMD  :
                        err_go                   ? ST_ERR  :
                        (cmd_pop & has_opnd)     ? ST_OPND :
                                                   ST_CMD;

arv_ipdff #(.WIDTH(2), .RST_VAL(ST_CMD), .ARST_EN(ASYNC_RST_EN)) u_state (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(state_en), .d_i(state_nxt), .q_o(state));

wire        tgt_en    = skip_go | (cmd_pop & has_opnd);
// (one-hot: has_opnd words only; SET_SRC is TGT_SRC = 0)
wire  [4:0] tgt_dec   = ({5{is_src}}     & TGT_SRC)    |
                        ({5{is_dst}}     & TGT_DST)    |
                        ({5{is_fill}}    & TGT_FILL)   |
                        ({5{is_transp}}  & TGT_TRANSP) |
                        ({5{is_setuv}}   & TGT_UV)     |
                        ({5{is_setstp}}  & TGT_STEP)   |
                        ({5{is_call}}    & TGT_CALL)   |
                        ({5{is_setclip}} & TGT_CLIP)   |
                        ({5{is_rstep}}   & TGT_RSTEP)  |
                        ({5{is_setv0}}   & TGT_V0)     |
                        ({5{is_setv1}}   & TGT_V1)     |
                        ({5{is_setv2}}   & TGT_V2)     |
                        ({5{is_setgrgb}} & TGT_GRGB)   |
                        ({5{aux_rmp}}    & TGT_RMP)    |
                        ({5{aux_msk}}    & TGT_MSK)    |
                        ({5{is_line}}    & TGT_LINE)   |
                        ({5{aux_pen}}    & TGT_PEN)    |
                        ({5{aux_pat}}    & TGT_PAT)    |
                        ({5{aux_a8}}     & TGT_A8)     |
                        ({5{aux_filt}}   & TGT_FILT);
wire  [4:0] tgt_nxt   = skip_go ? TGT_SKIP : tgt_dec;

arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_tgt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tgt_en), .d_i(tgt_nxt), .q_o(tgt));

// ERR_OPCODE / ERR_CAUSE of the last error; GPU_ERR: the word that stopped the
// decoder (a CALL past the VRAM: its address operand), or the EXEC whose
// rectangle ran past the VRAM (loaded at every EXEC)
wire [31:0] err_word;
wire  [3:0] err_opcode;
wire  [2:0] err_cause;
wire  [2:0] cause_nxt = bound_evt ? 3'd5 : call_bad ? 3'd6 :
                        list_cut ? 3'd4 : fmt_bad ? 3'd3 : absent ? 3'd2 : 3'd1;
wire        exec_ld;
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_err_opcode (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(err_go),
             .d_i(bound_evt ? bound_word_i[31:28] : (list_cut | call_bad) ? OP_CALL : opcode), .q_o(err_opcode));
arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_err_cause (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(err_go), .d_i(cause_nxt), .q_o(err_cause));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_err_word (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cmd_bad | call_bad | exec_ld | bound_evt),
             .d_i(bound_evt ? bound_word_i : head), .q_o(err_word));

// FENCE [23:0] TAG, [24] IRQ, [25] AUTO (GPU_FENCE + 1, the tag ignored):
// GPU_FENCE holds the tag of the last one reached
wire        fence_pop = cmd_pop & is_fence;
wire [23:0] fence;
wire [23:0] fence_nxt = head[25] ? (fence + 24'd1) : head[23:0];
arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_fence (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(fence_pop), .d_i(fence_nxt), .q_o(fence));

// WAIT_REFR_DONE: armed once it is the next command (a rectangle before it may
// still draw, the GPU may be frozen), released by the next end of a frame.
// Priority: popped, flushed (ABORT in ERR too: the wait is no stream
// bookkeeping) or GPU_EN = 0 (both clear) > the frame ends
wire        refr_armed;
wire        wait_at   = gpu_en_i & ~flush_i & ~empty & st_cmd & is_wait;
wire        wait_clr  = ~gpu_en_i | flush_go | (flush_i & st_err) | (cmd_pop & is_wait);
wire        armed_nxt = ~wait_clr & (refr_armed | wait_at);
wire        seen_nxt  = ~wait_clr & (refr_seen | ((refr_armed | wait_at) & refr_done_i));
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_refr_wait (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({armed_nxt, seen_nxt}), .q_o({refr_armed, refr_seen}));

//=============================================================================
// 4)  CONFIGURATION REGISTERS
//=============================================================================
// SET_EXT2 RESET_STATE: every setting below back to its reset value (not the
// EXEC fields, the error record, GPU_FENCE nor the list)
wire        rst_go      = cmd_pop & is_rstate;
// The registers' data selects use the word's decode (st_cmd / st_opnd), the
// pop only their enables: rst_sel selects the reset value whenever rst_go
// loads (an operand word is never taken as RESET_STATE)
wire        rst_sel     = st_cmd & is_rstate;
wire [PA_W-1:0] src_base;
wire     [15:0] src_pitch;
wire [PA_W-1:0] dst_base;
wire     [15:0] dst_pitch;
wire     [15:0] fill;
wire     [15:0] transp;
wire  [DIM_W-1:0] width;
wire  [DIM_W-1:0] height;

wire        opnd_src    = opnd_pop & (tgt == TGT_SRC);
wire        opnd_dst    = opnd_pop & (tgt == TGT_DST);
wire        opnd_fill   = opnd_pop & (tgt == TGT_FILL);
wire        opnd_transp = opnd_pop & (tgt == TGT_TRANSP);
wire        opnd_uv     = opnd_pop & (tgt == TGT_UV);
wire        opnd_step   = opnd_pop & (tgt == TGT_STEP);
wire        opnd_call   = opnd_pop & (tgt == TGT_CALL);
wire        opnd_clip   = opnd_pop & (tgt == TGT_CLIP);
wire        opnd_rstep  = opnd_pop & (tgt == TGT_RSTEP);
wire        delta_pop   = cmd_pop  & (is_span | is_expand | is_tex | (is_trect & ~is_tritex));

// CALL: [23:0] N, then the list address operand (taken from the FIFO). A list
// must lie inside the VRAM: address + N <= VRAM_WORDS, else ERR (cause 6).
// The bound is set up at the CALL word: VRAM_WORDS - N (call_lim), N past
// VRAM_WORDS (call_ovf), N != 0 (call_nz); the operand cycle then compares
// the address with call_lim only.
localparam [31:0] VW32      = VRAM_WORDS;
localparam [25:0] VW26      = VW32[25:0];               // VRAM_WORDS <= 2^24
wire     [23:0] call_n;
wire            call_nz;
wire            call_ovf;
wire  [VRAM_AW:0] call_lim;
wire     [25:0] call_lim_d  = VW26 - {2'b00, head[23:0]};
arv_ipdff #(.WIDTH(24 + 2 + VRAM_AW + 1), .RST_VAL({24'd0, 2'b00, VW26[VRAM_AW:0]}), .ARST_EN(ASYNC_RST_EN)) u_call_n (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cmd_pop & is_call),
             .d_i({head[23:0], (head[23:0] != 24'd0), call_lim_d[25], call_lim_d[VRAM_AW:0]}),
             .q_o({call_n, call_nz, call_ovf, call_lim}));
assign          call_bad    = opnd_call & call_nz & (call_ovf | ({1'b0, head[VRAM_AW-1:0]} > call_lim));

arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_src_pitch (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_src) | rst_go), .d_i(rst_sel ? 16'h0000 : head[15:0]), .q_o(src_pitch));
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_src_fmt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_src) | rst_go), .d_i(rst_sel ? 4'h0 : head[19:16]), .q_o(src_fmt));
// (the operand of SET_SRC IMM is N: the source base is kept)
wire        src_imm_op;
wire        exec_pop;                                  // an EXEC taken (section below)
arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_src_base (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_src & ~src_imm_op) | rst_go), .d_i(rst_sel ? {PA_W{1'b0}} : head[PA_W-1:0]), .q_o(src_base));

// Immediate source: SET_SRC IMM (from GPU_CMD) arms, another SET_SRC from
// GPU_CMD disarms; the EXEC taking it, a flush, a DISCARD marker and GPU_EN =
// 0 disarm.
// RESET_STATE leaves it. imm: the EXEC's source is immediate
wire        imm;
generate
    if (IMM_USE) begin : g_imm_regs
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_src_imm_op (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cmd_pop & is_src), .d_i(head[20]), .q_o(src_imm_op));
        wire arm_en  = ~gpu_en_i | flush_go | mrk_pop | (cmd_pop & ((is_src & ~list_active_i) | imm_exec));
        wire arm_nxt = gpu_en_i & ~flush_go & cmd_pop & is_src & ~list_active_i & head[20];
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_imm_arm (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(arm_en), .d_i(arm_nxt), .q_o(imm_arm));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_imm (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop), .d_i(imm_exec), .q_o(imm));
    end else begin : g_no_imm_regs
        assign src_imm_op = 1'b0;
        assign imm_arm    = 1'b0;
        assign imm        = 1'b0;
        wire [3:0] imm_unused = {head_tag_i, head_cut_i, imm_busy_i, imm_eng_i};
        wire [1:0] arm_unused = {imm_arm, is_srcx};            // (imm_exec, imm_inv: IMM_USE)
    end
endgenerate
// EXEC_SPAN / EXEC_EXPAND: [27:14] signed DELTA added to the destination base
wire [PA_W-1:0] span_delta;
generate
    if (PA_W > 14) begin : g_delta_sext
        assign span_delta = {{(PA_W-14){head[27]}}, head[27:14]};
    end else begin : g_delta_trunc
        assign span_delta = head[14+PA_W-1:14];
    end
endgenerate

// x/y mode: SET_DST.XY makes the operand the surface origin (pixel (0, 0));
// SET_XY moves the position (x, y); the set-up stage computes the start
// address origin + y * pitch + x (pitch 0 = frame width)
wire            xy_mode;
wire [PA_W-1:0] origin;
wire     [15:0] cur_x;
wire     [15:0] cur_y;
wire     [15:0] set_x      = {{4{head[11]}}, head[11:0]};
wire     [15:0] set_y      = {{4{head[23]}}, head[23:12]};
wire            xy_pop     = cmd_pop & is_setxy;
wire     [15:0] delta16    = {{2{head[27]}}, head[27:14]};

// x/y mode: the line pitch is the SET_DST pitch, pitch 0 the frame width of
// the time of the SET_DST / SET_XY, for the start address and the line step
// alike. xy_pitch_q holds it registered: loaded at the SET_DST word (its
// pitch, pitch 0 the frame width then) and again at the operand and SET_XY,
// so a SET_DST cut by a flush before its operand keeps its pitch
wire            dst_word   = st_cmd & is_dst;                // the SET_DST word at the head
wire     [15:0] xy_pitch;
wire     [15:0] xy_pitch_q;
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_xy_pitch (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_dst) | opnd_dst | xy_pop | rst_go),
             .d_i(rst_sel ? 16'h0000 : xy_pitch), .q_o(xy_pitch_q));
// The SET_DST pitch itself (address mode). With x/y, a pitch that is not 0 is
// the one xy_pitch_q holds (loaded with it at the word; the operand and
// SET_XY reload it unchanged): only a "pitch 0" flag is kept
generate
    if (XY_USE) begin : g_dst_pz
        wire        dst_pz;
        arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_dst_pz (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_dst) | rst_go),
             .d_i(rst_sel | (head[15:0] == 16'h0000)), .q_o(dst_pz));
        wire        xy_pz  = dst_word ? (head[15:0] == 16'h0000) : dst_pz;
        assign      xy_pitch  = xy_pz ? {{(16-DIM_W){1'b0}}, disp_width_i} : (dst_word ? head[15:0] : xy_pitch_q);
        assign      dst_pitch = xy_pitch_q & {16{~dst_pz}};
    end else begin : g_dst_pitch
        arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_dst_pitch (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_dst) | rst_go), .d_i(rst_sel ? 16'h0000 : head[15:0]), .q_o(dst_pitch));
        wire [15:0] xp_p   = dst_word ? head[15:0] : dst_pitch;
        assign      xy_pitch  = (xp_p == 16'h0000) ? {{(16-DIM_W){1'b0}}, disp_width_i} : xp_p;
    end
endgenerate

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_xy_mode (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_dst) | rst_go), .d_i(rst_sel ? 1'b0 : (head[16] & XY_USE)), .q_o(xy_mode));
arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_origin (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_dst) | rst_go), .d_i(rst_sel ? {PA_W{1'b0}} : head[PA_W-1:0]), .q_o(origin));

// Priority: SET_DST (back to (0, 0)) > SET_XY > DELTA (the selects: the SET_DST
// operand is the only one loading them in ST_OPND, SET_XY / RESET_STATE decoded
// from the word in ST_CMD)
wire            xy_en      = opnd_dst | xy_pop | delta_pop;
wire            xy_zero    = st_opnd | rst_sel;
wire     [15:0] cur_x_nxt  = xy_zero ? 16'h0000 : (is_ext & (ext_sub == EXT_XY)) ? set_x : (cur_x + delta16);
wire     [15:0] cur_y_nxt  = xy_zero ? 16'h0000 : set_y;
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_cur_x (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((xy_en) | rst_go), .d_i(cur_x_nxt), .q_o(cur_x));
// (y: SET_XY's 12-bit field, sign-extended, or 0: bits 15-12 not kept)
wire     [11:0] cur_y12;
arv_ipdff #(.WIDTH(12), .ARST_EN(ASYNC_RST_EN)) u_cur_y (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_dst | xy_pop) | rst_go), .d_i(cur_y_nxt[11:0]), .q_o(cur_y12));
assign          cur_y      = {{4{cur_y12[11]}}, cur_y12};

// Address mode. Priority: SET_DST > DELTA
wire [PA_W-1:0] dst_base_nxt = st_opnd ? head[PA_W-1:0] : (dst_base + span_delta);

arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_dst_base (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_dst | delta_pop) | rst_go), .d_i(rst_sel ? {PA_W{1'b0}} : dst_base_nxt), .q_o(dst_base));

// Clip window {y0, x0, y1, x1}: reset to the full range
wire     [47:0] clip;
arv_ipdff #(.WIDTH(24), .RST_VAL(24'h800800), .ARST_EN(ASYNC_RST_EN)) u_clip_lo (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_setclip) | rst_go), .d_i(rst_sel ? 24'h800800 : head[23:0]), .q_o(clip[47:24]));
arv_ipdff #(.WIDTH(24), .RST_VAL(24'h7FF7FF), .ARST_EN(ASYNC_RST_EN)) u_clip_hi (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_clip & XY_USE) | rst_go), .d_i(rst_sel ? 24'h7FF7FF : head[23:0]), .q_o(clip[23:0]));

// SET_STEP_ROW, SET_TEXBOX, SET_GRAD {[18] RGB, [17] EN, [16:13] STEP, [12] AXIS,
// [11:0] N}, SET_GRAD_RGB {[29:20] dR, [19:10] dG, [9:0] dB}
wire     [31:0] tex_rstep;
wire     [23:0] tex_box;
wire     [18:0] grad;
wire     [29:0] grad_rgb;
wire            opnd_grgb   = opnd_pop & (tgt == TGT_GRGB);
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_tex_rstep (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_rstep & AFFINE_USE) | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(tex_rstep));
// TW / TH clamped to 512 for the engine: with affine blits as loaded (10
// bits each), else as read
generate
    if (AFFINE_USE) begin : g_tex_box_c
        wire  [9:0] tb_tw = (head[11:0]  > 12'd512) ? 10'd512 : head[9:0];
        wire  [9:0] tb_th = (head[23:12] > 12'd512) ? 10'd512 : head[21:12];
        wire [19:0] tex_box_q;
        arv_ipdff #(.WIDTH(20), .ARST_EN(ASYNC_RST_EN)) u_tex_box (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_texbox) | rst_go), .d_i(rst_sel ? 20'h0 : {tb_th, tb_tw}), .q_o(tex_box_q));
        assign tex_box = {2'b00, tex_box_q[19:10], 2'b00, tex_box_q[9:0]};
    end else begin : g_tex_box
        // (no x/y: SET_TEXBOX is refused with ERR_CAUSE 2 and is_texbox is
        // 0, so only RESET_STATE would load the box, and with 0: the box is
        // tied to its reset value, no flop, and the 512 clamp of the x/y
        // branch has nothing to clamp)
        assign tex_box = 24'h000000;
    end
endgenerate
arv_ipdff #(.WIDTH(19), .ARST_EN(ASYNC_RST_EN)) u_grad (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_setgrad) | rst_go), .d_i(rst_sel ? 19'h0 : head[18:0]), .q_o(grad));
arv_ipdff #(.WIDTH(30), .ARST_EN(ASYNC_RST_EN)) u_grad_rgb (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_grgb & GRAD_USE) | rst_go), .d_i(rst_sel ? 30'h0 : head[29:0]), .q_o(grad_rgb));

// Triangle: vertices {y, x} signed 12.4 (the set-up computes its box)
wire            opnd_v0  = opnd_pop & (tgt == TGT_V0);
wire            opnd_v1  = opnd_pop & (tgt == TGT_V1);
wire            opnd_v2  = opnd_pop & (tgt == TGT_V2);
wire     [31:0] tri_v0;
wire     [31:0] tri_v1;
wire     [31:0] tri_v2;
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_tri_v0 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_v0) | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(tri_v0));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_tri_v1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_v1) | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(tri_v1));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_tri_v2 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_v2) | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(tri_v2));

// Lines: the pen {y, x} (12.4), moved to the end point of every EXEC_FILL
// LINE operand taken (in either mode): the set-up takes the line's start (the
// pen before it) at exec_start_o, the cycle it moves; without blending (no AA)
// its fractions are not kept: a solid line uses the pixels only.
// LINE_PATTERN: [4:0] LEN - 1 (word), the pattern (operand). RESET_STATE: pen
// (0, 0), the solid pattern (32 ones)
wire            opnd_line = opnd_pop & (tgt == TGT_LINE);
wire            opnd_pen  = opnd_pop & (tgt == TGT_PEN);
wire            opnd_pat  = opnd_pop & (tgt == TGT_PAT);
wire     [31:0] pen;
wire     [31:0] lpat;
wire      [4:0] llen;
generate
    if (LINE_USE) begin : g_line_regs
        if (BLEND_USE) begin : g_pen_aa
            arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_pen (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(opnd_line | opnd_pen | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(pen));
        end else begin : g_pen_px
            wire [23:0] pen_px;
            arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_pen_px (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(opnd_line | opnd_pen | rst_go),
                 .d_i(rst_sel ? 24'h0 : {head[31:20], head[15:4]}), .q_o(pen_px));
            assign pen = {pen_px[23:12], 4'h0, pen_px[11:0], 4'h0};
        end
        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFF_FFFF), .ARST_EN(ASYNC_RST_EN)) u_lpat (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(opnd_pat | rst_go), .d_i(rst_sel ? 32'hFFFF_FFFF : head), .q_o(lpat));
        arv_ipdff #(.WIDTH(5), .RST_VAL(5'd31), .ARST_EN(ASYNC_RST_EN)) u_llen (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & aux_pat) | rst_go), .d_i(rst_sel ? 5'd31 : head[4:0]), .q_o(llen));
    end else begin : g_no_line_regs
        assign pen  = 32'h0;
        assign lpat = 32'hFFFF_FFFF;
        assign llen = 5'd31;
        wire [1:0] line_unused = {opnd_pen, opnd_pat};   // GPU_LINE_EN = 0: SET_AUX SEL 2 / 3 refused
    end
endgenerate

// SET_ALPHA {[9] MIX5, [8] EN, [7:0] A}: blending at 16 bpp, MIX5 the blend
// rule of every blend (LVGL's: a 5-bit factor, truncated)
wire      [8:0] alpha;
arv_ipdff #(.WIDTH(9), .ARST_EN(ASYNC_RST_EN)) u_alpha (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_alpha) | rst_go), .d_i(rst_sel ? 9'h000 : head[8:0]), .q_o(alpha));

// RGB565A8 (blending): SET_AUX ALPHA_PLANE operand = the byte address of the
// alpha of the source's first pixel (VRAM_AW + 2 bits); the EXEC's flag a8
// (SRC_FMT 5 on a copy or a texture) selects it as the plane the set-up takes
// K from, in place of the mask plane (exclusive: a8_inv)
wire            opnd_a8   = opnd_pop & (tgt == TGT_A8);
wire            opnd_filt = opnd_pop & (tgt == TGT_FILT);
wire            mix5;
wire            a8;
wire [PA_W-1:0] a8_base;
wire      [1:0] tex_filt;
generate
    if (BLEND_USE) begin : g_a8_regs
        wire [VRAM_AW+1:0] a8_ptr;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_mix5 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_alpha) | rst_go), .d_i(~rst_sel & head[9]), .q_o(mix5));
        arv_ipdff #(.WIDTH(VRAM_AW + 2), .ARST_EN(ASYNC_RST_EN)) u_a8_ptr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(opnd_a8 | rst_go), .d_i(rst_sel ? {(VRAM_AW+2){1'b0}} : head[VRAM_AW+1:0]), .q_o(a8_ptr));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_a8 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop),
             .d_i(fmt_a8 & (is_ecopy | is_ecopyt | is_tex | is_trect)), .q_o(a8));
        assign a8_base = {{(PA_W-VRAM_AW-2){1'b0}}, a8_ptr};
    end else begin : g_no_a8_regs
        assign mix5    = 1'b0;
        assign a8      = 1'b0;
        assign a8_base = {PA_W{1'b0}};
        wire   a8_unused = opnd_a8;                          // GPU_BLEND_EN = 0: SET_AUX ALPHA_PLANE refused
    end
    // SET_AUX TEX_FILTER {[1] TBORDER (blending), [0] BILINEAR}: set by the
    // word (a flush before its operand keeps it), the operand ignored
    if (BIL_USE) begin : g_filt_regs
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_tex_filt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & aux_filt) | rst_go),
             .d_i(rst_sel ? 2'b00 : {head[1] & BLEND_USE, head[0]}), .q_o(tex_filt));
    end else begin : g_no_filt_regs
        assign tex_filt = 2'b00;
    end
endgenerate
wire            filt_unused = opnd_filt;                   // the TEX_FILTER operand: reserved
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_fill (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_fill) | rst_go), .d_i(rst_sel ? 16'h0000 : head[15:0]), .q_o(fill));
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_transp (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_transp) | rst_go), .d_i(rst_sel ? 16'h0000 : head[15:0]), .q_o(transp));

// SET_AUX: REMAP_TABLE operand = the table's word address (a multiple of 64:
// its low 6 bits ignored); MASK_PLANE [16] INV, operand = the 1-bpp pixel
// address of the mask bit of the source's first pixel. SET_TEX [15:14] REMAP
// (sticky, as SHADE)
wire            opnd_rmp    = opnd_pop & (tgt == TGT_RMP);
wire            opnd_msk    = opnd_pop & (tgt == TGT_MSK);
wire [RB_W-1:0] rmp_base;
wire      [1:0] rmp_tex;
wire [PA_W-1:0] msk_base;
wire            msk_inv;
generate
    if (REMAP_USE) begin : g_rmp_regs
        wire [RB_W-1:0] rmp_opnd;
        if (VRAM_AW > 6) begin : g_rmp_aw
            assign rmp_opnd = head[VRAM_AW-1:6];
        end else begin : g_rmp_aw0
            assign rmp_opnd = {RB_W{1'b0}};                  // one table word group: the table at word 0
        end
        arv_ipdff #(.WIDTH(RB_W), .ARST_EN(ASYNC_RST_EN)) u_rmp_base (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(opnd_rmp | rst_go), .d_i(rst_sel ? {RB_W{1'b0}} : rmp_opnd), .q_o(rmp_base));
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_rmp_tex (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_settex) | rst_go), .d_i(rst_sel ? 2'd0 : head[15:14]), .q_o(rmp_tex));
    end else begin : g_no_rmp_regs
        assign rmp_base = {RB_W{1'b0}};
        assign rmp_tex  = 2'd0;
        wire   rmp_unused = opnd_rmp;                        // GPU_REMAP_EN = 0: SET_AUX REMAP_TABLE refused
    end
    if (MPLANE_USE) begin : g_msk_regs
        arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_msk_base (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(opnd_msk | rst_go), .d_i(rst_sel ? {PA_W{1'b0}} : head[PA_W-1:0]), .q_o(msk_base));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_msk_inv (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & aux_msk) | rst_go), .d_i(~rst_sel & head[16]), .q_o(msk_inv));
    end else begin : g_no_msk_regs
        assign msk_base = {PA_W{1'b0}};
        assign msk_inv  = 1'b0;
        wire   msk_unused = opnd_msk;                        // GPU_MPLANE_EN = 0: SET_AUX MASK_PLANE refused
    end
endgenerate

// SET_EXT: SET_TEX {[23:16] SHADE, [13] BOUND, [12] FREE_PITCH, [11:9] swaps,
// [8] TRANSP_EN, [7:4] log2 h, [3:0] log2 w}; SET_UV and SET_STEP operands
wire     [21:0] tex_cfg;
wire     [31:0] tex_uv;
wire     [31:0] tex_step;
arv_ipdff #(.WIDTH(22), .ARST_EN(ASYNC_RST_EN)) u_tex_cfg (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((cmd_pop & is_settex) | rst_go), .d_i(rst_sel ? 22'h0 : {head[23:16], head[13] & AFFINE_USE, head[12:0]}), .q_o(tex_cfg));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_tex_uv (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_uv) | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(tex_uv));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_tex_step (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((opnd_step) | rst_go), .d_i(rst_sel ? 32'h0 : head), .q_o(tex_step));

// SET_SIZE: [13:0] width, [27:14] height, DIM_W bits used, 0 -> 1
// Width and height reset to 1: a size of 0 is not representable.
wire [DIM_W-1:0] width_fld;
wire [DIM_W-1:0] height_fld;
generate
    if (DIM_W > SZ_W) begin : g_size_zext
        assign width_fld  = {{(DIM_W-SZ_W){1'b0}}, head[SZ_W-1:0]};
        assign height_fld = {{(DIM_W-SZ_W){1'b0}}, head[14+SZ_W-1:14]};
    end else begin : g_size_trunc
        assign width_fld  = head[SZ_W-1:0];
        assign height_fld = head[14+SZ_W-1:14];
    end
endgenerate

localparam [DIM_W-1:0] DIM_ONE = {{(DIM_W-1){1'b0}}, 1'b1};

wire [DIM_W-1:0] width_nxt  = (width_fld  == {DIM_W{1'b0}}) ? DIM_ONE : width_fld;
// EXEC_SPAN / EXEC_TEXSPAN: WIDTH (N) x 1
wire [DIM_W-1:0] height_nxt = ((height_fld == {DIM_W{1'b0}}) | is_span | is_tex) ? DIM_ONE : height_fld;

wire             size_pop   = cmd_pop & (is_size | is_span | is_tex);

arv_ipdff #(.WIDTH(DIM_W), .RST_VAL(DIM_ONE), .ARST_EN(ASYNC_RST_EN)) u_width (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((size_pop) | rst_go), .d_i(rst_sel ? DIM_ONE : width_nxt), .q_o(width));
arv_ipdff #(.WIDTH(DIM_W), .RST_VAL(DIM_ONE), .ARST_EN(ASYNC_RST_EN)) u_height (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((size_pop) | rst_go), .d_i(rst_sel ? DIM_ONE : height_nxt), .q_o(height));

// EXEC fields: [3:0] PX_OP, [6:4] DST {X,Y,CL}, [10:8] SRC {X,Y,CL} (COPY only).
// EXEC_SPAN is a FILL with op 0 and no swaps. EXEC_EXPAND: op 0, DST swaps,
// [2] OPAQUE, [3] MASK, the source depth from SET_SRC.SRC_FMT (exp_depth_nxt).
// EXEC_TEXSPAN: op 0, the SET_TEX swaps.
// (a line: its fields at the word, its start at the operand)
assign      exec_pop  = cmd_pop & (is_exec | is_span | is_expand | is_tex | is_trect);
assign      exec_ld   = exec_pop;
wire        exec_go   = (exec_pop & ~is_line) | opnd_line;
wire  [3:0] src_fmt_m1    = src_fmt - 4'd1;
wire  [1:0] exp_depth_nxt = src_fmt_m1[1:0];               // SRC_FMT 1-4 = 1/2/4/8 bpp

// EXEC_FILL [7] TRI: the triangle (nothing in address mode or outside the clip)
wire               tri_fill;
wire               tri_empty;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_tri (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop),
             .d_i({is_trifil | is_tritex, ~xy_mode}), .q_o({tri_fill, tri_empty}));
// EXEC_FILL [24] LINE, [19:16] {PH_RST, OPAQUE, NO_LAST, AA}
wire               line;
wire         [3:0] line_opt;
generate
    if (LINE_USE) begin : g_line_exec
        arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_line (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop),
             .d_i({is_line, head[19:16] & {4{is_line}}}), .q_o({line, line_opt}));
    end else begin : g_no_line_exec
        assign line     = 1'b0;
        assign line_opt = 4'h0;
    end
endgenerate
wire  [1:0] exp_depth;
wire        exp_opaque;
wire        exp_mask;
wire  [2:0] kind;
wire  [3:0] px_op;
wire  [2:0] dst_swap;
wire  [2:0] src_swap;
// kind: 0 FILL, 1 COPY, 2 COPY_TRANSP, 3 EXPAND, 4 TEXSPAN, 5 TEXRECT
wire  [2:0] kind_nxt  = {is_tex | is_trect, is_ecopyt | is_expand, is_ecopy | is_expand | is_trect};
wire        tex_kind  = is_tex | is_trect;
wire  [2:0] dswap_nxt = tex_kind ? (tex_cfg[11:9] & {3{~is_tritex}}) : (head[6:4] & {3{~is_span & ~is_trifil & ~is_line}});

// Raster op: [3:0] of the EXECs, [11:8] of EXEC_EXPAND, S for spans and textures
wire  [3:0] px_op_nxt = is_expand ? head[11:8] : (head[3:0] & {4{~(is_span | tex_kind)}});

arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_kind (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop), .d_i(kind_nxt), .q_o(kind));
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_px_op (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop), .d_i(px_op_nxt), .q_o(px_op));
arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_dst_swap (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop), .d_i(dswap_nxt), .q_o(dst_swap));
arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_src_swap (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop & ~is_efill & ~is_span & ~is_expand & ~tex_kind), .d_i(head[10:8]), .q_o(src_swap));
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_exp_cfg (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop & is_expand), .d_i({head[3:2], exp_depth_nxt}), .q_o({exp_mask, exp_opaque, exp_depth}));

// REMAP: [13:12] of FILL, COPY, COPY_TRANSP and EXPAND, SET_TEX's for the
// textures, off for SPAN; MPLANE: [11] of the copies. Per EXEC: they do not
// stay for the next one.
wire  [1:0] rmp_mode;
wire        mpl;
generate
    if (REMAP_USE) begin : g_rmp_exec
        wire  [1:0] rmp_nxt = tex_kind ? rmp_tex : (head[13:12] & {2{rmp_fld}});
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_rmp (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop), .d_i(rmp_nxt), .q_o(rmp_mode));
    end else begin : g_no_rmp_exec
        assign rmp_mode = 2'd0;
        wire [1:0] rmp_tex_unused = rmp_tex;                // GPU_REMAP_EN = 0
    end
    if (MPLANE_USE) begin : g_mpl_exec
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_mpl (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_pop), .d_i((is_ecopy | is_ecopyt) & head[11]), .q_o(mpl));
    end else begin : g_no_mpl_exec
        assign mpl = 1'b0;
    end
endgenerate

//=============================================================================
// 5)  OUTPUTS
//=============================================================================
// Immediate data at the FIFO head that no rectangle takes (the rest of a
// rectangle done, words owed across a flush) is dropped, one per cycle
wire        dat_drop  = head_dat & ~imm_busy_i & gpu_en_i & ~flush_i & ~freeze_i & ~st_err;
assign pop_o        = ((cmd_pop | opnd_pop) & ~list_active_i) | dat_drop | mrk_pop;
assign push_tag_o   = push_dat;
assign push_part_o  = push_owed | push_dat | push_arm;
assign list_pop_o   = (cmd_pop | opnd_pop) &  list_active_i;
assign call_start_o = opnd_call & call_nz & ~call_bad;
assign call_addr_o  = head[VRAM_AW-1:0];
assign call_n_o     = call_n;
assign exec_start_o = exec_go;
assign exec_kind_o  = kind;
assign exp_depth_o  = exp_depth;
assign exp_opaque_o = exp_opaque;
assign exp_mask_o   = exp_mask;
assign alpha_o      = alpha;
assign mix5_o       = mix5;
assign a8_o         = a8;
assign tex_filt_o   = tex_filt;
assign tex_cfg_o    = tex_cfg;
assign tex_uv_o     = tex_uv;
assign tex_step_o   = tex_step;
assign tex_rstep_o  = tex_rstep;
assign tex_box_o    = tex_box;
assign xy_mode_o    = xy_mode;
assign clip_o       = clip;
assign grad_o       = {grad[18], grad_rgb, grad[17:0]};
assign px_op_o      = px_op;
assign dst_swap_o   = dst_swap;
assign src_swap_o   = src_swap;
assign src_base_o   = src_base;
assign src_pitch_o  = src_pitch;
assign dst_base_o   = dst_base;
assign origin_o     = origin;
assign dst_pitch_o  = xy_mode ? xy_pitch_q : dst_pitch;
assign width_o      = width;
assign height_o     = height;
assign tri_o        = tri_fill;
assign xy_x_o       = cur_x;
assign xy_y_o       = cur_y;
assign tri_empty_o  = tri_empty;
assign tri_v_o      = {tri_v2, tri_v1, tri_v0};
assign line_o       = line;
assign line_start_o = opnd_line;
assign line_opt_o   = line_opt;
assign line_p1_o    = pen;
assign line_pat_o   = lpat;
assign line_len_o   = llen;
assign line_phclr_o = (cmd_pop & aux_pat) | rst_go;
assign fill_o       = fill;
assign transp_o     = transp;
assign rmp_mode_o   = rmp_mode;
assign rmp_base_o   = rmp_base;
assign mpl_o        = mpl;
assign msk_base_o   = a8 ? a8_base : msk_base;
assign msk_inv_o    = msk_inv;
assign imm_o        = imm;
assign imm_go_o     = exec_pop & imm_exec;
assign mrk_drop_o   = IMM_USE & mrk_pop & head_cut_i & imm_busy_i;
assign err_o        = st_err;
assign opnd_wait_o  = st_opnd & (tgt != TGT_SKIP);
assign refr_wait_o  = refr_armed & ~refr_seen;
assign err_opcode_o = err_opcode;
assign err_cause_o  = err_cause;
assign err_word_o   = err_word;
assign err_evt_o    = err_go;
assign fence_o      = fence;
assign fence_irq_o  = fence_pop & head[24];

//=============================================================================
// 6)  LINT CLEANUP
//=============================================================================
wire [31:0] head_unused = head;   // fields used depend on the opcode and DIM_W / PA_W
wire [23:0] push_data_unused = push_data_i[23:0];  // only the opcode and SET_EXT sub decide an operand
wire        rstep_unused  = opnd_rstep;     // GPU_XY_EN = 0 (no affine blit)
wire        clip_unused   = opnd_clip;      // GPU_XY_EN = 0
wire        grgb_unused   = opnd_grgb;      // GPU_GRAD_EN = 0
wire  [1:0] fmt_m1_unused = src_fmt_m1[3:2];  // SRC_FMT 1-4 only
wire  [3:0] cur_y_unused  = cur_y_nxt[15:12]; // copies of bit 11 (cur_y)
generate
    if (VRAM_AW < 24) begin : g_lim_hi
        wire [23-VRAM_AW:0] lim_unused = call_lim_d[24:VRAM_AW+1];   // VRAM_WORDS - N past VRAM_WORDS: call_ovf
    end
endgenerate

endmodule // blns_gpu_dec

`default_nettype wire
