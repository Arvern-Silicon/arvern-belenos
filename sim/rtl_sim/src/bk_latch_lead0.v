//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      bk_latch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bk_latch.v
// Module Description : Per-frame latching of the backend configuration (uarch
//                      §8 / §13 "Backend", spec §6): frame pointer (FRAME_SEL
//                      and the FRAMEn_PTR value), GFX_MODE, DISP_CFG,
//                      DISP_SIZE and every LUT_CFG field (SW_LUT_EN,
//                      REFR_BANK, HW_PALETTE, HW_BG, HW_FG) are taken from the
//                      last cycle before bdi_refresh_active_i rises and frozen
//                      until it falls. Checked on the BDI pixel stream
//                      (DIF_TYPE = 0) for four configuration pairs A -> B and
//                      three change instants:
//                        0: B written while the A frame streams, after some
//                           pixels (BDI model holds ready low meanwhile);
//                        1: B written after active rose, before any pixel is
//                           taken (backend FIFO full, fetch stalled);
//                        2: B written between the trigger and the rise of
//                           active (BDI model delays the rise).
//                      0/1: the in-flight frame is A, the next one is B;
//                      2: the frame is B.
//                      Edge sweep: one register changed (FRAME_SEL,
//                      FRAME0_PTR, CTRL, DISP_SIZE, DISP_CFG, LUT_CFG) while
//                      the BDI model raises active on its own (no trigger)
//                      0..12 cycles later: every frame is entirely A or
//                      entirely B (never mixed), A when active rose before
//                      the write's address phase, B when it rose 2 or more
//                      cycles after the write completed.
//                      Skipped unless DIF_TYPE = 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "bk_bdi_model.v"
`include "bk_ref.v"

// configuration sets: [0] = A, [1] = B
integer    la_fsel [0:1];
integer    la_base [0:1];
reg  [2:0] la_mode [0:1];
integer    la_w    [0:1];
integer    la_h    [0:1];
reg  [2:0] la_cfg  [0:1];
reg [31:0] la_lut  [0:1];
integer    la_p, la_v, la_nf;
integer    le_r, le_o, le_a0, le_wc;
reg        le_ma, le_mb;
reg [31:0] le_addr, le_val;
reg [64*8-1:0] la_tag;

task la_write;
   input integer kk;
   begin
      reg_wr(FRAME0_PTR + 4*la_fsel[kk], la_base[kk]);
      reg_wr(FRAME_SEL,  la_fsel[kk]);
      reg_wr(CTRL,       {29'h0, la_mode[kk]});
      reg_wr(DISP_SIZE,  (la_h[kk] << 16) | la_w[kk]);
      reg_wr(DISP_CFG,   {29'h0, la_cfg[kk]});
      reg_wr(LUT_CFG,    la_lut[kk]);
   end
endtask

task la_expect;
   input integer kk;
   input [64*8-1:0] tag;
   begin
      bkr_build(la_base[kk], la_mode[kk], la_w[kk], la_h[kk], la_cfg[kk], la_lut[kk]);
      bkr_check_bdi(tag);
   end
endtask

task la_set_pair;
   input integer pp;
   begin
      case (pp)
        0 : begin   // pointer (same FRAME_SEL), 2 bpp HW palette / BG, size, swaps
               la_fsel[0] = 0; la_base[0] = 37;   la_mode[0] = 3'd1; la_w[0] = 12; la_h[0] = 6; la_cfg[0] = 3'b000; la_lut[0] = 32'h0000_3200;
               la_fsel[1] = 0; la_base[1] = 3001; la_mode[1] = 3'd1; la_w[1] = 7;  la_h[1] = 9; la_cfg[1] = 3'b110; la_lut[1] = 32'h0000_3550;
            end
        1 : begin   // FRAME_SEL, GFX_MODE, 1 bpp BG/FG -> 16 bpp
               la_fsel[0] = 0; la_base[0] = 64;   la_mode[0] = 3'd0; la_w[0] = 40; la_h[0] = 3; la_cfg[0] = 3'b001; la_lut[0] = 32'h0000_A500;
               la_fsel[1] = FRAME_NR - 1; la_base[1] = 1201; la_mode[1] = 3'd4; la_w[1] = 9; la_h[1] = 8; la_cfg[1] = 3'b011; la_lut[1] = 32'h0000_5A00;
            end
        2 : begin   // 4 bpp SW LUT, REFR_BANK 0 -> 1, CL swap off
               la_fsel[0] = 0; la_base[0] = 200;  la_mode[0] = 3'd2; la_w[0] = 16; la_h[0] = 5; la_cfg[0] = 3'b101; la_lut[0] = 32'h0000_F001;
               la_fsel[1] = 0; la_base[1] = 200;  la_mode[1] = 3'd2; la_w[1] = 16; la_h[1] = 5; la_cfg[1] = 3'b000; la_lut[1] = 32'h0000_F003;
            end
        default : begin   // 8 bpp SW LUT -> HW RGB332, mode 3 -> 1 bpp HW FG/BG
               la_fsel[0] = 0; la_base[0] = 330;  la_mode[0] = 3'd3; la_w[0] = 10; la_h[0] = 10; la_cfg[0] = 3'b010; la_lut[0] = 32'h0000_0003;
               la_fsel[1] = 0; la_base[1] = 330;  la_mode[1] = 3'd3; la_w[1] = 10; la_h[1] = 10; la_cfg[1] = 3'b010; la_lut[1] = 32'h0000_E772;
            end
      endcase
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|      BACKEND: PER-FRAME CONFIGURATION LATCH   |");
      $display(" ===============================================");
      @(posedge reset_done);
      bkm_busy_lead = 0;   // Q6 reproducer: busy raised with refresh_active

      if (DIF_TYPE != 0)
         tb_skip_finish("|      (BDI-direct test: needs DIF_TYPE = 0)    |");

      bkm_en       = 1'b1;
      bk_chk_reads = 1'b1;
      bkm_rdy_mode = 0;
      bk_vram_rand(0, 2048);
      bk_lut_rand;

      for (la_p = 0; la_p < 4; la_p = la_p + 1)
        for (la_v = 0; la_v < 3; la_v = la_v + 1) begin
           la_set_pair(la_p);
           la_write(0);
           la_nf = bkm_frames;
           if (la_v < 2) begin
              // A frame in flight, B written, A must complete
              bkm_hold  = (la_v == 1);
              bkm_exp_n = la_w[0] * la_h[0];
              reg_wr(REFRESH, 32'h0000_0001);
              if (la_v == 0) begin
                 bkm_wait_pixels(5, 2000);
                 bkm_hold = 1'b1;
              end else
                 bkm_wait_active(2000);
              repeat(20) @(posedge free_clk);
              la_write(1);
              repeat(5) @(posedge free_clk);
              if (bkm_frames != la_nf) tb_error("latch test: frame ended while held");
              bkm_hold = 1'b0;
              bkm_wait_frames(la_nf + 1, 20000);
              reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
              $sformat(la_tag, "pair %0d instant %0d: in-flight frame keeps A", la_p, la_v);
              la_expect(0, la_tag);
              // next frame uses B
              bk_refresh(la_w[1] * la_h[1]);
              $sformat(la_tag, "pair %0d instant %0d: next frame uses B", la_p, la_v);
              la_expect(1, la_tag);
           end else begin
              // B written between the trigger and the rise of active
              bkm_start_delay = 400;
              bkm_exp_n       = la_w[1] * la_h[1];
              reg_wr(REFRESH, 32'h0000_0001);
              la_write(1);
              if (bdi_refresh_active_drv !== 1'b0 || bkm_frames != la_nf)
                 tb_error("latch test: active rose before B was written (test timing)");
              bkm_wait_frames(la_nf + 1, 20000);
              reg_poll(REFRESH, 32'h0000_0001, 32'h0000_0000, 50);
              bkm_start_delay = 2;
              $sformat(la_tag, "pair %0d instant 2: written before the rise -> B", la_p);
              la_expect(1, la_tag);
           end
        end

      // Edge sweep: base A = sel 0, ptr 100, 4 bpp, 8x4, no swap, HW colours
      bkm_auto_trig = 1'b0;
      bkm_exp_n     = 0;
      reg_wr(FRAME1_PTR, 777);
      for (le_r = 0; le_r < 6; le_r = le_r + 1)
        for (le_o = 0; le_o < 13; le_o = le_o + 1)
          if ((le_r != 0) || (FRAME_NR > 1)) begin
             la_fsel[0] = 0; la_base[0] = 100; la_mode[0] = 3'd2; la_w[0] = 8; la_h[0] = 4; la_cfg[0] = 3'b000; la_lut[0] = 32'h0000_F000;
             la_fsel[1] = 0; la_base[1] = 100; la_mode[1] = 3'd2; la_w[1] = 8; la_h[1] = 4; la_cfg[1] = 3'b000; la_lut[1] = 32'h0000_F000;
             case (le_r)
               0 : begin la_fsel[1] = 1; la_base[1] = 777; le_addr = FRAME_SEL;  le_val = 1;     end
               1 : begin la_base[1] = 1555;                le_addr = FRAME0_PTR; le_val = 1555;  end
               2 : begin la_mode[1] = 3'd3;                le_addr = CTRL;       le_val = 3;     end
               3 : begin la_w[1] = 6; la_h[1] = 5;         le_addr = DISP_SIZE;  le_val = (5 << 16) | 6; end
               4 : begin la_cfg[1] = 3'b111;               le_addr = DISP_CFG;   le_val = 7;     end
               default : begin la_lut[1] = 32'h0000_F001;  le_addr = LUT_CFG;    le_val = 32'h0000_F001; end
             endcase
             la_write(0);
             la_nf = bkm_frames;
             le_a0 = bkm_cycle;
             bkm_start_delay = le_o;
             bkm_go_req      = 1'b1;
             reg_wr(le_addr, le_val);
             le_wc = bkm_cycle;
             bkm_wait_frames(la_nf + 1, 5000);
             bkr_build(la_base[0], la_mode[0], la_w[0], la_h[0], la_cfg[0], la_lut[0]);
             le_ma = bkr_match(1'b0);
             bkr_build(la_base[1], la_mode[1], la_w[1], la_h[1], la_cfg[1], la_lut[1]);
             le_mb = bkr_match(1'b0);
             if (!le_ma && !le_mb) begin
                $display("ERROR: latch edge reg 0x%h, rise %0d cycles after the write start: frame is neither A nor B (mixed) %t",
                         le_addr, bkm_rise_cyc - le_a0, $time);
                error = error + 1;
             end else if (le_ma && (bkm_rise_cyc >= le_wc + 2) && !(le_mb)) begin
                $display("ERROR: latch edge reg 0x%h: active rose %0d cycles after the write completed, frame still A %t",
                         le_addr, bkm_rise_cyc - le_wc, $time);
                error = error + 1;
             end else if (le_mb && !le_ma && (bkm_rise_cyc <= le_a0 + 1)) begin
                $display("ERROR: latch edge reg 0x%h: active rose before the write, frame is B %t", le_addr, $time);
                error = error + 1;
             end else
                $display("OK:    latch edge reg 0x%h, rise at write-start %0d / write-end %0d cycles: frame %s",
                         le_addr, bkm_rise_cyc - le_a0, bkm_rise_cyc - le_wc, le_mb ? "B" : "A");
          end
      bkm_auto_trig = 1'b1;

      bkm_en = 1'b0;
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
