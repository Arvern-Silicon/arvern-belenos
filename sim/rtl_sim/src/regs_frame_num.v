//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_frame_num
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_frame_num.v
// Module Description : FRAME_NUM (0x038): frames sent, +1 at each REFR_DONE,
//                      read only, 0 out of reset, independent of FRAME_CNT,
//                      equal to the falling edges of refresh_active counted
//                      by the bench; FRAME_CNT counting the same frames
//                      down to FRAME_CNT_DONE; FRAME_SEL [5:4] LATCHED: the
//                      index the refresh latched for the frame in progress
//                      (the new FRAME_SEL between frames, the old one until
//                      the end of a frame during which it was written). Frames
//                      driven by the bench on the BDI (DIF_TYPE = 0, every
//                      edge placed), sent by the DBI driver (DIF_TYPE 1-3,
//                      manual refreshes) or by the DPI driver (DIF_TYPE 4-5,
//                      free-running panel frames).
//----------------------------------------------------------------------------
`include "dpi_tasks.v"

integer     f_i, f_n, f_k, f_b;
reg  [31:0] f_rd, f_st;

// The bench's count of frame ends (refresh_active falling), from the release
// of the reset: before it the state is not one of the design's (random
// initial values in a Verilator run)
integer     f_ends = 0;
reg         f_act_q = 1'b0;
always @(posedge hclk) begin
   if (!model_on) begin
      f_ends  = 0;
      f_act_q = 1'b0;
   end else begin
      if ((dut.refresh_active === 1'b0) && f_act_q) f_ends = f_ends + 1;
      f_act_q = (dut.refresh_active === 1'b1);
   end
end

// FRAME_NUM against the bench's count (a frame may end during the read)
task f_chk_num;
   begin
      f_b = f_ends;
      reg_rd_val(FRAME_NUM, f_rd);
      if ((f_rd !== (f_b & 32'hFFFF)) && (f_rd !== (f_ends & 32'hFFFF)) && (f_rd !== ((f_ends - 1) & 32'hFFFF))) begin
         $display("ERROR: FRAME_NUM = %0d, %0d frame ends seen %t", f_rd, f_ends, $time);
         error = error + 1;
      end
   end
endtask

// One frame: bench-driven edges (DIF_TYPE 0), a manual DBI refresh, or the
// next DPI panel frame end
task f_frame;
   integer f0;
   begin
      if (DIF_TYPE == 0) begin
         @(posedge free_clk); bdi_refresh_active_drv = 1'b1;
         repeat (6) @(posedge free_clk);
         @(posedge free_clk); bdi_refresh_active_drv = 1'b0;
         repeat (4) @(posedge free_clk);
      end else if (HAS_DBI) begin
         reg_wr(REFRESH, 32'h1);
         reg_poll(REFRESH, 32'h1, 32'h0, 8000);
         reg_poll(STATUS, 32'h1, 32'h0, 8000);
      end else begin
         f0 = f_ends;
         while (f_ends == f0) @(posedge free_clk);
         repeat (4) @(posedge free_clk);
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   REGS: FRAME_NUM and the latched FRAME_SEL   |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE == 0)
         bdi_busy_drv = 1'b1;                   // keep the clock requested (ICG builds)
      else if (HAS_DBI) begin
         for (f_i = 0; f_i < 4; f_i = f_i + 1)
            vram_wr(4*f_i, 32'h1234_5678 ^ f_i, SZ_W);
         reg_wr(CTRL,      32'h4);              // 16 bpp
         reg_wr(DISP_SIZE, (2 << 16) | 4);
         reg_wr(DIF_CFG,   HAS_8080 ? 32'h0000_0001 : 32'h0000_0005);   // LCD_ON, 8080 (else SPI)
      end

      //------------------------------------------------------------------
      $display("--- FRAME_NUM: 0 out of reset, read only");
      reg_rd(FRAME_NUM, 32'h0);
      reg_wr(FRAME_NUM, 32'hFFFF_FFFF);
      reg_rd(FRAME_NUM, 32'h0);
      if (HAS_DPI) begin                        // a small panel, frames from now on
         dpi_frame_fill(16, 8, 3);
         dpi_timing(2, 40, 2, 3, 5, 20, 1, 2, 2);
         reg_rd_val(DIF_CFG, f_rd);
         reg_wr(DIF_CFG, f_rd | 32'h9);           // LCD_ON, DPI_EN
      end

      $display("--- FRAME_NUM: +1 per frame");
      reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
      for (f_i = 0; f_i < 5; f_i = f_i + 1) begin
         f_frame;
         f_chk_num;
      end
      reg_rd_mask(IRQ_FLAG, 32'h1, 32'h1);      // REFR_DONE
      if (f_ends < 5) tb_error("fewer than 5 frames seen");

      $display("--- FRAME_NUM next to a FRAME_CNT wait (non-exclusive)");
      reg_wr(IRQ_FLAG, 32'h4);
      reg_wr(FRAME_CNT, 32'd3);
      f_k = f_ends;
      for (f_i = 0; f_i < 3; f_i = f_i + 1) begin
         reg_rd_mask(IRQ_FLAG, 32'h0, 32'h4);   // no FRAME_CNT_DONE before the last
         f_frame;
         reg_rd(FRAME_CNT, 2 - f_i);            // every driver's frames count
      end
      reg_rd_mask(IRQ_FLAG, 32'h4, 32'h4);      // FRAME_CNT_DONE
      reg_wr(IRQ_FLAG, 32'h4);
      f_chk_num;
      reg_wr(FRAME_CNT, 32'd7);                 // FRAME_CNT written: FRAME_NUM unchanged
      f_chk_num;
      reg_wr(FRAME_CNT, 32'd0);
      if (f_ends - f_k < 3) tb_error("FRAME_NUM did not count the FRAME_CNT frames");

      //------------------------------------------------------------------
      if (FRAME_NR >= 2) begin
         $display("--- FRAME_SEL [5:4]: the index latched for the frame in progress");
         if (DIF_TYPE == 0) begin
            reg_wr(FRAME_SEL, 32'h1);           // between frames: taken at once
            reg_rd(FRAME_SEL, 32'h11);
            reg_wr(FRAME_SEL, 32'h0);
            reg_rd(FRAME_SEL, 32'h00);
            f_frame;
            reg_rd(FRAME_SEL, 32'h00);
            // written during a frame: the old index until the frame ends
            @(posedge free_clk); bdi_refresh_active_drv = 1'b1;
            repeat (4) @(posedge free_clk);
            reg_wr(FRAME_SEL, 32'h1);
            reg_rd(FRAME_SEL, 32'h01);
            repeat (10) @(posedge free_clk);
            reg_rd(FRAME_SEL, 32'h01);
            @(posedge free_clk); bdi_refresh_active_drv = 1'b0;
            repeat (4) @(posedge free_clk);
            reg_rd(FRAME_SEL, 32'h11);
            if (FRAME_NR == 4) begin
               @(posedge free_clk); bdi_refresh_active_drv = 1'b1;
               repeat (4) @(posedge free_clk);
               reg_wr(FRAME_SEL, 32'h3);
               reg_rd(FRAME_SEL, 32'h13);
               reg_wr(FRAME_SEL, 32'h2);
               reg_rd(FRAME_SEL, 32'h12);
               @(posedge free_clk); bdi_refresh_active_drv = 1'b0;
               repeat (4) @(posedge free_clk);
               reg_rd(FRAME_SEL, 32'h22);
            end
         end else begin
            if (HAS_DBI) begin
               reg_wr(FRAME_SEL, 32'h1);        // no frame in progress: taken at once
               reg_rd(FRAME_SEL, 32'h11);
               reg_wr(FRAME_SEL, 32'h0);
               reg_rd(FRAME_SEL, 32'h00);
               reg_wr(DISP_SIZE, (8 << 16) | 16);
               reg_wr(REFRESH, 32'h1);
            end
            // catch a frame in progress
            reg_poll(STATUS, 32'h1, 32'h1, 40000);
            reg_wr(FRAME_SEL, 32'h1);
            reg_rd_val(FRAME_SEL, f_rd);
            reg_rd_val(STATUS, f_st);
            if (f_st[0] && (f_rd !== 32'h01)) begin
               $display("ERROR: FRAME_SEL written during a frame reads 0x%h / expected 0x01 %t", f_rd, $time);
               error = error + 1;
            end
            if (HAS_DBI) begin
               reg_poll(REFRESH, 32'h1, 32'h0, 20000);
               reg_poll(STATUS, 32'h1, 32'h0, 20000);
            end else
               f_frame;
            reg_rd_mask(FRAME_SEL, 32'h11, 32'h33);
         end
         f_chk_num;
         reg_wr(FRAME_SEL, 32'h0);
      end

      if (HAS_DPI) begin
         reg_rd_val(DIF_CFG, f_rd);
         reg_wr(DIF_CFG, f_rd & ~32'h9);
      end
      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
