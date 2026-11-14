//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_audio_rand
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_audio_rand.v
// Module Description : HDMI audio I2S slot capture against a reference model,
//                      random stream (seeded by the simulation seed): the
//                      source (i2s_src_model rmode) sends slots of random
//                      length with random bits in every position, every BCLK
//                      half period of random duration (at least 2.5 pixel
//                      clocks). Each stereo frame the receiver pushes is
//                      checked against the documented capture of the two
//                      slots that just ended (left, right): the first
//                      min(length, 24) bits MSB-justified, zero below, the
//                      bits past 24 dropped; and every pushed frame is the
//                      one after the previous (no frame skipped or repeated
//                      while the receiver stays armed). Phases:
//                      1. slots of 2..63 bits, BCLK half 2.5..6 pixel clocks;
//                      2. slots of 2..24 bits;
//                      3. slots of 24..63 bits, BCLK half 2.5..3 pixel clocks;
//                      4. LRCK and SD held for 70 BCLK periods (an LRCK
//                         stall), then the stream going on;
//                      5. one BCLK half period of 1100 pixel clocks (a BCLK
//                         stall), then the stream going on.
//                      After a stall the next frame may come any number of
//                      slots later, but must still match its slots.
//----------------------------------------------------------------------------
`define VERY_LONG_TIMEOUT

`include "dpi_tasks.v"

`define AR_I2S dut.G_DPI.u_dpi.g_hdmi.u_hdmi.g_i2s.u_i2s

reg     [31:0] v;
integer        ar_push, ar_prev, ar_bad, ar_slip, ar_s0, ar_p0;
reg            ar_resync;
real           pix_ns;

initial begin ar_push = 0; ar_prev = -1; ar_bad = 0; ar_slip = 0; ar_resync = 1'b1; end

// Every frame pushed: the left and right slots that just ended
always @(posedge `AR_I2S.clk_i)
   if (`AR_I2S.push === 1'b1) begin
      ar_push = ar_push + 1;
      if ((u_i2s.rs_last < 1) || (u_i2s.rs_last % 2 != 1)) begin
         ar_bad = ar_bad + 1;
         if (ar_bad <= 8) $display("  frame pushed after slot %0d, not a right slot %t", u_i2s.rs_last, $time);
      end else begin
         if (!ar_resync && (u_i2s.rs_last != ar_prev + 2)) begin
            ar_slip = ar_slip + 1;
            if (ar_slip <= 8) $display("  frame of slots %0d/%0d after %0d/%0d (skipped or repeated) %t",
                                       u_i2s.rs_last - 1, u_i2s.rs_last, ar_prev - 1, ar_prev, $time);
         end
         if ((`AR_I2S.fr[23:0]  !== u_i2s.rs_exp[(u_i2s.rs_last - 1) % u_i2s.RS_NR]) ||
             (`AR_I2S.fr[47:24] !== u_i2s.rs_exp[u_i2s.rs_last % u_i2s.RS_NR])) begin
            ar_bad = ar_bad + 1;
            if (ar_bad <= 8) $display("  frame of slots %0d/%0d: L 0x%06h R 0x%06h, expected L 0x%06h R 0x%06h %t",
                                      u_i2s.rs_last - 1, u_i2s.rs_last, `AR_I2S.fr[23:0], `AR_I2S.fr[47:24],
                                      u_i2s.rs_exp[(u_i2s.rs_last - 1) % u_i2s.RS_NR],
                                      u_i2s.rs_exp[u_i2s.rs_last % u_i2s.RS_NR], $time);
         end
      end
      ar_prev   = u_i2s.rs_last;
      ar_resync = 1'b0;
   end

// One phase: nslots slots with the given length and BCLK half-period ranges;
// at least nslots / 2 - 4 frames pushed
task ar_phase;
   input integer lmin, lmax;
   input real    hmin, hmax;
   input integer nslots;
   input [40*8-1:0] what;
   begin
      u_i2s.rl_min = lmin; u_i2s.rl_max = lmax;
      u_i2s.rh_min = hmin * pix_ns; u_i2s.rh_max = hmax * pix_ns;
      ar_s0 = u_i2s.rs_last; ar_p0 = ar_push;
      wait (u_i2s.rs_last >= ar_s0 + nslots);
      tb_checks = tb_checks + 1;
      if (ar_push - ar_p0 < nslots / 2 - 4) begin
         $display("ERROR: %0s: %0d frames pushed for %0d slots %t", what, ar_push - ar_p0, nslots, $time);
         error = error + 1;
      end else
         $display("OK:    %0s: %0d frames for %0d slots", what, ar_push - ar_p0, nslots);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   DPI: HDMI AUDIO CAPTURE, RANDOM I2S STREAM  |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_AUDIO)
         tb_skip_finish("|        (no HDMI audio in this build)          |");

      pix_ns = (DPI_PCLK_SEP != 0) ? 2.0 * dpi_pclk_half : 2.0 * CLK_HALF;

      reg_wr(DPI_AUD, {4'hB, 4'h2, 4'h0, 20'd2048});
      dpi_frame_fill(16, 8, 3);
      dpi_timing(0, 40, 8, 8, 90, 20, 2, 2, 2);          // blanking 106: two-packet islands
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      reg_wr(DPI_HDMI, 32'h0001_0817);                   // HDMI, AVI, AUD
      dpi_wait_frames(2);
      reg_rd_val(DPI_AUD_ST, v);
      if (!(v & 32'h0200_0000)) tb_error("DPI_AUD_STAT.ACTIVE not set");

      u_i2s.rseed = `SEED ^ 32'h12C5_A0D1;
      u_i2s.rmode = 1'b1;
      u_i2s.rh_min = 2.5 * pix_ns; u_i2s.rh_max = 6.0 * pix_ns;
      u_i2s.run   = 1'b1;
      wait (u_i2s.rs_last >= 4);

      ar_phase(2, 63, 2.5, 6.0, 600, "slots of 2..63 bits");
      ar_phase(2, 24, 2.5, 6.0, 400, "slots of 2..24 bits");
      ar_phase(24, 63, 2.5, 3.0, 300, "slots of 24..63 bits");

      // LRCK stall: LRCK and SD held while BCLK runs
      ar_resync = 1'b1;
      u_i2s.hold = 1'b1;
      repeat (70) @(posedge i2s_bclk);
      u_i2s.hold = 1'b0;
      ar_phase(2, 63, 2.5, 6.0, 100, "after an LRCK stall");

      // BCLK stall: one half period longer than 1023 pixel clocks
      ar_resync = 1'b1;
      u_i2s.rh_min = 1100.0 * pix_ns; u_i2s.rh_max = 1100.0 * pix_ns;
      @(posedge i2s_bclk);
      @(negedge i2s_bclk);
      ar_phase(2, 63, 2.5, 6.0, 100, "after a BCLK stall");

      u_i2s.run   = 1'b0;
      u_i2s.rmode = 1'b0;

      tb_checks = tb_checks + 1;
      if ((ar_bad != 0) || (ar_slip != 0)) begin
         $display("ERROR: %0d frames differ from the reference capture, %0d out of sequence", ar_bad, ar_slip);
         error = error + 1;
      end else
         $display("OK:    %0d frames, every one the reference capture of its two slots", ar_push);

      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
