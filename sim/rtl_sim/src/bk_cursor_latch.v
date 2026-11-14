//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_cursor_latch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_cursor_latch.v
// Module Description : Hardware cursor latch, on the BDI pixel stream
//                      (DIF_TYPE = 0, slow random back-pressure so that a
//                      frame spans many register writes):
//                        - CURSOR_POS, CURSOR_CTRL (EN, hotspot) and
//                          CURSOR_ADDR written during a frame: that frame
//                          shows the values it started with, the next frame
//                          the new ones (a shape switched by its block
//                          without a torn frame), at several points of the
//                          frame (before, inside and after the cursor lines);
//                        - the colours are live: a CURSOR_COL1 write during a
//                          frame switches the colour once, at some pixel,
//                          from the old to the new (every other pixel exact);
//                        - frames abandoned by the driver at several pixel
//                          counts (cursor reads in flight), each followed by
//                          an exact frame;
//                        - the debug freeze: FREEZE_REFRESH and FREEZE_GPU with
//                          the core halted do not stop the cursor.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

localparam integer CL_BLK0 = 640;
localparam integer CL_BLK1 = 768;
localparam integer CL_W    = 40;
localparam integer CL_H    = 30;

reg     [23:0] cl_old [0:CL_W*CL_H-1];
integer        cl_i, cl_k, cl_at, cl_nf, cl_bad, cl_sw, cl_amb;
reg     [64*8-1:0] cl_tag;

// Start a frame, wait until the driver has taken 'at' pixels
task cl_start;
   input integer at;
   integer       cc;
   begin
      bkm_exp_n = CL_W * CL_H;
      cl_nf     = bkm_frames;
      reg_wr(REFRESH, 32'h0000_0001);
      cc = 0;
      while (((bkm_n < at) || (bkm_state != 2)) && (cc < 200000)) begin @(posedge free_clk); cc = cc + 1; end
   end
endtask

task cl_finish;
   begin
      bkm_wait_frames(cl_nf + 1, 400000);
      reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        HARDWARE CURSOR: FRAME LATCH           |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en          = 1'b1;
      bk_chk_reads    = 1'b1;
      bkm_rdy_mode    = 1;
      bkm_rdy_pct_low = 60;
      bk_vram_rand(0, 640);
      bk_cursor_shape(CL_BLK0, 0);
      bk_cursor_shape(CL_BLK1, 0);
      bk_cursor_cols(24'hFF0000, 24'h00FF00, 24'h0000FF);
      bk_config(0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);

      //------------------------------------------------------------------
      // POS / CTRL / ADDR written mid-frame: applied at the next frame
      //------------------------------------------------------------------
      for (cl_k = 0; cl_k < 4; cl_k = cl_k + 1) begin
         case (cl_k)
           0 : cl_at = 10;                  // before the cursor lines
           1 : cl_at = 9 * CL_W + 5;        // inside them
           2 : cl_at = 27 * CL_W;           // after them
           default : cl_at = 1;
         endcase
         bk_cursor_set(1'b1, 6 + cl_k, 4 + cl_k, 0, 0, CL_BLK0);
         bk_frame("latch: start", 0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
         cl_start(cl_at);
         // the registers change, the bench's copy after this frame
         reg_wr(CURSOR_POS,  {16'd20, 16'd25});
         reg_wr(CURSOR_CTRL, (cl_k == 3) ? 32'h0000_0000 : 32'h0003_0201);
         reg_wr(CURSOR_ADDR, CL_BLK1);
         cl_finish;
         bkr_build(3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
         $sformat(cl_tag, "latch: frame with the writes after pixel %0d", cl_at);
         bkr_check_bdi(cl_tag);
         if (bk_chk_reads && (bkm_vreads != bkr_runs)) begin
            $display("ERROR: %0s -- %0d VRAM reads / expected %0d %t", cl_tag, bkm_vreads, bkr_runs, $time);
            error = error + 1;
         end
         bkr_cur_en = (cl_k != 3); bkr_cur_x = 25; bkr_cur_y = 20; bkr_cur_hx = 2; bkr_cur_hy = 3; bkr_cur_blk = CL_BLK1;
         bk_frame("latch: the next frame", 0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
      end

      //------------------------------------------------------------------
      // Colours live: one switch from the old colour to the new
      //------------------------------------------------------------------
      bk_cursor_set(1'b1, 2, 0, 0, 0, CL_BLK0);
      bk_cursor_cols(24'hFF0000, 24'h00FF00, 24'h0000FF);
      bk_frame("colours: before", 0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
      cl_start(14 * CL_W);
      reg_wr(CURSOR_COL1, 32'h0055_AA33);
      cl_finish;
      bkr_build(3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
      for (cl_i = 0; cl_i < bkr_n; cl_i = cl_i + 1) cl_old[cl_i] = bkr_exp[cl_i];
      bkr_cur_col1 = 24'h55AA33;
      bkr_build(3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
      cl_bad = 0; cl_sw = 0; cl_amb = 0;
      tb_checks = tb_checks + 1;
      if (bkm_n != bkr_n) tb_error("colours: pixel count");
      for (cl_i = 0; (cl_i < bkr_n) && (cl_i < bkm_n); cl_i = cl_i + 1)
         if (cl_old[cl_i] !== bkr_exp[cl_i]) begin              // a colour-1 pixel
            cl_amb = cl_amb + 1;
            if (bkm_px[cl_i] === bkr_exp[cl_i]) cl_sw = 1;
            else if ((bkm_px[cl_i] !== cl_old[cl_i]) || cl_sw) cl_bad = cl_bad + 1;
         end else if (bkm_px[cl_i] !== bkr_exp[cl_i]) cl_bad = cl_bad + 1;
      if ((cl_bad != 0) || !cl_sw) begin
         $display("ERROR: colours: %0d pixels wrong or switched back, switch seen %0d (%0d colour-1 pixels) %t", cl_bad, cl_sw, cl_amb, $time);
         error = error + 1;
      end else
         $display("OK:    colours: CURSOR_COL1 switched once during the frame (%0d colour-1 pixels)", cl_amb);
      bk_frame("colours: the next frame", 0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);

      //------------------------------------------------------------------
      // Abandoned frames, then an exact one
      //------------------------------------------------------------------
      bk_chk_reads = 1'b0;
      for (cl_k = 0; cl_k < 6; cl_k = cl_k + 1) begin
         bk_cursor_set(1'b1, (cl_k == 5) ? -3 : 1, (cl_k == 5) ? -2 : 0, 0, 0, cl_k[0] ? CL_BLK1 : CL_BLK0);
         case (cl_k)
           0 : bkm_abort_at = 1;
           1 : bkm_abort_at = 2;
           2 : bkm_abort_at = 33;
           3 : bkm_abort_at = CL_W + 3;
           4 : bkm_abort_at = 400;
           default : bkm_abort_at = 5;
         endcase
         bkm_exp_n = 0;
         cl_nf = bkm_frames;
         reg_wr(REFRESH, 32'h0000_0001);
         bkm_wait_frames(cl_nf + 1, 200000);
         reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
         bkm_abort_at = 0;
         $sformat(cl_tag, "after a frame abandoned at pixel %0d", (cl_k == 0) ? 1 : (cl_k == 1) ? 2 : (cl_k == 2) ? 33 :
                                                                  (cl_k == 3) ? CL_W + 3 : (cl_k == 4) ? 400 : 5);
         bk_frame(cl_tag, 0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
      end
      bk_chk_reads = 1'b1;

      //------------------------------------------------------------------
      // Debug freeze: the refresh and its cursor go on
      //------------------------------------------------------------------
      reg_wr(DBG_CTRL, 32'h0000_0003);
      dbg_stoptime = 1'b1;
      bk_cursor_set(1'b1, 17, 9, 4, 4, CL_BLK0);
      bk_frame("FREEZE_REFRESH / FREEZE_GPU with the core halted", 0, 3, 3'd4, CL_W, CL_H, 3'b000, 32'h0000_F000);
      dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0000_0000);

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
