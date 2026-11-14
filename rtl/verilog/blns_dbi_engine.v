//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dbi_engine
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dbi_engine.v
// Module Description : DBI command engine. Holds the one-deep command and fill slots,
//                      the refresh-trigger latch and the parameter FIFO, and turns
//                      the three operations into a stream of PHY items:
//                        command : cmd, NPARAM parameters from the FIFO
//                        fill    : [CASET 0x2A, PASET 0x2B] 0x2C, width*height copies
//                                  of the RGB565 colour
//                        refresh : [Get_Scanline 0x45 poll until the scanline crosses
//                                  SCANLINE | TE wait]
//                                  [CASET 0x2A, PASET 0x2B] 0x2C, pixels to px_last
//                      Start priority when idle: fill > refresh > command,
//                      except that a command goes before a refresh requested
//                      while the previous refresh was running (refr_late):
//                      a refresh timer that requests at least once per frame
//                      then alternates frames and commands instead of
//                      starving the commands.
//                      refresh_active_o (a flop) is high from the 0x2C item until
//                      the last pixel has left the PHY.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_dbi_engine #(
    parameter                 SCAN_EN      = 1'b1,  // Get_Scanline polling available (8080 PHY present)
    parameter                 PAR16_EN     = 1'b1,  // a PHY sends a parameter's [15:8] (8080 PHY present)
    parameter                 DIM_W        = 10,    // width/height field width
    parameter                 ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire               hclk_i,               // clock
    input  wire               hresetn_i,            // active-low reset (style per ASYNC_RST_EN)

// REGISTER WRITES (completion cycle)
    input  wire               cmd_wr_i,             // DIF_CMD written (cmd_free_o set)
    input  wire        [15:0] cmd_wdata_i,          // [7:0] command, [15:8] NPARAM
    input  wire               param_wr_i,           // DIF_PARAM written
    input  wire        [15:0] param_wdata_i,        // parameter
    input  wire               dfill_wr_i,           // DIF_DFILL written (dfill_free_o set)
    input  wire        [23:0] dfill_wdata_i,        // RGB888 colour

// CONFIGURATION
    input  wire               hw_window_en_i,       // CASET/PASET before each refresh
    input  wire               scan_sync_en_i,       // Get_Scanline sync (8080 selected)
    input  wire               te_sync_en_i,         // TE sync
    input  wire         [9:0] scanline_i,           // target scanline
    input  wire               te_rise_i,            // synchronised TE rising edge

// STATUS
    output wire               busy_o,               // operation in progress
    output wire               cmd_pend_o,           // command slot occupied
    output wire               dfill_pend_o,         // fill slot occupied
    output wire               cmd_free_o,           // a DIF_CMD write is accepted this cycle
    output wire               dfill_free_o,         // a DIF_DFILL write is accepted this cycle
    output wire               refr_pend_o,          // refresh trigger latched
    output wire               param_full_o,         // parameter FIFO full
    output wire         [4:0] param_level_o,        // parameter FIFO level
    output wire               refr_busy_o,          // refresh in progress
    output wire               wait_sync_o,          // waiting for scanline / TE
    output wire               dfill_busy_o,         // fill in progress
    output wire               done_o,               // command or fill finished (1 cycle)

// BDI PIXEL STREAM AND FRAME CONTROL
    input  wire               px_valid_i,           // pixel available
    input  wire        [23:0] px_data_i,            // pixel (RGB888)
    input  wire               px_last_i,            // final pixel of the frame
    output wire               px_ready_o,           // pixel taken
    input  wire               refresh_trig_i,       // frame request
    output wire               refresh_active_o,     // sending a frame
    output wire               size_hold_o,          // refresh started, before its frame
    input  wire   [DIM_W-1:0] width_i,              // display width
    input  wire   [DIM_W-1:0] height_i,             // display height
    output wire   [DIM_W-1:0] win_w_o,              // size taken at the operation's start (width)
    output wire   [DIM_W-1:0] win_h_o,              // ... (height)

// PHY ITEM INTERFACE
    output wire               txn_o,                // transaction open (CS low)
    output wire               xfer_valid_o,         // item available
    output wire               xfer_rd_o,            // read item
    output wire               xfer_dc_o,            // D/CX of the item
    output wire               xfer_px_o,            // pixel item (16 bits on SPI)
    output wire        [15:0] xfer_data_o,          // item value
    input  wire               xfer_ready_i,         // item taken
    input  wire               phy_idle_i,           // PHY idle, CS high
    input  wire               rd_valid_i,           // read data available
    input  wire         [7:0] rd_data_i             // read data
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================

localparam       SCAN_EN_PROC = (SCAN_EN != 0);
// Parameter FIFO entry width: the SPI PHY sends [7:0] of a parameter item
// only (blns_dbi_spi: a non-pixel item is one byte), so an SPI-only build
// stores 8 bits and the head reads [15:8] = 0
localparam       PAR_W        = (PAR16_EN != 0) ? 16 : 8;

// FSM states
localparam [3:0] ST_IDLE  = 4'd0,     // nothing in progress
                 ST_TE    = 4'd1,     // refresh: wait for a TE rising edge
                 ST_SCMD  = 4'd2,     // refresh: Get_Scanline command
                 ST_SRD   = 4'd3,     // refresh: dummy + two reads
                 ST_SCHK  = 4'd4,     // refresh: wait for the read data, compare
                 ST_WIN   = 4'd5,     // refresh: CASET / PASET and their parameters
                 ST_RAMWR = 4'd6,     // refresh / fill: Memory Write command
                 ST_PIX   = 4'd7,     // refresh / fill: pixels
                 ST_CMD   = 4'd8,     // command: command byte
                 ST_PAR   = 4'd9,     // command: parameters
                 ST_END   = 4'd10;    // wait for the PHY to release CS

// Operation codes
localparam [1:0] OP_CMD   = 2'd0,
                 OP_DFILL = 2'd1,
                 OP_REFR  = 2'd2;

localparam [7:0] DCS_CASET = 8'h2A,
                 DCS_PASET = 8'h2B,
                 DCS_RAMWR = 8'h2C,
                 DCS_GTS   = 8'h45;

//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

// State
wire                [3:0] state;
reg                 [3:0] state_nxt;
wire                [1:0] op;
wire                      cmd_pend;
wire                [7:0] pend_cmd;
wire                [7:0] pend_npar;
wire                      dfill_pend;
wire               [15:0] pend_color;
wire                      refr_pend;
wire                      refr_late;
wire                [7:0] act_cmd;
wire                [7:0] par_left;
wire               [15:0] act_color;
wire          [DIM_W-1:0] fill_x;
wire          [DIM_W-1:0] fill_y;
wire                [3:0] win_idx;
wire                [1:0] rd_cnt;
wire                [1:0] res_cnt;
wire                [1:0] gts_hi;
wire                [7:0] gts_lo;
wire                [9:0] scan_prev;
wire                      scan_prev_vld;
wire                      refr_active;
wire          [DIM_W-1:0] win_w;
wire          [DIM_W-1:0] win_h;

// FIFO
wire               [15:0] fifo_head;
wire                [4:0] fifo_level;
wire                      fifo_full;
wire                      fifo_empty;
wire                      fifo_pop;

// State decode
wire                      st_idle;
wire                      st_te;
wire                      st_scmd;
wire                      st_srd;
wire                      st_schk;
wire                      st_win;
wire                      st_ramwr;
wire                      st_pix;
wire                      st_cmd;
wire                      st_par;
wire                      st_end;
wire                      op_dfill;
wire                      op_refr;

// Control
wire                      accept;
wire                      start_dfill;
wire                      start_refr;
wire                      start_cmd;
wire                      start;
wire                [1:0] op_nxt;
wire                      sync_scan;
wire                      sync_te;
wire                      scan_done;
wire                      scan_cross;
wire                      scan_rd_valid;
wire                [7:0] scan_rd_data;
wire                [9:0] scan_sample;
wire                      scan_prev_vld_en;
wire                      pix_last;
wire                      fill_last;

// Geometry
wire          [DIM_W-1:0] width_m1;
wire          [DIM_W-1:0] height_m1;
wire               [16:0] win_w_ext;
wire               [16:0] win_h_ext;
wire               [15:0] win_wm1;
wire               [15:0] win_hm1;
wire                [7:0] win_byte;
wire                      win_cmd;
wire               [15:0] px_rgb565;

// Next-state
wire                      cmd_pend_en;
wire                      dfill_pend_en;
wire                      refr_pend_en;
wire                      refr_pend_nxt;
wire                      refr_late_set;
wire                      refr_late_en;
wire                      par_left_en;
wire                [7:0] par_left_nxt;
wire                      fill_x_en;
wire          [DIM_W-1:0] fill_x_nxt;
wire                      fill_y_en;
wire          [DIM_W-1:0] fill_y_nxt;
wire                      win_idx_en;
wire                [3:0] win_idx_nxt;
wire                      rd_cnt_en;
wire                [1:0] rd_cnt_nxt;
wire                      res_cnt_en;
wire                [1:0] res_cnt_nxt;
wire                      gts_hi_en;
wire                      gts_lo_en;
wire                      refr_active_nxt;

//=============================================================================
// 3)  SLOTS AND TRIGGER LATCH
//=============================================================================

assign start_dfill = st_idle & dfill_pend;
assign start_refr  = st_idle & ~dfill_pend & refr_pend & ~(cmd_pend & refr_late);
assign start_cmd   = st_idle & ~dfill_pend & cmd_pend  & (~refr_pend | refr_late);
assign start       = start_dfill | start_refr | start_cmd;

// Set/clear flags: a write fills the slot when it is free or emptied in the same
// cycle (cmd_free_o / dfill_free_o; the register side drops any other write), the
// start empties it. Priority: write (set) > start (clear).
assign cmd_pend_en   = cmd_wr_i   | start_cmd;
assign dfill_pend_en = dfill_wr_i | start_dfill;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_cmd_pend (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cmd_pend_en), .d_i(cmd_wr_i), .q_o(cmd_pend));

arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_pend_cmd (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cmd_wr_i), .d_i(cmd_wdata_i), .q_o({pend_npar, pend_cmd}));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_dfill_pend (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dfill_pend_en), .d_i(dfill_wr_i), .q_o(dfill_pend));

arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_pend_color (   // RGB888 -> RGB565 truncation
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dfill_wr_i),
    .d_i({dfill_wdata_i[23:19], dfill_wdata_i[15:10], dfill_wdata_i[7:3]}), .q_o(pend_color));

// Priority: new trigger (set) > refresh start (clear)
assign refr_pend_en  = refresh_trig_i | start_refr;
assign refr_pend_nxt = refresh_trig_i;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_refr_pend (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(refr_pend_en), .d_i(refr_pend_nxt), .q_o(refr_pend));

// The latched request arrived while a refresh was running (from its start
// cycle to its end): a queued command goes first. Priority: such a request
// (set) > a command or refresh start (clear). A fill start keeps it, so the
// command still goes before that refresh after the fill.
assign refr_late_set = refresh_trig_i & (start_refr | (~st_idle & op_refr));
assign refr_late_en  = refr_late_set | start_cmd | start_refr;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_refr_late (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(refr_late_en), .d_i(refr_late_set), .q_o(refr_late));

//=============================================================================
// 4)  PARAMETER FIFO
//=============================================================================

// A write to a full FIFO is dropped (blns_dbi: PARAM_OVFL)
assign fifo_pop     = st_par & accept;

blns_dbi_fifo #(
    .DW           ( PAR_W         ),
    .ASYNC_RST_EN ( ASYNC_RST_EN  )
) blns_dbi_fifo_inst (
// CLOCK & RESET
    .hclk_i       ( hclk_i        ),
    .hresetn_i    ( hresetn_i     ),
// PUSH / POP
    .push_i       ( param_wr_i    ),
    .push_data_i  ( param_wdata_i ),
    .pop_i        ( fifo_pop      ),
    .head_o       ( fifo_head     ),
// STATUS
    .level_o      ( fifo_level    ),
    .full_o       ( fifo_full     ),
    .empty_o      ( fifo_empty    )
);

//=============================================================================
// 5)  FSM
//=============================================================================

assign st_idle  = (state == ST_IDLE);
assign st_te    = (state == ST_TE);
assign st_scmd  = (state == ST_SCMD);
assign st_srd   = (state == ST_SRD);
assign st_schk  = (state == ST_SCHK);
assign st_win   = (state == ST_WIN);
assign st_ramwr = (state == ST_RAMWR);
assign st_pix   = (state == ST_PIX);
assign st_cmd   = (state == ST_CMD);
assign st_par   = (state == ST_PAR);
assign st_end   = (state == ST_END);
assign op_dfill = (op == OP_DFILL);
assign op_refr  = (op == OP_REFR);

assign accept     = xfer_valid_o & xfer_ready_i;

// Scanline polling exists only with the 8080 PHY; it wins over TE when both are set.
// Clearing the enable while waiting releases the wait.
generate
    if (SCAN_EN_PROC) begin : g_scan
        assign sync_scan     = scan_sync_en_i;
        assign scan_rd_valid = rd_valid_i;
        assign scan_rd_data  = rd_data_i;

        // Start when the scan passed SCANLINE between the previous sample and this one
        // (prev < SCANLINE <= sample, or across the wrap when sample < prev). The first
        // sample of a wait only becomes the previous one.
        assign scan_cross    = scan_prev_vld &
                               ((scan_sample < scan_prev) ? ((scan_prev < scanline_i) | (scanline_i <= scan_sample)) :
                                                            ((scan_prev < scanline_i) & (scanline_i <= scan_sample)));
    end else begin : g_no_scan
        assign sync_scan     = 1'b0;
        assign scan_rd_valid = 1'b0;
        assign scan_rd_data  = 8'h00;
        assign scan_cross    = 1'b0;
        wire   [20:0] scan_state_unused   = {scan_prev_vld, scan_prev, scan_sample};
        wire          scan_sync_en_unused = scan_sync_en_i;
        wire    [9:0] scanline_unused     = scanline_i;
        wire          rd_valid_unused     = rd_valid_i;
        wire    [7:0] rd_data_unused      = rd_data_i;
    end
endgenerate
assign sync_te    = ~sync_scan & te_sync_en_i;

assign scan_done  = (res_cnt == 2'd3);
assign scan_sample = {gts_hi, gts_lo};

assign fill_last  = (fill_x == {DIM_W{1'b0}}) & (fill_y == {DIM_W{1'b0}});
assign pix_last   = op_refr ? px_last_i : fill_last;

always @(*) begin
    state_nxt = state;
    case (state)
        ST_IDLE  : if (start_dfill & hw_window_en_i)             state_nxt = ST_WIN;
                   else if (start_dfill)                         state_nxt = ST_RAMWR;
                   else if (start_refr & sync_scan)              state_nxt = ST_SCMD;
                   else if (start_refr & sync_te)                state_nxt = ST_TE;
                   else if (start_refr & hw_window_en_i)         state_nxt = ST_WIN;
                   else if (start_refr)                          state_nxt = ST_RAMWR;
                   else if (start_cmd)                           state_nxt = ST_CMD;
        ST_TE    : if (sync_scan)                                state_nxt = ST_SCMD;
                   else if (te_rise_i | ~sync_te)                state_nxt = hw_window_en_i ? ST_WIN : ST_RAMWR;
        ST_SCMD  : if (accept)                                   state_nxt = ST_SRD;
        ST_SRD   : if (accept & (rd_cnt == 2'd2))                state_nxt = ST_SCHK;
        ST_SCHK  : if (scan_done & (scan_cross | ~sync_scan))    state_nxt = hw_window_en_i ? ST_WIN : ST_RAMWR;
                   else if (scan_done)                           state_nxt = ST_SCMD;
        ST_WIN   : if (accept & (win_idx == 4'd9))               state_nxt = ST_RAMWR;
        ST_RAMWR : if (accept)                                   state_nxt = ST_PIX;
        ST_PIX   : if (accept & pix_last)                        state_nxt = ST_END;
        ST_CMD   : if (accept)                                   state_nxt = (par_left != 8'd0) ? ST_PAR : ST_END;
        ST_PAR   : if (accept & (par_left == 8'd1))              state_nxt = ST_END;
        ST_END   : if (phy_idle_i)                               state_nxt = ST_IDLE;
        default  :                                               state_nxt = ST_IDLE;
    endcase
end

arv_ipdff #(.WIDTH(4), .RST_VAL(ST_IDLE), .ARST_EN(ASYNC_RST_EN)) u_state (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(state_nxt), .q_o(state));

assign op_nxt = start_dfill ? OP_DFILL :
                start_refr  ? OP_REFR  :
                              OP_CMD   ;

arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_op (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start), .d_i(op_nxt), .q_o(op));

//=============================================================================
// 6)  OPERATION COUNTERS
//=============================================================================

// Command byte and parameter count copied out of the slot at start
arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_act_cmd (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start_cmd), .d_i(pend_cmd), .q_o(act_cmd));

// Priority: start (load) > parameter sent (decrement)
assign par_left_en  = start_cmd | fifo_pop;
assign par_left_nxt = start_cmd ? pend_npar : (par_left - 8'd1);

arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_par_left (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(par_left_en), .d_i(par_left_nxt), .q_o(par_left));

// Fill colour and geometry copied at start; x counts the line, y the lines
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_act_color (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start_dfill), .d_i(pend_color), .q_o(act_color));

// The window commands, and the fill's line length, use the size taken at the
// start of the operation
arv_ipdff #(.WIDTH(2*DIM_W), .ARST_EN(ASYNC_RST_EN)) u_win_size (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start), .d_i({width_i, height_i}), .q_o({win_w, win_h}));

// Also the size the core passes on while size_hold_o is set (belenos_core):
// a refresh holds the size from its start, where this copy is taken, to its
// frame
assign win_w_o    = win_w;
assign win_h_o    = win_h;

assign win_w_ext  = {{(17-DIM_W){1'b0}}, win_w};
assign win_h_ext  = {{(17-DIM_W){1'b0}}, win_h};
// The size is never 0 (DISP_SIZE stores a 0 field as 1 and resets to 1x1)
assign win_wm1    = win_w_ext[15:0] - 16'd1;
assign win_hm1    = win_h_ext[15:0] - 16'd1;
assign width_m1   = width_i  - {{(DIM_W-1){1'b0}}, 1'b1};
assign height_m1  = height_i - {{(DIM_W-1){1'b0}}, 1'b1};

// Priority: start (load) > pixel sent (count down, x reloads at line end)
assign fill_x_en  = start_dfill | (st_pix & accept);
assign fill_x_nxt = start_dfill                    ? width_m1  :
                    (fill_x == {DIM_W{1'b0}})      ? win_wm1[DIM_W-1:0] :
                                                     (fill_x - {{(DIM_W-1){1'b0}}, 1'b1});
assign fill_y_en  = start_dfill | (st_pix & accept & (fill_x == {DIM_W{1'b0}}));
assign fill_y_nxt = start_dfill ? height_m1 : (fill_y - {{(DIM_W-1){1'b0}}, 1'b1});

arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_fill_x (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(fill_x_en), .d_i(fill_x_nxt), .q_o(fill_x));

arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ASYNC_RST_EN)) u_fill_y (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(fill_y_en), .d_i(fill_y_nxt), .q_o(fill_y));

// Window sequence index: 0x2A, 0, 0, (w-1)[15:8], (w-1)[7:0], 0x2B, 0, 0, (h-1)[15:8], (h-1)[7:0]
// Priority: start (clear) > item sent (increment)
assign win_idx_en  = start | (st_win & accept);
assign win_idx_nxt = start ? 4'd0 : (win_idx + 4'd1);

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_win_idx (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(win_idx_en), .d_i(win_idx_nxt), .q_o(win_idx));

assign win_cmd  = (win_idx == 4'd0) | (win_idx == 4'd5);
assign win_byte = ({8{win_idx == 4'd0}} & DCS_CASET)     |
                  ({8{win_idx == 4'd3}} & win_wm1[15:8]) |
                  ({8{win_idx == 4'd4}} & win_wm1[7:0])  |
                  ({8{win_idx == 4'd5}} & DCS_PASET)     |
                  ({8{win_idx == 4'd8}} & win_hm1[15:8]) |
                  ({8{win_idx == 4'd9}} & win_hm1[7:0])  ;

//=============================================================================
// 7)  SCANLINE READ
//=============================================================================

// Reads issued (0..2) and read results received (0: dummy, 1: GTS[9:8], 2: GTS[7:0]).
// Priority: new poll (clear) > item / result (increment)
assign rd_cnt_en   = st_scmd | (st_srd & accept);
assign rd_cnt_nxt  = st_scmd ? 2'd0 : (rd_cnt + 2'd1);
assign res_cnt_en  = st_scmd | scan_rd_valid;
assign res_cnt_nxt = st_scmd ? 2'd0 : (res_cnt + 2'd1);
assign gts_hi_en   = scan_rd_valid & (res_cnt == 2'd1);
assign gts_lo_en   = scan_rd_valid & (res_cnt == 2'd2);

arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_rd_cnt (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rd_cnt_en),  .d_i(rd_cnt_nxt),     .q_o(rd_cnt));

arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_res_cnt (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(res_cnt_en), .d_i(res_cnt_nxt),    .q_o(res_cnt));

arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_gts_hi (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(gts_hi_en),  .d_i(scan_rd_data[1:0]), .q_o(gts_hi));

arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_gts_lo (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(gts_lo_en),  .d_i(scan_rd_data),      .q_o(gts_lo));

arv_ipdff #(.WIDTH(10), .ARST_EN(ASYNC_RST_EN)) u_scan_prev (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_schk & scan_done), .d_i(scan_sample), .q_o(scan_prev));

// Priority: sample taken (set) > operation start (clear)
assign scan_prev_vld_en = (st_schk & scan_done) | start;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_scan_prev_vld (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(scan_prev_vld_en), .d_i(st_schk), .q_o(scan_prev_vld));

//=============================================================================
// 8)  PHY ITEMS
//=============================================================================

assign px_rgb565   = {px_data_i[23:19], px_data_i[15:10], px_data_i[7:3]};

assign txn_o       = ~(st_idle | st_te | st_end);

assign xfer_valid_o = st_scmd | st_srd | st_win | st_ramwr | st_cmd |
                      (st_par & ~fifo_empty) |
                      (st_pix & (op_refr ? px_valid_i : 1'b1));

assign xfer_rd_o   = st_srd;
assign xfer_px_o   = st_pix;
assign xfer_dc_o   = ~(st_scmd | st_ramwr | st_cmd | (st_win & win_cmd));

assign xfer_data_o = ({16{st_cmd}}              & {8'h00, act_cmd})   |
                     ({16{st_par}}              & fifo_head)          |
                     ({16{st_scmd}}             & {8'h00, DCS_GTS})   |
                     ({16{st_win}}              & {8'h00, win_byte})  |
                     ({16{st_ramwr}}            & {8'h00, DCS_RAMWR}) |
                     ({16{st_pix &  op_refr}}   & px_rgb565)          |
                     ({16{st_pix & ~op_refr}}   & act_color)          ;

assign px_ready_o  = st_pix & op_refr & xfer_ready_i;

//=============================================================================
// 9)  STATUS
//=============================================================================

// refresh_active from a flop (it reaches the backend, the refresh pacing and
// the register latches): the decode of the next state and operation, so it
// rises and falls in the same cycles as the state decode would
assign refr_active_nxt  = ((state_nxt == ST_RAMWR) | (state_nxt == ST_PIX) | (state_nxt == ST_END)) &
                          ((start ? op_nxt : op) == OP_REFR);

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_refr_active (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(refr_active_nxt), .q_o(refr_active));

assign refresh_active_o = refr_active;
assign size_hold_o      = (st_te | st_scmd | st_srd | st_schk | st_win) & op_refr;

assign busy_o        = ~st_idle;
assign cmd_pend_o    = cmd_pend;
assign dfill_pend_o  = dfill_pend;
assign cmd_free_o    = ~cmd_pend   | start_cmd;
assign dfill_free_o  = ~dfill_pend | start_dfill;
assign refr_pend_o   = refr_pend;
assign param_full_o  = fifo_full;
assign param_level_o = fifo_level;
assign refr_busy_o   = ~st_idle & op_refr;
assign dfill_busy_o  = ~st_idle & op_dfill;
assign wait_sync_o   = st_te | st_scmd | st_srd | st_schk;
assign done_o        = st_end & phy_idle_i & ~op_refr;

// Truncated colour bits (RGB888 -> RGB565) and the zero-extension guard bits
wire  [7:0] dfill_lsb_unused = {dfill_wdata_i[18:16], dfill_wdata_i[9:8], dfill_wdata_i[2:0]};
wire  [7:0] px_lsb_unused    = {px_data_i[18:16], px_data_i[9:8], px_data_i[2:0]};
wire  [1:0] dim_ext_unused   = {win_w_ext[16], win_h_ext[16]};

endmodule // blns_dbi_engine

`default_nettype wire
