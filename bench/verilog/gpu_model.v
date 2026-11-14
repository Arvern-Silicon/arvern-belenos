//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    gpu_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_model.v
// Module Description : GPU reference model and VRAM-port monitor for the gpu_*
//                      tests (`included by each test, inside tb_belenos).
//                      Written from the specification only
//                      (doc/gpu_commands.md):
//                      - shadow copy of VRAM, preloaded with the same data as
//                        the VRAM model through the backdoor;
//                      - GPU programming state, updated by the gpu_c_* tasks
//                        that also push the command words to GPU_CMD;
//                      - per-pixel model of EXEC_FILL / COPY / COPY_TRANSP in
//                        visit order (walk, 16 PX_OPs, transparency);
//                      - "touched" word bitmap, read back through the VRAM
//                        window and compared with the shadow;
//                      - VRAM-port monitor: access counts and cycle stamps,
//                        byte-enable check, forbidden-access window;
//                      - x/y destinations (SET_DST XY, SET_XY), clip window
//                        (SET_CLIP), gradient fill (SET_GRAD), texture unit
//                        (SET_TEX incl. BOUND, SET_UV, SET_STEP, SET_STEP_ROW,
//                        SET_TEXBOX) with EXEC_SPAN / EXPAND / TEXSPAN /
//                        TEXRECT models (gpu_c_span .. gpu_c_texrect),
//                        triangles (gpu_c_trifill, gpu_c_tritex), an
//                        allowed-word VRAM monitor (gpu_alw_*) and a per-pixel
//                        walk record with a prefix check (gpu_rec_*). All of
//                        it is off after gpu_model_init: the FILL / COPY /
//                        COPY_TRANSP model is unchanged in address mode.
//                        Palette remap (SET_AUX REMAP_TABLE, the REMAP
//                        fields: gpu_k_rmp for the next EXEC, gpu_k_trmp for
//                        SET_TEX) and the mask plane (SET_AUX MASK_PLANE,
//                        MPLANE: gpu_k_mpl), with their table / mask word
//                        reads in the access accounting and the rule
//                        checked (no mask or table word in the command's
//                        destination). Immediate source (SET_SRC IMM, N
//                        data words pushed after the EXEC: gpu_c_imm arms
//                        the next copy / EXPAND with gpu_imm_buf[0..N-1]):
//                        a surface at pixel 0 with the width as pitch,
//                        words past N read 0, no VRAM read; FENCE AUTO
//                        (gpu_c_fence_auto).
//                        Blending (SET_ALPHA: gpu_c_alpha, EXEC_EXPAND MASK:
//                        gpu_exp_mask) at 16 bpp in every drawing model:
//                        out = d + ((s - d) * a + 128) >> 8 per RGB565
//                        channel (gpu_blend565), s = S for ops 0-12, the
//                        constant of ops 13-15; SET_ALPHA [9] MIX5 (LVGL's
//                        rule, factor 8 ((alpha + 4) >> 3), truncated) in
//                        every blend (gpu_a_fac, gpu_a_comb).
//                        RGB565A8 sources (SRC_FMT 5, SET_AUX ALPHA_PLANE:
//                        gpu_k_a8 for the copies and textures pushed): the
//                        key first, then the A8 byte (x A with EN), its word
//                        read through the auxiliary holder, the no-D rule in
//                        the accounting. Bilinear sampling (SET_AUX
//                        TEX_FILTER: gpu_t_bil, gpu_bil_px) with a 2 x 2 tap
//                        cache model for the read counts.
//                        Flushes (gpu_flush): CLEAR_ERR, ABORT, GPU_EN = 0
//                        keep every setting; with gpu_flush_resend = 0 the
//                        command tasks never re-send SET_SRC after one, so a
//                        test sees what the GPU kept. Reserved and ignored
//                        command bits set at random with gpu_rsv_en.
//----------------------------------------------------------------------------

localparam integer GPU_PA_W     = VRAM_AW + 5;
localparam  [31:0] GPU_PA_MASK  = (GPU_PA_W >= 32) ? 32'hFFFF_FFFF : ((32'h1 << GPU_PA_W) - 32'h1);
localparam  [31:0] GPU_DIM_MASK = (32'h1 << ((DIM_W < 14) ? DIM_W : 14)) - 32'h1;

localparam  [3:0]  GPU_FILL     = 4'h8;
localparam  [3:0]  GPU_COPY     = 4'h9;
localparam  [3:0]  GPU_COPYT    = 4'hA;

// GPU_STAT fields
localparam  [31:0] GS_EMPTY     = 32'h0001_0000;
localparam  [31:0] GS_FULL      = 32'h0002_0000;
localparam  [31:0] GS_PRIM_BUSY  = 32'h0010_0000;
localparam  [31:0] GS_BUSY      = 32'h0020_0000;
localparam  [31:0] GS_ERR       = 32'h0040_0000;
localparam  [31:0] GS_WAIT      = 32'h0004_0000;
localparam  [31:0] GS_HELD      = 32'h0080_0000;

// IRQ_FLAG GPU bits
localparam  [31:0] IF_DONE      = 32'h10;
localparam  [31:0] IF_IDLE      = 32'h20;
localparam  [31:0] IF_OVFL      = 32'h40;
localparam  [31:0] IF_ERR       = 32'h80;
localparam  [31:0] IF_FENCE     = 32'h200;
localparam  [31:0] IF_GPU_ALL   = 32'h2F0;

reg         [31:0] gpu_shadow [0:VRAM_WORDS-1];
reg         [31:0] gpu_save   [0:VRAM_WORDS-1];
reg                gpu_touch  [0:VRAM_WORDS-1];
integer            gpu_seed;
integer            gpu_i;
integer            gpu_err_print;

// Programming state (model of the GPU registers)
reg         [31:0] gpu_m_src_base;
reg         [31:0] gpu_m_dst_base;
reg         [31:0] gpu_m_dst_org = 32'h0; // surface origin of x/y mode (every SET_DST operand)
reg         [15:0] gpu_m_src_pitch;
reg          [3:0] gpu_m_src_fmt = 4'h0; // SET_SRC.SRC_FMT as last pushed (the register survives model inits)
reg         [23:0] gpu_m_fence   = 24'h0; // tag of the last FENCE pushed
reg         [15:0] gpu_m_dst_pitch;
integer            gpu_m_w;
integer            gpu_m_h;
reg         [15:0] gpu_m_fill;
reg         [15:0] gpu_m_transp;
reg          [2:0] gpu_m_mode;          // CTRL.GFX_MODE as written
integer            gpu_m_dispw;         // DISP_SIZE width as stored
reg                gpu_m_xy;            // destination in x/y mode (SET_DST [16])
integer            gpu_m_x;             // x/y position of the next rectangle
integer            gpu_m_y;
integer            gpu_m_xyp;           // x/y line pitch, latched at SET_DST XY / SET_XY
integer            gpu_m_cx0;           // clip window (inclusive, signed)
integer            gpu_m_cy0;
integer            gpu_m_cx1;
integer            gpu_m_cy1;
reg                gpu_m_gen;           // SET_GRAD
reg                gpu_m_gaxis;
integer            gpu_m_gn;
integer            gpu_m_gstep;
reg                gpu_m_grgb;          // SET_GRAD [18] RGB (16 bpp), SET_GRAD_RGB steps (1/64)
integer            gpu_m_gdr;
integer            gpu_m_gdg;
integer            gpu_m_gdb;
reg         [31:0] gpu_m_rbase = 32'h0; // SET_AUX REMAP_TABLE: table word address (multiple of 64)
reg         [31:0] gpu_m_mbase = 32'h0; // SET_AUX MASK_PLANE: mask pixel of the source's first pixel
reg                gpu_m_minv  = 1'b0;  // ... INV
reg          [1:0] gpu_k_rmp   = 2'd0;  // REMAP field of the next EXEC (FILL, COPY, COPY_TRANSP, EXPAND)
reg                gpu_k_mpl   = 1'b0;  // MPLANE of the next EXEC_COPY / COPY_TRANSP
reg          [1:0] gpu_k_trmp  = 2'd0;  // REMAP field of the next SET_TEX
// Immediate source: armed by gpu_c_imm for the next copy / EXPAND
localparam integer GPU_IMM_MAX = 8192;
reg         [31:0] gpu_imm_buf [0:GPU_IMM_MAX-1];
integer            gpu_imm_n   = 0;     // N, the data words pushed after the EXEC
reg                gpu_k_imm   = 1'b0;  // armed
reg                gpu_x_imm   = 1'b0;  // the context's source is immediate
// Triangles: the vertices (12.4) of SET_V0..V2, and the DELTA field of the
// textured-triangle word (ignored with TRI)
integer            gpu_tv_x [0:2];
integer            gpu_tv_y [0:2];
reg         [13:0] gpu_tt_delta = 14'h0000;
// Blending: SET_ALPHA A / EN (16 bpp, GPU_BLEND_EN builds)
reg                gpu_m_aen   = 1'b0;
reg          [7:0] gpu_m_a     = 8'h00;
reg                gpu_x_blend = 1'b0;  // the context blends (EN, or an RGB565A8 source; 16 bpp)
integer            gpu_x_alpha = 256;   // its factor (EN), 0 .. 256 (gpu_a_fac of A)
// SET_ALPHA [9] MIX5, SET_AUX ALPHA_PLANE (the byte address of the alpha of
// the SET_SRC base pixel), SET_AUX TEX_FILTER (BILINEAR, TBORDER): settings,
// kept through model inits as the GPU keeps them (RESET_STATE: 0)
reg                gpu_m_mix5  = 1'b0;
reg         [31:0] gpu_m_abase = 32'h0;
reg                gpu_m_bil   = 1'b0;
reg                gpu_m_tbord = 1'b0;
reg                gpu_k_a8    = 1'b0;  // copies and textures pushed with SRC_FMT 5 (else 0)
// RGB565A8 source of the context: SRC_FMT 5 on a copy / texture at 16 bpp in
// a blend build (palette modes: as SRC_FMT 0, no A8 read)
reg                gpu_x_a8    = 1'b0;
reg                gpu_x_bilx  = 1'b0;  // the context samples bilinearly (texture, 16 bpp, BILINEAR)
reg         [31:0] gpu_x_ka    = 32'h0; // A8 byte address - source pixel (mod 2^PA_W)
reg                gpu_x_aen   = 1'b0;  // SET_ALPHA EN, A of the context
reg          [7:0] gpu_x_a     = 8'h00;
integer            gpu_a8_nrd  = 0;     // A8 word reads (the shared auxiliary holder)
integer            gpu_a8_nnd  = 0;     // A8 pixels written without a destination read
integer            gpu_a8_nskip = 0;    // A8 pixels skipped (factor 0)
// SET_SRC re-send after a GPU_CTRL / CTRL write (gpu_flush_hint): 1 = the
// model re-sends SET_SRC before the next source command (a flush may have
// dropped a queued SET_SRC); 0 = the settings are taken as kept (the test
// flushes only an idle GPU, or through gpu_flush)
reg                gpu_flush_resend = 1'b1;
// Reserved / ignored command bits set at random (their own seed)
reg                gpu_oob_ok   = 1'b0;  // pixels past VRAM_WORDS dropped (ERR_CAUSE 5 tests)
reg                gpu_rsv_en   = 1'b0;
integer            gpu_rsv_seed = 1;
integer            gpu_rsv_n    = 0;    // words pushed with a reserved bit set

// Context of the rectangle being modelled (latched at "EXEC start")
reg          [3:0] gpu_x_cmd;
reg          [3:0] gpu_x_op;
reg          [2:0] gpu_x_dsw;           // {X, Y, CL}
reg          [2:0] gpu_x_ssw;
integer            gpu_x_bl;
integer            gpu_x_spitch;
integer            gpu_x_dpitch;
integer            gpu_x_w;
integer            gpu_x_h;
reg         [31:0] gpu_x_sbase;
reg         [31:0] gpu_x_dbase;
reg         [15:0] gpu_x_fill;
reg         [15:0] gpu_x_transp;
reg                gpu_x_xy;
integer            gpu_x_x;
integer            gpu_x_y;
integer            gpu_x_cx0;
integer            gpu_x_cy0;
integer            gpu_x_cx1;
integer            gpu_x_cy1;
reg                gpu_x_gen;           // gradient applied (real FILL / SPAN only)
reg                gpu_x_gaxis;
integer            gpu_x_gn;
integer            gpu_x_gstep;
reg                gpu_x_grgb;
integer            gpu_x_gdr;
integer            gpu_x_gdg;
integer            gpu_x_gdb;
reg          [1:0] gpu_x_rmp;           // remap mode of the EXEC
reg         [31:0] gpu_x_rbase;
reg                gpu_x_mpl;           // mask plane
reg                gpu_x_minv;
reg         [31:0] gpu_x_k;             // mask pixel - source pixel

// Expected access / pixel counts (accumulated by the model)
integer            gpu_exp_rd;
integer            gpu_exp_wr;
integer            gpu_exp_transp;
integer            gpu_exp_clip;        // walk positions outside the clip window
integer            gpu_exp_drd = 0;     // ... of gpu_exp_rd: destination reads

// VRAM port monitor
integer            gpu_cyc;
reg                gpu_mon_en;
integer            gpu_mon_rd;
integer            gpu_mon_wr;
integer            gpu_mon_n;
integer            gpu_mon_t [0:4095];
reg                gpu_mon_t_wr [0:4095];
reg                gpu_mon_be_chk;
integer            gpu_mon_bl;
reg                gpu_mon_noacc;
integer            gpu_mon_noacc_hits;

initial begin
   gpu_cyc            = 0;
   gpu_mon_en         = 1'b0;
   gpu_mon_be_chk     = 1'b0;
   gpu_mon_noacc      = 1'b0;
   gpu_mon_noacc_hits = 0;
   gpu_mon_rd         = 0;
   gpu_mon_wr         = 0;
   gpu_mon_n          = 0;
   gpu_mon_bl         = 4;
   gpu_err_print      = 0;
end

always @(posedge free_clk) gpu_cyc <= gpu_cyc + 1;

// The window's read ahead (a read in an otherwise idle cycle, after an earlier
// window read) is not the GPU's: it is left out of both monitors
wire gpu_mon_wp = (dut.u_core.u_vram_arb.gnt_o[VRQ_WP] === 1'b1);

always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && !gpu_mon_wp) begin
     if (gpu_mon_en) begin
        if (vram_wen === 4'hF) gpu_mon_rd = gpu_mon_rd + 1;
        else                   gpu_mon_wr = gpu_mon_wr + 1;
        if (gpu_mon_n < 4096) begin
           gpu_mon_t[gpu_mon_n]    = gpu_cyc;
           gpu_mon_t_wr[gpu_mon_n] = (vram_wen !== 4'hF);
        end
        gpu_mon_n = gpu_mon_n + 1;
     end
     if (gpu_mon_noacc) begin
        gpu_mon_noacc_hits = gpu_mon_noacc_hits + 1;
        if (gpu_mon_noacc_hits <= 4)
           $display("ERROR: GPU VRAM access while the GPU is held (word 0x%h wen %b) %t", vram_addr, vram_wen, $time);
        error = error + 1;
     end
     if (gpu_mon_be_chk && (vram_wen !== 4'hF)) begin
        if ((gpu_mon_bl == 4) && ((vram_wen[1] !== vram_wen[0]) || (vram_wen[3] !== vram_wen[2]))) begin
           $display("ERROR: GPU write byte enables %b not whole %0d-bpp pixels %t", vram_wen, 1 << gpu_mon_bl, $time);
           error = error + 1;
        end
     end
  end

task gpu_mon_start;
   begin
      gpu_mon_rd = 0;
      gpu_mon_wr = 0;
      gpu_mon_n  = 0;
      gpu_mon_en = 1'b1;
   end
endtask

task gpu_mon_stop;
   begin
      gpu_mon_en = 1'b0;
   end
endtask

// Wait until the monitor (gpu_mon_start before the push) has seen n GPU
// writes: a flush then lands after the first writes of the primitive, in its
// middle. ok = 0 when the GPU went idle (or 20000 cycles passed) first.
task gpu_wait_wr;
   input  integer n;
   output         ok;
   integer        g;
   begin
      g = 0;
      while ((gpu_mon_wr < n) && (g < 20000) &&
             ((g < 20) || (dut.u_core.gpu_busy !== 1'b0))) begin
         @(posedge free_clk);
         g = g + 1;
      end
      ok = (gpu_mon_wr >= n);
   end
endtask

// Allowed-word monitor: while gpu_alw_en, every VRAM access must hit a word
// marked in gpu_alw (the models mark the words of every pixel they access:
// destination of an unclipped pixel, source / texel actually read). Nothing
// else may use the VRAM meanwhile (no window access, no refresh).
reg                gpu_alw    [0:VRAM_WORDS-1];
reg                gpu_alw_en;
integer            gpu_alw_n;
integer            gpu_alw_bad;
initial begin gpu_alw_en = 1'b0; gpu_alw_n = 0; gpu_alw_bad = 0; end

always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && gpu_alw_en && !gpu_mon_wp) begin
     gpu_alw_n = gpu_alw_n + 1;
     if (({{(32-VRAM_AW){1'b0}}, vram_addr} >= VRAM_WORDS) || (gpu_alw[vram_addr] !== 1'b1)) begin
        gpu_alw_bad = gpu_alw_bad + 1;
        if (gpu_alw_bad <= 6)
           $display("ERROR: GPU VRAM access to word 0x%h (wen %b) that holds no pixel to access %t",
                    vram_addr, vram_wen, $time);
        error = error + 1;
     end
  end

task gpu_alw_clear;
   integer ww;
   begin
      for (ww = 0; ww < VRAM_WORDS; ww = ww + 1)
         gpu_alw[ww] = 1'b0;
   end
endtask

task gpu_alw_mark;
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   begin
      wd = pa >> (5 - bl);
      if (wd < VRAM_WORDS) gpu_alw[wd] = 1'b1;
   end
endtask

task gpu_alw_start;
   begin
      gpu_alw_n  = 0;
      gpu_alw_en = 1'b1;
   end
endtask

task gpu_alw_stop;
   begin
      gpu_alw_en = 1'b0;
   end
endtask


// Byte-enable monitor: while gpu_be_en, every GPU write may enable only bytes
// marked in gpu_be_ok (doc/gpu_commands.md, concurrent CPU access: the bytes
// holding pixels of the rectangle). The models mark, for every visited pixel
// of the walk (written or skipped, never clipped or outside a triangle), the
// bytes holding it (gpu_rec_px). Words at or past GPU_BE_WORDS are not checked.
localparam integer GPU_BE_WORDS = (VRAM_WORDS > 262144) ? 262144 : VRAM_WORDS;
reg          [3:0] gpu_be_ok [0:GPU_BE_WORDS-1];
reg                gpu_be_en;
reg                gpu_be_mk = 1'b0;     // marks without the live check (a test checks the writes it logged)
integer            gpu_be_n;
integer            gpu_be_bad;
initial begin gpu_be_en = 1'b0; gpu_be_n = 0; gpu_be_bad = 0; end

always @(posedge hclk)
  if ((hresetn_d === 1'b1) && (vram_cen === 1'b0) && gpu_be_en && (vram_wen !== 4'hF) &&
      (dut.u_core.u_vram_arb.gnt_o[VRQ_GPU] === 1'b1) &&
      ({{(32-VRAM_AW){1'b0}}, vram_addr} < GPU_BE_WORDS)) begin
     gpu_be_n = gpu_be_n + 1;
     if ((~vram_wen & ~gpu_be_ok[vram_addr]) !== 4'h0) begin
        gpu_be_bad = gpu_be_bad + 1;
        if (gpu_be_bad <= 6)
           $display("ERROR: GPU write to word 0x%h enables bytes %b, only %b hold pixels of the rectangle %t",
                    vram_addr, ~vram_wen, gpu_be_ok[vram_addr], $time);
        error = error + 1;
     end
  end

task gpu_be_clear;
   integer ww;
   begin
      for (ww = 0; ww < GPU_BE_WORDS; ww = ww + 1)
         gpu_be_ok[ww] = 4'h0;
   end
endtask

task gpu_be_mark;                        // the bytes holding pixel pa (depth bl)
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   integer      bo;
   begin
      wd = pa >> (5 - bl);
      bo = ((pa & ((32 >> bl) - 1)) << bl) >> 3;   // first byte of the pixel
      if (wd < GPU_BE_WORDS)
         gpu_be_ok[wd] = gpu_be_ok[wd] | ((bl == 4) ? (4'h3 << bo) : (4'h1 << bo));
   end
endtask

//============================================================================
// Pixel helpers
//============================================================================
function integer gpu_bl;                 // bpp_log2 of a GFX_MODE
   input [2:0] mode;
   begin
      gpu_bl = (mode < 3'd4) ? mode : 4;
   end
endfunction

function [31:0] gpu_pmask;
   input integer bl;
   begin
      gpu_pmask = (bl == 4) ? 32'hFFFF : ((32'h1 << (1 << bl)) - 32'h1);
   end
endfunction

function [31:0] gpu_word_of;
   input [31:0] pa;
   input integer bl;
   begin
      gpu_word_of = pa >> (5 - bl);
   end
endfunction

function [31:0] gpu_get_px;
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   integer      off;
   begin
      wd  = pa >> (5 - bl);
      off = (pa & ((32 >> bl) - 1)) << bl;
      if (wd >= VRAM_WORDS) gpu_get_px = 32'hxxxx_xxxx;
      else                  gpu_get_px = (gpu_shadow[wd] >> off) & gpu_pmask(bl);
   end
endfunction

// Source pixel: the VRAM shadow, or the immediate data (words past N read 0)
function [31:0] gpu_src_px;
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   integer      off;
   begin
      if (!gpu_x_imm)
         gpu_src_px = gpu_get_px(pa, bl);
      else begin
         wd  = pa >> (5 - bl);
         off = (pa & ((32 >> bl) - 1)) << bl;
         gpu_src_px = (wd < gpu_imm_n) ? ((gpu_imm_buf[wd] >> off) & gpu_pmask(bl)) : 32'h0;
      end
   end
endfunction

// Out of VRAM (ERR_CAUSE 5): gpu_oob_hit is set by the first pixel write at or
// past VRAM_WORDS; with gpu_oob_stop the writes after it are dropped (the GPU
// abandons the rectangle at the faulting access)
reg                gpu_oob_hit  = 1'b0;
reg                gpu_oob_stop = 1'b0;

// Stream record (gpu_sr_en, the random stream model): every pixel write in
// order, as the word written, its value before and after. gpu_sr_cut finds the
// prefix of the writes the VRAM holds after a flush or an abandon.
localparam integer GPU_SR_MAX = 32768;
reg                gpu_sr_en = 1'b0;
integer            gpu_sr_n  = 0;
reg         [31:0] gpu_sr_wa  [0:GPU_SR_MAX-1];
reg         [31:0] gpu_sr_old [0:GPU_SR_MAX-1];
reg         [31:0] gpu_sr_new [0:GPU_SR_MAX-1];
integer            gpu_sr_ex  [0:GPU_SR_MAX-1];   // EXEC ordinal of the write
integer            gpu_sr_xn  = 0;                // EXECs recorded
integer            gpu_sr_ovf = 0;

task gpu_sr_add;
   input [31:0] wd;
   begin
      if (gpu_sr_n >= GPU_SR_MAX) begin
         if (gpu_sr_ovf == 0) begin
            $display("ERROR: GPU model -- stream record overflow (test bug) %t", $time);
            error = error + 1;
         end
         gpu_sr_ovf = gpu_sr_ovf + 1;
         gpu_sr_n   = GPU_SR_MAX - 1;
      end
      gpu_sr_wa[gpu_sr_n]  = wd;
      gpu_sr_old[gpu_sr_n] = gpu_shadow[wd];
      gpu_sr_ex[gpu_sr_n]  = gpu_sr_xn;
      gpu_sr_n = gpu_sr_n + 1;
   end
endtask

task gpu_set_px;
   input [31:0] pa;
   input integer bl;
   input [31:0] val;
   reg   [31:0] wd;
   integer      off;
   begin
      wd  = pa >> (5 - bl);
      off = (pa & ((32 >> bl) - 1)) << bl;
      if (wd >= VRAM_WORDS) begin
         gpu_oob_hit = 1'b1;
         if (!gpu_oob_ok) begin
            $display("ERROR: GPU model -- pixel 0x%h outside VRAM (test bug) %t", pa, $time);
            error = error + 1;
         end
      end else if (!(gpu_oob_stop && gpu_oob_hit)) begin
         if (gpu_sr_en) gpu_sr_add(wd);
         gpu_shadow[wd] = (gpu_shadow[wd] & ~(gpu_pmask(bl) << off)) | ((val & gpu_pmask(bl)) << off);
         if (gpu_sr_en) gpu_sr_new[gpu_sr_n - 1] = gpu_shadow[wd];
      end
   end
endtask

//----------------------------------------------------------------------------
// Blending (doc/gpu_commands.md, blending): per RGB565 channel
//   out = d + ((s - d) * a + 128) >> 8 (arithmetic shift), a = 0 .. 256
//----------------------------------------------------------------------------
function [15:0] gpu_blend565;
   input [15:0] s;
   input [15:0] d;
   input integer a;
   integer      sr, sg, sb, dr, dg, db, rr, rg, rb;   // integers: the shift is arithmetic
   begin
      sr = s[15:11]; sg = s[10:5]; sb = s[4:0];
      dr = d[15:11]; dg = d[10:5]; db = d[4:0];
      rr = dr + ((((sr - dr) * a) + 128) >>> 8);
      rg = dg + ((((sg - dg) * a) + 128) >>> 8);
      rb = db + ((((sb - db) * a) + 128) >>> 8);
      gpu_blend565 = ((rr & 31) << 11) | ((rg & 63) << 5) | (rb & 31);
   end
endfunction

// SET_ALPHA A as a blend alpha: 255 counts as 256 (opaque)
function integer gpu_a_const;
   input [7:0] a;
   begin
      gpu_a_const = (a == 8'd255) ? 256 : {24'h0, a};
   end
endfunction

// EXPAND MASK coverage alpha of a source value at source depth sdep (0..3 =
// 1, 2, 4, 8 bpp): 255 v, 85 v, 17 v, v; with SET_ALPHA EN the coverage
// times A / 255, rounded to the nearest. 0 writes nothing, 255 is opaque.
function integer gpu_a_mask;
   input [31:0] v;
   input  [1:0] sdep;
   input        en;
   input  [7:0] a;
   integer      am;
   begin
      case (sdep)
        2'd0:    am = (v[0] != 1'b0) ? 255 : 0;
        2'd1:    am = v[1:0] * 85;
        2'd2:    am = v[3:0] * 17;
        default: am = v[7:0];
      endcase
      if (en) am = (am * a + 127) / 255;
      gpu_a_mask = (am >= 255) ? 256 : am;
   end
endfunction

//----------------------------------------------------------------------------
// Blend rule (SET_ALPHA [9] MIX5, every blend at 16 bpp in a blend build).
// A blend is a factor a (0 .. 256) and a rounding constant r:
//   MIX5 = 0: a = 256 for alpha 255, else alpha; r = 128 (gpu_blend565);
//   MIX5 = 1: m = (alpha + 4) >> 3, a = 8 m;       r = 0;
//   out = d + floor(((s - d) * a + r) / 256) per field; a = 0: not written,
//   a = 256: s. The combination x o A of an alpha source x with SET_ALPHA A
//   (EN): MIX5 = 0 round(x A / 255) = ((x A + 127) * 257 + 256) >> 16,
//   MIX5 = 1 (x A) >> 8 (LV_OPA_MIX2).
//----------------------------------------------------------------------------
function [15:0] gpu_blend565r;           // with the rounding constant r
   input [15:0] s;
   input [15:0] d;
   input integer a;
   input integer r;
   integer      sr, sg, sb, dr, dg, db, rr, rg, rb;
   begin
      sr = s[15:11]; sg = s[10:5]; sb = s[4:0];
      dr = d[15:11]; dg = d[10:5]; db = d[4:0];
      rr = dr + ((((sr - dr) * a) + r) >>> 8);
      rg = dg + ((((sg - dg) * a) + r) >>> 8);
      rb = db + ((((sb - db) * a) + r) >>> 8);
      gpu_blend565r = ((rr & 31) << 11) | ((rg & 63) << 5) | (rb & 31);
   end
endfunction

function integer gpu_a_fac;              // the factor of alpha (0 .. 255) under rule mix5
   input integer al;
   input         mix5;
   begin
      if (!mix5) gpu_a_fac = gpu_a_const(al[7:0]);
      else       gpu_a_fac = 8 * ((al + 4) >> 3);
   end
endfunction

function integer gpu_a_comb;             // x o A under rule mix5
   input integer x;
   input  [7:0] a;
   input        mix5;
   begin
      if (!mix5) gpu_a_comb = (((x * a) + 127) * 257 + 256) >> 16;
      else       gpu_a_comb = (x * a) >> 8;
   end
endfunction

// EXPAND MASK / AA coverage factor under rule mix5 (gpu_a_mask for MIX5 = 0)
function integer gpu_a_mask5;
   input [31:0] v;
   input  [1:0] sdep;
   input        en;
   input  [7:0] a;
   input        mix5;
   integer      am;
   begin
      if (!mix5) gpu_a_mask5 = gpu_a_mask(v, sdep, en, a);
      else begin
         case (sdep)
           2'd0:    am = (v[0] != 1'b0) ? 255 : 0;
           2'd1:    am = v[1:0] * 85;
           2'd2:    am = v[3:0] * 17;
           default: am = v[7:0];
         endcase
         if (en) am = gpu_a_comb(am, a, 1'b1);
         gpu_a_mask5 = gpu_a_fac(am, 1'b1);
      end
   end
endfunction

// The colour written for a blended pixel over d: s itself at a = 256 (the
// context's rule: gpu_x_mix5)
reg gpu_x_mix5 = 1'b0;
function [31:0] gpu_blend_px;
   input [31:0] s;
   input [31:0] d;
   input integer a;
   begin
      gpu_blend_px = (a >= 256) ? (s & 32'hFFFF) :
                     {16'h0, gpu_blend565r(s[15:0], d[15:0], a, gpu_x_mix5 ? 0 : 128)};
   end
endfunction

task gpu_touch_px;
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   begin
      wd = pa >> (5 - bl);
      if (wd < VRAM_WORDS)       gpu_touch[wd]     = 1'b1;
      if ((wd + 1) < VRAM_WORDS) gpu_touch[wd + 1] = 1'b1;
      if (wd > 0)                gpu_touch[wd - 1] = 1'b1;
   end
endtask

// Pixel address of the k-th pixel visited (rectangle walk)
//   sw = {X, Y, CL}; no CL: inner +-1 (- if X), line +-pitch (- if Y);
//   CL: inner +-pitch (- if Y), line +-1 (- if X); w = inner run length.
function [31:0] gpu_walk;
   input [31:0] base;
   input integer pitch;
   input  [2:0] sw;
   input integer w;
   input integer k;
   integer      ii, jj, off;
   begin
      ii = k % w;
      jj = k / w;
      if (sw[0] == 1'b0)
         off = (sw[2] ? -ii : ii) + (sw[1] ? -jj : jj) * pitch;
      else
         off = (sw[1] ? -ii : ii) * pitch + (sw[2] ? -jj : jj);
      gpu_walk = (base + off) & GPU_PA_MASK;
   end
endfunction


//============================================================================
// Model state init, preload, checks
//============================================================================
reg gpu_inited = 1'b0;                   // gpu_model_init has run (the shadow holds the image)
task gpu_model_init;
   begin
      gpu_inited = 1'b1;
      for (gpu_i = 0; gpu_i < VRAM_WORDS; gpu_i = gpu_i + 1) begin
         gpu_shadow[gpu_i] = vram_mem[gpu_i];
         gpu_touch[gpu_i]  = 1'b0;
      end
      gpu_m_src_base  = 32'h0;
      gpu_m_dst_base  = 32'h0;
      gpu_m_dst_org   = 32'h0;
      gpu_m_src_pitch = 16'h0;
      gpu_m_dst_pitch = 16'h0;
      gpu_m_w         = 1;
      gpu_m_h         = 1;
      gpu_m_fill      = 16'h0;
      gpu_m_transp    = 16'h0;
      gpu_m_mode      = 3'd0;
      gpu_m_dispw     = 1;
      gpu_exp_rd      = 0;
      gpu_exp_wr      = 0;
      gpu_exp_transp  = 0;
      gpu_exp_clip    = 0;
      gpu_m_xy        = 1'b0;
      gpu_m_x         = 0;
      gpu_m_y         = 0;
      gpu_m_xyp       = 1;
      gpu_m_cx0       = -2048;
      gpu_m_cy0       = -2048;
      gpu_m_cx1       = 2047;
      gpu_m_cy1       = 2047;
      gpu_m_gen       = 1'b0;
      gpu_m_gaxis     = 1'b0;
      gpu_m_gn        = 0;
      gpu_m_gstep     = 0;
      gpu_m_grgb      = 1'b0;
      gpu_m_gdr       = 0;
      gpu_m_gdg       = 0;
      gpu_m_gdb       = 0;
      gpu_t_init;
      gpu_alw_clear;
      gpu_m_rbase     = 32'h0;
      gpu_m_mbase     = 32'h0;
      gpu_m_minv      = 1'b0;
      gpu_k_rmp       = 2'd0;
      gpu_k_mpl       = 1'b0;
      gpu_k_trmp      = 2'd0;
      gpu_r_nrd       = 0;
      gpu_m_nrd       = 0;
   end
endtask

// Random words in [lo, hi) (backdoor, both copies). GPU must be idle.
task gpu_preload_rand;
   input integer lo;
   input integer hi;
   integer       ww;
   reg    [31:0] vv;
   begin
      for (ww = lo; ww < hi; ww = ww + 1) begin
         vv = $random(gpu_seed);
         vram_mem[ww]   = vv;
         gpu_shadow[ww] = vv;
      end
   end
endtask

// Words in [lo, hi) built from a 4-colour palette at the given bpp
task gpu_preload_pal;
   input integer lo;
   input integer hi;
   input integer bl;
   input  [15:0] c0;
   input  [15:0] c1;
   input  [15:0] c2;
   input  [15:0] c3;
   integer       ww, pp, idx;
   reg    [31:0] vv;
   reg    [15:0] cc;
   begin
      for (ww = lo; ww < hi; ww = ww + 1) begin
         vv = 32'h0;
         for (pp = 0; pp < (32 >> bl); pp = pp + 1) begin
            idx = $random(gpu_seed) & 3;
            cc  = (idx == 0) ? c0 : (idx == 1) ? c1 : (idx == 2) ? c2 : c3;
            vv  = vv | ((cc & gpu_pmask(bl)) << (pp << bl));
         end
         vram_mem[ww]   = vv;
         gpu_shadow[ww] = vv;
      end
   end
endtask

// Read every touched word through the VRAM window and compare; clears marks
task gpu_check_touched;
   input [8*40-1:0] label;
   integer          ww, nchk, nbad;
   reg       [31:0] rd;
   begin
      nchk = 0;
      nbad = 0;
      tb_checks = tb_checks + 1;
      for (ww = 0; ww < VRAM_WORDS; ww = ww + 1)
         if (gpu_touch[ww]) begin
            gpu_touch[ww] = 1'b0;
            vram_rd_val(4*ww, SZ_W, rd);
            nchk = nchk + 1;
            if (rd !== gpu_shadow[ww]) begin
               nbad = nbad + 1;
               if (nbad <= 6)
                  $display("ERROR: GPU %0s -- VRAM word 0x%h = 0x%h / expected 0x%h %t",
                           label, ww, rd, gpu_shadow[ww], $time);
               error = error + 1;
            end
         end
      if (nbad == 0)
         $display("OK:    GPU %0s -- %0d words match the model", label, nchk);
      else
         $display("ERROR: GPU %0s -- %0d of %0d words differ", label, nbad, nchk);
   end
endtask

// Full backdoor compare of VRAM against the shadow (stray writes)
task gpu_check_all;
   input [8*40-1:0] label;
   integer          ww, nbad;
   begin
      nbad = 0;
      tb_checks = tb_checks + 1;
      for (ww = 0; ww < VRAM_WORDS; ww = ww + 1)
         if (vram_mem[ww] !== gpu_shadow[ww]) begin
            nbad = nbad + 1;
            if (nbad <= 6)
               $display("ERROR: GPU %0s -- backdoor word 0x%h = 0x%h / expected 0x%h %t",
                        label, ww, vram_mem[ww], gpu_shadow[ww], $time);
            error = error + 1;
         end
      if (nbad == 0)
         $display("OK:    GPU %0s -- whole VRAM matches the model", label);
   end
endtask

task gpu_snapshot;
   begin
      for (gpu_i = 0; gpu_i < VRAM_WORDS; gpu_i = gpu_i + 1)
         gpu_save[gpu_i] = gpu_shadow[gpu_i];
   end
endtask

task gpu_restore;
   begin
      for (gpu_i = 0; gpu_i < VRAM_WORDS; gpu_i = gpu_i + 1)
         gpu_shadow[gpu_i] = gpu_save[gpu_i];
   end
endtask


//============================================================================
// Rectangle model
//============================================================================

// Latch the exec context from the programming state (EXEC start)
task gpu_x_setup;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   begin
      gpu_x_cmd    = cmd;
      gpu_x_op     = op;
      gpu_x_dsw    = dsw;
      gpu_x_ssw    = ssw;
      gpu_x_bl     = gpu_bl(gpu_m_mode);
      gpu_x_spitch = (gpu_m_src_pitch == 16'h0) ? gpu_m_dispw : gpu_m_src_pitch;
      gpu_x_dpitch = (gpu_m_dst_pitch == 16'h0) ? gpu_m_dispw : gpu_m_dst_pitch;
      gpu_x_w      = gpu_m_w;
      gpu_x_h      = gpu_m_h;
      gpu_x_sbase  = gpu_m_src_base;
      gpu_x_dbase  = gpu_m_xy ? gpu_m_dst_org : gpu_m_dst_base;
      gpu_x_fill   = gpu_m_fill;
      gpu_x_transp = gpu_m_transp;
      gpu_x_xy     = gpu_m_xy;
      if (gpu_m_xy) gpu_x_dpitch = gpu_m_xyp;
      gpu_x_x      = gpu_m_x;
      gpu_x_y      = gpu_m_y;
      gpu_x_cx0    = gpu_m_cx0;
      gpu_x_cy0    = gpu_m_cy0;
      gpu_x_cx1    = gpu_m_cx1;
      gpu_x_cy1    = gpu_m_cy1;
      gpu_x_gen    = 1'b0;                 // set by the FILL / SPAN tasks only
      gpu_x_gaxis  = gpu_m_gaxis;
      gpu_x_gn     = (gpu_m_gn == 0) ? 1 : gpu_m_gn;
      gpu_x_gstep  = gpu_m_gstep;
      gpu_x_grgb   = gpu_m_grgb;
      gpu_x_gdr    = gpu_m_gdr;
      gpu_x_gdg    = gpu_m_gdg;
      gpu_x_gdb    = gpu_m_gdb;
      gpu_x_rmp    = 2'd0;                 // set by the command tasks
      gpu_x_rbase  = gpu_m_rbase;
      gpu_x_mpl    = 1'b0;
      gpu_x_minv   = gpu_m_minv;
      gpu_x_k      = (gpu_m_mbase - gpu_m_src_base) & GPU_PA_MASK;
      gpu_x_imm    = 1'b0;                 // set by the command tasks
      gpu_x_mix5   = gpu_m_mix5 && (GPU_BLEND_EN != 0);
      gpu_x_aen    = gpu_m_aen;
      gpu_x_a      = gpu_m_a;
      gpu_x_blend  = gpu_m_aen && (gpu_x_bl == 4) && (GPU_BLEND_EN != 0);
      gpu_x_alpha  = gpu_a_fac(gpu_m_a, gpu_x_mix5);
      gpu_x_a8     = 1'b0;                 // set by the copy / texture tasks (gpu_x_take_a8)
      gpu_x_bilx   = 1'b0;                 // set by the texture tasks (gpu_x_take_bil)
      gpu_x_ka     = (gpu_m_abase - gpu_m_src_base) & GPU_PA_MASK;
   end
endtask

// A copy / texture takes the RGB565A8 source when SRC_FMT is 5 (16 bpp, blend
// build): every pixel blends with its alpha
task gpu_x_take_a8;
   begin
      gpu_x_a8 = (gpu_m_src_fmt == 4'd5) && (gpu_x_bl == 4) && (GPU_BLEND_EN != 0);
      if (gpu_x_a8) gpu_x_blend = 1'b1;
   end
endtask

// The A8 byte of source / texel pixel spa, with its word read (the auxiliary
// word holder shared with the mask plane). oob: its word is at or past
// VRAM_WORDS (ERR_CAUSE 5: the pixel and the rest not drawn)
task gpu_a8_byte;
   input  [31:0] spa;
   output  [7:0] b;
   output        oob;
   reg    [31:0] apa, wa;
   begin
      apa = (spa + gpu_x_ka) & GPU_PA_MASK;
      wa  = apa >> 2;
      oob = 1'b0;
      b   = 8'h00;
      if (!gpu_m_mv || (gpu_m_mwa != wa)) begin
         gpu_m_nrd  = gpu_m_nrd + 1;
         gpu_a8_nrd = gpu_a8_nrd + 1;
         gpu_exp_rd = gpu_exp_rd + 1;
         gpu_m_mv   = 1'b1;
         gpu_m_mwa  = wa;
      end
      gpu_alw_mark(apa, 3);
      gpu_d9_aux(wa);
      if (wa >= VRAM_WORDS) begin
         oob = 1'b1;
         if (!gpu_oob_ok) begin
            $display("ERROR: GPU model -- A8 word 0x%h outside VRAM (test bug) %t", wa, $time);
            error = error + 1;
         end
         gpu_oob_hit = 1'b1;
         gpu_m_mv    = 1'b0;
      end else
         b = gpu_shadow[wa] >> (8 * apa[1:0]);
   end
endtask

// The factor of an A8 byte b in the context (EN: b o A), and whether the
// pixel is written without a destination read (the no-D predicate, stated on
// b, EN and A: doc DECISIONS 4 / spec 3.1)
function integer gpu_a8_fac;
   input [7:0] b;
   begin
      gpu_a8_fac = gpu_a_fac(gpu_x_aen ? gpu_a_comb(b, gpu_x_a, gpu_x_mix5) : b, gpu_x_mix5);
   end
endfunction

function gpu_a8_nod;
   input [7:0] b;
   begin
      gpu_a8_nod = gpu_x_mix5 ? ((!gpu_x_aen && (b >= 8'd252)) || (gpu_x_aen && (gpu_x_a == 8'd255) && (b >= 8'd253)))
                              : ((b == 8'd255) && (!gpu_x_aen || (gpu_x_a == 8'd255)));
   end
endfunction

// The context takes the armed immediate source (a copy or EXPAND): a surface
// at pixel 0, the width as pitch
task gpu_x_take_imm;
   begin
      gpu_x_imm = gpu_k_imm;
      gpu_k_imm = 1'b0;
      if (gpu_x_imm) begin
         gpu_x_sbase  = 32'h0;
         gpu_x_spitch = gpu_x_w;
         gpu_x_k      = gpu_m_mbase & GPU_PA_MASK;
      end
   end
endtask

// Push the data words of the immediate source after its EXEC (FREE waited)
task gpu_imm_push;
   integer ii;
   reg     pw;
   begin
      if (gpu_x_imm) begin
         pw = gpu_push_wait;
         gpu_push_wait = 1'b1;
         for (ii = 0; ii < gpu_imm_n; ii = ii + 1)
            gpu_push(gpu_imm_buf[ii]);
         gpu_push_wait = pw;
      end
   end
endtask

// Destination of walk position k of the current context: pixel address and
// whether it lies inside the clip window (always in address mode).
//   x/y mode: (x, y) is the first pixel visited; no CL: run x +- i, lines
//   y +- j; CL: run y +- i, columns x +- j (- with the X / Y swap).
task gpu_x_pos;
   input  integer k;
   output  [31:0] pa;
   output         ins;
   integer        ii, jj, px, py;
   begin
      if (!gpu_x_xy) begin
         pa  = gpu_walk(gpu_x_dbase, gpu_x_dpitch, gpu_x_dsw, gpu_x_w, k);
         ins = 1'b1;
      end else begin
         ii = k % gpu_x_w;
         jj = k / gpu_x_w;
         if (gpu_x_dsw[0] == 1'b0) begin
            px = gpu_x_x + (gpu_x_dsw[2] ? -ii : ii);
            py = gpu_x_y + (gpu_x_dsw[1] ? -jj : jj);
         end else begin
            py = gpu_x_y + (gpu_x_dsw[1] ? -ii : ii);
            px = gpu_x_x + (gpu_x_dsw[2] ? -jj : jj);
         end
         pa  = (gpu_x_dbase + py * gpu_x_dpitch + px) & GPU_PA_MASK;
         ins = (px >= gpu_x_cx0) && (px <= gpu_x_cx1) && (py >= gpu_x_cy0) && (py <= gpu_x_cy1);
      end
   end
endtask

// Gradient source value of walk position k: fill + floor(i / N) * STEP
// RGB gradient channel: base + the whole part of the step count times the
// step (1/64 units, saturated to 14 bits signed), saturated to 0 .. max
function integer gpu_x_gch;
   input integer base;
   input integer q;
   input integer d;
   input integer max;
   integer       acc;
   integer       v;
   begin
      acc = q * d;
      if (acc > 8191)  acc = 8191;
      if (acc < -8192) acc = -8192;
      v = base + ((acc >= 0) ? (acc / 64) : -((-acc + 63) / 64));
      gpu_x_gch = (v < 0) ? 0 : (v > max) ? max : v;
   end
endfunction

function [31:0] gpu_x_gval;
   input integer k;
   integer       idx;
   integer       q;
   begin
      idx = gpu_x_gaxis ? (k % gpu_x_w) : (k / gpu_x_w);
      q   = idx / gpu_x_gn;
      if (gpu_x_grgb && (gpu_x_bl == 4))
         gpu_x_gval = (gpu_x_gch(gpu_x_fill[15:11], q, gpu_x_gdr, 31) << 11) |
                      (gpu_x_gch(gpu_x_fill[10:5],  q, gpu_x_gdg, 63) << 5)  |
                       gpu_x_gch(gpu_x_fill[4:0],   q, gpu_x_gdb, 31);
      else
         gpu_x_gval = gpu_x_fill + q * gpu_x_gstep;
   end
endfunction

function gpu_x_needs_src;
   input dummy;
   begin
      gpu_x_needs_src = (gpu_x_cmd != GPU_FILL) && !((gpu_x_cmd == GPU_COPY) && (gpu_x_op == 4'd2) && !gpu_x_blend);
   end
endfunction

function gpu_x_needs_dst;
   input dummy;
   begin
      gpu_x_needs_dst = (gpu_x_bl < 3) || gpu_x_blend ||
                        !((gpu_x_op == 4'd0) || (gpu_x_op == 4'd1) || (gpu_x_op >= 4'd13)) ||
                        gpu_x_rdst(gpu_x_op);
   end
endfunction

//----------------------------------------------------------------------------
// Palette remap and mask plane
//   remap: the colour S the raster op takes (source pixel, fill, EXPAND
//   colour, texel + SHADE) becomes T[S] (SRC) or T[D] (DST), T the byte table
//   at gpu_x_rbase (entry i at byte i, the low bpp bits used), after the
//   transparency decision; no effect at 16 bpp and for ops 2, 13-15.
//   mask plane (copies): a pixel is drawn where the 1-bpp mask at its source
//   pixel + K is 1 (0 with INV).
//   Reads: a one-word table cache and a one-word mask entry, empty at each
//   command start (gpu_r_nrd / gpu_m_nrd count them, gpu_exp_rd too).
//----------------------------------------------------------------------------
integer gpu_r_nrd = 0, gpu_m_nrd = 0;
integer gpu_m_rwa = 0, gpu_m_mwa = 0;
reg     gpu_m_rv = 1'b0, gpu_m_mv = 1'b0;

function gpu_x_rmp_on;                   // a lookup for the operation
   input [3:0] op;
   begin
      gpu_x_rmp_on = (gpu_x_rmp != 2'd0) && (gpu_x_bl < 4) &&
                     (op != 4'd2) && (op != 4'd13) && (op != 4'd14) && (op != 4'd15);
   end
endfunction

function gpu_x_rdst;                     // ... of the destination pixel
   input [3:0] op;
   begin
      gpu_x_rdst = gpu_x_rmp_on(op) && (gpu_x_rmp == 2'd2);
   end
endfunction

task gpu_aux_begin;
   begin
      gpu_m_rv = 1'b0;
      gpu_m_mv = 1'b0;
      gpu_d9_begin;
   end
endtask

// T[idx] (the low bpp bits), with its read
task gpu_rmp_lookup;
   input  [31:0] idx;
   output [31:0] val;
   reg    [31:0] wa;
   begin
      wa  = gpu_x_rbase + ((idx & 32'hFF) >> 2);
      if (!gpu_m_rv || (gpu_m_rwa != wa)) begin
         gpu_r_nrd  = gpu_r_nrd + 1;
         gpu_exp_rd = gpu_exp_rd + 1;
         gpu_m_rv   = 1'b1;
         gpu_m_rwa  = wa;
      end
      gpu_alw_mark(wa << 5, 0);
      gpu_d9_aux(wa);
      if (wa >= VRAM_WORDS) begin
         $display("ERROR: GPU model -- remap table word 0x%h outside VRAM (test bug) %t", wa, $time);
         error = error + 1;
         val = 32'h0;
      end else
         val = (gpu_shadow[wa] >> (8 * (idx & 3))) & gpu_pmask(gpu_x_bl);
   end
endtask

// The mask bit of source pixel spa (1: drawn), with its read
task gpu_msk_bit;
   input  [31:0] spa;
   output        bit_o;
   reg    [31:0] mpa, wa;
   begin
      mpa = (spa + gpu_x_k) & GPU_PA_MASK;
      wa  = mpa >> 5;
      if (!gpu_m_mv || (gpu_m_mwa != wa)) begin
         gpu_m_nrd  = gpu_m_nrd + 1;
         gpu_exp_rd = gpu_exp_rd + 1;
         gpu_m_mv   = 1'b1;
         gpu_m_mwa  = wa;
      end
      gpu_alw_mark(mpa, 0);
      gpu_d9_aux(wa);
      if (wa >= VRAM_WORDS) begin
         $display("ERROR: GPU model -- mask word 0x%h outside VRAM (test bug) %t", wa, $time);
         error = error + 1;
         bit_o = 1'b0;
      end else
         bit_o = gpu_shadow[wa][mpa & 31] ^ gpu_x_minv;
   end
endtask

// A mask or table word of a command must not be one of its destination
// words (the test is wrong otherwise)
reg     gpu_d9_d [0:VRAM_WORDS-1];
reg     gpu_d9_a [0:VRAM_WORDS-1];
integer gpu_d9_dl [0:4095];
integer gpu_d9_al [0:1023];
integer gpu_d9_nd = 0, gpu_d9_na = 0, gpu_d9_bad = 0;
reg     gpu_d9_on = 1'b0;
integer gpu_d9_i;
initial
   for (gpu_d9_i = 0; gpu_d9_i < VRAM_WORDS; gpu_d9_i = gpu_d9_i + 1) begin
      gpu_d9_d[gpu_d9_i] = 1'b0;
      gpu_d9_a[gpu_d9_i] = 1'b0;
   end

task gpu_d9_begin;
   integer ii;
   begin
      if ((gpu_d9_nd > 4096) || (gpu_d9_na > 1024))
         for (ii = 0; ii < VRAM_WORDS; ii = ii + 1) begin
            gpu_d9_d[ii] = 1'b0;
            gpu_d9_a[ii] = 1'b0;
         end
      else begin
         for (ii = 0; ii < gpu_d9_nd; ii = ii + 1) gpu_d9_d[gpu_d9_dl[ii]] = 1'b0;
         for (ii = 0; ii < gpu_d9_na; ii = ii + 1) gpu_d9_a[gpu_d9_al[ii]] = 1'b0;
      end
      gpu_d9_nd = 0;
      gpu_d9_na = 0;
   end
endtask

task gpu_d9_hit;
   input [31:0] wa;
   begin
      gpu_d9_bad = gpu_d9_bad + 1;
      if (gpu_d9_bad <= 4)
         $display("ERROR: GPU model -- word 0x%h is a mask / table word and a destination word of the same command (test bug) %t",
                  wa, $time);
      error = error + 1;
   end
endtask

task gpu_d9_aux;
   input [31:0] wa;
   begin
      if (gpu_d9_on && (wa < VRAM_WORDS)) begin
         if (!gpu_d9_a[wa]) begin
            if (gpu_d9_d[wa]) gpu_d9_hit(wa);
            gpu_d9_a[wa] = 1'b1;
            if (gpu_d9_na < 1024) gpu_d9_al[gpu_d9_na] = wa;
            gpu_d9_na = gpu_d9_na + 1;
         end
      end
   end
endtask

task gpu_d9_dst;
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wa;
   begin
      wa = pa >> (5 - bl);
      if (gpu_d9_on && (wa < VRAM_WORDS)) begin
         if (!gpu_d9_d[wa]) begin
            if (gpu_d9_a[wa]) gpu_d9_hit(wa);
            gpu_d9_d[wa] = 1'b1;
            if (gpu_d9_nd < 4096) gpu_d9_dl[gpu_d9_nd] = wa;
            gpu_d9_nd = gpu_d9_nd + 1;
         end
      end
   end
endtask

// Access accounting of the pixel engine: a one-word source cache and a
// one-word destination buffer (read when the destination is needed, written
// once with every pixel it took). A FILL along rows (no CL swap, no gradient
// along the run) takes the pixels of a run in one word together: the
// destination is read only when they do not cover whole bytes or the
// operation uses D. Exact when the source and destination words do not
// overlap.
integer gpu_m_cwa, gpu_m_wwa, gpu_m_swa, gpu_m_srow;
reg     gpu_m_cv, gpu_m_wv, gpu_m_wd, gpu_m_sv;
reg  [31:0] gpu_m_smask;
initial begin
   gpu_m_cv = 1'b0; gpu_m_wv = 1'b0; gpu_m_wd = 1'b0; gpu_m_sv = 1'b0;
   gpu_m_cwa = 0; gpu_m_wwa = 0; gpu_m_swa = 0; gpu_m_srow = 0; gpu_m_smask = 32'h0;
end

task gpu_acc_begin;
   begin
      gpu_m_cv = 1'b0;
      gpu_m_wv = 1'b0;
      gpu_m_wd = 1'b0;
      gpu_m_sv = 1'b0;
      gpu_m_tv = 1'b0;
      gpu_m_wl = 1'b0;
   end
endtask

function gpu_x_wfill;                    // FILL tokens take whole words
   input dummy;
   begin
      gpu_x_wfill = (gpu_x_cmd == GPU_FILL) && !gpu_x_dsw[0] && !(gpu_x_gen && gpu_x_gaxis) &&
                    !gpu_x_rmp_on(gpu_x_op) && !gpu_x_blend;
   end
endfunction

function gpu_bytes_whole;
   input [31:0] m;
   integer      bb;
   begin
      gpu_bytes_whole = 1'b1;
      for (bb = 0; bb < 4; bb = bb + 1)
         if ((m[8*bb +: 8] != 8'h00) && (m[8*bb +: 8] != 8'hFF)) gpu_bytes_whole = 1'b0;
   end
endfunction

task gpu_acc_seg_close;
   begin
      if (gpu_m_sv)
         gpu_acc_dst(gpu_m_swa, !((gpu_x_op == 4'd0) || (gpu_x_op == 4'd1) || (gpu_x_op >= 4'd13)) ||
                                ((gpu_x_bl < 3) && !gpu_bytes_whole(gpu_m_smask)));
      gpu_m_sv = 1'b0;
   end
endtask

task gpu_acc_seg;
   input integer wa;
   input integer row;
   input [31:0]  pmask;
   begin
      if (!gpu_m_sv || (gpu_m_swa != wa) || (gpu_m_srow != row)) begin
         gpu_acc_seg_close;
         gpu_m_sv    = 1'b1;
         gpu_m_swa   = wa;
         gpu_m_srow  = row;
         gpu_m_smask = 32'h0;
      end
      gpu_m_smask = gpu_m_smask | pmask;
   end
endtask

task gpu_acc_src;
   input integer wa;
   begin
      if (!gpu_m_cv || (gpu_m_cwa != wa)) begin
         gpu_exp_rd = gpu_exp_rd + 1;
         gpu_m_cv   = 1'b1;
         gpu_m_cwa  = wa;
      end
   end
endtask

task gpu_acc_dst;
   input integer wa;
   input         nd;                                  // the destination is read
   begin
      if (!gpu_m_wv || (gpu_m_wwa != wa)) begin
         if (gpu_m_wd) gpu_exp_wr = gpu_exp_wr + 1;
         if (nd)       begin gpu_exp_rd = gpu_exp_rd + 1; gpu_exp_drd = gpu_exp_drd + 1; end
         gpu_m_wv  = 1'b1;
         gpu_m_wwa = wa;
      end
      gpu_m_wd = 1'b1;
   end
endtask

// Word-token COPY: a COPY / COPY_TRANSP token takes the pixels of its run
// up to the end of its destination word and of its source word (its source
// limit dropped when no source is read, COPY op 2), so each token reads one
// source word and merges into one destination word. A token is one pixel with
// a CL swap on either side, with blending, and when its source word is its
// destination word with the source behind the destination along the walk
// (the "overlap rule": the image stays the one of a pixel-by-pixel copy);
// below level 2 for a keyed copy (COPY_TRANSP, ops 13-15), below level 3 for
// a mirror (X swaps differ). The destination is read for a token when the
// operation uses D, when its pixels do not cover whole bytes, or below 8 bpp
// for a keyed copy; a token whose pixels are all transparent writes nothing.
// The image model is unchanged (pixel by pixel in walk order).
// GPU_WCOPY_LVL: what the RTL implements (0 = one pixel per COPY token, 1 =
// word tokens without key or mirror, 2 = + key, 3 = + mirror). The access
// accounting as a whole (gpu_exp_rd / gpu_exp_wr, the one-word caches, the
// tokens) follows the RTL's micro-architecture: the tests compare it as a
// regression lock, not as spec evidence; the image model is the spec.
localparam integer GPU_WCOPY_LVL = 3;
integer gpu_wcopy = GPU_WCOPY_LVL;     // the accounting used (a test may force 0)
integer gpu_m_tdwa, gpu_m_tswa, gpu_m_trow, gpu_m_tmwa;
reg     gpu_m_tv, gpu_m_tany, gpu_m_tone, gpu_m_wl;
reg     gpu_m_tnd = 1'b1;                  // the A8 pixel needs the destination (gpu_a8_nod) ...
reg     gpu_m_ttnd = 1'b1;                 // ... of the open token
reg  [31:0] gpu_m_tmask;
initial begin
   gpu_m_tv = 1'b0; gpu_m_tany = 1'b0; gpu_m_tone = 1'b0; gpu_m_wl = 1'b0;
   gpu_m_tdwa = 0; gpu_m_tswa = 0; gpu_m_trow = 0; gpu_m_tmask = 32'h0;
end

function gpu_x_keyed;                    // pixels equal to SET_TRANSP are skipped
   input dummy;
   begin
      gpu_x_keyed = (gpu_x_cmd == GPU_COPYT) || (gpu_x_op >= 4'd13);
   end
endfunction

function gpu_x_wcopy;                    // the copy is modelled with word tokens
   input dummy;
   begin
      gpu_x_wcopy = (gpu_wcopy >= 1) && ((gpu_x_cmd == GPU_COPY) || (gpu_x_cmd == GPU_COPYT));
   end
endfunction

function gpu_x_wtok;                     // its tokens may take several pixels
   input dummy;
   begin
      gpu_x_wtok = gpu_x_wcopy(1'b0) && !gpu_x_dsw[0] && !gpu_x_ssw[0] && !gpu_x_rmp_on(gpu_x_op) && !gpu_x_blend &&
                   ((gpu_x_dsw[2] == gpu_x_ssw[2]) || (gpu_wcopy >= 3)) &&
                   (!gpu_x_keyed(1'b0) || (gpu_wcopy >= 2));
   end
endfunction

// The destination buffer takes a token's word (nd: the token reads it)
task gpu_acc_tok;
   input integer wa;
   input         nd;
   begin
      if (!(gpu_m_wv && (gpu_m_wwa == wa) && (gpu_m_wl || !nd))) begin
         if (gpu_m_wd) gpu_exp_wr = gpu_exp_wr + 1;
         if (nd)       begin gpu_exp_rd = gpu_exp_rd + 1; gpu_exp_drd = gpu_exp_drd + 1; end
         gpu_m_wv  = 1'b1;
         gpu_m_wwa = wa;
         gpu_m_wl  = nd;
      end
      gpu_m_wd = 1'b1;
   end
endtask

task gpu_acc_ctok_close;
   begin
      if (gpu_m_tv && gpu_m_tany)
         gpu_acc_tok(gpu_m_tdwa, (gpu_x_a8 ? gpu_m_ttnd : gpu_x_blend) || (!gpu_x_a8 && !((gpu_x_op == 4'd0) || (gpu_x_op == 4'd1) || (gpu_x_op >= 4'd13))) ||
                                 ((gpu_x_bl < 3) && (gpu_x_keyed(1'b0) || gpu_x_mpl || !gpu_bytes_whole(gpu_m_tmask))) ||
                                 gpu_x_rdst(gpu_x_op));
      gpu_m_tv = 1'b0;
   end
endtask

// One pixel of a word-token copy (walk order): it joins the open token when it lies in
// the same run, destination word, (a source read) source word and (the mask
// plane) mask word
task gpu_acc_ctok;
   input integer k;
   input  [31:0] dpa;
   input  [31:0] spa;
   input         nsrc;
   input         thit;                   // transparent or masked: not written
   integer       dwa, swa, row, ds, ss, mwa;
   reg           one;
   begin
      dwa = dpa >> (5 - gpu_x_bl);
      swa = nsrc ? (spa >> (5 - gpu_x_bl)) : 0;
      mwa = gpu_x_mpl ? (((spa + gpu_x_k) & GPU_PA_MASK) >> 5) : 0;
      row = k / gpu_x_w;
      if (!gpu_m_tv || gpu_m_tone || (gpu_m_tdwa != dwa) || (gpu_m_trow != row) ||
          (nsrc && (gpu_m_tswa != swa)) || (gpu_x_mpl && (gpu_m_tmwa != mwa))) begin
         gpu_acc_ctok_close;
         ds  = dpa % (32 >> gpu_x_bl);
         ss  = nsrc ? (spa % (32 >> gpu_x_bl)) : 0;
         // overlap rule, at the token's first pixel
         one = !gpu_x_wtok(1'b0) ||
               (nsrc && !gpu_x_imm && (swa == dwa) && ((gpu_x_dsw[2] != gpu_x_ssw[2]) ||
                                         (!gpu_x_dsw[2] && (ss < ds)) || (gpu_x_dsw[2] && (ss > ds))));
         gpu_m_tv    = 1'b1;
         gpu_m_tone  = one;
         gpu_m_tdwa  = dwa;
         gpu_m_tswa  = swa;
         gpu_m_tmwa  = mwa;
         gpu_m_trow  = row;
         gpu_m_tmask = 32'h0;
         gpu_m_tany  = 1'b0;
         gpu_m_ttnd  = gpu_m_tnd;
      end
      gpu_m_tmask = gpu_m_tmask | (gpu_pmask(gpu_x_bl) << ((dpa % (32 >> gpu_x_bl)) << gpu_x_bl));
      if (!thit) gpu_m_tany = 1'b1;
   end
endtask

task gpu_acc_end;
   begin
      gpu_acc_ctok_close;
      gpu_acc_seg_close;
      if (gpu_m_wd) gpu_exp_wr = gpu_exp_wr + 1;
      gpu_m_wd = 1'b0;
      gpu_m_wv = 1'b0;
      gpu_m_cv = 1'b0;
   end
endtask

// Apply pixel k of the current context to the shadow
task gpu_px_step;
   input integer k;
   reg    [31:0] pm, spa, dpa, ss, dd, rr;
   reg           tchk, thit, nsrc, ins, mbit, bskip, aoob;
   reg     [7:0] ab;
   integer       af;
   begin
      pm   = gpu_pmask(gpu_x_bl);
      af   = gpu_x_alpha;
      bskip = gpu_x_blend && (gpu_x_alpha == 0);         // alpha 0: nothing written
      gpu_x_pos(k, dpa, ins);
      nsrc = gpu_x_needs_src(1'b0);
      if (!ins)
         gpu_exp_clip = gpu_exp_clip + 1;
      else begin
         spa  = gpu_walk(gpu_x_sbase, gpu_x_spitch, gpu_x_ssw, gpu_x_w, k);
         mbit = 1'b1;
         gpu_d9_dst(dpa, gpu_x_bl);
         if (gpu_x_mpl) gpu_msk_bit(spa, mbit);          // (the mask follows the source walk)
         if (gpu_x_cmd == GPU_FILL)
            ss = (gpu_x_gen ? gpu_x_gval(k) : gpu_x_fill) & pm;
         else if (nsrc) begin
            ss  = gpu_src_px(spa, gpu_x_bl);
            if (!gpu_x_imm) gpu_alw_mark(spa, gpu_x_bl);
         end else
            ss  = 32'h0;
         if (nsrc && !gpu_x_imm) gpu_acc_src(spa >> (5 - gpu_x_bl));
         tchk = (gpu_x_cmd == GPU_COPYT) || (gpu_x_op >= 4'd13);
         thit = tchk && (ss == (gpu_x_transp & pm));
         if (gpu_x_a8) begin                             // RGB565A8: the key first, then the alpha
            gpu_a8_byte(spa, ab, aoob);
            af        = gpu_a8_fac(ab);
            bskip     = aoob || (af == 0);
            gpu_m_tnd = !gpu_a8_nod(ab);
            if (!thit && !aoob) begin
               if (af == 0)      gpu_a8_nskip = gpu_a8_nskip + 1;
               else if (!gpu_m_tnd) gpu_a8_nnd = gpu_a8_nnd + 1;
            end
         end
         gpu_touch_px(dpa, gpu_x_bl);
         gpu_alw_mark(dpa, gpu_x_bl);
         if (gpu_x_wcopy(1'b0)) gpu_acc_ctok(k, dpa, spa, nsrc, thit || !mbit || bskip);
         if (thit || !mbit || bskip) begin
            if (thit) gpu_exp_transp = gpu_exp_transp + 1;
            gpu_rec_px(dpa, 1'b0, 32'h0);
         end else begin
            dd = gpu_get_px(dpa, gpu_x_bl);
            // the remap: after the transparency decision
            if (gpu_x_rmp_on(gpu_x_op)) gpu_rmp_lookup(gpu_x_rdst(gpu_x_op) ? dd : ss, ss);
            case (gpu_x_op)
              4'd0:  rr = ss;
              4'd1:  rr = ~ss;
              4'd2:  rr = ~dd;
              4'd3:  rr = ss & dd;
              4'd4:  rr = ss | dd;
              4'd5:  rr = ss ^ dd;
              4'd6:  rr = ~(ss & dd);
              4'd7:  rr = ~(ss | dd);
              4'd8:  rr = ~(ss ^ dd);
              4'd9:  rr = ~ss & dd;
              4'd10: rr = ss & ~dd;
              4'd11: rr = ~ss | dd;
              4'd12: rr = ss | ~dd;
              4'd13: rr = 32'h0;
              4'd14: rr = 32'hFFFF_FFFF;
              default: rr = (gpu_x_cmd == GPU_FILL) ? ss : gpu_x_fill;   // a FILL's colour: the ramp
            endcase
            // blending: S (ops 0-12, their logic with D not applied) or the
            // constant of ops 13-15, over D
            if (gpu_x_blend) rr = gpu_blend_px((gpu_x_op >= 4'd13) ? rr : ss, dd, af);
            gpu_rec_px(dpa, 1'b1, rr);
            gpu_set_px(dpa, gpu_x_bl, rr & pm);
            if (gpu_x_wcopy(1'b0))
               ;                                                  // gpu_acc_ctok above
            else if (gpu_x_a8)
               gpu_acc_tok(dpa >> (5 - gpu_x_bl), gpu_m_tnd);
            else if (gpu_x_wfill(1'b0))
               gpu_acc_seg(dpa >> (5 - gpu_x_bl), k / gpu_x_w,
                           gpu_pmask(gpu_x_bl) << ((dpa % (32 >> gpu_x_bl)) << gpu_x_bl));
            else
               gpu_acc_dst(dpa >> (5 - gpu_x_bl), gpu_x_needs_dst(1'b0));
         end
      end
   end
endtask

task gpu_x_run;
   integer kk;
   begin
      gpu_acc_begin;
      gpu_d9_on = gpu_x_mpl || gpu_x_a8 || gpu_x_rmp_on(gpu_x_op);
      gpu_aux_begin;
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1)
         gpu_px_step(kk);
      gpu_acc_end;
      gpu_d9_on = 1'b0;
   end
endtask

// Mark the destination words of the current context (no model update)
task gpu_x_touch_dst;
   integer      kk;
   reg   [31:0] pa;
   reg          ins;
   begin
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         gpu_x_pos(kk, pa, ins);
         if (ins) gpu_touch_px(pa, gpu_x_bl);
      end
   end
endtask

// After an abandoned rectangle: restore the snapshot and find the smallest
// pixel count n whose model image equals VRAM on every touched word.
// Returns -1 when no prefix matches.
integer gpu_fp_list [0:4095];             // the touched words (gpu_find_prefix)
task gpu_find_prefix;
   output integer nfound;
   integer        kk, ww, ok, ntot, nl;
   begin
      gpu_restore;
      gpu_x_touch_dst;
      nl = 0;
      for (ww = 0; ww < VRAM_WORDS; ww = ww + 1)
         if (gpu_touch[ww]) begin
            if (nl < 4096) gpu_fp_list[nl] = ww;
            nl = nl + 1;
         end
      ntot   = gpu_x_w * gpu_x_h;
      nfound = -1;
      gpu_aux_begin;
      for (kk = 0; (kk <= ntot) && (nfound < 0); kk = kk + 1) begin
         if (kk > 0) gpu_px_step(kk - 1);
         ok = 1;
         if (nl <= 4096) begin
            for (ww = 0; (ww < nl) && ok; ww = ww + 1)
               if (vram_mem[gpu_fp_list[ww]] !== gpu_shadow[gpu_fp_list[ww]]) ok = 0;
         end else
            for (ww = 0; (ww < VRAM_WORDS) && ok; ww = ww + 1)
               if (gpu_touch[ww] && (vram_mem[ww] !== gpu_shadow[ww])) ok = 0;
         if (ok) nfound = kk;
      end
      if (nfound < 0) gpu_restore;
   end
endtask


//============================================================================
// Command tasks: push to GPU_CMD and update the model
//============================================================================
// gpu_push_wait = 1: wait for FREE != 0 first (no overflow when queueing)
// gpu_cap_en = 1: the words are appended to gpu_cap_buf instead (command lists
// for CALL; the model tasks update the model as usual)
localparam integer GPU_CAP_MAX = 4096;
reg                gpu_push_wait;
reg                gpu_cap_en;
integer            gpu_cap_n;
reg         [31:0] gpu_cap_buf [0:GPU_CAP_MAX-1];
initial begin gpu_push_wait = 1'b0; gpu_cap_en = 1'b0; gpu_cap_n = 0; end

// gpu_push only posts the word: one process pushes it, so a call site stays small
reg                gp_req = 1'b0;
reg                gp_ack = 1'b0;
reg         [31:0] gp_word;

task gpu_push;
   input [31:0] word;
   begin
      gp_word = word;
      gp_req  = ~gp_req;
      wait (gp_ack === gp_req);
   end
endtask

reg         [31:0] gp_st;
always begin
   wait (gp_req !== gp_ack);
   if (gpu_cap_en) begin
      if (gpu_cap_n < GPU_CAP_MAX)
         gpu_cap_buf[gpu_cap_n] = gp_word;
      else begin
         $display("ERROR: GPU model -- command list capture overflow (test bug) %t", $time);
         error = error + 1;
      end
      gpu_cap_n = gpu_cap_n + 1;
   end else begin
      if (gpu_push_wait) begin
         gp_st = 32'h0;
         while ((gp_st & 32'hFF) == 0) reg_rd_val(GPU_STAT, gp_st);
      end
      reg_wr(GPU_CMD, gp_word);
   end
   gp_ack = gp_req;
end

task gpu_set_mode;                       // CTRL: GPU_EN + GFX_MODE
   input [2:0] mode;
   begin
      reg_wr(CTRL, 32'h10 | mode);
      gpu_m_mode = mode;
   end
endtask

task gpu_set_dispw;
   input integer w;
   begin
      reg_wr(DISP_SIZE, 32'h0001_0000 | (w & ((1 << DIM_W) - 1)));
      gpu_m_dispw = ((w & ((1 << DIM_W) - 1)) == 0) ? 1 : (w & ((1 << DIM_W) - 1));
   end
endtask

task gpu_c_src;
   input [15:0] pitch;
   input [31:0] base;
   begin
      if (gpu_flush_hint && gpu_flush_resend) gpu_m_src_fmt = 4'h0;   // re-sent below with 0
      gpu_flush_hint = 1'b0;
      gpu_push({OP_SET_SRC, 8'h00, gpu_m_src_fmt, pitch});
      gpu_push(base);
      gpu_k_imm       = 1'b0;                            // (a SET_SRC without IMM disarms)
      gpu_m_src_pitch = pitch;
      gpu_m_src_base  = base & GPU_PA_MASK;
   end
endtask

// SET_SRC with an explicit SRC_FMT (self-contained command sequences)
task gpu_c_src_fmt;
   input [15:0] pitch;
   input [31:0] base;
   input  [3:0] fmt;
   begin
      gpu_flush_hint = 1'b0;
      gpu_m_src_fmt  = fmt;
      gpu_c_src(pitch, base);
   end
endtask

// Re-send SET_SRC when the next command needs another SRC_FMT (EXPAND: the
// source depth + 1; copies and textures: 0)
task gpu_src_fmt;
   input [3:0] fmt;
   begin
      if (gpu_flush_hint && gpu_flush_resend) gpu_m_src_fmt = 4'hF;   // unknown: re-send
      gpu_flush_hint = 1'b0;
      if (gpu_m_src_fmt != fmt) begin
         gpu_m_src_fmt = fmt;
         gpu_push({OP_SET_SRC, 8'h00, fmt, gpu_m_src_pitch});
         gpu_push(gpu_m_src_base);
         gpu_k_imm = 1'b0;
      end
   end
endtask

task gpu_c_dst;
   input [15:0] pitch;
   input [31:0] base;
   begin
      gpu_push({OP_SET_DST, 12'h000, pitch});
      gpu_push(base);
      gpu_m_dst_pitch = pitch;
      gpu_m_dst_base  = base & GPU_PA_MASK;
      gpu_m_dst_org   = base & GPU_PA_MASK;
      gpu_m_xy        = 1'b0;
      gpu_m_x         = 0;                  // every SET_DST operand: position (0, 0)
      gpu_m_y         = 0;                  // and the x/y line pitch (pitch 0: the frame width)
      gpu_m_xyp       = (pitch == 16'h0) ? gpu_m_dispw : pitch;
   end
endtask

task gpu_c_size;
   input [13:0] w;
   input [13:0] h;
   begin
      gpu_push({OP_SET_SIZE, h, w});
      gpu_m_w = ((w & GPU_DIM_MASK) == 0) ? 1 : (w & GPU_DIM_MASK);
      gpu_m_h = ((h & GPU_DIM_MASK) == 0) ? 1 : (h & GPU_DIM_MASK);
   end
endtask

task gpu_c_fill;
   input [31:0] color;
   begin
      gpu_push({OP_SET_FILL, 28'h0});
      gpu_push(color);
      gpu_m_fill = color[15:0];
   end
endtask

task gpu_c_transp;
   input [31:0] color;
   begin
      gpu_push({OP_SET_TRANSP, 28'h0});
      gpu_push(color);
      gpu_m_transp = color[15:0];
   end
endtask

function [31:0] gpu_exec_word;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;                     // {X, Y, CL}
   input  [2:0] ssw;
   begin
      gpu_exec_word = {cmd, 17'h0, ssw, 1'b0, dsw, op};
   end
endfunction

// The REMAP / MPLANE fields of the next EXEC (gpu_k_rmp, gpu_k_mpl)
function [31:0] gpu_exec_aux;
   input  [3:0] cmd;
   begin
      gpu_exec_aux = {18'h0, gpu_k_rmp, (cmd != GPU_FILL) & gpu_k_mpl, 11'h000};
   end
endfunction

task gpu_x_aux;                          // the context takes them
   input  [3:0] cmd;
   begin
      gpu_x_rmp = gpu_k_rmp;
      gpu_x_mpl = (cmd != GPU_FILL) && gpu_k_mpl;
   end
endtask

// SET_AUX REMAP_TABLE (the table's word address: its low 6 bits ignored)
task gpu_c_remap_table;
   input [31:0] wa;
   reg   [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, EXT_SET_AUX, 4'd0, 20'h00000}, 32'h000F_FFFF, cw);   // [19:0] ignored
      gpu_push(cw);
      gpu_push(wa);
      gpu_m_rbase = (VRAM_AW > 6) ? (wa & ((32'h1 << VRAM_AW) - 32'h1) & ~32'h3F) : 32'h0;
   end
endtask

// SET_AUX MASK_PLANE (the 1-bpp pixel address of the source's first pixel's mask bit)
task gpu_c_mask_plane;
   input [31:0] pa;
   input        inv;
   reg   [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, EXT_SET_AUX, 4'd1, 3'b000, inv, 16'h0000}, 32'h000E_0000, cw);   // [19:17] ignored
      gpu_push(cw);
      gpu_push(pa);
      gpu_m_mbase = pa & GPU_PA_MASK;
      gpu_m_minv  = inv;
   end
endtask

// SET_ALPHA (SET_EXT sub 8): [7:0] A, [8] EN, [9] MIX5 (0 here); no operand
task gpu_c_alpha;
   input       en;
   input [7:0] a;
   begin
      gpu_c_alpha5(en, a, 1'b0);
   end
endtask

// SET_ALPHA with the blend rule MIX5 ([23:10] ignored: random with gpu_rsv_en)
task gpu_c_alpha5;
   input       en;
   input [7:0] a;
   input       mix5;
   reg  [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, 4'h8, 14'h0000, mix5, en, a}, 32'h00FF_FC00, cw);
      gpu_push(cw);
      gpu_m_aen  = en;
      gpu_m_a    = a;
      gpu_m_mix5 = mix5;
   end
endtask

// SET_AUX ALPHA_PLANE (SEL 4, PITCH 0): the byte address of the alpha of the
// SET_SRC base pixel ([19:16] ignored; operand bits above VRAM_AW + 1 ignored)
task gpu_c_alpha_plane;
   input [31:0] ba;
   reg   [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, EXT_SET_AUX, 4'd4, 20'h00000}, 32'h000F_0000, cw);
      gpu_push(cw);
      gpu_push(ba);
      gpu_m_abase = ba & ((32'h1 << (VRAM_AW + 2)) - 32'h1);
   end
endtask

// SET_AUX TEX_FILTER (SEL 5): [0] BILINEAR, [1] TBORDER ([19:2] ignored), the
// operand ignored (random)
task gpu_c_tex_filter;
   input bil;
   input tbord;
   reg   [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, EXT_SET_AUX, 4'd5, 18'h00000, tbord, bil}, 32'h000F_FFFC, cw);
      gpu_push(cw);
      gpu_push(gpu_rsv_en ? $random(gpu_rsv_seed) : 32'h0);
      gpu_m_bil   = bil;
      gpu_m_tbord = tbord;
   end
endtask

// OR random values into the reserved / ignored bits m of command word w
// (gpu_rsv_en; own seed, so the stimulus of the test is unchanged)
task gpu_rsv_or;
   input  [31:0] w;
   input  [31:0] m;
   output [31:0] o;
   reg    [31:0] r;
   begin
      o = w;
      if (gpu_rsv_en) begin
         r = $random(gpu_rsv_seed);
         o = w | (r & m);
         if ((r & m) != 32'h0) gpu_rsv_n = gpu_rsv_n + 1;
      end
   end
endtask

// A flush of an idle GPU, with the model update (kind 0: CLEAR_ERR, 1: ABORT,
// 2: GPU_EN 0 then 1, 3: CLEAR_ERR and ABORT together): every setting is
// kept, the immediate source is disarmed. With words still queued the model
// has already taken them: flush an idle GPU (gpu_wait_idle) or model the
// discarded part in the test.
task gpu_flush;
   input integer kind;
   begin
      case (kind)
        0:       reg_wr(GPU_CTRL, 32'h1);
        1:       reg_wr(GPU_CTRL, 32'h2);
        3:       reg_wr(GPU_CTRL, 32'h3);
        default: begin
                    reg_wr(CTRL, {29'h0, gpu_m_mode});
                    reg_wr(CTRL, 32'h10 | gpu_m_mode);
                 end
      endcase
      gpu_k_imm = 1'b0;
      gpu_m_lph = 0;                                        // the line pattern phase: stream state
      if (!gpu_flush_resend) gpu_flush_hint = 1'b0;
   end
endtask

// Push an EXEC and model it with the current state
task gpu_c_exec;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   reg   [31:0] ew;
   begin
      if (cmd != GPU_FILL) gpu_src_fmt(gpu_k_a8 ? 4'h5 : 4'h0);
      gpu_rsv_or(gpu_exec_word(cmd, op, dsw, ssw) | gpu_exec_aux(cmd), (cmd != GPU_FILL) ? 32'h80 : 32'h0, ew);
      gpu_push(ew);                                       // copies: [7] ignored
      gpu_d_exec(cmd, op, dsw, ssw);
      gpu_imm_push;
   end
endtask

// Model of a decoded EXEC_FILL / COPY / COPY_TRANSP rectangle (REMAP, MPLANE:
// gpu_k_rmp, gpu_k_mpl; the immediate source: gpu_k_imm)
task gpu_d_exec;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   begin
      gpu_x_setup(cmd, op, dsw, ssw);
      gpu_x_aux(cmd);
      if (cmd != GPU_FILL) begin gpu_x_take_imm; gpu_x_take_a8; end
      gpu_x_gen = gpu_m_gen && (cmd == GPU_FILL);
      gpu_x_run;
   end
endtask

task gpu_c_fence;
   input irq;
   begin
      gpu_m_fence = gpu_m_fence + 24'd1;
      gpu_push({OP_FENCE, 3'b000, irq, gpu_m_fence});
   end
endtask

// FENCE AUTO: GPU_FENCE + 1 (the tag field is ignored: random here)
task gpu_c_fence_auto;
   input irq;
   reg [23:0] junk;
   begin
      gpu_m_fence = gpu_m_fence + 24'd1;
      junk        = $random(gpu_seed);
      gpu_push({OP_FENCE, 2'b00, 1'b1, irq, junk});
   end
endtask

// SET_SRC IMM: SRC_FMT fmt, the pitch kept (unused), operand N; arms the next
// copy / EXPAND with gpu_imm_buf[0..n-1] (pushed after its EXEC)
task gpu_c_imm;
   input  [3:0] fmt;
   input integer n;
   reg   [31:0] imm_w;
   begin
      gpu_flush_hint = 1'b0;
      gpu_m_src_fmt  = fmt;
      gpu_push({OP_SET_SRC, 7'h00, 1'b1, fmt, gpu_m_src_pitch});
      gpu_rsv_or(n, 32'hFF00_0000, imm_w);                                   // [31:24] ignored
      gpu_push(imm_w);
      gpu_imm_n = n;
      gpu_k_imm = 1'b1;
   end
endtask

task gpu_wait_idle;
   begin
      reg_poll(GPU_STAT, GS_BUSY, 32'h0, 200000);
   end
endtask

// SET_EXT2 WAIT_REFR_DONE: the commands after it wait for the end of a frame
task gpu_c_wait_refr;
   reg [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, EXT_SET_EXT2, X2_WAIT_REFR, 16'h0000}, 32'h0000_FFFF, cw);   // [15:0] ignored
      gpu_push(cw);
   end
endtask


// Freeze control (DBG_CTRL[1] & dbg_stoptime)
task gpu_freeze;
   input on;
   begin
      reg_wr(DBG_CTRL, on ? 32'h2 : 32'h0);
      @(negedge free_clk);
      dbg_stoptime = on;
   end
endtask


//============================================================================
// Walk record (abandon prefix): per pixel of one EXEC, in walk order, the
// pixel address, the value before and the value written (wr = 0: skipped).
// Clipped and out-of-box pixels are not recorded.
//============================================================================
localparam integer GPU_REC_MAX = 1024;
reg         [31:0] gpu_rec_pa  [0:GPU_REC_MAX-1];
reg         [31:0] gpu_rec_old [0:GPU_REC_MAX-1];
reg         [31:0] gpu_rec_new [0:GPU_REC_MAX-1];
reg                gpu_rec_wr  [0:GPU_REC_MAX-1];
integer            gpu_rec_n;
integer            gpu_rec_bl;
reg                gpu_rec_en;
initial begin gpu_rec_en = 1'b0; gpu_rec_n = 0; gpu_rec_bl = 0; end

task gpu_rec_begin;
   begin
      gpu_rec_n  = 0;
      gpu_rec_en = 1'b1;
   end
endtask

task gpu_rec_end;
   begin
      gpu_rec_en = 1'b0;
   end
endtask

task gpu_rec_px;
   input [31:0] pa;
   input        wr;
   input [31:0] val;
   begin
      if (gpu_be_en || gpu_be_mk) gpu_be_mark(pa, gpu_x_bl);
      if (gpu_rec_en) begin
         if (gpu_rec_n >= GPU_REC_MAX) begin
            $display("ERROR: GPU model -- walk record overflow (test bug) %t", $time);
            error = error + 1;
         end else begin
            gpu_rec_pa[gpu_rec_n]  = pa;
            gpu_rec_old[gpu_rec_n] = gpu_get_px(pa, gpu_x_bl);
            gpu_rec_new[gpu_rec_n] = val & gpu_pmask(gpu_x_bl);
            gpu_rec_wr[gpu_rec_n]  = wr;
            gpu_rec_bl             = gpu_x_bl;
         end
         gpu_rec_n = gpu_rec_n + 1;
      end
   end
endtask

function [31:0] gpu_vram_px;             // pixel of the VRAM model (backdoor)
   input [31:0] pa;
   input integer bl;
   reg   [31:0] wd;
   integer      off;
   begin
      wd  = pa >> (5 - bl);
      off = (pa & ((32 >> bl) - 1)) << bl;
      gpu_vram_px = (wd < VRAM_WORDS) ? ((vram_mem[wd] >> off) & gpu_pmask(bl)) : 32'hxxxx_xxxx;
   end
endfunction

// Classify the recorded walk against VRAM after an abandon (GPU settled).
// A pixel whose new value differs from its old one is drawn (VRAM = new) or
// undrawn (VRAM = old); the image is a prefix when every drawn index precedes
// every undrawn one. cls: 0 nothing drawn, 1 strict prefix, 2 whole walk,
// -1 not a prefix. The shadow is rebuilt from the old image plus the prefix
// (from VRAM after an error). done = GPU_DONE seen: only legal for cls 2.
task gpu_rec_prefix;
   input          done;
   output integer cls;
   output integer ndrawn;
   integer        kk, maxd, minu, nbad;
   reg     [31:0] got;
   begin
      maxd = -1;
      minu = gpu_rec_n;
      nbad = 0;
      for (kk = 0; kk < gpu_rec_n; kk = kk + 1) begin
         got = gpu_vram_px(gpu_rec_pa[kk], gpu_rec_bl);
         if (gpu_rec_wr[kk] && (gpu_rec_new[kk] != gpu_rec_old[kk])) begin
            if (got === gpu_rec_new[kk]) begin
               if (kk > maxd) maxd = kk;
            end else if (got === gpu_rec_old[kk]) begin
               if (kk < minu) minu = kk;
            end else begin
               nbad = nbad + 1;
               if (nbad <= 4)
                  $display("ERROR: abandoned walk pixel %0d (0x%h) = 0x%h, neither old 0x%h nor new 0x%h %t",
                           kk, gpu_rec_pa[kk], got, gpu_rec_old[kk], gpu_rec_new[kk], $time);
            end
         end else if (got !== gpu_rec_old[kk]) begin
            nbad = nbad + 1;
            if (nbad <= 4)
               $display("ERROR: abandoned walk pixel %0d (0x%h) = 0x%h, expected unchanged 0x%h %t",
                        kk, gpu_rec_pa[kk], got, gpu_rec_old[kk], $time);
         end
      end
      ndrawn = maxd + 1;
      if (nbad != 0) begin
         error = error + nbad;
         cls   = -1;
      end else if (maxd > minu) begin
         $display("ERROR: abandoned walk is not a prefix: pixel %0d drawn after undrawn pixel %0d (of %0d) %t",
                  maxd, minu, gpu_rec_n, $time);
         error = error + 1;
         cls   = -1;
      end else if (minu == gpu_rec_n)
         cls = 2;
      else if (maxd < 0)
         cls = 0;
      else
         cls = 1;
      if (done && (cls != 2)) begin
         $display("ERROR: GPU_DONE raised for an abandoned walk (%0d drawn, first undrawn %0d of %0d) %t",
                  ndrawn, minu, gpu_rec_n, $time);
         error = error + 1;
      end
      for (kk = gpu_rec_n - 1; kk >= 0; kk = kk - 1)
         gpu_set_px(gpu_rec_pa[kk], gpu_rec_bl, gpu_rec_old[kk]);
      if (cls < 0) begin
         for (kk = 0; kk < gpu_rec_n; kk = kk + 1)
            gpu_set_px(gpu_rec_pa[kk], gpu_rec_bl, gpu_vram_px(gpu_rec_pa[kk], gpu_rec_bl));
      end else
         for (kk = 0; kk < ndrawn; kk = kk + 1)
            if (gpu_rec_wr[kk]) gpu_set_px(gpu_rec_pa[kk], gpu_rec_bl, gpu_rec_new[kk]);
   end
endtask


//============================================================================
// Region guards of the new-kind models (test bugs): source / texel words in
// [gpu_rgn_slo, gpu_rgn_shi), destination words in [gpu_rgn_dlo, gpu_rgn_dhi)
//============================================================================
integer            gpu_rgn_slo, gpu_rgn_shi, gpu_rgn_dlo, gpu_rgn_dhi;
initial begin gpu_rgn_slo = 0; gpu_rgn_shi = VRAM_WORDS; gpu_rgn_dlo = 0; gpu_rgn_dhi = VRAM_WORDS; end

task gpu_rgn_src;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < gpu_rgn_slo) || (gpu_word_of(pa, bl) >= gpu_rgn_shi)) begin
         $display("ERROR: GPU model -- source pixel 0x%h outside the source region (test bug) %t", pa, $time);
         error = error + 1;
      end
   end
endtask

task gpu_rgn_dst;
   input [31:0] pa;
   input integer bl;
   begin
      if ((gpu_word_of(pa, bl) < gpu_rgn_dlo) || (gpu_word_of(pa, bl) >= gpu_rgn_dhi)) begin
         $display("ERROR: GPU model -- destination pixel 0x%h (word 0x%h, log2 bpp %0d) outside the destination region [0x%h, 0x%h) (test bug) %t",
                  pa, gpu_word_of(pa, bl), bl, gpu_rgn_dlo, gpu_rgn_dhi, $time);
         error = error + 1;
      end
   end
endtask


//============================================================================
// x/y destinations, clip window, gradient: command tasks
//============================================================================
function integer gpu_sx12;               // signed 12-bit field
   input [11:0] f;
   begin
      gpu_sx12 = f[11] ? ({20'h0, f} - 4096) : {20'h0, f};
   end
endfunction

function integer gpu_sx14;               // signed 14-bit field (DELTA)
   input [13:0] f;
   begin
      gpu_sx14 = f[13] ? ({18'h0, f} - 16384) : {18'h0, f};
   end
endfunction

function integer gpu_sx16;               // signed 16-bit field (5.11, 10.6)
   input [15:0] f;
   begin
      gpu_sx16 = f[15] ? ({16'h0, f} - 65536) : {16'h0, f};
   end
endfunction

// SET_DST with XY: origin = pixel (0, 0) of the surface, position (0, 0)
task gpu_c_dst_xy;
   input [15:0] pitch;
   input [31:0] origin;
   begin
      gpu_push({OP_SET_DST, 11'h000, 1'b1, pitch});
      gpu_push(origin);
      gpu_m_dst_pitch = pitch;
      gpu_m_dst_base  = origin & GPU_PA_MASK;
      gpu_m_dst_org   = origin & GPU_PA_MASK;
      gpu_m_xy        = 1'b1;
      gpu_m_x         = 0;
      gpu_m_y         = 0;
      gpu_m_xyp       = (pitch == 16'h0) ? gpu_m_dispw : pitch;
   end
endtask

// SET_XY: pitch 0 = the frame width at this point
task gpu_c_xy;
   input integer x;
   input integer y;
   reg    [11:0] xf, yf;
   begin
      xf = x;
      yf = y;
      gpu_push({OP_SET_EXT, EXT_SET_XY, yf, xf});
      gpu_m_x   = gpu_sx12(xf);
      gpu_m_y   = gpu_sx12(yf);
      gpu_m_xyp = (gpu_m_dst_pitch == 16'h0) ? gpu_m_dispw : gpu_m_dst_pitch;
   end
endtask

task gpu_c_clip;
   input integer x0;
   input integer y0;
   input integer x1;
   input integer y1;
   reg    [11:0] a, b, c, d;
   begin
      a = x0;
      b = y0;
      c = x1;
      d = y1;
      gpu_push({OP_SET_EXT, EXT_SET_CLIP, b, a});
      gpu_push({8'h00, d, c});
      gpu_m_cx0 = gpu_sx12(a);
      gpu_m_cy0 = gpu_sx12(b);
      gpu_m_cx1 = gpu_sx12(c);
      gpu_m_cy1 = gpu_sx12(d);
   end
endtask

task gpu_c_noclip;
   begin
      gpu_c_clip(-2048, -2048, 2047, 2047);
   end
endtask

task gpu_c_grad;
   input integer n;                      // pixels per step, 0..4095 (0 counts as 1)
   input         axis;                   // 0 per line of the walk, 1 per pixel along the run
   input integer step;                   // -8 .. +7
   input         en;
   reg    [11:0] nf;
   reg     [3:0] sf;
   begin
      nf = n;
      sf = step;
      gpu_push({OP_SET_EXT, EXT_SET_GRAD, 6'h00, en, sf, axis, nf});
      gpu_m_gn    = nf;
      gpu_m_gaxis = axis;
      gpu_m_gstep = sf[3] ? ({28'h0, sf} - 16) : {28'h0, sf};
      gpu_m_gen   = en;
      gpu_m_grgb  = 1'b0;
   end
endtask

// Per-channel gradient (16 bpp): SET_GRAD_RGB steps in 1/64 of a channel unit
// (-512 .. 511 each), then SET_GRAD with RGB
task gpu_c_grad_rgb;
   input integer n;
   input         axis;
   input integer dr;
   input integer dg;
   input integer db;
   input         en;
   reg    [11:0] nf;
   reg     [9:0] rf;
   reg     [9:0] gf;
   reg     [9:0] bf;
   begin
      nf = n;
      rf = dr;
      gf = dg;
      bf = db;
      gpu_push({OP_SET_EXT, EXT_SET_GRGB, 24'h0});
      gpu_push({2'b00, rf, gf, bf});
      gpu_push({OP_SET_EXT, EXT_SET_GRAD, 5'h00, 1'b1, en, 4'h0, axis, nf});
      gpu_m_gn    = nf;
      gpu_m_gaxis = axis;
      gpu_m_gstep = 0;
      gpu_m_gen   = en;
      gpu_m_grgb  = 1'b1;
      gpu_m_gdr   = rf[9] ? ({22'h0, rf} - 1024) : {22'h0, rf};
      gpu_m_gdg   = gf[9] ? ({22'h0, gf} - 1024) : {22'h0, gf};
      gpu_m_gdb   = bf[9] ? ({22'h0, bf} - 1024) : {22'h0, bf};
   end
endtask

// Destination move by DELTA: the x/y position and the address-mode base both
// move, whatever the mode (the one of the current mode is used); a cut
// SET_DST changing the mode shows the other
task gpu_m_move;
   input [13:0] d14;
   begin
      gpu_m_x        = gpu_sx16(gpu_m_x + gpu_sx14(d14));     // (16-bit position)
      gpu_m_dst_base = (gpu_m_dst_base + gpu_sx14(d14)) & GPU_PA_MASK;
   end
endtask

// EXEC_SPAN: move, width x 1, FILL op 0, no swaps (gradient applies)
task gpu_c_span;
   input integer delta;
   input  [13:0] width;
   reg    [13:0] d14;
   begin
      d14 = delta;
      gpu_push({OP_EXEC_SPAN, d14, width});
      gpu_d_span(d14, width);
   end
endtask

task gpu_d_span;
   input  [13:0] d14;
   input  [13:0] width;
   begin
      gpu_m_move(d14);
      gpu_m_w = ((width & GPU_DIM_MASK) == 0) ? 1 : (width & GPU_DIM_MASK);
      gpu_m_h = 1;
      gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_x_gen = gpu_m_gen;
      if (gpu_x_xy) gpu_x_chk_dst;
      gpu_x_run;
   end
endtask

// Region guard over the unclipped destination pixels of the current context
task gpu_x_chk_dst;
   integer      kk;
   reg   [31:0] pa;
   reg          ins;
   begin
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         gpu_x_pos(kk, pa, ins);
         if (ins) gpu_rgn_dst(pa, gpu_x_bl);
      end
   end
endtask

// EXEC_EXPAND (source walk without swaps, pitch 0 = width; value 0 skipped
// or, with OPAQUE, the TRANSP colour; v >= 1: fill + v - 1). gpu_exp_op is the
// raster op ([11:8]) applied to the expanded colour; ops 13-15 write 0, ones or
// the fill colour (no SET_TRANSP test: value 0 is EXPAND's transparency).
// Blending (16 bpp, GPU_BLEND_EN): gpu_exp_mask sets [3] MASK, the source
// values are a coverage alpha (gpu_a_mask) of the fill colour (ops 13-15:
// their constant), alpha 0 writes nothing; under SET_ALPHA EN without MASK
// the expanded colour (ops 13-15: their constant) is blended with A. MASK has
// no effect below 16 bpp or without GPU_BLEND_EN; OPAQUE has none with MASK.
reg       gpu_exp_mask = 1'b0;
reg [3:0] gpu_exp_op   = 4'd0;

function [31:0] gpu_exp_rop;
   input  [3:0] op;
   input [31:0] ss, dd, fill;
   begin
      case (op)
        4'd0:  gpu_exp_rop = ss;
        4'd1:  gpu_exp_rop = ~ss;
        4'd2:  gpu_exp_rop = ~dd;
        4'd3:  gpu_exp_rop = ss & dd;
        4'd4:  gpu_exp_rop = ss | dd;
        4'd5:  gpu_exp_rop = ss ^ dd;
        4'd6:  gpu_exp_rop = ~(ss & dd);
        4'd7:  gpu_exp_rop = ~(ss | dd);
        4'd8:  gpu_exp_rop = ~(ss ^ dd);
        4'd9:  gpu_exp_rop = ~ss & dd;
        4'd10: gpu_exp_rop = ss & ~dd;
        4'd11: gpu_exp_rop = ~ss | dd;
        4'd12: gpu_exp_rop = ss | ~dd;
        4'd13: gpu_exp_rop = 32'h0;
        4'd14: gpu_exp_rop = 32'hFFFF_FFFF;
        default: gpu_exp_rop = fill;
      endcase
   end
endfunction

task gpu_c_expand;
   input integer delta;
   input   [2:0] dsw;                    // {X, Y, CL}
   input         opaque;
   input   [1:0] sdep;
   reg    [13:0] d14;
   reg    [31:0] spa, dpa, vv, pm, ee, rr, ew;
   reg           ins, msk;
   integer       kk, sbl, spitch, ae;
   begin
      d14 = delta;
      gpu_src_fmt({2'b00, sdep} + 4'd1);
      ew = {OP_EXEC_EXP, d14, gpu_k_rmp, gpu_exp_op, 1'b0, dsw, gpu_exp_mask, opaque, 2'b00};
      gpu_rsv_or(ew, 32'h0000_0083, ew);
      gpu_push(ew);
      gpu_d_expand(d14, dsw, opaque, sdep);
      gpu_imm_push;
      gpu_x_imm = 1'b0;
   end
endtask

// Model of a decoded EXEC_EXPAND (gpu_exp_op, gpu_exp_mask, gpu_k_rmp, gpu_k_imm)
task gpu_d_expand;
   input  [13:0] d14;
   input   [2:0] dsw;
   input         opaque;
   input   [1:0] sdep;
   reg    [31:0] spa, dpa, vv, pm, ee, rr;
   reg           ins, msk;
   integer       kk, sbl, spitch, ae;
   begin
      gpu_m_move(d14);
      gpu_x_setup(GPU_FILL, 4'd0, dsw, 3'b000);
      gpu_x_rmp = gpu_k_rmp;
      gpu_x_take_imm;
      gpu_d9_on = gpu_x_rmp_on(gpu_exp_op);
      gpu_aux_begin;
      sbl    = sdep;                               // 0..3 = 1, 2, 4, 8 bpp
      spitch = gpu_x_imm ? gpu_x_w : (gpu_m_src_pitch == 16'h0) ? gpu_x_w : gpu_m_src_pitch;
      pm     = gpu_pmask(gpu_x_bl);
      msk    = gpu_exp_mask && (gpu_x_bl == 4) && (GPU_BLEND_EN != 0);   // (OPAQUE has no effect)
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         gpu_x_pos(kk, dpa, ins);
         if (!ins)
            gpu_exp_clip = gpu_exp_clip + 1;
         else begin
            spa = (gpu_x_sbase + (kk / gpu_x_w) * spitch + (kk % gpu_x_w)) & GPU_PA_MASK;
            if (!gpu_x_imm) gpu_rgn_src(spa, sbl);
            gpu_rgn_dst(dpa, gpu_x_bl);
            vv  = gpu_src_px(spa, sbl);
            if (!gpu_x_imm) gpu_alw_mark(spa, sbl);
            gpu_alw_mark(dpa, gpu_x_bl);
            gpu_touch_px(dpa, gpu_x_bl);
            gpu_d9_dst(dpa, gpu_x_bl);
            if (msk) begin                                     // coverage alpha of the fill colour
               ae = gpu_a_mask5(vv, sdep, gpu_m_aen, gpu_m_a, gpu_x_mix5);
               if (ae == 0)
                  gpu_rec_px(dpa, 1'b0, 32'h0);
               else begin
                  ee = (gpu_exp_op >= 4'd13) ? gpu_exp_rop(gpu_exp_op, 32'h0, 32'h0, gpu_x_fill) : gpu_x_fill;
                  rr = gpu_blend_px(ee, gpu_get_px(dpa, gpu_x_bl), ae);
                  gpu_rec_px(dpa, 1'b1, rr);
                  gpu_set_px(dpa, gpu_x_bl, rr & pm);
               end
            end else if ((vv !== 32'h0) || opaque) begin
               ee = (vv !== 32'h0) ? (gpu_x_fill + vv - 32'h1) : gpu_x_transp;
               if (gpu_x_rmp_on(gpu_exp_op))
                  gpu_rmp_lookup(gpu_x_rdst(gpu_exp_op) ? gpu_get_px(dpa, gpu_x_bl) : (ee & pm), ee);
               if (gpu_x_blend)                                // S (ops 0-12) or the constant
                  rr = gpu_blend_px((gpu_exp_op >= 4'd13) ? gpu_exp_rop(gpu_exp_op, 32'h0, 32'h0, gpu_x_fill) : ee,
                                    gpu_get_px(dpa, gpu_x_bl), gpu_x_alpha);
               else
                  rr = gpu_exp_rop(gpu_exp_op, ee & pm, gpu_get_px(dpa, gpu_x_bl), gpu_x_fill & pm);
               if (gpu_x_blend && (gpu_x_alpha == 0))
                  gpu_rec_px(dpa, 1'b0, 32'h0);
               else begin
                  gpu_rec_px(dpa, 1'b1, rr);
                  gpu_set_px(dpa, gpu_x_bl, rr & pm);
               end
            end else
               gpu_rec_px(dpa, 1'b0, 32'h0);
         end
      end
      gpu_d9_on = 1'b0;
   end
endtask


//============================================================================
// Texture unit: SET_TEX / SET_UV / SET_STEP / SET_STEP_ROW / SET_TEXBOX,
// EXEC_TEXSPAN and EXEC_TEXRECT
//   pixel (c, r) of the walk (c along the run, r = run index) reads
//   (u, v) = (u0 + r*du' + c*du, v0 + r*dv' + c*dv), 10.11 accumulators.
//   No BOUND: unsigned, integer part = bits [20:11] (mod 1024), wrapped to
//   2^lw x 2^lh with FREE_PITCH 0 (pitch 2^lw), direct with FREE_PITCH 1
//   (pitch = SET_SRC pitch or frame width).
//   BOUND: signed (start and steps), integer part = floor; texels outside
//   [0, TW) x [0, TH) (TW, TH above 512 = 512) are skipped (no read); inside
//   the box a power-of-two texture still wraps (a box larger than the texture
//   repeats it), a free-pitch one does not; pitch as above. The coordinates
//   keep 10 signed integer bits: past +-512 texels they wrap (and fall
//   outside the box, which is at most 512 x 512).
//============================================================================
reg          [3:0] gpu_t_lw, gpu_t_lh;
reg                gpu_t_ten, gpu_t_free, gpu_t_bound;
reg          [2:0] gpu_t_sw;
reg          [7:0] gpu_t_shade;
reg          [1:0] gpu_t_rmp = 2'd0;      // SET_TEX [15:14] REMAP
reg         [15:0] gpu_t_u0, gpu_t_v0, gpu_t_du, gpu_t_dv, gpu_t_dur, gpu_t_dvr;
integer            gpu_t_uo, gpu_t_vo;    // textured triangle: start offset (10.11) added to (u, v)
initial begin gpu_t_uo = 0; gpu_t_vo = 0; end
integer            gpu_t_tw, gpu_t_th;
integer            gpu_t_nrd, gpu_t_nbnd, gpu_t_ntr, gpu_t_nwr, gpu_t_nwrap;
// BOUND with a power-of-two texture (FREE_PITCH 0): 1 = the coordinates wrap
// at the texture size inside the box (doc/gpu_commands.md, textured spans);
// gpu_t_nbwrap counts the in-box texels at or past the texture size,
// gpu_t_nbcut the texels inside the texture size but outside a smaller box
reg                gpu_t_bwrap = 1'b1;
integer            gpu_t_nbwrap = 0, gpu_t_nbcut = 0;

task gpu_t_init;
   begin
      gpu_t_lw    = 4'd0;
      gpu_t_lh    = 4'd0;
      gpu_t_ten   = 1'b0;
      gpu_t_free  = 1'b0;
      gpu_t_bound = 1'b0;
      gpu_t_sw    = 3'b000;
      gpu_t_shade = 8'h00;
      gpu_t_rmp   = 2'd0;
      gpu_t_u0    = 16'h0;
      gpu_t_v0    = 16'h0;
      gpu_t_du    = 16'h0;
      gpu_t_dv    = 16'h0;
      gpu_t_dur   = 16'h0;
      gpu_t_dvr   = 16'h0;
      gpu_t_tw    = 0;
      gpu_t_th    = 0;
      gpu_t_nrd   = 0;
      gpu_t_nbnd  = 0;
      gpu_t_ntr   = 0;
      gpu_t_nwr   = 0;
      gpu_t_nwrap = 0;
   end
endtask

// SET_EXT2 RESET_STATE: every setting back to its reset value (the model's
// copy too; GFX_MODE, the display width and the counts are not settings)
task gpu_c_reset_state;
   reg [31:0] cw;
   begin
      gpu_rsv_or({OP_SET_EXT, EXT_SET_EXT2, X2_RESET_STATE, 16'h0000}, 32'h0000_FFFF, cw);   // [15:0] ignored
      gpu_push(cw);
      gpu_m_aen       = 1'b0;
      gpu_m_a         = 8'h00;
      gpu_m_mix5      = 1'b0;
      gpu_m_abase     = 32'h0;
      gpu_m_bil       = 1'b0;
      gpu_m_tbord     = 1'b0;
      gpu_m_src_base  = 32'h0;
      gpu_m_dst_base  = 32'h0;
      gpu_m_dst_org   = 32'h0;
      gpu_m_src_pitch = 16'h0;
      gpu_m_src_fmt   = 4'h0;
      gpu_m_dst_pitch = 16'h0;
      gpu_m_w         = 1;
      gpu_m_h         = 1;
      gpu_m_fill      = 16'h0;
      gpu_m_transp    = 16'h0;
      gpu_m_xy        = 1'b0;
      gpu_m_x         = 0;
      gpu_m_y         = 0;
      gpu_m_cx0       = -2048;
      gpu_m_cy0       = -2048;
      gpu_m_cx1       = 2047;
      gpu_m_cy1       = 2047;
      gpu_m_gen       = 1'b0;
      gpu_m_gaxis     = 1'b0;
      gpu_m_gn        = 0;
      gpu_m_gstep     = 0;
      gpu_m_grgb      = 1'b0;
      gpu_m_gdr       = 0;
      gpu_m_gdg       = 0;
      gpu_m_gdb       = 0;
      gpu_t_lw        = 4'd0;
      gpu_t_lh        = 4'd0;
      gpu_t_ten       = 1'b0;
      gpu_t_free      = 1'b0;
      gpu_t_bound     = 1'b0;
      gpu_t_sw        = 3'b000;
      gpu_t_shade     = 8'h00;
      gpu_t_u0        = 16'h0;
      gpu_t_v0        = 16'h0;
      gpu_t_du        = 16'h0;
      gpu_t_dv        = 16'h0;
      gpu_t_dur       = 16'h0;
      gpu_t_dvr       = 16'h0;
      gpu_t_tw        = 0;
      gpu_t_th        = 0;
      gpu_t_rmp       = 2'd0;
      gpu_m_rbase     = 32'h0;
      gpu_m_mbase     = 32'h0;
      gpu_m_minv      = 1'b0;
      gpu_m_pen_x     = 0;                                  // the line pen, pattern and phase
      gpu_m_pen_y     = 0;
      gpu_m_lpat      = 32'hFFFF_FFFF;
      gpu_m_llen      = 32;
      gpu_m_lph       = 0;
      for (gpu_i = 0; gpu_i < 3; gpu_i = gpu_i + 1) begin   // the triangle vertices
         gpu_tv_x[gpu_i] = 0;
         gpu_tv_y[gpu_i] = 0;
      end
   end
endtask

task gpu_c_tex;
   input  [3:0] lw;
   input  [3:0] lh;
   input        ten;
   input  [2:0] sw;                      // {X, Y, CL}
   input        free;
   input        bound;
   input  [7:0] shade;
   begin
      gpu_push({OP_SET_EXT, EXT_SET_TEX, shade, gpu_k_trmp, bound, free, sw, ten, lh, lw});
      gpu_t_rmp   = gpu_k_trmp;
      gpu_t_lw    = lw;
      gpu_t_lh    = lh;
      gpu_t_ten   = ten;
      gpu_t_sw    = sw;
      gpu_t_free  = free;
      gpu_t_bound = bound;
      gpu_t_shade = shade;
   end
endtask

task gpu_c_uv;
   input [15:0] u0;                      // 10.6 (signed with BOUND)
   input [15:0] v0;
   begin
      gpu_push({OP_SET_EXT, EXT_SET_UV, 24'h0});
      gpu_push({u0, v0});
      gpu_t_u0 = u0;
      gpu_t_v0 = v0;
   end
endtask

task gpu_c_step;
   input [15:0] du;                      // signed 5.11
   input [15:0] dv;
   begin
      gpu_push({OP_SET_EXT, EXT_SET_STEP, 24'h0});
      gpu_push({du, dv});
      gpu_t_du = du;
      gpu_t_dv = dv;
   end
endtask

task gpu_c_step_row;
   input [15:0] dur;                     // signed 5.11
   input [15:0] dvr;
   begin
      gpu_push({OP_SET_EXT, EXT_SET_STEP_ROW, 24'h0});
      gpu_push({dur, dvr});
      gpu_t_dur = dur;
      gpu_t_dvr = dvr;
   end
endtask

task gpu_c_texbox;
   input integer tw;
   input integer th;
   reg    [11:0] a, b;
   begin
      a = tw;
      b = th;
      gpu_push({OP_SET_EXT, EXT_SET_TEXBOX, b, a});
      gpu_t_tw = a;
      gpu_t_th = b;
   end
endtask

// Texel of pixel (c, r) in the current context: address and in-box flag
task gpu_t_texel;
   input  integer c;
   input  integer r;
   output  [31:0] spa;
   output         inb;
   integer        ua, va, ui, vi, lw, lh, pitch, tw, th;
   begin
      lw    = (gpu_t_lw > 4'd10) ? 10 : gpu_t_lw;
      lh    = (gpu_t_lh > 4'd10) ? 10 : gpu_t_lh;
      pitch = gpu_t_free ? gpu_x_spitch : (1 << lw);
      if (!gpu_t_bound) begin
         ua  = ({gpu_t_u0, 5'b00000} + gpu_t_uo + r * gpu_sx16(gpu_t_dur) + c * gpu_sx16(gpu_t_du)) & 32'h001F_FFFF;
         va  = ({gpu_t_v0, 5'b00000} + gpu_t_vo + r * gpu_sx16(gpu_t_dvr) + c * gpu_sx16(gpu_t_dv)) & 32'h001F_FFFF;
         ui  = ua >> 11;
         vi  = va >> 11;
         if (!gpu_t_free) begin
            ui = ui & ((1 << lw) - 1);
            vi = vi & ((1 << lh) - 1);
         end
         inb = 1'b1;
      end else begin
         ua  = gpu_sx16(gpu_t_u0) * 32 + gpu_t_uo + r * gpu_sx16(gpu_t_dur) + c * gpu_sx16(gpu_t_du);
         va  = gpu_sx16(gpu_t_v0) * 32 + gpu_t_vo + r * gpu_sx16(gpu_t_dvr) + c * gpu_sx16(gpu_t_dv);
         // 10 signed integer bits: beyond +-512 texels the coordinate wraps
         ua  = ((ua + 1048576) & 32'h001F_FFFF) - 1048576;
         va  = ((va + 1048576) & 32'h001F_FFFF) - 1048576;
         ui  = ua >>> 11;                  // floor
         vi  = va >>> 11;
         tw  = (gpu_t_tw > 512) ? 512 : gpu_t_tw;
         th  = (gpu_t_th > 512) ? 512 : gpu_t_th;
         inb = (ui >= 0) && (ui < tw) && (vi >= 0) && (vi < th);
         if (!gpu_t_free) begin
            if (inb && ((ui >= (1 << lw)) || (vi >= (1 << lh)))) gpu_t_nbwrap = gpu_t_nbwrap + 1;
            if (!inb && (ui >= 0) && (ui < (1 << lw)) && (vi >= 0) && (vi < (1 << lh))) gpu_t_nbcut = gpu_t_nbcut + 1;
         end
         if (!gpu_t_free && gpu_t_bwrap) begin       // a power-of-two texture wraps inside the box too
            ui = ui & ((1 << lw) - 1);
            vi = vi & ((1 << lh) - 1);
         end
      end
      spa = (gpu_x_sbase + vi * pitch + ui) & GPU_PA_MASK;
   end
endtask

//----------------------------------------------------------------------------
// Bilinear sampling (SET_AUX TEX_FILTER BILINEAR; GPU_BILINEAR_EN and
// GPU_XY_EN; 16 bpp; EXEC_TEXSPAN, EXEC_TEXRECT, textured triangles), written
// from spec 2.2 and the pinned decisions:
//   the walk at (u - 1/2, v - 1/2): u' = u - 1024 (10.11, mod 2^21, signed
//   with BOUND); x0 = u'[20:11] (10 bits), fx = (u'[10:3] + 4) >> 3, likewise
//   y0, fy; BOUND skips the pixel when floor(u) = (u' + 1024)[20:11] or
//   floor(v) is outside the box (no tap read, no write);
//   taps T_ij = (x0 + j, y0 + i) in the order 00, 01, 10, 11, weight
//   k = wx_j wy_i (wx = (32 - fx, fx), wy likewise); a tap of weight 0 is
//   dropped (not read); BOUND with TBORDER drops a tap outside the box, BOUND
//   without it clamps x to [0, TW - 1], y to [0, TH - 1]; the texel address
//   is today's texture addressing (power of two: wrapped);
//   tap alpha a: 255 (SRC_FMT 0) or its A8 byte (SRC_FMT 5); a keyed texel
//   (TRANSP_EN, blend builds): 0; with SET_ALPHA EN a o A;
//   a' = a + (a >> 7), e = (k a') >> 8, S = sum e, P_c = sum e c_c;
//   blend build: alpha256 = S >> 2 (0: not written), Pm_c = MIX5 ? P_c >> 2
//   : (P_c + 2) >> 2, r = MIX5 ? 0 : 128, out_c = d_c + floor((Pm_c - d_c
//   alpha256 + r) / 256), no D read at alpha256 = 256;
//   no-blend build: out_c = (P_c + 512) >> 10; with TRANSP_EN nearest.
//   SHADE has no effect. A tap colour or A8 word at or past VRAM_WORDS:
//   ERR_CAUSE 5, its pixel and the rest not drawn.
// Access accounting (micro-architecture, spec 3.2: a regression lock, not
// spec evidence): a 2 x 2 colour word cache indexed by (texel row & 1, word
// parity), cleared at each command start; a colour miss reads its word, and
// with SRC_FMT 5 the alpha companion (1 A8 read; 2 when the two bytes
// straddle A8 words: gpu_bil_nard_hi), the destination through gpu_acc_tok.
//----------------------------------------------------------------------------
integer            gpu_bil_ntap [0:4];   // pixels by taps read (0 .. 4)
integer            gpu_bil_ncrd = 0;     // colour words read (cache misses)
integer            gpu_bil_nard_lo = 0;  // A8 words read: the companion in one word ...
integer            gpu_bil_nard_hi = 0;  // ... or two words when (pointer - base) is odd
integer            gpu_bil_na0 = 0, gpu_bil_na256 = 0, gpu_bil_nmid = 0;   // alpha256 0 / 256 / between
integer            gpu_bil_nclamp = 0, gpu_bil_nborder = 0, gpu_bil_nkey = 0, gpu_bil_nbskip = 0;
reg         [31:0] gpu_bc_tag [0:3];
reg                gpu_bc_v   [0:3];
// Ledger of the colour misses and the A8 words they may read (gpu_bc_log_on,
// cleared by the test): the words, so that a test can attribute each VRAM
// read (a tap's row may wrap far from the texture, e.g. y0 = -1 -> 1023)
localparam         GPU_BC_LOG_N = 4096;
reg                gpu_bc_log_on = 1'b0;
integer            gpu_bc_log_nc = 0;    // colour misses logged
integer            gpu_bc_log_na = 0;    // A8 words logged (the companion's, one or two per miss)
reg         [31:0] gpu_bc_log_c [0:GPU_BC_LOG_N-1];
reg         [31:0] gpu_bc_log_a [0:GPU_BC_LOG_N-1];
initial begin : gpu_bil_init
   integer ii;
   for (ii = 0; ii < 5; ii = ii + 1) gpu_bil_ntap[ii] = 0;
   for (ii = 0; ii < 4; ii = ii + 1) begin gpu_bc_tag[ii] = 32'h0; gpu_bc_v[ii] = 1'b0; end
end

// The tap MAC and blend of one bilinear pixel: tap colours c (T00 in [15:0],
// T01, T10, T11), their alphas a (after the key and SET_ALPHA; 0 for a tap
// outside the box with TBORDER), the 5-bit weights fx, fy, the destination d,
// the rule, the build (blend: the premultiplied blend; else the straight
// colour). Returns {alpha256 (9 bits), 7'b0, out (16 bits)}: alpha256 0 not
// written, 256 written without a destination read.
function [31:0] gpu_bil_px;
   input [63:0] c;
   input [31:0] a;
   input integer fx;
   input integer fy;
   input [15:0] d;
   input        mix5;
   input        blend;
   integer      ii, k, e, ss, p0, p1, p2, aa, a256, rr, o0, o1, o2, d0, d1, d2;
   reg   [15:0] tc;
   begin
      ss = 0; p0 = 0; p1 = 0; p2 = 0;
      for (ii = 0; ii < 4; ii = ii + 1) begin
         k  = (ii[0] ? fx : (32 - fx)) * (ii[1] ? fy : (32 - fy));
         aa = blend ? a[8*ii +: 8] : 255;
         e  = (k * (aa + (aa >> 7))) >> 8;
         tc = c[16*ii +: 16];
         ss = ss + e;
         p0 = p0 + e * tc[15:11];
         p1 = p1 + e * tc[10:5];
         p2 = p2 + e * tc[4:0];
      end
      if (!blend) begin
         a256 = 256;
         o0 = (p0 + 512) >> 10; o1 = (p1 + 512) >> 10; o2 = (p2 + 512) >> 10;
      end else begin
         a256 = ss >> 2;
         rr = mix5 ? 0 : 128;
         d0 = d[15:11]; d1 = d[10:5]; d2 = d[4:0];
         p0 = mix5 ? (p0 >> 2) : ((p0 + 2) >> 2);
         p1 = mix5 ? (p1 >> 2) : ((p1 + 2) >> 2);
         p2 = mix5 ? (p2 >> 2) : ((p2 + 2) >> 2);
         o0 = d0 + ((p0 - d0 * a256 + rr) >>> 8);
         o1 = d1 + ((p1 - d1 * a256 + rr) >>> 8);
         o2 = d2 + ((p2 - d2 * a256 + rr) >>> 8);
         if (a256 == 0) begin o0 = d0; o1 = d1; o2 = d2; end
      end
      gpu_bil_px = {a256[8:0], 7'h00, o0[4:0], o1[5:0], o2[4:0]};
   end
endfunction

// The context samples bilinearly (after gpu_x_take_a8)
task gpu_x_take_bil;
   begin
      gpu_x_bilx = gpu_m_bil && (gpu_x_bl == 4) && (GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0) &&
                   !((GPU_BLEND_EN == 0) && gpu_t_ten);
      gpu_bc_v[0] = 1'b0; gpu_bc_v[1] = 1'b0; gpu_bc_v[2] = 1'b0; gpu_bc_v[3] = 1'b0;
      if (gpu_x_bilx) gpu_acc_begin;
   end
endtask

task gpu_x_end_bil;
   begin
      if (gpu_x_bilx) gpu_acc_end;
   end
endtask

// One tap's colour word through the cache (y: the tap's texel row)
task gpu_bc_tap;
   input [31:0] spa;
   input integer y;
   reg   [31:0] wa, apa;
   integer      ix;
   begin
      wa = spa >> 1;
      ix = 2 * (y & 1) + wa[0];
      if (!gpu_bc_v[ix] || (gpu_bc_tag[ix] != wa)) begin
         gpu_bil_ncrd = gpu_bil_ncrd + 1;
         if (gpu_bc_log_on && (gpu_bc_log_nc < GPU_BC_LOG_N)) begin
            gpu_bc_log_c[gpu_bc_log_nc] = wa;
            gpu_bc_log_nc = gpu_bc_log_nc + 1;
         end
         gpu_bc_v[ix]   = 1'b1;
         gpu_bc_tag[ix] = wa;
         if (gpu_x_a8) begin
            apa = ((wa << 1) + gpu_x_ka) & GPU_PA_MASK;   // the companion: the bytes of texels 2 wa, 2 wa + 1
            gpu_bil_nard_lo = gpu_bil_nard_lo + ((apa[1:0] == 2'd3) ? 2 : 1);
            gpu_bil_nard_hi = gpu_bil_nard_hi + (gpu_x_ka[0] ? 2 : 1);
            gpu_alw_mark(apa, 3);
            gpu_alw_mark((apa + 1) & GPU_PA_MASK, 3);
            if (gpu_bc_log_on && (gpu_bc_log_na < GPU_BC_LOG_N - 1)) begin
               gpu_bc_log_a[gpu_bc_log_na]     = apa >> 2;
               gpu_bc_log_a[gpu_bc_log_na + 1] = ((apa + 1) & GPU_PA_MASK) >> 2;
               gpu_bc_log_na = gpu_bc_log_na + 2;
            end
         end
      end
   end
endtask

// Pixel (c, r) of the current bilinear context at destination dpa
task gpu_t_bil;
   input integer c;
   input integer r;
   input  [31:0] dpa;
   integer       ua, va, ub, vb, ui, vi, x0, y0, fx, fy, ii, jj, x, y, k, a, e, ss, p0, p1, p2;
   integer       lw, lh, pitch, tw, th, nt, a256, d0, d1, d2, o0, o1, o2, wx0, wx1, wy0, wy1, rr;
   reg    [31:0] spa, apa, tt, dd, out, ta, res;
   reg    [63:0] tc;
   reg           oob, drop, nd;
   reg     [7:0] ab;
   begin
      lw    = (gpu_t_lw > 4'd10) ? 10 : gpu_t_lw;
      lh    = (gpu_t_lh > 4'd10) ? 10 : gpu_t_lh;
      pitch = gpu_t_free ? gpu_x_spitch : (1 << lw);
      tw    = (gpu_t_tw > 512) ? 512 : gpu_t_tw;
      th    = (gpu_t_th > 512) ? 512 : gpu_t_th;
      if (!gpu_t_bound) begin
         ua = ({gpu_t_u0, 5'b00000} + gpu_t_uo + r * gpu_sx16(gpu_t_dur) + c * gpu_sx16(gpu_t_du) - 1024) & 32'h001F_FFFF;
         va = ({gpu_t_v0, 5'b00000} + gpu_t_vo + r * gpu_sx16(gpu_t_dvr) + c * gpu_sx16(gpu_t_dv) - 1024) & 32'h001F_FFFF;
         x0 = ua >> 11;                                  // 0 .. 1023
         y0 = va >> 11;
      end else begin
         ua = gpu_sx16(gpu_t_u0) * 32 + gpu_t_uo + r * gpu_sx16(gpu_t_dur) + c * gpu_sx16(gpu_t_du) - 1024;
         va = gpu_sx16(gpu_t_v0) * 32 + gpu_t_vo + r * gpu_sx16(gpu_t_dvr) + c * gpu_sx16(gpu_t_dv) - 1024;
         ua = ((ua + 1048576) & 32'h001F_FFFF) - 1048576;  // signed 21 bits
         va = ((va + 1048576) & 32'h001F_FFFF) - 1048576;
         x0 = ua >>> 11;                                 // -512 .. 511
         y0 = va >>> 11;
      end
      fx  = (((ua & 2047) >> 3) + 4) >> 3;
      fy  = (((va & 2047) >> 3) + 4) >> 3;
      wx0 = 32 - fx; wx1 = fx; wy0 = 32 - fy; wy1 = fy;
      // BOUND: the pixel skip on (floor(u), floor(v))
      drop = 1'b0;
      if (gpu_t_bound) begin
         ub = ((ua + 1024 + 1048576) & 32'h001F_FFFF) - 1048576;
         vb = ((va + 1024 + 1048576) & 32'h001F_FFFF) - 1048576;
         ui = ub >>> 11;
         vi = vb >>> 11;
         drop = (ui < 0) || (ui >= tw) || (vi < 0) || (vi >= th);
      end
      gpu_rgn_dst(dpa, gpu_x_bl);
      gpu_d9_dst(dpa, gpu_x_bl);
      gpu_touch_px(dpa, gpu_x_bl);
      if (drop) begin
         gpu_t_nbnd     = gpu_t_nbnd + 1;
         gpu_bil_nbskip = gpu_bil_nbskip + 1;
         gpu_bil_ntap[0] = gpu_bil_ntap[0] + 1;
      end else begin
         nt = 0; ss = 0; p0 = 0; p1 = 0; p2 = 0; oob = 1'b0; tc = 64'h0; ta = 32'h0;
         for (ii = 0; (ii < 2) && !oob; ii = ii + 1)
            for (jj = 0; (jj < 2) && !oob; jj = jj + 1) begin
               k = ((jj == 0) ? wx0 : wx1) * ((ii == 0) ? wy0 : wy1);
               if (!gpu_t_bound) begin
                  x = (x0 + jj) & 1023;
                  y = (y0 + ii) & 1023;
               end else begin
                  x = x0 + jj;                              // x0 in [-1, TW - 1] (the pixel inside the box):
                  y = y0 + ii;                              // x0 + 1 = TW (512 too) clamps to TW - 1
               end
               if (k == 0)
                  ;                                            // weight 0: dropped
               else if (gpu_t_bound && gpu_m_tbord && ((x < 0) || (x >= tw) || (y < 0) || (y >= th)))
                  gpu_bil_nborder = gpu_bil_nborder + 1;      // outside the box: transparent, not read
               else begin
                  if (gpu_t_bound && !gpu_m_tbord) begin       // clamp
                     if ((x < 0) || (x >= tw) || (y < 0) || (y >= th)) gpu_bil_nclamp = gpu_bil_nclamp + 1;
                     if (x < 0) x = 0;
                     if (x > tw - 1) x = tw - 1;
                     if (y < 0) y = 0;
                     if (y > th - 1) y = th - 1;
                  end
                  if (!gpu_t_free && (!gpu_t_bound || gpu_t_bwrap)) begin
                     x = x & ((1 << lw) - 1);
                     y = y & ((1 << lh) - 1);
                  end
                  spa = (gpu_x_sbase + y * pitch + x) & GPU_PA_MASK;
                  nt  = nt + 1;
                  if ((spa >> 1) >= VRAM_WORDS) begin
                     oob = 1'b1;
                     if (!gpu_oob_ok) begin
                        $display("ERROR: GPU model -- bilinear tap 0x%h outside VRAM (test bug) %t", spa, $time);
                        error = error + 1;
                     end
                  end else begin
                     gpu_rgn_src(spa, gpu_x_bl);
                     gpu_alw_mark(spa, gpu_x_bl);
                     gpu_bc_tap(spa, y);
                     tt = gpu_get_px(spa, gpu_x_bl);
                     a  = 255;
                     if (gpu_x_a8) begin
                        apa = (spa + gpu_x_ka) & GPU_PA_MASK;
                        gpu_alw_mark(apa, 3);
                        gpu_d9_aux(apa >> 2);
                        if ((apa >> 2) >= VRAM_WORDS) begin
                           oob = 1'b1;
                           if (!gpu_oob_ok) begin
                              $display("ERROR: GPU model -- bilinear A8 word 0x%h outside VRAM (test bug) %t", apa >> 2, $time);
                              error = error + 1;
                           end
                        end else begin
                           ab = gpu_shadow[apa >> 2] >> (8 * apa[1:0]);
                           a  = ab;
                        end
                     end
                     if ((GPU_BLEND_EN != 0) && gpu_t_ten && (tt == gpu_x_transp)) begin
                        a = 0;
                        gpu_bil_nkey = gpu_bil_nkey + 1;
                     end
                     if ((GPU_BLEND_EN != 0) && gpu_x_aen) a = gpu_a_comb(a, gpu_x_a, gpu_x_mix5);
                     if (GPU_BLEND_EN == 0) a = 255;
                     tc[16 * (2 * ii + jj) +: 16] = tt[15:0];
                     ta[8 * (2 * ii + jj) +: 8]   = a;
                  end
               end
            end
         if (oob) begin
            gpu_oob_hit = 1'b1;                                // ERR_CAUSE 5: this pixel and the rest not drawn
            gpu_rec_px(dpa, 1'b0, 32'h0);
         end else begin
            gpu_bil_ntap[nt] = gpu_bil_ntap[nt] + 1;
            gpu_t_nrd = gpu_t_nrd + nt;
            dd  = gpu_get_px(dpa, gpu_x_bl);
            res = gpu_bil_px(tc, ta, fx, fy, dd[15:0], gpu_x_mix5, GPU_BLEND_EN != 0);
            if (GPU_BLEND_EN != 0) begin
               a256 = res[31:23];
               if (a256 == 0) gpu_bil_na0 = gpu_bil_na0 + 1;
               else if (a256 == 256) gpu_bil_na256 = gpu_bil_na256 + 1;
               else gpu_bil_nmid = gpu_bil_nmid + 1;
            end else
               a256 = 256;
            if (a256 == 0)
               gpu_rec_px(dpa, 1'b0, 32'h0);                   // nothing written
            else begin
               gpu_alw_mark(dpa, gpu_x_bl);
               nd  = (GPU_BLEND_EN != 0) && (a256 != 256);
               out = {16'h0, res[15:0]};
               gpu_rec_px(dpa, 1'b1, out);
               gpu_set_px(dpa, gpu_x_bl, out);
               gpu_t_nwr = gpu_t_nwr + 1;
               gpu_acc_tok(dpa >> 1, nd);
            end
         end
      end
   end
endtask

// Run the texture walk of the current context (w x h, swaps = SET_TEX)
task gpu_t_run;
   integer      kk, cc, rr;
   reg   [31:0] spa, dpa, tt, pm;
   reg          ins, inb, aoob;
   reg    [7:0] ab;
   integer      af;
   begin
      pm = gpu_pmask(gpu_x_bl);
      gpu_x_rmp = gpu_t_rmp;
      gpu_d9_on = gpu_x_a8 || gpu_x_rmp_on(4'd0);
      gpu_aux_begin;
      for (kk = 0; kk < gpu_x_w * gpu_x_h; kk = kk + 1) begin
         cc = kk % gpu_x_w;
         rr = kk / gpu_x_w;
         gpu_x_pos(kk, dpa, ins);
         if (!ins)
            gpu_exp_clip = gpu_exp_clip + 1;
         else if (gpu_x_bilx)
            gpu_t_bil(cc, rr, dpa);
         else begin
            gpu_rgn_dst(dpa, gpu_x_bl);
            gpu_d9_dst(dpa, gpu_x_bl);
            gpu_touch_px(dpa, gpu_x_bl);
            gpu_t_texel(cc, rr, spa, inb);
            if (!inb)
               gpu_t_nbnd = gpu_t_nbnd + 1;
            else begin
               gpu_rgn_src(spa, gpu_x_bl);
               tt = gpu_get_px(spa, gpu_x_bl);
               gpu_t_nrd = gpu_t_nrd + 1;
               gpu_alw_mark(spa, gpu_x_bl);
               gpu_alw_mark(dpa, gpu_x_bl);
               af   = gpu_x_alpha;
               aoob = 1'b0;
               if (gpu_x_a8) begin                         // the texel's A8 byte (read for a keyed texel too)
                  gpu_a8_byte(spa, ab, aoob);
                  af = aoob ? 0 : gpu_a8_fac(ab);
               end
               if (gpu_t_ten && (tt == (gpu_x_transp & pm))) begin
                  gpu_t_ntr = gpu_t_ntr + 1;
                  gpu_rec_px(dpa, 1'b0, 32'h0);
               end else begin
                  if ((tt + gpu_t_shade) > pm) gpu_t_nwrap = gpu_t_nwrap + 1;
                  tt = (tt + gpu_t_shade) & pm;
                  if (gpu_x_rmp_on(4'd0))
                     gpu_rmp_lookup(gpu_x_rdst(4'd0) ? gpu_get_px(dpa, gpu_x_bl) : tt, tt);
                  if (gpu_x_blend) tt = gpu_blend_px(tt, gpu_get_px(dpa, gpu_x_bl), af);
                  if (gpu_x_blend && (af == 0))
                     gpu_rec_px(dpa, 1'b0, 32'h0);
                  else begin
                     gpu_rec_px(dpa, 1'b1, tt);
                     gpu_set_px(dpa, gpu_x_bl, tt & pm);
                     gpu_t_nwr = gpu_t_nwr + 1;
                  end
               end
            end
         end
      end
      gpu_d9_on = 1'b0;
   end
endtask

// EXEC_TEXSPAN: move, N x 1, the texture walk (row 0)
task gpu_c_texspan;
   input integer delta;
   input  [13:0] n;
   reg    [13:0] d14;
   begin
      d14 = delta;
      gpu_src_fmt(gpu_k_a8 ? 4'h5 : 4'h0);
      gpu_push({OP_EXEC_TEX, d14, n});
      gpu_d_texspan(d14, n);
   end
endtask

task gpu_d_texspan;
   input  [13:0] d14;
   input  [13:0] n;
   begin
      gpu_m_move(d14);
      gpu_m_w = ((n & GPU_DIM_MASK) == 0) ? 1 : (n & GPU_DIM_MASK);
      gpu_m_h = 1;
      gpu_x_setup(GPU_FILL, 4'd0, gpu_t_sw, 3'b000);
      gpu_x_take_a8;
      gpu_x_take_bil;
      gpu_t_run;
      gpu_x_end_bil;
   end
endtask

// EXEC_TEXRECT: move, the SET_SIZE rectangle (size kept), the texture walk
task gpu_c_texrect;
   input integer delta;
   reg    [13:0] d14;
   begin
      d14 = delta;
      gpu_src_fmt(gpu_k_a8 ? 4'h5 : 4'h0);
      gpu_push({OP_EXEC_TEXRECT, d14, 14'h0000});
      gpu_d_texrect(d14);
   end
endtask

task gpu_d_texrect;
   input  [13:0] d14;
   begin
      gpu_m_move(d14);
      gpu_x_setup(GPU_FILL, 4'd0, gpu_t_sw, 3'b000);
      gpu_x_take_a8;
      gpu_x_take_bil;
      gpu_t_run;
      gpu_x_end_bil;
   end
endtask

//----------------------------------------------------------------------------
// Textured triangle: SET_V0..V2 and EXEC_TEXRECT [7] TRI (x/y mode, clip window).
// (u, v) of SET_UV is at V0; the walk starts at the centre of the box's first
// pixel, (u, v) carried there by floor(du * dx / 16) + floor(du' * dy / 16)
// (dx, dy: 12.4 offset from V0), then stepped per pixel / row as EXEC_TEXRECT.
// Inside test: the three edge functions (top / left edges include their pixels).
// Blending as EXEC_TEXRECT; the walk record (gpu_rec_*) holds the pixels
// inside the triangle in walk order (box rows, then columns).
//----------------------------------------------------------------------------

task gpu_c_vtx;
   input integer k;
   input integer x;                      // 12.4
   input integer y;
   reg    [15:0] xf, yf;
   begin
      xf = x;
      yf = y;
      gpu_push({OP_SET_EXT, 4'd9 + k[3:0], 24'h000000});
      gpu_push({yf, xf});
      gpu_tv_x[k] = gpu_sx16(xf);
      gpu_tv_y[k] = gpu_sx16(yf);
   end
endtask

// (64-bit: the products of vertices at the 12.4 extremes exceed 32 bits)
function signed [63:0] gpu_tri_e;        // edge function a -> b at pixel centre (px, py)
   input integer ax, ay, bx, by, px, py;
   reg signed [63:0] a, b, c, d;
   begin
      a = bx - ax;
      b = 16 * py + 8 - ay;
      c = by - ay;
      d = 16 * px + 8 - ax;
      gpu_tri_e = a * b - c * d;
   end
endfunction

function signed [63:0] gpu_tri_area;     // twice the signed area
   input integer x0, y0, x1, y1, x2, y2;
   reg signed [63:0] a, b, c, d;
   begin
      a = x1 - x0;
      b = y2 - y0;
      c = y1 - y0;
      d = x2 - x0;
      gpu_tri_area = a * b - c * d;
   end
endfunction

function gpu_tri_ok;
   input signed [63:0] e;
   input integer dx;
   input integer dy;
   begin
      gpu_tri_ok = (e > 0) || ((e == 0) && (((dy == 0) && (dx > 0)) || (dy < 0)));
   end
endfunction

task gpu_c_tritex;
   begin
      gpu_src_fmt(gpu_k_a8 ? 4'h5 : 4'h0);
      gpu_push({OP_EXEC_TEXRECT, gpu_tt_delta, 14'h0080});           // DELTA ignored with TRI
      gpu_d_tritex;
   end
endtask

task gpu_d_tritex;
   integer      x0, y0, x1, y1, x2, y2, t, mnx, mxx, mny, mxy, bx0, by0, bx1, by1, bw, bh;
   integer      cc, rr, px, py, dmax;
   reg signed [63:0] e0, e1, e2, area, pu;
   reg   [31:0] spa, dpa, tt, pm;
   reg          inb, aoob;
   reg    [7:0] ab;
   integer      af;
   begin
      gpu_x_setup(GPU_FILL, 4'd0, 3'b000, 3'b000);
      gpu_x_take_a8;
      gpu_x_take_bil;
      gpu_x_rmp = gpu_t_rmp;
      gpu_d9_on = gpu_x_a8 || gpu_x_rmp_on(4'd0);
      gpu_aux_begin;
      pm  = gpu_pmask(gpu_x_bl);
      x0 = gpu_tv_x[0]; y0 = gpu_tv_y[0];
      x1 = gpu_tv_x[1]; y1 = gpu_tv_y[1];
      x2 = gpu_tv_x[2]; y2 = gpu_tv_y[2];
      area = gpu_tri_area(x0, y0, x1, y1, x2, y2);
      if (area < 0) begin t = x1; x1 = x2; x2 = t; t = y1; y1 = y2; y2 = t; end
      mnx = (x0 < x1) ? ((x0 < x2) ? x0 : x2) : ((x1 < x2) ? x1 : x2);
      mxx = (x0 > x1) ? ((x0 > x2) ? x0 : x2) : ((x1 > x2) ? x1 : x2);
      mny = (y0 < y1) ? ((y0 < y2) ? y0 : y2) : ((y1 < y2) ? y1 : y2);
      mxy = (y0 > y1) ? ((y0 > y2) ? y0 : y2) : ((y1 > y2) ? y1 : y2);
      bx0 = (mnx + 7) >>> 4;  bx1 = (mxx - 8) >>> 4;
      by0 = (mny + 7) >>> 4;  by1 = (mxy - 8) >>> 4;
      if (bx0 < gpu_x_cx0) bx0 = gpu_x_cx0;
      if (by0 < gpu_x_cy0) by0 = gpu_x_cy0;
      if (bx1 > gpu_x_cx1) bx1 = gpu_x_cx1;
      if (by1 > gpu_x_cy1) by1 = gpu_x_cy1;
      bw = bx1 - bx0 + 1;
      bh = by1 - by0 + 1;
      dmax = GPU_DIM_MASK;
      if (bw > dmax) bw = dmax;
      if (bh > dmax) bh = dmax;
      if (gpu_x_xy && (area != 0) && (bw >= 1) && (bh >= 1)) begin
         // the start offset of (u, v): floor(du * dx / 16) + floor(du' * dy / 16)
         // (64-bit products, kept modulo 2^32: the coordinates wrap at 2^21)
         pu = gpu_sx16(gpu_t_du);  pu = (pu * (16 * bx0 + 8 - gpu_tv_x[0])) >>> 4;  gpu_t_uo = pu;
         pu = gpu_sx16(gpu_t_dur); pu = (pu * (16 * by0 + 8 - gpu_tv_y[0])) >>> 4;  gpu_t_uo = gpu_t_uo + pu;
         pu = gpu_sx16(gpu_t_dv);  pu = (pu * (16 * bx0 + 8 - gpu_tv_x[0])) >>> 4;  gpu_t_vo = pu;
         pu = gpu_sx16(gpu_t_dvr); pu = (pu * (16 * by0 + 8 - gpu_tv_y[0])) >>> 4;  gpu_t_vo = gpu_t_vo + pu;
         for (rr = 0; rr < bh; rr = rr + 1)
            for (cc = 0; cc < bw; cc = cc + 1) begin
               px = bx0 + cc;
               py = by0 + rr;
               e0 = gpu_tri_e(x0, y0, x1, y1, px, py);
               e1 = gpu_tri_e(x1, y1, x2, y2, px, py);
               e2 = gpu_tri_e(x2, y2, x0, y0, px, py);
               if (gpu_tri_ok(e0, x1 - x0, y1 - y0) && gpu_tri_ok(e1, x2 - x1, y2 - y1) &&
                   gpu_tri_ok(e2, x0 - x2, y0 - y2)) begin
                  dpa = (gpu_x_dbase + py * gpu_x_dpitch + px) & GPU_PA_MASK;
                  if (gpu_x_bilx) gpu_t_bil(cc, rr, dpa);
                  else begin
                  gpu_rgn_dst(dpa, gpu_x_bl);
                  gpu_d9_dst(dpa, gpu_x_bl);
                  gpu_touch_px(dpa, gpu_x_bl);
                  gpu_t_texel(cc, rr, spa, inb);
                  if (inb) begin
                     gpu_rgn_src(spa, gpu_x_bl);
                     tt = gpu_get_px(spa, gpu_x_bl);
                     gpu_alw_mark(spa, gpu_x_bl);
                     gpu_alw_mark(dpa, gpu_x_bl);
                     af = gpu_x_alpha;
                     if (gpu_x_a8) begin
                        gpu_a8_byte(spa, ab, aoob);
                        af = aoob ? 0 : gpu_a8_fac(ab);
                     end
                     if (!(gpu_t_ten && (tt == (gpu_x_transp & pm))) && !(gpu_x_blend && (af == 0))) begin
                        tt = (tt + gpu_t_shade) & pm;
                        if (gpu_x_rmp_on(4'd0))
                           gpu_rmp_lookup(gpu_x_rdst(4'd0) ? gpu_get_px(dpa, gpu_x_bl) : tt, tt);
                        if (gpu_x_blend) tt = gpu_blend_px(tt, gpu_get_px(dpa, gpu_x_bl), af);
                        gpu_rec_px(dpa, 1'b1, tt);
                        gpu_set_px(dpa, gpu_x_bl, tt & pm);
                     end else
                        gpu_rec_px(dpa, 1'b0, 32'h0);
                  end else
                     gpu_rec_px(dpa, 1'b0, 32'h0);
                  end
               end
            end
      end
      gpu_x_end_bil;
      gpu_t_uo  = 0;
      gpu_t_vo  = 0;
      gpu_d9_on = 1'b0;
   end
endtask

// Flat triangle: EXEC_FILL [7] TRI (REMAP: gpu_k_rmp) on the vertices of
// gpu_c_vtx, in x/y mode, clipped. The walk is the triangle's pixel box
// clipped (as gpu_c_tritex); a pixel inside the triangle is modelled as the
// FILL pixel at its box column / row (gpu_px_step on a box-sized context): the
// gradient counts from the box's first row (AXIS 0) or column (AXIS 1); the
// raster op, the ops 13-15 key, the remap after it, and the access accounting
// (pixels in walk order, row by row) and blending apply as on a rectangle.
task gpu_c_trifill;
   input  [3:0] op;
   begin
      gpu_push({OP_EXEC_FILL, 14'h0000, gpu_k_rmp, 4'h0, 1'b1, 3'b000, op});
      gpu_d_trifill(op);
   end
endtask

task gpu_d_trifill;
   input  [3:0] op;
   integer      x0, y0, x1, y1, x2, y2, t, mnx, mxx, mny, mxy, bx0, by0, bx1, by1, bw, bh;
   integer      cc, rr, px, py, dmax;
   reg signed [63:0] e0, e1, e2, area;
   begin
      gpu_x_setup(GPU_FILL, op, 3'b000, 3'b000);
      gpu_x_aux(GPU_FILL);
      gpu_x_gen = gpu_m_gen;
      x0 = gpu_tv_x[0]; y0 = gpu_tv_y[0];
      x1 = gpu_tv_x[1]; y1 = gpu_tv_y[1];
      x2 = gpu_tv_x[2]; y2 = gpu_tv_y[2];
      area = gpu_tri_area(x0, y0, x1, y1, x2, y2);
      if (area < 0) begin t = x1; x1 = x2; x2 = t; t = y1; y1 = y2; y2 = t; end
      mnx = (x0 < x1) ? ((x0 < x2) ? x0 : x2) : ((x1 < x2) ? x1 : x2);
      mxx = (x0 > x1) ? ((x0 > x2) ? x0 : x2) : ((x1 > x2) ? x1 : x2);
      mny = (y0 < y1) ? ((y0 < y2) ? y0 : y2) : ((y1 < y2) ? y1 : y2);
      mxy = (y0 > y1) ? ((y0 > y2) ? y0 : y2) : ((y1 > y2) ? y1 : y2);
      bx0 = (mnx + 7) >>> 4;  bx1 = (mxx - 8) >>> 4;
      by0 = (mny + 7) >>> 4;  by1 = (mxy - 8) >>> 4;
      if (bx0 < gpu_x_cx0) bx0 = gpu_x_cx0;
      if (by0 < gpu_x_cy0) by0 = gpu_x_cy0;
      if (bx1 > gpu_x_cx1) bx1 = gpu_x_cx1;
      if (by1 > gpu_x_cy1) by1 = gpu_x_cy1;
      bw = bx1 - bx0 + 1;
      bh = by1 - by0 + 1;
      dmax = GPU_DIM_MASK;
      if (bw > dmax) bw = dmax;
      if (bh > dmax) bh = dmax;
      if (gpu_x_xy && (area != 0) && (bw >= 1) && (bh >= 1)) begin
         gpu_x_x = bx0;
         gpu_x_y = by0;
         gpu_x_w = bw;
         gpu_x_h = bh;
         gpu_acc_begin;
         gpu_d9_on = gpu_x_rmp_on(gpu_x_op);
         gpu_aux_begin;
         for (rr = 0; rr < bh; rr = rr + 1)
            for (cc = 0; cc < bw; cc = cc + 1) begin
               px = bx0 + cc;
               py = by0 + rr;
               e0 = gpu_tri_e(x0, y0, x1, y1, px, py);
               e1 = gpu_tri_e(x1, y1, x2, y2, px, py);
               e2 = gpu_tri_e(x2, y2, x0, y0, px, py);
               if (gpu_tri_ok(e0, x1 - x0, y1 - y0) && gpu_tri_ok(e1, x2 - x1, y2 - y1) &&
                   gpu_tri_ok(e2, x0 - x2, y0 - y2))
                  gpu_px_step(rr * bw + cc);
            end
         gpu_acc_end;
         gpu_d9_on = 1'b0;
      end
   end
endtask

// Raw EXEC word of a FILL / COPY / COPY_TRANSP, modelled (x/y, clip, gradient)
// -- same as gpu_c_exec, plus the destination region guard in x/y mode.
task gpu_c_exec_xy;
   input  [3:0] cmd;
   input  [3:0] op;
   input  [2:0] dsw;
   input  [2:0] ssw;
   reg   [31:0] ew;
   begin
      if (cmd != GPU_FILL) gpu_src_fmt(gpu_k_a8 ? 4'h5 : 4'h0);
      gpu_rsv_or(gpu_exec_word(cmd, op, dsw, ssw) | gpu_exec_aux(cmd), (cmd != GPU_FILL) ? 32'h80 : 32'h0, ew);
      gpu_push(ew);
      gpu_x_setup(cmd, op, dsw, ssw);
      gpu_x_aux(cmd);
      if (cmd != GPU_FILL) begin gpu_x_take_imm; gpu_x_take_a8; end
      gpu_x_gen = gpu_m_gen && (cmd == GPU_FILL);
      if (gpu_x_xy) gpu_x_chk_dst;
      gpu_x_run;
      gpu_imm_push;
   end
endtask


//============================================================================
// Lines (doc/gpu_commands.md, lines): EXEC_FILL [24] LINE from the pen to the
// operand (12.4), SET_AUX LINE_PEN / LINE_PATTERN, written from the
// specification's closed forms (not the RTL's walk):
//   solid: the pixels holding the end points; one pixel per major coordinate,
//   the minor one the exact line value rounded to the nearest, an exact half
//   toward the smaller coordinate; N = D + 1 steps (D with NO_LAST);
//   AA (16 bpp, GPU_BLEND_EN): the major axis from the 12.4 deltas, the slope
//   G = sign * floor(|dQ| 2^16 / |dP|), M = Q0 2^12 + floor(G d0 / 16) + k G,
//   T = M - 2^15: rows T >> 16 and + 1, coverage 255 - f and f (f = T[15:8]);
//   the pattern: bit phase of each step, the phase advancing by N in x/y mode
//   (stream state: 0 after a flush, a fault, LINE_PATTERN, RESET_STATE).
//   Each pixel drawn as a FILL pixel of the colour (a gap with OPAQUE: the
//   transparent colour): ops 13-15 key, remap, op, blending (AA: its coverage,
//   times A with SET_ALPHA EN). gpu_ln_* hold the walk of the last line
//   (pixel addresses, in walk order) for the prefix checks.
//============================================================================
integer            gpu_m_pen_x  = 0;     // the pen (12.4)
integer            gpu_m_pen_y  = 0;
reg         [31:0] gpu_m_lpat   = 32'hFFFF_FFFF;   // LINE_PATTERN
integer            gpu_m_llen   = 32;
integer            gpu_m_lph    = 0;     // the pattern phase (stream state)
integer            gpu_ln_n     = 0;     // last line: steps, pixels walked
integer            gpu_ln_np    = 0;
integer            gpu_ln_ndrawn = 0;    // ... pixels written
localparam integer GPU_LN_MAX   = 8192;
reg         [31:0] gpu_ln_pa [0:GPU_LN_MAX-1];   // its pixels in walk order (inside the clip window)
reg                gpu_ln_wr [0:GPU_LN_MAX-1];   // ... written

function integer gpu_fdiv;               // floor(a / b), b > 0
   input integer a;
   input integer b;
   begin
      gpu_fdiv = (a >= 0) ? (a / b) : -((-a + b - 1) / b);
   end
endfunction

task gpu_c_pen;                          // SET_AUX LINE_PEN, 12.4
   input integer x;
   input integer y;
   reg   [15:0] xf, yf;
   reg   [31:0] cw;
   begin
      xf = x;
      yf = y;
      gpu_rsv_or({OP_SET_EXT, EXT_SET_AUX, 4'd2, 20'h00000}, 32'h000F_FFFF, cw);   // [19:0] ignored
      gpu_push(cw);
      gpu_push({yf, xf});
      gpu_m_pen_x = gpu_sx16(xf);
      gpu_m_pen_y = gpu_sx16(yf);
   end
endtask

task gpu_c_pattern;                      // SET_AUX LINE_PATTERN: the pattern, LEN 1-32
   input [31:0] pat;
   input integer len;
   reg   [31:0] cw;
   reg    [4:0] lf;
   begin
      lf = len - 1;
      gpu_rsv_or({OP_SET_EXT, EXT_SET_AUX, 4'd3, 15'h0000, lf}, 32'h000F_FFE0, cw);   // [19:5] ignored
      gpu_push(cw);
      gpu_push(pat);
      gpu_m_lpat = pat;
      gpu_m_llen = lf + 1;
      gpu_m_lph  = 0;
   end
endtask

// The EXEC_FILL LINE word: opt {PH_RST, OPAQUE, NO_LAST, AA}, REMAP gpu_k_rmp
function [31:0] gpu_line_word;
   input  [3:0] op;
   input  [3:0] opt;
   begin
      gpu_line_word = {OP_EXEC_FILL, 3'b000, 1'b1, 4'h0, opt, 2'b00, gpu_k_rmp, 8'h00, op};
   end
endfunction

// EXEC_FILL LINE to (x, y), 12.4, from the pen; modelled, the pen moved
task gpu_c_line;
   input integer x;
   input integer y;
   input  [3:0] op;
   input  [3:0] opt;
   reg   [15:0] xf, yf;
   reg   [31:0] cw;
   begin
      xf = x;
      yf = y;
      gpu_rsv_or(gpu_line_word(op, opt), 32'h0EF0_CF00, cw);   // [27:25], [23:20], [15:14], [11:8] ignored
      gpu_push(cw);
      gpu_push({yf, xf});
      gpu_d_line(op, opt, gpu_sx16(xf), gpu_sx16(yf));
   end
endtask

// One pixel of a line (x, y) of colour c (alpha a: -1 the context's; else a
// coverage 0-255), in walk order
task gpu_ln_px;
   input integer x;
   input integer y;
   input  [31:0] c;
   input integer a;
   reg    [31:0] pm, ss, dd, rr, dpa;
   reg           thit, bskip;
   integer       al;
   begin
      pm = gpu_pmask(gpu_x_bl);
      if ((x < gpu_x_cx0) || (x > gpu_x_cx1) || (y < gpu_x_cy0) || (y > gpu_x_cy1))
         gpu_exp_clip = gpu_exp_clip + 1;
      else if (a == 0)
         ;                                                        // coverage 0: no access
      else begin
         dpa = (gpu_x_dbase + y * gpu_x_dpitch + x) & GPU_PA_MASK;
         if (gpu_ln_np < GPU_LN_MAX) begin gpu_ln_pa[gpu_ln_np] = dpa; gpu_ln_wr[gpu_ln_np] = 1'b0; end
         gpu_ln_np = gpu_ln_np + 1;
         al = (a < 0) ? gpu_x_alpha : gpu_a_mask5(a, 2'd3, gpu_m_aen, gpu_m_a, gpu_x_mix5);
         bskip = gpu_x_blend && (al == 0);
         ss   = c & pm;
         thit = (gpu_x_op >= 4'd13) && (ss == (gpu_x_transp & pm));
         gpu_rgn_dst(dpa, gpu_x_bl);
         gpu_d9_dst(dpa, gpu_x_bl);
         gpu_touch_px(dpa, gpu_x_bl);
         gpu_alw_mark(dpa, gpu_x_bl);
         if (thit || bskip) begin
            if (thit) gpu_exp_transp = gpu_exp_transp + 1;
            gpu_rec_px(dpa, 1'b0, 32'h0);
         end else begin
            dd = gpu_get_px(dpa, gpu_x_bl);
            if (gpu_x_rmp_on(gpu_x_op)) gpu_rmp_lookup(gpu_x_rdst(gpu_x_op) ? dd : ss, ss);
            case (gpu_x_op)
              4'd0:  rr = ss;
              4'd1:  rr = ~ss;
              4'd2:  rr = ~dd;
              4'd3:  rr = ss & dd;
              4'd4:  rr = ss | dd;
              4'd5:  rr = ss ^ dd;
              4'd6:  rr = ~(ss & dd);
              4'd7:  rr = ~(ss | dd);
              4'd8:  rr = ~(ss ^ dd);
              4'd9:  rr = ~ss & dd;
              4'd10: rr = ss & ~dd;
              4'd11: rr = ~ss | dd;
              4'd12: rr = ss | ~dd;
              4'd13: rr = 32'h0;
              4'd14: rr = 32'hFFFF_FFFF;
              default: rr = ss;
            endcase
            if (gpu_x_blend) rr = gpu_blend_px((gpu_x_op >= 4'd13) ? rr : ss, dd, al);
            gpu_rec_px(dpa, 1'b1, rr);
            gpu_set_px(dpa, gpu_x_bl, rr & pm);
            if (gpu_ln_np <= GPU_LN_MAX) gpu_ln_wr[gpu_ln_np - 1] = 1'b1;
            gpu_ln_ndrawn = gpu_ln_ndrawn + 1;
            gpu_acc_dst(dpa >> (5 - gpu_x_bl), gpu_x_needs_dst(1'b0));
         end
      end
   end
endtask

// Model of a decoded EXEC_FILL LINE from the pen to (x1, y1) (12.4)
task gpu_d_line;
   input  [3:0] op;
   input  [3:0] opt;
   input integer x1;
   input integer y1;
   integer       x0, y0, a0, b0, a1, b1, dd, d, k, n, p, q, pp0, qq0, pp1, qq1, sp;
   integer       dp, dq, gs, i0, i1, d0, mm, tt, r, f;
   reg signed [63:0] gs64;
   reg           xm, aa, pbit;
   reg    [31:0] c;
   begin
      x0 = gpu_m_pen_x;
      y0 = gpu_m_pen_y;
      gpu_m_pen_x = x1;
      gpu_m_pen_y = y1;
      gpu_x_setup(GPU_FILL, op, 3'b000, 3'b000);
      gpu_x_aux(GPU_FILL);
      aa = opt[0] && (GPU_BLEND_EN != 0) && (gpu_x_bl == 4);
      if (aa) gpu_x_blend = 1'b1;                                  // the coverage alpha
      if (opt[3]) gpu_m_lph = 0;
      gpu_ln_n      = 0;
      gpu_ln_np     = 0;
      gpu_ln_ndrawn = 0;
      if (gpu_x_xy) begin
         gpu_acc_begin;
         gpu_d9_on = gpu_x_rmp_on(gpu_x_op);
         gpu_aux_begin;
         if (!aa) begin
            a0 = x0 >>> 4; b0 = y0 >>> 4; a1 = x1 >>> 4; b1 = y1 >>> 4;
            xm = ((a1 > a0) ? (a1 - a0) : (a0 - a1)) >= ((b1 > b0) ? (b1 - b0) : (b0 - b1));
            if (xm) begin pp0 = a0; qq0 = b0; pp1 = a1; qq1 = b1; end
            else    begin pp0 = b0; qq0 = a0; pp1 = b1; qq1 = a1; end
            dd = (pp1 >= pp0) ? (pp1 - pp0) : (pp0 - pp1);
            sp = (pp1 >= pp0) ? 1 : -1;
            n  = opt[1] ? dd : (dd + 1);
            for (k = 0; k < n; k = k + 1) begin
               p = pp0 + sp * k;
               // round(qq0 + k (qq1 - qq0) / dd), an exact half down: ceil((2 k dq - dd) / (2 dd))
               q = (dd == 0) ? qq0 : (qq0 - gpu_fdiv(-(2 * k * (qq1 - qq0) - dd), 2 * dd));
               pbit = gpu_m_lpat[gpu_m_lph];
               gpu_m_lph = (gpu_m_lph + 1) % gpu_m_llen;
               c = pbit ? gpu_x_fill : gpu_x_transp;
               if (pbit || opt[2]) begin
                  if (xm) gpu_ln_px(p, q, c, -1); else gpu_ln_px(q, p, c, -1);
               end
            end
         end else begin
            xm = ((x1 > x0) ? (x1 - x0) : (x0 - x1)) >= ((y1 > y0) ? (y1 - y0) : (y0 - y1));
            if (xm) begin pp0 = x0; qq0 = y0; pp1 = x1; qq1 = y1; end
            else    begin pp0 = y0; qq0 = x0; pp1 = y1; qq1 = x1; end
            dp = pp1 - pp0;
            dq = qq1 - qq0;
            if (dp == 0) gs = 0;
            else begin
               // (in 64 bits: |dq| 2^16 passes 2^31 from |dq| = 2 048 pixels)
               gs64 = ((((dq < 0) ? -dq : dq) * 64'sd65536) / ((dp < 0) ? -dp : dp));
               gs   = gs64;
               if (dq < 0) gs = -gs;
            end
            i0 = pp0 >>> 4;
            i1 = pp1 >>> 4;
            sp = (dp < 0) ? -1 : 1;
            n  = ((i1 >= i0) ? (i1 - i0) : (i0 - i1)) + (opt[1] ? 0 : 1);
            d0 = sp * (16 * i0 + 8 - pp0);
            mm = qq0 * 4096 + gpu_fdiv(gs * d0, 16);
            for (k = 0; k < n; k = k + 1) begin
               tt = mm + k * gs - 32768;
               r  = tt >>> 16;
               f  = (tt & 32'hFFFF) >> 8;
               p  = i0 + sp * k;
               pbit = gpu_m_lpat[gpu_m_lph];
               gpu_m_lph = (gpu_m_lph + 1) % gpu_m_llen;
               c = pbit ? gpu_x_fill : gpu_x_transp;
               if (pbit || opt[2]) begin
                  if (xm) begin gpu_ln_px(p, r, c, 255 - f); gpu_ln_px(p, r + 1, c, f); end
                  else    begin gpu_ln_px(r, p, c, 255 - f); gpu_ln_px(r + 1, p, c, f); end
               end
            end
         end
         gpu_ln_n = n;
         gpu_acc_end;
         gpu_d9_on = 1'b0;
      end
   end
endtask


//============================================================================
// Word-level stream model (the random command stream test, gpu_rstream)
//   doc/gpu_commands.md, command stream / errors / command lists. The test
//   logs every word the FIFO accepted (gpu_sm_push): the pushed-stream parser
//   gives it its kind as it is pushed (command, operand, immediate data of an
//   EXEC, or the operand of a command cut by a flush, which the GPU
//   discards). gpu_sm_run then decodes the log up to the position the GPU had
//   reached (the test reads it: GPU_STAT.USED and GPU_LIST, latched in the
//   cycle of a flush): each command word sets its half of the settings, each
//   operand its own; the error causes in their precedence with the record
//   (ERR_OPCODE, ERR_CAUSE, GPU_ERR, GPU_LIST); CALL lists read from the
//   shadow; every EXEC through the gpu_d_* models; FENCE, RESET_STATE.
//   gpu_sm_flush applies a flush to the decoder, gpu_sm_pflush to the parser,
//   gpu_sm_discard a DISCARD (its marker logged as a word).
//   Spec points this model takes where the text is silent (the RTL's choice):
//   - any flush ends a command list, ABORT in ERR included;
//   - a DELTA moves both the address-mode base and the 16-pbit x position,
//     whatever the mode (a cut SET_DST changing the mode shows it);
//   - after ERR_CAUSE 5 / 6 BUSY falls once nothing is queued;
//   - the data words an immediate rectangle takes are the ones the GPU had
//     taken from the FIFO at a flush (GPU_STAT.USED), and a word taken in the
//     flush's own cycle (gpu_sm_iadj): after CLEAR_ERR the rectangle reads 0
//     for the others.
//============================================================================
localparam integer GPU_SQ_MAX = 131072;
reg         [31:0] gpu_sq_w [0:GPU_SQ_MAX-1];
reg          [2:0] gpu_sq_k [0:GPU_SQ_MAX-1];   // 0 command, 1 operand, 2 data, 3 discarded operand,
                                                // 4 DISCARD marker, 5 ... cutting an immediate rectangle
integer            gpu_sq_o [0:GPU_SQ_MAX-1];   // data: log index of the EXEC taking it (-1: dropped)
integer            gpu_sq_n = 0;                // words logged
integer            gpu_sm_q = 0;                // next logged word to decode
// pushed-stream parser
reg                gpu_pp_owe  = 1'b0;          // the next word pushed is an operand
reg                gpu_pp_skip = 1'b0;          // ... which the GPU discards (cut command)
reg                gpu_pp_nsel = 1'b0;          // ... which is the N of a SET_SRC IMM
reg                gpu_pp_arm  = 1'b0;          // N held: the next copy / EXPAND pushed takes it
reg                gpu_pp_drop = 1'b0;          // the data words still owed are dropped (flushed)
integer            gpu_pp_nv   = 0;
integer            gpu_pp_act  = 0;             // data words owed
integer            gpu_pp_own  = -1;
// decoder
localparam integer GPU_SM_CMD = 0, GPU_SM_OPND = 1, GPU_SM_ERR = 2;
integer            gpu_sm_st   = 0;
reg         [31:0] gpu_sm_cw   = 32'h0;         // the command whose operand is next
reg                gpu_sm_cwl  = 1'b0;          // ... a list word
reg                gpu_sm_lact = 1'b0;          // a list being executed
integer            gpu_sm_lptr = 0;             // its next word address
integer            gpu_sm_lleft = 0;            // its words left
reg          [3:0] gpu_sm_eop  = 4'h0;          // ERR_OPCODE
reg          [2:0] gpu_sm_ecause = 3'h0;        // ERR_CAUSE
reg         [31:0] gpu_sm_eword = 32'h0;        // GPU_ERR
integer            gpu_sm_elist = 0;            // GPU_LIST in ERR (0: not in a list)
reg         [23:0] gpu_sm_fence = 24'h0;        // GPU_FENCE
reg                gpu_sm_firq = 1'b0;          // a FENCE with IRQ reached (since gpu_sm_irq_clr)
reg                gpu_sm_eirq = 1'b0;          // an error raised
reg                gpu_sm_dirq = 1'b0;          // an EXEC completed (GPU_DONE, when nothing was flushed)
reg                gpu_sm_bad  = 1'b0;
reg                gpu_sm_nochk = 1'b0;
integer            gpu_sm_iadj  = 0;            // data words taken in the flush's own cycle (gpu_sm_imm_data)         // gpu_sm_run: one more word allowed (the GPU stopped on it)          // an inconsistency was reported (the log is out of step)
integer            gpu_sm_nx   = 0;             // EXECs decoded (statistics)
integer            gpu_sm_nmrk = 0;             // DISCARD markers decoded (statistics)
integer            gpu_sm_xk [0:255];           // kind of each EXEC of the stream record (gpu_sr_ex)
reg                gpu_sm_oob  = 1'b0;          // an EXEC of the run faulted (ERR_CAUSE 5)
reg                gpu_sm_oobr = 1'b0;          // ... its record made
reg         [31:0] gpu_sm_oobw = 32'h0;         // ... its EXEC word
reg         [31:0] gpu_sm_lastx = 32'h0;        // the last EXEC word decoded
// kinds of EXEC for the record: 0 FILL, 1 COPY, 2 COPY_TRANSP, 3 SPAN, 4 EXPAND,
// 5 TEXSPAN, 6 TEXRECT, 7 TRI, 8 textured TRI, 9 LINE, 10 AA LINE
localparam integer GPU_SM_NK = 11;
reg          [7:0] gpu_sm_xf [0:255];           // features of each EXEC of the record (gpu_sm_cmd)
reg          [7:0] gpu_sm_xa [0:255];           // ... alpha / filter features (gpu_sm_xtail)
integer            gpu_sm_clip0 = 0;
reg                gpu_sm_ximm  = 1'b0;

task gpu_sm_reset;                         // the stream state of a GPU just enabled
   begin
      gpu_sq_n    = 0;
      gpu_sm_q    = 0;
      gpu_pp_owe  = 1'b0;
      gpu_pp_skip = 1'b0;
      gpu_pp_nsel = 1'b0;
      gpu_pp_arm  = 1'b0;
      gpu_pp_drop = 1'b0;
      gpu_pp_act  = 0;
      gpu_pp_own  = -1;
      gpu_sm_st   = GPU_SM_CMD;
      gpu_sm_lact = 1'b0;
      gpu_k_imm   = 1'b0;
   end
endtask

// Encoding: the command word takes an operand (whatever the build)
function gpu_sm_has_opnd;
   input [31:0] w;
   begin
      case (w[31:28])
        OP_SET_SRC, OP_SET_DST, OP_SET_FILL, OP_SET_TRANSP, OP_CALL: gpu_sm_has_opnd = 1'b1;
        GPU_FILL:   gpu_sm_has_opnd = w[24];                 // LINE: its end point
        OP_SET_EXT: gpu_sm_has_opnd = (w[27:24] == EXT_SET_UV) || (w[27:24] == EXT_SET_STEP) ||
                                       (w[27:24] == EXT_SET_CLIP) || (w[27:24] == EXT_SET_STEP_ROW) ||
                                       (w[27:24] == 4'd9) || (w[27:24] == 4'd10) || (w[27:24] == 4'd11) ||
                                       (w[27:24] == EXT_SET_GRGB) || (w[27:24] == EXT_SET_AUX);
        default:    gpu_sm_has_opnd = 1'b0;
      endcase
   end
endfunction

// The FIFO accepted word w: log it with its kind (pushed-stream parser)
task gpu_sm_push;
   input  [31:0] w;
   output  [1:0] kind;
   begin
      if (gpu_sq_n >= GPU_SQ_MAX) begin                         // reported once: the test stops pushing
         if (!gpu_sm_bad) begin
            $display("ERROR: GPU model -- stream log overflow: %0d words since the last checkpoint, model at word %0d, %0d data words owed (test bug) %t",
                     gpu_sq_n, gpu_sm_q, gpu_pp_act, $time);
            error = error + 1;
         end
         gpu_sm_bad = 1'b1;
         gpu_sq_n   = GPU_SQ_MAX - 1;
      end
      gpu_sq_o[gpu_sq_n] = -1;
      if (gpu_pp_act > 0) begin                                 // immediate data
         kind = 2'd2;
         gpu_sq_o[gpu_sq_n] = gpu_pp_drop ? -1 : gpu_pp_own;
         gpu_pp_act = gpu_pp_act - 1;
      end else if (gpu_pp_owe) begin                            // an operand
         kind = gpu_pp_skip ? 2'd3 : 2'd1;
         if (gpu_pp_nsel && !gpu_pp_skip) begin
            gpu_pp_nv  = w[23:0];
            gpu_pp_arm = 1'b1;
         end
         gpu_pp_owe  = 1'b0;
         gpu_pp_skip = 1'b0;
         gpu_pp_nsel = 1'b0;
      end else begin                                            // a command
         kind = 2'd0;
         gpu_pp_owe = gpu_sm_has_opnd(w);
         if (GPU_IMM_EN != 0) begin
            if (w[31:28] == OP_SET_SRC) begin
               gpu_pp_nsel = w[20];
               gpu_pp_arm  = 1'b0;
            end else if (gpu_pp_arm && ((w[31:28] == GPU_COPY) || (w[31:28] == GPU_COPYT) ||
                                        (w[31:28] == OP_EXEC_EXP))) begin
               gpu_pp_arm  = 1'b0;
               gpu_pp_act  = gpu_pp_nv;
               gpu_pp_own  = gpu_sq_n;
               gpu_pp_drop = 1'b0;
            end
         end
      end
      gpu_sq_w[gpu_sq_n] = w;
      gpu_sq_k[gpu_sq_n] = {1'b0, kind};
      gpu_sq_n = gpu_sq_n + 1;
   end
endtask

// GPU_CTRL.DISCARD, as the pushed-stream parser sees it (after the flush of
// the same write, gpu_sm_pflush; with_fl: there was one; in_err: the GPU was
// in ERR). The stream is partial with an operand or data owed or the source
// armed (N pushed); the parser then resynchronises. A marker is logged at the
// cut when it was partial, without a flush and outside ERR (mrk: 1 queued,
// cut: it cuts an immediate rectangle's data).
task gpu_sm_discard;
   input         with_fl;
   input         in_err;
   output        mrk;
   output        cut;
   begin
      mrk = (gpu_pp_owe || (gpu_pp_act > 0) || gpu_pp_arm) && !with_fl && !in_err;
      cut = mrk && (gpu_pp_act > 0);
      if (mrk) begin
         gpu_sq_o[gpu_sq_n] = cut ? gpu_pp_own : -1;
         gpu_sq_w[gpu_sq_n] = 32'h0;
         gpu_sq_k[gpu_sq_n] = cut ? 3'd5 : 3'd4;
         gpu_sq_n = gpu_sq_n + 1;
      end
      gpu_pp_owe  = 1'b0;
      gpu_pp_skip = 1'b0;
      gpu_pp_nsel = 1'b0;
      gpu_pp_arm  = 1'b0;
      gpu_pp_act  = 0;
   end
endtask

// A flush, as the pushed-stream parser sees it (kind 0 CLEAR_ERR, 1 ABORT,
// 2 GPU_EN = 0, 3 both bits; in_err: the GPU was in ERR). CLEAR_ERR / ABORT
// discard the operand still owed when it comes, keep the data count (the
// words still pushed are dropped) and disarm; in ERR an ABORT alone leaves
// this to the CLEAR_ERR. GPU_EN = 0 drops all of it.
task gpu_sm_pflush;
   input integer kind;
   input         in_err;
   begin
      if (kind == 2) begin
         gpu_pp_owe  = 1'b0;
         gpu_pp_skip = 1'b0;
         gpu_pp_nsel = 1'b0;
         gpu_pp_arm  = 1'b0;
         gpu_pp_act  = 0;
      end else if (!(in_err && (kind == 1))) begin
         if (gpu_pp_owe) gpu_pp_skip = 1'b1;
         gpu_pp_nsel = 1'b0;
         gpu_pp_arm  = 1'b0;
         gpu_pp_drop = 1'b1;
      end
   end
endtask

// The decoder model refuses or takes a command word
reg gpu_sm_ok;                              // gpu_sm_cmd: taken

task gpu_sm_err;
   input  [3:0] opc;
   input  [2:0] cause;
   input [31:0] word;
   input integer lst;
   begin
      gpu_sm_st     = GPU_SM_ERR;
      gpu_sm_eop    = opc;
      gpu_sm_ecause = cause;
      gpu_sm_eword  = word;
      gpu_sm_elist  = lst;
      gpu_sm_eirq   = 1'b1;
   end
endtask

// Immediate data of the EXEC at log index xi: the words the GPU took before
// log index lim
task gpu_sm_imm_data;
   input integer xi;
   input integer lim;
   integer       jj;
   begin
      gpu_imm_n = 0;
      for (jj = xi + 1; (jj < lim + gpu_sm_iadj) && (jj < gpu_sq_n); jj = jj + 1)
         if ((gpu_sq_k[jj] == 3'd2) && (gpu_sq_o[jj] == xi) && (gpu_imm_n < GPU_IMM_MAX)) begin
            gpu_imm_buf[gpu_imm_n] = gpu_sq_w[jj];
            gpu_imm_n = gpu_imm_n + 1;
         end
   end
endtask

task gpu_sm_reset_state;                   // RESET_STATE: the model's settings (gpu_c_reset_state)
   begin
      gpu_m_aen = 1'b0;  gpu_m_a = 8'h00;  gpu_m_mix5 = 1'b0;  gpu_m_abase = 32'h0;
      gpu_m_bil = 1'b0;  gpu_m_tbord = 1'b0;
      gpu_m_src_base = 32'h0;  gpu_m_dst_base = 32'h0;  gpu_m_dst_org = 32'h0;
      gpu_m_src_pitch = 16'h0; gpu_m_src_fmt = 4'h0;    gpu_m_dst_pitch = 16'h0;
      gpu_m_w = 1;  gpu_m_h = 1;  gpu_m_fill = 16'h0;  gpu_m_transp = 16'h0;
      gpu_m_xy = 1'b0;  gpu_m_x = 0;  gpu_m_y = 0;
      gpu_m_cx0 = -2048;  gpu_m_cy0 = -2048;  gpu_m_cx1 = 2047;  gpu_m_cy1 = 2047;
      gpu_m_gen = 1'b0;  gpu_m_gaxis = 1'b0;  gpu_m_gn = 0;  gpu_m_gstep = 0;
      gpu_m_grgb = 1'b0;  gpu_m_gdr = 0;  gpu_m_gdg = 0;  gpu_m_gdb = 0;
      gpu_t_lw = 4'd0;  gpu_t_lh = 4'd0;  gpu_t_ten = 1'b0;  gpu_t_free = 1'b0;  gpu_t_bound = 1'b0;
      gpu_t_sw = 3'b000;  gpu_t_shade = 8'h00;  gpu_t_rmp = 2'd0;
      gpu_t_u0 = 16'h0;  gpu_t_v0 = 16'h0;  gpu_t_du = 16'h0;  gpu_t_dv = 16'h0;
      gpu_t_dur = 16'h0;  gpu_t_dvr = 16'h0;  gpu_t_tw = 0;  gpu_t_th = 0;
      gpu_m_rbase = 32'h0;  gpu_m_mbase = 32'h0;  gpu_m_minv = 1'b0;
      gpu_m_pen_x = 0;  gpu_m_pen_y = 0;  gpu_m_lpat = 32'hFFFF_FFFF;  gpu_m_llen = 32;  gpu_m_lph = 0;
      for (gpu_i = 0; gpu_i < 3; gpu_i = gpu_i + 1) begin
         gpu_tv_x[gpu_i] = 0;
         gpu_tv_y[gpu_i] = 0;
      end
   end
endtask

// Decode command word w (lst: its list word address, or -1 from the FIFO;
// last: the list's last word; xi: its log index; lim: the decode limit, for
// the immediate data)
task gpu_sm_cmd;
   input [31:0] w;
   input integer lst;
   input         last;
   input integer xi;
   input integer lim;
   reg     [3:0] opc, sub, fmtv;
   reg     [3:0] sel;
   reg     [1:0] rf;
   reg           inl, has, valid, absent, fmt, rsv, imminv, cut, xy_u, af_u, tri_u, rf_fld, ln_u, lnw, bil_u, a8inv;
   reg    [13:0] d14;
   integer       kk;
   begin
      inl    = (lst >= 0);
      opc    = w[31:28];
      sub    = w[27:24];
      sel    = w[23:20];
      xy_u   = (GPU_XY_EN != 0);
      af_u   = (GPU_XY_EN != 0);
      tri_u  = (GPU_TRI_EN != 0) && (GPU_XY_EN != 0);
      ln_u   = (GPU_LINE_EN != 0) && (GPU_XY_EN != 0);
      bil_u  = (GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0);
      lnw    = (opc == GPU_FILL) && w[24];               // an EXEC_FILL LINE word
      rf_fld = (opc == GPU_FILL) || (opc == GPU_COPY) || (opc == GPU_COPYT) || (opc == OP_EXEC_EXP) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_TEX));
      rf     = ((opc == OP_SET_EXT) && (sub == EXT_SET_TEX)) ? w[15:14] : w[13:12];
      // defined commands
      case (opc)
        4'h0:       valid = 1'b0;
        GPU_FILL:   valid = !(w[24] && w[7]);           // LINE and TRI together
        OP_SET_EXT: valid = (sub != 4'd14) && !((sub == EXT_SET_AUX) && (sel > 4'd5)) &&
                            !((sub == EXT_SET_EXT2) && (w[23:16] != X2_WAIT_REFR) && (w[23:16] != X2_RESET_STATE));
        OP_CALL:    valid = !inl;
        default:    valid = 1'b1;
      endcase
      // an absent feature (ERR_CAUSE 2)
      absent = ((opc == OP_SET_DST) && w[16] && !xy_u) ||
               ((opc == OP_SET_EXT) && (((sub == EXT_SET_XY) || (sub == EXT_SET_CLIP)) && !xy_u)) ||
               ((opc == OP_SET_EXT) && (((sub == EXT_SET_STEP_ROW) || (sub == EXT_SET_TEXBOX)) && !af_u)) ||
               ((opc == OP_SET_EXT) && (((sub == EXT_SET_GRAD) || (sub == EXT_SET_GRGB)) && (GPU_GRAD_EN == 0))) ||
               ((opc == OP_SET_EXT) && (sub == 4'd8) && (GPU_BLEND_EN == 0)) ||
               ((opc == OP_SET_EXT) && ((sub == 4'd9) || (sub == 4'd10) || (sub == 4'd11)) && !tri_u) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_TEX) && w[13] && !af_u) ||
               ((opc == OP_EXEC_TEXRECT) && !af_u) ||
               (((opc == GPU_FILL) || (opc == OP_EXEC_TEXRECT)) && w[7] && !tri_u) ||
               ((opc == OP_SET_SRC) && w[20] && (GPU_IMM_EN == 0)) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_AUX) && (sel == 4'd0) && (GPU_REMAP_EN == 0)) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_AUX) && (sel == 4'd1) &&
                ((GPU_MPLANE_EN == 0) || (w[15:0] != 16'h0))) ||
               (rf_fld && ((rf == 2'd1) || (rf == 2'd2)) && (GPU_REMAP_EN == 0)) ||
               (((opc == GPU_COPY) || (opc == GPU_COPYT)) && w[11] && (GPU_MPLANE_EN == 0)) ||
               ((opc == OP_EXEC_EXP) && w[3] && (GPU_BLEND_EN == 0)) ||
               (lnw && (!ln_u || (w[16] && (GPU_BLEND_EN == 0)))) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_AUX) && ((sel == 4'd2) || (sel == 4'd3)) && !ln_u) ||
               // RGB565A8 and the alpha plane: blend builds; ALPHA_PLANE PITCH != 0 in every build;
               // TEX_FILTER: bilinear built, TBORDER with blending
               ((opc == OP_SET_SRC) && (w[19:16] == 4'd5) && (GPU_BLEND_EN == 0)) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_AUX) && (sel == 4'd4) &&
                ((GPU_BLEND_EN == 0) || (w[15:0] != 16'h0))) ||
               ((opc == OP_SET_EXT) && (sub == EXT_SET_AUX) && (sel == 4'd5) &&
                (!bil_u || (w[1] && (GPU_BLEND_EN == 0))));
      // formats (ERR_CAUSE 3): checked against SRC_FMT as set
      fmtv   = gpu_m_src_fmt;
      fmt    = ((opc == OP_SET_SRC) && (w[19:16] > 4'd5)) ||
               ((opc == OP_SET_DST) && (w[19:17] != 3'd0)) ||
               ((opc == OP_EXEC_EXP) && ((fmtv == 4'd0) || (fmtv == 4'd5))) ||
               (((opc == GPU_COPY) || (opc == GPU_COPYT) || (opc == OP_EXEC_TEX) || (opc == OP_EXEC_TEXRECT)) &&
                (fmtv != 4'd0) && (fmtv != 4'd5));
      // RGB565A8 copies: no mask plane (MPLANE built), no immediate source (cause 1)
      a8inv  = ((opc == GPU_COPY) || (opc == GPU_COPYT)) && (fmtv == 4'd5) &&
               ((w[11] && (GPU_MPLANE_EN != 0)) || ((GPU_IMM_EN != 0) && gpu_k_imm));
      rsv    = rf_fld && (rf == 2'd3);
      imminv = (GPU_IMM_EN != 0) &&
               (((opc == OP_SET_SRC) && w[20] && inl) ||
                (gpu_k_imm && inl && ((opc == GPU_COPY) || (opc == GPU_COPYT) || (opc == OP_EXEC_EXP))) ||
                (gpu_k_imm && !inl && ((opc == GPU_COPY) || (opc == GPU_COPYT)) && (w[10:8] != 3'b000)));
      // the operand of a word refused for its sub-command / SEL / PITCH, or a
      // CALL in a list, is never taken: such a word is never a list cut
      has    = gpu_sm_has_opnd(w) && !((opc == OP_CALL) && inl) &&
               !((opc == OP_SET_EXT) && (sub != EXT_SET_AUX) && absent) &&
               !((opc == OP_SET_EXT) && (sub == EXT_SET_AUX) && (absent || (sel > 4'd5))) &&
               !(lnw && (absent || w[7]));                 // a LINE refused (absent, with TRI)
      cut    = inl && last && has;
      gpu_sm_ok = 1'b0;
      if (cut)
         gpu_sm_err(OP_CALL, 3'd4, w, lst);
      else if (fmt)
         gpu_sm_err(opc, 3'd3, w, inl ? lst : 0);
      else if (absent)
         gpu_sm_err(opc, 3'd2, w, inl ? lst : 0);
      else if (!valid || rsv || imminv || a8inv)
         gpu_sm_err(opc, 3'd1, w, inl ? lst : 0);
      else begin
         gpu_sm_ok = 1'b1;
         if (has) begin
            gpu_sm_st  = GPU_SM_OPND;
            gpu_sm_cw  = w;
            gpu_sm_cwl = inl;
         end
         if ((opc >= GPU_FILL) && (opc <= OP_EXEC_TEXRECT)) begin
            gpu_sm_eword = w;                              // GPU_ERR: the last EXEC
            gpu_sm_lastx = w;
            gpu_sm_nx    = gpu_sm_nx + 1;
            gpu_oob_hit  = 1'b0;
            gpu_sm_clip0 = gpu_exp_clip;
            gpu_x_imm    = 1'b0;
            gpu_x_mpl    = 1'b0;
            gpu_x_rmp    = 2'd0;
            gpu_x_gen    = 1'b0;
            gpu_x_blend  = 1'b0;
            gpu_x_a8     = 1'b0;
            gpu_x_bilx   = 1'b0;
         end
         gpu_sm_ximm = 1'b0;
         if (gpu_sm_oob && (opc >= GPU_FILL) && (opc <= OP_EXEC_TEXRECT)) begin
            // decoded after a rectangle faulted past the VRAM: its settings, no drawing
            if (!lnw) begin                                // (a line: at its operand)
               gpu_sm_xk[gpu_sr_xn & 255] = 0;
               gpu_sr_xn = gpu_sr_xn + 1;
            end
            if ((opc == OP_EXEC_SPAN) || (opc == OP_EXEC_EXP) || (opc == OP_EXEC_TEX) ||
                ((opc == OP_EXEC_TEXRECT) && !(w[7] && tri_u))) gpu_m_move(w[27:14]);
            if ((opc == OP_EXEC_SPAN) || (opc == OP_EXEC_TEX)) begin
               gpu_m_w = ((w[13:0] & GPU_DIM_MASK) == 0) ? 1 : (w[13:0] & GPU_DIM_MASK);
               gpu_m_h = 1;
            end
            if ((opc == GPU_COPY) || (opc == GPU_COPYT) || (opc == OP_EXEC_EXP)) gpu_k_imm = 1'b0;
            opc = 4'h0;                                    // (nothing more below)
         end
         case (opc)
           OP_SET_SRC: begin
                          gpu_m_src_pitch = w[15:0];
                          gpu_m_src_fmt   = w[19:16];
                          if (!inl && (GPU_IMM_EN != 0)) gpu_k_imm = w[20];
                       end
           OP_SET_DST: begin
                          gpu_m_dst_pitch = w[15:0];
                          gpu_m_xy        = w[16];
                          gpu_m_xyp       = (w[15:0] == 16'h0) ? gpu_m_dispw : w[15:0];
                       end
           OP_SET_SIZE: begin
                          gpu_m_w = ((w[13:0] & GPU_DIM_MASK) == 0) ? 1 : (w[13:0] & GPU_DIM_MASK);
                          gpu_m_h = ((w[27:14] & GPU_DIM_MASK) == 0) ? 1 : (w[27:14] & GPU_DIM_MASK);
                       end
           OP_SET_EXT: case (sub)
                          EXT_SET_TEX: begin
                                          gpu_t_lw = w[3:0];  gpu_t_lh = w[7:4];  gpu_t_ten = w[8];
                                          gpu_t_sw = w[11:9]; gpu_t_free = w[12]; gpu_t_bound = w[13];
                                          gpu_t_rmp = w[15:14]; gpu_t_shade = w[23:16];
                                       end
                          EXT_SET_XY:  begin
                                          gpu_m_x   = gpu_sx12(w[11:0]);
                                          gpu_m_y   = gpu_sx12(w[23:12]);
                                          gpu_m_xyp = (gpu_m_dst_pitch == 16'h0) ? gpu_m_dispw : gpu_m_dst_pitch;
                                       end
                          EXT_SET_CLIP: begin
                                          gpu_m_cx0 = gpu_sx12(w[11:0]);
                                          gpu_m_cy0 = gpu_sx12(w[23:12]);
                                       end
                          EXT_SET_TEXBOX: begin
                                          gpu_t_tw = w[11:0];
                                          gpu_t_th = w[23:12];
                                       end
                          EXT_SET_GRAD: begin
                                          gpu_m_gn    = w[11:0];
                                          gpu_m_gaxis = w[12];
                                          gpu_m_gstep = w[16] ? ({28'h0, w[16:13]} - 16) : {28'h0, w[16:13]};
                                          gpu_m_gen   = w[17];
                                          gpu_m_grgb  = w[18];
                                       end
                          4'd8:        begin
                                          gpu_m_a    = w[7:0];
                                          gpu_m_aen  = w[8];
                                          gpu_m_mix5 = w[9];
                                       end
                          EXT_SET_AUX: if (sel == 4'd1) gpu_m_minv = w[16];
                                       else if (sel == 4'd5) begin   // the filter: at the word
                                          gpu_m_bil   = w[0];
                                          gpu_m_tbord = w[1];
                                       end
                                       else if (sel == 4'd3) begin
                                          gpu_m_llen = w[4:0] + 1;
                                          gpu_m_lph  = 0;
                                       end
                          EXT_SET_EXT2: if (w[23:16] == X2_RESET_STATE) gpu_sm_reset_state;
                          default: ;
                        endcase
           OP_CALL:     ;                                  // N with the operand
           GPU_FILL:    if (!lnw) begin                // (a line: drawn at its operand)
                          gpu_k_rmp = w[13:12];
                          gpu_k_mpl = 1'b0;
                          gpu_sm_xk[gpu_sr_xn & 255] = (w[7] && tri_u) ? 7 : 0;
                          if (w[7] && tri_u) gpu_d_trifill(w[3:0]);
                          else               gpu_d_exec(GPU_FILL, w[3:0], w[6:4], 3'b000);
                          gpu_sr_xn = gpu_sr_xn + 1;
                          gpu_k_rmp = 2'd0;
                       end
           GPU_COPY, GPU_COPYT:
                       begin
                          gpu_k_rmp = w[13:12];
                          gpu_k_mpl = w[11];
                          if (gpu_k_imm) gpu_sm_imm_data(xi, lim);
                          gpu_sm_xk[gpu_sr_xn & 255] = (opc == GPU_COPY) ? 1 : 2;
                          gpu_d_exec(opc, w[3:0], w[6:4], w[10:8]);
                          gpu_sr_xn = gpu_sr_xn + 1;
                          gpu_k_rmp = 2'd0;
                          gpu_k_mpl = 1'b0;
                          gpu_sm_ximm = gpu_x_imm;
                          gpu_x_imm = 1'b0;
                       end
           OP_EXEC_SPAN: begin
                          gpu_sm_xk[gpu_sr_xn & 255] = 3;
                          gpu_d_span(w[27:14], w[13:0]);
                          gpu_sr_xn = gpu_sr_xn + 1;
                       end
           OP_EXEC_EXP: begin
                          gpu_k_rmp    = w[13:12];
                          gpu_exp_op   = w[11:8];
                          gpu_exp_mask = w[3];
                          if (gpu_k_imm) gpu_sm_imm_data(xi, lim);
                          gpu_sm_xk[gpu_sr_xn & 255] = 4;
                          fmtv = gpu_m_src_fmt - 4'd1;
                          gpu_d_expand(w[27:14], w[6:4], w[2], fmtv[1:0]);
                          gpu_sr_xn = gpu_sr_xn + 1;
                          gpu_sm_ximm  = gpu_x_imm;
                          gpu_k_rmp    = 2'd0;
                          gpu_exp_op   = 4'd0;
                          gpu_exp_mask = 1'b0;
                          gpu_x_imm    = 1'b0;
                       end
           OP_EXEC_TEX: begin
                          gpu_sm_xk[gpu_sr_xn & 255] = 5;
                          gpu_d_texspan(w[27:14], w[13:0]);
                          gpu_sr_xn = gpu_sr_xn + 1;
                       end
           OP_EXEC_TEXRECT: begin
                          gpu_sm_xk[gpu_sr_xn & 255] = (w[7] && tri_u) ? 8 : 6;
                          if (w[7] && tri_u) gpu_d_tritex;
                          else               gpu_d_texrect(w[27:14]);
                          gpu_sr_xn = gpu_sr_xn + 1;
                       end
           OP_FENCE:    begin
                          gpu_sm_fence = w[25] ? (gpu_sm_fence + 24'd1) : w[23:0];
                          if (w[24]) gpu_sm_firq = 1'b1;
                       end
           default: ;
         endcase
         if ((opc >= GPU_FILL) && (opc <= OP_EXEC_TEXRECT) && !lnw) gpu_sm_xtail(opc, w, inl);
      end
   end
endtask

// After an EXEC's model (a line: at its operand): its features for the
// record, GPU_DONE, a fault past the VRAM (the line pattern phase to 0)
task gpu_sm_xtail;
   input  [3:0] opc;
   input [31:0] w;
   input        inl;
   begin
      // features of the EXEC (coverage): [0] clipped, [1] remap, [2] mask
      // plane, [3] blend, [4] gradient, [5] immediate, [6] from a list,
      // [7] x/y mode
      gpu_sm_xf[(gpu_sr_xn - 1) & 255] = {gpu_x_xy, inl, gpu_sm_ximm, gpu_x_gen,
                                           gpu_x_blend | ((opc == OP_EXEC_EXP) && w[3] && (gpu_x_bl == 4) && (GPU_BLEND_EN != 0)),
                                           gpu_x_mpl, (gpu_x_rmp != 2'd0) && (gpu_x_bl < 4),
                                           gpu_exp_clip != gpu_sm_clip0};
      // [0] RGB565A8 source, [1] a blend under MIX5 (EN, A8, MASK, AA); bilinear: [2] sampled,
      // [3] BOUND with TBORDER, [4] BOUND clamped, [5] wrapping (power of two, no BOUND)
      gpu_sm_xa[(gpu_sr_xn - 1) & 255] = {2'b00, gpu_x_bilx && !gpu_t_bound && !gpu_t_free,
                                           gpu_x_bilx && gpu_t_bound && !gpu_m_tbord,
                                           gpu_x_bilx && gpu_t_bound && gpu_m_tbord, gpu_x_bilx,
                                           gpu_x_mix5 && (gpu_x_bl == 4) && (gpu_x_blend || gpu_x_bilx ||
                                                          ((opc == OP_EXEC_EXP) && w[3] && (GPU_BLEND_EN != 0))),
                                           gpu_x_a8};
      gpu_sm_dirq = 1'b1;
      if (gpu_oob_hit) begin                               // ERR_CAUSE 5: the EXEC is gone; the decoder
         gpu_sm_oob   = 1'b1;                              // may have gone on (gpu_sm_run ends in ERR)
         gpu_sm_oobw  = w;
         gpu_sm_dirq  = 1'b0;
         gpu_m_lph    = 0;
      end
   end
endtask

// The operand v of the waiting command
task gpu_sm_opnd;
   input [31:0] v;
   reg    [3:0] opc, sub;
   integer      aw, nn;
   begin
      opc = gpu_sm_cw[31:28];
      sub = gpu_sm_cw[27:24];
      gpu_sm_st = GPU_SM_CMD;
      case (opc)
        OP_SET_SRC:    if (!gpu_sm_cw[20]) gpu_m_src_base = v & GPU_PA_MASK;
        OP_SET_DST:    begin
                          gpu_m_dst_base = v & GPU_PA_MASK;
                          gpu_m_dst_org  = v & GPU_PA_MASK;
                          gpu_m_x   = 0;
                          gpu_m_y   = 0;
                          gpu_m_xyp = (gpu_m_dst_pitch == 16'h0) ? gpu_m_dispw : gpu_m_dst_pitch;
                       end
        OP_SET_FILL:   gpu_m_fill   = v[15:0];
        OP_SET_TRANSP: gpu_m_transp = v[15:0];
        GPU_FILL:      begin                               // EXEC_FILL LINE: its end point
                          gpu_sm_xk[gpu_sr_xn & 255] = (gpu_sm_cw[16] && (GPU_BLEND_EN != 0) && (gpu_bl(gpu_m_mode) == 4)) ? 10 : 9;
                          if (gpu_sm_oob) begin               // decoded after a fault: the pen only
                             gpu_m_pen_x = gpu_sx16(v[15:0]);
                             gpu_m_pen_y = gpu_sx16(v[31:16]);
                             gpu_sr_xn = gpu_sr_xn + 1;
                          end else begin
                             gpu_k_rmp = gpu_sm_cw[13:12];
                             gpu_d_line(gpu_sm_cw[3:0], gpu_sm_cw[19:16], gpu_sx16(v[15:0]), gpu_sx16(v[31:16]));
                             gpu_k_rmp = 2'd0;
                             gpu_sr_xn = gpu_sr_xn + 1;          // (its writes: this EXEC's record index)
                             gpu_sm_xtail(GPU_FILL, gpu_sm_cw, gpu_sm_cwl);
                          end
                       end
        OP_CALL:       begin
                          aw = v & ((32'h1 << VRAM_AW) - 32'h1);
                          nn = gpu_sm_cw[23:0];
                          if (nn != 0) begin
                             if ((aw + nn) > VRAM_WORDS)
                                gpu_sm_err(OP_CALL, 3'd6, v, 0);
                             else begin
                                gpu_sm_lact  = 1'b1;
                                gpu_sm_lptr  = aw;
                                gpu_sm_lleft = nn;
                             end
                          end
                       end
        OP_SET_EXT:    case (sub)
                          EXT_SET_UV:       begin gpu_t_u0  = v[31:16]; gpu_t_v0  = v[15:0]; end
                          EXT_SET_STEP:     begin gpu_t_du  = v[31:16]; gpu_t_dv  = v[15:0]; end
                          EXT_SET_STEP_ROW: begin gpu_t_dur = v[31:16]; gpu_t_dvr = v[15:0]; end
                          EXT_SET_CLIP:     begin gpu_m_cx1 = gpu_sx12(v[11:0]); gpu_m_cy1 = gpu_sx12(v[23:12]); end
                          4'd9, 4'd10, 4'd11:
                                            begin
                                               gpu_tv_x[sub - 4'd9] = gpu_sx16(v[15:0]);
                                               gpu_tv_y[sub - 4'd9] = gpu_sx16(v[31:16]);
                                            end
                          EXT_SET_GRGB:     begin
                                               gpu_m_gdr = v[29] ? ({22'h0, v[29:20]} - 1024) : {22'h0, v[29:20]};
                                               gpu_m_gdg = v[19] ? ({22'h0, v[19:10]} - 1024) : {22'h0, v[19:10]};
                                               gpu_m_gdb = v[9]  ? ({22'h0, v[9:0]}   - 1024) : {22'h0, v[9:0]};
                                            end
                          EXT_SET_AUX:      case (gpu_sm_cw[23:20])
                                               4'd0: gpu_m_rbase = (VRAM_AW > 6) ? (v & ((32'h1 << VRAM_AW) - 32'h1) & ~32'h3F) : 32'h0;
                                               4'd1: gpu_m_mbase = v & GPU_PA_MASK;
                                               4'd2: begin gpu_m_pen_x = gpu_sx16(v[15:0]); gpu_m_pen_y = gpu_sx16(v[31:16]); end
                                               4'd3: gpu_m_lpat = v;
                                               4'd4: gpu_m_abase = v & ((32'h1 << (VRAM_AW + 2)) - 32'h1);
                                               default: ;                    // TEX_FILTER: ignored
                                            endcase
                          default: ;
                       endcase
        default: ;
      endcase
   end
endtask

// Decode the log up to word index qlim (exclusive) and the list up to word
// address llim (-1: to its end). Stops in ERR. The decoder must reach qlim
// exactly (else the log and the GPU are out of step: reported).
task gpu_sm_run;
   input integer qlim;
   input integer llim;
   reg    [31:0] w, dw;
   reg           go, dec, dlast, dlist;
   integer       dl, dxi;
   begin
      go  = 1'b1;
      while (go) begin
         dec = 1'b0;
         if (gpu_sm_st == GPU_SM_ERR)
            go = 1'b0;
         else if (gpu_sm_lact) begin
            if ((llim >= 0) && (gpu_sm_lptr >= llim))
               go = 1'b0;
            else begin
               w = (gpu_sm_lptr < VRAM_WORDS) ? gpu_shadow[gpu_sm_lptr] : 32'h0;
               if (gpu_sm_st == GPU_SM_OPND) begin
                  gpu_sm_opnd(w);
                  gpu_sm_lptr  = gpu_sm_lptr + 1;
                  gpu_sm_lleft = gpu_sm_lleft - 1;
                  if (gpu_sm_lleft == 0) gpu_sm_lact = 1'b0;
               end else begin
                  dec = 1'b1;  dlist = 1'b1;  dw = w;  dl = gpu_sm_lptr;  dlast = (gpu_sm_lleft == 1);  dxi = -1;
               end
            end
         end else if (gpu_sm_q >= qlim)
            go = 1'b0;
         else begin
            case (gpu_sq_k[gpu_sm_q])
              3'd0: if (gpu_sm_st == GPU_SM_OPND) begin
                       gpu_sm_out_of_step("an operand expected, the log has a command");
                       gpu_sm_q = gpu_sm_q + 1;
                    end else begin
                       dec = 1'b1;  dlist = 1'b0;  dw = gpu_sq_w[gpu_sm_q];  dl = -1;  dlast = 1'b0;  dxi = gpu_sm_q;
                    end
              3'd1: begin
                       if (gpu_sm_st != GPU_SM_OPND)
                          gpu_sm_out_of_step("a command expected, the log has an operand");
                       else
                          gpu_sm_opnd(gpu_sq_w[gpu_sm_q]);
                       gpu_sm_q = gpu_sm_q + 1;
                    end
              3'd4, 3'd5:                                   // a DISCARD marker: the command waiting for its
                    begin                                   // operand dropped, the source disarmed (an immediate
                       if (gpu_sm_st == GPU_SM_OPND)        // rectangle it cuts: abandoned, its writes a prefix)
                          gpu_sm_st = GPU_SM_CMD;
                       gpu_k_imm = 1'b0;
                       gpu_sm_nmrk = gpu_sm_nmrk + 1;
                       gpu_sm_q = gpu_sm_q + 1;
                    end
              default: gpu_sm_q = gpu_sm_q + 1;             // data, discarded operand
            endcase
         end
         // the one call site of the command decoder (Verilator inlines a task at each)
         if (dec) begin
            gpu_sm_cmd(dw, dl, dlast, dxi, qlim);
            if (gpu_sm_ok) begin
               if (dlist) begin
                  gpu_sm_lptr  = gpu_sm_lptr + 1;
                  gpu_sm_lleft = gpu_sm_lleft - 1;
                  if (gpu_sm_lleft == 0) gpu_sm_lact = 1'b0;
               end else
                  gpu_sm_q = gpu_sm_q + 1;
            end
         end
      end
      if (!gpu_sm_oobhold) gpu_sm_oob_fin;
      if ((gpu_sm_q != qlim) && !gpu_sm_bad && !gpu_sm_nochk)
         gpu_sm_out_of_step("the GPU took a different number of FIFO words");
   end
endtask

// A rectangle that faulted past the VRAM (gpu_sm_oob): its record, which
// replaces the one of a word the decoder refused after it. At a flush the
// test holds it (gpu_sm_oobhold): an ABORT before the fault cancels it.
reg gpu_sm_oobhold = 1'b0;
task gpu_sm_oob_fin;
   begin
      if (gpu_sm_oob && !gpu_sm_oobr) begin
         gpu_sm_oobr = 1'b1;
         if (gpu_sm_st != GPU_SM_ERR) gpu_sm_err(gpu_sm_oobw[31:28], 3'd5, gpu_sm_oobw, 0);
         else begin
            gpu_sm_eop    = gpu_sm_oobw[31:28];
            gpu_sm_ecause = 3'd5;
            gpu_sm_eword  = gpu_sm_oobw;
         end
      end
   end
endtask

task gpu_sm_out_of_step;
   input [8*64-1:0] why;
   begin
      $display("ERROR: GPU stream model -- %0s (model at word %0d of %0d, state %0d) %t", why, gpu_sm_q, gpu_sq_n,
               gpu_sm_st, $time);
      error = error + 1;
      gpu_sm_bad = 1'b1;
   end
endtask

// A flush, as the decoder sees it, once gpu_sm_run has reached its position:
// the FIFO words after it are gone, the list ends, ERR is cleared by CLEAR_ERR
// and GPU_EN = 0 (an ABORT in ERR keeps it and the immediate arm)
task gpu_sm_flush;
   input integer kind;
   begin
      gpu_sm_q    = gpu_sq_n;
      gpu_sm_lact = 1'b0;
      gpu_m_lph   = 0;                                     // the line pattern phase: stream state
      if (!((kind == 1) && (gpu_sm_st == GPU_SM_ERR))) begin
         gpu_sm_st = GPU_SM_CMD;
         gpu_k_imm = 1'b0;
      end
   end
endtask

// The prefix of the recorded writes the VRAM holds (after a flush, an abandon
// or a fault): the largest n such that the image with the first n writes
// equals the VRAM on every recorded word (every such n gives the same image);
// with whole_only n must end an EXEC. The shadow is left at that prefix
// (n = -1: none; the shadow then takes the VRAM's words and the caller reports
// the error).
reg gpu_sr_seen [0:VRAM_WORDS-1];
integer gpu_sr_i;
initial for (gpu_sr_i = 0; gpu_sr_i < VRAM_WORDS; gpu_sr_i = gpu_sr_i + 1) gpu_sr_seen[gpu_sr_i] = 1'b0;

task gpu_sr_cut;
   input          whole_only;
   output integer nbest;
   integer        kk, mm, wa;
   reg            b0, b1, bnd;
   begin
      for (kk = gpu_sr_n - 1; kk >= 0; kk = kk - 1)
         gpu_shadow[gpu_sr_wa[kk]] = gpu_sr_old[kk];
      mm = 0;
      for (kk = 0; kk < gpu_sr_n; kk = kk + 1) begin
         wa = gpu_sr_wa[kk];
         if (!gpu_sr_seen[wa]) begin
            gpu_sr_seen[wa] = 1'b1;
            if (gpu_shadow[wa] !== vram_mem[wa]) mm = mm + 1;
         end
      end
      nbest = (mm == 0) ? 0 : -1;
      for (kk = 0; kk < gpu_sr_n; kk = kk + 1) begin
         wa = gpu_sr_wa[kk];
         b0 = (gpu_shadow[wa] !== vram_mem[wa]);
         gpu_shadow[wa] = gpu_sr_new[kk];
         b1 = (gpu_shadow[wa] !== vram_mem[wa]);
         mm = mm + b1 - b0;
         bnd = (kk + 1 == gpu_sr_n) || (gpu_sr_ex[kk + 1] != gpu_sr_ex[kk]);
         if ((mm == 0) && (!whole_only || bnd)) nbest = kk + 1;
      end
      if (nbest < 0) begin
         for (kk = 0; kk < gpu_sr_n; kk = kk + 1)
            gpu_shadow[gpu_sr_wa[kk]] = vram_mem[gpu_sr_wa[kk]];
      end else
         for (kk = gpu_sr_n - 1; kk >= nbest; kk = kk - 1)
            gpu_shadow[gpu_sr_wa[kk]] = gpu_sr_old[kk];
      for (kk = 0; kk < gpu_sr_n; kk = kk + 1)
         gpu_sr_seen[gpu_sr_wa[kk]] = 1'b0;
   end
endtask
