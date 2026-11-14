//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          File:      dpi_tasks.v
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_tasks.v
// Module Description : Shared tasks of the DPI driver tests (`included by the
//                      stimulus):
//                        - the frame Belenos sends, captured from the BDI
//                          stream (dpi_src, complete frames only);
//                        - panel set-up (dpi_timing) and the expectations of
//                          the panel model;
//                        - a 16 bpp test frame in the VRAM (dpi_frame_fill);
//                        - the reference image of the panel and its check
//                          (dpi_check_image): nearest neighbour or bilinear,
//                          the rule of the programming guide.
//----------------------------------------------------------------------------

localparam integer DPI_SRC_MAX = 65536;            // dpi_wide's 1280 x 4 frame, dpi_hd's 320 x 180

reg     [23:0] dpi_src      [0:DPI_SRC_MAX-1];   // last complete frame
reg     [23:0] dpi_src_next [0:DPI_SRC_MAX-1];
integer        dpi_src_n    = 0;                 // pixels of the frame being captured
integer        dpi_src_done = 0;                 // complete frames captured
integer        dpi_src_len  = 0;                 // pixels of the last complete frame
reg            dpi_ra_q     = 1'b0;
integer        dpi_k;

always @(posedge hclk) begin
   if (dut.refresh_active && !dpi_ra_q) dpi_src_n = 0;
   if (dut.refresh_active && bdi_px_valid && dut.px_ready) begin
      if (dpi_src_n < DPI_SRC_MAX) dpi_src_next[dpi_src_n] = bdi_px_data;
      dpi_src_n = dpi_src_n + 1;
      if (bdi_px_last) begin
         for (dpi_k = 0; (dpi_k < dpi_src_n) && (dpi_k < DPI_SRC_MAX); dpi_k = dpi_k + 1) dpi_src[dpi_k] = dpi_src_next[dpi_k];
         dpi_src_len  = dpi_src_n;
         dpi_src_done = dpi_src_done + 1;
      end
   end
   dpi_ra_q = dut.refresh_active;
end

// Panel timing: registers and the panel model's expectations
integer dpi_hact, dpi_vact;
integer dpi_div_set = -1;
task dpi_timing;
   input integer div;
   input integer ha, hf, hw, hb, va, vf, vw, vb;
   reg   [31:0]  cfg;
   begin
      reg_wr(DPI_H_ACT,   ha);
      reg_wr(DPI_H_BLANK, hf | (hw << 10) | (hb << 20));
      reg_wr(DPI_V_ACT,   va);
      reg_wr(DPI_V_BLANK, vf | (vw << 10) | (vb << 20));
      reg_rd_val(DIF_CFG, cfg);
      reg_wr(DIF_CFG, (cfg & 32'hFFFF_F0FF) | (div << 8));
      u_dpipanel.h_act = ha; u_dpipanel.h_fp = hf; u_dpipanel.h_sw = hw; u_dpipanel.v_act = va;
      u_dpipanel.h_bp = hb; u_dpipanel.v_fp = vf; u_dpipanel.v_sw = vw; u_dpipanel.v_bp = vb;
      // a CLK_DIV change taken while the panel model checks: one irregular
      // clock period at the frame start that takes it
      if (u_dpipanel.check && (dpi_div_set >= 0) && (div != dpi_div_set)) u_dpipanel.lt_slack = 1;
      dpi_div_set = div;
      dpi_hact = ha; dpi_vact = va;
   end
endtask

// CLK_DIV for a test's divider d that keeps its pixel rate at most what it is
// with the default pixel clock (a faster PCLK_HALF divides more): the image
// tests need the BDI stream to keep up (UNDERFLOW is dpi_underflow's subject)
function integer dpi_div;
   input integer d;
   dpi_div = (d + 1) * PCLK_FAST - 1;
endfunction

// Wait for n complete panel frames (at most max_cycles hclk cycles)
task dpi_wait_frames;
   input integer n;
   integer       f0, nc;
   begin
      f0 = u_dpipanel.frames; nc = 0;
      while ((u_dpipanel.frames < f0 + n) && (nc < 4000000)) begin @(posedge free_clk); nc = nc + 1; end
      if (u_dpipanel.frames < f0 + n) tb_error("DPI panel frames did not arrive");
   end
endtask

// A W x H frame at 16 bpp at pixel address 0: pixel (x, y) = x + 64*y + seed
task dpi_frame_fill;
   input integer w, h, seed;
   integer       x, y;
   reg    [15:0] p0, p1;
   begin
      reg_wr(CTRL, {29'd0, GFX_16BPP});
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(DISP_SIZE, (h << 16) | w);
      for (y = 0; y < h; y = y + 1)
         for (x = 0; x < w; x = x + 2) begin
            p0 = x + 64*y + seed; p1 = x + 1 + 64*y + seed;
            vram_wr((y*w + x) * 2, {p1, p0}, SZ_W);
         end
   end
endtask

// Reference image of the panel from the captured frame (sl pixels per stream
// line, sn lines) and the check of the panel model's last frame
function [7:0] dpi_ch; input [23:0] v; input integer c; dpi_ch = v >> (8*c); endfunction
function [23:0] dpi_expect;
   input integer x, y, sl, sn, iw, ih, x0, y0, stx, sty, fil, border;
   integer       fx, fy, sx, sy, sx1, sy1, wx, wy, c, h0, h1;
   reg    [23:0] a, b, cc, d, r;
   begin
      if ((x < x0) || (x >= x0 + iw) || (y < y0) || (y >= y0 + ih)) dpi_expect = border;
      else begin
         fx = (x - x0) * stx; fy = (y - y0) * sty;
         sx = fx >> 12; sy = fy >> 12;
         if (sx > sl - 1) sx = sl - 1;
         if (sy > sn - 1) sy = sn - 1;
         wx  = (fil && (stx <= 4096)) ? ((fx >> 8) & 15) : 0;
         wy  = (fil && (sty <= 4096)) ? ((fy >> 8) & 15) : 0;
         sx1 = (fil && (stx <= 4096) && (sx < sl - 1)) ? sx + 1 : sx;
         sy1 = (fil && (sty <= 4096) && (sy < sn - 1)) ? sy + 1 : sy;
         a = dpi_src[sy*sl + sx]; b = dpi_src[sy*sl + sx1]; cc = dpi_src[sy1*sl + sx]; d = dpi_src[sy1*sl + sx1];
         for (c = 0; c < 3; c = c + 1) begin
            h0 = dpi_ch(a, c)*(16 - wx) + dpi_ch(b, c)*wx;
            h1 = dpi_ch(cc, c)*(16 - wx) + dpi_ch(d, c)*wx;
            r[8*c +: 8] = (h0*(16 - wy) + h1*wy + 128) >> 8;
         end
         dpi_expect = r;
      end
   end
endfunction

task dpi_check_image;
   input integer sl, sn, iw, ih, x0, y0, stx, sty, fil, border;
   input [8*48-1:0] what;
   integer       x, y, bad;
   reg    [23:0] e;
   begin
      bad = 0;
      tb_checks = tb_checks + 1;
      for (y = 0; y < dpi_vact; y = y + 1)
         for (x = 0; x < dpi_hact; x = x + 1) begin
            e = dpi_expect(x, y, sl, sn, iw, ih, x0, y0, stx, sty, fil, border);
            if (u_dpipanel.fb[y*u_dpipanel.W_MAX + x] !== e) begin
               if (bad < 5) $display("ERROR: %0s -- panel pixel (%0d,%0d) = %06h, expected %06h %t",
                                     what, x, y, u_dpipanel.fb[y*u_dpipanel.W_MAX + x], e, $time);
               bad = bad + 1;
            end
         end
      if (bad != 0) begin
         $display("ERROR: %0s -- %0d pixels differ", what, bad);
         error = error + 1;
      end else
         $display("OK:    %0s (%0d x %0d panel, image %0d x %0d at %0d,%0d)", what, dpi_hact, dpi_vact, iw, ih, x0, y0);
   end
endtask
