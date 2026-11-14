//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_reg_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_reg_walk.v
// Module Description : DPI / HDMI register walk: every staged field taken by
//                      the pixel side with all ones, then 0101... and
//                      1010... patterns, so that every bit of the staged and
//                      the applied copies changes both ways.
//                       A. Stopped driver: DIF_CFG [31:8], DIF_SYNC, the
//                          timing registers, DPI_IMG_*, DPI_SCALE,
//                          DPI_BORDER, DPI_CTRL.TEST and DIF_IRQ_EN written
//                          with the pattern, DPI_EN set (the start takes
//                          them, extreme timing included): every register
//                          reads the pattern under the documented mask, the
//                          driver runs (UPDATE 0, BUSY), and DIF_STATUS reads
//                          LINE = V_ACT with VBLANK (the scan starts at the
//                          first blanking line); then stopped, without
//                          waiting for a frame.
//                       B. HDMI (DPI_ISLAND_EN): DPI_HDMI fields, and with
//                          DPI_AUDIO_EN DPI_AUD and DPI_PKT0-7 (walking
//                          one too), written with GP and AUD clear and taken
//                          by a running driver with UPDATE, the I2S source on.
//                       C. Ordinary settings again: the image is exact.
//----------------------------------------------------------------------------

`define LONG_TIMEOUT
`include "dpi_tasks.v"

reg     [31:0] v, p, filt, hmask, pkt;
integer        k, i, b;

function [31:0] pat;
   input integer n;
   case (n)
      0:       pat = 32'hFFFF_FFFF;
      1:       pat = 32'h5555_5555;
      2:       pat = 32'hAAAA_AAAA;
      default: pat = 32'h5555_5555;
   endcase
endfunction

// DPI_PKTi for pattern p of step k. The header type HB0 keeps away from the
// packet types the receiver model decodes (clock regeneration 0x01, audio
// sample 0x02): the walking one runs on it with its top four bits inverted
function [31:0] pkt_word;
   input integer i;
   input [31:0]  p;
   input integer k;
   begin
      if (i == 0) pkt_word = {8'h00, p[23:8], (k < 4) ? p[7:0] : (p[7:0] ^ 8'hF0)};
      else        pkt_word = p ^ (i * 32'h0101_0101);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        DPI: REGISTER WALK                     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      filt  = (DPI_SCALER == 2) ? 32'h0020_0000 : 32'h0;
      dpi_frame_fill(16, 8, 1);

      //------------------------------------------------------------------
      $display("--- A. staged fields taken by a start, extreme values included");
      for (k = 0; k < 4; k = k + 1) begin
         p = pat(k);
         reg_wr(DIF_CFG,      p & 32'h003F_0F03);           // DPI_EN 0
         reg_wr(DIF_SYNC,     p);
         reg_wr(DPI_H_ACT,    p);
         reg_wr(DPI_H_BLANK,  p);
         reg_wr(DPI_V_ACT,    p);
         reg_wr(DPI_V_BLANK,  p);
         reg_wr(DPI_IMG_SIZE, p);
         reg_wr(DPI_IMG_POS,  p);
         reg_wr(DPI_SCALE,    p);
         reg_wr(DPI_BORDER,   p);
         reg_wr(DPI_CTRL,     p & 32'h2);                    // TEST (UPDATE: no effect while off)
         reg_wr(DIF_IRQ_EN,   p);
         reg_rd_val(DIF_CFG, v);
         reg_wr(DIF_CFG, v | 32'h8);                         // start: takes the staged values
         reg_poll(DPI_CTRL, 32'h1, 32'h0, 2000);             // the driver runs
         reg_rd_val(DIF_STATUS, v);
         if ((v & 32'h1FFF_0081) !== ({3'd0, p[12:0] & 13'h0FFF, 16'h0} | 32'h81)) begin
            $display("ERROR: pattern %0d: DIF_STATUS 0x%h after the start, expected LINE %0d (V_ACT), VBLANK, BUSY %t",
                     k, v, p & 32'hFFF, $time);
            error = error + 1;
         end
         reg_rd(DIF_CFG,      (p & (32'h001F_0F03 | filt)) | 32'h8);
         reg_rd(DIF_SYNC,     p & 32'h0000_1FFF);
         reg_rd(DPI_H_ACT,    p & 32'h0000_0FFF);
         reg_rd(DPI_H_BLANK,  p & 32'h3FFF_FFFF);
         reg_rd(DPI_V_ACT,    p & 32'h0000_0FFF);
         reg_rd(DPI_V_BLANK,  p & 32'h3FFF_FFFF);
         reg_rd(DPI_IMG_SIZE, (DPI_SCALER != 0) ? (p & 32'h0FFF_0FFF) : 32'h0);
         reg_rd(DPI_IMG_POS,  p & 32'h8FFF_0FFF);
         reg_rd(DPI_SCALE,    (DPI_SCALER != 0) ? p : 32'h0);
         reg_rd(DPI_BORDER,   p & 32'h00FF_FFFF);
         reg_rd(DPI_CTRL,     p & 32'h2);
         reg_rd(DIF_IRQ_EN,   p & 32'h78);
         reg_wr(DIF_SYNC, ~p);                               // running, no UPDATE pending: accepted
         reg_rd(DIF_SYNC, ~p & 32'h0000_1FFF);
         reg_wr(DIF_SYNC, p);
         reg_rd_val(DIF_CFG, v);
         reg_wr(DIF_CFG, v & ~32'h8);                        // stop before any frame
         reg_poll(DIF_STATUS, 32'h1, 32'h0, 2000 * PCLK_SLOW);
         reg_wr(DIF_IRQ_EN, 32'h0);
         reg_wr(DIF_IRQ_FLAG, 32'h78);
      end

      //------------------------------------------------------------------
      if (HAS_ISLAND) begin
         $display("--- B. HDMI fields taken by a running driver");
         hmask = HAS_AUDIO ? 32'h007F_0F3F : 32'h007F_0F33;
         reg_wr(DPI_BORDER, 32'h0);
         reg_wr(DPI_IMG_POS, 32'h8000_0000);
         reg_wr(DPI_IMG_SIZE, 32'h0);
         reg_wr(DPI_SCALE, 32'h0);
         reg_wr(DPI_CTRL, 32'h0);
         reg_wr(DIF_SYNC, 32'h0);
         reg_wr(DIF_CFG, 32'h0);
         dpi_timing(0, 40, 8, 8, 90, 20, 2, 2, 2);           // blanking 106: islands of two packets
         reg_wr(DPI_HDMI, 32'h0);
         reg_wr(DIF_CFG, 32'h9);
         reg_poll(DPI_CTRL, 32'h1, 32'h0, 2000);
         if (HAS_AUDIO) begin
            u_i2s.half = ((DPI_PCLK_SEP != 0) && (PCLK_HALF != 73)) ? 30.0 * (2.0 * dpi_pclk_half) / 14.6 : 30.0;
            u_i2s.slot = 32; u_i2s.run = 1'b1;
         end
         for (k = 0; k < 4 + (HAS_AUDIO ? 32 : 0); k = k + 1) begin
            p = (k < 4) ? pat(k) : (32'h1 << (k - 4));       // then a walking one
            reg_wr(DPI_HDMI, 32'h0);                         // GP and AUD clear
            reg_wr(DPI_CTRL, 32'h1);
            reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
            if (HAS_AUDIO) begin
               reg_poll(DPI_AUD_ST, 32'h0200_0000, 32'h0, 2000 * PCLK_SLOW);   // ACTIVE 0
               dpi_wait_frames(1);
               reg_wr(DPI_AUD, p);
               reg_rd(DPI_AUD, p & 32'hFF0F_FF80);
               for (i = 0; i < 8; i = i + 1) begin
                  pkt = pkt_word(i, p, k);
                  reg_wr(DPI_PKT0 + 4*i, pkt);
               end
            end
            reg_wr(DPI_HDMI, 32'h0000_000F | (p & hmask));   // HDMI, AVI, AUD, GP and the fields
            reg_rd(DPI_HDMI, (32'h0000_000F | p) & hmask);
            reg_wr(DPI_CTRL, 32'h1);                         // the AVI fields at UPDATE
            reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
            dpi_wait_frames(2);
            if (HAS_AUDIO) begin
               for (i = 0; i < 8; i = i + 1) begin
                  pkt = pkt_word(i, p, k);
                  reg_wr(DPI_PKT0 + 4*i, ~pkt);              // read only while GP is set
                  reg_rd(DPI_PKT0 + 4*i, pkt);
               end
               reg_rd_mask(DPI_AUD_ST, 32'h0200_0000, 32'h0200_0000);   // ACTIVE
            end
         end
         reg_wr(DPI_HDMI, 32'h0);
         reg_wr(DPI_CTRL, 32'h1);
         reg_poll(DPI_CTRL, 32'h1, 32'h0, 4000 * PCLK_SLOW);
         u_i2s.run = 1'b0;
         reg_wr(DIF_CFG, 32'h0);
         reg_poll(DIF_STATUS, 32'h1, 32'h0, 2000 * PCLK_SLOW);
      end

      //------------------------------------------------------------------
      $display("--- C. ordinary settings again");
      reg_wr(DPI_BORDER, 32'h0);
      reg_wr(DPI_IMG_POS, 32'h8000_0000);
      reg_wr(DPI_IMG_SIZE, 32'h0);
      reg_wr(DPI_SCALE, 32'h0);
      reg_wr(DPI_CTRL, 32'h0);
      reg_wr(DIF_SYNC, 32'h0);
      reg_wr(DIF_CFG, 32'h0);
      dpi_timing(dpi_div(1), 40, 3, 2, 6, 20, 2, 1, 2);
      reg_wr(DIF_IRQ_FLAG, 32'h78);
      reg_rd_val(DIF_CFG, v);
      reg_wr(DIF_CFG, v | 32'h9);
      reg_poll(DPI_CTRL, 32'h1, 32'h0, 2000);
      dpi_wait_frames(2);
      u_dpipanel.check = 1'b1;
      dpi_wait_frames(2);
      dpi_check_image(16, 8, 16, 8, 12, 6, 4096, 4096, 0, 24'h0, "frames after the walk");
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h20);               // no UNDERFLOW
      if (u_dpipanel.errors != 0) tb_error("DPI panel model saw timing errors");
      u_dpipanel.check = 1'b0;
      reg_wr(DIF_CFG, 32'h0);
      reg_poll(DIF_STATUS, 32'h9, 32'h0, 2000 * PCLK_SLOW);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
