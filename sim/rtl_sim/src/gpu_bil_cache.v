//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_bil_cache
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_bil_cache.v
// Module Description : The bilinear tap cache (16 bpp, GPU_BILINEAR_EN and
//                      GPU_XY_EN), run with each configuration's
//                      VRAM_RD_LAT:
//                      - footprints across words and rows: spans and blits
//                        at even and odd texel starts, rotations, zoom-in
//                        and zoom-out, free pitch (odd pitches: the row
//                        parity of a footprint; pitches of 2 048 to
//                        65 535 pixels), power-of-two wraps; the
//                        image, the allowed words, the colour words read
//                        against the 2 x 2 direct-mapped cache model of
//                        gpu_model.v (index: texel row and word parity,
//                        cleared at each command start), with RGB565A8 the
//                        A8 words read (one per colour miss, two with an odd
//                        alpha offset): micro-architecture regression counts,
//                        the image is the spec check. Each VRAM read is
//                        attributed to the model's words (its ledger of
//                        misses and companions), word by word: a footprint
//                        may wrap far from the texture (free pitch without
//                        BOUND, v0 < 1/2: row y0 = -1 is row 1023), and
//                        directed footprints do;
//                      - the debug freeze toggled mid-blit (it holds between
//                        pixels: the image exact, the cache dropped);
//                      - ABORT and GPU_EN = 0 mid-blit: a strict prefix of
//                        the walk, no GPU_DONE, then the next blit exact;
//                      - a texture overlapping its destination (a W write
//                        to a cached word: the result undefined): the blit
//                        ends with GPU_DONE, no error, and the next blit is
//                        exact.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer BC_TLO  = 4096;               // textures: words [4096, 6144)
localparam integer BC_ALO  = 8192;               // A8 planes: words [8192, 9216)
localparam integer BC_DLO  = 10240;              // destinations: words [10240, 14336)
localparam integer BC_DP   = 128;

integer    bc_nless = 0;
integer    bc_nwrap = 0;                  // colour words read outside the texture window (wrapped rows)
// The reads of a blit (word addresses), attributed after it to the model's ledger
localparam integer BC_RD_N = 16384;
integer    bc_nrd;
reg [31:0] bc_rd   [0:BC_RD_N-1];
integer    bc_rc   [0:VRAM_WORDS-1];      // reads of a word
integer    bc_mc   [0:VRAM_WORDS-1];      // the model's colour misses of a word
reg        bc_ma   [0:VRAM_WORDS-1];      // a word the model's A8 companions may read
initial begin : bc_led_init
   integer ii;
   for (ii = 0; ii < VRAM_WORDS; ii = ii + 1) begin bc_rc[ii] = 0; bc_mc[ii] = 0; bc_ma[ii] = 1'b0; end
end
integer    bc_i, bc_k, bc_w, bc_h, bc_crd, bc_ard, bc_c0, bc_lo0, bc_hi0, bc_cls, bc_nd, bc_trg, bc_nstrict;
reg        bc_on, bc_bl, bc_hit;
reg        bc_nobnd = 1'b0;               // no BOUND (every pixel drawn: the abandon cases)
reg [31:0] bc_t, bc_flag;

initial begin bc_on = 1'b0; bc_crd = 0; bc_ard = 0; bc_nrd = 0; end
always @(posedge hclk)
   if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && !gpu_mon_wp && bc_on && (vram_wen === 4'hF)) begin
      if (bc_nrd < BC_RD_N) bc_rd[bc_nrd] = vram_addr;
      bc_nrd = bc_nrd + 1;
   end

// The blit's reads, word by word against the model's ledger: a colour word is
// read exactly as often as the model misses it (plus its A8 reads when it is
// also an A8 word of the blit); the rest of the A8 words' reads are the A8
// reads (bc_ard); a read of the texture or A8 window the ledger does not
// explain is an error. Sets bc_crd, bc_ard.
task bc_attrib;
   integer i, w, ex;
   begin
      bc_crd = 0; bc_ard = 0;
      if ((bc_nrd > BC_RD_N) || (gpu_bc_log_nc >= GPU_BC_LOG_N) || (gpu_bc_log_na >= GPU_BC_LOG_N - 1))
         tb_error("bilinear read ledger full (test bug)");
      for (i = 0; i < gpu_bc_log_nc; i = i + 1) bc_mc[gpu_bc_log_c[i]] = bc_mc[gpu_bc_log_c[i]] + 1;
      for (i = 0; i < gpu_bc_log_na; i = i + 1) bc_ma[gpu_bc_log_a[i]] = 1'b1;
      for (i = 0; (i < bc_nrd) && (i < BC_RD_N); i = i + 1) bc_rc[bc_rd[i]] = bc_rc[bc_rd[i]] + 1;
      // colour words (counted once: bc_mc cleared once seen)
      for (i = 0; i < gpu_bc_log_nc; i = i + 1) begin
         w = gpu_bc_log_c[i];
         if (bc_mc[w] != 0) begin
            ex = bc_rc[w] - bc_mc[w];
            if ((ex < 0) || ((ex != 0) && !bc_ma[w])) begin
               $display("ERROR: GPU bilinear colour word 0x%h read %0d times, the cache model %0d %t", w, bc_rc[w], bc_mc[w], $time);
               error = error + 1;
            end
            bc_crd = bc_crd + bc_mc[w];
            if (ex > 0) bc_ard = bc_ard + ex;
            if ((w < BC_TLO) || (w >= BC_TLO + 2048)) bc_nwrap = bc_nwrap + 1;
            bc_mc[w] = 0;
            bc_rc[w] = 0;                                  // (its A8 reads counted)
         end
      end
      // A8 words that are not colour words
      for (i = 0; i < gpu_bc_log_na; i = i + 1) begin
         w = gpu_bc_log_a[i];
         bc_ard = bc_ard + bc_rc[w];
         bc_rc[w] = 0;
      end
      // reads the ledger does not explain, in the texture or the A8 window
      for (i = 0; (i < bc_nrd) && (i < BC_RD_N); i = i + 1) begin
         w = bc_rd[i];
         if ((bc_rc[w] != 0) && (((w >= BC_TLO) && (w < BC_TLO + 2048)) || ((w >= BC_ALO) && (w < BC_ALO + 1024)))) begin
            $display("ERROR: GPU bilinear read of word 0x%h, no tap or A8 companion of the model %t", w, $time);
            error = error + 1;
         end
         bc_rc[w] = 0;
      end
      for (i = 0; i < gpu_bc_log_na; i = i + 1) bc_ma[gpu_bc_log_a[i]] = 1'b0;
   end
endtask

function integer bc_rnd;
   input integer n;
   begin
      bc_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

// A random texture and blit set-up (w x h), the kind of footprint
task bc_setup;
   input integer kind;
   reg   [15:0] du, dv, dur, dvr;
   reg          fr;
   begin
      fr = (kind == 3);
      gpu_c_tex_filter(1'b1, bc_bl && bc_rnd(2));
      if (bc_bl) gpu_c_alpha5(1'b0, 8'd0, bc_rnd(2));
      gpu_k_a8 = bc_bl && bc_rnd(2);
      gpu_c_src(fr ? (16'd17 + 2 * bc_rnd(20)) : 16'd0, 2 * BC_TLO + 64 + bc_rnd(64));   // free pitch: odd
      if (gpu_k_a8) gpu_c_alpha_plane(4 * BC_ALO + 64 + bc_rnd(64));                    // even and odd offsets
      gpu_c_tex(4'd5, 4'd5, 1'b0, 3'b000, fr, !bc_nobnd && (bc_rnd(3) == 0), 8'h00);
      gpu_c_texbox(8 + bc_rnd(24), 8 + bc_rnd(24));
      gpu_c_uv(bc_rnd(1024), bc_rnd(1024));
      case (kind)
        0: begin du = 16'd2048; dv = 16'd0;      dur = 16'd0;     dvr = 16'd2048; end   // 1:1, fractional start
        1: begin du = 16'd1774; dv = 16'd1024;   dur = -16'sd1024; dvr = 16'd1774; end  // 30 degrees
        2: begin du = 16'd683;  dv = 16'd0;      dur = 16'd0;     dvr = 16'd683;  end   // zoom-in 3x
        3: begin du = 16'd2048 + bc_rnd(2048); dv = bc_rnd(1024); dur = bc_rnd(1024); dvr = 16'd2048; end
        default: begin du = 16'd4096 + bc_rnd(2048); dv = 16'd0; dur = 16'd0; dvr = 16'd4096; end   // zoom-out
      endcase
      gpu_c_step(du, dv);
      gpu_c_step_row(dur, dvr);
      gpu_c_size(bc_w, bc_h);
      gpu_c_dst(BC_DP, 2 * BC_DLO + 2 * BC_DP * 4 + 2 * bc_rnd(BC_DP * 4) + bc_rnd(2));
   end
endtask

task bc_check_reads;
   input [8*40-1:0] label;
   begin
      // the colour reads exact; the A8 reads at most the companion count (one per
      // colour miss, two with an odd alpha offset), none without an RGB565A8 source
      if (bc_ard < gpu_bil_nard_hi - bc_hi0) bc_nless = bc_nless + 1;
      if ((bc_crd != gpu_bil_ncrd - bc_c0) || (bc_ard > gpu_bil_nard_hi - bc_hi0) ||
          ((gpu_bil_nard_hi == bc_hi0) && (bc_ard != 0)) || ((gpu_bil_nard_hi != bc_hi0) && (bc_ard == 0))) begin
         $display("ERROR: GPU bilinear %0s: %0d colour / %0d A8 reads, the cache model %0d / %0d (A8 at least %0d) %t",
                  label, bc_crd, bc_ard, gpu_bil_ncrd - bc_c0, gpu_bil_nard_hi - bc_hi0, gpu_bil_nard_lo - bc_lo0, $time);
         error = error + 1;
      end
   end
endtask

// One footprint blit of the current set-up: its reads against the model
task bc_footprint;
   input [8*40-1:0] label;
   begin
      gpu_wait_idle;
      bc_c0 = gpu_bil_ncrd; bc_lo0 = gpu_bil_nard_lo; bc_hi0 = gpu_bil_nard_hi;
      bc_nrd = 0;
      gpu_bc_log_nc = 0; gpu_bc_log_na = 0;
      gpu_bc_log_on = 1'b1;
      gpu_alw_clear;
      gpu_alw_start;
      bc_on = 1'b1;
      gpu_c_texrect(0);
      gpu_wait_idle;
      bc_on = 1'b0;
      gpu_bc_log_on = 1'b0;
      gpu_alw_stop;
      gpu_k_a8 = 1'b0;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      bc_attrib;
      bc_check_reads(label);
      gpu_check_touched(label);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: bilinear tap cache                |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BILINEAR_EN == 0) || (GPU_XY_EN == 0))
         tb_skip_finish("|   (GPU_BILINEAR_EN / GPU_XY_EN = 0: absent)   |");
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;
      bc_bl = (GPU_BLEND_EN != 0);
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_mode(4);
      gpu_set_dispw(64);
      $display("       VRAM_RD_LAT %0d", VRAM_RD_LAT);

      //--------------------------------------------------------------
      $display("--- 1. footprints: colour and A8 reads against the cache model");
      for (bc_i = 0; (bc_i < 60) && (error == 0); bc_i = bc_i + 1) begin
         bc_w = 4 + bc_rnd(24); bc_h = 2 + bc_rnd(10);
         bc_setup(bc_i % 5);
         bc_footprint("footprint");
      end
      // footprints wrapping to row 1023 (free pitch without BOUND, v0 < 1/2)
      bc_nobnd = 1'b1;
      for (bc_i = 0; (bc_i < 8) && (error == 0); bc_i = bc_i + 1) begin
         bc_w = 4 + bc_rnd(24); bc_h = 2 + bc_rnd(10);
         bc_setup(3);
         gpu_c_uv(bc_rnd(1024), bc_rnd(32));
         bc_footprint("wrapped footprint");
      end
      bc_nobnd = 1'b0;
      if (bc_nwrap == 0) tb_error("no footprint read a wrapped row (test bug)");
      // free pitches of 2 048 to 65 535 pixels (a 32 x 2 texture, its second
      // row far from the first, kept off the destinations): every pitch bit
      if (VRAM_WORDS >= BC_TLO + 32768 + 512)
         for (bc_i = 0; (bc_i < 12) && (error == 0); bc_i = bc_i + 1) begin
            bc_w = 4 + bc_rnd(8); bc_h = 1;
            bc_setup(3);
            gpu_k_a8 = 1'b0;
            gpu_c_src(bc_rnd(2) ? (16'd2048 + bc_rnd(4096)) : (16'd24000 + bc_rnd(41536)), 2 * BC_TLO + 64 + bc_rnd(64));
            gpu_c_tex(4'd5, 4'd1, 1'b0, 3'b000, 1'b1, 1'b0, 8'h00);
            gpu_c_uv(bc_rnd(1024), 16'd32 + bc_rnd(16));
            gpu_c_step(16'd1500, 16'd0);
            gpu_c_step_row(16'd0, 16'd0);
            bc_footprint("free pitch above 2 048");
         end
      $display("       %0d colour words, %0d A8 words read (model); %0d blits read fewer A8 words than one per miss; %0d colour words of wrapped rows",
               gpu_bil_ncrd, gpu_bil_nard_hi, bc_nless, bc_nwrap);

      //--------------------------------------------------------------
      $display("--- 2. the debug freeze toggled mid-blit: the image exact");
      reg_wr(DBG_CTRL, 32'h2);
      for (bc_i = 0; (bc_i < 8) && (error == 0); bc_i = bc_i + 1) begin
         bc_w = 24; bc_h = 10;
         bc_setup(bc_i % 5);
         gpu_wait_idle;
         gpu_c_texrect(0);
         for (bc_k = 0; bc_k < 12; bc_k = bc_k + 1) begin
            repeat(3 + bc_rnd(40)) @(posedge free_clk);
            @(negedge free_clk) dbg_stoptime = 1'b1;
            repeat(5 + bc_rnd(20)) @(posedge free_clk);
            @(negedge free_clk) dbg_stoptime = 1'b0;
         end
         gpu_wait_idle;
         gpu_k_a8 = 1'b0;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("bilinear across freezes");
      end
      reg_wr(DBG_CTRL, 32'h0);

      //--------------------------------------------------------------
      if (GPU_DIM_MASK >= 1023) begin
         $display("--- 3. ABORT / GPU_EN = 0 mid-blit: a strict prefix, then an exact blit");
         bc_nstrict = 0;
         for (bc_i = 0; (bc_i < 10) && (error == 0); bc_i = bc_i + 1) begin
            bc_w = 40; bc_h = 12;
            bc_nobnd = 1'b1;
            bc_setup(bc_i % 5);
            bc_nobnd = 1'b0;
            gpu_wait_idle;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_mon_start;
            gpu_rec_begin;
            gpu_c_texrect(0);
            gpu_rec_end;
            bc_trg = 2 + bc_rnd(20);
            gpu_wait_wr(bc_trg, bc_hit);
            if (!bc_hit) tb_error("bilinear blit ended before the abandon (test bug)");
            if (bc_i[0]) reg_wr(GPU_CTRL, 32'h2);
            else         reg_wr(CTRL, {29'h0, gpu_m_mode});
            repeat(10) @(posedge free_clk);
            reg_rd_val(IRQ_FLAG, bc_flag);
            gpu_mon_stop;
            gpu_rec_prefix(bc_flag[4], bc_cls, bc_nd);
            if (bc_cls == 1) bc_nstrict = bc_nstrict + 1;
            else begin
               $display("ERROR: GPU bilinear %0s after %0d writes: class %0d (%0d of %0d pixels), a strict prefix expected %t",
                        bc_i[0] ? "ABORT" : "GPU_EN = 0", bc_trg, bc_cls, bc_nd, gpu_rec_n, $time);
               error = error + 1;
            end
            if (!bc_i[0]) gpu_set_mode(gpu_m_mode);
            gpu_k_a8 = 1'b0;
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_check_touched("abandoned bilinear blit");
            bc_w = 12; bc_h = 4;
            bc_setup(bc_rnd(5));
            gpu_c_texrect(0);
            gpu_wait_idle;
            gpu_k_a8 = 1'b0;
            gpu_check_touched("bilinear blit after the abandon");
         end
         $display("       %0d strict prefixes", bc_nstrict);
      end

      //--------------------------------------------------------------
      $display("--- 4. a texture overlapping its destination: the blit ends, the next is exact");
      for (bc_i = 0; (bc_i < 4) && (error == 0); bc_i = bc_i + 1) begin
         gpu_c_tex_filter(1'b1, 1'b0);
         gpu_k_a8 = 1'b0;
         gpu_c_src_fmt(16'd64, 2 * BC_DLO + 2 * 64 * 4, 4'h0);
         gpu_c_tex(4'd6, 4'd5, 1'b0, 3'b000, 1'b1, 1'b0, 8'h00);
         gpu_c_uv(16'd32 + bc_rnd(64), 16'd32 + bc_rnd(64));
         gpu_c_step(16'd2048, 16'd0);
         gpu_c_step_row(16'd0, 16'd2048);
         gpu_c_size(14'd20, 14'd6);
         gpu_c_dst(16'd64, 2 * BC_DLO + 2 * 64 * 4 + 1 + bc_rnd(3));    // over the texture, a texel off
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push({OP_EXEC_TEXRECT, 28'h0});                             // not modelled (undefined)
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE | IF_ERR);
         for (bc_k = BC_DLO; bc_k < BC_DLO + 4096; bc_k = bc_k + 1) gpu_shadow[bc_k] = vram_mem[bc_k];
         bc_w = 12; bc_h = 4;
         bc_setup(bc_rnd(5));
         gpu_c_texrect(0);
         gpu_wait_idle;
         gpu_k_a8 = 1'b0;
         gpu_check_touched("bilinear blit after an overlap");
      end
      gpu_c_tex_filter(1'b0, 1'b0);
      if (bc_bl) gpu_c_alpha(1'b0, 8'd0);
      gpu_check_all("gpu_bil_cache end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
