//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    arv_synchronizer (formal model)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal stand-in for arvern-ips arv_primitives/arv_synchronizer (same name,
// parameters and ports; read by the CDC proofs instead of the primitive).
// The two-flop synchroniser with metastability modelled as the solver's
// choice, per bit and per destination edge: a bit whose input differs from
// the first stage may be captured one edge late (the first stage resolved
// to the old value), never on two edges in a row. A change therefore reaches
// sync_o on the second or third destination edge, and the bits of a bundle
// may arrive on different edges, as in the simulation-only ARV_SYNC_JITTER
// model of the primitive.
//----------------------------------------------------------------------------
`default_nettype none
module  arv_synchronizer #(
    parameter           W       = 1,
    parameter [W-1:0]   RST_VAL = {W{1'b0}},
    parameter           ARST_EN = 1'b1
) (
    input  wire         clk_i,
    input  wire         rst_n_i,
    input  wire [W-1:0] async_i,
    output wire [W-1:0] sync_o
);

reg  [W-1:0] meta_q;
reg  [W-1:0] sync_q;
reg  [W-1:0] late_q;                         // held late on the last edge
wire [W-1:0] late = $anyseq;                 // the solver's choice
wire [W-1:0] hold = late & ~late_q & (async_i ^ meta_q);
wire [W-1:0] meta_d = (hold & meta_q) | (~hold & async_i);

assign sync_o = sync_q;

generate
    if (ARST_EN) begin : g_async_rst
        always @(posedge clk_i or negedge rst_n_i)
            if (!rst_n_i) begin
                meta_q <= RST_VAL;
                sync_q <= RST_VAL;
                late_q <= {W{1'b0}};
            end else begin
                meta_q <= meta_d;
                sync_q <= meta_q;
                late_q <= hold;
            end
    end else begin : g_sync_rst
        always @(posedge clk_i) begin
            meta_q <= rst_n_i ? meta_d : RST_VAL;
            sync_q <= meta_q;
            late_q <= rst_n_i ? hold : {W{1'b0}};
        end
    end
endgenerate

endmodule

`default_nettype wire
