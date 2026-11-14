//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_frame
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_frame.v
// Module Description : DPI driver frames, 1:1: a 16 x 8 frame at 16 bpp on a
//                      40 x 20 panel, checked pixel by pixel against the
//                      frame Belenos sent (BDI stream) and timed by the panel
//                      model: centred on the border colour, a new border
//                      through UPDATE (a write while it is pending is
//                      ignored), an explicit position cropped by the
//                      active area, a transposed frame (CL_SWAP), a frame
//                      taller than the active area cut at its bottom (both
//                      crops: the rest of the frame taken and dropped, no
//                      UNDERFLOW, no REFR_ABANDONED), the SCANLINE and
//                      VBLANK flags, no UNDERFLOW, DPI_FRAMES, BUSY and
//                      REFRESH_BUSY, and the stop (outputs idle).
//----------------------------------------------------------------------------

`include "dpi_tasks.v"

reg [31:0] v;

initial
   begin
      $display(" ===============================================");
      $display("|               DPI: FRAMES 1:1                 |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      dpi_frame_fill(16, 8, 7);
      dpi_timing(1, 40, 3, 2, 6, 20, 2, 1, 2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(3);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "1:1 centred");
      reg_rd_mask(DIF_STATUS, 32'h1, 32'h1);                 // BUSY
      reg_rd_val(DPI_FRAMES, v);
      if (v < 3) tb_error("DPI_FRAMES does not count the panel frames");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h08, 32'h28);             // VBLANK, no UNDERFLOW

      // Border colour (staged, taken with UPDATE)
      reg_wr(DPI_BORDER, 32'h00A5_5A3C);
      dpi_wait_frames(1);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "border staged, not yet taken");
      reg_wr(DPI_CTRL, 32'h1);
      reg_rd_mask(DPI_CTRL, 32'h1, 32'h1);                   // UPDATE pending
      reg_wr(DPI_BORDER, 32'h0012_3456);                     // ignored while pending
      reg_rd(DPI_BORDER, 32'h00A5_5A3C);
      dpi_wait_frames(2);
      reg_rd_mask(DPI_CTRL, 32'h0, 32'h1);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'hA55A3C, "border through UPDATE");

      // Explicit position, cropped on the right and at the bottom
      reg_wr(DPI_IMG_POS, (15 << 16) | 30);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 30, 15, 4096, 4096, 0, 24'hA55A3C, "explicit position, cropped");
      // The image reaches the bottom of the active area: the frame's last
      // lines are not shown, taken and dropped, the frame not abandoned
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(2);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h08, 32'h28);             // VBLANK, no UNDERFLOW
      reg_rd_mask(STATUS, 32'h00, 32'h10);                   // no REFR_ABANDONED
      reg_wr(DPI_IMG_POS, 32'h8000_0000);

      // SCANLINE flag
      reg_wr(DIF_SYNC, 5);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(1);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h18, 32'h38);             // LINE and VBLANK, no UNDERFLOW
      reg_wr(DIF_IRQ_FLAG, 32'h10);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h10);

      // Transposed frame: the stream's lines are the frame's columns
      reg_wr(DISP_CFG, 32'h1);
      reg_wr(DPI_CTRL, 32'h1);
      dpi_wait_frames(4);
      dpi_check_image(8, 16, 8, 16, 16, 2, 4096, 4096, 0, 24'hA55A3C, "CL_SWAP, transposed");
      reg_wr(DISP_CFG, 32'h0);

      // A frame taller than the active area, centred: cut to the active
      // height from its top, the lines below taken and dropped
      dpi_frame_fill(16, 24, 3);
      dpi_wait_frames(3);
      dpi_check_image(16, 24, 16, 20, 12, 0, 4096, 4096, 0, 24'hA55A3C, "taller frame, cut at the bottom");
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(2);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h08, 32'h28);             // VBLANK, no UNDERFLOW
      reg_rd_mask(STATUS, 32'h00, 32'h10);                   // no REFR_ABANDONED

      // Stop: outputs idle, BUSY falls
      u_dpipanel.check = 1'b0;
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 200);
      repeat (20) @(posedge free_clk);
      if ((dpi_de !== 1'b0) || (dpi_hs !== 1'b1) || (dpi_vs !== 1'b1) || (dpi_rgb !== 24'h0))
         tb_error("DPI outputs not idle after the stop");
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
