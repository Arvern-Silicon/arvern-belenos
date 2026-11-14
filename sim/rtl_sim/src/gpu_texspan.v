//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_texspan
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_texspan.v
// Module Description : EXEC_TEXSPAN (opcode 0xD) with SET_EXT SET_TEX /
//                      SET_UV / SET_STEP (opcode 0x6, sub-commands 0/1/2):
//                      destination base += DELTA, then a run of N pixels
//                      walked with the SET_TEX swaps; pixel i reads the
//                      texel at the 10.11 accumulators u0<<5 + i*du,
//                      v0<<5 + i*dv (integer parts wrapped to 2^log2 w/h
//                      with FREE_PITCH 0, pitch 2^log2w; direct with
//                      FREE_PITCH 1, pitch = SET_SRC pitch or display
//                      width), skips it with TRANSP_EN when it equals the
//                      TRANSP colour, else writes texel + SHADE. GFX_MODE
//                      0..4 x eight cases (magnification, minification
//                      +-16, zero and negative steps crossing 0, fractional
//                      u0/v0, 1-texel texture, the eight swap codes,
//                      destination pitch explicit / 0), log2 sizes above
//                      10, accumulator wrap at 1024 in both texture modes,
//                      raycaster column chains (CL, DELTA +1 / + rows),
//                      DELTA +8191 / -8192, N = 0 / 1 / maximum / bits
//                      above DIM_W, state left behind (moved base, N x 1,
//                      SRC / FILL / TRANSP kept, restart from u0/v0, raster
//                      op and EXEC swaps not leaking), GPU_DONE per EXEC,
//                      frozen FIFO filled to FULL with operand commands,
//                      FREE-paced bursts, an invalid SET_EXT sub 14 and SET_EXT2 code
//                      0 (ERR, ERR_OPCODE 6, CLEAR_ERR). Touched words are
//                      read through the VRAM window, the whole VRAM is
//                      compared through the backdoor.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TX_DPITCH = 29;
localparam integer TX_SPITCH = 41;
localparam integer TX_DISPW  = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer TX_NMAX   = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer TX_SRC_LO = 40;               // textures in words [TX_SRC_LO, TX_SRC_HI)
localparam integer TX_SRC_HI = 280;
localparam integer TX_DST_LO = 300;              // destinations in words >= TX_SRC_HI
localparam integer TX_DST_HI = 990;

integer    tx_mode, tx_bl, tx_ppw, tx_c, tx_i, tx_k, tx_r, tx_n, tx_p, tx_d, tx_px, tx_lo;
integer    tx_row, tx_dt, tx_h, tx_cur, tx_tgt, tx_delta, tx_ncol;
integer    tx_skipped, tx_written, tx_wraps, tx_errop;
reg [31:0] tx_pm, tx_tb, tx_b, tx_d0, tx_tr, tx_exp, tx_eb;
reg [15:0] tx_sp, tx_pp, tx_a, tx_bb, tx_s1, tx_s2;
reg [13:0] tx_nf;
reg  [7:0] tx_sh;
reg  [3:0] tx_lwv, tx_lhv, tx_sub;
reg  [2:0] tx_sw;
reg        tx_fp, tx_te;

// Texture state (model of SET_TEX / SET_UV / SET_STEP)
reg  [3:0] tx_lw;
reg  [3:0] tx_lh;
reg        tx_ten;
reg        tx_free;
reg  [2:0] tx_dsw;
reg  [7:0] tx_shade;
reg [15:0] tx_u0;
reg [15:0] tx_v0;
reg [15:0] tx_du;
reg [15:0] tx_dv;

task tx_set_tex;
   input  [3:0] lw;
   input  [3:0] lh;
   input        ten;
   input  [2:0] dsw;                     // {X, Y, CL}
   input        free;
   input  [7:0] shade;
   begin
      gpu_push({OP_SET_EXT, 4'h0, shade, 3'b000, free, dsw, ten, lh, lw});
      tx_lw    = lw;
      tx_lh    = lh;
      tx_ten   = ten;
      tx_dsw   = dsw;
      tx_free  = free;
      tx_shade = shade;
   end
endtask

task tx_set_uv;
   input [15:0] u0;                      // unsigned 10.6
   input [15:0] v0;
   begin
      gpu_push({OP_SET_EXT, 4'h1, 24'h0});
      gpu_push({u0, v0});
      tx_u0 = u0;
      tx_v0 = v0;
   end
endtask

task tx_set_step;
   input [15:0] du;                      // signed 5.11
   input [15:0] dv;
   begin
      gpu_push({OP_SET_EXT, 4'h2, 24'h0});
      gpu_push({du, dv});
      tx_du = du;
      tx_dv = dv;
   end
endtask

// Push one EXEC_TEXSPAN and model it
task tx_exec;
   input integer delta;
   input  [13:0] n;
   reg    [13:0] d14;
   reg    [20:0] ua, va, dua, dva;
   reg    [31:0] spa, dpa, tt, pm;
   integer       kk, lw, lh, pitch, ui, vi;
   begin
      d14 = delta;
      gpu_src_fmt(4'h0);
      gpu_push({OP_EXEC_TEX, d14, n});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_m_w        = ((n & GPU_DIM_MASK) == 0) ? 1 : (n & GPU_DIM_MASK);
      gpu_m_h        = 1;
      gpu_x_setup(GPU_FILL, 4'd0, tx_dsw, 3'b000);
      pm    = gpu_pmask(gpu_x_bl);
      lw    = (tx_lw > 4'd10) ? 10 : tx_lw;
      lh    = (tx_lh > 4'd10) ? 10 : tx_lh;
      pitch = tx_free ? gpu_x_spitch : (1 << lw);
      ua    = {tx_u0, 5'b00000};
      va    = {tx_v0, 5'b00000};
      dua   = {{5{tx_du[15]}}, tx_du};
      dva   = {{5{tx_dv[15]}}, tx_dv};
      for (kk = 0; kk < gpu_x_w; kk = kk + 1) begin
         ui = ua[20:11];
         vi = va[20:11];
         if (!tx_free) begin
            ui = ui & ((1 << lw) - 1);
            vi = vi & ((1 << lh) - 1);
         end
         spa = (gpu_x_sbase + vi * pitch + ui) & GPU_PA_MASK;
         if (gpu_word_of(spa, gpu_x_bl) >= TX_SRC_HI)
            tb_error("texel outside the texture region (test bug)");
         tt  = gpu_get_px(spa, gpu_x_bl);
         dpa = gpu_walk(gpu_x_dbase, gpu_x_dpitch, gpu_x_dsw, gpu_x_w, kk);
         if (gpu_word_of(dpa, gpu_x_bl) < TX_SRC_HI)
            tb_error("destination inside the texture region (test bug)");
         gpu_touch_px(dpa, gpu_x_bl);
         if (tx_ten && (tt == (gpu_x_transp & pm)))
            tx_skipped = tx_skipped + 1;
         else begin
            if ((tt + tx_shade) > pm)
               tx_wraps = tx_wraps + 1;
            gpu_set_px(dpa, gpu_x_bl, (tt + tx_shade) & pm);
            tx_written = tx_written + 1;
         end
         ua = ua + dua;
         va = va + dva;
      end
   end
endtask

task tx_check_irq;
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

task tx_no_err;
   begin
      reg_rd_mask(GPU_STAT, tx_errop << 28, GS_ERR | 32'hF000_0000);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

task tx_check_base;
   input [31:0] exp;
   begin
      if (gpu_m_dst_base !== (exp & GPU_PA_MASK))
         tb_error("texspan chain did not end at the expected base (test bug)");
   end
endtask

// Random colour with the bits above the destination depth set
function [31:0] tx_hi_color;
   input [31:0] rnd;
   input [31:0] pm;
   begin
      tx_hi_color = rnd | (~pm & 32'hFFFF) | 32'hA5A5_0000;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: EXEC_TEXSPAN                      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed   = `SEED;
      tx_skipped = 0;
      tx_written = 0;
      tx_wraps   = 0;
      tx_errop   = 0;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(TX_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("--- GFX_MODE 0..4 x 8 cases: wrap, FREE_PITCH, steps, swaps, TRANSP_EN, SHADE");
      for (tx_mode = 0; tx_mode < 5; tx_mode = tx_mode + 1) begin
         gpu_wait_idle;
         gpu_set_mode(tx_mode);
         tx_bl  = gpu_bl(tx_mode);
         tx_ppw = 32 >> tx_bl;
         tx_pm  = gpu_pmask(tx_bl);
         for (tx_c = 0; tx_c < 8; tx_c = tx_c + 1) begin
            gpu_wait_idle;
            tx_te = tx_c % 2;
            tx_sh = ((tx_c % 3) == 0) ? 8'hFF : (8'h01 | $random(gpu_seed));
            tx_tr = tx_hi_color($random(gpu_seed), tx_pm);
            gpu_preload_rand(TX_DST_LO, TX_DST_HI);
            if (tx_te)                                       // TRANSP, TRANSP - SHADE, max
               gpu_preload_pal(TX_SRC_LO, TX_SRC_HI, tx_bl, tx_tr, tx_tr - tx_sh, tx_pm, $random(gpu_seed));
            else if ((tx_c % 4) == 0)
               gpu_preload_pal(TX_SRC_LO, TX_SRC_HI, tx_bl, $random(gpu_seed), tx_pm, tx_pm - 1, $random(gpu_seed));
            else
               gpu_preload_rand(TX_SRC_LO, TX_SRC_HI);
            tx_tb = 48 * tx_ppw + ($random(gpu_seed) & (tx_ppw - 1));
            tx_sp = ((tx_c % 3) == 2) ? 16'd117 : 16'd0;      // ignored with FREE_PITCH 0
            tx_fp = 1'b0;
            tx_a  = $random(gpu_seed);
            tx_bb = $random(gpu_seed);
            tx_nf = 1 + (($random(gpu_seed) & 32'h7FFF_FFFF) % TX_NMAX);
            case (tx_c)
              0 : begin                                      // magnification
                     tx_lwv = 4'd3;
                     tx_lhv = 4'd2;
                     if ((tx_mode % 2) == 0) begin           // u0 fraction 3F, tiny du, dv = -1/2048
                        tx_a  = tx_a | 16'h003F;
                        tx_bb = tx_bb & 16'hFFC0;
                        tx_s1 = 16'h0011;
                        tx_s2 = 16'hFFFF;
                     end else begin
                        tx_s1 = $random(gpu_seed) & 16'h07FF;
                        tx_s2 = $random(gpu_seed) & 16'h03FF;
                     end
                  end
              1 : begin                                      // negative steps crossing 0
                     tx_lwv = 4'd2;
                     tx_lhv = 4'd3;
                     tx_a   = tx_a & 16'h007F;
                     tx_bb  = tx_bb & 16'h007F;
                     tx_s1  = -($random(gpu_seed) & 16'h1FFF) - 1;
                     tx_s2  = -($random(gpu_seed) & 16'h07FF) - 1;
                  end
              2 : begin                                      // 1-texel texture, N 0 -> 1 / 1
                     tx_lwv = 4'd0;
                     tx_lhv = 4'd0;
                     tx_s1  = $random(gpu_seed);
                     tx_s2  = $random(gpu_seed);
                     tx_nf  = (tx_mode % 2) ? 14'd0 : 14'd1;
                  end
              3 : begin                                      // minification, extremes
                     tx_lwv = 4'd4;
                     tx_lhv = 4'd1;
                     if ((tx_mode % 2) == 0) begin
                        tx_s1 = 16'h7FFF;
                        tx_s2 = 16'h8000;
                     end else begin
                        tx_s1 = 16'h8000 | $random(gpu_seed);
                        tx_s2 = 16'h7FFF & $random(gpu_seed);
                     end
                  end
              4, 5 : begin                                   // FREE_PITCH 1, u in [4, 32], v in [0, 5]
                     tx_fp  = 1'b1;
                     tx_lwv = $random(gpu_seed);             // ignored
                     tx_lhv = $random(gpu_seed);
                     tx_sp  = (tx_c == 4) ? TX_SPITCH : 16'd0;
                     tx_a   = ((16 + ($random(gpu_seed) & 3)) << 6) | ($random(gpu_seed) & 63);
                     tx_bb  = ((2 + ($random(gpu_seed) & 1)) << 6) | ($random(gpu_seed) & 63);
                     tx_s1  = (($random(gpu_seed) & 32'h7FFF_FFFF) % 4097) - 2048;
                     tx_s2  = (($random(gpu_seed) & 32'h7FFF_FFFF) % 513) - 256;
                  end
              6 : begin                                      // zero steps (or dv = -1)
                     tx_lwv = 4'd1;
                     tx_lhv = 4'd4;
                     tx_s1  = 16'h0000;
                     tx_s2  = (tx_mode % 2) ? 16'hF800 : 16'h0000;
                  end
              default : begin                                // du = -16 / -15.9995
                     tx_lwv = 4'd5;
                     tx_lhv = 4'd0;
                     tx_s1  = (tx_mode % 2) ? 16'h8000 : 16'h8001;
                     tx_s2  = $random(gpu_seed) & 16'h0FFF;
                  end
            endcase
            tx_sw    = (tx_c + tx_mode) & 7;
            tx_delta = ($random(gpu_seed) & 31) - 16;
            tx_d0    = 640 * tx_ppw + ($random(gpu_seed) & (tx_ppw - 1));
            tx_pp    = ((tx_c % 3) == 1) ? 16'd0 : TX_DPITCH;
            gpu_c_transp(tx_tr);
            gpu_c_src(tx_sp, tx_tb);
            gpu_c_dst(tx_pp, tx_d0 - tx_delta);
            tx_set_tex(tx_lwv, tx_lhv, tx_te, tx_sw, tx_fp, tx_sh);
            tx_set_uv(tx_a, tx_bb);
            tx_set_step(tx_s1, tx_s2);
            tx_exec(tx_delta, tx_nf);
            gpu_wait_idle;
            tx_no_err;
            $display("       mode %0d case %0d: lw %0d lh %0d free %0d spitch %0d, uv %h/%h step %h/%h, N %0d, sw %b, transp %0d, shade %h, dpitch %0d, delta %0d",
                     tx_mode, tx_c, tx_lwv, tx_lhv, tx_fp, tx_sp, tx_a, tx_bb, tx_s1, tx_s2,
                     tx_nf, tx_sw, tx_te, tx_sh, tx_pp, tx_delta);
            tx_check_base(tx_d0);
            gpu_check_touched("texspan matrix");
         end
         gpu_check_all("texspan matrix");
      end
      $display("       skipped %0d, written %0d, shade wraps %0d", tx_skipped, tx_written, tx_wraps);

      //--------------------------------------------------------------
      $display("--- log2 sizes above 10, accumulator wrap at 1024 (1 and 2 bpp)");
      for (tx_mode = 0; tx_mode < 2; tx_mode = tx_mode + 1) begin
         gpu_wait_idle;
         gpu_set_mode(tx_mode);
         tx_bl  = gpu_bl(tx_mode);
         tx_ppw = 32 >> tx_bl;
         tx_pm  = gpu_pmask(tx_bl);
         gpu_preload_rand(TX_SRC_LO, TX_SRC_HI);
         gpu_preload_rand(TX_DST_LO, TX_DST_HI);
         tx_tb = 48 * tx_ppw + 1;
         tx_b  = 640 * tx_ppw + 7;
         gpu_c_src(16'd77, tx_tb);                            // pitch ignored (FREE_PITCH 0)
         gpu_c_dst(TX_DPITCH, tx_b);
         // 2^15 x 2: pitch 1024, u wraps 1023 -> 0
         tx_set_tex(4'd15, 4'd1, 1'b0, 3'b000, 1'b0, $random(gpu_seed));
         tx_set_uv({10'd1020, 6'h0} | ($random(gpu_seed) & 63), $random(gpu_seed));
         tx_set_step(16'h0C00, 16'h0600);                     // +1.5, +0.75
         tx_exec(0, TX_NMAX);
         // 1 x 2^12: pitch 1, v wraps 0 -> 1023, vertical run
         tx_set_tex(4'd0, 4'd12, 1'b0, 3'b001, 1'b0, $random(gpu_seed));
         tx_set_uv($random(gpu_seed), {10'd2, 6'h0} | ($random(gpu_seed) & 63));
         tx_set_step($random(gpu_seed), 16'hF800);            // dv = -1
         tx_exec(2 * TX_DPITCH, TX_NMAX);
         // 2^11 x 1: u steps +3 from 1023, X swap, TRANSP_EN
         gpu_c_transp(tx_hi_color($random(gpu_seed), tx_pm));
         tx_set_tex(4'd11, 4'd0, 1'b1, 3'b100, 1'b0, $random(gpu_seed));
         tx_set_uv({10'd1023, 6'h0} | ($random(gpu_seed) & 63), $random(gpu_seed));
         tx_set_step(16'h1800, $random(gpu_seed));
         tx_exec(40, TX_NMAX);
         // 2^11 x 2^11: pitch 1024, u steps -4 from 5, v in rows 0..1
         tx_set_tex(4'd11, 4'd11, 1'b0, 3'b010, 1'b0, $random(gpu_seed));
         tx_set_uv({10'd5, 6'h0} | ($random(gpu_seed) & 63), {10'd0, 6'h20});
         tx_set_step(16'hE000, 16'h0100);                     // -4, +0.125
         tx_exec(-3 * TX_DPITCH, TX_NMAX);
         // FREE_PITCH 1, explicit pitch: u 1022.5 + 0.75 crosses 1024 -> 0
         gpu_c_src(TX_SPITCH, tx_tb);
         tx_set_tex(4'd2, 4'd1, 1'b0, 3'b000, 1'b1, $random(gpu_seed));
         tx_set_uv({10'd1022, 6'h20}, {10'd1, 6'h0} | ($random(gpu_seed) & 63));
         tx_set_step(16'h0600, 16'h0200);                     // +0.75, +0.25
         tx_exec(20, TX_NMAX);
         // FREE_PITCH 1, explicit pitch: u from 1 with -0.5 crosses 0 -> 1023
         tx_set_uv({10'd1, 6'h0} | ($random(gpu_seed) & 63), {10'd2, 6'h0});
         tx_set_step(16'hFC00, 16'h0000);
         tx_exec(20, TX_NMAX);
         // FREE_PITCH 1, pitch 0 = display width; CL vertical run
         gpu_c_src(16'd0, tx_tb);
         tx_set_tex(4'd7, 4'd9, 1'b0, 3'b001, 1'b1, $random(gpu_seed));
         tx_set_uv({10'd1021, 6'h0} | ($random(gpu_seed) & 63), {10'd0, 6'h0} | ($random(gpu_seed) & 63));
         tx_set_step(16'h0400, 16'h0100);                     // +0.5, +0.125
         tx_exec(20, TX_NMAX);
         gpu_wait_idle;
         tx_no_err;
         $display("       mode %0d texture base 0x%h", tx_mode, tx_tb);
         gpu_check_touched("texspan wrap / large log2");
      end
      gpu_check_all("texspan wrap / large log2");

      //--------------------------------------------------------------
      $display("--- raycaster: CL columns, DELTA +1 (+ rows), own SET_UV / SET_STEP each");
      for (tx_i = 0; tx_i < 3; tx_i = tx_i + 1) begin
         gpu_wait_idle;
         tx_mode = (tx_i == 0) ? 3 : (tx_i == 1) ? 4 : 0;
         gpu_set_mode(tx_mode);
         tx_bl  = gpu_bl(tx_mode);
         tx_ppw = 32 >> tx_bl;
         tx_pm  = gpu_pmask(tx_bl);
         tx_tr  = tx_hi_color($random(gpu_seed), tx_pm);
         gpu_preload_pal(TX_SRC_LO, TX_SRC_HI, tx_bl, tx_tr, $random(gpu_seed), tx_pm, $random(gpu_seed));
         gpu_preload_rand(TX_DST_LO, TX_DST_HI);
         tx_p  = ((tx_i == 1) && (TX_DISPW >= 30)) ? TX_DISPW : TX_DPITCH;
         tx_pp = ((tx_i == 1) && (TX_DISPW >= 30)) ? 16'd0 : TX_DPITCH;
         tx_b  = TX_DST_LO * tx_ppw + 16 * tx_p + 3 + ($random(gpu_seed) & (tx_ppw - 1));
         tx_sw = (tx_i == 1) ? 3'b011 : 3'b001;                // CL, upward with Y
         tx_tb = 48 * tx_ppw + ($random(gpu_seed) & (tx_ppw - 1));
         gpu_c_transp(tx_tr);
         gpu_c_src(16'd0, tx_tb);
         gpu_c_dst(tx_pp, tx_b);
         tx_eb  = tx_b;
         tx_row = 0;
         for (tx_k = 0; tx_k < 12; tx_k = tx_k + 1) begin
            if ((tx_k % 3) == 0)                               // shade changes every 3 columns
               tx_set_tex(4'd3, 4'd3, tx_i == 2, tx_sw, 1'b0, 8'h10 * tx_k + ($random(gpu_seed) & 15));
            tx_h  = 4 + (($random(gpu_seed) & 32'h7FFF_FFFF) % 6);
            if (tx_h > GPU_DIM_MASK) tx_h = GPU_DIM_MASK;
            tx_dt = (tx_k == 0) ? 0 : ($random(gpu_seed) & 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % 5) - 2;
            if ((tx_row + tx_dt > 6) || (tx_row + tx_dt < -6))
               tx_dt = -tx_dt;
            tx_row   = tx_row + tx_dt;
            tx_delta = (tx_k == 0) ? 0 : 1 + tx_dt * tx_p;
            tx_set_uv(((($random(gpu_seed) & 7)) << 6) | ($random(gpu_seed) & 63), $random(gpu_seed) & 63);
            tx_set_step((tx_i == 2) ? ($random(gpu_seed) & 16'h00FF) : 16'h0000, 16384 / tx_h);
            tx_exec(tx_delta, tx_h);
            tx_eb = tx_eb + tx_delta;
         end
         gpu_wait_idle;
         tx_no_err;
         $display("       mode %0d, line pitch %0d (SET_DST pitch %0d), sw %b, base 0x%h",
                  tx_mode, tx_p, tx_pp, tx_sw, tx_b);
         tx_check_base(tx_eb);
         gpu_check_touched("texspan raycaster");
      end
      gpu_check_all("texspan raycaster");

      //--------------------------------------------------------------
      $display("--- extreme deltas +8191 / -8192 (largest that fits)");
      for (tx_mode = 0; tx_mode < 5; tx_mode = tx_mode + 1) begin
         gpu_wait_idle;
         gpu_set_mode(tx_mode);
         tx_bl  = gpu_bl(tx_mode);
         tx_ppw = 32 >> tx_bl;
         tx_px  = VRAM_WORDS * tx_ppw;
         tx_lo  = TX_SRC_HI * tx_ppw;
         tx_d   = (tx_px - tx_lo - 80) / 2;
         if (tx_d > 8191) tx_d = 8191;
         tx_b   = tx_lo + tx_d + 18 + ($random(gpu_seed) & (tx_ppw - 1));
         gpu_c_dst(16'd8, tx_b);
         gpu_c_src(16'd0, 48 * tx_ppw + 5);
         tx_set_tex(4'd2, 4'd1, 1'b0, (tx_mode % 2) ? 3'b100 : 3'b000, 1'b0, $random(gpu_seed));
         tx_set_uv($random(gpu_seed), $random(gpu_seed));
         tx_set_step($random(gpu_seed), $random(gpu_seed));
         tx_exec(tx_d,        14'd4);                          // S + d
         tx_exec(-(tx_d + 1), 14'd2);                          // S - 1
         tx_exec(-(tx_d + 1), 14'd3);                          // S - 2 - d
         tx_exec(tx_d,        14'd1);                          // S - 2
         gpu_wait_idle;
         tx_no_err;
         $display("       mode %0d start 0x%h delta +%0d / -%0d", tx_mode, tx_b, tx_d, tx_d + 1);
         tx_check_base(tx_b - 2);
         gpu_check_touched("texspan extreme deltas");
      end
      gpu_check_all("texspan extreme deltas");

      //--------------------------------------------------------------
      $display("--- N maximum %0d, field truncation", GPU_DIM_MASK);
      gpu_wait_idle;
      gpu_set_mode(0);
      gpu_preload_rand(TX_SRC_LO, TX_SRC_HI);
      gpu_c_src(16'd0, 48 * 32 + 3);
      gpu_c_dst(16'd0, TX_DST_LO * 32 + 5);
      tx_set_tex(4'd3, 4'd2, 1'b0, 3'b000, 1'b0, 8'h01);
      tx_set_uv($random(gpu_seed), $random(gpu_seed));
      tx_set_step($random(gpu_seed), $random(gpu_seed));
      tx_exec(0, GPU_DIM_MASK);
      gpu_wait_idle;
      gpu_check_touched("texspan N max 1 bpp");
      gpu_c_transp(32'h1);
      tx_set_tex(4'd4, 4'd3, 1'b1, 3'b000, 1'b0, 8'h00);
      tx_exec(-3, GPU_DIM_MASK);
      gpu_wait_idle;
      gpu_check_touched("texspan N max 1 bpp, -3");
      if (DIM_W < 14) begin
         tx_exec(7, (14'd1 << DIM_W) | 14'd3);               // bits above DIM_W ignored: 3
         tx_exec(7, 14'd1 << DIM_W);                         // -> 0 -> 1
         tx_exec(7, 14'h3FFF);                               // -> 2^DIM_W - 1
         gpu_wait_idle;
         gpu_check_touched("texspan N truncated");
      end
      if (TX_DST_LO * 2 + GPU_DIM_MASK + 8 < VRAM_WORDS * 2) begin
         gpu_wait_idle;
         gpu_set_mode(4);
         gpu_c_src(16'd0, 48 * 2 + 1);
         gpu_c_dst(16'd0, TX_DST_LO * 2 + 1);
         gpu_c_transp($random(gpu_seed));
         tx_set_tex(4'd4, 4'd3, 1'b0, 3'b000, 1'b0, $random(gpu_seed));
         tx_set_step($random(gpu_seed), $random(gpu_seed));
         tx_exec(0, GPU_DIM_MASK);
         gpu_wait_idle;
         gpu_check_touched("texspan N max 16 bpp");
      end
      tx_no_err;
      gpu_check_all("texspan N");

      //--------------------------------------------------------------
      $display("--- state left behind, no leak of raster op / EXEC swaps, restart from u0, v0");
      for (tx_i = 0; tx_i < 2; tx_i = tx_i + 1) begin
         gpu_wait_idle;
         tx_mode = (tx_i == 0) ? 2 : 4;
         gpu_set_mode(tx_mode);
         tx_bl  = gpu_bl(tx_mode);
         tx_ppw = 32 >> tx_bl;
         tx_pm  = gpu_pmask(tx_bl);
         gpu_preload_rand(TX_SRC_LO, TX_SRC_HI);
         gpu_preload_rand(TX_DST_LO, TX_DST_HI);
         tx_tb = 48 * tx_ppw + 3;
         tx_b  = 640 * tx_ppw + 5 * TX_DPITCH + 3;
         gpu_c_src(TX_SPITCH, tx_tb);
         gpu_c_dst(TX_DPITCH, tx_b);
         gpu_c_size(14'd5, 14'd3);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(gpu_get_px(tx_tb + 2, tx_bl));            // a pixel the later COPY_TRANSP reads
         gpu_c_exec(GPU_FILL, 4'd5, 3'b100, 3'b000);            // XOR, X swap
         gpu_c_exec(GPU_COPY, 4'd9, 3'b111, 3'b110);            // op 9, all swaps
         tx_set_tex(4'd2, 4'd1, 1'b0, 3'b000, 1'b1, $random(gpu_seed));
         tx_set_uv({10'd3, 6'h0} | ($random(gpu_seed) & 63), {10'd1, 6'h0} | ($random(gpu_seed) & 63));
         tx_set_step(16'h0C00, 16'h0200);                       // +1.5, +0.25
         tx_exec(7, 14'd9);                                     // raster op S, SET_TEX swaps
         gpu_wait_idle;
         gpu_check_touched("texspan after XOR/swapped EXECs");
         gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);            // 9 x 1 at the moved base, FILL kept
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);            // SRC base / pitch kept
         gpu_c_exec(GPU_COPYT, 4'd0, 3'b000, 3'b000);           // TRANSP kept
         gpu_wait_idle;
         gpu_check_touched("FILL / COPY / COPY_TRANSP after tex");
         tx_exec(TX_DPITCH, 14'd6);                             // restarts from u0, v0
         tx_exec(TX_DPITCH, 14'd6);                             // again
         tx_set_step(16'hFC00, 16'h0000);                       // new step, u0 / v0 kept
         tx_exec(TX_DPITCH, 14'd6);
         gpu_c_transp(tx_hi_color($random(gpu_seed), tx_pm));
         tx_set_tex(4'd3, 4'd3, 1'b1, 3'b101, 1'b0, $random(gpu_seed));   // X|CL, pitch 41 ignored
         tx_exec(-2 * TX_DPITCH + 12, 14'd5);
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);            // 5 x 1, SET_TEX swaps not applied
         gpu_c_size(14'd4, 14'd3);
         gpu_c_exec(GPU_FILL, 4'd14, 3'b000, 3'b000);
         tx_exec(-TX_DPITCH, 14'd3);                            // size back to N x 1
         gpu_c_exec(GPU_FILL, 4'd3, 3'b000, 3'b000);
         gpu_wait_idle;
         tx_no_err;
         gpu_check_touched("texspan state");
      end
      gpu_check_all("texspan state");

      //--------------------------------------------------------------
      $display("--- GPU_DONE per texspan, irq_o");
      gpu_wait_idle;
      gpu_set_mode(4);
      gpu_preload_pal(TX_SRC_LO, TX_SRC_HI, 4, 16'h1234, 16'hFFFF, $random(gpu_seed), $random(gpu_seed));
      gpu_c_src(16'd0, 48 * 2 + 1);
      gpu_c_dst(TX_DPITCH, TX_DST_LO * 2 + 200);
      gpu_c_transp(32'h0000_1234);
      tx_set_uv($random(gpu_seed), $random(gpu_seed));
      tx_set_step($random(gpu_seed), $random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, IF_DONE);
      tx_check_irq(1'b0);
      for (tx_k = 0; tx_k < 4; tx_k = tx_k + 1) begin
         tx_set_tex(4'd2, 4'd1, tx_k & 1, (tx_k * 3) & 7, 1'b0, $random(gpu_seed));
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);              // SET_TEX: no GPU_DONE
         tx_check_irq(1'b0);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tx_exec(20, 2 + tx_k);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         tx_check_irq(1'b1);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tx_check_irq(1'b0);
      end
      tx_set_tex(4'd3, 4'd2, 1'b0, 3'b000, 1'b0, $random(gpu_seed));   // configuration: no GPU_DONE
      tx_set_uv($random(gpu_seed), $random(gpu_seed));
      tx_set_step($random(gpu_seed), $random(gpu_seed));
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_GPU_ALL);
      tx_check_irq(1'b0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      if (GPU_DIM_MASK >= 255) begin
         tx_exec(20, 14'd255);                                 // GPU_DONE only at completion
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
      end
      reg_wr(IRQ_EN, 32'h0);
      tx_no_err;
      gpu_check_touched("texspan GPU_DONE");

      //--------------------------------------------------------------
      $display("--- frozen FIFO filled to FULL with SET_UV / SET_STEP / SET_TEX / EXEC_TEXSPAN");
      gpu_wait_idle;
      gpu_set_mode(1);
      gpu_preload_rand(TX_SRC_LO, TX_SRC_HI);
      gpu_c_src(16'd0, 48 * 16 + 5);
      gpu_c_dst(TX_DPITCH, TX_DST_LO * 16 + 2000 + 1);
      gpu_c_transp($random(gpu_seed));
      tx_set_tex(4'd3, 4'd2, 1'b1, 3'b000, 1'b0, $random(gpu_seed));
      tx_set_uv($random(gpu_seed), $random(gpu_seed));
      tx_set_step($random(gpu_seed), $random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_push_wait = 1'b0;
      gpu_freeze(1'b1);
      tx_n = 0;
      while (tx_n < GPU_FIFO_DEPTH) begin
         tx_r = $random(gpu_seed) & 3;
         if ((tx_r == 0) && (tx_n + 2 <= GPU_FIFO_DEPTH)) begin
            tx_set_uv($random(gpu_seed), $random(gpu_seed));
            tx_n = tx_n + 2;
         end else if ((tx_r == 1) && (tx_n + 2 <= GPU_FIFO_DEPTH)) begin
            tx_set_step($random(gpu_seed), $random(gpu_seed));
            tx_n = tx_n + 2;
         end else if (tx_r == 2) begin
            tx_set_tex($random(gpu_seed) & 3, $random(gpu_seed) & 3, $random(gpu_seed),
                       $random(gpu_seed), 1'b0, $random(gpu_seed));
            tx_n = tx_n + 1;
         end else begin
            tx_exec(($random(gpu_seed) & 63) - 24, $random(gpu_seed) & 15);
            tx_n = tx_n + 1;
         end
      end
      reg_rd(GPU_STAT, GS_HELD | GS_BUSY | GS_FULL | (GPU_FIFO_DEPTH << 8));
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      gpu_freeze(1'b0);
      gpu_push_wait = 1'b1;
      tx_exec(5, 14'd3);                                       // ends with an EXEC: GPU_DONE
      gpu_wait_idle;
      reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tx_no_err;
      gpu_check_touched("texspan frozen FIFO burst");

      //--------------------------------------------------------------
      $display("--- FREE-paced bursts of SET_TEX / SET_UV / SET_STEP / SET_SRC / EXEC_TEXSPAN");
      for (tx_i = 0; tx_i < 2; tx_i = tx_i + 1) begin
         gpu_wait_idle;
         tx_mode = (tx_i == 0) ? 3 : 0;
         gpu_set_mode(tx_mode);
         tx_bl  = gpu_bl(tx_mode);
         tx_ppw = 32 >> tx_bl;
         tx_pm  = gpu_pmask(tx_bl);
         tx_tr  = tx_hi_color($random(gpu_seed), tx_pm);
         gpu_preload_pal(TX_SRC_LO, TX_SRC_HI, tx_bl, tx_tr, $random(gpu_seed), tx_pm, $random(gpu_seed));
         tx_lo  = TX_DST_LO * tx_ppw + 400;
         tx_cur = tx_lo + 200;
         gpu_c_dst(TX_DPITCH, tx_cur);
         gpu_c_src(16'd0, 48 * tx_ppw + 1);
         gpu_c_transp(tx_tr);
         tx_set_tex(4'd2, 4'd2, 1'b1, 3'b000, 1'b0, $random(gpu_seed));
         tx_set_uv($random(gpu_seed), $random(gpu_seed));
         tx_set_step($random(gpu_seed), $random(gpu_seed));
         tx_ncol = 0;
         for (tx_k = 0; tx_k < 3 * GPU_FIFO_DEPTH; tx_k = tx_k + 1) begin
            tx_r = $random(gpu_seed) & 15;
            if (tx_r == 0)
               tx_set_tex(($random(gpu_seed) & 32'h7FFF_FFFF) % 5, $random(gpu_seed) & 3, $random(gpu_seed),
                          $random(gpu_seed), 1'b0, $random(gpu_seed));
            else if (tx_r == 1)
               tx_set_uv($random(gpu_seed), $random(gpu_seed));
            else if (tx_r == 2)
               tx_set_step($random(gpu_seed), $random(gpu_seed));
            else if (tx_r == 3)
               gpu_c_src($random(gpu_seed), 48 * tx_ppw + ($random(gpu_seed) & 63));
            else if (tx_r == 4)
               gpu_c_transp(tx_hi_color($random(gpu_seed), tx_pm));
            else begin
               tx_tgt = tx_lo + (($random(gpu_seed) & 32'h7FFF_FFFF) % 1500);
               tx_exec(tx_tgt - tx_cur, $random(gpu_seed) & 15);
               tx_cur  = tx_tgt;
               tx_ncol = tx_ncol + 1;
            end
         end
         tx_exec(3, 14'd4);                                    // ends with an EXEC: GPU_DONE
         gpu_wait_idle;
         reg_rd(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH);
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tx_no_err;
         $display("       mode %0d, %0d texspans", tx_mode, tx_ncol + 1);
         gpu_check_touched("texspan FREE-paced burst");
      end
      gpu_check_all("texspan bursts");

      //--------------------------------------------------------------
      $display("--- reserved SET_EXT sub-commands: ERR, ERR_OPCODE 6, CLEAR_ERR");
      for (tx_i = 0; tx_i < 2; tx_i = tx_i + 1) begin
         tx_sub = (tx_i == 0) ? 4'd15 : 4'd14;           // SET_EXT2 code 0, sub 14: invalid
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push({OP_SET_EXT, tx_sub, 24'h00_1234});
         gpu_push({OP_EXEC_TEX, 14'd5, 14'd4});                 // queued, flushed: never executed
         repeat(20) @(posedge free_clk);
         tx_exp = (32'h6 << 28) | GS_ERR | GS_BUSY | (32'h2 << 8) | (GPU_FIFO_DEPTH - 2);
         reg_rd_mask(GPU_STAT, tx_exp, 32'hF0FF_FFFF);
         reg_rd_mask(IRQ_FLAG, IF_ERR, IF_GPU_ALL);
         reg_wr(GPU_CTRL, 32'h1);                                // CLEAR_ERR
         repeat(4) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, (32'h6 << 28) | GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
         tx_errop = 6;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         // the decoder resumes (texture state re-sent)
         tx_set_tex(4'd2, 4'd2, 1'b0, 3'b001, 1'b0, $random(gpu_seed));
         tx_set_uv($random(gpu_seed), $random(gpu_seed));
         tx_set_step($random(gpu_seed), $random(gpu_seed));
         tx_exec(3, 14'd5);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         tx_no_err;
         gpu_check_touched("texspan after SET_EXT error");
      end

      tx_no_err;
      gpu_check_all("texspan end");
      $display("       skipped %0d, written %0d, shade wraps %0d", tx_skipped, tx_written, tx_wraps);
      if ((tx_skipped == 0) || (tx_wraps == 0))
         tb_error("no skipped or no shade-wrapped pixel modelled (test bug)");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
