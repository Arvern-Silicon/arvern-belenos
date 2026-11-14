//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    bk_ref
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_ref.v
// Module Description : Reference model of the Belenos display backend
//                      (`included by the bk_ tests into tb_belenos), written
//                      from the specification only:
//                        - scan order: (start corner, inner walk of
//                          W pixels, or H with CL_SWAP);
//                        - unpack: the pixel-format rules (LSB-first,
//                          bpp from GFX_MODE, modes 5-7 = 16 bpp);
//                        - colour: HW tables taken as
//                          their RGB565 values and expanded with the documented
//                          RGB565 -> RGB888 rule; LUT index {bank, value
//                          zero-extended to 8 bits}, RGB888 entry verbatim;
//                        - pixel doubling (bkr_dbl): pixel k of panel scan
//                          line j = pixel k/2 of source scan line j/2;
//                        - the hardware cursor (bkr_cur_*): shape pixel
//                          (i, j) over source-frame pixel (X - HOT_X + i,
//                          Y - HOT_Y + j), read from the row copy, or the
//                          column copy (+64) with CL swap; its colour
//                          replaces the pixel's; 2 VRAM reads per panel scan
//                          line that crosses the cursor (bkr_runs).
//                      bkr_build() fills bkr_exp[0..bkr_n-1] (RGB888) from the
//                      bench VRAM / LUT models; bkr_check_bdi() compares it with
//                      the BDI model log, bkr_check_565() with a panel log.
//----------------------------------------------------------------------------

localparam integer BKR_MAX = 65536;
localparam integer BKR_PA_W = VRAM_AW + 5;

reg       [23:0] bkr_exp [0:BKR_MAX-1];
integer          bkr_n;
integer          bkr_runs;      // word-address changes along the scan (VRAM reads needed)
integer          bkr_cur_n = 0; // pixels the cursor covers (code 1-3)
reg              bk_chk_reads;  // bk_frame also checks bkm_vreads == bkr_runs
initial bk_chk_reads = 1'b0;

// RGB565 -> RGB888
function [23:0] bkr_565to888;
   input [15:0] c;
   begin
      bkr_565to888 = {c[15:11], c[15:13], c[10:5], c[10:9], c[4:0], c[4:2]};
   end
endfunction

// RGB888 -> RGB565 truncation (DBI driver)
function [15:0] bkr_888to565;
   input [23:0] c;
   begin
      bkr_888to565 = {c[23:19], c[15:10], c[7:3]};
   end
endfunction

// CGA 16-colour table, RGB565
function [15:0] bkr_cga565;
   input [3:0] idx;
   begin
      case (idx)
        4'd0  : bkr_cga565 = 16'h0000;   // black
        4'd1  : bkr_cga565 = 16'h0015;   // blue
        4'd2  : bkr_cga565 = 16'h0560;   // green
        4'd3  : bkr_cga565 = 16'h0575;   // cyan
        4'd4  : bkr_cga565 = 16'hA800;   // red
        4'd5  : bkr_cga565 = 16'hA815;   // magenta
        4'd6  : bkr_cga565 = 16'hAAA0;   // brown
        4'd7  : bkr_cga565 = 16'hAD75;   // light grey
        4'd8  : bkr_cga565 = 16'h5AAB;   // grey
        4'd9  : bkr_cga565 = 16'h5ABF;   // light blue
        4'd10 : bkr_cga565 = 16'h5FEB;   // light green
        4'd11 : bkr_cga565 = 16'h5FFF;   // light cyan
        4'd12 : bkr_cga565 = 16'hFAAB;   // light red
        4'd13 : bkr_cga565 = 16'hFABF;   // light magenta
        4'd14 : bkr_cga565 = 16'hFFEB;   // yellow
        default: bkr_cga565 = 16'hFFFF;  // white
      endcase
   end
endfunction

// 2 bpp hardware palettes: CGA index of values 01/10/11
function [3:0] bkr_pal2_idx;
   input [2:0] pal;
   input [1:0] val;
   begin
      case (pal)
        3'd0    : bkr_pal2_idx = (val == 2'd1) ? 4'd10 : (val == 2'd2) ? 4'd12 : 4'd14;
        3'd1    : bkr_pal2_idx = (val == 2'd1) ? 4'd2  : (val == 2'd2) ? 4'd4  : 4'd6;
        3'd2    : bkr_pal2_idx = (val == 2'd1) ? 4'd11 : (val == 2'd2) ? 4'd13 : 4'd15;
        3'd3    : bkr_pal2_idx = (val == 2'd1) ? 4'd3  : (val == 2'd2) ? 4'd5  : 4'd7;
        3'd4    : bkr_pal2_idx = (val == 2'd1) ? 4'd11 : (val == 2'd2) ? 4'd12 : 4'd15;
        default : bkr_pal2_idx = (val == 2'd1) ? 4'd3  : (val == 2'd2) ? 4'd4  : 4'd7;
      endcase
   end
endfunction

// bpp_log2 of a GFX_MODE
function integer bkr_bpp_log2;
   input [2:0] mode;
   begin
      bkr_bpp_log2 = (mode >= 3'd4) ? 4 : mode;
   end
endfunction

// Colour of one unpacked pixel value
function [23:0] bkr_color;
   input  [2:0] mode;
   input [15:0] val;
   input [31:0] lutcfg;
   reg          sw;
   reg          bank;
   integer      bl;
   begin
      bl   = bkr_bpp_log2(mode);
      sw   = (LUT_EN != 0) && lutcfg[0];
      bank = (LUT_BANKS == 2) ? lutcfg[1] : 1'b0;
      if (bl == 4)
        bkr_color = bkr_565to888(val);
      else if (sw)
        bkr_color = lut_mem[{bank, val[7:0]}];
      else if (bl == 3)          // RGB332 -> RGB565, top bits repeated (R 001 -> 00100)
        bkr_color = bkr_565to888({val[7], val[6], val[5], val[7], val[6],
                                  val[4], val[3], val[2], val[4], val[3], val[2],
                                  val[1], val[0], val[1], val[0], val[1]});
      else if (bl == 2)
        bkr_color = bkr_565to888(bkr_cga565(val[3:0]));
      else if (bl == 1)
        bkr_color = bkr_565to888(bkr_cga565((val[1:0] == 2'd0) ? lutcfg[11:8] : bkr_pal2_idx(lutcfg[6:4], val[1:0])));
      else
        bkr_color = bkr_565to888(bkr_cga565(val[0] ? lutcfg[15:12] : lutcfg[11:8]));
   end
endfunction

// Pixel value at pixel address pa
function [15:0] bkr_pix;
   input [2:0] mode;
   input integer pa;
   integer      bl;
   integer      wa;
   integer      bo;
   reg   [31:0] word;
   reg   [31:0] sh;
   begin
      bl   = bkr_bpp_log2(mode);
      wa   = pa >> (5 - bl);
      bo   = (pa & ((32 >> bl) - 1)) << bl;
      word = vram_mem[wa];
      sh   = (word >> bo) & ((1 << (1 << bl)) - 1);
      bkr_pix = sh[15:0];
   end
endfunction

// Expected stream of one frame (w, h = the DISP_SIZE values as stored, >= 1)
// Line pitch of the refresh (REFR_PITCH); 0 = the source frame width
integer bkr_pitch = 0;
// DISP_CFG.PIX_DOUBLE of the frame
reg     bkr_dbl   = 1'b0;

// Hardware cursor as the next frame latches it (bk_cursor_set), colours live
reg          bkr_cur_en  = 1'b0;
integer      bkr_cur_x   = 0;           // CURSOR_POS, signed
integer      bkr_cur_y   = 0;
integer      bkr_cur_hx  = 0;           // CURSOR_CTRL HOT_X / HOT_Y
integer      bkr_cur_hy  = 0;
integer      bkr_cur_blk = 0;           // CURSOR_ADDR: word address of the block
reg   [23:0] bkr_cur_col1 = 24'h0;
reg   [23:0] bkr_cur_col2 = 24'h0;
reg   [23:0] bkr_cur_col3 = 24'h0;

// Cursor code over source-frame pixel (x, y): 0 = none
function [1:0] bkr_cur_code;
   input integer x;
   input integer y;
   input         cl;
   integer       i, j;
   reg    [31:0] wd;
   begin
      i = x - (bkr_cur_x - bkr_cur_hx);
      j = y - (bkr_cur_y - bkr_cur_hy);
      if ((CURSOR_EN == 0) || !bkr_cur_en || (i < 0) || (i > 31) || (j < 0) || (j > 31))
        bkr_cur_code = 2'd0;
      else begin
         if (cl) wd = vram_mem[bkr_cur_blk + 64 + 2*i + j/16];   // column i, pixel j
         else    wd = vram_mem[bkr_cur_blk + 2*j + i/16];        // row j, pixel i
         bkr_cur_code = wd >> (cl ? 2*(j % 16) : 2*(i % 16));
      end
   end
endfunction

// The pixel's colour with the cursor over it
function [23:0] bkr_cur_over;
   input  [23:0] rgb;
   input   [1:0] code;
   begin
      bkr_cur_over = (code == 2'd1) ? bkr_cur_col1 : (code == 2'd2) ? bkr_cur_col2 :
                     (code == 2'd3) ? bkr_cur_col3 : rgb;
   end
endfunction

// The cursor box meets the sw x sh source frame
function bkr_cur_vis;
   input integer sw;
   input integer sh;
   integer       tx, ty;
   begin
      tx = bkr_cur_x - bkr_cur_hx;
      ty = bkr_cur_y - bkr_cur_hy;
      bkr_cur_vis = (CURSOR_EN != 0) && bkr_cur_en && (tx + 31 >= 0) && (tx < sw) && (ty + 31 >= 0) && (ty < sh);
   end
endfunction

task bkr_build;
   input integer base;      // frame pixel address
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;       // [0] CL, [1] Y, [2] X
   input  [31:0] lutcfg;
   integer       ll, ii, sl, si, xx, yy, pa, nl, ni, wa, pwa, sw, sh, cx, cy;
   reg           vis, cur_ln;
   begin
      bkr_n    = 0;
      bkr_runs = 0;
      bkr_cur_n = 0;
      pwa      = -1;
      sw = bkr_dbl ? ((w + 1) / 2) : w;
      sh = bkr_dbl ? ((h + 1) / 2) : h;
      nl = cfg[0] ? w : h;
      ni = cfg[0] ? h : w;
      vis = bkr_cur_vis(sw, sh);
      for (ll = 0; ll < nl; ll = ll + 1) begin
        sl = bkr_dbl ? (ll / 2) : ll;
        // a panel scan line that crosses the cursor: its two words are read
        cx = (cfg[2] ? (sw - 1 - sl) : sl) - (bkr_cur_x - bkr_cur_hx);
        cy = (cfg[1] ? (sh - 1 - sl) : sl) - (bkr_cur_y - bkr_cur_hy);
        cur_ln = vis && (cfg[0] ? ((cx >= 0) && (cx <= 31)) : ((cy >= 0) && (cy <= 31)));
        if (cur_ln) bkr_runs = bkr_runs + 2;
        for (ii = 0; ii < ni; ii = ii + 1) begin
           si = bkr_dbl ? (ii / 2) : ii;
           if (cfg[0]) begin
              yy = cfg[1] ? (sh - 1 - si) : si;
              xx = cfg[2] ? (sw - 1 - sl) : sl;
           end else begin
              yy = cfg[1] ? (sh - 1 - sl) : sl;
              xx = cfg[2] ? (sw - 1 - si) : si;
           end
           pa = (base + yy * ((bkr_pitch != 0) ? bkr_pitch : sw) + xx) & ((1 << BKR_PA_W) - 1);
           wa = pa >> (5 - bkr_bpp_log2(mode));
           if (wa != pwa) bkr_runs = bkr_runs + 1;
           pwa = wa;
           if (bkr_cur_code(xx, yy, cfg[0]) != 2'd0) bkr_cur_n = bkr_cur_n + 1;
           if (bkr_n < BKR_MAX)
             bkr_exp[bkr_n] = bkr_cur_over(bkr_color(mode, bkr_pix(mode, pa), lutcfg), bkr_cur_code(xx, yy, cfg[0]));
           bkr_n = bkr_n + 1;
        end
      end
   end
endtask

// Compare the BDI model log of the last frame with bkr_exp
task bkr_check_bdi;
   input [64*8-1:0] tag;
   integer          ii, nerr;
   begin
      nerr = 0;
      tb_checks = tb_checks + 1;
      if (bkm_n != bkr_n) begin
         $display("ERROR: %0s -- %0d pixels received / expected %0d %t", tag, bkm_n, bkr_n, $time);
         error = error + 1;
      end
      for (ii = 0; (ii < bkr_n) && (ii < bkm_n) && (ii < BKR_MAX); ii = ii + 1)
        if (bkm_px[ii] !== bkr_exp[ii]) begin
           nerr = nerr + 1;
           if (nerr <= 8)
             $display("ERROR: %0s -- pixel %0d = 0x%h / expected 0x%h %t", tag, ii, bkm_px[ii], bkr_exp[ii], $time);
        end
      if (bkr_n > 0 && bkm_n == bkr_n && bkm_lst[bkr_n-1] !== 1'b1) begin
         $display("ERROR: %0s -- px_last not set on the final pixel %t", tag, $time);
         error = error + 1;
      end
      error = error + nerr;
      if ((nerr == 0) && (bkm_n == bkr_n) && (bkr_cur_n != 0))
        $display("OK:    %0s -- %0d pixels, %0d under the cursor", tag, bkr_n, bkr_cur_n);
      else if ((nerr == 0) && (bkm_n == bkr_n))
        $display("OK:    %0s -- %0d pixels", tag, bkr_n);
      else if (nerr > 0)
        $display("ERROR: %0s -- %0d pixel mismatches %t", tag, nerr, $time);
   end
endtask

// Program the backend registers for one frame (refresh frame fsel)
task bk_config;
   input integer fsel;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input  [31:0] lutcfg;
   begin
      reg_wr(FRAME0_PTR + 4*fsel, base);
      reg_wr(FRAME_SEL,  fsel);
      reg_wr(CTRL,       {29'h0, mode});
      reg_wr(DISP_SIZE,  (h << 16) | w);
      reg_wr(DISP_CFG,   {27'h0, bkr_dbl, 1'b0, cfg});
      reg_wr(LUT_CFG,    lutcfg);
      if ((bdi_width !== w[DIM_W-1:0]) || (bdi_height !== h[DIM_W-1:0])) begin
         $display("ERROR: bdi_width_o/bdi_height_o = %0d/%0d after DISP_SIZE %0dx%0d %t", bdi_width, bdi_height, w, h, $time);
         error = error + 1;
      end
   end
endtask

// Manual refresh (REFRESH.START, PERIOD 0), wait for the BDI model to frame
// it, check START self-clears
task bk_refresh;
   input integer exp_n;
   integer       nf;
   begin
      bkm_exp_n = exp_n;
      nf        = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bkm_wait_frames(nf + 1, 2000 + 60*exp_n);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
   end
endtask

// One complete frame: configure, refresh, build the reference, compare
task bk_frame;
   input [64*8-1:0] tag;
   input integer    fsel;
   input integer    base;
   input      [2:0] mode;
   input integer    w;
   input integer    h;
   input      [2:0] cfg;
   input     [31:0] lutcfg;
   begin
      bk_config(fsel, base, mode, w, h, cfg, lutcfg);
      bk_refresh(w*h);
      bkr_build(base, mode, w, h, cfg, lutcfg);
      bkr_check_bdi(tag);
      if (bk_chk_reads && (bkm_vreads != bkr_runs)) begin
         $display("ERROR: %0s -- %0d VRAM reads during the frame / expected %0d (one per word-address change) %t",
                  tag, bkm_vreads, bkr_runs, $time);
         error = error + 1;
      end
   end
endtask

// Backdoor fill of VRAM words [first, first+nr) with random data
task bk_vram_rand;
   input integer first;
   input integer nr;
   integer       ii;
   begin
      for (ii = first; ii < first + nr; ii = ii + 1)
        vram_mem[ii] = $random(bkm_seed);
   end
endtask

// Backdoor fill of the whole LUT model with random RGB888 entries
task bk_lut_rand;
   integer       ii;
   reg    [31:0] rr;
   begin
      for (ii = 0; ii < 512; ii = ii + 1) begin
        rr          = $random(bkm_seed);
        lut_mem[ii] = rr[23:0];
      end
   end
endtask

// 1 when the BDI model log of the last frame equals bkr_exp (no report)
function bkr_match;
   input dummy;
   integer ii;
   begin
      bkr_match = (bkm_n == bkr_n);
      for (ii = 0; (ii < bkr_n) && (ii < BKR_MAX) && bkr_match; ii = ii + 1)
        if (bkm_px[ii] !== bkr_exp[ii]) bkr_match = 1'b0;
   end
endfunction

// Cursor registers and their bench copy (the frame after the write latches
// them; the colours apply at once)
task bk_cursor_set;
   input         en;
   input integer x;
   input integer y;
   input integer hx;
   input integer hy;
   input integer blk;
   begin
      reg_wr(CURSOR_POS,  {y[15:0], x[15:0]});
      reg_wr(CURSOR_CTRL, {11'h0, hy[4:0], 3'h0, hx[4:0], 7'h0, en});
      reg_wr(CURSOR_ADDR, blk);
      bkr_cur_en  = en;
      bkr_cur_x   = $signed(x[15:0]);
      bkr_cur_y   = $signed(y[15:0]);
      bkr_cur_hx  = hx;
      bkr_cur_hy  = hy;
      bkr_cur_blk = blk;
   end
endtask

task bk_cursor_cols;
   input [23:0] c1;
   input [23:0] c2;
   input [23:0] c3;
   begin
      reg_wr(CURSOR_COL1, {8'h00, c1});
      reg_wr(CURSOR_COL2, {8'h00, c2});
      reg_wr(CURSOR_COL3, {8'h00, c3});
      bkr_cur_col1 = c1;
      bkr_cur_col2 = c2;
      bkr_cur_col3 = c3;
   end
endtask

// A random shape (each code with weight, about a third transparent) into the
// block at word blk by the backdoor: rows at +0, the transposed copy at +64
// (colmix != 0: the copy is a different shape, to tell which one is read)
task bk_cursor_shape;
   input integer blk;
   input integer colmix;
   integer       i, j;
   reg    [31:0] r;
   reg     [1:0] c;
   begin
      for (j = 0; j < 64; j = j + 1) vram_mem[blk + j] = 32'h0;
      for (j = 0; j < 32; j = j + 1)
        for (i = 0; i < 32; i = i + 1) begin
           r = $random(bkm_seed);
           c = (r[3:0] < 5) ? 2'd0 : r[5:4];
           vram_mem[blk + 2*j + i/16] = vram_mem[blk + 2*j + i/16] | ({30'h0, c} << (2*(i % 16)));
        end
      for (i = 0; i < 32; i = i + 1) begin
         vram_mem[blk + 64 + 2*i]     = 32'h0;
         vram_mem[blk + 64 + 2*i + 1] = 32'h0;
      end
      for (i = 0; i < 32; i = i + 1)
        for (j = 0; j < 32; j = j + 1) begin
           c = vram_mem[blk + 2*j + i/16] >> (2*(i % 16));
           if (colmix != 0) begin
              r = $random(bkm_seed);
              c = r[1:0];
           end
           vram_mem[blk + 64 + 2*i + j/16] = vram_mem[blk + 64 + 2*i + j/16] | ({30'h0, c} << (2*(j % 16)));
        end
   end
endtask
