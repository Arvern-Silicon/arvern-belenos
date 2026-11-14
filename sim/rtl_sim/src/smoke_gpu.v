//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      smoke_gpu
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : smoke_gpu.v
// Module Description : Smoke test of the GPU at 16 bpp: SET_DST (explicit
//                      pitch), SET_SIZE 4x3, SET_FILL, EXEC_FILL (PX_OP 0 =
//                      S) of a rectangle; GPU_STAT polled until idle; every
//                      pixel of the rectangle and its two neighbours checked
//                      through the VRAM window. Skipped without the GPU.
//----------------------------------------------------------------------------

localparam integer F_PITCH = 16;              // pixels per line
localparam integer F_X     = 2;               // rectangle origin and size
localparam integer F_Y     = 1;
localparam integer F_W     = 4;
localparam integer F_H     = 3;
localparam  [15:0] F_COLOR = 16'hF81F;
localparam  [31:0] F_BASE  = 32'h0000_0000;   // destination surface (pixel address)

integer    gx, gy;
reg [31:0] gword;
reg [15:0] gexp;
reg [15:0] gpix;

initial
   begin
      $display(" ===============================================");
      $display("|                   SMOKE: GPU                  |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");

      // Background: zero the surface lines the rectangle touches (+1 margin)
      for (gy = 0; gy < F_Y + F_H + 1; gy = gy + 1)
         for (gx = 0; gx < F_PITCH; gx = gx + 2)
            vram_mem[(gy*F_PITCH + gx) >> 1] = 32'h0000_0000;

      reg_wr(CTRL, 32'h0000_0010 | {29'h0, GFX_16BPP});      // GPU_EN, 16 bpp
      reg_rd(GPU_STAT, 32'h0001_0000 | GPU_FIFO_DEPTH);      // EMPTY, FREE = depth

      reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, F_PITCH[15:0]});
      reg_wr(GPU_CMD, F_BASE + F_Y*F_PITCH + F_X);
      reg_wr(GPU_CMD, {OP_SET_SIZE, F_H[13:0], F_W[13:0]});
      reg_wr(GPU_CMD, {OP_SET_FILL, 28'h000_0000});
      reg_wr(GPU_CMD, {16'h0000, F_COLOR});
      reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h000_0000});          // PX_OP 0, no swap

      // BUSY (bit 21) low and EMPTY (bit 16) high
      reg_poll(GPU_STAT, 32'h0021_0000, 32'h0001_0000, 200);
      reg_rd_mask(GPU_STAT, 32'h0000_0000, 32'h0040_0000);    // no ERR

      // Rectangle plus a one-pixel border
      for (gy = F_Y - 1; gy <= F_Y + F_H; gy = gy + 1)
         for (gx = F_X - 1; gx <= F_X + F_W; gx = gx + 1) begin
            vram_rd_val(4*((gy*F_PITCH + gx) >> 1), SZ_W, gword);
            gpix = ((gy*F_PITCH + gx) & 1) ? gword[31:16] : gword[15:0];
            gexp = ((gx >= F_X) && (gx < F_X + F_W) && (gy >= F_Y) && (gy < F_Y + F_H)) ? F_COLOR : 16'h0000;
            if (gpix !== gexp) begin
               $display("ERROR: GPU fill pixel (%0d,%0d) = 0x%h / expected 0x%h %t", gx, gy, gpix, gexp, $time);
               error = error + 1;
            end
         end
      if (error == 0)
         $display("OK:    GPU fill rectangle %0dx%0d at (%0d,%0d) matches", F_W, F_H, F_X, F_Y);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
