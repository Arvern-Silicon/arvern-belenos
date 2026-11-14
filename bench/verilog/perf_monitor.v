//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    perf_monitor
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : perf_monitor.v
// Module Description : Passive cycle counters (`included into tb_belenos),
//                      printed as one "PERF:" line by tb_extra_report: cycles
//                      since reset_done, VRAM grants per requester, the GPU's
//                      busy cycles, the pixel engine's cycles with a read in
//                      flight and with F holding a token, and the VRAM-window
//                      wait cycles. Compares a build against another on the
//                      same test and seed.
//----------------------------------------------------------------------------

`define PM_ARB dut.u_core.u_vram_arb

integer pm_cyc, pm_bk, pm_win_rd, pm_win_wr, pm_gpu_rd, pm_gpu_wr;
integer pm_gpu_busy, pm_px_rdp, pm_px_fstall, pm_v_wait;
initial begin
   pm_cyc = 0; pm_bk = 0; pm_win_rd = 0; pm_win_wr = 0; pm_gpu_rd = 0; pm_gpu_wr = 0;
   pm_gpu_busy = 0; pm_px_rdp = 0; pm_px_fstall = 0; pm_v_wait = 0;
end

always @(posedge free_clk)
   if (reset_done === 1'b1) begin
      pm_cyc = pm_cyc + 1;
      if (`PM_ARB.gnt_o[VRQ_BK] === 1'b1)                                          pm_bk     = pm_bk + 1;
      if ((`PM_ARB.gnt_o[VRQ_WIN] === 1'b1) && (`PM_ARB.we_i[VRQ_WIN] !== 1'b1)) pm_win_rd = pm_win_rd + 1;
      if ((`PM_ARB.gnt_o[VRQ_WIN] === 1'b1) && (`PM_ARB.we_i[VRQ_WIN] === 1'b1)) pm_win_wr = pm_win_wr + 1;
      if ((`PM_ARB.gnt_o[VRQ_GPU] === 1'b1) && (`PM_ARB.we_i[VRQ_GPU] !== 1'b1)) pm_gpu_rd = pm_gpu_rd + 1;
      if ((`PM_ARB.gnt_o[VRQ_GPU] === 1'b1) && (`PM_ARB.we_i[VRQ_GPU] === 1'b1)) pm_gpu_wr = pm_gpu_wr + 1;
      if (v_hready === 1'b0)                                                     pm_v_wait = pm_v_wait + 1;
   end

generate
   if (GPU_EN != 0) begin : g_pm_gpu
      always @(posedge free_clk)
         if (reset_done === 1'b1) begin
            if (dut.u_core.G_GPU.u_gpu.busy_o === 1'b1)                         pm_gpu_busy  = pm_gpu_busy + 1;
            if (dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.rd_pend === 1'b1)       pm_px_rdp    = pm_px_rdp + 1;
            if ((dut.u_core.G_GPU.u_gpu.u_px.t1_v === 1'b1) &&
                (dut.u_core.G_GPU.u_gpu.u_px.u_px_fw.f_take !== 1'b1))      pm_px_fstall = pm_px_fstall + 1;
         end
   end
endgenerate

task perf_report;
   begin
      $display("PERF: cyc=%0d bk=%0d win_rd=%0d win_wr=%0d gpu_rd=%0d gpu_wr=%0d gpu_busy=%0d px_rdpend=%0d px_fstall=%0d v_wait=%0d",
               pm_cyc, pm_bk, pm_win_rd, pm_win_wr, pm_gpu_rd, pm_gpu_wr,
               pm_gpu_busy, pm_px_rdp, pm_px_fstall, pm_v_wait);
   end
endtask
