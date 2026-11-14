//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_freeze
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_freeze.v
// Module Description : Debug freeze of the GPU:
//                      DBG_CTRL[1] & dbg_stoptime during a rectangle -> HELD
//                      within a few cycles, then no VRAM access at all and no
//                      FIFO word consumed (words pushed while held stay in
//                      the FIFO), BUSY / PRIM_BUSY kept; release -> identical
//                      final image, GPU_DONE. Then rectangles at 1/4/8/16 bpp
//                      (FILL, COPY, COPY_TRANSP) with the freeze toggled at
//                      random instants (through dbg_stoptime and through
//                      DBG_CTRL[1]); every final image must match the model.
//                      Frozen with nothing in progress: HELD = 1; words
//                      pushed then stay queued (HELD, BUSY, no access) and
//                      run on release. A clipped-away x/y FILL with the
//                      freeze raised 0..40 cycles after its EXEC push: no
//                      GPU_DONE (IRQ pin) while frozen, one on release.
//----------------------------------------------------------------------------
`include "gpu_model.v"

integer    tz_k, tz_t, tz_mode, tz_waits, tz_d;
reg        tz_frz, tz_frz_p, tz_frz_q, tz_irq_q;
initial begin tz_frz = 1'b0; tz_frz_p = 1'b0; tz_frz_q = 1'b0; tz_irq_q = 1'b0; end

// No GPU event while frozen: the freeze takes effect one cycle after
// dbg_stoptime and the IRQ flag is set the cycle after the event, so an IRQ
// rising after a cycle that ended frozen is an event under freeze
always @(posedge hclk) begin
   if (tz_frz_q && (irq === 1'b1) && !tz_irq_q) begin
      $display("ERROR: GPU interrupt raised while frozen %t", $time);
      error = error + 1;
   end
   tz_irq_q <= (irq === 1'b1);
   tz_frz_p <= tz_frz && (dbg_stoptime_d === 1'b1);
   tz_frz_q <= tz_frz_p;
end
reg [31:0] tz_stat;
reg  [3:0] tz_cmd;

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: debug freeze                      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);

      $display("--- freeze in the middle of a rectangle");
      gpu_set_mode(2);
      gpu_c_src(16'd120, 32'd2000);
      gpu_c_dst(16'd100, 32'd90000);
      gpu_c_size(14'd30, 14'd20);
      gpu_c_fill(32'h0000_0005);
      gpu_c_exec(GPU_COPY, 4'd5, 3'b000, 3'b000);
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
      repeat(200) @(posedge free_clk);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(DBG_CTRL, 32'h2);
      @(negedge free_clk) dbg_stoptime = 1'b1;
      tz_t = gpu_cyc;
      tz_stat = 0;
      while (!(tz_stat & GS_HELD) && (gpu_cyc - tz_t < 100))
         reg_rd_val(GPU_STAT, tz_stat);
      gpu_mon_noacc = 1'b1;
      if (!(tz_stat & GS_HELD)) begin
         $display("ERROR: GPU HELD not set 100 cycles after the freeze %t", $time);
         error = error + 1;
      end else
         $display("OK:    GPU HELD %0d cycles after the freeze (register-read granularity)", gpu_cyc - tz_t);
      reg_rd_mask(GPU_STAT, GS_HELD | GS_BUSY | GS_PRIM_BUSY | GS_EMPTY, 32'hFFF_FF00);
      gpu_c_fill(32'h0000_000A);                         // 2 words, not consumed
      gpu_c_exec(GPU_FILL, 4'd15, 3'b001, 3'b000);       // 1 more (CL swap)
      repeat(300) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_HELD | GS_BUSY | GS_PRIM_BUSY | 32'h0300, 32'hFFF_FF00);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      gpu_mon_noacc = 1'b0;
      if (gpu_mon_noacc_hits == 0) $display("OK:    GPU no VRAM access while held");
      @(negedge free_clk) dbg_stoptime = 1'b0;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_HELD | GS_EMPTY | GS_BUSY);
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      gpu_check_touched("freeze/release");

      $display("--- freeze with nothing in progress, then commands queued while held");
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(DBG_CTRL, 32'h2);
      @(negedge free_clk) dbg_stoptime = 1'b1;
      repeat(4) @(posedge free_clk);
      // idle and frozen: HELD = 1 (the freeze has taken effect), not BUSY
      reg_rd_mask(GPU_STAT, GS_HELD | GS_EMPTY, GS_HELD | GS_BUSY | GS_PRIM_BUSY | GS_EMPTY);
      gpu_mon_noacc = 1'b1;
      gpu_c_size(14'd9, 14'd7);                          // 2 words (any FIFO depth):
      gpu_c_exec(GPU_FILL, 4'd0, 3'b000, 3'b000);        // the last destination and colour
      repeat(200) @(posedge free_clk);
      // work queued while frozen: HELD and BUSY, nothing consumed, no access
      reg_rd_mask(GPU_STAT, GS_HELD | GS_BUSY | 32'h0200, GS_HELD | GS_BUSY | GS_PRIM_BUSY | 32'hFF00);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_GPU_ALL);
      gpu_mon_noacc = 1'b0;
      if (gpu_mon_noacc_hits == 0) $display("OK:    GPU no VRAM access while held with work queued");
      @(negedge free_clk) dbg_stoptime = 1'b0;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, GS_EMPTY, GS_HELD | GS_EMPTY | GS_BUSY);
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE);
      gpu_check_touched("queued while held");

      $display("--- random freeze toggling");
      for (tz_k = 0; tz_k < 8; tz_k = tz_k + 1) begin
         tz_mode = (tz_k % 4 == 0) ? 0 : (tz_k % 4 == 1) ? 2 : (tz_k % 4 == 2) ? 3 : 4;
         tz_cmd  = (tz_k % 3 == 0) ? GPU_FILL : (tz_k % 3 == 1) ? GPU_COPY : GPU_COPYT;
         gpu_set_mode(tz_mode);
         gpu_c_src(16'd77, 32'd3000 + 13 * tz_k);
         gpu_c_dst(16'd81, 32'd60000 + 5 * tz_k);
         gpu_c_size(14'd25, 14'd12);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(gpu_get_px(32'd3000 + 13 * tz_k, gpu_bl(tz_mode)));
         gpu_c_exec(tz_cmd, $random(gpu_seed) & 15, $random(gpu_seed) & 7, 3'b000);
         reg_wr(DBG_CTRL, 32'h2);
         tz_waits = 0;
         while (tz_waits < 40) begin
            repeat(1 + ($random(gpu_seed) & 31)) @(negedge free_clk);
            if (tz_k & 1) dbg_stoptime = ~dbg_stoptime;
            else begin
               dbg_stoptime = 1'b1;
               reg_wr(DBG_CTRL, (tz_waits & 1) ? 32'h2 : 32'h0);
            end
            tz_waits = tz_waits + 1;
         end
         @(negedge free_clk) dbg_stoptime = 1'b0;
         reg_wr(DBG_CTRL, 32'h0);
         gpu_wait_idle;
         $display("       mode %0d cmd %h op %0d", tz_mode, tz_cmd, gpu_x_op);
         gpu_check_touched("random freeze");
      end

      if (GPU_XY_EN != 0) begin
         $display("--- clipped-away FILL, freeze 0..40 cycles after the EXEC");
         gpu_set_mode(3);
         gpu_c_dst_xy(16'd64, 32'd4096);
         gpu_c_clip(0, 0, 9, 9);
         gpu_c_size(14'd5, 14'd5);
         gpu_wait_idle;
         reg_wr(IRQ_EN, IF_DONE);
         for (tz_d = 0; tz_d <= 40; tz_d = tz_d + 1) begin
            reg_wr(IRQ_FLAG, IF_GPU_ALL);
            gpu_c_xy(50, 50);
            gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
            reg_wr(DBG_CTRL, 32'h2);
            repeat (tz_d) @(posedge free_clk);                // hclk may be gated (ICG)
            tz_frz = 1'b1;
            @(negedge free_clk) dbg_stoptime = 1'b1;
            repeat (80) @(posedge free_clk);
            @(negedge free_clk) dbg_stoptime = 1'b0;
            tz_frz = 1'b0;
            reg_wr(DBG_CTRL, 32'h0);
            gpu_wait_idle;
            reg_rd_mask(IRQ_FLAG, IF_DONE, IF_DONE);
         end
         reg_wr(IRQ_EN, 32'h0);
         gpu_c_noclip;
      end

      gpu_check_all("freeze end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
