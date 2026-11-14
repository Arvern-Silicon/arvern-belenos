//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_walk.v
// Module Description : GPU rectangle address walker (one per surface), in pixel
//                      addresses. The walk starts at base_i (the first pixel
//                      visited). Inner step: +-n pixels (X swap = -), or
//                      +-stride with CL swap (Y swap = -). At a line end the
//                      line start moves by +-stride (Y swap = -), or by +-1
//                      with CL swap (X swap = -). Arithmetic wraps modulo
//                      2^PA_W; carry_o flags a forward step crossing 2^PA_W.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_walk #(
    parameter                  PA_W         = 21,   // pixel-address width
    parameter                  ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                hclk_i,              // clock
    input  wire                hresetn_i,           // active-low reset

// CONTROL
    input  wire                init_i,              // load base_i (wins over step_i)
    input  wire   [PA_W-1:0]   base_i,              // first pixel visited
    input  wire                step_i,              // advance
    input  wire          [5:0] step_n_i,            // ... by this many pixels along a run (no CL swap)
    input  wire                line_done_i,         // the pixel being left is the last of its run
    input  wire   [PA_W-1:0]   stride_i,            // surface pitch in pixels
    input  wire                cl_swap_i,           // runs are vertical
    input  wire                y_swap_i,            // lines advance upwards
    input  wire                x_swap_i,            // columns advance leftwards

// ADDRESS
    output wire   [PA_W-1:0]   addr_o,              // current pixel address
    output wire   [PA_W-1:0]   next_line_o,         // first pixel of the next line
    output wire                carry_o              // the step (to addr_o's next value) carries past 2^PA_W
                                                    // (forward steps; a backward one carries unless it wraps)
);

//=============================================================================
// 1)  STEP VALUES
//=============================================================================
localparam [PA_W-1:0] ONE = {{(PA_W-1){1'b0}}, 1'b1};

wire [PA_W+5:0] step_n_w  = {{PA_W{1'b0}}, step_n_i};
wire [PA_W-1:0] step_n    = step_n_w[PA_W-1:0];
wire [PA_W-1:0] inner_mag = cl_swap_i ? stride_i : step_n;
wire            inner_neg = cl_swap_i ? y_swap_i : x_swap_i;
wire [PA_W-1:0] outer_mag = cl_swap_i ? ONE      : stride_i;
wire            outer_neg = cl_swap_i ? x_swap_i : y_swap_i;

// A negative step as the inverted magnitude plus a carry-in (-m = ~m + 1):
// one adder per register, no negate in front of it
wire [PA_W-1:0] inner_opd = inner_mag ^ {PA_W{inner_neg}};
wire [PA_W-1:0] outer_opd = outer_mag ^ {PA_W{outer_neg}};

//=============================================================================
// 2)  REGISTERS
//=============================================================================
wire [PA_W-1:0] addr;
wire [PA_W-1:0] line_addr;

wire   [PA_W:0] next_line_c = {1'b0, line_addr} + {1'b0, outer_opd} + {{PA_W{1'b0}}, outer_neg};
wire   [PA_W:0] next_px_c   = {1'b0, addr}      + {1'b0, inner_opd} + {{PA_W{1'b0}}, inner_neg};
wire [PA_W-1:0] next_line = next_line_c[PA_W-1:0];
wire [PA_W-1:0] next_px   = next_px_c[PA_W-1:0];

// Priority: init > step (line end) > step (inner)
wire            addr_en   = init_i | step_i;
wire [PA_W-1:0] addr_nxt  = init_i      ? base_i    :
                            line_done_i ? next_line :
                                          next_px;

wire            line_en   = init_i | (step_i & line_done_i);
wire [PA_W-1:0] line_nxt  = init_i ? base_i : next_line;

arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_addr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(addr_en), .d_i(addr_nxt), .q_o(addr));

arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_line_addr (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(line_en), .d_i(line_nxt), .q_o(line_addr));

assign addr_o      = addr;
assign next_line_o = next_line;
assign carry_o     = line_done_i ? next_line_c[PA_W] : next_px_c[PA_W];

wire      [5:0] step_n_unused = step_n_w[PA_W+5:PA_W];

endmodule // blns_gpu_walk

`default_nettype wire
