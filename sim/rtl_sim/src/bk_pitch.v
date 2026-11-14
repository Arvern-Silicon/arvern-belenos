//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_pitch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_pitch.v
// Module Description : Refresh line pitch (REFR_PITCH), checked on the BDI
//                      pixel stream (DIF_TYPE = 0, random back-pressure)
//                      against the backend model: the register (16 bits, RW,
//                      reset 0); every DISP_CFG combination x every bpp with a
//                      pitch wider than the frame (odd, word-aligned and
//                      sub-word bases), a pitch narrower than the frame
//                      (overlapping lines), the largest pitch; a window of a
//                      wider surface scrolled by moving the frame pointer one
//                      line and one pixel at a time; a pitch written during a
//                      frame taken only at the next frame start; pitch 0 =
//                      the frame width again. Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`include "bk_bdi_model.v"
`include "bk_ref.v"

integer    pt_c, pt_m, pt_s, pt_p, pt_w, pt_h, pt_base, pt_k;
reg [64*8-1:0] pt_tag;

task pt_frame;
   input [64*8-1:0] tag;
   input integer    base, mode, w, h, cfg, pitch;
   begin
      reg_wr(REFR_PITCH, pitch);
      bkr_pitch = pitch;
      bk_frame(tag, 0, base, mode[2:0], w, h, cfg[2:0], 32'h0000_7C40);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        BACKEND: REFRESH LINE PITCH            |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      reg_rd(REFR_PITCH, 32'h0);
      reg_wr(REFR_PITCH, 32'hFFFF_ABCD);
      reg_rd(REFR_PITCH, 32'h0000_ABCD);
      reg_wr(REFR_PITCH, 32'h0);

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 1;
      bkm_rdy_pct_low = 20;
      bk_vram_rand(0, 1024);

      // wider pitch, every orientation and depth
      for (pt_c = 0; pt_c < 8; pt_c = pt_c + 1)
        for (pt_m = 0; pt_m < 5; pt_m = pt_m + 1)
          for (pt_s = 0; pt_s < 3; pt_s = pt_s + 1) begin
             case (pt_s)
               0 : begin pt_w = 5;  pt_h = 3; pt_p = 13; end
               1 : begin pt_w = 9;  pt_h = 4; pt_p = 32; end
               default : begin pt_w = 3; pt_h = 6; pt_p = 4; end
             endcase
             pt_base = (pt_s == 1) ? 0 : (3 + 2*pt_c);
             $sformat(pt_tag, "pitch %0d cfg %0d mode %0d %0dx%0d base %0d", pt_p, pt_c, pt_m, pt_w, pt_h, pt_base);
             pt_frame(pt_tag, pt_base, pt_m, pt_w, pt_h, pt_c, pt_p);
          end

      // narrower pitch than the frame: overlapping lines
      for (pt_c = 0; pt_c < 8; pt_c = pt_c + 1)
         pt_frame("pitch 3 < width 7 (overlapping lines)", 5, 3, 7, 4, pt_c, 3);

      // the largest pitch at 1 bpp (65535 pixels, 2048 words a line)
      if (VRAM_WORDS >= 8 * 2048)
         for (pt_c = 0; pt_c < 8; pt_c = pt_c + 2)
            pt_frame("pitch 65535 at 1 bpp", 7, 0, 9, 3, pt_c, 65535);

      // a 12 x 6 window of a 40-pixel-wide surface, scrolled by the frame pointer
      for (pt_k = 0; pt_k < 6; pt_k = pt_k + 1) begin
         $sformat(pt_tag, "scroll step %0d", pt_k);
         pt_frame(pt_tag, 200 + 40*pt_k + pt_k, 3, 12, 6, 0, 40);
      end

      // a pitch written during a frame is taken at the next frame start
      reg_wr(REFR_PITCH, 21);
      bkr_pitch = 21;
      bk_config(0, 16, 3'd3, 10, 30, 3'b000, 32'h0000_7C40);
      bkm_exp_n = 10*30;
      pt_k      = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      wait (bdi_refresh_active_d === 1'b1);
      reg_wr(REFR_PITCH, 33);                        // during the frame
      bkm_wait_frames(pt_k + 1, 2000 + 60*10*30);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
      bkr_build(16, 3'd3, 10, 30, 3'b000, 32'h0000_7C40);
      bkr_check_bdi("pitch written during a frame: not taken");
      bkr_pitch = 33;
      bk_refresh(10*30);
      bkr_build(16, 3'd3, 10, 30, 3'b000, 32'h0000_7C40);
      bkr_check_bdi("... taken at the next frame start");

      // pitch 0: the frame width again
      pt_frame("pitch 0 = width", 9, 4, 6, 5, 3, 0);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
