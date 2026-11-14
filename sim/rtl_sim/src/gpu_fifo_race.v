//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_fifo_race
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_fifo_race.v
// Module Description : Push to a full FIFO around the first pop (a
//                      push to a full FIFO is dropped even if a word is
//                      consumed in the same cycle). The FIFO is filled with
//                      FENCE[0]=0 words while frozen; the freeze is released
//                      at a swept offset (-4..+8 cycles) around a push of a
//                      marker EXEC_FILL (op 14 on one pixel). For every offset
//                      exactly one of {GPU_OVFL, marker executed (GPU_DONE and
//                      pixel all-ones)} must hold; a push whose data phase
//                      completes while the FIFO is still full must be dropped.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tw_off, tw_k, tw_ndrop, tw_nacc, tw_tpush, tw_trel;
reg [31:0] tw_flag, tw_word;
reg        tw_dropped;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: push to a full FIFO vs. pop       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      gpu_c_size(14'd1, 14'd1);
      gpu_c_fill(32'h0);
      gpu_c_transp(32'h1234);                         // op 14 must not be transparent
      tw_ndrop = 0;
      tw_nacc  = 0;

      for (tw_off = -4; tw_off <= 8; tw_off = tw_off + 1) begin
         gpu_c_dst(16'd64, 32'd1000 + tw_off + 4);
         gpu_wait_idle;
         vram_mem[(1000 + tw_off + 4) >> 1] = 32'h0;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_freeze(1'b1);
         for (tw_k = 0; tw_k < GPU_FIFO_DEPTH; tw_k = tw_k + 1)
            gpu_push({OP_FENCE, 28'h0});
         reg_rd_mask(GPU_STAT, GS_FULL, GS_FULL);
         // marker push and release, offset tw_off cycles apart
         fork
            begin
               if (tw_off < 0) repeat(-tw_off) @(posedge free_clk);
               gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
               tw_tpush = gpu_cyc;
            end
            begin
               if (tw_off > 0) repeat(tw_off) @(posedge free_clk);
               @(negedge free_clk) dbg_stoptime = 1'b0;
               tw_trel = gpu_cyc;
            end
         join
         gpu_wait_idle;
         reg_wr(DBG_CTRL, 32'h0);
         reg_rd_val(IRQ_FLAG, tw_flag);
         vram_rd_val(4 * ((1000 + tw_off + 4) >> 1), SZ_W, tw_word);
         tw_word = ((1000 + tw_off + 4) & 1) ? (tw_word >> 16) : (tw_word & 32'hFFFF);
         tw_dropped = tw_flag[6];
         if (tw_dropped && !tw_flag[4] && (tw_word == 32'h0)) begin
            tw_ndrop = tw_ndrop + 1;
            $display("OK:    offset %0d (push done %0d, release %0d): dropped, GPU_OVFL", tw_off, tw_tpush, tw_trel);
         end else if (!tw_dropped && tw_flag[4] && (tw_word == 32'hFFFF)) begin
            tw_nacc = tw_nacc + 1;
            $display("OK:    offset %0d (push done %0d, release %0d): accepted and executed", tw_off, tw_tpush, tw_trel);
         end else begin
            $display("ERROR: offset %0d: IRQ_FLAG 0x%h, pixel 0x%h -- inconsistent drop / execute %t", tw_off, tw_flag, tw_word, $time);
            error = error + 1;
         end
      end
      if ((tw_ndrop == 0) || (tw_nacc == 0)) begin
         $display("ERROR: the sweep did not cover both outcomes (%0d dropped, %0d accepted)", tw_ndrop, tw_nacc);
         error = error + 1;
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
