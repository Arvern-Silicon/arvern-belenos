//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_slot_freeze
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_slot_freeze.v
// Module Description : FILLs at 1 and 2 bpp whose rows overlap (pitch 2-7
//                      pixels, width 6-16), with short debug freezes and
//                      back-to-back VRAM-window traffic: a run that covers
//                      whole bytes is merged without reading the destination,
//                      the next run in the same word needs the read. The word
//                      with merged bytes must reach the VRAM first, whether it
//                      waits in the write-back slot (held there by the window
//                      traffic, or handed over by a freeze) or moves to it in
//                      the same cycle. Image checked against the model after
//                      each FILL.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer SF_LO = 3000;
localparam integer SF_HI = 3400;
localparam integer SF_N  = 200;

// Background VRAM-window manager (own driver: ahb_xfer is not re-entrant), back to back
reg        tn_bg_en, tn_bg_busy;
integer    tn_seed, tn_nw, tn_nr, tn_waits;
reg [31:0] tn_addr, tn_data, tn_raw, tn_exp, tn_lane;
reg  [1:0] tn_size;
reg        tn_wr;
initial begin tn_bg_en = 1'b0; tn_bg_busy = 1'b0; tn_nw = 0; tn_nr = 0; end

always begin : tn_bg
   @(negedge free_clk);
   if (tn_bg_en) begin
      tn_bg_busy = 1'b1;
      tn_wr   = $random(tn_seed);
      tn_size = $random(tn_seed) % 3; if (tn_size > 2) tn_size = 2;
      tn_addr = 4 * (16000 + ({$random(tn_seed)} % 3000)) + ({$random(tn_seed)} & 3);
      tn_addr = (tn_size == SZ_W) ? (tn_addr & ~32'h3) : (tn_size == SZ_H) ? (tn_addr & ~32'h1) : tn_addr;
      tn_data = $random(tn_seed);
      tn_lane = (tn_size == SZ_B) ? {4{tn_data[7:0]}} : (tn_size == SZ_H) ? {2{tn_data[15:0]}} : tn_data;
      // address phase (hready high: single manager on this port)
      while (v_hready !== 1'b1) @(negedge free_clk);
      v_hsel = 1'b1; v_haddr = tn_addr; v_htrans = 2'b10; v_hwrite = tn_wr;
      v_hsize = {1'b0, tn_size}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
      if (tn_wr) v_hwdata = tn_lane;
      tn_waits = 0;
      @(negedge free_clk);
      while (v_hready !== 1'b1) begin @(negedge free_clk); tn_waits = tn_waits + 1; end
      tn_raw = v_hrdata;
      if (v_hresp !== 1'b0) begin
         $display("ERROR: background window access 0x%h got ERROR %t", tn_addr, $time);
         error = error + 1;
      end
      @(posedge free_clk);
      if (tn_wr) begin
         if (tn_size == SZ_W) gpu_shadow[tn_addr >> 2] = tn_lane;
         else if (tn_size == SZ_H) begin
            if (tn_addr[1]) gpu_shadow[tn_addr >> 2][31:16] = tn_lane[15:0];
            else            gpu_shadow[tn_addr >> 2][15:0]  = tn_lane[15:0];
         end else
            case (tn_addr[1:0])
              2'd0: gpu_shadow[tn_addr >> 2][ 7: 0] = tn_lane[7:0];
              2'd1: gpu_shadow[tn_addr >> 2][15: 8] = tn_lane[7:0];
              2'd2: gpu_shadow[tn_addr >> 2][23:16] = tn_lane[7:0];
              default: gpu_shadow[tn_addr >> 2][31:24] = tn_lane[7:0];
            endcase
         tn_nw = tn_nw + 1;
      end else begin
         tn_exp = gpu_shadow[tn_addr >> 2];
         tn_exp = (tn_size == SZ_B) ? ((tn_exp >> (8 * tn_addr[1:0])) & 32'hFF) :
                  (tn_size == SZ_H) ? ((tn_exp >> (16 * tn_addr[1])) & 32'hFFFF) : tn_exp;
         tn_raw = (tn_size == SZ_B) ? ((tn_raw >> (8 * tn_addr[1:0])) & 32'hFF) :
                  (tn_size == SZ_H) ? ((tn_raw >> (16 * tn_addr[1])) & 32'hFFFF) : tn_raw;
         if (tn_raw !== tn_exp) begin
            $display("ERROR: background window read 0x%h = 0x%h / expected 0x%h %t", tn_addr, tn_raw, tn_exp, $time);
            error = error + 1;
         end
         tn_nr = tn_nr + 1;
      end
      tn_bg_busy = 1'b0;
   end
end

task tn_bg_pause;
   begin
      tn_bg_en = 1'b0;
      while (tn_bg_busy) @(negedge free_clk);
      @(negedge free_clk);
   end
endtask

integer    sf_i, sf_mode, sf_bl, sf_ppw, sf_w, sf_h, sf_p, sf_op, sf_k;
reg [31:0] sf_base, sf_fill;
reg        sf_run;

function integer sf_rnd;
   input integer n;
   begin
      sf_rnd = ($random(gpu_seed) & 32'h7FFF_FFFF) % n;
   end
endfunction

// Freeze pulses of 1-3 cycles every 1-6 cycles while sf_run
always begin : sf_pulses
   @(negedge free_clk);
   if (sf_run) begin
      repeat(1 + ({$random(tn_seed)} % 6)) @(negedge free_clk);
      dbg_stoptime = 1'b1;
      repeat(1 + ({$random(tn_seed)} % 3)) @(negedge free_clk);
      dbg_stoptime = 1'b0;
   end
end

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: short freezes with the write-back slot  |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 19100)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      gpu_seed = `SEED;
      tn_seed  = gpu_seed ^ 32'h0F0F_5A5A;
      sf_run   = 1'b0;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      reg_wr(DBG_CTRL, 32'h2);                                      // freeze armed: dbg_stoptime holds the GPU

      for (sf_i = 0; sf_i < SF_N; sf_i = sf_i + 1) begin
         if ((sf_i % 25) == 0) begin
            gpu_wait_idle;
            sf_mode = sf_rnd(2);                                     // 1 or 2 bpp
            sf_bl   = gpu_bl(sf_mode);
            sf_ppw  = 32 >> sf_bl;
            gpu_check_all("before the next block");       // no stray write absorbed by the re-init
            gpu_preload_rand(SF_LO, SF_HI);
            gpu_model_init;
            gpu_set_mode(sf_mode);
            gpu_set_dispw(64);
         end
         sf_w    = 6 + sf_rnd(11);
         sf_h    = 4 + sf_rnd(7);
         sf_p    = 2 + sf_rnd(6);
         sf_base = (SF_LO + 40 + sf_rnd(200)) * sf_ppw + (sf_rnd(2) ? 0 : 8 * sf_rnd(sf_ppw / 8 + 1));
         case (sf_rnd(5))
           0: sf_op = 0; 1: sf_op = 1; 2: sf_op = 13; 3: sf_op = 14; default: sf_op = 15;
         endcase
         sf_fill = $random(gpu_seed);
         gpu_c_size(sf_w, sf_h);
         gpu_c_dst(sf_p, sf_base);
         gpu_c_fill(sf_fill);
         gpu_c_transp(~sf_fill);                                     // never transparent
         tn_bg_en = 1'b1;
         sf_run   = 1'b1;
         gpu_c_exec(GPU_FILL, sf_op, 3'b000, 3'b000);
         gpu_wait_idle;
         sf_run   = 1'b0;
         @(negedge free_clk) dbg_stoptime = 1'b0;
         tn_bg_pause;
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("FILL with short freezes");
         if (error != 0) sf_i = SF_N;
      end
      reg_wr(DBG_CTRL, 32'h0);
      $display("       %0d FILLs, background window: %0d writes, %0d reads", SF_N, tn_nw, tn_nr);
      gpu_check_all("slot freeze end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
