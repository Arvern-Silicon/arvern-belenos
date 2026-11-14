//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_extremes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_extremes.v
// Module Description : Field extremes of the GPU: width / height
//                      2^DIM_W - 1 (with and without CL swap), DISP_WIDTH at
//                      its maximum as the pitch-0 stride, pitches 0x8000,
//                      0x8001 and 0xFFFF (16-bit pitch field, no sign
//                      extension) with X/Y swaps walking up and down, bases
//                      above 2^20 pixels, the last pixel of VRAM. 1 bpp keeps
//                      the large pitches inside VRAM. Pitches with each bit
//                      8..14 set, as destination and source, in address
//                      and x/y mode.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TX_MAX = (1 << DIM_W) - 1;
localparam integer TX_PX1 = VRAM_WORDS * 32;            // pixels at 1 bpp

integer    tx_m, tx_c;

// One 1 x 1 FILL (c = 0: destination) or COPY (c = 1: source) at word
// 2^VRAM_AW + 50, raw commands (the model rejects such an address)
task tx_alias;
   input integer m;                      // GFX_MODE 1..4 (2..16 bpp)
   input integer c;
   reg    [31:0] pa, w50, w200;
   begin
      gpu_set_mode(m);
      gpu_wait_idle;
      pa   = ((1 << VRAM_AW) + 50) * (32 >> m);
      w50  = vram_mem[50];
      w200 = vram_mem[200];
      gpu_push({OP_SET_SIZE, 14'd1, 14'd1});
      if (c == 0) begin
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(pa);
         gpu_push({OP_SET_FILL, 28'h0});
         gpu_push(32'hBEEF_BEEF);
         gpu_push({OP_EXEC_FILL, 28'h0});
      end else begin
         gpu_push({OP_SET_SRC, 12'h000, 16'd0});
         gpu_push(pa);
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push(200 * (32 >> m));
         gpu_push({OP_EXEC_COPY, 28'h0});
      end
      reg_poll(GPU_STAT, GS_ERR, GS_ERR, 100);
      reg_rd_mask(GPU_STAT, {(c == 0) ? OP_EXEC_FILL : OP_EXEC_COPY, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
      repeat(20) @(posedge free_clk);
      if ((vram_mem[50] !== w50) || (vram_mem[200] !== w200)) begin
         $display("ERROR: mode %0d %s past 2^VRAM_AW words: word 50 0x%h (was 0x%h), word 200 0x%h (was 0x%h) %t",
                  m, (c == 0) ? "FILL" : "COPY", vram_mem[50], w50, vram_mem[200], w200, $time);
         error = error + 1;
      end
      reg_wr(GPU_CTRL, 32'h1);                             // CLEAR_ERR
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: field extremes                    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;

      $display("--- width 2^DIM_W-1 at 8 bpp, pitch 0 = DISP_WIDTH max");
      gpu_set_mode(3);
      gpu_set_dispw(TX_MAX);
      gpu_c_dst(16'd0, 32'd4000 + 1);
      gpu_c_size(TX_MAX, 14'd3);
      gpu_c_fill(32'h0000_00C3);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("w max");

      $display("--- height 2^DIM_W-1, and CL swap with the width as vertical run");
      gpu_set_mode(0);
      gpu_c_dst(16'd40, 32'd200000 + 3);
      gpu_c_size(14'd3, TX_MAX);
      gpu_c_exec(GPU_FILL, 4'd2, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("h max");
      gpu_c_dst(16'd40, 32'd300000 + 5 + 2 * 40);
      gpu_c_size(TX_MAX, 14'd3);
      gpu_c_exec(GPU_FILL, 4'd2, 3'b011, 3'b000);       // CL + Y: start at the bottom row
      gpu_wait_idle;
      gpu_check_touched("CL, w max vertical");

      $display("--- 16-bit pitches 0x8000 / 0x8001 / 0xFFFF at 1 bpp");
      gpu_c_src(16'hFFFF, 32'd70000 + 13);
      gpu_c_dst(16'h8000, 32'd100000 + 7);
      gpu_c_size(14'd9, 14'd17);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("pitch 0x8000 / 0xFFFF down");
      gpu_c_src(16'hFFFF, 32'd70000 + 13 + 16 * 65535);
      gpu_c_dst(16'h8001, 32'd120000 + 8 + 16 * 32769);
      gpu_c_exec(GPU_COPY, 4'd6, 3'b110, 3'b010);       // dst X+Y, src Y: walking up
      gpu_wait_idle;
      gpu_check_touched("pitch 0x8001 / 0xFFFF up");
      gpu_c_src(16'hFFFF, 32'd70000 + 17);
      gpu_c_dst(16'h8000, 32'd140000 + 3 + 8 * 32768);
      gpu_c_size(14'd9, 14'd17);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b011, 3'b001);       // CL both, dst Y: vertical runs upward
      gpu_wait_idle;
      gpu_check_touched("pitch CL up/down");

      $display("--- pitches with each bit 8..14 set (destination and source, address and x/y mode)");
      gpu_set_mode(0);
      for (tx_m = 8; tx_m <= 14; tx_m = tx_m + 1) begin
         tx_c = (1 << tx_m) | ($random(gpu_seed) & ((1 << tx_m) - 1));
         // the COPY below walks its source up two lines (Y swap): a base of
         // 2 048 words keeps 2 x 0x7FFF pixels below it
         gpu_c_src(tx_c, 32 * 2048 + ($random(gpu_seed) & 31));
         gpu_c_dst(tx_c, 32 * 6000 + ($random(gpu_seed) & 31));
         gpu_c_size(14'd5, 14'd3);
         gpu_c_fill($random(gpu_seed));
         gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
         gpu_c_dst(tx_c, 32 * 12000 + ($random(gpu_seed) & 31));
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b010);
         if (GPU_XY_EN != 0) begin
            gpu_c_dst_xy(tx_c, 32 * 18000);
            gpu_c_xy(3, 1);
            gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b001, 3'b000);
         end
         gpu_wait_idle;
         gpu_check_touched("pitch bit");
      end

      $display("--- last pixel of VRAM, bases above 2^20");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, VRAM_WORDS * 2 - 1);
      gpu_c_size(14'd1, 14'd1);
      gpu_c_fill(32'h0000_BEEF);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("last 16-bpp pixel");
      gpu_set_mode(0);
      gpu_c_src(16'd100, TX_PX1 - 1 - 5 * 100);
      gpu_c_dst(16'd77, TX_PX1 - 1);
      gpu_c_size(14'd6, 14'd5);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b110, 3'b100);       // dst ends at pixel 0x... (X+Y swap from the last pixel)
      gpu_wait_idle;
      gpu_check_touched("last 1-bpp pixel, swapped");

      // Pixel addresses whose word is past 2^VRAM_AW at 2..16 bpp: cause 5,
      // nothing written (word 2^VRAM_AW + 50 must not alias onto word 50)
      $display("--- pixel addresses past 2^VRAM_AW words at 2..16 bpp");
      for (tx_m = 1; tx_m <= 4; tx_m = tx_m + 1)
         for (tx_c = 0; tx_c < 2; tx_c = tx_c + 1)
            tx_alias(tx_m, tx_c);

      gpu_check_all("extremes end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
