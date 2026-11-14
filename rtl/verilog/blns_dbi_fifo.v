//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dbi_fifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dbi_fifo.v
// Module Description : DBI driver parameter FIFO (16 entries x 16 bits, or x 8 bits
//                      when no PHY sends a parameter's [15:8]: the SPI PHY alone).
//                      A push while full and a pop while empty are ignored; push
//                      and pop may happen in the same cycle.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_dbi_fifo #(
    parameter             DW           = 16,   // stored bits per entry (16, or 8: head_o[15:8] reads 0)
    parameter             ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire           hclk_i,              // clock
    input  wire           hresetn_i,           // active-low reset (style per ASYNC_RST_EN)

// PUSH / POP
    input  wire           push_i,              // write push_data_i
    input  wire    [15:0] push_data_i,         // entry written
    input  wire           pop_i,               // drop the head entry
    output wire    [15:0] head_o,              // oldest entry (valid when not empty)

// STATUS
    output wire     [4:0] level_o,             // number of entries (0..16)
    output wire           full_o,              // 16 entries
    output wire           empty_o              // no entry
);

//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

wire                [3:0] wr_ptr;
wire                [3:0] rd_ptr;
wire                [4:0] level;
wire                      push_ok;
wire                      pop_ok;
wire                [3:0] wr_ptr_nxt;
wire                [3:0] rd_ptr_nxt;
wire                [4:0] level_nxt;
wire                      level_en;

//=============================================================================
// 2)  POINTERS AND LEVEL
//=============================================================================

assign full_o     = level[4];
assign empty_o    = (level == 5'd0);
assign level_o    = level;

assign push_ok    = push_i & ~level[4];
assign pop_ok     = pop_i  & ~empty_o;

assign wr_ptr_nxt = wr_ptr + 4'd1;
assign rd_ptr_nxt = rd_ptr + 4'd1;

// Priority: push only > pop only (push & pop together keep the level)
assign level_en   = push_ok ^ pop_ok;
assign level_nxt  = push_ok ? (level + 5'd1) :
                              (level - 5'd1) ;

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_wr_ptr (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(push_ok),  .d_i(wr_ptr_nxt), .q_o(wr_ptr));

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_rd_ptr (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(pop_ok),   .d_i(rd_ptr_nxt), .q_o(rd_ptr));

arv_ipdff #(.WIDTH(5), .ARST_EN(ASYNC_RST_EN)) u_level (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(level_en), .d_i(level_nxt),  .q_o(level));

//=============================================================================
// 3)  STORAGE
//=============================================================================
// No reset, as the GPU command FIFO (blns_gpu_fifo): an entry is written
// before it is read, and the head reads 0 while the FIFO is empty.
// DW = 8: only [7:0] of an entry is stored, [15:8] reads 0 (zero-extended
// through a 32-bit word: no zero-width replication at DW = 16)

wire             [DW-1:0] push_data = push_data_i[DW-1:0];
reg              [DW-1:0] mem [0:15];

always @(posedge hclk_i) begin
    if (push_ok) mem[wr_ptr] <= push_data;
end

wire             [DW-1:0] head    = {DW{~empty_o}} & mem[rd_ptr];
wire               [31:0] head_32 = {{(32-DW){1'b0}}, head};
assign head_o = head_32[15:0];

wire               [15:0] head_32_unused = head_32[31:16];
generate
    if (DW < 16) begin : g_narrow
        wire   [15-DW:0] push_data_unused = push_data_i[15:DW];
    end
endgenerate

endmodule // blns_dbi_fifo

`default_nettype wire
