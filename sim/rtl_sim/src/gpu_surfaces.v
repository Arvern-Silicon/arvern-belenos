//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_surfaces
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_surfaces.v
// Module Description : Surface and size programming:
//                      size resets to 1x1; pitch 0 = DISP_WIDTH for SRC and
//                      DST; sprite-sheet copy (src pitch != dst pitch != width);
//                      re-execution with a single EXEC word (state persists,
//                      FILL leaves SRC alone); SET_SIZE truncation to DIM_W
//                      bits and 0 -> 1; SET_FILL / SET_TRANSP keep [15:0];
//                      base operand truncated to PA_W bits; the GPU base is
//                      absolute (FRAMEn_PTR not added); SET_DST / SET_SRC
//                      pitch taken with the command and base with the operand
//                      (a flush in between keeps the new pitch, old base,
//                      and discards the operand pushed after it);
//                      GFX_MODE and DISP_WIDTH latched when an EXEC starts;
//                      pitch 0 is the DISP_SIZE width (halved with pixel
//                      doubling), never REFR_PITCH (REFR_PITCH set to
//                      neither W nor W / 2, W odd): SET_SRC / SET_DST in
//                      address mode, SET_DST XY and SET_XY after a width
//                      change, a free-pitch texture, the EXPAND source
//                      (the rectangle width).
//----------------------------------------------------------------------------
`include "gpu_model.v"

reg [31:0] tu_stat;
localparam integer TU_W1 = (DIM_W >= 6) ? 51 : 13;  // odd display widths of the build
localparam integer TU_W2 = (DIM_W >= 6) ? 45 : 11;
integer    tu_n;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: surfaces, pitch, size, latching   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;

      //--------------------------------------------------------------
      $display("--- size resets to 1x1");
      gpu_set_mode(4);
      gpu_set_dispw(50);
      gpu_c_dst(16'd0, 32'd1000);
      gpu_c_fill(32'h0000_5A5A);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("reset size 1x1");

      //--------------------------------------------------------------
      $display("--- pitch 0 = DISP_WIDTH (src and dst), then DISP_WIDTH change + re-exec");
      gpu_c_src(16'd0, 32'd2000 + 3);
      gpu_c_dst(16'd0, 32'd6000 + 7);
      gpu_c_size(14'd4, 14'd3);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("pitch 0 = DISP_WIDTH 50");
      gpu_set_dispw(70);
      gpu_c_exec(GPU_COPY, 4'd5, 3'b000, 3'b000);       // single EXEC word
      gpu_wait_idle;
      gpu_check_touched("pitch 0 = DISP_WIDTH 70, re-exec");
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);       // FILL: same dst, fill 5A5A
      gpu_c_exec(GPU_COPY, 4'd1, 3'b000, 3'b000);       // COPY: SRC unchanged by FILL
      gpu_wait_idle;
      gpu_check_touched("FILL then COPY, persistent state");

      //--------------------------------------------------------------
      gpu_push_wait = 1'b1;                              // (any FIFO depth)
      for (tu_n = 0; tu_n < 2; tu_n = tu_n + 1) begin
         $display("--- pitch 0 = the DISP_SIZE width%0s, never REFR_PITCH", tu_n ? " halved (PIX_DOUBLE)" : "");
         gpu_wait_idle;
         reg_wr(REFR_PITCH, 32'd123);                    // neither W nor W / 2
         reg_wr(DISP_SIZE, 32'h0001_0000 | TU_W1);        // W odd
         reg_wr(DISP_CFG, tu_n ? 32'h10 : 32'h0);
         gpu_m_dispw = tu_n ? (TU_W1 + 1) / 2 : TU_W1;
         gpu_c_src(16'd0, 32'd2400 + 5);
         gpu_c_dst(16'd0, 32'd7000 + 3);
         gpu_c_size(14'd6, 14'd4);
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_c_dst(16'd0, 32'd7400 + 1);
         gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
         gpu_c_dst(16'd0, 32'd7800 + 7);
         gpu_c_src(16'd0, 32'd2600 + 1);                  // EXPAND source: pitch 0 = the rectangle width
         gpu_c_expand(0, 3'b000, 1'b1, 2'd0);
         if (GPU_XY_EN != 0) begin
            gpu_c_dst_xy(16'd0, 32'd8200 + 9);             // the width at SET_DST
            gpu_c_clip(-2048, -2048, 2047, 2047);
            gpu_c_xy(3, 2);
            gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b000, 3'b000);
            gpu_wait_idle;
            reg_wr(DISP_SIZE, 32'h0001_0000 | TU_W2);     // the width at SET_XY
            gpu_m_dispw = tu_n ? (TU_W2 + 1) / 2 : TU_W2;
            gpu_c_xy(1, 3);
            gpu_c_exec_xy(GPU_FILL, 4'd1, 3'b000, 3'b000);
            gpu_c_src(16'd0, 32'd2800 + 3);                // a free-pitch texture: pitch 0 = the width
            gpu_c_tex(4'd15, 4'd15, 1'b0, 3'b000, 1'b1, 1'b0, 8'h00);
            gpu_c_uv(16'h0040, 16'h0040);
            gpu_c_step(16'h0800, 16'h0000);
            gpu_c_step_row(16'h0000, 16'h0800);
            gpu_c_xy(10, 0);
            gpu_c_size(14'd5, 14'd4);
            gpu_c_texrect(0);
         end
         gpu_wait_idle;
         gpu_check_touched(tu_n ? "pitch 0 halved, REFR_PITCH 123" : "pitch 0 = width, REFR_PITCH 123");
      end
      reg_wr(REFR_PITCH, 32'd0);
      reg_wr(DISP_CFG, 32'h0);
      gpu_push_wait = 1'b0;
      gpu_set_dispw(70);

      //--------------------------------------------------------------
      $display("--- sprite sheet: src pitch 128, dst pitch 0 (width 70)");
      gpu_c_src(16'd128, 32'd10000 + 8*128 + 40);
      gpu_c_dst(16'd0,   32'd20000 + 5);
      gpu_c_size(14'd7, 14'd5);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("sprite sheet 16 bpp");
      gpu_set_mode(2);                                   // 4 bpp, sub-word everything
      gpu_c_src(16'd96, 32'd40000 + 3*96 + 13);
      gpu_c_dst(16'd30, 32'd60000 + 6);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("sprite sheet 4 bpp");

      //--------------------------------------------------------------
      $display("--- SET_SIZE truncation and 0 -> 1");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 32'd30000);
      gpu_c_size(14'h3C06, 14'h2403);                    // DIM_W bits only
      gpu_c_fill(32'h1234_8001);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("SET_SIZE truncated");
      gpu_c_dst(16'd64, 32'd31000);
      gpu_c_size(14'h0000, 14'h0000);                    // 0 -> 1
      gpu_c_exec(GPU_FILL, 4'd1, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("SET_SIZE 0x0 -> 1x1");
      gpu_c_dst(16'd64, 32'd32000);
      gpu_c_size(14'd1 << DIM_W, 14'd2);                 // width 2^DIM_W -> 0 -> 1
      gpu_c_exec(GPU_FILL, 4'd1, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("SET_SIZE width 2^DIM_W -> 1");

      //--------------------------------------------------------------
      $display("--- SET_FILL / SET_TRANSP keep [15:0]");
      gpu_c_src(16'd64, 32'd33000);
      gpu_c_dst(16'd64, 32'd34000);
      gpu_c_size(14'd6, 14'd2);
      gpu_c_fill(32'hFFFF_00F0);
      gpu_c_transp({16'hBEEF, gpu_shadow[33000 >> 1][15:0]});   // first src pixel
      gpu_c_exec(GPU_COPYT, 4'd15, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("fill/transp [15:0]");

      //--------------------------------------------------------------
      $display("--- base operand truncated to PA_W, FRAMEn_PTR not added");
      reg_wr(FRAME0_PTR, 32'h0000_1000);
      reg_wr(FRAME1_PTR, 32'h0000_2000);
      reg_wr(FRAME_SEL,  32'h0000_1101);
      // every bit above the pixel address (PA_W = VRAM_AW + 5) set: dropped
      gpu_c_src(16'd64, (32'hFFFF_FFFF << (VRAM_AW + 5)) | 32'd36000);
      gpu_c_dst(16'd64, (32'hFFFF_FFFF << (VRAM_AW + 5)) | 32'd37001);
      gpu_c_size(14'd3, 14'd3);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("base PA_W, absolute");
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME1_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);

      //--------------------------------------------------------------
      $display("--- pitch with the command, base with the operand");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_c_dst(16'd40, 32'd38000);                      // P1 / B1
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push({OP_SET_DST, 12'h000, 16'd60});           // P2, no operand
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_BUSY | GS_EMPTY, GS_BUSY | GS_EMPTY | GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_IDLE);
      reg_wr(GPU_CTRL, 32'h1);                           // CLEAR_ERR outside ERR: flush
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_BUSY | GS_EMPTY | GS_ERR);
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_IDLE | IF_DONE);
      gpu_push(32'd50000);                               // B2: discarded
      gpu_m_dst_pitch = 16'd60;                          // new pitch, old base
      gpu_c_size(14'd3, 14'd4);
      gpu_c_fill(32'h0000_0F0F);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("SET_DST pitch kept after flush");
      // same with SET_SRC, flushed by ABORT
      gpu_c_src(16'd30, 32'd39000);
      gpu_push({OP_SET_SRC, 12'h000, 16'd45});
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_BUSY | GS_EMPTY, GS_BUSY | GS_EMPTY | GS_ERR);
      reg_wr(GPU_CTRL, 32'h2);                           // ABORT: flush
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_BUSY | GS_EMPTY | GS_ERR);
      gpu_push(32'd50000);                               // discarded
      gpu_m_src_pitch = 16'd45;
      gpu_c_dst(16'd64, 32'd41000);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("SET_SRC pitch kept after abort");

      //--------------------------------------------------------------
      $display("--- GFX_MODE and DISP_WIDTH latched at EXEC start");
      gpu_set_mode(4);
      gpu_set_dispw(50);
      gpu_c_dst(16'd0, 32'd44000);
      gpu_c_size(14'd40, 14'd20);
      gpu_c_fill(32'h0000_C3A5);
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);        // ~1600 cycles
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
      reg_wr(CTRL, 32'h10 | 32'd3);                      // 8 bpp, GPU_EN kept
      reg_wr(DISP_SIZE, 32'h0001_0000 | 32'd90);
      reg_rd_mask(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY);   // still running
      gpu_wait_idle;
      gpu_m_mode  = 3'd3;
      gpu_m_dispw = ((90 & ((1 << DIM_W) - 1)) == 0) ? 1 : (90 & ((1 << DIM_W) - 1));
      gpu_check_touched("mode / width latched");
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);        // now 8 bpp, width 90
      gpu_wait_idle;
      gpu_check_touched("new mode / width at next EXEC");

      gpu_check_all("surfaces end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
