//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      smoke_regs
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : smoke_regs.v
// Module Description : Smoke test of the register port: BLNS_ID and BLNS_CFG
//                      (computed from the bench parameters), CTRL / IRQ_EN /
//                      DISP_SIZE write-read, an unmapped offset (OKAY, reads
//                      0), sub-word accesses (two-cycle ERROR, no side
//                      effect) and, with PRIV_CHECK_EN, a U-mode access
//                      (ERROR).
//----------------------------------------------------------------------------

reg [31:0] dim_mask;

initial
   begin
      $display(" ===============================================");
      $display("|                 SMOKE: REGISTERS              |");
      $display(" ===============================================");
      @(posedge reset_done);

      // Identification
      reg_rd(BLNS_ID, BLNS_VERSION_EXP);

      reg_rd(BLNS_CFG,  BLNS_CFG_EXP);
      reg_rd(BLNS_CFG2, BLNS_CFG2_EXP);
      reg_rd(FRAME_NUM, 32'h0);

      // CTRL: [2:0] GFX_MODE, [4] GPU_EN (only with the GPU present)
      reg_rd(CTRL, 32'h0000_0000);
      reg_wr(CTRL, 32'hFFFF_FFFF);
      reg_rd(CTRL, (GPU_EN != 0) ? 32'h0000_0017 : 32'h0000_0007);
      reg_wr(CTRL, 32'h0000_0004);
      reg_rd(CTRL, 32'h0000_0004);
      reg_wr(CTRL, 32'h0000_0000);

      // IRQ_EN: one bit per IRQ_FLAG bit (bit 3 reserved)
      reg_rd(IRQ_EN, 32'h0000_0000);
      reg_wr(IRQ_EN, 32'hFFFF_FFFF);
      reg_rd(IRQ_EN, 32'h0000_07F7);
      reg_wr(IRQ_EN, 32'h0000_0000);
      reg_rd(IRQ_EN, 32'h0000_0000);

      // DISP_SIZE: reset 1x1, a value, 0 -> 1, all-ones masked to DIM_W
      dim_mask = (32'h1 << DIM_W) - 1;
      reg_rd(DISP_SIZE, 32'h0001_0001);
      reg_wr(DISP_SIZE, 32'h0004_0008);
      reg_rd(DISP_SIZE, 32'h0004_0008);
      reg_wr(DISP_SIZE, 32'h0000_0000);
      reg_rd(DISP_SIZE, 32'h0001_0001);
      reg_wr(DISP_SIZE, 32'hFFFF_FFFF);
      reg_rd(DISP_SIZE, (dim_mask << 16) | dim_mask);

      // Unmapped offset in the global space: OKAY, reads 0, write ignored
      reg_wr(32'h0000_007C, 32'hFFFF_FFFF);
      reg_rd(32'h0000_007C, 32'h0000_0000);

      // Sub-word accesses: two-cycle ERROR, no side effect
      reg_wr(CTRL, 32'h0000_0003);
      ahb_write_x(PORT_R, CTRL,     32'h0000_0005, SZ_B, MACHINE, HART_MASTER, ERROR);
      ahb_write_x(PORT_R, CTRL + 2, 32'h0000_0005, SZ_H, MACHINE, HART_MASTER, ERROR);
      ahb_read_x (PORT_R, CTRL,     32'h0, 32'h0, SZ_B, MACHINE, HART_MASTER, 1'b0, ERROR);
      ahb_read_x (PORT_R, BLNS_ID,  32'h0, 32'h0, SZ_H, MACHINE, HART_MASTER, 1'b0, ERROR);
      reg_rd(CTRL, 32'h0000_0003);
      reg_wr(CTRL, 32'h0000_0000);

      // Privilege: U-mode is denied only with PRIV_CHECK_EN; S-mode always allowed
      ahb_read_x (PORT_R, BLNS_ID, BLNS_VERSION_EXP, 32'hFFFF_FFFF, SZ_W, SUPERVISOR, HART_MASTER, 1'b1, OK);
      if (PRIV_CHECK_EN != 0) begin
         ahb_write_x(PORT_R, CTRL,    32'h0000_0002, SZ_W, USER, HART_MASTER, ERROR);
         ahb_read_x (PORT_R, BLNS_ID, 32'h0, 32'h0,  SZ_W, USER, HART_MASTER, 1'b0, ERROR);
         reg_rd(CTRL, 32'h0000_0000);
      end else begin
         ahb_write_x(PORT_R, CTRL,    32'h0000_0002, SZ_W, USER, HART_MASTER, OK);
         ahb_read_x (PORT_R, CTRL,    32'h0000_0002, 32'hFFFF_FFFF, SZ_W, USER, HART_MASTER, 1'b1, OK);
         reg_wr(CTRL, 32'h0000_0000);
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
