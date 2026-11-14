//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      gpu_remap
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpu_remap.v
// Module Description : Palette remap (SET_AUX REMAP_TABLE, the REMAP fields of
//                      EXEC_FILL / COPY / COPY_TRANSP / EXPAND and SET_TEX;
//                      skipped when BLNS_CFG2.REMAP is 0): S' = T[S] (SRC) or
//                      T[D] (DST), T a byte table on a 256-byte boundary, the
//                      low bpp bits of the entry. SRC and DST on COPY and
//                      COPY_TRANSP (every op: 2 and 13-15 make no lookup;
//                      the key tested on the raw source; every swap) and
//                      FILL (with a gradient when built) at 1, 2, 4 and 8
//                      bpp: the image and the VRAM reads (table words
//                      included: one-word table cache) and writes against
//                      gpu_model.v, only the words of the rectangle and of
//                      its table accessed; at 16 bpp the field has no
//                      effect (no table read). EXPAND (OPAQUE: the
//                      background remapped too) and TEXSPAN / TEXRECT (texel
//                      + SHADE, TRANSP_EN on the raw texel, SET_TEX [15:14]
//                      sticky): the image. With GPU_TRI_EN: flat triangles
//                      (EXEC_FILL TRI, SRC and DST, any op, with a gradient
//                      when built, clipped) against gpu_c_trifill, image and
//                      accesses, and textured triangles (SET_TEX REMAP) at
//                      every depth; ops 2 and 13-15 make no lookup, REMAP 3
//                      on a TRI is refused (ERR_CAUSE 1), triangles back to
//                      back with the table pointer and the mode changed
//                      between them. Then: REMAP per EXEC; a table
//                      written by a GPU FILL and SET_AUX re-sent; RESET_STATE
//                      (pointer and SET_TEX field back to 0); remap with the
//                      mask plane; commands back to back with the table
//                      pointer changed between them (run-ahead copy), and
//                      SET_AUX pushed while the copy before it draws (with
//                      run-ahead decoded during the draw: the running copy
//                      keeps the old table, the next one the new); a
//                      table past VRAM_WORDS stops the command with
//                      ERR_CAUSE 5; ABORT and the debug freeze with table
//                      reads in flight.
//                      The VRAM access counts compared here (gpu_model.v
//                      accounting, GPU_WCOPY_LVL) follow the RTL's tokens
//                      and buffers: micro-architectural regression checks,
//                      not spec checks (the image is the spec check).
//----------------------------------------------------------------------------
`include "gpu_model.v"

localparam integer RM_P    = 192;                // pitch (pixels)
localparam integer RM_SLO  = 4096;               // source region: words [4096, 5120)
localparam integer RM_DLO  = 6144;               // destination region: words [6144, 7168)
localparam integer RM_TLO  = 8192;               // tables: words [8192, 8448), four of 64 words
localparam integer RM_SZ   = 1024;
localparam integer RM_X0   = 80;
localparam integer RM_Y0   = 4;
localparam integer RM_WMAX = (GPU_DIM_MASK >= 40) ? 40 : GPU_DIM_MASK;

`define RM_FW dut.u_core.G_GPU.u_gpu.u_px.u_px_fw

integer    rm_mode, rm_bl, rm_ppw, rm_n, rm_i, rm_j, rm_k, rm_w, rm_h, rm_sp;
integer    rm_rd0, rm_wr0, rm_r0, rm_nsrc, rm_ndst, rm_nexp, rm_ntex, rm_ntri, rm_x, rm_hit_ab, rm_hit_fz;
reg [31:0] rm_sb, rm_db, rm_pm, rm_t, rm_st, rm_tb;
reg  [3:0] rm_cmd, rm_op;
reg  [2:0] rm_dsw, rm_ssw;
reg        rm_frz_arm, rm_ab_arm;
reg        rm_nograd = 1'b0;                     // no gradient on the next FILLs

initial begin rm_hit_ab = 0; rm_hit_fz = 0; rm_frz_arm = 1'b0; rm_ab_arm = 1'b0; end
always @(posedge hclk)
   if (GPU_EN != 0) begin
      if (rm_ab_arm && (`RM_FW.abort_i === 1'b1) && (`RM_FW.rd_pend === 1'b1) && (`RM_FW.rd_r === 1'b1))
         rm_hit_ab = rm_hit_ab + 1;
      if (rm_frz_arm && (`RM_FW.freeze_i === 1'b1) && (`RM_FW.rd_pend === 1'b1) && (`RM_FW.rd_r === 1'b1))
         rm_hit_fz = rm_hit_fz + 1;
   end

function integer rm_rnd;                 // uniform in [0, n)
   input integer n;
   begin
      rm_rnd = (n <= 1) ? 0 : (($random(gpu_seed) & 32'h7FFF_FFFF) % n);
   end
endfunction

task rm_set_mode;
   input integer mode;
   begin
      gpu_wait_idle;
      rm_mode = mode;
      rm_bl   = gpu_bl(mode);
      rm_ppw  = 32 >> rm_bl;
      rm_pm   = gpu_pmask(rm_bl);
      gpu_preload_rand(RM_SLO, RM_SLO + RM_SZ);
      gpu_preload_rand(RM_DLO, RM_DLO + RM_SZ);
      gpu_preload_rand(RM_TLO, RM_TLO + 256);
      gpu_model_init;
      gpu_set_mode(mode);
      gpu_set_dispw(64);
      gpu_c_fill($random(gpu_seed));
   end
endtask

// A table: one of the four (its word address, sometimes with low bits the
// GPU ignores)
task rm_table;
   begin
      rm_tb = RM_TLO + 64 * rm_rnd(4);
      gpu_c_remap_table(rm_tb | (rm_rnd(4) ? 0 : rm_rnd(64)));
   end
endtask

task rm_clear_alw;
   integer ii;
   begin
      for (ii = RM_SLO; ii < RM_SLO + RM_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = RM_DLO; ii < RM_DLO + RM_SZ; ii = ii + 1) gpu_alw[ii] = 1'b0;
      for (ii = RM_TLO; ii < RM_TLO + 256; ii = ii + 1)   gpu_alw[ii] = 1'b0;
   end
endtask

// One FILL / COPY / COPY_TRANSP with remap mode md: image and accesses
task rm_case;
   input   [3:0] cmd;
   input   [3:0] op;
   input   [1:0] md;
   input integer w;
   input integer h;
   input   [2:0] dsw;
   input   [2:0] ssw;
   input         xy;
   integer       ss, ds;
   begin
      gpu_wait_idle;
      ss    = rm_rnd(rm_ppw);
      ds    = rm_rnd(rm_ppw);
      rm_sp = rm_rnd(4) ? RM_P : (RM_P - 1 + rm_rnd(3));
      rm_sb = (RM_SLO * rm_ppw) + RM_Y0 * RM_P + RM_X0 + ss;
      rm_db = (RM_DLO * rm_ppw) + RM_Y0 * RM_P + RM_X0 + ds;
      gpu_c_size(w, h);
      if (cmd != GPU_FILL) gpu_c_src(rm_sp, rm_sb);
      rm_table;
      if (xy) begin
         gpu_c_dst_xy(RM_P, RM_DLO * rm_ppw);
         gpu_c_xy(RM_X0 + ds, RM_Y0);
         rm_x = dsw[2] ? (RM_X0 + ds - w + 1) : (RM_X0 + ds);
         gpu_c_clip(rm_x + rm_rnd(3), 0, rm_x + w - 1 - rm_rnd(3), 4 * RM_Y0);
      end else
         gpu_c_dst(RM_P, rm_db);
      if (rm_rnd(2))
         gpu_c_transp(gpu_get_px(gpu_walk(rm_sb, rm_sp, ssw, w, 0), rm_bl));
      else
         gpu_c_transp($random(gpu_seed));
      if ((cmd == GPU_FILL) && (GPU_GRAD_EN != 0) && rm_rnd(2) && !dsw[0] && !rm_nograd)
         gpu_c_grad(1 + rm_rnd(3), rm_rnd(2), rm_rnd(16) - 8, 1'b1);
      if (1)
         $display("       cmd %h op %0d remap %0d %0d x %0d swaps %b -> %b%0s grad %0d table %0d", cmd, op, md, w, h,
                  ssw, dsw, xy ? " x/y" : "", gpu_m_gen, gpu_m_rbase);
      rm_clear_alw;
      rm_rd0 = gpu_exp_rd;
      rm_wr0 = gpu_exp_wr;
      gpu_mon_bl     = rm_bl;
      gpu_mon_be_chk = 1'b1;
      gpu_alw_start;
      gpu_mon_start;
      gpu_k_rmp = md;
      if (xy) gpu_c_exec_xy(cmd, op, dsw, ssw);
      else    gpu_c_exec(cmd, op, dsw, ssw);
      gpu_k_rmp = 2'd0;
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_alw_stop;
      gpu_mon_be_chk = 1'b0;
      if (gpu_m_gen) gpu_c_grad(0, 1'b0, 0, 1'b0);
      rm_n = rm_n + 1;
      if (md == 2'd1) rm_nsrc = rm_nsrc + 1;
      if (md == 2'd2) rm_ndst = rm_ndst + 1;
      if ((gpu_mon_rd != gpu_exp_rd - rm_rd0) || (gpu_mon_wr != gpu_exp_wr - rm_wr0)) begin
         $display("ERROR: GPU remap mode %0d cmd %h op %0d remap %0d %0d x %0d swaps %b -> %b%0s: %0d reads / %0d writes, expected %0d / %0d %t",
                  rm_mode, cmd, op, md, w, h, ssw, dsw, xy ? " x/y" : "",
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - rm_rd0, gpu_exp_wr - rm_wr0, $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      if (xy) gpu_c_dst(RM_P, rm_db);
      gpu_check_touched("remapped rectangle");
   end
endtask

task rm_rand;
   input xy;
   begin
      case (rm_rnd(xy ? 4 : 7))
        0, 1:    begin rm_dsw = 3'b000; rm_ssw = 3'b000; end
        2:       begin rm_dsw = 3'b100; rm_ssw = 3'b000; end
        3:       begin rm_dsw = 3'b010; rm_ssw = 3'b110; end
        4:       begin rm_dsw = 3'b001; rm_ssw = 3'b000; end
        5:       begin rm_dsw = 3'b000; rm_ssw = 3'b011; end
        default: begin rm_dsw = rm_rnd(8); rm_ssw = rm_rnd(8); end
      endcase
      rm_cmd = (rm_rnd(4) == 0) ? GPU_FILL : rm_rnd(2) ? GPU_COPY : GPU_COPYT;
      rm_op  = rm_rnd(3) ? (rm_rnd(2) ? 4'd0 : 4'd5) : rm_rnd(16);
      rm_w   = (rm_dsw[0] | rm_ssw[0]) ? (1 + rm_rnd(4)) : (1 + rm_rnd(RM_WMAX));
      if (rm_w > RM_WMAX) rm_w = RM_WMAX;
      rm_h   = 1 + rm_rnd(3);
      rm_case(rm_cmd, rm_op, 1 + rm_rnd(2), rm_w, rm_h, rm_dsw, (rm_cmd == GPU_FILL) ? 3'b000 : rm_ssw, xy);
   end
endtask

// EXPAND from a 1/2/4/8-bpp source (at most the colour depth): image
task rm_expand;
   input [1:0] md;
   integer     sdep;
   begin
      gpu_wait_idle;
      sdep = rm_rnd((rm_bl > 3) ? 4 : (rm_bl + 1));
      gpu_c_src(16'd0, RM_SLO * (32 >> sdep) + rm_rnd(32));
      gpu_c_dst(RM_P, (RM_DLO * rm_ppw) + RM_Y0 * RM_P + RM_X0 + rm_rnd(rm_ppw));
      gpu_c_size(1 + rm_rnd(24), 1 + rm_rnd(6));
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp($random(gpu_seed));
      rm_table;
      gpu_exp_op = rm_rnd(3) ? 4'd0 : rm_rnd(16);
      gpu_k_rmp  = md;
      gpu_c_expand(0, rm_rnd(2) ? 3'b000 : rm_rnd(8), rm_rnd(2), sdep);
      gpu_k_rmp  = 2'd0;
      gpu_exp_op = 4'd0;
      rm_nexp    = rm_nexp + 1;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("remapped expand");
   end
endtask

// TEXSPAN / TEXRECT with SET_TEX [15:14] = md: image
task rm_tex;
   input [1:0] md;
   begin
      gpu_wait_idle;
      gpu_c_src(16'd0, RM_SLO * rm_ppw + rm_rnd(64));
      gpu_c_dst(RM_P, (RM_DLO * rm_ppw) + RM_Y0 * RM_P + RM_X0 + rm_rnd(rm_ppw));
      gpu_c_transp($random(gpu_seed) & rm_pm);
      rm_table;
      gpu_k_trmp = md;
      gpu_c_tex(4'd3, 4'd3, rm_rnd(2), rm_rnd(2) ? 3'b000 : 3'b100, 1'b0, 1'b0, $random(gpu_seed));
      gpu_k_trmp = 2'd0;
      gpu_c_uv($random(gpu_seed), $random(gpu_seed));
      gpu_c_step({rm_rnd(2) ? 4'h0 : 4'hF, 1'b0, 11'h0} | rm_rnd(4096), rm_rnd(4096));
      if ((GPU_XY_EN != 0) && rm_rnd(2)) begin
         gpu_c_size(1 + rm_rnd(16), 1 + rm_rnd(5));
         gpu_c_step_row(rm_rnd(4096), 16'h0800);
         gpu_c_texrect(0);
      end else
         gpu_c_texspan(0, 1 + rm_rnd(30));
      rm_ntex = rm_ntex + 1;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("remapped texture");
   end
endtask

// Triangles (GPU_TRI_EN, x/y mode): the destination region as an x/y surface
// of pitch RM_P, a clip window inside it, three vertices (12.4) around a
// random point, the triangle's box at most RM_TS pixels each way
localparam integer RM_TS = (GPU_DIM_MASK >= 24) ? 24 : GPU_DIM_MASK;

task rm_tri_surf;
   integer rows;
   begin
      rows = (RM_SZ * rm_ppw) / RM_P;
      gpu_c_dst_xy(RM_P, RM_DLO * rm_ppw);
      gpu_c_clip(rm_rnd(3), rm_rnd(2), RM_P - 1 - rm_rnd(3), rows - 1 - rm_rnd(2));
   end
endtask

task rm_tri_vtx;
   integer cx, cy, k;
   begin
      cx = rm_rnd(RM_P + 8) - 4 - RM_TS / 2;
      cy = rm_rnd((RM_SZ * rm_ppw) / RM_P + 8) - 4 - RM_TS / 2;
      for (k = 0; k < 3; k = k + 1)
         gpu_c_vtx(k, 16 * cx + rm_rnd(16 * RM_TS - 15), 16 * cy + rm_rnd(16 * RM_TS - 15));
   end
endtask

// A flat triangle (EXEC_FILL TRI) with remap mode md: image and accesses
task rm_tri;
   input [1:0] md;
   input [3:0] op;
   begin
      gpu_wait_idle;
      rm_tri_surf;
      rm_table;
      gpu_c_fill($random(gpu_seed));
      gpu_c_transp(rm_rnd(2) ? gpu_m_fill : $random(gpu_seed));
      if ((GPU_GRAD_EN != 0) && rm_rnd(2) && !rm_nograd)
         gpu_c_grad(1 + rm_rnd(3), rm_rnd(2), rm_rnd(16) - 8, 1'b1);
      rm_tri_vtx;
      rm_clear_alw;
      rm_rd0 = gpu_exp_rd;
      rm_wr0 = gpu_exp_wr;
      gpu_mon_bl     = rm_bl;
      gpu_mon_be_chk = 1'b1;
      gpu_alw_start;
      gpu_mon_start;
      gpu_k_rmp = md;
      gpu_c_trifill(op);
      gpu_k_rmp = 2'd0;
      gpu_wait_idle;
      gpu_mon_stop;
      gpu_alw_stop;
      gpu_mon_be_chk = 1'b0;
      if (gpu_m_gen) gpu_c_grad(0, 1'b0, 0, 1'b0);
      rm_ntri = rm_ntri + 1;
      if ((gpu_mon_rd != gpu_exp_rd - rm_rd0) || (gpu_mon_wr != gpu_exp_wr - rm_wr0)) begin
         $display("ERROR: GPU remap mode %0d triangle op %0d remap %0d box %0d x %0d at (%0d, %0d) grad %0d: %0d reads / %0d writes, expected %0d / %0d %t",
                  rm_mode, op, md, gpu_x_w, gpu_x_h, gpu_x_x, gpu_x_y, gpu_x_gen,
                  gpu_mon_rd, gpu_mon_wr, gpu_exp_rd - rm_rd0, gpu_exp_wr - rm_wr0, $time);
         error = error + 1;
      end
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("remapped triangle");
   end
endtask

// A textured triangle (EXEC_TEXRECT TRI) with SET_TEX [15:14] = md: image
task rm_tritex;
   input [1:0] md;
   begin
      gpu_wait_idle;
      rm_tri_surf;
      gpu_c_src(16'd0, RM_SLO * rm_ppw + rm_rnd(64));
      gpu_c_transp($random(gpu_seed) & rm_pm);
      rm_table;
      gpu_k_trmp = md;
      gpu_c_tex(4'd3, 4'd3, rm_rnd(2), 3'b000, 1'b0, 1'b0, $random(gpu_seed));
      gpu_k_trmp = 2'd0;
      gpu_c_uv($random(gpu_seed), $random(gpu_seed));
      gpu_c_step(rm_rnd(4096), rm_rnd(4096));
      gpu_c_step_row(rm_rnd(4096), rm_rnd(4096));
      rm_tri_vtx;
      gpu_c_tritex;
      rm_ntri = rm_ntri + 1;
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("remapped textured triangle");
   end
endtask

// DST remap FILL left running (one table read per pixel, mostly)
task rm_long_start;
   begin
      gpu_wait_idle;
      gpu_c_dst(RM_P, (RM_DLO * rm_ppw) + RM_P);
      gpu_c_size(14'd30, 14'd12);
      rm_table;
      gpu_wait_idle;
      reg_wr(IRQ_FLAG, IF_GPU_ALL);
      gpu_snapshot;
      gpu_k_rmp = 2'd2;
      gpu_push(gpu_exec_word(GPU_FILL, 4'd0, 3'b001, 3'b000) | gpu_exec_aux(GPU_FILL));
      gpu_x_setup(GPU_FILL, 4'd0, 3'b001, 3'b000);
      gpu_x_aux(GPU_FILL);
      gpu_k_rmp = 2'd0;
      reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        GPU: palette remap                     |");
      $display(" ===============================================");
      @(posedge reset_done);
      if (GPU_EN == 0)
         tb_skip_finish("|          (GPU_EN = 0: no GPU present)         |");
      if (VRAM_WORDS < RM_TLO + 256)
         tb_skip_finish("|           (VRAM too small for the test)       |");
      reg_rd_val(BLNS_CFG2, rm_st);
      if ((rm_st & CFG2_REMAP) == 0) begin
         reg_wr(CTRL, 32'h14);
         reg_wr(GPU_CMD, {OP_EXEC_FILL, 14'h0000, 2'd1, 12'h000});   // refused: ERR_CAUSE 2
         repeat(10) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_EXEC_FILL, 3'd2, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_wr(GPU_CTRL, 32'h1);
         tb_skip_finish("|        (BLNS_CFG2.REMAP = 0: no remap)        |");
      end
      gpu_seed = `SEED;
      gpu_push_wait = 1'b1;                            // commands queued behind long ones
      rm_n = 0; rm_nsrc = 0; rm_ndst = 0; rm_nexp = 0; rm_ntex = 0; rm_ntri = 0;

      // FILL / COPY / COPY_TRANSP, SRC and DST, at every depth (16 bpp: no effect)
      for (rm_mode = 0; (rm_mode < 5) && (error == 0); rm_mode = rm_mode + 1) begin
         rm_set_mode((rm_mode == 4) ? (4 + rm_rnd(4)) : rm_mode);
         rm_r0 = gpu_r_nrd;
         for (rm_i = 0; (rm_i < 24) && (error == 0); rm_i = rm_i + 1)
            rm_rand(1'b0);
         if (GPU_XY_EN != 0)
            for (rm_i = 0; (rm_i < 4) && (error == 0); rm_i = rm_i + 1)
               rm_rand(1'b1);
         for (rm_i = 0; (rm_i < 6) && (error == 0); rm_i = rm_i + 1)
            rm_expand(1 + rm_rnd(2));
         for (rm_i = 0; (rm_i < 6) && (error == 0); rm_i = rm_i + 1)
            rm_tex(rm_rnd(3));
         if ((GPU_TRI_EN != 0) && (GPU_XY_EN != 0)) begin
            for (rm_i = 0; (rm_i < 10) && (error == 0); rm_i = rm_i + 1)
               rm_tri(1 + rm_rnd(2), rm_rnd(3) ? (rm_rnd(2) ? 4'd0 : 4'd5) : rm_rnd(16));
            for (rm_i = 0; (rm_i < 4) && (error == 0); rm_i = rm_i + 1)
               rm_tritex(1 + rm_rnd(2));
         end
         $display("       mode %0d: %0d table words read", rm_mode, gpu_r_nrd - rm_r0);
         if ((rm_bl == 4) && (gpu_r_nrd != rm_r0)) begin
            $display("ERROR: GPU remap -- table reads at 16 bpp %t", $time);
            error = error + 1;
         end
      end
      $display("       %0d rectangles (%0d SRC, %0d DST), %0d expands, %0d textures, %0d triangles",
               rm_n, rm_nsrc, rm_ndst, rm_nexp, rm_ntex, rm_ntri);

      //--------------------------------------------------------------
      $display("--- ops 2 and 13-15 make no lookup; a one-colour FILL one");
      rm_set_mode(3);
      for (rm_i = 0; rm_i < 4; rm_i = rm_i + 1) begin
         rm_r0 = gpu_r_nrd;
         rm_case(GPU_COPY, (rm_i == 0) ? 4'd2 : (4'd12 + rm_i), 2'd1, 30, 3, 3'b000, 3'b000, 1'b0);
         if (gpu_r_nrd != rm_r0) begin
            $display("ERROR: GPU remap -- the model looked up for an op without S (test bug) %t", $time);
            error = error + 1;
         end
      end
      rm_r0     = gpu_r_nrd;
      rm_nograd = 1'b1;
      rm_case(GPU_FILL, 4'd0, 2'd1, 40, 4, 3'b000, 3'b000, 1'b0);
      rm_nograd = 1'b0;
      if (gpu_r_nrd != rm_r0 + 1) begin
         $display("ERROR: GPU remap -- a one-colour FILL reads %0d table words, 1 expected %t", gpu_r_nrd - rm_r0, $time);
         error = error + 1;
      end

      $display("--- REMAP per EXEC; a table written by a GPU FILL, SET_AUX sent again");
      rm_set_mode(3);
      gpu_c_src(RM_P, RM_SLO * 4);
      gpu_c_dst(RM_P, RM_DLO * 4);
      gpu_c_size(14'd40, 14'd3);
      gpu_c_remap_table(RM_TLO);
      gpu_k_rmp = 2'd1;
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_k_rmp = 2'd0;
      gpu_c_exec(GPU_COPY, 4'd6, 3'b000, 3'b000);         // not remapped
      gpu_c_dst(16'd0, RM_TLO * 4);                        // the table rewritten by the GPU
      gpu_c_size(14'd256, 14'd1);
      gpu_c_fill(32'h0000_005A);
      gpu_c_exec(GPU_FILL, 4'd5, 3'b000, 3'b000);
      gpu_c_remap_table(RM_TLO);
      gpu_c_dst(RM_P, RM_DLO * 4 + 8 * RM_P);
      gpu_c_size(14'd40, 14'd3);
      gpu_k_rmp = 2'd1;
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_k_rmp = 2'd0;
      gpu_wait_idle;
      gpu_check_touched("table rewritten");

      $display("--- RESET_STATE: table pointer and SET_TEX REMAP back to 0");
      rm_set_mode(3);
      gpu_c_remap_table(RM_TLO + 64);
      gpu_k_trmp = 2'd1;
      gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
      gpu_k_trmp = 2'd0;
      gpu_c_reset_state;
      gpu_c_src(RM_P, RM_SLO * 4);
      gpu_c_dst(RM_P, RM_DLO * 4);
      gpu_c_size(14'd40, 14'd3);
      gpu_k_rmp = 2'd1;                                    // the table at word 0
      gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
      gpu_k_rmp = 2'd0;
      gpu_c_uv(16'h0000, 16'h0000);
      gpu_c_step(16'h0800, 16'h0000);
      gpu_c_texspan(8 * RM_P, 14'd20);                    // SET_TEX REMAP 0
      gpu_wait_idle;
      reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
      gpu_check_touched("after RESET_STATE");

      if (GPU_MPLANE_EN != 0) begin
         $display("--- remap and mask plane together");
         rm_set_mode(2);
         gpu_preload_rand(RM_TLO + 256, RM_TLO + 384);
         gpu_c_src(RM_P, RM_SLO * 8 + 3);
         gpu_c_dst(RM_P, RM_DLO * 8 + 5);
         gpu_c_mask_plane((RM_TLO + 256) * 32 + 7, 1'b0);
         for (rm_i = 0; rm_i < 4; rm_i = rm_i + 1) begin
            rm_table;
            gpu_c_size(1 + rm_rnd(40), 1 + rm_rnd(3));
            gpu_k_rmp = 1 + rm_rnd(2);
            gpu_k_mpl = 1'b1;
            gpu_c_exec(rm_rnd(2) ? GPU_COPY : GPU_COPYT, rm_rnd(2) ? 4'd0 : 4'd4, rm_rnd(2) ? 3'b100 : 3'b001, 3'b000);
            gpu_k_mpl = 1'b0;
            gpu_k_rmp = 2'd0;
         end
         gpu_wait_idle;
         gpu_check_touched("remap and mask");
      end

      $display("--- back to back, the table pointer changed between commands");
      rm_set_mode(3);
      gpu_c_src(RM_P, RM_SLO * 4);
      for (rm_i = 0; rm_i < 12; rm_i = rm_i + 1) begin
         rm_table;
         gpu_c_dst(RM_P, RM_DLO * 4 + rm_i * 2 * RM_P + rm_rnd(8));
         gpu_c_size(1 + rm_rnd(30), 1 + rm_rnd(2));
         gpu_k_rmp = 1 + rm_rnd(2);
         gpu_c_exec(rm_rnd(3) ? GPU_COPY : GPU_FILL, rm_rnd(2) ? 4'd0 : 4'd6, 3'b000, 3'b000);
         gpu_k_rmp = 2'd0;
      end
      gpu_wait_idle;
      gpu_check_touched("back to back");

      if ((GPU_TRI_EN != 0) && (GPU_XY_EN != 0)) begin
         $display("--- triangles: ops 2 and 13-15 make no lookup, a one-colour one reads one table word");
         rm_set_mode(3);
         for (rm_i = 0; rm_i < 5; rm_i = rm_i + 1) begin
            rm_r0 = gpu_r_nrd;
            rm_nograd = 1'b1;
            rm_tri(2'd1 + rm_i[0], (rm_i == 0) ? 4'd2 : (rm_i == 4) ? 4'd0 : (4'd12 + rm_i));
            rm_nograd = 1'b0;
            if ((rm_i < 4) ? (gpu_r_nrd != rm_r0) : (gpu_r_nrd > rm_r0 + 1)) begin
               $display("ERROR: GPU remap -- the model read %0d table words for triangle %0d (test bug) %t",
                        gpu_r_nrd - rm_r0, rm_i, $time);
               error = error + 1;
            end
         end

         $display("--- triangles: REMAP 3 on EXEC_FILL TRI is refused (ERR_CAUSE 1)");
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_push({OP_EXEC_FILL, 14'h0000, 2'd3, 4'h0, 1'b1, 3'b000, 4'd0});
         repeat(10) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_EXEC_FILL, 3'd1, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_wr(GPU_CTRL, 32'h1);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);

         $display("--- triangles back to back, the table pointer and the mode changed between them");
         for (rm_k = 0; rm_k < 2; rm_k = rm_k + 1) begin
            rm_set_mode(rm_k ? 2 : 3);
            rm_tri_surf;
            for (rm_i = 0; rm_i < 10; rm_i = rm_i + 1) begin
               rm_table;
               gpu_c_fill($random(gpu_seed));
               rm_tri_vtx;
               if (rm_rnd(3)) begin
                  gpu_k_rmp = rm_rnd(3);
                  gpu_c_trifill(rm_rnd(2) ? 4'd0 : 4'd6);
                  gpu_k_rmp = 2'd0;
               end else begin
                  gpu_c_src(16'd0, RM_SLO * rm_ppw + rm_rnd(64));
                  gpu_k_trmp = rm_rnd(3);
                  gpu_c_tex(4'd3, 4'd3, 1'b0, 3'b000, 1'b0, 1'b0, 8'h00);
                  gpu_k_trmp = 2'd0;
                  gpu_c_uv($random(gpu_seed), $random(gpu_seed));
                  gpu_c_step(rm_rnd(4096), 16'h0000);
                  gpu_c_step_row(16'h0000, rm_rnd(4096));
                  gpu_c_tritex;
               end
            end
            gpu_wait_idle;
            reg_rd_mask(GPU_STAT, 32'h0, GS_ERR);
            gpu_check_touched("triangles back to back");
         end
      end

      //--------------------------------------------------------------
      rm_tb = ((VRAM_WORDS + 63) / 64) * 64;
      if ((VRAM_AW > 6) && (rm_tb < (1 << VRAM_AW))) begin
         $display("--- a table past VRAM_WORDS: ERR_CAUSE 5, nothing drawn");
         rm_set_mode(3);
         gpu_c_dst(RM_P, RM_DLO * 4);
         gpu_c_size(14'd20, 14'd2);
         gpu_c_remap_table(rm_tb);
         gpu_wait_idle;
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         rm_t = gpu_exec_word(GPU_FILL, 4'd0, 3'b000, 3'b000) | 32'h1000;
         gpu_push(rm_t);
         repeat(200) @(posedge free_clk);
         reg_rd_mask(GPU_STAT, {OP_EXEC_FILL, 3'd5, 25'h0} | GS_ERR, 32'hFE40_0000);
         reg_rd(GPU_ERR, rm_t);
         reg_rd_mask(IRQ_FLAG, IF_ERR, IF_ERR | IF_DONE);
         reg_wr(GPU_CTRL, 32'h1);
         reg_wr(IRQ_FLAG, IF_GPU_ALL);
         gpu_check_all("table past the VRAM");
      end

      //--------------------------------------------------------------
      // (DIM_W >= 10: rectangles long enough to be caught mid-way, as gpu_abort)
      if (GPU_DIM_MASK < 1023)
         $display("--- (DIM_W < 10: ABORT and freeze with table reads in flight not run)");
      else begin
         $display("--- ABORT with table reads in flight: a clean prefix");
         // (until one ABORT met a table read in flight)
         for (rm_k = 0; ((rm_k < 8) || ((rm_hit_ab == 0) && (rm_k < 40))) && (error == 0); rm_k = rm_k + 1) begin
            rm_set_mode(rm_k[0] ? 3 : 2);
            rm_long_start;
            repeat(20 + rm_rnd(300)) @(posedge free_clk);
            rm_ab_arm = 1'b1;
            reg_wr(GPU_CTRL, 32'h2);
            repeat(10) @(posedge free_clk);
            rm_ab_arm = 1'b0;
            reg_rd_mask(IRQ_FLAG, IF_IDLE, IF_DONE | IF_IDLE | IF_ERR);
            gpu_find_prefix(rm_j);
            if ((rm_j < 0) || (rm_j >= gpu_x_w * gpu_x_h)) begin
               $display("ERROR: GPU abandoned remapped fill -- not a strict prefix (n = %0d of %0d) %t", rm_j, gpu_x_w * gpu_x_h, $time);
               error = error + 1;
            end
            gpu_check_touched("abandoned remapped fill");
         end

         $display("--- debug freeze with table reads in flight: the image completed");
         reg_wr(DBG_CTRL, 32'h2);
         for (rm_k = 0; ((rm_k < 6) || ((rm_hit_fz == 0) && (rm_k < 30))) && (error == 0); rm_k = rm_k + 1) begin
            rm_set_mode(rm_k[0] ? 1 : 3);
            gpu_c_src(RM_P, RM_SLO * rm_ppw + RM_P);
            gpu_c_dst(RM_P, RM_DLO * rm_ppw + RM_P);
            gpu_c_size(14'd30, 14'd8);
            rm_table;
            gpu_wait_idle;
            rm_frz_arm = 1'b1;
            gpu_k_rmp  = rm_k[1] ? 2'd2 : 2'd1;
            gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);
            gpu_k_rmp  = 2'd0;
            for (rm_i = 0; rm_i < 12; rm_i = rm_i + 1) begin
               repeat(3 + rm_rnd(30)) @(posedge free_clk);
               @(negedge free_clk) dbg_stoptime = 1'b1;
               repeat(10 + rm_rnd(20)) @(posedge free_clk);
               @(negedge free_clk) dbg_stoptime = 1'b0;
            end
            gpu_wait_idle;
            rm_frz_arm = 1'b0;
            gpu_check_touched("remapped copy across freezes");
         end
         reg_wr(DBG_CTRL, 32'h0);
         $display("       table read in flight at %0d ABORTs, %0d freezes", rm_hit_ab, rm_hit_fz);
         if ((rm_hit_ab == 0) || (rm_hit_fz == 0)) begin
            $display("ERROR: GPU remap -- no ABORT or no freeze met a table read in flight %t", $time);
            error = error + 1;
         end
      end

      //--------------------------------------------------------------
      // SET_AUX REMAP_TABLE pushed while the remapped copy before it draws
      // (run-ahead: decoded during the draw, checked; without it the decoder
      // waits): the running copy keeps the old table, the next takes the new
      $display("--- SET_AUX REMAP_TABLE while the copy before it draws: old table for it, new for the next");
      for (rm_k = 0; rm_k < 6; rm_k = rm_k + 1) begin
         rm_set_mode((rm_k % 3 == 0) ? 3 : (rm_k % 3 == 1) ? 2 : 1);
         gpu_c_src(RM_P, RM_SLO * rm_ppw + RM_P);
         gpu_c_dst(RM_P, RM_DLO * rm_ppw + RM_P + rm_rnd(rm_ppw));
         gpu_c_size(RM_WMAX, 14'd8);
         gpu_c_remap_table(RM_TLO);
         gpu_wait_idle;
         gpu_k_rmp = rm_k[0] ? 2'd2 : 2'd1;
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);              // A: table 0
         reg_poll(GPU_STAT, GS_PRIM_BUSY, GS_PRIM_BUSY, 50);
         gpu_c_remap_table(RM_TLO + 64 * (1 + rm_rnd(3)));       // while A draws
         reg_rd_val(GPU_STAT, rm_st);
         if (!(rm_st & GS_PRIM_BUSY) ||
             ((GPU_RUNAHEAD_EN != 0) ? !(rm_st & GS_EMPTY) : (rm_st[15:8] != 8'd2))) begin
            $display("ERROR: GPU_STAT 0x%h after SET_AUX: %0s (test bug: A too short) %t", rm_st,
                     (GPU_RUNAHEAD_EN != 0) ? "decoded while A draws expected" : "queued behind A expected", $time);
            error = error + 1;
         end
         gpu_c_dst(RM_P, (RM_DLO + 512) * rm_ppw + RM_P + rm_rnd(rm_ppw));
         gpu_k_rmp = rm_k[1] ? 2'd2 : 2'd1;
         gpu_c_exec(GPU_COPY, 4'd0, 3'b000, 3'b000);              // B: the new table
         gpu_k_rmp = 2'd0;
         gpu_wait_idle;
         gpu_check_touched("SET_AUX REMAP_TABLE during a copy");
      end

      gpu_check_all("remap end");
      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
