//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_audio_pkt
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_audio_pkt.v
// Module Description : HDMI audio packets read from their sources while they
//                      are sent (DPI_AUDIO_EN), on 858-pixel lines with a
//                      138-pixel blanking (two-packet islands, the 480p
//                      line), the receiver model decoding every packet:
//                      - 32, 44.1 and 48 kHz (843.75, 612.24 and 562.5
//                        pixel clocks a frame at 27 MHz, N 4096 / 6272 /
//                        6144, the channel-status sampling frequency of
//                        each): every frame in order,
//                        none lost, the channel status of the rate, every
//                        clock regeneration packet's N and CTS; frames that
//                        complete while a sample packet is sent (counted);
//                      - two frames a line, drifting by a pixel clock a
//                        line, N = 128 (a measurement every frame; AVI and GP
//                        off, the islands full): frames complete at every
//                        phase of the island, so at the load of a
//                        sample packet, during it, at its last data character
//                        (the pop), and a CTS measurement ends while a clock
//                        regeneration packet is sent (dropped: the next one
//                        is sent); every frame in order, every CTS right;
//                      - AUD cleared at phases across a sample packet: the
//                        packet sent whole, the frames up to the stop in
//                        order, and after AUD is set again the first frames
//                        whole and in order (no stale frame);
//                      - AUD cleared and set again at once across a sample
//                        packet: the frames held are dropped and the block
//                        restarts (audio back on within the packet with one
//                        clock);
//                      - AUD set with the I2S source stopped: AVI and audio
//                        InfoFrames in one island;
//                      - the packet types in the two packets of an island
//                        (sample packet then sample, clock regeneration, AVI,
//                        audio InfoFrame, generic packet; AVI then audio
//                        InfoFrame), counted at the second packet's load.
//                      Each corner is counted through hierarchical probes and
//                      must be reached.
//----------------------------------------------------------------------------
`define VERY_LONG_TIMEOUT

`include "dpi_tasks.v"

`define PK_H dut.G_DPI.u_dpi.g_hdmi.u_hdmi
`define PK_A dut.G_DPI.u_dpi.g_hdmi.u_hdmi.g_i2s.u_i2s

localparam  [3:0] CS_WL  = 4'hB;
localparam integer LN    = 858;                   // line total (pixel clocks)

reg     [31:0] v;
reg     [23:0] pkt_hdr;
reg    [223:0] pkt_pb;
reg      [3:0] cs_fs;
integer        i, t, k, n0, n1, f0, c0, s0, d0, b0, g0, x0, a0;
real           pix_ns;

//--------------------------------------------------------------------
// Probes (pixel clock): the corners of a packet read in place
//--------------------------------------------------------------------
integer pk_defer, pk_defer_load, pk_push_pop, pk_en_fall, pk_en_back, pk_drop, pk_dlost, pk_pop;
integer pk_cyc, pk_fall_cyc, pk_lat;
reg     pk_en_q;
reg   [2:0] pk_first;
reg  [35:0] pk_pairs;                             // bit 6 * first + second: ASP, ACR, AVI, AIF, GP, null
initial begin
   pk_defer = 0; pk_defer_load = 0; pk_push_pop = 0; pk_en_fall = 0; pk_en_back = 0; pk_drop = 0; pk_dlost = 0;
   pk_pop = 0; pk_cyc = 0; pk_fall_cyc = 0; pk_lat = 0; pk_en_q = 1'b0; pk_first = 3'd5; pk_pairs = 36'd0;
end

function [2:0] pk_type;
   input s_asp, s_acr, s_avi, s_aif, s_gp;
   pk_type = s_asp ? 3'd0 : s_acr ? 3'd1 : s_avi ? 3'd2 : s_aif ? 3'd3 : s_gp ? 3'd4 : 3'd5;
endfunction

always @(posedge `PK_H.clk_i) begin
   if (`PK_A.defer === 1'b1) begin
      pk_defer = pk_defer + 1;
      if (`PK_H.load === 1'b1) pk_defer_load = pk_defer_load + 1;
   end
   if ((`PK_A.push === 1'b1) && (`PK_H.a_pop === 1'b1)) pk_push_pop = pk_push_pop + 1;
   if ((`PK_A.rd_i === 1'b1) && (`PK_A.en_i === 1'b0) && pk_en_q) pk_en_fall = pk_en_fall + 1;
   if ((`PK_A.rd_i === 1'b1) && (`PK_A.en_i === 1'b1) && !pk_en_q && (`PK_A.stop === 1'b1)) pk_en_back = pk_en_back + 1;
   if ((`PK_A.meas & `PK_A.cv & ~`PK_A.pc_sat & `PK_A.cts_hold_i) === 1'b1) pk_drop = pk_drop + 1;
   if (`PK_A.dlost === 1'b1) pk_dlost = pk_dlost + 1;
   if (`PK_H.a_pop === 1'b1) pk_pop = pk_pop + 1;
   if (pk_en_q && (`PK_A.en_i !== 1'b1)) pk_fall_cyc = pk_cyc;
   pk_en_q = (`PK_A.en_i === 1'b1);
   pk_cyc = pk_cyc + 1;
   if (`PK_H.load === 1'b1) begin
      if (`PK_H.icnt == 7'd14)
         pk_first = pk_type(`PK_H.s_asp, `PK_H.s_acr, `PK_H.s_avi, `PK_H.s_aif, `PK_H.s_gp);
      else
         pk_pairs[6 * pk_first + pk_type(`PK_H.s_asp, `PK_H.s_acr, `PK_H.s_avi, `PK_H.s_aif, `PK_H.s_gp)] = 1'b1;
   end
end

//--------------------------------------------------------------------
// Every clock regeneration packet decoded while acr_watch is set: N and a
// CTS of (N / 128) frame periods
//--------------------------------------------------------------------
reg     acr_watch;
integer acr_n_exp, acr_bad;
real    acr_lo, acr_hi;
real    fp_t0, fp_meas;                   // set_stream: the realised frame period
integer fp_f0;
initial begin acr_watch = 1'b0; acr_bad = 0; end
always @(g_tmdsrx.u_tmdsrx.n_acr)
   if (acr_watch && !((g_tmdsrx.u_tmdsrx.acr_n === acr_n_exp) &&
                      (g_tmdsrx.u_tmdsrx.acr_cts >= acr_lo) && (g_tmdsrx.u_tmdsrx.acr_cts <= acr_hi))) begin
      acr_bad = acr_bad + 1;
      if (acr_bad <= 8) $display("  clock regeneration N %0d CTS %0d, expected N %0d CTS %0.1f..%0.1f %t",
                                 g_tmdsrx.u_tmdsrx.acr_n, g_tmdsrx.u_tmdsrx.acr_cts, acr_n_exp, acr_lo, acr_hi, $time);
   end

// Expected 24-bit value of source frame k, channel ch (32-bit slots)
function [23:0] smp;
   input integer k;
   input integer ch;
   smp = {k[15:0], (ch != 0) ? 8'hC3 : 8'h3C};
endfunction

function cs_exp;
   input integer j;
   input integer ch;
   cs_exp = (j == 2) || ((j == 20) && (ch == 0)) || ((j == 21) && (ch == 1)) ||
            ((j >= 24) && (j < 28) && cs_fs[j - 24]) || ((j >= 32) && (j < 36) && CS_WL[j - 32]);
endfunction

// Frames logged from index a to b - 1: consecutive source frames, the channel
// status of cs_fs between block starts 192 frames apart; at least nmin
task check_seq;
   input integer a;
   input integer b;
   input integer nmin;
   input [80*8-1:0] what;
   integer jj, nb, bs, k16;
   begin
      if (b - a < nmin) begin
         $display("  %0d frames logged", b - a);
         tb_error({what, ": too few audio frames"});
      end else begin
         k16 = g_tmdsrx.u_tmdsrx.aud_l[a][23:8];
         nb = 0; bs = -1;
         for (jj = a; jj < b; jj = jj + 1) begin
            if ((g_tmdsrx.u_tmdsrx.aud_l[jj] !== smp(k16, 0)) || (g_tmdsrx.u_tmdsrx.aud_r[jj] !== smp(k16, 1))) begin
               $display("  frame %0d: L 0x%06h R 0x%06h, expected source frame %0d", jj,
                        g_tmdsrx.u_tmdsrx.aud_l[jj], g_tmdsrx.u_tmdsrx.aud_r[jj], k16);
               tb_error({what, ": audio frame lost or out of sequence"});
               jj = b;
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
         $display("%0s: %0d frames in order, %0d block starts", what, b - a, nb);
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

// Until d pixel clocks after the load of a sample packet, less pk_lat (the
// clocks from a DPI_HDMI write to the audio stopping in the pixel domain):
// a write then stops the audio d clocks into the next line's sample packet
task at_asp;
   input integer d;
   integer c0;
   begin
      @(posedge `PK_H.clk_i);
      while (!((`PK_H.load === 1'b1) && (`PK_H.s_asp === 1'b1))) @(posedge `PK_H.clk_i);
      c0 = pk_cyc;
      while (pk_cyc < c0 + LN + d - pk_lat) @(posedge `PK_H.clk_i);
   end
endtask

task aud_on;
   begin
      reg_rd_val(DPI_HDMI, v);
      reg_wr(DPI_HDMI, v | 32'h4);
   end
endtask

// The source at a frame period of fp pixel clocks (32-bit slots), N and the
// channel-status sampling frequency; audio restarted
task set_stream;
   input real    fp;
   input integer n;
   input [3:0]   fs;
   begin
      aud_off;
      cs_fs = fs;
      reg_wr(DPI_AUD, {CS_WL, fs, 4'h0, n[19:0]});
      u_i2s.run = 1'b0;
      u_i2s.slot = 32; u_i2s.half = fp * pix_ns / 128.0;
      u_i2s.run = 1'b1;
      // the CTS bounds from the frame period the bench realises (its BCLK
      // delays rounded to the time precision), measured over 32 frames, not
      // the nominal fp: +-2 is then the measurement's and the synchroniser
      // jitter's, with no rounding error of the bench in it
      @(u_i2s.frames); fp_t0 = $realtime; fp_f0 = u_i2s.frames;
      while (u_i2s.frames < fp_f0 + 32) @(u_i2s.frames);
      fp_meas   = ($realtime - fp_t0) / (32.0 * pix_ns);
      $display("frame period %0.3f pixel clocks (nominal %0.3f)", fp_meas, fp);
      acr_n_exp = n;
      acr_lo    = (n / 128) * fp_meas - 2.0;
      acr_hi    = (n / 128) * fp_meas + 2.0;
      aud_on;
      dpi_wait_frames(2);
   end
endtask

// A stream of nf frames at a frame period of fp pixel clocks: every frame in
// order, every clock regeneration packet right, none lost
task run_stream;
   input integer nf;
   input [80*8-1:0] what;
   begin
      n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;  c0 = g_tmdsrx.u_tmdsrx.n_acr;
      s0 = pk_pop;  d0 = pk_defer;  b0 = acr_bad;
      acr_watch = 1'b1;
      wait_audio(f0 + nf);
      acr_watch = 1'b0;
      n1 = g_tmdsrx.u_tmdsrx.aud_n;
      if (((n1 - n0) - (u_i2s.frames - f0) > 4) || ((u_i2s.frames - f0) - (n1 - n0) > 4)) begin
         $display("  %0d frames sent, %0d received", u_i2s.frames - f0, n1 - n0);
         tb_error({what, ": frames lost or added"});
      end
      check_seq(n0, n1, nf - 8, what);
      if (g_tmdsrx.u_tmdsrx.n_acr - c0 < 3) tb_error({what, ": clock regeneration packets missing"});
      if (acr_bad != b0) tb_error({what, ": a clock regeneration packet with a wrong N or CTS"});
      reg_rd_mask(DPI_AUD_ST, 32'h0200_0000, 32'h0300_0000);   // ACTIVE, not LOST
      $display("%0s: %0d sample packets, %0d frames completed while one was sent (%0.1f %%), %0d clock regeneration packets",
               what, pk_pop - s0, pk_defer - d0, 100.0 * (pk_defer - d0) / (pk_pop - s0 + 0.001),
               g_tmdsrx.u_tmdsrx.n_acr - c0);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DPI: HDMI AUDIO PACKETS READ WHILE SENT     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_AUDIO)
         tb_skip_finish("|        (no HDMI audio in this build)          |");

      pix_ns = (DPI_PCLK_SEP != 0) ? 2.0 * dpi_pclk_half : 2.0 * CLK_HALF;

      cs_fs = 4'h2;
      reg_wr(DPI_AUD, {CS_WL, cs_fs, 4'h0, 20'd6144});
      pkt_hdr = 24'h19_01_83;
      for (i = 0; i < 28; i = i + 1) pkt_pb[8*i +: 8] = 8'h41 + i;
      reg_wr(DPI_PKT0, {8'h00, pkt_hdr});
      for (i = 0; i < 7; i = i + 1) reg_wr(DPI_PKT0 + 4 + 4*i, pkt_pb[32*i +: 32]);

      // 858-pixel lines, a blanking of 138 (two-packet islands), 14 lines a frame
      dpi_frame_fill(16, 8, 3);
      dpi_timing(0, LN - 138, 16, 62, 60, 8, 2, 2, 2);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      reg_wr(DPI_HDMI, 32'h0001_081B);                   // HDMI, AVI, GP
      u_i2s.slot = 32; u_i2s.half = 563.0 * pix_ns / 128.0; u_i2s.run = 1'b1;
      dpi_wait_frames(2);

      //--------------------------------------------------------------
      // 32, 44.1 and 48 kHz on the 480p line
      //--------------------------------------------------------------
      set_stream(843.75, 4096, 4'h3);
      run_stream(420, "32 kHz");
      set_stream(612.24, 6272, 4'h0);
      run_stream(420, "44.1 kHz");
      set_stream(562.5, 6144, 4'h2);
      run_stream(420, "48 kHz");
      if (pk_defer == 0) tb_error("no frame completed while a sample packet was sent");

      //--------------------------------------------------------------
      // Two frames a line, drifting a pixel clock a line, a measurement every
      // frame: completions and measurements at every phase of the island
      //--------------------------------------------------------------
      // (AVI and GP off: a sample and a clock regeneration packet fill every
      // island, so the InfoFrame would wait past the next frame start)
      reg_rd_val(DPI_HDMI, v);
      reg_wr(DPI_HDMI, v & ~32'hA);
      set_stream(LN / 2.0 + 0.5, 128, 4'h2);
      run_stream(2 * LN + 20, "every phase of the island");
      // A corner one pixel clock wide (the pop) is crossed by about two frames
      // a sweep: the synchroniser jitter and the simulator's rounding of the
      // I2S half period can step over it, so up to two more sweeps
      for (k = 0; (k < 2) && ((pk_defer_load == 0) || (pk_push_pop == 0) || (pk_drop == 0)); k = k + 1)
         run_stream(2 * LN + 20, "every phase of the island, again");
      reg_rd_val(DPI_HDMI, v);
      reg_wr(DPI_HDMI, v | 32'hA);
      $display("every phase: %0d at the load, %0d at the pop, %0d measurements dropped during a clock regeneration packet",
               pk_defer_load, pk_push_pop, pk_drop);
      if (pk_defer_load == 0) tb_error("no frame completed at the load of a sample packet");
      if (pk_push_pop == 0)   tb_error("no frame completed at the pop of a sample packet");
      if (pk_drop == 0)       tb_error("no CTS measurement ended during a clock regeneration packet");
      if (pk_dlost != 0)      tb_error("a frame waiting aside was lost");

      //--------------------------------------------------------------
      // AUD cleared at phases across a sample packet
      //--------------------------------------------------------------
      set_stream(562.5, 6144, 4'h2);
      // the latency of a DPI_HDMI write to the audio stopping, in pixel clocks
      reg_rd_val(DPI_HDMI, v);
      k = pk_cyc;
      reg_wr(DPI_HDMI, v & ~32'h4);
      while (pk_fall_cyc <= k) @(posedge `PK_H.clk_i);
      pk_lat = pk_fall_cyc - k;
      $display("AUD clear: the pixel domain stops %0d pixel clocks after the write starts", pk_lat);
      aud_on;
      dpi_wait_frames(2);
      for (t = 0; t < 8; t = t + 1) begin
         n0 = g_tmdsrx.u_tmdsrx.aud_n;
         dpi_wait_frames(1);
         reg_rd_val(DPI_HDMI, v);
         at_asp(4 * t);
         k = pk_en_fall;
         reg_wr(DPI_HDMI, v & ~32'h4);
         aud_off;
         dpi_wait_frames(1);
         n1 = g_tmdsrx.u_tmdsrx.aud_n;
         check_seq(n0, n1, 10, "frames up to an AUD clear");
         $display("AUD cleared %0d pixel clocks after a sample packet's load: %0s", 4 * t,
                  (pk_en_fall != k) ? "during the packet" : "after it");
         n0 = g_tmdsrx.u_tmdsrx.aud_n;
         aud_on;
         dpi_wait_frames(2);
         check_seq(n0, g_tmdsrx.u_tmdsrx.aud_n, 10, "frames after AUD set again");
      end
      if (pk_en_fall < 2) tb_error("AUD cleared during a sample packet fewer than twice");

      //--------------------------------------------------------------
      // AUD cleared and set again at once, across a sample packet: audio
      // restarts (frames whole and in order, the channel-status block from
      // its start), nothing kept from before
      //--------------------------------------------------------------
      for (t = 0; t < 6; t = t + 1) begin
         dpi_wait_frames(1);
         reg_rd_val(DPI_HDMI, v);
         at_asp(2 * t);
         k = pk_en_back;
         reg_wr(DPI_HDMI, v & ~32'h4);
         n0 = g_tmdsrx.u_tmdsrx.aud_n;
         reg_wr(DPI_HDMI, v);
         dpi_wait_frames(2);
         // the first frame sent after the restart: the buffer's frames before
         // it are gone, the block starts again
         i = n0;
         while ((i < g_tmdsrx.u_tmdsrx.aud_n) && !g_tmdsrx.u_tmdsrx.aud_b[i]) i = i + 1;
         check_seq(i, g_tmdsrx.u_tmdsrx.aud_n, 10, "frames after a short AUD clear");
         if ((i - n0 > 4) || (i == g_tmdsrx.u_tmdsrx.aud_n))
            tb_error("short AUD clear: the channel-status block does not restart with the audio");
         $display("short AUD clear %0d pixel clocks after a sample packet's load: %0s", 2 * t,
                  (pk_en_back != k) ? "audio back on during the packet" : "audio back on after it");
      end
      if ((DPI_PCLK_SEP == 0) && (pk_en_back == 0)) tb_error("audio never back on during the sample packet it stopped in");

      //--------------------------------------------------------------
      // AUD set, the source stopped: AVI and audio InfoFrame together
      //--------------------------------------------------------------
      u_i2s.run = 1'b0;
      dpi_wait_frames(3);

      //--------------------------------------------------------------
      // The packet types of the two packets of an island
      //--------------------------------------------------------------
      $display("two-packet islands, first -> second (ASP ACR AVI AIF GP null): %b_%b_%b_%b_%b_%b",
               pk_pairs[5:0], pk_pairs[11:6], pk_pairs[17:12], pk_pairs[23:18], pk_pairs[29:24], pk_pairs[35:30]);
      if (!pk_pairs[0])      tb_error("no island of two sample packets");
      if (!pk_pairs[1])      tb_error("no sample packet followed by clock regeneration");
      if (!pk_pairs[2])      tb_error("no sample packet followed by the AVI InfoFrame");
      if (!pk_pairs[3])      tb_error("no sample packet followed by the audio InfoFrame");
      if (!pk_pairs[4])      tb_error("no sample packet followed by the generic packet");
      if (!pk_pairs[6*2+3])  tb_error("no AVI InfoFrame followed by the audio InfoFrame");

      if (g_tmdsrx.u_tmdsrx.asp_perr != 0) tb_error("audio subframe parity");
      if (g_tmdsrx.u_tmdsrx.asp_ferr != 0) tb_error("audio sample packet header or layout");
      if (g_tmdsrx.u_tmdsrx.acr_err != 0)  tb_error("clock regeneration subpackets");
      if (g_tmdsrx.u_tmdsrx.oth_hdr !== pkt_hdr) tb_error("generic packet header");
      if (g_tmdsrx.u_tmdsrx.oth_sub !== pkt_pb)  tb_error("generic packet bytes");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
