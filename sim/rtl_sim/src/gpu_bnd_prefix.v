//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_bnd_prefix
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_bnd_prefix.v
// Module Description : ERR_CAUSE 5 raised by stage F keeps the pixels before
//                      the faulting one: an F read past VRAM_WORDS (a source
//                      or mask word) or an immediate index past it waits
//                      while W still has an older pixel it cannot take in the
//                      cycle (a DST remap looking its colour up, a blended
//                      pixel merging the cycle after its read data, the
//                      buffer waiting for the write-back slot).
//                      1. Copies and keyed copies whose source row runs past
//                         VRAM_WORDS, at every depth, ops S / S&D / XOR, X
//                         swaps of the destination, REMAP off / SRC / DST
//                         (palette modes); the VRAM contention of the
//                         configuration (the refresh of a DPI build, a read
//                         latency of 2 or 3, run-ahead).
//                      2. With the immediate source and the remap in a small
//                         VRAM (VRAM_WORDS <= 4096): an 8-bpp immediate COPY
//                         with REMAP DST whose data index crosses VRAM_WORDS
//                         in its last row (rows overlapping in the
//                         destination, pitch 8).
//                      Each copy must stop with ERR_CAUSE 5; the check is
//                      invariant 14 of gpu_inv_check (an F bound error drops
//                      no older pixel, every cycle). The test also requires
//                      the case to be reached: cycles where W holds a pixel it
//                      does not take while F asks past the VRAM (part 1, with
//                      the remap built) or while the immediate index is past
//                      it (part 2).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

integer    bn_it, bn_w, bn_h, bn_mode, bn_op, bn_ppw, bn_sw, bn_kind, bn_rmp, bn_k;
integer    bn_near_f = 0, bn_near_i = 0, bn_bound = 0, bn_c5 = 0;
reg [31:0] bn_st;

`define BN_FW dut.u_core.G_GPU.u_gpu.u_px.u_px_fw
generate
   if (GPU_EN != 0) begin : G_BN
      always @(posedge hclk) begin
         // W holds a pixel it does not take while F asks past the VRAM / the
         // immediate index is past it: the bound error must wait
         if ((`BN_FW.t2_v === 1'b1) && (`BN_FW.w_take !== 1'b1) && (`BN_FW.f_slot === 1'b1) &&
             (`BN_FW.w_slot !== 1'b1) && (`BN_FW.f_oob === 1'b1))   bn_near_f = bn_near_f + 1;
         if ((`BN_FW.t2_v === 1'b1) && (`BN_FW.w_take !== 1'b1) && (`BN_FW.i_oob === 1'b1)) bn_near_i = bn_near_i + 1;
         if (`BN_FW.bound === 1'b1) bn_bound = bn_bound + 1;
      end
   end
endgenerate

// The GPU stopped with ERR_CAUSE 5, then CLEAR_ERR
task bn_end;
   begin
      // (the words reach GPU_CMD through the bench's pusher: wait for the
      // EXEC's GPU_ERR or GPU_DONE flag, cleared before the copy)
      bn_st = 32'h0;
      while (!(bn_st & (IF_ERR | IF_DONE))) reg_rd_val(IRQ_FLAG, bn_st);
      reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 4000);
      reg_rd_val(GPU_STAT, bn_st);
      if ((bn_st & GS_ERR) && (bn_st[27:25] == 3'd5)) bn_c5 = bn_c5 + 1;
      else begin
         $display("ERROR: gpu_bnd_prefix -- GPU_STAT 0x%h, expected ERR_CAUSE 5 (mode %0d %0dx%0d op %0d kind %0d remap %0d) %t",
                  bn_st, bn_mode, bn_w, bn_h, bn_op, bn_kind, bn_rmp, $time);
         error = error + 1;
      end
      reg_wr(GPU_CTRL, 32'h1);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   GPU: ERR_CAUSE 5 by F keeps the prefix      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      if (VRAM_WORDS < 700)
         tb_skip_finish("|       (VRAM_WORDS < 700: no room)              |");

      $display("=== 1. copies whose source runs past VRAM_WORDS");
      for (bn_it = 0; bn_it < 600; bn_it = bn_it + 1) begin
         bn_mode = $random(gpu_seed) & 7; if (bn_mode > 4) bn_mode = 4;
         bn_ppw  = 32 >> ((bn_mode == 4) ? 4 : bn_mode);         // pixels per word: 1/2/4/8/16 bpp
         bn_w    = 1 + (($random(gpu_seed) & 32'h7FFF) % ((GPU_DIM_MASK < 40) ? GPU_DIM_MASK : 40));
         bn_h    = 1 + (($random(gpu_seed) & 32'h7FFF) % ((GPU_DIM_MASK < 3) ? GPU_DIM_MASK : 3));
         bn_op   = (($random(gpu_seed) & 3) != 0) ? 5 : (($random(gpu_seed) & 1) == 0) ? 3 : 0;
         bn_sw   = (($random(gpu_seed) & 3) == 0) ? 3'b100 : 3'b000;
         bn_kind = $random(gpu_seed) & 3;
         bn_rmp  = ((GPU_REMAP_EN != 0) && (bn_mode < 4)) ? ($random(gpu_seed) & 3) : 0;   // REMAP: 0 off, 1 SRC, 2 DST
         if (bn_rmp == 3) bn_rmp = 2;
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         reg_wr(CTRL, 32'h10 | bn_mode);
         if (bn_rmp != 0) begin
            gpu_push({OP_SET_EXT, 4'hD, 4'h0, 20'h0});         // REMAP_TABLE at word 192
            gpu_push(32'd192);
            bn_op = 0;
         end
         gpu_push({OP_SET_SRC, 12'h000, 16'd0});
         gpu_push(VRAM_WORDS * bn_ppw - (($random(gpu_seed) & 32'h7FFF) % bn_w));   // its first row crosses VRAM_WORDS
         gpu_push({OP_SET_DST, 12'h000, 16'd0});
         gpu_push((VRAM_WORDS / 2) * bn_ppw + ($random(gpu_seed) & 255));
         gpu_push({OP_SET_SIZE, bn_h[13:0], bn_w[13:0]});
         if (bn_kind == 3)
            gpu_push({GPU_COPYT, 14'h0, bn_rmp[1:0], 1'b0, 3'b000, 1'b0, bn_sw[2:0], bn_op[3:0]});
         else
            gpu_push({GPU_COPY, 14'h0, bn_rmp[1:0], 1'b0, 3'b000, 1'b0, bn_sw[2:0], bn_op[3:0]});
         bn_end;
      end
      $display("OK:    %0d copies stopped with ERR_CAUSE 5, %0d cycles of W holding a pixel while F asked past the VRAM",
               bn_c5, bn_near_f);
      if ((GPU_REMAP_EN != 0) && (bn_near_f == 0)) begin
         $display("ERROR: gpu_bnd_prefix -- part 1 never held a pixel in W while F asked past the VRAM (test bug) %t", $time);
         error = error + 1;
      end

      if ((GPU_IMM_EN != 0) && (GPU_REMAP_EN != 0) && (VRAM_WORDS <= 4096) && (GPU_DIM_MASK >= 1023)) begin
         $display("=== 2. an immediate COPY with REMAP DST whose index crosses VRAM_WORDS");
         for (bn_it = 0; bn_it < 2; bn_it = bn_it + 1) begin
            bn_w = 1000;
            bn_h = (4 * VRAM_WORDS) / bn_w + 1;                     // 8 bpp: the last row crosses VRAM_WORDS words
            gpu_wait_idle;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            reg_wr(CTRL, 32'h10 | 3);
            gpu_push({OP_SET_EXT, 4'hD, 4'h0, 20'h0});
            gpu_push(32'd192);
            gpu_push({OP_SET_DST, 12'h000, 16'd8});            // rows overlapping: pitch 8
            gpu_push(4 * 320 + bn_it);
            gpu_push({OP_SET_SIZE, bn_h[13:0], bn_w[13:0]});
            gpu_push({OP_SET_SRC, 7'h00, 1'b1, 4'h0, 16'd0});  // SET_SRC IMM: N data words
            gpu_push(VRAM_WORDS + 4);
            gpu_push({GPU_COPY, 14'h0, 2'd2, 12'h000});        // REMAP DST
            gpu_push_wait = 1'b1;                                    // (the data words: each when FREE > 0)
            for (bn_k = 0; bn_k < VRAM_WORDS + 4; bn_k = bn_k + 1)
               gpu_push($random(gpu_seed));
            gpu_push_wait = 1'b0;
            bn_end;
         end
         $display("OK:    %0d cycles of W holding a pixel with the immediate index past the VRAM", bn_near_i);
         if (bn_near_i == 0) begin
            $display("ERROR: gpu_bnd_prefix -- part 2 never held a pixel in W with the index past the VRAM (test bug) %t", $time);
            error = error + 1;
         end
      end

      $display("gpu_bnd_prefix: %0d bound errors", bn_bound);
      tb_checks = tb_checks + bn_c5;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
