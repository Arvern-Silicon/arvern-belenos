//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_vram_contention
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_vram_contention.v
// Module Description : VRAM-window port under contention with the other VRAM
//                      masters, at 16 bpp:
//                      - the backend refreshes frame A (period mode, 8080
//                        driver when present, else the bench BDI model);
//                      - the GPU fills rectangle C four times (GPU_EN);
//                      - meanwhile the window runs pipelined random byte /
//                        half / word reads and writes on region B, every read
//                        checked against an issue-order reference, and no
//                        window transfer waits more than 16 cycles.
//                      Afterwards: every refreshed frame equals frame A, C
//                      holds the fill colour, B the reference, and nothing outside the regions changed.
//                      Then (GPU_EN): GPU writes to the word of a window
//                      read in flight. While the GPU fills region D, each
//                      GPU write seen on the macro starts a half-word window
//                      read of the word k ahead (k = 0..3), then a word read
//                      of it: a read whose word is written while its data is
//                      on the way must not be kept in the read-ahead buffer
//                      (the always-on buffer check compares every buffer hit
//                      with the VRAM); with a read latency of 2 or more the
//                      case is reached at least once; D ends with the last
//                      fill colour.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer CA_W   = 16;               // frame A: 16 x 8 pixels, words 0..63
localparam integer CA_H   = 8;
localparam integer CB_W0  = 256;              // region B: words 256..287 (window)
localparam integer CB_N   = 32;
localparam integer CC_W0  = 512;              // region C: GPU fill, 16 x 32 pixels, pitch 16 (x4)
localparam [15:0]  CC_COL = 16'hBEEF;

integer     c_i, c_k, c_f, c_px0, c_frames, c_maxw, c_s;
integer     c_n, c_cyc, c_stale;
reg  [31:0] c_dz;
localparam integer CD_W0  = 768;              // region D: words 768..1023 (GPU fill under window reads)

// Window demand reads whose word was written by another requester in flight
initial c_stale = 0;
always @(posedge hclk) if (dut.u_core.u_ahb_vram.dm_stale === 1'b1) c_stale = c_stale + 1;
reg  [31:0] c_v, c_a, c_mask;
reg   [2:0] c_sz;
reg  [15:0] c_e;
reg  [31:0] c_ref   [0:CB_N-1];
reg  [31:0] c_pexp  [0:PIPE_MAX-1];
reg  [31:0] c_pmask [0:PIPE_MAX-1];
reg  [31:0] c_save  [0:1023];

function [15:0] ca_pix;
   input integer i;
   begin
      ca_pix = (i * 16'h0731) ^ 16'h9C4A;
   end
endfunction

function [31:0] lane_mask;
   input [2:0]  size;
   input [31:0] addr;
   begin
      lane_mask = (size == 3'b000) ? (32'hFF   << (8*addr[1:0])) :
                  (size == 3'b001) ? (32'hFFFF << (16*addr[1]))  : 32'hFFFF_FFFF;
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        REGS: VRAM WINDOW UNDER CONTENTION     |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (VRAM_WORDS < 1024)
         tb_skip_finish("|        (needs VRAM_WORDS >= 1024)             |");

      // Back-door contents
      for (c_i = 0; c_i < 1024; c_i = c_i + 1) vram_mem[c_i] = $random(tmp_seed);
      for (c_i = 0; c_i < CA_W*CA_H/2; c_i = c_i + 1)
         vram_mem[c_i] = {ca_pix(2*c_i + 1), ca_pix(2*c_i)};
      for (c_i = 0; c_i < CB_N; c_i = c_i + 1) c_ref[c_i] = vram_mem[CB_W0 + c_i];
      for (c_i = 0; c_i < 1024; c_i = c_i + 1) c_save[c_i] = vram_mem[c_i];

      reg_wr(CTRL,       {27'h0, (GPU_EN != 0) ? 2'b10 : 2'b00, GFX_16BPP});
      reg_wr(DISP_SIZE,  (CA_H << 16) | CA_W);
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);
      if (HAS_8080) begin
         reg_wr(DIF_CFG, 32'h0000_0001);               // LCD_ON, 8080, CLK_DIV 0
         c_px0 = u_lcd8080.px_count;
      end else if (DIF_TYPE == 0) begin
         bm_auto = 1'b1; bm_rise_delay = 2; bm_fall_delay = 2; bm_exp_px = CA_W*CA_H;
         c_px0 = bm_px;
      end
      if (HAS_8080 || (DIF_TYPE == 0))
         reg_wr(REFRESH, (300 << 4) | 1);

      // GPU fill of C
      if (GPU_EN != 0) begin
         reg_wr(GPU_CMD, {OP_SET_DST,  12'h000, 16'd16});
         reg_wr(GPU_CMD, 2*CC_W0);
         reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd32, 14'd16});
         reg_wr(GPU_CMD, {OP_SET_FILL, 28'h0});
         reg_wr(GPU_CMD, {16'h0, CC_COL});
         for (c_i = 0; c_i < 4; c_i = c_i + 1) reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
      end

      // window traffic on B, built with an issue-order reference
      vp_clear;
      for (c_i = 0; c_i < 400; c_i = c_i + 1) begin
         c_s = ($random(tmp_seed) & 32'hFFFF) % 6;             // 6 words: many hazards
         c_k = $random(tmp_seed) & 3;
         c_sz = (c_k == 3) ? 3'b010 : {2'b00, c_k[0]};
         c_a  = 4*(CB_W0 + c_s) + ((c_sz == 3'b000) ? ($random(tmp_seed) & 3) : (c_sz == 3'b001) ? ($random(tmp_seed) & 2) : 0);
         c_mask = lane_mask(c_sz, c_a);
         c_v = $random(tmp_seed);
         if ($random(tmp_seed) & 1) begin
            vp_add(c_a, 1'b1, c_sz, c_v, MACHINE, HART_MASTER, ((c_i % 9) == 0) ? 2'b10 : 2'b10, (($random(tmp_seed) & 7) == 0) ? 1 : 0);
            c_ref[c_s] = (c_ref[c_s] & ~c_mask) | (c_v & c_mask);
            c_pmask[vp_n-1] = 0;
         end else begin
            vp_add(c_a, 1'b0, c_sz, 0, MACHINE, HART_MASTER, 2'b10, (($random(tmp_seed) & 7) == 0) ? 1 : 0);
            c_pexp[vp_n-1]  = c_ref[c_s];
            c_pmask[vp_n-1] = c_mask;
         end
      end
      // and a word burst over the whole of B
      for (c_i = 0; c_i < CB_N; c_i = c_i + 1) begin
         c_v = $random(tmp_seed);
         vp_add(4*(CB_W0 + c_i), 1'b1, 3'b010, c_v, MACHINE, HART_MASTER, (c_i == 0) ? 2'b10 : 2'b11, 0);
         c_ref[c_i] = c_v;
         c_pmask[vp_n-1] = 0;
      end
      for (c_i = 0; c_i < CB_N; c_i = c_i + 1) begin
         vp_add(4*(CB_W0 + c_i), 1'b0, 3'b010, 0, MACHINE, HART_MASTER, (c_i == 0) ? 2'b10 : 2'b11, 0);
         c_pexp[vp_n-1]  = c_ref[c_i];
         c_pmask[vp_n-1] = 32'hFFFF_FFFF;
      end

      vp_run;

      c_maxw = 0;
      for (c_i = 0; c_i < vp_n; c_i = c_i + 1) begin
         vp_chk(c_i, OK, c_pexp[c_i], c_pmask[c_i], -1);
         if (vp_waits[c_i] > c_maxw) c_maxw = vp_waits[c_i];
      end
      $display("OK:    window under contention: max %0d wait states", c_maxw);
      // The window is served between the refresh's own fetches: a refresh that
      // held it off for a whole burst would show waits of a line or more
      if (c_maxw > 16) tb_error("window waited more than 16 cycles under contention");

      // let the GPU finish, stop the refresh, drain
      if (GPU_EN != 0) reg_poll(GPU_STAT, 32'h0030_0000, 32'h0, 5000);
      repeat (700) @(posedge free_clk);
      if (HAS_8080 || (DIF_TYPE == 0)) reg_wr(REFRESH, 32'h0);
      if (HAS_8080) reg_poll(DIF_STATUS, 32'h0000_0009, 32'h0, 4000);
      repeat (400) @(posedge free_clk);

      // refreshed frames
      if (HAS_8080) begin
         c_frames = (u_lcd8080.px_count - c_px0) / (CA_W*CA_H);
         if ((c_frames < 2) || (((u_lcd8080.px_count - c_px0) % (CA_W*CA_H)) != 0)) begin
            $display("ERROR: panel received %0d pixels (frames of %0d expected, >= 2) %t", u_lcd8080.px_count - c_px0, CA_W*CA_H, $time);
            error = error + 1;
         end
         for (c_f = 0; (c_f < c_frames) && (c_px0 + (c_f+1)*CA_W*CA_H <= 4096); c_f = c_f + 1)
            for (c_i = 0; c_i < CA_W*CA_H; c_i = c_i + 1)
               if (u_lcd8080.px_log[c_px0 + c_f*CA_W*CA_H + c_i] !== ca_pix(c_i)) begin
                  $display("ERROR: frame %0d pixel %0d = 0x%h / expected 0x%h %t", c_f, c_i,
                           u_lcd8080.px_log[c_px0 + c_f*CA_W*CA_H + c_i], ca_pix(c_i), $time);
                  error = error + 1;
               end
         $display("INFO:  %0d frames refreshed during the test", c_frames);
         if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel protocol anomalies");
      end else if (DIF_TYPE == 0) begin
         c_frames = (bm_px - c_px0) / (CA_W*CA_H);
         if ((c_frames < 2) || (bm_px_bad_last != 0)) begin
            $display("ERROR: BDI model: %0d pixels, %0d bad frames %t", bm_px - c_px0, bm_px_bad_last, $time);
            error = error + 1;
         end
         for (c_f = 0; (c_f < c_frames) && (c_px0 + (c_f+1)*CA_W*CA_H <= 4096); c_f = c_f + 1)
            for (c_i = 0; c_i < CA_W*CA_H; c_i = c_i + 1)
               begin
                  c_e = ca_pix(c_i);
                  if (bm_px_log[c_px0 + c_f*CA_W*CA_H + c_i] !== {c_e[15:11], c_e[15:13], c_e[10:5], c_e[10:9], c_e[4:0], c_e[4:2]}) begin
                     $display("ERROR: BDI frame %0d pixel %0d = 0x%h %t", c_f, c_i, bm_px_log[c_px0 + c_f*CA_W*CA_H + c_i], $time);
                     error = error + 1;
                  end
               end
         $display("INFO:  %0d frames refreshed during the test", c_frames);
      end

      // memory contents
      for (c_i = 0; c_i < 1024; c_i = c_i + 1) begin
         if ((c_i >= CB_W0) && (c_i < CB_W0 + CB_N))
            c_v = c_ref[c_i - CB_W0];
         else if ((GPU_EN != 0) && (c_i >= CC_W0) && (c_i < CC_W0 + 256))
            c_v = {CC_COL, CC_COL};
         else
            c_v = c_save[c_i];
         if (vram_mem[c_i] !== c_v) begin
            $display("ERROR: VRAM word %0d = 0x%h / expected 0x%h %t", c_i, vram_mem[c_i], c_v, $time);
            error = error + 1;
         end
      end

      //------------------------------------------------------------------
      // GPU writes to the word of a window read in flight
      //------------------------------------------------------------------
      if (GPU_EN != 0) begin
         reg_wr(GPU_CMD, {OP_SET_DST,  12'h000, 16'd16});
         reg_wr(GPU_CMD, 2*CD_W0);
         reg_wr(GPU_CMD, {OP_SET_SIZE, 14'd32, 14'd16});
         for (c_k = 0; c_k < 5; c_k = c_k + 1) begin
            reg_wr(GPU_CMD, {OP_SET_FILL, 28'h0});
            c_v = 32'h1111 * (c_k + 1); reg_wr(GPU_CMD, {16'h0, c_v[15:0]});
            reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
            reg_wr(GPU_CMD, {OP_EXEC_FILL, 28'h0});
            c_n = 0; c_cyc = 0;
            while ((c_k > 0) && (c_n < 40) && (c_cyc < 3000)) begin
               @(posedge hclk);
               c_cyc = c_cyc + 1;
               if ((vram_cen === 1'b0) && (vram_wen !== 4'hF) && (vram_addr >= CD_W0) && (vram_addr < CD_W0 + 248)) begin
                  c_a = vram_addr + (c_k - 1);
                  vram_rd_val(4*c_a, SZ_H, c_dz);
                  vram_rd_val(4*c_a, SZ_W, c_dz);
                  c_n = c_n + 1;
               end
            end
            reg_poll(GPU_STAT, 32'h0030_0000, 32'h0, 5000);
         end
         for (c_i = CD_W0; c_i < CD_W0 + 256; c_i = c_i + 1) vram_rd(4*c_i, {2{16'h5555}}, SZ_W);
         if ((VRAM_RD_LAT + VRAM_RD_REG_EN >= 2) && (c_stale == 0))
            tb_error("no window read had its word written in flight (case not reached)");
         $display("OK:    GPU writes to the word of a window read in flight (%0d cycles of a stale read)", c_stale);
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
