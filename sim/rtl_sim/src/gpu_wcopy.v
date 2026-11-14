//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_wcopy
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_wcopy.v
// Module Description : Word-token COPY: EXEC_COPY and EXEC_COPY_TRANSP at
//                      every depth, source and destination at every pair of
//                      slots in their words at 4 and 8 bpp (sampled at 1, 2
//                      and 16 bpp), run lengths from 1 to two words and one
//                      pixel, every swap (none, X, Y, XY on both sides, the
//                      two mirrors, CL swaps), every raster operation, keys
//                      taken from the source (some at the edges of its
//                      words, some source words wholly transparent), a
//                      source pitch a pixel off the destination's now and
//                      then; with GPU_XY_EN, x/y destinations cut by the
//                      clip window on either side. Each copy: the image
//                      against gpu_model.v (pixel by pixel in walk order),
//                      the VRAM reads and writes against the model's
//                      accounting at the level the RTL implements
//                      (GPU_WCOPY_LVL), only the words of the rectangle
//                      accessed, whole 16-bpp pixels in the byte enables.
//                      Source and destination in separate regions (the
//                      overlapping cases are gpu_overlap's).
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer WC_P    = 192;                // pitch (pixels)
localparam integer WC_SLO  = 4096;               // source region: words [4096, 5120)
localparam integer WC_DLO  = 6144;               // destination region: words [6144, 7168)
localparam integer WC_SZ   = 1024;
localparam integer WC_X0   = 80;                 // first column visited (+ the slot)
localparam integer WC_Y0   = 4;                  // first row visited
localparam integer WC_WMAX = (GPU_DIM_MASK >= 65) ? 65 : GPU_DIM_MASK;

integer    wc_mode, wc_bl, wc_ppw, wc_n, wc_i, wc_j, wc_k, wc_w, wc_h, wc_ss, wc_ds, wc_sp, wc_ww;
integer    wc_rd0, wc_wr0, wc_nkey, wc_nmir, wc_ncl, wc_nxy, wc_x, wc_cx0, wc_cx1;
reg [31:0] wc_sb, wc_db, wc_pm, wc_t, wc_pa;
reg  [3:0] wc_cmd, wc_op;
reg  [2:0] wc_dsw, wc_ssw;
reg [15:0] wc_c0, wc_c1, wc_c2, wc_c3;

function integer wc_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      wc_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task wc_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      wc_mode = mode;
      wc_bl   = gpu_bl(mode);
      wc_ppw  = 32 >> wc_bl;
      wc_pm   = gpu_pmask(wc_bl);
      wc_c0   = $random(gpu_seed);
      wc_c1   = $random(gpu_seed);
      wc_c2   = $random(gpu_seed);
      wc_c3   = $random(gpu_seed);
      if (gpu_inited) gpu_check_all("before the next class");   // no stray write absorbed by the re-init
      gpu_preload_pal(WC_SLO, WC_SLO + WC_SZ, wc_bl, wc_c0, wc_c1, wc_c2, wc_c3);
      gpu_preload_rand(WC_DLO, WC_DLO + WC_SZ);
      gpu_model_init;
      gpu_set_mode(mode);
      gpu_set_dispw(64);
      gpu_c_fill($random(gpu_seed));
   end
endtask

// Fill words [wa, wa + n) of the source with the key colour (backdoor)
task wc_solid;
   input integer wa;
   input integer n;
   input  [31:0] key;
   integer       ww, pp;
   reg    [31:0] vv;
   begin
      vv = 32'h0;
      for (pp = 0; pp < wc_ppw; pp = pp + 1)
         vv = vv | ((key & wc_pm) << (pp << wc_bl));
      for (ww = wa; ww < wa + n; ww = ww + 1)
         if ((ww >= WC_SLO) && (ww < WC_SLO + WC_SZ)) begin
            vram_mem[ww]   = vv;
            gpu_shadow[ww] = vv;
         end
   end
endtask

// One copy: source slot ss, destination slot ds, w x h, swaps, command, op;
// key: 0 random colour, 1 the source pixel at a run end (a word edge when
// the slots allow), 2 as 1 and the source words of the first run made
// transparent (some wholly, the last one or two left as they are)
task wc_case;
   input integer ss;
   input integer ds;
   input integer w;
   input integer h;
   input   [2:0] dsw;
   input   [2:0] ssw;
   input   [3:0] cmd;
   input   [3:0] op;
   input integer key;
   input         xy;                     // x/y destination, clip cutting the run
   integer       ii, sa, sb, sc;
   begin
      gpu_wait_idle;
      wc_sp = wc_rnd(4) ? WC_P : (WC_P - 1 + wc_rnd(3));
      wc_sb = (WC_SLO * wc_ppw) + WC_Y0 * WC_P + WC_X0 + ss;
      wc_db = (WC_DLO * wc_ppw) + WC_Y0 * WC_P + WC_X0 + ds;
      gpu_c_size(w, h);
      gpu_c_src(wc_sp, wc_sb);
      if (xy) begin
         // the surface origin at the region's first pixel; the run cut by the
         // clip window at one or both ends
         gpu_c_dst_xy(WC_P, WC_DLO * wc_ppw);
         gpu_c_xy(WC_X0 + ds, WC_Y0);
         wc_x   = dsw[2] ? (WC_X0 + ds - w + 1) : (WC_X0 + ds);
         wc_cx0 = wc_x + wc_rnd(3) * wc_rnd(w);
         wc_cx1 = wc_x + w - 1 - wc_rnd(3) * wc_rnd(w);
         if (wc_cx1 < wc_cx0) wc_cx1 = wc_cx0;
         gpu_c_clip(wc_cx0, 0, wc_cx1, 4 * WC_Y0);
      end else
         gpu_c_dst(WC_P, wc_db);
      if (key == 0)
         wc_t = $random(gpu_seed);
      else begin
         wc_pa = gpu_walk(wc_sb, wc_sp, ssw, w, wc_rnd(2) ? (w - 1) : 0);
         wc_t  = gpu_get_px(wc_pa, wc_bl);
         if (key == 2) begin
            // the source words of the first run, the first or the last one
            // sometimes left out
            sa = (ssw[2] ? (wc_sb - w + 1) : wc_sb) >> (5 - wc_bl);
            sb = (ssw[2] ? wc_sb : (wc_sb + w - 1)) >> (5 - wc_bl);
            sc = wc_rnd(3);
            wc_solid(sa + (sc == 1), sb - sa + 1 - (sc != 0), wc_t);
         end
      end
      gpu_c_transp(wc_t);
      for (ii = WC_SLO; ii < WC_SLO + WC_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = WC_DLO; ii < WC_DLO + WC_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      wc_rd0 = gpu_exp_rd;
      wc_wr0 = gpu_exp_wr;
      gpu_mon_bl     = wc_bl;
      gpu_mon_be_chk = 1'b1;
      gpu_alw_start;
      gpu_mon_start;
      if (xy) gpu_c_exec_xy(cmd, op, dsw, ssw);
      else    gpu_c_exec(cmd, op, dsw, ssw);
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_alw_stop;
      gpu_mon_be_chk = 1'b0;
      wc_n = wc_n + 1;
      if ((gpu_mon_rd != gpu_exp_rd - wc_rd0) || (gpu_mon_wr != gpu_exp_wr - wc_wr0)) begin
         $display("ERROR: GPU wcopy mode %0d cmd %h op %0d %0d x %0d slots %0d -> %0d swaps %b -> %b%0s: %0d reads / %0d writes, expected %0d / %0d %t",
                  wc_mode, cmd, op, w, h, ss, ds, ssw, dsw, xy ? " x/y" : "",
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - wc_rd0, gpu_exp_wr - wc_wr0, $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      if (xy) gpu_c_dst(WC_P, wc_db);
      gpu_check_touched("word-token copy");
   end
endtask

// A random copy at the current depth with the given slots
task wc_rand;
   input integer ss;
   input integer ds;
   integer       sw;
   begin
      sw = wc_rnd(10);
      case (sw)
        0, 1:    begin wc_dsw = 3'b000; wc_ssw = 3'b000; end
        2:       begin wc_dsw = 3'b100; wc_ssw = 3'b100; end
        3:       begin wc_dsw = 3'b010; wc_ssw = 3'b010; end
        4:       begin wc_dsw = 3'b110; wc_ssw = 3'b110; end
        5:       begin wc_dsw = 3'b100; wc_ssw = 3'b000; end      // mirrors
        6:       begin wc_dsw = 3'b000; wc_ssw = 3'b100; end
        7:       begin wc_dsw = 3'b010; wc_ssw = 3'b110; end
        8:       begin wc_dsw = wc_rnd(8); wc_ssw = wc_rnd(8) | 3'b001; end   // CL swaps
        default: begin wc_dsw = wc_rnd(8) | 3'b001; wc_ssw = wc_rnd(8); end
      endcase
      if (wc_dsw[2] != wc_ssw[2]) wc_nmir = wc_nmir + 1;
      if (wc_dsw[0] | wc_ssw[0]) begin
         wc_ncl = wc_ncl + 1;
         wc_w   = 1 + wc_rnd(4);
         wc_h   = 1 + wc_rnd(3);
      end else begin
         // short, about a word, about two words
         case (wc_rnd(3))
           0:       wc_w = 1 + wc_rnd(wc_ppw);
           1:       wc_w = wc_ppw - 1 + wc_rnd(3);
           default: wc_w = 1 + wc_rnd(2 * wc_ppw + 1);
         endcase
         if (wc_w < 1) wc_w = 1;
         wc_h = 1 + wc_rnd(3);
      end
      if (wc_w > WC_WMAX) wc_w = WC_WMAX;
      wc_cmd = wc_rnd(3) ? GPU_COPY : GPU_COPYT;
      wc_op  = wc_rnd(16);
      wc_k   = wc_rnd(4);
      if (wc_k == 3) wc_k = 1;
      if ((wc_cmd == GPU_COPYT) || (wc_op >= 4'd13)) wc_nkey = wc_nkey + 1;
      wc_case(ss, ds, wc_w, wc_h, wc_dsw, wc_ssw, wc_cmd, wc_op, wc_k, 1'b0);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: word-token COPY                   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < WC_DLO + WC_SZ)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      $display("       model accounting level %0d (GPU_WCOPY_LVL)", gpu_wcopy);
      wc_n = 0; wc_nkey = 0; wc_nmir = 0; wc_ncl = 0; wc_nxy = 0;

      // Every slot pair at 4 and 8 bpp, 24 pairs at 1 and 2 bpp, every pair
      // twice at 16 bpp
      for (wc_mode = 0; wc_mode < 5; wc_mode = wc_mode + 1) begin
         wc_set_mode((wc_mode == 4) ? (4 + wc_rnd(4)) : wc_mode);
         if (wc_ppw <= 8) begin
            for (wc_i = 0; wc_i < wc_ppw; wc_i = wc_i + 1)
               for (wc_j = 0; wc_j < wc_ppw; wc_j = wc_j + 1) begin
                  wc_rand(wc_i, wc_j);
                  if (wc_ppw <= 2) wc_rand(wc_i, wc_j);
                  if (error != 0) wc_j = wc_ppw;
               end
         end else
            for (wc_i = 0; wc_i < 24; wc_i = wc_i + 1)
               wc_rand((wc_i < 4) ? ((wc_i & 1) ? wc_ppw - 1 : 0) : wc_rnd(wc_ppw),
                       (wc_i < 4) ? ((wc_i & 2) ? wc_ppw - 1 : 0) : wc_rnd(wc_ppw));
         if (error != 0) wc_mode = 5;
      end

      // Every operation on aligned and unaligned long runs, unkeyed and keyed
      // with fully transparent source words, at 4 and 8 bpp
      for (wc_mode = 2; (wc_mode < 4) && (error == 0); wc_mode = wc_mode + 1) begin
         wc_set_mode(wc_mode);
         for (wc_i = 0; wc_i < 16; wc_i = wc_i + 1) begin
            wc_case(0, 0, 3 * wc_ppw, 2, 3'b000, 3'b000, GPU_COPY, wc_i, 0, 1'b0);
            wc_case(1, 0, 3 * wc_ppw - 1, 2, 3'b100, 3'b100, GPU_COPY, wc_i, 1, 1'b0);
            wc_case(wc_rnd(wc_ppw), wc_rnd(wc_ppw), 3 * wc_ppw + 1, 2, 3'b000, 3'b000, GPU_COPYT, wc_i, 2, 1'b0);
            wc_case(wc_rnd(wc_ppw), wc_rnd(wc_ppw), 2 * wc_ppw + 1, 2, 3'b100, 3'b000, GPU_COPYT, wc_i, 2, 1'b0);
         end
         wc_nkey = wc_nkey + 32;
         wc_nmir = wc_nmir + 16;
      end

      // x/y destinations, the run cut by the clip window
      if (GPU_XY_EN != 0)
         for (wc_mode = 0; (wc_mode < 5) && (error == 0); wc_mode = wc_mode + 1) begin
            wc_set_mode(wc_mode);
            for (wc_i = 0; wc_i < 6; wc_i = wc_i + 1) begin
               wc_dsw = wc_rnd(2) ? 3'b100 : 3'b000;
               wc_ssw = wc_rnd(3) ? wc_dsw : ~wc_dsw & 3'b100;
               wc_w   = 1 + wc_rnd(2 * wc_ppw + 1);
               if (wc_w > WC_WMAX) wc_w = WC_WMAX;
               wc_case(wc_rnd(wc_ppw), wc_rnd(wc_ppw), wc_w, 1 + wc_rnd(3), wc_dsw, wc_ssw,
                       wc_rnd(2) ? GPU_COPY : GPU_COPYT, wc_rnd(16), 1, 1'b1);
               wc_nxy = wc_nxy + 1;
            end
         end

      $display("       %0d copies (%0d keyed, %0d mirrored, %0d with a CL swap, %0d x/y clipped)",
               wc_n, wc_nkey, wc_nmir, wc_ncl, wc_nxy);
      gpu_check_all("wcopy end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
