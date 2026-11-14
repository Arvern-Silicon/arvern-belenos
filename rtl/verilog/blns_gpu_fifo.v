//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_fifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_fifo.v
// Module Description : GPU command FIFO: 2^AW x 32-bit words in a memory
//                      array without reset (LUT RAM on FPGA, flops on ASIC),
//                      combinational head read, 0 while empty.
//                      A push to a full FIFO is dropped (even with a pop in the
//                      same cycle); flush empties it and wins over push / pop.
//                      TAG_W tag bits stored with each word (the GPU's
//                      discard marker and immediate source data), read with
//                      the head.
//                      EMPTY and FULL are registered with the count: the
//                      head gate and the decoder's paths start at a flop.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_fifo #(
    parameter            DEPTH        = 8,    // entries (2^AW)
    parameter            AW           = 3,    // log2(DEPTH)
    parameter            TAG_W        = 1,    // tag bits per word (1..2)
    parameter            ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire          hclk_i,              // clock
    input  wire          hresetn_i,           // active-low reset

// CONTROL
    input  wire          flush_i,             // empty the FIFO (wins over push / pop)
    input  wire          push_i,              // write wdata_i (ignored when full)
    input  wire   [31:0] wdata_i,             // word to push
    input  wire [TAG_W-1:0] wtag_i,           // its tag bits
    input  wire          pop_i,               // drop the head (only when not empty)

// STATUS
    output wire   [31:0] head_o,              // word at the head (valid when not empty)
    output wire [TAG_W-1:0] head_tag_o,       // its tag (0 while empty)
    output wire          empty_o,             // no word
    output wire          full_o,              // DEPTH words
    output wire   [AW:0] count_o              // number of words
);

//=============================================================================
// 0)  PARAMETER CHECK
//=============================================================================
// pragma translate_off
generate
    if ((AW < 1) || (DEPTH != (1 << AW))) begin : CHECK_DEPTH
        initial $fatal(1, "blns_gpu_fifo: DEPTH (%0d) must be 2^AW (AW %0d >= 1).", DEPTH, AW);
    end
    if ((TAG_W < 1) || (TAG_W > 2)) begin : CHECK_TAG_W
        initial $fatal(1, "blns_gpu_fifo: TAG_W (%0d) must be 1..2.", TAG_W);
    end
endgenerate
// pragma translate_on

//=============================================================================
// 1)  POINTERS AND COUNT
//=============================================================================
localparam [31:0] DEPTH_32  = DEPTH;
localparam [AW:0] DEPTH_CNT = DEPTH_32[AW:0];
localparam [AW:0] DEPTH_M1  = DEPTH_CNT - {{AW{1'b0}}, 1'b1};

wire   [AW-1:0] wr_ptr;
wire   [AW-1:0] rd_ptr;
wire     [AW:0] count;
wire            full;                                // count == DEPTH (registered)
wire            empty;                               // count == 0 (registered)

wire            push_ok  = push_i & ~full;
wire            pop_ok   = pop_i  & ~empty;

// Priority: flush > push/pop
wire            wr_ptr_en  = flush_i | push_ok;
wire   [AW-1:0] wr_ptr_nxt = flush_i ? {AW{1'b0}} : (wr_ptr + {{(AW-1){1'b0}}, 1'b1});

wire            rd_ptr_en  = flush_i | pop_ok;
wire   [AW-1:0] rd_ptr_nxt = flush_i ? {AW{1'b0}} : (rd_ptr + {{(AW-1){1'b0}}, 1'b1});

wire            count_en   = flush_i | (push_ok ^ pop_ok);
wire     [AW:0] count_nxt  = flush_i ? {(AW+1){1'b0}}                    :
                             push_ok ? (count + {{AW{1'b0}}, 1'b1})      :
                                       (count - {{AW{1'b0}}, 1'b1});

arv_ipdff #(.WIDTH(AW), .ARST_EN(ASYNC_RST_EN)) u_wr_ptr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_ptr_en), .d_i(wr_ptr_nxt), .q_o(wr_ptr));

arv_ipdff #(.WIDTH(AW), .ARST_EN(ASYNC_RST_EN)) u_rd_ptr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rd_ptr_en), .d_i(rd_ptr_nxt), .q_o(rd_ptr));

arv_ipdff #(.WIDTH(AW+1), .ARST_EN(ASYNC_RST_EN)) u_count (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(count_en), .d_i(count_nxt), .q_o(count));

// FULL and EMPTY follow the count (same enable): a push reaches DEPTH from
// DEPTH - 1, a pop reaches 0 from 1, a flush empties
wire            full_nxt   = ~flush_i & push_ok & (count == DEPTH_M1);
wire            empty_nxt  =  flush_i | (~push_ok & (count == {{AW{1'b0}}, 1'b1}));
arv_ipdff #(.WIDTH(2), .RST_VAL(2'b01), .ARST_EN(ASYNC_RST_EN)) u_flags (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(count_en), .d_i({full_nxt, empty_nxt}), .q_o({full, empty}));

//=============================================================================
// 2)  STORAGE
//=============================================================================
// No reset, so that an FPGA maps it to LUT RAM: an entry is written before it
// is read, and the head reads 0 while the FIFO is empty.
reg  [31:0] mem [0:DEPTH-1];
wire        mem_wr = push_ok & ~flush_i;

always @(posedge hclk_i) begin
    if (mem_wr) mem[wr_ptr] <= wdata_i;
end

assign head_o  = {32{~empty}} & mem[rd_ptr];

// The tags: [TAG_W-1] the GPU's discard marker, [0] with TAG_W = 2 its
// immediate data (blns_gpu)
reg  [TAG_W-1:0] tag_mem [0:DEPTH-1];

always @(posedge hclk_i) begin
    if (mem_wr) tag_mem[wr_ptr] <= wtag_i;
end

assign head_tag_o = {TAG_W{~empty}} & tag_mem[rd_ptr];

assign empty_o = empty;
assign full_o  = full;
assign count_o = count;

endmodule // blns_gpu_fifo

`default_nettype wire
