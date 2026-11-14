//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_ext_list
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_ext_list.v
// Module Description : Length extremes of the command lists and of the
//                      immediate source:
//                        - CALL N = 2^24 - 1 at word 2 (list end past VRAM_WORDS:
//                          ERR_CAUSE 6, nothing run);
//                        - a list of VRAM_WORDS - 64 words (every length bit
//                          the VRAM allows), ABORTed after its first words
//                          (harmless SET_FILL pairs), the GPU idle and
//                          without error after it;
//                        - a list of 5 000 words (drawing commands, then
//                          SET_FILL pairs) run to its end, against the model;
//                        - an immediate source armed with N = 2^24 - 1 and
//                          disarmed, then re-armed with a short N;
//                        - an immediate COPY whose rectangle needs far more
//                          words than its N (the missing ones read 0): with
//                          a VRAM of 1 M words or more, 1022 x 514 pixels at
//                          16 bpp (262 654 data words), else 1022 x 40;
//                          the destination is checked through the backdoor;
//                        - a short list, then CALL N = 0 (nothing run) and
//                          CALL N = 2^24 - 1 again (cause 6): the CALL bound
//                          VRAM_WORDS - N rises to VRAM_WORDS and falls to
//                          its smallest after the short list's.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer EL_LST = 64;                      // the long list (aborted)
localparam integer EL_DST = 8192;                    // destinations of the 5 000-word list

integer    el_i, el_n, el_h, el_w, el_nbad, el_cl, el_dbase, el_pa;
reg [31:0] el_v, el_st;

function integer el_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      el_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

// The GPU stopped on an error of the given opcode and cause; cleared after it
task el_err;
   input [3:0] op;
   input [2:0] cause;
   begin
      reg_poll(GPU_STAT, GS_ERR, GS_ERR, 2000);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_wr(GPU_CTRL, 32'h1);                             // CLEAR_ERR
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: list and immediate-source lengths       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 38400)
         tb_skip_finish("|        (VRAM below 38 400 words)              |");
      gpu_seed = `SEED;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;
      gpu_preload_rand(0, 32768);
      gpu_model_init;
      gpu_set_dispw(64);
      gpu_set_mode(4);

      $display("--- CALL N = 2^24 - 1 at word 2: past VRAM_WORDS, cause 6");
      gpu_push({OP_CALL, 4'h0, 24'hFF_FFFF});
      gpu_push(32'd2);
      el_err(OP_CALL, 3'd6);
      gpu_check_all("after the refused CALL");

      $display("--- a list of VRAM_WORDS - 64 words, aborted after its first words");
      for (el_i = 0; el_i < 8192; el_i = el_i + 2) begin
         vram_mem[EL_LST + el_i]     = {OP_SET_FILL, 28'h0};
         vram_mem[EL_LST + el_i + 1] = el_i;
         gpu_shadow[EL_LST + el_i]     = {OP_SET_FILL, 28'h0};
         gpu_shadow[EL_LST + el_i + 1] = el_i;
      end
      el_n = VRAM_WORDS - EL_LST;
      gpu_push({OP_CALL, 4'h0, el_n[23:0]});
      gpu_push(EL_LST);
      repeat (300) @(posedge free_clk);
      tb_checks = tb_checks + 1;
      reg_rd_val(GPU_LIST, el_v);
      if ((el_v <= EL_LST) || (el_v >= EL_LST + 8192)) begin
         $display("ERROR: GPU_LIST 0x%h during the long list / expected inside [0x%h, 0x%h) %t",
                  el_v, EL_LST, EL_LST + 8192, $time);
         error = error + 1;
      end
      reg_wr(GPU_CTRL, 32'h2);                             // ABORT
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd(GPU_LIST, 32'h0);

      $display("--- a list of 5 000 words run to its end");
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      for (el_i = 0; el_i < 250; el_i = el_i + 1) begin
         gpu_c_dst(16'd100, (EL_DST + el_rnd(20000)) << 1);
         gpu_c_size(1 + el_rnd(8), 1 + el_rnd(4));
         gpu_c_fill($random(gpu_seed));
         gpu_c_src(16'd64, (EL_DST + el_rnd(20000)) << 1);
         gpu_c_exec(el_rnd(2) ? GPU_FILL : GPU_COPY, el_rnd(13), el_rnd(8), 3'b000);
      end
      if ((gpu_cap_n & 1) != 0) gpu_c_size(gpu_m_w, gpu_m_h);  // even: the SET_FILL pairs follow
      gpu_cap_en = 1'b0;
      if (gpu_cap_n > 4000) begin
         $display("ERROR: the captured list has %0d words, more than 4 000 (test bug) %t", gpu_cap_n, $time);
         error = error + 1;
      end
      el_cl = VRAM_WORDS - 5000;                           // the list at the top of the VRAM
      for (el_i = 0; el_i < 5000; el_i = el_i + 1) begin
         if (el_i < gpu_cap_n)
            el_v = gpu_cap_buf[el_i];
         else if (((el_i - gpu_cap_n) & 1) == 0)
            el_v = {OP_SET_FILL, 28'h0};
         else
            el_v = gpu_m_fill;                             // the fill stays the model's
         vram_mem[el_cl + el_i]   = el_v;
         gpu_shadow[el_cl + el_i] = el_v;
      end
      gpu_push({OP_CALL, 4'h0, 24'd5000});
      gpu_push(el_cl);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("5 000-word list");

      $display("--- immediate source armed with N = 2^24 - 1, disarmed, re-armed short");
      gpu_c_imm(4'h0, 24'hFF_FFFF);
      gpu_k_imm = 1'b0;
      gpu_c_src(16'd64, 32'd0);                            // a SET_SRC disarms it
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);

      if (VRAM_WORDS >= 1048576) begin el_w = 1022; el_h = 514; end
      else begin el_w = 1022; el_h = 40; end
      $display("--- immediate COPY %0d x %0d at 16 bpp with N = 2 (the rest reads 0)", el_w, el_h);
      el_dbase = VRAM_WORDS - (el_w * el_h) / 2 - 6000 - 64; // below the list
      gpu_imm_buf[0] = 32'h1234_5678;
      gpu_imm_buf[1] = 32'h9ABC_DEF0;
      gpu_c_size(el_w, el_h);
      gpu_c_dst(el_w, el_dbase * 2);
      gpu_c_imm(4'h0, 2);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      reg_poll(GPU_STAT, GS_BUSY, 32'h0, 4000000);         // up to 525 K pixels
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("long immediate COPY");
      // the destination, through the backdoor: 2 data words, then 0
      el_nbad = 0;
      tb_checks = tb_checks + 1;
      for (el_i = 0; el_i < (el_w * el_h) / 2; el_i = el_i + 1) begin
         el_v = (el_i == 0) ? 32'h1234_5678 : (el_i == 1) ? 32'h9ABC_DEF0 : 32'h0;
         if (vram_mem[el_dbase + el_i] !== el_v) begin
            el_nbad = el_nbad + 1;
            if (el_nbad <= 6)
               $display("ERROR: GPU immediate COPY -- word 0x%h = 0x%h / expected 0x%h %t",
                        el_dbase + el_i, vram_mem[el_dbase + el_i], el_v, $time);
         end
      end
      error = error + el_nbad;
      if (el_nbad == 0) $display("OK:    GPU immediate COPY -- %0d words", (el_w * el_h) / 2);

      $display("--- a short CALL after the long ones");
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_c_dst(16'd90, (EL_DST + el_rnd(20000)) << 1);
      gpu_c_size(1 + el_rnd(8), 1 + el_rnd(4));
      gpu_c_fill($random(gpu_seed));
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_cap_en = 1'b0;
      for (el_i = 0; el_i < gpu_cap_n; el_i = el_i + 1) begin
         vram_mem[EL_LST + el_i]   = gpu_cap_buf[el_i];
         gpu_shadow[EL_LST + el_i] = gpu_cap_buf[el_i];
      end
      gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
      gpu_push(EL_LST);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("short list");

      $display("--- CALL N = 0, then CALL N = 2^24 - 1 again (cause 6)");
      gpu_push({OP_CALL, 4'h0, 24'd0});
      gpu_push(EL_LST);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd(GPU_LIST, 32'h0);                              // never started
      gpu_push({OP_CALL, 4'h0, 24'hFF_FFFF});
      gpu_push(32'd2);
      el_err(OP_CALL, 3'd6);
      gpu_check_all("gpu_ext_list end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
