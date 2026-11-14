//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_imm
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_imm.v
// Module Description : Immediate source (SET_SRC [20] IMM, operand N: the next
//                      EXEC_COPY / COPY_TRANSP / EXPAND written to GPU_CMD
//                      reads its source from the N words pushed after it, a
//                      surface at pixel 0 with the width as pitch, rows not
//                      word-aligned; skipped when BLNS_CFG2.IMM is 0, after
//                      checking SET_SRC IMM is refused with ERR_CAUSE 2).
//                      BLNS_CFG2 [10] IMM. COPY / COPY_TRANSP at
//                      every depth (ops, destination swaps, keys), EXPAND
//                      from 1/2/4/8 bpp: the image against gpu_model.v, the
//                      VRAM reads and writes (no source read: only the
//                      destination words accessed), the FIFO empty after.
//                      N exact, short (the words past N read 0), long (the
//                      extra words dropped) and 0. x/y destinations with the
//                      clip window trimming leading and trailing source
//                      words. Remap and mask plane on an immediate source.
//                      Back to back immediate commands (run-ahead builds);
//                      an immediate copy then a VRAM copy of its result.
//                      SET_SRC without IMM disarms. Refused (ERR_CAUSE 1):
//                      SET_SRC IMM in a list, a copy / EXPAND in a list
//                      while armed, a copy with SRC swaps. ABORT, CLEAR_ERR and
//                      GPU_EN = 0 in the middle of the data, every word
//                      pushed taken: ABORT / GPU_EN = 0 leave a clean prefix
//                      (no GPU_DONE), CLEAR_ERR completes the rectangle with
//                      0 for the data not taken (GPU_DONE); the words still
//                      pushed are dropped, the stream goes on. An immediate
//                      start past VRAM_WORDS, and (DIM_W >= 13) past the
//                      pixel address range: ERR_CAUSE 5, nothing drawn; with
//                      a power-of-two VRAM a 1-bpp EXPAND starting past or
//                      walking across 2^PA_W: ERR_CAUSE 5 (no wrap).
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT
`include "gpu_model.v"

localparam integer IM_P    = 128;                // destination pitch (pixels)
localparam integer IM_SLO  = 2048;               // VRAM source region: words [2048, 4096)
localparam integer IM_DLO  = 4096;               // destination region: words [4096, 6144)
localparam integer IM_DSZ  = 2048;
localparam integer IM_MLO  = 7168;               // mask plane: words [7168, 7424)
localparam integer IM_TLO  = 8192;               // remap table: words [8192, 8256)
localparam integer IM_LLO  = 8320;               // command lists: words [8320, 8336)
localparam integer IM_X0   = 16;
localparam integer IM_Y0   = 4;
localparam integer IM_WMAX = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer IM_HMAX = (GPU_DIM_MASK >= 6) ? 6 : GPU_DIM_MASK;

integer    im_mode, im_bl, im_ppw, im_i, im_j, im_k, im_n, im_rd0, im_wr0, im_w, im_h, im_x;
integer    im_ncase, im_nshort, im_nlong, im_nzero, im_nexp, im_nxy, im_nd;
reg [31:0] im_pm, im_st, im_t, im_db;
reg  [3:0] im_cmd, im_op;
reg  [2:0] im_dsw;

function integer im_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      im_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task im_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      im_mode = mode;
      im_bl   = gpu_bl(mode);
      im_ppw  = 32 >> im_bl;
      im_pm   = gpu_pmask(im_bl);
      gpu_preload_rand(IM_SLO, IM_SLO + 2048);
      gpu_preload_rand(IM_DLO, IM_DLO + IM_DSZ);
      gpu_preload_rand(IM_MLO, IM_MLO + 256);
      gpu_preload_rand(IM_TLO, IM_TLO + 64);
      gpu_model_init;
      gpu_set_mode(mode);
      gpu_set_dispw(64);
      gpu_c_fill($random(gpu_seed));
   end
endtask

// The data words: random, n of them (exact: ceil(w * h * bpp / 32); short,
// long or none by nmode)
task im_data;
   input integer w;
   input integer h;
   input integer sbl;                    // log2 of the source depth
   input integer nmode;                  // 0 exact, 1 short, 2 long, 3 none
   integer       ne, ii;
   begin
      ne = (w * h * (1 << sbl) + 31) / 32;
      case (nmode)
        1:       begin im_n = ne - 1 - im_rnd(ne); im_nshort = im_nshort + 1; end
        2:       begin im_n = ne + 1 + im_rnd(4);  im_nlong  = im_nlong + 1;  end
        3:       begin im_n = 0;                   im_nzero  = im_nzero + 1;  end
        default: im_n = ne;
      endcase
      if (im_n < 0) im_n = 0;
      for (ii = 0; ii < im_n; ii = ii + 1)
         gpu_imm_buf[ii] = $random(gpu_seed);
   end
endtask

task im_clear_alw;
   integer ii;
   begin
      for (ii = IM_DLO; ii < IM_DLO + IM_DSZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = IM_MLO; ii < IM_MLO + 256; ii = ii + 1)    gpu_alw[ii] = 1'b0;
      for (ii = IM_TLO; ii < IM_TLO + 64; ii = ii + 1)     gpu_alw[ii] = 1'b0;
   end
endtask

task im_chk_end;
   input [8*40-1:0] label;
   begin
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | 32'hFF00);    // no error, the FIFO empty
      gpu_check_touched(label);
   end
endtask

// One immediate COPY / COPY_TRANSP: image and VRAM accesses
task im_case;
   input   [3:0] cmd;
   input   [3:0] op;
   input integer w;
   input integer h;
   input   [2:0] dsw;
   input integer nmode;
   input         xy;
   input   [1:0] rmp;
   input         mpl;
   integer       ds;
   begin
      gpu_wait_idle;
      ds    = im_rnd(im_ppw);
      im_db = (IM_DLO * im_ppw) + IM_Y0 * IM_P + IM_X0 + ds;
      gpu_c_size(w, h);
      im_data(w, h, im_bl, nmode);
      if (xy) begin
         gpu_c_dst_xy(IM_P, IM_DLO * im_ppw);
         gpu_c_xy(IM_X0 + ds + (dsw[2] ? w : 0), IM_Y0 + (dsw[1] ? h : 0));
         im_x = IM_X0 + ds + (dsw[2] ? 1 : 0);
         // a window cutting columns and rows on either side
         gpu_c_clip(im_x + im_rnd(4), IM_Y0 + im_rnd(2), im_x + w - 1 - im_rnd(4), IM_Y0 + h + 1 - im_rnd(3));
         im_nxy = im_nxy + 1;
      end else
         gpu_c_dst(IM_P, im_db);
      if ((im_n > 0) && im_rnd(2))
         gpu_c_transp((gpu_imm_buf[im_rnd(im_n)] >> (im_rnd(im_ppw) << im_bl)) & im_pm);
      else
         gpu_c_transp($random(gpu_seed));
      if (rmp != 2'd0) gpu_c_remap_table(IM_TLO);
      if (mpl) gpu_c_mask_plane(IM_MLO * 32 + im_rnd(32), im_rnd(2));
      $display("       cmd %h op %0d %0d x %0d -> %b%0s N %0d%0s%0s", cmd, op, w, h, dsw, xy ? " x/y" : "",
               im_n, (rmp != 2'd0) ? " remap" : "", mpl ? " mask" : "");
      gpu_c_imm(4'h0, im_n);
      im_clear_alw;
      im_rd0 = gpu_exp_rd;
      im_wr0 = gpu_exp_wr;
      gpu_mon_bl     = im_bl;
      gpu_mon_be_chk = 1'b1;
      gpu_alw_start;
      gpu_mon_start;
      gpu_k_rmp = rmp;
      gpu_k_mpl = mpl;
      if (xy) gpu_c_exec_xy(cmd, op, dsw, 3'b000);
      else    gpu_c_exec(cmd, op, dsw, 3'b000);
      gpu_k_rmp = 2'd0;
      gpu_k_mpl = 1'b0;
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_alw_stop;
      gpu_mon_be_chk = 1'b0;
      if ((gpu_mon_rd != gpu_exp_rd - im_rd0) || (gpu_mon_wr != gpu_exp_wr - im_wr0)) begin
         $display("ERROR: GPU immediate mode %0d cmd %h op %0d %0d x %0d -> %b: %0d reads / %0d writes, expected %0d / %0d %t",
                  im_mode, cmd, op, w, h, dsw, gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - im_rd0, gpu_exp_wr - im_wr0, $time);
         error = error + 1;
      end
      if (xy) begin
         gpu_c_noclip;
         gpu_c_dst(IM_P, im_db);
      end
      im_ncase = im_ncase + 1;
      im_chk_end("immediate copy");
   end
endtask

task im_rand;
   input xy;
   begin
      case (im_rnd(6))
        0, 1:    im_dsw = 3'b000;
        2:       im_dsw = 3'b100;
        3:       im_dsw = 3'b010;
        4:       im_dsw = 3'b001;
        default: im_dsw = im_rnd(8);
      endcase
      im_cmd = im_rnd(2) ? GPU_COPY : GPU_COPYT;
      im_op  = im_rnd(3) ? (im_rnd(2) ? 4'd0 : 4'd6) : im_rnd(16);
      im_w   = im_dsw[0] ? (1 + im_rnd(6)) : (1 + im_rnd(IM_WMAX));
      im_h   = 1 + im_rnd(IM_HMAX);
      im_case(im_cmd, im_op, im_w, im_h, im_dsw, (im_rnd(5) == 0) ? (1 + im_rnd(3)) : 0, xy, 2'd0, 1'b0);
   end
endtask

// EXPAND from an immediate 1/2/4/8-bpp source: image, no source read
task im_expand;
   input xy;
   integer sdep;
   begin
      gpu_wait_idle;
      sdep = im_rnd((im_bl > 3) ? 4 : (im_bl + 1));
      im_w = 1 + im_rnd(IM_WMAX);
      im_h = 1 + im_rnd(IM_HMAX);
      gpu_c_size(im_w, im_h);
      im_db = (IM_DLO * im_ppw) + IM_Y0 * IM_P + IM_X0 + im_rnd(im_ppw);
      if (xy) begin
         gpu_c_dst_xy(IM_P, IM_DLO * im_ppw);
         gpu_c_xy(IM_X0 + im_rnd(im_ppw), IM_Y0);
         gpu_c_clip(IM_X0 + im_rnd(5), IM_Y0 + im_rnd(2), IM_X0 + im_w - 2, IM_Y0 + im_h);
      end else
         gpu_c_dst(IM_P, im_db);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));
      im_data(im_w, im_h, sdep, (im_rnd(5) == 0) ? (1 + im_rnd(3)) : 0);
      gpu_exp_op = im_rnd(3) ? 4'd0 : im_rnd(16);
      $display("       EXPAND %0d bpp %0d x %0d%0s N %0d op %0d", 1 << sdep, im_w, im_h, xy ? " x/y" : "", im_n, gpu_exp_op);
      gpu_c_imm({2'b00, sdep[1:0]} + 4'd1, im_n);
      im_clear_alw;
      gpu_alw_start;
      gpu_c_expand(0, im_rnd(2) ? 3'b000 : im_rnd(8), im_rnd(2), sdep);
      gpu_wait_idle;
      gpu_alw_stop;
      gpu_exp_op = 4'd0;
      if (xy) begin
         gpu_c_noclip;
         gpu_c_dst(IM_P, im_db);
      end
      im_nexp = im_nexp + 1;
      im_chk_end("immediate expand");
   end
endtask

// A command list of two words at IM_LLO, called; refused with ERR_CAUSE 1
task im_list_err;
   input [31:0] w0;
   input [31:0] w1;
   input  [3:0] opc;
   begin
      gpu_wait_idle;
      vram_wr(4 * IM_LLO,       w0, SZ_W);
      vram_wr(4 * (IM_LLO + 1), w1, SZ_W);
      gpu_shadow[IM_LLO]     = w0;
      gpu_shadow[IM_LLO + 1] = w1;
      reg_wr(GPU_CMD, {OP_CALL, 4'h0, 24'd2});
      reg_wr(GPU_CMD, IM_LLO);
      repeat(40) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {opc, 3'd1, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_wait_idle;
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: immediate source                  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < IM_LLO + 16)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      reg_rd_val(BLNS_CFG2, im_st);
      if ((im_st & CFG2_IMM) == 0) begin
         reg_wr(CTRL, 32'h14);
         reg_wr(GPU_CMD, {OP_SET_SRC, 7'h00, 1'b1, 20'h00000});   // refused: ERR_CAUSE 2
         repeat(10) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_SET_SRC, 3'd2, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_wr(GPU_CTRL, 32'h1);
         tb_skip_finish("|      (BLNS_CFG2.IMM = 0: no immediate source) |");
      end
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;                            // commands queued behind long ones
      im_ncase = 0; im_nshort = 0; im_nlong = 0; im_nzero = 0; im_nexp = 0; im_nxy = 0;

      // COPY / COPY_TRANSP and EXPAND at every depth
      for (im_k = 0; (im_k < 5) && (error == 0); im_k = im_k + 1) begin
         im_set_mode((im_k == 4) ? (4 + im_rnd(4)) : im_k);
         for (im_i = 0; (im_i < 14) && (error == 0); im_i = im_i + 1)
            im_rand(1'b0);
         if (GPU_XY_EN != 0)
            for (im_i = 0; (im_i < 4) && (error == 0); im_i = im_i + 1)
               im_rand(1'b1);
         for (im_i = 0; (im_i < 5) && (error == 0); im_i = im_i + 1)
            im_expand((GPU_XY_EN != 0) && im_rnd(2));
      end
      $display("       %0d copies (%0d x/y), %0d expands; N short %0d, long %0d, 0 %0d",
               im_ncase, im_nxy, im_nexp, im_nshort, im_nlong, im_nzero);

      //--------------------------------------------------------------
      if ((GPU_REMAP_EN != 0) || (GPU_MPLANE_EN != 0)) begin
         $display("--- remap and mask plane on an immediate source");
         for (im_k = 0; (im_k < 3) && (error == 0); im_k = im_k + 1) begin
            im_set_mode(im_k + 1);
            for (im_i = 0; (im_i < 4) && (error == 0); im_i = im_i + 1)
               im_case(im_rnd(2) ? GPU_COPY : GPU_COPYT, im_rnd(2) ? 4'd0 : 4'd4, 1 + im_rnd(IM_WMAX), 1 + im_rnd(IM_HMAX),
                       im_rnd(2) ? 3'b000 : 3'b100, 0, 1'b0,
                       (GPU_REMAP_EN != 0) ? (1 + im_rnd(2)) : 2'd0, (GPU_MPLANE_EN != 0) && im_rnd(2));
         end
      end

      //--------------------------------------------------------------
      $display("--- back to back immediate commands, a VRAM copy of the result");
      im_set_mode(4);
      gpu_c_transp($random(gpu_seed));
      for (im_i = 0; im_i < 10; im_i = im_i + 1) begin
         im_w = 1 + im_rnd(IM_WMAX);
         im_h = 1 + im_rnd(3);
         gpu_c_size(im_w, im_h);
         gpu_c_dst(IM_P, (IM_DLO * 2) + (IM_Y0 + 3 * (im_i % 6)) * IM_P + IM_X0 + im_rnd(8));
         if (im_rnd(3)) begin
            im_data(im_w, im_h, 4, 0);
            gpu_c_imm(4'h0, im_n);
            gpu_c_exec(im_rnd(2) ? GPU_COPY : GPU_COPYT, 4'd0, 3'b000, 3'b000);
         end else begin
            im_data(im_w, im_h, 0, 0);
            gpu_c_imm(4'h1, im_n);
            gpu_c_expand(0, 3'b000, 1'b1, 0);
         end
      end
      gpu_c_src(IM_P, (IM_DLO * 2) + IM_Y0 * IM_P + IM_X0);    // the result read back by the GPU
      gpu_c_dst(IM_P, (IM_DLO * 2) + (IM_Y0 + 20) * IM_P + IM_X0);
      gpu_c_size(IM_WMAX, 6);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      im_chk_end("back to back");

      //--------------------------------------------------------------
      $display("--- SET_SRC without IMM disarms: the copy reads the VRAM");
      im_set_mode(3);
      gpu_c_size(20, 2);
      gpu_c_dst(IM_P, (IM_DLO * 4) + IM_Y0 * IM_P);
      gpu_c_imm(4'h0, 10);
      gpu_c_src(IM_P, IM_SLO * 4 + 5);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      im_chk_end("disarmed");

      //--------------------------------------------------------------
      $display("--- refused: SET_SRC IMM in a list, a copy in a list while armed, SRC swaps");
      im_set_mode(4);
      im_list_err({OP_SET_SRC, 7'h00, 1'b1, 20'h00000}, 32'h0000_0003, OP_SET_SRC);
      gpu_c_size(4, 1);
      gpu_push({OP_SET_SRC, 7'h00, 1'b1, 20'h00000});
      gpu_push(32'd0);
      im_list_err({OP_EXEC_COPY, 28'h0}, {OP_FENCE, 28'h0}, OP_EXEC_COPY);
      // (the flush disarmed both sides: the next copy reads the VRAM)
      gpu_push({OP_SET_SRC, 7'h00, 1'b1, 20'h00000});
      gpu_push(32'd2);
      gpu_push(gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b100));
      gpu_push(32'h1234_5678);                                   // its two data words
      gpu_push(32'h9ABC_DEF0);
      repeat(40) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {OP_EXEC_COPY, 3'd1, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_wr(GPU_CTRL, 32'h1);
      gpu_flush_hint = 1'b0;
      gpu_m_src_fmt  = 4'h0;
      gpu_c_src(IM_P, IM_SLO * 2);
      gpu_c_dst(IM_P, (IM_DLO * 2) + IM_Y0 * IM_P);
      gpu_c_size(10, 2);
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      im_chk_end("after the refusals");

      //--------------------------------------------------------------
      $display("--- ABORT, CLEAR_ERR and GPU_EN = 0 in the middle of the data: the image");
      for (im_k = 0; im_k < 9; im_k = im_k + 1) begin
         im_set_mode(4);
         im_w = IM_WMAX;
         im_h = (GPU_DIM_MASK >= 24) ? 24 : GPU_DIM_MASK;
         im_n = (im_w * im_h + 1) / 2;
         im_dsw = {im_rnd(2), 2'b00};                             // X mirror or not
         gpu_c_size(im_w, im_h);
         gpu_c_dst(IM_P, (IM_DLO * 2) + IM_Y0 * IM_P + IM_X0 + 40);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         for (im_i = 0; im_i < im_n; im_i = im_i + 1)
            gpu_imm_buf[im_i] = $random(gpu_seed);
         im_j = im_n / 4 + im_rnd(im_n / 2);                       // data words pushed before the flush
         // the model: the whole copy, recorded (ABORT, GPU_EN = 0: a prefix of it)
         gpu_imm_n = im_n;
         if ((im_k % 3) != 2) begin
            gpu_x_setup(GPU_COPY, 4'd0, im_dsw, 3'b000);
            gpu_k_imm = 1'b1;
            gpu_x_take_imm;
            gpu_rec_begin;
            gpu_x_run;
            gpu_rec_end;
            gpu_x_imm = 1'b0;
         end
         gpu_push({OP_SET_SRC, 7'h00, 1'b1, 20'h00000});
         gpu_push(im_n);
         gpu_push(gpu_exec_word(GPU_COPY, 4'd0, im_dsw, 3'b000));
         for (im_i = 0; im_i < im_j; im_i = im_i + 1)
            gpu_push(gpu_imm_buf[im_i]);
         $display("       %0s after %0d of %0d data words, destination swaps %b",
                  ((im_k % 3) == 1) ? "ABORT" : ((im_k % 3) == 2) ? "CLEAR_ERR" : "GPU_EN = 0", im_j, im_n, im_dsw);
         // the GPU has taken every word pushed and waits for the next one
         im_st = 32'hFF00;
         while ((im_st & 32'hFF00) != 32'h0) reg_rd_val(GPU_STAT, im_st);
         repeat(60) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, GS_BUSY | GS_PRIM_BUSY, GS_BUSY | GS_PRIM_BUSY | GS_ERR);
         if ((im_k % 3) != 0) begin
            // ABORT, or CLEAR_ERR alone (the rectangle completes with 0 for the
            // rest): the words still pushed are dropped
            reg_wr(GPU_CTRL, ((im_k % 3) == 1) ? 32'h2 : 32'h1);
            for (im_i = im_j; im_i < im_n; im_i = im_i + 1)
               gpu_push($random(gpu_seed));
         end else begin
            reg_wr(CTRL, 32'h4);                                 // GPU_EN = 0: nothing more is owed
            gpu_set_mode(4);
         end
         gpu_wait_idle;
         reg_rd_val(IRQ_FLAG, im_t);
         if ((im_k % 3) == 2) begin
            // CLEAR_ERR: the whole rectangle, the data not taken read 0
            if (!im_t[4]) tb_error("gpu_imm: no GPU_DONE for the copy completed after CLEAR_ERR");
            gpu_imm_n = im_j;
            gpu_x_setup(GPU_COPY, 4'd0, im_dsw, 3'b000);
            gpu_k_imm = 1'b1;
            gpu_x_take_imm;
            gpu_x_run;
            gpu_x_imm = 1'b0;
            gpu_check_touched("CLEAR_ERR: rest of the data read 0");
         end else begin
            gpu_rec_prefix(im_t[4], im_i, im_nd);
            if ((im_i != 1) || (im_nd > 2 * im_j)) begin
               $display("ERROR: GPU immediate copy abandoned -- class %0d, %0d pixels drawn (data for %0d) %t",
                        im_i, im_nd, 2 * im_j, $time);
               error = error + 1;
            end else
               $display("OK:    GPU immediate copy abandoned after %0d of %0d pixels (clean prefix, data for %0d)",
                        im_nd, im_w * im_h, 2 * im_j);
            gpu_check_touched("abandoned immediate copy");
         end
         gpu_k_imm = 1'b0;
         gpu_flush_hint = 1'b0;
         gpu_m_src_fmt  = 4'h0;
         im_t = 32'h00A5A0 + im_k;
         gpu_push({OP_FENCE, 4'h0, im_t[23:0]});                // decoded as a command
         // a second immediate copy at once: its data are its own
         gpu_c_size(im_w, 2);
         gpu_c_dst(IM_P, (IM_DLO * 2) + (IM_Y0 + 26) * IM_P + IM_X0);
         im_data(im_w, 2, 4, 0);
         gpu_c_imm(4'h0, im_n);
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, GS_EMPTY, GS_ERR | GS_EMPTY | 32'hFF00);
         reg_rd(GPU_FENCE, 32'h00A5A0 + im_k);
         im_chk_end("after the flush mid-data");
      end

      //--------------------------------------------------------------
      im_h = (2 * VRAM_WORDS) / 1000 + 3;                       // rows of 1000 pixels at 16 bpp
      if ((GPU_XY_EN != 0) && (GPU_DIM_MASK >= 1000) && (im_h <= GPU_DIM_MASK)) begin
         $display("--- an immediate start past VRAM_WORDS (clip window): ERR_CAUSE 5, nothing drawn");
         im_set_mode(4);
         gpu_c_size(1000, im_h);
         gpu_c_dst_xy(16'd64, (IM_DLO * 2) - (im_h - 3) * 64);
         gpu_c_xy(0, 0);
         gpu_c_clip(0, im_h - 2, 10, im_h - 1);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push({OP_SET_SRC, 7'h00, 1'b1, 20'h00000});
         gpu_push((1000 * im_h + 1) / 2);
         im_t = gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_push(im_t);
         repeat(300) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_EXEC_COPY, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_rd(GPU_ERR, im_t);
         reg_wr(GPU_CTRL, 32'h1);
         reg_wr(CTRL, 32'h4);                                     // the data owed dropped
         gpu_set_mode(4);
         gpu_c_noclip;
         gpu_check_all("immediate start past the VRAM");
      end

      // the start index past the pixel address range (2^PA_W): it saturates and
      // the bound check stops the copy
      im_h = (1 << (GPU_PA_W - 12)) + 1;                         // start row of a 4096-wide source
      if ((GPU_XY_EN != 0) && (GPU_DIM_MASK >= 4096) && (im_h + 2 <= GPU_DIM_MASK) && (im_h <= 2000)) begin
         $display("--- an immediate start index past 2^PA_W (row %0d of a 4096-pixel source): ERR_CAUSE 5, nothing drawn", im_h);
         im_set_mode(4);
         gpu_c_size(4096, im_h + 2);
         gpu_c_dst_xy(16'd64, IM_DLO * 2);
         gpu_c_xy(0, 0);
         gpu_c_clip(0, im_h, 10, im_h + 1);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push({OP_SET_SRC, 7'h00, 1'b1, 20'h00000});
         gpu_push(24'hFF_FFFF);
         im_t = gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_push(im_t);
         repeat(300) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_EXEC_COPY, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_rd(GPU_ERR, im_t);
         reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR | IF_DONE);
         reg_wr(GPU_CTRL, 32'h1);
         reg_wr(CTRL, 32'h4);                                     // the data owed dropped
         gpu_set_mode(4);
         gpu_c_noclip;
         gpu_check_all("immediate start past 2^PA_W");
      end

      // 1 bpp, a power-of-two VRAM: the last word of the pixel-address range is
      // inside the VRAM, so an index past 2^PA_W must not wrap or saturate into
      // it: a start past it (the clip window) and a walk crossing it (the line
      // step) stop the rectangle with ERR_CAUSE 5 (the data words zero, not
      // OPAQUE: nothing drawn either way). Rows of 1000 pixels.
      im_st = (32'h1 << GPU_PA_W) - 32'd64;                     // 64 pixels below 2^PA_W
      im_h  = (1 << GPU_PA_W) / 1000;                           // its row; the row after is past
      im_x  = im_st % 1000;
      if ((VRAM_WORDS == (1 << VRAM_AW)) && (GPU_XY_EN != 0) && (im_h + 2 <= GPU_DIM_MASK) &&
          (im_h + 2 <= 2000) && (im_x + 64 <= 1000) && (im_st / 1000 == im_h)) begin
         for (im_k = 0; im_k < 2; im_k = im_k + 1) begin
            $display("--- a 1-bpp immediate EXPAND %0s 2^PA_W (power-of-two VRAM): ERR_CAUSE 5, nothing drawn",
                     (im_k == 0) ? "starting past" : "walking across");
            im_set_mode(4);
            gpu_c_size(1000, im_h + 2);
            gpu_c_dst_xy(16'd64, (IM_DLO * 2) - (im_h + 1 - im_k) * 64);
            gpu_c_xy(0, 0);
            if (im_k == 0) gpu_c_clip(0, im_h + 1, 10, im_h + 1);              // start index past 2^PA_W
            else           gpu_c_clip(im_x, im_h, im_x + 63, im_h + 1);        // 2^PA_W - 64, then the next row
            gpu_wait_idle;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_push({OP_SET_SRC, 7'h00, 1'b1, 4'h1, 16'h0000});  // SRC_FMT 1: 1 bpp
            gpu_push((1000 * (im_h + 2) + 31) / 32);
            im_t = {OP_EXEC_EXP, 14'd0, 2'b00, 4'h0, 1'b0, 3'b000, 1'b0, 1'b0, 2'b00};
            gpu_push(im_t);
            if (im_k == 1) begin                                 // the words up to the last below 2^PA_W
               im_n = gpu_push_wait;
               gpu_push_wait = 1'b1;
               for (im_i = 0; im_i < (1 << VRAM_AW); im_i = im_i + 1) gpu_push(32'h0);
               gpu_push_wait = im_n;
            end
            repeat(300) @(posedge free_clk);
            reg_rd_mask(GPU_STAT, {OP_EXEC_EXP, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
            reg_rd(GPU_ERR, im_t);
            reg_wr(GPU_CTRL, 32'h1);
            reg_wr(CTRL, 32'h4);                                  // the data owed dropped
            gpu_set_mode(4);
            gpu_c_noclip;
            gpu_check_all("1-bpp immediate index past 2^PA_W");
         end
      end

      gpu_check_all("immediate end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
