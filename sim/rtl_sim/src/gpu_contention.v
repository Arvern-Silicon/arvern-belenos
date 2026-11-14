//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_contention
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_contention.v
// Module Description : gpu_random under VRAM contention: while the
//                      rectangles run, a background manager hammers the VRAM
//                      window (byte / half / word reads and writes on a region
//                      the GPU never touches; reads checked, writes mirrored in
//                      the shadow) and, with the 8080 PHY, periodic display
//                      refreshes read a frame (backend requester, urgent
//                      priority above the GPU). Every GPU access must wait for
//                      its grant: the final image must still match the model.
//                      Window traffic pauses while the touched words are read
//                      back. Background traffic uses its own v-port driver.
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer TR_ITER = 40;

// Background VRAM-window manager (own driver: ahb_xfer is not re-entrant)
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
      repeat({$random(tn_seed)} % 6) @(negedge free_clk);
   end
end

task tn_bg_pause;
   begin
      tn_bg_en = 1'b0;
      while (tn_bg_busy) @(negedge free_clk);
      @(negedge free_clk);
   end
endtask

integer    tr_it, tr_b, tr_nb, tr_bl, tr_ppw, tr_rows, tr_cols, tr_x0, tr_y0;
integer    tr_w, tr_h, tr_sp, tr_dp, tr_spe, tr_dpe, tr_r;
reg  [2:0] tr_mode, tr_dsw, tr_ssw;
reg  [3:0] tr_cmd, tr_op;
reg [31:0] tr_sorg, tr_dorg, tr_sbase, tr_dbase, tr_pix;
integer    tr_npx;

function [31:0] tr_corner;
   input [31:0] org;
   input integer pitch;
   input integer x0;
   input integer y0;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows = sw[0] ? w : h;
      cols = sw[0] ? h : w;
      tr_corner = org + (y0 + (sw[1] ? rows - 1 : 0)) * pitch + x0 + (sw[2] ? cols - 1 : 0);
   end
endfunction

function integer tr_pitch;              // random pitch for a surface
   input integer minp;
   integer      r;
   begin
      r = $random(gpu_seed) & 15;
      if (r < 3)       tr_pitch = 0;                                  // DISP_WIDTH
      else if (r == 3) tr_pitch = 1 + ($random(gpu_seed) & 7);        // overlapping rows
      else             tr_pitch = minp + ($random(gpu_seed) & 127);
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: random under VRAM contention       |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      tn_seed = gpu_seed ^ 32'h5A5A_1234;
      if (HAS_8080) begin
         reg_wr(DISP_SIZE, 32'h0008_0010);
         reg_wr(DIF_CFG,   32'h0000_0001);                // LCD_ON, 8080, CLK_DIV 0
         reg_wr(REFRESH,   (32'd150 << 4) | 32'h1);       // periodic refresh
      end
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      tr_npx = 0;

      for (tr_it = 0; tr_it < TR_ITER; tr_it = tr_it + 1) begin
         tr_mode = $random(gpu_seed);
         tr_bl   = gpu_bl(tr_mode);
         tr_ppw  = 32 >> tr_bl;
         // the refresh pauses while the mode, the size and the frame pointer
         // (in pixels of the mode) change together
         if (HAS_8080) begin
            reg_wr(REFRESH, 32'h0);
            reg_poll(STATUS, 32'h1, 32'h0, 200000);
         end
         gpu_set_mode(tr_mode);
         gpu_set_dispw(8 + ($random(gpu_seed) & 255));
         reg_wr(DISP_SIZE, 32'h0008_0000 | gpu_m_dispw);   // height 8 for the refresh
         reg_wr(FRAME0_PTR, 16000 * tr_ppw);
         if (HAS_8080) reg_wr(REFRESH, (32'd150 << 4) | 32'h1);
         tn_bg_en = 1'b1;
         tr_nb = 1 + ($random(gpu_seed) & 3);
         $display("--- iteration %0d: mode %0d, DISP_WIDTH %0d, %0d rectangle(s)", tr_it, tr_mode, gpu_m_dispw, tr_nb);
         for (tr_b = 0; tr_b < tr_nb; tr_b = tr_b + 1) begin
            tr_r = $random(gpu_seed) & 7;
            if ((tr_r != 0) || (tr_b == 0) || (tr_it == 0)) begin     // new state (else: re-exec)
               tr_w   = 1 + ($random(gpu_seed) % 12); if (tr_w < 1) tr_w = -tr_w + 1;
               tr_h   = 1 + ($random(gpu_seed) % 8);  if (tr_h < 1) tr_h = -tr_h + 1;
               tr_dsw = $random(gpu_seed);
               tr_ssw = $random(gpu_seed);
               tr_sp  = tr_pitch(16);
               tr_dp  = tr_pitch(16);
               tr_spe = (tr_sp == 0) ? gpu_m_dispw : tr_sp;
               tr_dpe = (tr_dp == 0) ? gpu_m_dispw : tr_dp;
               // surfaces: source in words [1000, 15000), destination in [20000, 37000)
               if (tr_b == 0)                                        // backdoor preload only while idle
                  tr_sorg = (1000 + ($random(gpu_seed) & 4095)) * tr_ppw + ($random(gpu_seed) & (tr_ppw - 1));
               tr_dorg = (20000 + ($random(gpu_seed) & 4095)) * tr_ppw + ($random(gpu_seed) & (tr_ppw - 1)) + 4 * tr_b * tr_ppw * 600;
               tr_x0   = $random(gpu_seed) & 15;
               tr_y0   = $random(gpu_seed) & 3;
               tr_sbase = tr_corner(tr_sorg, tr_spe, tr_x0, tr_y0, tr_ssw, tr_w, tr_h);
               tr_dbase = tr_corner(tr_dorg, tr_dpe, tr_x0, tr_y0, tr_dsw, tr_w, tr_h);
               if (($random(gpu_seed) & 1) && (tr_b == 0))
                  gpu_preload_pal(gpu_word_of(tr_sorg, tr_bl), gpu_word_of(tr_sorg, tr_bl) + (20 * tr_spe + 40) / tr_ppw + 2,
                                  tr_bl, $random(gpu_seed), $random(gpu_seed), $random(gpu_seed), $random(gpu_seed));
               gpu_c_src(tr_sp, tr_sbase);
               gpu_c_dst(tr_dp, tr_dbase);
               gpu_c_size(tr_w, tr_h);
               gpu_c_fill($random(gpu_seed));
               tr_pix = gpu_get_px(tr_sbase, tr_bl);
               if ($random(gpu_seed) & 1) gpu_c_transp({$random(gpu_seed)} << 16 | tr_pix);
               else                       gpu_c_transp($random(gpu_seed));
            end
            tr_r   = $random(gpu_seed) & 3;
            tr_cmd = (tr_r == 0) ? GPU_FILL : (tr_r == 1) ? GPU_COPY : GPU_COPYT;
            tr_op  = $random(gpu_seed);
            tr_dsw = (($random(gpu_seed) & 3) == 0) ? $random(gpu_seed) : tr_dsw;
            if (tr_dsw != gpu_x_dsw) begin
               // swaps changed without a new base: recompute the corner
               tr_dbase = tr_corner(tr_dorg, tr_dpe, tr_x0, tr_y0, tr_dsw, gpu_m_w, gpu_m_h);
               gpu_c_dst(tr_dp, tr_dbase);
            end
            $display("       %0s op %0d %0dx%0d dst sw %b pitch %0d base 0x%h, src sw %b pitch %0d base 0x%h",
                     (tr_cmd == GPU_FILL) ? "FILL" : (tr_cmd == GPU_COPY) ? "COPY" : "COPY_TRANSP", tr_op,
                     gpu_m_w, gpu_m_h, tr_dsw, gpu_m_dst_pitch, gpu_m_dst_base, tr_ssw, gpu_m_src_pitch, gpu_m_src_base);
            gpu_c_exec(tr_cmd, tr_op, tr_dsw, tr_ssw);
            tr_npx = tr_npx + gpu_m_w * gpu_m_h;
         end
         gpu_wait_idle;
         tn_bg_pause;
         gpu_check_touched("contention batch");
      end

      tn_bg_pause;
      reg_wr(REFRESH, 32'h0);
      reg_poll(DIF_STATUS, 32'h1, 32'h0, 20000);
      $display("       background: %0d window writes, %0d window reads; panel pixels %0d", tn_nw, tn_nr, u_lcd8080.px_count);
      if (HAS_8080 && (u_lcd8080.px_count == 0)) begin
         $display("ERROR: no refresh ran during the test %t", $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
      $display("       %0d pixels in total", tr_npx);
      gpu_check_all("contention end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
