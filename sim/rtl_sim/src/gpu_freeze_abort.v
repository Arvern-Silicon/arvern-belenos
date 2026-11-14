//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_freeze_abort
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_freeze_abort.v
// Module Description : Freeze combined with the other GPU controls:
//                      GPU_CTRL.ABORT and CTRL.GPU_EN = 0 while held
//                      in the middle of a rectangle (FIFO flushed, BUSY and
//                      PRIM_BUSY 0, HELD stays 1 as frozen-while-idle, no
//                      GPU_DONE, clean prefix image, nothing runs after the
//                      release); an operand word pushed while the decoder
//                      waits for it and the GPU is held is not consumed until
//                      the release.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tk_k, tk_n, tk_tot;
reg [31:0] tk_stat;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: freeze + ABORT / GPU_EN=0         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);

      for (tk_k = 0; tk_k < 2; tk_k = tk_k + 1) begin
         $display("--- %0s while held mid-rectangle", tk_k ? "CTRL.GPU_EN=0" : "GPU_CTRL.ABORT");
         gpu_set_mode(2);
         gpu_c_src(16'd120, 32'd2000 + 9 * tk_k);
         gpu_c_dst(16'd100, 32'd90000 + 17 * tk_k);
         gpu_c_size(14'd30, 14'd20);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_snapshot;
         gpu_push(gpu_exec_word(GPU_COPY, 4'd5, 3'b000, 3'b000));
         gpu_x_setup(GPU_COPY, 4'd5, 3'b000, 3'b000);
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         repeat(150) @(posedge free_clk);
         gpu_freeze(1'b1);
         reg_poll(GPU_STAT, GS_HELD, GS_HELD, 50);
         gpu_push({OP_FENCE, 28'h100_0001});
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
         reg_rd_mask(GPU_STAT, GS_HELD | GS_BUSY | GS_PRIM_BUSY | 32'h0200, GS_HELD | GS_BUSY | GS_PRIM_BUSY | 32'hFF00);
         if (tk_k) reg_wr(CTRL, 32'd2);
         else      reg_wr(GPU_CTRL, 32'h2);
         repeat(10) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_HELD | GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
         reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR);
         gpu_mon_start;
         gpu_freeze(1'b0);
         if (tk_k) gpu_set_mode(2);
         repeat(200) @(posedge free_clk);
         gpu_mon_stop;
         if (gpu_mon_n != 0) begin
            $display("ERROR: GPU %0d VRAM accesses after the release of an abandoned rectangle %t", gpu_mon_n, $time);
            error = error + 1;
         end
         reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
         gpu_find_prefix(tk_n);
         tk_tot = gpu_x_w * gpu_x_h;
         if ((tk_n <= 0) || (tk_n >= tk_tot)) begin
            $display("ERROR: GPU abandoned rectangle -- image is not a strict prefix (n = %0d of %0d) %t", tk_n, tk_tot, $time);
            error = error + 1;
         end else
            $display("OK:    GPU abandoned while held after %0d of %0d pixels (clean prefix)", tk_n, tk_tot);
         gpu_check_touched("abandoned while held");
      end

      $display("--- operand pushed while held is not consumed");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 32'd3000);
      gpu_c_size(14'd4, 14'd2);
      gpu_wait_idle;
      gpu_push({OP_SET_FILL, 28'h0});
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_BUSY | GS_EMPTY, GS_BUSY | GS_EMPTY | GS_HELD | 32'hFF00);
      gpu_freeze(1'b1);
      reg_poll(GPU_STAT, GS_HELD, GS_HELD, 50);
      gpu_push(32'h0000_6B6B);
      gpu_m_fill = 16'h6B6B;
      repeat(20) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_HELD | GS_BUSY | 32'h0100, GS_HELD | GS_BUSY | GS_EMPTY | 32'hFF00);
      gpu_freeze(1'b0);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_HELD | GS_BUSY | GS_EMPTY | 32'hFF00);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("operand after release");

      gpu_check_all("freeze_abort end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
