//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_refresh_dbi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_refresh_dbi.v
// Module Description : Refresh pacing and the global interrupt block with the
//                      shipped DBI driver (DIF_TYPE 2 or 3, 8080 PHY):
//                      - period mode with FRAME_CNT = 3: FRAME_CNT_DONE and
//                        irq_o once three refreshes are done, FRAME_CNT stays
//                        0 afterwards, START stays set (no self-clear in
//                        period mode), REFR_START / REFR_DONE set,
//                        STATUS.REFRESH_ACTIVE seen high during a frame, and
//                        the panel receives whole frames only;
//                      - bdi_refresh_trig_o carries the requests with the
//                        built-in driver: one-cycle pulses, PERIOD apart;
//                      - IRQ_FLAG.DIF follows the driver interrupt (TE edge
//                        with DIF_IRQ_EN.TE): not W1C, cleared through
//                        DIF_IRQ_FLAG; STATUS.DIF_BUSY with the TE IRQ armed;
//                      - manual refresh: one frame per START, START clears;
//                      - debug freeze with FREEZE_REFRESH: the timer stops
//                        (no request on bdi_refresh_trig_o), FRAME_CNT holds,
//                        a manual START is served, so is a request already
//                        waiting in the driver for TE; FRAME_NUM and
//                        REFR_START / REFR_DONE count the frames sent; after
//                        the resume FRAME_CNT counts again.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer RD_W = 4;
localparam integer RD_H = 2;

integer     d_i, d_k, d_px0, d_act, d_t0;
reg  [31:0] d_rd, d_fn;

initial
   begin
      $display(" ===============================================");
      $display("|      REGS: REFRESH PACING WITH DBI DRIVER     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_8080)
         tb_skip_finish("|       (DIF_TYPE has no 8080 PHY: 2 or 3)      |");

      for (d_i = 0; d_i < RD_W*RD_H/2; d_i = d_i + 1)
         vram_wr(4*d_i, ((32'h1000 + d_i*2 + 1) << 16) | (32'h1000 + d_i*2), SZ_W);
      reg_wr(CTRL,       {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE,  (RD_H << 16) | RD_W);
      reg_wr(DIF_CFG,    32'h0000_0001);            // LCD_ON, 8080, CLK_DIV 0, no HW window
      if (DIF_TYPE == 3) reg_wr(DIF_CFG, 32'h0000_0001);
      reg_wr(IRQ_FLAG,   32'h1F7);

      //------------------------------------------------------------------
      // Period mode with FRAME_CNT
      //------------------------------------------------------------------
      reg_wr(IRQ_EN,    32'h0000_0004);             // FRAME_CNT_DONE only
      reg_wr(FRAME_CNT, 32'd3);
      d_px0 = u_lcd8080.px_count;
      bm_trig_n = 0; bm_trig_wide = 0;
      reg_wr(REFRESH, (300 << 4) | 1);
      d_act = 0;
      d_k   = 0;
      while ((irq !== 1'b1) && (d_k < 4000)) begin
         reg_rd_val(STATUS, d_rd);
         if (d_rd[0]) d_act = 1;
         d_k = d_k + 1;
      end
      if (irq !== 1'b1) tb_error("FRAME_CNT_DONE interrupt never raised in period mode");
      reg_rd(FRAME_CNT, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h7, 32'h7);
      reg_rd(REFRESH, (300 << 4) | 1);             // period mode: START stays set
      if (!d_act) tb_error("STATUS.REFRESH_ACTIVE never seen high during period refreshes");
      if (u_lcd8080.px_count - d_px0 < 3*RD_W*RD_H) begin
         $display("ERROR: panel received %0d pixels after 3 refreshes / expected >= %0d %t",
                  u_lcd8080.px_count - d_px0, 3*RD_W*RD_H, $time);
         error = error + 1;
      end
      reg_wr(IRQ_FLAG, 32'h4);
      @(negedge free_clk);
      if (irq !== 1'b0) tb_error("irq_o still high after FRAME_CNT_DONE W1C");
      // more refreshes: FRAME_CNT stays 0, no new FRAME_CNT_DONE
      repeat (700) @(posedge free_clk);
      reg_rd(FRAME_CNT, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h4);
      reg_wr(REFRESH, 32'h0);
      reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 2000);
      repeat (20) @(posedge free_clk);
      if (((u_lcd8080.px_count - d_px0) % (RD_W*RD_H)) != 0) begin
         $display("ERROR: panel received %0d pixels: not whole %0dx%0d frames %t", u_lcd8080.px_count - d_px0, RD_W, RD_H, $time);
         error = error + 1;
      end
      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel protocol anomalies");
      // With a built-in driver bdi_refresh_trig_o still carries the
      // internal requests
      if (bm_trig_n < 3) begin
         $display("ERROR: %0d pulses on bdi_refresh_trig_o in period mode / expected 3 or more %t", bm_trig_n, $time);
         error = error + 1;
      end else begin
         for (d_i = 0; (d_i + 1 < bm_trig_n) && (d_i < 255); d_i = d_i + 1)
            if (bm_trig_cyc[d_i+1] - bm_trig_cyc[d_i] != 300) begin
               $display("ERROR: bdi_refresh_trig_o interval %0d / expected 300 %t", bm_trig_cyc[d_i+1] - bm_trig_cyc[d_i], $time);
               error = error + 1;
            end
         $display("OK:    %0d refresh triggers 300 cycles apart", bm_trig_n);
      end
      if (bm_trig_wide != 0) tb_error("bdi_refresh_trig_o pulse longer than one cycle");
      reg_wr(IRQ_FLAG, 32'h1F7);
      reg_wr(IRQ_EN,   32'h0);

      //------------------------------------------------------------------
      // Manual refresh through the driver
      //------------------------------------------------------------------
      d_px0 = u_lcd8080.px_count;
      reg_wr(REFRESH, 32'h1);
      reg_poll(REFRESH, 32'h1, 32'h0, 2000);
      reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 2000);
      repeat (300) @(posedge free_clk);
      if (u_lcd8080.px_count - d_px0 != RD_W*RD_H) begin
         $display("ERROR: manual refresh sent %0d pixels / expected %0d %t", u_lcd8080.px_count - d_px0, RD_W*RD_H, $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h3);
      reg_wr(IRQ_FLAG, 32'h1F7);

      //------------------------------------------------------------------
      // Debug freeze (FREEZE_REFRESH): timer and FRAME_CNT stop, frames sent
      // on request still count in FRAME_NUM and the REFR_* flags
      //------------------------------------------------------------------
      reg_wr(FRAME_CNT, 32'd5);
      reg_wr(DIF_SYNC, 32'h0001_0000);                // TE sync: the next request waits
      reg_wr(REFRESH, 32'h1);
      repeat (100) @(posedge free_clk);
      reg_rd_mask(DIF_STATUS, 32'h10, 32'h10);        // WAIT_SYNC
      reg_wr(DBG_CTRL, 32'h1);
      @(negedge free_clk); dbg_stoptime = 1'b1;
      repeat (4) @(posedge free_clk);
      reg_rd_val(FRAME_NUM, d_fn);
      reg_wr(IRQ_FLAG, 32'h1F7);
      d_px0 = u_lcd8080.px_count;
      // the request waiting in the driver is served
      @(posedge free_clk); lcd_te = 1'b1; repeat (6) @(posedge free_clk); lcd_te = 1'b0;
      reg_poll(REFRESH, 32'h1, 32'h0, 2000);
      reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 2000);
      if (u_lcd8080.px_count - d_px0 != RD_W*RD_H) tb_error("freeze: the request waiting for TE was not served");
      reg_rd(FRAME_NUM, (d_fn + 1) & 32'hFFFF);
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h7);            // REFR_START / REFR_DONE, no FRAME_CNT_DONE
      reg_rd(FRAME_CNT, 32'd5);
      // a manual START is served
      reg_wr(DIF_SYNC, 32'h0);
      reg_wr(IRQ_FLAG, 32'h1F7);
      reg_wr(REFRESH, 32'h1);
      reg_poll(REFRESH, 32'h1, 32'h0, 2000);
      reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 2000);
      if (u_lcd8080.px_count - d_px0 != 2*RD_W*RD_H) tb_error("freeze: a manual START was not served");
      reg_rd(FRAME_NUM, (d_fn + 2) & 32'hFFFF);
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h7);
      reg_rd(FRAME_CNT, 32'd5);
      // the timer does not run
      d_t0 = bm_trig_n;
      reg_wr(REFRESH, (300 << 4) | 1);
      repeat (1000) @(posedge free_clk);
      if (bm_trig_n != d_t0) tb_error("freeze: the refresh timer requested a frame");
      reg_rd(FRAME_CNT, 32'd5);
      // resume: requests and FRAME_CNT go on
      @(negedge free_clk); dbg_stoptime = 1'b0;
      d_k = 0;
      while ((bm_trig_n == d_t0) && (d_k < 2000)) begin @(posedge free_clk); d_k = d_k + 1; end
      if (bm_trig_n == d_t0) tb_error("resume: the refresh timer does not run again");
      reg_wr(REFRESH, 32'h0);
      reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 2000);
      repeat (20) @(posedge free_clk);
      reg_rd_val(FRAME_CNT, d_rd);
      if (d_rd >= 5) tb_error("resume: FRAME_CNT did not count the frames after the freeze");
      reg_wr(DBG_CTRL, 32'h0);
      reg_wr(FRAME_CNT, 32'd0);
      reg_wr(DIF_IRQ_FLAG, 32'h7);                    // the TE edge of the freeze part
      reg_wr(IRQ_FLAG, 32'h1F7);

      //------------------------------------------------------------------
      // DIF bit from the driver interrupt (TE)
      //------------------------------------------------------------------
      reg_rd_mask(STATUS, 32'h0, 32'h8);
      reg_wr(DIF_IRQ_EN, 32'h0000_0002);            // TE
      repeat (4) @(posedge free_clk);
      reg_rd_mask(STATUS, 32'h8, 32'h8);              // TE armed -> DIF_BUSY
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h100);
      @(posedge free_clk); lcd_te = 1'b1; repeat (6) @(posedge free_clk); lcd_te = 1'b0;
      repeat (6) @(posedge free_clk);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h2, 32'h2);
      reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
      @(negedge free_clk);
      if (irq !== 1'b0) tb_error("irq_o high with IRQ_EN.DIF = 0");
      reg_wr(IRQ_EN, 32'h100);
      @(negedge free_clk);
      if (irq !== 1'b1) tb_error("irq_o low with IRQ_FLAG.DIF and IRQ_EN.DIF");
      reg_wr(IRQ_FLAG, 32'h100);                      // not W1C
      reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
      reg_wr(DIF_IRQ_FLAG, 32'h2);                    // the source clears it
      repeat (3) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h100);
      @(negedge free_clk);
      if (irq !== 1'b0) tb_error("irq_o still high after DIF_IRQ_FLAG W1C");
      reg_wr(DIF_IRQ_EN, 32'h0);
      reg_wr(IRQ_EN, 32'h0);
      repeat (4) @(posedge free_clk);
      reg_rd_mask(STATUS, 32'h0, 32'h8);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
