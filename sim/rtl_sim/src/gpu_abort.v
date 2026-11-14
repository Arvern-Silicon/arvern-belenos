//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_abort
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_abort.v
// Module Description : Abandoned rectangles:
//                      GPU_CTRL.ABORT and CTRL.GPU_EN = 0 in the middle of a
//                      rectangle (1, 4 and 16 bpp, read-merge-write and
//                      byte-enable paths): the image is the model image of a
//                      clean prefix of the walk (0 < n < total), no GPU_DONE,
//                      one GPU_IDLE, FIFO flushed (queued commands never run),
//                      pushes while disabled are dropped, and the GPU works
//                      normally afterwards (the copies with CL swaps: one
//                      pixel per token, slow enough to be caught mid-way;
//                      then ABORT in long word-token copies at 1 and 8 bpp).
//                      The FENCE queued behind the abandoned rectangle never
//                      updates GPU_FENCE nor raises GPU_FENCE. Then ABORT in
//                      the middle of COPY_TRANSP (one pixel per token), SPAN,
//                      a flat triangle, EXEC_TEXRECT and a textured triangle
//                      (as built): the image is a strict prefix of the walk
//                      in walk order (triangles: box rows, then columns),
//                      the abort landing after the first VRAM writes. Also
//                      CLEAR_ERR outside ERR while a rectangle runs: the
//                      queued words are flushed, the rectangle completes
//                      (GPU_DONE) and the queued op-14 FILL never draws.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    ta_k, ta_n, ta_tot, ta_mode, ta_cls, ta_nd, ta_g;
reg  [2:0] ta_sw;
reg [31:0] ta_flag;
integer    ta_strict [0:4];
initial for (ta_k = 0; ta_k < 5; ta_k = ta_k + 1) ta_strict[ta_k] = 0;

function integer ta_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      ta_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

// One primitive of kind k (0 COPY_TRANSP with CL swaps, 1 SPAN, 2 flat
// triangle, 3 EXEC_TEXRECT, 4 textured triangle), modelled with the walk
// record, then ABORT once the GPU has made its first writes: a strict prefix
// of the walk, no GPU_DONE
task ta_kind;
   input integer k;
   begin
      if (((k == 2) || (k == 4)) && ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0)))
         ;
      else if ((k == 3) && (GPU_XY_EN == 0))
         ;
      else begin
         ta_mode = (k == 0) ? 3 : 4;
         gpu_set_mode(ta_mode);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp($random(gpu_seed) & 32'h3);                 // a few source pixels transparent
         gpu_c_src(16'd100, 32'd8000 + ta_rnd(64));
         if (k >= 2) begin
            gpu_c_dst_xy(16'd128, 32'd40000);
            gpu_c_xy(10, 4);
            gpu_c_clip(-2048, -2048, 2047, 2047);
         end else
            gpu_c_dst(16'd96, 32'd50000 + ta_rnd(16));
         gpu_c_size((k == 1) ? 14'd1 : 14'd30, (k == 1) ? 14'd1 : 14'd20);
         if ((k == 2) || (k == 4)) begin
            gpu_c_vtx(0, 16 * 10 + ta_rnd(16), 16 * 4 + ta_rnd(16));
            gpu_c_vtx(1, 16 * 48 + ta_rnd(16), 16 * 10 + ta_rnd(16));
            gpu_c_vtx(2, 16 * 20 + ta_rnd(16), 16 * 34 + ta_rnd(16));
         end
         if (k >= 3) begin
            gpu_c_tex(4'd5, 4'd5, 1'b1, 3'b000, 1'b0, 1'b0, 8'd0);
            gpu_c_uv(16'd0, 16'd0);
            gpu_c_step(16'd1500, 16'd200);
            gpu_c_step_row(16'd100, 16'd1700);
         end
         gpu_wait_idle;
         // fresh destination contents: a pass drawing the texels of an earlier one
         // over its image would leave its drawn prefix invisible
         gpu_preload_rand(12000, 27000);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_mon_start;
         gpu_rec_begin;
         case (k)
           0: gpu_c_exec(GPU_COPYT, 4'd0, 3'b001, 3'b001);        // one pixel per token
           1: gpu_c_span(0, 14'd300);
           2: gpu_c_trifill(4'd5);
           3: gpu_c_texrect(0);
           default: gpu_c_tritex;
         endcase
         gpu_rec_end;
         ta_n = 1 + ta_rnd(gpu_rec_n / 6);                        // writes before the ABORT
         ta_g = 0;
         while ((gpu_mon_wr < ta_n) && (ta_g < 2000)) begin @(posedge free_clk); ta_g = ta_g + 1; end
         reg_wr(GPU_CTRL, 32'h2);
         gpu_mon_stop;
         gpu_flush_hint = 1'b0;
         gpu_wait_idle;
         reg_rd_val(IRQ_FLAG, ta_flag);
         gpu_rec_prefix(ta_flag[4], ta_cls, ta_nd);
         if (ta_cls != 1) begin
            $display("ERROR: GPU %0s aborted after %0d writes -- class %0d (%0d of %0d recorded pixels drawn): not a strict prefix %t",
                     (k == 0) ? "COPY_TRANSP" : (k == 1) ? "SPAN" : (k == 2) ? "TRI" : (k == 3) ? "TEXRECT" : "textured TRI",
                     ta_n, ta_cls, ta_nd, gpu_rec_n, $time);
            error = error + 1;
         end else begin
            ta_strict[k] = ta_strict[k] + 1;
            $display("OK:    GPU %0s aborted: %0d of %0d pixels drawn (clean prefix in walk order)",
                     (k == 0) ? "COPY_TRANSP" : (k == 1) ? "SPAN" : (k == 2) ? "TRI" : (k == 3) ? "TEXRECT" : "textured TRI",
                     ta_nd, gpu_rec_n);
         end
         gpu_check_touched("aborted primitive");
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: ABORT / GPU_EN=0 mid-rectangle    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);

      for (ta_k = 0; ta_k < 6; ta_k = ta_k + 1) begin
         ta_mode = ((ta_k % 3) == 0) ? 0 : ((ta_k % 3) == 1) ? 2 : 4;
         $display("--- %0s mid-rectangle, mode %0d", (ta_k < 3) ? "ABORT" : "GPU_EN=0", ta_mode);
         gpu_set_mode(ta_mode);
         gpu_c_src(16'd100, 32'd1000 + 7 * ta_k);
         gpu_c_dst(16'd90, 32'd30000 + 11 * ta_k);
         gpu_c_size(14'd30, 14'd20);
         gpu_c_fill($random(gpu_seed));
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_snapshot;
         ta_sw = (ta_mode == 4) ? 3'b000 : 3'b001;                // copies: CL swaps (30 rows, 20 columns)
         gpu_push(gpu_exec_word((ta_mode == 4) ? GPU_FILL : GPU_COPY, 4'd5, ta_sw, ta_sw));
         gpu_x_setup((ta_mode == 4) ? GPU_FILL : GPU_COPY, 4'd5, ta_sw, ta_sw);
         gpu_push({OP_FENCE, 28'h100_0001});                      // flushed: no DONE
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         repeat(150 + ($random(gpu_seed) & 255)) @(posedge free_clk);
         if (ta_k < 3)
            reg_wr(GPU_CTRL, 32'h2);
         else begin
            reg_wr(CTRL, ta_mode);
            gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));  // dropped
            reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
         end
         repeat(10) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
         reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_FENCE);
         repeat(200) @(posedge free_clk);                 // nothing else happens
         reg_rd(GPU_FENCE, 32'h0);                        // the flushed FENCE never reached
         gpu_find_prefix(ta_n);
         ta_tot = gpu_x_w * gpu_x_h;
         if ((ta_n <= 0) || (ta_n >= ta_tot)) begin
            $display("ERROR: GPU abandoned rectangle -- image is not a strict prefix (n = %0d of %0d) %t", ta_n, ta_tot, $time);
            error = error + 1;
         end else
            $display("OK:    GPU abandoned after %0d of %0d pixels (clean prefix)", ta_n, ta_tot);
         gpu_check_touched("abandoned rectangle");
         if (ta_k >= 3) gpu_set_mode(ta_mode);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         // the GPU works afterwards (state re-programmed)
         gpu_c_src(16'd100, 32'd1000 + 7 * ta_k);
         gpu_c_dst(16'd90, 32'd30000 + 11 * ta_k);
         gpu_c_size(14'd5, 14'd4);
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         gpu_check_touched("after abandon");
      end

      // ABORT in long word-token copies (a word of pixels per token): the image
      // is still a clean prefix of the walk
      for (ta_k = 0; ta_k < 2; ta_k = ta_k + 1) begin
         ta_mode = ta_k ? 3 : 0;
         $display("--- ABORT mid word-token copy, mode %0d", ta_mode);
         gpu_set_mode(ta_mode);
         gpu_c_src(16'd512, 32'd4096 + 5 * ta_k);
         gpu_c_dst(16'd512, 32'd65536 + 3 * ta_k);
         gpu_c_size(ta_k ? 14'd64 : 14'd480, 14'd16);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_snapshot;
         gpu_push(gpu_exec_word(GPU_COPY, 4'd5, 3'b000, 3'b000));
         gpu_x_setup(GPU_COPY, 4'd5, 3'b000, 3'b000);
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         repeat(150 + ($random(gpu_seed) & 255)) @(posedge free_clk);
         reg_wr(GPU_CTRL, 32'h2);
         repeat(10) @(posedge free_clk);
         reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR);
         gpu_find_prefix(ta_n);
         ta_tot = gpu_x_w * gpu_x_h;
         if ((ta_n <= 0) || (ta_n >= ta_tot)) begin
            $display("ERROR: GPU abandoned word-token copy -- image is not a strict prefix (n = %0d of %0d) %t", ta_n, ta_tot, $time);
            error = error + 1;
         end else
            $display("OK:    GPU word-token copy abandoned after %0d of %0d pixels (clean prefix)", ta_n, ta_tot);
         gpu_check_touched("abandoned word-token copy");
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
      end

      $display("--- CLEAR_ERR outside ERR while a rectangle runs: queue flushed");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 32'd50000);
      gpu_c_size(14'd20, 14'd10);
      gpu_c_fill(32'h0000_1234);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_snapshot;
      gpu_push(gpu_exec_word(GPU_FILL, 4'd5, 3'b000, 3'b000));
      gpu_x_setup(GPU_FILL, 4'd5, 3'b000, 3'b000);
      gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      gpu_push({OP_FENCE, 28'h100_0001});
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
      if (GPU_RUNAHEAD_EN == 0)
         reg_rd_mask(GPU_STAT, 32'h0000_0200, 32'h0000_FF00);   // 2 queued
      else begin                                              // run-ahead: the FILL may be in the set-up
         reg_rd_val(GPU_STAT, ta_flag);
         if ((ta_flag[15:8] != 8'd1) && (ta_flag[15:8] != 8'd2)) begin
            $display("ERROR: GPU_STAT.USED = %0d with run-ahead, 1 or 2 expected %t", ta_flag[15:8], $time);
            error = error + 1;
         end
      end
      reg_wr(GPU_CTRL, 32'h1);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | GS_ERR | 32'hFF00);
      gpu_wait_idle;
      reg_rd_val(IRQ_FLAG, ta_flag);
      gpu_find_prefix(ta_n);
      ta_tot = gpu_x_w * gpu_x_h;
      if ((ta_n != ta_tot) || !ta_flag[4]) begin
         $display("ERROR: GPU CLEAR_ERR during a rectangle -- %0d of %0d pixels drawn, GPU_DONE %0d (the rectangle must complete; the queued op 14 must not run) %t",
                  ta_n, ta_tot, ta_flag[4], $time);
         error = error + 1;
      end else
         $display("OK:    GPU CLEAR_ERR during a rectangle: the rectangle completed (GPU_DONE), the queue flushed");
      reg_rd(GPU_FENCE, 32'h0);
      gpu_check_touched("CLEAR_ERR during rectangle");

      // ABORT in the middle of the other kinds, with the walk record
      for (ta_k = 0; ta_k < 10; ta_k = ta_k + 1)
         ta_kind(ta_k % 5);

      gpu_check_all("abort end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
