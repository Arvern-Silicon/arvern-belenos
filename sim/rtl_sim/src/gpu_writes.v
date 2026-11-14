//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_writes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_writes.v
// Module Description : When and how the GPU writes its destination words
//                      (doc/gpu_commands.md, fences and concurrent CPU access):
//                      1. FENCE completes only after the writes of the
//                         commands before it are in the VRAM: a stream of
//                         random primitives (FILL, COPY, COPY_TRANSP with
//                         the swaps and ops reading D, EXPAND, TEXSPAN,
//                         TEXRECT, triangles, every depth) each followed by
//                         a FENCE, pushed back to back while a background
//                         manager writes the VRAM window on almost every
//                         cycle (the GPU's write-back slot waits for its
//                         VRAM cycle); at the cycle GPU_FENCE takes a tag,
//                         every destination word of the commands before it
//                         holds its model value (backdoor). Fences reached
//                         within 3 cycles of the GPU's last write, and
//                         fences whose last write waited 3 cycles or more
//                         for its VRAM cycle, are counted (none: a test
//                         bug);
//                      2. byte enables: each GPU write enables only bytes
//                         holding pixels of its rectangle (whole bytes below
//                         8 bpp; never a clipped pixel nor one outside a
//                         triangle), every depth, swaps, partial words at
//                         both row ends, x/y clip; while it draws, the CPU
//                         writes through the window the other bytes of the
//                         same words (they keep the CPU's value), the
//                         destination prefilled with a pattern; the whole
//                         VRAM compared through the backdoor.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer WS_SLO   = 1000;              // sources, textures: words [1000, 7000)
localparam integer WS_SHI   = 7000;
localparam integer WS_DLO   = 8000;              // destinations: words [8000, 24000)
localparam integer WS_DHI   = 24000;
localparam integer WS_BLO   = 30000;             // background window traffic: words [30000, 34000)
localparam integer WS_BHI   = 34000;
localparam integer WS_PITCH = 256;               // pixels (every depth)
localparam integer WS_WMAX  = (GPU_DIM_MASK >= 24) ? 24 : GPU_DIM_MASK;
localparam integer WS_HMAX  = (GPU_DIM_MASK >= 10) ? 10 : GPU_DIM_MASK;
localparam integer WS_NF    = 48;                // fences in the stream
localparam integer WS_SMAX  = 65536;             // set entries
localparam integer WS_SEEN  = (VRAM_WORDS > 65536) ? 65536 : VRAM_WORDS;

integer    ws_k, ws_i, ws_n, ws_bl, ws_ppw, ws_kind, ws_w, ws_h, ws_x, ws_y, ws_last;
integer    ws_nset, ws_close, ws_fev, ws_gapmin, ws_cpu, ws_nprim;
reg  [2:0] ws_mode, ws_dsw, ws_ssw;
reg  [3:0] ws_op;
reg [31:0] ws_v, ws_db, ws_sb;

function integer ws_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      ws_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

//----------------------------------------------------------------------------
// Background window manager (own v-port driver): word writes to [WS_BLO,
// WS_BHI) pipelined, a new address phase every cycle the previous transfer
// completes (now and then an idle cycle), mirrored in the shadow
//----------------------------------------------------------------------------
reg        wb_en = 1'b0, wb_busy = 1'b0;
integer    wb_seed, wb_nw = 0, wb_g;
integer    wb_ai, wb_di;
reg [31:0] wb_av, wb_dv;

always begin : wb_bg
   @(negedge free_clk);
   if (!wb_en && (wb_di < 0))
      wb_busy = 1'b0;
   else begin
      wb_busy = 1'b1;
      if (wb_en && (({$random(wb_seed)} % 8) != 0)) begin
         wb_ai = WS_BLO + ({$random(wb_seed)} % (WS_BHI - WS_BLO));
         v_hsel = 1'b1; v_haddr = 4 * wb_ai; v_htrans = 2'b10; v_hwrite = 1'b1;
         v_hsize = {1'b0, SZ_W}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      end else begin
         wb_ai = -1;
         v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
      end
      if (wb_di >= 0) v_hwdata = wb_dv;
      #2;
      wb_g = 0;
      while (v_hready !== 1'b1) begin                        // a wait state: hold both phases
         @(negedge free_clk);
         #2;
         wb_g = wb_g + 1;
         if (wb_g > 1000) begin
            $display("ERROR: background window burst hung %t", $time);
            error = error + 1;
            wb_en = 1'b0;
         end
      end
      if (v_hresp !== 1'b0) begin
         $display("ERROR: background window write got ERROR %t", $time);
         error = error + 1;
      end
      if (wb_di >= 0) begin
         gpu_shadow[wb_di] = wb_dv;
         wb_nw = wb_nw + 1;
      end
      wb_di = wb_ai;
      wb_dv = $random(wb_seed);
      if (wb_di < 0) begin
         v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
         wb_busy = wb_en;
      end
   end
end
initial wb_di = -1;

task wb_stop;
   begin
      wb_en = 1'b0;
      while (wb_busy || (wb_di >= 0)) @(negedge free_clk);
      @(negedge free_clk);
   end
endtask

//----------------------------------------------------------------------------
// One random primitive at the current depth, modelled with the walk record.
// kind 0 FILL, 1 COPY, 2 COPY_TRANSP, 3 EXPAND, 4 TEXSPAN, 5 TEXRECT (x/y),
// 6 TRI (x/y), 7 FILL in x/y mode with a clip window cutting it
//----------------------------------------------------------------------------
task ws_prim;
   input integer kind;
   integer       k;
   begin
      k = kind;
      if (((k == 5) || (k == 7)) && (GPU_XY_EN == 0)) k = 1;
      if ((k == 6) && ((GPU_TRI_EN == 0) || (GPU_XY_EN == 0))) k = 0;
      ws_w   = 1 + ws_rnd(WS_WMAX);
      ws_h   = 1 + ws_rnd(WS_HMAX);
      ws_dsw = $random(gpu_seed);
      ws_ssw = $random(gpu_seed);
      if ((k == 2) || (k >= 4)) ws_ssw = 3'b000;
      ws_op  = (k == 2) ? (ws_rnd(2) ? 4'd0 : 4'd4) : $random(gpu_seed);
      ws_db  = (WS_DLO + 2600 + ws_rnd(9000)) * ws_ppw + ws_rnd(ws_ppw);
      ws_sb  = (WS_SLO + 2700 + ws_rnd(600)) * ws_ppw + ws_rnd(ws_ppw);
      if ((k == 5) || (k == 6) || (k == 7)) begin
         ws_x = 2 + ws_rnd(20);
         ws_y = 1 + ws_rnd(4);
         gpu_c_dst_xy(WS_PITCH, (WS_DLO + 2600 + ws_rnd(9000)) * ws_ppw + ws_rnd(ws_ppw));
         gpu_c_xy(ws_x, ws_y);
         if (k == 7)
            gpu_c_clip(ws_x + ws_rnd(3), ws_y + ws_rnd(2), ws_x + ws_w - 1 - ws_rnd(3), ws_y + ws_h - 1 - ws_rnd(2));
         else
            gpu_c_clip(-2048, -2048, 2047, 2047);
      end else
         gpu_c_dst(WS_PITCH, ws_db);
      gpu_c_src(WS_PITCH, ws_sb);
      gpu_c_size(ws_w, ws_h);
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed) & gpu_pmask(ws_bl) & 32'h3);   // some source pixels transparent
      gpu_rec_begin;
      case (k)
        0, 7: gpu_c_exec_xy(GPU_FILL, ws_op, ws_dsw, 3'b000);
        1:    gpu_c_exec_xy(GPU_COPY, ws_op, ws_dsw, ws_ssw);
        2:    gpu_c_exec_xy(GPU_COPYT, ws_op, ws_dsw, ws_ssw);
        3:    begin                                       // the source in its own depth's pixels
                 ws_n = ws_rnd(4);
                 gpu_c_src(16'd0, (WS_SLO + 2700 + ws_rnd(600)) * (32 >> ws_n) + ws_rnd(32 >> ws_n));
                 gpu_c_expand(0, ws_dsw, ws_rnd(2), ws_n);
              end
        4:    begin
                 gpu_c_tex(4'd4, 4'd4, ws_rnd(2), ws_dsw, 1'b0, 1'b0, $random(gpu_seed));
                 gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                 gpu_c_step(16'h0400 + ws_rnd(16'h0800), ws_rnd(16'h0400) - 16'h0200);
                 gpu_c_texspan(0, ws_w);
              end
        5:    begin
                 gpu_c_tex(4'd4, 4'd4, ws_rnd(2), ws_dsw, 1'b0, 1'b0, $random(gpu_seed));
                 gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                 gpu_c_step(16'h0400 + ws_rnd(16'h0800), ws_rnd(16'h0400) - 16'h0200);
                 gpu_c_step_row(ws_rnd(16'h0400) - 16'h0200, 16'h0400 + ws_rnd(16'h0800));
                 gpu_c_texrect(0);
              end
        default: begin
                 gpu_c_vtx(0, 16 * ws_x + ws_rnd(16), 16 * ws_y + ws_rnd(16));
                 gpu_c_vtx(1, 16 * (ws_x + ws_w) + ws_rnd(16), 16 * ws_y + 8 + ws_rnd(16));
                 gpu_c_vtx(2, 16 * (ws_x + ws_rnd(4)) + ws_rnd(16), 16 * (ws_y + ws_h) + ws_rnd(16));
                 gpu_c_trifill(ws_op);
              end
      endcase
      gpu_rec_end;
      ws_nprim = ws_nprim + 1;
   end
endtask

//----------------------------------------------------------------------------
// 1. Fences: the destination words of the commands before each fence
//----------------------------------------------------------------------------
reg  [31:0] fw_wd  [0:WS_SMAX-1];
reg  [31:0] fw_val [0:WS_SMAX-1];
integer     fw_beg [0:WS_NF];
integer     fw_end [0:WS_NF];
integer     fw_seen [0:WS_SEEN-1];
reg         fw_on = 1'b0;
integer     fw_bad = 0, fw_lastwr = 0;
reg  [23:0] fw_prev;

`define WS_DEC dut.u_core.G_GPU.u_gpu.u_dec

// The GPU's last write: its cycle and the cycles it waited for its grant
integer     fw_wwait = 0, fw_lastwait = 0, fw_waited = 0, fw_waitmax = 0;
always @(posedge hclk)
   if (hresetn_d === 1'b1) begin
      if ((dut.u_core.u_vram_arb.req_i[VRQ_GPU] === 1'b1) && (dut.u_core.u_vram_arb.we_i[VRQ_GPU] === 1'b1)) begin
         if (dut.u_core.u_vram_arb.gnt_o[VRQ_GPU] === 1'b1) begin
            fw_lastwr   = gpu_cyc;
            fw_lastwait = fw_wwait;
            fw_wwait    = 0;
         end else
            fw_wwait = fw_wwait + 1;
      end
   end

// At the cycle GPU_FENCE takes tag t (1 .. WS_NF): every word of sets 1 .. t
// holds its value (sets are disjoint in time: a later command may overwrite
// a word, the value recorded is the one right after the command)
always @(posedge hclk)
   if (fw_on && (GPU_EN != 0)) begin
      if (`WS_DEC.fence_o !== fw_prev) begin : fw_chk
         integer t, ii, gap;
         t       = `WS_DEC.fence_o;
         fw_prev = `WS_DEC.fence_o;
         gap     = gpu_cyc - fw_lastwr;
         @(negedge free_clk);                           // the VRAM model's writes of this edge done
         if ((t >= 1) && (t <= WS_NF)) begin
            ws_fev = ws_fev + 1;
            if (gap < ws_gapmin) ws_gapmin = gap;
            if (gap <= 3) ws_close = ws_close + 1;
            if (fw_lastwait >= 3) fw_waited = fw_waited + 1;
            if (fw_lastwait > fw_waitmax) fw_waitmax = fw_lastwait;
            for (ii = fw_beg[t]; ii < fw_end[t]; ii = ii + 1)
               if (vram_mem[fw_wd[ii]] !== fw_val[ii]) begin
                  fw_bad = fw_bad + 1;
                  if (fw_bad <= 6)
                     $display("ERROR: GPU_FENCE = %0d while word 0x%h of the command before it is 0x%h, expected 0x%h (a write still pending or a wrong value) %t",
                              t, fw_wd[ii], vram_mem[fw_wd[ii]], fw_val[ii], $time);
                  error = error + 1;
               end
         end
      end
   end

// The written words of the last primitive (walk record) as set t
task fw_set;
   input integer t;
   integer       kk, wd;
   begin
      fw_beg[t] = ws_nset;
      for (kk = 0; (kk < gpu_rec_n) && (kk < GPU_REC_MAX); kk = kk + 1)
         if (gpu_rec_wr[kk]) begin
            wd = gpu_word_of(gpu_rec_pa[kk], gpu_rec_bl);
            if ((wd < WS_SEEN) && (fw_seen[wd] != t) && (ws_nset < WS_SMAX)) begin
               fw_seen[wd]     = t;
               fw_wd[ws_nset]  = wd;
               fw_val[ws_nset] = gpu_shadow[wd];
               ws_nset = ws_nset + 1;
            end
         end
      fw_end[t] = ws_nset;
   end
endtask

//----------------------------------------------------------------------------
// 2. Byte enables, the CPU writing the other bytes of the same words
//----------------------------------------------------------------------------
task ws_bytes_case;
   input integer kind;
   integer       kk, wd, bb, nfree, lastw;
   reg     [7:0] bv;
   reg     [3:0] ok;
   begin
      gpu_wait_idle;
      gpu_preload_rand(WS_DLO, WS_DHI);                  // the pattern under the rectangle
      gpu_be_clear;
      gpu_be_en = 1'b1;
      ws_prim(kind);
      // the bytes of the rectangle's words that hold none of its pixels
      nfree = 0;
      lastw = -1;
      for (kk = 0; (kk < gpu_rec_n) && (kk < GPU_REC_MAX); kk = kk + 1) begin
         wd = gpu_word_of(gpu_rec_pa[kk], gpu_rec_bl);
         if ((wd != lastw) && (wd < GPU_BE_WORDS)) begin
            lastw = wd;
            ok    = gpu_be_ok[wd];
            if (ok != 4'hF)
               for (bb = 0; bb < 4; bb = bb + 1)
                  if (!ok[bb]) begin
                     bv = $random(gpu_seed);
                     vram_wr(4 * wd + bb, {4{bv}}, SZ_B);
                     gpu_shadow[wd] = (gpu_shadow[wd] & ~(32'hFF << (8 * bb))) | ({24'h0, bv} << (8 * bb));
                     nfree = nfree + 1;
                  end
         end
      end
      ws_cpu = ws_cpu + nfree;
      gpu_wait_idle;
      gpu_be_en = 1'b0;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_all("byte enables");
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|  GPU: fences after the writes, byte enables   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed = `SEED;
      wb_seed  = `SEED ^ 32'h0BAD_F00D;
      gpu_push_wait = 1'b1;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_set_dispw(64);
      ws_nset = 0; ws_close = 0; ws_fev = 0; ws_gapmin = 1000000; ws_cpu = 0; ws_nprim = 0;
      for (ws_i = 0; ws_i < WS_SEEN; ws_i = ws_i + 1) fw_seen[ws_i] = -1;

      //--------------------------------------------------------------
      $display("--- 1. FENCE after the writes, window traffic on almost every cycle");
      gpu_push({OP_FENCE, 4'h0, 24'h000000});
      gpu_wait_idle;
      reg_rd(GPU_FENCE, 32'h0);
      fw_prev = 24'h0;
      fw_on   = 1'b1;
      wb_en   = 1'b1;
      for (ws_k = 1; ws_k <= WS_NF; ws_k = ws_k + 1) begin
         if ((ws_k % 8) == 1) begin                                // GFX_MODE changed with the GPU idle
            gpu_wait_idle;
            ws_mode = ws_rnd(5);
            gpu_set_mode(ws_mode);
            ws_bl  = gpu_bl(ws_mode);
            ws_ppw = 32 >> ws_bl;
         end
         ws_prim(ws_rnd(8));
         fw_set(ws_k);
         gpu_push({OP_FENCE, 4'h0, ws_k[23:0]});
      end
      gpu_wait_idle;
      wb_stop;
      fw_on = 1'b0;
      reg_rd(GPU_FENCE, WS_NF);
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      $display("INFO:  %0d fences checked (%0d words), %0d within 3 cycles of the GPU's last write (closest %0d), %0d whose last write waited 3 cycles or more for its VRAM cycle (longest %0d), %0d window writes",
               ws_fev, ws_nset, ws_close, ws_gapmin, fw_waited, fw_waitmax, wb_nw);
      if (ws_fev != WS_NF) begin
         $display("ERROR: %0d fence tags seen, %0d expected %t", ws_fev, WS_NF, $time);
         error = error + 1;
      end
      if ((ws_close == 0) || (fw_waited == 0))
         tb_error("gpu_writes: no fence right after a write delayed by the window (test bug: the check is vacuous)");
      gpu_check_all("fences");

      //--------------------------------------------------------------
      $display("--- 2. byte enables, the other bytes written by the CPU meanwhile");
      for (ws_k = 0; ws_k < 80; ws_k = ws_k + 1) begin
         ws_mode = ws_k % 5;
         gpu_wait_idle;
         gpu_set_mode(ws_mode);
         ws_bl  = gpu_bl(ws_mode);
         ws_ppw = 32 >> ws_bl;
         ws_bytes_case(ws_k / 5 % 8);
      end
      $display("INFO:  %0d GPU writes checked, %0d CPU byte writes into the rectangles' words", gpu_be_n, ws_cpu);
      if ((gpu_be_n == 0) || (ws_cpu == 0)) tb_error("gpu_writes: no byte-enable check (test bug)");

      gpu_check_all("gpu_writes end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
