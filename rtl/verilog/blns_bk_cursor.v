//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_bk_cursor
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_bk_cursor.v
// Module Description : Backend hardware cursor (CURSOR_EN): 32 x 32 pixels,
//                      2 bpp, in source-frame coordinates. At the frame latch
//                      the cursor box is turned into scan coordinates (the
//                      index of its first pixel along a scan line and of its
//                      first scan line, both directions). In stage A it
//                      follows the walker's source steps, reads the two words
//                      of each cursor scan line on the backend's VRAM slot
//                      (tagged) into a 64-bit line buffer, loaded in scan
//                      order, and holds a cursor-box pixel until its line is
//                      read. In stage B each cursor-box token takes its 2-bit
//                      code from the buffer, which then shifts by one pixel.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_bk_cursor #(
    parameter                   VRAM_AW      = 16,   // VRAM word-address width
    parameter                   DIM_W        = 10,   // width/height field width
    parameter                   ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                 hclk_i,              // clock
    input  wire                 hresetn_i,           // active-low reset (style per ASYNC_RST_EN)

// CONFIGURATION (live; latched while refresh_active_i = 0)
    input  wire                 refresh_active_i,    // driver is sending a frame
    input  wire                 cur_en_i,            // CURSOR_CTRL.EN
    input  wire           [9:0] cur_hot_i,           // CURSOR_CTRL {HOT_Y, HOT_X}
    input  wire          [31:0] cur_pos_i,           // CURSOR_POS {Y, X}, signed
    input  wire   [VRAM_AW-1:0] cur_addr_i,          // CURSOR_ADDR ([6:0] = 0)
    input  wire     [DIM_W-1:0] src_width_i,         // source frame width W', >= 1
    input  wire     [DIM_W-1:0] src_height_i,        // source frame height H', >= 1
    input  wire           [2:0] disp_cfg_i,          // DISP_CFG {X, Y, CL}
    input  wire           [2:0] cfg_swap_i,          // ... latched with the same enable (blns_backend u_cfg)

// WALK (stage A, blns_bk_fetch)
    input  wire                 load_i,              // not running: reload, flush
    input  wire                 req_on_i,            // the request may be raised (a flop)
    input  wire                 issue_i,             // a pixel enters the pipeline
    input  wire                 eol_i,               // ... it ends its scan line
    input  wire                 px_again_i,          // ... it is sent again next (doubling)
    input  wire                 line_again_i,        // the scan line is walked again next (doubling)
    input  wire                 last_line_i,         // the scan line is the frame's last
    input  wire                 walk_ok_i,           // the walk is not done and has a pixel credit (flops)
    output wire                 cur_in_o,            // the pixel to issue is a cursor-box pixel
    output wire                 cur_wait_o,          // ... and its cursor line is not read yet

// VRAM SLOT (shared with the pixel fetch)
    output wire                 cur_sel_o,           // the cursor holds the slot (its request, address, tag)
    output wire                 cur_req_o,           // cursor read request, from flops
    output wire   [VRAM_AW-1:0] cur_addr_o,          // its word address
    input  wire                 vgnt_i,              // the slot's grant
    input  wire                 vrvalid_i,           // the slot's read data valid
    input  wire                 vrtag_i,             // ... a cursor read
    input  wire          [31:0] vrdata_i,            // read data

// STAGE B (the token line of blns_bk_fetch)
    input  wire                 b_push_i,            // a token leaves stage B
    input  wire                 b_cur_i,             // ... a cursor-box pixel
    input  wire                 b_cstep_i,           // ... followed by the next source pixel
    output wire           [1:0] code_o               // its cursor code (0 = transparent)
);

//=============================================================================
// 1) FRAME LATCH: CURSOR BOX IN SCAN COORDINATES
//=============================================================================
// Top-left of the shape in the source frame: (tx, ty) = (X - HOT_X, Y - HOT_Y).
// No CL: a scan line is a frame row (inner: x, lines: y); CL: a frame column
// (inner: y, lines: x). In each direction the box starts at s = t, or
// L - 32 - t when that direction is reversed (L its length in source pixels),
// and is reversed with it. Visible when -31 <= s <= L - 1 in both directions.
// Latched: s clamped at 0 (the source pixels before the box) and -s clamped
// at 0 (the box pixels before the scan start, 0-31).

wire     [17:0] tx    = {{2{cur_pos_i[15]}}, cur_pos_i[15:0]}  - {13'h0000, cur_hot_i[4:0]};
wire     [17:0] ty    = {{2{cur_pos_i[31]}}, cur_pos_i[31:16]} - {13'h0000, cur_hot_i[9:5]};
wire     [17:0] w18   = {{(18-DIM_W){1'b0}}, src_width_i};
wire     [17:0] h18   = {{(18-DIM_W){1'b0}}, src_height_i};

wire            cl    = disp_cfg_i[0];
wire            rv_in = cl ? disp_cfg_i[1] : disp_cfg_i[2];
wire            rv_ln = cl ? disp_cfg_i[2] : disp_cfg_i[1];
wire     [17:0] t_in  = cl ? ty  : tx;
wire     [17:0] t_ln  = cl ? tx  : ty;
wire     [17:0] l_in  = cl ? h18 : w18;
wire     [17:0] l_ln  = cl ? w18 : h18;

wire     [17:0] r_in  = l_in - 18'd32 - t_in;
wire     [17:0] r_ln  = l_ln - 18'd32 - t_ln;
wire     [17:0] s_in  = rv_in ? r_in : t_in;
wire     [17:0] s_ln  = rv_ln ? r_ln : t_ln;

wire     [17:0] s_in_p31 = s_in + 18'd31;
wire     [17:0] s_ln_p31 = s_ln + 18'd31;
wire     [17:0] s_in_ml  = s_in - l_in;
wire     [17:0] s_ln_ml  = s_ln - l_ln;
wire     [17:0] s_in_neg = 18'd0 - s_in;
wire     [17:0] s_ln_neg = 18'd0 - s_ln;
wire            vis_in   = ~s_in_p31[17] & s_in_ml[17];
wire            vis_ln   = ~s_ln_p31[17] & s_ln_ml[17];
wire            vis_nxt  = cur_en_i & vis_in & vis_ln;

wire [DIM_W-1:0] pre_in_nxt = s_in[17] ? {DIM_W{1'b0}} : s_in[DIM_W-1:0];
wire [DIM_W-1:0] pre_ln_nxt = s_ln[17] ? {DIM_W{1'b0}} : s_ln[DIM_W-1:0];
wire       [4:0] k_in_nxt   = s_in[17] ? s_in_neg[4:0] : 5'd0;
wire       [4:0] k_ln_nxt   = s_ln[17] ? s_ln_neg[4:0] : 5'd0;

localparam CCFG_W = 1 + 2*DIM_W + 10 + VRAM_AW;

wire             vis;           // the cursor shows in this frame
wire [DIM_W-1:0] pre_in;        // source pixels of a scan line before the box
wire [DIM_W-1:0] pre_ln;        // source scan lines before the box
wire       [4:0] k_in;          // box pixels before the scan-line start
wire       [4:0] k_ln;          // box lines before the first scan line
wire             rev_in;        // the box is walked reversed along a scan line
wire             rev_ln;        // ... across the scan lines
wire             cfg_cl;        // CL: the column copy (+64)
wire [VRAM_AW-1:0] cfg_addr;

arv_ipdff #(.WIDTH(CCFG_W), .ARST_EN(ASYNC_RST_EN)) u_ccfg (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~refresh_active_i),
             .d_i  ({vis_nxt, pre_in_nxt, pre_ln_nxt, k_in_nxt, k_ln_nxt, cur_addr_i}),
             .q_o  ({vis,     pre_in,     pre_ln,     k_in,     k_ln,     cfg_addr}));

// The reversals and CL of the frame: the backend's latched DISP_CFG swaps
// (loaded while refresh_active_i = 0, as u_ccfg), so no copy here
assign cfg_cl = cfg_swap_i[0];
assign rev_in = cfg_swap_i[0] ? cfg_swap_i[1] : cfg_swap_i[2];
assign rev_ln = cfg_swap_i[0] ? cfg_swap_i[2] : cfg_swap_i[1];

//=============================================================================
// 2) STAGE A: SCAN POSITION
//=============================================================================
// The counters step on the walker's source steps only: a pixel or line sent
// again (doubling) keeps its position.
//   - lines: lpre counts the source scan lines down to the box, lc is then the
//     box line (0-31, in scan order), ln_cur the current scan line is a box line;
//   - inner: ipre counts the source pixels down to the box (started), brem the
//     box pixels left after the one to issue, c_fin the line's box pixels are
//     all issued (also on a line that is not a box line).
wire             ev_l   = issue_i & eol_i;                    // a scan line ends
wire             lstep  = ev_l & ~line_again_i;               // ... the next is the next source line
wire             istep  = issue_i & ~eol_i & ~px_again_i;     // the next pixel is the next source pixel

wire             ln_cur;
wire [DIM_W-1:0] lpre;
wire       [4:0] lc;
wire             started;
wire [DIM_W-1:0] ipre;
wire       [4:0] brem;
wire             c_fin;

wire [DIM_W-1:0] dim_one   = {{(DIM_W-1){1'b0}}, 1'b1};
wire             lpre_z    = (lpre == {DIM_W{1'b0}});
wire             lpre_one  = (lpre == dim_one);
wire             lc_last   = (lc == 5'd31);
wire             pre_ln_z  = (pre_ln == {DIM_W{1'b0}});
wire             pre_in_z  = (pre_in == {DIM_W{1'b0}});
wire             ln0_cur   = vis & pre_ln_z;                  // the first scan line is a box line

// The next scan line: the same source line again (doubling), else the next;
// none after the frame's last
wire             ln_nxt_src = lpre_z ? (ln_cur & ~lc_last) : (vis & lpre_one);
wire             nxt_box    = ~last_line_i & (line_again_i ? ln_cur : ln_nxt_src);
wire             ln_cur_nxt = load_i ? ln0_cur : nxt_box;
wire       [4:0] lc_nxt_src = lpre_z ? (lc + 5'd1) : 5'd0;
wire       [4:0] lc_nxt     = load_i ? k_ln : lc_nxt_src;
wire             ln_en      = load_i | ev_l;
wire             lc_en      = load_i | (lstep & lpre_z & ln_cur);
wire             lpre_en    = load_i | (lstep & ~lpre_z);
wire [DIM_W-1:0] lpre_nxt   = load_i ? pre_ln : (lpre - dim_one);

arv_ipdff #(.WIDTH(1),     .ARST_EN(ASYNC_RST_EN)) u_ln_cur (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ln_en),   .d_i(ln_cur_nxt), .q_o(ln_cur));
arv_ipdff #(.WIDTH(5),     .ARST_EN(ASYNC_RST_EN)) u_lc (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lc_en),   .d_i(lc_nxt),     .q_o(lc));
arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_lpre (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(lpre_en), .d_i(lpre_nxt),   .q_o(lpre));

// Inner position, restarted at every scan line
wire             in_rst     = load_i | ev_l;
wire             in_box     = started & ~c_fin;               // the pixel to issue is a box pixel
wire             ipre_en    = in_rst | (istep & ~started);
wire [DIM_W-1:0] ipre_nxt   = in_rst ? pre_in : (ipre - dim_one);
wire             started_nxt = in_rst ? pre_in_z : (ipre == dim_one);
wire             brem_en    = in_rst | (istep & in_box);
wire       [4:0] brem_nxt   = in_rst ? ~k_in : (brem - 5'd1);
wire             fin_box    = istep & in_box & (brem == 5'd0); // the last box pixel is issued
wire             c_fin_en   = in_rst | fin_box;
wire             c_fin_nxt  = in_rst ? ~ln_cur_nxt : 1'b1;

arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_ipre (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ipre_en),  .d_i(ipre_nxt),    .q_o(ipre));
arv_ipdff #(.WIDTH(1),     .ARST_EN(ASYNC_RST_EN)) u_started (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ipre_en),  .d_i(started_nxt), .q_o(started));
arv_ipdff #(.WIDTH(5),     .ARST_EN(ASYNC_RST_EN)) u_brem (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(brem_en),  .d_i(brem_nxt),    .q_o(brem));
// Reset to 1: no box line until a frame loads
arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_c_fin (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(c_fin_en), .d_i(c_fin_nxt),   .q_o(c_fin));

//=============================================================================
// 3) STAGE A: LINE READS ON THE VRAM SLOT
//=============================================================================
// One buffer, for one box scan line: bv = its two reads are granted, bt = they
// are for the next scan line (0: the current one). The reads of a scan line
// start once the buffer is free:
//   - the current line's, while it is a box line not yet read (the frame's
//     first line, or a line whose box ran to the end of the line before);
//   - the next line's, once the current line's box pixels are all issued (or
//     from its start on a line that is not a box line).
// The two reads take the slot one at a time (cur_sel), each only at an edge
// where no pixel request waits (so a raised request keeps its address until
// granted): right after a pixel read is granted, the next pixels being in
// the word just read (no stream bubble at 16 bpp and below in scan-line
// order, one per read with CL swap), or while the walk is held (done, no
// credit, or waiting for this very line), in which case the slot is kept
// for the second read. A pair starts only with no cursor read in flight (a
// read of an abandoned frame returns, and is ignored, before a new pair).
// The token of a box pixel issued after the second grant reaches stage B
// after the second word: reads return in grant order, RD_LAT after the grant.
wire             cur_sel;
wire             wcnt;          // the read of the pair to grant (or granted last) is the second
wire             pair;          // the first read is granted, the second not yet
wire             bv;
wire             bt;
wire       [4:0] idx;           // the shape row (column with CL) read
wire       [1:0] c_pend;        // cursor reads granted, not returned
wire             rcnt;          // the next cursor word returned is the second

wire             cgnt     = vgnt_i & cur_sel;
wire             cret     = vrvalid_i & vrtag_i;
wire             pair_end = cgnt & wcnt;
wire       [1:0] c_pend_nxt = c_pend + {1'b0, cgnt} - {1'b0, cret};

// The pixel to issue is a box pixel whose line is not read yet (a flop below)
wire             cur_wait;
// The walk may issue and raise its own reads (all flops)
wire             walk_free = req_on_i & walk_ok_i & ~cur_wait;
wire             edge_ok   = vgnt_i | ~walk_free;
wire             want_cur = ln_cur & ~c_fin & ~bv & ~pair;
wire             want_nxt = c_fin & nxt_box & ~bv & ~pair;
wire             f_go     = ~load_i & ~cur_sel & (c_pend == 2'd0) & (want_cur | want_nxt) & edge_ok;
wire             f_w1     = ~load_i & ~cur_sel & pair & edge_ok;
wire             keep     = cgnt & ~wcnt & ~walk_free;        // the first read granted, the walk held
// From the load: the first line's reads when the frame's first pixel is a box pixel
wire             st0      = ln0_cur & pre_in_z & (c_pend_nxt == 2'd0);
wire             f_start  = load_i ? st0 : f_go;

// Shape line read: the current line's (lc), or the next line's
wire       [4:0] lc_nxt_ln = line_again_i ? lc : lc_nxt_src;
wire       [4:0] idx_scan  = load_i ? k_ln : want_nxt ? lc_nxt_ln : lc;
wire       [4:0] idx_nxt   = rev_ln ? ~idx_scan : idx_scan;

wire             cur_sel_nxt = load_i ? st0 : cur_sel ? (~cgnt | keep) : (f_go | f_w1);
wire             bv_clr      = bv & ~bt & (fin_box | ev_l);
wire             bv_en       = load_i | pair_end | bv_clr;
wire             bv_nxt      = ~load_i & pair_end;
wire             bt_en       = load_i | ev_l | f_go;
wire             bt_nxt      = ~load_i & ~ev_l & want_nxt;
wire             wcnt_en     = f_start | cgnt;
wire             wcnt_nxt    = ~f_start;
wire             pair_en     = load_i | f_start | cgnt;
wire             pair_nxt    = ~load_i & ~f_start & ~wcnt;
wire             rcnt_en     = f_start | cret;
wire             rcnt_nxt    = ~f_start & ~rcnt;

// cur_wait = in_box & ~(bv & ~bt) (the box pixel's line not granted yet),
// registered from the next state of its terms:
// one flop in front of the walker's issue
wire             started_q = ipre_en  ? started_nxt : started;
wire             c_fin_q   = c_fin_en ? c_fin_nxt   : c_fin;
wire             bv_q      = bv_en    ? bv_nxt      : bv;
wire             bt_q      = bt_en    ? bt_nxt      : bt;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_cur_wait (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
             .d_i(started_q & ~c_fin_q & ~(bv_q & ~bt_q)), .q_o(cur_wait));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_cur_sel (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),     .d_i(cur_sel_nxt), .q_o(cur_sel));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_wcnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wcnt_en),  .d_i(wcnt_nxt),    .q_o(wcnt));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_pair (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(pair_en),  .d_i(pair_nxt),    .q_o(pair));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_bv (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(bv_en),    .d_i(bv_nxt),      .q_o(bv));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_bt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(bt_en),    .d_i(bt_nxt),      .q_o(bt));
arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_idx (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(f_start),  .d_i(idx_nxt),     .q_o(idx));
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_c_pend (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),     .d_i(c_pend_nxt),  .q_o(c_pend));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rcnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rcnt_en),  .d_i(rcnt_nxt),    .q_o(rcnt));

// Word address: the 128-word block, the column copy with CL, the line, and
// the word: the second (pixels 16-31) first when the box is reversed along
// the scan line, so that the buffer fills in scan order
wire      [31:0] blk_32   = {{(32-VRAM_AW){1'b0}}, cfg_addr};
wire      [31:0] cur_wa   = blk_32 | {25'h000_0000, cfg_cl, idx, wcnt ^ rev_in};

assign cur_sel_o  = cur_sel;
assign cur_req_o  = req_on_i & cur_sel;
assign cur_addr_o = cur_wa[VRAM_AW-1:0];
assign cur_in_o   = in_box;
assign cur_wait_o = cur_wait;

//=============================================================================
// 4) LINE BUFFER AND STAGE B
//=============================================================================
// Loaded in scan order: the first word returned at [31:0], the second at
// [63:32], each with its 2-bit pixels reversed when the box is reversed along
// the scan line. A box token takes the code at pixel k_in (the box pixels
// before the scan start skipped) and, when the walk moves to the next source
// pixel, shifts the buffer by one pixel: past the box the code reads 0.
wire      [31:0] rd_rev;
genvar           pi;
generate
    for (pi = 0; pi < 16; pi = pi + 1) begin : g_rev
        assign rd_rev[2*pi +: 2] = vrdata_i[2*(15-pi) +: 2];
    end
endgenerate
wire      [31:0] rd_scan  = rev_in ? rd_rev : vrdata_i;

wire      [63:0] lbuf;
wire             b_shift  = b_push_i & b_cur_i & b_cstep_i;
wire      [63:0] lbuf_nxt = cret ? (rcnt ? {rd_scan, lbuf[31:0]} : {lbuf[63:32], rd_scan}) :
                                   {2'b00, lbuf[63:2]};
arv_ipdff #(.WIDTH(64), .ARST_EN(ASYNC_RST_EN)) u_lbuf (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cret | b_shift), .d_i(lbuf_nxt), .q_o(lbuf));

// The code at pixel k_in: a static select (k_in is latched for the frame)
wire       [1:0] tap      = lbuf[{k_in, 1'b0} +: 2];
assign code_o = {2{b_cur_i}} & tap;

//=============================================================================
// LINT CLEANUP
//=============================================================================
wire      [31:0] cur_wa_unused   = cur_wa;
wire      [67:0] cmp_unused      = {s_in_p31[16:0], s_ln_p31[16:0], s_in_ml[16:0], s_ln_ml[16:0]};
wire      [25:0] neg_unused      = {s_in_neg[17:5], s_ln_neg[17:5]};

endmodule // blns_bk_cursor

`default_nettype wire
