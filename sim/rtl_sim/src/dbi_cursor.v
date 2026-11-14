//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_cursor
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_cursor.v
// Module Description : Hardware cursor through the shipped DBI driver: manual
//                      refreshes (HW_WINDOW_EN = 0), the ILI9341 panel
//                      model's pixel log against the reference RGB888 stream
//                      (bk_ref.v, the cursor colours RGB888 truncated to
//                      RGB565 like every pixel):
//                        - 8080 (CLK_DIV 0) and SPI, every bpp and swap, the
//                          hardware tables and the SW LUT under the cursor,
//                          pixel doubling;
//                        - a windowed refresh: the frame pointer, DISP_SIZE
//                          and REFR_PITCH on a sub-rectangle of a larger
//                          frame, CURSOR_POS offset by the sub-rectangle's
//                          corner: the panel gets the sub-rectangle of the
//                          full frame with the cursor where it is on it; the
//                          same with the cursor outside the sub-rectangle;
//                          the cursor hidden (EN = 0).
//                      Skipped without a DBI PHY.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer DC_BLK = 768;

integer    dc_p, dc_k, dc_i, dc_nerr, dc_w, dc_h, dc_b, dc_x, dc_y;
reg  [2:0] dc_mode, dc_cfg;
reg [31:0] dc_lut;
reg [15:0] dc_got;
reg [64*8-1:0] dc_tag;

task dc_frame;
   input         spi;
   input  [64*8-1:0] tag;
   begin
      bk_config(0, dc_b, dc_mode, dc_w, dc_h, dc_cfg, dc_lut);
      if (spi) begin u_lcdspi.px_count = 0;  u_lcdspi.anomaly_count = 0;  end
      else     begin u_lcd8080.px_count = 0; u_lcd8080.anomaly_count = 0; end
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH,    32'h0000_0001, 32'h0000_0000, 40000);
      reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 2000);
      bkr_build(dc_b, dc_mode, dc_w, dc_h, dc_cfg, dc_lut);
      dc_nerr = 0;
      tb_checks = tb_checks + 1;
      if ((spi ? u_lcdspi.px_count : u_lcd8080.px_count) != bkr_n) begin
         $display("ERROR: %0s -- panel received %0d pixels / expected %0d %t", tag,
                  spi ? u_lcdspi.px_count : u_lcd8080.px_count, bkr_n, $time);
         error = error + 1;
      end
      if ((spi ? u_lcdspi.anomaly_count : u_lcd8080.anomaly_count) != 0)
         tb_error("panel model protocol anomaly");
      for (dc_i = 0; dc_i < bkr_n; dc_i = dc_i + 1) begin
         dc_got = spi ? u_lcdspi.px_log[dc_i] : u_lcd8080.px_log[dc_i];
         if (dc_got !== bkr_888to565(bkr_exp[dc_i])) begin
            dc_nerr = dc_nerr + 1;
            if (dc_nerr <= 8)
               $display("ERROR: %0s -- pixel %0d = 0x%h / expected 0x%h (RGB888 0x%h) %t", tag, dc_i, dc_got,
                        bkr_888to565(bkr_exp[dc_i]), bkr_exp[dc_i], $time);
         end
      end
      error = error + dc_nerr;
      if (dc_nerr == 0)
         $display("OK:    %0s -- %0d pixels, %0d under the cursor", tag, bkr_n, bkr_cur_n);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     HARDWARE CURSOR THROUGH THE DBI DRIVER    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|      (needs a DBI PHY: DIF_TYPE 1, 2 or 3)    |");

      bk_vram_rand(0, 768);
      bk_lut_rand;
      bk_cursor_shape(DC_BLK, 0);
      bk_cursor_cols(24'hF81F07, 24'h07E0F8, 24'hFFFFFF);

      for (dc_p = 0; dc_p < 2; dc_p = dc_p + 1)
        if (((dc_p == 0) && HAS_8080) || ((dc_p == 1) && HAS_SPI)) begin
           reg_wr(DIF_CFG, ((dc_p == 1) ? 32'h4 : 32'h0) | 32'h1);
           for (dc_k = 0; dc_k < ((dc_p == 1) ? 6 : 12); dc_k = dc_k + 1) begin
              dc_mode = (dc_k < 8) ? dc_k[2:0] : dc_k[1:0];
              dc_cfg  = dc_k[2:0] ^ {dc_k[3], 2'b00};
              dc_lut  = (dc_k >= 8) ? 32'h0000_0001 : 32'h0000_6D30;
              bkr_dbl = (dc_k == 5) || (dc_k == 10);
              dc_w    = (dc_p == 1) ? 20 : 34 + dc_k;
              dc_h    = (dc_p == 1) ? 9  : 12;
              dc_b    = 1 + dc_k;
              bk_cursor_set(1'b1, 3 + dc_k - 6, (dc_k % 3) - 4, dc_k % 4, 1, DC_BLK);
              $sformat(dc_tag, "%0s mode %0d %0s cfg %0d %0dx%0d%0s", (dc_p == 1) ? "SPI" : "8080", dc_mode,
                       (dc_k >= 8) ? "LUT" : "HW", dc_cfg, dc_w, dc_h, bkr_dbl ? " PIX_DOUBLE" : "");
              dc_frame(dc_p == 1, dc_tag);
           end
           bkr_dbl = 1'b0;

           // Windowed refresh: sub-rectangle (6, 4) 22x10 of a 50x30 8 bpp frame
           // at pixel 64; the cursor at (12, 7) of the full frame
           dc_mode = 3'd3; dc_cfg = 3'b000; dc_lut = 32'h0000_6D30;
           dc_w = 22; dc_h = 10; dc_b = 64 + 4*50 + 6;
           bkr_pitch = 50;
           reg_wr(REFR_PITCH, 32'd50);
           for (dc_k = 0; dc_k < 3; dc_k = dc_k + 1) begin
              dc_x = (dc_k == 1) ? 45 : 12;              // full-frame position (k = 1: outside the window)
              dc_y = (dc_k == 1) ? 25 : 7;
              bk_cursor_set(dc_k != 2, dc_x - 6, dc_y - 4, 2, 2, DC_BLK);
              $sformat(dc_tag, "%0s window (6,4) 22x10, cursor at (%0d,%0d)%0s", (dc_p == 1) ? "SPI" : "8080",
                       dc_x, dc_y, (dc_k == 2) ? " hidden" : "");
              dc_frame(dc_p == 1, dc_tag);
           end
           bkr_pitch = 0;
           reg_wr(REFR_PITCH, 32'd0);
        end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
