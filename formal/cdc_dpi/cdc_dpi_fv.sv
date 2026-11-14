//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    cdc_dpi_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of the DPI driver's clock-domain crossings: blns_dpi with
// DPI_PCLK_SEP = 1, both clocks free inputs (clk2fflogic: each solver step
// either clock may move, so every phase and frequency relation is covered),
// every arv_synchronizer replaced by the formal model of
// formal/common/arv_synchronizer_fv.v (each bit may arrive one destination
// edge late, independently). Software is free: any register write in any
// cycle, the BDI stream (pixels, last, frame size) free, the line length
// latched from that size as the backend latches it (bk_ln_len). Both resets are
// asserted at the start; with PRST_FREE the pixel reset alone may also be
// asserted at any step afterwards, for any number of steps (a pixel-only
// reset of any width: the register side detects it, blns_dpi_cdc
// u_prst_sync), and only the stability of the data the pixel domain takes
// at a start is checked (the handshake counts and the bank state restart
// with the pixel domain, by design).
//
// Properties, at every pixel-clock edge (a value sampled at an edge is the
// one of the step before it):
//   - quasi-static data are stable when the pixel domain samples them: the
//     data did not change since the previous pixel-clock edge, i.e. for a
//     whole pixel period before the sampling edge:
//       staged configuration  when the scan takes it (apply)
//       frame size            when the size toggle is seen
//       bank tag              while the bank is full in the pixel view
//       AVI fields (HDMI)     when the copy the InfoFrame sends loads (an
//                             UPDATE with AVI on, AVI rising)
//       DPI_AUD (HDMI audio)  at every edge while AUD is set in the pixel
//                             domain or was in the clock before (the
//                             clock regeneration N, the channel status)
//     (the generic packet, read when the packet former loads it while GP is
//     set, is not checked: that load is beyond the reachable depth)
//   - toggle handshakes lose and duplicate nothing: for the UPDATE request,
//     the frame size and each bank, the requests sent minus the
//     acknowledges (releases) is 0 or 1;
//   - the frame size the pixel domain takes is the one sent with its toggle;
//   - image done (its toggle crosses on its own synchroniser bit, at or
//     before the frame start it belongs to): a frame start never abandons the
//     frame before it when that frame's image done toggle moved (the register
//     side decides a cycle after the frame start), unless two pixel-side
//     events (frame start, image done, not in the same step) ever came within
//     4 hclk edges of each other (below the documented minimum line length,
//     integration guide "Separate pixel clock"); while the rest
//     of a frame is dropped, nothing is written into the line buffers.
//----------------------------------------------------------------------------
`default_nettype none
module cdc_dpi_fv #(
    parameter SCALER       = 0,
    parameter HDMI         = 0,
    parameter ASYNC_RST_EN = 1,
    parameter SW3_OFF      = 0,                  // 1: drop software rule SW3 (HDMI)
    parameter PRST_FREE    = 0                   // 1: pixel-only resets at any step
) (
    input  wire        hclk,
    input  wire        pclk,
    input  wire        hresetn,
    input  wire        presetn,
    input  wire        reg_sel,
    input  wire  [5:0] reg_addr,
    input  wire        reg_wr,
    input  wire [31:0] reg_wdata,
    input  wire        px_valid,
    input  wire [23:0] px_data,
    input  wire        px_last,
    input  wire  [3:0] width,
    input  wire  [3:0] height,
    input  wire        cl_swap,
    input  wire        panel_detect,
    input  wire [71:0] lb_rdata
);

localparam       NB    = (SCALER == 2) ? 3 : 2;
localparam       TW    = 5;                      // tag: {epoch, line} at DIM_W 4
localparam       CW    = 213;

wire        dpi_de, dpi_hs, dpi_vs, dpi_clk_d0, dpi_clk_d1;
wire [23:0] dpi_rgb;
wire [29:0] tmds;
wire [31:0] reg_rdata;
wire        reg_ready, irq, busy, lcd_reset_n, lcd_on, px_ready, refresh_active;
wire        ddc_scl_pd, ddc_sda_pd;
wire [NB-1:0] lb_we;
wire  [8:0] lb_waddr, lb_raddr;
wire [23:0] lb_wdata;

// The backend's latched line length (blns_bk_fetch line_len_m1, in Belenos
// fed to the driver's line_len_m1_i): the stream's line length (CL_SWAP: the
// height) latched while refresh_active = 0, reset 0, as in blns_backend u_cfg
reg   [3:0] bk_ln_len;
generate
    if (ASYNC_RST_EN != 0) begin : g_bk_arst
        always @(posedge hclk or negedge hresetn)
            if (!hresetn)             bk_ln_len <= 4'd0;
            else if (!refresh_active) bk_ln_len <= cl_swap ? height : width;
    end else begin : g_bk_srst
        always @(posedge hclk)
            if (!hresetn)             bk_ln_len <= 4'd0;
            else if (!refresh_active) bk_ln_len <= cl_swap ? height : width;
    end
endgenerate
wire  [3:0] bk_ln_len_m1 = bk_ln_len - 4'd1;

blns_dpi #(
    .DIM_W(4), .LB_AW(9), .SCALER(SCALER), .PCLK_SEP(1), .TMDS_EN(HDMI), .DDC_EN(0),
    .ISLAND_EN(HDMI), .AUDIO_EN(HDMI), .ASYNC_RST_EN(ASYNC_RST_EN)
) u_dut (
    .hclk_i(hclk), .hresetn_i(hresetn),
    .px_valid_i(px_valid), .px_data_i(px_data), .px_last_i(px_last), .px_ready_o(px_ready),
    .refresh_trig_i(1'b0), .refresh_active_o(refresh_active), .width_i(width), .height_i(height),
    .cl_swap_i(cl_swap), .line_len_m1_i(bk_ln_len_m1), .reg_sel_i(reg_sel), .reg_addr_i(reg_addr), .reg_wr_i(reg_wr),
    .reg_wdata_i(reg_wdata), .reg_rdata_o(reg_rdata), .reg_ready_o(reg_ready), .irq_o(irq), .busy_o(busy),
    .lcd_reset_n_o(lcd_reset_n), .lcd_on_o(lcd_on), .dpi_pclk_i(pclk), .dpi_presetn_i(presetn),
    .dpi_de_o(dpi_de), .dpi_hs_o(dpi_hs), .dpi_vs_o(dpi_vs), .dpi_rgb_o(dpi_rgb),
    .dpi_clk_d0_o(dpi_clk_d0), .dpi_clk_d1_o(dpi_clk_d1), .panel_detect_i(panel_detect),
    .tmds_o(tmds), .ddc_scl_i(1'b1), .ddc_sda_i(1'b1), .ddc_scl_pd_o(ddc_scl_pd), .ddc_sda_pd_o(ddc_sda_pd),
    .i2s_bclk_i(1'b0), .i2s_lrck_i(1'b0), .i2s_sd_i(1'b0),
    .dpi_lb_we_o(lb_we), .dpi_lb_waddr_o(lb_waddr), .dpi_lb_wdata_o(lb_wdata), .dpi_lb_raddr_o(lb_raddr),
    .dpi_lb_rdata_i(lb_rdata[NB*24-1:0])
);

// Probes into blns_dpi (connected by the driver)
wire [CW-1:0] p_staged;                          // hclk: staged configuration
wire          p_req, p_pix_en;                   // hclk: UPDATE request toggle, run enable
wire          p_apply, p_ack_p, p_req_p;         // pixel: take the staged set, acknowledge, request seen
wire          p_sz_req;                          // hclk: frame-size toggle
wire    [3:0] p_sz_w, p_sz_h;                    // hclk: frame size
wire          p_sz_req_p, p_sz_ack_p;            // pixel: toggle seen, acknowledge
wire    [3:0] p_src_w, p_src_h;                  // pixel: the frame size taken
wire [NB-1:0] p_fill, p_fill_p, p_rel_p;         // fill toggles (hclk, pixel view), release toggles
wire [NB*TW-1:0] p_tag;                          // hclk: bank tags
wire   [16:0] p_hdmi_cfg;                        // hclk: DPI_HDMI {fields, AVI, HDMI}
wire    [1:0] p_hdmi_cfg_p;                      // pixel: {AVI, HDMI}
wire          p_avi_q;                           // pixel: AVI last clock
wire   [27:0] p_aud_cfg;                         // hclk: DPI_AUD {WL, FS, N}
wire    [1:0] p_aud_ctl_p;                       // pixel: {GP, AUD}
wire          p_aud_p_q;                         // pixel: AUD last clock
wire          p_fs_p, p_idn_p;                   // pixel: frame-start (epoch) and image done toggles
wire          p_idn_h;                           // hclk: image done toggle (synchronised)
wire          p_abandon, p_drn;                  // hclk: a frame abandoned, the rest of a frame dropped
wire          p_spend;                           // hclk: a frame start waits for the dropped frame to end

//=============================================================================
// ENVIRONMENT
//=============================================================================
reg           init_q = 1'b1;
reg  [CW-1:0] staged_q;
wire          p_cfg_en;                          // hclk: DIF_CFG.DPI_EN
wire          p_run_h;                           // hclk: running (synchronised)
reg     [3:0] avi_st_q;                          // AVI: register, synchroniser stages, pixel copy
wire          p_avi_meta;                        // probe: the AVI synchroniser's first stage
reg    [14:0] fld_q;
reg    [27:0] aud_q;

always @(*) begin
    if ($initstate) begin
        assume (!hresetn);
        assume (!presetn);
    end else begin
        assume (hresetn);
        if (PRST_FREE == 0)
            assume (presetn);
    end
end

// Software rule (assumed, documented):
//   SW3 (HDMI): the AVI fields do not change while an AVI change is crossing
//        (programming guide "HDMI": one write with AVI clear and the fields,
//        then a separate write setting AVI)
// The staged configuration, the AVI fields around a start (formerly rule SW4)
// and DPI_AUD need no rule: the register side ignores their writes while the
// pixel domain may take them (blns_dpi_regs.v section 4, DPI_HDMI, HDMI
// audio).
always @(*)
    if (!init_q && !$initstate) begin
        // SW3: AVI not the same in the register, the synchroniser's two
        // stages and the pixel side's copy = a change crossing
        if (HDMI != 0 && !SW3_OFF && !(avi_st_q == 4'b0000 || avi_st_q == 4'b1111))
            sw3: assume (p_hdmi_cfg[16:2] == fld_q);
    end

//=============================================================================
// MONITORS (solver steps)
//=============================================================================
reg           pclk_q, hclk_q, prst_seen;
reg     [7:0] sz_q;
reg [NB*TW-1:0] tag_q;
reg           apply_q, upd_q, sz_cap_q, fld_cap_q, aud_rd_q;
reg  [NB-1:0] full_q;
reg           ch_st_q, ch_sz_q, ch_fld_q, ch_aud_q;
reg  [NB-1:0] ch_tag_q;

wire          p_rise   = !init_q & pclk & !pclk_q;
wire          h_rise   = !init_q & hclk & !hclk_q;
wire          sz_cap   = p_sz_req_p != p_sz_ack_p;
// AVI fields: a copy that is used. The InfoFrame is sent only while AVI is set
// in the pixel domain, and the copy is taken again when AVI rises there, so
// a copy at an UPDATE while AVI is clear there is never sent
wire          fld_cap  = (p_apply & p_hdmi_cfg_p[1] & p_avi_q) | (p_hdmi_cfg_p[1] & ~p_avi_q);
wire [NB-1:0] full_p   = p_fill_p ^ p_rel_p;
// DPI_AUD: read by the pixel domain while its AUD is set and in the clock
// after it clears (a packet or a measurement then still due)
wire          aud_rd   = p_aud_ctl_p[0] | p_aud_p_q;

// Changed since the last pixel-clock edge (that edge's own step excluded)
wire          ch_st    = !p_rise & (ch_st_q  | (p_staged != staged_q));
wire          ch_sz    = !p_rise & (ch_sz_q  | ({p_sz_w, p_sz_h} != sz_q));
wire          ch_fld   = !p_rise & (ch_fld_q | (p_hdmi_cfg[16:2] != fld_q));
wire          ch_aud   = !p_rise & (ch_aud_q | (p_aud_cfg != aud_q));
wire [NB-1:0] ch_tag;
genvar gb;
generate
    for (gb = 0; gb < NB; gb = gb + 1) begin : g_ch
        assign ch_tag[gb] = !p_rise & (ch_tag_q[gb] | (p_tag[gb*TW +: TW] != tag_q[gb*TW +: TW]));
    end
endgenerate

// Toggle counts (mod 4): requests and acknowledges
reg     [1:0] n_req, n_ack, n_szr, n_sza;
wire [2*NB-1:0] n_fill, n_rel;
reg           req_q2, ack_q2, szr_q2, sza_q2;
reg  [NB-1:0] fill_q2, rel_q2;
reg     [7:0] sz_sent;                           // the size sent with the last toggle
// Image done: the toggle's value when the frame-start toggle last moved (a
// toggle in the same step included) and at the frame start before (they differ
// when the frame between them had its image done), hclk edges since the last
// frame-start or
// image done toggle, and whether two such toggles ever came 0-3 hclk edges
// apart (in different steps)
reg           fs_p_q, idn_p_q, idn_at_fs, idn_prev_fs, dn_close;
reg     [2:0] h_since;
wire          fs_tog   = !init_q && (p_fs_p != fs_p_q);
wire          idn_tog  = !init_q && (p_idn_p != idn_p_q);
wire [NB-1:0] bank_ok, tag_ok;

always @($global_clock) begin
    init_q    <= 1'b0;
    avi_st_q  <= {p_hdmi_cfg[1], p_avi_meta, p_hdmi_cfg_p[1], p_avi_q};
    pclk_q    <= pclk;
    prst_seen <= !init_q & (prst_seen | !presetn);     // a pixel reset after the start-up one
    hclk_q    <= hclk;
    staged_q  <= p_staged;
    sz_q      <= {p_sz_w, p_sz_h};
    tag_q     <= p_tag;
    fld_q     <= p_hdmi_cfg[16:2];
    aud_q     <= p_aud_cfg;
    aud_rd_q  <= aud_rd;
    ch_aud_q  <= ch_aud;
    apply_q   <= p_apply;
    upd_q     <= p_apply & (p_req_p != p_ack_p);   // the set taken answers a pending request
    sz_cap_q  <= sz_cap;
    fld_cap_q <= fld_cap;
    full_q    <= full_p;
    ch_st_q   <= ch_st;
    ch_sz_q   <= ch_sz;
    ch_fld_q  <= ch_fld;
    ch_tag_q  <= ch_tag;
    req_q2    <= p_req;
    ack_q2    <= p_ack_p;
    szr_q2    <= p_sz_req;
    sza_q2    <= p_sz_ack_p;
    fill_q2   <= p_fill;
    rel_q2    <= p_rel_p;
    fs_p_q    <= p_fs_p;
    idn_p_q   <= p_idn_p;
    if (init_q) begin
        idn_at_fs <= 1'b0; idn_prev_fs <= 1'b0; h_since <= 3'd4; dn_close <= 1'b0;
    end else begin
        if (fs_tog) begin idn_at_fs <= p_idn_p; idn_prev_fs <= idn_at_fs; end
        h_since  <= (fs_tog || idn_tog) ? 3'd0 : (h_rise && (h_since != 3'd4)) ? h_since + 3'd1 : h_since;
        dn_close <= dn_close | ((fs_tog || idn_tog) && (h_since < 3'd4));
    end
    if (init_q) begin
        n_req <= 2'd0; n_ack <= 2'd0; n_szr <= 2'd0; n_sza <= 2'd0;
    end else begin
        n_req <= n_req + (p_req != req_q2);
        n_ack <= n_ack + (p_ack_p != ack_q2);
        n_szr <= n_szr + (p_sz_req != szr_q2);
        n_sza <= n_sza + (p_sz_ack_p != sza_q2);
        if (p_sz_req != szr_q2) sz_sent <= {p_sz_w, p_sz_h};
    end
end

generate
    for (gb = 0; gb < NB; gb = gb + 1) begin : g_cnt
        reg [1:0] nf, nr;
        always @($global_clock)
            if (init_q) begin
                nf <= 2'd0;
                nr <= 2'd0;
            end else begin
                nf <= nf + (p_fill[gb] != fill_q2[gb]);
                nr <= nr + (p_rel_p[gb] != rel_q2[gb]);
            end
        assign n_fill[2*gb +: 2] = nf;
        assign n_rel[2*gb +: 2]  = nr;
        // A bank is filled once, then released once; its tag is stable while
        // the pixel domain may read it (asserted below for every bank)
        assign bank_ok[gb] = (n_fill[2*gb +: 2] - n_rel[2*gb +: 2]) <= 2'd1;
        assign tag_ok[gb]  = !(p_rise && full_q[gb]) || !ch_tag_q[gb];
    end
endgenerate

//=============================================================================
// PROPERTIES
//=============================================================================
always @(*)
    if (!init_q && !$initstate) begin
        // UPDATE and frame-size handshakes: at most one transfer outstanding,
        // none taken twice
        if (PRST_FREE == 0) begin
            a_upd_handshake: assert ((n_req - n_ack) <= 2'd1);
            a_sz_handshake:  assert ((n_szr - n_sza) <= 2'd1);
            a_bank_fill_rel: assert (&bank_ok);
            a_tag_stable:    assert (&tag_ok);
            // Image done: no abandon of a done frame; nothing written while dropping
            // the frame decided at a frame start had no image done since the previous one
            if (p_abandon && !dn_close) a_done_order: assert (idn_at_fs == idn_prev_fs);
            a_drop_no_write: assert (!(p_drn && |lb_we));
        end
        // Quasi-static data stable for a pixel period before the sampling edge
        if (p_rise && apply_q)   a_staged_stable: assert (!ch_st_q);
        if (PRST_FREE == 0) begin
            if (p_rise && sz_cap_q)  a_sz_stable:     assert (!ch_sz_q);
            if (p_rise && sz_cap_q)  a_sz_value:      assert ({p_src_w, p_src_h} == sz_sent);
        end
        if (HDMI != 0) begin
            if (p_rise && fld_cap_q) a_fld_stable: assert (!ch_fld_q);
            if (p_rise && aud_rd_q)  a_aud_stable: assert (!ch_aud_q);
        end
    end

//=============================================================================
// COVERS
//=============================================================================
always @($global_clock)
    if (!init_q) begin
        c_start:       cover (p_rise && apply_q && !p_req_p);
        c_sz:          cover (p_rise && sz_cap_q);
        c_stop_pend:   cover (!p_pix_en && (p_req != p_ack_p));
        if (PRST_FREE != 0)
            c_prst_start: cover (p_rise && apply_q && prst_seen && p_pix_en);   // a restart after a pixel reset
        if (PRST_FREE == 0) begin                // not with free pixel resets: the slow tasks reach them
            c_update:      cover (p_rise && upd_q);
            c_bank_full:   cover (p_rise && full_q[0]);
            c_two_full:    cover (full_p[0] && full_p[1]);
            c_drop:        cover (p_drn);
            c_drop_start:  cover (p_spend && !dn_close);
        end
        if (HDMI != 0) begin
            c_fld:     cover (p_rise && fld_cap_q);
            c_aud:     cover (p_rise && aud_rd_q && !p_aud_ctl_p[0]);   // the clock after AUD clears
        end
    end

endmodule

`default_nettype wire
