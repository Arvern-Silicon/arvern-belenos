//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_a8_err
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_a8_err.v
// Module Description : Errors and state of the per-pixel alpha commands, in
//                      every GPU build (the causes depend on the build:
//                      GPU_BLEND_EN, GPU_BILINEAR_EN and GPU_XY_EN,
//                      GPU_MPLANE_EN, GPU_IMM_EN):
//                      - SET_SRC SRC_FMT 5: taken with blending, else cause 2;
//                        6..15 cause 3 (also with IMM);
//                      - SET_AUX SEL 4 ALPHA_PLANE: PITCH != 0 cause 2 in
//                        every build, absent without blending (2); SEL 5
//                        TEX_FILTER: absent without bilinear (2), TBORDER
//                        without blending (2); SEL 6..15 cause 1; a refused
//                        SET_AUX takes no operand: as a list's last word it
//                        reports its own cause, an accepted one is a list cut
//                        (4);
//                      - blend builds: an RGB565A8 copy with MPLANE (cause 1,
//                        2 without the mask plane) or taking the immediate
//                        source (1); EXEC_EXPAND with SRC_FMT 5 (3); FILL and
//                        SPAN ignore SRC_FMT 5; an A8 word at or past
//                        VRAM_WORDS (cause 5, GPU_ERR the EXEC, no GPU_DONE):
//                        the pixels before it drawn, its pixel and the rest
//                        not (a copy, a keyed copy whose faulting pixel is
//                        keyed, a texture span);
//                      - the alpha pointer and MIX5 kept through CLEAR_ERR,
//                        ABORT and GPU_EN = 0, 0 after RESET_STATE; an
//                        ALPHA_PLANE cut between its word and its operand by
//                        a flush changes nothing (its operand discarded).
//                      Each refusal: ERR_OPCODE, ERR_CAUSE, GPU_ERR,
//                      GPU_LIST, the GPU_ERR interrupt without GPU_DONE,
//                      then a recovery fill against the model.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer AE_LST   = 1000;              // command lists: words [1000, 1100)
localparam integer AE_SRC   = 2000;              // sources: words [2000, 3000)
localparam integer AE_DST   = 4000;              // destinations: words [4000, 6000)
localparam integer AE_APL   = 7000;              // A8 plane: words [7000, 8000)
localparam  [31:0] AE_REC   = 32'hFE40_0000;     // ERR_OPCODE, ERR_CAUSE, ERR

integer    ae_k, ae_i, ae_n, ae_w, ae_first, ae_nbad;
reg [31:0] ae_caps, ae_st, ae_flag, ae_xw, ae_ab;
reg        ae_bl, ae_bil;

function ae_opnd;                        // the word takes an operand (push side)
   input [31:0] w;
   begin
      ae_opnd = (w[31:28] == OP_SET_SRC) || (w[31:28] == OP_SET_DST) || (w[31:28] == OP_SET_FILL) ||
                (w[31:28] == OP_SET_TRANSP) || (w[31:28] == OP_CALL) ||
                ((w[31:28] == OP_SET_EXT) && ((w[27:24] == 4'd1) || (w[27:24] == 4'd2) || (w[27:24] == 4'd4) ||
                                              (w[27:24] == 4'd5) || (w[27:24] == 4'd9) || (w[27:24] == 4'd10) ||
                                              (w[27:24] == 4'd11) || (w[27:24] == 4'd12) || (w[27:24] == 4'd13)));
   end
endfunction

// A recovery fill against the model
task ae_fill;
   begin
      gpu_c_dst(16'd64, 2 * AE_DST + 2 * ($random(gpu_seed) & 255));
      gpu_c_size(14'd3, 14'd2);
      gpu_c_fill($random(gpu_seed));
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("recovery fill");
   end
endtask

// The GPU must be stopped with this record; then CLEAR_ERR (record kept) and
// a fill must run. lst: the expected GPU_LIST (0: none)
task ae_expect;
   input  [3:0] op;
   input  [2:0] cause;
   input [31:0] word;
   input [31:0] lst;
   input [8*56-1:0] label;
   integer      guard;
   begin
      guard = 0;
      ae_st = 32'h0;
      while (!(ae_st & GS_ERR) && (guard < 400)) begin
         reg_rd_val(GPU_STAT, ae_st);
         guard = guard + 1;
      end
      reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 4000);
      reg_rd_val(GPU_STAT, ae_st);
      reg_rd_val(IRQ_FLAG, ae_flag);
      if (((ae_st & AE_REC) !== ({op, cause, 25'h0} | GS_ERR)) || !(ae_flag & IF_ERR) || (ae_flag & IF_DONE)) begin
         $display("ERROR: %0s -- GPU_STAT 0x%h, IRQ_FLAG 0x%h / expected ERR_OPCODE %h, ERR_CAUSE %0d, GPU_ERR interrupt, no GPU_DONE %t",
                  label, ae_st, ae_flag, op, cause, $time);
         error = error + 1;
      end else
         $display("OK:    %0s: ERR_OPCODE %h, ERR_CAUSE %0d", label, op, cause);
      reg_rd(GPU_ERR, word);
      reg_rd(GPU_LIST, lst);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_flush_hint = 1'b0;
      gpu_k_imm = 1'b0;                                          // the flush disarms
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_EMPTY, AE_REC | GS_EMPTY);   // the record kept
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      ae_fill;
   end
endtask

// A word pushed to GPU_CMD (with its operand when it takes one): refused with
// cause (0: taken, no error)
task ae_word;
   input [31:0] w;
   input  [2:0] cause;
   input [8*56-1:0] label;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push(w);
      if (ae_opnd(w)) gpu_push(32'h0000_0000);
      if (cause != 3'd0)
         ae_expect(w[31:28], cause, w, 32'h0, label);
      else begin
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         $display("OK:    %0s: taken", label);
      end
   end
endtask

// A list: SET_SIZE, then the word, the list ending there (its last word)
task ae_list_last;
   input [31:0] w;
   input  [3:0] op;
   input  [2:0] cause;
   input [8*56-1:0] label;
   integer      ii;
   begin
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_push({OP_SET_SIZE, 14'd1, 14'd1});
      gpu_push(w);
      gpu_cap_en = 1'b0;
      for (ii = 0; ii < gpu_cap_n; ii = ii + 1) begin
         vram_mem[AE_LST + ii]   = gpu_cap_buf[ii];
         gpu_shadow[AE_LST + ii] = gpu_cap_buf[ii];
      end
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
      gpu_push(AE_LST);
      ae_expect(op, cause, w, AE_LST + 1, label);
   end
endtask

// A copy (or texture span) whose A8 bytes run past VRAM_WORDS at pixel k of a
// row of n: cause 5, pixels 0 .. k-1 drawn (the model with gpu_oob_stop)
task ae_past;
   input integer kind;                   // 0 COPY, 1 COPY_TRANSP with pixel k keyed, 2 TEXSPAN
   input integer k;
   input integer n;
   integer       ii;
   reg   [31:0]  sb;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      sb    = 2 * AE_SRC + 64 + ($random(gpu_seed) & 31);
      ae_ab = 4 * VRAM_WORDS - k;                               // pixel k's alpha: the first byte past the VRAM
      for (ii = 0; ii < k; ii = ii + 1) begin                   // nonzero alphas before the fault
         vram_mem[(ae_ab + ii) >> 2]   = vram_mem[(ae_ab + ii) >> 2] | (32'h80 << (8 * ((ae_ab + ii) & 3)));
         gpu_shadow[(ae_ab + ii) >> 2] = vram_mem[(ae_ab + ii) >> 2];
      end
      gpu_c_dst(16'd64, 2 * AE_DST + 2 * ($random(gpu_seed) & 127));
      gpu_c_size(n, 14'd1);
      gpu_k_a8 = 1'b1;
      gpu_c_src(16'd64, sb);
      gpu_c_alpha_plane(ae_ab);
      gpu_c_alpha5(1'b0, 8'd0, $random(gpu_seed));
      if (kind == 1) gpu_c_transp({16'h0, gpu_get_px(sb + k, 4)});   // the faulting pixel keyed
      gpu_oob_ok   = 1'b1;
      gpu_oob_stop = 1'b1;
      gpu_oob_hit  = 1'b0;
      gpu_wait_idle;
      if (kind == 2) begin
         gpu_c_tex(4'd6, 4'd0, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);   // 64 x 1: u = i
         gpu_c_uv(16'd0, 16'd0);
         gpu_c_step(16'd2048, 16'd0);
         gpu_c_texspan(0, n);
         ae_xw = {OP_EXEC_TEX, 14'd0, n[13:0]};
      end else begin
         gpu_c_exec((kind == 1) ? GPU_COPYT : GPU_COPY, 4'd0, 3'b000, 3'b000);
         ae_xw = gpu_exec_word((kind == 1) ? GPU_COPYT : GPU_COPY, 4'd0, 3'b000, 3'b000);
      end
      gpu_k_a8 = 1'b0;
      if (!gpu_oob_hit) tb_error("gpu_a8_err: the A8 plane never reaches VRAM_WORDS (test bug)");
      gpu_oob_ok   = 1'b0;
      gpu_oob_stop = 1'b0;
      // (the prefix: the touched words, checked by the recovery fill's check)
      ae_expect((kind == 2) ? OP_EXEC_TEX : ((kind == 1) ? OP_EXEC_COPYT : OP_EXEC_COPY), 3'd5,
                (kind == 2) ? {OP_EXEC_TEX, 14'd0, n[13:0]} : ae_xw, 32'h0,
                (kind == 0) ? "A8 word past the VRAM: COPY" : (kind == 1) ? "A8 word past the VRAM: keyed pixel" :
                              "A8 word past the VRAM: TEXSPAN");
   end
endtask

// A blended one-row RGB565A8 copy with the settings the GPU holds
task ae_copy;
   input [8*40-1:0] label;
   begin
      gpu_c_dst(16'd64, 2 * AE_DST + 2 * ($random(gpu_seed) & 255));
      gpu_c_size(14'd9, 14'd2);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched(label);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   GPU: per-pixel alpha, errors and state      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      reg_rd_val(BLNS_CFG2, ae_caps);
      ae_bl  = (GPU_BLEND_EN != 0);
      ae_bil = (GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0);
      if (ae_caps[6] !== ae_bl)  tb_error("BLNS_CFG2.BLEND differs from the build");
      if (ae_caps[12] !== ae_bil) tb_error("BLNS_CFG2.BILINEAR differs from GPU_BILINEAR_EN && GPU_XY_EN");
      ae_caps = (ae_caps >> 8) & 32'h7;                         // [0] REMAP, [1] MPLANE, [2] IMM
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("=== SET_SRC SRC_FMT 5 / 6..15");
      ae_word({OP_SET_SRC, 8'h00, 4'd5, 16'd64}, ae_bl ? 3'd0 : 3'd2, "SET_SRC SRC_FMT 5");
      for (ae_k = 6; ae_k < 16; ae_k = ae_k + 1)
         ae_word({OP_SET_SRC, 8'h00, ae_k[3:0], 16'h0000}, 3'd3, "SET_SRC SRC_FMT 6..15");
      if (GPU_IMM_EN == 0)
         ae_word({OP_SET_SRC, 7'h00, 1'b1, 4'd5, 16'h0}, ae_bl ? 3'd2 : 3'd2, "SET_SRC IMM absent, SRC_FMT 5 (2)");
      gpu_c_src_fmt(16'd0, 2 * AE_SRC, 4'd0);

      $display("=== SET_AUX ALPHA_PLANE / TEX_FILTER / SEL 6..15");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd4, 4'h0, 16'h0001}, 3'd2, "ALPHA_PLANE PITCH 1");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd4, 4'h0, 16'h8000}, 3'd2, "ALPHA_PLANE PITCH 0x8000");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd4, 4'hF, 16'h0000}, ae_bl ? 3'd0 : 3'd2, "ALPHA_PLANE ([19:16] ignored)");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00000}, ae_bil ? 3'd0 : 3'd2, "TEX_FILTER nearest");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'hFFFFC}, ae_bil ? 3'd0 : 3'd2, "TEX_FILTER ([19:2] ignored)");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00002}, (ae_bil && ae_bl) ? 3'd0 : 3'd2, "TEX_FILTER TBORDER");
      ae_word({OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00000}, ae_bil ? 3'd0 : 3'd2, "TEX_FILTER back to nearest");
      for (ae_k = 6; ae_k < 16; ae_k = ae_k + 1)
         ae_word({OP_SET_EXT, EXT_SET_AUX, ae_k[3:0], 20'h00000}, 3'd1, "SET_AUX SEL 6..15");
      $display("--- as a list's last word: a refused one its own cause, a taken one a list cut");
      ae_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd4, 4'h0, 16'h0004}, OP_SET_EXT, 3'd2, "last word: ALPHA_PLANE PITCH (2)");
      ae_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd4, 20'h00000}, ae_bl ? OP_CALL : OP_SET_EXT, ae_bl ? 3'd4 : 3'd2,
                   "last word: ALPHA_PLANE");
      ae_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00001}, ae_bil ? OP_CALL : OP_SET_EXT, ae_bil ? 3'd4 : 3'd2,
                   "last word: TEX_FILTER");
      ae_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd5, 20'h00002}, (ae_bil && ae_bl) ? OP_CALL : OP_SET_EXT,
                   (ae_bil && ae_bl) ? 3'd4 : 3'd2, "last word: TEX_FILTER TBORDER");
      ae_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd6, 20'h00000}, OP_SET_EXT, 3'd1, "last word: SET_AUX SEL 6 (1)");
      ae_list_last({OP_SET_EXT, EXT_SET_AUX, 4'd15, 20'h00000}, OP_SET_EXT, 3'd1, "last word: SET_AUX SEL 15 (1)");
      ae_list_last({OP_SET_SRC, 8'h00, 4'd5, 16'h0}, OP_CALL, 3'd4, "last word: SET_SRC SRC_FMT 5 (4)");
      if (ae_bil) begin                                          // a taken TEX_FILTER: back to nearest
         gpu_c_tex_filter(1'b0, 1'b0);
         gpu_wait_idle;
      end

      //--------------------------------------------------------------
      if (ae_bl) begin
         $display("=== RGB565A8 commands (blend build)");
         gpu_c_alpha_plane(4 * AE_APL);
         gpu_c_src_fmt(16'd64, 2 * AE_SRC, 4'd5);
         ae_word(gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000) | 32'h800, ae_caps[1] ? 3'd1 : 3'd2,
                 "COPY SRC_FMT 5 with MPLANE");
         ae_word(gpu_exec_word(GPU_COPYT, 4'd0, 3'b000, 3'b000) | 32'h800, ae_caps[1] ? 3'd1 : 3'd2,
                 "COPY_TRANSP SRC_FMT 5 with MPLANE");
         ae_word({OP_EXEC_EXP, 14'h0000, 14'h0000}, 3'd3, "EXEC_EXPAND with SRC_FMT 5");
         if (ae_caps[2]) begin
            gpu_c_size(14'd4, 14'd1);
            gpu_c_imm(4'h5, 2);
            gpu_wait_idle;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_push(gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000));
            gpu_push(32'h1111_1111);
            gpu_push(32'h2222_2222);
            ae_expect(OP_EXEC_COPY, 3'd1, gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000), 32'h0,
                      "COPY SRC_FMT 5 taking the immediate source");
            gpu_c_size(14'd4, 14'd1);
            gpu_c_imm(4'h5, 2);
            gpu_wait_idle;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_push(gpu_exec_word(GPU_COPYT, 4'd0, 3'b000, 3'b000));
            gpu_push(32'h1111_1111);
            gpu_push(32'h2222_2222);
            ae_expect(OP_EXEC_COPYT, 3'd1, gpu_exec_word(GPU_COPYT, 4'd0, 3'b000, 3'b000), 32'h0,
                      "COPY_TRANSP SRC_FMT 5 taking the immediate source");
         end
         $display("--- FILL and SPAN ignore SRC_FMT 5");
         gpu_c_src_fmt(16'd64, 2 * AE_SRC, 4'd5);
         gpu_c_alpha5(1'b1, 8'd99, 1'b1);
         gpu_c_dst(16'd64, 2 * AE_DST + 300);
         gpu_c_size(14'd7, 14'd2);
         gpu_c_fill($random(gpu_seed));
         gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000));
         gpu_d_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_push({OP_EXEC_SPAN, 14'd20, 14'd5});
         gpu_d_span(14'd20, 14'd5);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("FILL / SPAN with SRC_FMT 5");
         gpu_c_alpha(1'b0, 8'd0);

         $display("--- an A8 word past VRAM_WORDS: cause 5, the pixels before drawn");
         if ((VRAM_WORDS < (1 << VRAM_AW)) || (VRAM_AW < 28)) begin
            // every fault position 1 .. 9 of each kind: the pixel before the
            // fault blended (it reads D) while F asks for the A8 word past the
            // VRAM must still be drawn
            for (ae_k = 0; ae_k < 27; ae_k = ae_k + 1)
               ae_past(ae_k % 3, 1 + ae_k / 3, 12);
         end

         $display("=== the alpha pointer and MIX5: kept through the flushes, 0 at RESET_STATE");
         gpu_c_alpha_plane(4 * AE_APL + 3);
         gpu_c_alpha5(1'b0, 8'd0, 1'b1);
         gpu_k_a8 = 1'b1;
         gpu_c_src(16'd64, 2 * AE_SRC + 5);
         for (ae_k = 0; ae_k < 4; ae_k = ae_k + 1) begin
            gpu_wait_idle;
            gpu_flush(ae_k);
            ae_copy((ae_k == 0) ? "after CLEAR_ERR" : (ae_k == 1) ? "after ABORT" : (ae_k == 2) ? "after GPU_EN = 0" :
                                  "after CLEAR_ERR + ABORT");
         end
         $display("--- an ALPHA_PLANE cut by a flush: nothing changes, its operand discarded");
         for (ae_k = 0; ae_k < 2; ae_k = ae_k + 1) begin
            gpu_wait_idle;
            gpu_push({OP_SET_EXT, EXT_SET_AUX, 4'd4, 20'h00000});
            repeat(10) @(posedge free_clk);
            reg_wr(GPU_CTRL, ae_k ? 32'h2 : 32'h1);
            gpu_push(4 * AE_APL + 400);                         // the operand: discarded
            ae_copy("after a cut ALPHA_PLANE");
         end
         gpu_c_reset_state;
         gpu_set_dispw(64);
         gpu_k_a8 = 1'b1;
         gpu_c_src_fmt(16'd64, 2 * AE_SRC + 7, 4'd5);
         ae_copy("after RESET_STATE (pointer 0, rounding rule)");
         gpu_k_a8 = 1'b0;
         gpu_c_src_fmt(16'd0, 2 * AE_SRC, 4'd0);
      end

      gpu_check_all("gpu_a8_err end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
