//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_cursor_bw
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_cursor_bw.v
// Module Description : Hardware cursor reads against the refresh deadlines, on
//                      the BDI pixel stream (DIF_TYPE = 0), ready held at 1
//                      (the stream at one pixel per cycle):
//                        - scan lines long enough for the two cursor reads
//                          between two cursor lines (16 bpp, 100 pixels): no
//                          bubble;
//                        - short scan lines (36 and 33 pixels, the cursor
//                          almost the whole line) and CL swap at 16 bpp (a
//                          read per pixel): the stream stalls, never a wrong
//                          pixel; the bubbles per cursor line stay within the
//                          two reads, the decision cycle and the read latency;
//                        - the frame's first pixel under the cursor: offered
//                          at most 2 cycles after the BDI contract (DIM_W + 4
//                          cycles plus the read latency);
//                        - the VRAM window and the GPU at full rate during a
//                          cursor frame: exact frame, window traffic served,
//                          the cursor reads turn urgent (counted).
//                      The VRAM reads of every frame are checked as in
//                      bk_cursor_basic.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer CW_BLK   = 4096;
localparam integer CW_GDST  = 16384;      // GPU fill (16 bpp pixel address: word 8192)
localparam integer CW_WIN   = 12000;      // window traffic words
localparam integer CW_LAT   = DIM_W + 4 + VRAM_RD_LAT + VRAM_RD_REG_EN;   // the BDI first-pixel contract
localparam  [15:0] CW_PITCH = 64;
localparam  [13:0] CW_FW    = 64;
localparam  [13:0] CW_FH    = 60;

integer    cw_k, cw_i, cw_bub, cw_lat, cw_nf, cw_nwin, cw_urg, cw_cgnt, cw_w, cw_h;
reg  [2:0] cw_cfg;
reg [31:0] cw_v, cw_rd;
reg [64*8-1:0] cw_tag;

// Urgent grants of the cursor's reads (the backend slot with its tag)
always @(posedge hclk)
   if ((CURSOR_EN != 0) && (dut.u_core.v_gnt[VRQ_BK] === 1'b1) && (dut.u_core.v_tag[VRQ_BK] === 1'b1)) begin
      cw_cgnt = cw_cgnt + 1;
      if (dut.u_core.v_urgent[VRQ_BK] === 1'b1) cw_urg = cw_urg + 1;
   end

// Bubbles of the last frame (ready held at 1)
task cw_bubbles;
   begin
      cw_bub = 0;
      for (cw_i = 1; (cw_i < bkm_n) && (cw_i < BKM_LOG); cw_i = cw_i + 1)
         if (bkm_cyc[cw_i] != bkm_cyc[cw_i-1] + 1) cw_bub = cw_bub + bkm_cyc[cw_i] - bkm_cyc[cw_i-1] - 1;
      cw_lat = bkm_cyc[0] - bkm_rise_cyc;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     HARDWARE CURSOR: BANDWIDTH, DEADLINES     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      cw_urg = 0; cw_cgnt = 0;
      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 0;
      bk_vram_rand(0, 4096);
      bk_cursor_shape(CW_BLK, 0);
      bk_cursor_cols(24'hFFFFFF, 24'h000000, 24'hFF00FF);

      //------------------------------------------------------------------
      // Long lines: no bubble
      //------------------------------------------------------------------
      for (cw_k = 0; cw_k < 4; cw_k = cw_k + 1) begin
         cw_cfg = cw_k[1:0] << 1;                           // the X / Y swaps
         bk_cursor_set(1'b1, 30, 3, 0, 0, CW_BLK);
         $sformat(cw_tag, "100x40 16 bpp cfg %0d", cw_cfg);
         bk_frame(cw_tag, 0, 0, 3'd4, 100, 40, cw_cfg, 32'h0000_F000);
         cw_bubbles;
         if (cw_bub != 0) begin
            $display("ERROR: %0s -- %0d bubbles with the cursor reads between long lines %t", cw_tag, cw_bub, $time);
            error = error + 1;
         end
      end

      //------------------------------------------------------------------
      // Short lines and CL swap: stalls only
      //------------------------------------------------------------------
      for (cw_k = 0; cw_k < 6; cw_k = cw_k + 1) begin
         case (cw_k)
           0 : begin cw_w = 36; cw_h = 40; cw_cfg = 3'b000; bk_cursor_set(1'b1, 2, 3, 0, 0, CW_BLK); end
           1 : begin cw_w = 33; cw_h = 40; cw_cfg = 3'b100; bk_cursor_set(1'b1, 0, 0, 0, 0, CW_BLK); end
           2 : begin cw_w = 20; cw_h = 40; cw_cfg = 3'b000; bk_cursor_set(1'b1, -6, 1, 0, 0, CW_BLK); end
           3 : begin cw_w = 40; cw_h = 50; cw_cfg = 3'b001; bk_cursor_set(1'b1, 5, 9, 0, 0, CW_BLK); end
           4 : begin cw_w = 40; cw_h = 34; cw_cfg = 3'b111; bk_cursor_set(1'b1, 3, 1, 0, 0, CW_BLK); end
           default : begin cw_w = 60; cw_h = 32; cw_cfg = 3'b011; bk_cursor_set(1'b1, 50, -10, 0, 0, CW_BLK); end
         endcase
         $sformat(cw_tag, "%0dx%0d 16 bpp cfg %0d", cw_w, cw_h, cw_cfg);
         bk_frame(cw_tag, 0, 0, 3'd4, cw_w, cw_h, cw_cfg, 32'h0000_F000);
         cw_bubbles;
         $display("INFO:  %0s -- %0d bubbles, first pixel after %0d cycles", cw_tag, cw_bub, cw_lat);
         if (cw_bub > 32 * (6 + VRAM_RD_LAT + VRAM_RD_REG_EN)) begin
            $display("ERROR: %0s -- %0d bubbles, more than the cursor reads explain %t", cw_tag, cw_bub, $time);
            error = error + 1;
         end
      end

      //------------------------------------------------------------------
      // The frame's first pixel under the cursor
      //------------------------------------------------------------------
      for (cw_k = 0; cw_k < 8; cw_k = cw_k + 1) begin
         bk_cursor_set(1'b1, (cw_k[2] ? 20 : 0), (cw_k[1] ? 20 : 0), 0, 0, CW_BLK);
         $sformat(cw_tag, "first pixel, cfg %0d", cw_k);
         bk_frame(cw_tag, 0, 0, 3'd4, 21, 21, cw_k[2:0], 32'h0000_F000);
         cw_bubbles;
         if (cw_lat > CW_LAT + 2) begin
            $display("ERROR: %0s -- first pixel %0d cycles after the rise, more than %0d %t", cw_tag, cw_lat, CW_LAT + 2, $time);
            error = error + 1;
         end
      end
      bk_cursor_set(1'b1, 40, 40, 0, 0, CW_BLK);
      bk_frame("first pixel, cursor elsewhere", 0, 0, 3'd4, 100, 60, 3'b000, 32'h0000_F000);
      cw_bubbles;
      if (cw_lat > CW_LAT) begin
         $display("ERROR: first pixel %0d cycles after the rise with the cursor elsewhere, more than %0d %t", cw_lat, CW_LAT, $time);
         error = error + 1;
      end

      //------------------------------------------------------------------
      // VRAM window and GPU at full rate
      //------------------------------------------------------------------
      bkm_rdy_mode = 0;
      for (cw_k = 0; cw_k < 2; cw_k = cw_k + 1) begin
         cw_cfg = cw_k ? 3'b001 : 3'b000;
         bk_cursor_set(1'b1, 7, 5, 0, 0, CW_BLK);
         bk_config(0, 0, 3'd4, 40, 40, cw_cfg, 32'h0000_F000);
         if (GPU_EN != 0) begin
            reg_wr(CTRL, 32'h0000_0014);
            reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, CW_PITCH});
            reg_wr(GPU_CMD, CW_GDST);
            reg_wr(GPU_CMD, {OP_SET_SIZE, CW_FH, CW_FW});
            reg_wr(GPU_CMD, {OP_SET_FILL, 28'h000_0000});
            reg_wr(GPU_CMD, 32'h0000_1234);
            for (cw_i = 0; cw_i < 6; cw_i = cw_i + 1) reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h000_0000});
         end
         bkm_exp_n = 40 * 40;
         cw_nf     = bkm_frames;
         cw_nwin   = 0;
         reg_wr(REFRESH, 32'h0000_0001);
         while (bkm_frames == cw_nf) begin
            cw_v = {cw_nwin[15:0], 16'h5A0F ^ cw_nwin[15:0]};
            vram_wr(4*(CW_WIN + (cw_nwin % 500)), cw_v, SZ_W);
            vram_rd(4*(CW_WIN + (cw_nwin % 500)), cw_v, SZ_W);
            cw_nwin = cw_nwin + 1;
         end
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
         bkr_build(0, 3'd4, 40, 40, cw_cfg, 32'h0000_F000);
         $sformat(cw_tag, "contended cfg %0d (%0d window transfers)", cw_cfg, cw_nwin);
         bkr_check_bdi(cw_tag);
         if (bkm_vreads < bkr_runs) tb_error("fewer VRAM reads than the frame and its cursor need");
         // (a CL frame at a pixel per cycle reads a word per pixel: the urgent
         // refresh may then take every cycle, by design)
         if ((cw_cfg == 3'b000) && (cw_nwin < 5)) tb_error("window traffic starved during the refresh");
         if (GPU_EN != 0) reg_poll(GPU_STAT, 32'h0061_0000, 32'h0001_0000, 20000);
      end
      $display("INFO:  cursor reads granted %0d, urgent %0d", cw_cgnt, cw_urg);
      if ((GPU_EN != 0) && (cw_urg == 0))
         tb_error("no cursor read became urgent under contention");

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
