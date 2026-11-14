//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dpi_scan
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dpi_scan.v
// Module Description : Pixel-clock domain of the MIPI-DPI driver: the panel
//                      timing, the line-buffer reads and releases, the image
//                      placement and scaling (nearest neighbour, optional
//                      bilinear) and the registered panel outputs. Every
//                      input from blns_dpi is either synchronised (toggles,
//                      levels) or stable while it is read (configuration,
//                      tags, frame size).
//
//                      Pixel pipeline, one stage per pixel step (pe):
//                        S0  position of the pixel, line-buffer read address
//                        S1  controls; read data (CLK_DIV >= 1)
//                        S2  read data (CLK_DIV = 0), bilinear neighbours
//                        S3  horizontal blend of both lines
//                        S4  vertical blend, border / test colour
//                        S5  output registers
//----------------------------------------------------------------------------
`default_nettype none
module  blns_dpi_scan #(
    parameter                 DIM_W        = 10,    // width/height field width
    parameter                 LB_AW        = 10,    // line-buffer address width
    parameter                 NB           = 2,     // line-buffer banks (2, or 3 for bilinear)
    parameter                 SCALER       = 1,     // 0 none, 1 nearest, 2 nearest and bilinear
    parameter                 CW           = 213,   // configuration bundle width
    parameter                 PRE_EN       = 0,     // 1 = the HDMI video preamble and guard band windows
    parameter                 ARST_EN      = 1      // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               pclk_i,               // pixel-domain clock
    input  wire               presetn_i,            // pixel-domain reset (active low)
// From the register side (synchronised levels and toggles)
    input  wire               en_i,                 // DPI_EN
    input  wire               req_i,                // configuration request toggle
    input  wire      [CW-1:0] staged_i,             // staged configuration (stable while requested)
    input  wire               sz_req_i,             // frame-size toggle
    input  wire   [DIM_W-1:0] sz_w_i,               // frame line length (stable while requested)
    input  wire   [DIM_W-1:0] sz_h_i,               // frame line count
    input  wire      [NB-1:0] fill_i,               // bank fill toggles
    input  wire [NB*(DIM_W+1)-1:0] tag_i,           // bank tags {epoch, line} (stable while full)
// To the register side
    output wire               run_o,                // panel timing running
    output wire               ack_o,                // configuration acknowledge toggle
    output wire               apply_o,              // the staged configuration is taken (one clock)
    output wire               sz_ack_o,             // frame-size acknowledge toggle
    output wire      [NB-1:0] rel_o,                // bank release toggles
    output wire               fs_o,                 // frame-start toggle (the frame epoch)
    output wire               sl_o,                 // SCANLINE toggle
    output wire               uf_o,                 // underflow toggle
    output wire               idn_o,                // image done toggle: no later line of the frame is needed
    output wire               ln_o,                 // line toggle (LINE snapshot)
    output wire        [12:0] line_o,               // line being sent (stable for a line)
    output wire               vblank_o,             // vertical blanking (stable for a line)
// Line-buffer read port
    output wire   [LB_AW-1:0] lb_raddr_o,
    input  wire     [NB*24-1:0] lb_rdata_i,
// Panel
    output wire               dpi_de_o,
    output wire               dpi_hs_o,
    output wire               dpi_vs_o,
    output wire        [23:0] dpi_rgb_o,
    output wire               dpi_clk_d0_o,
    output wire               dpi_clk_d1_o,
    output wire               tmds_de_o,            // data enable, active high, with the panel outputs
    output wire               vpre_o,               // the 8 pixels before an active line's guard band (PRE_EN)
    output wire               vguard_o,             // the 2 pixels before an active line (PRE_EN)
    output wire               hbl_o,                // the first horizontal blanking pixel of a line (PRE_EN)
    output wire         [1:0] isl_o,                // data island packets the horizontal blanking holds (0-2, PRE_EN)
    output wire               div0_o                // CLK_DIV = 0: one pixel per clock
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================

localparam             SCALE_EN = (SCALER != 0);
localparam             FILT_EN  = (SCALER == 2);
localparam             TW       = DIM_W + 1;        // tag width {epoch, line}

// Configuration bundle (built by blns_dpi_regs): the bit offset of each field
localparam             B_TEST   = 0;                //  1: DPI_CTRL.TEST
localparam             B_BORDER = 1;                // 24: DPI_BORDER
localparam             B_STEP   = 25;               // 32: DPI_SCALE {X, Y}
localparam             B_POS    = 57;               // 25: DPI_IMG_POS {X, Y, CENTRE}
localparam             B_IMG    = 82;               // 24: DPI_IMG_SIZE {W, H}
localparam             B_V      = 106;              // 42: DPI_V_ACT, DPI_V_BLANK {ACT, FP, SW, BP}
localparam             B_H      = 148;              // 42: DPI_H_ACT, DPI_H_BLANK
localparam             B_SCAN   = 190;              // 13: DIF_SYNC
localparam             B_CFG    = 203;              // 10: DIF_CFG {CLK_DIV, PCLK_EDGE, HS_POL, VS_POL, DE_POL, BGR, FILTER}

// pragma translate_off
generate
    if (CW != B_CFG + 10) begin : CHECK_CW
        initial $fatal(1, "blns_dpi_scan: the configuration bundle is %0d bits, its fields %0d.", CW, B_CFG + 10);
    end
endgenerate
// pragma translate_on

// One-hot of the full banks holding line {ep, line}
function [NB-1:0] bank_of;
    input [NB*TW-1:0] tags;
    input    [NB-1:0] fl;
    input             ep;
    input [DIM_W-1:0] line;
    integer           k;
    begin
        for (k = 0; k < NB; k = k + 1)
            bank_of[k] = fl[k] & (tags[k*TW +: TW] == {ep, line});
    end
endfunction

//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

// Run control
wire                      run;
wire                      en_q;
wire                      start;                // first cycle of a run
wire                      stop;

// Applied configuration
wire                      apply;                // take the staged configuration
wire             [CW-1:0] cur;
wire                      ack;
wire                      fl_go;                // a frame start if this pixel ends a line
wire                      apply_l;              // the staged configuration taken if it does
wire             [CW-1:0] cfg_g;                // the configuration from a frame start
wire             [CW-1:0] cfg_st;               // the configuration from the next cycle while stopped

// Configuration fields (of cur, and of the next set at a frame start)
wire                [3:0] c_div;
wire                      c_edge;
wire                      c_hs_pol;
wire                      c_vs_pol;
wire                      c_de_pol;
wire                      c_bgr;
wire               [12:0] c_scanline;
wire               [11:0] c_h_act;
wire               [11:0] c_v_act;
wire               [23:0] c_border;
wire                      c_test;
wire               [11:0] n_v_act;
wire               [11:0] n_img_w;
wire               [11:0] n_img_h;
wire               [11:0] n_pos_x;
wire               [11:0] n_pos_y;
wire                      n_centre;
wire               [15:0] n_step_x;
wire               [15:0] n_step_y;
wire                      n_filter;
wire                      n_hs_pol;
wire                      n_vs_pol;
wire                      n_de_pol;
wire               [11:0] n_h_act;

// Timing
wire                [3:0] pcnt;
wire                [3:0] pcnt_nxt;
wire                      pe;
wire                      run_nxt;
wire                [1:0] ck_cur;               // the clock halves' next values, current divider
wire                [1:0] ck_stg;               // and with the staged one
wire                [1:0] ck_nxt;
wire               [12:0] hcnt;
wire               [12:0] vcnt;
wire               [12:0] hcnt_nxt;
wire               [12:0] vcnt_nxt;
wire               [12:0] h_ss;
wire               [12:0] h_se;
wire               [12:0] h_tm1;
wire               [12:0] v_ss;
wire               [12:0] v_se;
wire               [12:0] v_tm1;
wire               [12:0] v_am1;
wire               [90:0] tim_nxt;
wire               [12:0] v_tm1_n;
wire                      h_end_nxt;
wire                      h_end;
wire                      v_end;
wire                      frame_go;
wire                      line_go;
wire                      h_act;
wire                      v_act;
wire                      h_sync;
wire                      v_sync;

// Frame size
wire                      sz_ack;
wire          [DIM_W-1:0] src_w;
wire          [DIM_W-1:0] src_h;

// Frame geometry (taken at the frame start)
wire               [12:0] img_w;
wire               [12:0] img_h;
wire               [12:0] x0;
wire               [12:0] y0;
wire               [15:0] stp_x;
wire               [15:0] stp_y;
wire                      fil_x;
wire                      fil_y;
wire               [12:0] g_img_w;
wire               [12:0] g_img_h;
wire               [12:0] g_x0;
wire               [12:0] g_y0;
wire               [15:0] g_stp_x;
wire               [15:0] g_stp_y;

// Position
wire               [27:0] fx;
wire               [27:0] fy;
wire               [27:0] fx_nxt;
wire               [27:0] fy_nxt;
wire               [27:0] fy_1;                 // fy + step
wire               [27:0] fy_2;                 // fy + 2 steps
wire          [DIM_W-1:0] sx;
wire          [DIM_W-1:0] sx1;
wire          [DIM_W-1:0] sy;
wire          [DIM_W-1:0] sy1;
wire          [DIM_W-1:0] sy_next;
wire          [DIM_W-1:0] nl_row;               // source line of the line after the current one
wire                      in_x;
wire                      in_y;
wire                      in_img;
wire                [3:0] wx;
wire                [3:0] wy;
wire          [DIM_W-1:0] sx_prev;
wire                      sx_new;

// Banks
wire                      epoch;
wire             [NB-1:0] rel;
wire             [NB-1:0] full;
wire             [NB-1:0] rel_en;
wire             [NB-1:0] bk0;
wire             [NB-1:0] bk1;
wire                      ok0;
wire                      ok1;
wire                      valid;
wire            [DIM_W:0] need_lo;
wire            [DIM_W:0] need_lo_nxt;
wire                      need_en;
wire               [16:0] skip_hi;
wire               [16:0] skip_hi_nxt;
wire                      uf_seen;
wire                      uf_hit;
wire                      uf;
wire                      dsent;                // the image done event of the frame was sent
wire                      dn_hit;
wire                      idn;
wire                      sl;
wire                      ln;

// Test bars
wire               [11:0] bar_w;
wire               [11:0] bar_cnt;
wire                [2:0] bar_idx;

// Pipeline
wire                      s1_de;
wire                      s1_hs;
wire                      s1_vs;
wire                      s1_img;
wire                      s1_ok;
wire                      s1_new;
wire                [2:0] s1_bar;
wire             [NB-1:0] s1_bk0;
wire             [NB-1:0] s1_bk1;
wire                [3:0] s1_wx;
wire                [3:0] s1_wy;
wire               [23:0] s1_d0;
wire               [23:0] s1_d1;
wire                      s2_de;
wire                      s2_hs;
wire                      s2_vs;
wire                      s2_img;
wire                      s2_ok;
wire                [2:0] s2_bar;
wire                [3:0] s2_wx;
wire                [3:0] s2_wy;
wire               [23:0] s2_a0;
wire               [23:0] s2_b0;
wire               [23:0] s2_a1;
wire               [23:0] s2_b1;
wire                      s3_de;
wire                      s3_hs;
wire                      s3_vs;
wire                      s3_img;
wire                      s3_ok;
wire                [2:0] s3_bar;
wire                [3:0] s3_wy;
wire               [35:0] s3_h0;
wire               [35:0] s3_h1;
wire                      s4_de;
wire                      s4_hs;
wire                      s4_vs;
wire               [23:0] s4_rgb;
wire               [23:0] rd0;
wire               [23:0] rd1;
wire               [23:0] d0_now;
wire               [23:0] d1_now;
wire               [23:0] a0_nxt;
wire               [23:0] b0_nxt;
wire               [23:0] a1_nxt;
wire               [23:0] b1_nxt;
wire               [35:0] h0_nxt;
wire               [35:0] h1_nxt;
wire               [23:0] blend;
wire               [23:0] bar_rgb;
wire               [23:0] px_rgb;
wire               [23:0] out_rgb;
wire                      tmds_de_nxt;
wire                      out_de;
wire                      out_hs;
wire                      out_vs;
wire                      ddr;
wire                [1:0] dpi_clk;              // {d1, d0}

//=============================================================================
// 3)  RUN CONTROL AND CONFIGURATION
//=============================================================================
// A run starts in the first line of the vertical blanking, with the staged
// configuration; a stop is immediate. The staged configuration is taken at
// the start and, when requested, at every frame start.

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_en_q (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(en_i), .q_o(en_q));

assign start = en_i & ~en_q;
assign stop  = ~en_i;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_run (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | stop), .d_i(en_i), .q_o(run));

assign apply   = start | (frame_go & (req_i != ack));

// The data of the registers taken only at a line start (line_go) or at the
// start: built as if this pixel ended a line, so that the pixel step (pe) is
// not in their cone. The fields of the next set (n_*) are used only at a
// frame start, where the set taken is the staged one if requested
assign fl_go   = start | (vcnt == v_am1);
assign apply_l = start | (fl_go & (req_i != ack));
assign cfg_g   = (start | (req_i != ack)) ? staged_i : cur;
assign cfg_st  = start ? staged_i : cur;

arv_ipdff #(.WIDTH(CW), .ARST_EN(ARST_EN)) u_cur (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(apply), .d_i(staged_i), .q_o(cur));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ack (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(apply), .d_i(req_i), .q_o(ack));

assign ack_o   = ack;
assign apply_o = apply;
assign run_o = run;

// Fields, in the order of blns_dpi's bundle (n_*: from a frame start, or for
// the idle polarities from the next cycle while stopped)
assign {c_div, c_edge, c_hs_pol, c_vs_pol, c_de_pol, c_bgr} = cur[B_CFG+1 +: 9];
assign c_scanline = cur[B_SCAN +: 13];
assign c_h_act    = cur[B_H+30 +: 12];
assign c_v_act    = cur[B_V+30 +: 12];
assign c_border = cur[B_BORDER +: 24];
assign c_test   = cur[B_TEST];

assign n_filter = cfg_g[B_CFG];
assign {n_hs_pol, n_vs_pol, n_de_pol} = cfg_st[B_CFG+2 +: 3];
assign n_h_act  = cfg_g[B_H+30 +: 12];
assign n_v_act  = cfg_g[B_V+30 +: 12];
assign {n_img_w, n_img_h}           = cfg_g[B_IMG +: 24];
assign {n_pos_x, n_pos_y, n_centre} = cfg_g[B_POS +: 25];
assign {n_step_x, n_step_y}         = cfg_g[B_STEP +: 32];

wire             [CW-1:0] cfg_unused = cur & cfg_g & cfg_st;   // each set is read in part
wire               [56:0] scale_unused = {n_filter, n_img_w, n_img_h, n_step_x, n_step_y};

//=============================================================================
// 4)  PANEL TIMING
//=============================================================================
// pe: one pixel every c_div + 1 cycles. The panel clock is low for the first
// ceil((c_div + 1) / 2) cycles of a pixel (inverted by c_edge). With c_div = 0
// the panel clock is the pixel-domain clock itself through the DDR output
// register (section 9).

assign pe       = (pcnt >= c_div);
assign pcnt_nxt = (pe | ~run) ? 4'd0 : pcnt + 4'd1;
assign ddr      = (c_div == 4'd0);

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_pcnt (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(pcnt_nxt), .q_o(pcnt));

// Sync start / end and last count of a line and a frame, from the staged
// set when it is taken; h_end (last pixel of the line) one pixel ahead
wire               [41:0] p_h = staged_i[B_H +: 42];
wire               [41:0] p_v = staged_i[B_V +: 42];
wire               [12:0] p_h_ss = {1'b0, p_h[41:30]} + {3'd0, p_h[29:20]};
wire               [12:0] p_h_se = p_h_ss + {3'd0, p_h[19:10]};
wire               [12:0] p_v_ss = {1'b0, p_v[41:30]} + {3'd0, p_v[29:20]};
wire               [12:0] p_v_se = p_v_ss + {3'd0, p_v[19:10]};
// The frame starts after the last active line, or with no active line
// (V_ACT = 0) after the last line of the frame
wire               [12:0] p_v_tm1 = p_v_se + {3'd0, p_v[9:0]} - 13'd1;
assign tim_nxt = {p_h_ss, p_h_se, p_h_se + {3'd0, p_h[9:0]} - 13'd1,
                  p_v_ss, p_v_se, p_v_tm1, (p_v[41:30] == 12'd0) ? p_v_tm1 : {1'b0, p_v[41:30]} - 13'd1};

arv_ipdff #(.WIDTH(91), .ARST_EN(ARST_EN)) u_tim (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(apply), .d_i(tim_nxt),
    .q_o({h_ss, h_se, h_tm1, v_ss, v_se, v_tm1, v_am1}));

// h_end is taken at a pixel step, where apply is a line end with fl_go; the
// line count is then 0, so the new line is one pixel long only when its
// total is
wire                      apply_h   = start | (h_end & apply_l);
assign v_tm1_n   = apply_l ? tim_nxt[25:13] : v_tm1;
assign h_end_nxt = apply_h ? (tim_nxt[64:52] == 13'd0) : (hcnt_nxt >= h_tm1);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_h_end (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | (run & pe)), .d_i(h_end_nxt), .q_o(h_end));

assign v_end    = (vcnt >= v_tm1);
assign line_go  = run & pe & h_end;
assign frame_go = start | (line_go & (vcnt == v_am1));

assign hcnt_nxt = (start | h_end) ? 13'd0 : hcnt + 13'd1;
assign vcnt_nxt = fl_go ? {1'b0, n_v_act} : v_end ? 13'd0 : vcnt + 13'd1;      // at a line start

arv_ipdff #(.WIDTH(13), .ARST_EN(ARST_EN)) u_hcnt (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | (run & pe)), .d_i(hcnt_nxt), .q_o(hcnt));

arv_ipdff #(.WIDTH(13), .ARST_EN(ARST_EN)) u_vcnt (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | line_go), .d_i(vcnt_nxt), .q_o(vcnt));

assign h_act  = (hcnt < {1'b0, c_h_act});
assign v_act  = (vcnt < {1'b0, c_v_act});
assign h_sync = (hcnt >= h_ss) & (hcnt < h_se);
// VSYNC changes with the HSYNC leading edge (CEA-861): before it, a line still
// carries the previous line's VSYNC. The first active line (vcnt 0) starts
// with VSYNC as its own, so that a vertical back porch of 0 does not hold
// VSYNC through its active pixels; with a back porch the two are the same.
// The previous line's VSYNC is only taken with vcnt != 0, where vcnt - 1
// does not wrap: v_ss <= vcnt - 1 < v_se is v_ss < vcnt <= v_se.
assign        v_sync   = ((hcnt >= h_ss) | (vcnt == 13'd0)) ? ((vcnt >= v_ss) & (vcnt <  v_se)) :
                                                              ((vcnt >  v_ss) & (vcnt <= v_se)) ;

//=============================================================================
// 5)  FRAME SIZE AND GEOMETRY
//=============================================================================

wire                      sz_en = (sz_req_i != sz_ack);

arv_ipdff #(.WIDTH(2*DIM_W+1), .ARST_EN(ARST_EN)) u_size (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(sz_en),
    .d_i({sz_req_i, sz_w_i, sz_h_i}), .q_o({sz_ack, src_w, src_h}));

assign sz_ack_o = sz_ack;

// Image size: DPI_IMG_SIZE, or the frame size (always without a scaler)
wire               [16:0] src_w17 = {{(17-DIM_W){1'b0}}, src_w};
wire               [16:0] src_h17 = {{(17-DIM_W){1'b0}}, src_h};
wire               [16:0] iw17    = (SCALE_EN && (n_img_w != 12'd0)) ? {5'd0, n_img_w} : src_w17;
wire               [16:0] ih17    = (SCALE_EN && (n_img_h != 12'd0)) ? {5'd0, n_img_h} : src_h17;
wire               [12:0] act_w   = {1'b0, n_h_act};
wire               [12:0] act_h   = {1'b0, n_v_act};

assign g_img_w = (iw17 > {4'd0, act_w}) ? act_w : iw17[12:0];
assign g_img_h = (ih17 > {4'd0, act_h}) ? act_h : ih17[12:0];
// Centred: half the active size less the clamped image size, i.e. 0 when
// the image is the larger, from one subtract (its borrow is the clamp)
wire               [16:0] cx_d    = {4'd0, act_w} - iw17;
wire               [16:0] cy_d    = {4'd0, act_h} - ih17;
wire                [5:0] c_d_unused = {cx_d[15:14], cx_d[0], cy_d[15:14], cy_d[0]};
assign g_x0    = n_centre ? (cx_d[16] ? 13'd0 : cx_d[13:1]) : {1'b0, n_pos_x};
assign g_y0    = n_centre ? (cy_d[16] ? 13'd0 : cy_d[13:1]) : {1'b0, n_pos_y};
assign g_stp_x = (SCALE_EN && (n_step_x != 16'd0)) ? n_step_x : 16'h1000;
assign g_stp_y = (SCALE_EN && (n_step_y != 16'd0)) ? n_step_y : 16'h1000;

arv_ipdff #(.WIDTH(4*13+2*16+2), .ARST_EN(ARST_EN)) u_geom (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(frame_go),
    .d_i({g_img_w, g_img_h, g_x0, g_y0, g_stp_x, g_stp_y,
          FILT_EN & n_filter & (g_stp_x <= 16'h1000), FILT_EN & n_filter & (g_stp_y <= 16'h1000)}),
    .q_o({img_w, img_h, x0, y0, stp_x, stp_y, fil_x, fil_y}));

//=============================================================================
// 6)  SOURCE POSITION
//=============================================================================
// fx / fy: source position of the current pixel / line in 16.12 fixed point,
// 0 at the image's first pixel / line, plus the step per pixel / line.

assign fx_nxt = (start | (hcnt_nxt <= x0)) ? 28'd0 : fx + {12'd0, stp_x};
// The next line when this one does not end the frame: the source-line
// registers below take 0 at a frame start whatever it is
wire               [12:0] vcnt_ln = v_end ? 13'd0 : vcnt + 13'd1;
wire                      fy_zero = fl_go | (vcnt_ln <= y0);
assign fy_nxt = fy_zero ? 28'd0 : fy_1;

// fy + step (fy_1) and fy + 2 steps (fy_2), registers taken with fy: the
// next-line registers below (need_lo, skip_hi, nl_row) read them without an
// add. With fy they take the step of the line they belong to: the new
// geometry's at a frame start (fl_go, where u_geom takes it), else the
// current one
wire               [15:0] stp_n    = fl_go ? g_stp_y : stp_y;
wire               [27:0] fy_1_nxt = fy_zero ? {12'd0, stp_n} : fy_2;
wire               [27:0] fy_2_nxt = fy_zero ? {11'd0, stp_n, 1'b0} : fy_2 + {12'd0, stp_y};

arv_ipdff #(.WIDTH(56), .ARST_EN(ARST_EN)) u_fy12 (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | line_go), .d_i({fy_2_nxt, fy_1_nxt}), .q_o({fy_2, fy_1}));

arv_ipdff #(.WIDTH(28), .ARST_EN(ARST_EN)) u_fx (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | (run & pe)), .d_i(fx_nxt), .q_o(fx));

arv_ipdff #(.WIDTH(28), .ARST_EN(ARST_EN)) u_fy (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | line_go), .d_i(fy_nxt), .q_o(fy));

// Clamped to the frame
wire               [15:0] fxi  = fx[27:12];
wire               [15:0] fyi  = fy[27:12];
wire               [16:0] wm1  = src_w17 - 17'd1;
wire               [16:0] hm1  = src_h17 - 17'd1;

assign sx      = ({1'b0, fxi}  > wm1) ? wm1[DIM_W-1:0] : fxi[DIM_W-1:0];
assign sy      = ({1'b0, fyi}  > hm1) ? hm1[DIM_W-1:0] : fyi[DIM_W-1:0];
// The next line's candidates clamped beside the line decisions that pick them
// (fy_1: the next line, fy_2: the one after, the step: the image's second line
// from its first); a clamped 0 is 0
wire               [16:0] c_fy1 = ({1'b0, fy_1[27:12]} > hm1) ? hm1 : {1'b0, fy_1[27:12]};
wire               [16:0] c_fy2 = ({1'b0, fy_2[27:12]} > hm1) ? hm1 : {1'b0, fy_2[27:12]};
wire               [16:0] c_stp = ({13'd0, stp_y[15:12]} > hm1) ? hm1 : {13'd0, stp_y[15:12]};
assign sy_next = fy_zero ? {DIM_W{1'b0}} : c_fy1[DIM_W-1:0];
wire          [16-DIM_W:0] c_fy1_unused = c_fy1[16:DIM_W];
wire                [7:0] fy_unused    = fy[7:0];          // the next lines are read from fy_1 / fy_2
assign sx1     = (fil_x && ({{(17-DIM_W){1'b0}}, sx} < wm1)) ? sx + 1'b1 : sx;

// The lines of the pixel; on the last pixel of a line the bilinear priming
// read (see below) is for the next line
wire          [DIM_W-1:0] sy_sel = (fil_x & h_end) ? nl_row : sy;
assign sy1     = (fil_y && ({{(17-DIM_W){1'b0}}, sy_sel} < hm1)) ? sy_sel + 1'b1 : sy_sel;
assign wx      = fil_x ? fx[11:8] : 4'd0;
assign wy      = fil_y ? fy[11:8] : 4'd0;

assign in_x   = (hcnt >= x0) & (hcnt < x0 + img_w) & h_act;
assign in_y   = (vcnt >= y0) & (vcnt < y0 + img_h) & v_act;
assign in_img = in_x & in_y;

// Line-buffer read address: the pixel itself, or with bilinear its right
// neighbour (the pixel is then the previous read; address 0 outside the image
// primes the first one). Pixels past the line buffer are not kept.
wire          [DIM_W-1:0] raddr   = fil_x ? (in_img ? sx1 : {DIM_W{1'b0}}) : sx;
wire                      in_lb_x = ((fil_x ? sx1 : sx) >> LB_AW) == {DIM_W{1'b0}};
generate
    if (DIM_W > LB_AW) begin : g_ra_trunc
        assign lb_raddr_o = raddr[LB_AW-1:0];
        wire   [DIM_W-LB_AW-1:0] raddr_unused = raddr[DIM_W-1:LB_AW];
    end else if (DIM_W == LB_AW) begin : g_ra_full
        assign lb_raddr_o = raddr;
    end else begin : g_ra_ext
        assign lb_raddr_o = {{(LB_AW-DIM_W){1'b0}}, raddr};
    end
endgenerate

arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ARST_EN)) u_sx_prev (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(run & pe), .d_i(sx), .q_o(sx_prev));

assign sx_new = (hcnt == x0) | (sx != sx_prev);

//=============================================================================
// 7)  LINE-BUFFER BANKS
//=============================================================================
// A bank is full while its fill toggle (register side) differs from its release
// toggle. A line is shown from the full bank tagged with that line of the
// current frame (epoch = frame-start parity). A bank is released when the scan
// no longer needs its line (below need_lo), when the line is skipped (above
// need_lo and below skip_hi, the line of the next panel line: vertical
// reduction), or at once when its tag is of an older frame.

wire                      epoch_nxt = ~epoch;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_epoch (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(frame_go), .d_i(epoch_nxt), .q_o(epoch));

assign fs_o = epoch;
assign full = fill_i ^ rel;

genvar gb;
generate
    for (gb = 0; gb < NB; gb = gb + 1) begin : g_bank
        wire             tag_ep   = tag_i[gb*TW + DIM_W];
        wire [DIM_W-1:0] tag_line = tag_i[gb*TW +: DIM_W];
        wire [16:0]      tag_l17  = {{(17-DIM_W){1'b0}}, tag_line};
        assign rel_en[gb] = run & full[gb] & ((tag_ep != epoch) | ({1'b0, tag_line} < need_lo) |
                                              ((tag_l17 > {{(16-DIM_W){1'b0}}, need_lo}) & (tag_l17 < skip_hi)));
    end
endgenerate

wire             [NB-1:0] rel_nxt = rel ^ rel_en;

arv_ipdff #(.WIDTH(NB), .ARST_EN(ARST_EN)) u_rel (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|rel_en), .d_i(rel_nxt), .q_o(rel));

assign rel_o = rel;

// need_lo: 0 until the image's first line (the vertical blanking that follows
// a frame start belongs to the next frame), then the source line of the panel
// line, then all lines once the image is past
wire                      act_nxt  = (vcnt_ln < {1'b0, c_v_act});
wire                      img_row  = act_nxt & (vcnt_ln >= y0) & (vcnt_ln < y0 + img_h);
wire                      img_past = act_nxt & (vcnt_ln >= y0 + img_h);
assign need_en     = frame_go | line_go;
assign need_lo_nxt = fl_go    ? {(DIM_W+1){1'b0}} :
                     img_row  ? {1'b0, sy_next}   :
                     img_past ? {(DIM_W+1){1'b1}} :
                                {(DIM_W+1){1'b0}};

arv_ipdff #(.WIDTH(DIM_W+1), .ARST_EN(ARST_EN)) u_need_lo (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(need_en), .d_i(need_lo_nxt), .q_o(need_lo));

// skip_hi: the source line of the next panel line (the image's second line
// before the image), clamped to the frame's last line; 0 from a frame start
// and once the image is past
// (fy_nxt + step, clamped)
assign skip_hi_nxt = (fl_go | img_past) ? 17'd0 : (img_row & ~fy_zero) ? c_fy2 : c_stp;

arv_ipdff #(.WIDTH(17), .ARST_EN(ARST_EN)) u_skip_hi (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(need_en), .d_i(skip_hi_nxt), .q_o(skip_hi));

// nl_row: the source line of the panel line after the one starting (0 when
// it is the image's first line or before it), for the bilinear priming read
// at the end of a line
wire               [12:0] nl_l1   = (vcnt_nxt >= v_tm1_n) ? 13'd0 : vcnt_nxt + 13'd1;
wire               [16:0] nl_c17  = (nl_l1 <= y0) ? 17'd0 : fy_zero ? c_stp : c_fy2;   // fy_nxt + step, clamped
wire           [16-DIM_W:0] nl_c17_unused = nl_c17[16:DIM_W];

arv_ipdff #(.WIDTH(DIM_W), .ARST_EN(ARST_EN)) u_nl_row (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(need_en), .d_i(nl_c17[DIM_W-1:0]), .q_o(nl_row));

// The banks of the pixel's lines, and whether they hold them
assign bk0 = bank_of(tag_i, full, epoch, sy_sel);
assign bk1 = bank_of(tag_i, full, epoch, sy1);

assign ok0   = |bk0;
assign ok1   = |bk1;
assign valid = ok0 & ok1 & in_lb_x;

// One underflow event per frame (also stops repeated toggling)
assign uf_hit = run & pe & in_img & ~valid & ~c_test;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_uf_seen (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(frame_go | uf_hit), .d_i(~frame_go), .q_o(uf_seen));

wire                      uf_nxt = ~uf;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_uf (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(uf_hit & ~uf_seen & ~frame_go), .d_i(uf_nxt), .q_o(uf));

assign uf_o = uf;

// Image done: once per frame, at the first line past the image, or at the
// frame start when the image reaches the bottom of the active area (none
// past it): no later line of the frame is needed, so the register side drops
// the rest of the frame (blns_dpi_bdi). The toggle never moves after the
// frame start it may come with (the start itself excepted)
assign dn_hit = ~dsent & ((line_go & ~fl_go & img_past) | (frame_go & ~start));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_dsent (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(frame_go | dn_hit), .d_i(~frame_go), .q_o(dsent));

wire                      idn_nxt = ~idn;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_idn (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(dn_hit), .d_i(idn_nxt), .q_o(idn));

assign idn_o = idn;

// SCANLINE event and LINE snapshot
wire                      sl_hit = line_go & (vcnt_nxt == c_scanline);

wire                      sl_nxt = ~sl;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sl (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(sl_hit), .d_i(sl_nxt), .q_o(sl));

wire               [14:0] line_nxt = {~ln, vcnt_nxt, (vcnt_nxt >= {1'b0, (fl_go ? n_v_act : c_v_act)})};

arv_ipdff #(.WIDTH(15), .ARST_EN(ARST_EN)) u_line (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | line_go), .d_i(line_nxt), .q_o({ln, line_o, vblank_o}));

assign sl_o = sl;
assign ln_o = ln;

//=============================================================================
// 8)  TEST BARS
//=============================================================================
// Eight bars of floor(H_ACT / 8) pixels, the last one to the end of the line

arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_bar_w (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(frame_go), .d_i(n_h_act >> 3), .q_o(bar_w));

wire                      bar_step = (bar_cnt + 12'd1 >= bar_w) & (bar_idx != 3'd7);

wire               [14:0] bar_nxt = (start | h_end) ? 15'd0 : bar_step ? {3'd0 + bar_idx + 3'd1, 12'd0} : {bar_idx, bar_cnt + 12'd1};

arv_ipdff #(.WIDTH(15), .ARST_EN(ARST_EN)) u_bar (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(start | (run & pe)), .d_i(bar_nxt), .q_o({bar_idx, bar_cnt}));

//=============================================================================
// 9)  PIXEL PIPELINE
//=============================================================================

function [23:0] mux_bank;
    input [NB-1:0]    bk;
    input [NB*24-1:0] d;
    integer           k;
    begin
        mux_bank = 24'h0;
        for (k = 0; k < NB; k = k + 1)
            mux_bank = mux_bank | ({24{bk[k]}} & d[k*24 +: 24]);
    end
endfunction

assign rd0 = mux_bank(s1_bk0, lb_rdata_i);
assign rd1 = mux_bank(s1_bk1, lb_rdata_i);

// S1: controls and position; with CLK_DIV >= 1 the read data of the pixel
// is already on the line-buffer outputs at its step (it was addressed for a
// whole pixel), so it is taken here
// The stages clear their controls while stopped, so that a run starts with
// no stale pixel
wire                [3:0] ctl0 = {h_act & v_act, h_sync, v_sync, in_img} & {4{run}};
wire                      st_en = ~run | pe;

arv_ipdff #(.WIDTH(4+1+1+3+2*NB+8), .ARST_EN(ARST_EN)) u_s1 (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en),
    .d_i({ctl0, valid, sx_new, bar_idx, bk0, bk1, wx, wy}),
    .q_o({s1_de, s1_hs, s1_vs, s1_img, s1_ok, s1_new, s1_bar, s1_bk0, s1_bk1, s1_wx, s1_wy}));

arv_ipdff #(.WIDTH(48), .ARST_EN(ARST_EN)) u_s1_d (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(run & pe), .d_i({mux_bank(bk0, lb_rdata_i), mux_bank(bk1, lb_rdata_i)}),
    .q_o({s1_d0, s1_d1}));

// S2: read data (CLK_DIV = 0: the read of the previous cycle); bilinear keeps
// the left neighbour (the previous read when the source pixel advanced)
assign d0_now = ddr ? rd0 : s1_d0;
assign d1_now = ddr ? rd1 : s1_d1;
assign b0_nxt = d0_now;
assign b1_nxt = d1_now;
assign a0_nxt = (FILT_EN && fil_x) ? (s1_new ? s2_b0 : s2_a0) : d0_now;
assign a1_nxt = (FILT_EN && fil_x) ? (s1_new ? s2_b1 : s2_a1) : d1_now;

arv_ipdff #(.WIDTH(4+1+3+8+96), .ARST_EN(ARST_EN)) u_s2 (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en),
    .d_i({{s1_de, s1_hs, s1_vs, s1_img} & {4{run}}, s1_ok, s1_bar, s1_wx, s1_wy, a0_nxt, b0_nxt, a1_nxt, b1_nxt}),
    .q_o({s2_de, s2_hs, s2_vs, s2_img, s2_ok, s2_bar, s2_wx, s2_wy, s2_a0, s2_b0, s2_a1, s2_b1}));

// S3: horizontal blend of each line, per channel: a*(16-w) + b*w (12 bits),
// computed as 16a + w*(b-a): one 4-bit multiplier per channel. Modulo 2^12
// the two are the same (the result, at most 4080, fits).
function [11:0] hblend1;
    input  [7:0] a;
    input  [7:0] b;
    input  [3:0] w;
    reg   [11:0] d;
    reg   [11:0] p;
    begin
        d       = {4'd0, b} - {4'd0, a};             // b - a, two's complement (modulo 2^12)
        p       = d * {8'd0, w};                     // w*(b - a), modulo 2^12
        hblend1 = {a, 4'd0} + p;
    end
endfunction

function [35:0] hblend;
    input [23:0] a;
    input [23:0] b;
    input  [3:0] w;
    begin
        hblend = {hblend1(a[23:16], b[23:16], w), hblend1(a[15:8], b[15:8], w), hblend1(a[7:0], b[7:0], w)};
    end
endfunction

generate
    if (FILT_EN) begin : g_filt
        assign h0_nxt = hblend(s2_a0, s2_b0, s2_wx);
        assign h1_nxt = hblend(s2_a1, s2_b1, s2_wx);
    end else begin : g_no_filt
        assign h0_nxt = {s2_a0[23:16], 4'd0, s2_a0[15:8], 4'd0, s2_a0[7:0], 4'd0};
        assign h1_nxt = 36'd0;
        wire   [76:0] filt_unused = {s1_new, s2_b0, s2_wx, s2_a1, s2_b1};
    end
endgenerate

arv_ipdff #(.WIDTH(4+1+3+4+72), .ARST_EN(ARST_EN)) u_s3 (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en),
    .d_i({{s2_de, s2_hs, s2_vs, s2_img} & {4{run}}, s2_ok, s2_bar, s2_wy, h0_nxt, h1_nxt}),
    .q_o({s3_de, s3_hs, s3_vs, s3_img, s3_ok, s3_bar, s3_wy, s3_h0, s3_h1}));

// S4: vertical blend, (h0*(16-w) + h1*w + 128) >> 8; border and test colours.
// As in S3: 16*h0 + w*(h1-h0) + 128, the same modulo 2^16 (at most 65408).
function [15:0] vblend;                         // the result is in [15:8]
    input [11:0] h0;
    input [11:0] h1;
    input  [3:0] w;
    reg   [15:0] d;
    reg   [15:0] p;
    begin
        d      = {4'd0, h1} - {4'd0, h0};       // h1 - h0, two's complement (modulo 2^16)
        p      = d * {12'd0, w};                // w*(h1 - h0), modulo 2^16
        vblend = {h0, 4'd0} + p + 16'd128;
    end
endfunction

generate
    if (FILT_EN) begin : g_vblend
        wire   [15:0] vb_r = vblend(s3_h0[35:24], s3_h1[35:24], s3_wy);
        wire   [15:0] vb_g = vblend(s3_h0[23:12], s3_h1[23:12], s3_wy);
        wire   [15:0] vb_b = vblend(s3_h0[11:0],  s3_h1[11:0],  s3_wy);
        assign blend = {vb_r[15:8], vb_g[15:8], vb_b[15:8]};
        wire   [23:0] vb_frac_unused = {vb_r[7:0], vb_g[7:0], vb_b[7:0]};
    end else begin : g_no_vblend
        assign blend = {s3_h0[35:28], s3_h0[23:16], s3_h0[11:4]};
        wire   [51:0] vblend_unused = {s3_h1, s3_wy, s3_h0[27:24], s3_h0[15:12], s3_h0[3:0]};
    end
endgenerate

// white, yellow, cyan, green, magenta, red, blue, black
assign bar_rgb = {{8{~s3_bar[1]}}, {8{~s3_bar[2]}}, {8{~s3_bar[0]}}};
assign px_rgb  = c_test ? bar_rgb : (s3_img & s3_ok) ? blend : c_border;

arv_ipdff #(.WIDTH(3+24), .ARST_EN(ARST_EN)) u_s4 (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en),
    .d_i({{s3_de, s3_hs, s3_vs} & {3{run}}, (run & s3_de) ? px_rgb : 24'h0}),
    .q_o({s4_de, s4_hs, s4_vs, s4_rgb}));

// S5: panel outputs, idle while stopped (at a start, with the polarities
// the run takes)
assign out_de  = run ? (s4_de ^ c_de_pol) : n_de_pol;
assign out_hs  = run ? (s4_hs ^ ~c_hs_pol) : ~n_hs_pol;
assign out_vs  = run ? (s4_vs ^ ~c_vs_pol) : ~n_vs_pol;
assign out_rgb = ~run ? 24'h0 : c_bgr ? {s4_rgb[7:0], s4_rgb[15:8], s4_rgb[23:16]} : s4_rgb;

assign tmds_de_nxt = run & s4_de;

// Reset to the idle levels of the reset polarities (DE low, syncs high)
arv_ipdff #(.WIDTH(4+24), .RST_VAL({1'b0, 1'b1, 1'b1, 24'h0, 1'b0}), .ARST_EN(ARST_EN)) u_out (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(~run | pe), .d_i({out_de, out_hs, out_vs, out_rgb, tmds_de_nxt}),
    .q_o({dpi_de_o, dpi_hs_o, dpi_vs_o, dpi_rgb_o, tmds_de_o}));

// HDMI windows: the last 10 pixels of a line followed by an active line,
// 8 for the video preamble then 2 for the guard band, and the first blanking
// pixel of every line, through the same stages as the data enable so that
// they arrive with it. An island of n packets ends 16 + 32n pixels after
// the first blanking pixel and needs a 12-character control period (the
// video preamble included) and the guard band after it: a blanking of
// 31 + 32n pixels (the island geometry of blns_hdmi: I_END1 / I_END2 + 15).
// isl_o is a register, taken with the configuration from the staged set
generate
    if (PRE_EN != 0) begin : g_pre
        wire        nxt_act = ((vcnt == v_tm1) & (c_v_act != 12'd0)) | ((vcnt + 13'd1) < {1'b0, c_v_act});
        wire        pw_win  = run & nxt_act & ((hcnt + 13'd10) > h_tm1);
        wire        pw_gb   = run & nxt_act & ((hcnt + 13'd2) > h_tm1);
        wire        pw_hb   = run & (hcnt == {1'b0, c_h_act});
        wire [12:0] hb_len  = tim_nxt[64:52] - {1'b0, staged_i[B_H+30 +: 12]} + 13'd1;   // of the staged set
        wire  [1:0] isl_nxt = (hb_len >= 13'd95) ? 2'd2 : (hb_len >= 13'd63) ? 2'd1 : 2'd0;
        wire  [2:0] p1;
        wire  [2:0] p2;
        wire  [2:0] p3;
        wire  [2:0] p4;
        arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_p1 (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en), .d_i({pw_hb, pw_win & ~pw_gb, pw_gb}), .q_o(p1));
        arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_p2 (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en), .d_i(p1 & {3{run}}), .q_o(p2));
        arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_p3 (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en), .d_i(p2 & {3{run}}), .q_o(p3));
        arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_p4 (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(st_en), .d_i(p3 & {3{run}}), .q_o(p4));
        arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_p5 (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(~run | pe), .d_i(p4 & {3{run}}), .q_o({hbl_o, vpre_o, vguard_o}));
        arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_isl (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(apply), .d_i(isl_nxt), .q_o(isl_o));
    end else begin : g_no_pre
        assign vpre_o   = 1'b0;
        assign vguard_o = 1'b0;
        assign hbl_o    = 1'b0;
        assign isl_o    = 2'd0;
    end
endgenerate

assign div0_o = (c_div == 4'd0);

// Panel clock halves for the DDR output register, registered: with
// CLK_DIV >= 1 both carry the clock's value of the cycle after, so that the
// DDR register's output changes with the data outputs (data change on the
// falling edge, PCLK_EDGE = 0); with CLK_DIV = 0 they are the constant
// halves of the pixel-domain clock. The register takes them for the next
// cycle: from the next run, divider count and configuration
function [1:0] clk_halves;                      // {d1, d0} in a cycle with these values
    input       r;                              // running
    input [3:0] pc;                             // divider count
    input [3:0] div;                            // CLK_DIV
    input       edg;                            // PCLK_EDGE
    reg   [3:0] pc_n;
    reg         cn;
    begin
        pc_n       = ((pc >= div) | ~r) ? 4'd0 : pc + 4'd1;
        cn         = r & ({1'b0, pc_n} >= (({1'b0, div} + 5'd2) >> 1));
        clk_halves = (div == 4'd0) ? {r & ~edg, r & edg} : {2{r & (cn ^ edg)}};
    end
endfunction

assign run_nxt = (start | stop) ? en_i : run;
assign ck_cur  = clk_halves(run_nxt, pcnt_nxt, c_div, c_edge);
assign ck_stg  = clk_halves(run_nxt, pcnt_nxt, staged_i[B_CFG+6 +: 4], staged_i[B_CFG+5]);
assign ck_nxt  = apply ? ck_stg : ck_cur;

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_clk (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(ck_nxt), .q_o(dpi_clk));

assign dpi_clk_d0_o = dpi_clk[0];
assign dpi_clk_d1_o = dpi_clk[1];

endmodule // blns_dpi_scan

`default_nettype wire
