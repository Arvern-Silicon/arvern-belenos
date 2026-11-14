//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_reset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_reset.v
// Module Description : hresetn_i asserted while the DPI driver runs (with
//                      DPI_PCLK_SEP = 1 the bench asserts dpi_presetn_i with
//                      it, as the integration guide asks), at instants across
//                      a panel frame (active lines, the blanking while the
//                      next frame is taken), with settings other than their
//                      reset values (active-high syncs, a border, an
//                      explicit position, interrupts enabled). During the
//                      reset the panel outputs are idle at the reset
//                      polarities (DE low, syncs high, colour 0) with
//                      lcd_on_o low and lcd_reset_n_o high; after it every
//                      DPI register and the frame accounting read their
//                      reset values and irq_o is low. Programmed again, the
//                      driver gives exact frames without UNDERFLOW, the
//                      panel (and TMDS) timing without error.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT
`include "dpi_tasks.v"

localparam integer TR_N = 4;

reg     [31:0] v, f0;
integer        k, tf, t0, te0;

// Program and start the driver, wait for steady frames
task dpi_start;
   input integer seed;
   begin
      dpi_frame_fill(16, 8, seed);
      dpi_timing(dpi_div(1), 40, 3, 2, 6, 20, 2, 1, 2);
      reg_wr(DPI_BORDER, 32'h0013_5724);
      reg_wr(DPI_IMG_POS, (5 << 16) | 9);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_wr(DIF_IRQ_EN, 32'h18);                            // LINE, VBLANK
      reg_wr(IRQ_EN, 32'h0000_0107);                         // DIF, REFR_*, FRAME_CNT_DONE
      reg_wr(FRAME_CNT, 32'd100);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h0006_0009);                    // active-high HS and VS, LCD_ON, DPI_EN
      u_dpipanel.hs_high = 1'b1; u_dpipanel.vs_high = 1'b1;
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: hresetn while the driver runs     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      dpi_start(4);
      dpi_check_image(16, 8, 16, 8, 9, 5, 4096, 4096, 0, 24'h135724, "before the resets");

      // Frame period (free_clk cycles)
      t0 = 0;
      f0 = u_dpipanel.frames;
      while (u_dpipanel.frames == f0) begin @(posedge free_clk); t0 = t0 + 1; end
      f0 = u_dpipanel.frames;
      tf = 0;
      while (u_dpipanel.frames == f0) begin @(posedge free_clk); tf = tf + 1; end

      for (k = 0; k < TR_N; k = k + 1) begin
         f0 = u_dpipanel.frames;
         while (u_dpipanel.frames == f0) @(posedge free_clk);
         repeat ((tf * (2 * k + 1)) / (2 * TR_N)) @(posedge free_clk);
         $display("--- hresetn %0d/%0d of a frame after VSYNC, panel line %0d, frame being taken %0d",
                  2 * k + 1, 2 * TR_N, u_dpipanel.vline, dut.refresh_active);
         u_dpipanel.check = 1'b0;
         te0 = g_tmdsrx.u_tmdsrx.errors;
         @(negedge free_clk);
         hresetn = 1'b0;
         repeat (20) @(posedge free_clk);                    // a synchronous reset needs clock edges
         if ((dpi_de !== 1'b0) || (dpi_hs !== 1'b1) || (dpi_vs !== 1'b1) || (dpi_rgb !== 24'h0))
            tb_error("DPI outputs not idle during the reset");
         if ((lcd_on !== 1'b0) || (lcd_reset_n !== 1'b1)) tb_error("panel control pins not idle during the reset");
         if (irq !== 1'b0) tb_error("irq_o high during the reset");
         @(negedge free_clk);
         hresetn = 1'b1;
         repeat (5) @(posedge free_clk);
         u_dpipanel.hs_high = 1'b0; u_dpipanel.vs_high = 1'b0;

         // Reset values
         reg_rd(DIF_CFG,      32'h0);
         reg_rd(DIF_SYNC,     32'h0);
         reg_rd(DIF_STATUS,   32'h0);
         reg_rd(DIF_IRQ_EN,   32'h0);
         reg_rd(DIF_IRQ_FLAG, 32'h0);
         reg_rd(DPI_H_ACT,    32'h0);
         reg_rd(DPI_H_BLANK,  32'h0);
         reg_rd(DPI_V_ACT,    32'h0);
         reg_rd(DPI_V_BLANK,  32'h0);
         reg_rd(DPI_IMG_SIZE, 32'h0);
         reg_rd(DPI_IMG_POS,  32'h8000_0000);
         reg_rd(DPI_SCALE,    32'h0);
         reg_rd(DPI_BORDER,   32'h0);
         reg_rd(DPI_CTRL,     32'h0);
         reg_rd(DPI_FRAMES,   32'h0);
         if (HAS_DDC)    reg_rd(DPI_DDC,  32'h0000_0300);
         if (HAS_ISLAND) reg_rd(DPI_HDMI, 32'h0);
         reg_rd(STATUS,       32'h0);
         reg_rd(IRQ_EN,       32'h0);
         reg_rd(IRQ_FLAG,     32'h0);
         reg_rd(FRAME_CNT,    32'h0);
         reg_rd(FRAME_NUM,    32'h0);
         repeat (20) @(posedge free_clk);
         if ((dpi_de !== 1'b0) || (dpi_hs !== 1'b1) || (dpi_vs !== 1'b1) || (dpi_rgb !== 24'h0))
            tb_error("DPI outputs not idle after the reset");
         if (irq !== 1'b0) tb_error("irq_o high after the reset");

         // Programmed again: exact frames
         dpi_start(4 + k);
         reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);           // no UNDERFLOW
         reg_rd_mask(STATUS, 32'h0, 32'h10);                 // whole frames
         reg_rd_val(DPI_FRAMES, v);
         if (v < 4) tb_error("DPI_FRAMES does not count after the reset");
         if (HAS_TMDS && (g_tmdsrx.u_tmdsrx.errors != te0)) tb_error("TMDS stream wrong after the reset");
         dpi_check_image(16, 8, 16, 8, 9, 5, 4096, 4096, 0, 24'h135724, "after hresetn");
      end

      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      u_dpipanel.check = 1'b0;
      reg_wr(IRQ_EN, 32'h0);
      reg_wr(DIF_IRQ_EN, 32'h0);
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000 * PCLK_SLOW);
      u_dpipanel.hs_high = 1'b0; u_dpipanel.vs_high = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
