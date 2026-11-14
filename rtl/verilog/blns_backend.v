//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_backend
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_backend.v
// Module Description : Display backend: frame fetch, pixel unpacking, colour lookup
//                      (hardware palettes / programmable LUT), hardware cursor
//                      overlay and the BDI pixel stream.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_backend #(
    parameter                   VRAM_AW      = 16,    // VRAM word-address width
    parameter                   DIM_W        = 10,    // width/height field width
    parameter                   LUT_EN       = 1,     // programmable LUT present
    parameter                   LUT_BANKS    = 2,     // LUT banks (1/2)
    parameter                   CURSOR_EN    = 1,     // hardware cursor present
    parameter                   RD_LAT       = 1,     // VRAM read data RD_LAT cycles after the grant (1-4)
    parameter                   FRAME_W_EN   = 0,     // frame_width_i is the source width of disp_width_i
    parameter                   ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire                 hclk_i,               // clock
    input  wire                 hresetn_i,            // active-low reset (style per ASYNC_RST_EN)
    input  wire           [2:0] gfx_mode_i,           // CTRL.GFX_MODE
    input  wire     [DIM_W-1:0] disp_width_i,         // display width
    input  wire     [DIM_W-1:0] disp_height_i,        // display height
    input  wire           [2:0] disp_cfg_i,           // DISP_CFG {X,Y,CL} swaps
    input  wire                 pix_double_i,         // DISP_CFG.PIX_DOUBLE
    input  wire     [DIM_W-1:0] frame_width_i,        // with FRAME_W_EN: pix_double_i ? ceil(W/2) : W of disp_width_i
    input  wire   [VRAM_AW+4:0] frame_base_i,         // refresh frame pointer (pixel address)
    input  wire          [15:0] pitch_i,              // REFR_PITCH: line pitch in source pixels, 0 = source width
    input  wire                 sw_lut_en_i,          // LUT_CFG.SW_LUT_EN
    input  wire                 refr_bank_i,          // LUT_CFG.REFR_BANK
    input  wire           [2:0] hw_palette_i,         // LUT_CFG.HW_PALETTE
    input  wire           [3:0] hw_bg_i,              // LUT_CFG.HW_BG
    input  wire           [3:0] hw_fg_i,              // LUT_CFG.HW_FG
    input  wire          [23:0] lut_rot_i,            // LUT_ROT {OFFSET, LAST, FIRST}
    input  wire                 cur_en_i,             // CURSOR_CTRL.EN
    input  wire           [9:0] cur_hot_i,            // CURSOR_CTRL {HOT_Y, HOT_X}
    input  wire          [31:0] cur_pos_i,            // CURSOR_POS {Y, X}
    input  wire   [VRAM_AW-1:0] cur_addr_i,           // CURSOR_ADDR
    input  wire          [23:0] cur_col1_i,           // CURSOR_COL1 (live)
    input  wire          [23:0] cur_col2_i,           // CURSOR_COL2 (live)
    input  wire          [23:0] cur_col3_i,           // CURSOR_COL3 (live)
    output wire                 vreq_o,               // VRAM read request
    output wire                 vurgent_o,            // pixel FIFO low: urgent priority
    output wire   [VRAM_AW-1:0] vaddr_o,              // word address
    output wire                 vtag_o,               // read tag: a cursor read
    input  wire                 vgnt_i,               // grant
    input  wire                 vrvalid_i,            // read data valid
    input  wire                 vrtag_i,              // the returning read's tag
    input  wire          [31:0] vrdata_i,             // read data
    output wire                 lreq_o,               // LUT read request
    output wire                 lreq_nxt_o,           // next cycle's lreq_o
    output wire           [8:0] laddr_o,              // LUT address {bank, index}
    input  wire                 lgnt_i,               // LUT grant
    input  wire                 lrvalid_i,            // LUT read data valid
    input  wire          [23:0] lrdata_i,             // LUT read data (RGB888)
    output wire                 px_valid_o,           // BDI pixel available
    output wire          [23:0] px_data_o,            // BDI pixel (RGB888)
    output wire                 px_last_o,            // final pixel of the frame
    input  wire                 px_ready_i,           // driver takes the pixel
    input  wire                 refresh_active_i,     // driver is sending a frame
    output wire                 active_dly_o,         // refresh_active_i one cycle late (a flop)
    output wire     [DIM_W-1:0] line_len_m1_o         // scan-line length - 1 of the latched frame (from flops)
);

localparam PA_W     = VRAM_AW + 5;
// Pixel credit: pixels issued to the fetch and not yet taken by the driver, the
// raw FIFO's depth. A pixel takes RD_LAT + 3 cycles from its issue to the
// driver in the LUT build (RD_LAT + 1 without), and its credit returns to the
// issue one cycle after the driver takes it: the stream runs at one pixel per
// cycle with PX_DEPTH >= RD_LAT + 4 (RD_LAT + 2 without the LUT).
localparam [31:0] PX_DEPTH = RD_LAT + 4;
localparam OQ_DEPTH = 3;               // RGB888 output queue (LUT_EN build)
localparam CRED_W   = $clog2(PX_DEPTH + 1);
localparam RAW_PW   = $clog2(PX_DEPTH);
localparam OQ_PW    = $clog2(OQ_DEPTH);
localparam OQ_CW    = $clog2(OQ_DEPTH + 1);
// The fetch turns urgent (the window and the GPU yield) with at most this
// many pixels in flight: the stream is then a read latency or less from a
// bubble, while above it the window and the GPU keep their priority.
localparam URG_CREDIT = 2;
localparam [CRED_W-1:0] PX_DEPTH_C   = PX_DEPTH[CRED_W-1:0];
localparam [CRED_W-1:0] URG_CREDIT_C = URG_CREDIT;
localparam [OQ_CW:0]    OQ_DEPTH_C   = OQ_DEPTH;
localparam LUT_EN_USE  = (LUT_EN != 0);
localparam LUT_BANK_EN = LUT_EN_USE & (LUT_BANKS == 2);
localparam CUR_USE     = (CURSOR_EN != 0);
localparam RAW_DW      = CUR_USE ? 19 : 17;   // raw FIFO entry {last, [cursor code,] value}

// pragma translate_off
generate
    if ((RD_LAT < 1) || (RD_LAT > 4)) begin : CHECK_RD_LAT
        initial $fatal(1, "blns_backend: RD_LAT (%0d) must be 1..4.", RD_LAT);
    end
    if (PX_DEPTH < RD_LAT + (LUT_EN_USE ? 4 : 2)) begin : CHECK_PX_DEPTH
        initial $fatal(1, "blns_backend: PX_DEPTH (%0d) must cover the issue-to-driver latency and the credit return.", PX_DEPTH);
    end
endgenerate
// pragma translate_on

//=============================================================================
// 1) FRAME CONFIGURATION LATCH
//=============================================================================
// Loaded every cycle while refresh_active_i = 0, frozen from its rising edge until
// it falls. The walker reloads from the latched copy while not running, so the
// values that start a frame are those of the last inactive cycle.

// The size is never 0: DISP_SIZE stores a 0 field as 1 and resets to 1x1
// (blns_regs), and the DBI size hold (belenos_core) is a copy of it.
// Source frame of a doubled picture: ceil(W/2) x ceil(H/2)
// With FRAME_W_EN (no DBI size hold: disp_width_i is DISP_SIZE itself) the
// source width is blns_regs' FRAME_WIDTH, the same function of the same
// registers: one incrementer for it and the GPU's default pitch
wire   [DIM_W:0] width_p1     = {1'b0, disp_width_i}  + {{DIM_W{1'b0}}, 1'b1};
wire   [DIM_W:0] height_p1    = {1'b0, disp_height_i} + {{DIM_W{1'b0}}, 1'b1};
wire [DIM_W-1:0] src_width_in  = (FRAME_W_EN != 0) ? frame_width_i :
                                 pix_double_i ? width_p1[DIM_W:1]  : disp_width_i;
wire [DIM_W-1:0] src_height_in = pix_double_i ? height_p1[DIM_W:1] : disp_height_i;

wire       [4:0] bpp_1hot_in  = {gfx_mode_i[2],
                                 (gfx_mode_i == 3'd3),
                                 (gfx_mode_i == 3'd2),
                                 (gfx_mode_i == 3'd1),
                                 (gfx_mode_i == 3'd0)};

localparam CFG_W = PA_W + 4*DIM_W + 16 + 1 + 3 + 5 + 3 + 4 + 4;

// Line pitch: REFR_PITCH, or the source frame width (zero-extended through a
// 32-bit word: no zero-width replication at DIM_W = 16)
wire      [31:0] src_width_32 = {{(32-DIM_W){1'b0}}, src_width_in};
wire      [15:0] pitch_in = (pitch_i != 16'h0000) ? pitch_i : src_width_32[15:0];
wire      [15:0] src_width_32_unused = src_width_32[31:16];

wire  [PA_W-1:0] cfg_base;
wire [DIM_W-1:0] cfg_width;
wire [DIM_W-1:0] cfg_height;
wire [DIM_W-1:0] cfg_src_width;
wire [DIM_W-1:0] cfg_src_height;
wire      [15:0] cfg_pitch;
wire             cfg_double;
wire       [2:0] cfg_swap;          // {X, Y, CL}
wire       [4:0] cfg_bpp_1hot;
wire       [2:0] cfg_palette;
wire       [3:0] cfg_bg;
wire       [3:0] cfg_fg;

arv_ipdff #(.WIDTH(CFG_W), .ARST_EN(ASYNC_RST_EN)) u_cfg (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~refresh_active_i),
             .d_i  ({frame_base_i, disp_width_i, disp_height_i, src_width_in, src_height_in, pitch_in,
                     pix_double_i, disp_cfg_i, bpp_1hot_in, hw_palette_i, hw_bg_i, hw_fg_i}),
             .q_o  ({cfg_base, cfg_width, cfg_height, cfg_src_width, cfg_src_height, cfg_pitch,
                     cfg_double, cfg_swap, cfg_bpp_1hot, cfg_palette, cfg_bg, cfg_fg}));

wire             width_p1_unused  = width_p1[0];
generate
    if (FRAME_W_EN != 0) begin : g_frame_w
        wire [DIM_W-1:0] width_p1_hi_unused = width_p1[DIM_W:1];
    end else begin : g_no_frame_w
        wire [DIM_W-1:0] frame_width_unused = frame_width_i;
    end
endgenerate
wire             height_p1_unused = height_p1[0];

//-----------------------------------------------------------------------------
// 1b) START OFFSET (H' - 1) x P
//-----------------------------------------------------------------------------
// The Y-swap start offset of the latched frame, shift-add, MSB first over
// H' - 1: acc <- 2 acc + bit x P in the first DIM_W cycles of the frame, from
// the latched copy (frozen from the first cycle of refresh_active_i). Cleared
// while refresh_active_i = 0, so every frame start, also one after an
// abandoned frame or a product in progress, restarts it from the operands it
// latches. Held in PA_W bits (the start address' width), or fewer when the
// product is narrower: the low bits of a product do not depend on its high
// bits, so the offset is (H' - 1) x P mod 2^PA_W.
localparam PRD_W = DIM_W + 16;
localparam ACC_W = (PA_W < PRD_W) ? PA_W : PRD_W;
localparam MC_W  = $clog2(DIM_W + 1);
localparam MB_W  = 1 << MC_W;
localparam     [31:0] MC_START = DIM_W;

wire  [MC_W-1:0] mcnt;          // multiply steps left
wire [ACC_W-1:0] macc;
wire             mdone = (mcnt == {MC_W{1'b0}});

// The multiplier bit of step mcnt (DIM_W down to 1): bit mcnt - 1 of H' - 1
wire [DIM_W-1:0] src_height_m1 = cfg_src_height - {{(DIM_W-1){1'b0}}, 1'b1};
wire      [32:0] mbits_33      = {{(32-DIM_W){1'b0}}, src_height_m1, 1'b0};
wire  [MB_W-1:0] mbits         = mbits_33[MB_W-1:0];
wire             mbit          = mbits[mcnt];
wire [ACC_W+15:0] pitch_w      = {{ACC_W{1'b0}}, cfg_pitch};

wire             mul_en   = ~refresh_active_i | ~mdone;
wire  [MC_W-1:0] mcnt_nxt = refresh_active_i ? (mcnt - {{(MC_W-1){1'b0}}, 1'b1}) : MC_START[MC_W-1:0];
wire [ACC_W-1:0] macc_nxt = {ACC_W{refresh_active_i}} &
                            ({macc[ACC_W-2:0], 1'b0} + ({ACC_W{mbit}} & pitch_w[ACC_W-1:0]));

arv_ipdff #(.WIDTH(MC_W), .RST_VAL(MC_START[MC_W-1:0]), .ARST_EN(ASYNC_RST_EN)) u_mcnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(mul_en), .d_i(mcnt_nxt), .q_o(mcnt));
arv_ipdff #(.WIDTH(ACC_W), .ARST_EN(ASYNC_RST_EN)) u_macc (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(mul_en), .d_i(macc_nxt), .q_o(macc));

wire [PA_W+PRD_W-1:0] yofs_ext = {{(PA_W+PRD_W-ACC_W){1'b0}}, macc};
wire       [PA_W-1:0] yofs     = yofs_ext[PA_W-1:0];
wire      [33-MB_W:0] mbits_unused    = {mbits_33[32:MB_W], mbits[0]};
wire           [15:0] pitch_w_unused  = pitch_w[ACC_W+15:ACC_W];
wire      [PRD_W-1:0] yofs_ext_unused = yofs_ext[PA_W+PRD_W-1:PA_W];

//=============================================================================
// 2) RUN CONTROL AND PIXEL CREDIT
//=============================================================================
// run = refresh_active_i once the start offset is done (go: from the
// (DIM_W + 2)th cycle of refresh_active_i on); everything is flushed while not
// running, the walker loading the start address in each of those cycles, the
// last time with the finished offset. The VRAM requests are qualified by go
// alone, the LUT requests by active_dly (both flops, high through the cycle
// refresh_active_i falls): they reach the arbiters, and the AHB HREADYOUTs
// behind them, from flops only; px_valid_o and the state updates follow
// refresh_active_i in the same cycle, as the BDI requires.
wire active_dly;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_active_dly (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(refresh_active_i), .q_o(active_dly));

assign active_dly_o = active_dly;

wire go;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_go (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(refresh_active_i & mdone), .q_o(go));

wire run   = refresh_active_i & go;
wire flush = ~run;

wire       issue;
wire       oq_valid;
wire       px_take = oq_valid & px_ready_i;

// Credit = pixels issued to the fetch pipeline and not yet taken by the driver.
wire [CRED_W-1:0] credit;
wire              credit_en  = flush | (issue ^ px_take);
wire [CRED_W-1:0] credit_nxt = flush ? {CRED_W{1'b0}}                         :
                               issue ? (credit + {{(CRED_W-1){1'b0}}, 1'b1}) :
                                       (credit - {{(CRED_W-1){1'b0}}, 1'b1});
arv_ipdff #(.WIDTH(CRED_W), .ARST_EN(ASYNC_RST_EN)) u_credit (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(credit_en), .d_i(credit_nxt), .q_o(credit));

wire issue_ok = (credit < PX_DEPTH_C);

// Urgent: the fetch requests (a flop-based request, see blns_bk_fetch) while
// the pixel credit is low; the window and the GPU yield to it in the arbiter
assign vurgent_o        = vreq_o & (credit <= URG_CREDIT_C);

//=============================================================================
// 3) FETCH AND CURSOR
//=============================================================================
// The cursor shares the backend's VRAM slot: while it holds it (cur_sel, a
// flop) the request, address and tag are its own (tag 1); the pixel fetch
// ignores the tagged returns.
wire        fetch_push;
wire [15:0] fetch_raw;
wire        fetch_last;
wire        pix_vreq;
wire [VRAM_AW-1:0] pix_vaddr;
wire        w_eol;
wire        w_px_again;
wire        w_line_again;
wire        w_last_line;
wire        w_walk_ok;
wire        cur_sel;
wire        cur_wait;
wire        cur_in;
wire        b_cur;
wire        b_cstep;
wire  [1:0] cur_code;

blns_bk_fetch #(
    .VRAM_AW      ( VRAM_AW      ),
    .DIM_W        ( DIM_W        ),
    .RD_LAT       ( RD_LAT       ),
    .ASYNC_RST_EN ( ASYNC_RST_EN )
) blns_bk_fetch_inst (
// CLOCK & RESET
    .hclk_i       ( hclk_i            ),
    .hresetn_i    ( hresetn_i         ),
// FRAME CONTROL
    .load_i       ( flush             ),
    .req_on_i     ( go                ),
    .issue_ok_i   ( issue_ok          ),
    .issue_o      ( issue             ),
// WALK EVENTS
    .eol_o        ( w_eol             ),
    .px_again_o   ( w_px_again        ),
    .line_again_o ( w_line_again      ),
    .last_line_o  ( w_last_line       ),
    .walk_ok_o    ( w_walk_ok         ),
// CURSOR
    .cur_sel_i    ( cur_sel           ),
    .cur_wait_i   ( cur_wait          ),
    .cur_in_i     ( cur_in            ),
    .vrtag_i      ( vrtag_i           ),
    .b_cur_o      ( b_cur             ),
    .b_cstep_o    ( b_cstep           ),
// LATCHED FRAME CONFIGURATION
    .base_i       ( cfg_base          ),
    .width_i      ( cfg_width         ),
    .height_i     ( cfg_height        ),
    .src_width_i  ( cfg_src_width     ),
    .yofs_i       ( yofs              ),
    .pitch_i      ( cfg_pitch         ),
    .double_i     ( cfg_double        ),
    .swap_x_i     ( cfg_swap[2]       ),
    .swap_y_i     ( cfg_swap[1]       ),
    .swap_cl_i    ( cfg_swap[0]       ),
    .bpp_1hot_i   ( cfg_bpp_1hot      ),
// VRAM REQUESTER
    .vreq_o       ( pix_vreq          ),
    .vaddr_o      ( pix_vaddr         ),
    .vgnt_i       ( vgnt_i            ),
    .vrvalid_i    ( vrvalid_i         ),
    .vrdata_i     ( vrdata_i          ),
// RAW PIXEL OUTPUT
    .px_push_o    ( fetch_push        ),
    .px_raw_o     ( fetch_raw         ),
    .px_last_o    ( fetch_last        ),
// LATCHED LINE LENGTH
    .line_len_m1_o( line_len_m1_o     )
);

generate
    if (CUR_USE) begin : g_cursor
        wire               cur_req;
        wire [VRAM_AW-1:0] cur_vaddr;

        blns_bk_cursor #(
            .VRAM_AW          ( VRAM_AW           ),
            .DIM_W            ( DIM_W             ),
            .ASYNC_RST_EN     ( ASYNC_RST_EN      )
        ) blns_bk_cursor_inst (
        // CLOCK & RESET
            .hclk_i           ( hclk_i            ),
            .hresetn_i        ( hresetn_i         ),
        // CONFIGURATION
            .refresh_active_i ( refresh_active_i  ),
            .cur_en_i         ( cur_en_i          ),
            .cur_hot_i        ( cur_hot_i         ),
            .cur_pos_i        ( cur_pos_i         ),
            .cur_addr_i       ( cur_addr_i        ),
            .src_width_i      ( src_width_in      ),
            .src_height_i     ( src_height_in     ),
            .disp_cfg_i       ( disp_cfg_i        ),
            .cfg_swap_i       ( cfg_swap          ),
        // WALK
            .load_i           ( flush             ),
            .req_on_i         ( go                ),
            .issue_i          ( issue             ),
            .eol_i            ( w_eol             ),
            .px_again_i       ( w_px_again        ),
            .line_again_i     ( w_line_again      ),
            .last_line_i      ( w_last_line       ),
            .walk_ok_i        ( w_walk_ok         ),
            .cur_in_o         ( cur_in            ),
            .cur_wait_o       ( cur_wait          ),
        // VRAM SLOT
            .cur_sel_o        ( cur_sel           ),
            .cur_req_o        ( cur_req           ),
            .cur_addr_o       ( cur_vaddr         ),
            .vgnt_i           ( vgnt_i            ),
            .vrvalid_i        ( vrvalid_i         ),
            .vrtag_i          ( vrtag_i           ),
            .vrdata_i         ( vrdata_i          ),
        // STAGE B
            .b_push_i         ( fetch_push        ),
            .b_cur_i          ( b_cur             ),
            .b_cstep_i        ( b_cstep           ),
            .code_o           ( cur_code          )
        );

        // The pixel request is held back while cur_sel is set: one request at most
        assign vreq_o  = pix_vreq | cur_req;
        assign vaddr_o = cur_sel ? cur_vaddr : pix_vaddr;
        assign vtag_o  = cur_sel;
    end else begin : g_no_cursor
        assign cur_sel  = 1'b0;
        assign cur_wait = 1'b0;
        assign cur_in   = 1'b0;
        assign cur_code = 2'b00;
        assign vreq_o   = pix_vreq;
        assign vaddr_o  = pix_vaddr;
        assign vtag_o   = 1'b0;
        wire   [47:0] cur_cfg_unused  = {cur_en_i, cur_hot_i, cur_pos_i, w_eol, w_px_again, w_line_again, w_last_line, w_walk_ok};
        wire   [VRAM_AW-1:0] cur_addr_unused = cur_addr_i;
        wire    [2:0] cur_tok_unused  = {b_cur, b_cstep, vrtag_i};
    end
endgenerate

//=============================================================================
// 4) RAW PIXEL FIFO
//=============================================================================
wire              raw_pop;
wire [RAW_DW-1:0] raw_head;
wire [RAW_DW-1:0] raw_wdata;
wire        [1:0] raw_code;
wire [CRED_W-1:0] raw_cnt;
wire              raw_valid = (raw_cnt != {CRED_W{1'b0}});

blns_bk_fifo #(
    .DW           ( RAW_DW       ),
    .DEPTH        ( PX_DEPTH     ),
    .PW           ( RAW_PW       ),
    .CW           ( CRED_W       ),
    .ASYNC_RST_EN ( ASYNC_RST_EN )
) blns_bk_fifo_raw_inst (
// CLOCK & RESET
    .hclk_i       ( hclk_i                     ),
    .hresetn_i    ( hresetn_i                  ),
// CONTROL
    .flush_i      ( flush                      ),
    .push_i       ( fetch_push                 ),
    .wdata_i      ( raw_wdata                  ),
    .pop_i        ( raw_pop                    ),
// STATUS / HEAD
    .rdata_o      ( raw_head                   ),
    .cnt_o        ( raw_cnt                    )
);

// raw_head: {last, [code,] value}; the last flag at [16] without the cursor
wire              raw_last = raw_head[RAW_DW-1];
generate
    if (CUR_USE) begin : g_raw_code
        assign raw_wdata = {fetch_last, cur_code, fetch_raw};
        assign raw_code  = raw_head[17:16];
    end else begin : g_raw_nocode
        assign raw_wdata = {fetch_last, fetch_raw};
        assign raw_code  = 2'b00;
        wire   [1:0] cur_code_unused = cur_code;
    end
endgenerate

//=============================================================================
// 5) COLOUR AND BDI PIXEL STREAM
//=============================================================================
// LUT build: colour stage (one-cycle LUT or hardware lookup) into a 3-entry RGB888
// output queue. No LUT: the hardware colour of the raw FIFO head is the stream, the
// raw FIFO being the only pixel storage.
wire        px_head_valid;
wire [23:0] px_head_rgb;
wire        px_head_last;

generate
    if (LUT_EN_USE) begin : g_lut
        wire        cfg_sw_lut_en;
        wire        cfg_bank;
        if (LUT_BANK_EN) begin : g_lut_bank
            arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_cfg_lut (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~refresh_active_i),
                         .d_i  ({sw_lut_en_i, refr_bank_i}),
                         .q_o  ({cfg_sw_lut_en, cfg_bank}));
        end else begin : g_lut_bank_none
            arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_cfg_lut (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~refresh_active_i),
                         .d_i  (sw_lut_en_i),
                         .q_o  (cfg_sw_lut_en));
            assign cfg_bank = 1'b0;
            wire   refr_bank_unused;
            assign refr_bank_unused = refr_bank_i;
        end

        // LUT_ROT, with the terms of the rotation that depend on the
        // configuration only precomputed off the pixel path: OFFSET less the
        // range length (LAST - FIRST + 1) and LAST - OFFSET
        wire  [7:0] rot_first_in = lut_rot_i[7:0];
        wire  [7:0] rot_last_in  = lut_rot_i[15:8];
        wire  [7:0] rot_ofs_in   = lut_rot_i[23:16];
        wire  [7:0] rot_wofs_in  = rot_ofs_in - rot_last_in + rot_first_in - 8'd1;
        wire  [8:0] rot_lim_in   = {1'b0, rot_last_in} - {1'b0, rot_ofs_in};
        wire  [7:0] cfg_rot_first;
        wire  [7:0] cfg_rot_last;
        wire  [7:0] cfg_rot_ofs;
        wire  [7:0] cfg_rot_wofs;
        wire  [8:0] cfg_rot_lim;
        arv_ipdff #(.WIDTH(41), .ARST_EN(ASYNC_RST_EN)) u_cfg_rot (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~refresh_active_i),
                     .d_i  ({rot_ofs_in, rot_wofs_in, rot_lim_in, rot_last_in, rot_first_in}),
                     .q_o  ({cfg_rot_ofs, cfg_rot_wofs, cfg_rot_lim, cfg_rot_last, cfg_rot_first}));

        wire [OQ_CW-1:0] oq_cnt;
        wire        color_held;
        wire        color_push;
        wire [23:0] color_rgb;
        wire        color_last;
        wire [24:0] oq_head;

        // Registered terms only: the slot cannot disappear while a LUT request waits.
        wire        oq_slot_ok = (({1'b0, oq_cnt} + {{OQ_CW{1'b0}}, color_held}) < OQ_DEPTH_C);

        // The same terms one cycle ahead (the LUT request's, for the register
        // port's registered HREADYOUT): the FIFO counts after this cycle's push,
        // pop and flush, stage C after this cycle's pop.
        wire        raw_valid_nxt = ~flush & (fetch_push |
                                              (raw_cnt > {{(CRED_W-1){1'b0}}, 1'b1}) |
                                              (raw_valid & ~raw_pop));
        wire [OQ_CW:0] oq_cnt_nxt = flush ? {(OQ_CW+1){1'b0}} :
                                    ({1'b0, oq_cnt} + {{OQ_CW{1'b0}}, color_push} - {{OQ_CW{1'b0}}, px_take});
        wire        oq_slot_ok_nxt = ((oq_cnt_nxt + {{OQ_CW{1'b0}}, raw_pop}) < OQ_DEPTH_C);

        blns_bk_color #(
            .ASYNC_RST_EN ( ASYNC_RST_EN )
        ) blns_bk_color_inst (
        // CLOCK & RESET
            .hclk_i       ( hclk_i              ),
            .hresetn_i    ( hresetn_i           ),
        // CONTROL
            .flush_i      ( flush               ),
            .slot_ok_i    ( oq_slot_ok          ),
        // RAW PIXEL INPUT
            .raw_valid_i  ( raw_valid           ),
            .raw_i        ( raw_head[15:0]      ),
            .raw_code_i   ( raw_code            ),
            .raw_last_i   ( raw_last            ),
            .raw_pop_o    ( raw_pop             ),
        // LATCHED FRAME CONFIGURATION
            .bpp_1hot_i   ( cfg_bpp_1hot        ),
            .sw_lut_en_i  ( cfg_sw_lut_en       ),
            .bank_i       ( cfg_bank            ),
            .hw_palette_i ( cfg_palette         ),
            .hw_bg_i      ( cfg_bg              ),
            .hw_fg_i      ( cfg_fg              ),
            .rot_first_i  ( cfg_rot_first       ),
            .rot_last_i   ( cfg_rot_last        ),
            .rot_ofs_i    ( cfg_rot_ofs         ),
            .rot_wofs_i   ( cfg_rot_wofs        ),
            .rot_lim_i    ( cfg_rot_lim         ),
            .cur_col1_i   ( cur_col1_i          ),
            .cur_col2_i   ( cur_col2_i          ),
            .cur_col3_i   ( cur_col3_i          ),
        // LUT REQUESTER
            .req_on_i     ( active_dly          ),
            .raw_valid_nxt_i ( raw_valid_nxt       ),
            .slot_ok_nxt_i ( oq_slot_ok_nxt      ),
            .req_on_nxt_i ( refresh_active_i    ),
            .lreq_o       ( lreq_o              ),
            .lreq_nxt_o   ( lreq_nxt_o          ),
            .laddr_o      ( laddr_o             ),
            .lgnt_i       ( lgnt_i              ),
            .lrvalid_i    ( lrvalid_i           ),
            .lrdata_i     ( lrdata_i            ),
        // RGB888 OUTPUT
            .px_held_o    ( color_held          ),
            .px_push_o    ( color_push          ),
            .px_rgb_o     ( color_rgb           ),
            .px_last_o    ( color_last          )
        );

        blns_bk_fifo #(
            .DW           ( 25           ),
            .DEPTH        ( OQ_DEPTH     ),
            .PW           ( OQ_PW        ),
            .CW           ( OQ_CW        ),
            .ASYNC_RST_EN ( ASYNC_RST_EN )
        ) blns_bk_fifo_out_inst (
        // CLOCK & RESET
            .hclk_i       ( hclk_i                     ),
            .hresetn_i    ( hresetn_i                  ),
        // CONTROL
            .flush_i      ( flush                      ),
            .push_i       ( color_push                 ),
            .wdata_i      ( {color_last, color_rgb}    ),
            .pop_i        ( px_take                    ),
        // STATUS / HEAD
            .rdata_o      ( oq_head                    ),
            .cnt_o        ( oq_cnt                     )
        );

        assign px_head_valid = (oq_cnt != {OQ_CW{1'b0}});
        assign px_head_rgb   = oq_head[23:0];
        assign px_head_last  = oq_head[24];

    end else begin : g_no_lut
        wire [23:0] hw_rgb;

        blns_bk_hwcol blns_bk_hwcol_inst (
        // PIXEL
            .raw_i        ( raw_head[15:0]      ),
        // LATCHED FRAME CONFIGURATION
            .bpp_1hot_i   ( cfg_bpp_1hot        ),
            .hw_palette_i ( cfg_palette         ),
            .hw_bg_i      ( cfg_bg              ),
            .hw_fg_i      ( cfg_fg              ),
        // COLOUR
            .rgb_o        ( hw_rgb              )
        );

        // The cursor colour replaces the pixel's (code 0: transparent)
        assign px_head_rgb   = ({24{raw_code == 2'd0}} & hw_rgb    ) |
                               ({24{raw_code == 2'd1}} & cur_col1_i) |
                               ({24{raw_code == 2'd2}} & cur_col2_i) |
                               ({24{raw_code == 2'd3}} & cur_col3_i);
        assign px_head_valid = raw_valid;
        assign px_head_last  = raw_last;
        assign raw_pop       = px_take;
        assign lreq_o        = 1'b0;
        assign lreq_nxt_o    = 1'b0;
        assign laddr_o       = 9'h000;

        wire        sw_lut_en_unused;
        assign      sw_lut_en_unused = sw_lut_en_i;
        wire        refr_bank_unused;
        assign      refr_bank_unused = refr_bank_i;
        wire [23:0] lut_rot_unused;
        assign      lut_rot_unused   = lut_rot_i;
        wire        lgnt_unused;
        assign      lgnt_unused      = lgnt_i;
        wire        lrvalid_unused;
        assign      lrvalid_unused   = lrvalid_i;
        wire [23:0] lrdata_unused;
        assign      lrdata_unused    = lrdata_i;
    end
endgenerate

assign oq_valid   = run & px_head_valid;
assign px_valid_o = oq_valid;
assign px_data_o  = px_head_rgb;
assign px_last_o  = px_head_last;

endmodule // blns_backend

`default_nettype wire
