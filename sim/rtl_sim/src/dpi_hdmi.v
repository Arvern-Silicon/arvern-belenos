//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_hdmi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_hdmi.v
// Module Description : HDMI mode and the AVI InfoFrame (DPI_ISLAND_EN):
//                      DPI_HDMI reset value, mask and read-back; DVI by
//                      default (no preamble, no island); with HDMI and AVI
//                      set, every line is preceded by a video preamble and
//                      guard band and every frame carries exactly one packet,
//                      in its island at the first vertical blanking line,
//                      that the receiver model decodes with correct parity: the AVI
//                      InfoFrame of the fields (header, checksum, PB1 to
//                      PB27), for two sets of fields; the RGB quantization
//                      range (QUANT: 0 default, 1 limited, 2 full, 3 reserved) in PB3
//                      bits 3:2 with the checksum right (the receiver model
//                      checks it) for each value; AVI clear: no packet;
//                      HDMI with CLK_DIV > 0 stays DVI; HDMI clear: back to
//                      DVI; the image right throughout. Without data islands:
//                      RAZ/WI, DPI_CAPS bit 9 clear. The horizontal blanking
//                      holds an island (63 pixels or more).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "dpi_tasks.v"

reg  [31:0] v;
reg   [7:0] pb [0:27];                    // PB0 .. PB27 expected
reg  [23:0] hdr;
reg [223:0] sub;
integer     i, p0, l0, l1, d0, f0, a0, i0, n0, q, e0;
// With audio the islands sit in the horizontal blanking: 64 pixels hold one packet
integer     hbp = 56;                        // a horizontal blanking of 64: the island's 63 and more

// The AVI InfoFrame expected for the fields (CTA-861, version 2, 13 bytes)
task avi_expect_q;
   input [1:0] pic;
   input [3:0] act;
   input [6:0] vic;
   input [1:0] qr;
   begin
      hdr = 24'h0D_02_82;
      for (i = 0; i < 28; i = i + 1) pb[i] = 8'h00;
      pb[1] = 8'h10;                      // RGB, active format present
      pb[2] = {2'b00, pic, act};
      pb[3] = {4'h0, qr, 2'b00};          // Q1:Q0, the RGB quantization range
      pb[4] = {1'b0, vic};
      v = hdr[7:0] + hdr[15:8] + hdr[23:16];
      for (i = 1; i < 14; i = i + 1) v = v + pb[i];
      pb[0] = 8'h00 - v[7:0];
      for (i = 0; i < 28; i = i + 1) sub[8*i +: 8] = pb[i];
   end
endtask
task avi_expect;
   input [1:0] pic;
   input [3:0] act;
   input [6:0] vic;
   avi_expect_q(pic, act, vic, 2'd0);
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: HDMI MODE AND DATA ISLANDS        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      if (!HAS_ISLAND) begin
         reg_wr(DPI_HDMI, 32'hFFFF_FFFF);     reg_rd(DPI_HDMI, 32'h0);
         reg_rd_mask(DPI_CAPS, 32'h0, 32'h200);
      end else begin
         // Register: reset value, mask, read-back of the fields
         reg_rd(DPI_HDMI, 32'h0);
         reg_wr(DPI_HDMI, 32'hFF80_F00C);     reg_rd(DPI_HDMI, HAS_AUDIO ? 32'hC : 32'h0);
         reg_wr(DPI_HDMI, 32'h007F_0FF0);     reg_rd(DPI_HDMI, 32'h007F_0FF0);
         reg_wr(DPI_HDMI, 32'h0);
         reg_rd_mask(DPI_CAPS, 32'h200, 32'h200);

         // Fields: picture 4:3, active format as the picture, VIC 1
         avi_expect(2'd1, 4'd8, 7'd1);

         // DVI first
         dpi_frame_fill(16, 8, 3);
         dpi_timing(0, 40, 4, 4, hbp, 20, 2, 2, 2);
         reg_rd_val(DIF_CFG, v);
         reg_wr(DIF_CFG, v | 32'h9);
         u_dpipanel.check = 1'b1;
         dpi_wait_frames(2);
         if (g_tmdsrx.u_tmdsrx.vlines_hdmi != 0) tb_error("HDMI: video preamble in DVI mode");
         if (g_tmdsrx.u_tmdsrx.pkt_count != 0)  tb_error("HDMI: packet in DVI mode");

         // HDMI mode with the AVI InfoFrame
         reg_wr(DPI_HDMI, 32'h0001_0813);  reg_rd(DPI_HDMI, 32'h0001_0813);
         dpi_wait_frames(2);
         n0 = g_tmdsrx.u_tmdsrx.n_avi;
         p0 = g_tmdsrx.u_tmdsrx.pkt_count;
         l0 = g_tmdsrx.u_tmdsrx.vlines_hdmi;
         d0 = g_tmdsrx.u_tmdsrx.vlines_dvi;
         f0 = g_tmdsrx.u_tmdsrx.fr_n;
         a0 = g_tmdsrx.u_tmdsrx.fr_avi0;
         i0 = g_tmdsrx.u_tmdsrx.isl_n;
         dpi_wait_frames(3);
         // One AVI InfoFrame in every frame (the receiver flags a second one)
         if (g_tmdsrx.u_tmdsrx.fr_n - f0 < 2) tb_error("HDMI: the receiver saw no frame end");
         if (g_tmdsrx.u_tmdsrx.fr_avi0 != a0) tb_error("HDMI: a frame without the AVI InfoFrame");
         if (g_tmdsrx.u_tmdsrx.pkt_count - p0 != g_tmdsrx.u_tmdsrx.n_avi - n0) tb_error("HDMI: a packet other than the AVI InfoFrame");
         if (g_tmdsrx.u_tmdsrx.isl_n - i0 < 2) tb_error("HDMI: no island placement checked");
         if (g_tmdsrx.u_tmdsrx.vlines_hdmi - l0 < 3*20 - 20) tb_error("HDMI: lines without a video preamble");
         if (g_tmdsrx.u_tmdsrx.vlines_dvi != d0) tb_error("HDMI: a line without the preamble in HDMI mode");
         if (g_tmdsrx.u_tmdsrx.pkt_hdr !== hdr) tb_error("HDMI: packet header differs");
         if (g_tmdsrx.u_tmdsrx.pkt_sub !== sub) tb_error("HDMI: packet content differs");
         dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "HDMI mode");
         $display("HDMI: %0d packets, %0d lines with the video preamble", g_tmdsrx.u_tmdsrx.pkt_count,
                  g_tmdsrx.u_tmdsrx.vlines_hdmi);

         // Other fields (with AVI clear for a frame): picture 16:9, active
         // format 14:9, VIC 0x5A
         reg_wr(DPI_HDMI, 32'h005A_0B21);
         dpi_wait_frames(1);
         avi_expect(2'd2, 4'd11, 7'h5A);
         reg_wr(DPI_HDMI, 32'h005A_0B23);
         dpi_wait_frames(1);
         p0 = g_tmdsrx.u_tmdsrx.pkt_count;
         dpi_wait_frames(2);
         if (g_tmdsrx.u_tmdsrx.pkt_count - p0 < 1) tb_error("HDMI: no packet after the fields changed");
         if (g_tmdsrx.u_tmdsrx.pkt_hdr !== hdr) tb_error("HDMI: packet header differs (second fields)");
         if (g_tmdsrx.u_tmdsrx.pkt_sub !== sub) tb_error("HDMI: packet content differs (second fields)");

         // RGB quantization range (QUANT, DPI_HDMI [7:6]): default, limited,
         // full, the reserved 3 (sent as written: both Q bits) and 0 again, each
         // written with AVI clear and then sent; the receiver model checks
         // the checksum of every AVI InfoFrame
         for (q = 0; q < 5; q = q + 1) begin
            e0 = g_tmdsrx.u_tmdsrx.errors;
            reg_wr(DPI_HDMI, 32'h0004_0921 | ((q & 3) << 6));
            reg_rd(DPI_HDMI, 32'h0004_0921 | ((q & 3) << 6));
            dpi_wait_frames(1);
            avi_expect_q(2'd2, 4'd9, 7'h04, q[1:0]);
            reg_wr(DPI_HDMI, 32'h0004_0923 | ((q & 3) << 6));
            dpi_wait_frames(1);
            p0 = g_tmdsrx.u_tmdsrx.n_avi;
            dpi_wait_frames(2);
            if (g_tmdsrx.u_tmdsrx.n_avi - p0 < 1) tb_error("HDMI: no AVI InfoFrame with QUANT");
            if (g_tmdsrx.u_tmdsrx.avi_hdr !== hdr) tb_error("HDMI: AVI header differs (QUANT)");
            if (g_tmdsrx.u_tmdsrx.avi_sub !== sub) tb_error("HDMI: AVI content differs (QUANT)");
            if (g_tmdsrx.u_tmdsrx.avi_q   !== q[1:0]) tb_error("HDMI: AVI quantization range differs");
            if (g_tmdsrx.u_tmdsrx.errors  !== e0) tb_error("HDMI: receiver errors with QUANT (checksum)");
            $display("HDMI: QUANT %0d sent, checksum 0x%02h", q & 3, pb[0]);
         end

         // HDMI without the InfoFrame
         reg_wr(DPI_HDMI, 32'h1);
         dpi_wait_frames(1);
         p0 = g_tmdsrx.u_tmdsrx.pkt_count;
         dpi_wait_frames(2);
         if (g_tmdsrx.u_tmdsrx.pkt_count != p0) tb_error("HDMI: packet sent with PKT clear");

         // HDMI with CLK_DIV = 1 (pixel repetition): stays DVI (no panel
         // timing check across the switches: a new CLK_DIV gives one
         // irregular period)
         u_dpipanel.check = 1'b0;
         dpi_timing(1, 40, 4, 4, hbp, 20, 2, 2, 2);
         reg_wr(DPI_CTRL, 32'h1);
         dpi_wait_frames(2);
         l1 = g_tmdsrx.u_tmdsrx.vlines_hdmi;
         dpi_wait_frames(2);
         if (g_tmdsrx.u_tmdsrx.vlines_hdmi != l1) tb_error("HDMI: video preamble with CLK_DIV > 0");
         dpi_timing(0, 40, 4, 4, hbp, 20, 2, 2, 2);
         reg_wr(DPI_CTRL, 32'h1);
         dpi_wait_frames(2);
         u_dpipanel.check = 1'b1;

         // Back to DVI
         reg_wr(DPI_HDMI, 32'h0);
         dpi_wait_frames(1);
         l1 = g_tmdsrx.u_tmdsrx.vlines_hdmi;
         dpi_wait_frames(2);
         if (g_tmdsrx.u_tmdsrx.vlines_hdmi != l1) tb_error("HDMI: video preamble after HDMI was cleared");
         dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "back to DVI");
      end
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
