//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    tmds_rx_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tmds_rx_model.v
// Module Description : TMDS receiver check for DIF_TYPE = 5. Every pixel-domain
//                      clock it decodes the three symbols and compares them
//                      with the DPI pins LAT cycles earlier: a data symbol
//                      while the true data enable is high that decodes to the
//                      pixel, with the running disparity of each channel
//                      bounded; in blanking a control symbol with {VSYNC,
//                      HSYNC} on channel 0 and 00 on channels 1 and 2, except
//                      for the HDMI structures, which it decodes:
//                      - a video preamble (8 controls, CTL0 = 1) and a video
//                        guard band (2 characters) right before a line;
//                      - a data island: preamble (8 controls, CTL0 = CTL2 = 1),
//                        guard band, packets of 32 TERC4 characters, guard
//                        band. Channel 0 carries {VSYNC, HSYNC} in every
//                        island character, bit 3 is 0 on the first data
//                        character only; each packet's BCH parity bytes are
//                        checked and the packet is kept (pkt_hdr, pkt_sub).
//                      Island placement: every island preamble starts at the
//                      6th blanking pixel (a 5-character control period from
//                      the first one; the island ends 16 + 32n pixels after
//                      the first). In an active line's blanking the position
//                      is counted from the DE fall. In the vertical blanking
//                      it is counted from the last DE fall with the line
//                      total, which is measured on the active lines (two
//                      equal DE-to-DE gaps holding one HSYNC pulse each) of
//                      the frames before and after; a vertical blanking
//                      where the timing changes (line total or active width)
//                      is not checked (isl_skip). Without audio (AUDIO = 0)
//                      the island sits in the first line of the vertical
//                      blanking, at most one per frame (isl_n counts the
//                      islands checked). At most one AVI InfoFrame per frame; frames
//                      without one are counted (fr_n, fr_avi0) for the
//                      tests that expect one in every frame.
//                      Counts: lines sent with and without the video preamble
//                      (vlines_hdmi, vlines_dvi), packets (pkt_count).
//                      Packets by type: null, audio clock regeneration (its
//                      four subpackets equal; acr_n, acr_cts), audio sample
//                      (2-channel layout; each frame present logged in
//                      aud_l/aud_r/aud_c/aud_b with a parity check of both
//                      subframes, asp_perr), AVI and audio InfoFrames (their
//                      checksum checked: header and PB0 to PB[length] sum
//                      to 0; the last AVI's RGB quantization range in
//                      avi_q), other types (last one in oth_hdr, oth_sub).
//----------------------------------------------------------------------------
module  tmds_rx_model #(
    parameter LAT   = 2,                  // encoder latency in pixel-domain clocks
    parameter AUDIO = 1                   // 0: one island per frame, in the first vblank line
) (
    input  wire        clk_i,             // pixel-domain clock
    input  wire        en_i,              // checking enabled (pixel domain out of reset)
    input  wire [29:0] tmds_i,            // {red, green, blue} symbols
    input  wire        de_i,              // true data enable (active high)
    input  wire        hs_i,              // HSYNC pin
    input  wire        vs_i,              // VSYNC pin
    input  wire [23:0] rgb_i              // RGB pins
);

integer errors      = 0;
integer data_sym    = 0;                  // data symbols checked
integer ctl_sym     = 0;                  // control symbols checked
integer vlines_hdmi = 0;                  // lines after a video preamble and guard band
integer vlines_dvi  = 0;                  // lines after plain control symbols
integer pkt_count   = 0;                  // packets received with correct parity
reg  [23:0] pkt_hdr = 24'd0;              // last packet: header HB2..HB0
reg [223:0] pkt_sub = 224'd0;             // last packet: subpackets 3..0
integer n_null      = 0;
integer isl2        = 0;                  // islands of two packets
integer n_acr       = 0;
integer n_asp       = 0;
integer n_avi       = 0;
integer n_aif       = 0;
integer n_oth       = 0;
integer asp_perr    = 0;                  // audio subframes with a wrong parity bit
integer asp_ferr    = 0;                  // audio sample packets with a bad header or layout
integer asp4        = 0;                  // audio sample packets holding 4 frames
integer acr_err     = 0;                  // clock regeneration packets with differing subpackets
integer aud_n       = 0;                  // audio frames logged
reg  [19:0] acr_n   = 20'd0;
reg  [19:0] acr_cts = 20'd0;
reg  [23:0] avi_hdr = 24'd0;
reg [223:0] avi_sub = 224'd0;
reg   [1:0] avi_q   = 2'd0;               // last AVI InfoFrame: Q1:Q0 (PB3 bits 3:2)
reg  [23:0] aif_hdr = 24'd0;
reg [223:0] aif_sub = 224'd0;
reg  [23:0] oth_hdr = 24'd0;
reg [223:0] oth_sub = 224'd0;
integer fr_n        = 0;                  // frames ended (a DE rise after a vertical blanking)
integer fr_avi0     = 0;                  // of them, frames without an AVI InfoFrame
integer isl_n       = 0;                  // islands whose placement was checked
integer fr_avi      = 0;                  // AVI InfoFrames in the frame being received
integer fr_on       = 0;                  // a frame boundary was seen since the start
integer isl_skip    = 0;                  // islands of a vertical blanking not checked
integer cyc         = 0;                  // clocks since the checks started
integer t_fall      = -1;                 // clock of the last DE fall (the first blanking pixel)
integer t_rise      = 0;                  // clock of the last DE rise
integer de_len      = 0;                  // active width of the last line
integer de_first    = -1;                 // active width of the frame's first line
integer first_ln    = 0;                  // the next DE fall ends a frame's first line
integer h_frame     = 0;                  // line total of this frame (0 unknown)
integer h_cand      = 0;                  // last DE-to-DE gap of one line
integer since_rise  = 0;                  // clocks since the last DE rise
integer hs_rises    = 0;                  // HSYNC rising edges since the last DE rise
integer nrec        = 0;                  // islands of the blanking being received
integer rec_t [0:15];                     // their first preamble clock
integer pv_on       = 0;                  // a vertical blanking waits for the next frame's line total
integer pv_n        = 0;
integer pv_t  [0:15];
integer pv_tf       = 0;                  // its last DE fall
integer pv_h        = 0;                  // line total and active width of the frame before it
integer pv_ha       = 0;
integer r;
reg  [23:0] aud_l [0:16383];
reg  [23:0] aud_r [0:16383];
reg   [1:0] aud_c [0:16383];              // {right, left} channel-status bits
reg         aud_b [0:16383];              // block start (frame 0 of 192)

localparam [9:0] GB_VID0 = 10'b1011001100;
localparam [9:0] GB_VID1 = 10'b0100110011;
localparam [9:0] GB_DI12 = 10'b0100110011;

reg [26:0] pipe [0:LAT-1];
integer    k;
integer    disp [0:2];
initial begin
   for (k = 0; k < LAT; k = k + 1) pipe[k] = 27'h0;
   for (k = 0; k < 3; k = k + 1) disp[k] = 0;
end

function is_ctl;
   input [9:0] s;
   is_ctl = (s == 10'b1101010100) || (s == 10'b0010101011) ||
            (s == 10'b0101010100) || (s == 10'b1010101011);
endfunction

function [1:0] ctl_val;
   input [9:0] s;
   ctl_val = (s == 10'b1101010100) ? 2'b00 : (s == 10'b0010101011) ? 2'b01 :
             (s == 10'b0101010100) ? 2'b10 : 2'b11;
endfunction

// TERC4 decode: {valid, nibble}
function [4:0] terc4_dec;
   input [9:0] s;
   case (s)
      10'b1010011100: terc4_dec = 5'h10; 10'b1001100011: terc4_dec = 5'h11;
      10'b1011100100: terc4_dec = 5'h12; 10'b1011100010: terc4_dec = 5'h13;
      10'b0101110001: terc4_dec = 5'h14; 10'b0100011110: terc4_dec = 5'h15;
      10'b0110001110: terc4_dec = 5'h16; 10'b0100111100: terc4_dec = 5'h17;
      10'b1011001100: terc4_dec = 5'h18; 10'b0100111001: terc4_dec = 5'h19;
      10'b0110011100: terc4_dec = 5'h1A; 10'b1011000110: terc4_dec = 5'h1B;
      10'b1010001110: terc4_dec = 5'h1C; 10'b1001110001: terc4_dec = 5'h1D;
      10'b0101100011: terc4_dec = 5'h1E; 10'b1011000011: terc4_dec = 5'h1F;
      default:        terc4_dec = 5'h00;
   endcase
endfunction

function [7:0] dec;
   input [9:0] s;
   reg   [7:0] v;
   integer     i;
   begin
      v      = s[9] ? ~s[7:0] : s[7:0];
      dec[0] = v[0];
      for (i = 1; i < 8; i = i + 1)
         dec[i] = s[8] ? (v[i] ^ v[i-1]) : ~(v[i] ^ v[i-1]);
   end
endfunction

function integer ones10;
   input [9:0] s;
   integer i;
   begin
      ones10 = 0;
      for (i = 0; i < 10; i = i + 1) ones10 = ones10 + s[i];
   end
endfunction

function [7:0] ecc_step;
   input [7:0] e;
   input       b;
   ecc_step = {1'b0, e[7:1]} ^ ((e[0] ^ b) ? 8'b1000_0011 : 8'h00);
endfunction

task err;
   input [80*8-1:0] msg;
   begin
      $display("ERROR: TMDS -- %0s %t", msg, $time);
      errors = errors + 1;
   end
endtask

// Blanking classification and the HDMI structures
localparam C_CTL = 0, C_VPRE = 1, C_IPRE = 2, C_VGB = 3, C_IGB = 4, C_TERC = 5, C_BAD = 6;
integer     run_cls  = C_CTL;             // class of the previous blanking characters
integer     run_len  = 0;                 // how many of them in a row
integer     prev_cls = C_CTL;             // class before that run
integer     prev_len = 0;
integer     isl      = 0;                 // island: 0 none, 1 after lead guard, 2 data, 3 after trail guard
integer     ipos     = 0;                 // data character index in the island
reg  [31:0] pb4;                          // header + parity, received
reg  [63:0] pb [0:3];                     // subpackets + parity, received
integer     j;

// InfoFrame checksum: the header and PB0 to PB[length] (length HB2) sum to 0
function if_sum_ok;
   input  [23:0] hdr;
   input [223:0] sub;
   reg     [7:0] sum;
   integer       i;
   begin
      sum = hdr[7:0] + hdr[15:8] + hdr[23:16];
      for (i = 0; i < 28; i = i + 1)
         if (i <= hdr[23:16]) sum = sum + sub[8*i +: 8];
      if_sum_ok = (sum == 8'h00);
   end
endfunction

task end_packet;
   reg [7:0] e;
   integer   b, s;
   reg       bad;
   begin
      bad = 1'b0;
      e = 8'd0;
      for (b = 0; b < 24; b = b + 1) e = ecc_step(e, pb4[b]);
      if (e !== pb4[31:24]) bad = 1'b1;
      for (s = 0; s < 4; s = s + 1) begin
         e = 8'd0;
         for (b = 0; b < 56; b = b + 1) e = ecc_step(e, pb[s][b]);
         if (e !== pb[s][63:56]) bad = 1'b1;
      end
      if (bad) err("packet parity error");
      else begin
         pkt_count = pkt_count + 1;
         pkt_hdr   = pb4[23:0];
         pkt_sub   = {pb[3][55:0], pb[2][55:0], pb[1][55:0], pb[0][55:0]};
         case (pb4[7:0])
            8'h00: n_null = n_null + 1;
            8'h01: begin
               n_acr = n_acr + 1;
               if ((pb[0][55:0] !== pb[1][55:0]) || (pb[0][55:0] !== pb[2][55:0]) ||
                   (pb[0][55:0] !== pb[3][55:0]) || (pb[0][7:0] !== 8'h00) || (pb4[23:8] !== 16'h0))
                  acr_err = acr_err + 1;
               acr_cts = {pb[0][11:8], pb[0][23:16], pb[0][31:24]};
               acr_n   = {pb[0][35:32], pb[0][47:40], pb[0][55:48]};
            end
            8'h02: begin
               n_asp = n_asp + 1;
               if ((pb4[15:12] !== 4'h0) || (pb4[19:16] !== 4'h0) || (pb4[11:8] == 4'h0)) asp_ferr = asp_ferr + 1;
               if (pb4[11:8] == 4'hF) asp4 = asp4 + 1;
               for (s = 0; s < 4; s = s + 1) begin
                  if (pb4[8 + s]) begin
                     if ((pb[s][53:52] !== 2'b00) || (pb[s][49:48] !== 2'b00)) asp_ferr = asp_ferr + 1;   // V and U
                     if (pb[s][51] !== ^{pb[s][23:0], pb[s][50], pb[s][49], pb[s][48]}) asp_perr = asp_perr + 1;
                     if (pb[s][55] !== ^{pb[s][47:24], pb[s][54], pb[s][53], pb[s][52]}) asp_perr = asp_perr + 1;
                     if (aud_n < 16384) begin
                        aud_l[aud_n] = pb[s][23:0];
                        aud_r[aud_n] = pb[s][47:24];
                        aud_c[aud_n] = {pb[s][54], pb[s][50]};
                        aud_b[aud_n] = pb4[20 + s];
                     end
                     aud_n = aud_n + 1;
                  end else if ((pb[s][55:0] !== 56'd0) || pb4[20 + s]) asp_ferr = asp_ferr + 1;
               end
            end
            8'h82: begin
               n_avi = n_avi + 1; avi_hdr = pb4[23:0]; avi_sub = pkt_sub; avi_q = pkt_sub[27:26];
               if (!if_sum_ok(pb4[23:0], pkt_sub)) err("AVI InfoFrame checksum");
               fr_avi = fr_avi + 1;
               if (fr_avi > 1) err("two AVI InfoFrames in one frame");
            end
            8'h84: begin
               n_aif = n_aif + 1; aif_hdr = pb4[23:0]; aif_sub = pkt_sub;
               if (!if_sum_ok(pb4[23:0], pkt_sub)) err("audio InfoFrame checksum");
            end
            default: begin n_oth = n_oth + 1; oth_hdr = pb4[23:0]; oth_sub = pkt_sub; end
         endcase
      end
   end
endtask

reg  [26:0] exp_q;
reg  [26:0] last_q;
reg   [9:0] sym;
reg   [9:0] s0, s1, s2;
reg   [4:0] t0, t1, t2;
integer     ch;
integer     cls;
integer     armed = 0;                    // clocks with en_i high: check once the pipe holds them

always @(posedge clk_i) begin
   exp_q = pipe[LAT-1];
   for (k = LAT-1; k > 0; k = k - 1) pipe[k] = pipe[k-1];
   pipe[0] = {de_i, vs_i, hs_i, rgb_i};
   armed   = en_i ? armed + 1 : 0;
   s0 = tmds_i[9:0]; s1 = tmds_i[19:10]; s2 = tmds_i[29:20];
   if ((armed > LAT) !== 1'b1) begin                  // not armed (also X before the first reset)
      t_fall = -1; h_frame = 0; h_cand = 0; since_rise = 0; hs_rises = 0; fr_on = 0;
      nrec = 0; pv_on = 0; first_ln = 0; fr_avi = 0;
   end else begin
      cyc        = cyc + 1;
      since_rise = since_rise + 1;
      if (exp_q[24] && !last_q[24]) hs_rises = hs_rises + 1;
      if (exp_q[26]) begin
         // A line starts: what came before it
         if (!last_q[26]) begin
            // A gap of one line (one HSYNC pulse): the islands of an
            // active line's blanking, the line total (two equal gaps);
            // several lines: a frame ends, its vertical blanking waits for
            // the next frame's line total; none (the driver stopped):
            // nothing known
            if (hs_rises == 1) begin
               for (r = 0; r < nrec; r = r + 1) begin
                  isl_n = isl_n + 1;
                  if (rec_t[r] - t_fall != 5) begin
                     $display("ERROR: TMDS -- island preamble at blanking pixel %0d of an active line, not the 6th %t",
                              rec_t[r] - t_fall + 1, $time);
                     errors = errors + 1;
                  end
                  if (AUDIO == 0) err("island in the blanking of an active line (no audio)");
               end
               if (since_rise == h_cand) h_frame = since_rise;
               h_cand = since_rise;
               if (pv_on && (h_frame != 0)) begin
                  pv_on = 0;
                  if ((h_frame == pv_h) && (de_first == pv_ha)) begin
                     for (r = 0; r < pv_n; r = r + 1) begin
                        isl_n = isl_n + 1;
                        if (((pv_t[r] - pv_tf) % h_frame != 5) || ((AUDIO == 0) && ((pv_t[r] - pv_tf) / h_frame != 1))) begin
                           $display("ERROR: TMDS -- island preamble at blanking pixel %0d of vertical blanking line %0d, not the 6th%0s",
                                    (pv_t[r] - pv_tf) % h_frame + 1, (pv_t[r] - pv_tf) / h_frame,
                                    (AUDIO == 0) ? " of line 1" : "");
                           errors = errors + 1;
                        end
                     end
                  end else isl_skip = isl_skip + pv_n;
               end
            end else if (hs_rises == 0) begin
               h_frame = 0; h_cand = 0; fr_on = 0; pv_on = 0; first_ln = 0; fr_avi = 0;
            end else begin
               if (pv_on) isl_skip = isl_skip + pv_n;
               if ((AUDIO == 0) && (nrec > 1)) err("more than one island in a frame without audio");
               pv_on = (h_frame != 0) && (t_fall >= 0);
               pv_n  = nrec; pv_tf = t_fall; pv_h = h_frame; pv_ha = de_len;
               for (r = 0; r < nrec; r = r + 1) pv_t[r] = rec_t[r];
               if (!pv_on) isl_skip = isl_skip + nrec;
               h_frame = 0; h_cand = 0; first_ln = 1;
               if (fr_on) begin
                  fr_n = fr_n + 1;
                  if (fr_avi == 0) fr_avi0 = fr_avi0 + 1;
               end
               fr_on = 1; fr_avi = 0;
            end
            since_rise = 0; hs_rises = 0; nrec = 0; t_rise = cyc;
            if ((run_cls == C_VGB) && (run_len == 2) && (prev_cls == C_VPRE) && (prev_len == 8))
               vlines_hdmi = vlines_hdmi + 1;
            else if (run_cls == C_CTL)
               vlines_dvi = vlines_dvi + 1;
            else err("line not preceded by a video preamble and guard band, nor by controls");
            if (isl != 0) err("data island not closed before the line");
            isl = 0;
         end
         run_cls = C_CTL; run_len = 0; prev_cls = C_CTL; prev_len = 0;
         for (ch = 0; ch < 3; ch = ch + 1) begin
            sym = tmds_i[ch*10 +: 10];
            if (is_ctl(sym)) err("control symbol during data");
            else if (dec(sym) !== exp_q[ch*8 +: 8]) err("data symbol does not decode to the pixel");
            disp[ch] = disp[ch] + ones10(sym) - 5;
            if ((disp[ch] > 8) || (disp[ch] < -8)) begin
               err("running disparity out of bounds");
               disp[ch] = 0;
            end
         end
         data_sym = data_sym + 1;
      end else begin
         // The first blanking pixel after a line
         if (last_q[26]) begin
            t_fall = cyc; de_len = cyc - t_rise;
            if (first_ln) begin de_first = de_len; first_ln = 0; end
         end
         for (ch = 0; ch < 3; ch = ch + 1) disp[ch] = 0;
         t0 = terc4_dec(s0); t1 = terc4_dec(s1); t2 = terc4_dec(s2);
         // Classify the character
         if (is_ctl(s0) && is_ctl(s1) && is_ctl(s2)) begin
            if (ctl_val(s0) !== exp_q[25:24]) err("channel 0 control does not carry the syncs");
            if ((ctl_val(s1) == 2'b00) && (ctl_val(s2) == 2'b00)) cls = C_CTL;
            else if ((ctl_val(s1) == 2'b01) && (ctl_val(s2) == 2'b00)) cls = C_VPRE;
            else if ((ctl_val(s1) == 2'b01) && (ctl_val(s2) == 2'b01)) cls = C_IPRE;
            else cls = C_BAD;
            ctl_sym = ctl_sym + 1;
         end else if ((s0 == GB_VID0) && (s1 == GB_VID1) && (s2 == GB_VID0) && (isl == 0))
            cls = C_VGB;
         else if ((s1 == GB_DI12) && (s2 == GB_DI12) && t0[4] && (t0[3:2] == 2'b11) &&
                  !((isl == 2) && (ipos % 32 != 0)))
            cls = C_IGB;
         else if (t0[4] && t1[4] && t2[4])
            cls = C_TERC;
         else
            cls = C_BAD;
         if (cls == C_BAD) err("character not allowed in blanking");
         // Island placement, at the first preamble character
         if ((cls == C_IPRE) && (run_cls != C_IPRE) && (t_fall >= 0) && (nrec < 16)) begin
            rec_t[nrec] = cyc;
            nrec = nrec + 1;
         end
         // Island structure
         case (cls)
            C_IGB: begin
               if (t0[1:0] !== exp_q[25:24]) err("island guard band does not carry the syncs");
               if (isl == 0) begin
                  // lead guard band, first character: after 8 island preamble characters
                  if ((run_cls == C_IPRE) && (run_len == 8)) isl = 1;
                  else err("island guard band without a preamble");
               end else if ((isl == 1) || (isl == 3)) begin
                  // second character of a guard band
                  if (!((run_cls == C_IGB) && (run_len == 1))) err("island guard band longer than 2 characters");
               end else begin
                  isl = 3;                // trailing guard band after whole packets
                  if (ipos == 64) isl2 = isl2 + 1;
               end
            end
            C_TERC: begin
               if (isl == 1) begin
                  if (!((run_cls == C_IGB) && (run_len == 2))) err("island data without a 2-character guard band");
                  isl = 2; ipos = 0;
               end
               if (isl != 2) err("TERC4 character outside a data island");
               else begin
                  if (t0[1:0] !== exp_q[25:24]) err("island data does not carry the syncs");
                  if (t0[3] !== (ipos != 0)) err("island channel 0 bit 3 wrong");
                  j = ipos % 32;
                  pb4[j]          = t0[2];
                  pb[0][2*j]      = t1[0]; pb[1][2*j]      = t1[1]; pb[2][2*j]      = t1[2]; pb[3][2*j]      = t1[3];
                  pb[0][2*j + 1]  = t2[0]; pb[1][2*j + 1]  = t2[1]; pb[2][2*j + 1]  = t2[2]; pb[3][2*j + 1]  = t2[3];
                  ipos = ipos + 1;
                  if (ipos % 32 == 0) end_packet;
               end
            end
            default: begin
               if (isl == 3) begin
                  if (!((run_cls == C_IGB) && (run_len == 2))) err("island not closed by a 2-character guard band");
                  isl = 0;
               end else if (isl != 0) begin
                  err("island interrupted");
                  isl = 0;
               end
            end
         endcase
         if (cls == C_VGB && !((run_cls == C_VPRE && run_len == 8) || (run_cls == C_VGB && run_len == 1)))
            err("video guard band without an 8-character preamble");
         if ((run_cls == C_VGB) && (cls != C_VGB)) err("video guard band not followed by a line");
         if (cls == run_cls) run_len = run_len + 1;
         else begin prev_cls = run_cls; prev_len = run_len; run_cls = cls; run_len = 1; end
      end
   end
   last_q = exp_q;
end

endmodule // tmds_rx_model
