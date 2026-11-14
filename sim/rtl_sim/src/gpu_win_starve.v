//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_win_starve
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_win_starve.v
// Module Description : GPU progress under VRAM-window writes issued back to
//                      back at the full AHB rate (a new transfer every cycle
//                      the window is ready). The GPU, losing 7 cycles in a row
//                      to the window, takes the next one: at least one GPU
//                      grant per 8 window grants while the FILL runs under
//                      the burst, checked cycle by cycle (cycles the refresh
//                      takes count neither way), also with the 8080 refresh
//                      running and urgent during the burst. Measures, as INFO,
//                      the time of a FILL alone and under the burst; checks
//                      the final images.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT
`include "gpu_model.v"

`define WS_ARB tb_belenos.dut.u_core.u_vram_arb

localparam integer WS_BURST  = 3000;           // window writes per burst
localparam integer WS_WBASE  = 8000;           // window burst area (words)

reg        ws_count;
integer    ws_gpu_gnt, ws_win_gnt, ws_t0, ws_t1, ws_alone, ws_under, ws_bcyc, ws_k;
integer    ws_run, ws_run_max, ws_urg;
initial begin ws_count = 1'b0; ws_gpu_gnt = 0; ws_win_gnt = 0; ws_run = 0; ws_run_max = 0; ws_urg = 0; end

// Cycles in a row a requesting GPU loses to the window (a
// refresh cycle neither counts nor ends the run): at most 7
always @(posedge hclk)
  if (ws_count) begin
     if (`WS_ARB.gnt_o[VRQ_GPU] === 1'b1) ws_gpu_gnt = ws_gpu_gnt + 1;
     if (`WS_ARB.gnt_o[VRQ_WIN] === 1'b1) ws_win_gnt = ws_win_gnt + 1;
     if (`WS_ARB.gnt_o[VRQ_BK] === 1'b1) ws_urg     = ws_urg + 1;
     if ((`WS_ARB.req_i[VRQ_GPU] !== 1'b1) || (`WS_ARB.gnt_o[VRQ_GPU] === 1'b1))
        ws_run = 0;
     else if (`WS_ARB.gnt_o[VRQ_WIN] === 1'b1) begin
        ws_run = ws_run + 1;
        if (ws_run > ws_run_max) ws_run_max = ws_run;
        if (ws_run == 8) begin
           $display("ERROR: GPU lost 8 cycles in a row to the window %t", $time);
           error = error + 1;
        end
     end
  end

// n word writes through the window, pipelined: a new address phase every
// cycle the previous transfer completes
task ws_burst;
   input integer n;
   integer ai, di, wcnt;
   begin
      ai = 0; di = -1; wcnt = 0;
      @(negedge free_clk);
      while ((ai < n) || (di >= 0)) begin
         if (ai < n) begin
            v_hsel = 1'b1; v_haddr = 4 * (WS_WBASE + ai); v_htrans = 2'b10; v_hwrite = 1'b1;
            v_hsize = {1'b0, SZ_W}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
         end else begin
            v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
         end
         if (di >= 0) v_hwdata = 32'hA5A5_0000 | di;
         #2;
         if (v_hready === 1'b1) begin
            if (di >= 0) gpu_shadow[WS_WBASE + di] = 32'hA5A5_0000 | di;
            if (ai < n) begin di = ai; ai = ai + 1; end
            else di = -1;
            wcnt = 0;
         end else begin
            wcnt = wcnt + 1;
            if (wcnt > 1000) begin
               $display("ERROR: window burst hung at write %0d %t", di, $time);
               error = error + 1;
               ai = n; di = -1;
            end
         end
         @(negedge free_clk);
      end
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
   end
endtask

// A 64 x 32 FILL at 8 bpp (2048 pixels) at destination word 'dw'
task ws_fill;
   input integer dw;
   begin
      gpu_c_dst(16'd64, 4 * dw);
      gpu_c_size(14'd64, 14'd32);
      gpu_c_fill(32'h0000_005A);
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|                 START SIMULATION              |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < WS_WBASE + WS_BURST)
         tb_skip_finish("|        (needs 11000 VRAM words or more)      |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_mode(3);
      gpu_set_dispw(64);

      $display("--- FILL alone");
      ws_t0 = gpu_cyc;
      ws_fill(2000);
      gpu_wait_idle;
      ws_alone = gpu_cyc - ws_t0;
      $display("INFO:  FILL of 2048 pixels alone: %0d cycles", ws_alone);

      $display("--- FILL under a back-to-back window burst");
      ws_fill(4000);
      ws_gpu_gnt = 0; ws_win_gnt = 0; ws_count = 1'b1;
      ws_t0 = gpu_cyc;
      fork
         begin
            ws_burst(WS_BURST);
            ws_bcyc  = gpu_cyc - ws_t0;
            ws_count = 1'b0;
         end
         begin
            gpu_wait_idle;
            ws_under = gpu_cyc - ws_t0;
         end
      join
      $display("INFO:  window burst of %0d writes: %0d cycles, %0d window grants, %0d GPU grants during it",
               WS_BURST, ws_bcyc, ws_win_gnt, ws_gpu_gnt);
      $display("INFO:  FILL under the burst: %0d cycles (alone %0d)", ws_under, ws_alone);
      // while the FILL outlasts the burst, every 8 cycles hold a GPU grant
      if ((ws_under > ws_bcyc) && (ws_gpu_gnt * 8 < ws_win_gnt)) begin
         $display("ERROR: GPU starved under the window burst: %0d GPU grants for %0d window grants %t",
                  ws_gpu_gnt, ws_win_gnt, $time);
         error = error + 1;
      end else if (ws_under <= ws_bcyc)
         $display("INFO:  the FILL completed during the burst");

      gpu_check_all("window burst");
      $display("INFO:  longest run of GPU losses to the window: %0d cycles", ws_run_max);

      if (HAS_8080) begin
         $display("--- FILL under a back-to-back window burst, 8080 refresh running");
         reg_wr(DISP_SIZE,  (32 << 16) | 64);
         reg_wr(FRAME0_PTR, 32'h0);
         reg_wr(FRAME_SEL,  32'h0);
         reg_wr(DIF_CFG,    32'h0000_0001);              // LCD_ON, 8080, CLK_DIV 0
         reg_wr(REFRESH,    (300 << 4) | 1);
         ws_fill(4000);
         ws_gpu_gnt = 0; ws_win_gnt = 0; ws_urg = 0; ws_run = 0; ws_run_max = 0; ws_count = 1'b1;
         ws_t0 = gpu_cyc;
         fork
            begin
               ws_burst(WS_BURST);
               ws_count = 1'b0;
            end
            gpu_wait_idle;
         join
         $display("INFO:  burst with refresh: %0d window, %0d GPU, %0d refresh grants; longest GPU loss run %0d",
                  ws_win_gnt, ws_gpu_gnt, ws_urg, ws_run_max);
         if (ws_urg == 0) begin
            $display("ERROR: the refresh took no VRAM cycle during the burst %t", $time);
            error = error + 1;
         end
         reg_wr(REFRESH, 32'h0);
         gpu_wait_idle;
         gpu_check_all("window burst with refresh");
      end
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
