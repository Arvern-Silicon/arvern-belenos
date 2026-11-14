//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_mplane
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_mplane.v
// Module Description : Mask plane (SET_AUX MASK_PLANE, EXEC_COPY /
//                      COPY_TRANSP [11] MPLANE; skipped when BLNS_CFG2.MPLANE
//                      is 0): a pixel is drawn where its 1-bpp mask bit, at
//                      its source pixel + (mask base - source base), is 1
//                      (0 with INV). Every depth, random source / destination
//                      slots and mask bit offsets (every offset at 1 and 8
//                      bpp), run lengths across mask words, every swap
//                      (mirrors and CL swaps included), every raster
//                      operation (op 2: no source read, the mask still
//                      walked), keyed copies (both tests apply), sparse,
//                      dense and random masks, INV; with GPU_XY_EN, x/y
//                      destinations trimmed by the clip window (the mask
//                      follows the trimmed source). Each copy: the image
//                      against gpu_model.v, the VRAM reads (mask words
//                      included) and writes against its accounting, only
//                      the words of the rectangle and of its mask accessed,
//                      whole 16-bpp pixels in the byte enables. Then: the
//                      mask enable is per EXEC; RESET_STATE clears the
//                      pointer and INV; a mask word past VRAM_WORDS stops the
//                      copy with ERR_CAUSE 5 (a prefix drawn); ABORT and
//                      the debug freeze with mask reads in flight (a clean
//                      prefix; the image completed after the freeze);
//                      SET_AUX pushed while the masked copy before it
//                      draws (with run-ahead decoded during the draw): the
//                      running copy keeps the old mask position and INV,
//                      the next one takes the new ones.
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer MP_P    = 192;                // pitch (pixels; the mask's too, in bits)
localparam integer MP_SLO  = 4096;               // source region: words [4096, 5120)
localparam integer MP_DLO  = 6144;               // destination region: words [6144, 7168)
localparam integer MP_MLO  = 8192;               // mask region: words [8192, 8320)
localparam integer MP_SZ   = 1024;
localparam integer MP_MSZ  = 128;
localparam integer MP_X0   = 80;                 // first column visited (+ the slot)
localparam integer MP_Y0   = 4;                  // first row visited
localparam integer MP_WMAX = (GPU_DIM_MASK >= 65) ? 65 : GPU_DIM_MASK;

`define MP_FW dut.u_core.G_GPU.u_gpu.u_px.u_px_fw

integer    mp_mode, mp_bl, mp_ppw, mp_n, mp_i, mp_j, mp_k, mp_w, mp_h, mp_sp;
integer    mp_rd0, mp_wr0, mp_nkey, mp_nmir, mp_ncl, mp_nxy, mp_ninv, mp_nop2, mp_x;
integer    mp_cx0, mp_cx1, mp_cy0, mp_cy1, mp_hit_ab, mp_hit_fz, mp_m0;
reg [31:0] mp_sb, mp_db, mp_mb, mp_pm, mp_t, mp_pa, mp_st;
reg  [3:0] mp_cmd, mp_op;
reg  [2:0] mp_dsw, mp_ssw;
reg [15:0] mp_c0, mp_c1, mp_c2, mp_c3;
reg        mp_frz_arm, mp_ab_arm;

// Mask reads in flight when the copy is abandoned or frozen
initial begin mp_hit_ab = 0; mp_hit_fz = 0; mp_frz_arm = 1'b0; mp_ab_arm = 1'b0; end
always @(posedge hclk)
   if (GPU_EN != 0) begin
      if (mp_ab_arm && (`MP_FW.abort_i === 1'b1) && (`MP_FW.rd_pend === 1'b1) && (`MP_FW.rd_m === 1'b1))
         mp_hit_ab = mp_hit_ab + 1;
      if (mp_frz_arm && (`MP_FW.freeze_i === 1'b1) && (`MP_FW.rd_pend === 1'b1) && (`MP_FW.rd_m === 1'b1))
         mp_hit_fz = mp_hit_fz + 1;
   end

function integer mp_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      mp_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task mp_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      mp_mode = mode;
      mp_bl   = gpu_bl(mode);
      mp_ppw  = 32 >> mp_bl;
      mp_pm   = gpu_pmask(mp_bl);
      mp_c0   = $random(gpu_seed);
      mp_c1   = $random(gpu_seed);
      mp_c2   = $random(gpu_seed);
      mp_c3   = $random(gpu_seed);
      gpu_preload_pal(MP_SLO, MP_SLO + MP_SZ, mp_bl, mp_c0, mp_c1, mp_c2, mp_c3);
      gpu_preload_rand(MP_DLO, MP_DLO + MP_SZ);
      gpu_preload_rand(MP_MLO, MP_MLO + MP_MSZ);
      gpu_model_init;
      gpu_set_mode(mode);
      gpu_set_dispw(64);
      gpu_c_fill($random(gpu_seed));
   end
endtask

// The mask region: 0 random, 1 sparse (mostly 0), 2 dense (mostly 1), with
// whole words of 0 or 1 now and then
task mp_mask_fill;
   input integer kind;
   integer       ww;
   reg    [31:0] vv;
   begin
      for (ww = MP_MLO; ww < MP_MLO + MP_MSZ; ww = ww + 1) begin
         vv = $random(gpu_seed);
         if (kind == 1) vv = vv & $random(gpu_seed) & $random(gpu_seed);
         if (kind == 2) vv = vv | $random(gpu_seed) | $random(gpu_seed);
         if (mp_rnd(8) == 0) vv = mp_rnd(2) ? 32'hFFFF_FFFF : 32'h0;
         vram_mem[ww]   = vv;
         gpu_shadow[ww] = vv;
      end
   end
endtask

// One masked copy: source slot ss, destination slot ds, mask bit offset mo,
// w x h, swaps, command, op; key 0 random colour, 1 a source pixel; xy: x/y
// destination trimmed by the clip window
task mp_case;
   input integer ss;
   input integer ds;
   input integer mo;
   input integer w;
   input integer h;
   input   [2:0] dsw;
   input   [2:0] ssw;
   input   [3:0] cmd;
   input   [3:0] op;
   input integer key;
   input         inv;
   input         xy;
   integer       ii;
   begin
      gpu_wait_idle;
      mp_mask_fill(mp_rnd(3));
      mp_sp = mp_rnd(4) ? MP_P : (MP_P - 1 + mp_rnd(3));
      mp_sb = (MP_SLO * mp_ppw) + MP_Y0 * MP_P + MP_X0 + ss;
      mp_db = (MP_DLO * mp_ppw) + MP_Y0 * MP_P + MP_X0 + ds;
      mp_mb = (MP_MLO * 32) + MP_Y0 * MP_P + MP_X0 + mo;
      gpu_c_size(w, h);
      gpu_c_src(mp_sp, mp_sb);
      gpu_c_mask_plane(mp_mb, inv);
      if (xy) begin
         gpu_c_dst_xy(MP_P, MP_DLO * mp_ppw);
         gpu_c_xy(MP_X0 + ds, MP_Y0);
         mp_x   = dsw[2] ? (MP_X0 + ds - w + 1) : (MP_X0 + ds);
         mp_cx0 = mp_x + mp_rnd(3) * mp_rnd(w);
         mp_cx1 = mp_x + w - 1 - mp_rnd(3) * mp_rnd(w);
         if (mp_cx1 < mp_cx0) mp_cx1 = mp_cx0;
         // a row trimmed now and then (the source start moves, the mask with it)
         mp_cy0 = (!dsw[1] && (h > 1) && mp_rnd(2)) ? (MP_Y0 + 1) : 0;
         mp_cy1 = ( dsw[1] && (h > 1) && mp_rnd(2)) ? (MP_Y0 - 1) : (4 * MP_Y0);
         gpu_c_clip(mp_cx0, mp_cy0, mp_cx1, mp_cy1);
      end else
         gpu_c_dst(MP_P, mp_db);
      if (key == 0)
         mp_t = $random(gpu_seed);
      else begin
         mp_pa = gpu_walk(mp_sb, mp_sp, ssw, w, mp_rnd(2) ? (w - 1) : 0);
         mp_t  = gpu_get_px(mp_pa, mp_bl);
      end
      gpu_c_transp(mp_t);
      for (ii = MP_SLO; ii < MP_SLO + MP_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = MP_DLO; ii < MP_DLO + MP_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = MP_MLO; ii < MP_MLO + MP_MSZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      mp_rd0 = gpu_exp_rd;
      mp_wr0 = gpu_exp_wr;
      gpu_mon_bl     = mp_bl;
      gpu_mon_be_chk = 1'b1;
      gpu_alw_start;
      gpu_mon_start;
      gpu_k_mpl = 1'b1;
      if (xy) gpu_c_exec_xy(cmd, op, dsw, ssw);
      else    gpu_c_exec(cmd, op, dsw, ssw);
      gpu_k_mpl = 1'b0;
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_alw_stop;
      gpu_mon_be_chk = 1'b0;
      mp_n = mp_n + 1;
      if (inv) mp_ninv = mp_ninv + 1;
      if ((cmd == GPU_COPY) && (op == 4'd2)) mp_nop2 = mp_nop2 + 1;
      if ((gpu_mon_rd != gpu_exp_rd - mp_rd0) || (gpu_mon_wr != gpu_exp_wr - mp_wr0)) begin
         $display("ERROR: GPU mplane mode %0d cmd %h op %0d %0d x %0d slots %0d -> %0d mask bit %0d swaps %b -> %b%0s%0s: %0d reads / %0d writes, expected %0d / %0d %t",
                  mp_mode, cmd, op, w, h, ss, ds, mo, ssw, dsw, inv ? " INV" : "", xy ? " x/y" : "",
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - mp_rd0, gpu_exp_wr - mp_wr0, $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      if (xy) gpu_c_dst(MP_P, mp_db);
      gpu_check_touched("masked copy");
   end
endtask

// A random masked copy at the current depth
task mp_rand;
   input integer ss;
   input integer ds;
   input integer mo;
   input         xy;
   integer       sw;
   begin
      sw = mp_rnd(xy ? 6 : 10);
      case (sw)
        0, 1:    begin mp_dsw = 3'b000; mp_ssw = 3'b000; end
        2:       begin mp_dsw = 3'b100; mp_ssw = 3'b100; end
        3:       begin mp_dsw = 3'b010; mp_ssw = 3'b010; end
        4:       begin mp_dsw = 3'b100; mp_ssw = 3'b000; end      // mirrors
        5:       begin mp_dsw = 3'b010; mp_ssw = 3'b110; end
        6:       begin mp_dsw = 3'b110; mp_ssw = 3'b110; end
        7:       begin mp_dsw = 3'b000; mp_ssw = 3'b100; end
        8:       begin mp_dsw = mp_rnd(8); mp_ssw = mp_rnd(8) | 3'b001; end   // CL swaps
        default: begin mp_dsw = mp_rnd(8) | 3'b001; mp_ssw = mp_rnd(8); end
      endcase
      if (mp_dsw[2] != mp_ssw[2]) mp_nmir = mp_nmir + 1;
      if (mp_dsw[0] | mp_ssw[0]) begin
         mp_ncl = mp_ncl + 1;
         mp_w   = 1 + mp_rnd(4);
         mp_h   = 1 + mp_rnd(3);
      end else begin
         case (mp_rnd(3))
           0:       mp_w = 1 + mp_rnd(mp_ppw);
           1:       mp_w = 30 + mp_rnd(5);                // about a mask word
           default: mp_w = 1 + mp_rnd(2 * 32 + 1);
         endcase
         mp_h = 1 + mp_rnd(3);
      end
      if (mp_w > MP_WMAX) mp_w = MP_WMAX;
      mp_cmd = mp_rnd(3) ? GPU_COPY : GPU_COPYT;
      mp_op  = mp_rnd(16);
      if ((mp_cmd == GPU_COPYT) || (mp_op >= 4'd13)) mp_nkey = mp_nkey + 1;
      if (xy) mp_nxy = mp_nxy + 1;
      mp_case(ss, ds, mo, mp_w, mp_h, mp_dsw, mp_ssw, mp_cmd, mp_op, mp_rnd(2), mp_rnd(2), xy);
   end
endtask

// A long masked copy pushed by hand (CL swaps: one pixel and one mask word per
// token), left running for the abort / freeze cases
task mp_long_start;
   begin
      gpu_wait_idle;
      mp_mask_fill(0);
      mp_sb = (MP_SLO * mp_ppw) + MP_Y0 * MP_P + MP_X0;
      mp_db = (MP_DLO * mp_ppw) + MP_Y0 * MP_P + MP_X0;
      gpu_c_src(MP_P, mp_sb);
      gpu_c_dst(MP_P, mp_db);
      gpu_c_mask_plane((MP_MLO * 32) + MP_Y0 * MP_P + MP_X0 + mp_rnd(32), mp_rnd(2));
      gpu_c_size(14'd12, 14'd20);
      gpu_c_transp($random(gpu_seed));
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_snapshot;
      gpu_k_mpl = 1'b1;
      gpu_push(gpu_exec_word(GPU_COPYT, 4'd0, 3'b001, 3'b001) | gpu_exec_aux(GPU_COPYT));
      gpu_x_setup(GPU_COPYT, 4'd0, 3'b001, 3'b001);
      gpu_x_aux(GPU_COPYT);
      gpu_k_mpl = 1'b0;
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: mask plane                        |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < MP_MLO + MP_MSZ)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      reg_rd_val(BLNS_CFG2, mp_st);
      if ((mp_st & CFG2_MPLANE) == 0) begin
         reg_wr(CTRL, 32'h14);
         reg_wr(GPU_CMD, {OP_SET_EXT, EXT_SET_AUX, 4'd1, 20'h00000});   // refused: ERR_CAUSE 2
         repeat(10) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {4'h6, 3'd2, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_wr(GPU_CTRL, 32'h1);
         tb_skip_finish("|      (BLNS_CFG2.MPLANE = 0: no mask plane)    |");
      end
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;                            // commands queued behind long ones
      mp_n = 0; mp_nkey = 0; mp_nmir = 0; mp_ncl = 0; mp_nxy = 0; mp_ninv = 0; mp_nop2 = 0;
      mp_m0 = 0;

      // Random masked copies at every depth; every mask bit offset at 1 and 8 bpp
      for (mp_mode = 0; mp_mode < 5; mp_mode = mp_mode + 1) begin
         mp_set_mode((mp_mode == 4) ? (4 + mp_rnd(4)) : mp_mode);
         mp_m0 = gpu_m_nrd;
         for (mp_i = 0; (mp_i < ((mp_bl == 0) || (mp_bl == 3) ? 32 : 12)) && (error == 0); mp_i = mp_i + 1)
            mp_rand(mp_rnd(mp_ppw), mp_rnd(mp_ppw), ((mp_bl == 0) || (mp_bl == 3)) ? mp_i : mp_rnd(32), 1'b0);
         $display("       mode %0d: %0d mask words read", mp_mode, gpu_m_nrd - mp_m0);
         if (error != 0) mp_mode = 5;
      end

      // Long runs, every operation, at 4 and 8 bpp
      for (mp_mode = 2; (mp_mode < 4) && (error == 0); mp_mode = mp_mode + 1) begin
         mp_set_mode(mp_mode);
         for (mp_i = 0; mp_i < 16; mp_i = mp_i + 1) begin
            mp_case(mp_rnd(mp_ppw), mp_rnd(mp_ppw), mp_rnd(32), MP_WMAX, 2, 3'b000, 3'b000,
                    (mp_i & 1) ? GPU_COPYT : GPU_COPY, mp_i, 1, mp_i[1], 1'b0);
            mp_case(mp_rnd(mp_ppw), mp_rnd(mp_ppw), mp_rnd(32), MP_WMAX, 2, 3'b100, 3'b000,
                    GPU_COPY, mp_i, 0, mp_i[2], 1'b0);
         end
      end

      // x/y destinations trimmed by the clip window
      if (GPU_XY_EN != 0)
         for (mp_mode = 0; (mp_mode < 5) && (error == 0); mp_mode = mp_mode + 1) begin
            mp_set_mode((mp_mode == 4) ? 4 : mp_mode);
            for (mp_i = 0; mp_i < 6; mp_i = mp_i + 1)
               mp_rand(mp_rnd(mp_ppw), mp_rnd(mp_ppw), mp_rnd(32), 1'b1);
         end

      $display("       %0d masked copies (%0d keyed, %0d mirrored, %0d with a CL swap, %0d x/y clipped, %0d INV, %0d op 2)",
               mp_n, mp_nkey, mp_nmir, mp_ncl, mp_nxy, mp_ninv, mp_nop2);

      //--------------------------------------------------------------
      $display("--- MPLANE per EXEC: a copy without it draws every pixel");
      mp_set_mode(3);
      gpu_c_mask_plane(MP_MLO * 32, 1'b0);
      gpu_c_src(MP_P, MP_SLO * 4);
      gpu_c_dst(MP_P, MP_DLO * 4);
      gpu_c_size(14'd40, 14'd3);
      gpu_k_mpl = 1'b1;
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_k_mpl = 1'b0;
      gpu_c_exec(GPU_COPY, 4'd6, 3'b000, 3'b000);
      gpu_wait_idle;
      gpu_check_touched("MPLANE per EXEC");

      $display("--- RESET_STATE: mask pointer and INV back to 0");
      gpu_c_mask_plane(MP_MLO * 32 + 77, 1'b1);
      gpu_c_reset_state;
      gpu_c_src(MP_P, MP_SLO * 4);
      gpu_c_dst(MP_P, MP_DLO * 4);
      gpu_c_size(14'd40, 14'd2);
      // the mask pointer is 0 after RESET_STATE: the mask of the source's first
      // pixel is bit 0 of VRAM word 0, not inverted
      gpu_k_mpl = 1'b1;
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_k_mpl = 1'b0;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("after RESET_STATE");

      //--------------------------------------------------------------
      $display("--- a mask word past VRAM_WORDS: ERR_CAUSE 5, a prefix drawn");
      mp_set_mode(3);
      for (mp_i = VRAM_WORDS - 4; mp_i < VRAM_WORDS; mp_i = mp_i + 1) begin
         vram_mem[mp_i]   = 32'hFFFF_FFFF;                // drawn up to the VRAM end
         gpu_shadow[mp_i] = 32'hFFFF_FFFF;
      end
      mp_w = (GPU_DIM_MASK >= 64) ? 64 : GPU_DIM_MASK;
      mp_h = mp_w - 8;                                    // mask bits in the VRAM
      gpu_c_src(MP_P, MP_SLO * 4);
      gpu_c_dst(MP_P, MP_DLO * 4);
      gpu_c_size(mp_w, 14'd1);
      gpu_c_mask_plane((VRAM_WORDS - 1) * 32 + 32 - mp_h, 1'b0);
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_snapshot;
      mp_t = gpu_exec_word(GPU_COPY, 4'd0, 3'b000, 3'b000) | 32'h800;
      gpu_push(mp_t);
      repeat(300) @(posedge free_clk);
      reg_rd_mask(GPU_STAT, {OP_EXEC_COPY, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
      reg_rd(GPU_ERR, mp_t);
      reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR | IF_DONE);
      // pixels 0 .. n-1 copied (n <= the mask bits in the VRAM), the others
      // unchanged (a source pixel equal to the old one fits either)
      mp_k = -1;
      for (mp_i = 0; mp_i < mp_w; mp_i = mp_i + 1)
         if ((gpu_vram_px(MP_DLO * 4 + mp_i, 3) === gpu_get_px(MP_SLO * 4 + mp_i, 3)) &&
             (gpu_get_px(MP_SLO * 4 + mp_i, 3) !== gpu_get_px(MP_DLO * 4 + mp_i, 3)))
            mp_k = mp_i;
      for (mp_i = 0; mp_i < mp_w; mp_i = mp_i + 1) begin
         mp_t = gpu_vram_px(MP_DLO * 4 + mp_i, 3);
         if ((mp_i <= mp_k) ? (mp_t !== gpu_get_px(MP_SLO * 4 + mp_i, 3)) : (mp_t !== gpu_get_px(MP_DLO * 4 + mp_i, 3))) begin
            $display("ERROR: GPU mask past the VRAM -- pixel %0d = 0x%h, not a prefix of the copy %t", mp_i, mp_t, $time);
            error = error + 1;
         end
      end
      if (mp_k >= mp_h) begin
         $display("ERROR: GPU mask past the VRAM -- pixel %0d drawn, its mask bit past the VRAM end %t", mp_k, $time);
         error = error + 1;
      end
      $display("       %0d of %0d pixels drawn before the fault", mp_k + 1, mp_h);
      for (mp_i = 0; mp_i < mp_w; mp_i = mp_i + 1)
         gpu_set_px(MP_DLO * 4 + mp_i, 3, gpu_vram_px(MP_DLO * 4 + mp_i, 3));
      reg_wr(GPU_CTRL, 32'h1);
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_check_all("mask past the VRAM");

      //--------------------------------------------------------------
      // (DIM_W >= 10: rectangles long enough to be caught mid-way, as gpu_abort)
      if (GPU_DIM_MASK < 1023)
         $display("--- (DIM_W < 10: ABORT and freeze with mask reads in flight not run)");
      else begin
         $display("--- ABORT with mask reads in flight: a clean prefix");
         // (until one ABORT met a mask read in flight)
         for (mp_k = 0; ((mp_k < 8) || ((mp_hit_ab == 0) && (mp_k < 40))) && (error == 0); mp_k = mp_k + 1) begin
            mp_set_mode(mp_k[0] ? 3 : 1);
            mp_long_start;
            repeat(20 + mp_rnd(200)) @(posedge free_clk);
            mp_ab_arm = 1'b1;
            reg_wr(GPU_CTRL, 32'h2);
            repeat(10) @(posedge free_clk);
            mp_ab_arm = 1'b0;
            reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR);
            gpu_find_prefix(mp_j);
            if ((mp_j < 0) || (mp_j >= gpu_x_w * gpu_x_h)) begin
               $display("ERROR: GPU abandoned masked copy -- not a strict prefix (n = %0d of %0d) %t", mp_j, gpu_x_w * gpu_x_h, $time);
               error = error + 1;
            end
            gpu_check_touched("abandoned masked copy");
         end

         $display("--- debug freeze with mask reads in flight: the image completed");
         reg_wr(DBG_CTRL, 32'h2);
         for (mp_k = 0; ((mp_k < 6) || ((mp_hit_fz == 0) && (mp_k < 30))) && (error == 0); mp_k = mp_k + 1) begin
            mp_set_mode(mp_k[0] ? 0 : 3);
            gpu_c_src(MP_P, (MP_SLO * mp_ppw) + MP_P);
            gpu_c_dst(MP_P, (MP_DLO * mp_ppw) + MP_P);
            gpu_c_mask_plane((MP_MLO * 32) + MP_P + mp_rnd(32), mp_rnd(2));
            gpu_c_size(14'd10, 14'd16);
            gpu_wait_idle;
            mp_frz_arm = 1'b1;
            gpu_k_mpl  = 1'b1;
            gpu_c_exec(GPU_COPY, 4'd0, 3'b001, 3'b001);
            gpu_k_mpl  = 1'b0;
            for (mp_i = 0; mp_i < 12; mp_i = mp_i + 1) begin
               repeat(3 + mp_rnd(30)) @(posedge free_clk);
               @(negedge free_clk) dbg_stoptime = 1'b1;
               repeat(10 + mp_rnd(20)) @(posedge free_clk);
               @(negedge free_clk) dbg_stoptime = 1'b0;
            end
            gpu_wait_idle;
            mp_frz_arm = 1'b0;
            gpu_check_touched("masked copy across freezes");
         end
         reg_wr(DBG_CTRL, 32'h0);
         $display("       mask read in flight at %0d ABORTs, %0d freezes", mp_hit_ab, mp_hit_fz);
         if ((mp_hit_ab == 0) || (mp_hit_fz == 0)) begin
            $display("ERROR: GPU mplane -- no ABORT or no freeze met a mask read in flight %t", $time);
            error = error + 1;
         end
      end

      //--------------------------------------------------------------
      // SET_AUX MASK_PLANE pushed while the masked copy before it draws
      // (run-ahead: decoded during the draw, checked; without it the decoder
      // waits): the running copy keeps the old mask position and INV, the
      // next takes the new ones
      $display("--- SET_AUX MASK_PLANE while the copy before it draws: old mask for it, new for the next");
      for (mp_k = 0; mp_k < 6; mp_k = mp_k + 1) begin
         mp_set_mode((mp_k % 3 == 0) ? 3 : (mp_k % 3 == 1) ? 2 : 0);
         mp_w = (MP_WMAX >= 60) ? 60 : MP_WMAX;
         gpu_c_src(MP_P, MP_SLO * mp_ppw + MP_P + mp_rnd(mp_ppw));
         gpu_c_dst(MP_P, MP_DLO * mp_ppw + MP_P + mp_rnd(mp_ppw));
         gpu_c_size(mp_w, 14'd6);
         gpu_c_mask_plane(MP_MLO * 32 + mp_rnd(32), mp_rnd(2));
         gpu_wait_idle;
         gpu_k_mpl = 1'b1;
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);              // A: mask 1
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         gpu_c_mask_plane((MP_MLO + 64) * 32 + mp_rnd(32), ~gpu_m_minv);   // while A draws
         reg_rd_val(GPU_STAT, mp_st);
         if (!(mp_st & GS_PRIM_BUSY) ||
             ((GPU_RUNAHEAD_EN != 0) ? !(mp_st & GS_EMPTY) : (mp_st[15:8] != 8'd2))) begin
            $display("ERROR: GPU_STAT 0x%h after SET_AUX: %0s (test bug: A too short) %t", mp_st,
                     (GPU_RUNAHEAD_EN != 0) ? "decoded while A draws expected" : "queued behind A expected", $time);
            error = error + 1;
         end
         gpu_c_dst(MP_P, (MP_DLO + 512) * mp_ppw + MP_P + mp_rnd(mp_ppw));
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);              // B: mask 2, INV flipped
         gpu_k_mpl = 1'b0;
         gpu_wait_idle;
         gpu_check_touched("SET_AUX MASK_PLANE during a copy");
      end

      gpu_check_all("mplane end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
