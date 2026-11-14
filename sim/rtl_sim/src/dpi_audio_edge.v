//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_audio_edge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_audio_edge.v
// Module Description : HDMI audio (DPI_AUDIO_EN) at its edges, the receiver
//                      model decoding every packet:
//                      - AUD set at six phases of a running I2S stream: the
//                        first frames sent are whole source frames, in order;
//                        DPI_AUD_STAT.ACTIVE follows AUD;
//                      - one-packet islands (blanking 70) with an audio frame
//                        rate above the line rate: every frame in order, and
//                        the clock regeneration packet, both InfoFrames and the
//                        generic packet still sent;
//                      - blankings of 62, 63, 94 and 95 pixels: no island, one
//                        packet, one packet, two packets;
//                      - 3 to 4 frames per line (long lines): every frame in
//                        order, none lost;
//                      - slots of 15, 24, 33 and 63 bits: the 24 MSBs (zero
//                        fill below 24 bits), every frame in order;
//                      - an I2S pause longer than the stall limit, restarted:
//                        frames in order, CTS of the following measurements
//                        right (never 0);
//                      - LRCK stopped mid-slot while BCLK runs, then the
//                        stream going on: no stale frame (the frames after
//                        it in order), every CTS right;
//                      - N changed with the source running, the documented
//                        sequence (AUD clear, wait for ACTIVE clear, DPI_AUD,
//                        AUD set), also with a pixel clock much slower than
//                        HCLK: every clock regeneration packet carries a CTS
//                        that matches its N, and the pixel domain sees AUD
//                        clear before N changes;
//                      - CLK_DIV not 0: no audio, ACTIVE clear;
//                      - the generic packet rewritten with GP cleared and set:
//                        every one decoded is the old or the new packet whole.
//----------------------------------------------------------------------------
`define VERY_LONG_TIMEOUT

`include "dpi_tasks.v"

localparam  [3:0] CS_FS  = 4'h2;
localparam  [3:0] CS_WL  = 4'hB;

reg     [31:0] v;
reg     [23:0] pkt_hdr, pkt2_hdr;
reg    [223:0] pkt_pb, pkt2_pb;
integer        i, t, k, j, kk, bad, n0, f0, c0, x0, a0, g0, s0, i0, nf, en_falls, b0;
real           pix_ns, half, cts_exp;
real           fp_t0, fp_meas;            // measure_fp: the realised frame period
integer        fp_f0;
integer        n_val;

// Expected 24-bit value of source frame k, channel ch, in a slot of l bits
function [23:0] smp;
   input integer k;
   input integer ch;
   input integer l;
   reg   [23:0]  s;
   begin
      s   = {k[15:0], (ch != 0) ? 8'hC3 : 8'h3C};
      smp = (l >= 24) ? s : (s & ~((24'h1 << (24 - l)) - 24'h1));
   end
endfunction

function cs_exp;
   input integer j;
   input integer ch;
   cs_exp = (j == 2) || ((j == 20) && (ch == 0)) || ((j == 21) && (ch == 1)) ||
            ((j >= 24) && (j < 28) && CS_FS[j - 24]) || ((j >= 32) && (j < 36) && CS_WL[j - 32]);
endfunction

// Frames logged from index a: consecutive source frames, channel-status block
// every 192; at least nmin of them
task check_frames;
   input integer a;
   input integer l;
   input integer nmin;
   input [80*8-1:0] what;
   integer jj, nb, bs, k16;
   begin
      if (g_tmdsrx.u_tmdsrx.aud_n - a < nmin) begin
         $display("  %0d frames logged", g_tmdsrx.u_tmdsrx.aud_n - a);
         tb_error({what, ": too few audio frames"});
      end
      // The frame index is in bits 23:8; a 15-bit slot drops its LSB, found
      // from whether the next frame repeats the value
      k16 = g_tmdsrx.u_tmdsrx.aud_l[a][23:8];
      if (l == 15) k16 = {g_tmdsrx.u_tmdsrx.aud_l[a][23:9], 1'b0} +
                         ((g_tmdsrx.u_tmdsrx.aud_l[a + 1] === g_tmdsrx.u_tmdsrx.aud_l[a]) ? 0 : 1);
      nb = 0; bs = -1;
      for (jj = a; jj < g_tmdsrx.u_tmdsrx.aud_n; jj = jj + 1) begin
         if ((g_tmdsrx.u_tmdsrx.aud_l[jj] !== smp(k16, 0, l)) ||
             (g_tmdsrx.u_tmdsrx.aud_r[jj] !== smp(k16, 1, l))) begin
            $display("  frame %0d: L 0x%06h R 0x%06h, expected source frame %0d (slot %0d)", jj,
                     g_tmdsrx.u_tmdsrx.aud_l[jj], g_tmdsrx.u_tmdsrx.aud_r[jj], k16, l);
            tb_error({what, ": audio frame out of sequence"});
            jj = g_tmdsrx.u_tmdsrx.aud_n;
         end else begin
            if (g_tmdsrx.u_tmdsrx.aud_b[jj]) begin
               if ((bs >= 0) && (jj - bs != 192)) tb_error({what, ": block starts not 192 frames apart"});
               bs = jj; nb = nb + 1;
            end
            if ((bs >= 0) && (jj - bs < 192)) begin
               if (g_tmdsrx.u_tmdsrx.aud_c[jj][0] !== cs_exp(jj - bs, 0)) tb_error({what, ": left channel-status bit"});
               if (g_tmdsrx.u_tmdsrx.aud_c[jj][1] !== cs_exp(jj - bs, 1)) tb_error({what, ": right channel-status bit"});
            end
         end
         k16 = (k16 + 1) & 16'hFFFF;
      end
      $display("%0s: %0d frames in order, %0d block starts", what, g_tmdsrx.u_tmdsrx.aud_n - a, nb);
   end
endtask

// The first n frames logged from index a are consecutive whole source frames
task check_first;
   input integer a;
   input integer n;
   input [80*8-1:0] what;
   integer jj, k0;
   begin
      if (g_tmdsrx.u_tmdsrx.aud_n - a < n + 1) tb_error({what, ": too few audio frames"});
      else begin
         k0 = g_tmdsrx.u_tmdsrx.aud_l[a + n][23:8] - n;
         for (jj = a; jj < a + n; jj = jj + 1)
            if ((g_tmdsrx.u_tmdsrx.aud_l[jj] !== smp(k0 + jj - a, 0, 32)) ||
                (g_tmdsrx.u_tmdsrx.aud_r[jj] !== smp(k0 + jj - a, 1, 32))) begin
               $display("  frame %0d: L 0x%06h R 0x%06h, expected source frame %0d",
                        jj - a, g_tmdsrx.u_tmdsrx.aud_l[jj], g_tmdsrx.u_tmdsrx.aud_r[jj], k0 + jj - a);
               tb_error({what, ": a first frame is not a whole source frame"});
            end
      end
   end
endtask

// Whole panel frames until the source has sent frame count f
task wait_audio;
   input integer f;
   integer vf;
   begin
      vf = 0;
      while ((u_i2s.frames < f) && (vf < 400)) begin dpi_wait_frames(1); vf = vf + 1; end
      if (u_i2s.frames < f) tb_error("I2S source frames did not arrive");
   end
endtask

// AUD set or clear, the documented way: clear, wait for ACTIVE clear
task aud_off;
   integer tries;
   begin
      reg_rd_val(DPI_HDMI, v);
      reg_wr(DPI_HDMI, v & ~32'h4);
      tries = 0; v = 32'h0200_0000;
      while ((v & 32'h0200_0000) && (tries < 2000)) begin reg_rd_val(DPI_AUD_ST, v); tries = tries + 1; end
      if (v & 32'h0200_0000) tb_error("DPI_AUD_STAT.ACTIVE did not clear after AUD was cleared");
   end
endtask

task aud_on;
   integer tries;
   begin
      reg_rd_val(DPI_HDMI, v);
      reg_wr(DPI_HDMI, v | 32'h4);
   end
endtask

task new_timing;
   input integer div, ha, hb;
   begin
      dpi_timing(div, ha, 8, 8, hb - 16, 20, 2, 2, 2);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
   end
endtask

// Every clock regeneration packet decoded while acr_watch is set carries
// N = acr_n_exp with a CTS within acr_lo..acr_hi, or (a packet already on its
// way when N changed) the previous N with its own CTS window
reg     acr_watch;
integer acr_n_exp, acr_n_old;
real    acr_lo, acr_hi, acr_lo_old, acr_hi_old;
integer acr_bad;
initial begin acr_watch = 1'b0; acr_bad = 0; acr_n_old = -1; end
always @(g_tmdsrx.u_tmdsrx.n_acr)
   if (acr_watch &&
       !(((g_tmdsrx.u_tmdsrx.acr_n === acr_n_exp) &&
          (g_tmdsrx.u_tmdsrx.acr_cts >= acr_lo) && (g_tmdsrx.u_tmdsrx.acr_cts <= acr_hi)) ||
         ((g_tmdsrx.u_tmdsrx.acr_n === acr_n_old) &&
          (g_tmdsrx.u_tmdsrx.acr_cts >= acr_lo_old) && (g_tmdsrx.u_tmdsrx.acr_cts <= acr_hi_old)))) begin
      acr_bad = acr_bad + 1;
      $display("  clock regeneration N %0d CTS %0d, expected N %0d CTS %0.1f..%0.1f %t",
               g_tmdsrx.u_tmdsrx.acr_n, g_tmdsrx.u_tmdsrx.acr_cts, acr_n_exp, acr_lo, acr_hi, $time);
   end

// Every generic packet decoded while oth_watch is set is the old or the new one, whole
reg     oth_watch;
integer oth_bad;
initial begin oth_watch = 1'b0; oth_bad = 0; end
always @(g_tmdsrx.u_tmdsrx.n_oth)
   if (oth_watch && !(((g_tmdsrx.u_tmdsrx.oth_hdr === pkt_hdr)  && (g_tmdsrx.u_tmdsrx.oth_sub === pkt_pb)) ||
                      ((g_tmdsrx.u_tmdsrx.oth_hdr === pkt2_hdr) && (g_tmdsrx.u_tmdsrx.oth_sub === pkt2_pb)))) begin
      oth_bad = oth_bad + 1;
      $display("  generic packet neither the old nor the new one %t", $time);
   end

// The pixel domain sees AUD clear: falls of the receiver's enable
initial en_falls = 0;
always @(negedge dut.G_DPI.u_dpi.g_hdmi.u_hdmi.g_i2s.u_i2s.en_i) en_falls = en_falls + 1;

// The frame period the bench realises (its BCLK delays rounded to the time
// precision), in pixel clocks, measured over 32 frames of the running source
// (slots of l bits), not the nominal one: the CTS bound of +-2 is then the
// measurement's and the synchroniser jitter's, with no rounding error of the
// bench in it. Measured again whenever the slot, the BCLK or the pixel clock
// changes; set_cts_window takes no time (one call is at a clock regeneration
// packet's due edge)
task measure_fp;
   input integer l;
   begin
      @(u_i2s.frames); fp_t0 = $realtime; fp_f0 = u_i2s.frames;
      while (u_i2s.frames < fp_f0 + 32) @(u_i2s.frames);
      fp_meas = ($realtime - fp_t0) / (32.0 * pix_ns);
      $display("frame period %0.3f pixel clocks (nominal %0.3f)", fp_meas, 2.0 * l * 2.0 * u_i2s.half / pix_ns);
   end
endtask

task set_cts_window;
   input integer n;
   begin
      acr_n_old  = acr_n_exp;  acr_lo_old = acr_lo;  acr_hi_old = acr_hi;
      cts_exp   = (n / 128) * fp_meas;
      acr_n_exp = n;
      acr_lo    = cts_exp - 2.0;
      acr_hi    = cts_exp + 2.0;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: HDMI AUDIO AT ITS EDGES           |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_AUDIO)
         tb_skip_finish("|        (no HDMI audio in this build)          |");

      pix_ns = (DPI_PCLK_SEP != 0) ? 2.0 * dpi_pclk_half : 2.0 * CLK_HALF;
      half   = 2.2 * pix_ns;                      // BCLK high and low: 2.2 pixel clocks
      if (half < 30.0 / PCLK_FAST) half = 30.0 / PCLK_FAST;   // floor scaled with a faster PCLK_HALF

      n_val = 2048;
      reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, n_val[19:0]});
      pkt_hdr  = 24'h19_01_83;  pkt2_hdr = 24'h19_01_83;
      for (i = 0; i < 28; i = i + 1) begin pkt_pb[8*i +: 8] = 8'h41 + i; pkt2_pb[8*i +: 8] = 8'hA0 + i; end
      reg_wr(DPI_PKT0, {8'h00, pkt_hdr});
      for (i = 0; i < 7; i = i + 1) reg_wr(DPI_PKT0 + 4 + 4*i, pkt_pb[32*i +: 32]);

      dpi_frame_fill(16, 8, 3);
      dpi_timing(0, 40, 8, 8, 90, 20, 2, 2, 2);          // blanking 106: two-packet islands
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW); // started: the fields are written
      reg_wr(DPI_HDMI, 32'h0001_0813);                   // HDMI and AVI
      u_i2s.half = half; u_i2s.slot = 32; u_i2s.run = 1'b1;
      dpi_wait_frames(2);

      //--------------------------------------------------------------
      // AUD set at six phases: whole first frames; ACTIVE follows AUD
      //--------------------------------------------------------------
      for (t = 0; t < 6; t = t + 1) begin
         #(t * 7.0 * half + 3.0);
         n0 = g_tmdsrx.u_tmdsrx.aud_n;
         aud_on;
         reg_rd_val(DPI_AUD_ST, v);
         k = 0;
         while (!(v & 32'h0200_0000) && (k < 200)) begin reg_rd_val(DPI_AUD_ST, v); k = k + 1; end
         if (!(v & 32'h0200_0000)) tb_error("DPI_AUD_STAT.ACTIVE not set with AUD");
         dpi_wait_frames(2);
         check_first(n0, 6, "AUD set while the source runs");
         aud_off;
         dpi_wait_frames(1);
      end
      $display("AUD set at six phases: first frames whole");

      //--------------------------------------------------------------
      // One-packet islands, audio frame rate above the line rate
      //--------------------------------------------------------------
      u_i2s.run = 1'b0; u_i2s.slot = 16; u_i2s.run = 1'b1;
      new_timing(0, 100, 70);                            // 170-pixel lines, 141-pixel frames
      reg_wr(DPI_HDMI, 32'h0001_081B);                   // HDMI, AVI, GP
      aud_on;
      dpi_wait_frames(3);
      measure_fp(16);
      set_cts_window(n_val);
      acr_watch = 1'b1;
      n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
      c0 = g_tmdsrx.u_tmdsrx.n_acr;  x0 = g_tmdsrx.u_tmdsrx.n_avi;
      a0 = g_tmdsrx.u_tmdsrx.n_aif;  g0 = g_tmdsrx.u_tmdsrx.n_oth;  nf = 0;
      wait_audio(f0 + 420);
      check_frames(n0, 16, 400, "one-packet islands");
      reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);
      $display("one-packet islands: %0d clock regeneration, %0d AVI, %0d audio InfoFrame, %0d generic packets",
               g_tmdsrx.u_tmdsrx.n_acr - c0, g_tmdsrx.u_tmdsrx.n_avi - x0,
               g_tmdsrx.u_tmdsrx.n_aif - a0, g_tmdsrx.u_tmdsrx.n_oth - g0);
      if (g_tmdsrx.u_tmdsrx.n_acr - c0 < (u_i2s.frames - f0) / 16 - 2) tb_error("one-packet islands: clock regeneration packets missing");
      if (g_tmdsrx.u_tmdsrx.n_avi - x0 < 5) tb_error("one-packet islands: AVI InfoFrame missing");
      if (g_tmdsrx.u_tmdsrx.n_aif - a0 < 5) tb_error("one-packet islands: audio InfoFrame missing");
      if (g_tmdsrx.u_tmdsrx.n_oth - g0 < 5) tb_error("one-packet islands: generic packet missing");
      acr_watch = 1'b0;

      //--------------------------------------------------------------
      // Island thresholds: 62 none, 63 and 94 one packet, 95 two
      //--------------------------------------------------------------
      for (t = 0; t < 4; t = t + 1) begin
         k = (t == 0) ? 62 : (t == 1) ? 63 : (t == 2) ? 94 : 95;
         new_timing(0, 100, k);
         s0 = g_tmdsrx.u_tmdsrx.n_asp;  i0 = g_tmdsrx.u_tmdsrx.isl2;  x0 = g_tmdsrx.u_tmdsrx.n_avi;
         dpi_wait_frames(3);
         $display("blanking %0d: %0d sample packets, %0d two-packet islands, %0d AVI", k,
                  g_tmdsrx.u_tmdsrx.n_asp - s0, g_tmdsrx.u_tmdsrx.isl2 - i0, g_tmdsrx.u_tmdsrx.n_avi - x0);
         if ((k == 62) && (g_tmdsrx.u_tmdsrx.n_asp != s0)) tb_error("blanking 62: an island was sent");
         if ((k != 62) && (g_tmdsrx.u_tmdsrx.n_asp == s0)) tb_error("island threshold: no audio sample packet");
         if ((k != 62) && (g_tmdsrx.u_tmdsrx.n_avi - x0 < 2)) tb_error("island threshold: AVI InfoFrame missing");
         if ((k == 63 || k == 94) && (g_tmdsrx.u_tmdsrx.isl2 != i0)) tb_error("island threshold: two packets in a one-packet blanking");
         if ((k == 95) && (g_tmdsrx.u_tmdsrx.isl2 == i0)) tb_error("blanking 95: no island of two packets");
      end
      aud_off;                                           // clears LOST (blanking 62)
      reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);

      //--------------------------------------------------------------
      // Long lines: 3 to 4 frames per sample packet
      //--------------------------------------------------------------
      new_timing(0, 400, 106);                           // 506-pixel lines, 141-pixel frames
      aud_on;
      dpi_wait_frames(2);
      n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
      wait_audio(f0 + 420);
      check_frames(n0, 16, 400, "3 to 4 frames per packet");
      reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);
      aud_off;

      //--------------------------------------------------------------
      // Slot lengths 15, 24, 33, 63 (the longest)
      //--------------------------------------------------------------
      new_timing(0, 100, 106);
      for (t = 0; t < 4; t = t + 1) begin
         k = (t == 0) ? 15 : (t == 1) ? 24 : (t == 2) ? 33 : 63;
         u_i2s.run = 1'b0; u_i2s.slot = k; u_i2s.run = 1'b1;
         aud_on;
         dpi_wait_frames(3);
         n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
         wait_audio(f0 + 420);
         case (t)
            0: check_frames(n0, 15, 400, "15-bit slots");
            1: check_frames(n0, 24, 400, "24-bit slots");
            2: check_frames(n0, 33, 400, "33-bit slots");
            3: check_frames(n0, 63, 400, "63-bit slots");
         endcase
         aud_off;
      end

      //--------------------------------------------------------------
      // A pause longer than the stall limit, then the same stream again
      //--------------------------------------------------------------
      u_i2s.run = 1'b0; u_i2s.slot = 32; u_i2s.run = 1'b1;
      aud_on;
      measure_fp(32);
      set_cts_window(n_val);
      acr_watch = 1'b1;
      c0 = g_tmdsrx.u_tmdsrx.n_acr;
      while (g_tmdsrx.u_tmdsrx.n_acr < c0 + 2) dpi_wait_frames(1);
      u_i2s.run = 1'b0;
      #(2000.0 * pix_ns);
      n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
      u_i2s.run = 1'b1;
      c0 = g_tmdsrx.u_tmdsrx.n_acr;
      wait_audio(f0 + 420);
      if (g_tmdsrx.u_tmdsrx.n_acr - c0 < 3) tb_error("I2S pause: clock regeneration packets missing after the restart");
      check_frames(n0, 32, 400, "after an I2S pause");
      reg_rd_val(DPI_AUD_ST, v);
      if ((v[19:0] < acr_lo) || (v[19:0] > acr_hi)) tb_error("I2S pause: DPI_AUD_STAT CTS");

      //--------------------------------------------------------------
      // LRCK stopped 10 bits into a left slot while BCLK runs (200 bit
      // clocks), then the stream goes on: the slot across the stop is
      // dropped, the frames after it in order, every CTS right
      //--------------------------------------------------------------
      c0 = g_tmdsrx.u_tmdsrx.n_acr;
      while (g_tmdsrx.u_tmdsrx.n_acr < c0 + 2) dpi_wait_frames(1);
      b0 = acr_bad;
      @(negedge u_i2s.bclk_o);
      while ((u_i2s.n % 64) != 11) @(negedge u_i2s.bclk_o);
      u_i2s.hold = 1'b1;
      #(400.0 * u_i2s.half);
      n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
      @(negedge u_i2s.bclk_o) u_i2s.hold = 1'b0;
      c0 = g_tmdsrx.u_tmdsrx.n_acr;
      wait_audio(f0 + 420);
      if (g_tmdsrx.u_tmdsrx.n_acr - c0 < 3) tb_error("LRCK stop: clock regeneration packets missing after it");
      check_frames(n0, 32, 400, "after an LRCK stop");
      if (acr_bad != b0) tb_error("LRCK stop: a clock regeneration packet with a wrong CTS");
      acr_watch = 1'b0;

      //--------------------------------------------------------------
      // N changed with the source running, the documented sequence; then
      // again with a pixel clock 8 times slower than HCLK (separate clock)
      //--------------------------------------------------------------
      for (t = 0; t < 2; t = t + 1) begin
         if ((t == 1) && (DPI_PCLK_SEP != 0)) begin
            aud_off;
            dpi_pclk_half = 40.0;  pix_ns = 80.0;
            u_i2s.run = 1'b0; u_i2s.half = 2.2 * pix_ns; u_i2s.run = 1'b1;
            dpi_wait_frames(2);
            measure_fp(32);
            aud_on;
         end
         set_cts_window(n_val);
         acr_n_old = -1;
         acr_watch = 1'b1;
         c0 = g_tmdsrx.u_tmdsrx.n_acr;
         while (g_tmdsrx.u_tmdsrx.n_acr < c0 + 2) dpi_wait_frames(1);
         @(dut.G_DPI.u_dpi.g_hdmi.u_hdmi.cts_t_o);   // a clock regeneration packet is due
         k = en_falls;
         n_val = (n_val == 2048) ? 4096 : 2048;
         set_cts_window(n_val);                          // from the clear on, only the new N
         aud_off;
         reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, n_val[19:0]});
         aud_on;
         if (en_falls == k) tb_error("N change: the pixel domain did not see AUD clear");
         c0 = g_tmdsrx.u_tmdsrx.n_acr;
         while (g_tmdsrx.u_tmdsrx.n_acr < c0 + 2) dpi_wait_frames(1);
         acr_watch = 1'b0;
         $display("N changed to %0d with the source running (pixel clock %0.1f ns): clock regeneration consistent", n_val, pix_ns);
      end
      if (acr_bad != 0) tb_error("a clock regeneration packet with a CTS that does not match its N");
      if (DPI_PCLK_SEP != 0) begin
         aud_off;
         dpi_pclk_half = dpi_pclk_base;  pix_ns = 2.0 * dpi_pclk_base;
         u_i2s.run = 1'b0; u_i2s.half = half; u_i2s.run = 1'b1;
         dpi_wait_frames(2);
         aud_on;
      end

      //--------------------------------------------------------------
      // CLK_DIV not 0: no audio, ACTIVE clear
      //--------------------------------------------------------------
      new_timing(1, 100, 106);
      dpi_wait_frames(1);
      s0 = g_tmdsrx.u_tmdsrx.n_asp;
      dpi_wait_frames(2);
      if (g_tmdsrx.u_tmdsrx.n_asp != s0) tb_error("CLK_DIV 1: audio sample packets sent");
      reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0200_0000);
      new_timing(0, 100, 106);

      //--------------------------------------------------------------
      // The generic packet rewritten while it is sent
      //--------------------------------------------------------------
      oth_watch = 1'b1;
      for (t = 0; t < 4; t = t + 1) begin
         reg_rd_val(DPI_HDMI, v);
         reg_wr(DPI_HDMI, v & ~32'h8);                   // GP clear
         reg_rd_val(DPI_FRAMES, i0);
         reg_rd_val(DPI_FRAMES, v);
         while (v == i0) reg_rd_val(DPI_FRAMES, v);      // one frame start
         reg_wr(DPI_PKT0, (t % 2) ? {8'h00, pkt_hdr} : {8'h00, pkt2_hdr});
         for (i = 0; i < 7; i = i + 1)
            reg_wr(DPI_PKT0 + 4 + 4*i, (t % 2) ? pkt_pb[32*i +: 32] : pkt2_pb[32*i +: 32]);
         reg_rd_val(DPI_HDMI, v);
         g0 = g_tmdsrx.u_tmdsrx.n_oth;
         reg_wr(DPI_HDMI, v | 32'h8);                    // GP set
         // until the new packet is sent: GP is due from the next start of
         // vertical blanking and goes after AVI and the audio InfoFrame, so a
         // fixed wait can clear GP again while it is due (and drop it)
         k = 0;
         while ((g_tmdsrx.u_tmdsrx.n_oth == g0) && (k < 4)) begin dpi_wait_frames(1); k = k + 1; end
         if (g_tmdsrx.u_tmdsrx.n_oth == g0) tb_error("generic packet: not sent after GP set");
      end
      oth_watch = 1'b0;
      if ((g_tmdsrx.u_tmdsrx.oth_hdr !== pkt_hdr) || (g_tmdsrx.u_tmdsrx.oth_sub !== pkt_pb))
         tb_error("generic packet: the last one written is not the one sent");
      if (oth_bad != 0) tb_error("a torn generic packet");

      if (g_tmdsrx.u_tmdsrx.asp_perr != 0) tb_error("audio subframe parity");
      if (g_tmdsrx.u_tmdsrx.asp_ferr != 0) tb_error("audio sample packet header or layout");
      if (g_tmdsrx.u_tmdsrx.acr_err != 0)  tb_error("clock regeneration subpackets");

      u_i2s.run = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
