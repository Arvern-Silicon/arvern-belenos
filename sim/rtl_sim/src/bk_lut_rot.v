//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_lut_rot
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_lut_rot.v
// Module Description : Palette rotation (LUT_ROT, 0x054: [7:0] FIRST,
//                      [15:8] LAST, [23:16] OFFSET, [31:24] read 0), checked
//                      on the BDI pixel stream (DIF_TYPE = 0, random
//                      back-pressure). With SW_LUT_EN = 1 at 1..8 bpp, a value
//                      v with FIRST <= v <= LAST selects entry
//                        s = v + OFFSET, e = (s > LAST) ? s - (LAST-FIRST+1) : s
//                      (e mod 256) of bank REFR_BANK; other values, FIRST >
//                      LAST, SW_LUT_EN = 0 and 16 bpp are unaffected:
//                        - reset value 0 (identity), register read-back;
//                        - 8 bpp ramp of all 256 values: mid range, OFFSET 0,
//                          full range, FIRST = LAST, FIRST > LAST, OFFSET >=
//                          length, the 8-bit wrap case, random settings;
//                        - bank 1 (bank 0 with LUT_BANKS = 1);
//                        - 1/2/4 bpp, ranges inside and beyond the depth;
//                        - 16 bpp and the hardware tables unaffected;
//                        - per-frame latch: a write during a frame applies
//                          from the next frame (alone and together with a
//                          LUT_CFG bank flip), a write before the rise of
//                          refresh_active applies to that frame; edge
//                          sweep (active raised 0..12 cycles after the
//                          write): each frame entirely old or new setting;
//                        - LUT window (0x800 / 0xC00) accesses not rotated.
//                      LUT_EN = 0: LUT_ROT reads 0, ignores writes, frames
//                      use the hardware tables. Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    lr_i, lr_m, lr_b, lr_k, lr_nf;
integer    le_o, le_a0, le_wc;
reg        le_ma, le_mb;
reg [31:0] lr_v;
reg [31:0] lr_rot;
reg [31:0] lr_rot_b;
reg [31:0] lr_rd;
reg [23:0] lr_sv5, lr_sv;
reg [64*8-1:0] lr_tag;

//----------------------------------------------------------------------------
// Reference model of the rotation
//----------------------------------------------------------------------------

// Entry index of a pixel value v under rotation rot ({OFFSET, LAST, FIRST})
function [7:0] lr_idx;
   input  [7:0] v;
   input [23:0] rot;
   integer      ff, ll, oo, ss, ee;
   begin
      ff = rot[7:0];
      ll = rot[15:8];
      oo = rot[23:16];
      if ((ff <= ll) && (v >= ff) && (v <= ll)) begin
         ss = v + oo;
         ee = (ss > ll) ? (ss - (ll - ff + 1)) : ss;
         lr_idx = ee % 256;
      end else
         lr_idx = v;
   end
endfunction

// Colour of one unpacked pixel value with rotation
function [23:0] lr_color;
   input  [2:0] mode;
   input [15:0] val;
   input [31:0] lutcfg;
   input [31:0] rot;
   reg          bank;
   begin
      bank = (LUT_BANKS == 2) ? lutcfg[1] : 1'b0;
      if ((LUT_EN != 0) && lutcfg[0] && (bkr_bpp_log2(mode) != 4))
         lr_color = lut_mem[{bank, lr_idx(val[7:0], rot[23:0])}];
      else
         lr_color = bkr_color(mode, val, lutcfg);
   end
endfunction

// Expected stream of one frame (bkr_build scan order, rotated colours)
task lr_build;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input  [31:0] lutcfg;
   input  [31:0] rot;
   integer       ll, ii, xx, yy, pa, nl, ni, wa, pwa;
   begin
      bkr_n    = 0;
      bkr_runs = 0;
      pwa      = -1;
      nl = cfg[0] ? w : h;
      ni = cfg[0] ? h : w;
      for (ll = 0; ll < nl; ll = ll + 1)
        for (ii = 0; ii < ni; ii = ii + 1) begin
           if (cfg[0]) begin
              yy = cfg[1] ? (h - 1 - ii) : ii;
              xx = cfg[2] ? (w - 1 - ll) : ll;
           end else begin
              yy = cfg[1] ? (h - 1 - ll) : ll;
              xx = cfg[2] ? (w - 1 - ii) : ii;
           end
           pa = (base + yy * w + xx) & ((1 << BKR_PA_W) - 1);
           wa = pa >> (5 - bkr_bpp_log2(mode));
           if (wa != pwa) bkr_runs = bkr_runs + 1;
           pwa = wa;
           if (bkr_n < BKR_MAX)
             bkr_exp[bkr_n] = lr_color(mode, bkr_pix(mode, pa), lutcfg, rot);
           bkr_n = bkr_n + 1;
        end
   end
endtask

// Write LUT_ROT and check its read-back
task lr_set_rot;
   input [31:0] rot;
   begin
      reg_wr(LUT_ROT, rot);
      reg_rd(LUT_ROT, (LUT_EN != 0) ? {8'h00, rot[23:0]} : 32'h0);
   end
endtask

// Compare the last frame with the model and the VRAM read count
task lr_check;
   input [64*8-1:0] tag;
   begin
      bkr_check_bdi(tag);
      if (bk_chk_reads && (bkm_vreads != bkr_runs)) begin
         $display("ERROR: %0s -- %0d VRAM reads during the frame / expected %0d %t",
                  tag, bkm_vreads, bkr_runs, $time);
         error = error + 1;
      end
   end
endtask

// One complete frame with rotation rot: configure, refresh, compare
task lr_frame;
   input [64*8-1:0] tag;
   input integer    base;
   input      [2:0] mode;
   input integer    w;
   input integer    h;
   input      [2:0] cfg;
   input     [31:0] lutcfg;
   input     [31:0] rot;
   begin
      bk_config(0, base, mode, w, h, cfg, lutcfg);
      lr_set_rot(rot);
      bk_refresh(w*h);
      lr_build(base, mode, w, h, cfg, lutcfg, rot);
      lr_check(tag);
   end
endtask

// 8 bpp ramp of all 256 values (VRAM words 0..63), bank b
task lr_ramp;
   input [64*8-1:0] tag;
   input            bank;
   input     [31:0] rot;
   begin
      $sformat(lr_tag, "%0s: 8bpp b%0d F%0d L%0d O%0d",
               tag, bank, rot[7:0], rot[15:8], rot[23:16]);
      lr_frame(lr_tag, 0, 3'd3, 32, 8, 3'b000, {16'h0000, 14'h0, bank, 1'b1}, rot);
   end
endtask

// Rotation setting {OFFSET, LAST, FIRST}
function [31:0] lr_mk;
   input [31:0] first;
   input [31:0] last;
   input [31:0] offset;
   begin
      lr_mk = {8'h00, offset[7:0], last[7:0], first[7:0]};
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: PALETTE ROTATION (LUT_ROT)    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 1;
      bk_lut_rand;

      // VRAM: words 0..63 = 8 bpp ramp 0..255, words 64..255 random
      for (lr_i = 0; lr_i < 64; lr_i = lr_i + 1)
         vram_mem[lr_i] = ((4*lr_i+3) << 24) | ((4*lr_i+2) << 16) | ((4*lr_i+1) << 8) | (4*lr_i);
      bk_vram_rand(64, 192);

      //------------------------------------------------------------------
      // Reset value and identity
      //------------------------------------------------------------------
      reg_rd(LUT_ROT, 32'h0000_0000);
      bk_config(0, 0, 3'd3, 32, 8, 3'b000, 32'h0000_F001);
      bk_refresh(256);
      lr_build(0, 3'd3, 32, 8, 3'b000, 32'h0000_F001, 32'h0);
      lr_check("reset LUT_ROT = 0: identity, 8 bpp bank 0");

      //------------------------------------------------------------------
      // Register read-back
      //------------------------------------------------------------------
      lr_set_rot(32'hFFFF_FFFF);
      lr_set_rot(32'hA5C3_7E81);
      for (lr_i = 0; lr_i < 4; lr_i = lr_i + 1)
         lr_set_rot($random(bkm_seed));
      lr_set_rot(32'h0000_0000);

      //------------------------------------------------------------------
      // 8 bpp, every value, directed settings (bank 0 then bank 1)
      //------------------------------------------------------------------
      for (lr_b = 0; lr_b < 2; lr_b = lr_b + 1) begin
         lr_ramp("mid range, offset 3",    lr_b, lr_mk( 16,  40,   3));
         lr_ramp("mid range, offset 1",    lr_b, lr_mk( 16,  40,   1));
         lr_ramp("mid range, offset 0",    lr_b, lr_mk( 16,  40,   0));
         lr_ramp("full range, offset 1",   lr_b, lr_mk(  0, 255,   1));
         lr_ramp("full range, offset 200", lr_b, lr_mk(  0, 255, 200));
         lr_ramp("full range, offset 255", lr_b, lr_mk(  0, 255, 255));
         lr_ramp("FIRST = LAST",           lr_b, lr_mk( 77,  77,   5));
         lr_ramp("FIRST > LAST",           lr_b, lr_mk(100,  50,   7));
         lr_ramp("FIRST > LAST, adjacent", lr_b, lr_mk(  9,   8,   1));
         lr_ramp("offset = length",        lr_b, lr_mk( 10,  20,  11));
         lr_ramp("offset > length",        lr_b, lr_mk( 10,  20,  30));
         lr_ramp("offset >> length",       lr_b, lr_mk(  3,   6, 250));
         lr_ramp("8-bit wrap",             lr_b, lr_mk(200, 255, 255));
         lr_ramp("top range",              lr_b, lr_mk(250, 255,   2));
         lr_ramp("bottom range",           lr_b, lr_mk(  0,   0, 100));
      end
      for (lr_i = 0; lr_i < 6; lr_i = lr_i + 1) begin
         lr_v = $random(bkm_seed);
         lr_ramp("random", lr_v[24], {8'h00, lr_v[23:0]});
      end
      // ordered random setting (FIRST <= LAST guaranteed)
      for (lr_i = 0; lr_i < 4; lr_i = lr_i + 1) begin
         lr_v = $random(bkm_seed);
         lr_rot = (lr_v[7:0] <= lr_v[15:8]) ? {8'h00, lr_v[23:0]} : {8'h00, lr_v[23:16], lr_v[7:0], lr_v[15:8]};
         lr_ramp("random ordered", lr_v[24], lr_rot);
      end

      // 8 bpp random content, swapped scan, rotation active
      lr_frame("8 bpp random content, CL/X swap, rotation", 64*4, 3'd3, 16, 16, 3'b101,
               32'h0000_0001, lr_mk(32, 191, 47));

      //------------------------------------------------------------------
      // 1/2/4 bpp (pixel values limited by the depth), both banks
      //------------------------------------------------------------------
      for (lr_b = 0; lr_b < 2; lr_b = lr_b + 1)
         for (lr_m = 0; lr_m < 3; lr_m = lr_m + 1)
            for (lr_k = 0; lr_k < 6; lr_k = lr_k + 1) begin
               case (lr_k)
                 0 : lr_rot = lr_mk(0, (1 << (1 << lr_m)) - 1, 1);                // full depth, +1
                 1 : lr_rot = lr_mk(1, (1 << (1 << lr_m)) - 1, (1 << (1 << lr_m)) - 2); // upper part
                 2 : lr_rot = lr_mk(0, (1 << (1 << lr_m)) - 1, 20);               // offset >> length
                 3 : lr_rot = lr_mk(1, 200, 100);                                 // range beyond depth
                 4 : lr_rot = lr_mk(0, 0, 37);                                    // single value 0
                 default : begin
                    lr_v   = $random(bkm_seed);
                    lr_rot = lr_mk(lr_v[7:0] % (1 << (1 << lr_m)), lr_v[15:8] % (1 << (1 << lr_m)), lr_v[23:16]);
                 end
               endcase
               $sformat(lr_tag, "%0d bpp bank %0d FIRST %0d LAST %0d OFFSET %0d",
                        1 << lr_m, lr_b, lr_rot[7:0], lr_rot[15:8], lr_rot[23:16]);
               lr_frame(lr_tag, 64 << (5 - lr_m), lr_m, 32, 4, 3'b000,
                        32'h0000_A561 | (lr_b << 1), lr_rot);
            end
      // 4 bpp ramp 0..15 (twice), mid range rotation
      vram_mem[256] = 32'h7654_3210;
      vram_mem[257] = 32'hFEDC_BA98;
      vram_mem[258] = 32'h7654_3210;
      vram_mem[259] = 32'hFEDC_BA98;
      lr_frame("4 bpp ramp FIRST 4 LAST 11 OFFSET 3", 256 << 3, 3'd2, 32, 1, 3'b000,
               32'h0000_0001, lr_mk(4, 11, 3));

      //------------------------------------------------------------------
      // Unaffected: 16 bpp with SW_LUT_EN, hardware tables
      //------------------------------------------------------------------
      for (lr_m = 4; lr_m < 8; lr_m = lr_m + 1) begin
         $sformat(lr_tag, "16 bpp mode %0d, SW_LUT_EN, rotation set", lr_m);
         lr_frame(lr_tag, 64*2, lr_m, 8, 8, 3'b000, 32'h0000_0003, lr_mk(0, 255, 1));
      end
      for (lr_m = 0; lr_m < 4; lr_m = lr_m + 1) begin
         $sformat(lr_tag, "%0d bpp HW tables (SW_LUT_EN 0), rotation set", 1 << lr_m);
         lr_frame(lr_tag, 64 << (5 - lr_m), lr_m, 32, 4, 3'b000, 32'h0000_C320, lr_mk(0, 255, 1));
      end
      lr_ramp("back to SW LUT", 1'b0, lr_mk(0, 255, 1));

      //------------------------------------------------------------------
      // Per-frame latch
      //------------------------------------------------------------------
      for (lr_k = 0; lr_k < 2; lr_k = lr_k + 1) begin
         // A: bank 0, full range +1; B: identity (lr_k = 0) or full range
         // +100 with a REFR_BANK flip written together (lr_k = 1)
         lr_rot   = lr_mk(0, 255, 1);
         lr_rot_b = (lr_k == 0) ? 32'h0 : lr_mk(0, 255, 100);
         bk_config(0, 0, 3'd3, 32, 8, 3'b000, 32'h0000_0001);
         lr_set_rot(lr_rot);
         lr_nf     = bkm_frames;
         bkm_exp_n = 256;
         reg_wr(REFRESH, 32'h0000_0001);
         bkm_wait_pixels(5, 2000);
         bkm_hold = 1'b1;
         repeat(20) @(posedge free_clk);
         reg_wr(LUT_ROT, lr_rot_b);
         if (lr_k == 1) reg_wr(LUT_CFG, 32'h0000_0003);
         repeat(5) @(posedge free_clk);
         if (bkm_frames != lr_nf) tb_error("LUT_ROT latch: frame ended while held");
         bkm_hold = 1'b0;
         bkm_wait_frames(lr_nf + 1, 20000);
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
         lr_build(0, 3'd3, 32, 8, 3'b000, 32'h0000_0001, lr_rot);
         $sformat(lr_tag, "latch %0d: in-flight frame keeps the old LUT_ROT", lr_k);
         lr_check(lr_tag);
         bk_refresh(256);
         lr_build(0, 3'd3, 32, 8, 3'b000, (lr_k == 0) ? 32'h0000_0001 : 32'h0000_0003, lr_rot_b);
         $sformat(lr_tag, "latch %0d: next frame uses the new LUT_ROT", lr_k);
         lr_check(lr_tag);
      end
      // Written between the trigger and the rise of refresh_active
      lr_set_rot(lr_mk(0, 255, 1));
      lr_nf           = bkm_frames;
      bkm_start_delay = 400;
      bkm_exp_n       = 256;
      reg_wr(REFRESH, 32'h0000_0001);
      reg_wr(LUT_ROT, lr_mk(64, 191, 64));
      if ((bdi_refresh_active_drv !== 1'b0) || (bkm_frames != lr_nf))
         tb_error("LUT_ROT latch: active rose before the write (test timing)");
      bkm_wait_frames(lr_nf + 1, 20000);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      bkm_start_delay = 2;
      lr_build(0, 3'd3, 32, 8, 3'b000, 32'h0000_0003, lr_mk(64, 191, 64));
      lr_check("latch: written before the rise of active -> new LUT_ROT");

      // Edge sweep: LUT_ROT A -> B written while the BDI model raises active
      // on its own 0..12 cycles later; every frame is entirely A or B
      bkm_auto_trig = 1'b0;
      bkm_exp_n     = 0;
      for (le_o = 0; le_o < 13; le_o = le_o + 1) begin
         bk_config(0, 0, 3'd3, 32, 2, 3'b000, 32'h0000_0001);
         lr_set_rot(lr_mk(0, 63, 1));
         lr_nf           = bkm_frames;
         le_a0           = bkm_cycle;
         bkm_start_delay = le_o;
         bkm_go_req      = 1'b1;
         reg_wr(LUT_ROT, lr_mk(0, 63, 5));
         le_wc = bkm_cycle;
         bkm_wait_frames(lr_nf + 1, 5000);
         lr_build(0, 3'd3, 32, 2, 3'b000, 32'h0000_0001, lr_mk(0, 63, 1));
         le_ma = bkr_match(1'b0);
         lr_build(0, 3'd3, 32, 2, 3'b000, 32'h0000_0001, lr_mk(0, 63, 5));
         le_mb = bkr_match(1'b0);
         if (!le_ma && !le_mb) begin
            $display("ERROR: LUT_ROT latch edge, rise %0d cycles after the write start: frame is neither A nor B (mixed) %t",
                     bkm_rise_cyc - le_a0, $time);
            error = error + 1;
         end else if (le_ma && !le_mb && (bkm_rise_cyc >= le_wc + 2)) begin
            $display("ERROR: LUT_ROT latch edge: active rose %0d cycles after the write completed, frame still A %t",
                     bkm_rise_cyc - le_wc, $time);
            error = error + 1;
         end else if (le_mb && !le_ma && (bkm_rise_cyc <= le_a0 + 1)) begin
            $display("ERROR: LUT_ROT latch edge: active rose before the write, frame is B %t", $time);
            error = error + 1;
         end else
            $display("OK:    LUT_ROT latch edge, rise at write-start %0d / write-end %0d cycles: frame %s",
                     bkm_rise_cyc - le_a0, bkm_rise_cyc - le_wc, le_mb ? "B" : "A");
      end
      bkm_auto_trig   = 1'b1;
      bkm_start_delay = 2;

      //------------------------------------------------------------------
      // LUT window accesses are not rotated
      //------------------------------------------------------------------
      if (LUT_EN != 0) begin
         lr_set_rot(lr_mk(0, 255, 3));
         for (lr_i = 0; lr_i < 16; lr_i = lr_i + 1) begin
            reg_rd(LUT_BASE + 4*lr_i, {8'h00, lut_mem[lr_i]});
            reg_rd(LUT_BASE + 32'h400 + 4*lr_i, (LUT_BANKS == 2) ? {8'h00, lut_mem[256 + lr_i]} : 32'h0);
         end
         lr_sv5 = lut_mem[5];
         lr_sv  = lut_mem[8];
         lr_v   = $random(bkm_seed);
         reg_wr(LUT_BASE + 4*5, lr_v);
         repeat(3) @(posedge free_clk);
         if (lut_mem[5] !== lr_v[23:0])
            tb_error("LUT window write with LUT_ROT set did not land at its own index");
         if (lut_mem[8] !== lr_sv)
            tb_error("LUT window write with LUT_ROT set modified the rotated index");
         reg_rd(LUT_BASE + 4*5, {8'h00, lr_v[23:0]});
         if (lr_v[23:0] == lr_sv5)
            $display("NOTE:  LUT window write value equals the old entry (weak check)");
         // the rewritten entry is reached by value 2 through the rotation
         lr_ramp("after window write", 1'b0, lr_mk(0, 255, 3));
      end

      // Back to identity
      lr_set_rot(32'h0);
      lr_ramp("identity restored", 1'b1, 32'h0);

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
