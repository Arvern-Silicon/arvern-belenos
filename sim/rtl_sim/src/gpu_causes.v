//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_causes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_causes.v
// Module Description : Error causes per command (doc/gpu_commands.md, errors):
//                      every check reads ERR_OPCODE, ERR_CAUSE, GPU_ERR,
//                      GPU_LIST, the GPU_ERR interrupt and GPU_DONE, then
//                      recovers with CLEAR_ERR (record kept):
//                      - cause 1: REMAP 3 on EXEC_FILL, EXEC_COPY_TRANSP,
//                        EXEC_EXPAND; with the immediate source, SET_SRC IMM,
//                        COPY_TRANSP and EXPAND in a list while armed (a
//                        list's SET_SRC does not disarm);
//                      - cause 2 (as built): EXEC_TEXRECT TRI without
//                        triangles, REMAP 1 / 2 on EXPAND and COPY_TRANSP,
//                        SET_TEX REMAP 2 without remap; an absent SET_CLIP's
//                        operand pushed after the CLEAR_ERR is discarded;
//                      - cause 3: every reserved SRC_FMT (6..15) and DST_FMT
//                        (1..7), SRC_FMT 1..4 on COPY_TRANSP, TEXSPAN,
//                        TEXRECT, the textured triangle, SRC_FMT 0 on EXPAND;
//                      - cause 4: a list ending after the word of every
//                        two-word command (ERR_OPCODE 7, GPU_ERR the command,
//                        GPU_LIST its address);
//                      - precedence: a word that is several (3 over 2, 2 over
//                        1, 4 over 3 / 2 / 1 for a list's last word), and a
//                        list's last word refused without an operand (a
//                        SET_EXT / SET_AUX sub-command or SEL absent or
//                        reserved, a CALL in a list): its own cause, never 4;
//                      - cause 5 (non-power-of-two VRAM): EXPAND, TEXRECT,
//                        a triangle and a textured triangle running past
//                        VRAM_WORDS, also from a list (GPU_LIST): the pixels
//                        before the fault drawn, the rest not, no GPU_DONE.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer CZ_LST   = 1000;              // command lists: words [1000, 1100)
localparam integer CZ_SRC   = 2000;              // sources: words [2000, 3000)
localparam integer CZ_DST   = 4000;              // destinations: words [4000, 6000)
localparam  [31:0] CZ_REC   = 32'hFE40_0000;     // ERR_OPCODE, ERR_CAUSE, ERR

integer    cz_k, cz_i, cz_n, cz_vw, cz_tot, cz_first, cz_nbad;
reg [31:0] cz_caps, cz_st, cz_w, cz_flag;
reg        cz_ra;

function cz_opnd;                        // the word takes an operand (push side)
   input [31:0] w;
   begin
      cz_opnd = (w[31:28] == OP_SET_SRC) || (w[31:28] == OP_SET_DST) || (w[31:28] == OP_SET_FILL) ||
                (w[31:28] == OP_SET_TRANSP) || (w[31:28] == OP_CALL) ||
                ((w[31:28] == OP_SET_EXT) && ((w[27:24] == 4'd1) || (w[27:24] == 4'd2) || (w[27:24] == 4'd4) ||
                                              (w[27:24] == 4'd5) || (w[27:24] == 4'd9) || (w[27:24] == 4'd10) ||
                                              (w[27:24] == 4'd11) || (w[27:24] == 4'd12) || (w[27:24] == 4'd13)));
   end
endfunction

// The GPU must be stopped with this record; then CLEAR_ERR (record kept) and
// a fill must run. lst: the expected GPU_LIST (0: none)
task cz_expect;
   input  [3:0] op;
   input  [2:0] cause;
   input [31:0] word;
   input [31:0] lst;
   input [8*48-1:0] label;
   integer      guard;
   begin
      guard = 0;
      cz_st = 32'h0;
      while (!(cz_st & GS_ERR) && (guard < 400)) begin
         reg_rd_val(GPU_STAT, cz_st);
         guard = guard + 1;
      end
      reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 4000);
      reg_rd_val(GPU_STAT, cz_st);
      reg_rd_val(IRQ_FLAG, cz_flag);
      if (((cz_st & CZ_REC) !== ({op, cause, 25'h0} | GS_ERR)) || !(cz_flag & IF_ERR) || (cz_flag & IF_DONE)) begin
         $display("ERROR: %0s -- GPU_STAT 0x%h, IRQ_FLAG 0x%h / expected ERR_OPCODE %h, ERR_CAUSE %0d, GPU_ERR interrupt, no GPU_DONE %t",
                  label, cz_st, cz_flag, op, cause, $time);
         error = error + 1;
      end else
         $display("OK:    %0s: ERR_OPCODE %h, ERR_CAUSE %0d", label, op, cause);
      reg_rd(GPU_ERR, word);
      reg_rd(GPU_LIST, lst);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_flush_hint = 1'b0;
      gpu_k_imm = 1'b0;                                          // the flush disarms
      repeat(4) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {op, cause, 25'h0} | GS_EMPTY, CZ_REC | GS_EMPTY);   // the record kept
      reg_rd(GPU_ERR, word);
      reg_rd(GPU_LIST, 32'h0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // the GPU works: a modelled fill
      gpu_c_dst(16'd64, 2 * CZ_DST + 2 * ($random(gpu_seed) & 255));
      gpu_c_size(14'd3, 14'd2);
      gpu_c_fill($random(gpu_seed));
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("recovery fill");
   end
endtask

// A word pushed to GPU_CMD (with its operand when it takes one)
task cz_word;
   input [31:0] w;
   input  [2:0] cause;
   input [8*48-1:0] label;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push(w);
      if (cz_opnd(w)) gpu_push(32'h0000_0000);
      cz_expect(w[31:28], cause, w, 32'h0, label);
   end
endtask

// A list of n words already captured in gpu_cap_buf, written at CZ_LST and called
task cz_call;
   integer ii;
   begin
      for (ii = 0; ii < gpu_cap_n; ii = ii + 1) begin
         vram_mem[CZ_LST + ii]   = gpu_cap_buf[ii];
         gpu_shadow[CZ_LST + ii] = gpu_cap_buf[ii];
      end
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
      gpu_push(CZ_LST);
   end
endtask

// A list: SET_SIZE, then the word (and its operand), the list ending there
// (last = 1: the word is the list's last word)
task cz_list_word;
   input [31:0] w;
   input        last;
   input  [3:0] op;
   input  [2:0] cause;
   input [8*48-1:0] label;
   begin
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_push({OP_SET_SIZE, 14'd1, 14'd1});
      gpu_push(w);
      if (!last && cz_opnd(w)) gpu_push(32'h0000_0000);
      if (!last) gpu_push({OP_FENCE, 28'h0});
      gpu_cap_en = 1'b0;
      cz_call;
      cz_expect(op, cause, w, CZ_LST + 1, label);
   end
endtask

// After a cause 5: the pixels of the record before the first one past
// VRAM_WORDS are drawn, none after it
task cz_oob_check;
   input [8*48-1:0] label;
   integer      kk;
   reg   [31:0] got;
   begin
      cz_first = gpu_rec_n;
      for (kk = gpu_rec_n - 1; kk >= 0; kk = kk - 1)
         if ((gpu_rec_pa[kk] >> (5 - gpu_rec_bl)) >= VRAM_WORDS) cz_first = kk;
      cz_nbad = 0;
      for (kk = 0; kk < gpu_rec_n; kk = kk + 1)
         if ((gpu_rec_pa[kk] >> (5 - gpu_rec_bl)) < VRAM_WORDS) begin
            got = gpu_vram_px(gpu_rec_pa[kk], gpu_rec_bl);
            if (got !== (((kk < cz_first) && gpu_rec_wr[kk]) ? gpu_rec_new[kk] : gpu_rec_old[kk])) begin
               cz_nbad = cz_nbad + 1;
               if (cz_nbad <= 4)
                  $display("ERROR: %0s -- walk pixel %0d (0x%h) = 0x%h / expected 0x%h (first pixel past the VRAM: %0d) %t",
                           label, kk, gpu_rec_pa[kk], got,
                           ((kk < cz_first) && gpu_rec_wr[kk]) ? gpu_rec_new[kk] : gpu_rec_old[kk], cz_first, $time);
            end
            gpu_set_px(gpu_rec_pa[kk], gpu_rec_bl, got);              // the shadow follows
         end
      error = error + cz_nbad;
      if (cz_first == gpu_rec_n)
         tb_error("gpu_causes: the primitive never reaches VRAM_WORDS (test bug)");
      else if (cz_nbad == 0)
         $display("OK:    %0s: the %0d pixels before the fault drawn, none after", label, cz_first);
   end
endtask

// A primitive of kind k (0 EXPAND, 1 TEXRECT, 2 TRI, 3 textured TRI) whose
// destination runs past VRAM_WORDS at 16 bpp; inl: from a list
task cz_past;
   input integer k;
   input         inl;
   reg   [31:0] ew;
   integer      ii;
   begin
      gpu_set_mode(4);
      gpu_wait_idle;
      gpu_c_size(14'd12, 14'd6);
      if (k == 0) begin
         gpu_c_src_fmt(16'd0, 32 * CZ_SRC, 4'd1);
         gpu_c_dst(16'd64, 2 * (cz_vw - 3 * 32) + 6);                // rows 0..2 inside, row 3 past
      end else begin
         gpu_c_src_fmt(16'd32, 2 * CZ_SRC, 4'd0);
         gpu_c_dst_xy(16'd64, 2 * (cz_vw - 3 * 32));
         gpu_c_xy(6, 0);
         gpu_c_noclip;
         if (k >= 2) begin
            gpu_c_vtx(0, 16 * 4, 16 * 0);
            gpu_c_vtx(1, 16 * 24, 16 * 2);
            gpu_c_vtx(2, 16 * 8, 16 * 6);
         end
         if (k != 2) begin
            gpu_c_tex(4'd4, 4'd4, 1'b0, 3'b000, 1'b0, 1'b0, 8'd0);
            gpu_c_uv(16'd0, 16'd0);
            gpu_c_step(16'd2048, 16'd0);
            gpu_c_step_row(16'd0, 16'd2048);
         end
      end
      gpu_c_fill(32'h0000_5A5A);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_oob_ok  = 1'b1;
      gpu_rgn_dhi = 32'h7FFF_FFFF;                               // the destination runs past the VRAM
      if (inl) begin
         gpu_cap_n  = 0;
         gpu_cap_en = 1'b1;
      end
      gpu_rec_begin;
      case (k)
        0: gpu_c_expand(0, 3'b000, 1'b1, 2'd0);
        1: gpu_c_texrect(0);
        2: gpu_c_trifill(4'd0);
        default: gpu_c_tritex;
      endcase
      gpu_rec_end;
      if (inl) begin
         ew = gpu_cap_buf[gpu_cap_n - 1];
         for (ii = 0; ii < 4; ii = ii + 1) gpu_push({OP_SET_SIZE, 14'd1, 14'd1});   // the decoder may go on
         gpu_push({OP_FENCE, 28'h0});                              // (waits for the engine: run-ahead stops here)
         gpu_push({OP_SET_SIZE, 14'd1, 14'd1});
         gpu_cap_en = 1'b0;
         cz_n = gpu_cap_n;
         cz_call;
      end else
         ew = 32'h0;
      gpu_oob_ok  = 1'b0;
      gpu_rgn_dhi = VRAM_WORDS;
      if (!inl) begin
         // the EXEC word: the last word pushed (gpu_push records nothing)
         ew = (k == 0) ? {OP_EXEC_EXP, 14'd0, 2'b00, 4'd0, 1'b0, 3'b000, 1'b0, 1'b1, 2'b00} :
              (k == 1) ? {OP_EXEC_TEXRECT, 14'd0, 14'd0} :
              (k == 2) ? {OP_EXEC_FILL, 14'd0, 2'b00, 4'h0, 1'b1, 3'b000, 4'd0} :
                         {OP_EXEC_TEXRECT, gpu_tt_delta, 14'h0080};
      end
      reg_poll(GPU_STAT, GS_ERR, GS_ERR, 4000);
      reg_poll(GPU_STAT, GS_PRIM_BUSY, 32'h0, 4000);
      cz_oob_check((k == 0) ? "EXPAND past VRAM_WORDS" : (k == 1) ? "TEXRECT past VRAM_WORDS" :
                   (k == 2) ? "TRI past VRAM_WORDS" : "textured TRI past VRAM_WORDS");
      if (inl && cz_ra) begin
         // with run-ahead: GPU_LIST is the word the decoder had reached (at
         // most the FENCE, which waits for the engine)
         reg_rd_val(GPU_LIST, cz_w);
         if ((cz_w < CZ_LST + cz_n - 6) || (cz_w > CZ_LST + cz_n - 2)) begin
            $display("ERROR: cause 5 in a list (run-ahead) -- GPU_LIST 0x%h outside the words after the EXEC %t", cz_w, $time);
            error = error + 1;
         end
         cz_expect(ew[31:28], 3'd5, ew, cz_w, "cause 5 in a list");
      end else
         cz_expect(ew[31:28], 3'd5, ew, inl ? (CZ_LST + cz_n - 6) : 32'h0, inl ? "cause 5 in a list" : "cause 5");
   end
endtask


initial
   begin
      $display(" ===============================================");
      $display("|  GPU: error causes per command, precedence    |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_flush_resend = 1'b0;
      gpu_push_wait    = 1'b1;                 // FREE checked before each push (any FIFO depth)
      cz_vw = VRAM_WORDS;
      cz_ra = (GPU_RUNAHEAD_EN != 0);
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      reg_rd_val(BLNS_CFG2, cz_caps);
      cz_caps = (cz_caps >> 8) & 32'h7;                         // [0] REMAP, [1] MPLANE, [2] IMM
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("=== cause 1");
      cz_word({OP_EXEC_FILL, 14'h0000, 2'd3, 12'h000}, 3'd1, "EXEC_FILL REMAP 3");
      cz_word({OP_EXEC_COPYT, 14'h0000, 2'd3, 12'h000}, 3'd1, "EXEC_COPY_TRANSP REMAP 3");
      gpu_c_src_fmt(16'd0, 32 * CZ_SRC, 4'd1);
      cz_word({OP_EXEC_EXP, 14'h0000, 2'd3, 12'h000}, 3'd1, "EXEC_EXPAND REMAP 3");
      gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd0);
      if ((GPU_IMM_EN != 0) && cz_caps[2]) begin
         cz_list_word({OP_SET_SRC, 7'h00, 1'b1, 20'h00000}, 1'b0, OP_SET_SRC, 3'd1, "SET_SRC IMM in a list");
         gpu_c_size(14'd4, 14'd1);
         gpu_c_imm(4'h0, 2);
         gpu_wait_idle;
         cz_list_word(gpu_exec_word(GPU_COPYT, 4'd0, 3'b000, 3'b000), 1'b0, OP_EXEC_COPYT, 3'd1,
                      "COPY_TRANSP in a list while armed");
         gpu_c_src_fmt(16'd0, 32 * CZ_SRC, 4'd1);
         gpu_c_imm(4'h1, 1);
         gpu_wait_idle;
         cz_list_word({OP_EXEC_EXP, 14'h0000, 2'd0, 12'h000}, 1'b0, OP_EXEC_EXP, 3'd1, "EXPAND in a list while armed");
         $display("--- a list's SET_SRC does not disarm the immediate source");
         gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd0);
         gpu_c_dst(16'd64, 2 * CZ_DST + 600);
         gpu_c_size(14'd4, 14'd2);
         gpu_c_imm(4'h0, 4);
         for (cz_i = 0; cz_i < 4; cz_i = cz_i + 1) gpu_imm_buf[cz_i] = $random(gpu_seed);
         gpu_wait_idle;
         gpu_cap_n  = 0;
         gpu_cap_en = 1'b1;
         gpu_push({OP_SET_SRC, 12'h000, 16'd32});
         gpu_push(2 * CZ_SRC + 64);
         gpu_cap_en = 1'b0;
         cz_call;
         gpu_wait_idle;
         gpu_m_src_pitch = 16'd32;
         gpu_m_src_base  = 2 * CZ_SRC + 64;
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);              // still the immediate source
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, GS_EMPTY, GS_EMPTY | GS_ERR);
         gpu_check_touched("armed through a list's SET_SRC");
      end

      //--------------------------------------------------------------
      $display("=== cause 2 (as built)");
      if ((GPU_XY_EN != 0) && (GPU_TRI_EN == 0))
         cz_word({OP_EXEC_TEXRECT, 14'd0, 14'h0080}, 3'd2, "EXEC_TEXRECT TRI without triangles");
      if (!cz_caps[0]) begin
         gpu_c_src_fmt(16'd0, 32 * CZ_SRC, 4'd1);
         cz_word({OP_EXEC_EXP, 14'h0000, 2'd1, 12'h000}, 3'd2, "EXEC_EXPAND REMAP 1 without remap");
         gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd0);
         cz_word({OP_EXEC_COPYT, 14'h0000, 2'd2, 12'h000}, 3'd2, "EXEC_COPY_TRANSP REMAP 2 without remap");
         cz_word({OP_SET_EXT, EXT_SET_TEX, 8'h00, 2'd2, 14'h0000}, 3'd2, "SET_TEX REMAP 2 without remap");
      end
      if (GPU_XY_EN == 0) begin
         $display("--- an absent SET_CLIP: its operand, pushed after the CLEAR_ERR, is discarded");
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push({OP_SET_EXT, EXT_SET_CLIP, 24'h000000});
         repeat(20) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_SET_EXT, 3'd2, 25'h0} | GS_ERR, CZ_REC);
         reg_wr(GPU_CTRL, 32'h1);
         gpu_push(gpu_exec_word(GPU_FILL, 4'd2, 3'b000, 3'b000));   // the operand: never decoded
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, {OP_SET_EXT, 3'd2, 25'h0}, CZ_REC);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_check_all("absent SET_CLIP operand discarded");
      end

      //--------------------------------------------------------------
      $display("=== cause 3");
      for (cz_k = 6; cz_k < 16; cz_k = cz_k + 1)                 // (5, RGB565A8: gpu_a8_err)
         cz_word({OP_SET_SRC, 8'h00, cz_k[3:0], 16'h0000}, 3'd3, "SET_SRC reserved SRC_FMT");
      for (cz_k = 1; cz_k < 8; cz_k = cz_k + 1)
         cz_word({OP_SET_DST, 8'h00, cz_k[2:0], 1'b0, 16'h0000}, 3'd3, "SET_DST reserved DST_FMT");
      gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd1 + ($random(gpu_seed) & 3));
      cz_word(gpu_exec_word(GPU_COPYT, 4'd0, 3'b000, 3'b000), 3'd3, "COPY_TRANSP with SRC_FMT 1..4");
      cz_word({OP_EXEC_TEX, 14'd0, 14'd4}, 3'd3, "TEXSPAN with SRC_FMT 1..4");
      if (GPU_XY_EN != 0) cz_word({OP_EXEC_TEXRECT, 14'd0, 14'd0}, 3'd3, "TEXRECT with SRC_FMT 1..4");
      if ((GPU_XY_EN != 0) && (GPU_TRI_EN != 0))
         cz_word({OP_EXEC_TEXRECT, 14'd0, 14'h0080}, 3'd3, "textured TRI with SRC_FMT 1..4");
      gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd0);
      cz_word({OP_EXEC_EXP, 28'h0}, 3'd3, "EXPAND with SRC_FMT 0");

      //--------------------------------------------------------------
      $display("=== cause 4: a list ending after the word of each two-word command");
      gpu_wait_idle;
      cz_list_word({OP_SET_SRC, 12'h000, 16'd8}, 1'b1, OP_CALL, 3'd4, "list cut: SET_SRC");
      cz_list_word({OP_SET_DST, 12'h000, 16'd8}, 1'b1, OP_CALL, 3'd4, "list cut: SET_DST");
      cz_list_word({OP_SET_FILL, 28'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_FILL");
      cz_list_word({OP_SET_TRANSP, 28'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_TRANSP");
      cz_list_word({OP_SET_EXT, EXT_SET_UV, 24'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_UV");
      cz_list_word({OP_SET_EXT, EXT_SET_STEP, 24'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_STEP");
      if (GPU_XY_EN != 0) begin
         cz_list_word({OP_SET_EXT, EXT_SET_CLIP, 24'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_CLIP");
         cz_list_word({OP_SET_EXT, EXT_SET_STEP_ROW, 24'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_STEP_ROW");
         cz_list_word({OP_SET_DST, 11'h000, 1'b1, 16'd8}, 1'b1, OP_CALL, 3'd4, "list cut: SET_DST XY");
      end
      if ((GPU_TRI_EN != 0) && (GPU_XY_EN != 0))
         for (cz_k = 9; cz_k < 12; cz_k = cz_k + 1)
            cz_list_word({OP_SET_EXT, cz_k[3:0], 24'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_V0..V2");
      if (GPU_GRAD_EN != 0)
         cz_list_word({OP_SET_EXT, EXT_SET_GRGB, 24'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_GRAD_RGB");
      if (cz_caps[0])
         cz_list_word({OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_AUX REMAP_TABLE");
      if (cz_caps[1])
         cz_list_word({OP_SET_EXT, EXT_SET_AUX, 4'd1, 20'h0}, 1'b1, OP_CALL, 3'd4, "list cut: SET_AUX MASK_PLANE");

      //--------------------------------------------------------------
      $display("=== precedence");
      // a list's last word refused without an operand: its own cause, never 4
      cz_list_word({OP_SET_EXT, EXT_SET_AUX, 4'd6, 20'h0}, 1'b1, OP_SET_EXT, 3'd1, "last word: SET_AUX reserved SEL (1)");
      cz_list_word({OP_SET_EXT, EXT_SET_AUX, 4'd1, 4'h0, 16'h0100}, 1'b1, OP_SET_EXT, 3'd2,
                   "last word: SET_AUX MASK_PLANE PITCH (2)");
      cz_list_word({OP_CALL, 4'h0, 24'd1}, 1'b1, OP_CALL, 3'd1, "last word: CALL in a list (1)");
      if (GPU_XY_EN == 0)
         cz_list_word({OP_SET_EXT, EXT_SET_CLIP, 24'h0}, 1'b1, OP_SET_EXT, 3'd2, "last word: absent SET_CLIP (2)");
      if (GPU_GRAD_EN == 0)
         cz_list_word({OP_SET_EXT, EXT_SET_GRGB, 24'h0}, 1'b1, OP_SET_EXT, 3'd2, "last word: absent SET_GRAD_RGB (2)");
      if (!cz_caps[0])
         cz_list_word({OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h0}, 1'b1, OP_SET_EXT, 3'd2, "last word: absent REMAP_TABLE (2)");
      // a list's last word refused with an operand: the list cut first
      cz_list_word({OP_SET_SRC, 8'h00, 4'd9, 16'h0}, 1'b1, OP_CALL, 3'd4, "last word: SET_SRC SRC_FMT 9 (4 over 3)");
      cz_list_word({OP_SET_SRC, 7'h00, 1'b1, 20'h0}, 1'b1, OP_CALL, 3'd4, "last word: SET_SRC IMM (4 over 1 / 2)");
      if (GPU_XY_EN == 0)
         cz_list_word({OP_SET_DST, 11'h000, 1'b1, 16'd0}, 1'b1, OP_CALL, 3'd4, "last word: absent SET_DST XY (4 over 2)");
      // one word, several causes (from GPU_CMD)
      if (GPU_XY_EN == 0)
         cz_word({OP_SET_DST, 8'h00, 3'd1, 1'b1, 16'h0}, 3'd3, "SET_DST XY absent, DST_FMT 1 (3 over 2)");
      if (GPU_IMM_EN == 0)
         cz_word({OP_SET_SRC, 7'h00, 1'b1, 4'd7, 16'h0}, 3'd3, "SET_SRC IMM absent, SRC_FMT 7 (3 over 2)");
      if (GPU_XY_EN == 0)
         cz_word({OP_SET_EXT, EXT_SET_TEX, 8'h00, 2'd3, 1'b1, 13'h0}, 3'd2, "SET_TEX REMAP 3 and BOUND absent (2 over 1)");
      if (!cz_caps[1])
         cz_word({OP_EXEC_COPY, 14'h0000, 2'd3, 1'b1, 11'h000}, 3'd2, "EXEC_COPY REMAP 3, MPLANE absent (2 over 1)");
      gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd2);
      cz_word({OP_EXEC_COPY, 14'h0000, 2'd3, 12'h000}, 3'd3, "EXEC_COPY REMAP 3 with SRC_FMT 2 (3 over 1)");
      gpu_c_src_fmt(16'd0, 2 * CZ_SRC, 4'd0);

      //--------------------------------------------------------------
      if ((cz_vw < (1 << VRAM_AW)) && (GPU_DIM_MASK >= 24)) begin
         $display("=== cause 5: past VRAM_WORDS (%0d)", cz_vw);
         for (cz_k = 0; cz_k < 4; cz_k = cz_k + 1)
            if ((cz_k == 0) || ((cz_k == 1) && (GPU_XY_EN != 0)) || ((cz_k >= 2) && (GPU_TRI_EN != 0) && (GPU_XY_EN != 0))) begin
               cz_past(cz_k, 1'b0);
               cz_past(cz_k, 1'b1);
            end
      end

      gpu_check_all("gpu_causes end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
