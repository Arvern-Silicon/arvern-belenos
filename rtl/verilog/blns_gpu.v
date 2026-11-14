//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu.v
// Module Description : 2D graphics engine: command FIFO, command lists in VRAM
//                      (CALL), decoder and rectangle DMA (FILL / COPY /
//                      COPY_TRANSPARENT, 16 raster operations),
//                      the immediate source (data words through the FIFO,
//                      tagged as pushed), lines (EXEC_FILL LINE: solid,
//                      dashed, anti-aliased), the partial-command discard
//                      (GPU_CTRL.DISCARD: a marker through the FIFO), the
//                      GPU_FIFO_LOW event (programmable threshold), RGB565A8
//                      sources and the MIX5 blend rule (blending) and
//                      bilinear texture sampling (GPU_BILINEAR_EN).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu #(
    parameter                    VRAM_WORDS     = 38400, // VRAM depth in 32-bit words
    parameter                    VRAM_AW        = 16,   // VRAM word-address width
    parameter                    DIM_W          = 10,   // width/height field width
    parameter                    GPU_XY_EN      = 1,    // x/y destinations and clip
    parameter                    GPU_GRAD_EN    = 1,    // gradient fill
    parameter                    GPU_BLEND_EN   = 0,    // alpha blending at 16 bpp
    parameter                    GPU_TRI_EN     = 0,    // triangle fill
    parameter                    GPU_RUNAHEAD_EN = 0,   // set-up of the next primitive while one draws
    parameter                    GPU_REMAP_EN    = 1,   // palette remap
    parameter                    GPU_MPLANE_EN   = 1,   // mask plane on copies
    parameter                    GPU_IMM_EN      = 1,   // immediate source (SET_SRC IMM)
    parameter                    GPU_LINE_EN     = 1,   // lines (EXEC_FILL LINE), needs GPU_XY_EN
    parameter                    GPU_BILINEAR_EN = 0,   // bilinear texture sampling (SET_AUX TEX_FILTER), needs GPU_XY_EN
    parameter                    GPU_FIFO_AW     = 3,   // command FIFO: 2^GPU_FIFO_AW words (3..6)
    parameter                    RD_LAT         = 1,    // VRAM read latency: data RD_LAT cycles after the grant (1-4)
    parameter                    ASYNC_RST_EN   = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
    input  wire                  hclk_i,                // clock
    input  wire                  hresetn_i,             // active-low reset (style per ASYNC_RST_EN)
    input  wire                  rb_valid_i,            // register-bus transfer pending (held until ready)
    input  wire                  rb_sel_i,              // this slave is selected
    input  wire                  rb_wr_i,               // 1 = write, 0 = read
    input  wire            [4:2] rb_addr_i,             // word offset inside the slave window
    input  wire           [31:0] rb_wdata_i,            // write data
    output wire           [31:0] rb_rdata_o,            // read data (valid with ready)
    output wire                  rb_ready_o,            // transfer completes this cycle
    input  wire            [2:0] gfx_mode_i,            // CTRL.GFX_MODE
    input  wire      [DIM_W-1:0] disp_width_i,          // display width (default surface pitch)
    input  wire                  gpu_en_i,              // CTRL.GPU_EN (0 = flush, abort, idle)
    input  wire                  freeze_i,              // debug time freeze (DBG_CTRL[1] & stoptime)
    input  wire                  refr_done_i,           // a frame sent to the panel ended (1 cycle)
    output wire                  vreq_o,                // VRAM request (up while an access waits; its address may change)
    output wire                  vwe_o,                 // 1 = write
    output wire            [3:0] vbe_o,                 // byte enables (writes)
    output wire    [VRAM_AW-1:0] vaddr_o,               // word address
    output wire    [VRAM_AW-1:0] vwaddr_o,              // ... of a write (= vaddr_o with vwe_o), from a flop
    output wire           [31:0] vwdata_o,              // write data
    output wire                  vtag_o,                // read tag: a command list read
    input  wire                  vgnt_i,                // grant: access issued this cycle
    input  wire                  vrvalid_i,             // read data valid: exactly RD_LAT cycles after the grant, in grant order
    input  wire                  vrtag_i,               // the returning read's tag (with vrvalid_i)
    input  wire           [31:0] vrdata_i,              // read data
    output wire                  busy_o,                // FIFO not empty or DMA busy
    output wire                  err_o,                 // decoder in error
    output wire                  done_evt_o,            // EXEC completed (1 cycle)
    output wire                  fence_evt_o,           // FENCE with IRQ reached (1 cycle)
    output wire                  idle_evt_o,            // became idle (1 cycle)
    output wire                  ovfl_evt_o,            // command dropped (1 cycle)
    output wire                  err_evt_o,             // entered error (1 cycle)
    output wire                  fifo_low_evt_o         // FREE rose above GPU_FIFO_LOW.THRESH (1 cycle)
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================
localparam PA_W           = VRAM_AW + 5;
localparam RB_W           = (VRAM_AW > 6) ? (VRAM_AW - 6) : 1;   // remap table base: word address / 64
localparam FIFO_AW        = GPU_FIFO_AW;                // command FIFO: 2^FIFO_AW words
localparam FIFO_DEPTH_USE = 1 << FIFO_AW;
localparam IMM_USE        = (GPU_IMM_EN != 0);
localparam [0:0] TRI_USE  = (GPU_TRI_EN != 0) && (GPU_XY_EN != 0);   // triangles are x/y-only (passed down)
localparam [0:0] LINE_USE = (GPU_LINE_EN != 0) && (GPU_XY_EN != 0);  // lines too
localparam [0:0] BIL_USE  = (GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0);   // bilinear sampling too
localparam       BLEND_USE = (GPU_BLEND_EN != 0);

// pragma translate_off
generate
    if ((VRAM_AW < 1) || (VRAM_AW > 24) || (VRAM_WORDS < 1) || (VRAM_WORDS > (1 << VRAM_AW)) ||
        ((VRAM_AW > 1) && (VRAM_WORDS <= (1 << (VRAM_AW-1))))) begin : CHECK_VRAM
        initial $fatal(1, "blns_gpu: VRAM_AW (%0d) must satisfy 2^(VRAM_AW-1) < VRAM_WORDS (%0d) <= 2^VRAM_AW, VRAM_AW <= 24.", VRAM_AW, VRAM_WORDS);
    end
    if ((DIM_W < 4) || (DIM_W > 16)) begin : CHECK_DIM_W
        initial $fatal(1, "blns_gpu: DIM_W (%0d) must be 4..16.", DIM_W);
    end
    if ((GPU_FIFO_AW < 3) || (GPU_FIFO_AW > 6)) begin : CHECK_GPU_FIFO_AW
        initial $fatal(1, "blns_gpu: GPU_FIFO_AW (%0d) must be 3..6.", GPU_FIFO_AW);
    end
    if ((RD_LAT < 1) || (RD_LAT > 4)) begin : CHECK_RD_LAT
        initial $fatal(1, "blns_gpu: RD_LAT (%0d) must be 1..4.", RD_LAT);
    end
endgenerate
// pragma translate_on

//=============================================================================
// 2)  REGISTER BUS
//=============================================================================
// 0x00 GPU_CMD (W), 0x04 GPU_STAT (R), 0x08 GPU_CTRL (W), 0x0C GPU_LIST (R),
// 0x10 GPU_FENCE (R), 0x14 GPU_ERR (R), 0x18 GPU_FIFO_LOW (RW), 0x1C reserved
// (RAZ/WI)
wire              rb_xfer    = rb_valid_i & rb_sel_i;
wire              rb_write   = rb_xfer & rb_wr_i;
wire              cmd_wr     = rb_write & (rb_addr_i == 3'd0);
wire              ctrl_wr    = rb_write & (rb_addr_i == 3'd2);
wire              thr_wr     = rb_write & (rb_addr_i == 3'd6);
wire              clear_err  = ctrl_wr & rb_wdata_i[0];
wire              abort      = ctrl_wr & rb_wdata_i[1];
wire              discard    = ctrl_wr & rb_wdata_i[2] & gpu_en_i;

// FIFO tag: [TAG_W-1] a DISCARD marker; with the immediate source, [0] its
// data (no marker) or, on a marker, the rectangle whose data it cut
localparam        TAG_W      = IMM_USE ? 2 : 1;

wire              fifo_full;
wire              fifo_empty;
wire [FIFO_AW:0]  fifo_count;
wire       [31:0] fifo_head;
wire  [TAG_W-1:0] fifo_head_tag;
wire              fifo_pop;
wire              dec_pop;
wire              imm_pop;                              // the pixel engine takes an immediate word
wire              push_tag;
wire              push_owed;
wire              push_part;
wire              mrk_pend;                             // a marker waits for FIFO room
// One-hot: imm_pop needs the head tagged (imm_avail), which the decoder sees
// as no word (no command, operand or marker pop), and its drop of a tagged
// head needs no immediate rectangle running (~imm_busy, which imm_avail needs)
assign            fifo_pop   = dec_pop | imm_pop;

wire              bound_err;
wire              dma_vreq;
wire              dec_err;
wire              push       = cmd_wr & gpu_en_i & ~fifo_full & ~mrk_pend;
wire              flush      = ~gpu_en_i | clear_err | abort;
wire              eng_abort  = ~gpu_en_i | abort;
wire              dma_abort  = eng_abort | bound_err;

//-----------------------------------------------------------------------------
// DISCARD: the push side resynchronises at once (blns_gpu_dec). If the pushed
// stream was partial, a marker enters the FIFO at the cut in the same edge,
// for the decoder to drop the cut command there; one that finds the FIFO full
// waits in mrk_pend and enters at the first room, before any push (pushes are
// dropped meanwhile: FREE reads 0). Not needed with a flush in the same write
// (the flush, then the push side clear, leave the decoder in step) nor in ERR
// (only a flush leaves it). A flush drops a pending marker.
//-----------------------------------------------------------------------------
wire              mrk_go     = discard & push_part & ~flush & ~dec_err;
wire              mrk_cut_q;                            // the pending marker cuts an immediate rectangle
wire              mrk_ins    = (mrk_go | (mrk_pend & ~flush)) & ~fifo_full;
wire              mrk_cut    = mrk_pend ? mrk_cut_q : push_owed;
wire              pend_nxt   = ~flush & fifo_full & (mrk_go | mrk_pend);
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_mrk_pend (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({pend_nxt, mrk_cut}), .q_o({mrk_pend, mrk_cut_q}));

wire              fifo_push  = push | mrk_ins;
wire  [TAG_W-1:0] fifo_wtag;
generate
    if (IMM_USE) begin : g_tag_imm
        assign fifo_wtag = mrk_ins ? {1'b1, mrk_cut} : {1'b0, push_tag};
    end else begin : g_tag_mrk
        assign fifo_wtag = mrk_ins;
        wire [1:0] tag_unused = {push_tag, mrk_cut};          // GPU_IMM_EN = 0: no immediate data
    end
endgenerate

//=============================================================================
// 3)  COMMAND FIFO
//=============================================================================
blns_gpu_fifo #(
    .DEPTH        (FIFO_DEPTH_USE),
    .AW           (FIFO_AW),
    .TAG_W        (TAG_W),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_fifo (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .flush_i      (flush),
    .push_i       (fifo_push),
    .wdata_i      (rb_wdata_i),                         // (a marker's word: not decoded)
    .wtag_i       (fifo_wtag),
    .pop_i        (fifo_pop),
// STATUS
    .head_o       (fifo_head),
    .head_tag_o   (fifo_head_tag),
    .empty_o      (fifo_empty),
    .full_o       (fifo_full),
    .count_o      (fifo_count)
);

//=============================================================================
// 4)  DECODER
//=============================================================================
wire              px_busy;                              // pixel engine (blns_gpu_px)
wire              setup_busy;
wire              setup_go;
wire              setup_empty;
wire              prim_busy;                            // set-up or pixel engine: a primitive in progress
wire   [PA_W-1:0] origin;
wire   [PA_W-1:0] su_dst;                               // read by the engine as its walk is loaded
wire   [PA_W-1:0] su_src;
wire              su_src_past;                          // an immediate source index past 2^PA_W (with su_src)
wire       [15:0] su_spitch;
wire  [DIM_W-1:0] su_w;
wire  [DIM_W-1:0] su_h;
wire [3*(49+2*DIM_W)-1:0] su_tri_e;
wire          [3*36-1:0] su_tri_s;                   // taken by the engine as it starts
wire       [20:0] su_u0;                                // read by the engine as its walk is loaded
wire       [20:0] su_v0;                                // read by the engine as its walk is loaded
wire       [11:0] su_gcnt;
wire       [41:0] su_gval;
wire              dma_done;
wire              dma_held;
wire              dec_stall;                            // the decoder waits (set-up, and the engine without run-ahead)
wire       [31:0] px_word;                              // the EXEC of the rectangle the engine draws
wire              exec_start;
wire        [2:0] exec_kind;
wire       [21:0] tex_cfg;
wire       [31:0] tex_uv;
wire       [31:0] tex_step;
wire       [31:0] tex_rstep;
wire       [23:0] tex_box;
wire              xy_mode;
wire       [15:0] xy_x;
wire       [15:0] xy_y;
wire       [47:0] clip;
wire       [48:0] grad;
wire        [1:0] exp_depth;
wire              exp_opaque;
wire              exp_mask;
wire        [8:0] alpha;
wire              mix5;                                 // SET_ALPHA MIX5
wire              a8;                                   // the EXEC's source is RGB565A8
wire        [1:0] tex_filt;                             // SET_AUX TEX_FILTER {TBORDER, BILINEAR}
wire              tri_fill;
wire              tri_empty;
wire       [95:0] tri_v;
wire              line;                                 // EXEC_FILL LINE
wire        [3:0] line_opt;                             // ... {PH_RST, OPAQUE, NO_LAST, AA}
wire       [31:0] line_p1;
wire              line_start;                           // ... a line starts (with exec_start)
wire       [31:0] line_pat;
wire        [4:0] line_len;
wire              line_phclr;
wire        [3:0] px_op;
wire        [2:0] dst_swap;
wire        [2:0] src_swap;
wire   [PA_W-1:0] src_base;
wire       [15:0] src_pitch;
wire   [PA_W-1:0] dst_base;
wire       [15:0] dst_pitch;
wire  [DIM_W-1:0] rect_width;
wire  [DIM_W-1:0] rect_height;
wire       [15:0] fill_color;
wire       [15:0] transp_color;
wire        [1:0] rmp_mode;
wire   [RB_W-1:0] rmp_base;
wire              mpl;
wire   [PA_W-1:0] msk_base;
wire              msk_inv;
wire   [PA_W-1:0] su_k;                                 // mask plane offset (set-up)
wire              dec_opnd_wait;
wire              refr_wait;
wire        [3:0] err_opcode;
wire        [2:0] err_cause;
wire       [31:0] err_word;
wire              dec_err_evt;
wire       [23:0] fence_tag;
wire              fence_irq;
wire              list_active;
wire       [31:0] list_head;
wire              list_empty;
wire              list_last;
wire              list_pop;
wire              imm;                                  // the decoder's EXEC: immediate source
wire              imm_go;
wire              imm_busy;                             // an immediate rectangle not done
wire              imm_eng;                              // the engine draws an immediate rectangle
wire              imm_drop;                             // a marker abandons the immediate rectangle (1 cycle)
// The FIFO head: immediate data, a marker, a marker that cuts an immediate
// rectangle
wire              head_mrk   = fifo_head_tag[TAG_W-1];
wire              head_dat;
wire              head_cut;
generate
    if (IMM_USE) begin : g_head_imm
        assign head_dat = fifo_head_tag[0] & ~fifo_head_tag[1];
        assign head_cut = fifo_head_tag[0] &  fifo_head_tag[1];
    end else begin : g_head_mrk
        assign head_dat = 1'b0;
        assign head_cut = 1'b0;
    end
endgenerate
wire              call_start;
wire [VRAM_AW-1:0] call_addr;
wire       [23:0] call_n;

blns_gpu_dec #(
    .VRAM_WORDS    (VRAM_WORDS),
    .GPU_XY_EN     (GPU_XY_EN),
    .GPU_GRAD_EN   (GPU_GRAD_EN),
    .GPU_BLEND_EN  (GPU_BLEND_EN),
    .TRI_USE       (TRI_USE),
    .GPU_REMAP_EN  (GPU_REMAP_EN),
    .GPU_MPLANE_EN (GPU_MPLANE_EN),
    .GPU_IMM_EN    (GPU_IMM_EN),
    .LINE_USE      (LINE_USE),
    .BIL_USE       (BIL_USE),
    .PA_W          (PA_W),
    .VRAM_AW       (VRAM_AW),
    .DIM_W         (DIM_W),
    .RB_W          (RB_W),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_dec (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .gpu_en_i     (gpu_en_i),
    .freeze_i     (freeze_i),
    .flush_i      (flush),
    .clear_err_i  (clear_err),
    .discard_i    (discard),
    .bound_err_i  (bound_err),
    .refr_done_i  (refr_done_i),
    .disp_width_i (disp_width_i),
// FIFO
    .head_i       (fifo_head),
    .empty_i      (fifo_empty),
    .pop_o        (dec_pop),
    .push_i       (push),
    .push_data_i  (rb_wdata_i),
    .push_tag_o   (push_tag),
    .push_owed_o  (push_owed),
    .push_part_o  (push_part),
    .head_tag_i   (head_dat),
    .head_mrk_i   (head_mrk),
    .head_cut_i   (head_cut),
    .imm_busy_i   (imm_busy),
    .imm_eng_i    (imm_eng),
// COMMAND LIST
    .list_active_i(list_active),
    .list_head_i  (list_head),
    .list_empty_i (list_empty),
    .list_last_i  (list_last),
    .list_pop_o   (list_pop),
    .call_start_o (call_start),
    .call_addr_o  (call_addr),
    .call_n_o     (call_n),
// DMA
    .stall_i      (dec_stall),
    .px_busy_i    (px_busy),
    .bound_word_i (px_word),
    .exec_start_o (exec_start),
    .exec_kind_o  (exec_kind),
    .exp_depth_o  (exp_depth),
    .exp_opaque_o (exp_opaque),
    .exp_mask_o   (exp_mask),
    .alpha_o      (alpha),
    .mix5_o       (mix5),
    .a8_o         (a8),
    .tex_filt_o   (tex_filt),
    .tri_o        (tri_fill),
    .tri_empty_o  (tri_empty),
    .tri_v_o      (tri_v),
    .line_o       (line),
    .line_start_o (line_start),
    .line_opt_o   (line_opt),
    .line_p1_o    (line_p1),
    .line_pat_o   (line_pat),
    .line_len_o   (line_len),
    .line_phclr_o (line_phclr),
    .tex_cfg_o    (tex_cfg),
    .tex_uv_o     (tex_uv),
    .tex_step_o   (tex_step),
    .tex_rstep_o  (tex_rstep),
    .tex_box_o    (tex_box),
    .xy_mode_o    (xy_mode),
    .xy_x_o       (xy_x),
    .xy_y_o       (xy_y),
    .clip_o       (clip),
    .grad_o       (grad),
    .px_op_o      (px_op),
    .dst_swap_o   (dst_swap),
    .src_swap_o   (src_swap),
    .src_base_o   (src_base),
    .src_pitch_o  (src_pitch),
    .dst_base_o   (dst_base),
    .origin_o     (origin),
    .dst_pitch_o  (dst_pitch),
    .width_o      (rect_width),
    .height_o     (rect_height),
    .fill_o       (fill_color),
    .transp_o     (transp_color),
    .rmp_mode_o   (rmp_mode),
    .rmp_base_o   (rmp_base),
    .mpl_o        (mpl),
    .msk_base_o   (msk_base),
    .msk_inv_o    (msk_inv),
    .imm_o        (imm),
    .imm_go_o     (imm_go),
    .mrk_drop_o   (imm_drop),
// STATUS / EVENTS
    .err_o        (dec_err),
    .opnd_wait_o  (dec_opnd_wait),
    .refr_wait_o  (refr_wait),
    .err_opcode_o (err_opcode),
    .err_cause_o  (err_cause),
    .err_word_o   (err_word),
    .err_evt_o    (dec_err_evt),
    .fence_o      (fence_tag),
    .fence_irq_o  (fence_irq)
);

//=============================================================================
// 5)  COMMAND LIST FETCH AND VRAM PORT SHARING
//=============================================================================
// The DMA has priority on the GPU's VRAM port; the list reads use the cycles
// it does not request (the arbiter grants in the request cycle). A list read
// carries a tag through the arbiter, which returns it with the read data.
wire              dma_vwe;
wire        [3:0] dma_vbe;
wire [VRAM_AW-1:0] dma_vaddr;
wire [VRAM_AW-1:0] dma_vwaddr;
wire       [31:0] dma_vwdata;
wire              list_vreq;
wire [VRAM_AW-1:0] list_vaddr;
wire [VRAM_AW-1:0] list_ptr;
wire               list_rd_pend;                // a list read in flight
wire              list_vgnt  = vgnt_i & ~dma_vreq;
wire              dma_vgnt   = vgnt_i &  dma_vreq;
wire              list_rvalid = vrvalid_i &  vrtag_i;
wire              dma_rvalid  = vrvalid_i & ~vrtag_i;

blns_gpu_list #(
    .VRAM_AW       (VRAM_AW),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_list (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .flush_i      (flush),
    .freeze_i     (freeze_i),
    .start_i      (call_start),
    .start_addr_i (call_addr),
    .start_n_i    (call_n),
// DECODER
    .pop_i        (list_pop),
    .active_o     (list_active),
    .head_o       (list_head),
    .empty_o      (list_empty),
    .last_o       (list_last),
    .ptr_o        (list_ptr),
    .rd_pend_o    (list_rd_pend),
// VRAM PORT
    .vreq_o       (list_vreq),
    .vaddr_o      (list_vaddr),
    .vgnt_i       (list_vgnt),
    .vrvalid_i    (list_rvalid),
    .vrdata_i     (vrdata_i)
);

// Bounds: the pixel engine does not make an access at or past VRAM_WORDS; it
// abandons the rectangle and the decoder stops (ERR_CAUSE 5). A list is
// checked whole at its CALL by the decoder.
wire [VRAM_AW-1:0] port_vaddr = dma_vreq ? dma_vaddr : list_vaddr;

assign vreq_o   = dma_vreq | list_vreq;
assign vwe_o    = dma_vreq & dma_vwe;
assign vbe_o    = dma_vbe;
assign vaddr_o  = port_vaddr;
assign vwaddr_o = dma_vwaddr;                           // only the DMA writes
assign vwdata_o = dma_vwdata;
assign vtag_o   = ~dma_vreq;

//=============================================================================
// 6)  SET-UP AND RECTANGLE ENGINE
//=============================================================================
assign prim_busy = setup_busy | px_busy;

// A flush drops what the engine has not started: with run-ahead, the
// primitive in the set-up stage too. A marker abandoning the immediate
// rectangle drops it where it is: in the set-up (the only primitive after its
// EXEC is its data), or in the engine (imm_eng; not the engine's own other
// primitive, with run-ahead)
wire              setup_abort = dma_abort | ((GPU_RUNAHEAD_EN != 0) & flush) | imm_drop;
wire              px_abort    = eng_abort | (imm_drop & imm_eng);

// The per-channel gradient applies at 16 bpp only (below, SET_GRAD as plain),
// with GFX_MODE as the EXEC started, for the whole primitive
wire              grad_16_q;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_grad_16 (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(exec_start),
                     .d_i(gfx_mode_i[2]), .q_o(grad_16_q));
wire       [48:0] grad_m = {grad[48] & grad_16_q, grad[47:0]};

// Lines: the pattern phase is stream state, 0 after a flush and a bound
// error too; an AA line is drawn as such at 16 bpp (GFX_MODE at its start)
wire              ph_clr = line_phclr | flush | bound_err;
wire              su_ln_aa;
wire              su_ln_xm;
wire              su_ln_sm;
wire              su_ln_sn;
wire       [28:0] su_ln_g;
wire       [28:0] su_ln_e0;                             // read by the engine as its walk is loaded
wire       [12:0] su_ln_p0;
wire       [12:0] su_ln_q0;
wire       [12:0] su_ln_nm1;
wire        [4:0] su_ln_ph;

blns_gpu_setup #(
    .GPU_XY_EN     (GPU_XY_EN),
    .GPU_GRAD_EN   (GPU_GRAD_EN),
    .TRI_USE       (TRI_USE),
    .GPU_MPLANE_EN (GPU_MPLANE_EN),
    .GPU_BLEND_EN  (GPU_BLEND_EN),
    .LINE_USE      (LINE_USE),
    .GPU_RUNAHEAD_EN (GPU_RUNAHEAD_EN),
    .PA_W          (PA_W),
    .DIM_W         (DIM_W),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_setup (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .abort_i      (setup_abort),
    .start_i      (exec_start),
    .eng_idle_i   (~px_busy),
    .freeze_i     (freeze_i),
    .go_o         (setup_go),
    .empty_done_o (setup_empty),
    .busy_o       (setup_busy),
// PRIMITIVE
    .kind_i       (exec_kind),
    .tri_i        (tri_fill),
    .tri_empty_i  (tri_empty),
    .tri_v_i      (tri_v),
    .xy_mode_i    (xy_mode),
    .xy_x_i       (xy_x),
    .xy_y_i       (xy_y),
    .clip_i       (clip),
    .origin_i     (origin),
    .dst_base_i   (dst_base),
    .dst_pitch_i  (dst_pitch),
    .src_base_i   (src_base),
    .imm_i        (imm),
    .msk_base_i   (msk_base),
    .src_pitch_i  (src_pitch),
    .disp_width_i (disp_width_i),
    .width_i      (rect_width),
    .height_i     (rect_height),
    .dst_swap_i   (dst_swap),
    .src_swap_i   (src_swap),
    .tex_uv_i     (tex_uv),
    .tex_step_i   (tex_step),
    .tex_rstep_i  (tex_rstep),
    .grad_i       (grad_m),
    .line_i       (line),
    .line_start_i (line_start),
    .line_opt_i   (line_opt),
    .line_16_i    (grad_16_q),
    .line_p1_i    (line_p1),
    .line_len_i   (line_len),
    .ph_clr_i     (ph_clr),
// TO THE RECTANGLE ENGINE
    .dst_base_o   (su_dst),
    .src_base_o   (su_src),
    .src_past_o   (su_src_past),
    .msk_k_o      (su_k),
    .src_pitch_o  (su_spitch),
    .width_o      (su_w),
    .height_o     (su_h),
    .tex_u0_o     (su_u0),
    .tex_v0_o     (su_v0),
    .grad_cnt0_o  (su_gcnt),
    .grad_val0_o  (su_gval),
    .tri_edges_o  (su_tri_e),
    .tri_starts_o (su_tri_s),
    .ln_aa_o      (su_ln_aa),
    .ln_xmaj_o    (su_ln_xm),
    .ln_smaj_o    (su_ln_sm),
    .ln_smin_o    (su_ln_sn),
    .ln_g_o       (su_ln_g),
    .ln_e0_o      (su_ln_e0),
    .ln_p0_o      (su_ln_p0),
    .ln_q0_o      (su_ln_q0),
    .ln_nm1_o     (su_ln_nm1),
    .ln_ph_o      (su_ln_ph)
);

//-----------------------------------------------------------------------------
// Run-ahead: the engine takes a copy of the primitive when it starts, so the
// decoder and the set-up go on with the next one while it draws (a FENCE waits
// for the engine). Without it the decoder waits for the engine.
// The copy holds what the engine reads after its first cycle. The destination
// and source starts and the texture start (u, v) are read only as the walk is
// loaded, the cycle after the start, straight from the set-up: its registers
// change at the earliest a cycle later, when it latches the next primitive (as
// the triangle's first-row bounds, taken at the start). With the copy, the
// engine takes the texture base from its source walker (blns_gpu_px_a).
// The texture fields (TEXSPAN, TEXRECT) and the gradient fields (FILL) share
// one slot of the copy: no primitive reads both. The other group's engine
// registers may then load other values; nothing reads them for that kind.
// COPY, COPY_TRANSP and EXPAND read neither group: with the mask plane, the
// copies keep theirs there (MPLANE, INV, K). The remap mode and table base
// are used by every kind but SPAN: fields of their own.
// SET_TEX swaps (read by the decoder) are not kept, the texture box is kept
// clamped as the engine takes it (blns_gpu_px_a). A line (a FILL, no
// gradient) keeps its pattern, OPAQUE, geometry and clip window in the
// gradient's slot; its start values are read as the walk is loaded.
//-----------------------------------------------------------------------------
localparam        RUNAHEAD_USE = (GPU_RUNAHEAD_EN != 0);
localparam        MPLANE_USE   = (GPU_MPLANE_EN != 0);
localparam        REMAP_USE    = (GPU_REMAP_EN != 0);
localparam        SLOT_W       = LINE_USE ? 119 : 103;  // max(texture 19 + 32 + 32 + 20, gradient 49 + 12 + 42, mask PA_W + 2, line 37 + 5 + 29 + 48)
localparam        RMP_W        = REMAP_USE ? (2 + RB_W) : 1;
localparam        DESC_W       = 239 + SLOT_W + 8*DIM_W + RMP_W;

wire [2:0]        e_kind;
wire [1:0]        e_exp_depth;
wire              e_exp_opaque;
wire              e_exp_mask;
wire [8:0]        e_alpha;
wire              e_tri;
wire [3*(49+2*DIM_W)-1:0] e_tri_e;
wire [21:0]       e_tex_cfg;
wire [31:0]       e_tex_step;
wire [31:0]       e_tex_rstep;
wire [23:0]       e_tex_box;

// SET_TEXBOX TW / TH (clamped to 512 by the decoder), for the run-ahead slot
// and the pixel engine
wire        [9:0] tex_tw_c  = tex_box[9:0];
wire        [9:0] tex_th_c  = tex_box[21:12];
wire        [3:0] tex_box_unused = {tex_box[23:22], tex_box[11:10]};   // 0: at most 512
wire [48:0]       e_grad;
wire [11:0]       e_grad_cnt0;
wire [41:0]       e_grad_val0;
wire [3:0]        e_px_op;
wire [2:0]        e_dst_swap;
wire [2:0]        e_src_swap;
wire [PA_W-1:0]   e_src_base;
wire [15:0]       e_src_pitch;
wire [15:0]       e_dst_pitch;
wire [DIM_W-1:0]  e_width;
wire [DIM_W-1:0]  e_height;
wire [15:0]       e_fill;
wire [15:0]       e_transp;
wire [1:0]        e_rmp_mode;
wire [RB_W-1:0]   e_rmp_base;
wire              e_mpl;
wire              e_msk_inv;
wire [PA_W-1:0]   e_msk_k;
wire              e_ln;
wire              e_ln_aa;
wire              e_ln_opq;
wire              e_ln_xm;
wire              e_ln_sm;
wire              e_ln_sn;
wire [28:0]       e_ln_g;
wire [47:0]       e_ln_clip;
wire [31:0]       e_ln_pat;
wire [4:0]        e_ln_len;

generate
    if (RUNAHEAD_USE) begin : g_runahead
        // The slot: {SHADE, BOUND, FREE_PITCH, TRANSP_EN, log2 h, log2 w, step,
        // row step, TH, TW} for a texture, else {gradient, its phase}
        wire      [102:0] slot_tx   = {tex_cfg[21:12], tex_cfg[8:0], tex_step, tex_rstep, tex_th_c, tex_tw_c};
        wire [SLOT_W-1:0] slot_tex;
        wire [SLOT_W-1:0] slot_fill;
        if (LINE_USE) begin : g_slot_line
            assign slot_tex = {16'h0000, slot_tx};
            // ... {pattern, LEN, OPAQUE, AA, axes and signs, steps, clip} for a line
            wire [SLOT_W-1:0] slot_line = {line_pat, line_len, line_opt[2], su_ln_aa, su_ln_xm, su_ln_sm, su_ln_sn,
                                           su_ln_g, clip};
            assign slot_fill = line ? slot_line : {16'h0000, grad_m, su_gcnt, su_gval};
        end else begin : g_slot_noline
            assign slot_tex  = slot_tx;
            assign slot_fill = {grad_m, su_gcnt, su_gval};
        end
        wire [SLOT_W-1:0] slot_live;
        if (MPLANE_USE) begin : g_slot_msk
            // ... {MPLANE, INV, K} for a copy
            wire [SLOT_W-1:0] slot_msk = {{(SLOT_W-PA_W-2){1'b0}}, mpl, msk_inv, su_k};
            wire              cpk_live = ~exec_kind[2] & (exec_kind[1] ^ exec_kind[0]);
            assign slot_live = exec_kind[2] ? slot_tex : cpk_live ? slot_msk : slot_fill;
        end else begin : g_slot_nomsk
            assign slot_live = exec_kind[2] ? slot_tex : slot_fill;
        end
        wire  [RMP_W-1:0] rmp_live;
        if (REMAP_USE) begin : g_rmp_live
            assign rmp_live = {rmp_mode, rmp_base};
        end else begin : g_rmp_nolive
            assign rmp_live = 1'b0;
        end
        wire [DESC_W-1:0] desc_live = {exec_kind,
                                       exp_depth,
                                       exp_opaque,
                                       exp_mask,
                                       alpha,
                                       tri_fill,
                                       line,
                                       su_tri_e,
                                       slot_live,
                                       px_op,
                                       dst_swap,
                                       src_swap,
                                       su_spitch,
                                       dst_pitch,
                                       su_w,
                                       su_h,
                                       fill_color,
                                       transp_color,
                                       rmp_live};
        wire [DESC_W-1:0] desc;
        wire [SLOT_W-1:0] e_slot;
        wire  [RMP_W-1:0] e_rmp;

        arv_ipdff #(.WIDTH(DESC_W), .ARST_EN(ASYNC_RST_EN)) u_desc (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(setup_go), .d_i(desc_live), .q_o(desc));
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_px_word (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(setup_go), .d_i(err_word), .q_o(px_word));
        assign dec_stall = setup_busy;

        assign {e_kind,
                e_exp_depth,
                e_exp_opaque,
                e_exp_mask,
                e_alpha,
                e_tri,
                e_ln,
                e_tri_e,
                e_slot,
                e_px_op,
                e_dst_swap,
                e_src_swap,
                e_src_pitch,
                e_dst_pitch,
                e_width,
                e_height,
                e_fill,
                e_transp,
                e_rmp} = desc;
        assign e_tex_cfg   = {e_slot[102:93], 3'b000, e_slot[92:84]};
        assign e_tex_step  = e_slot[83:52];
        assign e_tex_rstep = e_slot[51:20];
        assign e_tex_box   = {2'b00, e_slot[19:10], 2'b00, e_slot[9:0]};
        assign {e_grad, e_grad_cnt0, e_grad_val0} = e_slot[102:0];
        if (LINE_USE) begin : g_line_e
            assign {e_ln_pat, e_ln_len, e_ln_opq, e_ln_aa, e_ln_xm, e_ln_sm, e_ln_sn, e_ln_g, e_ln_clip} = e_slot;
        end else begin : g_line_noe
            assign {e_ln_pat, e_ln_len, e_ln_opq, e_ln_aa, e_ln_xm, e_ln_sm, e_ln_sn, e_ln_g, e_ln_clip} = 119'd0;
            wire [119:0] line_unused = {line_pat, line_len, line_opt[2], su_ln_aa, su_ln_xm, su_ln_sm, su_ln_sn, su_ln_g, clip, e_ln};   // GPU_LINE_EN = 0
        end
        assign e_src_base  = su_src;
        // (the mask fields read for a copy only: blns_gpu_px_a)
        assign {e_mpl, e_msk_inv, e_msk_k} = e_slot[PA_W+1:0];
        if (REMAP_USE) begin : g_rmp_e
            assign {e_rmp_mode, e_rmp_base} = e_rmp;
        end else begin : g_rmp_noe
            assign e_rmp_mode = 2'd0;
            assign e_rmp_base = {RB_W{1'b0}};
            wire [RMP_W+RB_W+1:0] rmp_unused = {e_rmp, rmp_mode, rmp_base};   // GPU_REMAP_EN = 0
        end
        if (!MPLANE_USE) begin : g_msk_noe
            wire [PA_W+1:0] msk_unused = {mpl, msk_inv, su_k};      // GPU_MPLANE_EN = 0
        end
        wire        [2:0] tex_swap_unused = tex_cfg[11:9];       // used by the decoder
    end else begin : g_no_runahead
        assign px_word  = err_word;
        assign dec_stall = prim_busy;

        assign e_kind       = exec_kind;
        assign e_exp_depth  = exp_depth;
        assign e_exp_opaque = exp_opaque;
        assign e_exp_mask   = exp_mask;
        assign e_alpha      = alpha;
        assign e_tri        = tri_fill;
        assign e_tri_e      = su_tri_e;
        assign e_tex_cfg    = tex_cfg;
        assign e_tex_step   = tex_step;
        assign e_tex_rstep  = tex_rstep;
        assign e_tex_box    = {2'b00, tex_th_c, 2'b00, tex_tw_c};
        assign e_grad       = grad_m;
        assign e_grad_cnt0  = su_gcnt;
        assign e_grad_val0  = su_gval;
        assign e_px_op      = px_op;
        assign e_dst_swap   = dst_swap;
        assign e_src_swap   = src_swap;
        assign e_src_base   = su_src;
        assign e_src_pitch  = su_spitch;
        assign e_dst_pitch  = dst_pitch;
        assign e_width      = su_w;
        assign e_height     = su_h;
        assign e_fill       = fill_color;
        assign e_transp     = transp_color;
        assign e_rmp_mode   = rmp_mode;
        assign e_rmp_base   = rmp_base;
        assign e_mpl        = mpl;
        assign e_msk_inv    = msk_inv;
        assign e_msk_k      = su_k;
        assign e_ln         = line;
        assign e_ln_aa      = su_ln_aa;
        assign e_ln_opq     = line_opt[2];
        assign e_ln_xm      = su_ln_xm;
        assign e_ln_sm      = su_ln_sm;
        assign e_ln_sn      = su_ln_sn;
        assign e_ln_g       = su_ln_g;
        assign e_ln_clip    = clip;
        assign e_ln_pat     = line_pat;
        assign e_ln_len     = line_len;
    end
endgenerate

// RGB565A8, the blend rule and the texture filter of the primitive the engine
// draws: with run-ahead copied at the set-up's go as the rest; the K of an
// RGB565A8 source (ALPHA_PLANE - source base) has a field of its own (a
// texture's slot is full), and replaces the mask plane's K for the engine
wire              e_a8;
wire              e_mix5;
wire   [PA_W-1:0] e_ak;
wire        [1:0] e_tfilt;
generate
    if (RUNAHEAD_USE && BLEND_USE) begin : g_ra_a8
        arv_ipdff #(.WIDTH(PA_W + 2), .ARST_EN(ASYNC_RST_EN)) u_desc_a8 (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(setup_go), .d_i({a8, mix5, su_k}), .q_o({e_a8, e_mix5, e_ak}));
    end else begin : g_e_a8
        assign {e_a8, e_mix5, e_ak} = {a8, mix5, su_k};
    end
    if (RUNAHEAD_USE && BIL_USE) begin : g_ra_bil
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_desc_bil (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(setup_go), .d_i(tex_filt), .q_o(e_tfilt));
    end else begin : g_e_bil
        assign e_tfilt = tex_filt;
    end
endgenerate
wire   [PA_W-1:0] px_k = e_a8 ? e_ak : e_msk_k;

// The immediate flag of the rectangle the engine draws (run-ahead: copied at
// the set-up's go with the rest); an immediate rectangle is not done from its
// EXEC to its completion by the engine or the set-up (trimmed away), or a
// flush: until then the decoder neither drops the data words at the FIFO
// head nor takes another immediate EXEC
wire              e_imm;
generate
    if (IMM_USE && RUNAHEAD_USE) begin : g_e_imm_ra
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_e_imm (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(setup_go), .d_i(imm), .q_o(e_imm));
    end else begin : g_e_imm
        assign e_imm = imm;
    end
    if (IMM_USE) begin : g_imm_busy
        wire imm_busy_nxt = imm_go | (imm_busy & ~flush & ~imm_drop & ~(dma_done & e_imm) & ~(setup_empty & imm));
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_imm_busy (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(imm_busy_nxt), .q_o(imm_busy));
    end else begin : g_no_imm_busy
        assign imm_busy = 1'b0;
        wire [1:0] imm_unused = {imm_go, push_owed};
    end
endgenerate
// The engine takes data words only while its immediate rectangle is not done
// for the decoder (after CLEAR_ERR without ABORT the rectangle completes with
// 0 for the rest, the decoder dropping the words still pushed). No data word
// left for it: that, the head a command (or a marker after its last data
// word), or the FIFO empty and nothing owed. A marker that cuts it is not
// short: the decoder abandons it there (a pending marker: the FIFO is full)
wire              imm_avail = head_dat & imm_busy;
wire              imm_short = ~imm_busy | (~fifo_empty & ~fifo_head_tag[0]) | (fifo_empty & ~push_owed);
// An immediate rectangle still drawn (flushed by CLEAR_ERR alone): the next
// immediate EXEC waits for it
assign            imm_eng   = e_imm & px_busy;

blns_gpu_px #(
    .GPU_XY_EN     (GPU_XY_EN),
    .GPU_GRAD_EN   (GPU_GRAD_EN),
    .GPU_BLEND_EN  (GPU_BLEND_EN),
    .TRI_USE       (TRI_USE),
    .GPU_REMAP_EN  (GPU_REMAP_EN),
    .GPU_MPLANE_EN (GPU_MPLANE_EN),
    .GPU_IMM_EN    (GPU_IMM_EN),
    .LINE_USE      (LINE_USE),
    .BIL_USE       (BIL_USE),
    .RUNAHEAD_EN   (GPU_RUNAHEAD_EN),
    .RD_REG_EN     ((RD_LAT > 1) ? 1 : 0),
    .RD_LAT        (RD_LAT),
    .VRAM_WORDS    (VRAM_WORDS),
    .VRAM_AW       (VRAM_AW),
    .PA_W          (PA_W),
    .DIM_W         (DIM_W),
    .RB_W          (RB_W),
    .ASYNC_RST_EN  (ASYNC_RST_EN)
) u_px (
// CLOCK & RESET
    .hclk_i       (hclk_i),
    .hresetn_i    (hresetn_i),
// CONTROL
    .abort_i      (px_abort),
    .freeze_i     (freeze_i),
    .start_i      (setup_go),
    .gfx_mode_i   (gfx_mode_i),
    .disp_width_i (disp_width_i),
// RECTANGLE CONFIGURATION
    .kind_i       (e_kind),
    .imm_i        (e_imm),
    .imm_word_i   (fifo_head),
    .imm_avail_i  (imm_avail),
    .imm_short_i  (imm_short),
    .imm_pop_o    (imm_pop),
    .exp_depth_i  (e_exp_depth),
    .exp_opaque_i (e_exp_opaque),
    .exp_mask_i   (e_exp_mask),
    .alpha_i      (e_alpha),
    .mix5_i       (e_mix5),
    .a8_i         (e_a8),
    .tex_filt_i   (e_tfilt),
    .tri_i        (e_tri),
    .tri_e_i      (e_tri_e),
    .tri_s_i      (su_tri_s),
    .tex_cfg_i    (e_tex_cfg),
    .tex_u0_i     (su_u0),
    .tex_v0_i     (su_v0),
    .tex_step_i   (e_tex_step),
    .tex_rstep_i  (e_tex_rstep),
    .tex_box_i    (e_tex_box),
    .grad_i       (e_grad),
    .grad_cnt0_i  (e_grad_cnt0),
    .grad_val0_i  (e_grad_val0),
    .px_op_i      (e_px_op),
    .dst_swap_i   (e_dst_swap),
    .src_swap_i   (e_src_swap),
    .src_base_i   (e_src_base),
    .src_past_i   (su_src_past),                         // read with the source base, at the walk load
    .src_pitch_i  (e_src_pitch),
    .dst_base_i   (su_dst),
    .dst_pitch_i  (e_dst_pitch),
    .width_i      (e_width),
    .height_i     (e_height),
    .fill_i       (e_fill),
    .transp_i     (e_transp),
    .rmp_mode_i   (e_rmp_mode),
    .rmp_base_i   (e_rmp_base),
    .mpl_i        (e_mpl),
    .msk_inv_i    (e_msk_inv),
    .msk_k_i      (px_k),
    .ln_i         (e_ln),
    .ln_aa_i      (e_ln_aa),
    .ln_opq_i     (e_ln_opq),
    .ln_xmaj_i    (e_ln_xm),
    .ln_smaj_i    (e_ln_sm),
    .ln_smin_i    (e_ln_sn),
    .ln_g_i       (e_ln_g),
    .ln_clip_i    (e_ln_clip),
    .ln_pat_i     (e_ln_pat),
    .ln_len_i     (e_ln_len),
    .ln_e0_i      (su_ln_e0),
    .ln_p0_i      (su_ln_p0),
    .ln_q0_i      (su_ln_q0),
    .ln_nm1_i     (su_ln_nm1),
    .ln_ph_i      (su_ln_ph),
// VRAM REQUESTER
    .vreq_o       (dma_vreq),
    .vwe_o        (dma_vwe),
    .vbe_o        (dma_vbe),
    .vaddr_o      (dma_vaddr),
    .vwaddr_o     (dma_vwaddr),
    .vwdata_o     (dma_vwdata),
    .vgnt_i       (dma_vgnt),
    .vrvalid_i    (dma_rvalid),
    .vrdata_i     (vrdata_i),
// STATUS
    .busy_o       (px_busy),
    .done_o       (dma_done),
    .held_o       (dma_held),
    .bound_o      (bound_err)
);

//=============================================================================
// 7)  STATUS, EVENTS AND READ DATA
//=============================================================================
// BUSY = FIFO not empty (a marker too: a pending one with the FIFO full), a
// list active, DMA busy, or decoder waiting for an operand word; the DMA start
// cycle is covered by the EXEC word still being in the FIFO or the list.
wire              busy       = ~fifo_empty | list_active | prim_busy | dec_opnd_wait;
wire              busy_q;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_busy_q (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(busy), .q_o(busy_q));

// GPU_IDLE needs a word pushed since the last one: a DISCARD marker drained
// on an otherwise idle GPU raises BUSY and lowers it again, silently
wire              idle_arm;
wire              idle_evt   = busy_q & ~busy & idle_arm;
wire              idle_arm_nxt = push | (idle_arm & ~idle_evt);
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_idle_arm (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(idle_arm_nxt), .q_o(idle_arm));

localparam     [31:0] FIFO_DEPTH_32  = FIFO_DEPTH_USE;
localparam [FIFO_AW:0] FIFO_DEPTH_CNT = FIFO_DEPTH_32[FIFO_AW:0];

// A pending marker holds the room it waits for: FREE 0, FULL
wire  [FIFO_AW:0] fifo_free  = {(FIFO_AW+1){~mrk_pend}} & (FIFO_DEPTH_CNT - fifo_count);
wire              stat_full  = fifo_full | mrk_pend;
wire        [7:0] stat_free  = {{(7-FIFO_AW){1'b0}}, fifo_free};
wire        [7:0] stat_used  = {{(7-FIFO_AW){1'b0}}, fifo_count};

wire       [31:0] gpu_stat   = {err_opcode,                     // [31:28] ERR_OPCODE
                                err_cause,                      // [27:25] ERR_CAUSE
                                list_active,                    // [24] LIST
                                dma_held,                       // [23] HELD
                                dec_err,                        // [22] ERR
                                busy,                           // [21] BUSY
                                prim_busy,                      // [20] PRIM_BUSY (set-up or pixel engine)
                                1'b0,                           // [19]
                                refr_wait,                      // [18] WAIT (WAIT_REFR_DONE)
                                stat_full,                      // [17] FULL
                                fifo_empty,                     // [16] EMPTY
                                stat_used,                      // [15:8] USED
                                stat_free};                     // [7:0] FREE

wire       [31:0] gpu_list   = {{(32-VRAM_AW){1'b0}}, list_ptr};


// GPU_FIFO_LOW [16:0] THRESH: the event when FREE rises above it (from <= to
// >). Reset: half the depth. A value of the depth or more never fires: it is
// kept (and read back) as the depth. Kept through every flush, GPU_EN = 0 and
// RESET_STATE. A write re-arms: fifo_above to 0, so the event fires the next
// cycle if FREE is already above (a CPU write's next edge: the clock request
// covers it)
localparam [FIFO_AW:0] FIFO_HALF = FIFO_DEPTH_CNT >> 1;
wire              thr_sat    = |rb_wdata_i[16:FIFO_AW];
wire  [FIFO_AW:0] thr_nxt    = thr_sat ? FIFO_DEPTH_CNT : {1'b0, rb_wdata_i[FIFO_AW-1:0]};
wire  [FIFO_AW:0] fifo_thr;
arv_ipdff #(.WIDTH(FIFO_AW+1), .RST_VAL(FIFO_HALF), .ARST_EN(ASYNC_RST_EN)) u_fifo_thr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(thr_wr), .d_i(thr_nxt), .q_o(fifo_thr));

wire              fifo_above;
wire              above_now  = (fifo_free > fifo_thr);
arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_fifo_above (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(above_now & ~thr_wr), .q_o(fifo_above));
assign fifo_low_evt_o = above_now & ~fifo_above;

wire       [31:0] gpu_thr    = {{(31-FIFO_AW){1'b0}}, fifo_thr};

assign rb_rdata_o  = ({32{~rb_wr_i & (rb_addr_i == 3'd1)}} & gpu_stat)            |
                     ({32{~rb_wr_i & (rb_addr_i == 3'd3)}} & gpu_list)            |
                     ({32{~rb_wr_i & (rb_addr_i == 3'd4)}} & {8'h00, fence_tag})  |
                     ({32{~rb_wr_i & (rb_addr_i == 3'd5)}} & err_word)            |
                     ({32{~rb_wr_i & (rb_addr_i == 3'd6)}} & gpu_thr);
assign rb_ready_o  = rb_xfer;

// (and the clock request: a list read cut by a flush is still in flight for
// VRAM_RD_LAT cycles, its data dropped when it arrives)
assign busy_o      = busy | list_rd_pend;
assign err_o       = dec_err;
assign done_evt_o  = dma_done | setup_empty;
assign fence_evt_o = fence_irq;
assign idle_evt_o  = idle_evt;
assign ovfl_evt_o  = cmd_wr & (stat_full | ~gpu_en_i);
assign err_evt_o   = dec_err_evt;

endmodule // blns_gpu

`default_nettype wire
