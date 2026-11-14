//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_refresh
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_refresh.v
// Module Description : Refresh pacing: REFRESH (period timer / manual one-shot),
//                      FRAME_CNT countdown and the refresh start/done events
//                      derived from the display driver's refresh_active, and
//                      whether the last frame was abandoned.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_refresh #(
    parameter                 ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,              // clock
    input  wire               hresetn_i,           // active-low reset

// Register access (from blns_regs)
    input  wire               refresh_wr_i,        // REFRESH write
    input  wire               frame_cnt_wr_i,      // FRAME_CNT write
    input  wire        [31:0] wdata_i,             // write data
    output wire        [31:0] refresh_o,           // REFRESH value
    output wire        [15:0] frame_cnt_o,         // FRAME_CNT value

// Control / status
    input  wire               freeze_i,            // debug time freeze (DBG_CTRL[0] & stoptime)
    input  wire               refresh_active_i,    // display driver is sending a frame
    input  wire               refresh_active_q_i,  // refresh_active_i one cycle late (a flop, reset 0)
    input  wire               px_last_i,           // the frame's last pixel was taken (1 cycle)
    output wire               refresh_trig_o,      // frame request (1 cycle)
    output wire               running_o,           // REFRESH.START set (keeps the clock on)
    output wire               refr_start_evt_o,    // refresh_active rising edge
    output wire               refr_done_evt_o,     // refresh_active falling edge
    output wire               frame_cnt_done_evt_o,// FRAME_CNT reached 0
    output wire               abandoned_o          // the last frame ended before its last pixel
);


//=============================================================================
// 1)  REFRESH_ACTIVE EDGES
//=============================================================================

// The delayed copy is the backend's (blns_backend u_active_dly, through
// blns_regs): one flop for the backend, the edges here and the clock request
wire                    active_q       =  refresh_active_q_i;

assign                  refr_start_evt_o =  refresh_active_i & ~active_q;
assign                  refr_done_evt_o  = ~refresh_active_i &  active_q;


//=============================================================================
// 2)  REFRESH REGISTER: [0] START, [31:4] PERIOD (0 = manual one-shot)
//=============================================================================

wire                    start;
wire             [27:0] period;
wire                    manual         =  (period == 28'd0);

// Manual mode: START stays set until every requested frame has been sent. The driver
// is handed one request at a time: a request written while the previous one has not
// started its frame waits here (further ones merge with it) and is handed over in the
// cycle after that frame's start (start_q, a flop: no path from refresh_active_i to
// refresh_trig_o), when the driver queues it behind the frame it is sending.
// trig_q : a request handed to the driver, its frame not started yet (or started in
//          the cycle before: start_q)
// wait_q : a request waiting to be handed over
// own_q  : the frame being sent answers a request
// start_q: a frame started in the cycle before
wire                    manual_go;
wire                    trig_q;
wire                    wait_q;
wire                    own_q;
wire                    start_q;
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_start_q (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(refr_start_evt_o), .q_o(start_q));
wire                    trig_free      = ~trig_q | start_q;
wire                    trig_wait      =  trig_q & ~start_q;      // a handed request, its frame not started
wire                    manual_trig    =  trig_free & (manual_go | wait_q);
wire                    trig_en        =  manual_trig | start_q;
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_trig_q (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(trig_en), .d_i(manual_trig), .q_o(trig_q));
// Set by a request while the driver holds one, cleared at a hand-over; both at once
// keep it (the hand-over takes the waiting request, the new one waits)
wire                    wait_set       =  manual_go & ~trig_free;
wire                    wait_clr       =  trig_free & ~manual_go;
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_wait_q (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wait_set | wait_clr),
                           .d_i(wait_set), .q_o(wait_q));
wire                    own_en         =  refr_start_evt_o | refr_done_evt_o;
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_own_q (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(own_en), .d_i(refr_start_evt_o & trig_q), .q_o(own_q));

wire                    start_clr      =  manual & start & refr_done_evt_o & own_q & ~trig_wait & ~wait_q & ~manual_go;
wire                    start_en       =  refresh_wr_i | start_clr;
wire                    start_nxt      =  refresh_wr_i ? wdata_i[0] : 1'b0;

arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_start (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start_en),     .d_i(start_nxt),     .q_o(start));
arv_ipdff #(.WIDTH(28), .ARST_EN(ASYNC_RST_EN)) u_period (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(refresh_wr_i), .d_i(wdata_i[31:4]), .q_o(period));

assign                  refresh_o  = {period, 3'b000, start};
assign                  running_o  =  start;


//=============================================================================
// 3)  PERIOD TIMER AND TRIGGER
//=============================================================================

// A down-counter: the cycles left to the next request (PERIOD after a REFRESH
// write or a request, 1 in the cycle of the request), so that the request is
// an equality to a constant rather than a subtract and a compare.
wire             [27:0] timer;
wire                    timer_expire   =  start & ~manual & ~freeze_i & (timer == 28'd1);

// Manual mode: one request per START write (taken the cycle after the write).
wire                    manual_go_nxt  =  refresh_wr_i & wdata_i[0] & (wdata_i[31:4] == 28'd0);
arv_ipdff #(.WIDTH(1),  .ARST_EN(ASYNC_RST_EN)) u_manual_go (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(manual_go_nxt), .q_o(manual_go));

wire                    timer_en       =  refresh_wr_i | (start & ~manual & ~freeze_i);
wire             [27:0] timer_nxt      =  refresh_wr_i ? wdata_i[31:4] : timer_expire ? period : (timer - 28'd1);

arv_ipdff #(.WIDTH(28), .ARST_EN(ASYNC_RST_EN)) u_timer (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(timer_en), .d_i(timer_nxt), .q_o(timer));

assign                  refresh_trig_o =  timer_expire | manual_trig;


//=============================================================================
// 4)  FRAME_CNT: -1 per finished frame while not zero
//=============================================================================

wire             [15:0] frame_cnt;
wire                    frame_cnt_dec  =  refr_done_evt_o & ~freeze_i & (frame_cnt != 16'd0);
wire                    frame_cnt_en   =  frame_cnt_wr_i | frame_cnt_dec;
wire             [15:0] frame_cnt_nxt  =  frame_cnt_wr_i ? wdata_i[15:0] : (frame_cnt - 16'd1);

arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_frame_cnt (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(frame_cnt_en), .d_i(frame_cnt_nxt), .q_o(frame_cnt));

assign                  frame_cnt_o          =  frame_cnt;
assign                  frame_cnt_done_evt_o =  frame_cnt_dec & ~frame_cnt_wr_i & (frame_cnt == 16'd1);


//=============================================================================
// 5)  ABANDONED FRAME
//=============================================================================
// A frame that ends before its last pixel was taken (a DPI driver abandons the
// frame it is still taking at a panel frame start): STATUS.REFR_ABANDONED,
// from the end of that frame to the end of the next

wire                    last_seen;
wire                    last_seen_nxt  = ~refr_start_evt_o & (last_seen | px_last_i);

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_last_seen (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(last_seen_nxt), .q_o(last_seen));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_abandoned (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(refr_done_evt_o), .d_i(~(last_seen | px_last_i)),
                           .q_o(abandoned_o));

wire              [2:0] wdata_unused = wdata_i[3:1];

endmodule // blns_refresh

`default_nettype wire
