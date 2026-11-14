//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_newkind_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_newkind_stress.v
// Module Description : EXEC_EXPAND / EXEC_TEXSPAN under the GPU controls:
//                      1. GPU_CTRL.ABORT and CTRL.GPU_EN = 0 at random points
//                         of a long TEXSPAN (power-of-two wrap and FREE_PITCH,
//                         TRANSP_EN) and of a large EXPAND (OPAQUE 0/1): the
//                         image is a prefix of the walk (every drawn pixel
//                         before every undrawn one, values exact), nothing
//                         else written, queued FENCE / EXEC flushed, no
//                         GPU_DONE unless the whole walk is there; then a
//                         new SET_SRC / SET_UV + EXEC drawn fully at once,
//                         and a TEXSPAN with no SET_UV restarting at u0/v0.
//                      2. Debug freeze toggled at random (dbg_stoptime and
//                         DBG_CTRL[1]) while EXPAND / TEXSPAN run with VRAM
//                         window traffic in parallel: no GPU_DONE while held
//                         mid-rectangle, one GPU_DONE after completion, the
//                         final VRAM equals the model.
//                      3. GPU_DONE per EXEC kind (SPAN, EXPAND, TEXSPAN,
//                         FILL, COPY; flag and irq_o), FENCE(0)/FENCE(1)
//                         alone (GPU_FENCE, no GPU_DONE), GPU_DONE and
//                         GPU_FENCE events counted with W1C polling: FENCE(1)
//                         before an EXPAND = 2 events, FENCE(0) = 1, FENCE(1)
//                         behind an EXPAND only once the EXPAND is complete;
//                         a mixed back-to-back burst with a FENCE(1) in the
//                         middle.
//                      4. Default pitches with DISP_CFG.PIX_DOUBLE, odd and
//                         even W: EXPAND destination pitch 0 = ceil(W/2) (W
//                         without doubling), source pitch 0 = rectangle width;
//                         TEXSPAN FREE_PITCH with SET_SRC pitch 0 = frame
//                         width; DISP_CFG flipped while a TEXSPAN runs (width
//                         taken at EXEC start) and while it waits in the FIFO
//                         behind an EXPAND (new width).
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer NK_DPITCH = 29;
localparam integer NK_SPITCH = 41;
localparam integer NK_DISPW  = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer NK_SRC_LO = 40;               // textures / expand sources: words [NK_SRC_LO, NK_SRC_HI)
localparam integer NK_SRC_HI = 280;
localparam integer NK_A_LO   = 300;              // destination region A: words [NK_A_LO, NK_B_LO)
localparam integer NK_B_LO   = 560;              // destination region B: words [NK_B_LO, NK_D_HI)
localparam integer NK_D_HI   = 860;
localparam integer NK_BG_LO  = 880;              // VRAM-window background traffic: words [NK_BG_LO, NK_BG_HI)
localparam integer NK_BG_HI  = 990;
localparam integer NK_NMAX   = (GPU_DIM_MASK >= 200) ? 200 : GPU_DIM_MASK;   // long TEXSPAN
localparam integer NK_EW     = (GPU_DIM_MASK >= 16) ? 16 : GPU_DIM_MASK;     // large EXPAND
localparam integer NK_EH     = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer NK_SMALL  = (GPU_DIM_MASK >= 6) ? 6 : GPU_DIM_MASK;
localparam integer NK_MAXP   = 512;


//============================================================================
// Background VRAM-window manager (own v-port driver; region NK_BG only)
//============================================================================
reg        nk_bg_en, nk_bg_busy;
integer    nk_bg_seed, nk_bg_nw, nk_bg_nr, nk_bg_waits;
reg [31:0] nk_bg_addr, nk_bg_data, nk_bg_raw, nk_bg_exp, nk_bg_lane;
reg  [1:0] nk_bg_size;
reg        nk_bg_wr;
initial begin nk_bg_en = 1'b0; nk_bg_busy = 1'b0; nk_bg_nw = 0; nk_bg_nr = 0; end

always begin : nk_bg
   @(negedge free_clk);
   if (nk_bg_en) begin
      nk_bg_busy = 1'b1;
      nk_bg_wr   = $random(nk_bg_seed);
      nk_bg_size = {$random(nk_bg_seed)} % 3;
      nk_bg_addr = 4 * (NK_BG_LO + ({$random(nk_bg_seed)} % (NK_BG_HI - NK_BG_LO))) + ({$random(nk_bg_seed)} & 3);
      nk_bg_addr = (nk_bg_size == SZ_W) ? (nk_bg_addr & ~32'h3) : (nk_bg_size == SZ_H) ? (nk_bg_addr & ~32'h1) : nk_bg_addr;
      nk_bg_data = $random(nk_bg_seed);
      nk_bg_lane = (nk_bg_size == SZ_B) ? {4{nk_bg_data[7:0]}} : (nk_bg_size == SZ_H) ? {2{nk_bg_data[15:0]}} : nk_bg_data;
      while (v_hready !== 1'b1) @(negedge free_clk);
      v_hsel = 1'b1; v_haddr = nk_bg_addr; v_htrans = 2'b10; v_hwrite = nk_bg_wr;
      v_hsize = {1'b0, nk_bg_size}; v_hprot = 4'h3; v_hsmode = 1'b0; v_hmaster = HART_MASTER;
      @(posedge free_clk);
      v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
      if (nk_bg_wr) v_hwdata = nk_bg_lane;
      nk_bg_waits = 0;
      @(negedge free_clk);
      while (v_hready !== 1'b1) begin @(negedge free_clk); nk_bg_waits = nk_bg_waits + 1; end
      nk_bg_raw = v_hrdata;
      if (v_hresp !== 1'b0) begin
         $display("ERROR: background window access 0x%h got ERROR %t", nk_bg_addr, $time);
         error = error + 1;
      end
      @(posedge free_clk);
      if (nk_bg_wr) begin
         if (nk_bg_size == SZ_W) gpu_shadow[nk_bg_addr >> 2] = nk_bg_lane;
         else if (nk_bg_size == SZ_H) begin
            if (nk_bg_addr[1]) gpu_shadow[nk_bg_addr >> 2][31:16] = nk_bg_lane[15:0];
            else               gpu_shadow[nk_bg_addr >> 2][15:0]  = nk_bg_lane[15:0];
         end else
            case (nk_bg_addr[1:0])
              2'd0:    gpu_shadow[nk_bg_addr >> 2][ 7: 0] = nk_bg_lane[7:0];
              2'd1:    gpu_shadow[nk_bg_addr >> 2][15: 8] = nk_bg_lane[7:0];
              2'd2:    gpu_shadow[nk_bg_addr >> 2][23:16] = nk_bg_lane[7:0];
              default: gpu_shadow[nk_bg_addr >> 2][31:24] = nk_bg_lane[7:0];
            endcase
         nk_bg_nw = nk_bg_nw + 1;
      end else begin
         nk_bg_exp = gpu_shadow[nk_bg_addr >> 2];
         nk_bg_exp = (nk_bg_size == SZ_B) ? ((nk_bg_exp >> (8 * nk_bg_addr[1:0])) & 32'hFF) :
                     (nk_bg_size == SZ_H) ? ((nk_bg_exp >> (16 * nk_bg_addr[1])) & 32'hFFFF) : nk_bg_exp;
         nk_bg_raw = (nk_bg_size == SZ_B) ? ((nk_bg_raw >> (8 * nk_bg_addr[1:0])) & 32'hFF) :
                     (nk_bg_size == SZ_H) ? ((nk_bg_raw >> (16 * nk_bg_addr[1])) & 32'hFFFF) : nk_bg_raw;
         if (nk_bg_raw !== nk_bg_exp) begin
            $display("ERROR: background window read 0x%h = 0x%h / expected 0x%h %t", nk_bg_addr, nk_bg_raw, nk_bg_exp, $time);
            error = error + 1;
         end
         nk_bg_nr = nk_bg_nr + 1;
      end
      nk_bg_busy = 1'b0;
      repeat({$random(nk_bg_seed)} % 6) @(negedge free_clk);
   end
end

task nk_bg_pause;
   begin
      nk_bg_en = 1'b0;
      while (nk_bg_busy) @(negedge free_clk);
      @(negedge free_clk);
   end
endtask


//============================================================================
// Helpers
//============================================================================
function integer nk_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      nk_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] nk_hi_color;             // random colour with the bits above the depth set
   input [31:0] rnd;
   input [31:0] pm;
   begin
      nk_hi_color = rnd | (~pm & 32'hFFFF) | 32'hA5A5_0000;
   end
endfunction

function [31:0] nk_vram_px;              // pixel read from the VRAM model (backdoor)
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   integer      off;
   begin
      wd  = pa >> (5 - bl);
      off = (pa & ((32 >> bl) - 1)) << bl;
      nk_vram_px = (vram_mem[wd] >> off) & gpu_pmask(bl);
   end
endfunction

task nk_chk_src;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < NK_SRC_LO) || (gpu_word_of(pa, bl) >= NK_SRC_HI))
         tb_error("source pixel outside the source region (test bug)");
   end
endtask

task nk_chk_dst;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < NK_A_LO) || (gpu_word_of(pa, bl) >= NK_D_HI))
         tb_error("destination pixel outside the destination regions (test bug)");
   end
endtask

task nk_check_irq;
   input exp;
   begin
      @(negedge free_clk);
      if (irq !== exp) begin
         $display("ERROR: irq_o = %b / expected %b %t", irq, exp, $time);
         error = error + 1;
      end
   end
endtask


//============================================================================
// Per-pixel record of the walk of one EXEC (abort prefix, completeness)
//============================================================================
reg [31:0] nk_epa  [0:NK_MAXP-1];
reg [31:0] nk_eold [0:NK_MAXP-1];
reg [31:0] nk_enew [0:NK_MAXP-1];
reg        nk_ewr  [0:NK_MAXP-1];
integer    nk_en, nk_ebl;
reg        nk_rec;
initial begin nk_rec = 1'b0; nk_en = 0; nk_ebl = 0; end

task nk_rec_px;
   input [31:0] pa;
   input        wr;
   input [31:0] val;
   begin
      if (nk_rec) begin
         if (nk_en >= NK_MAXP)
            tb_error("walk record overflow (test bug)");
         else begin
            nk_epa[nk_en]  = pa;
            nk_eold[nk_en] = gpu_get_px(pa, nk_ebl);
            nk_enew[nk_en] = val & gpu_pmask(nk_ebl);
            nk_ewr[nk_en]  = wr;
            nk_en          = nk_en + 1;
         end
      end
   end
endtask

// Two capture slots: final pixel values of a recorded EXEC
reg [31:0] nk_apa [0:NK_MAXP-1];
reg [31:0] nk_aval[0:NK_MAXP-1];
reg [31:0] nk_bpa [0:NK_MAXP-1];
reg [31:0] nk_bval[0:NK_MAXP-1];
integer    nk_an, nk_bn, nk_abl, nk_bbl;
initial begin nk_an = 0; nk_bn = 0; end

task nk_capture;
   input integer slot;
   integer       kk;
   begin
      for (kk = 0; kk < nk_en; kk = kk + 1)
         if (slot == 0) begin
            nk_apa[kk]  = nk_epa[kk];
            nk_aval[kk] = nk_ewr[kk] ? nk_enew[kk] : nk_eold[kk];
         end else begin
            nk_bpa[kk]  = nk_epa[kk];
            nk_bval[kk] = nk_ewr[kk] ? nk_enew[kk] : nk_eold[kk];
         end
      if (slot == 0) begin nk_an = nk_en; nk_abl = nk_ebl; end
      else           begin nk_bn = nk_en; nk_bbl = nk_ebl; end
   end
endtask

function nk_slot_done;                   // every pixel of a captured EXEC has its final value
   input integer slot;
   integer       kk, ok;
   begin
      ok = 1;
      if (slot == 0) begin
         for (kk = 0; kk < nk_an; kk = kk + 1)
            if (nk_vram_px(nk_apa[kk], nk_abl) !== nk_aval[kk]) ok = 0;
      end else begin
         for (kk = 0; kk < nk_bn; kk = kk + 1)
            if (nk_vram_px(nk_bpa[kk], nk_bbl) !== nk_bval[kk]) ok = 0;
      end
      nk_slot_done = ok;
   end
endfunction

// Classify the recorded walk against VRAM after an abandon. Pixels whose new
// value differs from the old one are drawn (new) or undrawn (old); the image
// is a prefix when every drawn index precedes every undrawn one. The shadow is
// rebuilt for that prefix. cls: 0 nothing drawn, 1 strict prefix, 2 whole walk,
// -1 not a prefix.
task nk_prefix_check;
   input        done;
   output integer cls;
   output integer ndrawn;
   integer      kk, maxd, minu, nbad;
   reg   [31:0] got;
   begin
      maxd = -1;
      minu = nk_en;
      nbad = 0;
      for (kk = 0; kk < nk_en; kk = kk + 1) begin
         got = nk_vram_px(nk_epa[kk], nk_ebl);
         if (nk_ewr[kk] && (nk_enew[kk] != nk_eold[kk])) begin
            if (got === nk_enew[kk]) begin
               if (kk > maxd) maxd = kk;
            end else if (got === nk_eold[kk]) begin
               if (kk < minu) minu = kk;
            end else begin
               nbad = nbad + 1;
               if (nbad <= 4)
                  $display("ERROR: abandoned walk pixel %0d (0x%h) = 0x%h, neither old 0x%h nor new 0x%h %t",
                           kk, nk_epa[kk], got, nk_eold[kk], nk_enew[kk], $time);
            end
         end else if (got !== nk_eold[kk]) begin
            nbad = nbad + 1;
            if (nbad <= 4)
               $display("ERROR: abandoned walk pixel %0d (0x%h) = 0x%h, expected unchanged 0x%h (%0s) %t",
                        kk, nk_epa[kk], got, nk_eold[kk], nk_ewr[kk] ? "same value" : "skipped", $time);
         end
      end
      ndrawn = maxd + 1;
      if (nbad != 0) begin
         error = error + nbad;
         cls   = -1;
      end else if (maxd > minu) begin
         $display("ERROR: abandoned walk is not a prefix: pixel %0d drawn after undrawn pixel %0d (of %0d) %t",
                  maxd, minu, nk_en, $time);
         error = error + 1;
         cls   = -1;
      end else if (minu == nk_en)
         cls = 2;
      else if (maxd < 0)
         cls = 0;
      else
         cls = 1;
      if (done && (cls != 2)) begin
         $display("ERROR: GPU_DONE raised for an abandoned walk (%0d drawn, first undrawn %0d of %0d) %t",
                  ndrawn, minu, nk_en, $time);
         error = error + 1;
      end
      // shadow: the old image, then the prefix (or what VRAM holds, after an error)
      for (kk = 0; kk < nk_en; kk = kk + 1)
         gpu_set_px(nk_epa[kk], nk_ebl, nk_eold[kk]);
      if (cls < 0) begin
         for (kk = 0; kk < nk_en; kk = kk + 1)
            gpu_set_px(nk_epa[kk], nk_ebl, nk_vram_px(nk_epa[kk], nk_ebl));
      end else
         for (kk = 0; kk < ndrawn; kk = kk + 1)
            if (nk_ewr[kk]) gpu_set_px(nk_epa[kk], nk_ebl, nk_enew[kk]);
   end
endtask


//============================================================================
// Command models (EXEC_SPAN / EXEC_EXPAND / SET_EXT / EXEC_TEXSPAN)
//============================================================================
task nk_span;
   input integer delta;
   input  [13:0] width;
   reg    [13:0] d14;
   begin
      d14 = delta;
      gpu_push({OP_EXEC_SPAN, d14, width});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_m_w        = ((width & GPU_DIM_MASK) == 0) ? 1 : (width & GPU_DIM_MASK);
      gpu_m_h        = 1;
      gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_x_run;
   end
endtask

task nk_exp;
   input integer delta;
   input   [2:0] dsw;                    // {X, Y, CL}
   input         opaque;
   input   [1:0] sdep;
   reg    [13:0] d14;
   reg    [31:0] spa, dpa, vv, pm;
   integer       kk, sbl, spitch;
   begin
      d14 = delta;
      gpu_src_fmt({2'b00, sdep} + 4'd1);                 // SRC_FMT 1-4 = 1/2/4/8 bpp
      gpu_push({OP_EXEC_EXP, d14, 7'h00, dsw, 1'b0, opaque, 2'b00});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_x_setup(GPU_FILL, 4'd0, dsw, 3'b000);
      sbl    = sdep;
      spitch = (gpu_m_src_pitch == 16'h0) ? gpu_x_w : gpu_m_src_pitch;
      pm     = gpu_pmask(gpu_x_bl);
      if (nk_rec) begin
         nk_en  = 0;
         nk_ebl = gpu_x_bl;
      end
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         spa = (gpu_x_sbase + (kk / gpu_x_w) * spitch + (kk % gpu_x_w)) & GPU_PA_MASK;
         nk_chk_src(spa, sbl);
         vv  = gpu_get_px(spa, sbl);
         dpa = gpu_walk(gpu_x_dbase, gpu_x_dpitch, dsw, gpu_x_w, kk);
         nk_chk_dst(dpa, gpu_x_bl);
         gpu_touch_px(dpa, gpu_x_bl);
         if (vv !== 32'h0) begin
            nk_rec_px(dpa, 1'b1, (gpu_x_fill + vv - 32'h1) & pm);
            gpu_set_px(dpa, gpu_x_bl, (gpu_x_fill + vv - 32'h1) & pm);
         end else if (opaque) begin
            nk_rec_px(dpa, 1'b1, gpu_x_transp & pm);
            gpu_set_px(dpa, gpu_x_bl, gpu_x_transp & pm);
         end else
            nk_rec_px(dpa, 1'b0, 32'h0);
      end
   end
endtask

// Texture state (model of SET_TEX / SET_UV / SET_STEP)
reg  [3:0] nk_lw, nk_lh;
reg        nk_ten, nk_free;
reg  [2:0] nk_tsw;
reg  [7:0] nk_shade;
reg [15:0] nk_u0, nk_v0, nk_du, nk_dv;

task nk_set_tex;
   input  [3:0] lw;
   input  [3:0] lh;
   input        ten;
   input  [2:0] dsw;                     // {X, Y, CL}
   input        free;
   input  [7:0] shade;
   begin
      gpu_push({OP_SET_EXT, 4'h0, shade, 3'b000, free, dsw, ten, lh, lw});
      nk_lw    = lw;
      nk_lh    = lh;
      nk_ten   = ten;
      nk_tsw   = dsw;
      nk_free  = free;
      nk_shade = shade;
   end
endtask

task nk_set_uv;
   input [15:0] u0;                      // unsigned 10.6
   input [15:0] v0;
   begin
      gpu_push({OP_SET_EXT, 4'h1, 24'h0});
      gpu_push({u0, v0});
      nk_u0 = u0;
      nk_v0 = v0;
   end
endtask

task nk_set_step;
   input [15:0] du;                      // signed 5.11
   input [15:0] dv;
   begin
      gpu_push({OP_SET_EXT, 4'h2, 24'h0});
      gpu_push({du, dv});
      nk_du = du;
      nk_dv = dv;
   end
endtask

task nk_tex;
   input integer delta;
   input  [13:0] n;
   reg    [13:0] d14;
   reg    [20:0] ua, va, dua, dva;
   reg    [31:0] spa, dpa, tt, pm;
   integer       kk, lw, lh, pitch, ui, vi;
   begin
      d14 = delta;
      gpu_src_fmt(4'h0);
      gpu_push({OP_EXEC_TEX, d14, n});
      gpu_m_dst_base = (gpu_m_dst_base + {{18{d14[13]}}, d14}) & GPU_PA_MASK;
      gpu_m_w        = ((n & GPU_DIM_MASK) == 0) ? 1 : (n & GPU_DIM_MASK);
      gpu_m_h        = 1;
      gpu_x_setup(GPU_FILL, 4'd0, nk_tsw, 3'b000);
      pm     = gpu_pmask(gpu_x_bl);
      lw     = (nk_lw > 4'd10) ? 10 : nk_lw;
      lh     = (nk_lh > 4'd10) ? 10 : nk_lh;
      pitch  = nk_free ? gpu_x_spitch : (1 << lw);
      ua     = {nk_u0, 5'b00000};
      va     = {nk_v0, 5'b00000};
      dua    = {{5{nk_du[15]}}, nk_du};
      dva    = {{5{nk_dv[15]}}, nk_dv};
      if (nk_rec) begin
         nk_en  = 0;
         nk_ebl = gpu_x_bl;
      end
      for (kk = 0; kk < gpu_x_w; kk = kk + 1) begin
         ui = ua[20:11];
         vi = va[20:11];
         if (!nk_free) begin
            ui = ui & ((1 << lw) - 1);
            vi = vi & ((1 << lh) - 1);
         end
         spa = (gpu_x_sbase + vi * pitch + ui) & GPU_PA_MASK;
         nk_chk_src(spa, gpu_x_bl);
         tt  = gpu_get_px(spa, gpu_x_bl);
         dpa = gpu_walk(gpu_x_dbase, gpu_x_dpitch, gpu_x_dsw, gpu_x_w, kk);
         nk_chk_dst(dpa, gpu_x_bl);
         gpu_touch_px(dpa, gpu_x_bl);
         if (nk_ten && (tt == (gpu_x_transp & pm)))
            nk_rec_px(dpa, 1'b0, 32'h0);
         else begin
            nk_rec_px(dpa, 1'b1, (tt + nk_shade) & pm);
            gpu_set_px(dpa, gpu_x_bl, (tt + nk_shade) & pm);
         end
         ua = ua + dua;
         va = va + dva;
      end
   end
endtask

task nk_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask


//============================================================================
// 1. ABORT / GPU_EN = 0 in the middle of a long TEXSPAN or a large EXPAND
//============================================================================
integer    nk_strict_tex, nk_strict_exp, nk_late, nk_none;

task nk_abort_case;
   input integer kind;                   // 0 TEXSPAN pow2, 1 TEXSPAN FREE_PITCH, 2 EXPAND, 3 EXPAND OPAQUE
   input integer how;                    // 0 GPU_CTRL.ABORT, 1 CTRL.GPU_EN = 0
   integer    mode, bl, ppw, sbl, sppw, tot, wmin, wmax, wt, t0, cls, nd, delta, n2, n3, ii, sp, pitch;
   reg [31:0] pm, tr, flag, tb, oa, ob, base, sb;
   reg  [2:0] sw;
   reg  [1:0] sdep;
   reg [15:0] du, dv, u0, v0;
   reg  [7:0] shade;
   reg        dec, tex;
   begin
      tex  = (kind < 2);
      mode = nk_rnd(5);
      gpu_wait_idle;
      gpu_set_mode(mode);
      bl   = gpu_bl(mode);
      ppw  = 32 >> bl;
      pm   = gpu_pmask(bl);
      gpu_preload_rand(NK_A_LO, NK_D_HI);
      oa   = NK_A_LO * ppw + 8 + nk_rnd(ppw);
      ob   = NK_B_LO * ppw + 8 + nk_rnd(ppw);
      delta = nk_rnd(32) - 16;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      if (tex) begin
         tot   = NK_NMAX;
         tr    = nk_hi_color($random(gpu_seed), pm);
         gpu_preload_pal(NK_SRC_LO, NK_SRC_HI, bl, tr, $random(gpu_seed), $random(gpu_seed), pm - 1);
         tb    = 48 * ppw + nk_rnd(ppw);
         ii    = nk_rnd(4);
         sw    = (ii == 0) ? 3'b000 : (ii == 1) ? 3'b100 : (ii == 2) ? 3'b001 : 3'b011;
         pitch = sw[0] ? 2 : NK_DPITCH;
         base  = oa + (sw[0] ? (sw[1] ? 2 * (tot - 1) : 0) : (sw[2] ? tot - 1 : 0));
         shade = $random(gpu_seed);
         gpu_c_transp(tr);
         gpu_c_dst(pitch, base - delta);
         if (kind == 0) begin
            gpu_c_src(16'd117, tb);                                // pitch ignored with FREE_PITCH 0
            nk_set_tex(4'd5, 4'd3, 1'b1, sw, 1'b0, shade);
            nk_set_uv($random(gpu_seed), $random(gpu_seed));
            nk_set_step($random(gpu_seed), $random(gpu_seed));
         end else begin
            gpu_c_src(NK_SPITCH, tb);
            nk_set_tex($random(gpu_seed), $random(gpu_seed), 1'b1, sw, 1'b1, shade);
            v0 = (nk_rnd(2) << 6) | nk_rnd(64);
            dv = nk_rnd(3 * 2048 / tot + 1);
            if (nk_rnd(2)) begin
               u0 = ((2 + nk_rnd(2)) << 6) | nk_rnd(64);
               du = nk_rnd(28 * 2048 / tot + 1);
            end else begin
               u0 = ((30 + nk_rnd(2)) << 6) | nk_rnd(64);
               du = -nk_rnd(28 * 2048 / tot + 1);
            end
            nk_set_uv(u0, v0);
            nk_set_step(du, dv);
         end
      end else begin
         tot   = NK_EW * NK_EH;
         sdep  = nk_rnd(4);
         sbl   = sdep;
         sppw  = 32 >> sbl;
         gpu_preload_pal(NK_SRC_LO, NK_SRC_HI, sbl, 16'h0, 16'h1, $random(gpu_seed), gpu_pmask(sbl));
         sp    = nk_rnd(2) ? 0 : NK_EW + nk_rnd(16);
         sb    = 48 * sppw + nk_rnd(sppw);
         sw    = $random(gpu_seed);
         base  = oa + (sw[1] ? ((sw[0] ? NK_EW : NK_EH) - 1) * NK_DPITCH : 0) + (sw[2] ? (sw[0] ? NK_EH : NK_EW) - 1 : 0);
         gpu_c_src(sp, sb);
         gpu_c_size(NK_EW, NK_EH);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(nk_hi_color($random(gpu_seed), pm));
         gpu_c_dst(NK_DPITCH, base - delta);
      end
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // the EXEC to abandon, recorded pixel by pixel
      nk_rec = 1'b1;
      if (tex) nk_tex(delta, tot);
      else     nk_exp(delta, sw, kind == 3, sdep);
      nk_rec = 1'b0;
      t0     = gpu_cyc;
      // queued complete commands that the flush must drop
      dec = (tot >= 60);
      if (dec) begin
         gpu_push({OP_FENCE, 28'h100_0001});
         gpu_push(gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));
      end
      wmin = dec ? 30 : 3;
      wmax = (tot * 6) / 10;                                     // the walk takes at least one cycle per pixel
      if (wmax <= wmin) wmax = wmin + 1;
      wt   = wmin + nk_rnd(wmax - wmin);
      while (gpu_cyc < t0 + wt) @(posedge free_clk);
      if (how == 0)
         reg_wr(GPU_CTRL, 32'h2);
      else begin
         reg_wr(CTRL, mode);                                       // GPU_EN = 0
         reg_wr(GPU_CMD, gpu_exec_word(GPU_FILL, 4'd14, 3'b000, 3'b000));   // dropped
         reg_rd_mask(IRQ_FLAG, IF_OVFL, IF_OVFL);
      end
      repeat(10) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH,
                  GS_EMPTY | GS_FULL | GS_PRIM_BUSY | GS_BUSY | GS_ERR | GS_HELD | 32'hFFFF);
      reg_rd_val(IRQ_FLAG, flag);
      if (!(flag & IF_IDLE) || (flag & IF_ERR)) begin
         $display("ERROR: IRQ_FLAG = 0x%h after the abandon (GPU_IDLE expected, no GPU_ERR) %t", flag, $time);
         error = error + 1;
      end
      // the abandoned walk (region A); settled, checked through the backdoor (no time)
      nk_prefix_check(flag[4], cls, nd);
      if (cls == 1) begin
         $display("OK:    %0s %0s mode %0d: abandoned after %0d of %0d pixels (clean prefix, no GPU_DONE)",
                  (kind == 0) ? "TEXSPAN pow2" : (kind == 1) ? "TEXSPAN FREE_PITCH" : (kind == 2) ? "EXPAND" : "EXPAND OPAQUE",
                  (how == 0) ? "ABORT" : "GPU_EN=0", mode, nd, tot);
         if (tex) nk_strict_tex = nk_strict_tex + 1;
         else     nk_strict_exp = nk_strict_exp + 1;
      end else if (cls == 2) begin
         $display("INFO:  %0s mode %0d: the whole walk was drawn before the %0s (GPU_DONE %0d)",
                  tex ? "TEXSPAN" : "EXPAND", mode, (how == 0) ? "ABORT" : "GPU_EN=0", flag[4]);
         nk_late = nk_late + 1;
      end else if (cls == 0) begin
         $display("INFO:  %0s mode %0d: nothing drawn before the %0s",
                  tex ? "TEXSPAN" : "EXPAND", mode, (how == 0) ? "ABORT" : "GPU_EN=0");
         nk_none = nk_none + 1;
      end
      if (how == 1) gpu_set_mode(mode);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      // immediately: new per-command state and a new EXEC in region B
      if (tex) begin
         n2   = (NK_NMAX >= 120) ? 120 : NK_NMAX;
         n3   = (NK_NMAX >= 24) ? 24 : NK_NMAX;
         base = ob + (nk_tsw[0] ? (nk_tsw[1] ? 2 * (n2 - 1) : 0) : (nk_tsw[2] ? n2 - 1 : 0));
         gpu_c_dst(nk_tsw[0] ? 16'd2 : NK_DPITCH, base);
         gpu_c_src((kind == 0) ? 16'd0 : NK_SPITCH, tb + nk_rnd(4));
         if (how == 1) begin
            nk_set_tex(nk_lw, nk_lh, nk_ten, nk_tsw, nk_free, nk_shade);
            nk_set_step(nk_du, nk_dv);
         end
         if (kind == 0) nk_set_uv($random(gpu_seed), $random(gpu_seed));
         else           nk_set_uv(((nk_du[15] ? 30 : 2) << 6) | nk_rnd(64), nk_rnd(64));
         nk_tex(0, n2);
         gpu_wait_idle;
         gpu_check_touched("restart after abandon");
         // no SET_UV: restarts at (u0, v0) with a new step
         if (kind == 0) nk_set_step($random(gpu_seed), $random(gpu_seed));
         else           nk_set_step(nk_du[15] ? -nk_rnd(20 * 2048 / n3 + 1) : nk_rnd(20 * 2048 / n3 + 1),
                                    nk_rnd(2 * 2048 / n3 + 1));
         nk_tex(0, n3);
      end else begin
         base = ob + (sw[1] ? ((sw[0] ? NK_EW : NK_EH) - 1) * NK_DPITCH : 0) + (sw[2] ? (sw[0] ? NK_EH : NK_EW) - 1 : 0);
         gpu_c_dst(NK_DPITCH, base);
         gpu_c_size(NK_EW, NK_EH);
         gpu_c_src(sp, sb + 17);
         nk_exp(0, sw, kind == 3, sdep);
         gpu_wait_idle;
         gpu_check_touched("restart after abandon");
         gpu_c_src(16'd0, sb + 3);
         gpu_c_fill($random(gpu_seed));
         nk_exp(0, sw, kind != 3, sdep);
      end
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("second EXEC after restart");
      gpu_check_all("abandon + restart");
   end
endtask


//============================================================================
// 2. Debug freeze toggling + VRAM-window contention
//============================================================================
integer nk_held_chk;

task nk_freeze_case;
   input integer k;
   integer    mode, bl, ppw, sbl, sppw, n, tg, sp;
   reg [31:0] pm, tr, st, base, o;
   reg  [2:0] sw;
   reg  [1:0] sdep;
   reg        dbgc;
   begin
      mode = nk_rnd(5);
      gpu_wait_idle;
      gpu_set_mode(mode);
      bl   = gpu_bl(mode);
      ppw  = 32 >> bl;
      pm   = gpu_pmask(bl);
      gpu_preload_rand(NK_A_LO, NK_D_HI);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      nk_bg_en = 1'b1;
      if (k % 2) begin                                             // TEXSPAN in region B
         n  = NK_NMAX;
         tr = nk_hi_color($random(gpu_seed), pm);
         gpu_preload_pal(NK_SRC_LO, NK_SRC_HI, bl, tr, $random(gpu_seed), pm, $random(gpu_seed));
         o  = NK_B_LO * ppw + 8 + nk_rnd(ppw);
         sw = nk_rnd(2) ? 3'b100 : 3'b000;
         gpu_c_transp(tr);
         gpu_c_dst(NK_DPITCH, o + (sw[2] ? n - 1 : 0));
         if ((k / 2) % 2) begin
            gpu_c_src(NK_SPITCH, 48 * ppw + nk_rnd(ppw));
            nk_set_tex(4'd0, 4'd0, 1'b1, sw, 1'b1, $random(gpu_seed));
            nk_set_uv(((2 + nk_rnd(2)) << 6) | nk_rnd(64), (nk_rnd(2) << 6) | nk_rnd(64));
            nk_set_step(nk_rnd(28 * 2048 / n + 1), nk_rnd(3 * 2048 / n + 1));
         end else begin
            gpu_c_src(16'd0, 48 * ppw + nk_rnd(ppw));
            nk_set_tex(4'd4, 4'd3, 1'b1, sw, 1'b0, $random(gpu_seed));
            nk_set_uv($random(gpu_seed), $random(gpu_seed));
            nk_set_step($random(gpu_seed), $random(gpu_seed));
         end
         nk_tex(0, n);
      end else begin                                               // EXPAND in region A
         sdep = nk_rnd(4);
         sbl  = sdep;
         sppw = 32 >> sbl;
         gpu_preload_pal(NK_SRC_LO, NK_SRC_HI, sbl, 16'h0, 16'h1, $random(gpu_seed), gpu_pmask(sbl));
         sp   = nk_rnd(2) ? 0 : NK_EW + nk_rnd(16);
         o    = NK_A_LO * ppw + 8 + nk_rnd(ppw);
         sw   = $random(gpu_seed);
         base = o + (sw[1] ? ((sw[0] ? NK_EW : NK_EH) - 1) * NK_DPITCH : 0) + (sw[2] ? (sw[0] ? NK_EH : NK_EW) - 1 : 0);
         gpu_c_src(sp, 48 * sppw + nk_rnd(sppw));
         gpu_c_size(NK_EW, NK_EH);
         gpu_c_fill($random(gpu_seed));
         gpu_c_transp(nk_hi_color($random(gpu_seed), pm));
         gpu_c_dst(NK_DPITCH, base);
         nk_exp(0, sw, nk_rnd(2), sdep);
      end
      // freeze toggled while the rectangle runs, frozen first right after the
      // push; no push while frozen
      dbg_stoptime = 1'b1;
      reg_wr(DBG_CTRL, 32'h2);
      dbgc = 1'b1;
      for (tg = 0; tg < 30; tg = tg + 1) begin
         if (dbg_stoptime && dbgc) begin
            reg_rd_val(GPU_STAT, st);
            if ((st & GS_HELD) && (st & GS_PRIM_BUSY)) begin       // held mid-rectangle: no GPU_DONE yet
               reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
               nk_held_chk = nk_held_chk + 1;
            end
         end
         repeat(1 + nk_rnd(8)) @(negedge free_clk);
         if (k & 2)
            dbg_stoptime = ~dbg_stoptime;
         else begin
            dbg_stoptime = 1'b1;
            dbgc         = ~dbgc;
            reg_wr(DBG_CTRL, dbgc ? 32'h2 : 32'h0);
         end
      end
      @(negedge free_clk) dbg_stoptime = 1'b0;
      reg_wr(DBG_CTRL, 32'h0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      repeat(30) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);                        // one GPU_DONE only
      $display("       %0s mode %0d, freeze via %0s, window traffic %0d writes / %0d reads so far",
               (k % 2) ? "TEXSPAN" : "EXPAND", mode, (k & 2) ? "dbg_stoptime" : "DBG_CTRL[1]", nk_bg_nw, nk_bg_nr);
      nk_bg_pause;
      gpu_check_touched("freeze + contention");
   end
endtask


//============================================================================
// 3. GPU_DONE counting (W1C polling) and FENCE ordering
//============================================================================
integer nk_ev_a   [1:8];
integer nk_ev_b   [1:8];
integer nk_ev_busy[1:8];

task nk_ev_rec;
   input integer cnt;
   begin
      if (cnt <= 8) begin
         nk_ev_a[cnt] = nk_slot_done(0);
         nk_ev_b[cnt] = nk_slot_done(1);
      end
   end
endtask

// Poll IRQ_FLAG until the GPU is idle, clearing and counting every GPU_DONE and
// GPU_FENCE (a FENCE first when both are seen in one poll); at each event
// record whether the captured EXECs are complete and BUSY.
task nk_poll_done;
   output integer cnt;
   reg   [31:0] f, s;
   integer      guard, pend;
   begin
      cnt   = 0;
      guard = 0;
      s     = GS_BUSY;
      while ((s & GS_BUSY) && (guard < 20000)) begin
         reg_rd_val(IRQ_FLAG, f);
         pend = 0;
         if (f & IF_FENCE) begin
            reg_wr(IRQ_FLAG, IF_FENCE);
            cnt  = cnt + 1;
            pend = pend + 1;
            nk_ev_rec(cnt);
         end
         if (f & IF_DONE) begin
            reg_wr(IRQ_FLAG, IF_DONE);
            cnt  = cnt + 1;
            pend = pend + 1;
            nk_ev_rec(cnt);
         end
         reg_rd_val(GPU_STAT, s);
         if ((pend != 0) && (cnt <= 8)) nk_ev_busy[cnt] = (s & GS_BUSY) ? 1 : 0;
         if ((pend == 2) && (cnt <= 8)) nk_ev_busy[cnt - 1] = nk_ev_busy[cnt];
         guard = guard + 1;
      end
      reg_rd_val(IRQ_FLAG, f);
      if (f & IF_FENCE) begin
         reg_wr(IRQ_FLAG, IF_FENCE);
         cnt = cnt + 1;
         nk_ev_rec(cnt);
         if (cnt <= 8) nk_ev_busy[cnt] = 0;
      end
      if (f & IF_DONE) begin
         reg_wr(IRQ_FLAG, IF_DONE);
         cnt = cnt + 1;
         nk_ev_rec(cnt);
         if (cnt <= 8) nk_ev_busy[cnt] = 0;
      end
      if (guard >= 20000) tb_error("GPU never became idle while counting GPU_DONE");
   end
endtask

task nk_settle;                          // idle, no GPU_DONE from configuration words, flags cleared
   begin
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE | IF_FENCE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      nk_check_irq(1'b0);
   end
endtask

task nk_done_once;
   input [8*24-1:0] what;
   begin
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      nk_check_irq(1'b1);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      nk_check_irq(1'b0);
      repeat(20) @(posedge free_clk);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_DONE);
      $display("       GPU_DONE once for %0s", what);
   end
endtask

// A large opaque EXPAND at origin o, recorded and captured in slot
task nk_big_exp;
   input [31:0] o;
   input integer slot;
   integer      sppw;
   begin
      sppw = 16;                                                   // SRC_DEPTH 1: 2 bpp
      gpu_c_dst(NK_DPITCH, o);
      gpu_c_size(NK_EW, NK_EH);
      gpu_c_src(16'd0, 48 * sppw + nk_rnd(200));
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));
      nk_rec = 1'b1;
      nk_exp(0, 3'b000, 1'b1, 2'd1);
      nk_rec = 1'b0;
      nk_capture(slot);
   end
endtask

task nk_done_section;
   integer    mode, bl, ppw, cnt, ii;
   reg [31:0] pm, o, oa, ob, st;
   begin
      mode = nk_rnd(5);
      gpu_wait_idle;
      gpu_set_mode(mode);
      bl   = gpu_bl(mode);
      ppw  = 32 >> bl;
      pm   = gpu_pmask(bl);
      gpu_preload_rand(NK_A_LO, NK_D_HI);
      gpu_preload_pal(NK_SRC_LO, NK_SRC_HI, 1, 16'h0, 16'h1, 16'h2, 16'h3);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      reg_wr(IRQ_EN, IF_DONE | IF_FENCE);
      nk_check_irq(1'b0);
      o = NK_B_LO * ppw + 100 + nk_rnd(ppw);
      $display("--- GPU_DONE per EXEC kind (mode %0d)", mode);
      // EXEC_SPAN
      gpu_c_dst(NK_DPITCH, o - 3);
      gpu_c_fill($random(gpu_seed));
      nk_settle;
      nk_span(3, 1 + nk_rnd((NK_SMALL >= 12) ? 12 : NK_SMALL));
      nk_done_once("EXEC_SPAN");
      // EXEC_EXPAND
      gpu_c_dst(NK_DPITCH, o + 48);
      gpu_c_src(16'd0, 48 * 16 + nk_rnd(16));
      gpu_c_size(1 + nk_rnd(NK_SMALL), 1 + nk_rnd(4));
      gpu_c_transp($random(gpu_seed));
      nk_settle;
      nk_exp(0, 3'b000, nk_rnd(2), 2'd1);
      nk_done_once("EXEC_EXPAND");
      // EXEC_TEXSPAN
      gpu_c_dst(NK_DPITCH, o + 88 + 5);
      gpu_c_src(16'd0, 48 * ppw + nk_rnd(ppw));
      nk_set_tex(4'd3, 4'd3, 1'b1, 3'b000, 1'b0, $random(gpu_seed));
      nk_set_uv($random(gpu_seed), $random(gpu_seed));
      nk_set_step($random(gpu_seed), $random(gpu_seed));
      gpu_c_transp(pm & 32'h1);
      nk_settle;
      nk_tex(-5, 1 + nk_rnd(NK_SMALL));
      nk_done_once("EXEC_TEXSPAN");
      // EXEC_FILL
      gpu_c_dst(NK_DPITCH, o + 200);
      gpu_c_size(1 + nk_rnd(NK_SMALL), 1 + nk_rnd(4));
      gpu_c_fill($random(gpu_seed));
      nk_settle;
      gpu_c_exec(GPU_FILL, $random(gpu_seed), 3'b000, 3'b000);
      nk_done_once("EXEC_FILL");
      // EXEC_COPY
      gpu_c_dst(NK_DPITCH, o + 330);
      gpu_c_src(NK_SPITCH, 48 * ppw + 3);
      nk_settle;
      gpu_c_exec(GPU_COPY, $random(gpu_seed), 3'b000, 3'b000);
      nk_done_once("EXEC_COPY");
      gpu_check_touched("GPU_DONE per kind");

      $display("--- FENCE alone");
      nk_settle;
      gpu_c_fence(1'b0);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_FENCE | IF_IDLE | IF_ERR);
      nk_check_irq(1'b0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_c_fence(1'b1);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_FENCE | IF_IDLE, IF_GPU_ALL);
      nk_check_irq(1'b1);
      reg_rd(GPU_FENCE, {8'h00, gpu_m_fence});
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      nk_check_irq(1'b0);

      oa = NK_A_LO * ppw + 8 + nk_rnd(ppw);
      ob = NK_B_LO * ppw + 8 + nk_rnd(ppw);
      nk_an = 0;
      nk_bn = 0;

      $display("--- FENCE(1) then EXPAND: GPU_FENCE before the EXPAND completes, then its GPU_DONE");
      nk_settle;
      gpu_push_wait = 1'b1;
      gpu_c_fence(1'b1);
      nk_big_exp(ob, 1);
      nk_poll_done(cnt);
      if ((cnt != 2) || (nk_ev_b[1] != 0) || (nk_ev_busy[1] != 1) || (nk_ev_b[2] != 1)) begin
         $display("ERROR: FENCE(1)+EXPAND: %0d GPU_DONE events (2 expected); first: expand complete %0d BUSY %0d; second: expand complete %0d %t",
                  cnt, nk_ev_b[1], nk_ev_busy[1], (cnt >= 2) ? nk_ev_b[2] : -1, $time);
         error = error + 1;
      end else
         $display("OK:    FENCE(1)+EXPAND: 2 GPU_DONE events in order");
      gpu_check_touched("FENCE(1)+EXPAND");

      $display("--- FENCE(0) then EXPAND: one GPU_DONE event");
      nk_settle;
      gpu_c_fence(1'b0);
      nk_big_exp(ob + 1, 1);
      nk_poll_done(cnt);
      if ((cnt != 1) || (nk_ev_b[1] != 1)) begin
         $display("ERROR: FENCE(0)+EXPAND: %0d GPU_DONE events (1 expected), expand complete at the first %0d %t",
                  cnt, nk_ev_b[1], $time);
         error = error + 1;
      end else
         $display("OK:    FENCE(0)+EXPAND: 1 GPU_DONE event");
      gpu_check_touched("FENCE(0)+EXPAND");

      $display("--- EXPAND then FENCE(1): no GPU_DONE before the EXPAND is complete");
      nk_settle;
      nk_bn = 0;
      nk_big_exp(oa, 0);
      gpu_c_fence(1'b1);
      reg_rd_val(GPU_STAT, st);
      if (((st & GS_PRIM_BUSY) == 0) || ((st & 32'hFF00) != 32'h0100))
         $display("INFO:  GPU_STAT 0x%h right after EXPAND + FENCE (FENCE not seen queued)", st);
      nk_poll_done(cnt);
      if ((cnt < 1) || (cnt > 2)) begin
         $display("ERROR: EXPAND+FENCE(1): %0d GPU_DONE events (1 or 2 expected) %t", cnt, $time);
         error = error + 1;
      end
      for (ii = 1; (ii <= cnt) && (ii <= 8); ii = ii + 1)
         if (nk_ev_a[ii] != 1) begin
            $display("ERROR: EXPAND+FENCE(1): GPU_DONE event %0d seen before the EXPAND was complete %t", ii, $time);
            error = error + 1;
         end
      gpu_check_touched("EXPAND+FENCE(1)");

      $display("--- EXPAND, FENCE(1), EXPAND");
      nk_settle;
      nk_big_exp(oa + 1, 0);
      gpu_c_fence(1'b1);
      nk_big_exp(ob + 2, 1);
      nk_poll_done(cnt);
      if ((cnt < 2) || (cnt > 3)) begin
         $display("ERROR: EXPAND+FENCE(1)+EXPAND: %0d GPU_DONE events (2 or 3 expected) %t", cnt, $time);
         error = error + 1;
      end else begin
         if (nk_ev_a[1] != 1) begin
            $display("ERROR: EXPAND+FENCE(1)+EXPAND: first GPU_DONE before the first EXPAND was complete %t", $time);
            error = error + 1;
         end
         if ((nk_ev_b[1] != 0) || (nk_ev_b[cnt] != 1)) begin
            $display("ERROR: EXPAND+FENCE(1)+EXPAND: second EXPAND complete at the first event %0d / at the last %0d %t",
                     nk_ev_b[1], nk_ev_b[cnt], $time);
            error = error + 1;
         end
      end
      gpu_check_touched("EXPAND+FENCE(1)+EXPAND");
      reg_wr(IRQ_EN, 32'h0);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      nk_check_irq(1'b0);
   end
endtask

// Mixed back-to-back burst, FENCE(1) in the middle
task nk_burst;
   integer    mode, bl, ppw, k, r, lo, rng, sdep, sbl, sppw, w, h;
   reg [31:0] tgt;
   reg  [2:0] sw;
   begin
      mode = nk_rnd(5);
      gpu_wait_idle;
      gpu_set_mode(mode);
      bl   = gpu_bl(mode);
      ppw  = 32 >> bl;
      gpu_preload_rand(NK_A_LO, NK_D_HI);
      gpu_preload_rand(NK_SRC_LO, NK_SRC_HI);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      lo  = NK_A_LO * ppw + 160;
      rng = (NK_D_HI - NK_A_LO) * ppw - 320;
      if (rng > 8000) rng = 8000;
      gpu_c_dst(NK_DPITCH, lo + nk_rnd(rng));
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));
      $display("--- mixed burst (mode %0d)", mode);
      for (k = 0; k < 14; k = k + 1) begin
         if (k == 7) gpu_c_fence(1'b1);
         tgt = lo + nk_rnd(rng);
         r   = nk_rnd(5);
         w   = 1 + nk_rnd(NK_SMALL);
         h   = 1 + nk_rnd(3);
         sw  = $random(gpu_seed);
         if (r == 0) begin
            if (nk_rnd(2)) gpu_c_fill($random(gpu_seed));
            nk_span(tgt - gpu_m_dst_base, w);
         end else if (r == 1) begin
            sdep = nk_rnd(4);
            sbl  = sdep;
            sppw = 32 >> sbl;
            gpu_c_src(nk_rnd(2) ? 16'd0 : 16'd9, 48 * sppw + nk_rnd(64));
            gpu_c_size(w, h);
            nk_exp(tgt - gpu_m_dst_base, sw, nk_rnd(2), sdep);
         end else if (r == 2) begin
            gpu_c_src(16'd0, 48 * ppw + nk_rnd(64));
            nk_set_tex(nk_rnd(4), nk_rnd(4), nk_rnd(2), sw, 1'b0, $random(gpu_seed));
            nk_set_uv($random(gpu_seed), $random(gpu_seed));
            nk_set_step($random(gpu_seed), $random(gpu_seed));
            nk_tex(tgt - gpu_m_dst_base, w);
         end else if (r == 3) begin
            gpu_c_size(w, h);
            gpu_c_dst(NK_DPITCH, tgt);
            gpu_c_exec(GPU_FILL, $random(gpu_seed), sw, 3'b000);
         end else begin
            gpu_c_src(NK_SPITCH, 48 * ppw + 130 + nk_rnd(64));
            gpu_c_size(w, h);
            gpu_c_dst(NK_DPITCH, tgt);
            gpu_c_exec(GPU_COPY, $random(gpu_seed), sw, $random(gpu_seed));
         end
      end
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_DONE | IF_IDLE | IF_ERR | IF_OVFL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_touched("mixed burst");
   end
endtask


//============================================================================
// 4. Default pitches under PIX_DOUBLE
//============================================================================
task nk_pd_case;
   input integer wdisp;                  // DISP_SIZE width
   integer    dbl, mode, bl, ppw, fw, n, nf, ew, eh;
   reg [31:0] st, oa, ob, tb, eb, ef, et;
   reg  [2:0] sw;
   reg [15:0] u0, v0, du, dv;
   reg  [7:0] shade;
   reg  [1:0] sdep;
   begin
      // parameters drawn once, used with PIX_DOUBLE 0 and 1
      mode  = nk_rnd(5);
      bl    = gpu_bl(mode);
      ppw   = 32 >> bl;
      ew    = (GPU_DIM_MASK >= 5) ? 5 : GPU_DIM_MASK;              // differs from W and ceil(W/2)
      eh    = 4;
      sdep  = nk_rnd(4);
      sw    = $random(gpu_seed);
      n     = (NK_NMAX >= 14) ? 14 : NK_NMAX;
      u0    = ((1 + nk_rnd(3)) << 6) | nk_rnd(64);
      v0    = nk_rnd(32);
      du    = 16'h0400;                                            // +0.5
      dv    = 16'h0250;                                            // ~ +0.29: rows 0..3
      shade = $random(gpu_seed);
      eb    = 48 * (32 >> (sdep)) + nk_rnd(8);
      tb    = 48 * ppw + nk_rnd(ppw);
      ef    = $random(gpu_seed);
      et    = $random(gpu_seed);
      for (dbl = 0; dbl < 2; dbl = dbl + 1) begin
         gpu_wait_idle;
         gpu_set_mode(mode);
         reg_wr(DISP_SIZE, (32'd9 << 16) | wdisp);
         reg_wr(DISP_CFG, dbl ? 32'h10 : 32'h0);
         fw          = dbl ? (wdisp + 1) / 2 : wdisp;
         gpu_m_dispw = fw;
         gpu_preload_rand(NK_A_LO, NK_D_HI);
         gpu_preload_rand(NK_SRC_LO, NK_SRC_HI);
         oa = NK_A_LO * ppw + 8 + nk_rnd(ppw) + 4 * fw;
         ob = NK_B_LO * ppw + 8 + nk_rnd(ppw);
         $display("--- PIX_DOUBLE %0d, W %0d: frame width %0d, mode %0d", dbl, wdisp, fw, mode);
         // EXPAND: destination pitch 0 = frame width, source pitch 0 = rectangle width
         gpu_c_src(16'd0, eb);
         gpu_c_size(ew, eh);
         gpu_c_fill(ef);
         gpu_c_transp(et);
         gpu_c_dst(16'd0, oa + (sw[1] ? 4 * fw : 0) + (sw[2] ? 5 : 0));
         nk_exp(0, sw, 1'b1, sdep);
         gpu_wait_idle;
         gpu_check_touched("EXPAND pitches 0");
         // TEXSPAN FREE_PITCH, SET_SRC pitch 0 = frame width (row and CL column, dst pitch 0)
         gpu_c_src(16'd0, tb);
         gpu_c_transp(32'h0);
         nk_set_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, shade);
         nk_set_uv(u0, v0);
         nk_set_step(du, dv);
         gpu_c_dst(16'd0, ob);
         nk_tex(0, n);
         nk_set_tex(4'd0, 4'd0, 1'b0, 3'b001, 1'b1, shade);
         nk_tex(1 + n, n);
         gpu_wait_idle;
         gpu_check_touched("TEXSPAN FREE_PITCH pitch 0");
         gpu_check_all("pixel-double pitches");
      end

      if (NK_NMAX >= 60) begin
         nf = 60;
         // DISP_CFG flipped while a TEXSPAN runs: the width at its start applies
         gpu_wait_idle;
         reg_wr(DISP_CFG, 32'h10);
         fw          = (wdisp + 1) / 2;
         gpu_m_dispw = fw;
         gpu_c_src(16'd0, tb);
         nk_set_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, shade);
         nk_set_uv(u0, 16'h0);
         nk_set_step(16'h0080, 16'h0088);                         // u +1/16, v 0 .. ~4
         gpu_c_dst(16'd0, ob + 100);
         nk_tex(0, nf);
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 20);
         reg_rd_val(GPU_STAT, st);
         if ((st & 32'hFF00) != 32'h0)
            tb_error("TEXSPAN not started before the DISP_CFG flip (test bug)");
         reg_wr(DISP_CFG, 32'h0);
         gpu_m_dispw = wdisp;
         reg_rd_val(GPU_STAT, st);
         if ((st & GS_PRIM_BUSY) == 0)
            $display("INFO:  TEXSPAN already complete after the DISP_CFG flip (start-width check weak)");
         gpu_wait_idle;
         gpu_check_touched("DISP_CFG flipped during TEXSPAN");
         // flipped while the TEXSPAN waits behind an EXPAND: the new width applies.
         // One SET_SRC (pitch 0) serves both: 4-bpp expand source (pitch = width)
         // and texture (pitch = frame width); only the EXEC_TEXSPAN word (DELTA
         // from the expand base) follows the EXPAND, so it fits a 4-word FIFO.
         // With run-ahead the TEXSPAN's set-up may run before the flip: skipped.
         if (GPU_RUNAHEAD_EN != 0)
            $display("INFO:  run-ahead: DISP_CFG flipped with a TEXSPAN queued not checked (its set-up may precede the flip)");
         else begin
         reg_wr(DISP_CFG, 32'h10);
         gpu_m_dispw = (wdisp + 1) / 2;
         nk_set_tex(4'd0, 4'd0, 1'b0, 3'b000, 1'b1, shade);
         nk_set_uv(u0, 16'h0);
         nk_set_step(16'h0080, 16'h0088);
         gpu_c_src(16'd0, ((40 * ppw > 320) ? 40 * ppw : 320) + 10);
         gpu_c_size(NK_EW, NK_EH);
         gpu_c_dst(NK_DPITCH, NK_A_LO * ppw + 8);
         nk_exp(0, 3'b000, 1'b1, 2'd2);                              // long, explicit destination pitch
         gpu_m_dispw = wdisp;                                       // the TEXSPAN starts after the flip
         nk_tex(392, nf);
         reg_wr(DISP_CFG, 32'h0);
         reg_rd_val(GPU_STAT, st);
         // USED >= 1: the EXEC_TEXSPAN word (the last one pushed) is still in the FIFO
         if ((st & GS_PRIM_BUSY) == 0)
            tb_error("EXPAND already complete at the DISP_CFG flip (test bug)");
         else if ((st & 32'hFF00) == 32'h0)
            $display("INFO:  EXEC_TEXSPAN word already popped while the EXPAND runs (width still expected at its start)");
         gpu_wait_idle;
         gpu_check_touched("DISP_CFG flipped with TEXSPAN queued");
         end
      end
      reg_wr(DISP_CFG, 32'h0);
      gpu_check_all("pixel-double end");
   end
endtask


//============================================================================
// Main
//============================================================================
integer nk_i;

initial
   begin
      $display(" ===============================================");
      $display("|   GPU: EXPAND / TEXSPAN under abort, freeze   |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      gpu_seed      = `SEED;
      nk_bg_seed    = gpu_seed ^ 32'h3C3C_9E37;
      nk_strict_tex = 0;
      nk_strict_exp = 0;
      nk_late       = 0;
      nk_none       = 0;
      nk_held_chk   = 0;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(NK_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);

      //--------------------------------------------------------------
      $display("--- 1. ABORT / GPU_EN=0 in the middle of TEXSPAN and EXPAND, then restart");
      for (nk_i = 0; nk_i < 24; nk_i = nk_i + 1)
         nk_abort_case(nk_i % 4, (nk_i / 4) % 2);
      $display("       strict prefixes: TEXSPAN %0d, EXPAND %0d; whole walk %0d, nothing drawn %0d",
               nk_strict_tex, nk_strict_exp, nk_late, nk_none);
      if (nk_strict_exp == 0)
         tb_error("no EXPAND abandoned mid-walk (test bug)");
      if ((NK_NMAX >= 60) && (nk_strict_tex == 0))
         tb_error("no TEXSPAN abandoned mid-walk (test bug)");
      nk_no_err;

      //--------------------------------------------------------------
      $display("--- 2. debug freeze toggled during EXPAND / TEXSPAN with VRAM-window traffic");
      for (nk_i = 0; nk_i < 8; nk_i = nk_i + 1)
         nk_freeze_case(nk_i);
      nk_bg_pause;
      $display("       held mid-rectangle checks %0d, window writes %0d, reads %0d", nk_held_chk, nk_bg_nw, nk_bg_nr);
      if ((nk_held_chk == 0) || (nk_bg_nw == 0) || (nk_bg_nr == 0))
         tb_error("freeze never seen held mid-rectangle, or no window traffic (test bug)");
      gpu_check_all("freeze + contention");
      nk_no_err;

      //--------------------------------------------------------------
      $display("--- 3. GPU_DONE counting and FENCE ordering");
      nk_done_section;
      nk_burst;
      nk_burst;
      gpu_check_all("GPU_DONE / FENCE");
      nk_no_err;

      //--------------------------------------------------------------
      $display("--- 4. default pitches under PIX_DOUBLE");
      nk_pd_case((GPU_DIM_MASK >= 40) ? 37 : 13);
      nk_pd_case((GPU_DIM_MASK >= 40) ? 36 : 12);
      reg_wr(DISP_CFG, 32'h0);
      gpu_set_dispw(NK_DISPW);
      nk_no_err;

      gpu_check_all("newkind end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
