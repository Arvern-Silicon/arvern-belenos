//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dpi_bdi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dpi_bdi.v
// Module Description : BDI side of the DPI driver (hclk_i): takes one frame
//                      per panel frame from the backend's pixel stream into
//                      the line buffers, with the bank handover (per-bank fill
//                      toggles, released by the pixel domain, and the bank
//                      tags {epoch, line} stable while full), drops the
//                      rest of a frame once the pixel domain needs no
//                      later line of it (image done), and sends the
//                      stream's frame size to the pixel domain.
//----------------------------------------------------------------------------
`default_nettype none
module  blns_dpi_bdi #(
    parameter                 DIM_W        = 10,    // width/height field width
    parameter                 LB_AW        = 10,    // line-buffer address width (DPI_LB_AW)
    parameter                 NB           = 2,     // line-buffer banks
    parameter                 ARST_EN      = 1      // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,
    input  wire               hresetn_i,
// BDI
    input  wire               px_valid_i,           // pixel available
    input  wire        [23:0] px_data_i,            // pixel (RGB888)
    input  wire               px_last_i,            // final pixel of the frame
    output wire               px_ready_o,           // pixel taken
    output wire               active_o,             // taking a frame (refresh_active)
    input  wire   [DIM_W-1:0] width_i,              // DISP_SIZE width
    input  wire   [DIM_W-1:0] height_i,             // DISP_SIZE height
    input  wire               cl_swap_i,            // DISP_CFG.CL_SWAP: the stream's lines are frame columns
    input  wire   [DIM_W-1:0] line_len_m1_i,        // line length - 1 of the frame being taken (from flops)
// Run control and events (blns_dpi_regs)
    input  wire               pix_en_i,             // the pixel domain runs
    input  wire               run_h_i,              // panel timing running (synchronised)
    input  wire               prst_h_i,             // 0: a reset of the pixel domain alone is (or was just) seen
    input  wire               fs_evt_i,             // a frame started (one cycle)
    input  wire               dn_evt_i,             // image done: no later line of the frame is needed (one cycle)
    input  wire               epoch_i,              // frame-start toggle: the frame's epoch
    output wire               abandon_o,            // a frame still being taken was abandoned
// Crossings (blns_dpi_cdc)
    output wire               sz_req_o,             // frame-size request toggle
    output wire   [DIM_W-1:0] sz_w_o,               // frame size (stable while requested)
    output wire   [DIM_W-1:0] sz_h_o,
    input  wire               sz_ack_i,             // frame-size acknowledge toggle (synchronised)
    output wire      [NB-1:0] fill_o,               // bank fill toggles
    input  wire      [NB-1:0] rel_i,                // bank release toggles (synchronised)
    output wire[NB*(DIM_W+1)-1:0] tag_o,            // bank tags {epoch, line} (stable while full)
// Line-buffer writes
    output wire      [NB-1:0] lb_we_o,
    output wire   [LB_AW-1:0] lb_waddr_o,
    output wire        [23:0] lb_wdata_o
);

localparam             TW       = DIM_W + 1;        // bank tag {epoch, line}

wire          [DIM_W-1:0] fsz_w;
wire          [DIM_W-1:0] fsz_h;
wire                      sz_send;
wire                      sz_rs;                // the size is sent again
wire                      sz_rs_set;
wire                      active;
wire                      active_nxt;
wire                [1:0] ab_cnt;               // gap before the next frame
wire                      ab_hold;
wire                      abandon;
wire                      fs_q;                 // a frame started last cycle
wire                      fwait;                // a frame start found this frame neither done nor complete
wire                      fwait_nxt;
wire                      drn;                  // dropping the rest of the frame (image done)
wire                      drn_nxt;
wire                      dn_acc;               // an image done event for this frame
wire                      spend;                // a frame start waits for the dropped frame to end
wire                      spend_nxt;
wire                      fin;                  // the frame's last pixel is taken
wire                      px_acc;               // a pixel taken (handshake)
wire          [DIM_W-1:0] wx;
wire          [DIM_W-1:0] wl;
wire             [NB-1:0] wb;                   // bank of the line being written (one-hot)
wire             [NB-1:0] wb_pick;              // lowest empty bank
wire             [NB-1:0] wsel;                 // bank of the pixel
wire                      wx_first;
wire                      px_take;              // a pixel taken into the line buffers
wire                      x_last;
wire             [NB-1:0] fill;
wire             [NB-1:0] full_h;
wire                      bank_free;

//=============================================================================
// 1)  FRAME SIZE
//=============================================================================
// The line length and count of the stream (transposed with CL_SWAP), sent to
// the pixel domain when they change, for the placement of the next frames,
// and again while the pixel domain starts (DPI_EN set, or a reset of the
// pixel domain alone, which clears its copy and its acknowledge, however
// short: prst_h_i): the toggle handshake is level-based, so a send made while
// the pixel domain does not run is taken when it starts. Nothing is sent
// while prst_h_i is low: the acknowledge seen here is then the one the pixel
// domain has (its reset value or a later one), not the one before the reset

assign fsz_w     = cl_swap_i ? height_i : width_i;
assign fsz_h     = cl_swap_i ? width_i  : height_i;
assign sz_send   = prst_h_i & (sz_req_o == sz_ack_i) & ((fsz_w != sz_w_o) | (fsz_h != sz_h_o) | sz_rs);
assign sz_rs_set = pix_en_i & ~(run_h_i & prst_h_i);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sz_rs (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sz_rs_set | sz_send), .d_i(sz_rs_set), .q_o(sz_rs));

wire        [2*DIM_W:0] sz_nxt = {~sz_req_o, fsz_w, fsz_h};

arv_ipdff #(.WIDTH(2*DIM_W+1), .ARST_EN(ARST_EN)) u_sz (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sz_send), .d_i(sz_nxt), .q_o({sz_req_o, sz_w_o, sz_h_o}));

//=============================================================================
// 2)  ONE FRAME PER PANEL FRAME INTO THE LINE BUFFERS
//=============================================================================
// At each frame start the driver takes a frame (refresh_active). Once the
// pixel domain needs no later line of the frame being taken (image done), the
// rest of that frame is taken and dropped: no line-buffer write, no bank
// handed over, the stream taken at once. A frame start that finds the frame
// still being taken waits for it to end when it is dropped (the next frame is
// then taken two cycles after its last pixel); otherwise the frame is
// abandoned: refresh_active low for two cycles, which flushes the backend.
// The image done event of a frame comes before or with its frame start, but
// crosses on its own synchroniser bit, so it may be seen one cycle after it:
// the frame start is decided one cycle later (fwait), and an image done event
// in the cycle after a frame start that started a frame is the old one's.
// No pixel is taken in either cycle. A line goes to the lowest empty bank,
// picked with its first pixel; the bank's tag {epoch, L} is written with that
// pixel and the bank is handed over with the last.

assign fin        = px_acc & px_last_i;
assign fwait_nxt  = fs_evt_i & pix_en_i & active & ~drn & ~dn_evt_i;
assign dn_acc     = dn_evt_i & active & ~(fs_q & ~fwait);
assign abandon    = fwait & pix_en_i & ~dn_evt_i;
assign ab_hold    = (ab_cnt != 2'd0);
assign active_nxt = (fs_evt_i & pix_en_i & ~active) | (ab_cnt == 2'd1) |
                    (active & ~fin & pix_en_i & ~abandon);
assign drn_nxt    = pix_en_i & active & ~fin & ~abandon & (drn | dn_acc);
assign spend_nxt  = pix_en_i & ~fin & (spend | (fs_evt_i & active & (drn | dn_evt_i)) | (fwait & dn_evt_i));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_active (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(active_nxt), .q_o(active));

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_fstate (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({fs_evt_i, fwait_nxt, drn_nxt, spend_nxt}),
    .q_o({fs_q, fwait, drn, spend}));

wire                [1:0] ab_cnt_nxt = ~pix_en_i ? 2'd0 : (abandon | (fin & spend)) ? 2'd2 : ab_cnt - 2'd1;

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_ab_cnt (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(abandon | (fin & spend) | ab_hold | ~pix_en_i),
    .d_i(ab_cnt_nxt), .q_o(ab_cnt));

assign active_o  = active;
assign abandon_o = abandon;

// Line length: the one of the configuration Belenos takes for the frame
// (the last cycle before refresh_active rises): the backend's latched copy
// (blns_bk_fetch line_len_m1, loaded from the same size and CL_SWAP while
// refresh_active = 0), less one

assign full_h     = fill ^ rel_i;
assign wx_first   = (wx == {DIM_W{1'b0}});
assign wb_pick    = ~full_h & ~(~full_h - {{(NB-1){1'b0}}, 1'b1});
assign wsel       = wx_first ? wb_pick : wb;
assign bank_free  = ~wx_first | ~&full_h;
assign px_ready_o = active & ~fs_evt_i & ~fwait & (drn | bank_free);
assign px_acc     = px_valid_i & px_ready_o;
assign px_take    = px_acc & ~drn;
assign x_last     = (wx == line_len_m1_i);

wire                      frm_new = fs_evt_i | ~active;

wire      [2*DIM_W-1:0] wpos_nxt = frm_new ? {2*DIM_W{1'b0}} : x_last ? {{DIM_W{1'b0}}, wl + 1'b1} : {wx + 1'b1, wl};

arv_ipdff #(.WIDTH(2*DIM_W), .ARST_EN(ARST_EN)) u_wpos (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(frm_new | px_take), .d_i(wpos_nxt), .q_o({wx, wl}));

arv_ipdff #(.WIDTH(NB), .ARST_EN(ARST_EN)) u_wb (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(px_take & wx_first), .d_i(wb_pick), .q_o(wb));

// Tags, written with the first pixel of a line; fill toggles with its last
genvar gb;
generate
    for (gb = 0; gb < NB; gb = gb + 1) begin : g_bank
        arv_ipdff #(.WIDTH(TW), .ARST_EN(ARST_EN)) u_tag (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(px_take & wsel[gb] & wx_first),
            .d_i({epoch_i, wl}), .q_o(tag_o[gb*TW +: TW]));
    end
endgenerate

wire             [NB-1:0] fill_nxt = fill ^ wsel;

arv_ipdff #(.WIDTH(NB), .ARST_EN(ARST_EN)) u_fill (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(px_take & x_last), .d_i(fill_nxt), .q_o(fill));

assign fill_o = fill;

// Line-buffer writes (pixels past the buffer are dropped)
wire                      wx_in = (wx >> LB_AW) == {DIM_W{1'b0}};
assign lb_we_o    = {NB{px_take & wx_in}} & wsel;
assign lb_wdata_o = px_data_i;
generate
    if (DIM_W > LB_AW) begin : g_wa_trunc
        assign lb_waddr_o = wx[LB_AW-1:0];
        wire   [DIM_W-LB_AW-1:0] wx_unused = wx[DIM_W-1:LB_AW];
    end else if (DIM_W == LB_AW) begin : g_wa_full
        assign lb_waddr_o = wx;
    end else begin : g_wa_ext
        assign lb_waddr_o = {{(LB_AW-DIM_W){1'b0}}, wx};
    end
endgenerate

endmodule // blns_dpi_bdi

`default_nettype wire
