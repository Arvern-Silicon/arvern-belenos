//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dpi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dpi.v
// Module Description : MIPI-DPI (parallel RGB) display driver attached through
//                      the BDI contract, with the optional TMDS / HDMI output.
//                      This top connects:
//                        blns_dpi_regs  register side (hclk_i): the DIF / DPI
//                                       registers and the HDMI page, the
//                                       staged configuration and UPDATE, the
//                                       panel-detect filter, the interrupts
//                        blns_dpi_bdi   BDI side (hclk_i): one frame per panel
//                                       frame into the line buffers, the bank
//                                       handover, the frame size
//                        blns_dpi_cdc   every crossing between hclk_i and the
//                                       pixel clock
//                        blns_dpi_scan  pixel domain: the panel timing, the
//                                       line-buffer reads, the scaler
//                      and, in the pixel domain, the copies of the AVI fields
//                      and the generic packet and the TMDS / HDMI transmitter.
//                      Without a separate pixel clock (DPI_PCLK_SEP = 0) the
//                      pixel domain runs on hclk_i.
//----------------------------------------------------------------------------
`default_nettype none
module  blns_dpi #(
    parameter                 DIM_W        = 10,    // width/height field width
    parameter                 LB_AW        = 10,    // line-buffer address width (DPI_LB_AW)
    parameter                 SCALER       = 1,     // 0 none, 1 nearest, 2 nearest and bilinear (DPI_SCALER)
    parameter                 PCLK_SEP     = 0,     // 1 = panel timing on dpi_pclk_i (DPI_PCLK_SEP)
    parameter                 TMDS_EN      = 0,     // 1 = TMDS encoder on the panel outputs (HDMI)
    parameter                 DDC_EN       = 0,     // 1 = DDC register (HDMI: the monitor's EDID over I2C)
    parameter                 ISLAND_EN    = 0,     // 1 = HDMI mode: guard bands and a data island per frame (needs TMDS_EN)
    parameter                 AUDIO_EN     = 0,     // 1 = HDMI audio and the generic packet (needs ISLAND_EN)
    parameter                 NB           = (SCALER == 2) ? 3 : 2,   // line-buffer banks: derived
    parameter                 ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,               // clock
    input  wire               hresetn_i,            // active-low reset (style per ASYNC_RST_EN)
// BDI
    input  wire               px_valid_i,           // pixel available
    input  wire        [23:0] px_data_i,            // pixel (RGB888)
    input  wire               px_last_i,            // final pixel of the frame
    output wire               px_ready_o,           // pixel taken
    input  wire               refresh_trig_i,       // frame request (not used: the driver pulls frames)
    output wire               refresh_active_o,     // taking a frame
    input  wire   [DIM_W-1:0] width_i,              // DISP_SIZE width
    input  wire   [DIM_W-1:0] height_i,             // DISP_SIZE height
    input  wire               cl_swap_i,            // DISP_CFG.CL_SWAP: the stream's lines are frame columns
    input  wire   [DIM_W-1:0] line_len_m1_i,        // the stream's line length - 1, latched while
                                                    //   refresh_active_o = 0 (the backend's)
    input  wire               reg_sel_i,            // register transfer pending
    input  wire         [5:0] reg_addr_i,           // word offset in the window: [5] the page (0x180 / 0x200)
    input  wire               reg_wr_i,             // 1 = write
    input  wire        [31:0] reg_wdata_i,          // write data
    output wire        [31:0] reg_rdata_o,          // read data
    output wire               reg_ready_o,          // transfer completes
    output wire               irq_o,                // driver interrupt (level)
    output wire               busy_o,               // driver needs the clock
// Panel control
    output wire               lcd_reset_n_o,        // panel reset
    output wire               lcd_on_o,             // panel power / backlight
// Pixel clock domain
    input  wire               dpi_pclk_i,           // pixel clock (DPI_PCLK_SEP = 1)
    input  wire               dpi_presetn_i,        // pixel-domain reset (DPI_PCLK_SEP = 1)
// Panel
    output wire               dpi_de_o,
    output wire               dpi_hs_o,
    output wire               dpi_vs_o,
    output wire        [23:0] dpi_rgb_o,
    output wire               dpi_clk_d0_o,
    output wire               dpi_clk_d1_o,
    input  wire               panel_detect_i,       // panel present (asynchronous)
// TMDS symbols (TMDS_EN = 1), pixel domain: {red, green, blue}, bit 0 sent first
    output wire        [29:0] tmds_o,
    input  wire               ddc_scl_i,            // DDC SCL level (asynchronous)
    input  wire               ddc_sda_i,            // DDC SDA level (asynchronous)
    output wire               ddc_scl_pd_o,         // DDC SCL pulled low (open-drain pad enable)
    output wire               ddc_sda_pd_o,         // DDC SDA pulled low
    input  wire               i2s_bclk_i,           // HDMI audio, I2S bit clock (asynchronous, AUDIO_EN)
    input  wire               i2s_lrck_i,           // HDMI audio, I2S word clock (asynchronous)
    input  wire               i2s_sd_i,             // HDMI audio, I2S data (asynchronous)
// Line-buffer macros
    output wire      [NB-1:0] dpi_lb_we_o,
    output wire   [LB_AW-1:0] dpi_lb_waddr_o,
    output wire        [23:0] dpi_lb_wdata_o,
    output wire   [LB_AW-1:0] dpi_lb_raddr_o,
    input  wire   [NB*24-1:0] dpi_lb_rdata_i
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================

// pragma translate_off
generate
    if ((LB_AW < 9) || (LB_AW > 12)) begin : CHECK_LB_AW
        initial $fatal(1, "blns_dpi: DPI_LB_AW (%0d) must be 9..12.", LB_AW);
    end
    if ((SCALER < 0) || (SCALER > 2)) begin : CHECK_SCALER
        initial $fatal(1, "blns_dpi: DPI_SCALER (%0d) must be 0, 1 or 2.", SCALER);
    end
    if ((PCLK_SEP != 0) && (PCLK_SEP != 1)) begin : CHECK_PCLK_SEP
        initial $fatal(1, "blns_dpi: DPI_PCLK_SEP (%0d) must be 0 or 1.", PCLK_SEP);
    end
    if ((TMDS_EN != 0) && (TMDS_EN != 1)) begin : CHECK_TMDS_EN
        initial $fatal(1, "blns_dpi: TMDS_EN (%0d) must be 0 or 1.", TMDS_EN);
    end
    if (NB != ((SCALER == 2) ? 3 : 2)) begin : CHECK_NB
        initial $fatal(1, "blns_dpi: NB is derived from DPI_SCALER, leave it at its default.");
    end
endgenerate
// pragma translate_on

localparam             ARST_EN  = (ASYNC_RST_EN != 0);
localparam             SEP_EN   = (PCLK_SEP != 0);
localparam             HDMI_EN  = (TMDS_EN != 0) && (ISLAND_EN != 0);
localparam             AUD_EN   = HDMI_EN && (AUDIO_EN != 0);
localparam             TW       = DIM_W + 1;        // bank tag {epoch, line}
localparam             CW       = 213;              // configuration bundle

//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

// Register side (blns_dpi_regs)
wire                      pix_en;               // DPI_EN as seen by the pixel domain
wire                      req;                  // configuration request toggle
wire             [CW-1:0] staged;               // staged configuration (stable while locked)
wire               [16:0] hdmi_cfg;             // DPI_HDMI {QUANT, VIC, ACTIVE, PICTURE, AVI, HDMI}
wire                [1:0] aud_ctl;              // {GP, AUD}
wire               [27:0] aud_cfg;              // DPI_AUD {word length, sampling frequency, N}
wire              [247:0] gp_pkt;               // DPI_PKT0-7 {PB27..PB0, HB2..HB0}
wire                      fs_evt;
wire                      dn_evt;               // image done (blns_dpi_bdi drops the rest of the frame)
wire                      line_take;

// BDI side (blns_dpi_bdi)
wire                      active;
wire                      abandon;
wire                      sz_req;
wire          [DIM_W-1:0] sz_w;
wire          [DIM_W-1:0] sz_h;
wire             [NB-1:0] fill;
wire          [NB*TW-1:0] tag;

// Pixel domain -> hclk (blns_dpi_cdc)
wire                      run_h;
wire                      prst_h;               // 0: a pixel-only reset is (or was just) seen
wire                      ack_h;
wire                      sz_ack_h;
wire                      fs_h;                 // frame-start toggle (epoch)
wire                      sl_h;
wire                      uf_h;
wire                      ln_h;
wire                      idn_h;
wire             [NB-1:0] rel_h;
wire               [12:0] st_line;
wire                      st_vblank;
wire                [1:0] aud_st_h;             // {audio on, lost}
wire               [19:0] cts_h;                // the last CTS, taken on its toggle
wire                      aud_echo_h;           // AUD as the pixel domain took it

// Pixel domain
wire                      pclk;
wire                      presetn;
wire                      en_p;
wire                      req_p;
wire                      sz_req_p;
wire             [NB-1:0] fill_p;
wire                [1:0] hdmi_cfg_p;           // {AVI, HDMI} in the pixel domain
wire                [1:0] aud_ctl_p;            // {GP, AUD} in the pixel domain
wire                      run_p;
wire                      ack_p;
wire                      apply_p;              // the pixel domain takes a configuration
wire                      sz_ack_p;
wire             [NB-1:0] rel_p;
wire                      fs_p;
wire                      sl_p;
wire                      uf_p;
wire                      ln_p;
wire                      idn_p;
wire               [12:0] line_p;
wire                      vblank_p;
wire                      tmds_de;
wire                      vpre;                 // HDMI windows before an active line
wire                      vguard;
wire                      div0;                 // CLK_DIV = 0
wire                      hbl;                  // first horizontal blanking pixel
wire                [1:0] isl;                  // island packets the horizontal blanking holds
wire                      pnl_hs;
wire                      pnl_vs;
wire               [23:0] pnl_rgb;
wire               [14:0] avi_f_p;              // AVI fields {QUANT, VIC, ACTIVE, PICTURE} the pixel domain sends
wire               [19:0] cts_p;
wire                      cts_t_p;
wire                      ovf_p;
wire                      aud_on_p;             // audio on in the pixel domain

//=============================================================================
// 3)  REGISTER SIDE
//=============================================================================

blns_dpi_regs #(
    .LB_AW          ( LB_AW                ),
    .SCALER         ( SCALER               ),
    .SEP_EN         ( SEP_EN ? 1 : 0       ),
    .TMDS_EN        ( (TMDS_EN != 0) ? 1 : 0 ),
    .DDC_EN         ( (DDC_EN != 0) ? 1 : 0  ),
    .HDMI_EN        ( HDMI_EN ? 1 : 0      ),
    .AUD_EN         ( AUD_EN ? 1 : 0       ),
    .CW             ( CW                   ),
    .ARST_EN        ( ARST_EN ? 1 : 0      )
) u_dpi_regs (
    .hclk_i         ( hclk_i         ),
    .hresetn_i      ( hresetn_i      ),
    .reg_sel_i      ( reg_sel_i      ),
    .reg_addr_i     ( reg_addr_i     ),
    .reg_wr_i       ( reg_wr_i       ),
    .reg_wdata_i    ( reg_wdata_i    ),
    .reg_rdata_o    ( reg_rdata_o    ),
    .reg_ready_o    ( reg_ready_o    ),
    .irq_o          ( irq_o          ),
    .busy_o         ( busy_o         ),
    .lcd_reset_n_o  ( lcd_reset_n_o  ),
    .lcd_on_o       ( lcd_on_o       ),
    .panel_detect_i ( panel_detect_i ),
    .ddc_scl_i      ( ddc_scl_i      ),
    .ddc_sda_i      ( ddc_sda_i      ),
    .ddc_scl_pd_o   ( ddc_scl_pd_o   ),
    .ddc_sda_pd_o   ( ddc_sda_pd_o   ),
    .pix_en_o       ( pix_en         ),
    .req_o          ( req            ),
    .staged_o       ( staged         ),
    .hdmi_cfg_o     ( hdmi_cfg       ),
    .aud_ctl_o      ( aud_ctl        ),
    .aud_cfg_o      ( aud_cfg        ),
    .gp_pkt_o       ( gp_pkt         ),
    .run_h_i        ( run_h          ),
    .prst_h_i       ( prst_h         ),
    .ack_h_i        ( ack_h          ),
    .fs_h_i         ( fs_h           ),
    .sl_h_i         ( sl_h           ),
    .uf_h_i         ( uf_h           ),
    .ln_h_i         ( ln_h           ),
    .idn_h_i        ( idn_h          ),
    .line_h_i       ( st_line        ),
    .vblank_h_i     ( st_vblank      ),
    .aud_st_h_i     ( aud_st_h       ),
    .aud_echo_h_i   ( aud_echo_h     ),
    .cts_h_i        ( cts_h          ),
    .fs_evt_o       ( fs_evt         ),
    .dn_evt_o       ( dn_evt         ),
    .line_take_o    ( line_take      ),
    .active_i       ( active         ),
    .abandon_i      ( abandon        )
);

//=============================================================================
// 4)  BDI SIDE: ONE FRAME PER PANEL FRAME INTO THE LINE BUFFERS
//=============================================================================

blns_dpi_bdi #(
    .DIM_W          ( DIM_W            ),
    .LB_AW          ( LB_AW            ),
    .NB             ( NB               ),
    .ARST_EN        ( ARST_EN ? 1 : 0  )
) u_dpi_bdi (
    .hclk_i         ( hclk_i           ),
    .hresetn_i      ( hresetn_i        ),
    .px_valid_i     ( px_valid_i       ),
    .px_data_i      ( px_data_i        ),
    .px_last_i      ( px_last_i        ),
    .px_ready_o     ( px_ready_o       ),
    .active_o       ( active           ),
    .width_i        ( width_i          ),
    .height_i       ( height_i         ),
    .cl_swap_i      ( cl_swap_i        ),
    .line_len_m1_i  ( line_len_m1_i    ),
    .pix_en_i       ( pix_en           ),
    .run_h_i        ( run_h            ),
    .prst_h_i       ( prst_h           ),
    .fs_evt_i       ( fs_evt           ),
    .dn_evt_i       ( dn_evt           ),
    .epoch_i        ( fs_h             ),
    .abandon_o      ( abandon          ),
    .sz_req_o       ( sz_req           ),
    .sz_w_o         ( sz_w             ),
    .sz_h_o         ( sz_h             ),
    .sz_ack_i       ( sz_ack_h         ),
    .fill_o         ( fill             ),
    .rel_i          ( rel_h            ),
    .tag_o          ( tag              ),
    .lb_we_o        ( dpi_lb_we_o      ),
    .lb_waddr_o     ( dpi_lb_waddr_o   ),
    .lb_wdata_o     ( dpi_lb_wdata_o   )
);

assign refresh_active_o = active;

wire                      bdi_unused = refresh_trig_i;

//=============================================================================
// 5)  CLOCK-DOMAIN CROSSINGS AND THE PIXEL DOMAIN
//=============================================================================

blns_dpi_cdc #(
    .NB             ( NB                                   ),
    .SEP_EN         ( SEP_EN ? 1 : 0                       ),
    .HDMI_EN        ( HDMI_EN ? 1 : 0                      ),
    .AUD_EN         ( AUD_EN ? 1 : 0                       ),
    .ARST_EN        ( ARST_EN ? 1 : 0                      )
) u_dpi_cdc (
    .hclk_i         ( hclk_i         ),
    .hresetn_i      ( hresetn_i      ),
    .dpi_pclk_i     ( dpi_pclk_i     ),
    .dpi_presetn_i  ( dpi_presetn_i  ),
    .pclk_o         ( pclk           ),
    .presetn_o      ( presetn        ),
    .prst_h_o       ( prst_h         ),
    .en_i           ( pix_en         ),
    .req_i          ( req            ),
    .sz_req_i       ( sz_req         ),
    .fill_i         ( fill           ),
    .en_p_o         ( en_p           ),
    .req_p_o        ( req_p          ),
    .sz_req_p_o     ( sz_req_p       ),
    .fill_p_o       ( fill_p         ),
    .hdmi_ctl_i     ( hdmi_cfg[1:0]  ),
    .hdmi_ctl_p_o   ( hdmi_cfg_p     ),
    .aud_ctl_i      ( aud_ctl        ),
    .aud_ctl_p_o    ( aud_ctl_p      ),
    .run_p_i        ( run_p          ),
    .ack_p_i        ( ack_p          ),
    .sz_ack_p_i     ( sz_ack_p       ),
    .fs_p_i         ( fs_p           ),
    .sl_p_i         ( sl_p           ),
    .uf_p_i         ( uf_p           ),
    .ln_p_i         ( ln_p           ),
    .idn_p_i        ( idn_p          ),
    .rel_p_i        ( rel_p          ),
    .run_h_o        ( run_h          ),
    .ack_h_o        ( ack_h          ),
    .sz_ack_h_o     ( sz_ack_h       ),
    .fs_h_o         ( fs_h           ),
    .sl_h_o         ( sl_h           ),
    .uf_h_o         ( uf_h           ),
    .ln_h_o         ( ln_h           ),
    .idn_h_o        ( idn_h          ),
    .rel_h_o        ( rel_h          ),
    .line_take_i    ( line_take      ),
    .line_p_i       ( line_p         ),
    .vblank_p_i     ( vblank_p       ),
    .line_h_o       ( st_line        ),
    .vblank_h_o     ( st_vblank      ),
    .aud_on_p_i     ( aud_on_p       ),
    .ovf_p_i        ( ovf_p          ),
    .cts_t_p_i      ( cts_t_p        ),
    .cts_p_i        ( cts_p          ),
    .aud_st_h_o     ( aud_st_h       ),
    .aud_echo_h_o   ( aud_echo_h     ),
    .cts_h_o        ( cts_h          )
);

blns_dpi_scan #(
    .DIM_W            ( DIM_W            ),
    .LB_AW            ( LB_AW            ),
    .NB               ( NB               ),
    .SCALER           ( SCALER           ),
    .CW               ( CW               ),
    .PRE_EN           ( HDMI_EN ? 1 : 0  ),
    .ARST_EN          ( ARST_EN ? 1 : 0  )
) u_dpi_scan (
    .pclk_i           ( pclk             ),
    .presetn_i        ( presetn          ),
    .en_i             ( en_p             ),
    .req_i            ( req_p            ),
    .staged_i         ( staged           ),
    .sz_req_i         ( sz_req_p         ),
    .sz_w_i           ( sz_w             ),
    .sz_h_i           ( sz_h             ),
    .fill_i           ( fill_p           ),
    .tag_i            ( tag              ),
    .run_o            ( run_p            ),
    .ack_o            ( ack_p            ),
    .apply_o          ( apply_p          ),
    .sz_ack_o         ( sz_ack_p         ),
    .rel_o            ( rel_p            ),
    .fs_o             ( fs_p             ),
    .sl_o             ( sl_p             ),
    .uf_o             ( uf_p             ),
    .idn_o            ( idn_p            ),
    .ln_o             ( ln_p             ),
    .line_o           ( line_p           ),
    .vblank_o         ( vblank_p         ),
    .lb_raddr_o       ( dpi_lb_raddr_o   ),
    .lb_rdata_i       ( dpi_lb_rdata_i   ),
    .dpi_de_o         ( dpi_de_o         ),
    .dpi_hs_o         ( pnl_hs           ),
    .dpi_vs_o         ( pnl_vs           ),
    .dpi_rgb_o        ( pnl_rgb          ),
    .dpi_clk_d0_o     ( dpi_clk_d0_o     ),
    .dpi_clk_d1_o     ( dpi_clk_d1_o     ),
    .tmds_de_o        ( tmds_de          ),
    .vpre_o           ( vpre             ),
    .vguard_o         ( vguard           ),
    .hbl_o            ( hbl              ),
    .isl_o            ( isl              ),
    .div0_o           ( div0             )
);

//=============================================================================
// 6)  TMDS ENCODER (HDMI)
//=============================================================================

assign dpi_hs_o  = pnl_hs;
assign dpi_vs_o  = pnl_vs;
assign dpi_rgb_o = pnl_rgb;

// The AVI fields the pixel domain sends: taken from the registers at a frame
// start that takes an UPDATE (apply_p, the start included), and when AVI
// rises there. Software changes them with AVI clear, or with it set followed
// by an UPDATE (writes are ignored while that UPDATE is pending, and during a
// start). The generic packet is read from the registers, which do not change
// while GP is set
generate
    if (HDMI_EN) begin : g_hdmi_copy
        wire avi_q;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_avi_q (
            .clk_i(pclk), .rst_n_i(presetn), .en_i(1'b1), .d_i(hdmi_cfg_p[1]), .q_o(avi_q));
        arv_ipdff #(.WIDTH(15), .ARST_EN(ARST_EN)) u_avi_f (
            .clk_i(pclk), .rst_n_i(presetn), .en_i(apply_p | (hdmi_cfg_p[1] & ~avi_q)),
            .d_i(hdmi_cfg[16:2]), .q_o(avi_f_p));
    end else begin : g_no_hdmi_copy
        assign avi_f_p = 15'd0;
        wire   [263:0] copy_unused = {apply_p, avi_f_p, gp_pkt};
    end
endgenerate

// Channel 0 carries the syncs (C0 = HSYNC, C1 = VSYNC, as sent on the DPI pins)
generate
    if (HDMI_EN) begin : g_hdmi
        blns_hdmi #(.AUDIO_EN(AUD_EN ? 1 : 0), .ASYNC_RST_EN(ARST_EN)) u_hdmi (
            .clk_i      ( pclk            ),
            .rst_n_i    ( presetn         ),
            .mode_i     ( hdmi_cfg_p[0]   ),
            .avi_i      ( hdmi_cfg_p[1]   ),
            .aud_i      ( aud_ctl_p[0]    ),
            .gp_i       ( aud_ctl_p[1]    ),
            .pic_i      ( avi_f_p[1:0]    ),
            .act_i      ( avi_f_p[5:2]    ),
            .vic_i      ( avi_f_p[12:6]   ),
            .quant_i    ( avi_f_p[14:13]  ),
            .n_i        ( aud_cfg[19:0]   ),
            .cs_fs_i    ( aud_cfg[23:20]  ),
            .cs_wl_i    ( aud_cfg[27:24]  ),
            .gp_hdr_i   ( gp_pkt[23:0]    ),
            .gp_pb_i    ( gp_pkt[247:24]  ),
            .div0_i     ( div0            ),
            .de_i       ( tmds_de         ),
            .hs_i       ( pnl_hs          ),
            .vs_i       ( pnl_vs          ),
            .rgb_i      ( pnl_rgb         ),
            .vpre_i     ( vpre            ),
            .vguard_i   ( vguard          ),
            .vblank_i   ( vblank_p        ),
            .hbl_i      ( hbl             ),
            .isl_i      ( isl             ),
            .i2s_bclk_i ( i2s_bclk_i      ),
            .i2s_lrck_i ( i2s_lrck_i      ),
            .i2s_sd_i   ( i2s_sd_i        ),
            .tmds_o     ( tmds_o          ),
            .cts_o      ( cts_p           ),
            .cts_t_o    ( cts_t_p         ),
            .ovf_o      ( ovf_p           ),
            .aud_on_o   ( aud_on_p        )
        );
    end else if (TMDS_EN != 0) begin : g_tmds
        assign cts_p   = 20'd0;
        assign cts_t_p = 1'b0;
        assign ovf_p   = 1'b0;
        assign aud_on_p = 1'b0;
        wire   [5:0] aud_in_unused = {hbl, isl, i2s_bclk_i, i2s_lrck_i, i2s_sd_i};
        blns_tmds #(.ASYNC_RST_EN(ARST_EN)) u_tmds_b (
            .clk_i(pclk), .rst_n_i(presetn), .de_i(tmds_de), .c_i({pnl_vs, pnl_hs}),
            .d_i(pnl_rgb[7:0]),   .q_o(tmds_o[9:0]));
        blns_tmds #(.CTL_EN(0), .ASYNC_RST_EN(ARST_EN)) u_tmds_g (
            .clk_i(pclk), .rst_n_i(presetn), .de_i(tmds_de), .c_i(2'b00),
            .d_i(pnl_rgb[15:8]),  .q_o(tmds_o[19:10]));
        blns_tmds #(.CTL_EN(0), .ASYNC_RST_EN(ARST_EN)) u_tmds_r (
            .clk_i(pclk), .rst_n_i(presetn), .de_i(tmds_de), .c_i(2'b00),
            .d_i(pnl_rgb[23:16]), .q_o(tmds_o[29:20]));
        wire   [21:0] hdmi_unused = {hdmi_cfg_p, hdmi_cfg, vpre, vguard, div0};
        wire   [29:0] aud_unused  = {aud_ctl_p, aud_cfg};
    end else begin : g_no_tmds
        assign tmds_o = 30'h0;
        assign cts_p   = 20'd0;
        assign cts_t_p = 1'b0;
        assign ovf_p   = 1'b0;
        assign aud_on_p = 1'b0;
        wire   [5:0] aud_in_unused = {hbl, isl, i2s_bclk_i, i2s_lrck_i, i2s_sd_i};
        wire   tmds_de_unused = tmds_de;
        wire   [21:0] hdmi_unused = {hdmi_cfg_p, hdmi_cfg, vpre, vguard, div0};
        wire   [29:0] aud_unused  = {aud_ctl_p, aud_cfg};
    end
endgenerate

endmodule // blns_dpi

`default_nettype wire
