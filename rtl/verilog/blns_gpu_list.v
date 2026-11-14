//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_list
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_list.v
// Module Description : GPU command-list fetch (CALL): reads N command words
//                      from VRAM into a 2-word buffer that the decoder takes
//                      instead of the FIFO while the list is active. Reads
//                      use the GPU's VRAM port when the DMA does not. A list
//                      lies inside the VRAM (the decoder checks it at the
//                      CALL): the word counter is VRAM_AW + 1 bits (the
//                      words still to read follow from it and the words
//                      buffered or in flight), and the list's activity is a
//                      flop.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_list #(
    parameter                    VRAM_AW      = 16,    // VRAM word-address width
    parameter                    ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,               // clock
    input  wire                  hresetn_i,            // active-low reset

// CONTROL
    input  wire                  flush_i,              // end the list, drop the buffered words
    input  wire                  freeze_i,             // debug freeze: no new read
    input  wire                  start_i,              // CALL operand taken (N > 0)
    input  wire    [VRAM_AW-1:0] start_addr_i,         // list word address
    input  wire           [23:0] start_n_i,            // list length in words (<= VRAM_WORDS: blns_gpu_dec)

// DECODER
    input  wire                  pop_i,                // head word consumed (only while active_o)
    output wire                  active_o,             // words left to consume
    output wire           [31:0] head_o,               // head word
    output wire                  empty_o,              // no word buffered
    output wire                  last_o,               // the head word is the list's last
    output wire    [VRAM_AW-1:0] ptr_o,                // address of the head word (0 when idle)
    output wire                  rd_pend_o,            // a read in flight (also after a flush: its data is dropped)

// VRAM PORT (shared with the DMA, which has priority)
    output wire                  vreq_o,               // read request
    output wire    [VRAM_AW-1:0] vaddr_o,              // word address
    input  wire                  vgnt_i,               // read issued this cycle
    input  wire                  vrvalid_i,            // read data valid (this reader's, in grant order)
    input  wire           [31:0] vrdata_i              // read data
);

//=============================================================================
// 1)  COUNTERS AND ADDRESSES
//=============================================================================
// A list holds at most VRAM_WORDS <= 2^VRAM_AW words (CALL operand check)
localparam           CW = (VRAM_AW < 24) ? (VRAM_AW + 1) : 24;
localparam  [CW-1:0] CW_ONE = {{(CW-1){1'b0}}, 1'b1};

wire        [CW-1:0] start_n    = start_n_i[CW-1:0];
wire        [CW-1:0] cons_left;                     // words still to be consumed
wire                 active;                        // cons_left != 0 (registered)
wire   [VRAM_AW-1:0] head_addr;
wire   [VRAM_AW-1:0] fetch_addr;
wire                 b0_v;
wire                 b1_v;
wire                 rd_pend;                       // a read in flight
wire                 rd_drop;                       // ... cut by a flush: its data is dropped

// Priority: flush > start > step
wire                 cons_en    = flush_i | start_i | pop_i;
wire        [CW-1:0] cons_nxt   = flush_i ? {CW{1'b0}} : start_i ? start_n : (cons_left - CW_ONE);
// Active from the start (N > 0) to the pop of the last word or a flush
wire                 last       = (cons_left == CW_ONE);
wire                 active_nxt = ~flush_i & (start_i | (active & ~(pop_i & last)));
wire   [VRAM_AW-1:0] head_nxt   = start_i ? start_addr_i : (head_addr + {{(VRAM_AW-1){1'b0}}, 1'b1});
wire   [VRAM_AW-1:0] faddr_nxt  = start_i ? start_addr_i : (fetch_addr + {{(VRAM_AW-1){1'b0}}, 1'b1});

arv_ipdff #(.WIDTH(CW), .ARST_EN(ASYNC_RST_EN)) u_cons_left (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cons_en), .d_i(cons_nxt), .q_o(cons_left));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_active (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cons_en), .d_i(active_nxt), .q_o(active));
arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_head_addr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start_i | pop_i), .d_i(head_nxt), .q_o(head_addr));
arv_ipdff #(.WIDTH(VRAM_AW), .ARST_EN(ASYNC_RST_EN)) u_fetch_addr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start_i | vgnt_i), .d_i(faddr_nxt), .q_o(fetch_addr));

//=============================================================================
// 2)  READS
//=============================================================================
// One read in flight at most with one buffered word, or none with two; a new
// read in the cycle the previous one returns at the earliest. Words still to
// be read: the words to consume less those buffered or in flight (not
// dropped); a flush clears both, a start comes with neither. With room, at
// most one word is buffered or in flight (occ)
wire                 room       = ~b1_v & ~(b0_v & rd_pend);
wire                 rd_free    = ~rd_pend | vrvalid_i;
wire                 occ        = b0_v | (rd_pend & ~rd_drop);
assign               vreq_o     = ({1'b0, cons_left} > {{CW{1'b0}}, occ}) & room & rd_free & ~freeze_i;

// A read granted in a flush cycle, or in flight across one, is dropped (the
// flush stays off the request: GPU_CTRL write data never reaches the port)
wire                 rd_pend_nxt = vgnt_i | (rd_pend & ~vrvalid_i);
wire                 rd_drop_nxt = vgnt_i ? flush_i : (rd_pend & ~vrvalid_i & (rd_drop | flush_i));
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_rd_pend (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({rd_drop_nxt, rd_pend_nxt}), .q_o({rd_drop, rd_pend}));

wire                 accept     = vrvalid_i & rd_pend & ~rd_drop & ~flush_i;

//=============================================================================
// 3)  2-WORD BUFFER
//=============================================================================
wire          [31:0] b0_d;
wire          [31:0] b1_d;

wire                 b0_v_nxt   = ~flush_i & (pop_i ? (b1_v | accept) : (b0_v | accept));
wire                 b1_v_nxt   = ~flush_i & (pop_i ? (b1_v & accept) : (b1_v | (accept & b0_v)));
wire                 b0_load    = ~flush_i & (pop_i ? (b1_v | accept) : (accept & ~b0_v));
wire          [31:0] b0_d_nxt   = (pop_i & b1_v) ? b1_d : vrdata_i;
wire                 b1_load    = accept & ((pop_i & b1_v) | (~pop_i & b0_v));

arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_buf_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({b1_v_nxt, b0_v_nxt}), .q_o({b1_v, b0_v}));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_b0_d (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(b0_load), .d_i(b0_d_nxt), .q_o(b0_d));
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_b1_d (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(b1_load), .d_i(vrdata_i), .q_o(b1_d));

//=============================================================================
// 4)  OUTPUTS
//=============================================================================
assign active_o  = active;
assign head_o    = b0_d;
assign empty_o   = ~b0_v;
assign last_o    = last;
assign ptr_o     = {VRAM_AW{active}} & head_addr;
assign vaddr_o   = fetch_addr;
assign rd_pend_o = rd_pend;

//=============================================================================
// 5)  LINT CLEANUP
//=============================================================================
generate
    if (CW < 24) begin : g_n_hi
        wire [23-CW:0] start_n_unused = start_n_i[23:CW];  // a list fits the VRAM
    end
endgenerate

endmodule // blns_gpu_list

`default_nettype wire
