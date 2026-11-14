//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_a8_copy
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_a8_copy.v
// Module Description : RGB565A8 copies (SET_SRC SRC_FMT 5, SET_AUX SEL 4
//                      ALPHA_PLANE; GPU_BLEND_EN): each 16-bpp source pixel p
//                      blends with the byte at the alpha pointer + (p - source
//                      base), times A with SET_ALPHA EN, under the rounding
//                      rule or MIX5. Against gpu_model.v:
//                      - the alpha edges 0, 1-3, 4, 251, 252, 253, 255 with
//                        and without MIX5, EN with A 0 / 1 / 128 / 254 / 255;
//                        the no-D predicate one pixel at a time, its D read
//                        count stated here (not taken from the model): bytes
//                        252 / 253 with EN = 1, A = 255, MIX5 (252 reads D);
//                        alpha 0 / m = 0 write nothing;
//                      - one destination word with alpha 255 then 128 (the
//                        no-D pixel first: flushed and read again, 2 writes,
//                        1 read) and 128 then 255 (1 read, 1 write);
//                      - random copies: COPY and COPY_TRANSP (the key on the
//                        raw colour first, then the alpha), ops 0, 5, 13-15
//                        and random, every swap (mirrors and CL swaps on
//                        either side), random and odd alpha offsets, icon-
//                        like (0 / 255), edge and random alpha planes, x/y
//                        destinations trimmed by the clip window (the alpha
//                        follows the trimmed source);
//                      - palette modes: SRC_FMT 5 acts as 0, no A8 read.
//                      Each copy: the image (window read of the touched
//                      words), the writes, the destination and source reads
//                      exact, the A8 reads at least the model's one-word
//                      holder count (a read-ahead may add some), every access
//                      to a word the model marks (A8 words of walked pixels
//                      only), whole 16-bpp pixels in the byte enables.
//                      The access counts other than the D reads of the
//                      predicate cases follow the RTL's tokens (regression
//                      checks); the image is the spec check.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer AC_P    = 96;                 // pitch (pixels; the A8 plane's too, in bytes)
localparam integer AC_SLO  = 4096;               // source region: words [4096, 5632)
localparam integer AC_DLO  = 6144;               // destination region: words [6144, 7680)
localparam integer AC_ALO  = 8192;               // A8 plane: words [8192, 9216)
localparam integer AC_SZ   = 1536;
localparam integer AC_ASZ  = 1024;
localparam integer AC_X0   = 30;                 // first column visited (+ the slot)
localparam integer AC_Y0   = 6;                  // first row visited
localparam integer AC_WMAX = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;

integer    ac_i, ac_j, ac_k, ac_n, ac_w, ac_h, ac_sp, ac_mode, ac_nkey, ac_nmir, ac_ncl, ac_nxy, ac_nm5, ac_nen;
integer    ac_rd0, ac_wr0, ac_drd0, ac_ard0, ac_nnd0, ac_x, ac_cx0, ac_cx1, ac_cy0, ac_cy1, ac_exd, ac_exw;
integer    ac_srd, ac_drd, ac_ard, ac_wr, ac_orw, ac_nlow;
reg        ac_on;
reg [31:0] ac_sb, ac_db, ac_ab, ac_t, ac_pa, ac_st;
reg  [3:0] ac_cmd, ac_op;
reg  [2:0] ac_dsw, ac_ssw;
reg  [7:0] ac_b;

// Accesses classified by region: source, destination, A8 plane, other
initial begin ac_on = 1'b0; ac_srd = 0; ac_drd = 0; ac_ard = 0; ac_wr = 0; ac_orw = 0; end
always @(posedge hclk)
   if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && !gpu_mon_wp && ac_on) begin
      if (vram_wen !== 4'hF) ac_wr = ac_wr + 1;
      else if ((vram_addr >= AC_ALO) && (vram_addr < AC_ALO + AC_ASZ)) ac_ard = ac_ard + 1;
      else if ((vram_addr >= AC_DLO) && (vram_addr < AC_DLO + AC_SZ))  ac_drd = ac_drd + 1;
      else if ((vram_addr >= AC_SLO) && (vram_addr < AC_SLO + AC_SZ))  ac_srd = ac_srd + 1;
      else ac_orw = ac_orw + 1;
   end

function integer ac_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      ac_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task ac_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      ac_mode = mode;
      gpu_preload_rand(AC_SLO, AC_SLO + AC_SZ);
      gpu_preload_rand(AC_DLO, AC_DLO + AC_SZ);
      gpu_model_init;
      gpu_set_mode(mode);
      gpu_set_dispw(64);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));           // (the model init forgot the GPU's)
   end
endtask

// The A8 plane: 0 random, 1 icon-like (0 / 255, edges between), 2 the rule's
// edge values
function [7:0] ac_edge;
   input integer r;
   begin
      case (r % 14)
        0: ac_edge = 8'd0;    1: ac_edge = 8'd1;    2: ac_edge = 8'd3;    3: ac_edge = 8'd4;
        4: ac_edge = 8'd5;    5: ac_edge = 8'd128;  6: ac_edge = 8'd250;  7: ac_edge = 8'd251;
        8: ac_edge = 8'd252;  9: ac_edge = 8'd253;  10: ac_edge = 8'd254; default: ac_edge = 8'd255;
      endcase
   end
endfunction

task ac_plane_fill;
   input integer kind;
   integer       ww, bb;
   reg    [31:0] vv;
   reg     [7:0] b;
   begin
      for (ww = AC_ALO; ww < AC_ALO + AC_ASZ; ww = ww + 1) begin
         vv = 32'h0;
         for (bb = 0; bb < 4; bb = bb + 1) begin
            case (kind)
              0:       b = $random(gpu_seed);
              1:       b = (ac_rnd(8) == 0) ? ac_rnd(256) : (ac_rnd(2) ? 8'd255 : 8'd0);
              default: b = ac_edge(ac_rnd(14));
            endcase
            vv = vv | (b << (8 * bb));
         end
         vram_mem[ww]   = vv;
         gpu_shadow[ww] = vv;
      end
   end
endtask

task ac_set_byte;                        // one A8 byte (backdoor, both copies)
   input [31:0] ba;
   input  [7:0] b;
   begin
      vram_mem[ba >> 2]   = (vram_mem[ba >> 2] & ~(32'hFF << (8 * ba[1:0]))) | (b << (8 * ba[1:0]));
      gpu_shadow[ba >> 2] = vram_mem[ba >> 2];
   end
endtask

// Run one prepared copy with the monitors: image, writes, D / source reads
// exact, A8 reads at least the model's
task ac_run;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   input        xy;
   input [8*40-1:0] what;
   integer      ii, erd, ewr, edrd, eard;
   begin
      for (ii = AC_SLO; ii < AC_SLO + AC_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = AC_DLO; ii < AC_DLO + AC_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = AC_ALO; ii < AC_ALO + AC_ASZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      gpu_wait_idle;
      ac_rd0  = gpu_exp_rd;
      ac_wr0  = gpu_exp_wr;
      ac_drd0 = gpu_exp_drd;
      ac_ard0 = gpu_a8_nrd;
      ac_nnd0 = gpu_a8_nnd;
      gpu_mon_bl     = 4;
      gpu_mon_be_chk = (gpu_m_mode >= 3'd4);
      ac_srd = 0; ac_drd = 0; ac_ard = 0; ac_wr = 0; ac_orw = 0;
      gpu_alw_start;
      ac_on = 1'b1;
      if (xy) gpu_c_exec_xy(cmd, op, dsw, ssw);
      else    gpu_c_exec(cmd, op, dsw, ssw);
      gpu_wait_idle;
      ac_on = 1'b0;
      gpu_alw_stop;
      gpu_mon_be_chk = 1'b0;
      ac_n  = ac_n + 1;
      edrd  = gpu_exp_drd - ac_drd0;
      eard  = gpu_a8_nrd - ac_ard0;
      ewr   = gpu_exp_wr - ac_wr0;
      erd   = gpu_exp_rd - ac_rd0 - edrd - eard;               // source reads
      ac_exd = edrd;
      ac_exw = ewr;
      if ((ac_wr != ewr) || (ac_drd != edrd) || (ac_srd != erd) || (ac_ard < eard) || (ac_orw != 0)) begin
         $display("ERROR: GPU A8 %0s: mode %0d cmd %h op %0d %0d x %0d swaps %b -> %b: writes %0d / %0d, D reads %0d / %0d, source reads %0d / %0d, A8 reads %0d / at least %0d, other %0d %t",
                  what, gpu_m_mode, cmd, op, gpu_m_w, gpu_m_h, ssw, dsw, ac_wr, ewr, ac_drd, edrd, ac_srd, erd,
                  ac_ard, eard, ac_orw, $time);
         error = error + 1;
      end
      if (ac_ard > eard) ac_nlow = ac_nlow + 1;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      if (xy) gpu_c_dst(AC_P, AC_DLO * 2);
      gpu_check_touched(what);
   end
endtask

// One RGB565A8 copy: source slot ss, destination slot ds, alpha offset ao,
// w x h, swaps, command, op, key (0 random, 1 a source pixel), x/y (trimmed
// by a clip window), the blend rule and SET_ALPHA
task ac_case;
   input integer ss;
   input integer ds;
   input integer ao;
   input integer w;
   input integer h;
   input   [2:0] dsw;
   input   [2:0] ssw;
   input   [3:0] cmd;
   input   [3:0] op;
   input integer key;
   input         xy;
   input         mix5;
   input         en;
   input   [7:0] a;
   begin
      gpu_wait_idle;
      ac_plane_fill(ac_rnd(3));
      ac_sp = ac_rnd(4) ? AC_P : (AC_P - 1 + ac_rnd(3));
      ac_sb = (AC_SLO * 2) + AC_Y0 * AC_P + AC_X0 + ss;
      ac_db = (AC_DLO * 2) + AC_Y0 * AC_P + AC_X0 + ds;
      ac_ab = (AC_ALO * 4) + AC_Y0 * AC_P + AC_X0 + ao;
      gpu_c_size(w, h);
      gpu_k_a8 = 1'b1;
      gpu_c_src(ac_sp, ac_sb);
      gpu_c_alpha_plane(ac_ab);
      gpu_c_alpha5(en, a, mix5);
      if (xy) begin
         gpu_c_dst_xy(AC_P, AC_DLO * 2);
         gpu_c_xy(AC_X0 + ds, AC_Y0);
         ac_x   = dsw[2] ? (AC_X0 + ds - w + 1) : (AC_X0 + ds);
         ac_cx0 = ac_x + ac_rnd(3) * ac_rnd(w);
         ac_cx1 = ac_x + w - 1 - ac_rnd(3) * ac_rnd(w);
         if (ac_cx1 < ac_cx0) ac_cx1 = ac_cx0;
         ac_cy0 = (!dsw[1] && (h > 1) && ac_rnd(2)) ? (AC_Y0 + 1) : 0;
         ac_cy1 = ( dsw[1] && (h > 1) && ac_rnd(2)) ? (AC_Y0 - 1) : (4 * AC_Y0);
         gpu_c_clip(ac_cx0, ac_cy0, ac_cx1, ac_cy1);
      end else
         gpu_c_dst(AC_P, ac_db);
      if (key == 0)
         ac_t = $random(gpu_seed);
      else begin
         ac_pa = gpu_walk(ac_sb, ac_sp, ssw, w, ac_rnd(2) ? (w - 1) : 0);
         ac_t  = gpu_get_px(ac_pa, 4);
      end
      gpu_c_transp(ac_t);
      ac_run(cmd, op, dsw, ssw, xy, "RGB565A8 copy");
      if (xy) gpu_c_noclip;
      gpu_k_a8 = 1'b0;
   end
endtask

task ac_rand;
   input xy;
   integer sw, r;
   reg [7:0] a;
   begin
      sw = ac_rnd(xy ? 6 : 10);
      case (sw)
        0, 1:    begin ac_dsw = 3'b000; ac_ssw = 3'b000; end
        2:       begin ac_dsw = 3'b100; ac_ssw = 3'b100; end
        3:       begin ac_dsw = 3'b010; ac_ssw = 3'b010; end
        4:       begin ac_dsw = 3'b100; ac_ssw = 3'b000; end      // mirrors
        5:       begin ac_dsw = 3'b010; ac_ssw = 3'b110; end
        6:       begin ac_dsw = 3'b110; ac_ssw = 3'b110; end
        7:       begin ac_dsw = 3'b000; ac_ssw = 3'b100; end
        8:       begin ac_dsw = ac_rnd(8); ac_ssw = ac_rnd(8) | 3'b001; end   // CL swaps
        default: begin ac_dsw = ac_rnd(8) | 3'b001; ac_ssw = ac_rnd(8); end
      endcase
      if (ac_dsw[2] != ac_ssw[2]) ac_nmir = ac_nmir + 1;
      if (ac_dsw[0] | ac_ssw[0]) begin
         ac_ncl = ac_ncl + 1;
         ac_w = 1 + ac_rnd(5);
         ac_h = 1 + ac_rnd(4);
      end else begin
         ac_w = 1 + ac_rnd(AC_WMAX);
         ac_h = 1 + ac_rnd(4);
      end
      ac_cmd = ac_rnd(3) ? GPU_COPY : GPU_COPYT;
      r = ac_rnd(8);
      ac_op = (r < 3) ? 4'd0 : (r == 3) ? 4'd5 : (r == 4) ? (4'd13 + ac_rnd(3)) : ac_rnd(16);
      if ((ac_cmd == GPU_COPYT) || (ac_op >= 4'd13)) ac_nkey = ac_nkey + 1;
      if (xy) ac_nxy = ac_nxy + 1;
      r = ac_rnd(10);
      a = (r == 0) ? 8'd0 : (r == 1) ? 8'd1 : (r == 2) ? 8'd128 : (r == 3) ? 8'd254 : (r < 6) ? 8'd255 : ac_rnd(256);
      ac_case(ac_rnd(2), ac_rnd(2), ac_rnd(4), ac_w, ac_h, ac_dsw, ac_ssw, ac_cmd, ac_op, ac_rnd(2), xy,
              ac_rnd(3) != 0, ac_rnd(3) == 0, a);
      if (gpu_m_mix5) ac_nm5 = ac_nm5 + 1;
      if (gpu_m_aen)  ac_nen = ac_nen + 1;
   end
endtask

// One pixel copy with A8 byte b: the D reads and writes stated here
task ac_one_px;
   input        mix5;
   input        en;
   input  [7:0] a;
   input  [7:0] b;
   input integer exp_d;                  // D reads
   input integer exp_w;                  // writes
   begin
      ac_sb = (AC_SLO * 2) + 2 * AC_P + 10;
      ac_db = (AC_DLO * 2) + 2 * AC_P + 10 + ac_rnd(2);
      ac_ab = (AC_ALO * 4) + 2 * AC_P + 10 + ac_rnd(4);
      ac_set_byte(ac_ab, b);
      gpu_c_size(14'd1, 14'd1);
      gpu_k_a8 = 1'b1;
      gpu_c_src(AC_P, ac_sb);
      gpu_c_alpha_plane(ac_ab);
      gpu_c_alpha5(en, a, mix5);
      gpu_c_dst(AC_P, ac_db);
      ac_run(GPU_COPY, 4'd0, 3'b000, 3'b000, 1'b0, "A8 one pixel");
      gpu_k_a8 = 1'b0;
      if ((ac_drd != exp_d) || (ac_wr != exp_w)) begin
         $display("ERROR: GPU A8 pixel byte %0d MIX5 %0d EN %0d A %0d: %0d D reads / %0d writes, expected %0d / %0d %t",
                  b, mix5, en, a, ac_drd, ac_wr, exp_d, exp_w, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: RGB565A8 copies                   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if ((GPU_EN == 0) || (GPU_BLEND_EN == 0))
         tb_skip_finish("|      (GPU_BLEND_EN = 0: no RGB565A8 source)   |");
      gpu_seed = `SEED;
      gpu_rsv_en   = 1'b1;
      gpu_rsv_seed = `SEED ^ 32'h0A8C_0B1E;
      gpu_push_wait = 1'b1;
      ac_n = 0; ac_nkey = 0; ac_nmir = 0; ac_ncl = 0; ac_nxy = 0; ac_nm5 = 0; ac_nen = 0; ac_nlow = 0;

      //--------------------------------------------------------------
      $display("--- alpha edges, the no-D predicate: one pixel, D reads and writes");
      ac_set_mode(4);
      // the rounding rule: 0 skipped, 1..254 read D, 255 alone no D
      ac_one_px(1'b0, 1'b0, 8'd0,   8'd0,   0, 0);
      ac_one_px(1'b0, 1'b0, 8'd0,   8'd1,   1, 1);
      ac_one_px(1'b0, 1'b0, 8'd0,   8'd3,   1, 1);
      ac_one_px(1'b0, 1'b0, 8'd0,   8'd252, 1, 1);
      ac_one_px(1'b0, 1'b0, 8'd0,   8'd254, 1, 1);
      ac_one_px(1'b0, 1'b0, 8'd0,   8'd255, 0, 1);
      ac_one_px(1'b0, 1'b1, 8'd255, 8'd255, 0, 1);
      ac_one_px(1'b0, 1'b1, 8'd254, 8'd255, 1, 1);
      ac_one_px(1'b0, 1'b1, 8'd0,   8'd255, 0, 0);       // 255 o 0 = 0: skipped
      ac_one_px(1'b0, 1'b1, 8'd1,   8'd255, 1, 1);       // 255 o 1 = 1
      ac_one_px(1'b0, 1'b1, 8'd128, 8'd200, 1, 1);
      // MIX5: m = 0 (0..3) skipped, 4..251 read D, 252..255 no D (EN 0)
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd0,   0, 0);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd1,   0, 0);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd3,   0, 0);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd4,   1, 1);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd251, 1, 1);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd252, 0, 1);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd253, 0, 1);
      ac_one_px(1'b1, 1'b0, 8'd0,   8'd255, 0, 1);
      // MIX5 with EN = 1, A = 255: 252 o 255 = 251 (m 31) reads D, 253 o 255 = 252 does not
      ac_one_px(1'b1, 1'b1, 8'd255, 8'd252, 1, 1);
      ac_one_px(1'b1, 1'b1, 8'd255, 8'd253, 0, 1);
      ac_one_px(1'b1, 1'b1, 8'd255, 8'd255, 0, 1);
      // A < 255 reads D even where m reaches 32 (the predicate is sufficient only)
      ac_one_px(1'b1, 1'b1, 8'd254, 8'd255, 1, 1);
      ac_one_px(1'b1, 1'b1, 8'd1,   8'd255, 0, 0);       // (255 * 1) >> 8 = 0: skipped
      ac_one_px(1'b1, 1'b1, 8'd16,  8'd255, 1, 1);       // 15: m = 2
      ac_one_px(1'b1, 1'b1, 8'd128, 8'd128, 1, 1);
      ac_one_px(1'b1, 1'b1, 8'd0,   8'd255, 0, 0);

      //--------------------------------------------------------------
      $display("--- one destination word: alpha 255 then 128, and 128 then 255");
      for (ac_k = 0; ac_k < 4; ac_k = ac_k + 1) begin
         ac_sb = (AC_SLO * 2) + 3 * AC_P + 12;
         ac_db = (AC_DLO * 2) + 3 * AC_P + 12;              // an even pixel: the two share a word
         ac_ab = (AC_ALO * 4) + 3 * AC_P + 12 + ac_rnd(3);
         ac_set_byte(ac_ab,     ac_k[0] ? 8'd128 : 8'd255);
         ac_set_byte(ac_ab + 1, ac_k[0] ? 8'd255 : 8'd128);
         gpu_c_size(14'd2, 14'd1);
         gpu_k_a8 = 1'b1;
         gpu_c_src(AC_P, ac_sb);
         gpu_c_alpha_plane(ac_ab);
         gpu_c_alpha5(1'b0, 8'd0, ac_k[1]);
         gpu_c_dst(AC_P, ac_db);
         ac_run(GPU_COPY, 4'd0, 3'b000, 3'b000, 1'b0, "one word, both orders");
         gpu_k_a8 = 1'b0;
         // no-D first: the word written, read again, written (2 / 1); else 1 / 1
         if ((ac_drd != 1) || (ac_wr != (ac_k[0] ? 1 : 2))) begin
            $display("ERROR: GPU A8 one word, %0s: %0d D reads / %0d writes, expected 1 / %0d %t",
                     ac_k[0] ? "128 then 255" : "255 then 128", ac_drd, ac_wr, ac_k[0] ? 1 : 2, $time);
            error = error + 1;
         end
      end

      //--------------------------------------------------------------
      $display("--- random RGB565A8 copies at 16 bpp (modes 4..7)");
      for (ac_i = 0; (ac_i < 4) && (error == 0); ac_i = ac_i + 1) begin
         ac_set_mode(4 + ac_i);
         for (ac_j = 0; (ac_j < 30) && (error == 0); ac_j = ac_j + 1) ac_rand(1'b0);
      end
      $display("--- ops 0, 5, 13-15, long rows, both rules");
      ac_set_mode(4);
      for (ac_j = 0; (ac_j < 20) && (error == 0); ac_j = ac_j + 1)
         ac_case(ac_rnd(2), ac_rnd(2), ac_rnd(4), AC_WMAX, 3, 3'b000, 3'b000, ac_j[0] ? GPU_COPYT : GPU_COPY,
                 (ac_j % 5 == 0) ? 4'd0 : (ac_j % 5 == 1) ? 4'd5 : (4'd11 + ac_j % 5), 1, 1'b0, ac_j[1], ac_j[2],
                 ac_j[3] ? 8'd255 : 8'd200);
      if (GPU_XY_EN != 0) begin
         $display("--- x/y destinations trimmed by the clip window");
         for (ac_j = 0; (ac_j < 30) && (error == 0); ac_j = ac_j + 1) ac_rand(1'b1);
      end
      $display("       %0d copies (%0d keyed, %0d mirrored, %0d with a CL swap, %0d x/y, %0d MIX5, %0d EN); %0d with A8 reads above the one-word count",
               ac_n, ac_nkey, ac_nmir, ac_ncl, ac_nxy, ac_nm5, ac_nen, ac_nlow);
      $display("       %0d A8 pixels written without a destination read, %0d skipped", gpu_a8_nnd, gpu_a8_nskip);
      if ((gpu_a8_nnd == 0) || (gpu_a8_nskip == 0)) tb_error("no A8 pixel without D read, or none skipped (test bug)");

      //--------------------------------------------------------------
      $display("--- palette modes: SRC_FMT 5 acts as 0, the A8 plane is not read");
      for (ac_i = 0; (ac_i < 4) && (error == 0); ac_i = ac_i + 1) begin
         ac_set_mode(ac_i);
         ac_ard0 = gpu_a8_nrd;
         gpu_c_size(14'd20, 14'd3);
         gpu_k_a8 = 1'b1;
         gpu_c_src(AC_P, (AC_SLO << (5 - ac_i)) + AC_P + ac_rnd(16));
         gpu_c_alpha_plane(AC_ALO * 4 + ac_rnd(64));
         gpu_c_alpha5(1'b1, 8'd100, ac_rnd(2));
         gpu_c_dst(AC_P, (AC_DLO << (5 - ac_i)) + AC_P + ac_rnd(16));
         ac_run(ac_rnd(2) ? GPU_COPY : GPU_COPYT, ac_rnd(16), 3'b000, 3'b000, 1'b0, "palette mode, SRC_FMT 5");
         gpu_k_a8 = 1'b0;
         if ((ac_ard != 0) || (gpu_a8_nrd != ac_ard0)) tb_error("A8 plane read in a palette mode");
      end
      gpu_set_mode(4);
      gpu_c_alpha(1'b0, 8'd0);
      gpu_c_src_fmt(16'd0, 32'h0, 4'h0);
      gpu_check_all("gpu_a8_copy end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
