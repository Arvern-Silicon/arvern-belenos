//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_audio_cts
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_audio_cts.v
// Module Description : HDMI audio clock regeneration at the ends of the CTS
//                      range (DPI_AUDIO_EN):
//                        - a slow audio clock (about 64 600 pixel clocks a
//                          frame) with N = 2 048: a CTS of about 1 033 600
//                          (0xFC5xx, just below 2^20), in DPI_AUD_STAT and in
//                          the clock regeneration packets;
//                        - the usual audio clock (about 260 pixel clocks a
//                          frame) with N = 0xFFF80 (8 191 frames a
//                          measurement): the count reaches 2^20 - 1, the
//                          measurement is dropped (DPI_AUD_STAT keeps the
//                          last CTS);
//                        - N = 128 (one frame): the CTS of one frame again.
//                      Each N is written with AUD clear (DPI_AUD writes are
//                      ignored while the pixel domain may read it).
//----------------------------------------------------------------------------
`define VERY_LONG_TIMEOUT
`include "dpi_tasks.v"

localparam  [3:0] AC_FS = 4'h2;
localparam  [3:0] AC_WL = 4'hB;

reg [31:0] v;
real       ac_pix, ac_exp;
integer    ac_c0, ac_k;

// A new N: AUD cleared, DPI_AUD written until it reads back, AUD set again
task ac_set_n;
   input [19:0] n;
   integer      k;
   begin
      reg_wr(DPI_HDMI, 32'h0001_081B);
      k = 0; v = 32'h0;
      while ((v != {AC_WL, AC_FS, 4'h0, n}) && (k < 200)) begin
         reg_wr(DPI_AUD, {AC_WL, AC_FS, 4'h0, n});
         reg_rd_val(DPI_AUD, v);
         k = k + 1;
      end
      if (v != {AC_WL, AC_FS, 4'h0, n}) tb_error("DPI_AUD not written after AUD was cleared");
      reg_wr(DPI_HDMI, 32'h0001_081F);
   end
endtask

// Wait for m more clock regeneration packets, at most nf panel frames
task ac_wait_acr;
   input integer m;
   input integer nf;
   integer       k;
   begin
      ac_c0 = g_tmdsrx.u_tmdsrx.n_acr;
      k = 0;
      while ((g_tmdsrx.u_tmdsrx.n_acr < ac_c0 + m) && (k < nf)) begin dpi_wait_frames(1); k = k + 1; end
      if (g_tmdsrx.u_tmdsrx.n_acr < ac_c0 + m) tb_error("clock regeneration packets did not arrive");
   end
endtask

// A measurement of nfr frames of the current source: DPI_AUD_STAT and the packets
task ac_meas;
   input integer nfr;
   input [80*8-1:0] what;
   begin
      ac_exp = nfr * (2.0 * u_i2s.slot * 2.0 * u_i2s.half) / ac_pix;
      // the measurement after the next frame boundary: two more measurements
      ac_k = 0;
      while ((ac_k < 2 * nfr + 8) && (ac_k < 100000)) begin
         @(posedge u_i2s.lrck_o); ac_k = ac_k + 1;
      end
      ac_wait_acr(2, 2000);                                 // one packet per measurement: 1 M pixel clocks apart
      tb_checks = tb_checks + 1;
      reg_rd_val(DPI_AUD_ST, v);
      if ((v[19:0] < ac_exp - 3.0) || (v[19:0] > ac_exp + 3.0) ||
          (g_tmdsrx.u_tmdsrx.acr_cts < ac_exp - 3.0) || (g_tmdsrx.u_tmdsrx.acr_cts > ac_exp + 3.0)) begin
         $display("  DPI_AUD_STAT 0x%08h, packet CTS %0d, expected %0.1f", v, g_tmdsrx.u_tmdsrx.acr_cts, ac_exp);
         tb_error({what, ": CTS"});
      end else
         $display("OK:    %0s -- CTS %0d (expected %0.1f)", what, v[19:0], ac_exp);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DPI: HDMI AUDIO CTS AT THE RANGE ENDS       |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || !HAS_AUDIO)
         tb_skip_finish("|      (no HDMI audio in this build)            |");

      ac_pix = (DPI_PCLK_SEP != 0) ? 2.0 * dpi_pclk_half : 2.0 * CLK_HALF;
      dpi_frame_fill(16, 8, 3);
      dpi_timing(0, 40, 8, 8, 90, 20, 2, 2, 2);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      u_dpipanel.check = 1'b1;
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);    // started: the fields are written
      reg_wr(DPI_HDMI, 32'h0001_081F);

      // 1) about 64 600 pixel clocks a frame (BCLK half: about 505 pixel clocks)
      u_i2s.slot = 32;
      u_i2s.half = 64600.0 * ac_pix / 128.0;
      ac_set_n(20'd2048);
      u_i2s.run = 1'b1;
      ac_meas(16, "N 2048, 64 600 pixel clocks a frame");

      // 2) 8 191 frames of about 260 pixel clocks: the count saturates
      u_i2s.run = 1'b0;
      repeat (3000) @(posedge free_clk);                     // a BCLK stall
      u_i2s.half = 260.0 * ac_pix / 128.0;
      ac_set_n(20'hF_FF80);
      u_i2s.run = 1'b1;
      ac_k = 0;
      while (ac_k < 8191 + 60) begin @(posedge u_i2s.lrck_o); ac_k = ac_k + 1; end
      tb_checks = tb_checks + 1;
      reg_rd_val(DPI_AUD_ST, v);
      ac_exp = 16 * (2.0 * 32 * 2.0 * 64600.0 * ac_pix / 128.0) / ac_pix;
      if ((v[19:0] < ac_exp - 3.0) || (v[19:0] > ac_exp + 3.0)) begin
         $display("  DPI_AUD_STAT 0x%08h, expected the last CTS %0.1f", v, ac_exp);
         tb_error("N 0xFFF80: a saturated measurement replaced the CTS");
      end else
         $display("OK:    N 0xFFF80 -- the saturated measurements dropped, CTS still %0d", v[19:0]);

      // 3) one frame per measurement
      ac_set_n(20'd128);
      ac_meas(1, "N 128, 260 pixel clocks a frame");

      reg_rd_mask(DPI_AUD_ST, 32'h0, 32'h0100_0000);         // LOST clear
      if (g_tmdsrx.u_tmdsrx.acr_err != 0) tb_error("clock regeneration subpackets");
      u_i2s.run = 1'b0;
      u_dpipanel.check = 1'b0;
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200000);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
