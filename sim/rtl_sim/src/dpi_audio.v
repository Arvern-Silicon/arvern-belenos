//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_audio
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_audio.v
// Module Description : HDMI audio (DPI_AUDIO_EN): DPI_AUD, DPI_AUD_STAT and
//                      DPI_PKT0-7 masks and read-back; with HDMI, AVI, AUD
//                      and GP set and the I2S source running (32-bit slots
//                      then 16-bit slots), the receiver model decodes, with
//                      correct parities: every source frame in order in the
//                      audio sample packets (parity, V and U bits), one
//                      channel-status block of the programmed fields every
//                      192 frames, the clock regeneration packet with N and
//                      the measured CTS (also in DPI_AUD_STAT), the audio
//                      InfoFrame, the generic packet as written, islands of
//                      two packets; DPI_AUD writes ignored while AUD is set
//                      and, with the pixel clock held stopped, after AUD is
//                      cleared until the pixel domain has seen it, then
//                      written; full-scale random samples in slots of
//                      16, 20, 24 and 32 bits, every value exact, packets of
//                      4 frames; a blanking too short for an island:
//                      frames lost, DPI_AUD_STAT bit 24, cleared with AUD
//                      (ACTIVE, bit 25, checked set with the CTS);
//                      AUD and GP clear: no more of these packets; the image
//                      right throughout. Without audio: RAZ/WI, DPI_CAPS
//                      bit 10 clear.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "dpi_tasks.v"

localparam [19:0] N_VAL  = 20'd2048;      // 16 frames per CTS measurement
localparam  [3:0] CS_FS  = 4'h2;
localparam  [3:0] CS_WL  = 4'hB;

reg  [31:0] v;
reg  [23:0] pkt_hdr;
reg [223:0] pkt_pb;
integer     i, k, n0, n1, f0, f1, c0, b0, b1, a0, x0, g0, s0, sl, ha, q0;
real        pix_ns, cts_exp, fpc;
real        fp_t0, fp_meas;               // measure_fp: the realised frame period
integer     fp_f0;

// The 16-bit check of the source's frame k (the bench model's sample())
function [23:0] smp;
   input integer kk;
   input integer ch;
   input integer slot;
   reg   [23:0] s;
   begin
      s   = {kk[15:0], (ch != 0) ? 8'hC3 : 8'h3C};
      smp = (slot == 32) ? s : {s[23:8], 8'h00};
   end
endfunction

// Channel-status bit j of the block, left (ch 0) or right (ch 1)
function cs_exp;
   input integer j;
   input integer ch;
   cs_exp = (j == 2) || ((j == 20) && (ch == 0)) || ((j == 21) && (ch == 1)) ||
            ((j >= 24) && (j < 28) && CS_FS[j - 24]) || ((j >= 32) && (j < 36) && CS_WL[j - 32]);
endfunction

// The frames logged from index a on: consecutive source frames, a block start
// every 192 frames with the channel-status block between two of them
task check_frames;
   input integer a;
   input integer slot;
   input [80*8-1:0] what;
   integer j, kk, nb, bs;
   begin
      if (g_tmdsrx.u_tmdsrx.aud_n - a < 400) tb_error({what, ": too few audio frames"});
      kk = g_tmdsrx.u_tmdsrx.aud_l[a][23:8];
      if (slot == 16) kk = {8'd0, g_tmdsrx.u_tmdsrx.aud_l[a][23:16], g_tmdsrx.u_tmdsrx.aud_l[a][15:8]};
      nb = 0; bs = -1;
      for (j = a; j < g_tmdsrx.u_tmdsrx.aud_n; j = j + 1) begin
         if ((g_tmdsrx.u_tmdsrx.aud_l[j] !== smp(kk, 0, slot)) || (g_tmdsrx.u_tmdsrx.aud_r[j] !== smp(kk, 1, slot))) begin
            $display("  frame %0d: L 0x%06h R 0x%06h, expected source frame %0d", j,
                     g_tmdsrx.u_tmdsrx.aud_l[j], g_tmdsrx.u_tmdsrx.aud_r[j], kk);
            tb_error({what, ": audio frame out of sequence"});
            j = g_tmdsrx.u_tmdsrx.aud_n;
         end
         if (g_tmdsrx.u_tmdsrx.aud_b[j]) begin
            if ((bs >= 0) && (j - bs != 192)) tb_error({what, ": block starts not 192 frames apart"});
            bs = j; nb = nb + 1;
         end
         if ((bs >= 0) && (j - bs < 192)) begin
            if (g_tmdsrx.u_tmdsrx.aud_c[j][0] !== cs_exp(j - bs, 0)) tb_error({what, ": left channel-status bit"});
            if (g_tmdsrx.u_tmdsrx.aud_c[j][1] !== cs_exp(j - bs, 1)) tb_error({what, ": right channel-status bit"});
         end
         kk = (kk + 1) & 16'hFFFF;
      end
      if (nb < 2) tb_error({what, ": fewer than two channel-status block starts"});
      $display("%0s: %0d frames in order, %0d block starts", what, g_tmdsrx.u_tmdsrx.aud_n - a, nb);
   end
endtask

// Random samples (the source's rnd mode) in slots of sl bits: the frames
// logged from index a on are consecutive source frames, each 24-bit value
// exact (the top sl bits of the sample, zero-filled, in a slot shorter than 24)
task check_rnd;
   input integer a;
   input integer sl;
   input [80*8-1:0] what;
   integer j, kk, f;
   reg [23:0] m;
   begin
      m = (sl >= 24) ? 24'hFF_FFFF : ~(24'hFF_FFFF >> sl);
      if (g_tmdsrx.u_tmdsrx.aud_n - a < 100) tb_error({what, ": too few audio frames"});
      f = -1;
      for (kk = 0; (kk < 20000) && (f < 0); kk = kk + 1)
         if ((g_tmdsrx.u_tmdsrx.aud_l[a] === (u_i2s.sample(kk, 0) & m)) &&
             (g_tmdsrx.u_tmdsrx.aud_r[a] === (u_i2s.sample(kk, 1) & m))) f = kk;
      if (f < 0) tb_error({what, ": first audio frame is no source frame"});
      else begin
         kk = f;
         for (j = a; j < g_tmdsrx.u_tmdsrx.aud_n; j = j + 1) begin
            if ((g_tmdsrx.u_tmdsrx.aud_l[j] !== (u_i2s.sample(kk, 0) & m)) ||
                (g_tmdsrx.u_tmdsrx.aud_r[j] !== (u_i2s.sample(kk, 1) & m))) begin
               $display("  frame %0d: L 0x%06h R 0x%06h, expected source frame %0d: L 0x%06h R 0x%06h", j,
                        g_tmdsrx.u_tmdsrx.aud_l[j], g_tmdsrx.u_tmdsrx.aud_r[j], kk,
                        u_i2s.sample(kk, 0) & m, u_i2s.sample(kk, 1) & m);
               tb_error({what, ": audio sample differs"});
               j = g_tmdsrx.u_tmdsrx.aud_n;
            end
            kk = kk + 1;
         end
         $display("%0s: %0d frames exact from source frame %0d", what, g_tmdsrx.u_tmdsrx.aud_n - a, f);
      end
   end
endtask

// Whole panel frames until the source has sent frame count f (vf: how many)
integer vf;
task wait_audio;
   input integer f;
   begin
      vf = 0;
      while ((u_i2s.frames < f) && (vf < 100)) begin dpi_wait_frames(1); vf = vf + 1; end
      if (u_i2s.frames < f) tb_error("I2S source frames did not arrive");
   end
endtask

// The frame period the bench realises (its BCLK delays rounded to the time
// precision), in pixel clocks, measured over 32 frames of the running source
// (slots of l bits), not the nominal one: the CTS bound of +-2 is then the
// measurement's and the synchroniser jitter's, with no rounding error of the
// bench in it
task measure_fp;
   input integer l;
   begin
      @(u_i2s.frames); fp_t0 = $realtime; fp_f0 = u_i2s.frames;
      while (u_i2s.frames < fp_f0 + 32) @(u_i2s.frames);
      fp_meas = ($realtime - fp_t0) / (32.0 * pix_ns);
      $display("frame period %0.3f pixel clocks (nominal %0.3f)", fp_meas, 2.0 * l * 2.0 * u_i2s.half / pix_ns);
   end
endtask

// CTS: the model's last clock regeneration packet and DPI_AUD_STAT
task check_cts;
   input [80*8-1:0] what;
   begin
      if (g_tmdsrx.u_tmdsrx.acr_n !== N_VAL) tb_error({what, ": clock regeneration N"});
      if ((g_tmdsrx.u_tmdsrx.acr_cts < cts_exp - 2.0) || (g_tmdsrx.u_tmdsrx.acr_cts > cts_exp + 2.0)) begin
         $display("  CTS %0d, expected %0.1f", g_tmdsrx.u_tmdsrx.acr_cts, cts_exp);
         tb_error({what, ": clock regeneration CTS"});
      end
      reg_rd_val(DPI_AUD_ST, v);
      // ACTIVE (bit 25) set while the source runs, LOST (bit 24) clear
      if ((v[19:0] < cts_exp - 2.0) || (v[19:0] > cts_exp + 2.0) || (v[31:20] !== 12'h020)) begin
         $display("  DPI_AUD_STAT 0x%08h, CTS expected %0.1f", v, cts_exp);
         tb_error({what, ": DPI_AUD_STAT"});
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: HDMI AUDIO AND THE GENERIC PACKET |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      if (!HAS_AUDIO) begin
         reg_rd_mask(DPI_CAPS, 32'h0, 32'h400);
         if (HAS_ISLAND) begin
            reg_wr(DPI_HDMI, 32'hC);  reg_rd(DPI_HDMI, 32'h0);
         end
         for (k = DPI_AUD; k < DPI_PKT0 + 32; k = k + 4) begin reg_wr(k, 32'hFFFF_FFFF); reg_rd(k, 32'h0); end
      end else begin
         pix_ns = (DPI_PCLK_SEP != 0) ? 2.0 * dpi_pclk_half : 2.0 * CLK_HALF;

         // Registers: reset values, masks, read-back
         reg_rd(DPI_AUD, 32'h0);  reg_rd(DPI_AUD_ST, 32'h0);
         reg_rd_mask(DPI_CAPS, 32'h400, 32'h400);
         reg_wr(DPI_AUD, 32'hFFFF_FFFF);    reg_rd(DPI_AUD, 32'hFF0F_FF80);   // N [6:0] read 0
         reg_wr(DPI_AUD_ST, 32'hFFFF_FFFF); reg_rd(DPI_AUD_ST, 32'h0);
         reg_wr(DPI_PKT0, 32'hFFFF_FFFF);   reg_rd(DPI_PKT0, 32'h00FF_FFFF);
         pkt_hdr = 24'h19_01_83;
         for (i = 0; i < 28; i = i + 1) pkt_pb[8*i +: 8] = 8'h41 + i;
         reg_wr(DPI_PKT0, {8'h00, pkt_hdr});  reg_rd(DPI_PKT0, {8'h00, pkt_hdr});
         for (i = 0; i < 7; i = i + 1) begin
            reg_wr(DPI_PKT0 + 4 + 4*i, pkt_pb[32*i +: 32]);
         end
         for (i = 0; i < 7; i = i + 1) reg_rd(DPI_PKT0 + 4 + 4*i, pkt_pb[32*i +: 32]);
         reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, N_VAL});
         reg_rd(DPI_AUD, {CS_WL, CS_FS, 4'h0, N_VAL});

         // A blanking of 106 pixels: islands of two packets
         dpi_frame_fill(16, 8, 3);
         dpi_timing(0, 40, 8, 8, 90, 20, 2, 2, 2);
         reg_rd_val(DIF_CFG, v);
         reg_wr(DIF_CFG, v | 32'h9);
         reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);   // started: the fields are written
         u_dpipanel.check = 1'b1;

         //--------------------------------------------------------------
         // 32-bit slots
         //--------------------------------------------------------------
         // BCLK high and low 30 ns; with another bench pixel clock (PCLK_HALF)
         // the same 2.05 pixel clocks, so frames per line stay as by default
         u_i2s.half = ((DPI_PCLK_SEP != 0) && (PCLK_HALF != 73)) ? 30.0 * pix_ns / 14.6 : 30.0;
         u_i2s.slot = 32; u_i2s.run = 1'b1;
         measure_fp(32);
         cts_exp = (N_VAL / 128) * fp_meas;
         reg_wr(DPI_HDMI, 32'h0001_081F);   reg_rd(DPI_HDMI, 32'h0001_081F);
         dpi_wait_frames(3);
         n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
         c0 = g_tmdsrx.u_tmdsrx.n_acr;  a0 = g_tmdsrx.u_tmdsrx.n_aif;
         g0 = g_tmdsrx.u_tmdsrx.n_oth;  s0 = g_tmdsrx.u_tmdsrx.isl2;  x0 = g_tmdsrx.u_tmdsrx.n_avi;
         wait_audio(f0 + 420);
         n1 = g_tmdsrx.u_tmdsrx.aud_n;  f1 = u_i2s.frames;
         if (((n1 - n0) - (f1 - f0) > 4) || ((f1 - f0) - (n1 - n0) > 4)) begin
            $display("  %0d frames sent, %0d received", f1 - f0, n1 - n0);
            tb_error("32-bit slots: frames lost or added");
         end
         check_frames(n0, 32, "32-bit slots");
         if (g_tmdsrx.u_tmdsrx.asp_perr != 0) tb_error("audio subframe parity");
         if (g_tmdsrx.u_tmdsrx.asp_ferr != 0) tb_error("audio sample packet header or layout");
         if (g_tmdsrx.u_tmdsrx.acr_err != 0)  tb_error("clock regeneration subpackets");
         if (g_tmdsrx.u_tmdsrx.n_acr - c0 < (f1 - f0) / 16 - 2) tb_error("clock regeneration packets missing");
         check_cts("32-bit slots");
         if (g_tmdsrx.u_tmdsrx.n_aif - a0 < vf - 1) tb_error("audio InfoFrame not in every frame");
         if (g_tmdsrx.u_tmdsrx.aif_hdr !== 24'h0A_01_84) tb_error("audio InfoFrame header");
         if (g_tmdsrx.u_tmdsrx.aif_sub !== {208'd0, 8'h01, 8'h70}) tb_error("audio InfoFrame content");
         if (g_tmdsrx.u_tmdsrx.n_avi - x0 < vf - 1) tb_error("AVI InfoFrame not in every frame");
         if (g_tmdsrx.u_tmdsrx.n_oth - g0 < vf - 1) tb_error("generic packet not in every frame");
         if (g_tmdsrx.u_tmdsrx.oth_hdr !== pkt_hdr) tb_error("generic packet header");
         if (g_tmdsrx.u_tmdsrx.oth_sub !== pkt_pb) tb_error("generic packet bytes");
         if (g_tmdsrx.u_tmdsrx.isl2 - s0 < 10) tb_error("no island of two packets");
         reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);
         dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "with audio");
         //--------------------------------------------------------------
         // DPI_AUD while the pixel domain reads it: writes ignored with AUD
         // set; with the pixel clock held stopped (DPI_PCLK_SEP = 1) also
         // after AUD is cleared, until the pixel domain has seen the clear;
         // then written
         //--------------------------------------------------------------
         reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, 20'd4096});
         reg_rd(DPI_AUD, {CS_WL, CS_FS, 4'h0, N_VAL});
         u_i2s.run = 1'b0;
         u_dpipanel.check = 1'b0;
         if (DPI_PCLK_SEP != 0) begin
            @(negedge dpi_pclk);
            dpi_pclk_stop = 1'b1;
         end
         reg_wr(DPI_HDMI, 32'h0001_081B);                     // AUD clear
         if (DPI_PCLK_SEP != 0) begin
            reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, 20'd4096});
            repeat (20) @(posedge free_clk);
            reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, 20'd4096});
            reg_rd(DPI_AUD, {CS_WL, CS_FS, 4'h0, N_VAL});
            dpi_pclk_stop = 1'b0;
         end
         k = 0; v = 32'h0;
         while ((v != {CS_WL, CS_FS, 4'h0, 20'd4096}) && (k < 200)) begin
            reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, 20'd4096});
            reg_rd_val(DPI_AUD, v);
            k = k + 1;
         end
         if (v != {CS_WL, CS_FS, 4'h0, 20'd4096}) tb_error("DPI_AUD not written after AUD was cleared");
         else $display("OK:    DPI_AUD written %0d writes after AUD was cleared", k);
         reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0200_0000);       // audio off
         reg_wr(DPI_AUD, {CS_WL, CS_FS, 4'h0, N_VAL});
         reg_rd(DPI_AUD, {CS_WL, CS_FS, 4'h0, N_VAL});
         u_i2s.run = 1'b1;
         $display("32-bit slots: %0d sample, %0d clock regeneration, %0d audio InfoFrame, %0d generic packets, %0d two-packet islands",
                  g_tmdsrx.u_tmdsrx.n_asp, g_tmdsrx.u_tmdsrx.n_acr, g_tmdsrx.u_tmdsrx.n_aif,
                  g_tmdsrx.u_tmdsrx.n_oth, g_tmdsrx.u_tmdsrx.isl2);

         //--------------------------------------------------------------
         // 16-bit slots (more than one frame per line), audio restarted
         //--------------------------------------------------------------
         reg_wr(DPI_HDMI, 32'h0001_0813);
         u_i2s.run = 1'b0;
         dpi_wait_frames(1);
         u_i2s.slot = 16; u_i2s.run = 1'b1;
         measure_fp(16);
         cts_exp = (N_VAL / 128) * fp_meas;
         reg_wr(DPI_HDMI, 32'h0001_0817);
         dpi_wait_frames(3);
         n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;
         wait_audio(f0 + 420);
         n1 = g_tmdsrx.u_tmdsrx.aud_n;  f1 = u_i2s.frames;
         if (((n1 - n0) - (f1 - f0) > 4) || ((f1 - f0) - (n1 - n0) > 4)) begin
            $display("  %0d frames sent, %0d received", f1 - f0, n1 - n0);
            tb_error("16-bit slots: frames lost or added");
         end
         check_frames(n0, 16, "16-bit slots");
         check_cts("16-bit slots");
         if (g_tmdsrx.u_tmdsrx.asp_perr != 0) tb_error("audio subframe parity (16-bit slots)");
         if (g_tmdsrx.u_tmdsrx.asp_ferr != 0) tb_error("audio sample packet header or layout (16-bit slots)");
         reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);

         //--------------------------------------------------------------
         // Full-scale random samples (both signs, all-ones, all-zeros) in
         // slots of 16, 20, 24 and 32 bits, each with a line of about 3.5
         // source frames: sample packets of 4 frames; every sample exact,
         // nothing lost (no panel timing check across the timing switches)
         //--------------------------------------------------------------
         u_dpipanel.check = 1'b0;
         u_i2s.seed = tmp_seed; u_i2s.rnd = 1'b1;
         for (k = 0; k < 4; k = k + 1) begin
            sl = (k == 0) ? 16 : (k == 1) ? 20 : (k == 2) ? 24 : 32;
            reg_wr(DPI_HDMI, 32'h0001_0813);
            reg_poll(DPI_AUD_ST, 32'h0200_0000, 32'h0, 2000);
            u_i2s.run = 1'b0;
            fpc = 2.0 * sl * 2.0 * u_i2s.half / pix_ns;
            ha  = fpc * 3.5 - 100.0;
            dpi_timing(0, ha, 8, 8, 84, 8, 2, 2, 2);
            reg_wr(DPI_CTRL, 32'h1);
            dpi_wait_frames(2);
            u_i2s.slot = sl; u_i2s.run = 1'b1;
            reg_wr(DPI_HDMI, 32'h0001_081F);
            dpi_wait_frames(2);
            n0 = g_tmdsrx.u_tmdsrx.aud_n;  f0 = u_i2s.frames;  q0 = g_tmdsrx.u_tmdsrx.asp4;
            wait_audio(f0 + 160);
            check_rnd(n0, sl, (sl == 16) ? "random samples, 16-bit slots" : (sl == 20) ? "random samples, 20-bit slots" :
                              (sl == 24) ? "random samples, 24-bit slots" : "random samples, 32-bit slots");
            if (g_tmdsrx.u_tmdsrx.asp4 - q0 < 1) tb_error("random samples: no sample packet of 4 frames");
            reg_rd_mask(DPI_AUD_ST, 32'h0200_0000, 32'h0300_0000);
         end
         if (g_tmdsrx.u_tmdsrx.asp_perr != 0) tb_error("audio subframe parity (random samples)");
         if (g_tmdsrx.u_tmdsrx.asp_ferr != 0) tb_error("audio sample packet header or layout (random samples)");
         u_i2s.rnd = 1'b0;

         //--------------------------------------------------------------
         // No room for an island: frames lost, reported, cleared with AUD
         // (no panel timing check across the timing switches)
         //--------------------------------------------------------------
         u_dpipanel.check = 1'b0;
         dpi_timing(0, 40, 4, 4, 8, 20, 2, 2, 2);
         reg_wr(DPI_CTRL, 32'h1);
         dpi_wait_frames(2);
         n0 = g_tmdsrx.u_tmdsrx.n_asp;
         dpi_wait_frames(1);
         if (g_tmdsrx.u_tmdsrx.n_asp != n0) tb_error("audio sample packet without room in the blanking");
         reg_rd_mask(DPI_AUD_ST, 32'h0100_0000, 32'h0100_0000);
         reg_wr(DPI_HDMI, 32'h0001_0813);
         dpi_wait_frames(1);
         reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);

         //--------------------------------------------------------------
         // AUD and GP clear: only the AVI InfoFrame
         //--------------------------------------------------------------
         dpi_timing(0, 40, 8, 8, 90, 20, 2, 2, 2);
         reg_wr(DPI_CTRL, 32'h1);
         dpi_wait_frames(2);
         u_dpipanel.check = 1'b1;
         n0 = g_tmdsrx.u_tmdsrx.n_asp;  c0 = g_tmdsrx.u_tmdsrx.n_acr;
         a0 = g_tmdsrx.u_tmdsrx.n_aif;  g0 = g_tmdsrx.u_tmdsrx.n_oth;  x0 = g_tmdsrx.u_tmdsrx.n_avi;
         dpi_wait_frames(3);
         if ((g_tmdsrx.u_tmdsrx.n_asp != n0) || (g_tmdsrx.u_tmdsrx.n_acr != c0) ||
             (g_tmdsrx.u_tmdsrx.n_aif != a0) || (g_tmdsrx.u_tmdsrx.n_oth != g0))
            tb_error("audio or generic packet with AUD and GP clear");
         if (g_tmdsrx.u_tmdsrx.n_avi - x0 < 2) tb_error("AVI InfoFrame missing with AUD clear");
         u_i2s.run = 1'b0;
         dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "after audio");
      end
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
