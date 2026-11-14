//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_regs
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_regs.v
// Module Description : DPI driver register window: reset values, write masks
//                      and read-back of every register (the staged ones read
//                      the staged copy), read-only STATUS / FRAMES / CAPS,
//                      FILTER writable only with DPI_SCALER = 2, IMG_SIZE and
//                      SCALE read 0 without a scaler, reserved offsets RAZ/WI,
//                      (DPI_DDC in dpi_ddc, DPI_HDMI in dpi_hdmi), UPDATE without effect while the driver is off, the
//                      LCD_ON / LCD_RESET pins, the DIF_IRQ_FLAG W1C.
//----------------------------------------------------------------------------

`include "dpi_tasks.v"

integer    k;
reg [31:0] caps_exp;
reg [31:0] filt;

initial
   begin
      $display(" ===============================================");
      $display("|             DPI: REGISTER WINDOW              |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      caps_exp = (DPI_LB_AW & 15) | ((DPI_SCALER & 3) << 4) | ((DPI_PCLK_SEP != 0) ? 32'h40 : 32'h0) |
                 (HAS_TMDS ? 32'h80 : 32'h0) | (HAS_DDC ? 32'h100 : 32'h0) | (HAS_ISLAND ? 32'h200 : 32'h0) |
                 (HAS_AUDIO ? 32'h400 : 32'h0);
      filt     = (DPI_SCALER == 2) ? 32'h0020_0000 : 32'h0;

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
      reg_rd(DPI_CAPS,     caps_exp);
      if ((lcd_on !== 1'b0) || (lcd_reset_n !== 1'b1)) tb_error("panel pins not idle at reset");

      // Write masks (DPI_EN left 0: nothing starts)
      reg_wr(DIF_CFG,      32'hFFFF_FFF7);
      reg_rd(DIF_CFG,      32'h001F_0F03 | filt);
      if ((lcd_on !== 1'b1) || (lcd_reset_n !== 1'b0)) tb_error("LCD_ON / LCD_RESET pins");
      reg_wr(DIF_SYNC,     32'hFFFF_FFFF);  reg_rd(DIF_SYNC,     32'h0000_1FFF);
      reg_wr(DPI_H_ACT,    32'hFFFF_FFFF);  reg_rd(DPI_H_ACT,    32'h0000_0FFF);
      reg_wr(DPI_H_BLANK,  32'hFFFF_FFFF);  reg_rd(DPI_H_BLANK,  32'h3FFF_FFFF);
      reg_wr(DPI_V_ACT,    32'hFFFF_FFFF);  reg_rd(DPI_V_ACT,    32'h0000_0FFF);
      reg_wr(DPI_V_BLANK,  32'hFFFF_FFFF);  reg_rd(DPI_V_BLANK,  32'h3FFF_FFFF);
      reg_wr(DPI_IMG_SIZE, 32'hFFFF_FFFF);  reg_rd(DPI_IMG_SIZE, (DPI_SCALER != 0) ? 32'h0FFF_0FFF : 32'h0);
      reg_wr(DPI_IMG_POS,  32'hFFFF_FFFF);  reg_rd(DPI_IMG_POS,  32'h8FFF_0FFF);
      reg_wr(DPI_IMG_POS,  32'h0123_0456);  reg_rd(DPI_IMG_POS,  32'h0123_0456);
      reg_wr(DPI_SCALE,    32'hFFFF_FFFF);  reg_rd(DPI_SCALE,    (DPI_SCALER != 0) ? 32'hFFFF_FFFF : 32'h0);
      reg_wr(DPI_BORDER,   32'hFFFF_FFFF);  reg_rd(DPI_BORDER,   32'h00FF_FFFF);
      reg_wr(DPI_CTRL,     32'hFFFF_FFFF);  reg_rd(DPI_CTRL,     32'h0000_0002);   // UPDATE: no effect while off
      reg_wr(DIF_IRQ_EN,   32'hFFFF_FFFF);  reg_rd(DIF_IRQ_EN,   32'h0000_0078);
      // Field placement
      reg_wr(DPI_H_BLANK,  32'h0080_4401);  reg_rd(DPI_H_BLANK,  32'h0080_4401);
      reg_wr(DPI_IMG_SIZE, 32'h0123_0456);  reg_rd(DPI_IMG_SIZE, (DPI_SCALER != 0) ? 32'h0123_0456 : 32'h0);
      reg_wr(DPI_SCALE,    32'h1234_5678);  reg_rd(DPI_SCALE,    (DPI_SCALER != 0) ? 32'h1234_5678 : 32'h0);

      // Read-only registers
      reg_wr(DIF_STATUS,   32'hFFFF_FFFF);  reg_rd(DIF_STATUS,   32'h0);
      reg_wr(DPI_FRAMES,   32'hFFFF_FFFF);  reg_rd(DPI_FRAMES,   32'h0);
      reg_wr(DPI_CAPS,     32'hFFFF_FFFF);  reg_rd(DPI_CAPS,     caps_exp);

      // Reserved offsets of the window
      for (k = 32'h188; k < 32'h194; k = k + 4) begin reg_wr(k, 32'hFFFF_FFFF); reg_rd(k, 32'h0); end
      // 0x1C8-0x1F8: reserved
      for (k = 32'h1C8; k < 32'h1FC; k = k + 4) begin reg_wr(k, 32'hFFFF_FFFF); reg_rd(k, 32'h0); end
      // HDMI page 0x200-0x27C: DPI_DDC, DPI_HDMI and the audio registers
      // 0x208-0x22C are covered by dpi_ddc, dpi_hdmi and dpi_audio in the builds
      // that have them; everything else reads 0
      for (k = 32'h200; k < 32'h280; k = k + 4)
         if (!((k == 32'h200) && HAS_DDC) && !((k == 32'h204) && HAS_ISLAND) && !((k >= 32'h208) && (k < 32'h230) && HAS_AUDIO)) begin
            reg_wr(k, 32'hFFFF_FFFF); reg_rd(k, 32'h0);
         end

      // DIF_IRQ_FLAG is W1C (nothing set while off)
      reg_wr(DIF_IRQ_FLAG, 32'hFFFF_FFFF);  reg_rd(DIF_IRQ_FLAG, 32'h0);

      // Back to reset values
      reg_wr(DIF_CFG, 32'h0);
      reg_rd(DIF_STATUS, 32'h0);
      if ((lcd_on !== 1'b0) || (lcd_reset_n !== 1'b1)) tb_error("panel pins not idle after clearing DIF_CFG");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
