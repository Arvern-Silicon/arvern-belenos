//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_contention
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_contention.v
// Module Description : Refresh under heavy VRAM traffic (uarch §4.2 / §8,
//                      spec §7: an underrun only slows a frame, it never
//                      corrupts it), DIF_TYPE = 0. While a 16 bpp frame
//                      streams to the BDI model (random ready, then ready at
//                      1 so the backend runs at its urgent level, then a CL
//                      swap frame where every pixel is a new word), the GPU
//                      runs a large FILL then a COPY outside the frame, and
//                      the single bus thread loops VRAM-window writes / read-
//                      backs and (8 bpp SW-LUT frame) LUT bank-1 window
//                      writes. Checked: the frame is exact (pixel data,
//                      count, px_last), the window traffic completes and is
//                      correct, the GPU rectangles
//                      are correct, and the frame time is reported against
//                      an uncontended baseline. Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer CT_W      = 40;
localparam integer CT_H      = 30;
localparam integer CT_FILL_W = 64;
localparam integer CT_FILL_H = 50;
localparam integer CT_GDST   = 8192;    // GPU fill base (pixel, 16 bpp: word 4096)
localparam integer CT_GCPY   = 16384;   // GPU copy destination (word 8192)
localparam integer CT_WIN    = 12000;   // window traffic words
localparam  [15:0] CT_COLOR  = 16'h7E0F;
localparam  [15:0] CT_PITCH16 = CT_FILL_W;
localparam  [13:0] CT_W14     = CT_FILL_W;
localparam  [13:0] CT_H14     = CT_FILL_H;

integer    ct_r, ct_i, ct_nf, ct_nwin, ct_nlut, ct_base_t, ct_t;
integer    ct_x, ct_y;
reg [31:0] ct_v, ct_rd;
reg  [2:0] ct_cfg;
reg  [2:0] ct_mode;
reg [31:0] ct_lut;
reg [64*8-1:0] ct_tag;

task ct_gpu_queue;
   begin
      reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, CT_PITCH16});
      reg_wr(GPU_CMD, CT_GDST);
      reg_wr(GPU_CMD, {OP_SET_SIZE, CT_H14, CT_W14});
      reg_wr(GPU_CMD, {OP_SET_FILL, 28'h000_0000});
      reg_wr(GPU_CMD, {16'h0000, CT_COLOR});
      reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h000_0000});
      reg_wr(GPU_CMD, {OP_SET_SRC, 12'h000, CT_PITCH16});
      reg_wr(GPU_CMD, CT_GDST);
      reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, CT_PITCH16});
      reg_wr(GPU_CMD, CT_GCPY);
      reg_wr(GPU_CMD, {OP_EXEC_COPY, 28'h000_0000});
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     BACKEND: REFRESH UNDER VRAM CONTENTION    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en = 1'b1;
      bk_vram_rand(0, 1024);
      bk_lut_rand;

      for (ct_r = 0; ct_r < 3; ct_r = ct_r + 1) begin
         ct_cfg  = (ct_r == 1) ? 3'b101 : 3'b000;
         ct_mode = (ct_r == 2) ? 3'd3 : 3'd4;
         ct_lut  = (ct_r == 2) ? 32'h0000_0001 : 32'h0000_F000;
         bkm_rdy_mode    = (ct_r == 1) ? 0 : 1;
         bkm_rdy_pct_low = 10;

         // Uncontended baseline
         bk_frame("baseline", 0, 3, ct_mode, CT_W, CT_H, ct_cfg, ct_lut);
         ct_base_t = bkm_fall_cyc - bkm_rise_cyc;

         // Background for the GPU
         for (ct_i = CT_GDST/2; ct_i < CT_GCPY/2 + CT_FILL_W*CT_FILL_H/2; ct_i = ct_i + 1)
            vram_mem[ct_i] = 32'h0;
         // the GPU works at the frame's GFX_MODE (16 bpp runs only)
         reg_wr(CTRL, {27'h0, (GPU_EN != 0) && (ct_mode == 3'd4), 1'b0, ct_mode});
         if ((GPU_EN != 0) && (ct_mode == 3'd4))
            ct_gpu_queue;

         // Contended frame: one bus thread, loops until the frame is done
         bkm_exp_n = CT_W * CT_H;
         ct_nf     = bkm_frames;
         ct_nwin   = 0;
         ct_nlut   = 0;
         reg_wr(REFRESH, 32'h0000_0001);
         while (bkm_frames == ct_nf) begin
            ct_v = {ct_r[3:0], ct_nwin[11:0], 16'hA5C3 ^ ct_nwin[15:0]};
            vram_wr(4*(CT_WIN + (ct_nwin % 500)), ct_v, SZ_W);
            vram_rd(4*(CT_WIN + (ct_nwin % 500)), ct_v, SZ_W);
            // identical data rewritten inside the displayed frame
            vram_rd_val(4*(10 + ct_nwin % 300), SZ_W, ct_rd);
            vram_wr(4*(10 + ct_nwin % 300), ct_rd, SZ_W);
            ct_nwin = ct_nwin + 1;
            if ((ct_r == 2) && (LUT_EN != 0) && (LUT_BANKS == 2)) begin
               reg_wr(LUT_BASE + 32'h400 + 4*(ct_nlut % 256), 32'h0012_3400 | ct_nlut);
               ct_nlut = ct_nlut + 1;
            end
         end
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
         ct_t = bkm_fall_cyc - bkm_rise_cyc;
         bkr_build(3, ct_mode, CT_W, CT_H, ct_cfg, ct_lut);
         $sformat(ct_tag, "contended frame %0d (%0d window, %0d LUT transfers)", ct_r, ct_nwin, ct_nlut);
         bkr_check_bdi(ct_tag);
         $display("INFO:  frame %0d: %0d cycles uncontended, %0d cycles contended", ct_r, ct_base_t, ct_t);
         if (ct_nwin < 5) tb_error("window traffic starved during the refresh");

         // GPU rectangles
         if ((GPU_EN != 0) && (ct_mode == 3'd4)) begin
            reg_poll(GPU_STAT, 32'h0061_0000, 32'h0001_0000, 5000);
            for (ct_i = 0; ct_i < CT_FILL_W*CT_FILL_H/2; ct_i = ct_i + 1) begin
               if (vram_mem[CT_GDST/2 + ct_i] !== {CT_COLOR, CT_COLOR}) begin
                  $display("ERROR: GPU fill word %0d = 0x%h %t", ct_i, vram_mem[CT_GDST/2 + ct_i], $time);
                  error = error + 1;
                  ct_i = CT_FILL_W*CT_FILL_H;
               end else if (vram_mem[CT_GCPY/2 + ct_i] !== {CT_COLOR, CT_COLOR}) begin
                  $display("ERROR: GPU copy word %0d = 0x%h %t", ct_i, vram_mem[CT_GCPY/2 + ct_i], $time);
                  error = error + 1;
                  ct_i = CT_FILL_W*CT_FILL_H;
               end
            end
         end

         // Frame contents are unchanged: a final uncontended frame matches too
         bk_frame("after contention", 0, 3, ct_mode, CT_W, CT_H, ct_cfg, ct_lut);
      end

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
