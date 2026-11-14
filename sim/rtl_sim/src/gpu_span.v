//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_span
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_span.v
// Module Description : EXEC_SPAN (opcode 0xB): destination base += DELTA
//                      (signed 14 bits), SET_SIZE WIDTH x 1, EXEC_FILL op 0
//                      without swaps. Chains of positive, zero and negative
//                      deltas at every GFX_MODE from sub-word bases with an
//                      odd destination pitch; DELTA +8191 / -8192 (or the
//                      largest that fits the VRAM); WIDTH 0 -> 1, WIDTH
//                      2^min(DIM_W,14)-1, bits above DIM_W ignored; state
//                      left behind (moved base, width x 1, pitch, SRC and
//                      TRANSP untouched) seen by EXEC_FILL / EXEC_COPY /
//                      EXEC_COPY_TRANSP and SET_SIZE + EXEC_FILL; op and
//                      swaps of a previous EXEC do not leak into a span;
//                      TRANSP = fill colour does not stop a span; no dst read
//                      at 8/16 bpp; GPU_DONE per span (flag and irq_o, only
//                      at completion); no ERR; a frozen FIFO filled to FULL
//                      with spans and mixed commands, and a FREE-paced burst;
//                      pixel-address wrap when VRAM_WORDS = 2^VRAM_AW.
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TN_PITCH = 37;

integer    tn_mode, tn_bl, tn_ppw, tn_px, tn_k, tn_d, tn_s, tn_w, tn_h, tn_n, tn_i;
integer    tn_lo, tn_cur, tn_tgt, tn_r;
reg [31:0] tn_base, tn_sbase;
reg  [3:0] tn_op;
reg  [2:0] tn_sw;

// Push one EXEC_SPAN and model it
task tn_span;
   input integer delta;
   input  [13:0] width;
   reg    [13:0] d14;
   begin
      d14 = delta;
      gpu_push({OP_EXEC_SPAN, d14, width});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_m_w        = ((width & GPU_DIM_MASK) == 0) ? 1 : (width & GPU_DIM_MASK);
      gpu_m_h        = 1;
      gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_x_run;
   end
endtask

task tn_check_irq;
   input exp;
   begin
      @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b %t", irq, exp, $time);
         error = error + 1;
      end else
         $display("OK:    irq_o = %b", irq);
   end
endtask

task tn_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR | 32'hF000_0000);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: EXEC_SPAN                         |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(64);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("--- span chains at every GFX_MODE, sub-word bases, pitch %0d", TN_PITCH);
      for (tn_mode = 0; tn_mode < 6; tn_mode = tn_mode + 1) begin
         gpu_set_mode(tn_mode);
         tn_bl   = gpu_bl(tn_mode);
         tn_ppw  = 32 >> tn_bl;
         tn_base = 16 * tn_ppw + ($random(gpu_seed) & (tn_ppw - 1)) + 4 * TN_PITCH;
         gpu_c_dst(TN_PITCH, tn_base);
         gpu_c_fill($random(gpu_seed));
         tn_span(0, 14'd0);                              // width 0 -> 1, delta 0
         tn_span(2, 14'd3);
         tn_span(5, 14'd7);
         tn_span(0, 14'd2);                              // zero delta, redraw
         tn_span(TN_PITCH, 14'd9);                       // next line
         gpu_c_fill($random(gpu_seed));
         tn_span(-1, 14'd1);
         tn_span(-3, 14'd4);
         tn_span(TN_PITCH - 6, 14'd11);
         tn_span(-2 * TN_PITCH, 14'd6);                  // back up two lines
         tn_span(1, 14'd0);
         tn_span(tn_ppw, tn_ppw & 15);                   // one word further
         tn_span(3 * TN_PITCH + 1, 14'd13);
         tn_span(-3 * TN_PITCH, 14'd5);
         gpu_wait_idle;
         tn_no_err;
         $display("       mode %0d base 0x%h", tn_mode, tn_base);
         gpu_check_touched("span chain");
      end
      gpu_check_all("span chains");

      //--------------------------------------------------------------
      $display("--- extreme deltas +8191 / -8192 (largest that fits)");
      for (tn_mode = 0; tn_mode < 5; tn_mode = tn_mode + 1) begin
         gpu_set_mode(tn_mode);
         tn_bl  = gpu_bl(tn_mode);
         tn_ppw = 32 >> tn_bl;
         tn_px  = VRAM_WORDS * tn_ppw;
         tn_d   = (tn_px - 80) / 2;
         if (tn_d > 8191) tn_d = 8191;
         tn_s   = tn_d + 18 + ($random(gpu_seed) & (tn_ppw - 1));
         gpu_c_dst(16'd200, tn_s);
         gpu_c_fill($random(gpu_seed));
         tn_span(tn_d,        14'd3);                    // S + d
         tn_span(-(tn_d + 1), 14'd2);                    // S - 1
         tn_span(-(tn_d + 1), 14'd3);                    // S - 2 - d
         tn_span(tn_d,        14'd1);                    // S - 2
         gpu_wait_idle;
         tn_no_err;
         $display("       mode %0d start 0x%h delta +%0d / -%0d", tn_mode, tn_s, tn_d, tn_d + 1);
         if (gpu_m_dst_base != tn_s - 2)
            tb_error("span extreme chain did not end at S - 2 (test bug)");
         gpu_check_touched("span extreme deltas");
      end

      //--------------------------------------------------------------
      $display("--- WIDTH maximum %0d, field truncation", GPU_DIM_MASK);
      gpu_set_mode(0);
      gpu_c_dst(16'd0, 32'd64 * 32 + 5);
      gpu_c_fill(32'hFFFF_FFFF);
      tn_span(0, GPU_DIM_MASK);
      gpu_wait_idle;
      gpu_check_touched("span width max 1 bpp");
      gpu_c_fill(32'h0);
      tn_span(-3, GPU_DIM_MASK);
      gpu_wait_idle;
      gpu_check_touched("span width max 1 bpp, -3");
      if (DIM_W < 14) begin
         tn_span(7, (14'd1 << DIM_W) | 14'd3);           // bits above DIM_W ignored: 3
         tn_span(7, 14'd1 << DIM_W);                     // -> 0 -> 1
         tn_span(7, 14'h3FFF);                           // -> 2^DIM_W - 1
         gpu_wait_idle;
         gpu_check_touched("span width truncated");
      end
      if (101 + GPU_DIM_MASK + 4 < VRAM_WORDS * 2) begin
         gpu_set_mode(4);
         gpu_c_dst(16'd0, 32'd101);
         gpu_c_fill($random(gpu_seed));
         tn_span(0, GPU_DIM_MASK);
         gpu_wait_idle;
         gpu_check_touched("span width max 16 bpp");
      end
      tn_no_err;
      gpu_check_all("span width");

      //--------------------------------------------------------------
      $display("--- no leak of op / swaps, state left behind");
      for (tn_i = 0; tn_i < 2; tn_i = tn_i + 1) begin
         tn_mode = (tn_i == 0) ? 2 : 4;
         gpu_set_mode(tn_mode);
         tn_bl   = gpu_bl(tn_mode);
         tn_sbase = 200 + 5 + 3 * 41;
         tn_base  = 900 + 5 * 29 + 3;
         gpu_c_src(16'd41, tn_sbase);
         gpu_c_dst(16'd29, tn_base);
         gpu_c_size(14'd6, 14'd4);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(gpu_get_px(tn_sbase + 2, tn_bl));       // a pixel the later COPY_TRANSP reads
         gpu_c_exec(GPU_FILL, 4'd5, 3'b100, 3'b000);           // XOR, X swap
         gpu_c_exec(GPU_COPY, 4'd9, 3'b111, 3'b110);           // all swaps
         gpu_c_fill($random(gpu_seed));
         tn_span(7, 14'd9);                                   // plain S, left to right
         gpu_wait_idle;
         gpu_check_touched("span after XOR/swapped EXECs");
         gpu_c_fill($random(gpu_seed));
         gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);          // XOR over 9 x 1 at moved base
         gpu_wait_idle;
         gpu_check_touched("EXEC_FILL XOR after span");
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);          // SRC untouched by the span
         gpu_c_exec(GPU_FILL, 4'd5, 3'b100, 3'b000);          // XOR, X swap from the moved base
         tn_span(TN_PITCH, 14'd4);
         gpu_c_exec(GPU_COPYT, 4'd0, 3'b000, 3'b000);         // TRANSP untouched by the span
         gpu_wait_idle;
         gpu_check_touched("COPY / COPY_TRANSP after span");
         gpu_c_transp(gpu_m_fill);                             // TRANSP = fill: span still writes
         tn_span(-TN_PITCH + 2, 14'd5);
         gpu_c_size(14'd4, 14'd3);                             // normal rectangle, pitch 29 kept
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         tn_span(-29, 14'd2);                                  // height back to 1
         gpu_c_exec(GPU_FILL, 4'd14, 3'b000, 3'b000);
         gpu_wait_idle;
         tn_no_err;
         gpu_check_touched("SET_SIZE + EXEC_FILL after span");
         if (tn_bl >= 3) begin
            gpu_exp_rd = 0;
            gpu_exp_wr = 0;
            gpu_mon_start;
            tn_span(TN_PITCH + 1, 14'd9);
            gpu_wait_idle;
            gpu_mon_stop;
            if ((gpu_mon_rd != 0) || (gpu_mon_wr != gpu_exp_wr)) begin
               $display("ERROR: span at %0d bpp: %0d reads / %0d writes, expected 0 / %0d %t",
                        1 << tn_bl, gpu_mon_rd, gpu_mon_wr, gpu_exp_wr, $time);
               error = error + 1;
            end else
               $display("OK:    span at %0d bpp: 0 reads / %0d writes", 1 << tn_bl, gpu_exp_wr);
            gpu_check_touched("span access count");
         end
      end
      gpu_check_all("span state");

      //--------------------------------------------------------------
      $display("--- GPU_DONE per span, irq_o");
      gpu_set_mode(4);
      gpu_c_dst(16'd64, 32'd1300);
      gpu_c_fill($random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, IF_DONE);
      tn_check_irq(1'b0);
      for (tn_k = 0; tn_k < 4; tn_k = tn_k + 1) begin
         tn_span(20, 2 + tn_k);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         tn_check_irq(1'b1);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tn_check_irq(1'b0);
      end
      gpu_c_fill($random(gpu_seed));                     // configuration: no GPU_DONE
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      tn_check_irq(1'b0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      if (GPU_DIM_MASK >= 255) begin
         tn_span(20, 14'd255);                           // GPU_DONE only at completion
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
      end
      reg_wr(IRQ_EN, 32'h0);
      tn_no_err;
      gpu_check_touched("span GPU_DONE");

      //--------------------------------------------------------------
      $display("--- frozen FIFO filled to FULL with spans and mixed commands");
      gpu_set_mode(1);
      gpu_c_dst(16'd50, 32'd6000 + 1);
      gpu_c_fill($random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push_wait = 1'b0;
      gpu_freeze(1'b1);
      tn_n = 0;
      while (tn_n < GPU_FIFO_DEPTH) begin
         tn_r = $random(gpu_seed) & 7;
         if ((tn_r == 0) && (tn_n + 3 <= GPU_FIFO_DEPTH)) begin
            gpu_c_fill($random(gpu_seed));
            tn_n = tn_n + 2;
         end else if (tn_r == 1) begin
            gpu_c_exec(GPU_FILL, $random(gpu_seed), 3'b000, 3'b000);
            tn_n = tn_n + 1;
         end else begin
            tn_span(($random(gpu_seed) & 63) - 24, $random(gpu_seed) & 15);
            tn_n = tn_n + 1;
         end
      end
      reg_rd(GPU_STAT, GS_HELD | GS_BUSY | GS_FULL | (GPU_FIFO_DEPTH << 8));
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      gpu_freeze(1'b0);
      gpu_push_wait = 1'b1;
      gpu_wait_idle;
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("frozen FIFO burst");

      //--------------------------------------------------------------
      $display("--- FREE-paced bursts mixing spans, SET_SIZE, SET_FILL, EXEC_FILL");
      for (tn_i = 0; tn_i < 2; tn_i = tn_i + 1) begin
         tn_mode = (tn_i == 0) ? 0 : 3;
         gpu_set_mode(tn_mode);
         tn_lo  = 1000;
         tn_cur = tn_lo + 200;
         gpu_c_dst(16'd50, tn_cur);
         gpu_c_fill($random(gpu_seed));
         for (tn_k = 0; tn_k < 3 * GPU_FIFO_DEPTH; tn_k = tn_k + 1) begin
            tn_r = $random(gpu_seed) & 15;
            if (tn_r == 0)
               gpu_c_fill($random(gpu_seed));
            else if (tn_r == 1) begin
               tn_w = $random(gpu_seed) & 15;
               tn_h = 1 + (($random(gpu_seed) & 3) % 3);
               gpu_c_size(tn_w, tn_h);
            end else if (tn_r < 4) begin
               tn_op = $random(gpu_seed);
               tn_sw = $random(gpu_seed);
               gpu_c_exec(GPU_FILL, tn_op, tn_sw, 3'b000);
            end else begin
               tn_tgt = tn_lo + (($random(gpu_seed) & 32'h7FFF_FFFF) % 400);
               tn_span(tn_tgt - tn_cur, $random(gpu_seed) & 15);
               tn_cur = tn_tgt;
            end
         end
         gpu_wait_idle;
         reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         $display("       mode %0d", tn_mode);
         gpu_check_touched("FREE-paced burst");
      end

      //--------------------------------------------------------------
      if (VRAM_WORDS == (1 << VRAM_AW)) begin
         $display("--- pixel-address wrap at PA_W (1 bpp)");
         gpu_set_mode(0);
         gpu_c_dst(16'd0, 32'd3);
         gpu_c_fill(32'h1);
         tn_span(-8, 14'd5);                             // last 5 pixels of VRAM
         gpu_c_fill(32'h0);
         tn_span(3, 14'd4);                              // crosses the top: -2, -1, 0, 1
         tn_span(5, 14'd2);                              // back at 3
         gpu_wait_idle;
         tn_no_err;
         gpu_check_touched("span address wrap");
      end

      tn_no_err;
      gpu_check_all("span end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
