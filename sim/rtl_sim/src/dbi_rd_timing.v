//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_rd_timing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_rd_timing.v
// Module Description : 8080 read strobe divider (DIF_CFG.RD_DIV) against the
//                      ILI9341 AC minima, checked by the panel model in ns
//                      (t_WRL / t_WRH 15, t_WC 66, t_RDL 45, t_RDH 90,
//                      t_RC 160). A refresh with scanline sync polls
//                      Get_Scanline and sends its pixels:
//                      1. CLK_DIV for the writes only (2*(CLK_DIV+1) cycles
//                         >= 66 ns) and RD_DIV 0 (reads follow CLK_DIV): the
//                         model must flag t_RDH (the checks are live);
//                      2. the same CLK_DIV with the smallest RD_DIV giving
//                         2*RD_DIV+1 cycles >= 90 ns: no violation, the scan
//                         values read are right, the writes keep CLK_DIV
//                         (the protocol monitor checks the cycle counts).
//                      Both refreshes also run the model's t_CS 15 / t_RCS 45
//                      (1: to the strobe's rising edge, as in the data sheet
//                      figure; 2: to its falling edge, the stricter reading),
//                      read access (t_RAT 40: D is X until then) and output
//                      disable (t_ROD 80) checks, and require the host to
//                      release D at least one cycle before RD falls (t_HZ):
//                      in 2 a wrong scan value or any of these is an error.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

localparam integer RT_T     = 2 * CLK_HALF;                    // hclk period (ns)
localparam integer RT_WDIV  = (66 + 2*RT_T - 1) / (2*RT_T) - 1; // writes: 2*(D+1)*T >= t_WC 66 ns
localparam integer RT_RN    = (90 + RT_T - 1) / RT_T;          // cycles for t_RDH 90 ns
localparam integer RT_RDIV  = RT_RN / 2;                       // 2*RD_DIV+1 >= RT_RN

integer    rt_kk, rt_p0, rt_rd0;

// One refresh with scanline sync: polls 0x010, 0x020, 0x030, 0x040 (SCANLINE
// 0x035 crossed at the fourth)
task rt_refresh;
   input [3:0] wdiv;
   input [3:0] rdiv;
   begin
      dif_cfg_rd(PHY_8080, wdiv, rdiv, 1'b1, 1'b1, 1'b0);
      scan_seq[0] = 10'h010; scan_seq[1] = 10'h020; scan_seq[2] = 10'h030;
      scan_seq[3] = 10'h040; scan_seq[4] = 10'h050;
      scan_seq_n   = 5;
      scan_seq_idx = 0;
      scan_seq_en  = 1'b1;
      rt_p0        = poll_nr;
      rt_rd0       = u_lcd8080.rd_count;
      reg_wr(DIF_SYNC, 32'h0000_8000 | 32'h035);
      reg_wr(REFRESH, 32'h0000_0001);
      reg_poll(REFRESH, 32'h1, 32'h0, 50000);
      dif_wait_idle(50000);
      scan_seq_en = 1'b0;
      reg_wr(DIF_SYNC, 32'h0);
      if (poll_nr - rt_p0 != 4) begin
         $display("ERROR: RD_DIV %0d: %0d polls / expected 4", rdiv, poll_nr - rt_p0);
         error = error + 1;
      end
      for (rt_kk = 0; (rt_kk < 4) && (rt_p0 + rt_kk < poll_nr); rt_kk = rt_kk + 1)
        if (poll_gts[rt_p0 + rt_kk] !== scan_seq[rt_kk]) begin
           $display("ERROR: RD_DIV %0d: poll %0d read GTS 0x%h / model 0x%h", rdiv, rt_kk,
                    poll_gts[rt_p0 + rt_kk], scan_seq[rt_kk]);
           error = error + 1;
        end
      if (u_lcd8080.rd_count - rt_rd0 != 12) begin
         $display("ERROR: RD_DIV %0d: %0d read strobes / expected 12", rdiv, u_lcd8080.rd_count - rt_rd0);
         error = error + 1;
      end
      reg_wr(IRQ_FLAG, 32'h3);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|     DBI: 8080 READ STROBE DIVIDER (RD_DIV)    |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_8080)
         tb_skip_finish("|        (no 8080 PHY in this build)            |");

      $display("INFO:  hclk %0d ns: CLK_DIV %0d (WR %0d ns), RD_DIV %0d (RD %0d ns)",
               RT_T, RT_WDIV, (RT_WDIV + 1) * RT_T, RT_RDIV, (2*RT_RDIV + 1) * RT_T);
      reg_wr(CTRL, {29'h0, GFX_16BPP});
      reg_wr(DISP_SIZE, (4 << 16) | 8);
      reg_wr(FRAME0_PTR, 32'h0);
      reg_wr(FRAME_SEL,  32'h0);

      // RD_DIV reads back, 0 after reset
      reg_rd_mask(DIF_CFG, 32'h0, 32'h0000_00F0);
      dif_cfg_rd(PHY_8080, 4'd0, 4'hA, 1'b0, 1'b0, 1'b0);
      reg_rd_mask(DIF_CFG, 32'h0000_00A0, 32'h0000_00F0);

      u_lcd8080.t_wrl_min = 15.0; u_lcd8080.t_wrh_min = 15.0; u_lcd8080.t_wc_min = 66.0;
      u_lcd8080.t_rdl_min = 45.0; u_lcd8080.t_rdh_min = 90.0; u_lcd8080.t_rc_min = 160.0;
      u_lcd8080.t_cs_min  = 15.0; u_lcd8080.t_rcs_min = 45.0;
      u_lcd8080.t_rat_max = 40.0; u_lcd8080.t_rod_max = 80.0;
      u_lcd8080.t_hz_min  = RT_T - 1.0;   // bus released at least a cycle before RD falls

      // 1. reads at CLK_DIV: t_RDH flagged
      u_lcd8080.ac_count = 0;
      rt_refresh(RT_WDIV, 4'd0);
      if (u_lcd8080.ac_count == 0)
         tb_error("RD_DIV 0: the panel model did not flag the short read strobe");
      else
         $display("OK:    RD_DIV 0 at CLK_DIV %0d: %0d AC violations flagged (RD high %0.1f ns)",
                  RT_WDIV, u_lcd8080.ac_count, u_lcd8080.ac_rdh_seen);

      // 2. reads at RD_DIV: no violation; t_CS / t_RCS taken to the strobe's
      //    falling edge (the CS lead is one write phase, CLK_DIV+1 cycles)
      u_lcd8080.ac_count       = 0;
      u_lcd8080.ac_cs_fall_ref = 1'b1;
      u_lcd8080.ac_rdl_seen = 1.0e9; u_lcd8080.ac_rdh_seen = 1.0e9;
      u_lcd8080.ac_wrl_seen = 1.0e9; u_lcd8080.ac_wrh_seen = 1.0e9;
      rt_refresh(RT_WDIV, RT_RDIV);
      if (u_lcd8080.ac_count != 0) begin
         $display("ERROR: RD_DIV %0d: %0d AC violations", RT_RDIV, u_lcd8080.ac_count);
         error = error + 1;
      end else
         $display("OK:    RD_DIV %0d: RD low %0.1f / high %0.1f ns, WR low %0.1f / high %0.1f ns",
                  RT_RDIV, u_lcd8080.ac_rdl_seen, u_lcd8080.ac_rdh_seen,
                  u_lcd8080.ac_wrl_seen, u_lcd8080.ac_wrh_seen);
      if ((u_lcd8080.ac_rdh_seen > 1.0e8) || (u_lcd8080.ac_wrl_seen > 1.0e8))
         tb_error("no read high phase or write strobe measured");

      u_lcd8080.t_wrl_min = 0.0; u_lcd8080.t_wrh_min = 0.0; u_lcd8080.t_wc_min = 0.0;
      u_lcd8080.t_rdl_min = 0.0; u_lcd8080.t_rdh_min = 0.0; u_lcd8080.t_rc_min = 0.0;
      u_lcd8080.t_cs_min  = 0.0; u_lcd8080.t_rcs_min = 0.0; u_lcd8080.t_hz_min  = 0.0;
      u_lcd8080.t_rat_max = 0.0; u_lcd8080.t_rod_max = 0.0; u_lcd8080.ac_cs_fall_ref = 1'b0;
      dif_cfg(PHY_8080, 4'd0, 1'b0, 1'b0, 1'b0);

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");

      repeat (5) @(posedge free_clk);
      stimulus_done = 1;
   end
