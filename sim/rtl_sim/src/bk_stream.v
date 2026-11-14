//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_stream
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_stream.v
// Module Description : BDI pixel-stream protocol, DIF_TYPE = 0:
//                        - back-pressure: random ready at 10/50/90 % low and
//                          bursty ready (gaps up to 30 cycles), over 16 bpp,
//                          1 bpp CL swap and 8 bpp SW-LUT frames: exact data,
//                          exactly W x H handshakes, px_last on the final one;
//                        - px_valid low while refresh_active is low and in the
//                          cycle it falls, and low after the last pixel while
//                          the driver keeps active high (BDI model checks);
//                        - STATUS.REFRESH_ACTIVE and IRQ_FLAG REFR_START /
//                          REFR_DONE follow the refresh_active edges;
//                        - abort: the driver drops active mid-frame (after N
//                          pixels, or with ready held low and the FIFO full);
//                          the next frame is complete and exact; the aborted
//                          frame raises REFR_DONE, decrements FRAME_CNT,
//                          counts in FRAME_NUM and sets STATUS.REFR_ABANDONED,
//                          which the next whole frame clears;
//                        - at most 8 pixels in flight: 16 bpp CL swap with
//                          the driver stalled from the rise, 1..8 VRAM reads;
//                        - back-to-back frames from the REFRESH period timer;
//                        - bdi_refresh_trig_o one cycle wide (BDI model).
//                      Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    st_i, st_k, st_nf, st_fn;
reg [31:0] st_rd;
reg [64*8-1:0] st_tag;

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: BDI STREAM PROTOCOL           |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en = 1'b1;
      bk_vram_rand(0, 2048);
      bk_lut_rand;

      // Back-pressure patterns
      for (st_k = 0; st_k < 4; st_k = st_k + 1) begin
         bkm_rdy_mode    = (st_k == 3) ? 2 : 1;
         bkm_rdy_pct_low = (st_k == 0) ? 10 : (st_k == 1) ? 50 : 90;
         bkm_rdy_gap     = 30;
         bkm_end_delay   = 10 * st_k;
         $sformat(st_tag, "back-pressure %0d: 16 bpp 20x10", st_k);
         bk_frame(st_tag, 0, 11, 3'd4, 20, 10, 3'b000, 32'h0000_F000);
         $sformat(st_tag, "back-pressure %0d: 1 bpp 33x7 CL+X", st_k);
         bk_frame(st_tag, 0, 5, 3'd0, 33, 7, 3'b101, 32'h0000_C300);
         $sformat(st_tag, "back-pressure %0d: 8 bpp SW LUT 13x9 Y", st_k);
         bk_frame(st_tag, 0, 9, 3'd3, 13, 9, 3'b010, 32'h0000_0003);
      end
      bkm_rdy_mode  = 1;
      bkm_rdy_pct_low = 30;
      bkm_end_delay = 1;

      // STATUS / IRQ_FLAG around a held frame
      reg_wr(IRQ_FLAG, 32'h0000_0003);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h0000_0003);
      bk_config(0, 64, 3'd2, 10, 4, 3'b000, 32'h0000_F000);
      bkm_hold  = 1'b1;
      bkm_exp_n = 40;
      st_nf     = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bkm_wait_active(500);
      repeat(30) @(posedge free_clk);
      reg_rd_mask(STATUS,   32'h0000_0001, 32'h0000_0001);
      reg_rd_mask(IRQ_FLAG, 32'h0000_0002, 32'h0000_0003);   // REFR_START only
      if (bkm_n != 0) tb_error("pixels taken while ready held low");
      bkm_hold = 1'b0;
      bkm_wait_frames(st_nf + 1, 5000);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      reg_rd_mask(STATUS,   32'h0000_0000, 32'h0000_0001);
      reg_rd_mask(IRQ_FLAG, 32'h0000_0003, 32'h0000_0003);
      reg_wr(IRQ_FLAG, 32'h0000_0003);
      bkr_build(64, 3'd2, 10, 4, 3'b000, 32'h0000_F000);
      bkr_check_bdi("held frame");

      // At most 8 pixels in flight: 16 bpp CL swap (one VRAM
      // read per pixel), ready held low from before the rise
      for (st_k = 0; st_k < 2; st_k = st_k + 1) begin
         bk_config(0, 4 + st_k, 3'd4, 12, 10, st_k ? 3'b111 : 3'b001, 32'h0000_F000);
         bkm_hold  = 1'b1;
         bkm_exp_n = 120;
         st_nf     = bkm_frames;
         reg_wr(REFRESH, 32'h0000_0001);
         bkm_wait_active(500);
         repeat(60) @(posedge free_clk);
         if ((bkm_vreads < 1) || (bkm_vreads > 8)) begin
            $display("ERROR: %0d VRAM reads with the driver stalled from the start (1..8 pixels may be in flight) %t", bkm_vreads, $time);
            error = error + 1;
         end else
            $display("OK:    %0d pixels fetched ahead with the driver stalled", bkm_vreads);
         bkm_hold = 1'b0;
         bkm_wait_frames(st_nf + 1, 5000);
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
         bkr_build(4 + st_k, 3'd4, 12, 10, st_k ? 3'b111 : 3'b001, 32'h0000_F000);
         bkr_check_bdi("frame after the in-flight check");
         if (bkm_vreads != bkr_runs) begin
            $display("ERROR: %0d VRAM reads for the frame / expected %0d %t", bkm_vreads, bkr_runs, $time);
            error = error + 1;
         end
      end

      // Abort after N pixels, then a complete frame
      for (st_i = 0; st_i < 6; st_i = st_i + 1) begin
         bk_config(0, 3 + st_i, (st_i < 3) ? 3'd4 : 3'd1, 17, 6, st_i[2:0], 32'h0000_5410);
         bkm_rdy_mode = (st_i[0]) ? 0 : 1;
         bkm_abort_at = 1 + 13 * st_i;
         bkm_exp_n    = 0;
         st_nf        = bkm_frames;
         reg_rd_val(FRAME_NUM, st_rd);
         st_fn        = st_rd;
         reg_wr(FRAME_CNT, 32'd2);
         reg_wr(IRQ_FLAG, 32'h0000_0007);
         reg_wr(REFRESH, 32'h0000_0001);
         bkm_wait_frames(st_nf + 1, 5000);
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
         if (bkm_n != bkm_abort_at) begin
            $display("ERROR: abort after %0d pixels: %0d taken %t", bkm_abort_at, bkm_n, $time);
            error = error + 1;
         end
         // the aborted frame: REFR_DONE, counted, REFR_ABANDONED
         reg_rd_mask(STATUS, 32'h0000_0010, 32'h0000_0011);
         reg_rd_mask(IRQ_FLAG, 32'h0000_0003, 32'h0000_0007);
         reg_rd(FRAME_CNT, 32'd1);
         reg_rd(FRAME_NUM, (st_fn + 1) & 32'hFFFF);
         bkm_abort_at = 0;
         repeat(st_i) @(posedge free_clk);
         $sformat(st_tag, "frame after abort at pixel %0d", 1 + 13 * st_i);
         bk_frame(st_tag, 0, 3 + st_i, (st_i < 3) ? 3'd4 : 3'd1, 17, 6, st_i[2:0], 32'h0000_5410);
         // the next whole frame clears REFR_ABANDONED and counts
         reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0011);
         reg_rd(FRAME_CNT, 32'd0);
         reg_rd_mask(IRQ_FLAG, 32'h0000_0004, 32'h0000_0004);
         reg_rd(FRAME_NUM, (st_fn + 2) & 32'hFFFF);
         reg_wr(IRQ_FLAG, 32'h0000_0007);
      end

      // Abort with ready held low (FIFO full, fetch stalled), then a frame
      bk_config(0, 0, 3'd4, 30, 8, 3'b001, 32'h0000_F000);
      bkm_rdy_mode = 1;
      bkm_exp_n    = 0;
      st_nf        = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bkm_wait_pixels(7, 2000);
      bkm_hold = 1'b1;
      repeat(40) @(posedge free_clk);
      bkm_drop;
      bkm_wait_frames(st_nf + 1, 100);
      bkm_hold = 1'b0;
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      reg_rd_mask(STATUS, 32'h0000_0010, 32'h0000_0011);
      bk_frame("frame after a held abort", 0, 0, 3'd4, 30, 8, 3'b001, 32'h0000_F000);
      reg_rd_mask(STATUS, 32'h0000_0000, 32'h0000_0011);
      reg_wr(IRQ_FLAG, 32'h0000_0003);

      // Back-to-back frames from the period timer (no gap after DONE)
      bk_config(0, 77, 3'd2, 9, 7, 3'b010, 32'h0000_F000);
      bkm_rdy_mode    = 0;
      bkm_start_delay = 0;
      bkm_end_delay   = 0;
      bkm_exp_n       = 63;
      st_nf           = bkm_frames;
      bkr_build(77, 3'd2, 9, 7, 3'b010, 32'h0000_F000);
      reg_wr(REFRESH, 32'h0000_0010 * 120 | 32'h1);           // PERIOD 120, START
      for (st_i = 1; st_i <= 6; st_i = st_i + 1) begin
         bkm_wait_frames(st_nf + st_i, 2000);
         $sformat(st_tag, "periodic frame %0d", st_i);
         bkr_check_bdi(st_tag);
      end
      reg_wr(REFRESH, 32'h0000_0000);
      repeat(300) @(posedge free_clk);
      bkm_start_delay = 2;
      bkm_end_delay   = 1;

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
