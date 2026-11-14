//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dpi_cdc
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dpi_cdc.v
// Module Description : Every crossing of the DPI driver between hclk_i (the
//                      register and BDI side) and the pixel clock, in one
//                      place. With SEP_EN = 0 the pixel clock is hclk_i and
//                      every crossing is a wire.
//
//   Synchronised here (two-flop arv_synchronizer bundles of independent
//   bits):
//     hclk -> pixel   run enable, configuration request, frame-size
//                     request, bank fill toggles; HDMI mode and AVI enable;
//                     AUD and GP enables
//     pixel -> hclk   running, configuration and frame-size acknowledges,
//                     frame-start, scanline, underflow, line and image done
//                     toggles, bank release toggles; audio on, frame lost,
//                     CTS toggle, the pixel domain's copy of AUD (each a
//                     pixel-domain register)
//   The pixel-domain reset on hclk_i (u_prst_sync, u_prst_q): cleared
//   asynchronously by dpi_presetn_i (ASYNC_RST_EN = 1), released on hclk_i
//   three edges after it, so that a pixel-only reset of any width counts on
//   the register side as a stop (prst_h_o low)
//   Snapshots taken here on a synchronised toggle (the data held stable for
//   the toggle's period):
//     u_line          LINE / VBLANK (a whole line)
//     u_cts_h         the measured CTS (a whole measurement)
//   Unsynchronised data read by the other side only while held stable by a
//   handshake or an enable (not in this module; constrained by
//   rtl/constraints/belenos_dpi.sdc):
//     blns_dpi_regs  staged configuration (u_st_*: locked while the pixel
//                    domain may take it), AVI fields (u_hdmi_fld: copied in
//                    the pixel domain at an UPDATE or when AVI rises), the
//                    generic packet (u_pkt0, u_pkt: read while GP is set,
//                    not written then),
//                    DPI_AUD (u_aud_cfg: read while AUD is set in the
//                    pixel domain, not written then: AUD crosses as a
//                    handshake, u_aud_x)
//     blns_dpi_bdi   frame size (u_sz), bank tags (u_tag)
//----------------------------------------------------------------------------
`default_nettype none
module  blns_dpi_cdc #(
    parameter                 NB           = 2,     // line-buffer banks
    parameter                 SEP_EN       = 0,     // 1 = separate pixel clock (DPI_PCLK_SEP)
    parameter                 HDMI_EN      = 0,     // 1 = HDMI mode and the AVI enable cross
    parameter                 AUD_EN       = 0,     // 1 = the audio enables and status cross
    parameter                 ARST_EN      = 1      // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,
    input  wire               hresetn_i,
    input  wire               dpi_pclk_i,           // pixel clock (SEP_EN)
    input  wire               dpi_presetn_i,        // pixel-domain reset (SEP_EN)
    output wire               pclk_o,               // the pixel-domain clock
    output wire               presetn_o,            // its reset
    output wire               prst_h_o,             // hclk: 0 from a pixel-domain reset until 3 edges after it

// hclk -> pixel domain
    input  wire               en_i,                 // run enable
    input  wire               req_i,                // configuration request toggle
    input  wire               sz_req_i,             // frame-size request toggle
    input  wire      [NB-1:0] fill_i,               // bank fill toggles
    output wire               en_p_o,
    output wire               req_p_o,
    output wire               sz_req_p_o,
    output wire      [NB-1:0] fill_p_o,
    input  wire         [1:0] hdmi_ctl_i,           // {AVI, HDMI}
    output wire         [1:0] hdmi_ctl_p_o,
    input  wire         [1:0] aud_ctl_i,            // {GP, AUD}
    output wire         [1:0] aud_ctl_p_o,

// pixel domain -> hclk
    input  wire               run_p_i,              // running
    input  wire               ack_p_i,              // configuration acknowledge toggle
    input  wire               sz_ack_p_i,           // frame-size acknowledge toggle
    input  wire               fs_p_i,               // frame-start toggle
    input  wire               sl_p_i,               // scanline toggle
    input  wire               uf_p_i,               // underflow toggle
    input  wire               ln_p_i,               // line toggle
    input  wire               idn_p_i,              // image done toggle
    input  wire      [NB-1:0] rel_p_i,              // bank release toggles
    output wire               run_h_o,
    output wire               ack_h_o,
    output wire               sz_ack_h_o,
    output wire               fs_h_o,
    output wire               sl_h_o,
    output wire               uf_h_o,
    output wire               ln_h_o,
    output wire               idn_h_o,
    output wire      [NB-1:0] rel_h_o,
    input  wire               line_take_i,          // hclk: the line toggle moved
    input  wire        [12:0] line_p_i,             // LINE
    input  wire               vblank_p_i,           // VBLANK
    output wire        [12:0] line_h_o,
    output wire               vblank_h_o,
    input  wire               aud_on_p_i,           // audio on in the pixel domain (a register)
    input  wire               ovf_p_i,              // an audio frame was lost
    input  wire               cts_t_p_i,            // CTS toggle
    input  wire        [19:0] cts_p_i,              // CTS (held for a measurement)
    output wire         [1:0] aud_st_h_o,           // {audio on, lost}
    output wire               aud_echo_h_o,         // AUD as the pixel domain took it (a register there)
    output wire        [19:0] cts_h_o
);

generate
    if (SEP_EN != 0) begin : g_sep
        assign pclk_o    = dpi_pclk_i;
        assign presetn_o = dpi_presetn_i;

        // The pixel-domain reset seen on hclk_i: 0 from the reset (cleared
        // asynchronously by it with ASYNC_RST_EN = 1, so however short it is)
        // until the third hclk_i edge after its release. Running (run_h_o)
        // falls at most three edges after the reset asserts, if the pixel
        // domain's stop lasts long enough to be captured, and otherwise the
        // pixel domain restarted before the second edge: the register side
        // sees no gap between the two. With ASYNC_RST_EN = 0 the reset is
        // sampled on hclk_i (a reset of at least 3 hclk_i periods is seen)
        wire prst_s;
        arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_prst_sync (
            .clk_i   ( hclk_i        ),
            .rst_n_i ( dpi_presetn_i ),
            .async_i ( 1'b1          ),
            .sync_o  ( prst_s        )
        );
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_prst_q (
            .clk_i(hclk_i), .rst_n_i(ARST_EN ? dpi_presetn_i : hresetn_i), .en_i(1'b1), .d_i(prst_s), .q_o(prst_h_o));

        arv_synchronizer #(.W(3+NB), .RST_VAL({(3+NB){1'b0}}), .ARST_EN(ARST_EN)) u_h2p (
            .clk_i   ( pclk_o                                    ),
            .rst_n_i ( presetn_o                                 ),
            .async_i ( {en_i, req_i, sz_req_i, fill_i}           ),
            .sync_o  ( {en_p_o, req_p_o, sz_req_p_o, fill_p_o}   )
        );
        arv_synchronizer #(.W(8+NB), .RST_VAL({(8+NB){1'b0}}), .ARST_EN(ARST_EN)) u_p2h (
            .clk_i   ( hclk_i                                                                     ),
            .rst_n_i ( hresetn_i                                                                  ),
            .async_i ( {run_p_i, ack_p_i, sz_ack_p_i, fs_p_i, sl_p_i, uf_p_i, ln_p_i, idn_p_i, rel_p_i} ),
            .sync_o  ( {run_h_o, ack_h_o, sz_ack_h_o, fs_h_o, sl_h_o, uf_h_o, ln_h_o, idn_h_o, rel_h_o} )
        );
    end else begin : g_same
        assign pclk_o     = hclk_i;
        assign presetn_o  = hresetn_i;
        assign prst_h_o   = 1'b1;
        assign en_p_o     = en_i;
        assign req_p_o    = req_i;
        assign sz_req_p_o = sz_req_i;
        assign fill_p_o   = fill_i;
        assign run_h_o    = run_p_i;
        assign ack_h_o    = ack_p_i;
        assign sz_ack_h_o = sz_ack_p_i;
        assign fs_h_o     = fs_p_i;
        assign sl_h_o     = sl_p_i;
        assign uf_h_o     = uf_p_i;
        assign ln_h_o     = ln_p_i;
        assign idn_h_o    = idn_p_i;
        assign rel_h_o    = rel_p_i;
        wire   pclk_unused = dpi_pclk_i | dpi_presetn_i;
    end

    if ((SEP_EN != 0) && (HDMI_EN != 0)) begin : g_hdmi_sync
        arv_synchronizer #(.W(2), .RST_VAL(2'b00), .ARST_EN(ARST_EN)) u_hdmi_sync (
            .clk_i   ( pclk_o       ),
            .rst_n_i ( presetn_o    ),
            .async_i ( hdmi_ctl_i   ),
            .sync_o  ( hdmi_ctl_p_o )
        );
    end else begin : g_hdmi_nosync
        assign hdmi_ctl_p_o = hdmi_ctl_i;
    end

    if (AUD_EN != 0) begin : g_aud
        wire [2:0] ast_h;                           // {audio on, lost, CTS toggle}
        wire       cts_t_q;
        if (SEP_EN != 0) begin : g_aud_sync
            wire aud_p_q;
            arv_synchronizer #(.W(2), .RST_VAL(2'b00), .ARST_EN(ARST_EN)) u_ctl_sync (
                .clk_i   ( pclk_o      ),
                .rst_n_i ( presetn_o   ),
                .async_i ( aud_ctl_i   ),
                .sync_o  ( aud_ctl_p_o )
            );
            // AUD as taken, a clock later: the pixel domain reads DPI_AUD while
            // AUD is set there and in the clock after it clears
            arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_aud_p_q (
                .clk_i(pclk_o), .rst_n_i(presetn_o), .en_i(1'b1), .d_i(aud_ctl_p_o[0]), .q_o(aud_p_q));
            arv_synchronizer #(.W(4), .RST_VAL(4'b0000), .ARST_EN(ARST_EN)) u_st_sync (
                .clk_i   ( hclk_i                                    ),
                .rst_n_i ( hresetn_i                                 ),
                .async_i ( {aud_on_p_i, ovf_p_i, cts_t_p_i, aud_p_q} ),
                .sync_o  ( {ast_h, aud_echo_h_o}                     )
            );
        end else begin : g_aud_same
            assign aud_ctl_p_o  = aud_ctl_i;
            assign ast_h        = {aud_on_p_i, ovf_p_i, cts_t_p_i};
            assign aud_echo_h_o = aud_ctl_i[0];
        end
        // CTS: taken when its toggle moves (the value is held for a whole measurement)
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cts_t_q (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(ast_h[0]), .q_o(cts_t_q));
        arv_ipdff #(.WIDTH(20), .ARST_EN(ARST_EN)) u_cts_h (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ast_h[0] != cts_t_q), .d_i(cts_p_i), .q_o(cts_h_o));
        // LOST only with ACTIVE: in the pixel domain it clears a clock after ACTIVE,
        // and the two bits cross independently, so it could read 1 with ACTIVE 0
        assign aud_st_h_o = {ast_h[2], ast_h[1] & ast_h[2]};
    end else begin : g_no_aud
        assign aud_ctl_p_o  = 2'b00;
        assign aud_st_h_o   = 2'b00;
        assign aud_echo_h_o = 1'b0;
        assign cts_h_o      = 20'd0;
        wire   [24:0] aud_unused = {aud_ctl_i, aud_on_p_i, ovf_p_i, cts_t_p_i, cts_p_i};
    end
endgenerate

// LINE / VBLANK: taken when the line toggle moves (stable for a whole line)
arv_ipdff #(.WIDTH(14), .ARST_EN(ARST_EN)) u_line (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(line_take_i), .d_i({line_p_i, vblank_p_i}), .q_o({line_h_o, vblank_h_o}));

endmodule // blns_dpi_cdc

`default_nettype wire
