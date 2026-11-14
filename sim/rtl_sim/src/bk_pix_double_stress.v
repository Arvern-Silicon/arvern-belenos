//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_pix_double_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_pix_double_stress.v
// Module Description : Pixel doubling (DISP_CFG[4] PIX_DOUBLE) under stress,
//                      on the BDI model stream (DIF_TYPE = 0). Reference:
//                      pixel k of panel scan line j = pixel k/2 of source
//                      scan line j/2, source ceil(W/2) x ceil(H/2) (pitch
//                      ceil(W/2)) walked with the DISP_CFG swaps.
//                        - doubled frames under VRAM contention: while the
//                          frame streams (random / always / bursty ready), a
//                          fork runs pipelined register-port rounds (GPU
//                          FILL + COPY at 16 bpp, LUT bank-1 window writes)
//                          and VRAM-window rounds (writes and
//                          read-backs elsewhere, identical rewrites and reads
//                          of the displayed words); every bpp, all 8 swaps,
//                          odd / even / unit sizes. Checked: the stream is
//                          exact, the window / GPU results are exact
//                          (whole-VRAM compare with the shadow);
//                        - PIX_DOUBLE with LUT_ROT and SW_LUT_EN at 8 / 4 /
//                          2 / 1 bpp, both banks, swaps: the rotation applies
//                          to the doubled pixels;
//                        - VRAM reads of uncontended doubled frames against
//                          the same picture sent undoubled (the W' x H'
//                          source frame): reads_dbl * W'H' <= reads_src * WH,
//                          numbers reported (no contract on the exact count);
//                        - aborts with doubling on (driver drops active after
//                          N pixels: inside a line, at a line end, inside the
//                          repeated line, between the two copies of a pixel,
//                          and with ready held low): the pixels sent are the
//                          exact prefix, the next doubled frame is exact.
//                      Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"
`include "vram_shadow.v"

localparam integer PS_WIN    = 12000;   // window traffic words
localparam integer PS_RAMP   = 2048;    // ramp words of the rotation part
localparam integer PS_GDST   = 8192;    // GPU fill base (pixel, 16 bpp: word 4096)
localparam integer PS_GCPY   = 16384;   // GPU copy destination (word 8192)
localparam integer PS_FILL_W = 64;
localparam integer PS_FILL_H = 50;
localparam  [15:0] PS_COLOR  = 16'h3C5A;
localparam  [15:0] PS_PITCH16 = PS_FILL_W;
localparam  [13:0] PS_W14     = PS_FILL_W;
localparam  [13:0] PS_H14     = PS_FILL_H;

integer    ps_i, ps_k, ps_m, ps_w, ps_h, ps_b, ps_n, ps_nf, ps_rr, ps_vr, ps_ract, ps_vact;
integer    ps_rd_d, ps_rn_d, ps_rd_s, ps_rn_s, ps_sw, ps_sh, ps_nerr;
reg        ps_gpu, ps_lutw;
reg  [2:0] ps_mode, ps_cfg;
reg [31:0] ps_lut, ps_rot, ps_v, ps_d;
reg [64*8-1:0] ps_tag;

//----------------------------------------------------------------------------
// Reference
//----------------------------------------------------------------------------
function ps_fits;
   input integer w;
   input integer h;
   begin
      ps_fits = (w < (1 << DIM_W)) && (h < (1 << DIM_W));
   end
endfunction

// LUT entry of value v under rotation rot ({OFFSET, LAST, FIRST})
function [7:0] ps_idx;
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
         ps_idx = ee % 256;
      end else
         ps_idx = v;
   end
endfunction

function [23:0] ps_color;
   input  [2:0] mode;
   input [15:0] val;
   input [31:0] lutcfg;
   input [31:0] rot;
   reg          bank;
   begin
      bank = (LUT_BANKS == 2) ? lutcfg[1] : 1'b0;
      if ((LUT_EN != 0) && lutcfg[0] && (bkr_bpp_log2(mode) != 4))
         ps_color = lut_mem[{bank, ps_idx(val[7:0], rot[23:0])}];
      else
         ps_color = bkr_color(mode, val, lutcfg);
   end
endfunction

// Expected stream into bkr_exp[0..bkr_n-1]; bkr_runs = word-address changes
// along the scan
task ps_build;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;       // [0] CL, [1] Y, [2] X
   input         dbl;
   input  [31:0] lutcfg;
   input  [31:0] rot;
   integer       sw, sh, nl, ni, ll, ii, sl, si, xx, yy, pa, wa, pwa;
   begin
      sw = dbl ? ((w + 1) / 2) : w;
      sh = dbl ? ((h + 1) / 2) : h;
      nl = cfg[0] ? w : h;
      ni = cfg[0] ? h : w;
      bkr_n    = 0;
      bkr_runs = 0;
      pwa      = -1;
      for (ll = 0; ll < nl; ll = ll + 1)
        for (ii = 0; ii < ni; ii = ii + 1) begin
           sl = dbl ? (ll / 2) : ll;
           si = dbl ? (ii / 2) : ii;
           if (cfg[0]) begin
              yy = cfg[1] ? (sh - 1 - si) : si;
              xx = cfg[2] ? (sw - 1 - sl) : sl;
           end else begin
              yy = cfg[1] ? (sh - 1 - sl) : sl;
              xx = cfg[2] ? (sw - 1 - si) : si;
           end
           pa = (base + yy * sw + xx) & ((1 << BKR_PA_W) - 1);
           wa = pa >> (5 - bkr_bpp_log2(mode));
           if (wa != pwa) bkr_runs = bkr_runs + 1;
           pwa = wa;
           if (bkr_n < BKR_MAX)
             bkr_exp[bkr_n] = ps_color(mode, bkr_pix(mode, pa), lutcfg, rot);
           bkr_n = bkr_n + 1;
        end
   end
endtask

// Program the refresh (frame 0) and the shadow state
task ps_config;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input         dbl;
   input  [31:0] lutcfg;
   input  [31:0] rot;
   input         gpu;
   begin
      vsh_frame(0, base);
      vsh_fsel(32'h0);
      reg_wr(CTRL, {27'h0, gpu, 1'b0, mode});
      vsh_mode = mode;
      vsh_disp(w, h);
      reg_wr(DISP_CFG, {27'h0, dbl, 1'b0, cfg});
      reg_wr(LUT_CFG,  lutcfg);
      reg_wr(LUT_ROT,  rot);
      if ((bdi_width !== w[DIM_W-1:0]) || (bdi_height !== h[DIM_W-1:0])) begin
         $display("ERROR: bdi_width_o/bdi_height_o = %0d/%0d after DISP_SIZE %0dx%0d (PIX_DOUBLE %0d) %t",
                  bdi_width, bdi_height, w, h, dbl, $time);
         error = error + 1;
      end
   end
endtask

// One uncontended frame: configure, refresh, compare; ps_rd_d / ps_rn_d =
// VRAM reads during the frame / word-address changes of the scan
task ps_frame;
   input [64*8-1:0] tag;
   input integer    base;
   input      [2:0] mode;
   input integer    w;
   input integer    h;
   input      [2:0] cfg;
   input            dbl;
   input     [31:0] lutcfg;
   input     [31:0] rot;
   begin
      if (!ps_fits(w, h))
         $display("NOTE:  %0s -- skipped (%0dx%0d does not fit DIM_W = %0d)", tag, w, h, DIM_W);
      else begin
         ps_config(base, mode, w, h, cfg, dbl, lutcfg, rot, 1'b0);
         bk_refresh(w * h);
         ps_rd_d = bkm_vreads;
         ps_build(base, mode, w, h, cfg, dbl, lutcfg, rot);
         ps_rn_d = bkr_runs;
         bkr_check_bdi(tag);
      end
   end
endtask

//----------------------------------------------------------------------------
// Contention traffic
//----------------------------------------------------------------------------
task ps_gpu_queue;
   begin
      vsh_q_reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, PS_PITCH16});
      vsh_q_reg_wr(GPU_CMD, PS_GDST);
      vsh_q_reg_wr(GPU_CMD, {OP_SET_SIZE, PS_H14, PS_W14});
      vsh_q_reg_wr(GPU_CMD, {OP_SET_FILL, 28'h000_0000});
      vsh_q_reg_wr(GPU_CMD, {16'h0000, PS_COLOR});
      vsh_q_reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h000_0000});
      vsh_q_reg_wr(GPU_CMD, {OP_SET_SRC, 12'h000, PS_PITCH16});
      vsh_q_reg_wr(GPU_CMD, PS_GDST);
      vsh_q_reg_wr(GPU_CMD, {OP_SET_DST, 12'h000, PS_PITCH16});
      vsh_q_reg_wr(GPU_CMD, PS_GCPY);
      vsh_q_reg_wr(GPU_CMD, {OP_EXEC_COPY, 28'h000_0000});
   end
endtask

// One register-port round (queue built against the model, then driven)
task ps_r_round;
   input integer rr;
   integer       j;
   begin
      vsh_q_reset;
      if ((rr == 0) && ps_gpu)
         ps_gpu_queue;
      if (ps_lutw)
         for (j = 0; j < 4; j = j + 1)
            vsh_q_reg_wr(LUT_BASE + 32'h400 + 4*((4*rr + j) % 256), $random(vsh_seed));
      if (vsh_rq_n > 0)
         vsh_rburst;
   end
endtask

// One VRAM-window round: writes / read-backs elsewhere, identical rewrites
// and reads of the displayed source words [wlo, whi]
task ps_v_round;
   input integer rr;
   input integer wlo;
   input integer whi;
   integer       j, ww;
   begin
      vsh_vq_reset;
      for (j = 0; j < 12; j = j + 1) begin
         vsh_vq_wr(PS_WIN + ((12*rr + j) % 250), $random(vsh_seed));
         vsh_vq_rd(PS_WIN + ((12*rr + j + 125) % 250));
         ww = wlo + ($unsigned($random(vsh_seed)) % (whi - wlo + 1));
         if (j % 2) vsh_vq_wr(ww, vsh_mem[ww]);
         else       vsh_vq_rd(ww);
      end
      vsh_vburst;
   end
endtask

// One doubled frame under contention
task ps_contended;
   input integer idx;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input  [31:0] lutcfg;
   integer       nn, nf, wlo, whi, ii, sw, sh;
   begin
      if (!ps_fits(w, h))
         $display("NOTE:  contended frame %0d -- skipped (%0dx%0d does not fit DIM_W = %0d)", idx, w, h, DIM_W);
      else begin
         nn  = w * h;
         sw  = (w + 1) / 2;
         sh  = (h + 1) / 2;
         wlo = base >> (5 - bkr_bpp_log2(mode));
         whi = (base + sw * sh - 1) >> (5 - bkr_bpp_log2(mode));
         ps_gpu  = (GPU_EN != 0) && (mode == 3'd4);
         ps_lutw = (LUT_EN != 0) && (LUT_BANKS == 2) && !(lutcfg[0] && lutcfg[1]);
         if (ps_gpu)
            for (ii = PS_GDST/2; ii < PS_GCPY/2 + PS_FILL_W*PS_FILL_H/2; ii = ii + 1) begin
               vram_mem[ii] = 32'h0;
               vsh_mem[ii]   = 32'h0;
            end
         ps_config(base, mode, w, h, cfg, 1'b1, lutcfg, 32'h0, ps_gpu);
         case (idx % 3)
            0 :      begin bkm_rdy_mode = 1; bkm_rdy_pct_low = 25; end
            1 :      bkm_rdy_mode = 0;
            default: begin bkm_rdy_mode = 2; bkm_rdy_gap = 6; end
         endcase

         bkm_exp_n = nn;
         nf        = bkm_frames;
         ps_rr     = 0;
         ps_vr     = 0;
         ps_ract   = 0;
         ps_vact   = 0;
         reg_wr(REFRESH, 32'h0000_0001);
         fork
            if (ps_gpu || ps_lutw)
               while (((ps_rr == 0) || (bkm_frames == nf)) && (ps_rr < 200)) begin
                  ps_r_round(ps_rr);
                  ps_rr = ps_rr + 1;
                  if (bkm_frames == nf) ps_ract = ps_ract + 1;
               end
            while (((ps_vr == 0) || (bkm_frames == nf)) && (ps_vr < 200)) begin
               ps_v_round(ps_vr, wlo, whi);
               ps_vr = ps_vr + 1;
               if (bkm_frames == nf) ps_vact = ps_vact + 1;
            end
            bkm_wait_frames(nf + 1, 4000 + 200 * nn);
         join
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);

         ps_build(base, mode, w, h, cfg, 1'b1, lutcfg, 32'h0);
         $sformat(ps_tag, "contended doubled frame %0d mode %0d cfg %0d %0dx%0d", idx, mode, cfg, w, h);
         bkr_check_bdi(ps_tag);
         $display("INFO:  frame %0d: %0d cycles active, %0d / %0d r-rounds and %0d / %0d v-rounds ended while it ran, GPU %0d, LUT writes %0d",
                  idx, bkm_fall_cyc - bkm_rise_cyc, ps_ract, ps_rr, ps_vact, ps_vr, ps_gpu, ps_lutw);
         if ((nn >= 300) && (ps_vact == 0))
            tb_error("VRAM-window traffic did not overlap the doubled frame");

         if (ps_gpu) begin
            reg_poll(GPU_STAT, 32'h0061_0000, 32'h0001_0000, 5000);
            ps_nerr = 0;
            for (ii = 0; ii < PS_FILL_W*PS_FILL_H/2; ii = ii + 1)
               if ((vram_mem[PS_GDST/2 + ii] !== {PS_COLOR, PS_COLOR}) ||
                   (vram_mem[PS_GCPY/2 + ii] !== {PS_COLOR, PS_COLOR}))
                  ps_nerr = ps_nerr + 1;
            if (ps_nerr != 0) begin
               $display("ERROR: contended frame %0d -- %0d GPU fill / copy words wrong %t", idx, ps_nerr, $time);
               error = error + 1;
            end else
               $display("OK:    contended frame %0d -- GPU fill and copy rectangles exact", idx);
            vsh_resync(PS_GDST/2, PS_GCPY/2 + PS_FILL_W*PS_FILL_H/2 - PS_GDST/2);
         end
         vsh_check_touched;
         reg_wr(CTRL, {29'h0, mode});

         // the frame is unchanged: the same doubled frame without traffic
         bkm_rdy_mode = 1;
         $sformat(ps_tag, "doubled frame %0d again, no traffic", idx);
         ps_frame(ps_tag, base, mode, w, h, cfg, 1'b1, lutcfg, 32'h0);
      end
   end
endtask

//----------------------------------------------------------------------------
// Aborted doubled frame (driver drops active after n pixels), then a clean one
//----------------------------------------------------------------------------
task ps_abort;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input integer n;
   integer       nf, ii, ne;
   begin
      ps_config(base, mode, w, h, cfg, 1'b1, 32'h0000_5410, 32'h0, 1'b0);
      bkm_abort_at = n;
      bkm_exp_n    = 0;
      nf           = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bkm_wait_frames(nf + 1, 5000 + 60 * w * h);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      bkm_abort_at = 0;
      ps_build(base, mode, w, h, cfg, 1'b1, 32'h0000_5410, 32'h0);
      ne = 0;
      for (ii = 0; (ii < bkm_n) && (ii < bkr_n); ii = ii + 1)
         if (bkm_px[ii] !== bkr_exp[ii]) ne = ne + 1;
      if ((bkm_n != n) || (ne != 0)) begin
         $display("ERROR: doubled frame mode %0d cfg %0d %0dx%0d aborted after %0d pixels: %0d taken, %0d prefix mismatches %t",
                  mode, cfg, w, h, n, bkm_n, ne, $time);
         error = error + 1;
      end else
         $display("OK:    doubled frame mode %0d cfg %0d %0dx%0d aborted after %0d pixels, prefix exact", mode, cfg, w, h, n);
      repeat (n % 5) @(posedge free_clk);
      $sformat(ps_tag, "doubled frame after an abort at pixel %0d", n);
      ps_frame(ps_tag, base, mode, w, h, cfg, 1'b1, 32'h0000_5410, 32'h0);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|   BACKEND: PIXEL DOUBLING UNDER STRESS        |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en          = 1'b1;
      bkm_rdy_mode    = 1;
      bkm_rdy_pct_low = 20;
      bk_lut_rand;
      bk_vram_rand(0, 2048);
      // 8 bpp ramp 0..255 (words PS_RAMP..+63), 4 bpp ramps (+64..+79)
      for (ps_i = 0; ps_i < 64; ps_i = ps_i + 1)
         vram_mem[PS_RAMP + ps_i] = ((4*ps_i+3) << 24) | ((4*ps_i+2) << 16) | ((4*ps_i+1) << 8) | (4*ps_i);
      for (ps_i = 64; ps_i < 80; ps_i = ps_i + 1)
         vram_mem[PS_RAMP + ps_i] = ps_i[0] ? 32'hFEDC_BA98 : 32'h7654_3210;
      bk_vram_rand(PS_RAMP + 80, 176);
      vsh_resync(0, VRAM_WORDS);
      vsh_fill(PS_WIN, 32'd300, 32'h5A11);          // non-zero background for the window read-backs

      //--------------------------------------------------------------
      $display("--- doubled frames under VRAM contention: every bpp, all 8 swaps");
      for (ps_i = 0; ps_i < 10; ps_i = ps_i + 1) begin
         case (ps_i)
            0 : begin ps_w = 24; ps_h = 18; end
            1 : begin ps_w = 23; ps_h = 17; end
            2 : begin ps_w = 17; ps_h = 24; end
            3 : begin ps_w = 30; ps_h = 13; end
            4 : begin ps_w = 40; ps_h = 30; end
            5 : begin ps_w = 1;  ps_h = 9;  end
            6 : begin ps_w = 31; ps_h = 2;  end
            7 : begin ps_w = 20; ps_h = 20; end
            8 : begin ps_w = 13; ps_h = 13; end
            default : begin ps_w = 33; ps_h = 21; end
         endcase
         ps_mode = ps_i % 5;
         ps_cfg  = ps_i % 8;
         ps_b    = 5 + 37 * ps_i;
         case (ps_i)
            3 :      ps_lut = 32'h0000_6D31;   // 8 bpp SW LUT bank 0
            6 :      ps_lut = 32'h0000_6D31;   // 2 bpp SW LUT bank 0
            7 :      ps_lut = 32'h0000_6D33;   // 4 bpp SW LUT bank 1
            default: ps_lut = (ps_i % 2) ? 32'h0000_A560 : 32'h0000_6D30;
         endcase
         ps_contended(ps_i, ps_b, ps_mode, ps_w, ps_h, ps_cfg, ps_lut);
      end

      //--------------------------------------------------------------
      $display("--- PIX_DOUBLE with LUT_ROT and SW_LUT_EN");
      bkm_rdy_mode    = 1;
      bkm_rdy_pct_low = 30;
      // 8 bpp: the 16x16 source holds every value 0..255
      for (ps_k = 0; ps_k < 7; ps_k = ps_k + 1) begin
         case (ps_k)
            0 : begin ps_rot = {8'h0,  8'd3,  8'd40,  8'd16}; ps_cfg = 3'b000; ps_v = 0; ps_w = 32; ps_h = 32; end
            1 : begin ps_rot = {8'h0,  8'd1,  8'd255, 8'd0};  ps_cfg = 3'b110; ps_v = 1; ps_w = 31; ps_h = 31; end
            2 : begin ps_rot = {8'h0,  8'd255,8'd255, 8'd200};ps_cfg = 3'b001; ps_v = 0; ps_w = 32; ps_h = 31; end
            3 : begin ps_rot = {8'h0,  8'd7,  8'd50,  8'd100};ps_cfg = 3'b111; ps_v = 0; ps_w = 32; ps_h = 32; end
            4 : begin ps_rot = {8'h0,  8'd30, 8'd20,  8'd10}; ps_cfg = 3'b011; ps_v = 1; ps_w = 31; ps_h = 32; end
            5 : begin ps_rot = {8'h0,  8'd5,  8'd77,  8'd77}; ps_cfg = 3'b101; ps_v = 0; ps_w = 32; ps_h = 32; end
            default : begin
               ps_d   = $random(bkm_seed);
               ps_rot = (ps_d[7:0] <= ps_d[15:8]) ? {8'h00, ps_d[23:0]} : {8'h00, ps_d[23:16], ps_d[7:0], ps_d[15:8]};
               ps_cfg = ps_d[26:24];
               ps_v   = ps_d[27];
               ps_w   = 32; ps_h = 32;
            end
         endcase
         ps_lut = 32'h0000_6D31 | (ps_v << 1);
         $sformat(ps_tag, "doubled 8 bpp %0dx%0d cfg %0d bank %0d FIRST %0d LAST %0d OFFSET %0d",
                  ps_w, ps_h, ps_cfg, ps_v, ps_rot[7:0], ps_rot[15:8], ps_rot[23:16]);
         ps_frame(ps_tag, PS_RAMP * 4, 3'd3, ps_w, ps_h, ps_cfg, 1'b1, ps_lut, ps_rot);
      end
      ps_frame("undoubled 8 bpp 16x16, same rotation (contrast)", PS_RAMP * 4, 3'd3, 16, 16, 3'b000, 1'b0,
               32'h0000_6D31, {8'h0, 8'd3, 8'd40, 8'd16});
      // 4 bpp: 8x8 source over the 0..15 ramps
      for (ps_k = 0; ps_k < 4; ps_k = ps_k + 1) begin
         case (ps_k)
            0 :      begin ps_rot = {8'h0, 8'd3,   8'd11,  8'd4}; ps_cfg = 3'b000; ps_w = 16; ps_h = 16; end
            1 :      begin ps_rot = {8'h0, 8'd1,   8'd15,  8'd0}; ps_cfg = 3'b100; ps_w = 15; ps_h = 16; end
            2 :      begin ps_rot = {8'h0, 8'd100, 8'd200, 8'd1}; ps_cfg = 3'b011; ps_w = 16; ps_h = 15; end
            default: begin ps_rot = {8'h0, 8'd14,  8'd15,  8'd2}; ps_cfg = 3'b111; ps_w = 15; ps_h = 15; end
         endcase
         ps_lut = 32'h0000_6D31 | ((ps_k % 2) << 1);
         $sformat(ps_tag, "doubled 4 bpp %0dx%0d cfg %0d FIRST %0d LAST %0d OFFSET %0d",
                  ps_w, ps_h, ps_cfg, ps_rot[7:0], ps_rot[15:8], ps_rot[23:16]);
         ps_frame(ps_tag, (PS_RAMP + 64) * 8, 3'd2, ps_w, ps_h, ps_cfg, 1'b1, ps_lut, ps_rot);
      end
      ps_frame("doubled 2 bpp 20x10 X+Y, FIRST 0 LAST 3 OFFSET 1", (PS_RAMP + 80) * 16 + 3, 3'd1, 20, 10, 3'b110, 1'b1,
               32'h0000_6D31, {8'h0, 8'd1, 8'd3, 8'd0});
      ps_frame("doubled 1 bpp 25x6 CL, FIRST 0 LAST 1 OFFSET 1", (PS_RAMP + 90) * 32 + 7, 3'd0, 25, 6, 3'b001, 1'b1,
               32'h0000_6D33, {8'h0, 8'd1, 8'd1, 8'd0});
      ps_frame("doubled 16 bpp 10x6, rotation set (no effect)", 101, 3'd4, 10, 6, 3'b010, 1'b1,
               32'h0000_6D31, {8'h0, 8'd1, 8'd255, 8'd0});
      reg_wr(LUT_ROT, 32'h0);

      //--------------------------------------------------------------
      $display("--- VRAM reads of doubled frames vs the undoubled source frame (no traffic)");
      bkm_rdy_mode = 0;
      for (ps_k = 0; ps_k < 10; ps_k = ps_k + 1) begin
         ps_m = ps_k % 5;
         ps_w = (ps_k < 5) ? 24 : 23;
         ps_h = (ps_k < 5) ? 18 : 17;
         if (ps_k == 9) begin ps_w = 6; ps_h = 4; end
         ps_cfg = (ps_k < 5) ? ps_k[2:0] : (3'd7 - ps_k[2:0]);
         ps_b   = 31 + 11 * ps_k;
         ps_sw  = (ps_w + 1) / 2;
         ps_sh  = (ps_h + 1) / 2;
         $sformat(ps_tag, "read count: source %0dx%0d mode %0d cfg %0d base %0d", ps_sw, ps_sh, ps_m, ps_cfg, ps_b);
         ps_frame(ps_tag, ps_b, ps_m, ps_sw, ps_sh, ps_cfg, 1'b0, 32'h0000_6D30, 32'h0);
         ps_rd_s = ps_rd_d;
         ps_rn_s = ps_rn_d;
         $sformat(ps_tag, "read count: doubled %0dx%0d mode %0d cfg %0d base %0d", ps_w, ps_h, ps_m, ps_cfg, ps_b);
         ps_frame(ps_tag, ps_b, ps_m, ps_w, ps_h, ps_cfg, 1'b1, 32'h0000_6D30, 32'h0);
         $display("INFO:  reads: doubled %0dx%0d = %0d (scan word changes %0d), source %0dx%0d = %0d (word changes %0d), mode %0d cfg %0d",
                  ps_w, ps_h, ps_rd_d, ps_rn_d, ps_sw, ps_sh, ps_rd_s, ps_rn_s, ps_m, ps_cfg);
         if (ps_rd_d * ps_sw * ps_sh > ps_rd_s * ps_w * ps_h) begin
            $display("ERROR: doubled frame %0dx%0d mode %0d cfg %0d: %0d VRAM reads, more per pixel than the source frame (%0d reads for %0d pixels) %t",
                     ps_w, ps_h, ps_m, ps_cfg, ps_rd_d, ps_rd_s, ps_sw * ps_sh, $time);
            error = error + 1;
         end
         if (ps_rd_d > ps_rn_d)
            $display("NOTE:  doubled frame reads exceed the word-address changes of its scan (%0d > %0d)", ps_rd_d, ps_rn_d);
      end

      //--------------------------------------------------------------
      $display("--- aborted doubled frames, then a clean doubled frame");
      for (ps_k = 0; ps_k < 6; ps_k = ps_k + 1) begin
         bkm_rdy_mode = ps_k % 2;
         case (ps_k)
            0 :      ps_n = 5;            // inside the first line
            1 :      ps_n = 3;            // between the two copies of source pixel 1
            2 :      ps_n = 17;           // at the end of the first panel line
            3 :      ps_n = 17 + 9;       // inside the repeated line, between two copies
            4 :      ps_n = 2 * 17 + 4;   // second source line, first copy
            default: ps_n = 81;           // inside the last line pair
         endcase
         ps_abort(3 + ps_k, (ps_k < 3) ? 3'd4 : 3'd1, 17, 6, ps_k[2:0], ps_n);
      end
      // CL swap: the panel line is a source column pair
      ps_abort(9, 3'd3, 9, 14, 3'b001, 15);
      ps_abort(9, 3'd0, 9, 14, 3'b111, 29);

      // abort with ready held low (fetch stalled), then a clean frame
      ps_config(0, 3'd4, 30, 8, 3'b001, 1'b1, 32'h0000_F000, 32'h0, 1'b0);
      bkm_rdy_mode = 1;
      bkm_exp_n    = 0;
      ps_nf        = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      bkm_wait_pixels(7, 2000);
      bkm_hold = 1'b1;
      repeat (40) @(posedge free_clk);
      bkm_drop;
      bkm_wait_frames(ps_nf + 1, 100);
      bkm_hold = 1'b0;
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      ps_frame("doubled frame after a held abort", 0, 3'd4, 30, 8, 3'b001, 1'b1, 32'h0000_F000, 32'h0);
      reg_wr(IRQ_FLAG, 32'h0000_0003);

      reg_wr(DISP_CFG, 32'h0);
      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
