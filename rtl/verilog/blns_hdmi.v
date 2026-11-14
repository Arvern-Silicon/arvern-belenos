//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_hdmi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_hdmi.v
// Module Description : HDMI transmitter channels (pixel domain): the three
//                      TMDS encoders and, in HDMI mode, the video preamble and
//                      guard band before every active line and a packet
//                      engine (AUDIO_EN = 0: the AVI InfoFrame only, one
//                      subpacket serialised; AUDIO_EN = 1, DPI_AUDIO_EN:
//                      also audio). A data island of one or two packets
//                      may start in every line's horizontal blanking
//                      (hbl_i; isl_i: how many the blanking holds), its
//                      packets taken in this order: an audio sample packet
//                      (2 channels, up to 4 frames from blns_hdmi_i2s), the
//                      audio clock regeneration packet after each CTS
//                      measurement, then once per frame the AVI InfoFrame,
//                      the audio InfoFrame and the generic packet of the
//                      registers, each while enabled; in a one-packet island
//                      the audio sample packet yields to another due packet
//                      while fewer than 3 frames wait. A null packet fills
//                      an island planned for two. A packet is read from its
//                      sources while it is sent, its type and the fields
//                      that may change latched at its load (the AVI fields,
//                      N, the audio frames' channel-status bits and block
//                      starts): the audio buffer holds still until the
//                      packet's last data character, and no CTS measurement
//                      is taken while a clock regeneration packet is sent.
//                      Header and subpacket BCH parities are computed while
//                      they are sent. The
//                      register fields (InfoFrame, N, channel status,
//                      generic packet) are read while their enable is set,
//                      and a due packet is dropped when its enable clears:
//                      the fields change with it clear (the register side
//                      locks the AVI fields and N / channel status then;
//                      aud_on_o, a register, tells when audio has stopped in
//                      this domain).
//                      Island, from hbl_i (count 1 to 16 + 32n): 1-4
//                      control, 5-12 preamble, 13-14 guard band, packets of
//                      32 characters, 2 guard band characters. The blanking
//                      that holds it (blns_dpi_scan g_pre, isl_i: 31 + 32n
//                      pixels) adds the 12-character control period and the
//                      video guard band before the next active line.
//----------------------------------------------------------------------------
`default_nettype none
module  blns_hdmi #(
    parameter                 AUDIO_EN     = 1,     // 1: audio and the generic packet (DPI_AUDIO_EN)
    parameter                 ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               clk_i,                // pixel-domain clock
    input  wire               rst_n_i,              // active-low reset
    input  wire               mode_i,               // HDMI mode (else DVI)
    input  wire               avi_i,                // send the AVI InfoFrame once per frame
    input  wire               aud_i,                // audio: sample, clock regeneration and audio InfoFrame packets
    input  wire               gp_i,                 // send the generic packet once per frame
    input  wire         [1:0] pic_i,                // picture aspect ratio (M1:M0)
    input  wire         [3:0] act_i,                // active format aspect ratio (R3:R0)
    input  wire         [6:0] vic_i,                // video identification code
    input  wire         [1:0] quant_i,              // RGB quantization range (Q1:Q0)
    input  wire        [19:0] n_i,                  // audio clock regeneration N (a multiple of 128)
    input  wire         [3:0] cs_fs_i,              // channel status: sampling frequency (bits 24-27)
    input  wire         [3:0] cs_wl_i,              // channel status: word length (bits 32-35)
    input  wire        [23:0] gp_hdr_i,             // generic packet header HB2..HB0
    input  wire       [223:0] gp_pb_i,              // generic packet bytes PB27..PB0
    input  wire               div0_i,               // one pixel per clock (CLK_DIV = 0)
    input  wire               de_i,                 // data enable (active high)
    input  wire               hs_i,                 // HSYNC level as sent
    input  wire               vs_i,                 // VSYNC level as sent
    input  wire        [23:0] rgb_i,                // pixel {red, green, blue}
    input  wire               vpre_i,               // video preamble window, with the stream
    input  wire               vguard_i,             // video guard band window, with the stream
    input  wire               vblank_i,             // vertical blanking (stable for a line)
    input  wire               hbl_i,                // first horizontal blanking pixel, with the stream
    input  wire         [1:0] isl_i,                // packets an island may hold in the blanking (0-2)
    input  wire               i2s_bclk_i,           // I2S bit clock (asynchronous)
    input  wire               i2s_lrck_i,           // I2S word clock (asynchronous)
    input  wire               i2s_sd_i,             // I2S data (asynchronous)
    output wire        [29:0] tmds_o,               // {red, green, blue} symbols
    output wire        [19:0] cts_o,                // last CTS measured
    output wire               cts_t_o,              // toggles when cts_o changes
    output wire               ovf_o,                // an audio frame was lost
    output wire               aud_on_o              // audio on in this domain (AUD and HDMI mode), a register
);

localparam             ARST_EN = (ASYNC_RST_EN != 0);
localparam             AUD     = (AUDIO_EN != 0);
localparam integer     SUBN    = AUD ? 4 : 1;       // subpackets serialised (AVI: subpacket 0 only)

// Island geometry (counts from hbl_i = 1): preamble, leading guard band,
// first data character, characters per packet, last count of an island of
// one / two packets (its trailing guard band ends there). blns_dpi_scan
// (g_pre, isl_o) sizes the blanking for it: I_END + 15 pixels, 31 + 32n
localparam       [6:0] I_PRE   = 7'd5,
                       I_LG    = 7'd13,
                       I_DAT   = 7'd15,
                       I_PKT   = 7'd32,
                       I_END1  = I_DAT + I_PKT + 7'd1,
                       I_END2  = I_END1 + I_PKT;

// Packet characters: header bits (then 8 parity), subpacket bit pairs (then
// 4 parity characters)
localparam       [4:0] P_HDR   = 5'd24,
                       P_SUB   = 5'd28;

localparam       [9:0] GB_VID0 = 10'b1011001100;    // video guard band, channels 0 and 2
localparam       [9:0] GB_VID1 = 10'b0100110011;    // video guard band, channel 1
localparam       [9:0] GB_DI12 = 10'b0100110011;    // data island guard band, channels 1 and 2

localparam       [1:0] K_NONE  = 2'd0,
                       K_VGB   = 2'd1,
                       K_IGB   = 2'd2,
                       K_DAT   = 2'd3;

// Packet headers {HB2, HB1, HB0}
localparam      [23:0] H_ACR   = 24'h00_00_01;
localparam      [23:0] H_AVI   = 24'h0D_02_82;
localparam      [23:0] H_AIF   = 24'h0A_01_84;    // audio InfoFrame v1, length 10 (PB1-PB10)

function [9:0] terc4;
    input [3:0] d;
    case (d)
        4'h0: terc4 = 10'b1010011100;
        4'h1: terc4 = 10'b1001100011;
        4'h2: terc4 = 10'b1011100100;
        4'h3: terc4 = 10'b1011100010;
        4'h4: terc4 = 10'b0101110001;
        4'h5: terc4 = 10'b0100011110;
        4'h6: terc4 = 10'b0110001110;
        4'h7: terc4 = 10'b0100111100;
        4'h8: terc4 = 10'b1011001100;
        4'h9: terc4 = 10'b0100111001;
        4'hA: terc4 = 10'b0110011100;
        4'hB: terc4 = 10'b1011000110;
        4'hC: terc4 = 10'b1010001110;
        4'hD: terc4 = 10'b1001110001;
        4'hE: terc4 = 10'b0101100011;
        default: terc4 = 10'b1011000011;
    endcase
endfunction

// BCH step, x^8 + x^7 + x^6 + 1, LSB first
function [7:0] ecc_step;
    input [7:0] e;
    input       b;
    ecc_step = {1'b0, e[7:1]} ^ ((e[0] ^ b) ? 8'b1000_0011 : 8'h00);
endfunction

// Channel-status bit of frame f (consumer, linear PCM): bit 2 no copyright
// asserted, bits 20-23 channel number (1 left, 2 right), 24-27 sampling
// frequency, 32-35 word length
function cs_bit;
    input [7:0] f;
    input       right;
    input [3:0] fs;
    input [3:0] wl;
    cs_bit = (f == 8'd2) |
             ((f == 8'd20) & ~right) | ((f == 8'd21) & right) |
             ((f[7:2] == 6'd6) & fs[f[1:0]]) |
             ((f[7:2] == 6'd8) & wl[f[1:0]]);
endfunction

// Audio sample subpacket of frame fr = {right, left} with channel-status
// bits cl (left) and cr (right): left in SB0-SB2, right in SB3-SB5,
// SB6 = {PR, CR, UR, VR, PL, CL, UL, VL} (valid, no user data, parity even
// over sample, V, U, C and P)
function [55:0] asp_sub;
    input [47:0] fr;
    input        cl;
    input        cr;
    asp_sub = {^{fr[47:24], cr}, cr, 2'b00, ^{fr[23:0], cl}, cl, 2'b00, fr};
endfunction

// Channel-status frame f + k, modulo 192
function [7:0] fr_add;
    input [7:0] f;
    input [1:0] k;
    reg   [8:0] s;
    begin
        s      = {1'b0, f} + {7'd0, k};
        fr_add = (s >= 9'd192) ? s[7:0] - 8'd192 : s[7:0];
    end
endfunction

//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

wire                vbl_q;
wire                vbl_rise;
wire                mode;
wire                mode_nxt;
wire                aud_on;
wire                vpre;
wire                vguard;
wire          [2:0] a_cnt;
wire        [191:0] a_smp;
wire          [7:0] a_idx;
wire                a_pop;
wire                cts_new;
wire         [19:0] cts;
wire                cts_t;
wire                cts_t_nxt;
wire          [3:0] pend;               // {GP, AIF, AVI, ACR}
wire          [3:0] pend_nxt;
wire          [3:0] pend_set;
wire          [3:0] pend_clr;
wire                asp_ok;
wire          [2:0] want;
wire                start;
wire                two;
wire          [6:0] icnt;
wire          [6:0] icnt_nxt;
wire          [6:0] iend;
wire          [6:0] ioff;
wire                ipre;
wire                iguard;
wire                idata;
wire          [4:0] pidx;
wire                load;
wire                pend_end;
wire          [4:0] sel_q;              // the packet sent {GP, AIF, AVI, ACR, ASP}, latched at load
wire          [4:0] sel_nxt;
wire                a_rd;
wire                s_asp;
wire                s_acr;
wire                s_avi;
wire                s_aif;
wire                s_gp;
wire          [3:0] sp;
wire          [3:0] bf;
wire          [7:0] f0;
wire          [7:0] f1;
wire          [7:0] f2;
wire          [7:0] f3;
wire          [3:0] cl;
wire          [3:0] cr;
wire         [14:0] fld_nxt;
wire         [14:0] fld_q;              // the packet's fields, latched at load
wire          [3:0] bf_q;
wire          [3:0] cl_q;
wire          [3:0] cr_q;
wire         [19:0] n_q;
wire          [1:0] pic_q;
wire          [3:0] act_q;
wire          [6:0] vic_q;
wire          [1:0] quant_q;
wire         [55:0] asp0;
wire         [55:0] asp1;
wire         [55:0] asp2;
wire         [55:0] asp3;
wire         [55:0] acr_sub;
wire          [7:0] pb2;
wire          [7:0] pb3;
wire          [7:0] pb0;
wire         [55:0] avi_sub;
wire         [23:0] hdr;
wire        [223:0] sub;
wire          [7:0] hecc;
wire          [7:0] hecc_nxt;
wire         [31:0] spar;
wire         [31:0] spar_nxt;
wire                hbit;
wire          [3:0] s0b;
wire          [3:0] s1b;
wire          [1:0] kind;
wire          [3:0] n0;
wire         [13:0] ovr_q1;             // {kind, channel 0, channel 1, channel 2 nibbles}
wire         [13:0] ovr_q2;
wire         [29:0] enc;

//=============================================================================
// 2)  FRAME EVENTS, MODE AND THE AUDIO INPUT
//=============================================================================

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_vbl (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(vblank_i), .q_o(vbl_q));

assign vbl_rise = vblank_i & ~vbl_q;
assign mode_nxt = mode_i & div0_i;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_mode (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(vbl_rise), .d_i(mode_nxt), .q_o(mode));

assign aud_on = AUD & aud_i & mode;
assign vpre   = vpre_i & mode;
assign vguard = vguard_i & mode;

generate
    if (AUD) begin : g_i2s
        blns_hdmi_i2s #(.ASYNC_RST_EN(ARST_EN)) u_i2s (
            .clk_i     ( clk_i       ),
            .rst_n_i   ( rst_n_i     ),
            .en_i      ( aud_on      ),
            .nfr_i     ( n_i[19:7]   ),
            .bclk_i    ( i2s_bclk_i  ),
            .lrck_i    ( i2s_lrck_i  ),
            .sd_i      ( i2s_sd_i    ),
            .rd_i      ( a_rd        ),
            .pop_i     ( a_pop       ),
            .cts_hold_i( sel_q[1]    ),
            .cnt_o     ( a_cnt       ),
            .smp_o     ( a_smp       ),
            .idx_o     ( a_idx       ),
            .cts_o     ( cts         ),
            .cts_new_o ( cts_new     ),
            .ovf_o     ( ovf_o       )
        );

        assign cts_t_nxt = ~cts_t;

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cts_t (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(cts_new), .d_i(cts_t_nxt), .q_o(cts_t));

        // Audio on for the register side, a register (it is synchronised there):
        // a gate of two flops could glitch when one rises as the other falls
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_aud_on (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(aud_on), .q_o(aud_on_o));
    end else begin : g_no_i2s
        assign a_cnt     = 3'd0;
        assign a_smp     = 192'd0;
        assign a_idx     = 8'd0;
        assign cts       = 20'd0;
        assign cts_new   = 1'b0;
        assign ovf_o     = 1'b0;
        assign cts_t     = 1'b0;
        assign cts_t_nxt = 1'b0;
        assign aud_on_o  = 1'b0;
        wire [283:0] aud_in_unused = {aud_i, gp_i, n_i, cs_fs_i, cs_wl_i, gp_hdr_i, gp_pb_i,
                                      i2s_bclk_i, i2s_lrck_i, i2s_sd_i, a_rd, a_pop, cts_t_nxt};
    end
endgenerate

assign cts_o    = cts;
assign cts_t_o  = cts_t;

//=============================================================================
// 3)  PACKETS DUE AND THE ISLAND SCHEDULE
//=============================================================================
// Once per frame (start of vertical blanking): AVI, audio InfoFrame, generic
// packet; after each CTS measurement: clock regeneration

assign pend_set = {vbl_rise & mode_nxt & gp_i & AUD, vbl_rise & mode_nxt & aud_i & AUD,
                   vbl_rise & mode_nxt & avi_i, cts_new & aud_on};
// A pending packet is dropped with its enable (and with HDMI mode): its
// fields are read only while the enable is set
assign pend_nxt = ({4{mode}} & {gp_i & AUD, aud_i & AUD, avi_i, aud_on} & pend & ~pend_clr) | pend_set;

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_pend (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pend_nxt), .q_o(pend));

assign asp_ok = aud_on & (a_cnt != 3'd0);
assign want   = {2'd0, asp_ok} + {2'd0, pend[0]} + {2'd0, pend[1]} + {2'd0, pend[2]} + {2'd0, pend[3]};
assign start  = hbl_i & mode & (isl_i != 2'd0) & (icnt == 7'd0) & (want != 3'd0);
assign iend   = two ? I_END2 : I_END1;

assign icnt_nxt = start                            ? 7'd1 :
                  ((icnt != 7'd0) & (icnt < iend)) ? icnt + 7'd1 : 7'd0;

arv_ipdff #(.WIDTH(7), .ARST_EN(ARST_EN)) u_icnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(icnt_nxt), .q_o(icnt));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_two (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(start), .d_i(isl_i[1] & (want > 3'd1)), .q_o(two));

assign ioff   = icnt - I_DAT;
assign ipre   = (icnt >= I_PRE) & (icnt < I_LG);
assign iguard = (icnt == I_LG) | (icnt == I_LG + 7'd1) | (icnt == iend - 7'd1) | (icnt == iend);
assign idata  = (icnt >= I_DAT) & (icnt < iend - 7'd1);
assign pidx   = ioff[4:0];

wire          [1:0] ioff_unused = ioff[6:5];

// A packet's type and fields are latched the clock before its first
// character: load, a register, decoded from the next count. pend_end: its
// last data character (28-31 carry parity only)
wire                load_nxt = (icnt_nxt == I_DAT - 7'd1) |
                               ((start ? (isl_i[1] & (want > 3'd1)) : two) & (icnt_nxt == I_DAT + I_PKT - 7'd1));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_load (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(load_nxt), .q_o(load));

assign pend_end = idata & (pidx == P_SUB - 5'd1);

//=============================================================================
// 4)  PACKET CONTENTS
//=============================================================================

// The audio sample packet goes first, except in a one-packet island while
// fewer than 3 frames wait and another packet is due: the buffer then absorbs
// the next line's frames (up to 2), so nothing is lost while the audio frame
// rate is at most twice the line rate
assign s_asp = asp_ok & (two | (pend == 4'd0) | (a_cnt >= 3'd3));
assign s_acr = ~s_asp & pend[0];
assign s_avi = ~s_asp & ~pend[0] & pend[1];
assign s_aif = ~s_asp & ~pend[0] & ~pend[1] & pend[2];
assign s_gp  = ~s_asp & ~pend[0] & ~pend[1] & ~pend[2] & pend[3];

assign pend_clr = {4{load}} & {s_gp, s_aif, s_avi, s_acr};

// The packet's type, latched at load, cleared after its last data character.
// The audio buffer holds still from the load of a sample packet to its pop
// (blns_hdmi_i2s), and the CTS meter takes no measurement while a clock
// regeneration packet reads the CTS
assign sel_nxt = {5{load}} & {s_gp, s_aif, s_avi, s_acr, s_asp};

arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_sel (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(load | pend_end), .d_i(sel_nxt), .q_o(sel_q));

assign a_rd  = (load & s_asp) | sel_q[0];
assign a_pop = sel_q[0] & pend_end;

// Audio sample packet: frames present, block starts (frame 0 of the 192),
// the channel-status bits of each frame
assign sp = {(a_cnt == 3'd4), (a_cnt >= 3'd3), (a_cnt >= 3'd2), (a_cnt != 3'd0)};
assign f0 = a_idx;
assign f1 = fr_add(a_idx, 2'd1);
assign f2 = fr_add(a_idx, 2'd2);
assign f3 = fr_add(a_idx, 2'd3);
assign bf = sp & {(f3 == 8'd0), (f2 == 8'd0), (f1 == 8'd0), (f0 == 8'd0)};
assign cl = {cs_bit(f3, 1'b0, cs_fs_i, cs_wl_i), cs_bit(f2, 1'b0, cs_fs_i, cs_wl_i),
             cs_bit(f1, 1'b0, cs_fs_i, cs_wl_i), cs_bit(f0, 1'b0, cs_fs_i, cs_wl_i)};
assign cr = {cs_bit(f3, 1'b1, cs_fs_i, cs_wl_i), cs_bit(f2, 1'b1, cs_fs_i, cs_wl_i),
             cs_bit(f1, 1'b1, cs_fs_i, cs_wl_i), cs_bit(f0, 1'b1, cs_fs_i, cs_wl_i)};

// The fields that may change while the packet is sent, latched at load:
// audio sample packet {block starts, right and left channel status}, clock
// regeneration N[19:7] (N[6:0] is 0), AVI {Q, VIC, R, M}. The other sources
// stay still: the frames (the buffer holds), the CTS (no measurement taken),
// the generic packet (not written while GP is set; software waits a frame
// after clearing it)
assign fld_nxt = ({15{s_asp}} & {3'd0, bf, cr, cl})                |
                 ({15{s_acr}} & {2'd0, n_i[19:7]})                 |
                 ({15{s_avi}} & {quant_i, vic_i, act_i, pic_i})    ;

arv_ipdff #(.WIDTH(15), .ARST_EN(ARST_EN)) u_fld (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(load), .d_i(fld_nxt), .q_o(fld_q));

assign {bf_q, cr_q, cl_q}             = fld_q[11:0];
assign n_q                            = {fld_q[12:0], 7'd0};
assign {quant_q, vic_q, act_q, pic_q} = fld_q;

wire          [6:0] n_unused = n_i[6:0];

assign asp0 = {56{sp[0]}} & asp_sub(a_smp[47:0],    cl_q[0], cr_q[0]);
assign asp1 = {56{sp[1]}} & asp_sub(a_smp[95:48],   cl_q[1], cr_q[1]);
assign asp2 = {56{sp[2]}} & asp_sub(a_smp[143:96],  cl_q[2], cr_q[2]);
assign asp3 = {56{sp[3]}} & asp_sub(a_smp[191:144], cl_q[3], cr_q[3]);

// Clock regeneration: SB0 = 0, SB1-SB3 = CTS, SB4-SB6 = N (most significant first)
assign acr_sub = {n_q[7:0], n_q[15:8], 4'h0, n_q[19:16], cts[7:0], cts[15:8], 4'h0, cts[19:16], 8'h00};

// AVI InfoFrame: PB1 = 0x10 (RGB, active format present), PB2 = {C, M, R},
// PB3 = {ITC, EC, Q, SC} with only Q1:Q0 (bits 3:2) set, PB4 = VIC; PB0 the
// checksum (header and PB0-PB13 sum to 0; 0xA1 is the header plus PB1)
assign pb2     = {2'b00, pic_q, act_q};
assign pb3     = {4'h0, quant_q, 2'b00};
assign pb0     = 8'h00 - (8'hA1 + pb2 + pb3 + {1'b0, vic_q});
assign avi_sub = {8'h00, 8'h00, {1'b0, vic_q}, pb3, pb2, 8'h10, pb0};

// The header and the subpackets of the packet sent
assign hdr = ({24{sel_q[0]}} & {bf_q, 4'h0, 4'h0, sp, 8'h02}) |
             ({24{sel_q[1]}} & H_ACR)                        |
             ({24{sel_q[2]}} & H_AVI)                        |
             ({24{sel_q[3]}} & H_AIF)                        |
             ({24{sel_q[4]}} & gp_hdr_i)                     ;

assign sub = ({224{sel_q[0]}} & {asp3, asp2, asp1, asp0})                   |
             ({224{sel_q[1]}} & {acr_sub, acr_sub, acr_sub, acr_sub})       |
             ({224{sel_q[2]}} & {168'd0, avi_sub})                          |
             // Audio InfoFrame (2 channels, the rest from the stream): PB1 = 0x01, checksum 0x70
             ({224{sel_q[3]}} & {168'd0, 40'd0, 8'h01, 8'h70})              |
             ({224{sel_q[4]}} & gp_pb_i)                                    ;

//=============================================================================
// 5)  PACKET SERIALISER
//=============================================================================
// Header: one bit per character (channel 0 bit 2), its parity in characters
// 24-31; subpacket k: two bits per character (channels 1 and 2, bit k), its
// parity in characters 28-31. The bits are read from the sources, indexed by
// the character

wire         [31:0] hdr_x = {8'h00, hdr};
wire                hcur  = hdr_x[pidx];

assign hecc_nxt = load ? 8'h00 : (idata & (pidx < P_HDR)) ? ecc_step(hecc, hcur) : hecc;

arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_hdr (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(hecc_nxt), .q_o(hecc));

genvar gk;
generate
    for (gk = 0; gk < SUBN; gk = gk + 1) begin : g_sub
        wire [63:0] src = {8'h00, sub[56*gk +: 56]};
        wire  [1:0] sh  = src[{pidx, 1'b0} +: 2];
        wire  [7:0] par = spar[8*gk +: 8];
        assign spar_nxt[8*gk +: 8]  = load ? 8'h00 :
                                      (idata & (pidx < P_SUB)) ? ecc_step(ecc_step(par, sh[0]), sh[1]) : par;
        assign s0b[gk] = (pidx < P_SUB) ? sh[0] : par[{pidx[1:0], 1'b0}];
        assign s1b[gk] = (pidx < P_SUB) ? sh[1] : par[{pidx[1:0], 1'b1}];
        arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_sub (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(spar_nxt[8*gk +: 8]), .q_o(spar[8*gk +: 8]));
    end
    // Without audio only subpacket 0 carries data (the AVI InfoFrame)
    for (gk = SUBN; gk < 4; gk = gk + 1) begin : g_sub_none
        assign spar[8*gk +: 8]     = 8'd0;
        assign spar_nxt[8*gk +: 8] = 8'd0;
        assign s0b[gk]             = 1'b0;
        assign s1b[gk]             = 1'b0;
        wire   [71:0] sub_unused   = {sub[56*gk +: 56], spar[8*gk +: 8], spar_nxt[8*gk +: 8]};
    end
endgenerate

assign hbit = (pidx < P_HDR) ? hcur : hecc[pidx[2:0]];

//=============================================================================
// 6)  SYMBOLS
//=============================================================================
// Preambles are control symbols (CTL0 on channel 1, CTL2 on channel 2); the
// guard bands and the TERC4 characters replace the encoders' output two
// clocks later, where the encoders deliver this clock's symbols

assign kind = vguard ? K_VGB : iguard ? K_IGB : idata ? K_DAT : K_NONE;
assign n0   = iguard ? {2'b11, vs_i, hs_i} : {(icnt != I_DAT), hbit, vs_i, hs_i};   // bit 3: 0 on the island's first character

arv_ipdff #(.WIDTH(14), .ARST_EN(ARST_EN)) u_ovr1 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i({kind, n0, s0b, s1b}), .q_o(ovr_q1));
arv_ipdff #(.WIDTH(14), .ARST_EN(ARST_EN)) u_ovr2 (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(ovr_q1), .q_o(ovr_q2));

blns_tmds #(.ASYNC_RST_EN(ARST_EN)) u_tmds_b (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .de_i(de_i), .c_i({vs_i, hs_i}),
    .d_i(rgb_i[7:0]),   .q_o(enc[9:0]));
blns_tmds #(.CTL_EN(2), .ASYNC_RST_EN(ARST_EN)) u_tmds_g (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .de_i(de_i), .c_i({1'b0, vpre | ipre}),
    .d_i(rgb_i[15:8]),  .q_o(enc[19:10]));
blns_tmds #(.CTL_EN(2), .ASYNC_RST_EN(ARST_EN)) u_tmds_r (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .de_i(de_i), .c_i({1'b0, ipre}),
    .d_i(rgb_i[23:16]), .q_o(enc[29:20]));

assign tmds_o = (ovr_q2[13:12] == K_VGB) ? {GB_VID0, GB_VID1, GB_VID0} :
                (ovr_q2[13:12] == K_IGB) ? {GB_DI12, GB_DI12, terc4(ovr_q2[11:8])} :
                (ovr_q2[13:12] == K_DAT) ? {terc4(ovr_q2[3:0]), terc4(ovr_q2[7:4]), terc4(ovr_q2[11:8])} :
                                           enc;

endmodule // blns_hdmi

`default_nettype wire
