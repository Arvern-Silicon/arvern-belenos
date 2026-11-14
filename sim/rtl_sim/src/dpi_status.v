//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_status
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_status.v
// Module Description : DPI driver status and frame accounting while it runs:
//                       A. DIF_STATUS read at spread instants of the scan:
//                          LINE against the line the panel model is in
//                          (one line of slack for the read and the
//                          crossing), VBLANK = LINE >= V_ACT, REFRESH_BUSY
//                          against the frame being taken on the BDI;
//                       B. the LINE flag set as line SCANLINE starts (first
//                          active line, mid-frame, last active line, first
//                          and last blanking lines) and the VBLANK flag as
//                          the vertical blanking starts, and not before;
//                       C. the driver interrupt is the OR of the enabled
//                          flags only (a set flag that is not enabled does
//                          not raise IRQ_FLAG.DIF or irq_o);
//                       D. FRAME_CNT counts the panel frames and raises
//                          FRAME_CNT_DONE; a manual REFRESH START sends
//                          nothing and clears once the next frame is taken;
//                       E. debug freeze with FREEZE_REFRESH: the panel keeps
//                          being refreshed (exact image, REFR_DONE,
//                          FRAME_NUM counting), only FRAME_CNT holds; the
//                          stop-time signal alone, or DBG_CTRL alone, holds
//                          nothing;
//                       F. an image larger than the active area is cut from
//                          its top-left corner (centred: from the corner);
//                       G. a stop while a frame is taken abandons it:
//                          REFR_DONE, STATUS.REFR_ABANDONED, FRAME_NUM + 1.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT
`include "dpi_tasks.v"

localparam integer S_HA = 40, S_HF = 3, S_HW = 2, S_HB = 6;
localparam integer S_VA = 20, S_VF = 2, S_VW = 1, S_VB = 2;
localparam integer S_VT = S_VA + S_VF + S_VW + S_VB;
localparam integer S_LT = S_HA + S_HF + S_HW + S_HB;

reg     [31:0] v, st, fn0, fn1;
integer        k, d, ln, ml0, ml1, rb0, rb1;
integer        n_vb0, n_vb1, n_rb0, n_rb1, n_lines;
reg     [S_VT-1:0] seen;
integer        last0, first1, s, nr;
// The flags follow the driver's scan, which leads the panel pins by the output
// pipeline (6 pixels at CLK_DIV 1); the read and the crossing add a pixel or two
localparam integer FL_EARLY = 8, FL_LATE = 4;

// Line distance a - b modulo the frame, in -S_VT/2 .. S_VT/2
function integer ldist;
   input integer a, b;
   integer       dd;
   begin
      dd = (a - b) % S_VT;
      if (dd < 0) dd = dd + S_VT;
      if (dd > S_VT / 2) dd = dd - S_VT;
      ldist = dd;
   end
endfunction

// Line l has a pixel in the frame positions a..b (pixels from the start of
// line 0, any sign: taken modulo the frame)
function line_ok;
   input integer l, a, b;
   integer       p;
   reg           ok;
   begin
      ok = 1'b0;
      for (p = a; p <= b; p = p + 1)
         if ((((p % (S_VT*S_LT)) + S_VT*S_LT) % (S_VT*S_LT)) / S_LT == l) ok = 1'b1;
      line_ok = ok;
   end
endfunction

// Wait until the panel model is in line l
task wait_line;
   input integer l;
   integer       nc;
   begin
      nc = 0;
      while ((u_dpipanel.vline != l) && (nc < 200000)) begin @(posedge free_clk); nc = nc + 1; end
      if (u_dpipanel.vline != l) tb_error("panel model never reached the line waited for");
   end
endtask

// Pixels from the start of panel line l to where the panel model is now
// (negative: before it)
function integer px_from;
   input integer l;
   integer       r, lref;
   begin
      r   = u_dpipanel.px - u_dpipanel.ls_px;                // < 0: in the back porch before the next line
      lref = (r < 0) ? u_dpipanel.vline + 1 : u_dpipanel.vline;
      px_from = r + ldist(lref, l) * S_LT;
   end
endfunction

// Where the panel model is now: pixels from the start of line 0
function integer pos_now;
   input integer dummy;
   integer       r, lref;
   begin
      r   = u_dpipanel.px - u_dpipanel.ls_px;
      lref = (r < 0) ? u_dpipanel.vline + 1 : u_dpipanel.vline;
      pos_now = lref * S_LT + r;
   end
endfunction

// Poll DIF_IRQ_FLAG for one flag from line `from` of the panel: where the
// panel was (pixels from the start of line l) at the start of the first read
// that shows the flag (first1) and at the end of the last that does not (last0)
task flag_at;
   input [31:0]  flag;
   input integer from, l;
   integer       p0, p1, done;
   begin
      wait_line(from);
      reg_wr(DIF_IRQ_FLAG, flag);
      last0 = -99999; first1 = 99999; nr = 0; done = 0;
      while (!done && (nr < 20000)) begin
         p0 = px_from(l);
         reg_rd_val(DIF_IRQ_FLAG, v);
         p1 = px_from(l);
         if (v & flag) begin first1 = p0; done = 1; end
         else          last0 = p1;
         nr = nr + 1;
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: STATUS, FLAGS AND FRAMES          |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      dpi_frame_fill(16, 8, 5);
      dpi_timing(dpi_div(1), S_HA, S_HF, S_HW, S_HB, S_VA, S_VF, S_VW, S_VB);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);                            // LCD_ON, DPI_EN
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(1);

      //------------------------------------------------------------------
      $display("--- A. LINE, VBLANK and REFRESH_BUSY while the panel is scanned");
      n_vb0 = 0; n_vb1 = 0; n_rb0 = 0; n_rb1 = 0; seen = 0;
      for (k = 0; k < 400; k = k + 1) begin
         d = $urandom(tmp_seed) % 61;
         tmp_seed = tmp_seed + 1;
         repeat (d) @(posedge free_clk);
         ml0 = pos_now(0); rb0 = dut.refresh_active;
         reg_rd_val(DIF_STATUS, st);
         ml1 = pos_now(0); rb1 = dut.refresh_active;
         if (ml1 < ml0) ml1 = ml1 + S_VT * S_LT;
         ln = st[28:16];
         if ((st & 32'hE000_FE76) != 0) begin
            $display("ERROR: DIF_STATUS 0x%h has reserved bits set %t", st, $time); error = error + 1;
         end
         if (!st[0]) begin
            $display("ERROR: DIF_STATUS BUSY 0 while running %t", $time); error = error + 1;
         end
         if (ln >= S_VT) begin
            $display("ERROR: DIF_STATUS LINE %0d past the frame (%0d lines) %t", ln, S_VT, $time); error = error + 1;
         end else begin
            seen[ln] = 1'b1;
            // a pixel of line LINE lies between FL_LATE pixels before the
            // panel's position at the start of the read and FL_EARLY after
            // its position at the end (pixels from the start of line 0)
            if (!line_ok(ln, ml0 - FL_LATE, ml1 + FL_EARLY)) begin
               $display("ERROR: DIF_STATUS LINE %0d, the panel at pixel %0d..%0d of the frame (%0d per line) %t",
                        ln, ml0, ml1, S_LT, $time);
               error = error + 1;
            end
         end
         if (st[7] !== (ln >= S_VA)) begin
            $display("ERROR: DIF_STATUS VBLANK %b with LINE %0d (V_ACT %0d) %t", st[7], ln, S_VA, $time); error = error + 1;
         end
         if ((st[3] != rb0) && (st[3] != rb1)) begin
            $display("ERROR: DIF_STATUS REFRESH_BUSY %b, the BDI frame activity %0d..%0d %t", st[3], rb0, rb1, $time); error = error + 1;
         end
         if (st[7]) n_vb1 = n_vb1 + 1; else n_vb0 = n_vb0 + 1;
         if (st[3]) n_rb1 = n_rb1 + 1; else n_rb0 = n_rb0 + 1;
      end
      n_lines = 0;
      for (k = 0; k < S_VT; k = k + 1) if (seen[k]) n_lines = n_lines + 1;
      $display("INFO:  %0d of %0d lines read, VBLANK 0/1 %0d/%0d, REFRESH_BUSY 0/1 %0d/%0d",
               n_lines, S_VT, n_vb0, n_vb1, n_rb0, n_rb1);
      if ((n_vb0 == 0) || (n_vb1 == 0) || (n_rb0 == 0) || (n_rb1 == 0) || (n_lines < S_VT - 3))
         tb_error("A: the status reads did not cover the frame");

      //------------------------------------------------------------------
      $display("--- B. LINE flag at line SCANLINE, VBLANK flag at the blanking start");
      for (k = 0; k < 6; k = k + 1) begin
         case (k)
            0: s = 0;
            1: s = 7;
            2: s = S_VA - 1;
            3: s = S_VA;
            4: s = S_VT - 1;
            default: s = 13;
         endcase
         reg_wr(DIF_SYNC, s);
         reg_wr(DPI_CTRL, 32'h1);
         reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
         reg_rd(DIF_SYNC, s);
         flag_at(32'h10, (s + S_VT - 4) % S_VT, s);
         $display("INFO:  SCANLINE %0d: flag clear %0d, set %0d pixels from the line start", s, last0, first1);
         if ((first1 < -FL_EARLY) || (first1 > FL_LATE)) begin
            $display("ERROR: LINE flag for SCANLINE %0d set %0d pixels from the line start %t", s, first1, $time);
            error = error + 1;
         end
      end
      flag_at(32'h08, S_VA - 4, S_VA);
      $display("INFO:  VBLANK flag: clear %0d, set %0d pixels from the first blanking line", last0, first1);
      if ((first1 < -FL_EARLY) || (first1 > FL_LATE)) begin
         $display("ERROR: VBLANK flag set %0d pixels from the first blanking line %t", first1, $time);
         error = error + 1;
      end

      //------------------------------------------------------------------
      $display("--- C. driver interrupt: only enabled flags");
      reg_wr(IRQ_EN, 32'h0000_0100);                         // DIF
      reg_wr(DIF_IRQ_EN, 32'h20);                            // UNDERFLOW only (none here)
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      dpi_wait_frames(2);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h18, 32'h38);             // LINE and VBLANK set, no UNDERFLOW
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h100);
      if (irq !== 1'b0) tb_error("C: a flag that is not enabled raised irq_o");
      reg_wr(DIF_IRQ_EN, 32'h10);                            // LINE
      reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
      if (irq !== 1'b1) tb_error("C: the enabled LINE flag does not reach irq_o");
      reg_wr(DIF_IRQ_EN, 32'h08);                            // VBLANK
      reg_rd_mask(IRQ_FLAG, 32'h100, 32'h100);
      if (irq !== 1'b1) tb_error("C: the enabled VBLANK flag does not reach irq_o");
      reg_wr(DIF_IRQ_EN, 32'h40);                            // DETECT only
      reg_wr(DIF_IRQ_FLAG, 32'h40);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h100);
      if (irq !== 1'b0) tb_error("C: LINE / VBLANK with only DETECT enabled raised irq_o");
      reg_wr(DIF_IRQ_EN, 32'h0);
      reg_wr(IRQ_EN, 32'h0);
      reg_wr(DIF_IRQ_FLAG, 32'h78);

      //------------------------------------------------------------------
      $display("--- D. FRAME_CNT counts the panel frames; REFRESH START");
      reg_wr(IRQ_FLAG, 32'h7);
      wait_line(5);
      reg_wr(FRAME_CNT, 32'd3);
      for (k = 2; k >= 0; k = k - 1) begin
         dpi_wait_frames(1);
         wait_line(2);
         reg_rd(FRAME_CNT, k);
         reg_rd_mask(IRQ_FLAG, (k == 0) ? 32'h4 : 32'h0, 32'h4);
      end
      reg_wr(IRQ_FLAG, 32'h4);
      dpi_wait_frames(1);
      reg_rd(FRAME_CNT, 32'h0);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h4);                   // 0 stays 0, no new event
      // START written while a frame is being taken: it stays set to the end
      // of that frame and of the whole next one, then clears
      wait_line(5);
      if (dut.refresh_active !== 1'b1) tb_error("D: no frame being taken at line 5");
      reg_wr(REFRESH, 32'h1);                                // manual START
      reg_rd_mask(REFRESH, 32'h1, 32'h1);
      @(negedge dut.refresh_active);                         // the frame in progress ends
      repeat (8) @(posedge free_clk);
      reg_rd_mask(REFRESH, 32'h1, 32'h1);
      @(posedge dut.refresh_active);                         // the next frame
      repeat (8) @(posedge free_clk);
      reg_rd_mask(REFRESH, 32'h1, 32'h1);
      @(negedge dut.refresh_active);                         // taken
      reg_poll(REFRESH, 32'h1, 32'h0, 4);
      if (u_dpipanel.errors != 0) tb_error("D: panel timing errors with a REFRESH request");

      //------------------------------------------------------------------
      $display("--- E. debug freeze: the panel goes on, FRAME_CNT holds");
      reg_wr(DBG_CTRL, 32'h1);                               // FREEZE_REFRESH
      wait_line(5);
      reg_wr(FRAME_CNT, 32'd2);
      reg_wr(IRQ_FLAG, 32'h7);
      dbg_stoptime = 1'b1;
      reg_rd_val(FRAME_NUM, fn0);
      dpi_wait_frames(3);
      reg_rd_val(FRAME_NUM, fn1);
      if (((fn1 - fn0) & 32'hFFFF) < 3) tb_error("E: FRAME_NUM did not count during the freeze");
      reg_rd(FRAME_CNT, 32'd2);                              // held
      reg_rd_mask(IRQ_FLAG, 32'h3, 32'h7);                   // REFR_START / REFR_DONE, no FRAME_CNT_DONE
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "frozen: the panel is refreshed");
      if (u_dpipanel.errors != 0) tb_error("E: panel timing errors during the freeze");
      wait_line(5);
      dbg_stoptime = 1'b0;                                   // resume: counts again
      dpi_wait_frames(2);
      wait_line(2);
      reg_rd(FRAME_CNT, 32'd0);
      reg_rd_mask(IRQ_FLAG, 32'h4, 32'h4);
      // the stop-time signal alone (DBG_CTRL 0) holds nothing
      reg_wr(DBG_CTRL, 32'h0);
      wait_line(5);
      reg_wr(FRAME_CNT, 32'd1);
      reg_wr(IRQ_FLAG, 32'h7);
      dbg_stoptime = 1'b1;
      dpi_wait_frames(1);
      wait_line(2);
      reg_rd(FRAME_CNT, 32'd0);
      reg_rd_mask(IRQ_FLAG, 32'h4, 32'h4);
      dbg_stoptime = 1'b0;
      // DBG_CTRL alone (no stop time) holds nothing
      reg_wr(DBG_CTRL, 32'h1);
      wait_line(5);
      reg_wr(FRAME_CNT, 32'd1);
      reg_wr(IRQ_FLAG, 32'h7);
      dpi_wait_frames(1);
      wait_line(2);
      reg_rd(FRAME_CNT, 32'd0);
      reg_rd_mask(IRQ_FLAG, 32'h4, 32'h4);
      reg_wr(DBG_CTRL, 32'h0);
      reg_wr(IRQ_FLAG, 32'h7);

      //------------------------------------------------------------------
      $display("--- F. an image larger than the active area: cut from its top-left");
      u_dpipanel.check = 1'b0;
      dpi_timing(dpi_div(1), 12, S_HF, S_HW, S_HB, 6, S_VF, S_VW, S_VB);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 0, 0, 4096, 4096, 0, 24'h0, "16 x 8 on 12 x 6, centred: from the corner");
      reg_wr(DPI_IMG_POS, (1 << 16) | 2);
      reg_wr(DPI_CTRL, 32'h1);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 2, 1, 4096, 4096, 0, 24'h0, "16 x 8 on 12 x 6 at 2,1: cropped");
      reg_wr(DPI_IMG_POS, 32'h8000_0000);

      //------------------------------------------------------------------
      $display("--- G. stop while a frame is taken: abandoned");
      wait (dut.refresh_active === 1'b1);
      repeat (20) @(posedge free_clk);
      reg_wr(IRQ_FLAG, 32'h7);
      reg_rd_val(FRAME_NUM, fn0);
      u_dpipanel.check = 1'b0;
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v & ~32'h8);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000 * PCLK_SLOW);
      reg_rd_mask(STATUS, 32'h10, 32'h11);                   // REFR_ABANDONED, no frame active
      reg_rd_mask(IRQ_FLAG, 32'h1, 32'h1);                   // REFR_DONE for it
      reg_rd_val(FRAME_NUM, fn1);
      if (((fn1 - fn0) & 32'hFFFF) != 1) tb_error("G: FRAME_NUM does not count the abandoned frame");
      reg_wr(IRQ_FLAG, 32'h7);

      if (u_dpipanel.blank_checks == 0) tb_error("panel model made no blanking measurement");
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      u_dpipanel.check = 1'b0;
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
