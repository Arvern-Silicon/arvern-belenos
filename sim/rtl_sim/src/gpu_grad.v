//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_grad
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_grad.v
// Module Description : Gradient fill, SET_EXT 7 SET_GRAD ([11:0] N, [12]
//                      AXIS, [16:13] signed STEP, [17] EN): with EN,
//                      EXEC_FILL and EXEC_SPAN write fill + floor(i / N) *
//                      STEP (low bpp bits; an integer add to the RGB565
//                      word at 16 bpp), i = index of the walk line (AXIS 0)
//                      or of the pixel in its run (AXIS 1, restarting at 0
//                      on every run), counted in walk order; N = 0 counts
//                      as 1.
//                      1. GFX_MODE 0..4 x AXIS 0 / 1 x N = 1, 3, 16, 4095,
//                         0 x STEP +-, 0, -8, +7, the eight swaps, raster
//                         ops S and XOR; exact VRAM access counts.
//                      2. AXIS 1 on multi-run rectangles (ramp restarts on
//                         every run), all swaps.
//                      3. EXEC_SPAN chains (each span restarts at i = 0),
//                         address and x/y destinations.
//                      4. clip (x/y mode): i counts walk positions, clipped
//                         pixels included.
//                      5. index wrap at 1 / 2 / 4 bpp, 16-bpp carries across
//                         the RGB565 fields (checked against literal values).
//                      6. every raster op with the ramp as S (op 15 writes
//                         the ramp, the colour of a gradient fill).
//                      7. EN = 0 = plain fill; the gradient left on does not
//                         touch COPY, COPY_TRANSP, EXPAND, TEXSPAN, TEXRECT.
//                      8. gradient settings and FILL / SPAN in a CALL list.
//                      9. per channel (SET_GRAD [18] RGB with SET_GRAD_RGB
//                         steps dR, dG, dB in 1/64): at 16 bpp each RGB565
//                         field + floor(i / N) * step, saturated (14-bit
//                         accumulators, then the field's range): AXIS x N x
//                         steps (extremes, saturating) x swaps x ops, clip
//                         (the set-up's three phase products), spans, a
//                         CALL list, literal values; at 8 bpp RGB is the
//                         plain gradient.
//                      10. long gradients (DIM_W >= 10): the clip window keeps
//                         the last 8 x 2 pixels of a ~1000-pixel / -line
//                         ramp, N 0 .. 4095, plain and per channel.
//                      Touched words are read through the VRAM window, the
//                      whole VRAM is compared through the backdoor.
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "gpu_model.v"

localparam integer GR_SRC_LO = 40;               // sources: words [40, 280)
localparam integer GR_SRC_HI = 280;
localparam integer GR_DST_LO = 300;              // destinations: words [300, 990)
localparam integer GR_DST_HI = 990;
localparam integer GR_LIST   = 8;                // command lists: words [8, 40)
localparam integer GR_P      = 29;
localparam integer GR_WMAX   = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer GR_HMAX   = (GPU_DIM_MASK >= 10) ? 10 : GPU_DIM_MASK;
localparam integer GR_LONG   = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;   // long run / many lines
localparam integer GR_DISPW  = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;
localparam integer GR_COUNTS = 1;                // 0: do not compare the VRAM access counts

integer    gr_mode, gr_bl, gr_ppw, gr_c, gr_i, gr_k, gr_w, gr_h, gr_n, gr_st, gr_cur, gr_dx;
integer    gr_rd0, gr_wr0, gr_cl0, gr_x, gr_y, gr_dr, gr_dg, gr_db, gr_off;
reg [31:0] gr_pm, gr_org, gr_b, gr_f, gr_exp;
reg [23:0] gr_n24;
reg  [3:0] gr_op;
reg  [2:0] gr_sw;
reg        gr_ax;

function integer gr_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      gr_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

function [31:0] gr_corner;               // first pixel visited of a w x h walk at top-left org
   input [31:0] org;
   input integer pitch;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows = sw[0] ? w : h;
      cols = sw[0] ? h : w;
      gr_corner = org + (sw[1] ? rows - 1 : 0) * pitch + (sw[2] ? cols - 1 : 0);
   end
endfunction

task gr_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      gpu_set_mode(mode);
      gr_mode = mode;
      gr_bl   = gpu_bl(mode);
      gr_ppw  = 32 >> gr_bl;
      gr_pm   = gpu_pmask(gr_bl);
   end
endtask

task gr_no_err;
   begin
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      reg_rd_mask(IRQ_FLAG, 32'h0, IF_OVFL | IF_ERR);
   end
endtask

task gr_mon_begin;
   begin
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gr_rd0 = gpu_exp_rd;
      gr_wr0 = gpu_exp_wr;
      gpu_mon_start;
   end
endtask

task gr_mon_end;
   input [8*24-1:0] what;
   begin
      gpu_wait_idle;
      gpu_mon_stop;
      if (GR_COUNTS && ((gpu_mon_rd != gpu_exp_rd - gr_rd0) || (gpu_mon_wr != gpu_exp_wr - gr_wr0))) begin
         $display("ERROR: %0s: %0d reads / %0d writes, expected %0d / %0d %t", what,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - gr_rd0, gpu_exp_wr - gr_wr0, $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
   end
endtask

// Literal check of one modelled pixel (guards the model itself)
task gr_expect;
   input [31:0] pa;
   input [31:0] val;
   begin
      if (gpu_get_px(pa, gr_bl) !== (val & gr_pm)) begin
         $display("ERROR: gradient model pixel 0x%h = 0x%h, literal 0x%h (test bug) %t",
                  pa, gpu_get_px(pa, gr_bl), val & gr_pm, $time);
         error = error + 1;
      end
   end
endtask

task gr_list_write;
   integer kk;
   begin
      if (GR_LIST + gpu_cap_n > GR_SRC_LO)
         tb_error("command list overflows its area (test bug)");
      for (kk = 0; kk < gpu_cap_n; kk = kk + 1) begin
         vram_mem[GR_LIST + kk]   = gpu_cap_buf[kk];
         gpu_shadow[GR_LIST + kk] = gpu_cap_buf[kk];
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: gradient fill (SET_GRAD)          |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if ((GPU_XY_EN == 0) || (GPU_GRAD_EN == 0))
         tb_skip_finish("|     (x/y, affine blit or gradient absent)     |");
      gpu_seed = `SEED;
      gpu_preload_rand(0, VRAM_WORDS);
      gpu_model_init;
      gpu_push_wait = 1'b1;
      gpu_set_dispw(GR_DISPW);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_rgn_slo = GR_SRC_LO;
      gpu_rgn_shi = GR_SRC_HI;
      gpu_rgn_dlo = GR_DST_LO;
      gpu_rgn_dhi = GR_DST_HI;

      //--------------------------------------------------------------
      $display("--- 1. GFX_MODE 0..4 x AXIS x N x STEP x swaps (AXIS 1 on single runs)");
      for (gr_mode = 0; gr_mode < 5; gr_mode = gr_mode + 1) begin
         gr_set_mode(gr_mode);
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         for (gr_c = 0; gr_c < 10; gr_c = gr_c + 1) begin
            gr_ax = gr_c % 2;
            gr_n  = ((gr_c / 2) == 0) ? 1 : ((gr_c / 2) == 1) ? 3 : ((gr_c / 2) == 2) ? 16 :
                    ((gr_c / 2) == 3) ? 4095 : 0;
            case ((gr_c + gr_mode) % 6)
              0 : gr_st = 1;
              1 : gr_st = -1;
              2 : gr_st = 7;
              3 : gr_st = -8;
              4 : gr_st = 0;
              default : gr_st = gr_rnd(16) - 8;
            endcase
            gr_sw = (gr_c * 3 + gr_mode) & 7;
            gr_op = ((gr_c % 4) == 3) ? 4'd5 : 4'd0;
            if (gr_ax) begin                                           // one run, long when N = 16
               gr_w = (gr_n == 16) ? GR_LONG : 1 + gr_rnd(GR_WMAX);
               gr_h = 1;
            end else begin                                             // many lines when N = 16
               gr_w = 1 + gr_rnd(4);
               gr_h = (gr_n == 16) ? GR_LONG : 1 + gr_rnd(GR_HMAX);
               if (gr_n == 16) gr_sw = gr_sw & 3'b110;                 // rows = lines
            end
            gr_f = $random(gpu_seed);
            if (gr_c % 3 == 0) gr_f = (gr_f & ~gr_pm) | (gr_st >= 0 ? gr_pm - gr_rnd(3) : gr_rnd(3));   // wraps
            gr_org = (GR_DST_LO + 10) * gr_ppw + gr_rnd(gr_ppw);
            gpu_c_grad(gr_n, gr_ax, gr_st, 1'b1);
            gpu_c_fill(gr_f);
            gpu_c_size(gr_w, gr_h);
            gpu_c_dst(GR_P, gr_corner(gr_org, GR_P, gr_sw, gr_w, gr_h));
            gr_mon_begin;
            gpu_c_exec_xy(GPU_FILL, gr_op, gr_sw, 3'b000);
            gr_mon_end("gradient matrix");
            gr_no_err;
            $display("       mode %0d AXIS %0d N %0d STEP %0d, %0dx%0d sw %b op %0d fill %h",
                     gr_mode, gr_ax, gr_n, gr_st, gr_w, gr_h, gr_sw, gr_op, gr_f);
            gpu_check_touched("gradient matrix");
         end
         gpu_check_all("gradient matrix");
      end

      //--------------------------------------------------------------
      $display("--- 2. AXIS 1 on multi-run rectangles: the ramp restarts on every run");
      for (gr_i = 0; gr_i < 8; gr_i = gr_i + 1) begin
         gr_set_mode(2 + (gr_i % 3));
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gr_sw  = gr_i;
         gr_w   = 2 + gr_rnd(GR_WMAX - 1);
         gr_h   = 2 + gr_rnd(GR_HMAX - 1);
         gr_n   = 1 + gr_rnd(4);
         gr_st  = gr_rnd(15) - 7;
         if (gr_st == 0) gr_st = 3;
         gr_org = (GR_DST_LO + 10) * gr_ppw + gr_rnd(gr_ppw);
         gpu_c_grad(gr_n, 1'b1, gr_st, 1'b1);
         gpu_c_fill($random(gpu_seed));
         gpu_c_size(gr_w, gr_h);
         gpu_c_dst(GR_P, gr_corner(gr_org, GR_P, gr_sw, gr_w, gr_h));
         gr_mon_begin;
         gpu_c_exec_xy(GPU_FILL, 4'd0, gr_sw, 3'b000);
         gr_mon_end("gradient AXIS 1 runs");
         // the last pixel of every run carries the same value as that of the first run
         for (gr_k = 1; gr_k < gr_h; gr_k = gr_k + 1)
            if (gpu_get_px(gpu_walk(gpu_m_dst_base, GR_P, gr_sw, gr_w, gr_k * gr_w + gr_w - 1), gr_bl) !==
                gpu_get_px(gpu_walk(gpu_m_dst_base, GR_P, gr_sw, gr_w, gr_w - 1), gr_bl))
               tb_error("AXIS 1 model does not restart per run (test bug)");
         gr_no_err;
         $display("       mode %0d %0dx%0d sw %b N %0d STEP %0d", gr_mode, gr_w, gr_h, gr_sw, gr_n, gr_st);
         gpu_check_touched("gradient AXIS 1 runs");
      end
      gpu_check_all("gradient AXIS 1 runs");

      //--------------------------------------------------------------
      $display("--- 3. EXEC_SPAN chains: every span restarts at i = 0");
      for (gr_i = 0; gr_i < 4; gr_i = gr_i + 1) begin
         gr_set_mode((gr_i == 0) ? 3 : (gr_i == 1) ? 4 : (gr_i == 2) ? 0 : 2);
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gpu_c_fill($random(gpu_seed));
         gr_org = (GR_DST_LO + 20) * gr_ppw + gr_rnd(gr_ppw);
         if (gr_i < 2) gpu_c_dst(GR_P, gr_org + 2 * GR_P + 10);
         else begin
            gpu_c_dst_xy(GR_P, gr_org);
            gpu_c_xy(10, 2);
         end
         gr_mon_begin;
         for (gr_k = 0; gr_k < 12; gr_k = gr_k + 1) begin
            if ((gr_k % 4) == 0)
               gpu_c_grad(1 + gr_rnd(3), gr_rnd(4) != 0, gr_rnd(16) - 8, 1'b1);   // AXIS 0 on a span: plain
            if ((gr_k % 4) == 2) gpu_c_fill($random(gpu_seed));
            gr_dx = ((gr_k % 3) == 2) ? GR_P - gr_rnd(5) : gr_rnd(9) - 4;
            if (gr_i >= 2) gr_dx = ((gr_k % 3) == 2) ? gr_rnd(9) - 4 : gr_dx;  // x/y: DELTA moves x only
            gr_w = 1 + gr_rnd(GR_WMAX);
            gpu_c_span(gr_dx, gr_w);
            if ((gr_i >= 2) && ((gr_k % 3) == 2)) gpu_c_xy(gpu_m_x, 2 + (gr_k + 1) / 3);   // next row: one SET_XY
         end
         gr_mon_end("gradient spans");
         gr_no_err;
         gpu_check_touched("gradient spans");
      end
      gpu_check_all("gradient spans");

      //--------------------------------------------------------------
      $display("--- 4. clip (x/y mode): i counts walk positions, clipped pixels included");
      for (gr_i = 0; gr_i < 6; gr_i = gr_i + 1) begin
         gr_set_mode((gr_i % 2) ? 4 : 3);
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gr_org = (GR_DST_LO + 20) * gr_ppw + 2 * GR_P + 3;
         gpu_c_dst_xy(GR_P, gr_org);
         gpu_c_clip(2, 1, 12, 6);
         gr_sw = (gr_i * 5) & 7;
         gr_w  = (GR_WMAX >= 10) ? 10 : GR_WMAX;
         gr_h  = (GR_HMAX >= 8) ? 8 : GR_HMAX;
         gpu_c_grad((gr_i < 3) ? 1 : 2, gr_i % 2, (gr_i < 3) ? 1 : -2, 1'b1);
         gpu_c_fill(32'h0000_0040);
         gpu_c_size(gr_w, gr_h);
         gr_x = -1 + (gr_sw[2] ? (gr_sw[0] ? gr_h : gr_w) - 1 : 0);           // top-left at (-1, -1)
         gr_y = -1 + (gr_sw[1] ? (gr_sw[0] ? gr_w : gr_h) - 1 : 0);
         gpu_c_xy(gr_x, gr_y);
         gr_cl0 = gpu_exp_clip;
         gr_mon_begin;
         gpu_c_exec_xy(GPU_FILL, 4'd0, gr_sw, 3'b000);
         gpu_c_span(-2, (GR_WMAX >= 9) ? 9 : GR_WMAX);                         // span starting at x - 2
         gr_mon_end("gradient + clip");
         if (gpu_exp_clip == gr_cl0) tb_error("gradient + clip case with no clipped pixel (test bug)");
         if (gr_i == 0)                                                  // AXIS 0, N 1, STEP 1, no swap:
            gr_expect(gr_org + 2 * GR_P + 2, 32'h40 + 3);                // (2, 2) is on walk line 3
         gr_no_err;
         gpu_check_touched("gradient + clip");
      end
      gpu_c_noclip;
      gpu_check_all("gradient + clip");

      //--------------------------------------------------------------
      $display("--- 5. index wrap at low bpp, 16-bpp carries (literal values)");
      for (gr_mode = 0; gr_mode < 3; gr_mode = gr_mode + 1) begin
         gr_set_mode(gr_mode);
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gr_b = (GR_DST_LO + 20) * gr_ppw;
         gpu_c_dst(GR_P, gr_b);
         gpu_c_fill(32'hFFF0 | (gr_pm - 1));
         gpu_c_size(GR_WMAX, 14'd1);
         gpu_c_grad(1, 1'b1, 7, 1'b1);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
         for (gr_k = 0; gr_k < GR_WMAX; gr_k = gr_k + 1)
            gr_expect(gr_b + gr_k, (gr_pm - 1) + 7 * gr_k);
         gpu_c_dst(GR_P, gr_b + GR_P);
         gpu_c_grad(2, 1'b1, -8, 1'b1);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b100, 3'b000);                  // X swap: ramp right to left
         gpu_wait_idle;
         gr_no_err;
         gpu_check_touched("gradient index wrap");
      end
      gr_set_mode(4);
      gr_b = (GR_DST_LO + 20) * 2 + 1;
      gpu_c_dst(GR_P, gr_b);
      gpu_c_size(14'd3, 14'd1);
      gpu_c_grad(1, 1'b1, 1, 1'b1);
      gpu_c_fill(32'h0000_001F);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // 001F 0020 0021
      gr_expect(gr_b, 32'h001F); gr_expect(gr_b + 1, 32'h0020); gr_expect(gr_b + 2, 32'h0021);
      gpu_c_dst(GR_P, gr_b + GR_P);
      gpu_c_fill(32'h0000_FFFE);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // FFFE FFFF 0000
      gr_expect(gr_b + GR_P + 2, 32'h0000);
      gpu_c_dst(GR_P, gr_b + 2 * GR_P);
      gpu_c_grad(1, 1'b1, -1, 1'b1);
      gpu_c_fill(32'h0000_0801);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // 0801 0800 07FF
      gr_expect(gr_b + 2 * GR_P + 2, 32'h07FF);
      gpu_c_dst(GR_P, gr_b + 3 * GR_P);
      gpu_c_grad(1, 1'b1, -8, 1'b1);
      gpu_c_fill(32'h0000_0005);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // 0005 FFFD FFF5
      gr_expect(gr_b + 3 * GR_P + 2, 32'hFFF5);
      gpu_wait_idle;
      gr_no_err;
      gpu_check_touched("gradient 16-bpp carries");
      gpu_check_all("gradient wrap / carries");

      //--------------------------------------------------------------
      $display("--- 6. raster ops 0..15 with the ramp as S (op 15: the ramp)");
      for (gr_k = 0; gr_k < 16; gr_k = gr_k + 1) begin
         gr_set_mode((gr_k % 2) ? 3 : 1);
         if (gr_k < 2) gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gpu_c_dst(GR_P, (GR_DST_LO + 30) * gr_ppw + gr_k * 3 * GR_P + gr_rnd(gr_ppw));
         gpu_c_size(1 + gr_rnd(GR_WMAX), 1 + gr_rnd(3));
         gpu_c_grad(1 + gr_rnd(2), gr_rnd(2), gr_rnd(16) - 8, 1'b1);
         gpu_c_fill($random(gpu_seed));
         gr_mon_begin;
         gpu_c_exec_xy(GPU_FILL, gr_k, $random(gpu_seed) & 3'b110, 3'b000);
         gr_mon_end("gradient raster ops");
      end
      gr_no_err;
      gpu_check_touched("gradient raster ops");
      gpu_check_all("gradient raster ops");

      //--------------------------------------------------------------
      $display("--- 7. EN = 0 = plain fill; gradient left on: no effect on COPY / EXPAND / TEXSPAN / TEXRECT");
      gr_set_mode(3);
      gpu_preload_rand(GR_SRC_LO, GR_SRC_HI);
      gpu_preload_rand(GR_DST_LO, GR_DST_HI);
      gr_b = (GR_DST_LO + 20) * 4 + 1;
      gpu_c_grad(1, 1'b1, 5, 1'b0);                                     // N, STEP set, EN = 0
      gpu_c_fill($random(gpu_seed));
      gpu_c_size(14'd6, 14'd3);
      gpu_c_dst(GR_P, gr_b);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_c_span(4 * GR_P, 14'd6);
      gpu_c_grad(1, 1'b1, 3, 1'b1);                                     // on, then non-FILL kinds
      gpu_c_size(14'd6, 14'd3);
      gpu_c_src(16'd8, 48 * 4 + 2);
      gpu_c_dst(GR_P, gr_b + 6 * GR_P);
      gpu_c_exec_xy(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_c_transp(gpu_get_px(48 * 4 + 3, 3));
      gpu_c_dst(GR_P, gr_b + 10 * GR_P);
      gpu_c_exec_xy(GPU_COPYT, 4'd0, 3'b000, 3'b000);
      gpu_c_src(16'd0, 48 * 16 + 5);
      gpu_c_expand(4 * GR_P, 3'b000, 1'b1, 2'd1);
      gpu_c_src(16'd0, 48 * 4);
      gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_c_uv($random(gpu_seed), $random(gpu_seed));
      gpu_c_step(16'h0800, 16'h0000);
      gpu_c_step_row(16'h0000, 16'h0800);
      gpu_c_texspan(4 * GR_P, 14'd6);
      gpu_c_size(14'd6, 14'd3);
      gpu_c_texrect(2 * GR_P);
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);                    // still on for FILL
      gpu_wait_idle;
      gr_no_err;
      gpu_check_touched("gradient no-leak");
      gpu_check_all("gradient no-leak");

      //--------------------------------------------------------------
      $display("--- 8. SET_GRAD, FILL, SPAN in a CALL list");
      for (gr_i = 0; gr_i < 2; gr_i = gr_i + 1) begin
         gr_set_mode((gr_i == 0) ? 3 : 4);
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gr_b = (GR_DST_LO + 100) * gr_ppw + 5;
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_cap_n  = 0;
         gpu_cap_en = 1'b1;
         gpu_c_grad(2, 1'b0, 3, 1'b1);
         gpu_c_fill($random(gpu_seed));
         gpu_c_size(14'd5, 14'd6);
         gpu_c_dst(GR_P, gr_b);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b010, 3'b000);
         gpu_c_grad(1, 1'b1, -1, 1'b1);
         gpu_c_span(8 * GR_P, 14'd7);
         gpu_c_span(GR_P, 14'd3);
         gpu_c_grad(0, 1'b1, 2, 1'b1);                                  // N = 0 counts as 1
         gpu_c_span(GR_P, 14'd5);
         gpu_c_grad(1, 1'b1, 2, 1'b0);
         gpu_c_span(GR_P, 14'd5);
         gpu_c_fence(1'b1);
         gpu_cap_en = 1'b0;
         gr_list_write;
         gr_n24 = gpu_cap_n;
         gpu_push({OP_CALL, 4'h0, gr_n24});
         gpu_push(GR_LIST);
         gpu_wait_idle;
         reg_rd_mask(IRQ_FLAG, IF_DONE | IF_FENCE | IF_IDLE, IF_GPU_ALL);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gr_no_err;
         $display("       mode %0d: %0d list words", gr_mode, gpu_cap_n);
         gpu_check_touched("gradient CALL list");
      end
      gpu_check_all("gradient CALL list");

      //--------------------------------------------------------------
      $display("--- 9. per-channel gradient (RGB, 16 bpp)");
      gr_set_mode(4);
      gpu_preload_rand(GR_DST_LO, GR_DST_HI);
      // literal: fill 0, R +1 per pixel, G +0.5, B -1 from 31
      gr_org = (GR_DST_LO + 10) * gr_ppw;
      gpu_c_grad_rgb(1, 1'b1, 64, 32, -64, 1'b1);
      gpu_c_fill(32'h0000_001F);
      gpu_c_size(14'd6, 14'd1);
      gpu_c_dst(GR_P, gr_org);
      gr_mon_begin;
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gr_mon_end("RGB gradient literal");
      gr_expect(gr_org,     32'h001F);
      gr_expect(gr_org + 1, 32'h081E);                                  // R 1, G 0, B 30
      gr_expect(gr_org + 2, 32'h103D);                                  // R 2, G 1, B 29
      gr_expect(gr_org + 5, 32'h285A);                                  // R 5, G 2, B 26
      gr_no_err;
      gpu_check_touched("RGB gradient literal");
      for (gr_c = 0; gr_c < 24; gr_c = gr_c + 1) begin
         gr_ax = gr_c % 2;
         gr_n  = ((gr_c / 2) % 4 == 0) ? 1 : ((gr_c / 2) % 4 == 1) ? 3 : ((gr_c / 2) % 4 == 2) ? 0 : 2;
         case (gr_c % 6)
           0 : begin gr_dr =  511; gr_dg = -512; gr_db =  511; end    // saturating
           1 : begin gr_dr = -512; gr_dg =  511; gr_db = -512; end
           2 : begin gr_dr =    0; gr_dg =    1; gr_db =   -1; end    // below one unit for long
           default : begin gr_dr = gr_rnd(1024) - 512; gr_dg = gr_rnd(1024) - 512; gr_db = gr_rnd(1024) - 512; end
         endcase
         gr_sw = (gr_c * 5) & 7;
         gr_op = ((gr_c % 4) == 3) ? 4'd6 : 4'd0;
         if (gr_ax) begin
            gr_w = (gr_c % 3 == 0) ? GR_LONG : 1 + gr_rnd(GR_WMAX);
            gr_h = 1 + gr_rnd(3);
         end else begin
            gr_w = 1 + gr_rnd(4);
            gr_h = (gr_c % 3 == 0) ? GR_LONG : 1 + gr_rnd(GR_HMAX);
            if (gr_c % 3 == 0) gr_sw = gr_sw & 3'b110;
         end
         gr_f = $random(gpu_seed);
         gr_org = (GR_DST_LO + 10) * gr_ppw + gr_rnd(gr_ppw);
         gpu_c_grad_rgb(gr_n, gr_ax, gr_dr, gr_dg, gr_db, 1'b1);
         gpu_c_fill(gr_f);
         gpu_c_size(gr_w, gr_h);
         gpu_c_dst(GR_P, gr_corner(gr_org, GR_P, gr_sw, gr_w, gr_h));
         gr_mon_begin;
         gpu_c_exec_xy(GPU_FILL, gr_op, gr_sw, 3'b000);
         gr_mon_end("RGB gradient matrix");
         gr_no_err;
         $display("       AXIS %0d N %0d d %0d %0d %0d, %0dx%0d sw %b op %0d fill %h",
                  gr_ax, gr_n, gr_dr, gr_dg, gr_db, gr_w, gr_h, gr_sw, gr_op, gr_f[15:0]);
         gpu_check_touched("RGB gradient matrix");
      end
      gpu_check_all("RGB gradient matrix");
      // GFX_MODE written while the RGB fill draws: the fill keeps the mode its
      // EXEC started with (the model fixes it at the EXEC)
      for (gr_i = 0; gr_i < 2; gr_i = gr_i + 1) begin
         gpu_c_grad_rgb(1, gr_i[0], 64, -32, 96, 1'b1);
         gpu_c_fill($random(gpu_seed));
         gpu_c_size(GR_WMAX, GR_HMAX);
         gpu_c_dst(GR_P, (GR_DST_LO + 10) * gr_ppw + gr_i);
         gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 200);
         reg_wr(CTRL, 32'h10 | 3'd3);                          // 8 bpp while it draws
         gpu_wait_idle;
         reg_wr(CTRL, 32'h10 | gr_mode);
         gr_no_err;
         gpu_check_touched("RGB gradient, GFX_MODE written while it draws");
      end
      // clip in x/y mode: the walk is trimmed, the gradient starts at its phase
      for (gr_i = 0; gr_i < 8; gr_i = gr_i + 1) begin
         gpu_preload_rand(GR_DST_LO, GR_DST_HI);
         gr_org = (GR_DST_LO + 20) * gr_ppw + 2 * GR_P + 3;
         gpu_c_dst_xy(GR_P, gr_org);
         gpu_c_clip(2, 1, 12, 6);
         gr_sw = (gr_i * 3) & 7;
         gr_w  = (GR_WMAX >= 10) ? 10 : GR_WMAX;
         gr_h  = (GR_HMAX >= 8) ? 8 : GR_HMAX;
         gpu_c_grad_rgb(1 + (gr_i % 3), gr_i % 2, gr_rnd(1024) - 512, gr_rnd(1024) - 512, gr_rnd(1024) - 512, 1'b1);
         gpu_c_fill($random(gpu_seed));
         gpu_c_size(gr_w, gr_h);
         gr_x = -3 + (gr_sw[2] ? (gr_sw[0] ? gr_h : gr_w) - 1 : 0);
         gr_y = -2 + (gr_sw[1] ? (gr_sw[0] ? gr_w : gr_h) - 1 : 0);
         gpu_c_xy(gr_x, gr_y);
         gr_cl0 = gpu_exp_clip;
         gr_mon_begin;
         gpu_c_exec_xy(GPU_FILL, 4'd0, gr_sw, 3'b000);
         gpu_c_span(-2, (GR_WMAX >= 9) ? 9 : GR_WMAX);
         gr_mon_end("RGB gradient + clip");
         if (gpu_exp_clip == gr_cl0) tb_error("RGB gradient + clip case with no clipped pixel (test bug)");
         gr_no_err;
         gpu_check_touched("RGB gradient + clip");
      end
      // a deep phase: the walk starts 25 pixels in, steps +-511 (saturated)
      if (GR_LONG >= 40)
         for (gr_i = 0; gr_i < 2; gr_i = gr_i + 1) begin
            gpu_preload_rand(GR_DST_LO, GR_DST_HI);
            gr_org = (GR_DST_LO + 20) * gr_ppw + 2 * GR_P + 3;
            gpu_c_dst_xy(GR_P, gr_org);
            gpu_c_clip(25, 0, 30, 1);
            gpu_c_grad_rgb(1, 1'b1, gr_i ? -512 : 511, gr_i ? 511 : -512, gr_i ? 300 : -300, 1'b1);
            gpu_c_fill(gr_i ? 32'h0000_0000 : 32'h0000_FFFF);
            gpu_c_size(14'd40, 14'd2);
            gpu_c_xy(0, 0);
            gr_mon_begin;
            gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
            gr_mon_end("RGB gradient, deep phase");
            gr_no_err;
            gpu_check_touched("RGB gradient, deep phase");
         end
      gpu_c_noclip;
      // in a CALL list, then RGB at 8 bpp: the plain gradient (its STEP)
      gpu_preload_rand(GR_DST_LO, GR_DST_HI);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_cap_n  = 0;
      gpu_cap_en = 1'b1;
      gpu_c_grad_rgb(2, 1'b1, 100, -50, 300, 1'b1);
      gpu_c_fill($random(gpu_seed));
      gpu_c_dst(GR_P, (GR_DST_LO + 100) * gr_ppw + 3);
      gpu_c_span(0, 14'd9);
      gpu_c_span(GR_P, 14'd7);
      gpu_c_fence(1'b1);
      gpu_cap_en = 1'b0;
      gr_list_write;
      gr_n24 = gpu_cap_n;
      gpu_push({OP_CALL, 4'h0, gr_n24});
      gpu_push(GR_LIST);
      gpu_wait_idle;
      reg_rd_mask(IRQ_FLAG, IF_DONE | IF_FENCE | IF_IDLE, IF_GPU_ALL);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gr_no_err;
      gpu_check_touched("RGB gradient CALL list");
      gr_set_mode(3);
      gpu_c_grad_rgb(1, 1'b1, 64, 64, 64, 1'b1);
      gpu_c_fill(32'h0000_0010);
      gpu_c_size(14'd5, 14'd1);
      gpu_c_dst(GR_P, (GR_DST_LO + 150) * gr_ppw);
      gr_mon_begin;
      gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gr_mon_end("RGB at 8 bpp");
      gr_expect((GR_DST_LO + 150) * gr_ppw + 4, 32'h10);                 // STEP 0: the fill colour
      gr_no_err;
      gpu_check_touched("RGB at 8 bpp");
      gpu_c_grad(1, 1'b0, 0, 1'b0);
      gpu_check_all("RGB gradient");

      // 10. long gradients: a rectangle of about 1000 pixels (or lines)
      // trimmed by the clip window to its last 8 x 2: the set-up's phase
      // (start index / N and its remainder) for large indexes, N up to 4095
      if (GPU_DIM_MASK >= 1023) begin
         $display("=== 10. long gradients: the clip window keeps the end of a ~1000-pixel ramp");
         for (gr_k = 0; gr_k < 16; gr_k = gr_k + 1) begin
            gr_set_mode((gr_k < 8) ? 4 : 3);
            gr_off = 900 + gr_rnd(110);
            gr_n   = (gr_k % 8 == 0) ? 1 : (gr_k % 8 == 1) ? 2 : (gr_k % 8 == 2) ? 3 : (gr_k % 8 == 3) ? 4095 :
                     (gr_k % 8 == 4) ? 0 : (gr_k % 8 == 5) ? 255 : 7 + gr_rnd(60);
            gpu_c_dst_xy(GR_P, (GR_DST_LO + 200) * gr_ppw + 3);
            gpu_c_fill($random(gpu_seed));
            if ((gr_bl == 4) && gr_rnd(2))
               gpu_c_grad_rgb(gr_n, gr_k[0], gr_rnd(1024) - 512, gr_rnd(1024) - 512, gr_rnd(1024) - 512, 1'b1);
            else
               gpu_c_grad(gr_n, gr_k[0], gr_rnd(16) - 8, 1'b1);
            if (gr_k[0]) begin                                       // AXIS 1: along the run
               gpu_c_size(gr_off + 8, 2);
               gpu_c_xy(-gr_off, 0);
            end else begin                                           // AXIS 0: per line
               gpu_c_size(8, gr_off + 2);
               gpu_c_xy(0, -gr_off);
            end
            gpu_c_clip(0, 0, 7, 1);
            gr_mon_begin;
            gpu_c_exec_xy(GPU_FILL, 4'd0, 3'b000, 3'b000);
            gr_mon_end("long gradient");
            gr_no_err;
            gpu_check_touched("long gradient");
            gpu_c_noclip;
         end
         gpu_c_grad(1, 1'b0, 0, 1'b0);
         gpu_check_all("long gradients");
      end

      gr_no_err;
      reg_rd_mask(GPU_STAT, GS_EMPTY | GPU_FIFO_DEPTH, 32'hF0FF_FFFF);
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
