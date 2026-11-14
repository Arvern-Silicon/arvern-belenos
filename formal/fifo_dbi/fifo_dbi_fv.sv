//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    fifo_dbi_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of blns_dbi_fifo (the DBI parameter FIFO, 16 x 16 bits).
// Every input is free: a push while full and a pop while empty are ignored
// (the documented rule: DIF_PARAM to a full FIFO is dropped, PARAM_OVFL),
// push and pop may come together.
//
// Reference: the level (pushes taken minus pops taken), and one tracked
// entry chosen by the solver, followed with the number of entries ahead.
//----------------------------------------------------------------------------
`default_nettype none
module fifo_dbi_fv #(
    parameter ASYNC_RST_EN = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        push,
    input  wire [15:0] wdata,
    input  wire        pop,
    input  wire        track
);

wire     [15:0] head;
wire      [4:0] level;
wire            full;
wire            empty;

blns_dbi_fifo #(.ASYNC_RST_EN(ASYNC_RST_EN)) u_dut (
    .hclk_i(clk), .hresetn_i(rst_n), .push_i(push), .push_data_i(wdata), .pop_i(pop),
    .head_o(head), .level_o(level), .full_o(full), .empty_o(empty));

always @(*) if ($initstate) assume (!rst_n);

// White-box probes (connected by the driver): the pointers and the entries,
// for the induction lemmas only
wire      [3:0] p_wr_ptr;
wire      [3:0] p_rd_ptr;
wire    [255:0] p_mem;                           // entry k at [16k +: 16]
wire      [3:0] t_slot = p_rd_ptr + t_ahead[3:0];  // the tracked entry's slot

reg       [5:0] n;
wire            m_push = push & (n != 16);
wire            m_pop  = pop  & (n != 0);
reg             t_on;
reg      [15:0] t_data;
reg       [5:0] t_ahead;

always @(posedge clk)
    if (!rst_n) begin
        n    <= 0;
        t_on <= 1'b0;
    end else begin
        n <= n + m_push - m_pop;
        if (!t_on && m_push && track) begin
            t_on    <= 1'b1;
            t_data  <= wdata;
            t_ahead <= n - m_pop;
        end else if (t_on && m_pop) begin
            if (t_ahead == 0) t_on <= 1'b0;
            else              t_ahead <= t_ahead - 1'b1;
        end
    end

always @(*)
    if (rst_n) begin
        a_level:     assert (level == n[4:0]);
        a_no_ovfl:   assert (level <= 5'd16);
        a_full:      assert (full  == (n == 16));
        a_empty:     assert (empty == (n == 0));
        if (t_on && t_ahead == 0) a_order: assert (head == t_data);
        h_ahead:     assert (!t_on || t_ahead < n);
        h_n:         assert (n <= 16);
        h_ptrs:      assert ((p_wr_ptr - p_rd_ptr) == n[3:0]);
        if (t_on)    h_slot: assert (p_mem[16 * t_slot +: 16] == t_data);
    end

always @(posedge clk)
    if (rst_n) begin
        c_full_pp:   cover (full && push && pop);
        c_wrap:      cover (t_on && t_ahead == 0 && n == 16);
    end

endmodule

`default_nettype wire
