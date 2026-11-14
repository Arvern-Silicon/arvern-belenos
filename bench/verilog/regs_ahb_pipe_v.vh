//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    regs_ahb_pipe_v
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_ahb_pipe_v.vh
// Module Description : Pipelined AHB-Lite manager for the VRAM-window port
//                      (`included by regs_tasks.v). Generated from
//                      regs_ahb_pipe_r.vh (r_h -> v_h, rp_ -> vp_); edit
//                      that file and regenerate.
//----------------------------------------------------------------------------
//============================================================================
// Pipelined AHB-Lite manager (vp_* on the register port, vp_* on the VRAM
// window port: same text).
//
// A transfer list is built with vp_add and executed by vp_run: the address
// phase of transfer n+1 is presented during the data phase of transfer n
// (unless a gap is requested), the address phase is held while hready is
// low, write data is driven only in the data phase (garbage otherwise), and
// every data-phase cycle is sampled so the two-cycle ERROR shape is checked
// (wait cycle: hreadyout 0 + hresp 1; completion: hready 1 + hresp 1). With
// vp_cancel_on_err = 1 the manager turns a pending address phase into IDLE
// after the first ERROR cycle (the transfer is marked cancelled).
//============================================================================
reg        [31:0] vp_addr   [0:PIPE_MAX-1];
reg               vp_wr     [0:PIPE_MAX-1];
reg         [2:0] vp_size   [0:PIPE_MAX-1];
reg         [1:0] vp_trans  [0:PIPE_MAX-1];
reg         [1:0] vp_mode   [0:PIPE_MAX-1];
reg         [3:0] vp_master [0:PIPE_MAX-1];
reg        [31:0] vp_wdata  [0:PIPE_MAX-1];
integer           vp_gap    [0:PIPE_MAX-1];
reg        [31:0] vp_rdata  [0:PIPE_MAX-1];
reg               vp_resp   [0:PIPE_MAX-1];
integer           vp_waits  [0:PIPE_MAX-1];
reg               vp_shape  [0:PIPE_MAX-1];
reg               vp_cancelled [0:PIPE_MAX-1];
integer           vp_cyc_acc [0:PIPE_MAX-1];   // pipe cycle of the address-phase acceptance
integer           vp_cyc_end [0:PIPE_MAX-1];   // pipe cycle of the data-phase completion
integer           vp_n;
reg               vp_cancel_on_err;
reg               vp_idle_hsel;                // keep hsel high while idle
integer           vp_cyc;                      // pipe cycle counter (posedges since vp_run start)

initial begin
   vp_n             = 0;
   vp_cancel_on_err = 1'b0;
   vp_idle_hsel     = 1'b0;
   vp_cyc           = 0;
end

task vp_clear;
   begin
      vp_n = 0;
   end
endtask

// Append one transfer. trans: 2'b10 NONSEQ, 2'b11 SEQ, 2'b01 BUSY, 2'b00 IDLE
// (with hsel high). wdata is the full 32-bit bus value of the data phase.
task vp_add;
   input  [31:0] addr;
   input         wr;
   input   [2:0] size;
   input  [31:0] wdata;
   input   [1:0] mode;
   input   [3:0] master;
   input   [1:0] trans;
   input integer gap;
   begin
      vp_addr[vp_n]   = addr;
      vp_wr[vp_n]     = wr;
      vp_size[vp_n]   = size;
      vp_wdata[vp_n]  = wdata;
      vp_mode[vp_n]   = mode;
      vp_master[vp_n] = master;
      vp_trans[vp_n]  = trans;
      vp_gap[vp_n]    = gap;
      vp_rdata[vp_n]  = 32'hxxxx_xxxx;
      vp_resp[vp_n]   = 1'bx;
      vp_waits[vp_n]  = -1;
      vp_shape[vp_n]  = 1'b0;
      vp_cancelled[vp_n] = 1'b0;
      vp_n = vp_n + 1;
   end
endtask

// Shorthands: word / sized NONSEQ, machine mode, hart master
task vp_w;
   input  [31:0] addr;
   input  [31:0] wdata;
   input integer gap;
   begin
      vp_add(addr, 1'b1, 3'b010, wdata, MACHINE, HART_MASTER, 2'b10, gap);
   end
endtask

task vp_r;
   input  [31:0] addr;
   input integer gap;
   begin
      vp_add(addr, 1'b0, 3'b010, 32'h0, MACHINE, HART_MASTER, 2'b10, gap);
   end
endtask

task vp_drive_idle;
   begin
      v_hsel    = vp_idle_hsel;
      v_htrans  = 2'b00;
      v_haddr   = $random(tmp_seed);
      v_hwrite  = $random(tmp_seed);
      v_hsize   = $random(tmp_seed);
      v_hprot   = 4'h3;
      v_hsmode  = 1'b0;
      v_hmaster = 4'h0;
   end
endtask

task vp_run;
   integer ai, ap, dp, gc, w;
   reg     ap_v, dp_v, hr, hrs, acc, dp_done, err1, bad_wait_resp, cancel_now;
   reg     [31:0] hrd;
   begin
      ai = 0; ap = 0; dp = 0; gc = 0; w = 0;
      ap_v = 1'b0; dp_v = 1'b0; err1 = 1'b0; bad_wait_resp = 1'b0; cancel_now = 1'b0;
      vp_cyc = 0;
      @(posedge free_clk);
      while ((ai < vp_n) || ap_v || dp_v) begin
         // posedge: present the next address phase
         if (!ap_v) begin
            if (ai < vp_n) begin
               if (gc >= vp_gap[ai]) begin
                  v_hsel    = 1'b1;
                  v_haddr   = vp_addr[ai];
                  v_htrans  = vp_trans[ai];
                  v_hwrite  = vp_wr[ai];
                  v_hsize   = vp_size[ai];
                  ax_prot_r = $random(ax_prot_seed);   // hprot[0], [2], [3] random
                  v_hprot   = {ax_prot_r[3:2], (vp_mode[ai] == USER) ? 1'b0 : (vp_mode[ai] == 2'b10) ? 1'b0 : 1'b1, ax_prot_r[0]};
                  v_hsmode  = (vp_mode[ai] == SUPERVISOR) || (vp_mode[ai] == 2'b10);
                  v_hmaster = vp_master[ai];
                  ap = ai; ap_v = 1'b1; ai = ai + 1; gc = 0;
               end else begin
                  vp_drive_idle;
                  gc = gc + 1;
               end
            end else begin
               vp_drive_idle;
            end
         end
         // negedge: sample the data-phase response
         @(negedge free_clk);
         hr  = v_hready;
         hrs = v_hresp;
         hrd = v_hrdata;
         dp_done = 1'b0;
         if (dp_v) begin
            if (hr === 1'b1) begin
               vp_rdata[dp] = hrd;
               vp_resp[dp]  = hrs;
               vp_waits[dp] = w;
               vp_cyc_end[dp] = vp_cyc;
               vp_shape[dp] = (hrs === 1'b1) ? (err1 && (w == 1)) : (!err1 && !bad_wait_resp);
               dp_done = 1'b1;
            end else begin
               if (hrs === 1'b1) begin
                  err1 = 1'b1;
                  if (vp_cancel_on_err && ap_v) cancel_now = 1'b1;
               end else if (err1) begin
                  bad_wait_resp = 1'b1;
               end
               w = w + 1;
               if (w > AHB_MAX_WAIT) begin
                  $display("ERROR: vp_run -- transfer %0d (address 0x%h) hung %t", dp, vp_addr[dp], $time);
                  error = error + 1;
                  vp_waits[dp] = w; vp_resp[dp] = 1'bx;
                  dp_done = 1'b1;
               end
            end
         end
         acc = ap_v && (hr === 1'b1);
         @(posedge free_clk);
         vp_cyc = vp_cyc + 1;
         if (dp_done) dp_v = 1'b0;
         if (cancel_now) begin
            vp_cancelled[ap] = 1'b1;
            ap_v = 1'b0;
            cancel_now = 1'b0;
            vp_drive_idle;
         end
         if (acc) begin
            vp_cyc_acc[ap] = vp_cyc;
            dp = ap; dp_v = 1'b1; ap_v = 1'b0; w = 0; err1 = 1'b0; bad_wait_resp = 1'b0;
            if (vp_wr[dp] && vp_trans[dp][1]) v_hwdata = vp_wdata[dp];
            else                              v_hwdata = $random(tmp_seed);
         end else if (dp_done) begin
            v_hwdata = $random(tmp_seed);
         end
      end
      vp_drive_idle;
      v_hsel = 1'b0;
   end
endtask

// Check one executed transfer. exp_waits < 0: not checked.
task vp_chk;
   input integer i;
   input         exp_resp;
   input  [31:0] exp_data;
   input  [31:0] mask;
   input integer exp_waits;
   begin
      tb_checks = tb_checks + 1;                 // one comparison (tb_min_checks)
      if (vp_cancelled[i]) begin
         $display("ERROR: rp transfer %0d (0x%h) was cancelled %t", i, vp_addr[i], $time);
         error = error + 1;
      end else if (vp_resp[i] !== exp_resp) begin
         $display("ERROR: rp transfer %0d (%s 0x%h size %0d) hresp %b / expected %b %t",
                  i, vp_wr[i] ? "write" : "read", vp_addr[i], vp_size[i], vp_resp[i], exp_resp, $time);
         error = error + 1;
      end else if (!vp_shape[i]) begin
         $display("ERROR: rp transfer %0d (%s 0x%h) bad response shape (waits %0d, resp %b) %t",
                  i, vp_wr[i] ? "write" : "read", vp_addr[i], vp_waits[i], vp_resp[i], $time);
         error = error + 1;
      end else if ((exp_waits >= 0) &&
                   (vp_wr[i] | vp_resp[i] ? (vp_waits[i] != exp_waits)
                                          : (vp_waits[i] >  exp_waits + VWIN_RD_L - 1))) begin
         // a read (OKAY) waits a cycle more per cycle of the window's read
         // latency past the first (VWIN_RD_L), and none when the read-ahead
         // buffer has its word
         $display("ERROR: rp transfer %0d (%s 0x%h) %0d wait states / expected %0d %t",
                  i, vp_wr[i] ? "write" : "read", vp_addr[i], vp_waits[i],
                  exp_waits + ((vp_wr[i] | vp_resp[i]) ? 0 : (VWIN_RD_L - 1)), $time);
         error = error + 1;
      end else if (((vp_rdata[i] & mask) !== (exp_data & mask))) begin
         $display("ERROR: rp transfer %0d (read 0x%h) data 0x%h / expected 0x%h (mask 0x%h) %t",
                  i, vp_addr[i], vp_rdata[i] & mask, exp_data & mask, mask, $time);
         error = error + 1;
      end
   end
endtask
