//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_rstream
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_rstream.v
// Module Description : Constrained-random GPU command stream checked against
//                      the word-level stream model of gpu_model.v.
//                      Segments of 1-6 primitives over every EXEC kind the
//                      build has (FILL, COPY, COPY_TRANSP, SPAN, EXPAND incl.
//                      MASK / OPAQUE, TEXSPAN, TEXRECT, triangles, textured
//                      triangles, lines solid, dashed and anti-aliased with
//                      pen changes, patterns, PH_RST, NO_LAST and OPAQUE)
//                      with random settings: every GFX_MODE, the
//                      display width, address and x/y destinations with
//                      negative coordinates and clip windows, pitch 0 and
//                      explicit pitches, swaps, raster ops 0-15, keys,
//                      gradients (RGB too), blending, palette remap, mask
//                      plane, immediate source (short and long N), FENCE
//                      (tag, AUTO, IRQ), RESET_STATE, WAIT_REFR_DONE before a
//                      flush, reserved / ignored bits set at random. About a
//                      quarter of the segments run as a CALL list. Each
//                      setting is sent only when the planned primitive needs
//                      another value than the GPU holds: nothing is re-sent
//                      after a flush, and a segment after a flush may start
//                      with a bare EXEC on the kept settings.
//                      Injections at random points of the push stream and
//                      random cycles: CLEAR_ERR, ABORT, both, GPU_EN 0 -> 1
//                      (cut commands, owed operands and immediate data
//                      included), DISCARD (alone, an operand or immediate
//                      data owed or the source armed, or not partial; with
//                      the flushes; with the FIFO full: a pending marker),
//                      bad words of every ERR_CAUSE (1-6, in the
//                      FIFO and in lists) with each recovery, a push dropped
//                      on a full FIFO (debug freeze) then resynchronised,
//                      discarded or misread, debug freeze pulses,
//                      GPU_FIFO_LOW writes (checked by gpu_inv_check).
//                      Observation boundary: the stream model decodes the
//                      logged words up to where the GPU had got. At a flush
//                      that is GPU_STAT.USED, LIST and GPU_LIST as a read in
//                      the flush's first cycle would return (taken from the
//                      register read data of blns_gpu); elsewhere the
//                      registers are read. The image of the primitives in
//                      flight at a flush (or an ERR_CAUSE 5 fault) must be a
//                      prefix of the model's writes, whole primitives for a
//                      CLEAR_ERR outside ERR.
//                      Checks at every idle or ERR point: whole VRAM against
//                      the model, GPU_STAT (ERR, ERR_CAUSE, ERR_OPCODE,
//                      LIST), GPU_ERR, GPU_FENCE, GPU_LIST, IRQ_FLAG GPU_OVFL
//                      / GPU_ERR / GPU_FENCE, the FIFO words accepted, and
//                      the byte enables of every GPU write (only bytes of
//                      visited pixels). Cross-coverage bins (rs_*) are
//                      printed as COVERAGE HIT lines.
//                      BLNS_GPU_RS_SEEDS (bench only): seed streams run one
//                      after the other; RS_SEGS segments each.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT
`ifdef RS_TRACE_ON
`define RS_TRACE
`endif

`include "gpu_model.v"

`define RS_G dut.u_core.G_GPU.u_gpu

`ifdef BLNS_GPU_RS_SEEDS
localparam integer RS_NSEEDS = `BLNS_GPU_RS_SEEDS;
`else
localparam integer RS_NSEEDS = 1;
`endif
`ifdef RS_SEGS_DEF
localparam integer RS_SEGS = `RS_SEGS_DEF;
`else
localparam integer RS_SEGS = 500;
`endif

// VRAM areas (words)
localparam integer RS_LIST_LO = 64;              // command lists
localparam integer RS_LIST_HI = 2112;
localparam integer RS_SRC_LO  = 2304;            // sources, textures, EXPAND sources
localparam integer RS_SRC_HI  = 8448;
localparam integer RS_MSK_LO  = 8448;            // mask plane
localparam integer RS_MSK_HI  = 8960;
localparam integer RS_TAB_LO  = 8960;            // four remap tables (64 words each)
localparam integer RS_A8_LO   = 9216;            // RGB565A8 alpha planes: words [9216, 10240)
localparam integer RS_DST_LO  = 10240;           // destinations
localparam integer RS_DST_HI  = 36864;
localparam integer RS_M       = 8;               // canvas margin (pixels)
localparam integer RS_WMAX    = (GPU_DIM_MASK >= 24) ? 24 : GPU_DIM_MASK;
localparam integer RS_HMAX    = (GPU_DIM_MASK >= 12) ? 12 : GPU_DIM_MASK;
localparam integer RS_DWMAX   = (1 << DIM_W) - 1;  // widest display width (DISP_SIZE field)
localparam integer RS_XY      = (GPU_XY_EN != 0);
localparam integer RS_TRI     = (GPU_TRI_EN != 0) && (GPU_XY_EN != 0);
localparam integer RS_LINE    = (GPU_LINE_EN != 0) && (GPU_XY_EN != 0);
localparam integer RS_BIL     = (GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0);

integer    rs_seed, rs_rsv_seed, rs_si, rs_seg;
reg        rs_rsvon;

function integer rs_r;                           // uniform in [0, n)
   input integer n;
   begin
      rs_r = (n <= 1) ? 0 : ((f32($random(rs_seed))) % n);
   end
endfunction

function integer rs_rr;                          // uniform in [a, b]
   input integer a;
   input integer b;
   begin
      rs_rr = a + rs_r(b - a + 1);
   end
endfunction

function [31:0] rs_rsv;                          // random bits in the ignored field m
   input [31:0] m;
   reg   [31:0] v;
   begin
      v = $random(rs_rsv_seed);
      rs_rsv = (rs_rsvon && v[31]) ? (v & m) : 32'h0;
      if (rs_rsv != 32'h0) gpu_rsv_n = gpu_rsv_n + 1;
   end
endfunction

// Sized random fields
function [0:0] f1;
   input integer v;
   begin
      f1 = v;
   end
endfunction

function [2:0] f3;
   input integer v;
   begin
      f3 = v;
   end
endfunction

function [3:0] f4;
   input integer v;
   begin
      f4 = v;
   end
endfunction

function [7:0] f8;
   input integer v;
   begin
      f8 = v;
   end
endfunction

function [9:0] f10;
   input integer v;
   begin
      f10 = v;
   end
endfunction

function [11:0] f12;
   input integer v;
   begin
      f12 = v;
   end
endfunction

function [13:0] f14;
   input integer v;
   begin
      f14 = v;
   end
endfunction

function [15:0] f16;
   input integer v;
   begin
      f16 = v;
   end
endfunction

function [23:0] f24;
   input integer v;
   begin
      f24 = v;
   end
endfunction

function [27:0] f28;
   input integer v;
   begin
      f28 = v;
   end
endfunction

function [31:0] f32;
   input integer v;
   begin
      f32 = v;
   end
endfunction

//----------------------------------------------------------------------------
// Probes: words the FIFO accepted, the decoder position at a flush, GPU writes
//----------------------------------------------------------------------------
integer    rs_acc = 0;                           // accepted pushes (blns_gpu push)
reg        rs_fl_q = 1'b0;
integer    rs_fl_cnt = 0;
reg [31:0] rs_fl_stat = 32'h0, rs_fl_list = 32'h0;
reg        rs_fl_ipop = 1'b0;
reg        rs_fl_pend = 1'b0;                     // a DISCARD marker pending at the flush (not in USED)
integer    rs_dc_cnt = 0;                         // DISCARD writes (GPU_EN = 1)
reg [31:0] rs_dc_stat = 32'h0;                    // GPU_STAT in the DISCARD's cycle
reg        rs_dc_mrk = 1'b0;                      // ... a marker queued (or pending)
reg        rs_dc_cut = 1'b0;                      // a DISCARD abandoned an immediate rectangle (settle: a prefix)
reg        rs_dc_pseen = 1'b0;                    // a marker pending seen (coverage)
integer    rs_n_dc, rs_n_dcm, rs_n_dcab;          // DISCARDs, their markers, strict prefixes
localparam integer RS_BEW_MAX = 65536;
reg        rs_bel_on = 1'b0;
integer    rs_bew_n = 0;
reg [31:0] rs_bew_a [0:RS_BEW_MAX-1];
reg  [3:0] rs_bew_e [0:RS_BEW_MAX-1];

always @(posedge hclk)
   if (hresetn_d === 1'b1) begin
      if (`RS_G.push === 1'b1) rs_acc = rs_acc + 1;
      if ((`RS_G.flush === 1'b1) && !rs_fl_q) begin
         rs_fl_stat = `RS_G.gpu_stat;
         rs_fl_ipop = (`RS_G.imm_pop === 1'b1);    // a data word taken in the flush's cycle
         rs_fl_list = `RS_G.gpu_list;
         rs_fl_pend = (`RS_G.mrk_pend === 1'b1);
         rs_fl_cnt  = rs_fl_cnt + 1;
      end
      if (`RS_G.mrk_pend === 1'b1) rs_dc_pseen = 1'b1;
      if (`RS_G.discard === 1'b1) begin
         rs_dc_stat = `RS_G.gpu_stat;
         rs_dc_mrk  = (`RS_G.mrk_go === 1'b1);
         rs_dc_cnt  = rs_dc_cnt + 1;
      end
      rs_fl_q = (`RS_G.flush === 1'b1);
      if (rs_bel_on && (vram_cen === 1'b0) && (vram_wen !== 4'hF) &&
          (dut.u_core.u_vram_arb.gnt_o[VRQ_GPU] === 1'b1)) begin
         if (rs_bew_n < RS_BEW_MAX) begin
            rs_bew_a[rs_bew_n] = vram_addr;
            rs_bew_e[rs_bew_n] = ~vram_wen;
         end
         rs_bew_n = rs_bew_n + 1;
      end
   end

//----------------------------------------------------------------------------
// Coverage
//----------------------------------------------------------------------------
reg  rs_cv_kd [0:GPU_SM_NK*5-1];                 // kind x depth
reg  rs_cv_kf [0:GPU_SM_NK*8-1];                 // kind x feature
reg  rs_cv_fk [0:4*(GPU_SM_NK+1)-1];             // flush kind x kind in flight (+ idle)
reg  rs_cv_ec [0:7*3-1];                         // cause x context (FIFO, list, run-ahead)
reg  rs_cv_cut [0:15];                           // cut command (decoded word, operand lost) by opcode
localparam integer RS_NMISC = 43;
reg  rs_cv_misc [0:RS_NMISC-1];
integer rs_n_fl, rs_n_err, rs_n_drop, rs_n_prefix, rs_n_whole, rs_n_none, rs_n_list, rs_n_frz, rs_n_bare;
integer rs_n_px;
initial begin : rs_cv_init
   integer ii;
   for (ii = 0; ii < GPU_SM_NK*5; ii = ii + 1) rs_cv_kd[ii] = 1'b0;
   for (ii = 0; ii < GPU_SM_NK*8; ii = ii + 1) rs_cv_kf[ii] = 1'b0;
   for (ii = 0; ii < 4*(GPU_SM_NK+1); ii = ii + 1) rs_cv_fk[ii] = 1'b0;
   for (ii = 0; ii < 21; ii = ii + 1) rs_cv_ec[ii] = 1'b0;
   for (ii = 0; ii < 16; ii = ii + 1) rs_cv_cut[ii] = 1'b0;
   for (ii = 0; ii < RS_NMISC; ii = ii + 1) rs_cv_misc[ii] = 1'b0;
end
// misc bins
localparam integer CV_DROP = 0, CV_MISREAD = 1, CV_WAITFL = 2, CV_FREEZE = 3, CV_FAUTO = 4, CV_FIRQ = 5,
                   CV_RSTATE = 6, CV_BARE = 7, CV_CUTQ = 8, CV_IMMCUT = 9, CV_DATADROP = 10, CV_SKIP = 11,
                   CV_ABORT_ERR = 12, CV_PREFIX = 13, CV_LISTCUT = 14, CV_FRZFL = 15,
                   CV_LDASH = 16, CV_LERR2 = 17, CV_LERR4 = 18, CV_LPHRST = 19,
                   CV_DC_NOP = 20, CV_DC_OPND = 21, CV_DC_DATA = 22, CV_DC_ARM = 23, CV_DC_PEND = 24,
                   CV_DC_FLUSH = 25, CV_DC_ERR = 26, CV_DC_SKIP = 27, CV_FLOW_WR = 28,
                   CV_A8_COPY = 29, CV_A8_TEX = 30, CV_MIX5 = 31, CV_ERR_C2_A8 = 32, CV_ERR_C1_A8_MPL = 33,
                   CV_ERR_C1_A8_IMM = 34, CV_BIL = 35, CV_BIL_A8 = 36, CV_BIL_TBORDER = 37, CV_BIL_CLAMP = 38,
                   CV_BIL_WRAP = 39, CV_ERR_C2_BIL = 40, CV_FL_ABORT_BIL = 41, CV_FL_CLR_BIL = 42;

function [8*12-1:0] rs_kname;
   input integer k;
   begin
      case (k)
        0: rs_kname = "fill";    1: rs_kname = "copy";    2: rs_kname = "copyt";
        3: rs_kname = "span";    4: rs_kname = "expand";  5: rs_kname = "texspan";
        6: rs_kname = "texrect"; 7: rs_kname = "tri";     8: rs_kname = "tritex";
        9: rs_kname = "line";    10: rs_kname = "lineaa";
        default: rs_kname = "idle";
      endcase
   end
endfunction

function [8*8-1:0] rs_fname;
   input integer f;
   begin
      case (f)
        0: rs_fname = "clip";  1: rs_fname = "remap"; 2: rs_fname = "mask";  3: rs_fname = "blend";
        4: rs_fname = "grad";  5: rs_fname = "imm";   6: rs_fname = "list";  default: rs_fname = "xy";
      endcase
   end
endfunction

function [8*10-1:0] rs_flname;
   input integer f;
   begin
      case (f)
        0: rs_flname = "clrerr"; 1: rs_flname = "abort"; 2: rs_flname = "gpuen"; default: rs_flname = "clrabort";
      endcase
   end
endfunction

task rs_cov_report;
   integer kk, ff;
   begin
      if (rs_dc_pseen) rs_cv_misc[CV_DC_PEND] = 1'b1;
      for (kk = 0; kk < GPU_SM_NK; kk = kk + 1) begin
         for (ff = 0; ff < 5; ff = ff + 1)
            if (rs_cv_kd[kk*5+ff]) $display("COVERAGE HIT: rs_%0s_d%0d", rs_kname(kk), 1 << ff);
         for (ff = 0; ff < 8; ff = ff + 1)
            if (rs_cv_kf[kk*8+ff]) $display("COVERAGE HIT: rs_%0s_%0s", rs_kname(kk), rs_fname(ff));
      end
      for (ff = 0; ff < 4; ff = ff + 1)
         for (kk = 0; kk <= GPU_SM_NK; kk = kk + 1)
            if (rs_cv_fk[ff*(GPU_SM_NK+1)+kk]) $display("COVERAGE HIT: rs_fl_%0s_%0s", rs_flname(ff), rs_kname(kk));
      for (kk = 1; kk <= 6; kk = kk + 1)
         for (ff = 0; ff < 3; ff = ff + 1)
            if (rs_cv_ec[kk*3+ff])
               $display("COVERAGE HIT: rs_err_c%0d_%0s", kk, (ff == 0) ? "fifo" : (ff == 1) ? "list" : "ahead");
      for (kk = 0; kk < 16; kk = kk + 1)
         if (rs_cv_cut[kk]) $display("COVERAGE HIT: rs_cut_op%0h", kk);
      for (kk = 0; kk < RS_NMISC; kk = kk + 1)
         if (rs_cv_misc[kk])
            case (kk)
              CV_DROP:      $display("COVERAGE HIT: rs_drop");
              CV_MISREAD:   $display("COVERAGE HIT: rs_drop_misread");
              CV_WAITFL:    $display("COVERAGE HIT: rs_wait_flush");
              CV_FREEZE:    $display("COVERAGE HIT: rs_freeze");
              CV_FAUTO:     $display("COVERAGE HIT: rs_fence_auto");
              CV_FIRQ:      $display("COVERAGE HIT: rs_fence_irq");
              CV_RSTATE:    $display("COVERAGE HIT: rs_reset_state");
              CV_BARE:      $display("COVERAGE HIT: rs_bare_exec");
              CV_CUTQ:      $display("COVERAGE HIT: rs_cut_queued");
              CV_IMMCUT:    $display("COVERAGE HIT: rs_imm_flush");
              CV_DATADROP:  $display("COVERAGE HIT: rs_data_dropped");
              CV_SKIP:      $display("COVERAGE HIT: rs_opnd_discarded");
              CV_ABORT_ERR: $display("COVERAGE HIT: rs_abort_in_err");
              CV_PREFIX:    $display("COVERAGE HIT: rs_flush_mid");
              CV_LISTCUT:   $display("COVERAGE HIT: rs_list_flushed");
              CV_FRZFL:     $display("COVERAGE HIT: rs_freeze_flush");
              CV_LDASH:     $display("COVERAGE HIT: rs_line_dash");
              CV_LERR2:     $display("COVERAGE HIT: rs_err_c2_line");
              CV_LERR4:     $display("COVERAGE HIT: rs_err_c4_line");
              CV_LPHRST:    $display("COVERAGE HIT: rs_line_phrst");
              CV_DC_NOP:    $display("COVERAGE HIT: rs_dc_nop");
              CV_DC_OPND:   $display("COVERAGE HIT: rs_dc_opnd");
              CV_DC_DATA:   $display("COVERAGE HIT: rs_dc_data");
              CV_DC_ARM:    $display("COVERAGE HIT: rs_dc_arm");
              CV_DC_PEND:   $display("COVERAGE HIT: rs_dc_pend");
              CV_DC_FLUSH:  $display("COVERAGE HIT: rs_dc_flush");
              CV_DC_ERR:    $display("COVERAGE HIT: rs_dc_err");
              CV_DC_SKIP:   $display("COVERAGE HIT: rs_dc_skip");
              CV_A8_COPY:   $display("COVERAGE HIT: rs_a8_copy");
              CV_A8_TEX:    $display("COVERAGE HIT: rs_a8_tex");
              CV_MIX5:      $display("COVERAGE HIT: rs_mix5");
              CV_ERR_C2_A8: $display("COVERAGE HIT: rs_err_c2_a8");
              CV_ERR_C1_A8_MPL: $display("COVERAGE HIT: rs_err_c1_a8_mplane");
              CV_ERR_C1_A8_IMM: $display("COVERAGE HIT: rs_err_c1_a8_imm");
              CV_BIL:       $display("COVERAGE HIT: rs_bil");
              CV_BIL_A8:    $display("COVERAGE HIT: rs_bil_a8");
              CV_BIL_TBORDER: $display("COVERAGE HIT: rs_bil_tborder");
              CV_BIL_CLAMP: $display("COVERAGE HIT: rs_bil_clamp");
              CV_BIL_WRAP:  $display("COVERAGE HIT: rs_bil_wrap");
              CV_ERR_C2_BIL: $display("COVERAGE HIT: rs_err_c2_bil");
              CV_FL_ABORT_BIL: $display("COVERAGE HIT: rs_fl_abort_bil");
              CV_FL_CLR_BIL: $display("COVERAGE HIT: rs_fl_clr_bil");
              default:      $display("COVERAGE HIT: rs_flow_wr");
            endcase
   end
endtask

//----------------------------------------------------------------------------
// Planned words of a segment (FIFO or list), with their role
//----------------------------------------------------------------------------
localparam integer RS_PW_MAX = 4096;
reg [31:0] rs_pw [0:RS_PW_MAX-1];
reg  [1:0] rs_pr [0:RS_PW_MAX-1];                // 0 command, 1 operand, 2 data
integer    rs_np;
reg        rs_inlist;                            // planning into a list
reg        rs_plan_stop;                         // nothing planned after this word
reg [31:0] rs_lw [0:RS_PW_MAX-1];
integer    rs_nl;
integer    rs_boundary [0:255];                  // word indexes at a command boundary
integer    rs_nb;

task rs_w;                                       // append a planned word
   input [31:0] w;
   input  [1:0] role;
   begin
      if (rs_inlist && (role != 2'd2)) begin
         if (rs_nl < RS_PW_MAX) rs_lw[rs_nl] = w;
         rs_nl = rs_nl + 1;
      end else begin
         if (rs_np < RS_PW_MAX) begin rs_pw[rs_np] = w; rs_pr[rs_np] = role; end
         rs_np = rs_np + 1;
      end
   end
endtask

task rs_mark;                                    // a command boundary
   begin
      if (rs_nb < 256) rs_boundary[rs_nb] = rs_inlist ? rs_nl : rs_np;
      rs_nb = rs_nb + 1;
   end
endtask

//----------------------------------------------------------------------------
// Generator view of the settings (what the GPU will hold once the planned
// words are decoded); loaded from the model at each segment start
//----------------------------------------------------------------------------
integer    g_bl, g_ppw;
reg        g_dxy;
reg [15:0] g_dpf;
reg [31:0] g_dbase, g_dorg, g_sbase;
integer    g_xyp, g_x, g_y;
reg [15:0] g_spf;
reg  [3:0] g_sfmt;
integer    g_w, g_h;
reg        g_gen, g_aen, g_arm;
reg  [3:0] g_tlw, g_tlh;
reg        g_tfree, g_tbound;
reg [31:0] g_rbase, g_mbase;
integer    g_vx [0:2];                           // triangle vertices (12.4)
integer    g_vy [0:2];
integer    g_lpx, g_lpy;                         // the line pen (12.4)
// the canvas of the segment
integer    cv_p, cv_w, cv_h;
reg [15:0] cv_pf;
reg [31:0] cv_o;

task rs_g_load;
   begin
      g_bl    = gpu_bl(gpu_m_mode);
      g_ppw   = 32 >> g_bl;
      g_dxy   = gpu_m_xy;
      g_dpf   = gpu_m_dst_pitch;
      g_dbase = gpu_m_dst_base;
      g_dorg  = gpu_m_dst_org;
      g_xyp   = gpu_m_xyp;
      g_x     = gpu_m_x;
      g_y     = gpu_m_y;
      g_spf   = gpu_m_src_pitch;
      g_sbase = gpu_m_src_base;
      g_sfmt  = gpu_m_src_fmt;
      g_w     = gpu_m_w;
      g_h     = gpu_m_h;
      g_gen   = gpu_m_gen;
      g_aen   = gpu_m_aen;
      g_arm   = 1'b0;
      g_tlw   = gpu_t_lw;
      g_tlh   = gpu_t_lh;
      g_tfree = gpu_t_free;
      g_tbound = gpu_t_bound;
      g_rbase = gpu_m_rbase;
      g_mbase = gpu_m_mbase;
      for (gpu_i = 0; gpu_i < 3; gpu_i = gpu_i + 1) begin
         g_vx[gpu_i] = gpu_tv_x[gpu_i];
         g_vy[gpu_i] = gpu_tv_y[gpu_i];
      end
      g_lpx   = gpu_m_pen_x;
      g_lpy   = gpu_m_pen_y;
   end
endtask

task rs_g_reset;                                 // after a planned RESET_STATE
   begin
      g_dxy = 1'b0; g_dpf = 16'h0; g_dbase = 32'h0; g_dorg = 32'h0; g_xyp = 1; g_x = 0; g_y = 0;
      g_spf = 16'h0; g_sbase = 32'h0; g_sfmt = 4'h0; g_w = 1; g_h = 1; g_gen = 1'b0; g_aen = 1'b0;
      g_tlw = 4'h0; g_tlh = 4'h0; g_tfree = 1'b0; g_tbound = 1'b0; g_rbase = 32'h0; g_mbase = 32'h0;
      g_vx[0] = 0; g_vx[1] = 0; g_vx[2] = 0; g_vy[0] = 0; g_vy[1] = 0; g_vy[2] = 0;
      g_lpx = 0; g_lpy = 0;
   end
endtask

//----------------------------------------------------------------------------
// Encoders: one command each, the generator view updated
//----------------------------------------------------------------------------
task e_src;                                      // SET_SRC (not IMM)
   input [15:0] pf;
   input  [3:0] fmt;
   input [31:0] base;
   begin
      rs_mark;
      rs_w({OP_SET_SRC, 8'h00, fmt, pf}, 2'd0);
      rs_w(base | (rs_rsv(32'hFFFF_FFFF) & ~GPU_PA_MASK), 2'd1);
      g_spf = pf; g_sfmt = fmt; g_sbase = base & GPU_PA_MASK; g_arm = 1'b0;
   end
endtask

task e_dst;                                      // SET_DST (xy: XY)
   input [15:0] pf;
   input        xy;
   input [31:0] base;
   begin
      rs_mark;
      rs_w({OP_SET_DST, 11'h000, xy, pf}, 2'd0);
      rs_w(base | (rs_rsv(32'hFFFF_FFFF) & ~GPU_PA_MASK), 2'd1);
      g_dpf = pf; g_dxy = xy; g_dbase = base & GPU_PA_MASK; g_dorg = base & GPU_PA_MASK;
      g_x = 0; g_y = 0; g_xyp = (pf == 16'h0) ? gpu_m_dispw : pf;
   end
endtask

task e_size;
   input integer w;
   input integer h;
   reg   [13:0] wf, hf;
   begin
      wf = w; hf = h;
      rs_mark;
      rs_w({OP_SET_SIZE, hf, wf}, 2'd0);
      g_w = w; g_h = h;
   end
endtask

task e_two;                                      // a two-word setting with no planner state
   input [31:0] cw;
   input [31:0] ov;
   begin
      rs_mark;
      rs_w(cw, 2'd0);
      rs_w(ov, 2'd1);
   end
endtask

task e_one;
   input [31:0] cw;
   begin
      rs_mark;
      rs_w(cw, 2'd0);
   end
endtask

task e_xy;
   input integer x;
   input integer y;
   reg   [11:0] xf, yf;
   begin
      xf = x; yf = y;
      e_one({OP_SET_EXT, EXT_SET_XY, yf, xf});
      g_x = x; g_y = y; g_xyp = (g_dpf == 16'h0) ? gpu_m_dispw : g_dpf;
   end
endtask

task e_clip;                                     // a random clip window (or none)
   integer      r, x0, y0, x1, y1;
   reg   [11:0] a, b, c, d;
   begin
      r = rs_r(4);
      if (r == 0) begin x0 = -2048; y0 = -2048; x1 = 2047; y1 = 2047; end
      else begin
         x0 = rs_rr(-RS_M, cv_w / 2); y0 = rs_rr(-RS_M, cv_h / 2);
         x1 = x0 + rs_rr(-2, cv_w); y1 = y0 + rs_rr(-2, cv_h);   // sometimes empty
         if (x1 > cv_w + RS_M - 1) x1 = cv_w + RS_M - 1;
         if (y1 > cv_h + RS_M - 1) y1 = cv_h + RS_M - 1;
      end
      a = x0; b = y0; c = x1; d = y1;
      e_two({OP_SET_EXT, EXT_SET_CLIP, b, a}, ({8'h00, d, c} | rs_rsv(32'hFF00_0000)));
   end
endtask

task e_fill_transp;                              // colours: fill and key, now and then
   reg [31:0] v;
   begin
      if (rs_r(3) != 0) e_two({OP_SET_FILL, 28'h0}, $random(rs_seed));
      if (rs_r(3) == 0) begin
         v = $random(rs_seed);
         if (rs_r(2)) v = gpu_get_px(RS_SRC_LO * g_ppw + rs_r(256), g_bl);   // a key present in the sources
         e_two({OP_SET_TRANSP, 28'h0}, v);
      end
   end
endtask

task e_grad;                                     // gradient on / off
   integer r;
   begin
      if (GPU_GRAD_EN != 0) begin
         r = rs_r(6);
         if (r == 0) begin
            e_one({OP_SET_EXT, EXT_SET_GRAD, 6'h00, 1'b0, 4'h0, 1'b0, 12'h000});
            g_gen = 1'b0;
         end else if (r == 1) begin
            e_one({OP_SET_EXT, EXT_SET_GRAD, 6'h00, 1'b1, f4(rs_r(16)), f1(rs_r(2)), f12(rs_r(6))});
            g_gen = 1'b1;
         end else if ((r == 2) && (g_bl == 4)) begin
            e_two({OP_SET_EXT, EXT_SET_GRGB, 24'h0}, {2'b00, f10(rs_rr(-300, 300)), f10(rs_rr(-300, 300)),
                                                       f10(rs_rr(-300, 300))});
            e_one({OP_SET_EXT, EXT_SET_GRAD, 5'h00, 1'b1, 1'b1, 4'h0, f1(rs_r(2)), f12(rs_r(4))});
            g_gen = 1'b1;
         end
      end
   end
endtask

task e_alpha;
   begin
      if ((GPU_BLEND_EN != 0) && (rs_r(4) == 0)) begin
         g_aen = rs_r(2);
         // [9] MIX5 is a setting (never a reserved bit); [23:10] ignored
         e_one({OP_SET_EXT, 4'h8, 14'h0000, f1(rs_r(2)), g_aen, (rs_r(4) == 0) ? 8'hFF : (f8(rs_r(256)))} |
               rs_rsv(32'h00FF_FC00));
      end
   end
endtask

task e_remap;                                    // REMAP mode for the EXEC (needs a table)
   output [1:0] m;
   begin
      m = 2'd0;
      if ((GPU_REMAP_EN != 0) && (rs_r(4) == 0)) begin
         m = 1 + rs_r(2);
         if ((g_rbase == 0) || (rs_r(3) == 0)) begin
            g_rbase = RS_TAB_LO + 64 * rs_r(4);
            e_two(({OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h0} | rs_rsv(32'h000F_FFFF)), g_rbase | rs_r(64));
         end
      end
   end
endtask

//----------------------------------------------------------------------------
// Geometry
//----------------------------------------------------------------------------
// First pixel visited of a w x h rectangle at (x, y) of the canvas (address)
function [31:0] rs_corner;
   input [31:0] org;
   input integer pitch;
   input integer x;
   input integer y;
   input  [2:0] sw;
   input integer w;
   input integer h;
   integer      rows, cols;
   begin
      rows = sw[0] ? w : h;
      cols = sw[0] ? h : w;
      rs_corner = org + (y + (sw[1] ? rows - 1 : 0)) * pitch + x + (sw[2] ? cols - 1 : 0);
   end
endfunction

// Pick a rectangle position inside the safe box of the canvas: (rs_px, rs_py)
// its top-left pixel, (rs_fx, rs_fy) the first pixel its walk visits
integer rs_px, rs_py, rs_fx, rs_fy;
task rs_pos;
   input integer w;
   input integer h;
   input  [2:0] sw;
   integer      cols, rows;
   begin
      cols = sw[0] ? h : w;
      rows = sw[0] ? w : h;
      rs_px = rs_rr(-RS_M, cv_w + RS_M - cols);
      rs_py = rs_rr(-RS_M, cv_h + RS_M - rows);
      rs_fx = rs_px + (sw[2] ? cols - 1 : 0);
      rs_fy = rs_py + (sw[1] ? rows - 1 : 0);
   end
endtask

// Destination of a primitive: x/y (xy) or address mode; dmove: DELTA allowed
// (returns the DELTA to put in the EXEC word, 0 otherwise)
integer rs_delta;
task rs_dest;
   input        xy;
   input integer w;
   input integer h;
   input  [2:0] sw;
   input        dmove;
   reg   [31:0] base;
   integer      d;
   begin
      rs_delta = 0;
      rs_pos(w, h, sw);
      if (xy) begin
         if (!g_dxy || (g_dorg != cv_o) || (g_xyp != cv_p)) e_dst(cv_pf, 1'b1, cv_o);
         if (dmove && (g_y == rs_fy) && (rs_r(2) == 0)) rs_delta = rs_fx - g_x;
         else if (dmove && rs_r(2)) begin
            d = rs_rr(-12, 12);
            e_xy(rs_fx - d, rs_fy);
            rs_delta = d;
         end else if ((g_x != rs_fx) || (g_y != rs_fy) || rs_r(2))
            e_xy(rs_fx, rs_fy);
      end else begin
         base = rs_corner(cv_o, cv_p, rs_px, rs_py, sw, w, h);
         if (dmove && !g_dxy && (g_dpf == cv_pf) && ((base - g_dbase) < 32'd4000 || (g_dbase - base) < 32'd4000) &&
             rs_r(2))
            rs_delta = base - g_dbase;
         else if (dmove && rs_r(2)) begin
            d = rs_rr(-40, 40);
            e_dst(cv_pf, 1'b0, base - d);
            rs_delta = d;
         end else if (g_dxy || (g_dpf != cv_pf) || (g_dbase != base))
            e_dst(cv_pf, 1'b0, base);
      end
      // a DELTA moves the x/y position and the address-mode base, whatever the mode
      g_x     = g_x + rs_delta;
      g_dbase = (g_dbase + rs_delta) & GPU_PA_MASK;
   end
endtask

// Size, sent only when it changes (or now and then)
task rs_size;
   input integer w;
   input integer h;
   begin
      if ((g_w != w) || (g_h != h) || (rs_r(8) == 0)) e_size(w, h);
   end
endtask

// A source rectangle w x h (swaps sw) at fmt 0 in the source area
task rs_src;
   input integer w;
   input integer h;
   input  [2:0] sw;
   integer      sp, rows;
   reg   [15:0] pf;
   reg   [31:0] org;
   begin
      pf  = rs_r(4) ? (16 + rs_r(100)) : 16'h0;
      sp  = (pf == 16'h0) ? gpu_m_dispw : pf;
      org = RS_SRC_LO * g_ppw + rs_r(g_ppw) + rs_r(8) * sp + rs_r(16);
      e_src(pf, 4'h0, rs_corner(org, sp, 0, 0, sw, w, h));
   end
endtask

//----------------------------------------------------------------------------
// Primitive planners
//----------------------------------------------------------------------------
reg rs_xyok;                                     // x/y mode for this primitive
reg rs_a8 = 1'b0;                                // an RGB565A8 copy / texture (SRC_FMT 5, blend builds)

// The alpha plane of an RGB565A8 source: the byte of the source's lowest
// pixel smin at a random (odd too) offset in the alpha area, the pointer the
// byte of the SET_SRC base pixel
task e_aplane;
   input [31:0] smin;
   reg   [31:0] ab;
   begin
      ab = RS_A8_LO * 4 + rs_r(1024) + (g_sbase - smin);
      e_two(({OP_SET_EXT, EXT_SET_AUX, 4'd4, 20'h00000} | rs_rsv(32'h000F_0000)),
            ab | (rs_rsv(32'hFFFF_FFFF) & ~((32'h1 << (VRAM_AW + 2)) - 32'h1)));
   end
endtask

function [31:0] rs_xw;                           // EXEC word with its ignored bits
   input [31:0] w;
   input [31:0] m;
   begin
      rs_xw = w | rs_rsv(m);
   end
endfunction

task p_fill;
   input        is_tri;
   integer      w, h, op, k;
   reg    [2:0] sw;
   reg    [1:0] rm;
   begin
      w  = rs_rr(1, RS_WMAX); h = rs_rr(1, RS_HMAX);
      sw = rs_r(8);
      op = rs_r(3) ? 0 : rs_r(16);
      e_fill_transp;
      e_grad;
      e_alpha;
      e_remap(rm);
      if (is_tri) begin
         // the canvas in x/y mode; now and then address mode kept (nothing drawn)
         if (g_dxy ? ((g_dorg != cv_o) || (g_xyp != cv_p)) : (rs_r(12) != 0)) e_dst(cv_pf, 1'b1, cv_o);
         if (rs_r(3) == 0) e_clip;
         rs_vtx;
         rs_mark;
         rs_w({OP_EXEC_FILL, 14'h0000, rm, 4'h0, 1'b1, f3(rs_r(8)), op[3:0]}, 2'd0);
      end else begin
         if (rs_xyok && (rs_r(4) == 0)) e_clip;
         rs_dest(rs_xyok, w, h, sw, 1'b0);
         rs_size(w, h);
         rs_mark;
         rs_w(rs_xw({OP_EXEC_FILL, 14'h0000, rm, 4'h0, 1'b0, sw, op[3:0]}, 32'h0EFF_CF00), 2'd0);   // never [24] LINE
      end
   end
endtask

task p_copy;
   input        transp;
   integer      w, h, op, n, k, nw, sp;
   reg    [2:0] dsw, ssw;
   reg    [1:0] rm;
   reg          mpl, imm, inv;
   reg   [31:0] mb, smin;
   begin
      w   = rs_rr(1, RS_WMAX); h = rs_rr(1, RS_HMAX);
      dsw = rs_r(8);
      ssw = rs_r(2) ? dsw : rs_r(8);
      op  = rs_r(3) ? 0 : rs_r(16);
      imm = (GPU_IMM_EN != 0) && !rs_inlist && (rs_r(5) == 0) && !rs_a8;
      if (imm) ssw = 3'b000;
      e_fill_transp;
      e_alpha;
      e_remap(rm);
      if (rs_xyok && (rs_r(4) == 0)) e_clip;
      rs_dest(rs_xyok, w, h, dsw, 1'b0);
      rs_size(w, h);
      mpl = (GPU_MPLANE_EN != 0) && (rs_r(4) == 0) && !rs_a8;
      if (rs_a8) begin                           // RGB565A8: an explicit pitch, the alpha plane
         sp   = 16 + rs_r(100);
         smin = RS_SRC_LO * g_ppw + rs_r(g_ppw) + rs_r(8) * sp + rs_r(16);
         e_src(sp, 4'd5, rs_corner(smin, sp, 0, 0, ssw, w, h));
         e_aplane(smin);
      end else if (!imm) rs_src(w, h, ssw);
      if (mpl) begin
         inv = rs_r(2);
         if (imm) mb = RS_MSK_LO * 32 + rs_r(4096);
         else begin
            sp   = (g_spf == 16'h0) ? gpu_m_dispw : g_spf;
            smin = rs_corner(g_sbase, sp, 0, 0, ssw, w, h);     // the source walk's lowest pixel
            smin = g_sbase - (ssw[1] ? (((ssw[0] ? w : h) - 1) * sp) : 0) - (ssw[2] ? ((ssw[0] ? h : w) - 1) : 0);
            mb   = RS_MSK_LO * 32 + rs_r(4096) + (g_sbase - smin);
         end
         e_two(({OP_SET_EXT, EXT_SET_AUX, 4'd1, 3'b000, inv, 16'h0000} | rs_rsv(32'h000E_0000)), mb);
      end
      if (imm) begin
         nw = (w * h * (1 << g_bl) + 31) / 32;
         n  = (rs_r(4) == 0) ? rs_rr(0, nw + 2) : nw;
         rs_mark;
         rs_w({OP_SET_SRC, 7'h00, 1'b1, 4'h0, g_spf}, 2'd0);
         rs_w(n | rs_rsv(32'hFF00_0000), 2'd1);
         g_sfmt = 4'h0;
         rs_mark;
         rs_w(rs_xw({transp ? GPU_COPYT : GPU_COPY, 14'h0000, rm, mpl, ssw, 1'b0, dsw, op[3:0]}, 32'h80), 2'd0);
         for (k = 0; k < n; k = k + 1) rs_w($random(rs_seed), 2'd2);
      end else begin
         rs_mark;
         rs_w(rs_xw({transp ? GPU_COPYT : GPU_COPY, 14'h0000, rm, mpl, ssw, 1'b0, dsw, op[3:0]}, 32'h80), 2'd0);
      end
   end
endtask

task p_span;
   integer w;
   begin
      w = rs_rr(1, RS_WMAX);
      e_fill_transp;
      e_grad;
      e_alpha;
      rs_dest(rs_xyok, w, 1, 3'b000, 1'b1);
      rs_mark;
      rs_w({OP_EXEC_SPAN, rs_delta[13:0], w[13:0]}, 2'd0);
      g_w = w; g_h = 1;
   end
endtask

task p_expand;
   integer      w, h, op, sd, sp, n, nw, k;
   reg    [2:0] dsw;
   reg    [1:0] rm;
   reg          imm, opq, msk;
   reg   [15:0] pf;
   begin
      w   = rs_rr(1, RS_WMAX); h = rs_rr(1, RS_HMAX);
      dsw = rs_r(8);
      sd  = rs_r(4);
      op  = rs_r(3) ? 0 : rs_r(16);
      opq = rs_r(3) == 0;
      msk = (GPU_BLEND_EN != 0) && (rs_r(3) == 0);
      imm = (GPU_IMM_EN != 0) && !rs_inlist && (rs_r(4) == 0);
      e_fill_transp;
      e_alpha;
      e_remap(rm);
      if (rs_xyok && (rs_r(4) == 0)) e_clip;
      rs_size(w, h);
      if (imm) begin
         nw = (w * h * (1 << sd) + 31) / 32;
         n  = (rs_r(4) == 0) ? rs_rr(0, nw + 2) : nw;
         rs_mark;
         rs_w({OP_SET_SRC, 7'h00, 1'b1, sd[3:0] + 4'd1, g_spf}, 2'd0);
         rs_w(n | rs_rsv(32'hFF00_0000), 2'd1);
         g_sfmt = sd + 1;
      end else begin
         pf = rs_r(2) ? 16'h0 : (w + rs_r(40));
         sp = (pf == 16'h0) ? w : pf;
         e_src(pf, sd[3:0] + 4'd1, (RS_SRC_LO + 3000) * (32 >> sd) + rs_r(64));
      end
      rs_dest(rs_xyok, w, h, dsw, 1'b1);
      rs_mark;
      rs_w(rs_xw({OP_EXEC_EXP, rs_delta[13:0], rm, op[3:0], 1'b0, dsw, msk, opq, 2'b00}, 32'h83), 2'd0);
      if (imm) for (k = 0; k < n; k = k + 1) rs_w($random(rs_seed), 2'd2);
   end
endtask

// Texture settings: a power-of-two texture, or a free-pitch one with BOUND
task e_tex;
   input integer w;
   input integer h;
   input        is_tri;
   reg    [3:0] lw, lh;
   reg          fr, bd;
   reg    [1:0] rm;
   reg   [15:0] pf;
   integer      tw, th;
   begin
      lw = rs_r(6); lh = rs_r(6);
      fr = RS_XY && (rs_r(3) == 0);             // free pitch with BOUND only
      bd = (RS_XY && (fr || (rs_r(3) == 0)));
      rm = 2'd0;
      if ((GPU_REMAP_EN != 0) && (rs_r(4) == 0)) begin
         rm = 1 + rs_r(2);
         if (g_rbase == 0) begin
            g_rbase = RS_TAB_LO + 64 * rs_r(4);
            e_two({OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h00000}, g_rbase);
         end
      end
      pf = fr ? (32 + rs_r(64)) : 16'h0;
      if (!fr && (rs_r(3) == 0)) pf = 16'h0;
      e_src(pf, rs_a8 ? 4'd5 : 4'h0, RS_SRC_LO * g_ppw + rs_r(g_ppw) + rs_r(16));
      if (rs_a8) e_aplane(g_sbase);              // the alpha of texel (0, 0)
      e_one({OP_SET_EXT, EXT_SET_TEX, f8(rs_r(256)), rm, bd, fr, f3(rs_r(8)), f1(rs_r(2)), lh, lw});
      if (RS_BIL && (rs_r(3) == 0))                // TEX_FILTER: BILINEAR, TBORDER (blending), now and then
         e_two(({OP_SET_EXT, EXT_SET_AUX, 4'd5, 18'h00000, f1((GPU_BLEND_EN != 0) && rs_r(2)), f1(rs_r(3) != 0)} |
                rs_rsv(32'h000F_FFFC)), $random(rs_seed));
      g_tlw = lw; g_tlh = lh; g_tfree = fr; g_tbound = bd;
      if (bd) begin
         tw = rs_rr(1, 32); th = rs_rr(1, 32);
         if (!fr && (rs_r(2) == 0)) begin tw = rs_rr(1, 40); th = rs_rr(1, 40); end   // box larger than the texture
         e_one({OP_SET_EXT, EXT_SET_TEXBOX, th[11:0], tw[11:0]});
         e_two({OP_SET_EXT, EXT_SET_UV, 24'h0}, {f16(rs_rr(-640, 2400)), f16(rs_rr(-640, 2400))});
         e_two({OP_SET_EXT, EXT_SET_STEP, 24'h0}, {f16(rs_rr(-4096, 4096)), f16(rs_rr(-4096, 4096))});
         if (RS_XY) e_two({OP_SET_EXT, EXT_SET_STEP_ROW, 24'h0}, {f16(rs_rr(-4096, 4096)), f16(rs_rr(-4096, 4096))});
      end else begin
         // power of two: anything wraps inside the texture
         e_two({OP_SET_EXT, EXT_SET_UV, 24'h0}, $random(rs_seed));
         e_two({OP_SET_EXT, EXT_SET_STEP, 24'h0}, {f16(rs_rr(-8192, 8192)), f16(rs_rr(-8192, 8192))});
         if (RS_XY) e_two({OP_SET_EXT, EXT_SET_STEP_ROW, 24'h0}, {f16(rs_rr(-8192, 8192)), f16(rs_rr(-8192, 8192))});
      end
   end
endtask

task p_texspan;
   integer n;
   reg [2:0] sw;
   begin
      n = rs_rr(1, RS_WMAX);
      e_alpha;
      if (rs_r(3) == 0) e_two({OP_SET_TRANSP, 28'h0}, $random(rs_seed));
      e_tex(n, 1, 1'b0);
      sw = rs_lw_or_pw_tex_sw(1'b0);              // the swaps of the SET_TEX just planned
      if (rs_xyok && (rs_r(4) == 0)) e_clip;
      rs_dest(rs_xyok, n, 1, sw, 1'b1);
      rs_mark;
      rs_w({OP_EXEC_TEX, rs_delta[13:0], n[13:0]}, 2'd0);
      g_w = n; g_h = 1;
   end
endtask

// The swaps of the last SET_TEX planned
function [2:0] rs_lw_or_pw_tex_sw;
   input dummy;
   integer ii;
   reg [31:0] w;
   begin
      rs_lw_or_pw_tex_sw = 3'b000;
      if (rs_inlist) begin
         for (ii = 0; ii < rs_nl; ii = ii + 1)
            if ((rs_lw[ii][31:24] == {OP_SET_EXT, EXT_SET_TEX})) rs_lw_or_pw_tex_sw = rs_lw[ii][11:9];
      end else
         for (ii = 0; ii < rs_np; ii = ii + 1)
            if ((rs_pr[ii] == 2'd0) && (rs_pw[ii][31:24] == {OP_SET_EXT, EXT_SET_TEX})) rs_lw_or_pw_tex_sw = rs_pw[ii][11:9];
   end
endfunction

task p_texrect;
   input        is_tri;
   integer      w, h, k;
   reg    [2:0] sw;
   begin
      w = rs_rr(1, RS_WMAX); h = rs_rr(1, RS_HMAX);
      e_alpha;
      if (rs_r(3) == 0) e_two({OP_SET_TRANSP, 28'h0}, $random(rs_seed));
      e_tex(w, h, is_tri);
      sw = rs_lw_or_pw_tex_sw(1'b0);
      if (is_tri) begin
         if (!g_dxy || (g_dorg != cv_o) || (g_xyp != cv_p)) e_dst(cv_pf, 1'b1, cv_o);
         if (rs_r(3) == 0) e_clip;
         rs_vtx;
         rs_mark;
         rs_w({OP_EXEC_TEXRECT, f14(rs_r(16384)), 6'h00, 1'b1, 7'h00}, 2'd0);
      end else begin
         if (rs_xyok && (rs_r(4) == 0)) e_clip;
         rs_size(w, h);
         rs_dest(rs_xyok, w, h, sw, 1'b1);
         rs_mark;
         rs_w({OP_EXEC_TEXRECT, rs_delta[13:0], 14'h0000}, 2'd0);
      end
   end
endtask

// Triangle vertices: each re-sent at random, and always when the one the GPU
// holds lies outside the safe box of the canvas
task rs_vtx;
   integer k, vx, vy;
   begin
      for (k = 0; k < 3; k = k + 1)
         if ((rs_r(4) != 0) || (g_vx[k] < -RS_M * 16) || (g_vx[k] > (cv_w + RS_M) * 16 - 1) ||
             (g_vy[k] < -RS_M * 16) || (g_vy[k] > (cv_h + RS_M) * 16 - 1)) begin
            vy = rs_rr(-RS_M * 16, (cv_h + RS_M) * 16 - 1);
            vx = rs_rr(-RS_M * 16, (cv_w + RS_M) * 16 - 1);
            e_two({OP_SET_EXT, 4'd9 + k[3:0], 24'h0}, {f16(vy), f16(vx)});
            g_vx[k] = vx;
            g_vy[k] = vy;
         end
   end
endtask

function rs_pw_last_irq;                       // the FENCE just planned has IRQ
   input dummy;
   begin
      rs_pw_last_irq = rs_inlist ? rs_lw[rs_nl - 1][24] : rs_pw[rs_np - 1][24];
   end
endfunction

task p_fence;
   integer r;
   begin
      r = rs_r(3);
      rs_mark;
      rs_w({OP_FENCE, 2'b00, r == 2, rs_r(3) == 0, f24($random(rs_seed))}, 2'd0);
      if (r == 2) rs_cv_misc[CV_FAUTO] = 1'b1;
      if (rs_pw_last_irq(1'b0)) rs_cv_misc[CV_FIRQ] = 1'b1;
   end
endtask


// Lines: x/y mode on the canvas (now and then address mode kept: nothing
// drawn), the pen re-sent at random and always when the one the GPU holds
// lies outside the canvas box (2 pixels inside the margin: an AA line's row
// r + 1), a pattern now and then, PH_RST / NO_LAST / OPAQUE at random; the
// ignored EXEC bits ([27:25], [23:20], [15:14], [11:8], swaps) set at random
task p_line;
   input        aa;
   integer      op, x, y, lo_x, hi_x, lo_y, hi_y;
   reg    [1:0] rm;
   reg    [3:0] opt;
   reg    [4:0] lf;
   begin
      op = rs_r(3) ? 0 : rs_r(16);
      e_fill_transp;
      e_alpha;
      e_remap(rm);
      if (g_dxy ? ((g_dorg != cv_o) || (g_xyp != cv_p)) : (rs_r(12) != 0)) e_dst(cv_pf, 1'b1, cv_o);
      if (rs_r(3) == 0) e_clip;
      lo_x = -(RS_M - 2) * 16; hi_x = (cv_w + RS_M - 2) * 16 - 1;
      lo_y = -(RS_M - 2) * 16; hi_y = (cv_h + RS_M - 2) * 16 - 1;
      if ((rs_r(3) == 0) || (g_lpx < lo_x) || (g_lpx > hi_x) || (g_lpy < lo_y) || (g_lpy > hi_y)) begin
         x = rs_rr(lo_x, hi_x);
         y = rs_rr(lo_y, hi_y);
         e_two(({OP_SET_EXT, EXT_SET_AUX, 4'd2, 20'h0} | rs_rsv(32'h000F_FFFF)), {f16(y), f16(x)});
         g_lpx = x;
         g_lpy = y;
      end
      if (rs_r(5) == 0) begin
         lf = rs_r(32);
         e_two(({OP_SET_EXT, EXT_SET_AUX, 4'd3, 15'h0000, lf} | rs_rsv(32'h000F_FFE0)), $random(rs_seed));
         rs_cv_misc[CV_LDASH] = 1'b1;
      end
      x = (rs_r(4) == 0) ? (g_lpx + rs_rr(-40, 40)) : rs_rr(lo_x, hi_x);   // short ones too
      y = (rs_r(4) == 0) ? (g_lpy + rs_rr(-40, 40)) : rs_rr(lo_y, hi_y);
      if (x < lo_x) x = lo_x;
      if (x > hi_x) x = hi_x;
      if (y < lo_y) y = lo_y;
      if (y > hi_y) y = hi_y;
      opt = {rs_r(6) == 0, rs_r(4) == 0, rs_r(3) == 0, aa};
      if (opt[3]) rs_cv_misc[CV_LPHRST] = 1'b1;
      rs_mark;
      rs_w(rs_xw({OP_EXEC_FILL, 3'b000, 1'b1, 4'h0, opt, 2'b00, rm, 4'h0, 1'b0, 3'b000, op[3:0]}, 32'h0EF0_CF70), 2'd0);
      rs_w({f16(y), f16(x)}, 2'd1);
      g_lpx = x;
      g_lpy = y;
   end
endtask

// One primitive (or FENCE / RESET_STATE) of a random kind
task rs_plan_one;
   integer r;
   reg     done;
   begin
      rs_xyok = RS_XY && rs_r(2);
      rs_a8   = (GPU_BLEND_EN != 0) && (rs_r(3) == 0);  // (copies and textures only)
      done = 1'b0;
      while (!done) begin
         r = rs_r(112);
         done = 1'b1;
         if      (r < 16) p_fill(1'b0);
         else if (r < 28) p_copy(1'b0);
         else if (r < 36) p_copy(1'b1);
         else if (r < 44) p_span;
         else if (r < 56) p_expand;
         else if (r < 64) p_texspan;
         else if (r < 72) begin if (RS_XY) p_texrect(1'b0); else done = 1'b0; end
         else if (r < 82) begin if (RS_TRI) p_fill(1'b1); else done = 1'b0; end
         else if (r < 90) begin if (RS_TRI) p_texrect(1'b1); else done = 1'b0; end
         else if (r < 98) p_fence;
         else if (r >= 100) begin
            if (RS_LINE) p_line((GPU_BLEND_EN != 0) && (rs_r(3) == 0)); else done = 1'b0;
         end else begin
            e_one(({OP_SET_EXT, EXT_SET_EXT2, X2_RESET_STATE, 16'h0000} | rs_rsv(32'h0000_FFFF)));
            rs_g_reset;
            rs_cv_misc[CV_RSTATE] = 1'b1;
         end
      end
      rs_a8 = 1'b0;
   end
endtask

//----------------------------------------------------------------------------
// Bad words (deliberate errors): planned at a command boundary
//----------------------------------------------------------------------------
task rs_plan_bad;
   integer r;
   reg [31:0] w;
   begin
      r = rs_r(rs_inlist ? 16 : 18);
      case (r)
        0: e_one({4'h0, f28($random(rs_seed))});                         // opcode 0
        1: e_one({OP_SET_EXT, 4'd14, f24($random(rs_seed))});              // sub 14
        2: e_one({OP_SET_EXT, EXT_SET_EXT2, 8'd3 + (f8(rs_r(250))), 16'h0000}); // EXT2 code
        3: begin                                                                    // SET_AUX SEL 6-15, and 2 / 3 / 4 / 5 where absent
              rs_mark;
              w = 6 + rs_r(10);
              if (rs_r(2)) begin
                 r = 2 + rs_r(4);
                 if (((r <= 3) && !RS_LINE) || ((r == 4) && (GPU_BLEND_EN == 0)) ||
                     ((r == 5) && !RS_BIL)) w = r;
                 if ((r == 5) && RS_BIL && (GPU_BLEND_EN == 0)) w = 5 + 32'h100;   // TBORDER without blending
              end
              rs_w({OP_SET_EXT, EXT_SET_AUX, w[3:0], 18'h00000, w[8], 1'b0}, 2'd0);
              if (rs_r(2)) rs_w(32'h1234_5678, 2'd1);
           end
        4: e_one({GPU_FILL, 14'h0000, 2'b11, 12'h000});                              // REMAP 3
        5: e_one({OP_SET_EXT, EXT_SET_AUX, rs_r(2) ? 4'd4 : 4'd1, 4'h0, f16($random(rs_seed)) | 16'h0001}); // PITCH != 0
        6: begin                                                                    // reserved SRC_FMT
              // refused, but its operand is parsed as pushed: with IMM it is the
              // data count N and arms the next copy (always planned, and small:
              // a base address or the next command word taken as N would owe
              // thousands to millions of data words)
              rs_mark;
              w = {OP_SET_SRC, 7'h00, f1(rs_r(2)), 4'd6 + (f4(rs_r(10))), 16'h0000};
              rs_w(w, 2'd0);
              r = rs_r(2);
              if (w[20])  rs_w(32'd1 + w[17:16], 2'd1);
              else if (r) rs_w(RS_SRC_LO * g_ppw, 2'd1);
           end
        7: begin                                                                    // SET_DST [19:17]
              rs_mark;
              rs_w({OP_SET_DST, 8'h00, 3'd1 + (f3(rs_r(7))), 1'b0, 16'h0000}, 2'd0);
              if (rs_r(2)) rs_w(RS_DST_LO * g_ppw, 2'd1);
           end
        8: begin                                                                    // EXPAND with SRC_FMT 0
              e_src(16'h0, 4'h0, RS_SRC_LO * g_ppw);
              e_one({OP_EXEC_EXP, 14'h0000, 14'h0000});
           end
        9: begin                                                                    // copy / texture with SRC_FMT 1-4
              e_src(16'h0, 4'd1 + rs_r(4), RS_SRC_LO * g_ppw);
              r = rs_r(3);
              e_one((r == 0) ? {GPU_COPY, 28'h0} : (r == 1) ? {OP_EXEC_TEX, 14'h0, 14'h1} : {OP_EXEC_TEXRECT, 28'h0});
           end
       10: begin                                                                    // an absent feature (opcode 0 when the build has it)
              r = rs_r(11);
              if (!(((r <= 1) && !RS_XY) || ((r == 2) && (GPU_GRAD_EN == 0)) || ((r == 3) && (GPU_BLEND_EN == 0)) ||
                    (((r == 4) || (r == 5)) && !RS_TRI) || ((r == 6) && (GPU_REMAP_EN == 0)) ||
                    ((r == 7) && (GPU_IMM_EN == 0)) || ((r == 8) && (GPU_BLEND_EN == 0)) ||
                    ((r == 9) && !RS_LINE) || ((r == 10) && RS_LINE && (GPU_BLEND_EN == 0))))
                 r = 11;
              case (r)
                0: e_two({OP_SET_DST, 11'h000, 1'b1, 16'h0}, RS_DST_LO * g_ppw);
                1: e_one({OP_SET_EXT, EXT_SET_XY, 24'h000000});
                2: e_one({OP_SET_EXT, EXT_SET_GRAD, 24'h000000});
                3: e_one({OP_SET_EXT, 4'h8, 24'h000000});
                4: e_two({OP_SET_EXT, 4'd9, 24'h0}, 32'h0);
                5: e_one({OP_EXEC_FILL, 14'h0, 2'b00, 4'h0, 1'b1, 7'h00});
                6: e_two({OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h0}, RS_TAB_LO);
                7: e_two({OP_SET_SRC, 7'h00, 1'b1, 4'h0, 16'h0}, 32'h0);
                8: e_one({OP_EXEC_EXP, 20'h00000, 8'h08});                              // MASK
                9: begin                                                                // LINE, or LINE_PEN / LINE_PATTERN
                      r = rs_r(3);
                      e_two((r == 0) ? {OP_EXEC_FILL, 28'h100_0000} : {OP_SET_EXT, EXT_SET_AUX, 4'd1 + f4(r), 20'h0}, 32'h0);
                   end
               10: e_two({OP_EXEC_FILL, 28'h101_0000}, 32'h0);                          // AA without blending
                default: e_one({4'h0, f28($random(rs_seed))});
              endcase
           end
       11: begin                                                                    // CALL past the VRAM
              rs_mark;
              rs_w({OP_CALL, 4'h0, 24'd64 + (f24(rs_r(64)))}, 2'd0);
              rs_w(VRAM_WORDS - 8 - rs_r(32), 2'd1);
           end
       12: begin                                                                    // immediate copy with SRC swaps
              if (GPU_IMM_EN != 0) begin
                 e_size(4, 2);
                 rs_mark;
                 rs_w({OP_SET_SRC, 7'h00, 1'b1, 4'h0, 16'h0}, 2'd0);
                 rs_w(32'd3, 2'd1);
                 rs_mark;
                 rs_w({GPU_COPY, 14'h0, 2'b00, 1'b0, 3'd1 + (f3(rs_r(7))), 1'b0, 3'b000, 4'h0}, 2'd0);
                 rs_w(32'h1111_1111, 2'd2); rs_w(32'h2222_2222, 2'd2); rs_w(32'h3333_3333, 2'd2);
              end else
                 e_one({4'h0, 28'h0});
           end
       13: e_one({OP_SET_EXT, EXT_SET_TEX, 8'h00, 2'b11, 14'h0000});          // SET_TEX REMAP 3
       14: begin                                                                    // RGB565A8 / TEX_FILTER absent, or a copy with MPLANE
              r = rs_r(3);
              if ((GPU_BLEND_EN == 0) && (r == 0))
                 e_two({OP_SET_SRC, 8'h00, 4'd5, 16'h0}, RS_SRC_LO * g_ppw);
              else if ((GPU_BLEND_EN == 0) && (r == 1))
                 e_two({OP_SET_EXT, EXT_SET_AUX, 4'd4, 20'h00000}, RS_A8_LO * 4);
              else if (((GPU_BLEND_EN == 0) || (r == 2)) && (!RS_BIL || (GPU_BLEND_EN == 0)))
                 e_two({OP_SET_EXT, EXT_SET_AUX, 4'd5, 18'h00000, f1(RS_BIL), 1'b1}, 32'h0);   // absent / TBORDER
              else if (GPU_MPLANE_EN != 0) begin
                 e_src(16'd32, 4'd5, RS_SRC_LO * g_ppw);
                 e_one({rs_r(2) ? GPU_COPY : GPU_COPYT, 16'h0000, 1'b1, 11'h000});
              end else
                 e_one({4'h0, 28'h0});
           end
       15: begin                                                                    // an RGB565A8 copy taking the immediate source
              if ((GPU_IMM_EN != 0) && (GPU_BLEND_EN != 0) && !rs_inlist) begin
                 e_size(4, 2);
                 rs_mark;
                 rs_w({OP_SET_SRC, 7'h00, 1'b1, 4'd5, 16'h0}, 2'd0);
                 rs_w(32'd3, 2'd1);
                 g_sfmt = 4'd5;
                 rs_mark;
                 rs_w({GPU_COPY, 28'h0}, 2'd0);
                 rs_w(32'h1111_1111, 2'd2); rs_w(32'h2222_2222, 2'd2); rs_w(32'h3333_3333, 2'd2);
              end else
                 e_one({4'h0, 28'h0});
           end
        default: begin                                                              // ERR_CAUSE 5: a FILL past the VRAM
              e_dst(16'd64, 1'b0, (VRAM_WORDS - 1 - rs_r(3)) * g_ppw + rs_r(g_ppw));
              e_size(rs_rr(1, RS_WMAX), rs_rr(2, RS_HMAX));
              rs_mark;
              rs_w({OP_EXEC_FILL, 20'h00000, 1'b0, 3'b000, f4(rs_r(16))}, 2'd0);
              rs_plan_stop = 1'b1;                   // the faulting rectangle comes last
           end
      endcase
   end
endtask

//----------------------------------------------------------------------------
// Push and settle
//----------------------------------------------------------------------------
integer rs_credit;
reg     rs_hold = 1'b0;                          // the FIFO is held on purpose (dropped push)
reg     rs_abort_run;
reg     rs_last_flushed = 1'b0;
reg     rs_flush_frozen_q = 1'b0;
integer rs_ff_kind;
reg     rs_ff_err;
integer rs_exp_acc;                              // pushes the FIFO must have accepted
reg     rs_in_err;
reg     rs_ovfl;                                 // a push was dropped on purpose (GPU_OVFL expected)

task rs_push;                                    // push one word with FIFO room; logs it
   input [31:0] w;
   output       ok;
   reg   [31:0] st;
   reg    [1:0] k;
   integer      g;
   begin
      ok = !gpu_sm_bad;                          // the stream log is out of step: nothing more pushed
      if (ok && (rs_credit == 0)) begin
         reg_rd_val(GPU_STAT, st);
         rs_credit = st[7:0];
         if ((rs_credit == 0) && dbg_stoptime && !rs_hold) gpu_freeze(1'b0);   // a freeze pulse ends at a full FIFO
         g = 0;
         while ((rs_credit == 0) && !rs_in_err && (g < 4000) && !st[22]) begin
            reg_rd_val(GPU_STAT, st);
            rs_credit = st[7:0];
            g = g + 1;
         end
      end
      if (rs_credit == 0) begin
         ok = 1'b0;                              // stopped with a full FIFO: not pushed
         if (!rs_in_err && !st[22] && !rs_hold) tb_error("rstream: the FIFO did not drain (test bug)");
      end
      else begin
         reg_wr(GPU_CMD, w);
         rs_credit  = rs_credit - 1;
         rs_exp_acc = rs_exp_acc + 1;
         gpu_sm_push(w, k);
`ifdef RS_TRACE
         $display("TRACE: push [%0d] 0x%h kind %0d %t", gpu_sq_n - 1, w, k, $time);
`endif
         if (k == 2'd3) rs_cv_misc[CV_SKIP] = 1'b1;
         if ((k == 2'd2) && (gpu_sq_o[gpu_sq_n - 1] < 0)) rs_cv_misc[CV_DATADROP] = 1'b1;
      end
   end
endtask

task rs_poll_settle;                             // idle, or stopped in ERR with nothing drawing
   output [31:0] st;
   integer       g;
   begin
      g = 0;
      reg_rd_val(GPU_STAT, st);
      while (!((st[21] == 1'b0) || (st[22] && !st[20] && !st[24]) || (st[22] && !st[20] && st[24])) && (g < 100000)) begin
         reg_rd_val(GPU_STAT, st);
         g = g + 1;
      end
      if (g >= 100000) tb_error("GPU did not settle (stream hang)");
   end
endtask

// Run the model up to (qlim, llim), with the record, the byte-enable marks
// and the out-of-VRAM fault on
// rs_model_run posts the run to one process (rs_mr_*): the decoder and drawing
// models are then expanded once, not at every call site (Verilator inlines tasks)
reg     rs_mr_req = 1'b0, rs_mr_ack = 1'b0;
integer rs_mr_q, rs_mr_l;
task rs_model_run;
   input integer qlim;
   input integer llim;
   begin
      rs_mr_q   = qlim;
      rs_mr_l   = llim;
      rs_mr_req = ~rs_mr_req;
      wait (rs_mr_ack === rs_mr_req);
   end
endtask

always begin
   wait (rs_mr_req !== rs_mr_ack);
   rs_model_run_do(rs_mr_q, rs_mr_l);
   rs_mr_ack = rs_mr_req;
end

task rs_model_run_do;
   input integer qlim;
   input integer llim;
   integer       kk;
   begin
      gpu_sr_n  = 0;
      gpu_sr_xn = 0;
      gpu_sr_en = 1'b1;
      gpu_be_mk = 1'b1;
      gpu_oob_ok   = 1'b1;
      gpu_oob_stop = 1'b1;
      gpu_sm_run(qlim, llim);
      gpu_sr_en = 1'b0;
      gpu_be_mk = 1'b0;
      gpu_oob_ok   = 1'b0;
      gpu_oob_stop = 1'b0;
      gpu_oob_hit  = 1'b0;
      rs_cov_execs;
      for (kk = 0; kk < gpu_sr_n; kk = kk + 1)       // the generator keeps every write in its area
         if ((gpu_sr_wa[kk] < RS_DST_LO) || ((gpu_sr_wa[kk] >= RS_DST_HI) && (gpu_sr_wa[kk] < VRAM_WORDS - 4))) begin
            $display("ERROR: rstream -- a model write to word 0x%h, outside the destination area (EXEC %0d of the run, kind %0d) (test bug) %t",
                     gpu_sr_wa[kk], gpu_sr_ex[kk], gpu_sm_xk[gpu_sr_ex[kk] & 255], $time);
            error = error + 1;
            kk = gpu_sr_n;
         end
   end
endtask

task rs_cov_execs;
   integer kk, ff, kd;
   begin
      for (kk = 0; (kk < gpu_sr_xn) && (kk < 256); kk = kk + 1) begin
         kd = gpu_sm_xk[kk];
         rs_cv_kd[kd * 5 + ((gpu_bl(gpu_m_mode) == 4) ? 4 : gpu_bl(gpu_m_mode))] = 1'b1;
         for (ff = 0; ff < 8; ff = ff + 1)
            if (gpu_sm_xf[kk][ff]) rs_cv_kf[kd * 8 + ff] = 1'b1;
         if (gpu_sm_xa[kk][0] && ((kd == 1) || (kd == 2)))            rs_cv_misc[CV_A8_COPY] = 1'b1;
         if (gpu_sm_xa[kk][0] && ((kd == 5) || (kd == 6) || (kd == 8))) rs_cv_misc[CV_A8_TEX] = 1'b1;
         if (gpu_sm_xa[kk][1]) rs_cv_misc[CV_MIX5] = 1'b1;
         if (gpu_sm_xa[kk][2]) rs_cv_misc[CV_BIL] = 1'b1;
         if (gpu_sm_xa[kk][2] && gpu_sm_xa[kk][0]) rs_cv_misc[CV_BIL_A8] = 1'b1;
         if (gpu_sm_xa[kk][3]) rs_cv_misc[CV_BIL_TBORDER] = 1'b1;
         if (gpu_sm_xa[kk][4]) rs_cv_misc[CV_BIL_CLAMP] = 1'b1;
         if (gpu_sm_xa[kk][5]) rs_cv_misc[CV_BIL_WRAP] = 1'b1;
      end
   end
endtask

// Check the byte enables of the GPU writes logged since the last check
task rs_be_check;
   integer kk, nb;
   begin
      nb = 0;
      for (kk = 0; (kk < rs_bew_n) && (kk < RS_BEW_MAX); kk = kk + 1)
         if ((rs_bew_a[kk] < GPU_BE_WORDS) && ((rs_bew_e[kk] & ~gpu_be_ok[rs_bew_a[kk]]) != 4'h0)) begin
            nb = nb + 1;
            if (nb <= 4)
               $display("ERROR: GPU write to word 0x%h enables bytes %b, only %b hold visited pixels %t",
                        rs_bew_a[kk], rs_bew_e[kk], gpu_be_ok[rs_bew_a[kk]], $time);
         end
      error = error + nb;
      tb_checks = tb_checks + 1;
      rs_bew_n = 0;
      for (kk = RS_DST_LO; kk < GPU_BE_WORDS; kk = kk + 1) gpu_be_ok[kk] = 4'h0;
   end
endtask

// Settle at an idle or ERR point: model up to the GPU's position, then every check
task rs_settle;
   input [8*24-1:0] where;
   reg    [31:0] st, gl, rd, fl, exp;
   integer       qlim, llim, n, ww, nbad;
   begin
      rs_poll_settle(st);
      reg_rd_val(GPU_STAT, st);
      reg_rd_val(GPU_LIST, gl);
      qlim = gpu_sq_n - st[15:8] - ((`RS_G.mrk_pend === 1'b1) ? 1 : 0);   // a pending marker: not in USED
      llim = st[24] ? gl : -1;
`ifdef RS_TRACE
      $display("TRACE: settle %0s stat 0x%h list 0x%h qlim %0d llim %0d model q %0d st %0d %t", where, st, gl, qlim, llim, gpu_sm_q, gpu_sm_st, $time);
`endif
      rs_model_run(qlim, llim);
      if (st[22] && (gpu_sm_st != GPU_SM_ERR) && !gpu_sm_bad) begin
         // stopped on a refused word, still at the head: the model must refuse it
         gpu_sm_nochk = 1'b1;
         rs_model_run(st[24] ? qlim : qlim + 1, st[24] ? gl + 1 : -1);
         gpu_sm_nochk = 1'b0;
      end
      if (gpu_sm_oob) begin                       // ERR_CAUSE 5: the faulting rectangle drew a prefix
         gpu_sr_cut(1'b0, n);
         if (n < 0) tb_error("ERR_CAUSE 5 rectangle: the VRAM is not a prefix of its walk");
         gpu_sm_oob  = 1'b0;
         gpu_sm_oobr = 1'b0;
         rs_dc_cut   = 1'b0;
      end
      if (rs_dc_cut) begin                        // a DISCARD abandoned an immediate rectangle: a prefix
         gpu_sr_cut(1'b0, n);
         if (n < 0) tb_error("rstream: after a DISCARD that cut immediate data the VRAM is not a prefix");
         else if (n < gpu_sr_n) rs_n_dcab = rs_n_dcab + 1;
         rs_dc_cut = 1'b0;
      end
      rs_be_check;
      // registers
      tb_checks = tb_checks + 1;
      if ((st[31:28] !== gpu_sm_eop) || (st[27:25] !== gpu_sm_ecause) || (st[24] !== gpu_sm_lact) ||
          (st[22] !== (gpu_sm_st == GPU_SM_ERR)) ||
          (st[21] !== ((gpu_sm_st == GPU_SM_ERR) && ((gpu_sm_q < gpu_sq_n) || gpu_sm_lact)))) begin
         $display("ERROR: rstream %0s -- GPU_STAT 0x%h: ERR_OPCODE %0d ERR_CAUSE %0d LIST %0d ERR %0d BUSY %0d, model %0d %0d %0d %0d %0d (seed %0d segment %0d) %t",
                  where, st, st[31:28], st[27:25], st[24], st[22], st[21], gpu_sm_eop, gpu_sm_ecause, gpu_sm_lact,
                  gpu_sm_st == GPU_SM_ERR, gpu_sm_st == GPU_SM_ERR, rs_si, rs_seg, $time);
         error = error + 1;
      end
      reg_rd_val(GPU_ERR, rd);
      tb_checks = tb_checks + 1;
      if (rd !== gpu_sm_eword) begin
         $display("ERROR: rstream %0s -- GPU_ERR 0x%h, model 0x%h (seed %0d segment %0d) %t", where, rd, gpu_sm_eword,
                  rs_si, rs_seg, $time);
         error = error + 1;
      end
      reg_rd_val(GPU_FENCE, rd);
      tb_checks = tb_checks + 1;
      if (rd[23:0] !== gpu_sm_fence) begin
         $display("ERROR: rstream %0s -- GPU_FENCE 0x%h, model 0x%h (seed %0d segment %0d) %t", where, rd, gpu_sm_fence,
                  rs_si, rs_seg, $time);
         error = error + 1;
      end
      exp = (gpu_sm_st == GPU_SM_ERR) ? gpu_sm_elist : 0;
      if (gpu_sm_lact && (gpu_sm_st != GPU_SM_ERR)) exp = gpu_sm_lptr;
      tb_checks = tb_checks + 1;
      if (gl !== exp) begin
         $display("ERROR: rstream %0s -- GPU_LIST 0x%h, model 0x%h (seed %0d segment %0d) %t", where, gl, exp, rs_si, rs_seg, $time);
         error = error + 1;
      end
      // the FIFO words accepted
      tb_checks = tb_checks + 1;
      if (rs_acc != rs_exp_acc) begin
         $display("ERROR: rstream %0s -- the FIFO accepted %0d words, %0d expected (seed %0d segment %0d) %t", where, rs_acc,
                  rs_exp_acc, rs_si, rs_seg, $time);
         error = error + 1;
         rs_exp_acc = rs_acc;
      end
      // interrupt flags
      reg_rd_val(IRQ_FLAG, fl);
      tb_checks = tb_checks + 1;
      if ((fl[6] !== rs_ovfl) || (fl[7] !== gpu_sm_eirq) || (fl[9] !== gpu_sm_firq)) begin
         $display("ERROR: rstream %0s -- IRQ_FLAG GPU_OVFL %0d GPU_ERR %0d GPU_FENCE %0d, expected %0d %0d %0d (seed %0d segment %0d) %t",
                  where, fl[6], fl[7], fl[9], rs_ovfl, gpu_sm_eirq, gpu_sm_firq, rs_si, rs_seg, $time);
         error = error + 1;
      end
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      rs_ovfl = 1'b0; gpu_sm_eirq = 1'b0; gpu_sm_firq = 1'b0; gpu_sm_dirq = 1'b0;
      // the whole VRAM
      nbad = 0;
      tb_checks = tb_checks + 1;
      for (ww = 0; ww < VRAM_WORDS; ww = ww + 1)
         if (vram_mem[ww] !== gpu_shadow[ww]) begin
            nbad = nbad + 1;
            if (nbad <= 6)
               $display("ERROR: rstream %0s -- word 0x%h = 0x%h / model 0x%h (seed %0d segment %0d) %t", where, ww,
                        vram_mem[ww], gpu_shadow[ww], rs_si, rs_seg, $time);
`ifdef RS_TRACE
            for (n = 0; n < gpu_sr_n; n = n + 1)
               if (gpu_sr_wa[n] == ww)
                  $display("TRACE:   write %0d by EXEC %0d (kind %0d, features %b): 0x%h -> 0x%h", n, gpu_sr_ex[n],
                           gpu_sm_xk[gpu_sr_ex[n] & 255], gpu_sm_xf[gpu_sr_ex[n] & 255], gpu_sr_old[n], gpu_sr_new[n]);
`endif
            gpu_shadow[ww] = vram_mem[ww];              // resynchronise: one report per difference
         end
      error = error + nbad;
      if ((gpu_sm_st != GPU_SM_ERR) && (gpu_sm_q == gpu_sq_n) && !gpu_pp_owe && (gpu_pp_act == 0)) begin
         gpu_sq_n = 0;
         gpu_sm_q = 0;
      end
      rs_in_err = (st[22] === 1'b1);
      if (gpu_sm_bad) begin
         $display("ERROR: rstream -- the stream model is out of step: test stopped (seed %0d segment %0d) %t", rs_si, rs_seg, $time);
         rs_abort_run = 1'b1;
      end
   end
endtask


// A flush of kind k (0 CLEAR_ERR, 1 ABORT, 2 GPU_EN 0 -> 1, 3 both bits);
// with rs_fl_disc (kinds 0, 1, 3) DISCARD in the same write
reg rs_fl_disc = 1'b0;
task rs_flush;
   input integer k;
   reg    [31:0] st, dbit;
   integer       fc, qlim, llim, n, lk, g;
   reg           busy, inerr, dmrk, dcut;
   begin
      fc    = rs_fl_cnt;
      dbit  = (rs_fl_disc && (k != 2)) ? 32'h4 : 32'h0;
      case (k)
        0:       reg_wr(GPU_CTRL, 32'h1 | dbit);
        1:       reg_wr(GPU_CTRL, 32'h2 | dbit);
        3:       reg_wr(GPU_CTRL, 32'h3 | dbit);
        default: begin
                    reg_wr(CTRL, {29'h0, gpu_m_mode});
                    reg_wr(CTRL, 32'h10 | gpu_m_mode);
                 end
      endcase
      if (rs_fl_cnt == fc) tb_error("rstream: the flush was not seen by the probe");
      inerr = rs_fl_stat[22];                      // in ERR at the flush (as a read in that cycle)
      rs_n_fl = rs_n_fl + 1;
      if (inerr && (k == 1)) rs_cv_misc[CV_ABORT_ERR] = 1'b1;
      if (rs_fl_stat[24]) rs_cv_misc[CV_LISTCUT] = 1'b1;
      if (rs_fl_stat[23] || dbg_stoptime) rs_cv_misc[CV_FRZFL] = 1'b1;
      if (rs_fl_stat[18]) rs_cv_misc[CV_WAITFL] = 1'b1;
      if (gpu_pp_owe) rs_cv_misc[CV_CUTQ] = 1'b1;
      if (gpu_pp_act > 0) rs_cv_misc[CV_IMMCUT] = 1'b1;
      busy  = rs_fl_stat[20];
      // the GPU winds down (an ABORT at once, a CLEAR_ERR completes its rectangle)
      g = 0;
      reg_rd_val(GPU_STAT, st);
      while ((st[20] || !st[16]) && (g < 100000) && !dbg_stoptime) begin
         reg_rd_val(GPU_STAT, st);
         g = g + 1;
      end
      if (!dbg_stoptime && (g >= 100000)) tb_error("rstream: the GPU did not stop after a flush");
      qlim = gpu_sq_n - rs_fl_stat[15:8] - rs_fl_pend;     // a pending marker: not in USED
      llim = rs_fl_stat[24] ? rs_fl_list : -1;
`ifdef RS_TRACE
      $display("TRACE: flush %0d stat 0x%h list 0x%h qlim %0d llim %0d inerr %0d %t", k, rs_fl_stat, rs_fl_list, qlim, llim, inerr, $time);
`endif
      if (!dbg_stoptime) begin
         gpu_sm_iadj    = rs_fl_ipop;
         gpu_sm_oobhold = 1'b1;
         rs_model_run(qlim, llim);
         gpu_sm_oobhold = 1'b0;
         gpu_sm_iadj    = 0;
         if (gpu_sm_oob && !inerr) begin            // abandoned before its access past the VRAM
            gpu_sm_oob = 1'b0;
            gpu_sm_eword = gpu_sm_lastx;
         end else
            gpu_sm_oob_fin;
         if (inerr && (gpu_sm_st != GPU_SM_ERR) && !gpu_sm_bad) begin   // stopped on the word at the head
            gpu_sm_nochk = 1'b1;
            rs_model_run(rs_fl_stat[24] ? qlim : qlim + 1, rs_fl_stat[24] ? rs_fl_list + 1 : -1);
            gpu_sm_nochk = 1'b0;
            if (gpu_sm_st != GPU_SM_ERR) tb_error("rstream: the GPU was in ERR at a flush, the model not");
         end
         lk = GPU_SM_NK;
         if (busy && (gpu_sr_xn > 0)) lk = gpu_sm_xk[(gpu_sr_xn - 1) & 255];
         rs_cv_fk[k * (GPU_SM_NK + 1) + lk] = 1'b1;
         if (busy && (gpu_sr_xn > 0) && gpu_sm_xa[(gpu_sr_xn - 1) & 255][2]) begin
            if (k == 1)                rs_cv_misc[CV_FL_ABORT_BIL] = 1'b1;
            if ((k == 0) || (k == 3))  rs_cv_misc[CV_FL_CLR_BIL]   = 1'b1;
         end
         if (gpu_sm_st == GPU_SM_OPND) rs_cv_cut[gpu_sm_cw[31:28]] = 1'b1;
         if (gpu_sr_n > 0) begin
`ifdef RS_TRACE
            for (n = 0; n < gpu_sr_n; n = n + 1)
               $display("TRACE:   rec %0d ex %0d kind %0d word 0x%h old 0x%h new 0x%h vram 0x%h", n, gpu_sr_ex[n],
                        gpu_sm_xk[gpu_sr_ex[n] & 255], gpu_sr_wa[n], gpu_sr_old[n], gpu_sr_new[n], vram_mem[gpu_sr_wa[n]]);
`endif
            gpu_sr_cut((k == 0) && !inerr, n);
            if (n < 0) begin
               $display("ERROR: rstream -- after flush kind %0d the VRAM is not a prefix of the %0d model writes (seed %0d segment %0d) %t",
                        k, gpu_sr_n, rs_si, rs_seg, $time);
               error = error + 1;
            end else if (n < gpu_sr_n) begin
               rs_n_prefix = rs_n_prefix + 1;
               rs_cv_misc[CV_PREFIX] = 1'b1;
            end else
               rs_n_whole = rs_n_whole + 1;
         end
         gpu_sm_flush(k);
      end else begin
         rs_flush_frozen_q = 1'b1;
         rs_ff_err         = inerr;
      end
      gpu_sm_pflush(k, inerr);
      if (dbit != 32'h0) begin                     // the push side then resynchronised, no marker
         rs_cv_misc[CV_DC_FLUSH] = 1'b1;
         gpu_sm_discard(1'b1, inerr, dmrk, dcut);
         if (rs_dc_mrk) tb_error("rstream: a marker queued with a flush in the same write");
      end
      rs_in_err = inerr && (k == 1);
      rs_credit = 0;
   end
endtask

// DISCARD alone: the model's parser resynchronises; a marker is logged at the
// cut when the stream was partial and the GPU not in ERR (the GPU's own
// decision, probed, must agree). A cut immediate rectangle is abandoned: the
// next settle takes a prefix of the record.
task rs_discard;
   integer dc;
   reg     mrk, cut, inerr;
   begin
      dc = rs_dc_cnt;
      if (!gpu_pp_owe && (gpu_pp_act == 0) && !gpu_pp_arm) rs_cv_misc[CV_DC_NOP]  = 1'b1;
      if (gpu_pp_owe)                                   rs_cv_misc[CV_DC_OPND] = 1'b1;
      if (gpu_pp_owe && gpu_pp_skip)                    rs_cv_misc[CV_DC_SKIP] = 1'b1;
      if (gpu_pp_act > 0)                               rs_cv_misc[CV_DC_DATA] = 1'b1;
      if (gpu_pp_arm)                                   rs_cv_misc[CV_DC_ARM]  = 1'b1;
      reg_wr(GPU_CTRL, 32'h4);
      gpu_flush_hint = 1'b0;                       // SET_SRC kept: nothing to re-send
      if (rs_dc_cnt == dc) tb_error("rstream: the DISCARD was not seen by the probe");
      inerr = rs_dc_stat[22];
      if (inerr) rs_cv_misc[CV_DC_ERR] = 1'b1;
      gpu_sm_discard(1'b0, inerr, mrk, cut);
      if (mrk !== rs_dc_mrk) begin
         $display("ERROR: rstream -- DISCARD: the GPU %0s a marker, the model %0s (seed %0d segment %0d) %t",
                  rs_dc_mrk ? "queued" : "did not queue", mrk ? "does" : "does not", rs_si, rs_seg, $time);
         error = error + 1;
      end
`ifdef RS_TRACE
      $display("TRACE: discard marker %0d cut %0d in ERR %0d (log %0d) %t", mrk, cut, inerr, gpu_sq_n, $time);
`endif
      rs_n_dc   = rs_n_dc + 1;
      rs_n_dcm  = rs_n_dcm + mrk;
      rs_dc_cut = rs_dc_cut | cut;
      rs_credit = 0;                               // the marker takes a word
   end
endtask

// GPU_FIFO_LOW written now and then (the event: gpu_inv_check)
task rs_flow_wr;
   reg [31:0] v;
   begin
      case (rs_r(6))
        0:       v = GPU_FIFO_DEPTH / 2;
        1:       v = GPU_FIFO_DEPTH + rs_r(4);
        2:       v = $random(rs_seed);
        default: v = rs_r(GPU_FIFO_DEPTH);
      endcase
      reg_wr(GPU_FIFO_LOW, v);
      rs_cv_misc[CV_FLOW_WR] = 1'b1;
   end
endtask

// A flush while frozen: the model runs once the GPU is released (the latched position holds)
task rs_flush_frozen_done;
   integer qlim, llim, n;
   reg [31:0] st;
   integer g;
   begin
      if (rs_flush_frozen_q) begin
         g = 0;
         reg_rd_val(GPU_STAT, st);
         while ((st[20] || !st[16]) && (g < 100000)) begin reg_rd_val(GPU_STAT, st); g = g + 1; end
         qlim = gpu_sq_n - rs_fl_stat[15:8] - rs_fl_pend;
         llim = rs_fl_stat[24] ? rs_fl_list : -1;
         gpu_sm_iadj = rs_fl_ipop;
         rs_model_run(qlim, llim);
         gpu_sm_iadj = 0;
         if (rs_ff_err && (gpu_sm_st != GPU_SM_ERR) && !gpu_sm_bad) begin
            gpu_sm_nochk = 1'b1;
            rs_model_run(rs_fl_stat[24] ? qlim : qlim + 1, rs_fl_stat[24] ? rs_fl_list + 1 : -1);
            gpu_sm_nochk = 1'b0;
         end
         if (gpu_sr_n > 0) begin
            gpu_sr_cut((rs_ff_kind == 0) && !rs_ff_err, n);
            if (n < 0) tb_error("rstream: after a flush while frozen the VRAM is not a prefix");
         end
         gpu_sm_flush(rs_ff_kind);
         rs_flush_frozen_q = 1'b0;
      end
   end
endtask

// After a flush: push the rest of the cut command (its operand, the
// immediate data still owed), as an interrupted pusher would; stop at the
// next command
task rs_continue;
   input integer from;
   integer       i;
   reg           ok;
   begin
      i  = from;
      ok = 1'b1;
      while ((i < rs_np) && ok && (((rs_pr[i] == 2'd1) && gpu_pp_owe) || ((rs_pr[i] == 2'd2) && (gpu_pp_act > 0)))) begin
         rs_push(rs_pw[i], ok);
         i = i + 1;
      end
   end
endtask

// The immediate data words the pushed stream still owes, pushed (the GPU drops
// them). More than a planned rectangle takes (a SET_SRC IMM whose N is a
// misread word) are dropped with GPU_EN = 0 -> 1 instead, as a driver would
// (gpu_commands.md, immediate source): the stream log stays bounded
localparam integer RS_OWE_MAX = RS_PW_MAX;
task rs_owed_data;
   output ok;
   begin
      ok = 1'b1;
      if (gpu_pp_act > RS_OWE_MAX) rs_flush(2);
      while ((gpu_pp_act > 0) && ok) rs_push($random(rs_seed), ok);
   end
endtask

//----------------------------------------------------------------------------
// One segment
//----------------------------------------------------------------------------
integer rs_inj, rs_at, rs_dl;
task rs_segment;
   integer i, k, r, nprim, rk;
   reg     ok, frz, bare, done, imm_arm, dfrz;
   reg [31:0] st;
   begin
      // the immediate data still owed by the pushed stream are pushed first (dropped)
      if ((gpu_pp_act > 0) || gpu_pp_owe) begin
         rs_owed_data(ok);
         if (gpu_pp_owe && ok) rs_push($random(rs_seed), ok);   // a cut command's operand (discarded)
         rs_settle("owed words");
      end
      // idle here: new depth / display width now and then
      if ((rs_seg == 0) || (rs_r(6) == 0)) begin
         gpu_set_mode(rs_r(8));
         if (rs_r(2)) gpu_set_dispw(rs_rr(48, 400));
      end
      rs_g_load;
      rs_np = 0; rs_nl = 0; rs_nb = 0;
      // the canvas: kept while the GPU's destination still matches it
      if (!((cv_pf == 16'h0) ? (cv_p == gpu_m_dispw) : 1'b1) || (rs_r(4) == 0) || (rs_seg == 0) || (cv_w == 0)) begin
         cv_w  = rs_rr(16, 96);
         cv_h  = rs_rr(12, 40);
         // pitch 0 (the display width) only when the display width can hold the canvas
         if ((rs_r(3) == 0) && (cv_w + 2 * RS_M <= RS_DWMAX)) begin
            cv_pf = 16'h0;
            if (gpu_m_dispw < cv_w + 2 * RS_M)
               gpu_set_dispw(cv_w + 2 * RS_M + rs_r((RS_DWMAX - cv_w - 2 * RS_M < 63) ? RS_DWMAX - cv_w - 2 * RS_M + 1 : 64));
            cv_p  = gpu_m_dispw;
         end else begin
            cv_p  = cv_w + 2 * RS_M + rs_r(80);
            cv_pf = cv_p;
         end
      end
      if ((cv_h + 2 * RS_M) * cv_p / g_ppw + 64 > RS_DST_HI - RS_DST_LO) cv_h = 8;
      cv_o = RS_DST_LO * g_ppw + rs_r(g_ppw) + RS_M * cv_p + RS_M +
             rs_r(((RS_DST_HI - RS_DST_LO) * g_ppw - (cv_h + 2 * RS_M + 2) * cv_p) > 1 ?
                  ((RS_DST_HI - RS_DST_LO) * g_ppw - (cv_h + 2 * RS_M + 2) * cv_p) : 1);
      // the placement above reserves rows of cv_p pixels: the canvas must fit a row
      if (cv_p < cv_w + 2 * RS_M) tb_error("gpu_rstream: canvas wider than its pitch (generator)");
      rs_rsvon = rs_r(4) == 0;
      // a bare EXEC first, on the kept settings, when they are still legal
      bare = 1'b0;
      if ((rs_seg > 0) && rs_last_flushed && (rs_r(2) == 0)) rs_try_bare(bare);
      // the injection
      r = rs_r(100);
      rs_inj = (r < 42) ? 0 : (r < 50) ? 6 : (r < 72) ? 1 : (r < 86) ? 2 : (r < 91) ? 3 : (r < 96) ? 4 : 5;
      if (rs_r(8) == 0) rs_flow_wr;
      // a list now and then (no immediate data in a list)
      rs_inlist = (rs_r(4) == 0);
      if (rs_inlist) rs_n_list = rs_n_list + 1;
      nprim = rs_rr(1, 6);
      rs_plan_stop = 1'b0;
      for (k = 0; (k < nprim) && !rs_plan_stop; k = k + 1) begin
         if ((rs_inj == 2) && (k == nprim / 2) && (rs_r(2) == 0)) rs_plan_bad;
         if (!rs_plan_stop) rs_plan_one;
      end
      if ((rs_inj == 2) && !rs_plan_stop && (rs_r(2) == 0)) rs_plan_bad;
      if (rs_inlist) begin
         // a list's last word cut (ERR_CAUSE 4), a CALL in it, now and then with an error
         if ((rs_inj == 2) && (rs_r(2) == 0)) begin
            k = rs_r(3);
            if (k == 0)                  begin rs_mark; rs_w({OP_SET_FILL, 28'h0}, 2'd0); end
            else if ((k == 1) && RS_LINE) begin rs_mark; rs_w({OP_EXEC_FILL, 28'h100_0000}, 2'd0); end   // a LINE cut
            else                         begin rs_mark; rs_w({OP_CALL, 4'h0, 24'd1}, 2'd0); rs_w(RS_LIST_LO, 2'd1); end
         end
         if (rs_nl > RS_LIST_HI - RS_LIST_LO) rs_nl = RS_LIST_HI - RS_LIST_LO;
         for (i = 0; i < rs_nl; i = i + 1) begin
            vram_wr(4 * (RS_LIST_LO + i), rs_lw[i], SZ_W);
            gpu_shadow[RS_LIST_LO + i] = rs_lw[i];
         end
         rs_inlist = 1'b0;
         rs_np = 0;
         rs_w(({OP_CALL, 4'h0, rs_nl[23:0]} | rs_rsv(32'h0F00_0000)), 2'd0);
         rs_w(RS_LIST_LO | (rs_rsv(32'hFFFF_FFFF) & ~((32'h1 << VRAM_AW) - 32'h1)), 2'd1);
         if (rs_r(3) == 0) begin rs_w({OP_FENCE, 2'b00, 1'b1, 1'b0, 24'h0}, 2'd0); end
      end
      // WAIT_REFR_DONE before a flush
      if ((rs_inj == 5) && (rs_np < RS_PW_MAX - 1)) begin
         rs_pw[rs_np] = ({OP_SET_EXT, EXT_SET_EXT2, X2_WAIT_REFR, 16'h0000} | rs_rsv(32'h0000_FFFF));
         rs_pr[rs_np] = 2'd0;
         rs_np = rs_np + 1;
         for (k = 0; k < 2; k = k + 1) begin rs_pw[rs_np] = {OP_SET_SIZE, 28'h0004004}; rs_pr[rs_np] = 2'd0; rs_np = rs_np + 1; end
      end
      rs_at = rs_r(rs_np + 1) - 1;               // -1: before the first word
      if ((rs_inj == 1) && rs_r(2)) begin        // cut a command between word and operand
         for (i = 0; i < rs_np - 1; i = i + 1)
            if ((rs_pr[i] == 2'd0) && (rs_pr[i + 1] != 2'd0) && (rs_r(3) == 0)) rs_at = i;
      end
      if (rs_inj == 5) rs_at = rs_np - 1;
      if ((rs_inj == 6) && (rs_r(4) != 0)) begin  // DISCARD: cut a command, immediate data, or after N
         k = rs_r(3);
         for (i = 0; i < rs_np - 1; i = i + 1)
            if (((k == 0) && (rs_pr[i] == 2'd0) && (rs_pr[i + 1] != 2'd0)) ||
                ((k == 1) && (rs_pr[i] == 2'd2) && (rs_pr[i + 1] == 2'd2)) ||
                ((k == 2) && (i > 0) && (rs_pw[i - 1][31:28] == OP_SET_SRC) && rs_pw[i - 1][20] && (rs_r(3) == 0)) ||
                (rs_r(6) == 0))
               if (rs_r(2) == 0) rs_at = i;
      end
      rs_dl = (rs_r(3) == 0) ? rs_r(400) : rs_r(40);
      if (rs_inj == 3) rs_at = rs_r(rs_np);
`ifdef RS_TRACE
      $display("TRACE: segment %0d inj %0d at %0d delay %0d words %0d list %0d %t", rs_seg, rs_inj, rs_at, rs_dl, rs_np, rs_nl, $time);
`endif
      // push
      frz = 1'b0;
      done = 1'b0;
      if ((rs_inj == 1 || rs_inj == 5) && (rs_at < 0)) begin
         rs_flush(rs_r(4));
         done = 1'b1;
      end
      if ((rs_inj == 6) && (rs_at < 0)) begin
         rs_discard;
         done = 1'b1;
      end
      // DISCARD with the FIFO full: the GPU held while the segment fills it,
      // the DISCARD where the next word finds no room (its marker pending when
      // the stream is partial there)
      dfrz = (rs_inj == 6) && !done && (rs_r(3) == 0);
      if (dfrz) begin
         gpu_freeze(1'b1);
         rs_hold = 1'b1;
         rs_at   = rs_np;
      end
      for (i = 0; (i < rs_np) && !done; i = i + 1) begin
         if ((rs_inj == 3) && (i == rs_at)) begin
            rs_drop(i);
            done = 1'b1;
         end else begin
            rs_push(rs_pw[i], ok);
            if (!ok) done = 1'b1;
            if (!ok && dfrz && !gpu_sm_bad) rs_discard;
            if ((rs_inj == 4) && (i == rs_at) && !frz) begin
               gpu_freeze(1'b1);
               frz = 1'b1;
               rs_cv_misc[CV_FREEZE] = 1'b1;
               rs_n_frz = rs_n_frz + 1;
            end
            if (frz && (rs_r(6) == 0)) begin
               repeat (rs_r(30)) @(posedge free_clk);
               gpu_freeze(1'b0);
               frz = 1'b0;
            end
            if (((rs_inj == 1) || (rs_inj == 5)) && (i == rs_at)) begin
               repeat (rs_dl) @(posedge free_clk);
               rs_flush(rs_r(4));
               if (rs_r(4) == 0) rs_discard;       // the rest of the cut command not pushed
               else              rs_continue(i + 1);
               done = 1'b1;
            end
            if ((rs_inj == 6) && (i == rs_at)) begin
               // DISCARD (alone, or in a flush's write): the rest of the cut command
               // is not pushed, the segment ends there
               repeat (rs_dl) @(posedge free_clk);
               if (rs_r(4) == 0) begin
                  rs_fl_disc = 1'b1;
                  k = rs_r(3);
                  rs_flush((k == 2) ? 3 : k);
                  rs_fl_disc = 1'b0;
               end else
                  rs_discard;
               done = 1'b1;
            end
            if (rs_r(64) == 0) rs_flow_wr;
         end
      end
      if (dfrz) begin
         if (!done) rs_discard;                    // the segment fitted: not partial
         rs_hold = 1'b0;
         repeat (rs_r(8)) @(posedge free_clk);
         gpu_freeze(1'b0);
      end
      if (frz) begin
         repeat (rs_r(60)) @(posedge free_clk);
         if (rs_r(4) == 0) begin                  // a flush while held
            rs_ff_kind = rs_r(4);
            rs_flush(rs_ff_kind);
         end
         gpu_freeze(1'b0);
         rs_flush_frozen_done;
      end
      if ((rs_inj == 1) && !done) begin
         repeat (rs_dl) @(posedge free_clk);
         rs_flush(rs_r(4));
      end
      rs_last_flushed = (rs_inj == 1) || (rs_inj == 3) || (rs_inj == 5) || (rs_inj == 4) || (rs_inj == 6);
      rs_settle("segment");
      // an error: check the record (rs_settle did), then recover
      if (rs_in_err && !rs_abort_run) begin
         rs_n_err = rs_n_err + 1;
         rs_cv_ec[gpu_sm_ecause * 3 + ((gpu_sm_elist != 0) ? 1 : (GPU_RUNAHEAD_EN != 0) ? 2 : 0)] = 1'b1;
         if (gpu_sm_ecause == 3'd4) rs_cv_ec[4 * 3 + 1] = 1'b1;
         if ((gpu_sm_ecause == 3'd2) && (((gpu_sm_eword[31:28] == OP_SET_SRC) && (gpu_sm_eword[19:16] == 4'd5)) ||
                                         ((gpu_sm_eword[31:24] == {OP_SET_EXT, EXT_SET_AUX}) &&
                                          (gpu_sm_eword[23:20] == 4'd4))))
            rs_cv_misc[CV_ERR_C2_A8] = 1'b1;
         if ((gpu_sm_ecause == 3'd2) && (gpu_sm_eword[31:24] == {OP_SET_EXT, EXT_SET_AUX}) && (gpu_sm_eword[23:20] == 4'd5))
            rs_cv_misc[CV_ERR_C2_BIL] = 1'b1;
         if ((gpu_sm_ecause == 3'd1) && ((gpu_sm_eword[31:28] == GPU_COPY) || (gpu_sm_eword[31:28] == GPU_COPYT)) &&
             (gpu_m_src_fmt == 4'd5)) begin
            if (gpu_sm_eword[11]) rs_cv_misc[CV_ERR_C1_A8_MPL] = 1'b1;
            else                  rs_cv_misc[CV_ERR_C1_A8_IMM] = 1'b1;
         end
         if ((gpu_sm_eword[31:28] == GPU_FILL) && gpu_sm_eword[24]) begin
            if (gpu_sm_ecause == 3'd2) rs_cv_misc[CV_LERR2] = 1'b1;
            if (gpu_sm_ecause == 3'd4) rs_cv_misc[CV_LERR4] = 1'b1;
         end
         rk = rs_r(6);
         case (rk)
           0: rs_flush(0);
           1: rs_flush(3);
           2: rs_flush(2);
           5: begin                                // DISCARD in ERR (no marker), then a recover with it
                 rs_discard;
                 rs_fl_disc = 1'b1;
                 rs_flush(rs_r(2) ? 3 : 0);
                 rs_fl_disc = 1'b0;
              end
           default: begin
                       // in ERR: the immediate source armed before an ABORT stays armed until
                       // the CLEAR_ERR (the stream bookkeeping waits for it): the copy pushed
                       // between them takes the data words that follow
                       imm_arm = (GPU_IMM_EN != 0) && !gpu_pp_owe && (gpu_pp_act == 0) && rs_r(2);
                       if (imm_arm) begin
                          rs_push({OP_SET_SRC, 7'h00, 1'b1, 4'h0, 16'h0000}, ok);
                          if (ok) rs_push(32'd1 + rs_r(4), ok);
                          imm_arm = ok;
                       end
                       rs_flush(1);
                       if (imm_arm) begin
                          rs_push({GPU_COPY, 28'h0}, ok);
                          rs_cv_misc[CV_ABORT_ERR] = 1'b1;
                          for (i = 0; i < rs_r(3); i = i + 1) if (ok && (gpu_pp_act > 0)) rs_push($random(rs_seed), ok);
                       end else
                          for (i = 0; i < rs_r(3); i = i + 1)
                             rs_push({OP_SET_SIZE, 4'h0, 10'd2, 4'h0, 10'd3}, ok);
                       rs_flush(0);
                    end
         endcase
         // the operand of the refused word, if it is still owed (discarded)
         if (gpu_pp_owe && rs_r(2)) rs_push(32'h0000_0000, ok);
         rs_owed_data(ok);                                        // the data still owed (dropped)
         rs_last_flushed = 1'b1;
         rs_settle("after recovery");
      end
   end
endtask



// A bare EXEC on the settings the GPU kept (nothing re-sent): only when they
// keep every pixel inside the destination area and the source in its area
task rs_try_bare;
   output       ok;
   reg   [31:0] a;
   integer      dp, sp, kk, ww, hh;
   begin
      ok = 1'b0;
      if (!gpu_m_xy && (gpu_m_src_fmt == 4'h0) && !gpu_m_gen && !gpu_m_aen) begin
         dp = (gpu_m_dst_pitch == 16'h0) ? gpu_m_dispw : gpu_m_dst_pitch;
         sp = (gpu_m_src_pitch == 16'h0) ? gpu_m_dispw : gpu_m_src_pitch;
         ww = gpu_m_w; hh = gpu_m_h;
         ok = 1'b1;
         for (kk = 0; kk < 4; kk = kk + 1) begin
            a = gpu_walk(gpu_m_dst_base, dp, 3'b000, ww, (kk[0] ? ww - 1 : 0) + (kk[1] ? (hh - 1) * ww : 0));
            if ((gpu_word_of(a, g_bl) < RS_DST_LO) || (gpu_word_of(a, g_bl) >= RS_DST_HI)) ok = 1'b0;
            a = gpu_walk(gpu_m_src_base, sp, 3'b000, ww, (kk[0] ? ww - 1 : 0) + (kk[1] ? (hh - 1) * ww : 0));
            if ((gpu_word_of(a, g_bl) < RS_SRC_LO) || (gpu_word_of(a, g_bl) >= RS_DST_HI)) ok = 1'b0;
         end
         if (ok) begin
            rs_mark;
            rs_w({(rs_r(2) ? GPU_COPY : GPU_FILL), 28'h0}, 2'd0);
            rs_n_bare = rs_n_bare + 1;
            rs_cv_misc[CV_BARE] = 1'b1;
         end
      end
   end
endtask

// Dropped push: freeze, fill the FIFO, push one word too many, then
// resynchronise with GPU_EN = 0 -> 1, or let the next word be misread
task rs_drop;
   input integer from;
   integer       i, g;
   reg           ok, mis;
   reg    [31:0] st, dw;
   begin
      gpu_freeze(1'b1);
      rs_hold = 1'b1;
      repeat (4) @(posedge free_clk);
      i  = from;
      ok = 1'b1;
      reg_rd_val(GPU_STAT, st);
      g = 0;
      while (!st[17] && ok && (g < 64)) begin           // fill until FULL (the freeze takes a cycle)
         rs_credit = st[7:0];
         while ((rs_credit > 0) && ok) begin
            rs_push((i < rs_np) ? rs_pw[i] : {OP_SET_SIZE, 28'h0004004}, ok);
            i = i + 1;
         end
         reg_rd_val(GPU_STAT, st);
         g = g + 1;
      end
      if (!st[17]) tb_error("rstream: the FIFO is not full for the dropped push");
      dw = (i < rs_np) ? rs_pw[i] : {OP_SET_FILL, 28'h0};
      mis = 1'b0;
      if ((rs_r(2) == 0) && !gpu_pp_owe && (gpu_pp_act == 0)) begin
         dw  = {OP_SET_TRANSP, 28'h0};                    // a command with an operand
         mis = rs_r(2) == 0;                              // ... whose operand is then misread
      end
      reg_wr(GPU_CMD, dw);                          // dropped: not logged
      rs_hold = 1'b0;
      rs_ovfl = 1'b1;
      rs_n_drop = rs_n_drop + 1;
      rs_cv_misc[CV_DROP] = 1'b1;
      if (mis) begin
         // the operand pushed next is decoded as a command (opcode 0): ERR_CAUSE 1
         gpu_freeze(1'b0);
         rs_credit = 0;
         rs_push(32'h0000_00A5, ok);
         rs_cv_misc[CV_MISREAD] = 1'b1;
      end else if (rs_r(2) && (gpu_pp_owe || (gpu_pp_act > 0) || gpu_pp_arm)) begin
         // the dropped word left nothing owed it did not push; a DISCARD with the
         // FIFO full and the stream partial: its marker pending until the GPU
         // drains a word
         rs_discard;
         repeat (rs_r(8)) @(posedge free_clk);
         gpu_freeze(1'b0);
      end else begin
         rs_ff_kind = 2;
         rs_flush(2);
         gpu_freeze(1'b0);
         rs_flush_frozen_done;
      end
   end
endtask

//----------------------------------------------------------------------------
// Main
//----------------------------------------------------------------------------
integer rs_t0, rs_ii;
reg     rs_okb;
initial
   begin
      $display(" ===============================================");
      $display("|   GPU: constrained-random command stream      |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < 38400)
         tb_skip_finish("|      (VRAM below 38400 words: not run)       |");
      rs_n_fl = 0; rs_n_err = 0; rs_n_drop = 0; rs_n_prefix = 0; rs_n_whole = 0; rs_n_none = 0;
      rs_n_list = 0; rs_n_frz = 0; rs_n_bare = 0; rs_n_dc = 0; rs_n_dcm = 0; rs_n_dcab = 0;
      rs_abort_run = 1'b0;
      cv_w = 0; cv_p = 1; cv_pf = 16'h1; cv_h = 8; cv_o = 0;
      for (rs_si = 0; (rs_si < RS_NSEEDS) && !rs_abort_run; rs_si = rs_si + 1) begin
         rs_seed     = `SEED ^ (rs_si * 32'h9E37_79B9);
         rs_rsv_seed = rs_seed ^ 32'h5EED_0BAD;
         gpu_seed    = rs_seed;
         $display("INFO:  seed stream %0d of %0d: seed %0d", rs_si + 1, RS_NSEEDS, rs_seed);
         gpu_preload_rand(0, VRAM_WORDS);
         for (rs_t0 = RS_A8_LO; rs_t0 < RS_A8_LO + 1024; rs_t0 = rs_t0 + 1)   // alpha planes: mostly 0 / 255
            vram_mem[rs_t0] = (rs_r(3) == 0) ? vram_mem[rs_t0] : ({rs_r(4) ? 8'hFF : 8'h00, rs_r(4) ? 8'hFF : 8'h00,
                                                                            rs_r(4) ? 8'hFF : 8'h00, rs_r(4) ? 8'hFF : 8'h00});
         gpu_model_init;
         gpu_set_mode(3'd0);
         reg_wr(CTRL, 32'h0);                       // GPU_EN 0 -> 1: a known stream state
         reg_wr(CTRL, 32'h10);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_sm_reset;
         gpu_sm_st = GPU_SM_CMD;
         gpu_m_dispw = 1;
         gpu_set_dispw(320);
         rs_credit = 0; rs_in_err = 1'b0; rs_ovfl = 1'b0;
         rs_exp_acc = rs_acc;
         // a RESET_STATE through the stream: the model and the GPU agree on every setting
         rs_np = 0; rs_inlist = 1'b0;
         rs_push({OP_SET_EXT, EXT_SET_EXT2, X2_RESET_STATE, 16'h0000}, rs_okb);
         reg_rd_val(GPU_FENCE, rs_t0);
         gpu_sm_fence = rs_t0[23:0];
         reg_rd_val(GPU_ERR, rs_t0);
         gpu_sm_eword = rs_t0;
         reg_rd_val(GPU_STAT, rs_t0);
         gpu_sm_eop = rs_t0[31:28]; gpu_sm_ecause = rs_t0[27:25];
         gpu_sm_eirq = 1'b0; gpu_sm_firq = 1'b0;
         rs_settle("start");
         gpu_be_clear;
         rs_bew_n  = 0;
         rs_bel_on = 1'b1;
         for (rs_seg = 0; (rs_seg < RS_SEGS) && !rs_abort_run; rs_seg = rs_seg + 1)
            rs_segment;
         rs_bel_on = 1'b0;
         $display("INFO:  seed stream %0d done: %0d EXECs decoded so far", rs_si + 1, gpu_sm_nx);
      end
      $display("INFO:  %0d EXECs, %0d flushes (%0d left a strict prefix, %0d whole), %0d errors, %0d dropped pushes, %0d list segments, %0d freezes, %0d bare EXECs, %0d words with reserved bits",
               gpu_sm_nx, rs_n_fl, rs_n_prefix, rs_n_whole, rs_n_err, rs_n_drop, rs_n_list, rs_n_frz, rs_n_bare, gpu_rsv_n);
      $display("INFO:  %0d DISCARDs (%0d markers, %0d decoded; %0d immediate rectangles abandoned with a strict prefix)",
               rs_n_dc, rs_n_dcm, gpu_sm_nmrk, rs_n_dcab);
      if (gpu_sm_nx < 50) tb_error("rstream: too few EXECs decoded (test bug)");
      rs_cov_report;
      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
