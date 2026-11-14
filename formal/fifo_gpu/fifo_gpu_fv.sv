//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    fifo_gpu_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of blns_gpu_fifo (the GPU command FIFO, DEPTH = 2^AW as
// blns_gpu builds it). Every input is free: a push while full and a pop
// while empty are ignored by the FIFO itself (its documented rule), a flush
// wins over both.
//
// Reference: the number of words (pushes taken minus pops taken since the
// last flush), and one tracked word: a push chosen by the solver (input
// track) is followed with the number of words ahead of it; when none is
// left it must be the head, with its tag, until it is popped.
//----------------------------------------------------------------------------
`default_nettype none
module fifo_gpu_fv #(
    parameter AW           = 3,
    parameter TAG_W        = 2,
    parameter ASYNC_RST_EN = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,
    input  wire        push,
    input  wire [31:0] wdata,
    input  wire [TAG_W-1:0] wtag,
    input  wire        pop,
    input  wire        track
);

localparam      DEPTH = 1 << AW;

wire     [31:0] head;
wire [TAG_W-1:0] head_tag;
wire            empty;
wire            full;
wire     [AW:0] count;

blns_gpu_fifo #(.DEPTH(DEPTH), .AW(AW), .TAG_W(TAG_W), .ASYNC_RST_EN(ASYNC_RST_EN)) u_dut (
    .hclk_i(clk), .hresetn_i(rst_n), .flush_i(flush), .push_i(push), .wdata_i(wdata), .wtag_i(wtag),
    .pop_i(pop), .head_o(head), .head_tag_o(head_tag), .empty_o(empty), .full_o(full), .count_o(count));

always @(*) if ($initstate) assume (!rst_n);

// White-box probes (connected by the driver): pointers and storage, for the
// induction lemmas only
wire     [AW-1:0] p_wr_ptr;
wire     [AW-1:0] p_rd_ptr;
wire [32*DEPTH-1:0] p_mem;                       // word k at [32k +: 32]
wire [TAG_W*DEPTH-1:0] p_tag;                   // tag k at [TAG_W*k +: TAG_W]

// Reference count
reg      [AW+1:0] n;
wire              m_push = push & (n != DEPTH);
wire              m_pop  = pop  & (n != 0);
// Tracked word
reg               t_on;
reg        [31:0] t_data;
reg   [TAG_W-1:0] t_tag;
reg      [AW+1:0] t_ahead;                       // words ahead of it
wire     [AW-1:0] t_slot = p_rd_ptr + t_ahead[AW-1:0];   // its slot

always @(posedge clk)
    if (!rst_n || flush) begin
        n    <= 0;
        t_on <= 1'b0;
    end else begin
        n <= n + m_push - m_pop;
        if (!t_on && m_push && track) begin
            t_on    <= 1'b1;
            t_data  <= wdata;
            t_tag   <= wtag;
            t_ahead <= n - m_pop;
        end else if (t_on && m_pop) begin
            if (t_ahead == 0) t_on <= 1'b0;
            else              t_ahead <= t_ahead - 1'b1;
        end
    end

always @(*)
    if (rst_n) begin
        a_count:     assert (count == n[AW:0]);
        a_no_ovfl:   assert (count <= DEPTH);
        a_full:      assert (full  == (n == DEPTH));
        a_empty:     assert (empty == (n == 0));
        if (empty)   a_head_0:    assert (head == 32'd0 && head_tag == {TAG_W{1'b0}});
        if (t_on && t_ahead == 0) begin
            a_order:     assert (head == t_data);
            a_order_tag: assert (head_tag == t_tag);
        end
        h_ahead:     assert (!t_on || t_ahead < n);
        h_n:         assert (n <= DEPTH);
        h_ptrs:      assert ((p_wr_ptr - p_rd_ptr) == n[AW-1:0]);
        if (t_on) begin
            h_slot:      assert (p_mem[32 * t_slot +: 32] == t_data);
            h_slot_tag:  assert (p_tag[TAG_W * t_slot +: TAG_W] == t_tag);
        end
    end

always @(posedge clk)
    if (rst_n) begin
        c_full:      cover (full && push && pop);
        c_wrap:      cover (t_on && t_ahead == 0 && n == DEPTH && t_data != 32'd0);
        c_flush:     cover (flush && full);
    end

endmodule

`default_nettype wire
