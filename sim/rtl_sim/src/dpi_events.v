//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_events
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_events.v
// Module Description : DPI driver signal options and events: active-high
//                      syncs, active-low data enable, falling sampling edge
//                      and BGR order (image checked with the panel model set
//                      to match), the test bars, enabling while an update is
//                      pending (UPDATE dropped, DPI_FRAMES restarts),
//                      stopping with an update pending (UPDATE reads 0 once
//                      stopped, staging accepted then, taken at the restart),
//                      vertical and horizontal porches of 0, UPDATE (with
//                      TEST) written at several delays after DPI_EN (during
//                      the start: no effect, UPDATE 0 once the driver runs;
//                      after it: taken with TEST at a frame start), no active
//                      line (V_ACT = 0: frames still start, UPDATE taken),
//                      the panel-detect filter (a short glitch gives no event, a
//                      stable change gives DETECT and PRESENT) and the driver
//                      interrupt reaching IRQ_FLAG.DIF and irq_o.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "dpi_tasks.v"

reg     [31:0] v;
integer        x, y, bad, k, nwin;
reg     [23:0] e;

initial
   begin
      $display(" ===============================================");
      $display("|               DPI: OPTIONS AND EVENTS         |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      dpi_frame_fill(16, 8, 11);
      dpi_timing(2, 40, 2, 3, 5, 20, 1, 2, 2);
      reg_rd_val(DIF_CFG, v);
      // HS and VS active high, DE active low, falling edge, BGR
      reg_wr(DIF_CFG, v | 32'h001F_0009);
      u_dpipanel.hs_high = 1'b1; u_dpipanel.vs_high = 1'b1; u_dpipanel.de_low = 1'b1; u_dpipanel.edge_fall = 1'b1;
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(3);
      bad = 0;
      for (y = 0; y < 20; y = y + 1)
         for (x = 0; x < 40; x = x + 1) begin
            e = dpi_expect(x, y, 16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0);
            if (u_dpipanel.fb[y*u_dpipanel.W_MAX + x] !== {e[7:0], e[15:8], e[23:16]}) bad = bad + 1;
         end
      if (bad != 0) tb_error("polarities / edge / BGR: image differs");
      else $display("OK:    active-high syncs, active-low DE, falling edge, BGR");
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");

      // Back to the default signalling, test bars (no timing check across the switch)
      u_dpipanel.check = 1'b0;
      reg_wr(DIF_CFG, 32'h0000_0209);
      reg_wr(DPI_CTRL, 32'h3);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);     // taken at the next frame start
      u_dpipanel.hs_high = 1'b0; u_dpipanel.vs_high = 1'b0; u_dpipanel.de_low = 1'b0; u_dpipanel.edge_fall = 1'b0;
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(1);
      bad = 0;
      for (y = 0; y < 20; y = y + 1)
         for (x = 0; x < 40; x = x + 1) begin
            case (x / 5)
              0: e = 24'hFFFFFF; 1: e = 24'hFFFF00; 2: e = 24'h00FFFF; 3: e = 24'h00FF00;
              4: e = 24'hFF00FF; 5: e = 24'hFF0000; 6: e = 24'h0000FF; default: e = 24'h000000;
            endcase
            if (u_dpipanel.fb[y*u_dpipanel.W_MAX + x] !== e) bad = bad + 1;
         end
      if (bad != 0) tb_error("test bars differ");
      else $display("OK:    test bars");
      reg_wr(DPI_CTRL, 32'h1);                                 // TEST off
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "frames again after the test bars");

      // Enable while an update is pending: the update is dropped
      reg_wr(DPI_BORDER, 32'h0011_2233);
      reg_wr(DPI_CTRL, 32'h1);
      u_dpipanel.check = 1'b0;                                 // the stop cuts a line
      reg_wr(DIF_CFG, 32'h0000_0201);                          // stop
      reg_wr(DIF_CFG, 32'h0000_0209);                          // and start again
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 50);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      reg_rd_val(DPI_FRAMES, v);
      if ((v < 2) || (v > 4)) tb_error("DPI_FRAMES not restarted by DPI_EN");
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h112233, "restart takes the staged values");

      // Stop with an update pending: UPDATE reads 1 until the pixel domain
      // has stopped (it may still take the update), then 0; staging is
      // accepted then, UPDATE written then has no effect; the restart takes
      // the staged values and a later UPDATE is taken normally
      reg_wr(DPI_BORDER, 32'h0044_5566);
      reg_wr(DPI_CTRL, 32'h1);
      reg_rd(DPI_CTRL, 32'h1);                                 // pending
      u_dpipanel.check = 1'b0;
      reg_wr(DIF_CFG, 32'h0000_0201);                          // stop
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 50 * PCLK_SLOW);        // abandoned once stopped
      reg_rd_mask(DIF_STATUS, 32'h0, 32'h1);                   // stopped by then
      reg_rd(DPI_CTRL, 32'h0);
      reg_wr(DPI_BORDER, 32'h0077_8899);                       // accepted while stopped
      reg_rd(DPI_BORDER, 32'h0077_8899);
      reg_wr(DPI_CTRL, 32'h1);                                 // no effect while stopped
      reg_rd(DPI_CTRL, 32'h0);
      reg_wr(DPI_BORDER, 32'h0012_3456);
      reg_rd(DPI_BORDER, 32'h0012_3456);
      reg_wr(DIF_CFG, 32'h0000_0209);                          // start again
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 50);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h123456, "stop with UPDATE pending, restart");
      reg_wr(DPI_BORDER, 32'h00AB_CDEF);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'hABCDEF, "UPDATE after the restart");

      // Vertical back porch of 0, then front porch of 0: VSYNC moves with the
      // HSYNC leading edge and never overlaps active pixels (panel model)
      u_dpipanel.check = 1'b0;
      dpi_timing(2, 40, 2, 3, 5, 20, 1, 2, 0);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b0;
      dpi_timing(2, 40, 2, 3, 5, 20, 0, 2, 2);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      // Horizontal front and back porches of 0: HSYNC right after the last
      // active pixel, the next line's first pixel right after HSYNC
      u_dpipanel.check = 1'b0;
      dpi_timing(2, 40, 0, 3, 0, 20, 1, 2, 2);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'hABCDEF, "horizontal porches of 0");

      // UPDATE with TEST written at several delays after DPI_EN: during the
      // start (until the driver runs) it has no effect at all (TEST not
      // staged), so UPDATE reads 0 as soon as the driver runs; after it, it
      // is an ordinary UPDATE, TEST taken at the next frame start
      u_dpipanel.check = 1'b0;
      nwin = 0;
      for (k = 0; k < 12; k = k + 1) begin
         reg_wr(DIF_CFG, 32'h0000_0201);                       // stop
         reg_poll(DIF_STATUS, 32'h1, 32'h0, 200 * PCLK_SLOW);
         reg_wr(DIF_CFG, 32'h0000_0209);                       // start
         repeat (k) @(posedge hclk);
         reg_wr(DPI_CTRL, 32'h3);
         reg_rd_val(DPI_CTRL, v);
         if (v[1] == 1'b0) begin                               // during the start: ignored
            nwin = nwin + 1;
            reg_poll(DPI_CTRL, 32'h1, 32'h0, 50 * PCLK_SLOW);
         end else begin                                        // after it: taken at a frame start
            reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
            reg_wr(DPI_CTRL, 32'h1);
            reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
         end
      end
      if (nwin == 0) tb_error("no UPDATE written during the start");
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'hABCDEF, "UPDATE written during the start");

      // No active line (V_ACT = 0): the frames still start, an UPDATE is taken
      u_dpipanel.check = 1'b0;
      reg_wr(DPI_V_ACT, 0);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      reg_wr(DPI_BORDER, 32'h0055_AA55);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);     // taken with no active line
      reg_rd_mask(DIF_STATUS, 32'h80, 32'h80);                 // VBLANK
      reg_wr(DPI_V_ACT, 20);
      reg_wr(DPI_BORDER, 32'h00AB_CDEF);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(1);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'hABCDEF, "frames again after V_ACT = 0");

      // Panel detect: PRESENT after 2^16 stable cycles, glitch filtered
      reg_wr(IRQ_EN, 32'h0000_0100);
      reg_wr(DIF_IRQ_EN, 32'h40);
      reg_poll(DIF_STATUS, 32'h100, 32'h100, 70000);           // > 2^16 cycles, whatever the frames took
      reg_rd_mask(DIF_IRQ_FLAG, 32'h40, 32'h40);
      if (irq !== 1'b1) tb_error("DETECT does not reach irq_o");
      reg_wr(DIF_IRQ_FLAG, 32'h40);
      dpi_detect = 1'b0; repeat (2000) @(posedge free_clk); dpi_detect = 1'b1;
      repeat (70000) @(posedge free_clk);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h40);
      reg_rd_mask(DIF_STATUS, 32'h100, 32'h100);
      dpi_detect = 1'b0;
      repeat (70000) @(posedge free_clk);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h40, 32'h40);
      reg_rd_mask(DIF_STATUS, 32'h0, 32'h100);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_wr(DIF_IRQ_EN, 32'h0);
      reg_wr(IRQ_EN, 32'h0);
      dpi_detect = 1'b1;

      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
