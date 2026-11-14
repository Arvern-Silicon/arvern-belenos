//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_line_list
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_line_list.v
// Module Description : Lines in command lists and back to back:
//                       1. lines, LINE_PEN and LINE_PATTERN in CALL lists,
//                          the pattern phase carried across the list
//                          boundaries (FIFO -> list -> FIFO), PH_RST on a
//                          list's first line; one GPU_DONE per line;
//                       2. a list replayed (XOR): PH_RST on its first line
//                          restarts the rhythm at every CALL;
//                       3. dense streams of short lines with a SET_FILL,
//                          a LINE_PATTERN or a SET_CLIP between them (with
//                          run-ahead: decoded while the previous line
//                          draws, which keeps its own), mixed with
//                          rectangles and AA lines (GPU_BLEND_EN, 16 bpp).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer LL_P      = 83;
localparam integer LL_NR     = 60;
localparam integer LL_LST    = 400;             // lists: words [400, 1000)
localparam integer LL_D_LO   = 1024;
localparam integer LL_D_HI   = LL_D_LO + (LL_P * LL_NR) / 2 + 8;
localparam integer LL_VMIN   = LL_D_HI + 16;

integer    ll_i, ll_k, ll_m, ll_n, ll_bl, ll_ndone;
reg [31:0] ll_org;

function integer ll_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      ll_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task ll_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      ll_bl  = gpu_bl(mode);
      ll_org = LL_D_LO * (32 >> ll_bl) + 5;
      gpu_c_dst_xy(LL_P, ll_org);
      gpu_c_clip(0, 0, LL_P - 1, LL_NR - 1);                            // the surface
   end
endtask

task ll_rand_line;                       // a random line from the pen
   input  [3:0] opt;
   begin
      gpu_c_line(16 * ll_rnd(LL_P) + ll_rnd(16), 16 * ll_rnd(LL_NR) + ll_rnd(16), (ll_rnd(3) == 0) ? 4'd5 : 4'd0, opt);
   end
endtask

// Capture the pushes into a list (the model takes them as they are captured)
task ll_cap_begin;
   begin
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
   end
endtask

task ll_cap_call;                        // write the list, CALL it
   integer kk;
   begin
      gpu_cap_en = 1'b0;
      if (LL_LST + gpu_cap_n > LL_D_LO) tb_error("command list overflows its area (test bug)");
      for (kk = 0; kk < gpu_cap_n; kk = kk + 1) begin
         vram_mem[LL_LST + kk]   = gpu_cap_buf[kk];
         gpu_shadow[LL_LST + kk] = gpu_cap_buf[kk];
      end
      gpu_push({OP_CALL, 4'h0, gpu_cap_n[23:0]});
      gpu_push(LL_LST);
   end
endtask

// Count GPU_DONE events (one per line)
always @(posedge hclk)
   if ((hresetn_d === 1'b1) && (dut.u_core.G_GPU.u_gpu.done_evt_o === 1'b1)) ll_ndone = ll_ndone + 1;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: lines in lists, back to back      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_LINE_EN == 0))
         tb_skip_finish("|          (lines absent)                       |");
      if (VRAM_WORDS < LL_VMIN)
         tb_skip_finish("|          (VRAM too small)                     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(LL_P);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_dlo = LL_D_LO;
      gpu_rgn_dhi = LL_D_HI;
      gpu_c_reset_state;

      //--------------------------------------------------------------
      $display("--- 1. lines in lists, the phase across the boundaries, GPU_DONE per line");
      ll_set_mode(3);
      for (ll_m = 0; ll_m < 4; ll_m = ll_m + 1) begin
         gpu_preload_rand(LL_D_LO, LL_D_HI);
         gpu_wait_idle;
         ll_ndone = 0;
         gpu_c_pattern($random(gpu_seed), 5 + ll_rnd(27));
         gpu_c_fill($random(gpu_seed));
         gpu_c_pen(16 * 10 + 8, 16 * 10 + 8);
         ll_rand_line(4'b0010);                                          // FIFO: the phase advances
         ll_cap_begin;
         for (ll_i = 0; ll_i < 6; ll_i = ll_i + 1) begin
            if (ll_i == 2) gpu_c_fill($random(gpu_seed));
            if (ll_i == 4) gpu_c_pen(16 * ll_rnd(LL_P) + 8, 16 * ll_rnd(LL_NR) + 8);
            if ((ll_m == 3) && (ll_i == 3)) gpu_c_pattern($random(gpu_seed), 9);
            ll_rand_line({(ll_m == 1) && (ll_i == 0), ll_rnd(2) == 0, ll_rnd(2) == 0, 1'b0});
         end
         ll_cap_call;
         ll_rand_line(4'b0000);                                          // FIFO again: the list's phase
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         if (ll_ndone != 8) begin
            $display("ERROR: %0d GPU_DONE events for 8 lines %t", ll_ndone, $time);
            error = error + 1;
         end
         gpu_check_touched("lines in a list");
      end

      //--------------------------------------------------------------
      $display("--- 2. a list replayed");
      gpu_preload_rand(LL_D_LO, LL_D_HI);
      gpu_c_pattern(32'h0000_0337, 10);
      ll_cap_begin;
      gpu_c_fill($random(gpu_seed));
      gpu_c_pen(16 * 4 + 8, 16 * 30 + 8);
      gpu_c_line(16 * 70 + 8, 16 * 33 + 8, 4'd5, 4'b1000);              // PH_RST
      gpu_c_line(16 * 75 + 8, 16 * 50 + 8, 4'd5, 4'b0010);
      ll_n = gpu_cap_n;
      gpu_cap_en = 1'b0;
      for (ll_k = 0; ll_k < ll_n; ll_k = ll_k + 1) begin
         vram_mem[LL_LST + ll_k]   = gpu_cap_buf[ll_k];
         gpu_shadow[LL_LST + ll_k] = gpu_cap_buf[ll_k];
      end
      for (ll_k = 0; ll_k < 3; ll_k = ll_k + 1) begin
         gpu_push({OP_CALL, 4'h0, ll_n[23:0]});
         gpu_push(LL_LST);
         if (ll_k > 0) begin                                             // the model: the list again
            gpu_c_fill(gpu_m_fill);
            gpu_c_pen(16 * 4 + 8, 16 * 30 + 8);
            gpu_d_line(4'd5, 4'b1000, 16 * 70 + 8, 16 * 33 + 8);
            gpu_d_line(4'd5, 4'b0010, 16 * 75 + 8, 16 * 50 + 8);
         end
      end
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("a list replayed");

      //--------------------------------------------------------------
      $display("--- 3. dense streams: settings between lines, rectangles, AA");
      for (ll_m = 0; ll_m < 3; ll_m = ll_m + 1) begin
         ll_set_mode((ll_m == 0) ? 3 : (ll_m == 1) ? 0 : 4);
         gpu_preload_rand(LL_D_LO, LL_D_HI);
         for (ll_i = 0; ll_i < 60; ll_i = ll_i + 1) begin
            case (ll_rnd(6))
              0: gpu_c_fill($random(gpu_seed));
              1: gpu_c_pattern($random(gpu_seed), 1 + ll_rnd(32));
              2: gpu_c_clip(ll_rnd(40), ll_rnd(30), 40 + ll_rnd(43), 30 + ll_rnd(30));
              3: begin
                    gpu_c_xy(ll_rnd(LL_P - 8), ll_rnd(LL_NR - 4));
                    gpu_c_size(1 + ll_rnd(8), 1 + ll_rnd(4));
                    gpu_c_exec_xy(GPU_FILL, 4'd5, 3'b000, 3'b000);
                 end
              default: ;
            endcase
            gpu_c_pen(16 * ll_rnd(LL_P) + ll_rnd(16), 16 * ll_rnd(LL_NR) + ll_rnd(16));
            gpu_c_line(gpu_m_pen_x + 16 * (ll_rnd(13) - 6) + ll_rnd(16), gpu_m_pen_y + 16 * (ll_rnd(13) - 6) + ll_rnd(16),
                       (ll_rnd(3) == 0) ? 4'd5 : 4'd0,
                       {1'b0, ll_rnd(4) == 0, ll_rnd(2) == 0, (GPU_BLEND_EN != 0) && (ll_rnd(2) == 0)});
         end
         gpu_wait_idle;
         reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
         gpu_check_touched("dense line streams");
      end

      gpu_c_pattern(32'hFFFF_FFFF, 32);
      gpu_check_all("lines in lists");
      stimulus_done = 1;
   end
