//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_bk_color
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_bk_color.v
// Module Description : Backend colour stage of a LUT_EN build. Pops raw pixel values and
//                      converts them to RGB888 one cycle later, through the hardware
//                      colour (blns_bk_hwcol) or a programmable-LUT read {bank, value};
//                      a hardware-cursor code replaces the result by its colour.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_bk_color #(
    parameter             ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire           hclk_i,              // clock
    input  wire           hresetn_i,           // active-low reset (style per ASYNC_RST_EN)

// CONTROL
    input  wire           flush_i,             // not running: drop everything
    input  wire           slot_ok_i,           // output queue can take one more pixel

// RAW PIXEL INPUT (head of the raw FIFO)
    input  wire           raw_valid_i,         // the raw FIFO holds a pixel
    input  wire    [15:0] raw_i,               // its value (zero-extended)
    input  wire     [1:0] raw_code_i,          // its cursor code (0 = none)
    input  wire           raw_last_i,          // it is the frame's last
    output wire           raw_pop_o,           // the head is taken

// LATCHED FRAME CONFIGURATION
    input  wire     [4:0] bpp_1hot_i,          // {16, 8, 4, 2, 1} bpp
    input  wire           sw_lut_en_i,         // LUT_CFG.SW_LUT_EN
    input  wire           bank_i,              // LUT bank (0 with one bank)
    input  wire     [2:0] hw_palette_i,        // LUT_CFG.HW_PALETTE
    input  wire     [3:0] hw_bg_i,             // LUT_CFG.HW_BG
    input  wire     [3:0] hw_fg_i,             // LUT_CFG.HW_FG
    input  wire     [7:0] rot_first_i,         // LUT_ROT FIRST
    input  wire     [7:0] rot_last_i,          // LUT_ROT LAST
    input  wire     [7:0] rot_ofs_i,           // LUT_ROT OFFSET
    input  wire     [7:0] rot_wofs_i,          // OFFSET - (LAST - FIRST + 1), modulo 256
    input  wire     [8:0] rot_lim_i,           // LAST - OFFSET, two's complement
    input  wire    [23:0] cur_col1_i,          // cursor colours 1-3 (live)
    input  wire    [23:0] cur_col2_i,
    input  wire    [23:0] cur_col3_i,

// LUT REQUESTER (blns_lut: request held until granted, read data valid
// exactly one cycle after the grant)
    input  wire           req_on_i,            // the request may be raised (a flop: the second
                                               // and later cycles of a frame, and the falling one)
    input  wire           raw_valid_nxt_i,     // next cycle's raw_valid_i
    input  wire           slot_ok_nxt_i,       // next cycle's slot_ok_i
    input  wire           req_on_nxt_i,        // next cycle's req_on_i
    output wire           lreq_o,              // read request, from flops only
    output wire           lreq_nxt_o,          // next cycle's lreq_o
    output wire     [8:0] laddr_o,             // address {bank, index}
    input  wire           lgnt_i,              // grant (same cycle)
    input  wire           lrvalid_i,           // read data valid (one cycle after the grant)
    input  wire    [23:0] lrdata_i,            // read data (RGB888)

// RGB888 OUTPUT
    output wire           px_held_o,           // stage C holds a pixel (a flop)
    output wire           px_push_o,           // a pixel for the output queue
    output wire    [23:0] px_rgb_o,            // its colour
    output wire           px_last_o            // it is the frame's last
);

//=============================================================================
// 1) POP CONTROL AND LUT REQUEST
//=============================================================================
wire       lut_mode  = sw_lut_en_i & ~bpp_1hot_i[4];   // not at 16 bpp
// The pop needs a running frame (flush_i, combinational from the driver's
// refresh_active); the LUT request a flop instead (req_on_i, slot_ok_i), so
// that the LUT arbiter, and the macro controls behind it, see flops only. In the cycle a frame ends the request may be granted without a
// pop: that read is wasted (lrvalid_i with no LUT pixel in stage C).
wire       pop_ok    = raw_valid_i & slot_ok_i & ~flush_i;
wire       raw_pop   = pop_ok & (~lut_mode | lgnt_i);

// Palette rotation: a value in [FIRST, LAST] is moved by OFFSET inside the range
// (v + OFFSET, less the range length past LAST). The terms that depend on the
// configuration only come precomputed with it, so the compares and the adds
// run side by side: v + OFFSET > LAST is v > LAST - OFFSET.
wire [7:0] rot_v   = raw_i[7:0];
wire       rot_in  = (rot_v >= rot_first_i) & (rot_v <= rot_last_i);
wire [7:0] rot_sum = rot_v + rot_ofs_i;
wire [7:0] rot_wrp = rot_v + rot_wofs_i;
wire       rot_ovf = rot_lim_i[8] | (rot_v > rot_lim_i[7:0]);
wire [7:0] lidx    = ({8{ rot_in &  rot_ovf}} & rot_wrp) |
                     ({8{ rot_in & ~rot_ovf}} & rot_sum) |
                     ({8{~rot_in           }} & rot_v  );

assign lreq_o    = raw_valid_i & slot_ok_i & req_on_i & lut_mode;
// The request one cycle ahead, for the register port's registered HREADYOUT
// (blns_lut). lut_mode is the next cycle's too whenever it matters: the
// latched configuration loads only while req_on_nxt_i is low.
assign lreq_nxt_o = raw_valid_nxt_i & slot_ok_nxt_i & req_on_nxt_i & lut_mode;
assign laddr_o   = {bank_i, lidx};
assign raw_pop_o = raw_pop;

//=============================================================================
// 2) STAGE C REGISTER
//=============================================================================
wire        c_valid;
wire        c_lut;
wire [15:0] c_raw;
wire  [1:0] c_code;
wire        c_last;

arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_c_valid (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),    .d_i(raw_pop),               .q_o(c_valid));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_c_lut (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),    .d_i(raw_pop & lut_mode),    .q_o(c_lut));
arv_ipdff #(.WIDTH(19), .ARST_EN(ASYNC_RST_EN)) u_c_tok (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(raw_pop), .d_i({raw_last_i, raw_code_i, raw_i}),
             .q_o({c_last, c_code, c_raw}));

//=============================================================================
// 3) HARDWARE COLOUR
//=============================================================================
wire [23:0] hw_888;

blns_bk_hwcol blns_bk_hwcol_inst (
// PIXEL
    .raw_i        ( c_raw         ),
// LATCHED FRAME CONFIGURATION
    .bpp_1hot_i   ( bpp_1hot_i    ),
    .hw_palette_i ( hw_palette_i  ),
    .hw_bg_i      ( hw_bg_i       ),
    .hw_fg_i      ( hw_fg_i       ),
// COLOUR
    .rgb_o        ( hw_888        )
);

//=============================================================================
// 4) OUTPUT
//=============================================================================
assign px_held_o = c_valid;
assign px_push_o = c_valid & ~flush_i;
// A LUT pixel in stage C meets its LUT read data valid (the one-cycle LUT
// latency: checked in the formal harness, not masked here); a lrvalid_i
// without one is a read wasted at the end of a frame
// The cursor colour replaces the pixel's: the LUT read of the pixel under it
// is made all the same (code 0: transparent)
wire [23:0] px_888 = c_lut ? lrdata_i : hw_888;
assign px_rgb_o  = ({24{c_code == 2'd0}} & px_888    ) |
                   ({24{c_code == 2'd1}} & cur_col1_i) |
                   ({24{c_code == 2'd2}} & cur_col2_i) |
                   ({24{c_code == 2'd3}} & cur_col3_i);
wire       lrvalid_unused = lrvalid_i;
assign px_last_o = c_last;


endmodule // blns_bk_color

`default_nettype wire
