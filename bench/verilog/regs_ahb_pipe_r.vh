//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    regs_ahb_pipe_r
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : regs_ahb_pipe_r.vh
// Module Description : Pipelined AHB-Lite manager for the register port
//                      (`included by regs_tasks.v). regs_ahb_pipe_v.vh is
//                      this text below the header with r_h -> v_h and
//                      rp_ -> vp_ (whole-word substitutions).
//----------------------------------------------------------------------------
//============================================================================
// Pipelined AHB-Lite manager (rp_* on the register port, vp_* on the VRAM
// window port: same text).
//
// A transfer list is built with rp_add and executed by rp_run: the address
// phase of transfer n+1 is presented during the data phase of transfer n
// (unless a gap is requested), the address phase is held while hready is
// low, write data is driven only in the data phase (garbage otherwise), and
// every data-phase cycle is sampled so the two-cycle ERROR shape is checked
// (wait cycle: hreadyout 0 + hresp 1; completion: hready 1 + hresp 1). With
// rp_cancel_on_err = 1 the manager turns a pending address phase into IDLE
// after the first ERROR cycle (the transfer is marked cancelled).
//============================================================================
reg        [31:0] rp_addr   [0:PIPE_MAX-1];
reg               rp_wr     [0:PIPE_MAX-1];
reg         [2:0] rp_size   [0:PIPE_MAX-1];
reg         [1:0] rp_trans  [0:PIPE_MAX-1];
reg         [1:0] rp_mode   [0:PIPE_MAX-1];
reg         [3:0] rp_master [0:PIPE_MAX-1];
reg        [31:0] rp_wdata  [0:PIPE_MAX-1];
integer           rp_gap    [0:PIPE_MAX-1];
reg        [31:0] rp_rdata  [0:PIPE_MAX-1];
reg               rp_resp   [0:PIPE_MAX-1];
integer           rp_waits  [0:PIPE_MAX-1];
reg               rp_shape  [0:PIPE_MAX-1];
reg               rp_cancelled [0:PIPE_MAX-1];
integer           rp_cyc_acc [0:PIPE_MAX-1];   // pipe cycle of the address-phase acceptance
integer           rp_cyc_end [0:PIPE_MAX-1];   // pipe cycle of the data-phase completion
integer           rp_n;
reg               rp_cancel_on_err;
reg               rp_idle_hsel;                // keep hsel high while idle
integer           rp_cyc;                      // pipe cycle counter (posedges since rp_run start)

initial begin
   rp_n             = 0;
   rp_cancel_on_err = 1'b0;
   rp_idle_hsel     = 1'b0;
   rp_cyc           = 0;
end

task rp_clear;
   begin
      rp_n = 0;
   end
endtask

// Append one transfer. trans: 2'b10 NONSEQ, 2'b11 SEQ, 2'b01 BUSY, 2'b00 IDLE
// (with hsel high). wdata is the full 32-bit bus value of the data phase.
task rp_add;
   input  [31:0] addr;
   input         wr;
   input   [2:0] size;
   input  [31:0] wdata;
   input   [1:0] mode;
   input   [3:0] master;
   input   [1:0] trans;
   input integer gap;
   begin
      rp_addr[rp_n]   = addr;
      rp_wr[rp_n]     = wr;
      rp_size[rp_n]   = size;
      rp_wdata[rp_n]  = wdata;
      rp_mode[rp_n]   = mode;
      rp_master[rp_n] = master;
      rp_trans[rp_n]  = trans;
      rp_gap[rp_n]    = gap;
      rp_rdata[rp_n]  = 32'hxxxx_xxxx;
      rp_resp[rp_n]   = 1'bx;
      rp_waits[rp_n]  = -1;
      rp_shape[rp_n]  = 1'b0;
      rp_cancelled[rp_n] = 1'b0;
      rp_n = rp_n + 1;
   end
endtask

// Shorthands: word / sized NONSEQ, machine mode, hart master
task rp_w;
   input  [31:0] addr;
   input  [31:0] wdata;
   input integer gap;
   begin
      rp_add(addr, 1'b1, 3'b010, wdata, MACHINE, HART_MASTER, 2'b10, gap);
   end
endtask

task rp_r;
   input  [31:0] addr;
   input integer gap;
   begin
      rp_add(addr, 1'b0, 3'b010, 32'h0, MACHINE, HART_MASTER, 2'b10, gap);
   end
endtask

task rp_drive_idle;
   begin
      r_hsel    = rp_idle_hsel;
      r_htrans  = 2'b00;
      r_haddr   = $random(tmp_seed);
      r_hwrite  = $random(tmp_seed);
      r_hsize   = $random(tmp_seed);
      r_hprot   = 4'h3;
      r_hsmode  = 1'b0;
      r_hmaster = 4'h0;
   end
endtask

task rp_run;
   integer ai, ap, dp, gc, w;
   reg     ap_v, dp_v, hr, hrs, acc, dp_done, err1, bad_wait_resp, cancel_now;
   reg     [31:0] hrd;
   begin
      ai = 0; ap = 0; dp = 0; gc = 0; w = 0;
      ap_v = 1'b0; dp_v = 1'b0; err1 = 1'b0; bad_wait_resp = 1'b0; cancel_now = 1'b0;
      rp_cyc = 0;
      @(posedge free_clk);
      while ((ai < rp_n) || ap_v || dp_v) begin
         // posedge: present the next address phase
         if (!ap_v) begin
            if (ai < rp_n) begin
               if (gc >= rp_gap[ai]) begin
                  r_hsel    = 1'b1;
                  r_haddr   = rp_addr[ai];
                  r_htrans  = rp_trans[ai];
                  r_hwrite  = rp_wr[ai];
                  r_hsize   = rp_size[ai];
                  ax_prot_r = $random(ax_prot_seed);   // hprot[0], [2], [3] random
                  r_hprot   = {ax_prot_r[3:2], (rp_mode[ai] == USER) ? 1'b0 : (rp_mode[ai] == 2'b10) ? 1'b0 : 1'b1, ax_prot_r[0]};
                  r_hsmode  = (rp_mode[ai] == SUPERVISOR) || (rp_mode[ai] == 2'b10);
                  r_hmaster = rp_master[ai];
                  ap = ai; ap_v = 1'b1; ai = ai + 1; gc = 0;
               end else begin
                  rp_drive_idle;
                  gc = gc + 1;
               end
            end else begin
               rp_drive_idle;
            end
         end
         // negedge: sample the data-phase response
         @(negedge free_clk);
         hr  = r_hready;
         hrs = r_hresp;
         hrd = r_hrdata;
         dp_done = 1'b0;
         if (dp_v) begin
            if (hr === 1'b1) begin
               rp_rdata[dp] = hrd;
               rp_resp[dp]  = hrs;
               rp_waits[dp] = w;
               rp_cyc_end[dp] = rp_cyc;
               rp_shape[dp] = (hrs === 1'b1) ? (err1 && (w == 1)) : (!err1 && !bad_wait_resp);
               dp_done = 1'b1;
            end else begin
               if (hrs === 1'b1) begin
                  err1 = 1'b1;
                  if (rp_cancel_on_err && ap_v) cancel_now = 1'b1;
               end else if (err1) begin
                  bad_wait_resp = 1'b1;
               end
               w = w + 1;
               if (w > AHB_MAX_WAIT) begin
                  $display("ERROR: rp_run -- transfer %0d (address 0x%h) hung %t", dp, rp_addr[dp], $time);
                  error = error + 1;
                  rp_waits[dp] = w; rp_resp[dp] = 1'bx;
                  dp_done = 1'b1;
               end
            end
         end
         acc = ap_v && (hr === 1'b1);
         @(posedge free_clk);
         rp_cyc = rp_cyc + 1;
         if (dp_done) dp_v = 1'b0;
         if (cancel_now) begin
            rp_cancelled[ap] = 1'b1;
            ap_v = 1'b0;
            cancel_now = 1'b0;
            rp_drive_idle;
         end
         if (acc) begin
            rp_cyc_acc[ap] = rp_cyc;
            dp = ap; dp_v = 1'b1; ap_v = 1'b0; w = 0; err1 = 1'b0; bad_wait_resp = 1'b0;
            if (rp_wr[dp] && rp_trans[dp][1]) r_hwdata = rp_wdata[dp];
            else                              r_hwdata = $random(tmp_seed);
         end else if (dp_done) begin
            r_hwdata = $random(tmp_seed);
         end
      end
      rp_drive_idle;
      r_hsel = 1'b0;
   end
endtask

// Check one executed transfer. exp_waits < 0: not checked.
task rp_chk;
   input integer i;
   input         exp_resp;
   input  [31:0] exp_data;
   input  [31:0] mask;
   input integer exp_waits;
   begin
      tb_checks = tb_checks + 1;                 // one comparison (tb_min_checks)
      if (rp_cancelled[i]) begin
         $display("ERROR: rp transfer %0d (0x%h) was cancelled %t", i, rp_addr[i], $time);
         error = error + 1;
      end else if (rp_resp[i] !== exp_resp) begin
         $display("ERROR: rp transfer %0d (%s 0x%h size %0d) hresp %b / expected %b %t",
                  i, rp_wr[i] ? "write" : "read", rp_addr[i], rp_size[i], rp_resp[i], exp_resp, $time);
         error = error + 1;
      end else if (!rp_shape[i]) begin
         $display("ERROR: rp transfer %0d (%s 0x%h) bad response shape (waits %0d, resp %b) %t",
                  i, rp_wr[i] ? "write" : "read", rp_addr[i], rp_waits[i], rp_resp[i], $time);
         error = error + 1;
      end else if ((exp_waits >= 0) && (rp_waits[i] != exp_waits)) begin
         $display("ERROR: rp transfer %0d (%s 0x%h) %0d wait states / expected %0d %t",
                  i, rp_wr[i] ? "write" : "read", rp_addr[i], rp_waits[i], exp_waits, $time);
         error = error + 1;
      end else if (((rp_rdata[i] & mask) !== (exp_data & mask))) begin
         $display("ERROR: rp transfer %0d (read 0x%h) data 0x%h / expected 0x%h (mask 0x%h) %t",
                  i, rp_addr[i], rp_rdata[i] & mask, exp_data & mask, mask, $time);
         error = error + 1;
      end
   end
endtask
