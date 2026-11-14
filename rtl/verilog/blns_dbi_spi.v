//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dbi_spi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dbi_spi.v
// Module Description : MIPI-DBI type C option 3 (4-wire SPI) physical layer.
//                      Mode 0, MSB first, SCK low then high for CLK_DIV+1 cycles each
//                      (SCK = hclk / (2*(CLK_DIV+1))). An item is 8 bits (data[7:0])
//                      or, for a pixel, 16 bits (data[15:0], high byte first); DC is
//                      held for the whole item. CS frames one command: it rises
//                      before a command item that follows other items. CS is held
//                      for one SCK low phase after the last SCK fall, and stays
//                      high for at least one SCK period. The next item is accepted
//                      in the last high cycle of the current one (no gap).
//                      Every pin is driven by a flop. MISO is not used (no
//                      panel read on SPI).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_dbi_spi #(
    parameter             ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire           hclk_i,               // clock
    input  wire           hresetn_i,            // active-low reset (style per ASYNC_RST_EN)

// CONTROL
    input  wire           en_i,                 // PHY selected (pins idle when 0)
    input  wire     [3:0] clk_div_i,            // SCK divider

// ITEM INTERFACE
    input  wire           txn_i,                // transaction open: keep CS low
    input  wire           xfer_valid_i,         // item available
    input  wire           xfer_dc_i,            // D/CX of the item (0 = command)
    input  wire           xfer_px_i,            // 16-bit item (pixel)
    input  wire    [15:0] xfer_data_i,          // item value
    output wire           xfer_ready_o,         // item taken (valid & ready)
    output wire           idle_o,               // CS high, no item in flight

// SPI PANEL
    output wire           spi_sck_o,            // serial clock
    output wire           spi_mosi_o,           // serial data out
    input  wire           spi_miso_i,           // serial data in (not used)
    output wire           spi_cs_n_o,           // chip select
    output wire           spi_dc_o              // data/command
);

//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

wire                      act;             // item in flight
wire                      tail;            // SCK low phase after an item, CS still low
wire                      sck;             // SCK high phase
wire                [4:0] cnt;             // cycles left in the phase / CS-high gap, minus one
wire                [3:0] bit_left;        // bits left after the current one
wire               [15:0] shreg;           // shift register, MSB on MOSI
wire                      cs_n;
wire                      sent;            // an item went out since CS fell

wire                      ph_end;
wire                      item_end;
wire                      cmd_break;
wire                      xfer_ready;
wire                      accept;
wire                      act_nxt;
wire                      tail_nxt;
wire                      cs_rise;
wire                      sck_en;
wire                      sck_nxt;
wire                      cnt_en;
wire                [4:0] cnt_nxt;
wire                      bit_en;
wire                [3:0] bit_nxt;
wire                      sh_en;
wire               [15:0] sh_nxt;
wire                      cs_n_nxt;
wire                      sent_en;
wire                      sent_nxt;
wire                      dc_en;
wire                      dc_nxt;

//=============================================================================
// 2)  BIT SEQUENCER
//=============================================================================

assign ph_end       = (cnt == 5'd0);
assign item_end     = act & sck & ph_end & (bit_left == 4'd0);

// A command item after other items waits for CS to be released first
assign cmd_break    = sent & ~xfer_dc_i;

assign xfer_ready   = en_i & txn_i & ~cs_n & ~cmd_break & (~act | item_end);
assign accept       = xfer_valid_i & xfer_ready;
assign xfer_ready_o = xfer_ready;
assign idle_o       = cs_n & ~act & ~tail;

assign act_nxt      = accept | (act & ~item_end);
assign tail_nxt     = ~accept & ((act & item_end) | (tail & ~ph_end));
assign cs_rise      = cs_n_nxt & ~cs_n;

// Priority: accept (low phase) > phase end (toggle)
assign sck_en       = accept | (act & ph_end) | ~en_i;
assign sck_nxt      = ~accept & act & ~sck & en_i;

// Priority: CS rise (load gap) > accept / phase end (reload divider) > count down
assign cnt_en       = cs_rise | accept | act | tail | (cs_n & ~ph_end);
assign cnt_nxt      = cs_rise                   ? {clk_div_i, 1'b1}       :
                      (accept | (act & ph_end)) ? {1'b0, clk_div_i}       :
                                                  (cnt - 5'd1)            ;

assign bit_en       = accept | (act & sck & ph_end);
assign bit_nxt      = accept ? (xfer_px_i ? 4'd15 : 4'd7) :
                               (bit_left - 4'd1)          ;

// Priority: accept (load) > shift on SCK fall > clear at item end
assign sh_en        = accept | (act & sck & ph_end) | ~en_i;
assign sh_nxt       = (accept & en_i)              ? (xfer_px_i ? xfer_data_i : {xfer_data_i[7:0], 8'h00}) :
                      (en_i & (bit_left != 4'd0))  ? {shreg[14:0], 1'b0}                                   :
                                                     16'h0000                                              ;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_act (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),   .d_i(act_nxt), .q_o(act));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_tail (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),   .d_i(tail_nxt), .q_o(tail));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_sck (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sck_en), .d_i(sck_nxt), .q_o(sck));

arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_cnt (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cnt_en), .d_i(cnt_nxt), .q_o(cnt));

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_bit_left (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(bit_en), .d_i(bit_nxt), .q_o(bit_left));

arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_shreg (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sh_en),  .d_i(sh_nxt),  .q_o(shreg));

//=============================================================================
// 3)  CHIP SELECT AND DC
//=============================================================================

// CS low while the transaction is open (after the CS-high gap) or an item or its
// tail is in flight; released for a command item that follows other items.
assign cs_n_nxt = ~(en_i & (act_nxt | tail_nxt | (txn_i & ~(xfer_valid_i & cmd_break) & (~cs_n | ph_end))));

// Priority: accept (set) > CS high (clear)
assign sent_en  = accept | cs_n;
assign sent_nxt = accept;

assign dc_en    = ~en_i | accept;
assign dc_nxt   = en_i & xfer_dc_i;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_cs_n (   // idle high
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),    .d_i(cs_n_nxt), .q_o(cs_n));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_sent (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sent_en), .d_i(sent_nxt), .q_o(sent));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_dc (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dc_en),   .d_i(dc_nxt),   .q_o(spi_dc_o));

assign spi_cs_n_o = cs_n;
assign spi_sck_o  = sck;
assign spi_mosi_o = shreg[15];

//=============================================================================
// 4)  MISO (unused: the PHY does not read the panel)
//=============================================================================

wire miso_unused = spi_miso_i;

endmodule // blns_dbi_spi

`default_nettype wire
