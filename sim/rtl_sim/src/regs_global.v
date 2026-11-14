//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      regs_global
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_global.v
// Module Description : Global registers 0x000-0x07C: reset
//                      value of every register; BLNS_ID / BLNS_CFG /
//                      BLNS_CFG2 / VRAM_WORDS computed from the build
//                      parameters (fields packed from bit 0, nothing else); read-only registers ignore
//                      writes; write masks of every RW register with
//                      all-zero / all-one / alternating / random patterns,
//                      written in one pass and read back in a second pass
//                      (catches decode aliasing); DISP_SIZE 0 -> 1 per field
//                      and bdi_width_o / bdi_height_o; FRAME_SEL masked to
//                      FRAME_NR; FRAMEn_PTR count by FRAME_NR (PA_W bits,
//                      others RAZ/WI); IRQ_FLAG not settable by software;
//                      reserved offsets of the global block RAZ/WI with zero
//                      wait (0x070-0x07C, from 0x058 without the cursor:
//                      the cursor registers in regs_cursor); a DISP_SIZE field keeps its low
//                      DIM_W bits and stores a 0 as 1; LUT_CFG.SW_LUT_EN
//                      reads 0 without a LUT and REFR_BANK with one bank.
//----------------------------------------------------------------------------
`include "regs_tasks.v"

localparam integer PA_W     = VRAM_AW + 5;
localparam [31:0]  PA_MASK  = (PA_W >= 32) ? 32'hFFFF_FFFF : ((32'h1 << PA_W) - 1);
localparam [31:0]  DIM_MASK = (32'h1 << DIM_W) - 1;
localparam integer FS_BITS  = (FRAME_NR <= 1) ? 0 : (FRAME_NR <= 2) ? 1 : 2;
localparam [31:0]  FS_FMASK = (32'h1 << FS_BITS) - 1;

reg  [31:0] g_val;
reg  [31:0] g_rd;
reg  [31:0] g_pat [0:6];
reg  [31:0] g_wv  [0:15];
integer     g_i, g_p, g_n;

// RW registers checked by the mask pass (FRAME_SEL and LUT_CFG separately)
reg  [31:0] g_off [0:15];

function [31:0] g_ctrl_exp;
   input [31:0] v;
   begin
      g_ctrl_exp = v & ((GPU_EN != 0) ? 32'h0000_0017 : 32'h0000_0007);
   end
endfunction

function [31:0] g_size_exp;
   input [31:0] v;
   reg   [31:0] w, h;
   begin
      w = v & DIM_MASK;
      h = (v >> 16) & DIM_MASK;
      if (w == 0) w = 1;
      if (h == 0) h = 1;
      g_size_exp = (h << 16) | w;
   end
endfunction

// Expected read-back of RW register index k after writing v
function [31:0] g_exp;
   input integer k;
   input [31:0]  v;
   begin
      case (k)
        0: g_exp = g_ctrl_exp(v);                     // CTRL
        1: g_exp = v & 32'h0000_07F7;                 // IRQ_EN
        2: g_exp = g_size_exp(v);                     // DISP_SIZE
        3: g_exp = v & 32'h0000_0017;                 // DISP_CFG
        4: g_exp = v & 32'h0000_FFFF;                 // FRAME_CNT
        5: g_exp = v & 32'hFFFF_FFF0;                 // REFRESH (START kept 0 by the test)
        6: g_exp = v & 32'h0000_0003;                 // DBG_CTRL
        7: g_exp = (FRAME_NR > 0) ? (v & PA_MASK) : 0;  // FRAME0_PTR
        8: g_exp = (FRAME_NR > 1) ? (v & PA_MASK) : 0;  // FRAME1_PTR
        9: g_exp = (FRAME_NR > 2) ? (v & PA_MASK) : 0;  // FRAME2_PTR
       10: g_exp = (FRAME_NR > 3) ? (v & PA_MASK) : 0;  // FRAME3_PTR
        default: g_exp = 32'h0;
      endcase
   end
endfunction

initial
   begin
      $display(" ===============================================");
      $display("|          REGS: GLOBAL REGISTER BLOCK          |");
      $display(" ===============================================");
      @(posedge reset_done);

      g_off[0]  = CTRL;       g_off[1] = IRQ_EN;     g_off[2] = DISP_SIZE;  g_off[3] = DISP_CFG;
      g_off[4]  = FRAME_CNT;  g_off[5] = REFRESH;    g_off[6] = DBG_CTRL;   g_off[7] = FRAME0_PTR;
      g_off[8]  = FRAME1_PTR; g_off[9] = FRAME2_PTR; g_off[10] = FRAME3_PTR;
      g_n = 11;

      //------------------------------------------------------------------
      // Reset values
      //------------------------------------------------------------------
      reg_rd(BLNS_ID,    BLNS_VERSION_EXP);
      reg_rd(BLNS_CFG,   BLNS_CFG_EXP);
      reg_wr(BLNS_CFG,   32'hFFFF_FFFF);                             // read-only
      reg_rd(BLNS_CFG,   BLNS_CFG_EXP);
      reg_rd(BLNS_CFG2,  BLNS_CFG2_EXP);
      reg_wr(BLNS_CFG2,  32'hFFFF_FFFF);                             // read-only
      reg_rd(BLNS_CFG2,  BLNS_CFG2_EXP);
      reg_rd(32'h00C,    VRAM_WORDS & 32'h01FF_FFFF);                // VRAM_WORDS
      reg_wr(32'h00C,    32'hFFFF_FFFF);                             // read-only
      reg_rd(32'h00C,    VRAM_WORDS & 32'h01FF_FFFF);
      // REFR_PITCH: 16 bits, RW, reset 0
      reg_rd(REFR_PITCH, 32'h0);
      reg_wr(REFR_PITCH, 32'hFFFF_FFFF);
      reg_rd(REFR_PITCH, 32'h0000_FFFF);
      reg_wr(REFR_PITCH, 32'h0);
      reg_rd(CTRL,       32'h0);
      reg_rd(STATUS,     32'h0);
      reg_rd(IRQ_EN,     32'h0);
      reg_rd(IRQ_FLAG,   32'h0);
      reg_rd(DISP_SIZE,  32'h0001_0001);
      reg_rd(DISP_CFG,   32'h0);
      reg_rd(FRAME_CNT,  32'h0);
      reg_rd(REFRESH,    32'h0);
      reg_rd(FRAME_SEL,  32'h0);
      reg_rd(DBG_CTRL,   32'h0);
      reg_rd(FRAME0_PTR, 32'h0);
      reg_rd(FRAME1_PTR, 32'h0);
      reg_rd(FRAME2_PTR, 32'h0);
      reg_rd(FRAME3_PTR, 32'h0);
      reg_rd(LUT_CFG,    32'h0000_F000);
      if (bdi_width !== 1 || bdi_height !== 1)
         tb_error("bdi_width_o / bdi_height_o not 1 x 1 out of reset");

      //------------------------------------------------------------------
      // Read-only registers ignore writes
      //------------------------------------------------------------------
      reg_wr(BLNS_ID,  32'hFFFF_FFFF);
      reg_wr(BLNS_CFG, 32'hFFFF_FFFF);
      reg_wr(STATUS,   32'hFFFF_FFFF);
      reg_rd(BLNS_ID,  BLNS_VERSION_EXP);
      reg_rd(BLNS_CFG, BLNS_CFG_EXP);
      reg_rd(STATUS,   32'h0);
      reg_wr(BLNS_ID,  32'h0);
      reg_wr(BLNS_CFG, 32'h0);
      reg_rd(BLNS_ID,  BLNS_VERSION_EXP);
      reg_rd(BLNS_CFG, BLNS_CFG_EXP);

      // IRQ_FLAG: software cannot set a flag
      reg_wr(IRQ_FLAG, 32'hFFFF_FFFF);
      reg_rd(IRQ_FLAG, 32'h0);
      if (irq !== 1'b0) tb_error("irq_o high with no flag");

      //------------------------------------------------------------------
      // Write masks: write every RW register, then read them all back
      //------------------------------------------------------------------
      g_pat[0] = 32'h0000_0000;
      g_pat[1] = 32'hFFFF_FFFF;
      g_pat[2] = 32'hAAAA_AAAA;
      g_pat[3] = 32'h5555_5555;
      for (g_p = 4; g_p < 7; g_p = g_p + 1) g_pat[g_p] = $random(tmp_seed);

      for (g_p = 0; g_p < 7; g_p = g_p + 1) begin
         for (g_i = 0; g_i < g_n; g_i = g_i + 1) begin
            // vary the pattern per register so aliasing shows
            g_wv[g_i] = (g_p < 4) ? g_pat[g_p] : (g_pat[g_p] ^ (g_i * 32'h0101_0101) ^ ($random(tmp_seed) & 32'h00FF_00FF));
            if (g_i == 5) g_wv[g_i] = g_wv[g_i] & 32'hFFFF_FFFE;    // REFRESH: START stays 0
            reg_wr(g_off[g_i], g_wv[g_i]);
         end
         for (g_i = 0; g_i < g_n; g_i = g_i + 1)
            reg_rd(g_off[g_i], g_exp(g_i, g_wv[g_i]));
         // DISP_SIZE drives the BDI geometry outputs
         g_val = g_size_exp(g_wv[2]);
         if ((bdi_width !== g_val[DIM_W-1:0]) || (bdi_height !== g_val[16+DIM_W-1:16])) begin
            $display("ERROR: bdi_width_o/bdi_height_o = %0d x %0d / expected %0d x %0d %t",
                     bdi_width, bdi_height, g_val[DIM_W-1:0], g_val[16+DIM_W-1:16], $time);
            error = error + 1;
         end
         // Read-only registers unchanged by the RW traffic
         reg_rd(BLNS_ID,  BLNS_VERSION_EXP);
         reg_rd(BLNS_CFG, BLNS_CFG_EXP);
         reg_rd(IRQ_FLAG, 32'h0);
         reg_rd_mask(STATUS, 32'h0, 32'hFFFF_FFFF);
      end

      //------------------------------------------------------------------
      // CTRL: every GFX_MODE value reads back as written (modes 5-7 too)
      //------------------------------------------------------------------
      for (g_i = 0; g_i < 8; g_i = g_i + 1) begin
         reg_wr(CTRL, g_i);
         reg_rd(CTRL, g_i);
      end
      reg_wr(CTRL, 32'h0000_0010);
      reg_rd(CTRL, (GPU_EN != 0) ? 32'h0000_0010 : 32'h0);
      reg_wr(CTRL, 32'h0);

      //------------------------------------------------------------------
      // DISP_SIZE: each field clamps 0 -> 1 independently
      //------------------------------------------------------------------
      reg_wr(DISP_SIZE, 32'h0007_0000);
      reg_rd(DISP_SIZE, 32'h0007_0001);
      reg_wr(DISP_SIZE, 32'h0000_0005);
      reg_rd(DISP_SIZE, 32'h0001_0005);
      reg_wr(DISP_SIZE, DIM_MASK | (DIM_MASK << 16));
      reg_rd(DISP_SIZE, DIM_MASK | (DIM_MASK << 16));
      if ((bdi_width !== DIM_MASK[DIM_W-1:0]) || (bdi_height !== DIM_MASK[DIM_W-1:0]))
         tb_error("bdi_width_o/bdi_height_o not the maximum DISP_SIZE");
      if (DIM_W < 16) begin
         // Only bits above DIM_W set: the field keeps its low DIM_W bits,
         // all 0, so it is stored as 1
         reg_wr(DISP_SIZE, (32'h1 << DIM_W) | (32'h1 << (16 + DIM_W)));
         reg_rd(DISP_SIZE, 32'h0001_0001);
         reg_wr(DISP_SIZE, (32'h3 << (DIM_W - 1)) | (32'h5 << (16 + DIM_W - 2)));
         reg_rd(DISP_SIZE, ((32'h1 << (DIM_W - 1)) | ((32'h1 << (DIM_W - 2)) << 16)));
      end
      reg_wr(DISP_SIZE, 32'h0001_0001);

      //------------------------------------------------------------------
      // FRAME_SEL: refresh field masked to FRAME_NR, [5:4] LATCHED
      //------------------------------------------------------------------
      for (g_p = 0; g_p < 6; g_p = g_p + 1) begin
         g_val = (g_p == 0) ? 32'hFFFF_FFFF : (g_p == 1) ? 32'h0 : (g_p == 2) ? 32'h0000_1101 :
                 (g_p == 3) ? 32'h0000_2202 : $random(tmp_seed);
         reg_wr(FRAME_SEL, g_val);
         reg_rd_val(FRAME_SEL, g_rd);
         if ((g_rd & ~32'h0000_0033) !== 0) begin
            $display("ERROR: FRAME_SEL reserved bits set: wrote 0x%h read 0x%h %t", g_val, g_rd, $time);
            error = error + 1;
         end
         // refresh frame: exactly the low FS_BITS bits; [5:4] LATCHED, the
         // index latched for the next frame: the same, no refresh running
         if (((g_rd >> 4) & 3) !== (g_val & FS_FMASK)) begin
            $display("ERROR: FRAME_SEL latched index [5:4]: wrote 0x%h read 0x%h %t", g_val, g_rd, $time);
            error = error + 1;
         end
         if ((g_rd & 32'h3) !== (g_val & FS_FMASK)) begin
            $display("ERROR: FRAME_SEL refresh field: wrote 0x%h read 0x%h / expected field %0d %t", g_val, g_rd, g_val & FS_FMASK, $time);
            error = error + 1;
         end
      end
      reg_wr(FRAME_SEL, 32'h0);

      //------------------------------------------------------------------
      // LUT_CFG
      //------------------------------------------------------------------
      reg_wr(LUT_CFG, 32'hFFFF_FFFF);
      reg_rd_val(LUT_CFG, g_rd);
      if ((LUT_EN != 0) && (LUT_BANKS == 2)) begin
         if (g_rd !== 32'h0000_FF73) begin
            $display("ERROR: LUT_CFG all-ones reads 0x%h / expected 0x0000ff73 %t", g_rd, $time);
            error = error + 1;
         end
      end else begin
         if ((g_rd & 32'hFFFF_FFF0) !== 32'h0000_FF70) begin
            $display("ERROR: LUT_CFG all-ones reads 0x%h / expected HW_PALETTE/BG/FG 0x0000ff70 %t", g_rd, $time);
            error = error + 1;
         end
         if ((g_rd & 32'hC) !== 0) tb_error("LUT_CFG reserved bits [3:2] set");
         // SW_LUT_EN reads 0 without a LUT, REFR_BANK reads 0 with one bank
         if ((g_rd & 32'h3) !== ((LUT_EN != 0) ? 32'h1 : 32'h0)) begin
            $display("ERROR: LUT_CFG all-ones: [1:0] = %0d with LUT_EN = %0d LUT_BANKS = %0d %t", g_rd & 3, LUT_EN, LUT_BANKS, $time);
            error = error + 1;
         end
      end
      for (g_p = 0; g_p < 4; g_p = g_p + 1) begin
         g_val = $random(tmp_seed);
         reg_wr(LUT_CFG, g_val);
         reg_rd_mask(LUT_CFG, g_val & 32'h0000_FF70, 32'hFFFF_FFFC);
         if ((LUT_EN != 0) && (LUT_BANKS == 2))
            reg_rd(LUT_CFG, g_val & 32'h0000_FF73);
         else if (LUT_EN != 0)
            reg_rd(LUT_CFG, g_val & 32'h0000_FF71);
         else
            reg_rd(LUT_CFG, g_val & 32'h0000_FF70);
      end
      reg_wr(LUT_CFG, 32'h0000_F000);

      // LUT_ROT: [23:0] with a LUT, read 0 without
      reg_rd(LUT_ROT, 32'h0);
      for (g_p = 0; g_p < 4; g_p = g_p + 1) begin
         g_val = $random(tmp_seed);
         reg_wr(LUT_ROT, g_val);
         reg_rd(LUT_ROT, (LUT_EN != 0) ? (g_val & 32'h00FF_FFFF) : 32'h0);
      end
      reg_wr(LUT_ROT, 32'h0);

      //------------------------------------------------------------------
      // Reserved offsets of the global block: RAZ/WI, zero wait
      //------------------------------------------------------------------
      // 0x038 FRAME_NUM: read only (regs_frame_num)
      reg_rd_val(FRAME_NUM, g_rd);
      reg_wr(FRAME_NUM, 32'hFFFF_FFFF);
      reg_rd(FRAME_NUM, g_rd & 32'h0000_FFFF);
      rp_clear;
      g_i = (CURSOR_EN != 0) ? 32'h070 : 32'h058;
      while (g_i < 32'h080) begin
         begin
            rp_w(g_i, 32'hFFFF_FFFF, 0);
            rp_r(g_i, 0);
         end
         g_i = g_i + 4;
      end
      rp_run;
      for (g_i = 0; g_i < rp_n; g_i = g_i + 1)
         rp_chk(g_i, OK, 32'h0, rp_wr[g_i] ? 32'h0 : 32'hFFFF_FFFF, 0);
      // and nothing else changed
      reg_rd(CTRL,       32'h0);
      reg_rd(IRQ_EN,     g_exp(1, g_wv[1]));
      reg_rd(LUT_CFG,    32'h0000_F000);
      reg_rd(BLNS_CFG,   BLNS_CFG_EXP);
      reg_rd(32'h00C,    VRAM_WORDS & 32'h01FF_FFFF);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
