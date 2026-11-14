//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_bk_fifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_bk_fifo.v
// Module Description : Backend circular FIFO: flop storage, one-hot AND-OR read mux,
//                      synchronous flush. The writer guarantees no push when full and
//                      the reader no pop when empty.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_bk_fifo #(
    parameter               DW           = 16,    // entry width
    parameter               DEPTH        = 8,     // entries (>= 2)
    parameter               PW           = 3,     // pointer width (2^PW >= DEPTH)
    parameter               CW           = 4,     // count width (2^CW > DEPTH)
    parameter               ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire             hclk_i,
    input  wire             hresetn_i,

// CONTROL
    input  wire             flush_i,              // empty the FIFO (wins over push/pop)
    input  wire             push_i,               // write wdata_i
    input  wire    [DW-1:0] wdata_i,
    input  wire             pop_i,                // drop the head entry

// STATUS / HEAD
    output wire    [DW-1:0] rdata_o,              // head entry (valid when cnt_o != 0)
    output wire    [CW-1:0] cnt_o                 // entries held
);

localparam [31:0]   DEPTH_M1 = DEPTH - 1;
localparam [PW-1:0] PTR_LAST = DEPTH_M1[PW-1:0];

//=============================================================================
// POINTERS AND COUNT
//=============================================================================
wire [PW-1:0] wr_ptr;
wire [PW-1:0] rd_ptr;
wire [CW-1:0] cnt;

wire [PW-1:0] wr_ptr_inc = (wr_ptr == PTR_LAST) ? {PW{1'b0}} : (wr_ptr + {{(PW-1){1'b0}}, 1'b1});
wire [PW-1:0] rd_ptr_inc = (rd_ptr == PTR_LAST) ? {PW{1'b0}} : (rd_ptr + {{(PW-1){1'b0}}, 1'b1});

// Priority: flush > push/pop
wire          wr_ptr_en  = flush_i | push_i;
wire [PW-1:0] wr_ptr_nxt = flush_i ? {PW{1'b0}} : wr_ptr_inc;
wire          rd_ptr_en  = flush_i | pop_i;
wire [PW-1:0] rd_ptr_nxt = flush_i ? {PW{1'b0}} : rd_ptr_inc;
wire          cnt_en     = flush_i | (push_i ^ pop_i);
wire [CW-1:0] cnt_nxt    = flush_i ? {CW{1'b0}}                          :
                           push_i  ? (cnt + {{(CW-1){1'b0}}, 1'b1})      :
                                     (cnt - {{(CW-1){1'b0}}, 1'b1});

arv_ipdff #(.WIDTH(PW), .ARST_EN(ASYNC_RST_EN)) u_wr_ptr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_ptr_en), .d_i(wr_ptr_nxt), .q_o(wr_ptr));
arv_ipdff #(.WIDTH(PW), .ARST_EN(ASYNC_RST_EN)) u_rd_ptr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rd_ptr_en), .d_i(rd_ptr_nxt), .q_o(rd_ptr));
arv_ipdff #(.WIDTH(CW), .ARST_EN(ASYNC_RST_EN)) u_cnt (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cnt_en),    .d_i(cnt_nxt),    .q_o(cnt));

//=============================================================================
// STORAGE AND READ MUX
//=============================================================================
wire [DW-1:0] entry_and [0:DEPTH-1];
wire [DW-1:0] rd_or     [0:DEPTH];
assign rd_or[0] = {DW{1'b0}};

genvar gi;
generate
    for (gi = 0; gi < DEPTH; gi = gi + 1) begin : g_entry
        wire [DW-1:0] entry;
        arv_ipdff #(.WIDTH(DW), .ARST_EN(ASYNC_RST_EN)) u_entry (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i),
                     .en_i (push_i & ~flush_i & (wr_ptr == gi[PW-1:0])),
                     .d_i  (wdata_i),
                     .q_o  (entry));
        assign entry_and[gi] = {DW{rd_ptr == gi[PW-1:0]}} & entry;
        assign rd_or[gi+1]   = rd_or[gi] | entry_and[gi];
    end
endgenerate

assign rdata_o = rd_or[DEPTH];
assign cnt_o   = cnt;

endmodule // blns_bk_fifo

`default_nettype wire
