//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_px_fw
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_px_fw.v
// Module Description : GPU pixel engine, stages F and W, the VRAM port and the
//                      rectangle sequence (stage A: blns_gpu_px_a):
//                      F  fetch: the source word comes from a one-word cache,
//                         from a word read ahead for the token A offers next
//                         (an idle port cycle; not when an older pixel writes
//                         that word), from the write buffer (a word an older
//                         pixel wrote), or from a read that waits for its
//                         data; the source pixel and its alpha (an AA line:
//                         its coverage, times A with SET_ALPHA) are registered
//                         for W, or, for a word token (a COPY's pixels in one
//                         destination and one source word), the source word
//                         rotated to the destination slots, with the bits
//                         the token writes (its pixels equal to SET_TRANSP
//                         left out for a keyed copy, and those whose mask
//                         bit forbids them with the mask plane: one mask
//                         word held, read for a token that needs another,
//                         the token taken the cycle after) and whether it
//                         writes any; with a palette remap, the colour index
//                         (source pixel, EXPAND colour, texel + SHADE, fill);
//                         an RGB565A8 pixel's alpha is its byte of the A8 word,
//                         which comes through the mask word's holder, and its
//                         destination is not read when that byte makes the
//                         pixel opaque; with MIX5 the blend factor is LVGL's
//                         5-bit one (truncated products); bilinear (BIL_USE):
//                         a tap token's texel and A8 byte come from the tap
//                         cache (blns_gpu_px_tc: a miss reads the colour
//                         word, then the A8 word, in F's read slot), and its
//                         alpha (keyed: 0; times A) goes with its weight to
//                         stage L (blns_gpu_px_l), which hands W one token per
//                         pixel, premultiplied: W blends it as a source 0
//                         with the premultiplied colour as the addend;
//                      W  pixel function and write buffer: one destination
//                         word; a token of that word is merged in (expansion,
//                         shade, transparency, raster operation, blending,
//                         from registered values only); another word flushes
//                         it (one write carrying only the bytes of the pixels
//                         merged, whole bytes below 8 bpp, even when the
//                         word was read) and reads the new one only
//                         when the destination is needed (operations using D,
//                         below 8 bpp, blending); a blended pixel merges
//                         from the buffer the cycle after the read data. For
//                         an operation that always reads it (D, blending), the
//                         next token's destination word is read ahead in an
//                         idle port cycle and the buffer starts from it.
//                         Palette remap: the colour is the table byte of the
//                         index (SRC) or of the destination pixel, registered
//                         from the buffer first (DST), from a one-word table
//                         cache or a read merged as its data arrives;
//                      Immediate source (imm_i): the words come from the
//                      GPU FIFO head in order, through the one-word cache
//                      (word index, data); a token needing a later word
//                      takes the next one (a word no token needs is
//                      dropped); none left: 0. No VRAM read, read ahead or
//                      forwarding for the source; its index at or past
//                      VRAM_WORDS is a bound error.
//                      A rectangle ends when its last pixel is merged and the
//                      buffer flushed (GPU_DONE). ABORT drops the pixels in
//                      flight and writes the buffer (a prefix of the
//                      rectangle). A freeze stops A, drains F and W and
//                      flushes before HELD. An access at or past VRAM_WORDS is
//                      not made: it stops the rectangle (bound_o), the buffer
//                      written when it lies inside the VRAM; one F needs waits
//                      for the older pixels to merge (they are drawn).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_px_fw #(
    parameter                    RD_REG_EN     = 0,   // read data two cycles or more after the grant (second read-ahead entries)
    parameter                    RD_LAT        = 1,   // read data exactly RD_LAT cycles after the grant (1-4)
    parameter                    VRAM_WORDS    = 38400, // VRAM depth in 32-bit words
    parameter                    VRAM_AW       = 16,  // VRAM word-address width
    parameter                    RB_W          = 10,  // remap table base width: max(VRAM_AW - 6, 1)
    parameter                    GPU_BLEND_EN  = 1,   // alpha blending (the blend and coverage multipliers)
    parameter                    GPU_REMAP_EN  = 1,   // palette remap
    parameter                    GPU_MPLANE_EN = 1,   // mask plane on copies
    parameter                    GPU_IMM_EN    = 1,   // immediate source
    parameter              [0:0] BIL_USE       = 1'b0, // bilinear built (blns_gpu: GPU_BILINEAR_EN & GPU_XY_EN)
    parameter                    FILL_PIPE     = 1,   // the fill colour varies per token (gradient, line gaps); 0: t1_fill_i
                                                      // is the rectangle's, constant while busy (not registered here)
    parameter                    ASYNC_RST_EN  = 1'b1 // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  abort_i,             // abandon the rectangle
    input  wire                  freeze_i,            // hold between pixels
    input  wire                  start_i,             // start a rectangle (set-up go)

// SEQUENCE (to blns_gpu_px_a)
    output wire                  go_o,                // the rectangle starts
    output wire                  a_init_o,            // walkers loaded
    output wire                  a_run_o,             // one token per cycle
    output wire                  a_abort_o,           // dropped: flush the buffer
    input  wire                  a_last_emit_i,       // the last token leaves A

// RECTANGLE CONFIGURATION (stable while busy_o)
    input  wire                  exp_opaque_i,        // EXPAND: source 0 writes the background
    input  wire            [8:0] alpha_i,             // SET_ALPHA {EN, A}
    input  wire                  mix5_i,              // SET_ALPHA MIX5: LVGL's blend rule
    input  wire                  tex_tr_en_i,         // TEXSPAN / TEXRECT TRANSP_EN
    input  wire            [7:0] tex_shade_i,         // TEXSPAN / TEXRECT SHADE
    input  wire           [15:0] transp_i,            // transparent colour
    input  wire     [RB_W-1:0]   rmp_base_i,          // remap table word address / 64
    input  wire                  msk_inv_i,           // mask plane: drawn where the mask bit is 0
    input  wire                  imm_i,               // immediate source
    input  wire           [31:0] imm_word_i,          // ... the GPU FIFO head
    input  wire                  imm_avail_i,         // ... is an immediate data word
    input  wire                  imm_short_i,         // ... no data word will come for this rectangle
    output wire                  imm_pop_o,           // ... the head word taken

// OPERATION (blns_gpu_px_a)
    input  wire            [4:0] bpp_i,               // one-hot {16, 8, 4, 2, 1} bpp
    input  wire            [4:0] src_bpp_i,           // source depth, one-hot
    input  wire                  is_copy_i,           // not FILL
    input  wire                  is_tex_i,            // TEXSPAN or TEXRECT
    input  wire                  is_exp_i,            // EXPAND
    input  wire                  mask_on_i,           // EXPAND coverage alpha, blended
    input  wire                  blend_on_i,          // alpha blending
    input  wire            [3:0] px_op_i,             // raster operation (0 when blending)
    input  wire            [1:0] blk_op_i,            // blended constant: 0 none, ops 13/14/15 = 1/2/3 (S = 0 / ones / fill)
    input  wire                  op_no_d_i,           // the operation reads no destination
    input  wire                  need_src_i,          // the source is read
    input  wire                  need_dst_i,          // the destination is read
    input  wire                  transp_chk_i,        // a source equal to SET_TRANSP is skipped
    input  wire                  rmp_on_i,            // remap: each pixel's colour through the table
    input  wire                  rmp_dst_i,           // ... the destination's (DST)
    input  wire                  mp_on_i,             // mask plane: a pixel drawn where its mask bit allows
    input  wire                  aa_on_i,             // AA line: the token's coverage is its alpha
    input  wire                  a8_on_i,             // RGB565A8: the token's alpha is its A8 byte
    input  wire                  bil_on_i,            // bilinear: tap tokens, through the tap cache and L

// A -> F TOKEN
    input  wire                  t1_v_i,              // valid
    input  wire    [VRAM_AW:0]   t1_dwa_i,            // destination word (+ past 2^VRAM_AW)
    input  wire            [4:0] t1_dboff_i,          // bit offset of its lowest pixel
    input  wire            [5:0] t1_nbits_i,          // bits written
    input  wire    [VRAM_AW:0]   t1_swa_i,            // source word (+ past 2^VRAM_AW)
    input  wire            [4:0] t1_rot_i,            // source word rotation (right): the source bit offset of a one-pixel token
    input  wire                  t1_word_i,           // word token: the rotated source word sits at the destination slots
    input  wire                  t1_mir_i,            // ... once its pixel order is reversed (a mirror)
    input  wire                  t1_skip_i,           // nothing drawn (triangle, BOUND)
    input  wire           [15:0] t1_fill_i,           // fill colour (gradient applied)
    input  wire  [VRAM_AW-1:0]   t1_mwa_i,            // mask word (RGB565A8: the A8 word)
    input  wire                  t1_mhi_i,            // ... an A8 word past 2^VRAM_AW
    input  wire            [4:0] t1_mrot_i,           // mask word rotation (right): its bits at the destination slots
                                                      // (RGB565A8: [1:0] the A8 byte)
    input  wire            [7:0] t1_cov_i,            // AA line: coverage
    input  wire           [10:0] t1_k_i,              // bilinear: the tap's weight
    input  wire                  t1_tlast_i,          // ... the pixel's last tap
    input  wire                  t1_ypar_i,           // ... its texel row parity
    output wire                  f_take_o,            // F takes the token

// NEXT TOKEN (blns_gpu_px_a)
    input  wire                  nx_on_i,             // A has a token to offer when running
    input  wire                  nx_skip_i,           // nothing drawn for it
    input  wire    [VRAM_AW:0]   nx_dwa_i,            // its destination word
    input  wire    [VRAM_AW:0]   nx_swa_i,            // its source word
    input  wire                  nw_ok_i,             // the word after it may be read ahead
    input  wire    [VRAM_AW:0]   nw_wa_i,             // ... that word
    input  wire  [VRAM_AW-1:0]   nx_mwa_i,            // its A8 word (RGB565A8: read ahead)
    input  wire                  nx_mhi_i,            // ... past 2^VRAM_AW

// VRAM REQUESTER
    output wire                  vreq_o,              // request: up while a demand access waits (the access it carries
                                                      // may change: W's read is ahead of F's, a demand read ahead of a
                                                      // non-urgent slot write); a read ahead may be withdrawn
    output wire                  vwe_o,               // 1 = write
    output wire            [3:0] vbe_o,               // byte enables
    output wire  [VRAM_AW-1:0]   vaddr_o,             // word address
    output wire  [VRAM_AW-1:0]   vwaddr_o,            // ... of a write (= vaddr_o with vwe_o), from a flop
    output wire           [31:0] vwdata_o,            // write data
    input  wire                  vgnt_i,              // access issued this cycle
    input  wire                  vrvalid_i,           // read data valid: exactly RD_LAT cycles after the grant, in order
                                                      // (the read ahead relies on it: g_ra_fly)
    input  wire           [31:0] vrdata_i,            // read data

// STATUS
    output wire                  busy_o,              // rectangle running
    output wire                  done_o,              // rectangle completed (1 cycle)
    output wire                  held_o,              // frozen: nothing in flight
    output wire                  bound_o              // an access at or past VRAM_WORDS (1 cycle)
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================
localparam WA_W       = VRAM_AW + 1;                   // word address + "past 2^VRAM_AW" bit
localparam BLEND_USE  = (GPU_BLEND_EN  != 0);
localparam REMAP_USE  = (GPU_REMAP_EN  != 0);
localparam MPLANE_USE = (GPU_MPLANE_EN != 0);
localparam IMM_USE    = (GPU_IMM_EN    != 0);
localparam MHOLD_USE  = MPLANE_USE || BLEND_USE;       // the mask / A8 word holder

localparam [2:0] AS_IDLE  = 3'd0;
localparam [2:0] AS_INIT  = 3'd1;                     // walkers loaded
localparam [2:0] AS_RUN   = 3'd2;                     // one token per cycle
localparam [2:0] AS_DRAIN = 3'd3;                     // every token issued: drain F / W, flush
localparam [2:0] AS_ABORT = 3'd4;                     // dropped: flush the buffer

// The last token issued (a_done, set the cycle after it leaves A): the state
// stays RUN for that cycle, which decodes as DRAIN (no token, no read ahead:
// both walkers point past the rectangle), so the state register's next value
// takes a flop instead of the last token's handshake
wire [2:0] a_st;
wire       a_done;
wire       a_idle  = (a_st == AS_IDLE);
wire       a_init  = (a_st == AS_INIT);
wire       a_run   = (a_st == AS_RUN) & ~a_done;
wire       a_drain = (a_st == AS_DRAIN) | ((a_st == AS_RUN) & a_done);
wire       a_abort = (a_st == AS_ABORT);
wire       go      = a_idle & start_i & ~abort_i;

// Operation, token and next token (blns_gpu_px_a)
wire        [4:0] bpp        = bpp_i;
wire        [4:0] src_bpp    = src_bpp_i;
wire              is_copy    = is_copy_i;
wire              is_tex     = is_tex_i;
wire              is_exp     = is_exp_i;
wire              mask_on    = mask_on_i;
wire              blend_on   = blend_on_i;
wire        [3:0] px_op      = px_op_i;
wire        [1:0] blk_op     = blk_op_i;
wire              op_no_d    = op_no_d_i;
wire              need_src   = need_src_i;
wire              need_dst   = need_dst_i;
wire              transp_chk = transp_chk_i;
wire              tex_tr_en  = tex_tr_en_i;
wire        [7:0] tex_shade  = tex_shade_i & {8{~(BIL_USE & bil_on_i)}};   // (bilinear at 16 bpp: no SHADE)
wire              rmp_on     = rmp_on_i;
wire              rmp_dst    = rmp_dst_i;
wire              mp_on      = mp_on_i;
wire              a8_on      = BLEND_USE & a8_on_i;
wire              bil_on     = BIL_USE & bil_on_i;
wire              mix5       = BLEND_USE & mix5_i;

wire              t1_v       = t1_v_i;
wire   [WA_W-1:0] t1_dwa     = t1_dwa_i;
wire        [4:0] t1_dboff   = t1_dboff_i;
wire        [5:0] t1_nbits   = t1_nbits_i;
wire   [WA_W-1:0] t1_swa     = t1_swa_i;
wire        [4:0] t1_rot     = t1_rot_i;
wire              t1_word    = t1_word_i;
wire              t1_mir     = t1_mir_i;
wire              t1_skip    = t1_skip_i;
wire       [15:0] t1_fill    = t1_fill_i;
wire [VRAM_AW-1:0] t1_mwa    = t1_mwa_i;
wire              t1_mhi     = BLEND_USE & t1_mhi_i;
wire        [4:0] t1_mrot    = t1_mrot_i;
wire              f_take;                                // F takes the token (section 2)

wire              nx_on      = nx_on_i;
wire              nx_skip    = nx_skip_i;
wire   [WA_W-1:0] nx_dwa     = nx_dwa_i;
wire   [WA_W-1:0] nx_swa     = nx_swa_i;
wire              nw_ok      = nw_ok_i;
wire   [WA_W-1:0] nw_wa      = nw_wa_i;

//=============================================================================
// 2)  F: SOURCE WORD (cache, write buffer, or a read)
//=============================================================================
// Write buffer state (section 3), needed here for forwarding and hazards
wire               w_v;                                  // the buffer holds a word
wire    [WA_W-1:0] w_wa;
wire        [31:0] w_data;
wire               w_ld;                                 // the word was read: every byte valid
wire               w_dirty;
wire               t2_v;
wire    [WA_W-1:0] t2_dwa;
wire               t2_skip;
wire               w_take;                               // W consumes its token (section 3)

wire               c_v;
wire    [WA_W-1:0] c_wa;
wire        [31:0] c_data;
wire               rd_pend;                              // a read in flight
wire               rd_w;                                 // ... for W
wire               rd_pf;                                // ... read ahead (else F's demand)
wire               rd_dp;                                // ... destination read ahead
wire               ra_drop;                              // ... overtaken in flight: its data is dropped
wire               rd_m;                                 // ... a mask word for F
wire               rd_r;                                 // ... a remap table word for W
wire               rd_ma;                                // ... an A8 word read ahead (RGB565A8, below)
wire               ma_v;                                 // ... its entry
wire [VRAM_AW-1:0] ma_wa;
wire        [31:0] ma_data;
wire               rd_bc;                                // ... a bilinear tap's colour word (section 2b)
wire               rd_ba;                                // ... a bilinear tap's A8 word
wire               c_fill    = vrvalid_i & rd_pend & ~rd_w & ~rd_pf & ~rd_dp & ~rd_m & ~rd_r & ~rd_bc & ~rd_ba & ~rd_ma;   // F's read data arrives
wire               m_fill    = vrvalid_i & rd_pend &  rd_m;            // the mask word arrives
wire               r_fill    = vrvalid_i & rd_pend &  rd_r;            // the table word arrives
wire               p_fill    = vrvalid_i & rd_pend &  rd_pf & ~ra_drop; // the read-ahead data arrives
wire               rd_pf1;                               // ... into the second entry (RD_REG_EN)
wire               rd_dp1;
wire               p_fill0   = p_fill & ~rd_pf1;
wire               p_fill1   = p_fill &  rd_pf1;
wire               w_fill    = vrvalid_i & rd_pend &  rd_w;            // W's read data arrives
wire               rd_free   = ~rd_pend | vrvalid_i;     // a read may be issued
wire               dp_fill   = vrvalid_i & rd_pend &  rd_dp & ~ra_drop; // the destination read ahead arrives
wire               dp_fill0  = dp_fill & ~rd_dp1;
wire               dp_fill1  = dp_fill &  rd_dp1;

// Destination read-ahead entry (valid; its read in flight while rd_dp)
wire               dp_v;
wire    [WA_W-1:0] dp_wa;
wire        [31:0] dp_data;

// Read-ahead entry (valid; its read in flight while rd_pf)
wire               pf_v;
wire    [WA_W-1:0] pf_wa;
wire        [31:0] pf_data;

// With RD_REG_EN a read ahead issues in the cycle the previous read returns,
// into a second entry when the first is valid or awaited (entry 1: 0 without)
wire               pf1_v;
wire    [WA_W-1:0] pf1_wa;
wire        [31:0] pf1_data;
wire               dp1_v;
wire    [WA_W-1:0] dp1_wa;
wire        [31:0] dp1_data;
wire               pf0_occ   = pf_v  | (rd_pend & rd_pf & ~rd_pf1);    // valid or its read in flight
wire               pf1_occ   = pf1_v | (rd_pend & rd_pf &  rd_pf1);
wire               dp0_occ   = dp_v  | (rd_pend & rd_dp & ~rd_dp1);
wire               dp1_occ   = dp1_v | (rd_pend & rd_dp &  rd_dp1);
wire               dp_hit1;                              // W's word is in entry 1

// Write-back slot: a finished buffer word waiting for its write (section 3)
wire               wb_v;
wire    [WA_W-1:0] wb_wa;
wire        [31:0] wb_data;
wire               wb_ld;

// A word an older pixel still has to merge is not read yet; a word in the
// buffer or the write-back slot comes from there when every byte is valid,
// else it is written first (then read)
// An immediate source has no VRAM word: no hazard, forwarding or read (its
// words come through the cache, below)
wire               imm       = IMM_USE & imm_i;
wire               t1_sneed  = need_src & ~t1_skip;
wire               f_need    = t1_v & t1_sneed & ~bil_on;   // (bilinear: the tap cache, section 2b)
wire               f_haz     = ~imm & t2_v & ~t2_skip & (t2_dwa == t1_swa);
wire               f_in_w    = ~imm & w_v & (w_wa == t1_swa);
wire               f_in_wb   = ~imm & wb_v & (wb_wa == t1_swa);
wire               f_hit_w   = f_in_w & w_ld;
wire               f_hit_wb  = ~f_in_w & f_in_wb & wb_ld;
wire               f_wait    = (f_in_w & ~w_ld & (w_dirty | f_in_wb)) | (~f_in_w & f_in_wb & ~wb_ld);
wire               f_fwd     = f_hit_w | f_hit_wb | f_wait;
wire               f_hit_c   = ~f_fwd & c_v & (c_wa == t1_swa);
wire               f_pf_t1   = ~imm & ~f_fwd & ~f_hit_c & (pf_wa == t1_swa);
wire               f_pf1_t1  = ~imm & ~f_fwd & ~f_hit_c & (pf1_wa == t1_swa) & (RD_REG_EN != 0);
wire               f_hit_p1  = f_pf1_t1 & pf1_v;
wire               f_use_p1  = f_hit_p1 | (f_pf1_t1 & p_fill1);          // F takes entry 1
wire               f_hit_p   = (f_pf_t1 & pf_v) | f_hit_p1;
wire               f_fill_p  = (f_pf_t1 & p_fill0) | (f_pf1_t1 & p_fill1);
wire               f_wflush  = f_need & ~f_haz & f_in_w & ~w_ld & w_dirty;   // the buffer word goes to the slot
wire               f_wb_wait = f_need & ~f_haz & f_wait;                     // ... and is written before the read
// Mask plane: the token's mask word from the entry (read first when it holds
// another word; the token goes the cycle after its data). The mask lies
// outside the destination: no hazard, no forwarding. An RGB565A8 pixel's A8
// word the same way (a texel skipped by BOUND reads none); one past 2^VRAM_AW
// never hits (its read is a bound error)
wire               m_v;
wire [VRAM_AW-1:0] m_wa;
wire        [31:0] m_data;
wire               m_need    = t1_v & (mp_on | (a8_on & ~t1_skip & ~bil_on));
// An RGB565A8 copy's A8 word may also be in the read-ahead entry (ma, read for
// the token A offered next): the token takes it from there, and the holder
// takes the entry's word with the token
wire               m_hit_h   = m_v & (m_wa == t1_mwa) & ~t1_mhi;
wire               m_hit_a   = ~m_hit_h & ma_v & (ma_wa == t1_mwa) & ~t1_mhi;
wire               m_hit     = m_hit_h | m_hit_a;
wire               m_ok      = ~m_need | m_hit;
wire               m_rreq    = m_need & ~m_hit & rd_free & ~(rd_pend & ~rd_w);
wire               f_rreq    = f_need & ~imm & ~f_haz & ~f_fwd & ~f_hit_c & ~f_hit_p & ~c_fill & ~f_fill_p &
                               rd_free & ~(rd_pend & ~rd_w) & ~m_rreq;
wire               f_ready   = ~f_need | (~f_haz & (f_hit_w | f_hit_wb | f_hit_c | c_fill | f_hit_p | f_fill_p));
wire               t2_free   = ~t2_v | w_take;
wire               b_ready;                              // bilinear: the tap's words held (section 2b)
wire               l_free;                               // ... L takes a tap
assign             f_take    = bil_on ? (t1_v & b_ready & l_free) : (t1_v & f_ready & m_ok & t2_free);

// The VRAM read data (the latest input) on the outermost leg: selected by
// the arrival of F's read or of the read ahead it takes, when the word is not
// forwarded from the buffer or the slot (the priority of a chain buffer >
// slot > read data > entry > cache, the selects from flops and vrvalid_i)
wire               f_sel_vr  = (c_fill | f_fill_p) & ~f_hit_w & ~f_hit_wb;
wire        [31:0] f_word_r  = f_hit_w ? w_data : f_hit_wb ? wb_data :
                               f_hit_p ? (f_hit_p1 ? pf1_data : pf_data) : c_data;
wire        [31:0] f_word    = f_sel_vr ? vrdata_i : f_word_r;
// The source word rotated right by t1_rot: a one-pixel token's pixel in the
// low bits, a word token's pixels at their destination slots. A one-pixel
// token's rotation is its source bit offset, so its bits wrapped around land
// at or above the source pixel width (bits src_mask16 drops); the upper half
// and the reversed word are read for a word token only
wire        [63:0] f_rot64   = {f_word, f_word} >> t1_rot;
wire        [31:0] f_rot     = f_rot64[31:0];
// A mirrored word token: its pixel order reversed at the depth (bit b takes
// bit (31 - b) ^ (bits per pixel - 1))
wire        [31:0] f_rev;
genvar             gr;
generate
    for (gr = 0; gr < 32; gr = gr + 1) begin : g_rev
        assign f_rev[gr] = (bpp[0] & f_rot[31 - gr])         | (bpp[1] & f_rot[(31 - gr) ^ 1]) |
                           (bpp[2] & f_rot[(31 - gr) ^ 3])   | (bpp[3] & f_rot[(31 - gr) ^ 7]) |
                           (bpp[4] & f_rot[(31 - gr) ^ 15]);
    end
endgenerate
wire        [31:0] f_wsrc    = t1_mir ? f_rev : f_rot;  // a word token's source, at the destination slots
wire        [15:0] src_mask16 = ({16{src_bpp[0]}} & 16'h0001) |
                                ({16{src_bpp[1]}} & 16'h0003) |
                                ({16{src_bpp[2]}} & 16'h000F) |
                                ({16{src_bpp[3]}} & 16'h00FF) |
                                ({16{src_bpp[4]}} & 16'hFFFF);
wire        [15:0] f_pix     = f_rot[15:0] & src_mask16;

// Blend alpha: A, or the coverage (A1 0/255, A2 v * 85, A4 v * 17, A8 v; an AA
// line's token coverage; an RGB565A8 pixel's A8 byte), times A when both
// (A / 255 rounded, or with MIX5 A / 256 truncated); registered with the
// pixel for W. With MIX5 the factor W takes is 8 m, m = (alpha + 4) >> 3
// (0 .. 256: its ninth bit beside the alpha byte, t2_a9), otherwise the
// alpha byte (255 meaning 256 in W, as before)
wire  [7:0] f_alpha;
wire  [7:0] f_a8b;                                       // the A8 byte of the token
wire        f_a9;                                        // MIX5: the factor's ninth bit
wire  [7:0] f_tal;                                       // bilinear: the tap's alpha (times A)
wire  [7:0] b_acov;                                      // ... before A and the key: 255 or its A8 byte (section 2b)
wire        b_key;                                       // ... keyed: alpha 0
generate
    if (BLEND_USE) begin : g_blend_a
        wire [31:0] f_aw  = m_hit_a ? ma_data : m_data;
        assign      f_a8b = f_aw[{t1_mrot[1:0], 3'b000} +: 8];
        // (aa_on, a8_on: static, a FILL kind reads no source, an RGB565A8 copy is 16 bpp)
        wire  [7:0] a_cov = ({8{aa_on_i}} & t1_cov_i)              |
                            ({8{a8_on & ~bil_on}} & f_a8b)         |
                            ({8{bil_on}} & b_acov)                 |
                            ({8{src_bpp[0] & ~aa_on_i}} & {8{f_pix[0]}})   |
                            ({8{src_bpp[1] & ~aa_on_i}} & {4{f_pix[1:0]}}) |
                            ({8{src_bpp[2] & ~aa_on_i}} & {2{f_pix[3:0]}}) |
                            ({8{src_bpp[3] & ~aa_on_i}} & f_pix[7:0]);
        // round(cov * A / 255) as one multiply-add: ((cov * A + 127) * 257 + 256) >> 16,
        // with 257 * A = {A, A}; MIX5: (cov * A) >> 8 = (cov * 256 A) >> 16
        wire [15:0] a_mcand = {alpha_i[7:0], mix5 ? 8'h00 : alpha_i[7:0]};
        wire [23:0] a_mul = {16'h0000, a_cov} * {8'h00, a_mcand} + (mix5 ? 24'd0 : 24'd32895);
        wire  [7:0] f_al  = (mask_on | a8_on | bil_on) ? (alpha_i[8] ? a_mul[23:16] : a_cov) : alpha_i[7:0];
        wire  [8:0] f_ms  = {1'b0, f_al} + 9'd4;
        wire  [8:0] f_m8  = {f_ms[8:3], 3'b000};          // 8 m, 0 .. 256
        wire  [2:0] f_ms_unused = f_ms[2:0];
        assign      f_alpha = mix5 ? f_m8[7:0] : f_al;
        assign      f_a9    = mix5 & f_m8[8];
        // (bilinear: a keyed tap's alpha is 0, times A 0 too (32895 >> 16, or
        // 0 with MIX5), so the key is applied after the multiply: the
        // multiply works on the A8 byte or 255 alone, and the tap cache's
        // data-return path (port grant, overtake check, bypass select, key
        // compare) meets it only at this AND. Under bil_on a_cov's other
        // terms are 0: a texture at 16 bpp, not a line)
        assign      f_tal   = f_al & {8{~b_key}};
        wire [15:0] a_mul_unused = a_mul[15:0];            // the result is the top byte
    end else begin : g_no_blend_a
        assign      f_a8b   = 8'h00;
        assign      f_alpha = alpha_i[7:0];                // (no coverage alpha: mask_on is 0)
        assign      f_a9    = 1'b0;
        assign      f_tal   = 8'hFF;                       // (bilinear: every tap opaque)
        wire [31:0] ma_d_unused = ma_data;                 // (no A8 read ahead without blending)
        wire [20:0] alpha_unused = {alpha_i[8], aa_on_i, t1_cov_i, mix5_i, a8_on_i, b_acov, b_key};
    end
endgenerate

// The cache: filled by an F read, or the read-ahead word when F takes it;
// dropped when W writes its word, when its read is issued and while held
// (the VRAM may change)
wire        w_merge;                                     // W merges a pixel (section 3)
wire        f_rd_gnt;                                    // an F read issued (section 3)
wire        la_gnt;                                      // a read ahead issued (section 3)
wire        held;
wire        c_promo     = f_take & (f_hit_p | f_fill_p);
wire        c_drop      = ~imm & ((w_merge & (t2_dwa == c_wa)) | f_rd_gnt | held);
// Immediate source: the cache holds the word of index c_wa; a token needing
// another (a later one) loads the next word: the FIFO head, or 0 when no
// data word is left for this rectangle. i_cnt: the next word's index. An
// index at or past VRAM_WORDS loads nothing (bound error).
wire              i_ld;
wire   [WA_W-1:0] i_cnt;
wire              i_oob;
generate
    if (IMM_USE) begin : g_imm
        wire [31:0] t1_swa32 = {{(32-WA_W){1'b0}}, t1_swa};
        assign      i_oob    = imm & f_need & (t1_swa32 >= VRAM_WORDS);
        wire        i_need   = imm & f_need & ~(c_v & (c_wa == t1_swa)) & ~i_oob & ~a_abort & ~abort_i;
        assign      i_ld     = i_need & (imm_avail_i | imm_short_i);
        wire [WA_W-1:0] i_cnt_nxt = go ? {WA_W{1'b0}} : (i_cnt + {{(WA_W-1){1'b0}}, 1'b1});
        arv_ipdff #(.WIDTH(WA_W), .ARST_EN(ASYNC_RST_EN)) u_i_cnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(go | i_ld), .d_i(i_cnt_nxt), .q_o(i_cnt));
        assign      imm_pop_o = i_ld & imm_avail_i;
    end else begin : g_no_imm
        assign      i_oob     = 1'b0;
        assign      i_ld      = 1'b0;
        assign      i_cnt     = {WA_W{1'b0}};
        assign      imm_pop_o = 1'b0;
        wire [34:0] imm_unused = {imm_i, imm_word_i, imm_avail_i, imm_short_i};
    end
endgenerate
// Priority: fill / promotion / immediate word > drop
wire        c_v_nxt     = ~go & (c_fill | c_promo | i_ld | (c_v & ~c_drop));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_c_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(c_v_nxt), .q_o(c_v));

// Read-ahead entry: priority start / promotion / hold / a new read / (RD_REG_EN)
// a merge into its word > arrival. No older token writes the word of the next
// token (checked at the read); the word after it may be written by a token
// still to come.
wire        pf_kill0    = w_merge & (t2_dwa == pf_wa);
wire        pf_v_nxt    = (RD_REG_EN != 0) ? (~go & ~(c_promo & ~f_use_p1) & ~held & ~pf_kill0 & (p_fill0 | pf_v)) :
                                             (~go & ~c_promo & ~held & ~la_gnt & (p_fill | pf_v));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_pf_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(pf_v_nxt), .q_o(pf_v));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_pf_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(p_fill0), .d_i(vrdata_i), .q_o(pf_data));

// F -> W token. Whole bytes written by an operation without D (not blended)
// need no destination read: decided here, off W's accept path. The bits the
// token writes (t2_wmask) are decided here too.
// (bit i written: dboff <= i < dboff + nbits, two compares per bit against
// constants, a 7-bit sum)
wire  [6:0] f_mhi       = {2'b00, t1_dboff} + {1'b0, t1_nbits};
wire [31:0] f_mask;
genvar      gfm;
generate
    for (gfm = 0; gfm < 32; gfm = gfm + 1) begin : g_fmask
        assign f_mask[gfm] = (f_mhi > gfm) & (t1_dboff <= gfm);
    end
endgenerate
wire  [3:0] f_be        = {|f_mask[31:24], |f_mask[23:16], |f_mask[15:8], |f_mask[7:0]};
wire  [3:0] f_bfull     = {&f_mask[31:24], &f_mask[23:16], &f_mask[15:8], &f_mask[7:0]};
// Below 8 bpp a keyed word token, or any token with the mask plane, always
// reads D (its pixels left out are not known here: the key and mask tests
// stay off this decision); a DST remap always reads it
// An RGB565A8 pixel opaque by its A8 byte b (decided from b, beside the alpha
// multiplier): MIX5 m = 32, b >= 252 alone or b >= 253 times A = 255; else b =
// 255, alone or times A = 255. Sufficient, not necessary: some pixels reaching
// m = 32 through A still read D
wire        a8_full     = mix5 ? ((~alpha_i[8] & (f_a8b >= 8'd252)) | (alpha_i[8] & (alpha_i[7:0] == 8'hFF) & (f_a8b >= 8'd253))) :
                                 ((f_a8b == 8'hFF) & (~alpha_i[8] | (alpha_i[7:0] == 8'hFF)));
wire        f_nd        = need_dst & ~(op_no_d & ~blend_on & ~rmp_dst & (f_be == f_bfull) & ~(t1_word & transp_chk) & ~mp_on) &
                          ~(a8_on & a8_full);
// Key of a word token (COPY_TRANSP, ops 13-15): its pixels equal to SET_TRANSP,
// slot by slot at the depth, are not written
wire [15:0] k_tm        = transp_i & src_mask16;
wire [31:0] k_rep       = ({32{bpp[0]}} & {32{k_tm[0]}})    |
                          ({32{bpp[1]}} & {16{k_tm[1:0]}})  |
                          ({32{bpp[2]}} & { 8{k_tm[3:0]}})  |
                          ({32{bpp[3]}} & { 4{k_tm[7:0]}})  |
                          ({32{bpp[4]}} & { 2{k_tm[15:0]}});
wire [31:0] k_eq        = ~(f_wsrc ^ k_rep);             // bit by bit
wire [15:0] k_e2;                                        // 2-bit pixels equal
wire  [7:0] k_e4;
wire  [3:0] k_e8;
wire  [1:0] k_e16;
genvar      gk;
generate
    for (gk = 0; gk < 16; gk = gk + 1) begin : g_ke2
        assign k_e2[gk] = k_eq[2*gk] & k_eq[2*gk+1];
    end
    for (gk = 0; gk < 8; gk = gk + 1) begin : g_ke4
        assign k_e4[gk] = k_e2[2*gk] & k_e2[2*gk+1];
    end
    for (gk = 0; gk < 4; gk = gk + 1) begin : g_ke8
        assign k_e8[gk] = k_e4[2*gk] & k_e4[2*gk+1];
    end
    for (gk = 0; gk < 2; gk = gk + 1) begin : g_ke16
        assign k_e16[gk] = k_e8[2*gk] & k_e8[2*gk+1];
    end
endgenerate
wire [31:0] k_px        = ({32{bpp[0]}} & k_eq) |
                          ({32{bpp[1]}} & {{2{k_e2[15]}}, {2{k_e2[14]}}, {2{k_e2[13]}}, {2{k_e2[12]}},
                                           {2{k_e2[11]}}, {2{k_e2[10]}}, {2{k_e2[9]}},  {2{k_e2[8]}},
                                           {2{k_e2[7]}},  {2{k_e2[6]}},  {2{k_e2[5]}},  {2{k_e2[4]}},
                                           {2{k_e2[3]}},  {2{k_e2[2]}},  {2{k_e2[1]}},  {2{k_e2[0]}}}) |
                          ({32{bpp[2]}} & {{4{k_e4[7]}}, {4{k_e4[6]}}, {4{k_e4[5]}}, {4{k_e4[4]}},
                                           {4{k_e4[3]}}, {4{k_e4[2]}}, {4{k_e4[1]}}, {4{k_e4[0]}}}) |
                          ({32{bpp[3]}} & {{8{k_e8[3]}}, {8{k_e8[2]}}, {8{k_e8[1]}}, {8{k_e8[0]}}}) |
                          ({32{bpp[4]}} & {{16{k_e16[1]}}, {16{k_e16[0]}}});
// Mask plane: the mask word (reversed for a mirror) rotated right by t1_mrot
// puts each token pixel's mask bit at its destination slot; INV inverts it,
// then each bit is widened to its pixel
wire [31:0] m_rev;
wire [31:0] m_px;
genvar      gm;
generate
    for (gm = 0; gm < 32; gm = gm + 1) begin : g_mrev
        assign m_rev[gm] = m_data[31 - gm];
    end
endgenerate
wire [31:0] m_word      = t1_mir ? m_rev : m_data;
wire [63:0] m_rot64     = {m_word, m_word} >> t1_mrot;
wire [31:0] m_bits      = m_rot64[31:0] ^ {32{msk_inv_i}};
generate
    for (gm = 0; gm < 32; gm = gm + 1) begin : g_mpx
        assign m_px[gm] = (bpp[0] & m_bits[gm])      | (bpp[1] & m_bits[gm >> 1]) |
                          (bpp[2] & m_bits[gm >> 2]) | (bpp[3] & m_bits[gm >> 3]) |
                          (bpp[4] & m_bits[gm >> 4]);
    end
endgenerate
wire [31:0] f_wmask     = f_mask & ~({32{t1_word & transp_chk}} & k_px) & ({32{~mp_on}} | m_px);
wire        f_none      = (t1_word | mp_on) & ~|f_wmask; // every pixel keyed or masked: nothing written
// Remap (SRC): the colour the operation takes as S, at the depth: the source
// pixel (COPY), fill + v - 1 or, value 0 (OPAQUE), the background (EXPAND),
// texel + SHADE (textures), the fill colour (FILL)
wire  [7:0] f_rmask8    = ({8{bpp[0]}} & 8'h01) | ({8{bpp[1]}} & 8'h03) | ({8{bpp[2]}} & 8'h0F) |
                          ({8{bpp[3] | bpp[4]}} & 8'hFF);
wire  [7:0] f_exp_ix    = (f_pix[7:0] == 8'h00) ? transp_i[7:0] : (t1_fill[7:0] + f_pix[7:0] - 8'h01);
wire  [7:0] f_ridx      = f_rmask8 & (is_tex ? (f_pix[7:0] + tex_shade) : is_exp ? f_exp_ix :
                                      is_copy ? f_pix[7:0] : t1_fill[7:0]);
// The source: a one-pixel token's pixel, a word token's rotated word
wire [15:0] f_slo       = t1_word ? f_wsrc[15:0] : f_pix;
wire        t2_nd;
wire  [4:0] t2_dboff;
wire [15:0] t2_spix;                                     // the pixel, or a word token's lower half
wire [15:0] t2_fill;
wire  [7:0] t2_alpha;
wire [31:0] t2_wmask;                                    // the bits written
wire        t2_word;                                     // a word token
wire [15:0] t2_shi;                                      // ... its upper half
wire        t2_noop;                                     // nothing written (skipped, or a word token wholly keyed)
wire        t2_kchk;                                     // its pixel is tested against SET_TRANSP here (not a word token)
// Bilinear: W's token comes from L (a pixel, its last tap's destination: one
// 16-bpp pixel, premultiplied alpha256 in t2_alpha / t2_a9, the straight
// colour without blending), a static select (section 2b)
wire        l_out;                                       // L hands W a pixel
wire [WA_W-1:0] l_dwa;
wire        l_dhi;
wire        l_noop;
wire        l_nd;
wire  [8:0] l_a256;
wire [15:0] l_pix;
wire [41:0] t2_pm;                                       // ... its premultiplied colour (section 2b)
wire        t2_ld       = bil_on ? (l_out & t2_free) : f_take;
wire        t2_v_nxt    = ~a_abort & ~abort_i & (t2_ld | (t2_v & ~w_take));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_t2_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(t2_v_nxt), .q_o(t2_v));
arv_ipdff #(.WIDTH(WA_W + 31), .ARST_EN(ASYNC_RST_EN)) u_t2 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld),
             .d_i(bil_on ? {l_dwa, l_dhi, 4'h0, l_nd, l_noop, l_pix, l_a256[7:0]} :
                           {t1_dwa, t1_dboff, f_nd, t1_skip, t1_sneed ? f_slo : 16'h0000, f_alpha}),
             .q_o({t2_dwa, t2_dboff, t2_nd, t2_skip, t2_spix, t2_alpha}));
generate
    if (FILL_PIPE != 0) begin : g_t2_fill
        arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_t2_fill (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld), .d_i(t1_fill), .q_o(t2_fill));
    end else begin : g_no_t2_fill
        assign t2_fill = t1_fill;                          // the rectangle's fill colour
    end
endgenerate
// MIX5: the ninth bit of the factor (m = 32: 256)
wire        t2_a9;
generate
    if (BLEND_USE) begin : g_t2_a9
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_t2_a9 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld), .d_i(bil_on ? l_a256[8] : f_a9), .q_o(t2_a9));
    end else begin : g_no_t2_a9
        assign t2_a9 = 1'b0;
        wire [1:0] a9_unused = {f_a9, l_a256[8]};            // GPU_BLEND_EN = 0: 0, the straight colour
    end
endgenerate
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_t2_wm (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld),
             .d_i(bil_on ? {{16{l_dhi}}, {16{~l_dhi}}} : f_wmask), .q_o(t2_wmask));
// word token, its no-op and key-test flags registered whole: W's no-op, on
// the way to the port request, comes from a flop
arv_ipdff #(.WIDTH(19), .ARST_EN(ASYNC_RST_EN)) u_t2_sw (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld),
             .d_i(bil_on ? {1'b0, l_noop, 1'b0, 16'h0000} :
                           {t1_word, t1_skip | f_none, transp_chk & ~t1_word, t1_sneed ? f_wsrc[31:16] : 16'h0000}),
             .q_o({t2_word, t2_noop, t2_kchk, t2_shi}));

// Remap index, for W
wire  [7:0] t2_ridx;
generate
    if (REMAP_USE) begin : g_t2_ridx
        arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_t2_rx (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld), .d_i(f_ridx), .q_o(t2_ridx));
    end else begin : g_no_t2_ridx
        assign t2_ridx = 8'h00;
        wire [7:0] f_ridx_unused = f_ridx;                   // GPU_REMAP_EN = 0
    end
endgenerate

//=============================================================================
// 3)  W: PIXEL FUNCTION AND WRITE BUFFER
//=============================================================================
wire [15:0] bpp_mask16  = ({16{bpp[0]}} & 16'h0001) |
                          ({16{bpp[1]}} & 16'h0003) |
                          ({16{bpp[2]}} & 16'h000F) |
                          ({16{bpp[3]}} & 16'h00FF) |
                          ({16{bpp[4]}} & 16'hFFFF);
wire [15:0] fill_m      = t2_fill & bpp_mask16;
wire [15:0] transp_m    = transp_i & bpp_mask16;
wire [15:0] s_pix_reg   = is_copy ? t2_spix : fill_m;
wire        exp_zero    = (t2_spix == 16'h0000);
wire        transp_hit  = (t2_kchk & (s_pix_reg == transp_m)) |       // (a word token: its key in F)
                          (is_exp & ~exp_opaque_i & exp_zero) |
                          (is_tex & tex_tr_en & ~bil_on & (t2_spix == transp_m)) |   // (bilinear: per tap, in F)
                          (blend_on & ~t2_a9 & (t2_alpha == 8'h00));
wire        w_noop      = t2_noop | transp_hit;           // nothing written for this token

// Remap: the token's colour is the table byte of its index, the one from F
// (SRC) or the destination pixel (DST, registered from the buffer first: a
// cycle before the lookup). The table word comes from a one-word cache, or
// from a read merged in the cycle its data arrives (and kept in the cache).
// The decision (transparency, mask) is made before: no lookup for a pixel
// not written.
wire        r_v;
wire  [5:0] r_tag;
wire [31:0] r_data;
wire        r_dv;                                         // r_didx holds the W token's destination pixel
wire  [7:0] r_didx;
wire  [7:0] r_idx       = rmp_dst ? r_didx : t2_ridx;
wire        r_need      = t2_v & rmp_on & ~w_noop;
wire        r_hit       = r_v & (r_tag == r_idx[7:2]) & (~rmp_dst | r_dv);
wire        r_ok        = ~r_need | r_hit | r_fill;
wire [31:0] r_word      = r_fill ? vrdata_i : r_data;
wire [31:0] r_sh        = r_word >> {r_idx[1:0], 3'b000};

// EXPAND colour: 0 -> background, v -> fill + v - 1; texel + SHADE
wire [15:0] exp_ramp    = t2_fill + t2_spix - 16'h0001;
wire [15:0] exp_pix     = exp_zero ? transp_m : (exp_ramp & bpp_mask16);
wire [15:0] tex_sum_px  = t2_spix + {8'h00, tex_shade};
wire [15:0] tex_pix     = tex_sum_px & bpp_mask16;
// The colour the operation takes as S: the texel, the EXPAND colour, the
// source pixel or the fill colour; blended ops 13-15 take their constant (0,
// ones, the fill colour). The selects are static over the rectangle (no mux
// level added in front of the blend multipliers), and one-hot: with blk_on
// only c_fil / c_one (0 when neither); otherwise c_tex (textures), c_exp
// (EXPAND without MASK), c_cpy (copies) and c_fil (FILL, EXPAND with MASK)
// partition the kinds
wire        blk_on      = |blk_op;
// (bilinear with blending: no source, the premultiplied colour is the addend)
wire        c_tex       = is_tex & ~blk_on & ~(BLEND_USE & bil_on);
wire        c_exp       = is_exp & ~mask_on & ~blk_on;
wire        c_cpy       = is_copy & ~is_tex & ~is_exp & ~blk_on;
wire        c_fil       = blk_on ? (blk_op == 2'd3) : (~is_copy | (is_exp & mask_on));
wire        c_one       = (blk_op == 2'd2);
wire [15:0] c_pix       = ({16{c_tex}} & tex_pix) |
                          ({16{c_exp}} & exp_pix) |
                          ({16{c_cpy}} & t2_spix) |
                          ({16{c_fil}} & fill_m)  |
                          {16{c_one}};

// The destination word: the buffer, or the read data in the cycle it arrives
// (raster operations only: a blended pixel merges from the buffer, the cycle
// after, so the read data never reaches the blend multipliers). The buffer
// word, or the read-ahead entry holding the W token's word: the select from
// flops and the static dp_on only (no grant). It is the entry whenever the
// buffer takes the word from it (w_setd), and the buffer whenever W merges
// into a word the buffer holds (with dp_on the buffer holds only words read:
// every byte valid); elsewhere w_reg is not used.
wire        w_setd;                                       // the buffer starts from the read-ahead word
wire        dp_on;                                        // destination read ahead on (section below)
wire        dp_hit;
wire        w_reg_dp    = dp_on & dp_hit & ~(w_v & (w_wa == t2_dwa));
wire [31:0] w_reg       = w_reg_dp ? (dp_hit1 ? dp1_data : dp_data) : w_data;
wire [31:0] w_base      = w_fill ? vrdata_i : w_reg;
// The destination pixel (DST remap): t2_dboff is a multiple of the pixel size
// (its slot, at the depth latched for the primitive), so a select per depth
// (16 bpp: its low byte), not a shift
wire  [7:0] d_pix8      = ({8{bpp[3] | bpp[4]}} & w_reg[{t2_dboff[4:3], 3'b000} +: 8])       |
                          ({8{bpp[2]}}          & {4'h0, w_reg[{t2_dboff[4:2], 2'b00} +: 4]}) |
                          ({8{bpp[1]}}          & {6'h00, w_reg[{t2_dboff[4:1], 1'b0} +: 2]}) |
                          ({8{bpp[0]}}          & {7'h00, w_reg[t2_dboff]});

function [17:0] blend_ch;
    input  [5:0] s_c;
    input  [5:0] d_c;
    input  [8:0] a_c;
    input [14:0] p_c;                                    // the addend: 128 (MIX5: 0), + a bilinear pixel's Pm
    reg signed [7:0]  diff;
    reg signed [17:0] prod;
    begin
        diff     = $signed({2'b00, s_c}) - $signed({2'b00, d_c});
        prod     = diff * $signed({1'b0, a_c});
        blend_ch = $unsigned($signed({12'h000, d_c}) + ((prod + $signed({3'b000, p_c})) >>> 8));
    end
endfunction

// Blend: out = d + ((s - d) * a + 128) >> 8 per channel, a = 256 for 255;
// MIX5: out = d + ((s - d) * 8 m) >> 8, the factor from F (its ninth bit t2_a9)
wire [15:0] bl_pix;
generate
    if (BLEND_USE) begin : g_blend
        wire  [8:0] a256   = (mix5 | bil_on) ? {t2_a9, t2_alpha} : (t2_alpha == 8'hFF) ? 9'h100 : {1'b0, t2_alpha};
        // the addends: the rounding constant, + Pm of a bilinear pixel
        wire [14:0] rnd    = {7'h00, ~mix5, 7'h00};
        wire [41:0] pm     = {42{bil_on}} & t2_pm;
        wire [14:0] add_r  = {1'b0, pm[41:28]} + rnd;
        wire [14:0] add_g  = {1'b0, pm[27:14]} + rnd;
        wire [14:0] add_b  = {1'b0, pm[13:0]}  + rnd;
        // Blending: 16 bpp, one pixel per token, so the pixel's bit offset is
        // 0 or 16: a 2:1 select in front of the multipliers (d_pix8: the DST
        // remap's index)
        wire [15:0] d_pix  = t2_dboff[4] ? w_reg[31:16] : w_reg[15:0];
        wire [17:0] bl_r_w = blend_ch({1'b0, c_pix[15:11]}, {1'b0, d_pix[15:11]}, a256, add_r);
        wire [17:0] bl_g_w = blend_ch(c_pix[10:5],          d_pix[10:5],          a256, add_g);
        wire [17:0] bl_b_w = blend_ch({1'b0, c_pix[4:0]},   {1'b0, d_pix[4:0]},   a256, add_b);
        assign      bl_pix = {bl_r_w[4:0], bl_g_w[5:0], bl_b_w[4:0]};
        wire [37:0] bl_hi_unused = {bl_r_w[17:5], bl_g_w[17:6], bl_b_w[17:5]};
    end else begin : g_no_blend
        assign      bl_pix = c_pix;                         // (blend_on is 0)
        wire [41:0] pm_unused = t2_pm;                      // (0: bilinear without blending, the straight colour)
    end
endgenerate
wire [15:0] r_pix       = {8'h00, r_sh[7:0]} & bpp_mask16;
wire [15:0] s_pix       = rmp_on   ? r_pix :
                          blend_on ? bl_pix : c_pix;

wire [31:0] s_rep       = ({32{bpp[0]}} & {32{s_pix[0]}})     |
                          ({32{bpp[1]}} & {16{s_pix[1:0]}})   |
                          ({32{bpp[2]}} & { 8{s_pix[3:0]}})   |
                          ({32{bpp[3]}} & { 4{s_pix[7:0]}})   |
                          ({32{bpp[4]}} & { 2{s_pix[15:0]}});
wire [31:0] f_rep       = ({32{bpp[0]}} & {32{fill_m[0]}})    |
                          ({32{bpp[1]}} & {16{fill_m[1:0]}})  |
                          ({32{bpp[2]}} & { 8{fill_m[3:0]}})  |
                          ({32{bpp[3]}} & { 4{fill_m[7:0]}})  |
                          ({32{bpp[4]}} & { 2{fill_m[15:0]}});
wire [31:0] d_word      = {32{need_dst}} & w_base;
// The source operand: the replicated pixel, or a word token's word
wire [31:0] s_opd       = t2_word ? {t2_shi, t2_spix} : s_rep;

// The raster operation as its truth table {SD = 11, 10, 01, 00}, decoded once
// from the static PX_OP (13: zero, 14: ones, 15: the fill colour), then one
// 4:1 select per bit, the destination bit (the latest) the last select
function [3:0] rop_tt;
    input [3:0] op;
    begin
        case (op)
            4'd0:    rop_tt = 4'b1100;                    // S
            4'd1:    rop_tt = 4'b0011;                    // ~S
            4'd2:    rop_tt = 4'b0101;                    // ~D
            4'd3:    rop_tt = 4'b1000;                    // S & D
            4'd4:    rop_tt = 4'b1110;                    // S | D
            4'd5:    rop_tt = 4'b0110;                    // S ^ D
            4'd6:    rop_tt = 4'b0111;                    // ~(S & D)
            4'd7:    rop_tt = 4'b0001;                    // ~(S | D)
            4'd8:    rop_tt = 4'b1001;                    // ~(S ^ D)
            4'd9:    rop_tt = 4'b0010;                    // ~S & D
            4'd10:   rop_tt = 4'b0100;                    // S & ~D
            4'd11:   rop_tt = 4'b1011;                    // ~S | D
            4'd12:   rop_tt = 4'b1101;                    // S | ~D
            4'd14:   rop_tt = 4'b1111;                    // ones
            default: rop_tt = 4'b0000;                    // zero (13), the fill colour (15)
        endcase
    end
endfunction
wire  [3:0] op_tt       = rop_tt(px_op);
wire        op_fill     = (px_op == 4'd15);
wire [31:0] rop;
genvar      gro;
generate
    for (gro = 0; gro < 32; gro = gro + 1) begin : g_rop
        assign rop[gro] = (d_word[gro] ? (s_opd[gro] ? op_tt[3] : op_tt[1]) : (s_opd[gro] ? op_tt[2] : op_tt[0])) |
                          (op_fill & f_rep[gro]);
    end
endgenerate

wire  [3:0] px_be       = {|t2_wmask[31:24], |t2_wmask[23:16], |t2_wmask[15:8], |t2_wmask[7:0]};
wire [31:0] w_merged    = (rop & t2_wmask) | (w_base & ~t2_wmask);

// The pixel's word is in the buffer (read when the destination is needed); a
// word not read starts empty. A finished word moves to the write-back slot
// (no port cycle) and the buffer takes the next word at once.
wire        w_hit       = (w_v & (w_wa == t2_dwa) & (w_ld | ~t2_nd)) | (w_fill & ~blend_on);
wire        w_px        = t2_v & ~w_noop;                 // a pixel to write
wire        w_wanted    = w_px & ~w_hit;                  // switch to the pixel's word
wire        l_busy;                                       // bilinear: L holds a tap (section 2b)
wire        a_empty     = ~t1_v & ~t2_v & ~l_busy;
wire        w_end       = (a_drain | a_abort | freeze_i) & a_empty;
wire        wb_gnt;                                       // the slot is written this cycle
wire        w_mv        = w_dirty & (~wb_v | wb_gnt) & (w_wanted | f_wflush | w_end);
wire        w_free      = ~w_dirty | w_mv;
wire        w_set       = w_wanted & ~t2_nd & w_free;
assign      dp_hit1     = dp1_v & (dp1_wa == t2_dwa);
assign      dp_hit      = (dp_v & (dp_wa == t2_dwa)) | dp_hit1;
wire        dp_fly      = (rd_pend & rd_dp & ~rd_dp1 & (dp_wa  == t2_dwa)) |      // read ahead in flight: wait for it
                          (rd_pend & rd_dp &  rd_dp1 & (dp1_wa == t2_dwa));
assign      w_setd      = w_wanted & dp_on & dp_hit & w_free;      // dp_on: D always read (t2_nd)
// (with remap: once its colour is known; the buffer may take the word before)
assign      w_merge     = w_px & (w_hit | w_set | w_setd) & r_ok;
assign      w_take      = t2_v & (w_noop | ((w_hit | w_set | w_setd) & r_ok));
// (the read needs the slot free already: not the write of this cycle). A word
// with merged bytes, in the slot or moving to it now, is written before it is
// read.
wire        w_rreq      = w_wanted & t2_nd & (~w_dirty | ~wb_v) & ~(wb_v & (wb_wa == t2_dwa)) &
                          ~(w_dirty & (w_wa == t2_dwa)) & rd_free & ~(rd_pend & rd_w) & ~dp_hit & ~dp_fly;

// Remap DST: the destination pixel, once the buffer holds the word (or takes
// it from the read ahead), registered for the lookup the cycle after
wire        d_have      = w_v & (w_wa == t2_dwa) & w_ld;
wire        r_dcap      = r_need & rmp_dst & ~r_dv & (d_have | w_setd);
// The table word {base, index / 4}: the W read slot (after the destination's)
wire        r_rreq      = r_need & (~rmp_dst | r_dv) & ~r_hit & ~w_rreq & rd_free & ~(rd_pend & rd_r);
wire [RB_W+5:0] r_cat   = {rmp_base_i, r_idx[7:2]};
wire [31:0] r_wa32      = {{(26-RB_W){1'b0}}, r_cat};
wire    [WA_W-1:0] r_wa = {|r_wa32[31:VRAM_AW], r_wa32[VRAM_AW-1:0]};

//-----------------------------------------------------------------------------
// The VRAM port, one read in flight. Requesters, by priority:
//   W read      the W token's destination word (w_rreq), or a remap table
//               word (r_rreq): the demand slot of W
//   F read      the F token's source word (f_rreq), or its mask word
//               (m_rreq): the demand slot of F
//   slot urgent the write-back slot when something waits for it (wb_urgent)
//   read ahead  the source word of the token A offers next (la_want), or the
//               word after it (nw_want, RD_REG_EN); then the destination word
//               of the token after W's (dp_want)
//   slot        the write-back slot otherwise
// Entries: the cache c (F's word), the source read-ahead entries pf / pf1
// and the destination ones dp / dp1 (pf1 / dp1 with RD_REG_EN: a read ahead
// issued in the cycle the previous read returns), the mask word m, the
// table word r. An entry is occupied from its grant (its read in flight,
// rd_pend with rd_pf / rd_dp / rd_m / rd_r and rd_pf1 / rd_dp1) to its use.
// Kills: a merge into an entry's word (dp_kill / dp_kill1; pf_kill0 /
// pf_kill1 with RD_REG_EN, without it the hazard checks at the read exclude
// the merge) or the slot's write of it (dp) drops the entry; with RD_LAT > 2
// one in flight is remembered (g_ra_fly) and its data dropped. A start, a
// freeze (held), a new read into the entry and its promotion into the cache
// (pf) or the buffer (dp) also drop it.
// An access at or past VRAM_WORDS is not made (bound).
//-----------------------------------------------------------------------------
// Read ahead: the source word of the token A offers next, when no older token,
// the buffer or the slot has its word, never out of range (speculative: no
// bound error)
wire    [WA_W-1:0] la_wa = nx_swa;                      // a register's word: the walker's or the texel's
wire [31:0] la_wa32     = {{(32-WA_W){1'b0}}, la_wa};
wire        la_tok      = a_run & ~freeze_i & need_src & ~nx_skip & nx_on & ~imm & ~bil_on;
wire        la_have     = (c_v & (c_wa == la_wa)) | (pf0_occ & (pf_wa == la_wa)) | (pf1_occ & (pf1_wa == la_wa)) |
                          (t1_v & t1_sneed & (t1_swa == la_wa));
wire        la_haz      = (t1_v & ~t1_skip & (t1_dwa == la_wa)) |
                          (t2_v & ~t2_skip & (t2_dwa == la_wa)) |
                          (w_v & (w_wa == la_wa)) | (wb_v & (wb_wa == la_wa));
wire        la_keep     = f_need & (pf_wa == t1_swa) & (pf_v | (rd_pend & rd_pf));   // t1 still needs the entry
// RD_REG_EN: a free entry instead of keeping t1's, and the return cycle too
wire        la_free     = ~pf0_occ | ~pf1_occ;
wire        la_sel1     =  pf0_occ;
wire        la_want     = (RD_REG_EN != 0) ?
                          (la_tok & ~la_have & ~la_haz & la_free & (la_wa32 < VRAM_WORDS) & (~rd_pend | vrvalid_i) & ~a_abort) :
                          (la_tok & ~la_have & ~la_haz & ~la_keep & (la_wa32 < VRAM_WORDS) & ~rd_pend & ~a_abort);

// RD_REG_EN, a source walked along the run: once the next token's word is
// covered, the word after it when the run reaches it (never a wrong guess). Younger tokens may still write it: a merge into a read-ahead
// word drops the entry. A read in flight cannot be overtaken: a merge before
// its data needs a token in F or W at the read, which the hazard check
// excludes; a merge in the cycle of the data drops it.
// (the word, nw_wa, and when it may be read, nw_ok: blns_gpu_px_a)
wire        nw_on       = (RD_REG_EN != 0) & nw_ok & ~imm;
wire [31:0] nw_wa32     = {{(32-WA_W){1'b0}}, nw_wa};
wire        nw_have     = (c_v & (c_wa == nw_wa)) | (pf0_occ & (pf_wa == nw_wa)) | (pf1_occ & (pf1_wa == nw_wa)) |
                          (t1_v & t1_sneed & (t1_swa == nw_wa));
wire        nw_haz      = (t1_v & ~t1_skip & (t1_dwa == nw_wa)) |
                          (t2_v & ~t2_skip & (t2_dwa == nw_wa)) |
                          (w_v & (w_wa == nw_wa)) | (wb_v & (wb_wa == nw_wa));
// (the next token's word read or being read: not a demand read F still has to make)
wire        la_got      = (c_v & (c_wa == la_wa)) | (pf0_occ & (pf_wa == la_wa)) | (pf1_occ & (pf1_wa == la_wa));
wire        nw_want     = nw_on & la_tok & la_got & ~nw_have & ~nw_haz & la_free &
                          (nw_wa32 < VRAM_WORDS) & (~rd_pend | vrvalid_i) & ~a_abort;

// Destination read ahead, for an operation that always reads D: the word of
// the token after W's (in t1), else of the token A offers next, when no older
// token, the buffer, the slot or the entry has it (speculative: never out of
// range, no bound error)
// (not when a pixel may be transparent or masked: it would not need its word;
// an AA line's coverage 0 is skipped in A, SET_ALPHA could still make it 0)
wire        dp_aa       = aa_on_i & (~alpha_i[8] | (alpha_i[7:0] == 8'hFF));
assign      dp_on       = need_dst & (~op_no_d | blend_on | rmp_dst) & ~transp_chk & ~(is_exp & ~exp_opaque_i) &
                          ~(is_tex & tex_tr_en) & (~mask_on | dp_aa) & ~(blend_on & alpha_i[8] & (alpha_i[7:0] == 8'h00)) & ~mp_on &
                          ~a8_on & ~(blend_on & alpha_i[8] & mix5 & (alpha_i[7:2] == 6'h00)) & ~bil_on;
wire        dp_t1       = t1_v & ~t1_skip;
wire        dp_old_t1   = ~(t2_v & (t2_dwa == t1_dwa)) & ~(w_v & (w_wa == t1_dwa)) & ~(wb_v & (wb_wa == t1_dwa)) &
                          ~(dp0_occ & (dp_wa == t1_dwa)) & ~(dp1_occ & (dp1_wa == t1_dwa));
wire        dp_old_a    = ~(dp_t1 & (t1_dwa == nx_dwa)) & ~(t2_v & (t2_dwa == nx_dwa)) &
                          ~(w_v & (w_wa == nx_dwa)) & ~(wb_v & (wb_wa == nx_dwa)) &
                          ~(dp0_occ & (dp_wa == nx_dwa)) & ~(dp1_occ & (dp1_wa == nx_dwa));
wire        dp_sel_t1   = dp_t1 & dp_old_t1;
wire        dp_a        = a_run & ~freeze_i & nx_on & ~nx_skip & dp_old_a;
wire    [WA_W-1:0] dp_ta = dp_sel_t1 ? t1_dwa : nx_dwa;
wire [31:0] dp_wa32     = {{(32-WA_W){1'b0}}, dp_ta};
// the entry is kept while a token in F or W still wants its word (not in the
// cycle the buffer takes it without waiting for the slot's write)
wire        dp_take     = w_wanted & dp_on & dp_hit & (~w_dirty | ~wb_v);
wire        dp_keep     = (dp_v | (rd_pend & rd_dp)) & ((t1_v & (t1_dwa == dp_wa)) | (t2_v & (t2_dwa == dp_wa))) & ~dp_take;
wire        dp_free     = ~dp0_occ | ~dp1_occ;
wire        dp_sel1     =  dp0_occ;
wire        dp_want     = (RD_REG_EN != 0) ?
                          (dp_on & (dp_sel_t1 | dp_a) & dp_free & (dp_wa32 < VRAM_WORDS) & (~rd_pend | vrvalid_i) & ~a_abort & ~freeze_i) :
                          (dp_on & (dp_sel_t1 | dp_a) & ~dp_keep & (dp_wa32 < VRAM_WORDS) & ~rd_pend & ~a_abort & ~freeze_i);
wire        wb_urgent   = (w_dirty & (w_wanted | f_wflush | w_end)) | f_wb_wait |
                          (w_wanted & (wb_wa == t2_dwa)) | a_drain | a_abort | freeze_i;
// The demand slots: W's (its destination word, or a table word), F's (its
// source word, or a mask word); their addresses come from registers
wire        w_slot      = w_rreq | r_rreq;
wire    [WA_W-1:0] w_pa = r_rreq ? r_wa : t2_dwa;
// (bilinear: a tap's colour word, b_creq, or its A8 word, b_areq: section 2b)
wire        b_creq;
wire        b_areq;
wire        f_slot      = f_rreq | m_rreq | b_creq | b_areq;
wire        f_mword     = m_rreq | b_areq;
wire    [WA_W-1:0] f_pa = f_mword ? {1'b0, t1_mwa} : t1_swa;
wire        rd_any      = w_slot | f_slot;
wire        ra_want     = la_want | (nw_want & ~dp_want);  // a source read ahead (this token's word, or the next)
// (without RD_REG_EN a read ahead is la_want's: no select, nw_wa is 0)
wire    [WA_W-1:0] ra_wa = ((RD_REG_EN != 0) & ~la_want) ? nw_wa : la_wa;
// (the A8 read ahead, ma_want, never with dp_want: an RGB565A8 copy reads no
// destination ahead)
wire        ma_want;
wire [VRAM_AW-1:0] ma_ta;                                // ... its word
// Out of range, per demand source from its registers (beside the slot
// selects, not after the address mux), then selected as the address is: the
// same as p_addr >= VRAM_WORDS whenever p_want
wire        t2_oob      = {{(32-WA_W){1'b0}}, t2_dwa} >= VRAM_WORDS;
wire        r_oob       = {{(32-WA_W){1'b0}}, r_wa}   >= VRAM_WORDS;
wire        t1s_oob     = {{(32-WA_W){1'b0}}, t1_swa} >= VRAM_WORDS;
wire        t1m_oob     = ({{(33-WA_W){1'b0}}, t1_mwa} >= VRAM_WORDS) | t1_mhi;
wire        wb_oob      = {{(32-WA_W){1'b0}}, wb_wa}  >= VRAM_WORDS;
wire        w_oob       = r_rreq ? r_oob : t2_oob;
wire        f_oob       = f_mword ? t1m_oob : t1s_oob;
// An F read past the VRAM (and an immediate index past it) waits while an
// older pixel is still to merge: W may not take its token in the cycle (a
// blended pixel merges the cycle after its read data, a DST remap looks its
// colour up first, the buffer may wait for the slot), a bilinear one goes
// through L first: the pixels before the faulting one are drawn. Meanwhile
// the slot may write (W may need it to take its word) and the F slot neither
// selects the port nor raises the bound error
wire        f_bnd_wait  = ~w_slot & f_slot & f_oob & (t2_v | l_busy);
wire        f_slot_p    = f_slot & ~f_bnd_wait;          // F's slot on the port
wire        wb_sel      = wb_v & ~(w_slot | f_slot_p) & (wb_urgent | (~ra_want & ~dp_want & ~ma_want));
wire        pf_req      = ra_want & ~rd_any & ~(wb_v & wb_urgent);
wire        dp_req      = dp_want & ~ra_want & ~rd_any & ~(wb_v & wb_urgent);
wire        ma_req      = ma_want & ~ra_want & ~rd_any & ~(wb_v & wb_urgent);

wire    [WA_W-1:0] p_addr = w_slot ? w_pa : f_slot_p ? f_pa : wb_sel ? wb_wa : ra_want ? ra_wa :
                            ma_want ? {1'b0, ma_ta} : dp_ta;
wire        p_want      = w_slot | f_slot_p | wb_sel;
wire        p_oob       = w_slot ? w_oob : f_slot_p ? f_oob : wb_oob;
wire        p_req       = (p_want & ~p_oob & ~a_abort) | pf_req | dp_req | ma_req;
wire        p_gnt       = p_req & vgnt_i;
wire        p_rd_gnt    = p_gnt & ~wb_sel;
wire        w_rd_gnt    = p_rd_gnt &  w_rreq;
wire        r_rd_gnt    = p_rd_gnt &  r_rreq;
assign      f_rd_gnt    = p_rd_gnt &  f_rreq & ~w_slot;
wire        m_rd_gnt    = p_rd_gnt &  m_rreq & ~w_slot;
assign      la_gnt      = p_rd_gnt & ~rd_any & ra_want;
wire        dp_gnt      = p_rd_gnt & ~rd_any & ~ra_want & ~ma_want;
wire        ma_gnt      = p_rd_gnt & ~rd_any & ~ra_want &  ma_want;
wire        bound       = ((p_want & p_oob) | (i_oob & ~t2_v & ~l_busy)) & ~a_abort;
// Aborting: the slot is written if it lies inside the VRAM, else dropped
wire        ab_flush    = a_abort & wb_v & ~wb_oob;
assign      wb_gnt      = (p_gnt & wb_sel) | (ab_flush & vgnt_i);

// Priority: grant (a read issued) > its data
wire        rd_pend_nxt = p_rd_gnt | (rd_pend & ~vrvalid_i);
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_pend (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(rd_pend_nxt), .q_o(rd_pend));
arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_rd_w (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(p_rd_gnt), .d_i({w_rreq, la_gnt, dp_gnt}), .q_o({rd_w, rd_pf, rd_dp}));

//-----------------------------------------------------------------------------
// 2b) BILINEAR TAPS (BIL_USE): the F token is a tap; its colour word (and, for
// an RGB565A8 texture, its A8 byte) from the tap cache, a miss read in F's
// slot (the colour word first, then the A8 word: no hazard checks, a texture
// must not overlap its destination). The tap goes to L with its texel, its
// alpha (255 or its A8 byte; 0 when keyed with TRANSP_EN; times A with
// SET_ALPHA EN, on the coverage multiplier) and its weight; L hands W the
// pixel (t2_ld). A skipped pixel's token goes through L without a read.
//-----------------------------------------------------------------------------
generate
    if (BIL_USE) begin : g_bil
        wire        tc_hit;
        wire        tc_ahit;
        wire [31:0] tc_data;
        wire  [7:0] tc_abyte;
        wire        tc_cok;
        wire        b_need    = t1_v & bil_on & ~t1_skip;
        wire        b_hit     = tc_hit & ~t1_swa[WA_W-1];  // (a word past 2^VRAM_AW is never held: its read is a bound error)
        wire        b_ahit    = ~a8_on | tc_ahit;
        // The words of the tap's own reads are also taken in the cycle they
        // arrive (the colour word not overtaken; its A8 byte only from a held
        // colour word's companion or the A8 read)
        wire        b_cbyp    = vrvalid_i & rd_pend & rd_bc & tc_cok;
        wire        b_abyp    = vrvalid_i & rd_pend & rd_ba;
        assign      b_ready   = t1_skip | ((b_hit | b_cbyp) & (~a8_on | (b_hit & tc_ahit) | b_abyp));
        wire        b_rd_ok   = rd_free & ~(rd_pend & ~rd_w);
        assign      b_creq    = b_need & ~b_hit & b_rd_ok;
        assign      b_areq    = b_need & b_hit & ~b_ahit & b_rd_ok;
        wire        b_cgnt    = p_rd_gnt & b_creq & ~w_slot;
        wire        b_agnt    = p_rd_gnt & b_areq & ~w_slot;
        wire        rd_bc_nxt = b_cgnt | (rd_bc & ~p_rd_gnt);
        wire        rd_ba_nxt = b_agnt | (rd_ba & ~p_rd_gnt);
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_rd_b (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
             .d_i({rd_bc_nxt, rd_ba_nxt}), .q_o({rd_bc, rd_ba}));
        // The tap's A8 byte and its neighbour's (the other texel of the colour
        // word), when they share the A8 word
        wire        a_part    = t1_rot[4] ? (t1_mrot[1:0] != 2'd0) : (t1_mrot[1:0] != 2'd3);
        blns_gpu_px_tc #(
            .VRAM_AW       (VRAM_AW),
            .ASYNC_RST_EN  (ASYNC_RST_EN)
        ) u_px_tc (
        // CLOCK & RESET
            .hclk_i        (hclk_i),
            .hresetn_i     (hresetn_i),
        // CONTROL
            .clr_i         (go | held),
        // LOOK-UP
            .lk_wa_i       (t1_swa[VRAM_AW-1:0]),
            .lk_par_i      (t1_ypar_i),
            .lk_slot_i     (t1_rot[4]),
            .hit_o         (tc_hit),
            .data_o        (tc_data),
            .ahit_o        (tc_ahit),
            .abyte_o       (tc_abyte),
        // FILLS
            .cgnt_i        (b_cgnt),
            .agnt_i        (b_agnt),
            .alane_i       (t1_mrot[1:0]),
            .apart_i       (a_part),
            .cfill_i       (vrvalid_i & rd_pend & rd_bc),
            .afill_i       (vrvalid_i & rd_pend & rd_ba),
            .rdata_i       (vrdata_i),
        // DROPS
            .wm_i          (w_merge),
            .wm_wa_i       (t2_dwa[VRAM_AW-1:0]),
            .ww_i          (wb_gnt),
            .ww_wa_i       (wb_wa[VRAM_AW-1:0]),
            .fly_i         (rd_pend & ~vrvalid_i & rd_bc),
            .cok_o         (tc_cok)
        );
        // The tap: its texel, its alpha before A (keyed raw texel: 0, applied
        // after the multiply: f_tal). The texel's key is compared on both
        // candidates, the read data and the cache entry, so the bypass select
        // (from the overtake check, after the port grant) comes last
        wire [15:0] b_tex_vr  = t1_rot[4] ? vrdata_i[31:16] : vrdata_i[15:0];
        wire [15:0] b_tex_tc  = t1_rot[4] ? tc_data[31:16]  : tc_data[15:0];
        wire [15:0] b_tex     = b_cbyp ? b_tex_vr : b_tex_tc;
        wire  [7:0] b_ab      = b_abyp ? vrdata_i[{t1_mrot[1:0], 3'b000} +: 8] : tc_abyte;
        wire        b_key_vr  = (b_tex_vr == transp_i);
        wire        b_key_tc  = (b_tex_tc == transp_i);
        assign      b_key     = BLEND_USE & tex_tr_en & (b_cbyp ? b_key_vr : b_key_tc);
        wire  [1:0] b_key_unused = {b_key_vr, b_key_tc};   // GPU_BLEND_EN = 0: no key
        assign      b_acov    = a8_on ? b_ab : 8'hFF;
        wire [41:0] l_pm;
        blns_gpu_px_l #(
            .WA_W          (WA_W),
            .GPU_BLEND_EN  (GPU_BLEND_EN),
            .ASYNC_RST_EN  (ASYNC_RST_EN)
        ) u_px_l (
        // CLOCK & RESET
            .hclk_i        (hclk_i),
            .hresetn_i     (hresetn_i),
        // CONTROL
            .clr_i         (go | a_abort | abort_i),
            .mix5_i        (mix5),
        // TAP IN
            .in_v_i        (f_take & bil_on),
            .in_free_o     (l_free),
            .in_tex_i      (b_tex),
            .in_a_i        (f_tal),
            .in_k_i        (t1_k_i),
            .in_last_i     (t1_tlast_i),
            .in_skip_i     (t1_skip),
            .in_dwa_i      (t1_dwa),
            .in_dhi_i      (t1_dboff[4]),
        // PIXEL OUT
            .out_free_i    (t2_free),
            .out_v_o       (l_out),
            .out_dwa_o     (l_dwa),
            .out_dhi_o     (l_dhi),
            .out_noop_o    (l_noop),
            .out_nd_o      (l_nd),
            .out_a256_o    (l_a256),
            .out_pm_o      (l_pm),
            .out_pix_o     (l_pix),
            .busy_o        (l_busy)
        );
        if (BLEND_USE) begin : g_t2_pm
            arv_ipdff #(.WIDTH(42), .ARST_EN(ASYNC_RST_EN)) u_t2_pm (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(t2_ld), .d_i(l_pm), .q_o(t2_pm));
        end else begin : g_no_t2_pm
            assign t2_pm = 42'd0;
            wire [41:0] pm_unused = l_pm;                    // no blending: the straight colour
        end
    end else begin : g_no_bil
        assign      b_ready   = 1'b1;
        assign      b_creq    = 1'b0;
        assign      b_areq    = 1'b0;
        assign      b_acov    = 8'h00;
        assign      b_key     = 1'b0;
        assign      l_free    = 1'b1;
        assign      l_out     = 1'b0;
        assign      l_dwa     = {WA_W{1'b0}};
        assign      l_dhi     = 1'b0;
        assign      l_noop    = 1'b0;
        assign      l_nd      = 1'b0;
        assign      l_a256    = 9'd0;
        assign      l_pix     = 16'h0000;
        assign      l_busy    = 1'b0;
        assign      rd_bc     = 1'b0;
        assign      rd_ba     = 1'b0;
        assign      t2_pm     = 42'd0;
        wire [20:0] bil_unused = {t1_k_i, t1_tlast_i, t1_ypar_i, f_tal};   // GPU_BILINEAR_EN = 0
    end
endgenerate

//-----------------------------------------------------------------------------
// Mask entry (F) and remap table cache, captured destination pixel (W)
//-----------------------------------------------------------------------------
generate
    if (MHOLD_USE) begin : g_msk
        // Mask entry (or A8 word): priority start / hold / its read issued >
        // arrival (the read for another word drops it)
        // (RGB565A8: or the read-ahead entry's word, taken with its token)
        wire m_promo = f_take & m_hit_a;
        wire m_v_nxt = ~go & ~held & ~m_rd_gnt & (m_fill | m_promo | m_v);
        wire rd_m_nxt = m_rd_gnt | (rd_m & ~p_rd_gnt);
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_m_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({m_v_nxt, rd_m_nxt}), .q_o({m_v, rd_m}));
        arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_m_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m_rd_gnt | m_promo), .d_i(m_promo ? ma_wa : t1_mwa), .q_o(m_wa));
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_m_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m_fill | m_promo), .d_i(m_promo ? ma_data : vrdata_i), .q_o(m_data));
        if (BLEND_USE) begin : g_ma
            // A8 read ahead (an RGB565A8 copy or nearest texture): in an
            // idle port cycle (the cycle a read returns included: the entry
            // is its own), the A8 word of the F token when it misses (its
            // demand read cannot go in that cycle), else of the token A offers
            // next, when neither the holder nor the entry has it (never out
            // of range: no bound error). One entry: priority start / hold / a
            // new read / taken by the holder > arrival
            wire        ma_occ  = ma_v | (rd_pend & rd_ma);
            wire        ma_keep = m_need & ma_v & (ma_wa == t1_mwa);       // the F token still wants it
            wire        ma_t1   = m_need & ~m_hit & ~t1_mhi;               // the F token's word is missing
            assign      ma_ta   = ma_t1 ? t1_mwa : nx_mwa_i;
            wire [31:0] ma_t32  = {{(32-VRAM_AW){1'b0}}, ma_ta};
            assign      ma_want = a8_on & ~bil_on & (ma_t1 | (a_run & ~freeze_i & nx_on & ~nx_skip & ~nx_mhi_i)) &
                                  (ma_t32 < VRAM_WORDS) & ~(m_v & (m_wa == ma_ta)) & ~(ma_occ & (ma_wa == ma_ta)) &
                                  ~ma_keep & (~rd_pend | vrvalid_i) & ~a_abort;
            wire        ma_fill = vrvalid_i & rd_pend & rd_ma;
            wire        ma_v_nxt = ~go & ~held & ~ma_gnt & ~m_promo & (ma_fill | ma_v);
            wire        rd_ma_nxt = ma_gnt | (rd_ma & ~p_rd_gnt);
            arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_ma_v (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({ma_v_nxt, rd_ma_nxt}), .q_o({ma_v, rd_ma}));
            arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_ma_wa (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ma_gnt), .d_i(ma_ta), .q_o(ma_wa));
            arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_ma_data (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ma_fill), .d_i(vrdata_i), .q_o(ma_data));
        end else begin : g_no_ma
            assign ma_want = 1'b0;
            assign ma_ta   = {VRAM_AW{1'b0}};
            assign ma_v    = 1'b0;
            assign rd_ma   = 1'b0;
            assign ma_wa   = {VRAM_AW{1'b0}};
            assign ma_data = 32'h0000_0000;
            wire [VRAM_AW+1:0] ma_unused = {ma_gnt, nx_mwa_i, nx_mhi_i};   // GPU_BLEND_EN = 0
        end
    end else begin : g_no_msk
        assign m_v    = 1'b0;
        assign rd_m   = 1'b0;
        assign m_wa   = {VRAM_AW{1'b0}};
        assign m_data = 32'h0000_0000;
        assign ma_want = 1'b0;
        assign ma_ta   = {VRAM_AW{1'b0}};
        assign ma_v    = 1'b0;
        assign rd_ma   = 1'b0;
        assign ma_wa   = {VRAM_AW{1'b0}};
        assign ma_data = 32'h0000_0000;
        wire [VRAM_AW+3:0] msk_unused = {m_rd_gnt, m_fill, ma_gnt, nx_mwa_i, nx_mhi_i};   // GPU_MPLANE_EN = 0, GPU_BLEND_EN = 0
    end
    if (REMAP_USE) begin : g_rmp
        // Table cache: priority start / hold / a table read issued > arrival
        wire r_v_nxt  = ~go & ~held & ~r_rd_gnt & (r_fill | r_v);
        // Captured pixel: priority start / drop > capture > the token leaves
        wire r_dv_nxt = ~go & ~a_abort & ~abort_i & (r_dcap | (r_dv & ~w_take));
        wire rd_r_nxt = r_rd_gnt | (rd_r & ~p_rd_gnt);
        arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_r_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({r_v_nxt, r_dv_nxt, rd_r_nxt}), .q_o({r_v, r_dv, rd_r}));
        arv_ipdff #(.WIDTH(6), .ARST_EN(ASYNC_RST_EN)) u_r_tag (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(r_rd_gnt), .d_i(r_idx[7:2]), .q_o(r_tag));
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_r_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(r_fill), .d_i(vrdata_i), .q_o(r_data));
        arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_r_didx (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(r_dcap), .d_i(d_pix8), .q_o(r_didx));
    end else begin : g_no_rmp
        assign r_v    = 1'b0;
        assign r_dv   = 1'b0;
        assign rd_r   = 1'b0;
        assign r_tag  = 6'h00;
        assign r_data = 32'h0000_0000;
        assign r_didx = 8'h00;
        wire [WA_W+10:0] rmp_unused = {r_rd_gnt, r_fill, r_dcap, r_wa, d_pix8};   // GPU_REMAP_EN = 0
    end
endgenerate
// RD_LAT > 2: a younger token can merge into a read ahead's word (or the slot
// write it) while the read is in flight, before the cycle of its data that
// the entries check: the kill is kept until then and the data dropped. This
// (and the hazard checks of the read aheads, which hold up to latency 2)
// relies on the data coming exactly RD_LAT cycles after the grant: a memory
// with a variable latency needs the in-flight kill for every latency
generate
    if (RD_LAT > 2) begin : g_ra_fly
        wire [WA_W-1:0] fly_wa   = rd_pf ? (rd_pf1 ? pf1_wa : pf_wa) : (rd_dp1 ? dp1_wa : dp_wa);
        wire            fly_kill = rd_pend & ~vrvalid_i & (rd_pf | rd_dp) &
                                   ((w_merge & (t2_dwa == fly_wa)) | (rd_dp & wb_gnt & (wb_wa == fly_wa)));
        wire            ra_drop_nxt = ~p_rd_gnt & rd_pend & ~vrvalid_i & (ra_drop | fly_kill);
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_ra_drop (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(ra_drop_nxt), .q_o(ra_drop));
    end else begin : g_no_ra_fly
        assign ra_drop = 1'b0;
    end
endgenerate

// Destination read-ahead entry: priority start / hold / a new read / taken by
// the buffer / its word written or merged > arrival
wire        dp_kill     = (wb_gnt & (wb_wa == dp_wa)) | (w_merge & (t2_dwa == dp_wa));
wire        dp_v_nxt    = (RD_REG_EN != 0) ? (~go & ~held & ~(w_setd & ~dp_hit1) & ~dp_kill & (dp_fill0 | dp_v)) :
                                             (~go & ~held & ~dp_gnt & ~w_setd & ~dp_kill & (dp_fill | dp_v));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_dp_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(dp_v_nxt), .q_o(dp_v));
arv_ipdff #(.WIDTH(WA_W), .ARST_EN(ASYNC_RST_EN)) u_dp_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dp_gnt & ~(dp_sel1 & (RD_REG_EN != 0))), .d_i(dp_ta), .q_o(dp_wa));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_dp_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dp_fill0), .d_i(vrdata_i), .q_o(dp_data));
arv_ipdff #(.WIDTH(WA_W), .ARST_EN(ASYNC_RST_EN)) u_pf_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(la_gnt & ~(la_sel1 & (RD_REG_EN != 0))), .d_i(ra_wa), .q_o(pf_wa));

generate
    if (RD_REG_EN != 0) begin : g_ra2
        // Second entries: allocated when the first is occupied, filled by the
        // read recorded at the grant, freed like the first
        wire dp_kill1  = (wb_gnt & (wb_wa == dp1_wa)) | (w_merge & (t2_dwa == dp1_wa));
        wire pf_kill1  = w_merge & (t2_dwa == pf1_wa);
        wire pf1_v_nxt = ~go & ~(c_promo & f_use_p1) & ~held & ~pf_kill1 & (p_fill1 | pf1_v);
        wire dp1_v_nxt = ~go & ~held & ~(w_setd & dp_hit1) & ~dp_kill1 & (dp_fill1 | dp1_v);
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_ra2_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({pf1_v_nxt, dp1_v_nxt}), .q_o({pf1_v, dp1_v}));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_pf1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(la_gnt), .d_i(la_sel1), .q_o(rd_pf1));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_dp1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dp_gnt), .d_i(dp_sel1), .q_o(rd_dp1));
        arv_ipdff #(.WIDTH(WA_W), .ARST_EN(ASYNC_RST_EN)) u_pf1_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(la_gnt & la_sel1), .d_i(ra_wa), .q_o(pf1_wa));
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_pf1_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(p_fill1), .d_i(vrdata_i), .q_o(pf1_data));
        arv_ipdff #(.WIDTH(WA_W), .ARST_EN(ASYNC_RST_EN)) u_dp1_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dp_gnt & dp_sel1), .d_i(dp_ta), .q_o(dp1_wa));
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_dp1_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dp_fill1), .d_i(vrdata_i), .q_o(dp1_data));
        wire [1:0] ra2_unused = {la_keep, dp_keep};
    end else begin : g_no_ra2
        assign pf1_v    = 1'b0;
        assign pf1_wa   = {WA_W{1'b0}};
        assign pf1_data = 32'h0000_0000;
        assign dp1_v    = 1'b0;
        assign dp1_wa   = {WA_W{1'b0}};
        assign dp1_data = 32'h0000_0000;
        assign rd_pf1   = 1'b0;
        assign rd_dp1   = 1'b0;
        wire [6:0] ra2_unused = {la_free, dp_free, dp_fill1, la_sel1, dp_sel1, f_use_p1, pf_kill0};
    end
endgenerate

// Buffer: priority start (empty) > read data > a new word > merge > moved to
// the slot; a word being read, or held while frozen, is not valid. Its pixels
// are dropped with an out-of-range slot (they come after the faulting access)
wire        wb_drop     = a_abort & wb_v & wb_oob;
wire        w_v_nxt     = ~go & ~(a_idle & ~start_i) & (w_fill | w_set | w_setd | (w_v & ~w_rd_gnt & ~held));
wire        w_ld_nxt    = w_fill | w_setd | (w_ld & ~w_set & ~w_rd_gnt);
wire        w_dirty_nxt = ~go & ~wb_drop & (w_merge | (w_dirty & ~w_mv));
wire        w_wa_en     = w_fill | w_set | w_setd;
// (remap: the buffer may take the read-ahead word a cycle before the merge)
wire        w_setd_nm   = w_setd & ~r_ok;
wire [31:0] w_data_nxt  = w_merge ? w_merged : w_setd_nm ? w_reg : vrdata_i;
wire        w_data_en   = w_fill | w_merge | w_setd_nm;
wire  [3:0] w_be;
wire        w_be_clr    = go | wb_drop | w_mv | w_fill | w_set | w_setd;
wire  [3:0] w_be_nxt    = ({4{~w_be_clr}} & w_be) | ({4{w_merge}} & px_be);
wire        w_be_en     = w_be_clr | w_merge;

arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_w_flags (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
             .d_i({w_v_nxt, w_ld_nxt, w_dirty_nxt}), .q_o({w_v, w_ld, w_dirty}));
arv_ipdff #(.WIDTH(WA_W), .ARST_EN(ASYNC_RST_EN)) u_w_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(w_wa_en | w_rd_gnt), .d_i(t2_dwa), .q_o(w_wa));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_w_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(w_data_en), .d_i(w_data_nxt), .q_o(w_data));
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_w_be (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(w_be_en), .d_i(w_be_nxt), .q_o(w_be));

// Write-back slot: priority start > the buffer word moved in > written /
// dropped (aborting, out of range)
wire  [3:0] wb_be;
wire        wb_v_nxt    = ~go & (w_mv | (wb_v & ~wb_gnt & ~wb_drop));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_wb_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(wb_v_nxt), .q_o(wb_v));
arv_ipdff #(.WIDTH(WA_W + 37), .ARST_EN(ASYNC_RST_EN)) u_wb (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(w_mv),
             .d_i({w_wa, w_data, w_be, w_ld}), .q_o({wb_wa, wb_data, wb_be, wb_ld}));

// Cache: the word address at the read, its data on arrival
// (an immediate word: its index, the FIFO head or 0). The word is below
// VRAM_WORDS: a read granted, a read-ahead entry (never out of range), an
// immediate index loaded only below t1_swa (i_oob): no "past" bit
wire    [WA_W-1:0] c_wa_d = i_ld ? i_cnt : t1_swa;
wire [VRAM_AW-1:0] c_wa_q;
arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_c_wa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(f_rd_gnt | c_promo | i_ld), .d_i(c_wa_d[VRAM_AW-1:0]), .q_o(c_wa_q));
assign             c_wa   = {1'b0, c_wa_q};
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_c_data (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(c_fill | c_promo | i_ld),
             .d_i(i_ld ? (imm_word_i & {32{imm_avail_i}}) : c_fill ? vrdata_i : f_word), .q_o(c_data));

//=============================================================================
// 4)  SEQUENCE
//=============================================================================
wire       a_last_emit = a_last_emit_i;                  // A issued its last token
wire       all_clean   = a_empty & ~w_dirty & ~wb_v & ~rd_pend;
wire       fin         = a_drain & all_clean & ~freeze_i;   // no GPU_DONE while held
// Aborting ends once the slot is written (or dropped), the cycle after its
// write: no grant in the state's next value
wire       ab_done     = a_abort & a_empty & ~rd_pend & ~w_dirty & (~wb_v | wb_oob);

wire       ab_go       = (abort_i & ~a_idle & ~a_abort) | bound;
// Priority: abort / bound > start > init done > drained > last token issued
wire       a_to_drain  = (a_st == AS_RUN) & a_done;
wire       a_st_en     = ab_go | go | a_init | a_to_drain | fin | ab_done;
wire [2:0] a_st_nxt    = ab_go             ? AS_ABORT :
                         go                ? AS_INIT  :
                         a_init            ? AS_RUN   :
                         (fin | ab_done)   ? AS_IDLE  :
                         a_to_drain        ? AS_DRAIN :
                                             a_st;

arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_a_st (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_st_en), .d_i(a_st_nxt), .q_o(a_st));
// (a_last_emit only while a_run: a_done is one cycle, the state then leaves RUN)
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_a_done (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(a_last_emit & ~ab_go), .q_o(a_done));

//=============================================================================
// 5)  OUTPUTS
//=============================================================================
assign vreq_o   = p_req | ab_flush;
assign vwe_o    = wb_sel | ab_flush;
assign vbe_o    = wb_be;
assign vaddr_o  = ab_flush ? wb_wa[VRAM_AW-1:0] : p_addr[VRAM_AW-1:0];
assign vwaddr_o = wb_wa[VRAM_AW-1:0];                    // a write is the write buffer's (wb_sel: no read)
assign vwdata_o = wb_data;
assign busy_o   = ~a_idle;
assign done_o   = fin & ~abort_i;
assign held     = freeze_i & (a_idle | (~a_init & all_clean));
assign held_o   = held;
assign bound_o  = bound;

assign go_o      = go;
assign a_init_o  = a_init;
assign a_run_o   = a_run;
assign a_abort_o = a_abort;
assign f_take_o  = f_take;

//=============================================================================
// 6)  LINT CLEANUP
//=============================================================================
wire [31:0] f_rot_unused   = f_rot64[63:32];
wire [31:0] m_rot_unused   = m_rot64[63:32];
wire [23:0] r_sh_unused    = r_sh[31:8];
wire        p_addr_unused  = p_addr[WA_W-1];             // past 2^VRAM_AW: p_oob, from the sources
wire        c_wa_unused    = c_wa_d[WA_W-1];             // the cache word is below VRAM_WORDS
wire  [1:0] feat_unused    = {bil_on_i, t1_mhi_i};       // GPU_BILINEAR_EN = 0, GPU_BLEND_EN = 0
wire        nw_ok_unused   = nw_ok;                      // VRAM_RD_REG_EN = 0 (no next-word read)

endmodule // blns_gpu_px_fw

`default_nettype wire
