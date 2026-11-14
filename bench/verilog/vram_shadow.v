//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    vram_shadow
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : vram_shadow.v
// Module Description : VRAM shadow and pipelined bus drivers for the stress
//                      tests (`included inside tb_belenos):
//                      - a shadow of the VRAM (vsh_mem), back-door fill and
//                        re-synchronisation, and a whole-VRAM compare
//                        (vsh_check_touched: the words written through the
//                        window since the last call and their neighbours,
//                        then every word);
//                      - display register wrappers that keep the mode, width,
//                        frame pointers and FRAME_SEL;
//                      - pipelined AHB burst drivers, one per port
//                        (vsh_rburst, vsh_vburst), with an operation queue
//                        whose expected values come from the shadow at
//                        enqueue time. Each port has its own variables, so
//                        both may run in a fork.
//----------------------------------------------------------------------------

localparam integer VSH_PA_W    = VRAM_AW + 5;
localparam  [31:0] VSH_PA_MASK = (VSH_PA_W >= 32) ? 32'hFFFF_FFFF : ((32'h1 << VSH_PA_W) - 32'h1);
localparam  [31:0] VSH_DIM_MASK = (32'h1 << DIM_W) - 32'h1;
localparam integer VSH_QMAX    = 1024;

// Shadow state
reg         [31:0] vsh_mem       [0:VRAM_WORDS-1];
reg          [2:0] vsh_mode;
reg         [31:0] vsh_disp_w;
reg         [31:0] vsh_frame_ptr [0:3];
reg         [31:0] vsh_frame_sel;
integer            vsh_seed;
integer            vsh_i;
reg         [31:0] vsh_tlist     [0:VSH_QMAX-1];   // words written through the window queue
integer            vsh_tn;

initial begin
   for (vsh_i = 0; vsh_i < VRAM_WORDS; vsh_i = vsh_i + 1)
      vsh_mem[vsh_i] = 32'h0;
   vsh_mode      = 3'd0;
   vsh_disp_w    = 32'd1;
   for (vsh_i = 0; vsh_i < 4; vsh_i = vsh_i + 1)
      vsh_frame_ptr[vsh_i] = 32'h0;
   vsh_frame_sel = 32'h0;
   vsh_seed = `SEED;
   vsh_tn   = 0;
end

function [31:0] vsh_bl;                    // bpp_log2 of a GFX_MODE
   input [2:0] mode;
   begin
      vsh_bl = (mode >= 3'd4) ? 32'd4 : {29'h0, mode};
   end
endfunction

function [31:0] vsh_ppw;
   input [2:0] mode;
   begin
      vsh_ppw = 32'd32 >> vsh_bl(mode);
   end
endfunction

function [31:0] vsh_pmask;                 // right-aligned pixel mask
   input [2:0] mode;
   begin
      vsh_pmask = (32'h1 << (32'h1 << vsh_bl(mode))) - 32'h1;
   end
endfunction

// Deterministic non-zero fill pattern
function [31:0] vsh_hash;
   input [31:0] w;
   input [31:0] salt;
   reg   [31:0] x;
   begin
      x = (w + salt) * 32'h9E37_79B1;
      x = x ^ (x >> 15);
      x = x * 32'h85EB_CA6B;
      x = x ^ (x >> 13);
      vsh_hash = x;
   end
endfunction

// Back-door fill of the VRAM model and the shadow (DUT must be idle)
task vsh_fill;
   input [31:0] lo;
   input [31:0] n;
   input [31:0] salt;
   integer      i;
   begin
      for (i = lo; i < lo + n; i = i + 1)
         if (i < VRAM_WORDS) begin
            vram_mem[i] = vsh_hash(i, salt);
            vsh_mem[i]   = vsh_hash(i, salt);
         end
   end
endtask

// Re-synchronise the shadow from the VRAM model (after checking it)
task vsh_resync;
   input [31:0] lo;
   input [31:0] n;
   integer      i;
   begin
      for (i = lo; i < lo + n; i = i + 1)
         if (i < VRAM_WORDS) vsh_mem[i] = vram_mem[i];
   end
endtask


//============================================================================
// Display register wrappers (DUT + shadow state)
//============================================================================
task vsh_set_mode;
   input [2:0] mode;
   begin
      reg_wr(CTRL, {29'h0, mode});
      vsh_mode = mode;
   end
endtask

task vsh_disp;
   input [31:0] w;
   input [31:0] h;
   reg   [31:0] wm;
   begin
      reg_wr(DISP_SIZE, ((h & VSH_DIM_MASK) << 16) | (w & VSH_DIM_MASK));
      wm = w & VSH_DIM_MASK;
      vsh_disp_w = (wm == 0) ? 32'd1 : wm;
   end
endtask

task vsh_frame;
   input integer n;
   input  [31:0] ptr;
   begin
      reg_wr(FRAME0_PTR + 4*n, ptr);
      vsh_frame_ptr[n] = ptr & VSH_PA_MASK;
   end
endtask

task vsh_fsel;
   input [31:0] v;
   begin
      reg_wr(FRAME_SEL, v);
      vsh_frame_sel = v;
   end
endtask

task vsh_check_touched;
   integer      i, j, nerr;
   reg   [31:0] v, w;
   begin
      nerr = 0;
      tb_checks = tb_checks + 1;
      for (i = 0; i < vsh_tn; i = i + 1)
         for (j = -1; j <= 1; j = j + 1) begin
            w = vsh_tlist[i] + j;
            if (w < VRAM_WORDS) begin
               vram_rd_val(4*w, SZ_W, v);
               if (v !== vsh_mem[w]) begin
                  nerr = nerr + 1;
                  if (nerr <= 8)
                     $display("ERROR: VRAM word 0x%h -- window read 0x%h / expected 0x%h %t", w, v, vsh_mem[w], $time);
                  error = error + 1;
               end
            end
         end
      for (i = 0; i < VRAM_WORDS; i = i + 1)
         if (vram_mem[i] !== vsh_mem[i]) begin
            nerr = nerr + 1;
            if (nerr <= 16)
               $display("ERROR: VRAM model word 0x%h = 0x%h / expected 0x%h (stray or missing write) %t", i[31:0], vram_mem[i], vsh_mem[i], $time);
            error = error + 1;
            vsh_mem[i] = vram_mem[i];
         end
      if (nerr == 0)
         $display("OK:    %0d window-written words (+neighbours) and the whole VRAM match the model %t", vsh_tn, $time);
      vsh_tn = 0;
   end
endtask


//============================================================================
// Pipelined register-port burst
//============================================================================
reg  [31:0] vsh_rq_addr   [0:VSH_QMAX-1];
reg         vsh_rq_wr     [0:VSH_QMAX-1];
reg  [31:0] vsh_rq_wdata  [0:VSH_QMAX-1];
reg   [3:0] vsh_rq_master [0:VSH_QMAX-1];
reg  [31:0] vsh_rq_exp    [0:VSH_QMAX-1];
reg         vsh_rq_chk    [0:VSH_QMAX-1];
reg  [31:0] vsh_rq_rdata  [0:VSH_QMAX-1];
integer     vsh_rq_waits  [0:VSH_QMAX-1];
integer     vsh_rq_done   [0:VSH_QMAX-1];
integer     vsh_rq_n;
integer     vsh_rq_err;
initial vsh_rq_n = 0;

task vsh_q_reset;
   begin
      vsh_rq_n = 0;
   end
endtask

task vsh_q_raw;
   input  [31:0] addr;
   input         wr;
   input  [31:0] wdata;
   input   [3:0] master;
   input  [31:0] exp;
   input         chk;
   begin
      if (vsh_rq_n >= VSH_QMAX) begin
         $display("ERROR: register burst queue overflow %t", $time);
         error = error + 1;
      end else begin
         vsh_rq_addr[vsh_rq_n]   = addr;
         vsh_rq_wr[vsh_rq_n]     = wr;
         vsh_rq_wdata[vsh_rq_n]  = wdata;
         vsh_rq_master[vsh_rq_n] = master;
         vsh_rq_exp[vsh_rq_n]    = exp;
         vsh_rq_chk[vsh_rq_n]    = chk;
         vsh_rq_n = vsh_rq_n + 1;
      end
   end
endtask

task vsh_q_reg_wr;
   input [31:0] addr;
   input [31:0] d;
   begin
      vsh_q_raw(addr, 1'b1, d, HART_MASTER, 32'h0, 1'b0);
   end
endtask

task vsh_q_reg_rd;
   input [31:0] addr;
   input [31:0] exp;
   begin
      vsh_q_raw(addr, 1'b0, 32'h0, HART_MASTER, exp, 1'b1);
   end
endtask

// Drive the queued transfers with back-to-back address phases. The bus is
// driven on falling edges; hready / hresp / hrdata are sampled 2 ns later
// (after the bench's 1 ns input delay), i.e. the values of the completing
// rising edge. vsh_rq_done = cycle index of the completion, vsh_rq_waits = wait
// states of the data phase.
task vsh_rburst;
   integer ai, di, cyc, wcnt;
   begin
      ai = 0; di = -1; cyc = 0; wcnt = 0;
      vsh_rq_err = 0;
      @(negedge free_clk);
      while ((ai < vsh_rq_n) || (di >= 0)) begin
         if (ai < vsh_rq_n) begin
            r_hsel = 1'b1; r_haddr = vsh_rq_addr[ai]; r_htrans = 2'b10; r_hwrite = vsh_rq_wr[ai];
            r_hsize = 3'b010; r_hprot = 4'h3; r_hsmode = 1'b0; r_hmaster = vsh_rq_master[ai];
         end else begin
            r_hsel = 1'b0; r_htrans = 2'b00; r_hwrite = 1'b0;
         end
         if ((di >= 0) && vsh_rq_wr[di]) r_hwdata = vsh_rq_wdata[di];
         #2;
         if (r_hready === 1'b1) begin
            if (di >= 0) begin
               vsh_rq_rdata[di] = r_hrdata;
               vsh_rq_waits[di] = wcnt;
               vsh_rq_done[di]  = cyc;
               if (r_hresp !== 1'b0) begin
                  $display("ERROR: burst r-port item %0d address 0x%h -- hresp %b %t", di, vsh_rq_addr[di], r_hresp, $time);
                  error = error + 1; vsh_rq_err = vsh_rq_err + 1;
               end else if (!vsh_rq_wr[di] && vsh_rq_chk[di] && (r_hrdata !== vsh_rq_exp[di])) begin
                  $display("ERROR: burst r-port item %0d read 0x%h (master %h) -- 0x%h / expected 0x%h %t",
                           di, vsh_rq_addr[di], vsh_rq_master[di], r_hrdata, vsh_rq_exp[di], $time);
                  error = error + 1; vsh_rq_err = vsh_rq_err + 1;
               end
            end
            if (ai < vsh_rq_n) begin
               di = ai; ai = ai + 1;
            end else
               di = -1;
            wcnt = 0;
         end else begin
            wcnt = wcnt + 1;
            if (wcnt > AHB_MAX_WAIT) begin
               $display("ERROR: burst r-port hung at item %0d %t", di, $time);
               error = error + 1;
               di = -1; ai = vsh_rq_n;
            end
         end
         @(negedge free_clk);
         cyc = cyc + 1;
      end
      r_hsel = 1'b0; r_htrans = 2'b00; r_hwrite = 1'b0;
      @(posedge free_clk);
      if (vsh_rq_err == 0)
         $display("OK:    r-port burst of %0d transfers in %0d cycles %t", vsh_rq_n, cyc, $time);
   end
endtask


//============================================================================
// Pipelined VRAM-window burst (word or sub-word, own variables)
//============================================================================
reg  [31:0] vsh_vq_addr   [0:VSH_QMAX-1];
reg         vsh_vq_iswr     [0:VSH_QMAX-1];
reg   [1:0] vsh_vq_size   [0:VSH_QMAX-1];
reg  [31:0] vsh_vq_wdata  [0:VSH_QMAX-1];
reg  [31:0] vsh_vq_exp    [0:VSH_QMAX-1];
reg         vsh_vq_chk    [0:VSH_QMAX-1];
integer     vsh_vq_n;
integer     vsh_vq_err;
initial vsh_vq_n = 0;

task vsh_vq_reset;
   begin
      vsh_vq_n = 0;
   end
endtask

// Word write through the window (updates the shadow)
task vsh_vq_wr;
   input [31:0] word;
   input [31:0] d;
   begin
      vsh_vq_addr[vsh_vq_n] = 4*word; vsh_vq_iswr[vsh_vq_n] = 1'b1; vsh_vq_size[vsh_vq_n] = SZ_W;
      vsh_vq_wdata[vsh_vq_n] = d; vsh_vq_exp[vsh_vq_n] = 32'h0; vsh_vq_chk[vsh_vq_n] = 1'b0;
      vsh_vq_n = vsh_vq_n + 1;
      vsh_mem[word] = d;
      if (vsh_tn < VSH_QMAX) begin vsh_tlist[vsh_tn] = word; vsh_tn = vsh_tn + 1; end
   end
endtask

// Word read through the window, checked against the shadow
task vsh_vq_rd;
   input [31:0] word;
   begin
      vsh_vq_addr[vsh_vq_n] = 4*word; vsh_vq_iswr[vsh_vq_n] = 1'b0; vsh_vq_size[vsh_vq_n] = SZ_W;
      vsh_vq_wdata[vsh_vq_n] = 32'h0; vsh_vq_exp[vsh_vq_n] = vsh_mem[word]; vsh_vq_chk[vsh_vq_n] = 1'b1;
      vsh_vq_n = vsh_vq_n + 1;
   end
endtask

task vsh_vburst;
   integer ai, di, cyc, wcnt;
   reg [31:0] lane;
   begin
      ai = 0; di = -1; cyc = 0; wcnt = 0;
      vsh_vq_err = 0;
      @(negedge free_clk);
      while ((ai < vsh_vq_n) || (di >= 0)) begin
         if (ai < vsh_vq_n) begin
            v_hsel = 1'b1; v_haddr = vsh_vq_addr[ai]; v_htrans = 2'b10; v_hwrite = vsh_vq_iswr[ai];
            v_hsize = {1'b0, vsh_vq_size[ai]}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
         end else begin
            v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
         end
         if ((di >= 0) && vsh_vq_iswr[di]) begin
            lane = vsh_vq_wdata[di];
            v_hwdata = (vsh_vq_size[di] == SZ_B) ? {4{lane[7:0]}} :
                       (vsh_vq_size[di] == SZ_H) ? {2{lane[15:0]}} : lane;
         end
         #2;
         if (v_hready === 1'b1) begin
            if (di >= 0) begin
               if (v_hresp !== 1'b0) begin
                  $display("ERROR: burst v-port item %0d address 0x%h -- hresp %b %t", di, vsh_vq_addr[di], v_hresp, $time);
                  error = error + 1; vsh_vq_err = vsh_vq_err + 1;
               end else if (!vsh_vq_iswr[di] && vsh_vq_chk[di] && (v_hrdata !== vsh_vq_exp[di])) begin
                  $display("ERROR: burst v-port item %0d read 0x%h -- 0x%h / expected 0x%h %t",
                           di, vsh_vq_addr[di], v_hrdata, vsh_vq_exp[di], $time);
                  error = error + 1; vsh_vq_err = vsh_vq_err + 1;
               end
            end
            if (ai < vsh_vq_n) begin
               di = ai; ai = ai + 1;
            end else
               di = -1;
            wcnt = 0;
         end else begin
            wcnt = wcnt + 1;
            if (wcnt > AHB_MAX_WAIT) begin
               $display("ERROR: burst v-port hung at item %0d %t", di, $time);
               error = error + 1;
               di = -1; ai = vsh_vq_n;
            end
         end
         @(negedge free_clk);
         cyc = cyc + 1;
      end
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
      @(posedge free_clk);
      if (vsh_vq_err == 0)
         $display("OK:    v-port burst of %0d transfers in %0d cycles %t", vsh_vq_n, cyc, $time);
   end
endtask
