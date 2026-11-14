//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_tmds
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_tmds.v
// Module Description : One TMDS channel encoder (DVI 1.0): during the data
//                      enable, 8 bits -> 10 with transition minimisation and
//                      DC balance (running disparity); in blanking, the
//                      control symbol of {C1, C0} and the disparity cleared.
//                      One symbol per clock, two cycles of latency; symbol
//                      bit 0 is sent first.
//----------------------------------------------------------------------------
`default_nettype none
module  blns_tmds #(
    parameter                 CTL_EN       = 1,     // 1 = c_i carried; 2 = C0 only (C1 = 0); 0 = control bits 00
    parameter                 ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               clk_i,                // pixel-domain clock
    input  wire               rst_n_i,              // active-low reset
    input  wire               de_i,                 // data enable (active high)
    input  wire         [1:0] c_i,                  // control bits {C1, C0} (blanking)
    input  wire         [7:0] d_i,                  // pixel component
    output wire         [9:0] q_o                   // TMDS symbol
);

localparam             ARST_EN = (ASYNC_RST_EN != 0);

function [3:0] ones8;
    input [7:0] v;
    ones8 = {3'd0, v[0]} + {3'd0, v[1]} + {3'd0, v[2]} + {3'd0, v[3]} +
            {3'd0, v[4]} + {3'd0, v[5]} + {3'd0, v[6]} + {3'd0, v[7]};
endfunction

//=============================================================================
// 1)  STAGE 1: transition minimisation
//=============================================================================

wire                   [3:0] n1_d;
wire                         use_xnor;
wire                   [8:0] qm_nxt;
wire                   [8:0] s1_qm;
wire                         s1_de;
wire                   [1:0] s1_c;

assign n1_d     = ones8(d_i);
assign use_xnor = (n1_d > 4'd4) | ((n1_d == 4'd4) & ~d_i[0]);

assign qm_nxt[0] = d_i[0];
genvar gi;
generate
    for (gi = 1; gi < 8; gi = gi + 1) begin : g_qm
        assign qm_nxt[gi] = qm_nxt[gi-1] ^ d_i[gi] ^ use_xnor;
    end
endgenerate
assign qm_nxt[8] = ~use_xnor;

arv_ipdff #(.WIDTH(10), .ARST_EN(ARST_EN)) u_s1 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
    .d_i({de_i, qm_nxt}), .q_o({s1_de, s1_qm}));

generate
    if (CTL_EN == 1) begin : g_ctl
        arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_s1_c (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(c_i), .q_o(s1_c));
    end else if (CTL_EN == 2) begin : g_ctl0
        wire s1_c0;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_s1_c (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(c_i[0]), .q_o(s1_c0));
        assign s1_c = {1'b0, s1_c0};
        wire   c1_unused = c_i[1];
    end else begin : g_no_ctl
        assign s1_c = 2'b00;
        wire   [1:0] c_unused = c_i;
    end
endgenerate

//=============================================================================
// 2)  STAGE 2: DC balance and control symbols
//=============================================================================

wire                   [3:0] n1_q;
wire                   [3:0] diff;                  // (ones - zeros of q_m[7:0]) / 2, two's complement
wire                   [3:0] cnt;                   // running disparity / 2, two's complement
wire                         cnt_zero;
wire                         cnt_neg;
wire                         even;
wire                         same_sign;
wire                         q8;
wire                   [9:0] sym_bal;
wire                   [9:0] sym_ctl;
wire                   [3:0] cnt_bal;
wire                   [9:0] sym_nxt;
wire                   [3:0] cnt_nxt;

assign n1_q      = ones8(s1_qm[7:0]);
// The disparity only moves by even amounts (2·ones - 8, and the 2·q_m[8]
// correction), so it is held halved: every term below is the DVI value / 2
assign diff      = n1_q - 4'd4;
assign cnt_zero  = (cnt == 4'd0);
assign cnt_neg   = cnt[3];
assign even      = (n1_q == 4'd4);
assign same_sign = (~cnt_neg & (n1_q > 4'd4)) | (cnt_neg & (n1_q < 4'd4));
assign q8        = s1_qm[8];

// No disparity yet or a balanced word: invert when q_m[8] is 0; otherwise
// invert to pull the disparity back towards zero
assign sym_bal = (cnt_zero | even) ? {~q8, q8, q8 ? s1_qm[7:0] : ~s1_qm[7:0]} :
                 same_sign         ? {1'b1, q8, ~s1_qm[7:0]} :
                                     {1'b0, q8,  s1_qm[7:0]};
assign cnt_bal = (cnt_zero | even) ? (q8 ? (cnt + diff) : (cnt - diff)) :
                 same_sign         ? (cnt + {3'd0, q8} - diff) :
                                     (cnt - {3'd0, ~q8} + diff);

assign sym_ctl = (s1_c == 2'b00) ? 10'b1101010100 :
                 (s1_c == 2'b01) ? 10'b0010101011 :
                 (s1_c == 2'b10) ? 10'b0101010100 :
                                   10'b1010101011;

assign sym_nxt = s1_de ? sym_bal : sym_ctl;
assign cnt_nxt = s1_de ? cnt_bal : 4'd0;

arv_ipdff #(.WIDTH(14), .RST_VAL({10'b1101010100, 4'd0}), .ARST_EN(ARST_EN)) u_s2 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
    .d_i({sym_nxt, cnt_nxt}), .q_o({q_o, cnt}));

endmodule // blns_tmds

`default_nettype wire
