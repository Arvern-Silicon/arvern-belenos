//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_hdmi_update
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_hdmi_update.v
// Module Description : The AVI InfoFrame fields and the generic packet
//                      changed while they are being sent: AVI fields written
//                      with AVI set take effect at the next UPDATE (frame
//                      start), not before; written while that UPDATE is
//                      pending they are ignored (read back unchanged, not
//                      sent); generic-packet writes while GP is set are
//                      ignored; the sequence enable clear, write, enable set
//                      changes both; an UPDATE abandoned by clearing DPI_EN
//                      does not lock the fields; fields written during a
//                      start (DPI_EN set, the pixel clock held stopped so
//                      that the start cannot complete: DPI_PCLK_SEP = 1) are
//                      ignored, DPI_CTRL.UPDATE reads 1 meanwhile, and the
//                      start sends the fields written before it. The receiver model decodes every
//                      packet (correct parity) and the last AVI InfoFrame and
//                      generic packet are compared with the fields expected.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "dpi_tasks.v"

reg  [31:0] v;
reg  [23:0] hdr;
reg   [7:0] pb [0:27];
reg [223:0] sub;
reg  [23:0] g_hdr;
reg [223:0] g_pb;
integer     i;

task avi_expect;
   input [1:0] pic;
   input [3:0] act;
   input [6:0] vic;
   begin
      hdr = 24'h0D_02_82;
      for (i = 0; i < 28; i = i + 1) pb[i] = 8'h00;
      pb[1] = 8'h10;
      pb[2] = {2'b00, pic, act};
      pb[4] = {1'b0, vic};
      v = hdr[7:0] + hdr[15:8] + hdr[23:16];
      for (i = 1; i < 14; i = i + 1) v = v + pb[i];
      pb[0] = 8'h00 - v[7:0];
      for (i = 0; i < 28; i = i + 1) sub[8*i +: 8] = pb[i];
   end
endtask

task avi_check;
   input [8*40-1:0] what;
   integer          n0;
   begin
      n0 = g_tmdsrx.u_tmdsrx.n_avi;
      dpi_wait_frames(2);
      if (g_tmdsrx.u_tmdsrx.n_avi - n0 < 1) tb_error("HDMI: no AVI InfoFrame");
      if ((g_tmdsrx.u_tmdsrx.avi_hdr !== hdr) || (g_tmdsrx.u_tmdsrx.avi_sub !== sub)) begin
         $display("ERROR: %0s -- AVI InfoFrame %h / expected %h %t", what, g_tmdsrx.u_tmdsrx.avi_sub, sub, $time);
         error = error + 1;
      end else
         $display("OK:    %0s", what);
   end
endtask

task gp_write;
   input  [7:0] base;
   begin
      g_hdr = {8'h19, 8'h01, base};
      for (i = 0; i < 28; i = i + 1) g_pb[8*i +: 8] = base + i;
      reg_wr(DPI_PKT0, {8'h00, g_hdr});
      for (i = 0; i < 7; i = i + 1) reg_wr(DPI_PKT0 + 4 + 4*i, g_pb[32*i +: 32]);
   end
endtask

task gp_check;
   input [23:0]     e_hdr;
   input [223:0]    e_pb;
   input [8*40-1:0] what;
   integer          n0;
   begin
      n0 = g_tmdsrx.u_tmdsrx.n_oth;
      dpi_wait_frames(2);
      if (g_tmdsrx.u_tmdsrx.n_oth - n0 < 1) tb_error("HDMI: no generic packet");
      if ((g_tmdsrx.u_tmdsrx.oth_hdr !== e_hdr) || (g_tmdsrx.u_tmdsrx.oth_sub !== e_pb)) begin
         $display("ERROR: %0s -- generic packet %h %h / expected %h %h %t", what,
                  g_tmdsrx.u_tmdsrx.oth_hdr, g_tmdsrx.u_tmdsrx.oth_sub, e_hdr, e_pb, $time);
         error = error + 1;
      end else
         $display("OK:    %0s", what);
   end
endtask

reg  [23:0] p1_hdr;
reg [223:0] p1_pb;

initial
   begin
      $display(" ===============================================");
      $display("|   DPI: HDMI FIELDS AND PACKET WITH UPDATE     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_ISLAND)
         tb_skip_finish("|        (needs HDMI data islands)              |");

      dpi_frame_fill(16, 8, 3);
      dpi_timing(0, 40, 4, 4, 56, 20, 2, 2, 2);         // horizontal blanking of 64
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      u_dpipanel.check = 1'b1;
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);   // started: the fields are written
      if (HAS_AUDIO) gp_write(8'h40);
      p1_hdr = g_hdr; p1_pb = g_pb;

      // Fields A with HDMI, AVI (and GP)
      reg_wr(DPI_HDMI, 32'h0001_0813 | (HAS_AUDIO ? 32'h8 : 32'h0));
      dpi_wait_frames(1);
      avi_expect(2'd1, 4'd8, 7'd1);
      avi_check("AVI fields A");
      if (HAS_AUDIO) gp_check(p1_hdr, p1_pb, "generic packet 1");

      // Fields B written with AVI set: not before the UPDATE
      reg_wr(DPI_HDMI, 32'h005A_0B23 | (HAS_AUDIO ? 32'h8 : 32'h0));
      reg_rd(DPI_HDMI, 32'h005A_0B23 | (HAS_AUDIO ? 32'h8 : 32'h0));
      if (HAS_AUDIO) begin                              // GP set: packet writes ignored
         gp_write(8'h80);
         reg_rd(DPI_PKT0, {8'h00, p1_hdr});
         g_hdr = p1_hdr; g_pb = p1_pb;
      end
      dpi_wait_frames(1);
      avi_check("AVI fields A kept until the UPDATE");
      if (HAS_AUDIO) gp_check(p1_hdr, p1_pb, "generic packet 1 kept while GP is set");

      // UPDATE; fields C written while it is pending: ignored
      reg_wr(DPI_CTRL, 32'h1);
      reg_wr(DPI_HDMI, 32'h0003_0913 | (HAS_AUDIO ? 32'h8 : 32'h0));
      reg_rd(DPI_HDMI, 32'h005A_0B23 | (HAS_AUDIO ? 32'h8 : 32'h0));
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(1);
      avi_expect(2'd2, 4'd11, 7'h5A);
      avi_check("AVI fields B after the UPDATE");
      if (HAS_AUDIO) gp_check(p1_hdr, p1_pb, "generic packet 1 after the UPDATE");

      // The 1.0 sequence: AVI clear, a frame, fields C, AVI set
      reg_wr(DPI_HDMI, 32'h005A_0B21);
      dpi_wait_frames(1);
      reg_wr(DPI_HDMI, 32'h0003_0911);
      reg_wr(DPI_HDMI, 32'h0003_0913);
      dpi_wait_frames(1);
      avi_expect(2'd1, 4'd9, 7'd3);
      avi_check("AVI fields C, the 1.0 sequence");
      if (HAS_AUDIO) begin
         gp_write(8'hC0);
         reg_wr(DPI_HDMI, 32'h0003_091B);
         dpi_wait_frames(1);
         gp_check(g_hdr, g_pb, "generic packet 4: GP clear, write, GP set");
      end

      // UPDATE pending, stop: the abandoned update does not lock the fields;
      // fields D written while stopped are taken at the restart
      reg_wr(DPI_CTRL, 32'h1);
      reg_rd(DPI_CTRL, 32'h1);
      u_dpipanel.check = 1'b0;
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h1, 32'h0, 50 * PCLK_SLOW);
      reg_rd(DPI_CTRL, 32'h0);
      reg_wr(DPI_HDMI, 32'h0004_0A13 | (HAS_AUDIO ? 32'h8 : 32'h0));
      reg_rd(DPI_HDMI, 32'h0004_0A13 | (HAS_AUDIO ? 32'h8 : 32'h0));
      reg_wr(DIF_CFG, v);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      avi_expect(2'd1, 4'd10, 7'd4);
      avi_check("AVI fields D after a stop");

      // A start takes the fields: written between the DPI_EN write and the
      // start they are ignored (the pixel clock is held stopped so that the
      // start waits; with one clock the start is over before the next write)
      if (DPI_PCLK_SEP != 0) begin
         u_dpipanel.check = 1'b0;
         reg_rd_val(DIF_CFG, v);
         reg_wr(DIF_CFG, v & ~32'h8);
         reg_poll(DIF_STATUS, 32'h1, 32'h0, 50 * PCLK_SLOW);
         reg_wr(DPI_HDMI, 32'h0002_0913 | (HAS_AUDIO ? 32'h8 : 32'h0));      // fields E, stopped: written
         @(negedge dpi_pclk);
         dpi_pclk_stop = 1'b1;
         reg_wr(DIF_CFG, v);                                                // start, held
         reg_wr(DPI_HDMI, 32'h0005_0A13 | (HAS_AUDIO ? 32'h8 : 32'h0));      // fields F: ignored
         reg_rd(DPI_HDMI, 32'h0002_0913 | (HAS_AUDIO ? 32'h8 : 32'h0));
         reg_rd_mask(DPI_CTRL, 32'h1, 32'h1);                               // locked: the start is pending
         repeat (20) @(posedge free_clk);
         reg_rd(DPI_HDMI, 32'h0002_0913 | (HAS_AUDIO ? 32'h8 : 32'h0));
         dpi_pclk_stop = 1'b0;
         reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
         reg_wr(DPI_HDMI, 32'h0005_0A13 | (HAS_AUDIO ? 32'h8 : 32'h0));      // after the start: written
         reg_rd(DPI_HDMI, 32'h0005_0A13 | (HAS_AUDIO ? 32'h8 : 32'h0));
         dpi_wait_frames(2);
         avi_expect(2'd1, 4'd9, 7'd2);
         avi_check("AVI fields E: fields written during the start ignored");
      end

      u_dpipanel.check = 1'b0;
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
