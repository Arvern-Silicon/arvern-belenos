//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_bk_fetch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_bk_fetch.v
// Module Description : Backend frame fetch: start corner and scan walk (X / Y / CL
//                      swaps), VRAM read requester issuing a read only when the word
//                      address changes, word buffer and LSB-first pixel unpacking.
//                      Stage A walks one pixel per issue; stage B (RD_LAT cycles
//                      later) extracts the raw pixel value from the returned or
//                      buffered word. The hardware cursor (blns_bk_cursor)
//                      shares the VRAM slot (cur_sel_i), holds the walk
//                      (cur_wait_i) and rides on the token line (cur_in_i).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_bk_fetch #(
    parameter                   VRAM_AW      = 16,   // VRAM word-address width
    parameter                   DIM_W        = 10,   // width/height field width
    parameter                   RD_LAT       = 1,    // read data RD_LAT cycles after the grant (1-4)
    parameter                   ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                 hclk_i,              // clock
    input  wire                 hresetn_i,           // active-low reset (style per ASYNC_RST_EN)

// FRAME CONTROL
    input  wire                 load_i,              // not running: reload the walker, flush
    input  wire                 issue_ok_i,          // a pixel slot is free (registered credit)
    output wire                 issue_o,             // a pixel enters the pipeline

// WALK EVENTS (stage A, for the cursor)
    output wire                 eol_o,               // the pixel to issue ends its scan line
    output wire                 px_again_o,          // ... is sent again next (doubling)
    output wire                 line_again_o,        // the scan line is walked again next (doubling)
    output wire                 last_line_o,         // the scan line is the frame's last
    output wire                 walk_ok_o,           // not done, a pixel credit (flops)

// CURSOR (blns_bk_cursor; 0 without one)
    input  wire                 cur_sel_i,           // the cursor holds the VRAM slot (a flop)
    input  wire                 cur_wait_i,          // the pixel to issue waits for its cursor line (flops)
    input  wire                 cur_in_i,            // the pixel to issue is a cursor-box pixel (flops)
    input  wire                 vrtag_i,             // the returning read is the cursor's
    output wire                 b_cur_o,             // stage B token: a cursor-box pixel
    output wire                 b_cstep_o,           // ... the next pixel of its line is the next source pixel

// LATCHED FRAME CONFIGURATION
    input  wire   [VRAM_AW+4:0] base_i,              // frame pixel address
    input  wire     [DIM_W-1:0] width_i,             // >= 1
    input  wire     [DIM_W-1:0] height_i,            // >= 1
    input  wire     [DIM_W-1:0] src_width_i,         // source frame width, >= 1
    input  wire    [VRAM_AW+4:0] yofs_i,             // (H'-1) x pitch mod 2^(VRAM_AW+5), from flops
    input  wire          [15:0] pitch_i,             // line pitch in source pixels (>= 1)
    input  wire                 double_i,            // every source pixel and line sent twice
    input  wire                 swap_x_i,            // DISP_CFG X: lines walked right to left
    input  wire                 swap_y_i,            // DISP_CFG Y: bottom to top
    input  wire                 swap_cl_i,           // DISP_CFG CL: columns walked as lines
    input  wire           [4:0] bpp_1hot_i,          // {16, 8, 4, 2, 1} bpp

// VRAM REQUESTER (blns_vram_arb: request held with its address until granted;
// read data valid exactly RD_LAT cycles after the grant)
    input  wire                 req_on_i,            // the request may be raised (a flop: the cycles of
                                                     // a frame after its last load, and the falling one)
    output wire                 vreq_o,              // read request, from flops only
    output wire   [VRAM_AW-1:0] vaddr_o,             // word address
    input  wire                 vgnt_i,              // grant (same cycle)
    input  wire                 vrvalid_i,           // read data valid (RD_LAT cycles after the grant)
    input  wire          [31:0] vrdata_i,            // read data

// RAW PIXEL OUTPUT (stage B)
    output wire                 px_push_o,           // a pixel for the raw FIFO
    output wire          [15:0] px_raw_o,            // zero-extended pixel value
    output wire                 px_last_o,           // the pixel is the frame's last

// LATCHED LINE LENGTH (the DPI driver's)
    output wire     [DIM_W-1:0] line_len_m1_o        // scan-line length - 1 of the latched frame
);

localparam PA_W  = VRAM_AW + 5;
localparam PRD_W = DIM_W + 16;
localparam EXT_W = PA_W + PRD_W;

wire bpp1  = bpp_1hot_i[0];
wire bpp2  = bpp_1hot_i[1];
wire bpp4  = bpp_1hot_i[2];
wire bpp8  = bpp_1hot_i[3];
wire bpp16 = bpp_1hot_i[4];

//=============================================================================
// 1) GEOMETRY: START CORNER, STEPS, LINE LENGTHS
//=============================================================================
// Source frame W' x H' (W x H, or ceil(W/2) x ceil(H/2) when doubling), line
// pitch P (REFR_PITCH, or W'):
// Start = base + (X ? W'-1 : 0) + (Y ? (H'-1)*P : 0), (H'-1)*P from the
// backend (yofs_i, a shift-add done before the last load)
// No CL : inner step +-1 (- if X), line step +-P (- if Y), line length W, H lines
// CL    : inner step +-P (- if Y), line step +-1 (- if X), line length H, W lines

wire [DIM_W-1:0] width_m1      = width_i      - {{(DIM_W-1){1'b0}}, 1'b1};
wire [DIM_W-1:0] height_m1     = height_i     - {{(DIM_W-1){1'b0}}, 1'b1};
wire [DIM_W-1:0] src_width_m1  = src_width_i  - {{(DIM_W-1){1'b0}}, 1'b1};

wire [EXT_W-1:0] pitch_ext    = {{(EXT_W-16){1'b0}}, pitch_i};
wire [EXT_W-1:0] src_w_m1_ext = {{(EXT_W-DIM_W){1'b0}}, src_width_m1};

wire  [PA_W-1:0] pitch_pa    = pitch_ext[PA_W-1:0];
wire  [PA_W-1:0] src_w_m1_pa = src_w_m1_ext[PA_W-1:0];

wire  [PA_W-1:0] pa_one      = {{(PA_W-1){1'b0}}, 1'b1};
wire  [PA_W-1:0] pa_minus1   = {PA_W{1'b1}};
wire  [PA_W-1:0] pitch_neg   = ~pitch_pa + pa_one;

wire  [PA_W-1:0] start_pa    = base_i
                             + ({PA_W{swap_x_i}} & src_w_m1_pa)
                             + ({PA_W{swap_y_i}} & yofs_i);

wire  [PA_W-1:0] step_one    = swap_x_i ? pa_minus1 : pa_one;
wire  [PA_W-1:0] step_pitch  = swap_y_i ? pitch_neg : pitch_pa;
wire  [PA_W-1:0] inner_step  = swap_cl_i ? step_pitch : step_one;
wire  [PA_W-1:0] line_step   = swap_cl_i ? step_one   : step_pitch;

wire [DIM_W-1:0] line_len_m1 = swap_cl_i ? height_m1 : width_m1;
wire [DIM_W-1:0] lines_m1    = swap_cl_i ? width_m1  : height_m1;

assign line_len_m1_o = line_len_m1;

//=============================================================================
// 2) STAGE A: SCAN WALK AND VRAM REQUEST
//=============================================================================
wire  [PA_W-1:0] pa;            // pixel address to issue
wire  [PA_W-1:0] la;            // first pixel address of the current line
wire [DIM_W-1:0] icnt;          // pixel index in the line
wire [DIM_W-1:0] lcnt;          // line index
wire             done;
wire             lw_valid;      // lw_addr holds the last word read this frame
wire             px_rep;        // doubling: the pixel issued now is sent again next
wire             ln_rep;        // doubling: the current line is the first of its pair
wire [VRAM_AW-1:0] lw_addr;

// Word address and bit offset of the pixel (one-hot AND-OR on bpp)
wire [VRAM_AW-1:0] wa = ({VRAM_AW{bpp1 }} & pa[VRAM_AW+4:5]) |
                        ({VRAM_AW{bpp2 }} & pa[VRAM_AW+3:4]) |
                        ({VRAM_AW{bpp4 }} & pa[VRAM_AW+2:3]) |
                        ({VRAM_AW{bpp8 }} & pa[VRAM_AW+1:2]) |
                        ({VRAM_AW{bpp16}} & pa[VRAM_AW  :1]);
wire         [4:0] wa_off = ({5{bpp1 }} &  pa[4:0]         ) |
                            ({5{bpp2 }} & {pa[3:0], 1'b0}  ) |
                            ({5{bpp4 }} & {pa[2:0], 2'b00} ) |
                            ({5{bpp8 }} & {pa[1:0], 3'b000}) |
                            ({5{bpp16}} & {pa[0],   4'h0}  );

// need_fetch: the pixel to issue lies outside the word read last. It is a
// flop, computed from the walker's next state (section 2b), and the request
// is qualified by req_on_i (a flop) rather than load_i (combinational from the
// driver's refresh_active), so that the request and everything granted
// against it depend on flops only. In the cycle a frame ends the request may
// be granted without an issue: that read is wasted (its data only loads the
// word buffer, and the next frame's first pixel always fetches, lw_valid
// being cleared by the load).
// The cursor: while it holds the slot (cur_sel_i) the grant is its own; a
// cursor-box pixel whose line is not read yet waits (cur_wait_i), with its
// request held back too, so that no grant comes without an issue. Both are
// flops; cur_wait rises only on an issue or a load, cur_sel only with no
// pixel request waiting (blns_bk_cursor), so no pixel request already raised
// is dropped.
wire need_fetch;
wire walk_on    = ~load_i & ~done & issue_ok_i & ~cur_wait_i;
wire pgnt       = vgnt_i & ~cur_sel_i;
wire issue      = walk_on & (~need_fetch | pgnt);
wire fetch      = walk_on &   need_fetch & pgnt;

wire eol        = (icnt == line_len_m1);
wire eof        = eol & (lcnt == lines_m1);

wire  [PA_W-1:0] la_next = la + line_step;

// Doubling holds the address for every other pixel, and walks every line twice
wire             line_again = double_i & ln_rep;

// Priority: load > issue (end of frame / end of line / repeated pixel / inner step)
wire             walk_en  = load_i | issue;
wire  [PA_W-1:0] pa_step  = (eol & line_again)    ? la       :
                            eol                   ? la_next  :
                            (double_i & px_rep)   ? pa       :
                                                    (pa + inner_step);
wire  [PA_W-1:0] pa_nxt   = load_i ? start_pa : pa_step;
wire             la_en    = load_i | (issue & eol & ~line_again);
wire  [PA_W-1:0] la_nxt   = load_i ? start_pa : la_next;
wire             lc_en    = load_i | (issue & eol);
wire [DIM_W-1:0] icnt_nxt = (load_i | eol) ? {DIM_W{1'b0}} : (icnt + {{(DIM_W-1){1'b0}}, 1'b1});
wire [DIM_W-1:0] lcnt_nxt = load_i ? {DIM_W{1'b0}} : (lcnt + {{(DIM_W-1){1'b0}}, 1'b1});
wire             px_rep_nxt = load_i | eol | ~px_rep;
wire             ln_rep_nxt = load_i | ~ln_rep;
wire             done_en  = load_i | (issue & eof);
wire             lw_en    = load_i | fetch;

arv_ipdff #(.WIDTH(PA_W),  .ARST_EN(ASYNC_RST_EN)) u_pa (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(walk_en), .d_i(pa_nxt),   .q_o(pa));
arv_ipdff #(.WIDTH(PA_W),  .ARST_EN(ASYNC_RST_EN)) u_la (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(la_en),   .d_i(la_nxt),   .q_o(la));
arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_icnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(walk_en), .d_i(icnt_nxt), .q_o(icnt));
arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_lcnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lc_en),   .d_i(lcnt_nxt), .q_o(lcnt));
arv_ipdff #(.WIDTH(1),     .ARST_EN(ASYNC_RST_EN)) u_px_rep (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(walk_en), .d_i(px_rep_nxt), .q_o(px_rep));
arv_ipdff #(.WIDTH(1),     .ARST_EN(ASYNC_RST_EN)) u_ln_rep (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lc_en),   .d_i(ln_rep_nxt), .q_o(ln_rep));
arv_ipdff #(.WIDTH(1),     .ARST_EN(ASYNC_RST_EN)) u_done (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(done_en), .d_i(~load_i),  .q_o(done));
arv_ipdff #(.WIDTH(1),     .ARST_EN(ASYNC_RST_EN)) u_lw_valid (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lw_en),   .d_i(~load_i),  .q_o(lw_valid));
arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_lw_addr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(fetch),   .d_i(wa),       .q_o(lw_addr));

//-----------------------------------------------------------------------------
// 2b) NEED_FETCH FOR THE NEXT CYCLE
//-----------------------------------------------------------------------------
// The compare of the next pixel's word with the next last-read word, from the
// values pa, lw_valid and lw_addr take at this clock edge. A load clears
// lw_valid, so the compare is then masked: pa_n leaves out the load leg (the
// start address), which keeps the start-address adder out of this cone.
wire  [PA_W-1:0]   pa_n  = issue ? pa_step : pa;
wire [VRAM_AW-1:0] wa_n  = ({VRAM_AW{bpp1 }} & pa_n[VRAM_AW+4:5]) |
                           ({VRAM_AW{bpp2 }} & pa_n[VRAM_AW+3:4]) |
                           ({VRAM_AW{bpp4 }} & pa_n[VRAM_AW+2:3]) |
                           ({VRAM_AW{bpp8 }} & pa_n[VRAM_AW+1:2]) |
                           ({VRAM_AW{bpp16}} & pa_n[VRAM_AW  :1]);
wire               lwv_n = lw_en ? ~load_i : lw_valid;
wire [VRAM_AW-1:0] lwa_n = fetch ? wa      : lw_addr;
wire               nf_n  = ~lwv_n | (wa_n != lwa_n);

// Held inverted, so that it resets to 0 (need_fetch = 1: lw_valid resets to 0)
wire               no_fetch;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_no_fetch (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(~nf_n), .q_o(no_fetch));
assign need_fetch = ~no_fetch;

wire               pa_n0_unused = pa_n[0];
assign vreq_o  = req_on_i & ~done & issue_ok_i & need_fetch & ~cur_wait_i & ~cur_sel_i;
assign vaddr_o = wa;
assign issue_o = issue;

assign eol_o        = eol;
assign px_again_o   = double_i & px_rep;
assign line_again_o = line_again;
assign last_line_o  = (lcnt == lines_m1);
assign walk_ok_o    = ~done & issue_ok_i;

//=============================================================================
// 3) STAGE B: WORD BUFFER AND UNPACK
//=============================================================================
// A token reaches stage B RD_LAT cycles after its issue, the read latency: as
// early as its word can return. A token that fetched its word (b_new) pushes
// its pixel with the word's read data valid, and the word buffer takes every
// word returned for later tokens of the same word. With a macro of fixed
// latency both meet; a memory whose latency is not fixed would make the token
// line a FIFO that a b_new token leaves with its read data valid.
wire        b_valid;
wire        b_new;
wire  [4:0] b_off;
wire        b_last;
wire [31:0] word_buf;

// Token line: {valid, new} and {cursor, cursor step, last, offset} per stage
localparam TK_W = 8;
wire   [RD_LAT-1:0] tk_v;
wire   [RD_LAT-1:0] tk_new;
wire [TK_W*RD_LAT-1:0] tk_tok;
wire        b_cur;
wire        b_cstep;
wire        a_cstep = ~eol & ~(double_i & px_rep);   // the walk steps to the next source pixel

arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_b_valid (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),  .d_i(issue),  .q_o(tk_v[0]));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_b_new (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),  .d_i(fetch),  .q_o(tk_new[0]));
arv_ipdff #(.WIDTH(TK_W), .ARST_EN(ASYNC_RST_EN)) u_b_tok (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(issue), .d_i({cur_in_i, a_cstep, eof, wa_off}), .q_o(tk_tok[TK_W-1:0]));

genvar ki;
generate
    for (ki = 1; ki < RD_LAT; ki = ki + 1) begin : g_tk
        // load_i drops a token in the stages before B too
        wire            tk_v_in   = tk_v[ki-1];
        wire            tk_new_in = tk_new[ki-1];
        wire [TK_W-1:0] tk_tok_in = tk_tok[(ki-1)*TK_W +: TK_W];
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_tk_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
             .d_i({tk_v_in & ~load_i, tk_new_in}), .q_o({tk_v[ki], tk_new[ki]}));
        arv_ipdff #(.WIDTH(TK_W), .ARST_EN(ASYNC_RST_EN)) u_tk_tok (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(tk_v_in), .d_i(tk_tok_in), .q_o(tk_tok[ki*TK_W +: TK_W]));
    end
endgenerate
assign      b_valid         = tk_v[RD_LAT-1];
assign      b_new           = tk_new[RD_LAT-1];
assign      {b_cur, b_cstep, b_last, b_off} = tk_tok[(RD_LAT-1)*TK_W +: TK_W];
// The cursor's returns (tagged) are not pixel words
wire        b_fetch = vrvalid_i & ~vrtag_i;

arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_word_buf (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(b_fetch), .d_i(vrdata_i), .q_o(word_buf));

wire [31:0] b_word  = b_fetch ? vrdata_i : word_buf;
wire [31:0] b_shift = b_word >> b_off;
wire [15:0] b_mask  = ({16{bpp16}} & 16'hFFFF) |
                      ({16{bpp8 }} & 16'h00FF) |
                      ({16{bpp4 }} & 16'h000F) |
                      ({16{bpp2 }} & 16'h0003) |
                      ({16{bpp1 }} & 16'h0001);

// load_i flushes a token issued in the last running cycle. A token that
// fetched its word meets the word's read data valid (the fixed read latency:
// checked in the formal harness and by the bench, not masked here)
assign px_push_o = b_valid & ~load_i;
assign px_raw_o  = b_shift[15:0] & b_mask;
assign px_last_o = b_last;
assign b_cur_o   = b_cur;
assign b_cstep_o = b_cstep;

//=============================================================================
// LINT CLEANUP
//=============================================================================
wire [EXT_W-PA_W-1:0] pitch_ext_unused    = pitch_ext[EXT_W-1:PA_W];
wire [EXT_W-PA_W-1:0] src_w_m1_ext_unused = src_w_m1_ext[EXT_W-1:PA_W];
wire           [15:0] b_shift_unused      = b_shift[31:16];
wire                  b_new_unused        = b_new;      // the fixed-latency check (formal harness, bench)

endmodule // blns_bk_fetch

`default_nettype wire
