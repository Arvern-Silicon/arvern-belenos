//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_dfill
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_dfill.v
// Module Description : DBI driver display fill (DIF_DFILL) on every PHY of the
//                      build: width x height pixels of the RGB888 colour
//                      truncated to RGB565, with HW_WINDOW_EN = 0 (0x2C
//                      only) and 1 (CASET 0..width-1, PASET 0..height-1
//                      first; SPI: three CS frames), sizes 5x3, 2x300 (PASET
//                      high byte), 320x2 and 2x320 (CASET and PASET end 319)
//                      and DISP_SIZE 0 (= 1x1), CLK_DIV 0/1/3 on
//                      8080 (pixel period exactly 2(CLK_DIV+1), i.e. 2 cycles
//                      at 0) and 0/1 on SPI (no bubble between pixel bytes).
//                      CMD_DONE rises only after the last CS release with
//                      every pixel delivered; DFILL_BUSY while it runs; the
//                      panel frame memory holds the colour in the window.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    phy_i, case_i, kk, xx, yy, mark, w, h, nbad;
reg        phy, hw;
reg  [3:0] div;
reg [23:0] col;
reg        cs_at_irq;
integer    items_at_irq;

task run_dfill;
   input integer wi;
   input integer hi;
   input [31:0]  size_reg;
   input [23:0]  rgb;
   input         hwin;
   input [3:0]   dv;
   integer       nn;
   begin
      $display("INFO:  PHY %0s DFILL %0dx%0d colour 0x%h HW_WINDOW_EN %0d CLK_DIV %0d",
               (phy == PHY_8080) ? "8080" : "SPI", wi, hi, rgb, hwin, dv);
      dif_cfg(phy, dv, hwin, 1'b1, 1'b0);
      reg_wr(DISP_SIZE, size_reg);
      reg_wr(DIF_IRQ_FLAG, 32'h7);
      reg_wr(IRQ_FLAG, 32'h3);
      mark = lg_n; exp_reset;
      exp_dfill(phy, wi, hi, rgb, hwin);
      reg_wr(DIF_DFILL, {8'hA5, rgb});              // bits [31:24] ignored
      reg_rd_mask(DIF_STATUS, ST_BUSY | ST_DFILL_BUSY, ST_BUSY | ST_DFILL_BUSY | ST_DFILL_PEND | ST_CMD_PEND);
      reg_rd_mask(STATUS, 32'h0, 32'h1);              // a DFILL is not a refresh
      reg_rd(DIF_IRQ_FLAG, 32'h0);
      nn = 0;
      while ((irq !== 1'b1) && (nn < 200000)) begin
         @(negedge free_clk);
         nn = nn + 1;
      end
      items_at_irq = lg_n;
      cs_at_irq    = (phy == PHY_8080) ? lcd_cs_n : spi_cs_n;
      if (irq !== 1'b1)            tb_error("CMD_DONE (irq_o) never rose after the DFILL");
      if (cs_at_irq !== 1'b1)      tb_error("CMD_DONE raised while CS still low");
      if (items_at_irq - mark != ex_n) begin
         $display("ERROR: CMD_DONE raised after %0d / %0d items %t", items_at_irq - mark, ex_n, $time);
         error = error + 1;
      end
      reg_rd(DIF_IRQ_FLAG, 32'h1);
      reg_rd_mask(DIF_STATUS, 32'h0, ST_BUSY | ST_DFILL_BUSY | ST_DFILL_PEND);
      reg_wr(DIF_IRQ_FLAG, 32'h1);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h3);            // no REFR_START / REFR_DONE
      dbi_check_log(mark, "DFILL items");
      if (hwin) begin
         // panel memory: the window holds the colour
         nbad = 0;
         for (yy = 0; yy < hi; yy = yy + 1)
           for (xx = 0; xx < wi; xx = xx + 1)
             if (((phy == PHY_8080) ? u_lcd8080.fb[yy*u_lcd8080.W + xx] : u_lcdspi.fb[yy*u_lcdspi.W + xx]) !== rgb565(rgb))
               nbad = nbad + 1;
         if (nbad != 0) begin
            $display("ERROR: %0d panel pixels of the %0dx%0d window differ from 0x%h %t", nbad, wi, hi, rgb565(rgb), $time);
            error = error + 1;
         end
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|              DBI: DISPLAY FILL                |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(IRQ_EN,     32'h0000_0100);
      reg_wr(DIF_IRQ_EN, 32'h0000_0001);

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            run_dfill(5, 3,   (3 << 16) | 5,    24'hFF_07_F8, 1'b0, 4'd0);
            run_dfill(5, 3,   (3 << 16) | 5,    24'h0F_FC_03, 1'b1, 4'd0);
            run_dfill(2, 300, (300 << 16) | 2,  24'h84_82_81, 1'b1, 4'd0);
            run_dfill(320, 2, (2 << 16) | 320,  24'h3C_C3_5A, 1'b1, 4'd0);   // CASET end 319
            run_dfill(2, 320, (320 << 16) | 2,  24'hA5_5A_C3, 1'b1, 4'd0);
            run_dfill(1, 1,   32'h0000_0000,    24'h7B_DE_EF, 1'b1, 4'd0);   // 0 -> 1
            run_dfill(4, 3,   (3 << 16) | 4,    24'h55_AA_33, 1'b1, 4'd1);
            if (phy == PHY_8080)
              run_dfill(3, 3, (3 << 16) | 3,    24'hC6_39_9C, 1'b1, 4'd3);
         end
      end

      if (HAS_8080 && (m8_px_pairs == 0)) tb_error("8080 pixel-period check never exercised");
      if (HAS_SPI  && (ms_px_bounds == 0)) tb_error("SPI pixel-byte check never exercised");
      $display("INFO:  pixel-rate checks: %0d 8080 pixel pairs, %0d SPI pixel-byte boundaries", m8_px_pairs, ms_px_bounds);
      if (m8_px_gap_bad != 0) tb_error("8080: pixel period != 2(CLK_DIV+1) inside a DFILL");
      if (ms_px_gap_bad != 0) tb_error("SPI: bubble between DFILL pixel bytes");
      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
