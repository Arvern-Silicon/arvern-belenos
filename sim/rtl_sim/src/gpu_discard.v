//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_discard
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_discard.v
// Module Description : GPU_CTRL [2] DISCARD (every build with a GPU).
//                      Not partial (whole commands queued, GPU_EN = 0): no
//                      marker, nothing changes. P1, an operand owed
//                      (SET_FILL, SET_TRANSP, CALL, EXEC_FILL LINE, SET_SRC
//                      IMM before its N; the decoder already waiting for it,
//                      or the command still queued behind work; after a
//                      flush's skip): a marker (USED + 1), the command
//                      dropped (its operand's setting not taken, the CALL
//                      runs nothing, the line draws nothing and the pen does
//                      not move), the next word a command. P2, immediate data
//                      owed (IMM): the rectangle abandoned at the marker
//                      after 0, 1, some and N - 1 of its N words, the FIFO
//                      empty or the data still queued: a clean prefix of the
//                      copy, no pixel past its data, no GPU_DONE; dropped in
//                      the set-up stage or in the engine (both seen), a
//                      rectangle the engine draws meanwhile (run-ahead)
//                      untouched; the next immediate copy takes its own
//                      data. P3, SET_SRC IMM and N pushed: disarmed (the
//                      next copy reads the VRAM); the marker drained on the
//                      idle GPU raises no GPU_IDLE (P1 waiting: one). The FIFO full: the marker
//                      pending (FREE 0, FULL, a push dropped with GPU_OVFL),
//                      queued at the first room, also cutting immediate data.
//                      With ABORT / CLEAR_ERR in the same write, and in ERR:
//                      no marker, the stream in step after the CLEAR_ERR;
//                      ABORT | CLEAR_ERR | DISCARD as the recover from each
//                      cut (no GPU_EN pulse); CLEAR_ERR | DISCARD in the
//                      data: the rectangle completes with 0. Every cycle: a
//                      pending marker reads FREE 0 and FULL. A marker at
//                      every write position of a FIFO above 32 entries.
//                      Whole VRAM against gpu_model.v at the end.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer DC_P    = 128;                // destination pitch (pixels)
localparam integer DC_SLO  = 2048;               // VRAM source region: words [2048, 4096)
localparam integer DC_DLO  = 4096;               // destination region: words [4096, 6144)
localparam integer DC_LLO  = 8192;               // command list: words [8192, 8200)
localparam integer DC_WMAX = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer DC_HMAX = (GPU_DIM_MASK >= 24) ? 24 : GPU_DIM_MASK;
localparam [31:0]  DC_DISC = 32'h4;              // GPU_CTRL [2] DISCARD

`define DC_GPU dut.u_core.G_GPU.u_gpu

integer    dc_i, dc_j, dc_k, dc_n, dc_cls, dc_nd, dc_used;
integer    dc_n_su, dc_n_eng, dc_n_pend;
reg [31:0] dc_st, dc_t, dc_fill0;
reg        dc_imm, dc_line, dc_ra;

function integer dc_rnd;                         // uniform in [0, n)
   input integer n;
   begin
      dc_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

// Every cycle: a pending marker holds the room (FREE 0, FULL); where an
// abandon drops the immediate rectangle (the set-up stage or the engine)
initial begin dc_n_su = 0; dc_n_eng = 0; dc_n_pend = 0; end
always @(posedge hclk)
   if ((GPU_EN != 0) && (hresetn_d === 1'b1)) begin
      if (`DC_GPU.mrk_pend === 1'b1) begin
         dc_n_pend = dc_n_pend + 1;
         if ((`DC_GPU.gpu_stat[7:0] !== 8'h00) || (`DC_GPU.gpu_stat[17] !== 1'b1)) begin
            $display("ERROR: a pending marker with GPU_STAT 0x%h (FREE must be 0, FULL 1) %t", `DC_GPU.gpu_stat, $time);
            error = error + 1;
         end
      end
      if (`DC_GPU.imm_drop === 1'b1) begin
         if (`DC_GPU.imm_eng === 1'b1) dc_n_eng = dc_n_eng + 1;
         else                          dc_n_su  = dc_n_su + 1;
      end
   end

task dc_mode;
   begin
      gpu_wait_idle;
      gpu_preload_rand(DC_SLO, DC_SLO + 2048);
      gpu_preload_rand(DC_DLO, DC_DLO + 2048);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      dc_fill0 = $random(gpu_seed);
      gpu_c_fill(dc_fill0);
      gpu_c_transp($random(gpu_seed));
      gpu_c_src(DC_P, DC_SLO * 2);
      gpu_c_size(8, 3);
   end
endtask

task dc_disc;
   input [31:0] bits;
   begin
      reg_wr(GPU_CTRL, bits | DC_DISC);
      gpu_flush_hint = 1'b0;                     // SET_SRC kept: nothing to re-send
   end
endtask

// USED as GPU_STAT reads it now
task dc_used_rd;
   begin
      reg_rd_val(GPU_STAT, dc_st);
      dc_used = (dc_st >> 8) & 32'hFF;
   end
endtask

// A FILL at a random spot with the settings the model holds: drawn as modelled
task dc_probe_fill;
   input [8*40-1:0] label;
   begin
      gpu_c_dst(DC_P, (DC_DLO * 2) + (20 + dc_rnd(8)) * DC_P + dc_rnd(64));
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      gpu_check_touched(label);
   end
endtask

// P1: the command word cw (its operand owed) pushed, then DISCARD; queued:
// behind a frozen GPU (the marker counted in USED), else the decoder waits
// for the operand
task dc_p1;
   input [31:0] cw;
   input        queued;
   input [8*24-1:0] name;
   begin
      $display("       %0s, %0s", name, queued ? "queued (frozen)" : "the decoder waiting");
      if (queued) gpu_freeze(1'b1);
      gpu_push(cw);
      if (queued) begin
         dc_used_rd;
         dc_disc(32'h0);
         reg_rd_mask(GPU_STAT, (dc_used + 1) << 8, 32'hFF00);   // the marker: one word
         gpu_freeze(1'b0);
      end else begin
         repeat(20) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_EMPTY | GS_BUSY, GS_EMPTY | GS_BUSY | GS_ERR);   // operand wait
         reg_wr(IRQ_FLAG, IF_IDLE);
         dc_disc(32'h0);
      end
      gpu_wait_idle;
      if (!queued) reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_IDLE);  // BUSY fell after the push: GPU_IDLE
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      dc_probe_fill(name);
   end
endtask

// P2: an immediate copy of w x h (16 bpp) cut after j of its n words.
// how: 0 the GPU has taken every word (the FIFO empty at the DISCARD), 1 the
// words queued behind a frozen GPU, 2 the FIFO full (pending marker),
// 3 ABORT | CLEAR_ERR | DISCARD, 4 CLEAR_ERR | DISCARD (completes with 0).
// behind: a long FILL drawn first (run-ahead: the copy waits in the set-up)
task dc_p2;
   input integer how;
   input integer jsel;                           // 0: 0 words, 1: 1, 2: random, 3: n - 1
   input         behind;
   integer       w, h, n, j, ii;
   reg    [31:0] fl;
   begin
      w = DC_WMAX;
      h = ((how == 1) || (how == 2)) ? (2 * GPU_FIFO_DEPTH) / DC_WMAX + 1 : DC_HMAX;   // queued: N > the depth
      if (h > DC_HMAX) h = DC_HMAX;
      n = (w * h + 1) / 2;
      j = (jsel == 0) ? 0 : (jsel == 1) ? 1 : (jsel == 3) ? n - 1 : 2 + dc_rnd(n - 3);
      if ((how == 1) && (j > GPU_FIFO_DEPTH - 4)) j = GPU_FIFO_DEPTH - 4;   // queued: the words and the marker fit
      if (how == 2) j = GPU_FIFO_DEPTH - 3;      // SET_SRC + N + EXEC + j data words: the FIFO full
      if (j > n - 1) j = n - 1;
      if (behind) begin
         gpu_c_size(GPU_DIM_MASK >= 64 ? 64 : GPU_DIM_MASK, GPU_DIM_MASK >= 16 ? 16 : GPU_DIM_MASK);
         gpu_c_dst(DC_P, (DC_DLO * 2) + 30 * DC_P);
         gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);     // op 5 reads D: slow
      end
      gpu_c_size(w, h);
      gpu_c_dst(DC_P, (DC_DLO * 2) + 2 * DC_P + 8 + dc_rnd(16));
      if (!behind) gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      for (ii = 0; ii < n; ii = ii + 1)
         gpu_imm_buf[ii] = $random(gpu_seed);
      gpu_imm_n = n;
      if (how != 4) begin                        // the model: the whole copy, recorded (a prefix of it)
         gpu_x_setup(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_k_imm = 1'b1;
         gpu_x_take_imm;
         gpu_rec_begin;
         gpu_x_run;
         gpu_rec_end;
         gpu_x_imm = 1'b0;
      end
      if ((how == 1) || (how == 2)) gpu_freeze(1'b1);
      gpu_push({OP_SET_SRC, 7'h00, 1'b1, 4'h0, gpu_m_src_pitch});
      gpu_push(n);
      gpu_push(gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000));
      for (ii = 0; ii < j; ii = ii + 1)
         gpu_push(gpu_imm_buf[ii]);
      $display("       %0s, cut after %0d of %0d data words%0s",
               (how == 0) ? "taken" : (how == 1) ? "queued" : (how == 2) ? "FIFO full" :
               (how == 3) ? "ABORT | CLEAR_ERR | DISCARD" : "CLEAR_ERR | DISCARD", j, n,
               behind ? ", behind a FILL" : "");
      if ((how != 1) && (how != 2) && !behind) begin   // every word taken: the engine waits for data
         dc_st = 32'hFF00;
         while ((dc_st & 32'hFF00) != 32'h0) reg_rd_val(GPU_STAT, dc_st);
         repeat(40) @(posedge free_clk);
      end
      if (how == 2) begin
         reg_rd_mask(GPU_STAT, GS_FULL | (GPU_FIFO_DEPTH << 8), GS_FULL | 32'hFFFF);
         dc_disc(32'h0);
         reg_rd_mask(GPU_STAT, GS_FULL | (GPU_FIFO_DEPTH << 8), GS_FULL | 32'hFFFF);   // FREE 0: pending
         reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h0DEAD0});            // dropped
         reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
      end else if (how == 3) dc_disc(32'h3);
      else if (how == 4)     dc_disc(32'h1);
      else                   dc_disc(32'h0);
      if ((how == 1) || (how == 2)) gpu_freeze(1'b0);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      reg_rd_val(IRQ_FLAG, fl);
      if (how == 4) begin
         // CLEAR_ERR: the whole rectangle, the data not taken read 0
         if (!fl[4]) tb_error("gpu_discard: no GPU_DONE for the copy completed after CLEAR_ERR | DISCARD");
         gpu_imm_n = j;
         gpu_x_setup(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_k_imm = 1'b1;
         gpu_x_take_imm;
         gpu_x_run;
         gpu_x_imm = 1'b0;
         gpu_check_touched("CLEAR_ERR | DISCARD: the rest read 0");
      end else begin
         if (behind) fl[4] = 1'b0;               // (the FILL's GPU_DONE)
         gpu_rec_prefix(fl[4], dc_cls, dc_nd);
         if (((dc_cls != 1) && (dc_cls != 0)) || (dc_nd > 2 * j)) begin
            $display("ERROR: cut immediate copy -- class %0d, %0d pixels drawn (data for %0d) %t",
                     dc_cls, dc_nd, 2 * j, $time);
            error = error + 1;
         end
         gpu_check_touched("abandoned immediate copy");
      end
      gpu_k_imm      = 1'b0;
      gpu_m_src_fmt  = 4'h0;
      gpu_flush_hint = 1'b0;
      // the stream in step: a fence, then an immediate copy with its own data
      dc_t = 32'h00C0DE + how * 16 + jsel;
      gpu_push({OP_FENCE, 4'h0, dc_t[23:0]});
      gpu_c_size(w, 2);
      gpu_c_dst(DC_P, (DC_DLO * 2) + 40 * DC_P + 8);
      for (ii = 0; ii < w; ii = ii + 1)
         gpu_imm_buf[ii] = $random(gpu_seed);
      gpu_c_imm(4'h0, w);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd(GPU_FENCE, dc_t);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      gpu_check_touched("after the cut copy");
      gpu_c_src(DC_P, DC_SLO * 2);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: GPU_CTRL.DISCARD                  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < DC_LLO + 16)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      reg_rd_val(BLNS_CFG2, dc_st);
      dc_imm  = (dc_st & CFG2_IMM) != 0;
      dc_line = (dc_st & CFG2_LINE) != 0;
      dc_ra   = (GPU_RUNAHEAD_EN != 0);
      gpu_push_wait = 1'b1;
      dc_mode;

      //--------------------------------------------------------------
      $display("--- not partial: no marker, no change");
      gpu_freeze(1'b1);
      gpu_c_dst(DC_P, (DC_DLO * 2) + 4 * DC_P);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      dc_used_rd;
      dc_disc(32'h0);
      reg_rd_mask(GPU_STAT, dc_used << 8, 32'hFF00);
      gpu_freeze(1'b0);
      gpu_wait_idle;
      dc_disc(32'h0);                                         // idle, nothing owed
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      gpu_check_touched("not partial");
      $display("--- GPU_EN = 0: no effect");
      gpu_push({OP_SET_FILL, 28'h0});                         // owed ...
      reg_wr(CTRL, {29'h0, gpu_m_mode});                      // ... until GPU_EN = 0
      dc_disc(32'h0);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      reg_wr(CTRL, 32'h10 | gpu_m_mode);
      gpu_k_imm = 1'b0;
      gpu_m_lph = 0;
      dc_probe_fill("GPU_EN = 0");

      //--------------------------------------------------------------
      $display("--- P1: an operand owed");
      for (dc_k = 0; dc_k < 2; dc_k = dc_k + 1) begin
         dc_p1({OP_SET_FILL, 28'h0}, dc_k, "SET_FILL");
         dc_p1({OP_SET_TRANSP, 28'h0}, dc_k, "SET_TRANSP");
         // CALL of a list that would draw: it runs nothing
         gpu_cap_n  = 0;
         gpu_cap_en = 1'b1;
         gpu_push({OP_SET_FILL, 28'h0});
         gpu_push(~dc_fill0);
         gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000));
         gpu_cap_en = 1'b0;
         for (dc_i = 0; dc_i < gpu_cap_n; dc_i = dc_i + 1) begin
            vram_mem[DC_LLO + dc_i]   = gpu_cap_buf[dc_i];
            gpu_shadow[DC_LLO + dc_i] = gpu_cap_buf[dc_i];
         end
         dc_p1({OP_CALL, 4'h0, 24'd3}, dc_k, "CALL");
         if (dc_imm) begin
            // SET_SRC IMM with its N owed: armed at the word, disarmed by the marker
            dc_p1({OP_SET_SRC, 7'h00, 1'b1, 4'h0, gpu_m_src_pitch}, dc_k, "SET_SRC IMM (N owed)");
            gpu_c_size(8, 2);
            gpu_c_dst(DC_P, (DC_DLO * 2) + 12 * DC_P + 4);
            gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);       // reads the VRAM
            gpu_wait_idle;
            gpu_check_touched("the copy after SET_SRC IMM");
         end
         if (dc_line) begin
            // EXEC_FILL LINE without its end point: nothing drawn, the pen kept
            gpu_c_dst_xy(DC_P, DC_DLO * 2);
            gpu_c_pen(16 * 10 + 8, 16 * 30 + 8);
            gpu_wait_idle;
            dc_p1(gpu_line_word(4'd0, 4'h0), dc_k, "EXEC_FILL LINE");
            gpu_c_dst_xy(DC_P, DC_DLO * 2);
            gpu_c_line(16 * 40 + 8, 16 * 36 + 8, 4'd0, 4'h0);  // from the pen as it was
            gpu_wait_idle;
            gpu_check_touched("the line after the cut one");
            gpu_c_dst(DC_P, DC_DLO * 2);
         end
         gpu_c_size(8, 3);
      end
      $display("       after a flush's skip: the marker resolves it");
      gpu_push({OP_SET_FILL, 28'h0});
      repeat(20) @(posedge free_clk);                         // the decoder waits for the operand
      gpu_flush(1);                                           // ABORT: the operand would be skipped
      dc_disc(32'h0);
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      dc_probe_fill("after the skip");                        // its first word: a command
      $display("       with ABORT / CLEAR_ERR in the same write: no marker");
      for (dc_k = 1; dc_k < 4; dc_k = dc_k + 1) begin
         gpu_freeze(1'b1);
         gpu_push({OP_SET_FILL, 28'h0});
         dc_disc(dc_k);
         reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | 32'hFF00);   // flushed, no marker
         gpu_freeze(1'b0);
         gpu_k_imm = 1'b0;
         gpu_m_lph = 0;
         dc_probe_fill("DISCARD with a flush");
      end

      //--------------------------------------------------------------
      $display("--- in ERR: no marker, in step after the CLEAR_ERR");
      gpu_push(32'h0000_0000);                                // invalid: ERR
      gpu_push({OP_SET_FILL, 28'h0});
      repeat(20) @(posedge free_clk);
      dc_used_rd;
      if ((dc_st & GS_ERR) == 0) tb_error("gpu_discard: no ERR");
      dc_disc(32'h0);
      reg_rd_mask(GPU_STAT, GS_ERR | (dc_used << 8), GS_ERR | 32'hFF00);   // no marker
      reg_wr(GPU_CTRL, 32'h1);
      gpu_k_imm = 1'b0;
      gpu_m_lph = 0;
      dc_probe_fill("after ERR");
      $display("       ABORT | CLEAR_ERR | DISCARD in ERR with an operand owed");
      gpu_push(32'h0000_0000);
      gpu_push({OP_SET_DST, 28'h0});
      repeat(20) @(posedge free_clk);
      dc_disc(32'h3);
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
      gpu_k_imm = 1'b0;
      gpu_m_lph = 0;
      dc_probe_fill("recover in ERR");

      //--------------------------------------------------------------
      $display("--- the FIFO full: the marker pending");
      gpu_freeze(1'b1);
      for (dc_i = 0; dc_i < GPU_FIFO_DEPTH - 1; dc_i = dc_i + 1)
         gpu_c_fence(1'b0);
      gpu_push({OP_SET_FILL, 28'h0});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      dc_disc(32'h0);
      reg_rd_mask(GPU_STAT, GS_FULL | (GPU_FIFO_DEPTH << 8), GS_FULL | 32'hFFFF);
      reg_wr(GPU_CMD, {OP_FENCE, 4'h0, 24'h0DEAD1});          // dropped
      reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
      gpu_freeze(1'b0);
      gpu_wait_idle;
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      dc_probe_fill("after the pending marker");
      if (dc_n_pend == 0) tb_error("gpu_discard: no pending marker seen");

      //--------------------------------------------------------------
      if (dc_imm) begin
         $display("--- P2: immediate data owed");
         for (dc_k = 0; dc_k < 5; dc_k = dc_k + 1)
            for (dc_j = 0; dc_j < 4; dc_j = dc_j + 1)
               if ((dc_k != 2) || (dc_j == 0))
                  dc_p2(dc_k, dc_j, 1'b0);
         $display("       behind a FILL being drawn (run-ahead: the copy in the set-up)");
         for (dc_j = 0; dc_j < 4; dc_j = dc_j + 1)
            dc_p2(0, dc_j, 1'b1);
         dc_p2(1, 0, 1'b1);
         $display("       abandons: %0d in the set-up, %0d in the engine", dc_n_su, dc_n_eng);
         if ((dc_n_su == 0) || (dc_n_eng == 0))
            tb_error("gpu_discard: the abandon not seen both in the set-up and in the engine");

         $display("--- P3: SET_SRC IMM and N pushed: disarmed");
         for (dc_k = 0; dc_k < 2; dc_k = dc_k + 1) begin
            gpu_c_size(10, 2);
            gpu_c_dst(DC_P, (DC_DLO * 2) + (14 + 3 * dc_k) * DC_P + 4);
            if (dc_k) gpu_freeze(1'b1);
            gpu_push({OP_SET_SRC, 7'h00, 1'b1, 4'h0, gpu_m_src_pitch});
            gpu_push(32'd10);
            if (dc_k) begin
               dc_used_rd;
               dc_disc(32'h0);
               reg_rd_mask(GPU_STAT, (dc_used + 1) << 8, 32'hFF00);
               gpu_freeze(1'b0);
            end else begin
               gpu_wait_idle;
               reg_wr(IRQ_FLAG, IF_IDLE);
               dc_disc(32'h0);
               gpu_wait_idle;
               reg_rd_mask(IRQ_FLAG, 32'h0, IF_IDLE);       // the marker alone: no GPU_IDLE
            end
            gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);       // reads the VRAM
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | GS_BUSY | 32'hFF00);
            gpu_check_touched("the copy after the disarm");
         end
         $display("       ABORT | CLEAR_ERR | DISCARD while armed");
         gpu_push({OP_SET_SRC, 7'h00, 1'b1, 4'h0, gpu_m_src_pitch});
         gpu_push(32'd10);
         dc_disc(32'h3);
         gpu_k_imm = 1'b0;
         gpu_m_lph = 0;
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         gpu_check_touched("the copy after the recover");
      end

      //--------------------------------------------------------------
      // A marker in every FIFO entry: P1 (SET_FILL, queued) and its probe
      // FILL take 5 words, prime to the depth, so 2 x DEPTH of them write
      // the marker's tag at every write position (FIFOs above 32 entries,
      // whose upper entries the cases above leave without a marker)
      if (GPU_FIFO_DEPTH > 32) begin
         $display("--- a marker at every FIFO position (depth %0d)", GPU_FIFO_DEPTH);
         for (dc_k = 0; dc_k < 2 * GPU_FIFO_DEPTH; dc_k = dc_k + 1)
            dc_p1({OP_SET_FILL, 28'h0}, 1'b1, "SET_FILL, every position");
      end

      gpu_check_all("discard end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
