//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_underflow
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_underflow.v
// Module Description : DPI driver underflow, with its own pixel clock
//                      (DPI_PCLK_SEP = 1): a pixel clock too fast for the BDI
//                      stream at 1:1 shows the border colour where a line is
//                      late and raises UNDERFLOW (the frames go on, the
//                      panel timing stays right; a frame still being taken
//                      at the next frame start is abandoned, one whose image
//                      is past by then has its rest dropped and ends whole); with the pixel clock slowed down again
//                      the image is exact, whole frames are sent and no
//                      UNDERFLOW follows.
//----------------------------------------------------------------------------

`include "dpi_tasks.v"

reg     [31:0] v;
integer        x, y, nb;

initial
   begin
      $display(" ===============================================");
      $display("|               DPI: UNDERFLOW                  |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI || (DPI_PCLK_SEP == 0))
         tb_skip_finish("|   (needs the DPI driver with its own clock)   |");

      dpi_frame_fill(60, 8, 5);
      dpi_timing(0, 64, 1, 1, 1, 12, 1, 1, 1);
      reg_wr(DPI_BORDER, 32'h00FF_00FF);
      dpi_pclk_half = 1.3;                                     // about 4 pixels per hclk cycle
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_wr(DIF_CFG, 32'h0000_0009);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(4);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h20, 32'h20);               // UNDERFLOW
      nb = 0;
      for (y = 2; y < 10; y = y + 1)
         for (x = 2; x < 62; x = x + 1)
            if (u_dpipanel.fb[y*u_dpipanel.W_MAX + x] === 24'hFF00FF) nb = nb + 1;
      if (nb == 0) tb_error("no border pixel where the lines are late");
      else $display("OK:    UNDERFLOW, %0d late pixels shown in the border colour", nb);
      if (u_dpipanel.errors != 0) tb_error("panel timing wrong during underflow");

      // A pixel clock the stream keeps up with
      dpi_pclk_half = 40.0;
      dpi_wait_frames(3);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(2);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);
      reg_rd_mask(STATUS, 32'h0, 32'h10);                      // whole frames again
      dpi_check_image(60, 8, 60, 8, 2, 2, 4096, 4096, 0, 24'hFF00FF, "exact after the underflow");
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");

      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000);
      dpi_pclk_half = dpi_pclk_base;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
