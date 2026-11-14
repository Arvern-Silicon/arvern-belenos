//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_dbi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_dbi.v
// Module Description : Backend pixel stream through the shipped DBI driver
//                      (uarch §8 / §9, §0 RGB888 -> RGB565 truncation): manual
//                      refreshes (HW_WINDOW_EN = 0) of frames in every bpp,
//                      HW palettes and SW LUT, every DISP_CFG swap, non-
//                      aligned bases; the ILI9341 panel model's pixel log must
//                      equal the reference RGB888 stream truncated to RGB565,
//                      in scan order, with exactly W x H pixels and no
//                      protocol anomaly. 8080 PHY at CLK_DIV 0 and 1 (DIF_TYPE
//                      2 or 3), SPI PHY at CLK_DIV 0 (DIF_TYPE 1 or 3; with
//                      DIF_TYPE 3 both PHYs in turn via PHY_SEL). Skipped
//                      with DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    db_p, db_k, db_i, db_nerr, db_w, db_h, db_b;
reg  [2:0] db_mode, db_cfg;
reg [31:0] db_lut;
reg [15:0] db_got;
reg [64*8-1:0] db_tag;

task db_frame;
   input         spi;
   input  [64*8-1:0] tag;
   begin
      bk_config(0, db_b, db_mode, db_w, db_h, db_cfg, db_lut);
      if (spi) begin u_lcdspi.px_count = 0;  u_lcdspi.anomaly_count = 0;  end
      else     begin u_lcd8080.px_count = 0; u_lcd8080.anomaly_count = 0; end
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH,    32'h0000_0001, 32'h0000_0000, 20000);
      reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 2000);
      bkr_build(db_b, db_mode, db_w, db_h, db_cfg, db_lut);
      db_nerr = 0;
      if ((spi ? u_lcdspi.px_count : u_lcd8080.px_count) != bkr_n) begin
         $display("ERROR: %0s -- panel received %0d pixels / expected %0d %t", tag,
                  spi ? u_lcdspi.px_count : u_lcd8080.px_count, bkr_n, $time);
         error = error + 1;
      end
      if ((spi ? u_lcdspi.anomaly_count : u_lcd8080.anomaly_count) != 0)
         tb_error("panel model protocol anomaly");
      for (db_i = 0; db_i < bkr_n; db_i = db_i + 1) begin
         db_got = spi ? u_lcdspi.px_log[db_i] : u_lcd8080.px_log[db_i];
         if (db_got !== bkr_888to565(bkr_exp[db_i])) begin
            db_nerr = db_nerr + 1;
            if (db_nerr <= 8)
               $display("ERROR: %0s -- pixel %0d = 0x%h / expected 0x%h (RGB888 0x%h) %t", tag, db_i, db_got,
                        bkr_888to565(bkr_exp[db_i]), bkr_exp[db_i], $time);
         end
      end
      error = error + db_nerr;
      if (db_nerr == 0)
         $display("OK:    %0s -- %0d pixels", tag, bkr_n);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     BACKEND: STREAM THROUGH THE DBI DRIVER    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|      (needs a DBI PHY: DIF_TYPE 1, 2 or 3)    |");

      bk_vram_rand(0, 1024);
      bk_lut_rand;

      for (db_p = 0; db_p < 3; db_p = db_p + 1)
        // 0: 8080 CLK_DIV 0, 1: 8080 CLK_DIV 1, 2: SPI CLK_DIV 0
        if (((db_p < 2) && HAS_8080) || ((db_p == 2) && HAS_SPI)) begin
           reg_wr(DIF_CFG, ((db_p == 1) ? 32'h0000_0100 : 32'h0) | ((db_p == 2) ? 32'h4 : 32'h0) | 32'h1);
           for (db_k = 0; db_k < ((db_p == 2) ? 8 : 16); db_k = db_k + 1) begin
              db_mode = (db_k < 8) ? db_k[2:0] : db_k[2:0] & 3'd3;
              db_cfg  = db_k[2:0] ^ {db_k[3], 2'b00};
              db_lut  = (db_k >= 8) ? 32'h0000_0003 : 32'h0000_6D30;
              db_w    = (db_p == 2) ? 7 : 11 + db_k;
              db_h    = (db_p == 2) ? 3 : 5;
              db_b    = 1 + db_k;
              $sformat(db_tag, "%0s div %0d mode %0d %0s cfg %0d %0dx%0d",
                       (db_p == 2) ? "SPI" : "8080", (db_p == 1), db_mode, (db_k >= 8) ? "LUT" : "HW",
                       db_cfg, db_w, db_h);
              db_frame(db_p == 2, db_tag);
           end
        end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
