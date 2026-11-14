//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dbi_8080
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dbi_8080.v
// Module Description : MIPI-DBI type B (8080) 16-bit physical layer.
//                      One item per strobe. Write strobe: WR low CLK_DIV+1 cycles,
//                      high CLK_DIV+1 cycles. Read strobe: RD low 2*RD_DIV+1, high
//                      2*RD_DIV+1 (rd_div_i: DIF_CFG.RD_DIV, or CLK_DIV when it
//                      is 0). A read item first spends one turnaround cycle
//                      with RD high: the data bus is released on the edge that
//                      takes the item, one cycle before RD falls, and stays
//                      released to the end of the read's high phase.
//                      CS is low while txn_i is set or a strobe is in flight. It
//                      leads the first strobe by one write phase: after CS falls
//                      the phase counter runs CLK_DIV+1 cycles before an item is
//                      taken, so the first WR falls CLK_DIV+1 cycles after CS (a
//                      read item first adds its turnaround cycle). The next item is
//                      accepted in the last high cycle of the current strobe, so
//                      back-to-back writes run at 2*(CLK_DIV+1) cycles each.
//                      Every pin is driven by a flop.
//                      Read data: D[7:0] through arv_synchronizer; the value on the
//                      pins at the edge that raises RD is returned on rd_valid_o two
//                      cycles later.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_dbi_8080 #(
    parameter             ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire           hclk_i,               // clock
    input  wire           hresetn_i,            // active-low reset (style per ASYNC_RST_EN)

// CONTROL
    input  wire           en_i,                 // PHY selected (pins idle when 0)
    input  wire     [3:0] clk_div_i,            // write strobe divider
    input  wire     [3:0] rd_div_i,             // read strobe divider

// ITEM INTERFACE
    input  wire           txn_i,                // transaction open: keep CS low
    input  wire           xfer_valid_i,         // item available
    input  wire           xfer_rd_i,            // 1 = read strobe
    input  wire           xfer_dc_i,            // D/CX of the item (0 = command)
    input  wire    [15:0] xfer_data_i,          // bus value of a write item
    output wire           xfer_ready_o,         // item taken (valid & ready)
    output wire           idle_o,               // CS high, no strobe
    output wire           rd_valid_o,           // read data available (1 cycle)
    output wire     [7:0] rd_data_o,            // read data D[7:0]

// 8080 PANEL
    input  wire    [15:0] lcd_d_i,              // data in
    output wire    [15:0] lcd_d_o,              // data out
    output wire           lcd_d_oe_o,           // data output enable
    output wire           lcd_cs_n_o,           // chip select
    output wire           lcd_rd_n_o,           // read strobe
    output wire           lcd_wr_n_o,           // write strobe
    output wire           lcd_dc_o              // data/command
);

//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

wire                      stb_lo;          // strobe low phase
wire                      stb_hi;          // strobe high phase
wire                      stb_rd;          // strobe in flight is a read
wire                      stb_ta;          // read turnaround: bus released, RD still high
wire                [4:0] cnt;             // cycles left in the phase, minus one
wire                      cs_n;
wire                      cap_d1;          // read capture strobe, 1 cycle late
wire                      cap_d2;          // read capture strobe, 2 cycles late
wire                [7:0] d_sync;

wire                      ph_end;
wire                      xfer_ready;
wire                      accept;
wire                [4:0] len_wr;
wire                [4:0] len_rd;
wire                      stb_ta_nxt;
wire                      stb_lo_nxt;
wire                      stb_hi_nxt;
wire                      stb_rd_nxt;
wire                      cs_fall;         // CS falls at the next edge
wire                      cs_lead;         // CS low before the first strobe, lead not yet over
wire                      cnt_en;
wire                [4:0] cnt_nxt;
wire                      cs_n_nxt;
wire                      wr_n_nxt;
wire                      rd_n_nxt;
wire                      rd_sel;
wire                      dc_en;
wire                      dc_nxt;
wire                      d_en;
wire               [15:0] d_nxt;
wire                      oe_nxt;
wire                      cap_nxt;

//=============================================================================
// 2)  STROBE SEQUENCER
//=============================================================================

assign ph_end       = (cnt == 5'd0);
assign len_wr       = {1'b0, clk_div_i};
assign len_rd       = {rd_div_i, 1'b0};

// With no strobe in flight the counter holds 0, except during the CS lead
assign xfer_ready   = en_i & txn_i & ~cs_n & ((~(stb_ta | stb_lo | stb_hi) | stb_hi) & ph_end);
assign accept       = xfer_valid_i & xfer_ready;
assign xfer_ready_o = xfer_ready;
assign idle_o       = cs_n & ~stb_ta & ~stb_lo & ~stb_hi;

// A write item starts its low phase at once; a read item after its turnaround
// cycle (the counter, loaded at the accept, holds through it)
assign stb_ta_nxt   = accept & xfer_rd_i;
assign stb_lo_nxt   = (accept & ~xfer_rd_i) | stb_ta | (stb_lo & ~ph_end);
assign stb_hi_nxt   = (stb_lo & ph_end) | (stb_hi & ~ph_end);
assign stb_rd_nxt   = xfer_rd_i;

// CS lead: CS falling loads one write phase, counted down before the first accept
assign cs_fall      = cs_n & ~cs_n_nxt;
assign cs_lead      = ~cs_n & ~(stb_ta | stb_lo | stb_hi) & ~ph_end;

// Priority: accept (load low phase) > low->high (reload) > CS falling (load the
// lead) > count down to 0 (held there at the end of a high phase)
assign cnt_en       = accept | stb_lo | stb_hi | cs_fall | cs_lead;
assign cnt_nxt      = accept            ? (xfer_rd_i ? len_rd : len_wr) :
                      (stb_lo & ph_end) ? (stb_rd    ? len_rd : len_wr) :
                      cs_fall           ? len_wr                        :
                      ph_end            ? 5'd0                          :
                                          (cnt - 5'd1)                  ;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_stb_ta (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),   .d_i(stb_ta_nxt), .q_o(stb_ta));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_stb_lo (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),   .d_i(stb_lo_nxt), .q_o(stb_lo));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_stb_hi (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),   .d_i(stb_hi_nxt), .q_o(stb_hi));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_stb_rd (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(accept), .d_i(stb_rd_nxt), .q_o(stb_rd));

arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_cnt (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cnt_en), .d_i(cnt_nxt),    .q_o(cnt));

//=============================================================================
// 3)  PIN FLOPS
//=============================================================================

assign rd_sel   = accept ? xfer_rd_i : stb_rd;
assign cs_n_nxt = ~(en_i & (txn_i | stb_ta_nxt | stb_lo_nxt | stb_hi_nxt));
assign wr_n_nxt = ~(stb_lo_nxt & ~rd_sel);
assign rd_n_nxt = ~(stb_lo_nxt &  rd_sel);

// Bus released from the read's turnaround cycle to the end of its high phase;
// idle bus value 0 when deselected
assign oe_nxt   = en_i & ~((stb_ta_nxt | stb_lo_nxt | stb_hi_nxt) & rd_sel);

// Priority: deselect (clear) > accept of a write item (load)
assign dc_en    = ~en_i | accept;
assign dc_nxt   = en_i & xfer_dc_i;
assign d_en     = ~en_i | (accept & ~xfer_rd_i);
assign d_nxt    = {16{en_i}} & xfer_data_i;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_cs_n (   // idle high
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),  .d_i(cs_n_nxt), .q_o(cs_n));

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_wr_n (   // idle high
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),  .d_i(wr_n_nxt), .q_o(lcd_wr_n_o));

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ASYNC_RST_EN)) u_rd_n (   // idle high
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),  .d_i(rd_n_nxt), .q_o(lcd_rd_n_o));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_oe (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),  .d_i(oe_nxt),   .q_o(lcd_d_oe_o));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_dc (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dc_en), .d_i(dc_nxt),   .q_o(lcd_dc_o));

arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_d (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(d_en),  .d_i(d_nxt),    .q_o(lcd_d_o));

assign lcd_cs_n_o = cs_n;

//=============================================================================
// 4)  READ CAPTURE
//=============================================================================

genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_d_sync
        arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ASYNC_RST_EN)) u_d_sync (
            .clk_i   ( hclk_i       ),
            .rst_n_i ( hresetn_i    ),
            .async_i ( lcd_d_i[gi]  ),
            .sync_o  ( d_sync[gi]   )
        );
    end
endgenerate

wire  [7:0] lcd_d_15_8_unused = lcd_d_i[15:8];

// Last low cycle of a read: the next edge raises RD and the first synchroniser
// stage samples the bus; its value reaches d_sync two cycles later.
assign cap_nxt = stb_lo & stb_rd & ph_end;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_cap_d1 (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(cap_nxt), .q_o(cap_d1));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_cap_d2 (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(cap_d1),  .q_o(cap_d2));

assign rd_valid_o = cap_d2;
assign rd_data_o  = d_sync;

endmodule // blns_dbi_8080

`default_nettype wire
