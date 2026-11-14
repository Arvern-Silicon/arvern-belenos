//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_lut
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_lut.v
// Module Description : Colour LUT: register-bus window (one RGB888 entry per
//                      word) and LUT-macro arbiter (backend first; a
//                      register-port access waits at most 5 cycles).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_lut #(
    parameter                 LUT_BANKS    = 2,    // LUT banks (1/2)
    parameter                 ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,              // clock
    input  wire               hresetn_i,           // active-low reset

// Register bus (window 0x800-0xFFC)
    input  wire               rb_valid_i,          // transfer pending
    input  wire               rb_sel_i,            // this slave is selected
    input  wire               rb_wr_i,             // 1 = write
    input  wire        [10:2] rb_addr_i,           // {bank, index}
    input  wire        [31:0] rb_wdata_i,          // write data
    output wire        [31:0] rb_rdata_o,          // read data
    output wire               rb_ready_o,          // transfer completes
    input  wire               rb_wr_nxt_i,         // next cycle's rb_wr_i
    input  wire               rb_bank_nxt_i,       // next cycle's rb_addr_i[10]
    output wire               rb_ready_nxt_o,      // next cycle's rb_ready_o, for a transfer then

// Backend (read)
    input  wire               bk_lreq_i,           // request
    input  wire               bk_lreq_nxt_i,       // next cycle's bk_lreq_i
    input  wire         [8:0] bk_laddr_i,          // {bank, index}
    output wire               bk_lgnt_o,           // grant
    output wire               bk_lrvalid_o,        // read data valid

// LUT macro
    output wire               lut_cen_o,           // chip enable (active low)
    output wire               lut_wen_o,           // write enable (active low)
    output wire         [8:0] lut_addr_o,          // address
    output wire        [23:0] lut_din_o,           // write data
    input  wire        [23:0] lut_dout_i           // read data
);


//=============================================================================
// 1)  REGISTER-BUS WINDOW
//=============================================================================

wire                    rb_rd_pend;               // read granted, data due next cycle
wire                    rb_xfer   =  rb_valid_i & rb_sel_i;

// Bank 1 does not exist with a single bank: read as zero, writes ignored.
wire                    rb_hole   =  (LUT_BANKS == 1) & rb_addr_i[10];

wire                    rb_lreq   =  rb_xfer & ~rb_hole & ~rb_rd_pend;
wire                    rb_lgnt;

wire                    rb_rd_pend_nxt = rb_lgnt & ~rb_wr_i;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rb_rd_pend (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(rb_rd_pend_nxt), .q_o(rb_rd_pend));

assign                  rb_ready_o = (rb_xfer & rb_hole)               |
                                     (rb_lgnt & rb_wr_i)               |
                                      rb_rd_pend;
assign                  rb_rdata_o = {8'h00, lut_dout_i & {24{rb_rd_pend}}};


//=============================================================================
// 2)  MACRO ACCESS (backend has priority, bounded for the register port)
//=============================================================================

// The backend has priority, but a register-port access that has lost
// RB_WAIT_MAX cycles in a row takes the next one (rb_first, a flop): a
// display driver that takes a pixel in every cycle (the DPI driver filling a
// line buffer, an exported BDI sink) would otherwise hold the register port
// for a whole line or frame. The backend stalls that one cycle; its pixel
// FIFO absorbs it.
localparam        [2:0] RB_WAIT_MAX = 3'd4;
wire              [2:0] rb_wait;
wire                    rb_first   =  (rb_wait == RB_WAIT_MAX);
wire                    rb_lost    =  rb_lreq & bk_lreq_i & ~rb_first;
wire                    rb_wait_en =  rb_lost | (rb_wait != 3'd0);
wire              [2:0] rb_wait_nxt = rb_lost ? (rb_wait + 3'd1) : 3'd0;
arv_ipdff #(.WIDTH(3), .ARST_EN(ASYNC_RST_EN)) u_rb_wait (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rb_wait_en), .d_i(rb_wait_nxt), .q_o(rb_wait));

assign                  rb_lgnt    =  rb_lreq & (~bk_lreq_i | rb_first);
assign                  bk_lgnt_o  =  bk_lreq_i & ~(rb_lreq & rb_first);

// The ready one cycle ahead, for the register port's registered HREADYOUT
// (blns_ahb_reg qualifies it with the next cycle's transfer to this window):
// the next cycle's terms of rb_ready_o, from this cycle's next state. A read
// is never ready in its first cycle (rb_rd_pend_nxt is 0 when this cycle
// ends a transfer); rb_wait counts on only while an access loses.
wire                    rb_first_nxt   =  rb_lost & (rb_wait == (RB_WAIT_MAX - 3'd1));
wire                    rb_hole_nxt    =  (LUT_BANKS == 1) & rb_bank_nxt_i;
assign                  rb_ready_nxt_o =   rb_hole_nxt                                       |
                                          (rb_wr_nxt_i & (~bk_lreq_nxt_i | rb_first_nxt))     |
                                           rb_rd_pend_nxt;

wire              [8:0] rb_laddr   = {rb_addr_i[10] & (LUT_BANKS == 2), rb_addr_i[9:2]};

assign                  lut_cen_o  = ~(bk_lgnt_o | rb_lgnt);
assign                  lut_wen_o  = ~(rb_lgnt & rb_wr_i);
assign                  lut_addr_o =  ({9{bk_lgnt_o}} & bk_laddr_i) |
                                      ({9{rb_lgnt  }} & rb_laddr  );
assign                  lut_din_o  =  rb_wdata_i[23:0];

wire                    bk_lrvalid_nxt = bk_lgnt_o;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_bk_lrvalid (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(bk_lrvalid_nxt), .q_o(bk_lrvalid_o));

wire              [7:0] rb_wdata_unused = rb_wdata_i[31:24];
wire                    rb_bank_unused  = rb_bank_nxt_i;   // LUT_BANKS = 2 (no hole above the bank)

endmodule // blns_lut

`default_nettype wire
