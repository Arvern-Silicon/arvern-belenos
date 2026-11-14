//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    fifo_bk_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of blns_bk_fifo on its own (the backend FIFO: the raw pixel
// FIFO, read latency + 4 deep (5 to 8), and the RGB888 output queue, 3
// deep). The FIFO has no guard: its documented rule is that the writer never
// pushes when it is full and the reader never pops when it is empty; that
// rule is assumed here, and proved of its users in blns_backend by bk_ctx_fv.
//
// Reference: the count, and one tracked entry with the number ahead of it.
//----------------------------------------------------------------------------
`default_nettype none
module fifo_bk_fv #(
    parameter DEPTH        = 8,
    parameter PW           = 3,
    parameter CW           = 4,
    parameter ASYNC_RST_EN = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,
    input  wire        push,
    input  wire  [7:0] wdata,
    input  wire        pop,
    input  wire        track
);

wire      [7:0] rdata;
wire   [CW-1:0] cnt;

blns_bk_fifo #(.DW(8), .DEPTH(DEPTH), .PW(PW), .CW(CW), .ASYNC_RST_EN(ASYNC_RST_EN)) u_dut (
    .hclk_i(clk), .hresetn_i(rst_n), .flush_i(flush), .push_i(push), .wdata_i(wdata), .pop_i(pop),
    .rdata_o(rdata), .cnt_o(cnt));

// White-box probes (connected by the driver), for the induction lemmas only
wire   [PW-1:0] p_wr_ptr;
wire   [PW-1:0] p_rd_ptr;
wire [8*DEPTH-1:0] p_mem;                        // entry k at [8k +: 8]

reg       [4:0] n;
reg             t_on;
reg       [7:0] t_data;
reg       [4:0] t_ahead;
wire      [5:0] t_sum  = p_rd_ptr + t_ahead;
wire      [5:0] t_slot = (t_sum >= DEPTH) ? t_sum - DEPTH : t_sum;      // t_ahead < DEPTH
wire      [5:0] w_diff = (p_wr_ptr >= p_rd_ptr) ? p_wr_ptr - p_rd_ptr : p_wr_ptr + DEPTH - p_rd_ptr;

always @(*) begin
    if ($initstate) assume (!rst_n);
    if (rst_n && !flush) begin
        assume (!(push && n == DEPTH));                 // the writer: no push when full
        assume (!(pop  && n == 0));                     // the reader: no pop when empty
    end
end

always @(posedge clk)
    if (!rst_n || flush) begin
        n    <= 0;
        t_on <= 1'b0;
    end else begin
        n <= n + push - pop;
        if (!t_on && push && track) begin
            t_on    <= 1'b1;
            t_data  <= wdata;
            t_ahead <= n - pop;
        end else if (t_on && pop) begin
            if (t_ahead == 0) t_on <= 1'b0;
            else              t_ahead <= t_ahead - 1'b1;
        end
    end

always @(*)
    if (rst_n) begin
        a_cnt:     assert (cnt == n[CW-1:0]);
        h_bound:   assert (n <= DEPTH);
        if (t_on && t_ahead == 0) a_order: assert (rdata == t_data);
        h_ahead:   assert (!t_on || t_ahead < n);
        h_ptr_rng: assert (p_wr_ptr < DEPTH && p_rd_ptr < DEPTH);
        h_ptrs:    assert (w_diff == ((n == DEPTH) ? 0 : n));
        if (t_on)  h_slot: assert (p_mem[8 * t_slot +: 8] == t_data);
    end

always @(posedge clk)
    if (rst_n) begin
        c_full:    cover (n == DEPTH && pop && push);
        c_wrap:    cover (t_on && t_ahead == 0 && n == DEPTH);
    end

endmodule

`default_nettype wire
