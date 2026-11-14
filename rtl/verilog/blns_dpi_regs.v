//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dpi_regs
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dpi_regs.v
// Module Description : Register side of the DPI driver (hclk_i): the DIF and
//                      DPI registers (page 0 at 0x180) and the HDMI page (at
//                      0x200), the staged configuration (locked while the
//                      pixel domain may take it) and the UPDATE handshake,
//                      the run control, the events from the pixel domain,
//                      the panel-detect filter, the interrupts and the read
//                      data.
//
//                      The configuration bundle (CW bits) is laid out as
//                      blns_dpi_scan reads it (its B_* offsets), from the top:
//                      {CFG 10, SCANLINE 13, H 42, V 42, IMG 24, POS 25,
//                       STEP 32, BORDER 24, TEST 1}.
//----------------------------------------------------------------------------
`default_nettype none
module  blns_dpi_regs #(
    parameter                 LB_AW        = 10,    // DPI_LB_AW (DPI_CAPS)
    parameter                 SCALER       = 1,     // DPI_SCALER
    parameter                 SEP_EN       = 0,     // 1 = separate pixel clock (DPI_CAPS)
    parameter                 TMDS_EN      = 0,     // 1 = TMDS encoder (DPI_CAPS)
    parameter                 DDC_EN       = 0,     // 1 = DPI_DDC
    parameter                 HDMI_EN      = 0,     // 1 = DPI_HDMI (HDMI mode, AVI)
    parameter                 AUD_EN       = 0,     // 1 = audio, DPI_AUD, DPI_AUD_STAT, DPI_PKT0-7
    parameter                 CW           = 213,   // configuration bundle
    parameter                 ARST_EN      = 1      // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,
    input  wire               hresetn_i,
// Register port
    input  wire               reg_sel_i,            // register transfer pending
    input  wire         [5:0] reg_addr_i,           // word offset in the window: [5] the page (0x180 / 0x200)
    input  wire               reg_wr_i,             // 1 = write
    input  wire        [31:0] reg_wdata_i,          // write data
    output wire        [31:0] reg_rdata_o,          // read data
    output wire               reg_ready_o,          // transfer completes
    output wire               irq_o,                // driver interrupt (level)
    output wire               busy_o,               // driver needs the clock
// Panel control and pins
    output wire               lcd_reset_n_o,        // panel reset
    output wire               lcd_on_o,             // panel power / backlight
    input  wire               panel_detect_i,       // panel present (asynchronous)
    input  wire               ddc_scl_i,            // DDC SCL level (asynchronous)
    input  wire               ddc_sda_i,            // DDC SDA level (asynchronous)
    output wire               ddc_scl_pd_o,         // DDC SCL pulled low
    output wire               ddc_sda_pd_o,         // DDC SDA pulled low
// Run control and configuration, to the pixel domain (through blns_dpi_cdc)
    output wire               pix_en_o,             // DPI_EN as seen by the pixel domain
    output wire               req_o,                // configuration request toggle
    output wire      [CW-1:0] staged_o,             // staged configuration (stable while locked)
    output wire        [16:0] hdmi_cfg_o,           // DPI_HDMI {QUANT, VIC, ACTIVE, PICTURE, AVI, HDMI}
    output wire         [1:0] aud_ctl_o,            // {GP, AUD} for the pixel domain
    output wire        [27:0] aud_cfg_o,            // DPI_AUD {word length, sampling frequency, N}
    output wire       [247:0] gp_pkt_o,             // DPI_PKT0-7 {PB27..PB0, HB2..HB0}
// From the pixel domain (synchronised in blns_dpi_cdc)
    input  wire               run_h_i,              // running
    input  wire               prst_h_i,             // 0: a reset of the pixel domain alone is (or was just) seen
    input  wire               ack_h_i,              // configuration acknowledge toggle
    input  wire               fs_h_i,               // frame-start toggle
    input  wire               sl_h_i,               // scanline toggle
    input  wire               uf_h_i,               // underflow toggle
    input  wire               ln_h_i,               // line toggle
    input  wire               idn_h_i,              // image done toggle
    input  wire        [12:0] line_h_i,             // LINE
    input  wire               vblank_h_i,           // VBLANK
    input  wire         [1:0] aud_st_h_i,           // {audio on, lost}
    input  wire               aud_echo_h_i,         // AUD as the pixel domain takes it (SEP_EN)
    input  wire        [19:0] cts_h_i,              // the last CTS measured
    output wire               fs_evt_o,             // a frame started (one cycle)
    output wire               dn_evt_o,             // the image of the frame is done (one cycle)
    output wire               line_take_o,          // the line toggle moved
// BDI side (blns_dpi_bdi)
    input  wire               active_i,             // taking a frame
    input  wire               abandon_i             // a frame was abandoned
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================

localparam             SCALE_EN = (SCALER != 0);
localparam             FILT_EN  = (SCALER == 2);

// Register word offsets: page 0 at 0x180 + 4*n, page 1 (HDMI) at 0x200 + 4*(n - 32)
localparam [5:0] A_CFG      = 6'd0,
                 A_SYNC     = 6'd1,
                 A_STATUS   = 6'd5,
                 A_IRQ_EN   = 6'd6,
                 A_IRQ_FLAG = 6'd7,
                 A_H_ACT    = 6'd8,
                 A_H_BLANK  = 6'd9,
                 A_V_ACT    = 6'd10,
                 A_V_BLANK  = 6'd11,
                 A_IMG_SIZE = 6'd12,
                 A_IMG_POS  = 6'd13,
                 A_SCALE    = 6'd14,
                 A_BORDER   = 6'd15,
                 A_CTRL     = 6'd16,
                 A_FRAMES   = 6'd17,
                 A_CAPS     = 6'd31,
                 A_DDC      = 6'd32,            // page 1: 0x200
                 A_HDMI     = 6'd33,
                 A_AUD      = 6'd34,
                 A_AUD_ST   = 6'd35,
                 A_PKT0     = 6'd36;            // to 43

// DPI_CAPS: [3:0] DPI_LB_AW, [5:4] DPI_SCALER, [6] DPI_PCLK_SEP, [7] TMDS encoder, [8] DDC,
// [9] HDMI data islands, [10] HDMI audio
localparam [31:0] CAPS_LB  = LB_AW;
localparam [31:0] CAPS_SC  = SCALER;
localparam [31:0] CAPS     = (CAPS_LB & 32'hF) | ((CAPS_SC & 32'h3) << 4) | ((SEP_EN != 0) ? 32'h40 : 32'h0) |
                             ((TMDS_EN != 0) ? 32'h80 : 32'h0) | ((DDC_EN != 0) ? 32'h100 : 32'h0) |
                             ((HDMI_EN != 0) ? 32'h200 : 32'h0) | ((AUD_EN != 0) ? 32'h400 : 32'h0);

//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

// Register access
wire                      reg_wr;
wire                      sel_cfg;
wire                      sel_sync;
wire                      sel_status;
wire                      sel_irq_en;
wire                      sel_irq_flag;
wire                      sel_h_act;
wire                      sel_h_blank;
wire                      sel_v_act;
wire                      sel_v_blank;
wire                      sel_img_size;
wire                      sel_img_pos;
wire                      sel_scale;
wire                      sel_border;
wire                      sel_ctrl;
wire                      sel_frames;
wire                      sel_ddc;
wire                      sel_hdmi;
wire                      sel_aud;
wire                      sel_aud_st;
wire                      sel_pkt;
wire                      sel_caps;

// Immediate fields
wire                      cfg_lcd_on;
wire                      cfg_lcd_reset;
wire                      cfg_en;

// Staged fields
wire                [9:0] st_cfg;               // {CLK_DIV, PCLK_EDGE, HS_POL, VS_POL, DE_POL, BGR, FILTER}
wire               [12:0] st_scanline;
wire               [41:0] st_h;                 // {ACT, FP, SW, BP}
wire               [41:0] st_v;
wire               [23:0] st_img;               // {W, H}
wire               [24:0] st_pos;               // {X, Y, CENTRE}
wire               [31:0] st_step;              // {X, Y}
wire               [23:0] st_border;
wire                      st_test;
wire             [CW-1:0] staged;

// Run control and update handshake
wire                      pix_en;
wire                      pix_en_nxt;
wire                      req;
wire                      upd_pend;
wire                      run_ok;               // running, and no pixel-only reset seen since
wire                      start_lock;           // a start in flight: the pixel domain may take the set
wire                      st_lock;              // the pixel domain may take the staged set
wire                      st_wr;                // staged-register write
wire                      upd_wr;

// Events from the pixel domain
wire                      fs_q;
wire                      fs_evt;
wire                      sl_q;
wire                      uf_q;
wire                      ln_q;
wire                      idn_q;

// Panel detect
wire                      det_sync;
wire                      present;
wire               [15:0] det_cnt;
wire                      det_flip;

// Interrupts
wire                [3:0] irq_en;               // [3] DETECT, [2] UNDERFLOW, [1] LINE, [0] VBLANK
wire                [3:0] irq_flag;
wire                [3:0] irq_set;
wire                [3:0] irq_flag_nxt;
wire                      irq_flag_en;
wire               [31:0] frames;

//=============================================================================
// 3)  REGISTER ACCESS
//=============================================================================

assign sel_cfg      = (reg_addr_i == A_CFG);
assign sel_sync     = (reg_addr_i == A_SYNC);
assign sel_status   = (reg_addr_i == A_STATUS);
assign sel_irq_en   = (reg_addr_i == A_IRQ_EN);
assign sel_irq_flag = (reg_addr_i == A_IRQ_FLAG);
assign sel_h_act    = (reg_addr_i == A_H_ACT);
assign sel_h_blank  = (reg_addr_i == A_H_BLANK);
assign sel_v_act    = (reg_addr_i == A_V_ACT);
assign sel_v_blank  = (reg_addr_i == A_V_BLANK);
assign sel_img_size = (reg_addr_i == A_IMG_SIZE);
assign sel_img_pos  = (reg_addr_i == A_IMG_POS);
assign sel_scale    = (reg_addr_i == A_SCALE);
assign sel_border   = (reg_addr_i == A_BORDER);
assign sel_ctrl     = (reg_addr_i == A_CTRL);
assign sel_frames   = (reg_addr_i == A_FRAMES);
assign sel_ddc      = (reg_addr_i == A_DDC);
assign sel_hdmi     = (reg_addr_i == A_HDMI);
assign sel_aud      = (reg_addr_i == A_AUD);
assign sel_aud_st   = (reg_addr_i == A_AUD_ST);
assign sel_pkt      = (reg_addr_i >= A_PKT0) & (reg_addr_i <= A_PKT0 + 6'd7);
assign sel_caps     = (reg_addr_i == A_CAPS);

// Every access completes at once
assign reg_ready_o  = reg_sel_i;
assign reg_wr       = reg_sel_i & reg_wr_i;

//-----------------------------------------------------------------------------
// DIF_CFG: [0] LCD_ON, [1] LCD_RESET, [3] DPI_EN act at once; [11:8] CLK_DIV,
// [16] PCLK_EDGE, [17] HS_POL, [18] VS_POL, [19] DE_POL, [20] BGR, [21] FILTER
// are staged
//-----------------------------------------------------------------------------
arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_cfg_imm (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_cfg),
    .d_i({reg_wdata_i[3], reg_wdata_i[1:0]}), .q_o({cfg_en, cfg_lcd_reset, cfg_lcd_on}));

arv_ipdff #(.WIDTH(10), .ARST_EN(ARST_EN)) u_st_cfg (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_cfg),
    .d_i({reg_wdata_i[11:8], reg_wdata_i[16], reg_wdata_i[17], reg_wdata_i[18], reg_wdata_i[19], reg_wdata_i[20],
          FILT_EN & reg_wdata_i[21]}),
    .q_o(st_cfg));

assign lcd_on_o      = cfg_lcd_on;
assign lcd_reset_n_o = ~cfg_lcd_reset;

//-----------------------------------------------------------------------------
// Staged registers: DIF_SYNC, timing, image, border, DPI_CTRL.TEST. Writes
// are ignored while locked (section 4)
//-----------------------------------------------------------------------------
arv_ipdff #(.WIDTH(13), .ARST_EN(ARST_EN)) u_st_scanline (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_sync), .d_i(reg_wdata_i[12:0]), .q_o(st_scanline));

arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_st_h_act (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_h_act), .d_i(reg_wdata_i[11:0]), .q_o(st_h[41:30]));

arv_ipdff #(.WIDTH(30), .ARST_EN(ARST_EN)) u_st_h_blank (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_h_blank),
    .d_i({reg_wdata_i[9:0], reg_wdata_i[19:10], reg_wdata_i[29:20]}), .q_o(st_h[29:0]));

arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_st_v_act (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_v_act), .d_i(reg_wdata_i[11:0]), .q_o(st_v[41:30]));

arv_ipdff #(.WIDTH(30), .ARST_EN(ARST_EN)) u_st_v_blank (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_v_blank),
    .d_i({reg_wdata_i[9:0], reg_wdata_i[19:10], reg_wdata_i[29:20]}), .q_o(st_v[29:0]));

generate
    if (SCALE_EN) begin : g_st_scale
        arv_ipdff #(.WIDTH(24), .ARST_EN(ARST_EN)) u_st_img (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_img_size),
            .d_i({reg_wdata_i[11:0], reg_wdata_i[27:16]}), .q_o(st_img));

        arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_st_step (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_scale),
            .d_i({reg_wdata_i[15:0], reg_wdata_i[31:16]}), .q_o(st_step));
    end else begin : g_no_st_scale
        assign st_img  = 24'd0;
        assign st_step = 32'd0;
        wire   scale_wdata_unused = reg_wdata_i[30];
    end
endgenerate

arv_ipdff #(.WIDTH(25), .RST_VAL(25'd1), .ARST_EN(ARST_EN)) u_st_pos (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_img_pos),
    .d_i({reg_wdata_i[11:0], reg_wdata_i[27:16], reg_wdata_i[31]}), .q_o(st_pos));

arv_ipdff #(.WIDTH(24), .ARST_EN(ARST_EN)) u_st_border (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_border), .d_i(reg_wdata_i[23:0]), .q_o(st_border));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_st_test (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_wr & sel_ctrl), .d_i(reg_wdata_i[1]), .q_o(st_test));

// The bundle (layout shared with blns_dpi_scan)
assign staged = {st_cfg, st_scanline, st_h, st_v, st_img, st_pos, st_step, st_border, st_test};

//=============================================================================
// 4)  RUN CONTROL AND UPDATE HANDSHAKE
//=============================================================================
// The pixel domain runs while pix_en is 1. Setting DPI_EN raises pix_en once
// the pixel domain has stopped; once raised, pix_en stays 1 until the pixel
// domain runs, so a start in flight completes (and takes the staged set)
// even when DPI_EN is cleared at once. Clearing DPI_EN then drops pix_en.
// UPDATE (while running, staging not locked) toggles the request; the pixel
// domain takes the staged set at its next frame start and acknowledges; the
// TEST bit of the UPDATE write itself is taken. An UPDATE write while staging
// is locked (pending, or the start not complete) has no effect at all. The pixel domain reads the staged set
// directly: writes to it are ignored while it may take it: from the DPI_EN
// write until the pixel domain runs, and while a request is outstanding and
// the pixel domain runs or may still run (pix_en, or running not yet seen to
// stop). UPDATE reads st_lock, 1 exactly while they are ignored. Clearing
// DPI_EN abandons an outstanding request: UPDATE reads 0 once the pixel
// domain has stopped; the next start takes the staged set and acknowledges it.
// A reset of the pixel domain alone restarts it (with DPI_EN set): from that
// reset (prst_h_i, cleared asynchronously by it in blns_dpi_cdc) the pixel
// domain counts as not running, whatever the width of the reset, so the
// start that follows is locked like any other.

assign upd_pend   = (req != ack_h_i);
assign upd_wr     = reg_wr & sel_ctrl & reg_wdata_i[0] & pix_en & ~st_lock;
assign pix_en_nxt = (cfg_en & (pix_en | ~run_h_i)) | (pix_en & ~run_h_i);
assign run_ok     = run_h_i & prst_h_i;
assign start_lock = (cfg_en & ~(pix_en & run_ok)) | (pix_en & ~run_ok);
assign st_lock    = start_lock | (upd_pend & (pix_en | run_h_i));
assign st_wr      = reg_wr & ~st_lock;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_pix_en (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(pix_en_nxt), .q_o(pix_en));

assign staged_o = staged;

// Enabling makes the request look taken (the pixel domain takes the set at its
// start and acknowledges with the current request value)
wire                      req_nxt = ~req;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_req (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(upd_wr), .d_i(req_nxt), .q_o(req));

assign pix_en_o = pix_en;
assign req_o    = req;

//=============================================================================
// 5)  EVENTS FROM THE PIXEL DOMAIN
//=============================================================================

arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_evt_q (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i({fs_h_i, sl_h_i, uf_h_i, ln_h_i, idn_h_i}),
    .q_o({fs_q, sl_q, uf_q, ln_q, idn_q}));

assign fs_evt      = (fs_h_i != fs_q);
assign fs_evt_o    = fs_evt;
assign dn_evt_o    = (idn_h_i != idn_q);            // blns_dpi_bdi drops the rest of the frame
assign line_take_o = (ln_h_i != ln_q);          // LINE / VBLANK are taken in blns_dpi_cdc

//=============================================================================
// 6)  PANEL DETECT
//=============================================================================
// PRESENT follows panel_detect_i once it has been stable for 2^16 cycles

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_det_sync (
    .clk_i   ( hclk_i         ),
    .rst_n_i ( hresetn_i      ),
    .async_i ( panel_detect_i ),
    .sync_o  ( det_sync       )
);

assign det_flip = (det_sync != present) & (det_cnt == 16'hFFFF);

wire               [15:0] det_cnt_nxt = ((det_sync == present) | det_flip) ? 16'd0 : det_cnt + 16'd1;

arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_det_cnt (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(det_cnt_nxt), .q_o(det_cnt));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_present (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(det_flip), .d_i(det_sync), .q_o(present));

//=============================================================================
// 7)  INTERRUPTS, FRAME COUNTER, STATUS, READ DATA
//=============================================================================
// DIF_IRQ_EN / DIF_IRQ_FLAG [6:3]: DETECT, UNDERFLOW, LINE, VBLANK (W1C, set wins)

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_irq_en (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_irq_en), .d_i(reg_wdata_i[6:3]), .q_o(irq_en));

assign irq_set      = {det_flip, (uf_h_i != uf_q) | abandon_i, (sl_h_i != sl_q), fs_evt & pix_en};
assign irq_flag_en  = (reg_wr & sel_irq_flag) | (|irq_set);
assign irq_flag_nxt = irq_set | (irq_flag & ~({4{reg_wr & sel_irq_flag}} & reg_wdata_i[6:3]));

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_irq_flag (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(irq_flag_en), .d_i(irq_flag_nxt), .q_o(irq_flag));

assign irq_o = |(irq_flag & irq_en);

// Panel frames since DPI_EN was set
wire                      pix_rise   = pix_en_nxt & ~pix_en;
wire               [31:0] frames_nxt = pix_rise ? 32'd0 : frames + 32'd1;

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_frames (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i((fs_evt & pix_en) | pix_rise),
    .d_i(frames_nxt), .q_o(frames));

wire                      busy = cfg_en | pix_en | run_h_i;

// The clock request also holds while an event toggle from the pixel domain is
// pending here, and for one cycle after running is seen to fall: a toggle made
// on the stop edge crosses with running's fall, at most one edge after it
// (each synchroniser bit on its own), and must still set its flag with a gated
// clock; and while AUD crosses (its handshake needs the clock)
wire                      run_h_q;
wire                      aud_bsy;              // AUD crossing (HDMI audio, section below)
wire                      evt_pend = (fs_h_i != fs_q) | (sl_h_i != sl_q) | (uf_h_i != uf_q) | (ln_h_i != ln_q) |
                                     (idn_h_i != idn_q);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_run_h_q (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(run_h_i), .q_o(run_h_q));

assign busy_o = busy | run_h_q | evt_pend | active_i | irq_en[3] | aud_bsy;

wire               [31:0] cfg_rd    = {10'd0, st_cfg[0], st_cfg[1], st_cfg[2], st_cfg[3], st_cfg[4], st_cfg[5],
                                       4'd0, st_cfg[9:6], 4'd0, cfg_en, 1'b0, cfg_lcd_reset, cfg_lcd_on};
wire               [31:0] status_rd = {3'd0, line_h_i, 7'd0, present, vblank_h_i, 3'd0, active_i, 2'd0, busy};
wire               [31:0] ddc_rd;
wire               [31:0] hdmi_rd;
wire               [31:0] aud_rd;

assign reg_rdata_o = ({32{sel_cfg}}      & cfg_rd)                                                   |
                     ({32{sel_sync}}     & {19'd0, st_scanline})                                     |
                     ({32{sel_status}}   & status_rd)                                                |
                     ({32{sel_irq_en}}   & {25'd0, irq_en, 3'd0})                                    |
                     ({32{sel_irq_flag}} & {25'd0, irq_flag, 3'd0})                                  |
                     ({32{sel_h_act}}    & {20'd0, st_h[41:30]})                                     |
                     ({32{sel_h_blank}}  & {2'd0, st_h[9:0], st_h[19:10], st_h[29:20]})             |
                     ({32{sel_v_act}}    & {20'd0, st_v[41:30]})                                     |
                     ({32{sel_v_blank}}  & {2'd0, st_v[9:0], st_v[19:10], st_v[29:20]})             |
                     ({32{sel_img_size}} & {4'd0, st_img[11:0], 4'd0, st_img[23:12]})               |
                     ({32{sel_img_pos}}  & {st_pos[0], 3'd0, st_pos[12:1], 4'd0, st_pos[24:13]})     |
                     ({32{sel_scale}}    & {st_step[15:0], st_step[31:16]})                          |
                     ({32{sel_border}}   & {8'd0, st_border})                                        |
                     ({32{sel_ctrl}}     & {30'd0, st_test, st_lock})                                |
                     ({32{sel_frames}}   & frames)                                                   |
                     ({32{sel_ddc}}      & ddc_rd)                                                   |
                     hdmi_rd                                                                         |
                     aud_rd                                                                          |
                     ({32{sel_caps}}     & CAPS)                                                     ;

//-----------------------------------------------------------------------------
// DPI_DDC: [0] SCL, [1] SDA pulled low (1) or released (0), reset released;
// [8] SCL, [9] SDA line levels. Software runs the I2C master.
//-----------------------------------------------------------------------------
generate
    if (DDC_EN != 0) begin : g_ddc
        wire [1:0] ddc_pd;
        wire [1:0] ddc_in;
        arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_ddc_pd (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_ddc), .d_i(reg_wdata_i[1:0]), .q_o(ddc_pd));
        arv_synchronizer #(.W(2), .RST_VAL(2'b11), .ARST_EN(ARST_EN)) u_ddc_sync (
            .clk_i   ( hclk_i                 ),
            .rst_n_i ( hresetn_i              ),
            .async_i ( {ddc_sda_i, ddc_scl_i} ),
            .sync_o  ( ddc_in                 )
        );
        assign ddc_scl_pd_o = ddc_pd[0];
        assign ddc_sda_pd_o = ddc_pd[1];
        assign ddc_rd       = {22'd0, ddc_in, 6'd0, ddc_pd};
    end else begin : g_no_ddc
        assign ddc_scl_pd_o = 1'b0;
        assign ddc_sda_pd_o = 1'b0;
        assign ddc_rd       = 32'd0;
        wire   ddc_unused   = ddc_scl_i | ddc_sda_i | sel_ddc;
    end
endgenerate

//-----------------------------------------------------------------------------
// DPI_HDMI: [0] HDMI (guard bands, data islands), [1] AVI (the AVI InfoFrame
// once per frame), [5:4] PICTURE, [7:6] QUANT, [11:8] ACTIVE, [22:16] VIC:
// its fields, copied by the pixel domain at an UPDATE and when AVI rises
// (blns_dpi)
//-----------------------------------------------------------------------------
wire               [16:0] hdmi_cfg;     // {QUANT, VIC, ACTIVE, PICTURE, AVI, HDMI}

generate
    if (HDMI_EN != 0) begin : g_hdmi_regs
        // The fields are not written while the pixel domain may take them:
        // during a start (start_lock, as the staged set: a start takes them),
        // and while AVI is on and an UPDATE is pending and the pixel domain
        // runs or may still run (it takes them at that UPDATE's frame start);
        // an abandoned request stops locking them once the pixel domain has
        // stopped
        wire   fld_lock = start_lock | (hdmi_cfg[1] & upd_pend & (pix_en | run_h_i));
        arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_hdmi_ctl (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_hdmi),
            .d_i(reg_wdata_i[1:0]), .q_o(hdmi_cfg[1:0]));
        arv_ipdff #(.WIDTH(15), .ARST_EN(ARST_EN)) u_hdmi_fld (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_hdmi & ~fld_lock),
            .d_i({reg_wdata_i[7:6], reg_wdata_i[22:16], reg_wdata_i[11:8], reg_wdata_i[5:4]}),
            .q_o(hdmi_cfg[16:2]));
        assign hdmi_rd = {32{sel_hdmi}} & {9'd0, hdmi_cfg[14:8], 4'd0, hdmi_cfg[7:4], hdmi_cfg[16:15], hdmi_cfg[3:2],
                                           2'd0, hdmi_cfg[1:0]};
    end else begin : g_no_hdmi_regs
        assign hdmi_cfg = 17'd0;
        assign hdmi_rd  = 32'd0;
        wire   hdmi_sel_unused = sel_hdmi;
    end
endgenerate

assign hdmi_cfg_o = hdmi_cfg;

//-----------------------------------------------------------------------------
// HDMI audio (AUD_EN): DPI_HDMI [2] AUD (audio sample, clock regeneration
// and audio InfoFrame packets), [3] GP (the generic packet once per frame);
// DPI_AUD [19:7] N / 128 ([6:0] read 0: N is a multiple of 128, the CTS
// measurement spans N / 128 frames), [27:24] channel-status sampling
// frequency, [31:28] word length, read by the pixel domain while audio is on
// there (not written then, see below); DPI_AUD_STAT [19:0] the last CTS
// measured, [24] a frame lost since audio started, [25] audio on in the pixel
// domain; DPI_PKT0 [23:0] the generic packet's header, DPI_PKT1-7 PB0-PB27,
// read by the pixel domain while GP is set (not written then)
//-----------------------------------------------------------------------------
generate
    if (AUD_EN != 0) begin : g_aud_regs
        wire        [2:0] pk_i = reg_addr_i[2:0] - A_PKT0[2:0];
        wire        [1:0] aud_ctl;                  // {GP, AUD} as written
        wire              aud_x;                    // AUD for the pixel domain
        wire              aud_lock;                 // the pixel domain may read DPI_AUD
        wire              aud_busy;                 // AUD still crossing (keeps the clock)
        arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_aud_ctl (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_hdmi), .d_i(reg_wdata_i[3:2]), .q_o(aud_ctl));
        if (SEP_EN != 0) begin : g_aud_hs
            // AUD crosses as a level handshake: aud_x follows AUD only once
            // the pixel domain's copy (aud_echo_h_i, a register there,
            // synchronised back) has followed aud_x, so even a short AUD
            // pulse reaches the pixel domain whole. DPI_AUD is not written
            // while AUD, aud_x or that copy is set: the pixel domain reads it
            // only while its AUD (or the copy) is set, and its AUD cannot
            // rise again before aud_x does
            wire aud_x_nxt = (aud_x == aud_echo_h_i) ? aud_ctl[0] : aud_x;
            arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_aud_x (
                .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(aud_x_nxt), .q_o(aud_x));
            assign aud_lock = aud_ctl[0] | aud_x | aud_echo_h_i;
            assign aud_busy = (aud_x != aud_echo_h_i) | (aud_ctl[0] != aud_x);
        end else begin : g_aud_same
            // One clock: AUD at once; DPI_AUD not written while AUD is set or
            // audio is still on (the pixel domain reads it until then)
            assign aud_x    = aud_ctl[0];
            assign aud_lock = aud_ctl[0] | aud_st_h_i[1];
            assign aud_busy = 1'b0;
            wire   echo_unused = aud_echo_h_i;
        end
        assign aud_ctl_o = {aud_ctl[1], aud_x};
        assign aud_bsy   = aud_busy;
        wire [20:0] aud_cfg_q;
        arv_ipdff #(.WIDTH(21), .ARST_EN(ARST_EN)) u_aud_cfg (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_wr & sel_aud & ~aud_lock),
            .d_i({reg_wdata_i[31:24], reg_wdata_i[19:7]}), .q_o(aud_cfg_q));
        assign aud_cfg_o = {aud_cfg_q, 7'd0};
        // The packet is not written while GP is on
        wire   pkt_wr = reg_wr & sel_pkt & ~aud_ctl_o[1];
        arv_ipdff #(.WIDTH(24), .ARST_EN(ARST_EN)) u_pkt0 (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(pkt_wr & (pk_i == 3'd0)),
            .d_i(reg_wdata_i[23:0]), .q_o(gp_pkt_o[23:0]));
        genvar gp;
        for (gp = 1; gp < 8; gp = gp + 1) begin : g_pkt
            arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_pkt (
                .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(pkt_wr & (pk_i == gp)),
                .d_i(reg_wdata_i), .q_o(gp_pkt_o[24 + 32 * (gp - 1) +: 32]));
        end
        wire [31:0] pkt_w  = ({32{pk_i == 3'd0}} & {8'd0, gp_pkt_o[23:0]}) | ({32{pk_i == 3'd1}} & gp_pkt_o[55:24])   |
                             ({32{pk_i == 3'd2}} & gp_pkt_o[87:56])        | ({32{pk_i == 3'd3}} & gp_pkt_o[119:88])  |
                             ({32{pk_i == 3'd4}} & gp_pkt_o[151:120])      | ({32{pk_i == 3'd5}} & gp_pkt_o[183:152]) |
                             ({32{pk_i == 3'd6}} & gp_pkt_o[215:184])      | ({32{pk_i == 3'd7}} & gp_pkt_o[247:216]) ;
        assign      aud_rd = ({32{sel_hdmi}}   & {28'd0, aud_ctl, 2'd0})                    |
                             ({32{sel_aud}}    & {aud_cfg_o[27:20], 4'd0, aud_cfg_o[19:0]}) |
                             ({32{sel_aud_st}} & {6'd0, aud_st_h_i, 4'd0, cts_h_i})        |
                             ({32{sel_pkt}}    & pkt_w)                                     ;
    end else begin : g_no_aud_regs
        assign aud_ctl_o = 2'd0;
        assign aud_bsy   = 1'b0;
        assign aud_cfg_o = 28'd0;
        assign gp_pkt_o  = 248'd0;
        assign aud_rd    = 32'd0;
        wire   aud_unused = sel_aud | sel_aud_st | sel_pkt | (|aud_st_h_i) | (|cts_h_i) | aud_echo_h_i;
    end
endgenerate

endmodule // blns_dpi_regs

`default_nettype wire
