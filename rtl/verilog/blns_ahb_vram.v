//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_ahb_vram
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_ahb_vram.v
// Module Description : Direct video-memory window: AHB-Lite subordinate with
//                      byte / half-word / word access, mapped onto the VRAM
//                      arbiter. A write completes at once: made in its data
//                      phase when granted, else posted in a one-word entry
//                      the window drains first (the next transfer waits
//                      while it is full; wb_pend_o holds the register port
//                      meanwhile, blns_ahb_reg). A read completes when its
//                      data returns, registered here with RD_REG_EN = 0 (one
//                      more cycle). A one-word read-ahead buffer serves a
//                      read with no wait state: it keeps the word last read,
//                      or the next one, read ahead in an idle VRAM cycle, once
//                      a read ends on a word's last byte; any VRAM write to
//                      the word, the window's own at its acceptance, drops it.
//                      HREADYOUT, HRESP and HRDATA come from flops.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_ahb_vram #(
    parameter                 VRAM_AW       = 16,    // VRAM word-address width
    parameter                 VRAM_WORDS    = 38400, // VRAM depth in 32-bit words
    parameter                 PRIV_CHECK_EN = 0,     // deny U-mode accesses
    parameter                 RD_REG_EN     = 0,     // VRAM read data registered in the arbiter (vrdata_i from a flop)
    parameter                 ASYNC_RST_EN  = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,                // clock
    input  wire               hresetn_i,             // active-low reset

// AHB-Lite subordinate
    input  wire               hsel_i,                // select
    input  wire [VRAM_AW+1:0] haddr_i,               // byte address
    input  wire         [1:0] htrans_i,              // transfer type
    input  wire               hwrite_i,              // write
    input  wire         [2:0] hsize_i,               // transfer size
    input  wire         [3:0] hprot_i,               // protection (hprot[1] = privileged)
    input  wire               hsmode_i,              // aRVern S-mode sideband
    input  wire               hready_i,              // bus ready in
    input  wire        [31:0] hwdata_i,              // write data
    output wire        [31:0] hrdata_o,              // read data
    output wire               hreadyout_o,           // ready out
    output wire               hresp_o,               // response (1 = ERROR)
    output wire               active_o,              // address or data phase in progress, a posted write or a read ahead
    output wire               wb_pend_o,             // a posted write not yet made
    output wire               wb_pend_nxt_o,         // next cycle's wb_pend_o

// VRAM requester
    output wire               vreq_o,                // request
    output wire               vwe_o,                 // 1 = write
    output wire         [3:0] vbe_o,                 // byte enables
    output wire [VRAM_AW-1:0] vaddr_o,               // word address
    output wire        [31:0] vwdata_o,              // write data
    input  wire               vgnt_i,                // grant
    input  wire               vrvalid_i,             // read data valid
    input  wire               vrvalid_nxt_i,         // next cycle's vrvalid_i
    input  wire        [31:0] vrdata_i,              // read data (demand and read ahead)

// Read ahead (lowest priority) and the VRAM writes that invalidate it
    output wire               wp_vreq_o,             // request
    output wire [VRAM_AW-1:0] wp_vaddr_o,            // word address
    input  wire               wp_vgnt_i,             // grant
    input  wire               wp_vrvalid_i,          // read data valid
    input  wire               wp_vrvalid_nxt_i,      // next cycle's wp_vrvalid_i
    input  wire               mwr_i,                 // another requester's VRAM write is made this cycle
    input  wire [VRAM_AW-1:0] mwaddr_i               // ... at this word (from a flop: no address mux)
);


//=============================================================================
// 1)  ADDRESS PHASE
//=============================================================================

localparam       [31:0] VRAM_DEPTH = VRAM_WORDS;
localparam        [1:0] HSIZE_BYTE = 2'b00;
localparam        [1:0] HSIZE_HALF = 2'b01;
localparam        [1:0] HSIZE_WORD = 2'b10;

wire                    aph_valid  =  hsel_i & hready_i & htrans_i[1];

wire              [3:0] aph_be     = {((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b11)) | ((hsize_i[1:0]==HSIZE_HALF) & haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD),
                                      ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b10)) | ((hsize_i[1:0]==HSIZE_HALF) & haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD),
                                      ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b01)) | ((hsize_i[1:0]==HSIZE_HALF) & ~haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD),
                                      ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b00)) | ((hsize_i[1:0]==HSIZE_HALF) & ~haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD)};

// ERROR: transfers wider than a word, words beyond the populated depth, and
// U-mode accesses when the privilege check is enabled.
wire                    aph_err    =  hsize_i[2] | (hsize_i[1:0] == 2'b11)                         |
                                      ({{(32-VRAM_AW){1'b0}}, haddr_i[VRAM_AW+1:2]} >= VRAM_DEPTH)  |
                                      ((PRIV_CHECK_EN != 0) & ~hprot_i[1]);


//=============================================================================
// 2)  DATA PHASE
//=============================================================================

// The data phase as in blns_ahb_reg: load on an address phase, clear when the
// bus moves on without one, hold while the bus is stalled.
wire                    dph_en     =  hready_i;

wire                    dph_valid;
wire                    dph_write;
wire                    dph_err;
wire              [3:0] dph_be;
wire      [VRAM_AW-1:0] dph_addr;

arv_ipdff #(.WIDTH(1),       .ARST_EN(ASYNC_RST_EN)) u_dph_valid (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_valid),                              .q_o(dph_valid));
arv_ipdff #(.WIDTH(1),       .ARST_EN(ASYNC_RST_EN)) u_dph_write (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_valid & hwrite_i),                   .q_o(dph_write));
arv_ipdff #(.WIDTH(1),       .ARST_EN(ASYNC_RST_EN)) u_dph_err (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_valid & aph_err),                    .q_o(dph_err));
arv_ipdff #(.WIDTH(4),       .ARST_EN(ASYNC_RST_EN)) u_dph_be (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(aph_be & {4{aph_valid}}),               .q_o(dph_be));
arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_dph_addr (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(haddr_i[VRAM_AW+1:2] & {VRAM_AW{aph_valid}}), .q_o(dph_addr));

// The same flops one cycle ahead (their next state), for the registered
// HREADYOUT
wire                    dph_valid_nxt = dph_en ?  aph_valid            : dph_valid;
wire                    dph_write_nxt = dph_en ? (aph_valid & hwrite_i) : dph_write;
wire                    dph_err_nxt   = dph_en ? (aph_valid & aph_err)  : dph_err;
// The next word and whether it is inside the VRAM, for the read ahead
wire      [VRAM_AW-1:0] aph_nxt    =  haddr_i[VRAM_AW+1:2] + {{(VRAM_AW-1){1'b0}}, 1'b1};
wire                    aph_nxt_ok = ({{(32-VRAM_AW){1'b0}}, haddr_i[VRAM_AW+1:2]} + 32'd1) < VRAM_DEPTH;
wire      [VRAM_AW-1:0] a_nxt;
wire                    a_nxt_ok;
arv_ipdff #(.WIDTH(VRAM_AW+1), .ARST_EN(ASYNC_RST_EN)) u_dph_nxt (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i({aph_valid & aph_nxt_ok, aph_nxt & {VRAM_AW{aph_valid}}}),
                           .q_o({a_nxt_ok, a_nxt}));

// Clock request as in blns_ahb_reg, plus the posted write and the read ahead
// wanted or in flight.
wire                    pb_want;
wire                    pb_fly;
wire                    wb_v;
assign                  active_o   =  (hsel_i & htrans_i[1]) | dph_valid | pb_want | pb_fly | wb_v;


//=============================================================================
// 3)  VRAM ACCESS
//=============================================================================

// Read-ahead buffer: the word at pb_addr (pb_v), or its read to make
// (pb_want) or in flight (pb_fly; pb_stale: retargeted or written meanwhile)
wire                    pb_v;
wire                    pb_stale;
wire      [VRAM_AW-1:0] pb_addr;
wire             [31:0] pb_data;

wire                    rd_wait;                                               // a demand read in flight
wire                    rd_ret;                                                // RD_REG_EN = 0: the read's data landed in pb_data
wire                    xfer       =  dph_valid & ~dph_err;
wire                    rd_xfer    =  xfer & ~dph_write;
wire                    wr_xfer    =  xfer &  dph_write;
wire                    pb_match;                                              // dph_addr == pb_addr
wire                    pb_hit     =  rd_xfer & ~rd_wait & pb_v & pb_match;                          // no wait state
wire                    pb_wait    =  rd_xfer & ~rd_wait & ~pb_v & pb_fly & ~pb_stale & pb_match & ~rd_ret;  // its read ahead returns
wire                    pb_ret     =  wp_vrvalid_i;
wire                    wait_done  =  pb_wait & pb_ret;
wire                    dm_ret     =  rd_wait & vrvalid_i;                     // the demand read's data

// Posted write: a write completes in its data phase while the entry is empty,
// made then when granted, else kept in the entry; a full entry is the
// window's request (host class), the data phase behind it waits.
wire              [3:0] wb_be;
wire      [VRAM_AW-1:0] wb_addr;
wire             [31:0] wb_data;
wire                    wr_acc     =  wr_xfer & ~wb_v;                         // a write completes
wire                    wb_v_nxt   = (wb_v | wr_acc) & ~vgnt_i;

arv_ipdff #(.WIDTH(1),           .ARST_EN(ASYNC_RST_EN)) u_wb_v (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),   .d_i(wb_v_nxt),                     .q_o(wb_v));
arv_ipdff #(.WIDTH(VRAM_AW + 4), .ARST_EN(ASYNC_RST_EN)) u_wb_acc (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_acc), .d_i({dph_addr, dph_be}),           .q_o({wb_addr, wb_be}));
arv_ipdff #(.WIDTH(32),          .ARST_EN(ASYNC_RST_EN)) u_wb_data (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_acc), .d_i(hwdata_i),                     .q_o(wb_data));

assign                  wb_pend_o     =  wb_v;
assign                  wb_pend_nxt_o =  wb_v_nxt;

// A read is granted once, then waits for its data; a read that misses waits
// for the posted write too (the drain is not a read).
wire                    rd_gnt     =  vgnt_i & ~vwe_o;
wire                    rd_wait_nxt = rd_gnt | (rd_wait & ~vrvalid_i);
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_wait (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(rd_wait_nxt), .q_o(rd_wait));

assign                  vreq_o     =  wb_v | wr_xfer | (rd_xfer & ~rd_wait & ~pb_hit & ~pb_wait & ~rd_ret);
assign                  vwe_o      =  wb_v | dph_write;
assign                  vbe_o      =  wb_v ? wb_be   : dph_be;
assign                  vaddr_o    =  wb_v ? wb_addr : dph_addr;
assign                  vwdata_o   =  wb_v ? wb_data : hwdata_i;

// A read completes from the buffer, or from its returning data: in its cycle
// with RD_REG_EN (a flop in the arbiter), else the cycle after it lands in
// pb_data (land, rd_ret).
localparam              RET_REG    = (RD_REG_EN == 0);
wire                    land       =  RET_REG & (wait_done | dm_ret);
wire                    rd_cmp     =  RET_REG ? (pb_hit | rd_ret) : (pb_hit | wait_done | dm_ret);
wire                    rd_ret_nxt =  land;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_ret (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(rd_ret_nxt), .q_o(rd_ret));

// The window's own write drops the buffered word when it completes (posted
// or made: the read ahead is idle-only, so none is granted before the drain)
wire                    own_wr     =  wr_acc & (|dph_be);

// A write to the word while its read is in flight (or as it returns): the
// data read is older, so it is not kept. The window's own write cannot
// overlap its demand read.
wire                    dm_stale;
wire                    dm_whit    =  mwr_i & (mwaddr_i == dph_addr);
wire                    dm_stale_nxt = ~rd_gnt & rd_wait & (dm_stale | dm_whit);
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_dm_stale (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(dm_stale_nxt), .q_o(dm_stale));

// A read that completes keeps its word, or targets the next one when it ends
// on the word's last byte (inside the VRAM): byte and half-word runs hit too.
// With RD_REG_EN = 0 the word is kept as its data lands, the read then
// completing from the buffer.
wire                    rd_done    =  rd_xfer & rd_cmp;
wire                    go_next    =  rd_done & dph_be[3] & a_nxt_ok;
wire                    on_next    =  (pb_addr == a_nxt) & (pb_v | pb_want | (pb_fly & ~pb_stale));
wire                    keep_now   =  RET_REG ? dm_ret : (rd_done & ~go_next & ~pb_hit);   // the word read becomes the buffer's
wire                    retarget   =  (go_next & ~on_next) | keep_now;
// The next word's read leaves in the cycle the read completes, also as the
// previous read ahead returns; pb_want is the request kept for a later cycle
wire                    pb_early   =  go_next & ~on_next & (~pb_fly | pb_ret);
wire                    pb_whit    = (mwr_i  & (mwaddr_i == pb_addr)) |
                                     (own_wr & (dph_addr == pb_addr));

wire                    pb_ret_ok  =  pb_ret & ~pb_stale & ~pb_whit;  // the read ahead lands
// Priority: retarget > the read ahead returns > a write to the word
wire                    pb_v_nxt     =  retarget ? (keep_now & ~(wait_done ? pb_whit : (dm_stale | dm_whit))) :
                                       (pb_v & ~pb_whit) | pb_ret_ok;
wire                    pb_want_nxt  = retarget ? (go_next & ~(pb_early & wp_vgnt_i)) : (pb_want & ~wp_vgnt_i);
wire                    pb_fly_nxt   = wp_vgnt_i | (pb_fly & ~pb_ret);
wire                    pb_stale_nxt = wp_vgnt_i ? (retarget & ~pb_early) : (pb_fly & ~pb_ret & (pb_stale | retarget | pb_whit));
wire      [VRAM_AW-1:0] pb_addr_nxt  = go_next ? a_nxt : dph_addr;
// The data of a read ahead returning unretargeted is taken even when its word
// is written as it lands (not valid then): a read waiting for it returns it
wire                    pb_data_en   = retarget ? keep_now : (pb_ret & ~pb_stale);

// pb_match for the next data phase, compared in the address phase so that
// the request and the ready depend on flops only
wire      [VRAM_AW-1:0] aph_addr     =  haddr_i[VRAM_AW+1:2];
wire                    pb_match_nxt = ~dph_en   ? (~go_next)            :
                                       ~retarget ? (aph_addr == pb_addr) :
                                        go_next  ? (aph_addr == a_nxt)   :
                                                   (aph_addr == dph_addr);
wire                    pb_match_en  =  dph_en | retarget;

arv_ipdff #(.WIDTH(4),       .ARST_EN(ASYNC_RST_EN)) u_pb_flags (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                           .d_i({pb_v_nxt, pb_want_nxt, pb_fly_nxt, pb_stale_nxt}), .q_o({pb_v, pb_want, pb_fly, pb_stale}));
arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_pb_addr (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(retarget), .d_i(pb_addr_nxt), .q_o(pb_addr));
arv_ipdff #(.WIDTH(1),       .ARST_EN(ASYNC_RST_EN)) u_pb_match (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(pb_match_en), .d_i(pb_match_nxt), .q_o(pb_match));
arv_ipdff #(.WIDTH(32),      .ARST_EN(ASYNC_RST_EN)) u_pb_data (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(pb_data_en), .d_i(vrdata_i), .q_o(pb_data));

// One read ahead in flight at most
assign                  wp_vreq_o  = (pb_want & ~pb_fly) | pb_early;
assign                  wp_vaddr_o =  pb_early ? a_nxt : pb_addr;


//=============================================================================
// 4)  RESPONSE
//=============================================================================

// Two-cycle ERROR: HREADYOUT low then high, HRESP high for both cycles.
wire                    error_resp      =  dph_valid & dph_err;
wire                    error_resp_done;
wire                    error_resp_done_nxt = error_resp & ~error_resp_done;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_error_resp_done (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(error_resp_done_nxt), .q_o(error_resp_done));

// HREADYOUT is a flop, loaded with the ready of the next cycle's data phase
// decoded from the next state of the flops that ready depends on (the same
// wait states as a ready decoded in its own cycle): a write while the posted
// entry will be empty, a read served by the buffer, by its data landed
// (RD_REG_EN = 0) or returning (RD_REG_EN = 1: the arbiter's read valid one
// cycle ahead), an ERROR in its second cycle. The grants and read valids
// reach flop inputs only.
wire                    error_resp_nxt = dph_valid_nxt & dph_err_nxt;
wire                    xfer_nxt       = dph_valid_nxt & ~dph_err_nxt;
wire                    pb_match_q_nxt = pb_match_en ? pb_match_nxt : pb_match;
wire                    pb_hit_nxt     = ~rd_wait_nxt & pb_v_nxt & pb_match_q_nxt;
wire                    pb_wait_nxt    = ~rd_wait_nxt & ~pb_v_nxt & pb_fly_nxt & ~pb_stale_nxt & pb_match_q_nxt;
wire                    rd_cmp_nxt     = RET_REG ? (pb_hit_nxt | rd_ret_nxt) :
                                                   (pb_hit_nxt | (pb_wait_nxt & wp_vrvalid_nxt_i) | (rd_wait_nxt & vrvalid_nxt_i));
wire                    done_nxt       = dph_write_nxt ? ~wb_v_nxt : rd_cmp_nxt;
wire                    hready_nxt     = error_resp_nxt ? error_resp_done_nxt : ~(xfer_nxt & ~done_nxt);
wire                    hready_q;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_hready (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(hready_nxt), .q_o(hready_q));

assign                  hreadyout_o =  hready_q;
assign                  hresp_o     =  error_resp;

// Read data: the buffer, or with RD_REG_EN the arbiter's data register,
// selected by a flop (a buffer hit next cycle)
generate
    if (RET_REG) begin : G_RET_REG
        assign          hrdata_o = pb_data;
        wire      [1:0] rvalid_nxt_unused = {vrvalid_nxt_i, wp_vrvalid_nxt_i};
        wire            pb_wait_nxt_unused = pb_wait_nxt;   // (RD_REG_EN = 0: rd_ret_nxt)
    end else begin : G_RET_ARB
        wire            hr_pb;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_hr_pb (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(pb_hit_nxt), .q_o(hr_pb));
        assign          hrdata_o = hr_pb ? pb_data : vrdata_i;
    end
endgenerate

wire                    htrans_unused  = htrans_i[0];
wire              [3:0] hprot_unused   = hprot_i;          // hprot[1] is only read with PRIV_CHECK_EN = 1
wire                    hsmode_unused  = hsmode_i;

endmodule // blns_ahb_vram

`default_nettype wire
