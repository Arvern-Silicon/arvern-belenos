//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_hdmi_i2s
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_hdmi_i2s.v
// Module Description : HDMI audio input, pixel-clock domain: an I2S receiver
//                      (Philips format, LRCK low = left, MSB first one bit
//                      after the LRCK edge, slots of up to 63 bits) that
//                      samples BCLK, LRCK and SD through synchronisers, so
//                      BCLK must stay high and low for at least 2 pixel
//                      clocks each (4 x BCLK at a 50 % duty cycle): SD and
//                      LRCK are used in the clock that detects the BCLK
//                      edge. The 24 most significant bits of each slot are
//                      kept (zero fill below 24 bits). The receiver is
//                      armed by the first LRCK edge after audio starts or
//                      after a stall (1023 pixel clocks without a BCLK
//                      edge, or 64 BCLK edges without an LRCK edge), so no
//                      partial or stale frame is taken. A stereo frame
//                      goes into a 4-entry buffer, with the channel-status
//                      frame number (0-191) of its oldest entry. A packet
//                      reads the buffer from its load (rd_i) and empties it
//                      after its last data character (pop_i); the buffer
//                      holds still meanwhile: a frame completed then waits
//                      aside (its left sample here, the right one in the
//                      receiver until the next slot boundary, so a slot
//                      lasts at least 28 pixel clocks) and is the first
//                      entry after the pop, and audio stopping, even
//                      briefly, clears the buffer only after that packet.
//                      A frame is lost (ovf_o, sticky while en_i) when it
//                      arrives with the buffer full, or while it waits aside
//                      when the next boundary comes before the pop. The CTS
//                      meter counts pixel clocks over N / 128 frames; a
//                      measurement that spans a stall or saturates
//                      (2^20 - 1) is dropped, and so are the one after a
//                      saturated one and one that ends while a packet reads
//                      cts_o (cts_hold_i).
//----------------------------------------------------------------------------
`default_nettype none
module  blns_hdmi_i2s #(
    parameter                 ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               clk_i,                // pixel-domain clock
    input  wire               rst_n_i,              // active-low reset
    input  wire               en_i,                 // audio on (else idle, buffer empty)
    input  wire        [12:0] nfr_i,                // N / 128: frames per CTS measurement (0: none)
    input  wire               bclk_i,               // I2S bit clock (asynchronous)
    input  wire               lrck_i,               // I2S word clock (asynchronous)
    input  wire               sd_i,                 // I2S data (asynchronous)
    input  wire               rd_i,                 // a packet reads the buffer (from its load to the pop)
    input  wire               pop_i,                // take every frame held (the packet's last data character)
    input  wire               cts_hold_i,           // a packet reads cts_o
    output wire         [2:0] cnt_o,                // frames held (0-4)
    output wire       [191:0] smp_o,                // frames {right, left}, the oldest in [47:0]
    output wire         [7:0] idx_o,                // channel-status frame number of the oldest
    output wire        [19:0] cts_o,                // last CTS measured
    output wire               cts_new_o,            // cts_o updated (one clock)
    output wire               ovf_o                 // a frame was lost
);

localparam             ARST_EN = (ASYNC_RST_EN != 0);

//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

wire                bc_s;
wire                lr_s;
wire                sd_s;
wire                bc_q;
wire                lr_q;
wire                rise;
wire                bnd;
wire          [5:0] bn;                 // bits of the slot shifted so far
wire          [5:0] bn_nxt;
wire         [23:0] bpos;               // one-hot: the sample bit of the current slot bit (23 - bn), 0 past 24
wire         [23:0] bit_in;             // the current bit at its position
wire         [23:0] cap;                // the slot's 24 most significant bits so far (zero below)
wire         [23:0] cap_nxt;
wire          [9:0] idle;               // pixel clocks since the last BCLK rise
wire          [9:0] idle_nxt;
wire                bstall;             // BCLK stall
wire                lstall;             // LRCK stall (no edge within 64 BCLK rises)
wire                stall;
wire                armed;
wire                armed_nxt;
wire         [23:0] lsmp_nxt;
wire         [23:0] lsmp;
wire                l_ok;
wire                l_ok_nxt;
wire                push;
wire         [47:0] fr;
wire                defer;              // a frame completed while a packet reads the buffer
wire                dv;                 // a frame waits aside, its left sample in dl
wire                dv_nxt;
wire                dlost;              // the next boundary before the pop: the frame waiting is lost
wire         [23:0] dl;
wire         [47:0] fr0;
wire                stop;               // audio stopped while a packet reads the buffer
wire                stop_nxt;
wire                clr;
wire          [2:0] cnt;
wire          [2:0] cnt_nxt;
wire         [47:0] e0;
wire         [47:0] e1;
wire         [47:0] e2;
wire         [47:0] e3;
wire          [3:0] we;
wire          [7:0] idx;
wire          [8:0] idx_sum;
wire          [7:0] idx_nxt;
wire                ovf;
wire                ovf_nxt;
wire                fev;                // frame boundary (the right slot ends)
wire         [19:0] pc;                 // pixel clocks in this measurement
wire         [19:0] pc_nxt;
wire                pc_sat;
wire         [12:0] fc;                 // frames in this measurement
wire                meas;
wire         [12:0] fc_nxt;
wire                cv;                 // this measurement is kept (it began at a frame boundary, not after a saturated one)
wire         [19:0] cts;
wire                cts_new;

//=============================================================================
// 2)  I2S RECEIVER
//=============================================================================
// On each BCLK rising edge seen: SD shifted in; an LRCK change marks the
// slot boundary, where SD is the last bit of the slot that ends (LRCK before
// the change: its channel). The receiver is armed by the first boundary
// after audio starts or after a stall: the slot that boundary ends was not
// seen from its start and is not used. A slot that reaches 64 bits is an
// LRCK stall (LRCK stopped while BCLK runs): its bits are stale.

arv_synchronizer #(.W(3), .RST_VAL(3'b000), .ARST_EN(ARST_EN)) u_sync (
    .clk_i   ( clk_i                  ),
    .rst_n_i ( rst_n_i                ),
    .async_i ( {sd_i, lrck_i, bclk_i} ),
    .sync_o  ( {sd_s, lr_s, bc_s}     )
);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_bc_q (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(bc_s), .q_o(bc_q));

assign rise = en_i & bc_s & ~bc_q;
assign bnd  = rise & (lr_s != lr_q);

// BCLK stall: no rising edge for 1023 pixel clocks
assign bstall   = &idle;
assign lstall   = (bn == 6'd63);
assign stall    = bstall | lstall;
assign idle_nxt = (rise | ~en_i) ? 10'd0 : bstall ? idle : (idle + 10'd1);

arv_ipdff #(.WIDTH(10), .ARST_EN(ARST_EN)) u_idle (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(idle_nxt), .q_o(idle));

// LRCK followed while audio is off, so that the first boundary is a real edge
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_lr (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(rise | ~en_i), .d_i(lr_s), .q_o(lr_q));

assign armed_nxt = en_i & ~stall & (armed | bnd);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_armed (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(armed_nxt), .q_o(armed));

// Bits of the slot shifted so far (bn), so the slot length at a boundary
// is bn + 1; held at 63 (an LRCK stall) until the next boundary, 0 while
// audio is off
assign bn_nxt = (bnd | ~en_i) ? 6'd0 : lstall ? bn : bn + 6'd1;

arv_ipdff #(.WIDTH(6), .ARST_EN(ARST_EN)) u_bn (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(rise | ~en_i), .d_i(bn_nxt), .q_o(bn));

// The 24 MSBs, MSB-justified and zero-filled: slot bit bn (from the MSB) is
// written to bit 23 - bn while bn < 24, and later bits are dropped. The register
// is cleared at each boundary; the sample there is the register with the
// boundary's bit (the slot's last) at its position.
genvar gi;
generate
    for (gi = 0; gi < 24; gi = gi + 1) begin : g_bpos
        assign bpos[gi] = (bn == (6'd23 - gi));
    end
endgenerate

assign bit_in   = bpos & {24{sd_s}};
assign cap_nxt  = bnd ? 24'h00_0000 : (cap | bit_in);

arv_ipdff #(.WIDTH(24), .ARST_EN(ARST_EN)) u_cap (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(rise), .d_i(cap_nxt), .q_o(cap));

assign lsmp_nxt = cap | bit_in;

assign l_ok_nxt = bnd & ~lr_q & armed;

arv_ipdff #(.WIDTH(25), .ARST_EN(ARST_EN)) u_left (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(bnd | ~en_i), .d_i({l_ok_nxt, lsmp_nxt & {24{en_i}}}), .q_o({l_ok, lsmp}));

assign push = bnd & lr_q & l_ok & armed;
assign fr   = {lsmp_nxt, lsmp};

//=============================================================================
// 3)  FRAME BUFFER
//=============================================================================

// While a packet reads the buffer (rd_i) it holds still: a frame completed
// then waits aside, its left sample in dl and the right one in lsmp, which
// the next boundary (the end of a left slot) overwrites; at the pop it is
// the first entry. The pop takes every frame held and a frame completing in
// the same clock; audio stopping clears the buffer after the pop, also when
// it is on again by then (stop)
assign defer  = push & rd_i & ~pop_i;
assign dlost  = dv & bnd & ~pop_i;
assign dv_nxt = en_i & (defer | (dv & ~pop_i & ~bnd));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_dv (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(dv_nxt), .q_o(dv));
arv_ipdff #(.WIDTH(24), .ARST_EN(ARST_EN)) u_dl (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(defer), .d_i(lsmp), .q_o(dl));

assign stop_nxt = rd_i & (stop | ~en_i);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_stop (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(stop_nxt), .q_o(stop));

assign clr     = ~rd_i & (~en_i | stop);
assign cnt_nxt = clr                          ? 3'd0 :
                 pop_i                        ? {2'b00, push | dv} :
                 (push & ~rd_i & ~cnt[2])     ? cnt + 3'd1 : cnt;

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_cnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cnt_nxt), .q_o(cnt));

assign we[0] = (pop_i & (push | dv)) | (push & ~rd_i & (cnt == 3'd0));
assign we[1] = push & ~rd_i & (cnt == 3'd1);
assign we[2] = push & ~rd_i & (cnt == 3'd2);
assign we[3] = push & ~rd_i & (cnt == 3'd3);
assign fr0   = dv ? {lsmp, dl} : fr;

arv_ipdff #(.WIDTH(48), .ARST_EN(ARST_EN)) u_e0 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(we[0]), .d_i(fr0), .q_o(e0));
arv_ipdff #(.WIDTH(48), .ARST_EN(ARST_EN)) u_e1 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(we[1]), .d_i(fr), .q_o(e1));
arv_ipdff #(.WIDTH(48), .ARST_EN(ARST_EN)) u_e2 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(we[2]), .d_i(fr), .q_o(e2));
arv_ipdff #(.WIDTH(48), .ARST_EN(ARST_EN)) u_e3 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(we[3]), .d_i(fr), .q_o(e3));

// Channel-status frame number of the oldest entry: advances by the frames popped
assign idx_sum = {1'b0, idx} + {6'd0, cnt};
assign idx_nxt = clr ? 8'd0 : (idx_sum >= 9'd192) ? idx_sum[7:0] - 8'd192 : idx_sum[7:0];

arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_idx (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(pop_i | clr), .d_i(idx_nxt), .q_o(idx));

assign ovf_nxt = en_i & (ovf | (push & ~rd_i & cnt[2]) | dlost);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ovf (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(ovf_nxt), .q_o(ovf));

assign cnt_o = cnt;
assign smp_o = {e3, e2, e1, e0};
assign idx_o = idx;
assign ovf_o = ovf;

//=============================================================================
// 4)  CTS METER
//=============================================================================
// Pixel clocks between two frame boundaries N / 128 frames apart. The first
// measurement after audio starts or after a stall is dropped (it began
// mid-frame or spans the stall), and so are a count that saturated and the
// one after it, and one that ends while a packet reads cts_o (cts_hold_i).

assign pc_sat = &pc;

assign fev    = bnd & lr_q;
assign meas   = fev & (nfr_i != 13'd0) & ((fc + 13'd1) >= nfr_i);
assign fc_nxt = (~en_i | stall | meas) ? 13'd0 : fc + 13'd1;
assign pc_nxt = (~en_i | stall | meas) ? 20'd0 : pc_sat ? pc : pc + 20'd1;

arv_ipdff #(.WIDTH(13), .ARST_EN(ARST_EN)) u_fc (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(fev | ~en_i | stall), .d_i(fc_nxt), .q_o(fc));
arv_ipdff #(.WIDTH(20), .ARST_EN(ARST_EN)) u_pc (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pc_nxt), .q_o(pc));
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cv (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(meas | ~en_i | stall), .d_i(en_i & ~stall & ~pc_sat), .q_o(cv));

assign cts_new = meas & cv & ~pc_sat & ~cts_hold_i;

arv_ipdff #(.WIDTH(20), .ARST_EN(ARST_EN)) u_cts (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(cts_new), .d_i(pc + 20'd1), .q_o(cts));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cts_new (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cts_new), .q_o(cts_new_o));

assign cts_o = cts;

endmodule // blns_hdmi_i2s

`default_nettype wire
