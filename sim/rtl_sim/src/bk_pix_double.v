//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_pix_double
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_pix_double.v
// Module Description : Pixel doubling (DISP_CFG[4] PIX_DOUBLE). The refresh
//                      sends W x H pixels read from a ceil(W/2) x ceil(H/2)
//                      source frame (pitch ceil(W/2)) at the refresh frame
//                      pointer, walked with the DISP_CFG swaps: pixel k of
//                      panel scan line j = pixel k/2 of source scan line j/2.
//                      Checked against an own reference on the BDI model
//                      stream (DIF_TYPE = 0, random back-pressure) or on the
//                      ILI9341 panel log (DIF_TYPE 1/2/3, RGB565) or the
//                      stream the DPI driver takes (DIF_TYPE 4: a frame
//                      started after the configuration, panel-paced):
//                        - all 8 swap combinations x even / odd / 1-pixel
//                          sizes, every bpp, non-aligned frame bases;
//                        - every bpp at 24x18, odd x odd 23x17 with X+Y swap
//                          (SW LUT when present), CL swap on a 40x20
//                          landscape frame; doubling off returns to normal;
//                        - PIX_DOUBLE latched at frame start: a DISP_CFG write
//                          in the middle of a frame applies at the next one;
//                        - DISP_CFG reads back [4] and [2:0] only;
//                        - default pitch: GPU FILL / COPY with pitch 0 step
//                          by ceil(W/2) with PIX_DOUBLE, W without, from the
//                          live DISP_CFG (the last refresh latched the
//                          opposite value). Skipped without a GPU.
//                      Sizes that do not fit DIM_W are skipped (NOTE).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"
`include "gpu_model.v"
`include "dpi_tasks.v"

localparam [31:0] PD_DBL = 32'h0000_0010;
localparam [31:0] PD_FB  = 32'd64;                 // frame pointer of the pitch parts

integer    pd_c, pd_s, pd_m, pd_w, pd_h, pd_b, pd_i, pd_n, pd_nf, pd_nerr;
integer    pd_gw, pd_gh, pd_mw, pd_mh, pd_hw;
reg        pd_spi;
reg [31:0] pd_ctrl_hi;
reg [31:0] pd_lut;
reg  [2:0] pd_mode;
reg [15:0] pd_got;
reg [64*8-1:0] pd_tag;
reg [64*8-1:0] pd_tag2;

// A frame size the DISP_SIZE fields can hold
function pd_fits;
   input integer w;
   input integer h;
   begin
      pd_fits = (w < (1 << DIM_W)) && (h < (1 << DIM_W));
   end
endfunction

// Pixels logged by the active panel model
function integer pd_pxcnt;
   input dummy;
   begin
      pd_pxcnt = pd_spi ? u_lcdspi.px_count : u_lcd8080.px_count;
   end
endfunction

// Expected stream of one frame into bkr_exp[0..bkr_n-1] (RGB888)
task pd_build;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;       // [0] CL, [1] Y, [2] X
   input         dbl;
   input  [31:0] lutcfg;
   integer       sw, sh, nl, ni, ll, ii, sl, si, xx, yy, pa;
   begin
      sw = dbl ? ((w + 1) / 2) : w;
      sh = dbl ? ((h + 1) / 2) : h;
      nl = cfg[0] ? w : h;
      ni = cfg[0] ? h : w;
      bkr_n    = 0;
      bkr_runs = 0;
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
           if (bkr_n < BKR_MAX)
             bkr_exp[bkr_n] = bkr_color(mode, bkr_pix(mode, pa), lutcfg);
           bkr_n = bkr_n + 1;
        end
   end
endtask

// Program the refresh (frame 0)
task pd_config;
   input integer base;
   input   [2:0] mode;
   input integer w;
   input integer h;
   input   [2:0] cfg;
   input         dbl;
   input  [31:0] lutcfg;
   begin
      reg_wr(FRAME0_PTR, base);
      reg_wr(FRAME_SEL,  32'h0);
      reg_wr(CTRL,       pd_ctrl_hi | {29'h0, mode});
      reg_wr(DISP_SIZE,  (h << 16) | w);
      reg_wr(DISP_CFG,   {27'h0, dbl, 1'b0, cfg});
      reg_wr(LUT_CFG,    lutcfg);
      if ((bdi_width !== w[DIM_W-1:0]) || (bdi_height !== h[DIM_W-1:0])) begin
         $display("ERROR: bdi_width_o/bdi_height_o = %0d/%0d after DISP_SIZE %0dx%0d (PIX_DOUBLE %0d) %t",
                  bdi_width, bdi_height, w, h, dbl, $time);
         error = error + 1;
      end
   end
endtask

task pd_panel_clear;
   begin
      if (pd_spi) begin u_lcdspi.px_count = 0;  u_lcdspi.anomaly_count = 0;  end
      else        begin u_lcd8080.px_count = 0; u_lcd8080.anomaly_count = 0; end
   end
endtask

// Wait for the end of the frame requested by the last REFRESH write (DBI path)
task pd_panel_wait;
   begin
      reg_poll(REFRESH,    32'h0000_0001, 32'h0000_0000, 20000);
      reg_poll(DIF_STATUS, 32'h0000_0001, 32'h0000_0000, 2000);
   end
endtask

// DPI: the next frame started after now has been taken
task pd_dpi_next;
   integer nf, nc;
   begin
      nf = dpi_src_done + 2; nc = 0;
      while ((dpi_src_done < nf) && (nc < 200000)) begin @(posedge free_clk); nc = nc + 1; end
      if (dpi_src_done < nf) tb_error("DPI: no frame taken");
   end
endtask

// One manual refresh of n pixels
task pd_refresh;
   input integer n;
   begin
      if (DIF_TYPE == 0)
         bk_refresh(n);
      else if (HAS_DPI)
         pd_dpi_next;
      else begin
         pd_panel_clear;
         reg_wr(REFRESH, 32'h0000_0001);
         pd_panel_wait;
      end
   end
endtask

// Compare the received frame with bkr_exp
task pd_check;
   input [64*8-1:0] tag;
   begin
      if (DIF_TYPE == 0)
         bkr_check_bdi(tag);
      else if (HAS_DPI) begin
         pd_nerr = 0;
         if (dpi_src_len != bkr_n) begin
            $display("ERROR: %0s -- driver took %0d pixels / expected %0d %t", tag, dpi_src_len, bkr_n, $time);
            error = error + 1;
         end
         for (pd_i = 0; (pd_i < bkr_n) && (pd_i < DPI_SRC_MAX); pd_i = pd_i + 1)
            if (dpi_src[pd_i] !== bkr_exp[pd_i]) begin
               pd_nerr = pd_nerr + 1;
               if (pd_nerr <= 8)
                  $display("ERROR: %0s -- pixel %0d = 0x%h / expected 0x%h %t", tag, pd_i, dpi_src[pd_i], bkr_exp[pd_i], $time);
            end
         error = error + pd_nerr;
         if ((pd_nerr == 0) && (dpi_src_len == bkr_n))
            $display("OK:    %0s -- %0d pixels", tag, bkr_n);
      end else begin
         pd_nerr = 0;
         if (pd_pxcnt(1'b0) != bkr_n) begin
            $display("ERROR: %0s -- panel received %0d pixels / expected %0d %t", tag, pd_pxcnt(1'b0), bkr_n, $time);
            error = error + 1;
         end
         if ((pd_spi ? u_lcdspi.anomaly_count : u_lcd8080.anomaly_count) != 0)
            tb_error("panel model protocol anomaly");
         for (pd_i = 0; (pd_i < bkr_n) && (pd_i < 4096); pd_i = pd_i + 1) begin
            pd_got = pd_spi ? u_lcdspi.px_log[pd_i] : u_lcd8080.px_log[pd_i];
            if (pd_got !== bkr_888to565(bkr_exp[pd_i])) begin
               pd_nerr = pd_nerr + 1;
               if (pd_nerr <= 8)
                  $display("ERROR: %0s -- pixel %0d = 0x%h / expected 0x%h (RGB888 0x%h) %t", tag, pd_i, pd_got,
                           bkr_888to565(bkr_exp[pd_i]), bkr_exp[pd_i], $time);
            end
         end
         error = error + pd_nerr;
         if ((pd_nerr == 0) && (pd_pxcnt(1'b0) == bkr_n))
            $display("OK:    %0s -- %0d pixels", tag, bkr_n);
         else if (pd_nerr > 0)
            $display("ERROR: %0s -- %0d pixel mismatches %t", tag, pd_nerr, $time);
      end
   end
endtask

// One complete frame: configure, refresh, reference, compare
task pd_frame;
   input [64*8-1:0] tag;
   input integer    base;
   input      [2:0] mode;
   input integer    w;
   input integer    h;
   input      [2:0] cfg;
   input            dbl;
   input     [31:0] lutcfg;
   begin
      if (!pd_fits(w, h))
         $display("NOTE:  %0s -- skipped (%0dx%0d does not fit DIM_W = %0d)", tag, w, h, DIM_W);
      else begin
         pd_config(base, mode, w, h, cfg, dbl, lutcfg);
         pd_refresh(w * h);
         pd_build(base, mode, w, h, cfg, dbl, lutcfg);
         pd_check(tag);
      end
   end
endtask

// DISP_CFG rewritten in the middle of a frame: the frame keeps the value
// taken at its start, the next frame uses the new one
task pd_midframe;
   input [64*8-1:0] tag;
   input integer    base;
   input      [2:0] mode;
   input integer    w;
   input integer    h;
   input      [2:0] cfg1;
   input            dbl1;
   input      [2:0] cfg2;
   input            dbl2;
   input     [31:0] lutcfg;
   integer          nn;
   begin
      nn = w * h;
      pd_config(base, mode, w, h, cfg1, dbl1, lutcfg);
      if (DIF_TYPE == 0) begin
         bkm_exp_n = nn;
         pd_nf     = bkm_frames;
         reg_wr(REFRESH, 32'h0000_0001);
         bkm_wait_active(2000);                  // bkm_n restarts at the frame start
         bkm_wait_pixels(4, 2000 + 60*nn);
         bkm_hold = 1'b1;
         reg_wr(DISP_CFG, {27'h0, dbl2, 1'b0, cfg2});
         if ((bkm_n >= nn) || (bdi_refresh_active_drv !== 1'b1))
            tb_error("mid-frame DISP_CFG write: the frame had already ended");
         repeat(3) @(posedge free_clk);
         bkm_hold = 1'b0;
         bkm_wait_frames(pd_nf + 1, 2000 + 60*nn);
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      end else if (HAS_DPI) begin
         pd_dpi_next;                            // frames with cfg1 run
         pd_nf = dpi_src_done;
         pd_i  = 0;
         while (dut.refresh_active && (pd_i < 100000)) begin @(posedge free_clk); pd_i = pd_i + 1; end
         repeat (2) @(posedge free_clk);
         while (!(dut.refresh_active && (dpi_src_n >= 4)) && (pd_i < 100000)) begin
            @(posedge free_clk);
            pd_i = pd_i + 1;
         end
         reg_wr(DISP_CFG, {27'h0, dbl2, 1'b0, cfg2});
         if ((dpi_src_done != pd_nf) || (dpi_src_n >= nn))
            tb_error("mid-frame DISP_CFG write: the frame had already ended");
         pd_i = 0;
         while ((dpi_src_done == pd_nf) && (pd_i < 100000)) begin @(posedge free_clk); pd_i = pd_i + 1; end
      end else begin
         pd_panel_clear;
         reg_wr(REFRESH, 32'h0000_0001);
         pd_i = 0;
         while ((pd_pxcnt(1'b0) < 4) && (pd_i < 100000)) begin
            @(posedge free_clk);
            pd_i = pd_i + 1;
         end
         reg_wr(DISP_CFG, {27'h0, dbl2, 1'b0, cfg2});
         if (pd_pxcnt(1'b0) >= nn)
            tb_error("mid-frame DISP_CFG write: the frame had already ended");
         pd_panel_wait;
      end
      pd_build(base, mode, w, h, cfg1, dbl1, lutcfg);
      $sformat(pd_tag2, "%0s: frame running at the write", tag);
      pd_check(pd_tag2);
      pd_refresh(nn);
      pd_build(base, mode, w, h, cfg2, dbl2, lutcfg);
      $sformat(pd_tag2, "%0s: next frame", tag);
      pd_check(pd_tag2);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: PIXEL DOUBLING (DISP_CFG[4])  |");
      $display(" ===============================================");
      @(posedge reset_done);

      pd_spi     = (DIF_TYPE == 1);
      pd_ctrl_hi = 32'h0;
      bk_vram_rand(0, 512);
      bk_lut_rand;
      if (DIF_TYPE == 0) begin
         bkm_en          = 1'b1;
         bkm_rdy_mode    = 1;
         bkm_rdy_pct_low = 20;
      end else if (HAS_DPI) begin
         dpi_timing(0, 64, 2, 2, 2, 48, 1, 1, 1);  // the largest frame (40 x 20, CL) fits
         reg_rd_val(DIF_CFG, pd_ctrl_hi);
         reg_wr(DIF_CFG, pd_ctrl_hi | 32'h9);
         pd_ctrl_hi = 32'h0;
      end else
         reg_wr(DIF_CFG, pd_spi ? 32'h0000_0005 : 32'h0000_0001);   // LCD_ON, HW_WINDOW_EN = 0

      //--------------------------------------------------------------
      $display("--- DISP_CFG readback: [4] and [2:0]");
      reg_wr(DISP_CFG, 32'hFFFF_FFFF);
      reg_rd(DISP_CFG, 32'h0000_0017);
      reg_wr(DISP_CFG, 32'h0000_0008);
      reg_rd(DISP_CFG, 32'h0000_0000);
      reg_wr(DISP_CFG, 32'hFFFF_FFE8);
      reg_rd(DISP_CFG, 32'h0000_0000);
      reg_wr(DISP_CFG, 32'h0000_0010);
      reg_rd(DISP_CFG, 32'h0000_0010);
      reg_wr(DISP_CFG, 32'h0000_0015);
      reg_rd(DISP_CFG, 32'h0000_0015);
      reg_wr(DISP_CFG, 32'h0000_0000);
      reg_rd(DISP_CFG, 32'h0000_0000);

      //--------------------------------------------------------------
      $display("--- every swap combination x even / odd / unit sizes");
      for (pd_c = 0; pd_c < 8; pd_c = pd_c + 1)
        for (pd_s = 0; pd_s < 7; pd_s = pd_s + 1) begin
           case (pd_s)
             0 : begin pd_w = 6; pd_h = 4; end
             1 : begin pd_w = 7; pd_h = 5; end
             2 : begin pd_w = 1; pd_h = 1; end
             3 : begin pd_w = 1; pd_h = 6; end
             4 : begin pd_w = 7; pd_h = 1; end
             5 : begin pd_w = 2; pd_h = 3; end
             default : begin pd_w = 8; pd_h = 7; end
           endcase
           pd_mode = (pd_c + pd_s) % 5;
           pd_b    = 7 + 37*pd_s + 3*pd_c;
           pd_lut  = (((pd_c + pd_s) % 3) == 0) ? 32'h0000_6D31 : 32'h0000_6D30;
           $sformat(pd_tag, "double cfg %0d mode %0d %0dx%0d base %0d", pd_c, pd_mode, pd_w, pd_h, pd_b);
           pd_frame(pd_tag, pd_b, pd_mode, pd_w, pd_h, pd_c, 1'b1, pd_lut);
        end

      //--------------------------------------------------------------
      $display("--- every bpp at 24x18, then doubling off in the next frame");
      for (pd_m = 0; pd_m < 5; pd_m = pd_m + 1) begin
         pd_b = 301 + 2*pd_m;
         $sformat(pd_tag, "double 24x18 mode %0d cfg %0d base %0d", pd_m, pd_m, pd_b);
         pd_frame(pd_tag, pd_b, pd_m, 24, 18, pd_m, 1'b1, 32'h0000_6D30);
         if ((pd_m == 0) || (pd_m == 4)) begin
            $sformat(pd_tag, "normal 24x18 mode %0d cfg %0d base %0d (doubling off)", pd_m, pd_m, pd_b);
            pd_frame(pd_tag, pd_b, pd_m, 24, 18, pd_m, 1'b0, 32'h0000_6D30);
         end
      end

      //--------------------------------------------------------------
      $display("--- odd x odd, X+Y swap, 8 bpp (SW LUT when present)");
      pd_frame("double 23x17 X+Y 8 bpp LUT", 77, 3'd3, 23, 17, 3'b110, 1'b1, 32'h0000_6D33);
      pd_frame("double 23x17 CL+X+Y 2 bpp", 78, 3'd1, 23, 17, 3'b111, 1'b1, 32'h0000_6D30);

      //--------------------------------------------------------------
      $display("--- CL swap on a 40x20 landscape frame");
      pd_frame("double 40x20 CL 16 bpp",      33, 3'd4, 40, 20, 3'b001, 1'b1, 32'h0000_6D30);
      pd_frame("double 40x20 CL+X+Y 4 bpp",   45, 3'd2, 40, 20, 3'b111, 1'b1, 32'h0000_6D30);
      pd_frame("double 40x20 CL+Y 1 bpp",     61, 3'd0, 40, 20, 3'b011, 1'b1, 32'h0000_6D30);
      pd_frame("normal 40x20 CL+Y 1 bpp",     61, 3'd0, 40, 20, 3'b011, 1'b0, 32'h0000_6D30);

      //--------------------------------------------------------------
      $display("--- PIX_DOUBLE taken at frame start");
      pd_mw = (DIM_W >= 5) ? 24 : 14;
      pd_mh = (DIM_W >= 5) ? 18 : 10;
      pd_midframe("mid-frame off->on", 51, 3'd4, pd_mw, pd_mh, 3'b101, 1'b0, 3'b011, 1'b1, 32'h0000_6D30);
      pd_midframe("mid-frame on->off", 53, 3'd3, pd_mw, pd_mh, 3'b010, 1'b1, 3'b010, 1'b0, 32'h0000_6D30);
      // the last refresh latched PIX_DOUBLE = 0

      //--------------------------------------------------------------
      // Default pitch: W odd so that ceil(W/2) differs from floor(W/2) and W
      pd_gw = (DIM_W >= 6) ? 37 : 13;
      pd_gh = 9;
      pd_hw = (pd_gw + 1) / 2;

      if (GPU_EN == 0)
         $display("NOTE:  GPU_EN = 0: GPU default-pitch part skipped");
      else begin
         $display("--- GPU pitch 0 follows ceil(W/2) with PIX_DOUBLE (W = %0d)", pd_gw);
         gpu_seed = `SEED;
         gpu_model_init;
         pd_ctrl_hi = 32'h10;
         gpu_set_mode(3'd4);
         reg_wr(DISP_SIZE, (pd_gh << 16) | pd_gw);
         // refresh latches PIX_DOUBLE = 1, the GPU sees the live 0
         pd_frame("GPU part: refresh, PIX_DOUBLE 1", PD_FB, 3'd4, pd_gw, pd_gh, 3'b000, 1'b1, 32'h0000_6D30);
         reg_wr(DISP_CFG, 32'h0);
         gpu_m_dispw = pd_gw;
         gpu_c_dst(16'd0, 32'd400);
         gpu_c_size(14'd4, 14'd3);
         gpu_c_fill(32'h0000_A5C3);
         gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         gpu_check_touched("FILL pitch 0, PIX_DOUBLE 0");
         // refresh latches PIX_DOUBLE = 0, the GPU sees the live 1
         pd_frame("GPU part: refresh, PIX_DOUBLE 0", PD_FB, 3'd4, pd_gw, pd_gh, 3'b000, 1'b0, 32'h0000_6D30);
         reg_wr(DISP_CFG, PD_DBL);
         gpu_m_dispw = pd_hw;
         gpu_c_dst(16'd0, 32'd600);
         gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
         gpu_wait_idle;
         gpu_check_touched("FILL pitch 0, PIX_DOUBLE 1");
         gpu_c_src(16'd0, 32'd700);
         gpu_c_dst(16'd0, 32'd900 + 3*pd_hw);
         gpu_c_size(14'd5, 14'd4);
         gpu_c_exec(GPU_COPY, 4'd0, 3'b010, 3'b000);         // destination Y swap
         gpu_wait_idle;
         gpu_check_touched("COPY pitch 0 / 0, PIX_DOUBLE 1");
         // live 0 again with display swaps set
         reg_wr(DISP_CFG, 32'h7);
         gpu_m_dispw = pd_gw;
         gpu_c_dst(16'd0, 32'd1100);
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
         gpu_wait_idle;
         gpu_check_touched("COPY pitch 0 / 0, PIX_DOUBLE 0");
         gpu_check_all("pixel-double pitch end");
         reg_wr(DISP_CFG, 32'h0);
      end

      bkm_en = 1'b0;
      if (HAS_DPI) begin
         reg_wr(DIF_CFG, 32'h0);
         reg_poll(DIF_STATUS, 32'h9, 32'h0, 4000);
      end
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
