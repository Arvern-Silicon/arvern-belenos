//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_preset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_preset.v
// Module Description : DPI driver with its own pixel clock (DPI_PCLK_SEP =
//                      1): dpi_presetn_i asserted alone (hresetn_i stays
//                      high) while the driver runs, at TP_N instants spread
//                      over a panel frame. The register side keeps its fill
//                      toggles and the pixel side restarts with its release
//                      toggles at 0. After each reset: two frames to
//                      settle (the events of the reset itself -- UNDERFLOW,
//                      an abandoned frame -- are reported, not checked),
//                      then over two more frames no UNDERFLOW and no
//                      abandoned frame, DIF_STATUS.BUSY, no UPDATE pending,
//                      DPI_FRAMES counting, the image exact and the panel
//                      (and TMDS) timing without error: the bus side sends
//                      the frame size again while the pixel side starts
//                      (its copy and acknowledge reset to 0), whatever the
//                      number of size changes before. Then dpi_presetn_i
//                      alone while the driver is stopped (DPI_EN = 0), and a
//                      start: the image is exact again. The settings in
//                      use are not the reset values: a border colour, and
//                      before every other reset an explicit position with,
//                      with a scaler, an image size and a 2x step, before
//                      the others the image centred at the frame size; the
//                      frame size (DISP_SIZE) changes before every other
//                      reset. So the pixel side restarts with the register
//                      side's settings and the frame size last sent.
//                      Then (ASYNC_RST_EN = 1) pixel resets shorter than an
//                      hclk_i period, forced on dpi_presetn_i just after an
//                      hclk_i edge while the pixel clock runs 10 times
//                      faster than hclk_i, so that the pixel domain stops
//                      and starts again between two hclk_i edges (running
//                      never seen low there): with either value of the
//                      frame-size toggle the frame size is sent again and
//                      the image is exact.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT
`include "dpi_tasks.v"

localparam integer TP_N = 6;

reg     [31:0] v, f0;
integer        k, t0, tf, e0, te0, nuf, nab;
integer        fw, fh, iw, ih, st, md;

// The image with the settings in use (P_* below) for a frame of fw x fh
localparam [23:0]  P_BORDER = 24'h5A6B7C;
localparam integer P_X = 3, P_Y = 2;

// Settings other than their reset values: m 0 explicit position (and image
// size, 2x step), m 1 centred at the frame size, 1:1; taken with UPDATE
task set_mode;
   input integer m;
   begin
      md = m;
      u_dpipanel.check = 1'b0;
      reg_wr(DPI_BORDER, P_BORDER);
      reg_wr(DPI_IMG_POS,  (m == 1) ? 32'h8000_0000 : ((P_Y << 16) | P_X));
      reg_wr(DPI_IMG_SIZE, (m == 1) ? 32'h0 : ((16 << 16) | 32));   // read 0 without a scaler
      reg_wr(DPI_SCALE,    (m == 1) ? 32'h0 : 32'h0800_0800);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(1);
   end
endtask
task chk_img;
   input [8*48-1:0] what;
   begin
      if (md == 1)              dpi_check_image(fw, fh, fw, fh, (40 - fw) / 2, (20 - fh) / 2, 4096, 4096, 0, P_BORDER, what);
      else if (DPI_SCALER != 0) dpi_check_image(fw, fh, 32, 16, P_X, P_Y, 2048, 2048, 0, P_BORDER, what);
      else                      dpi_check_image(fw, fh, fw, fh, P_X, P_Y, 4096, 4096, 0, P_BORDER, what);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: pixel-domain reset alone          |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DPI_PCLK_SEP == 0))
         tb_skip_finish("|   (needs the DPI driver with its own clock)   |");

      dpi_frame_fill(16, 8, 7);
      dpi_timing(dpi_div(1), 40, 3, 2, 6, 20, 2, 1, 2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(3);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "before the pixel resets");

      // Frame period (free_clk cycles)
      dpi_wait_frames(1);
      t0 = 0;
      f0 = u_dpipanel.frames;
      while (u_dpipanel.frames == f0) begin @(posedge free_clk); t0 = t0 + 1; end
      tf = t0;
      $display("INFO:  panel frame: %0d free_clk cycles", tf);

      fw = 16; fh = 8;
      set_mode(0);
      chk_img("live settings, before the pixel resets");

      nuf = 0; nab = 0;
      for (k = 0; k < TP_N; k = k + 1) begin
         // the settings and the frame size in use before the reset
         if (k % 4 >= 2) begin fw = 12; fh = 6; end else begin fw = 16; fh = 8; end
         reg_wr(DISP_SIZE, (fh << 16) | fw);
         set_mode(k % 2);
         // k / TP_N of a frame after a frame end
         f0 = u_dpipanel.frames;
         while (u_dpipanel.frames == f0) @(posedge free_clk);
         repeat ((tf * k) / TP_N) @(posedge free_clk);
         u_dpipanel.check = 1'b0;
         e0  = u_dpipanel.errors;
         te0 = g_tmdsrx.u_tmdsrx.errors;
         dpi_prst_force = 1'b1;
         repeat (20) @(posedge dpi_pclk);                   // a synchronous reset needs clock edges
         dpi_prst_force = 1'b0;

         // Settle: the reset's own events
         dpi_wait_frames(2);
         reg_rd_val(DIF_IRQ_FLAG, v);
         if (v[5]) nuf = nuf + 1;
         reg_rd_val(STATUS, v);
         if (v[4]) nab = nab + 1;
         reg_wr(DIF_IRQ_FLAG, 32'h78);
         u_dpipanel.errors = e0;
         u_dpipanel.check  = 1'b1;
         reg_rd_val(DPI_FRAMES, f0);

         // Steady state again
         dpi_wait_frames(2);
         reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);           // no UNDERFLOW
         reg_rd_mask(STATUS, 32'h0, 32'h10);                 // whole frames
         reg_rd_mask(DIF_STATUS, 32'h1, 32'h1);              // BUSY
         reg_rd_mask(DPI_CTRL, 32'h0, 32'h1);                // no UPDATE pending
         reg_rd_val(DPI_FRAMES, v);
         if (v - f0 < 2) tb_error("DPI_FRAMES does not count after the pixel reset");
         if (u_dpipanel.errors != e0) tb_error("panel timing wrong after the pixel reset");
         if (HAS_TMDS && (g_tmdsrx.u_tmdsrx.errors != te0)) tb_error("TMDS stream wrong after the pixel reset");
         chk_img("after a pixel reset");
         $display("--- pixel reset %0d/%0d of a frame after a frame end: recovered", k, TP_N);
      end
      $display("INFO:  %0d of %0d pixel resets raised UNDERFLOW, %0d an abandoned frame, while settling",
               nuf, TP_N, nab);

      // Pixel resets shorter than an hclk_i period, the frame-size toggle at
      // 0 and at 1 (an asynchronous reset is needed for a reset without a
      // clock edge)
      if (ASYNC_RST_EN != 0) begin
         for (k = 0; k < 4; k = k + 1) begin
            set_mode(1);
            if (dut.G_DPI.u_dpi.u_dpi_bdi.sz_req_o != k[0]) begin  // one more size sent
               if (fw == 16) begin fw = 12; fh = 6; end else begin fw = 16; fh = 8; end
               reg_wr(DISP_SIZE, (fh << 16) | fw);
               dpi_wait_frames(2);
               u_dpipanel.check = 1'b1;
               dpi_wait_frames(1);
            end
            if (dut.G_DPI.u_dpi.u_dpi_bdi.sz_req_o != k[0]) tb_error("frame-size toggle not as planned");
            chk_img("before a short pixel reset");
            u_dpipanel.check = 1'b0;
            e0  = u_dpipanel.errors;
            te0 = g_tmdsrx.u_tmdsrx.errors;
            @(negedge dpi_pclk);
            dpi_pclk_half = CLK_HALF / 10.0;
            repeat (4) @(posedge dpi_pclk);
            @(posedge hclk);
            #(0.1 * CLK_HALF + 0.2 * k);
            force dpi_presetn = 1'b0;                        // until the next pixel-clock edge
            #0.1;
            release dpi_presetn;
            repeat (20) @(posedge dpi_pclk);
            dpi_pclk_half = dpi_pclk_base;
            dpi_wait_frames(2);
            reg_wr(DIF_IRQ_FLAG, 32'h78);
            u_dpipanel.errors = e0;
            u_dpipanel.check  = 1'b1;
            dpi_wait_frames(2);
            reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);        // no UNDERFLOW
            reg_rd_mask(STATUS, 32'h0, 32'h10);              // whole frames
            if (u_dpipanel.errors != e0) tb_error("panel timing wrong after a short pixel reset");
            if (HAS_TMDS && (g_tmdsrx.u_tmdsrx.errors != te0)) tb_error("TMDS stream wrong after a short pixel reset");
            chk_img("after a short pixel reset");
            $display("--- short pixel reset, frame-size toggle %0d: recovered", k[0]);
         end
      end

      // Pixel reset while stopped, then a start
      u_dpipanel.check = 1'b0;
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);                           // stop
      reg_poll(DIF_STATUS, 32'h1, 32'h0, 2000);
      dpi_prst_force = 1'b1;
      repeat (20) @(posedge dpi_pclk);
      dpi_prst_force = 1'b0;
      repeat (20) @(posedge dpi_pclk);
      reg_wr(DIF_CFG, v | 32'h8);                            // start
      dpi_wait_frames(2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      e0 = u_dpipanel.errors;
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);              // no UNDERFLOW
      if (u_dpipanel.errors != e0) tb_error("panel timing wrong after a pixel reset while stopped");
      chk_img("pixel reset while stopped, start");

      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
