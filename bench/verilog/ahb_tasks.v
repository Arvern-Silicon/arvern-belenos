//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    ahb_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_tasks.v
// Module Description : AHB-Lite manager tasks for the two Belenos ports
//                      (`included into tb_belenos). One generic transfer task
//                      drives either the register port (PORT_R) or the VRAM
//                      window (PORT_V); the wrappers below check responses and
//                      read data and count mismatches in `error`.
//
//                      Timing: the address phase is driven on a falling edge,
//                      the data phase follows the next rising edge, and the
//                      response is sampled on falling edges (hready, hresp,
//                      hrdata are then stable for the edge that completes the
//                      transfer). The task returns on that completing edge.
//                      Transfers are not pipelined.
//
//                      Privilege mode: USER -> hprot[1]=0; SUPERVISOR ->
//                      hprot[1]=1, hsmode=1; MACHINE -> hprot[1]=1, hsmode=0.
//                      hprot[0], [2] and [3] are random per transfer (from
//                      the run's seed): Belenos reads only hprot[1].
//                      The `master` argument drives the bench's r/v_hmaster
//                      registers only (Belenos has no such input).
//----------------------------------------------------------------------------

localparam        PORT_R     = 1'b0;
localparam        PORT_V     = 1'b1;

localparam  [1:0] USER       = 2'b00;
localparam  [1:0] SUPERVISOR = 2'b01;
localparam  [1:0] MACHINE    = 2'b11;

localparam        OK         = 1'b0;
localparam        ERROR      = 1'b1;

localparam  [1:0] SZ_B       = 2'd0;
localparam  [1:0] SZ_H       = 2'd1;
localparam  [1:0] SZ_W       = 2'd2;

localparam  [3:0] HART_MASTER = 4'h1;
localparam  [3:0] DBG_MASTER  = 4'h9;

localparam integer AHB_MAX_WAIT = 20000;

// Last transfer, for the coverage monitor and for tests
integer           ahb_last_waits;

// Random hprot[0], [2], [3] of every transfer (own seed: the tests' random
// streams are not disturbed)
integer           ax_prot_seed;
reg        [31:0] ax_prot_r;
initial           ax_prot_seed = `SEED ^ 32'h5A5A_1234;


//============================================================================
// Generic single transfer
//============================================================================
// One bus driver per port runs the transfer; ahb_xfer only posts the request and
// waits for its completion, so a call site stays small.
reg         [1:0] ax_req = 2'b00;  // toggled by ahb_xfer, per port
reg         [1:0] ax_ack = 2'b00;  // follows ax_req when the transfer completes
reg               ax_write  [0:1];
reg        [31:0] ax_addr   [0:1];
reg         [1:0] ax_size   [0:1];
reg        [31:0] ax_wdata  [0:1];
reg         [1:0] ax_mode   [0:1];
reg         [3:0] ax_master [0:1];
reg        [31:0] ax_rdata  [0:1];
reg               ax_resp   [0:1];
reg         [1:0] ax_kind   [0:1];   // AX_RAW / AX_WRITE / AX_READ / AX_READ_VAL
reg               ax_check  [0:1];   // AX_READ: compare the data
reg               ax_exp_resp [0:1];
reg        [31:0] ax_exp_data [0:1];
reg        [31:0] ax_mask   [0:1];

localparam  [1:0] AX_RAW      = 2'd0;   // no check
localparam  [1:0] AX_WRITE    = 2'd1;   // check the response
localparam  [1:0] AX_READ     = 2'd2;   // check the response and, with check, the data
localparam  [1:0] AX_READ_VAL = 2'd3;   // expect OKAY

task ahb_call;
   input         port;
   input         write;
   input  [31:0] addr;
   input   [1:0] size;
   input  [31:0] wdata;
   input   [1:0] mode;
   input   [3:0] master;
   input   [1:0] kind;
   input         check;
   input         exp_resp;
   input  [31:0] exp_data;
   input  [31:0] mask;
   output [31:0] rdata;
   output        resp;
   begin
      ax_write[port]    = write;
      ax_addr[port]     = addr;
      ax_size[port]     = size;
      ax_wdata[port]    = wdata;
      ax_mode[port]     = mode;
      ax_master[port]   = master;
      ax_kind[port]     = kind;
      ax_check[port]    = check;
      ax_exp_resp[port] = exp_resp;
      ax_exp_data[port] = exp_data;
      ax_mask[port]     = mask;
      ax_req[port]      = ~ax_req[port];
      wait (ax_ack[port] === ax_req[port]);
      rdata = ax_rdata[port];
      resp  = ax_resp[port];
   end
endtask

task ahb_xfer;
   input         port;      // PORT_R / PORT_V
   input         write;     // 1 = write
   input  [31:0] addr;      // byte address
   input   [1:0] size;      // SZ_B / SZ_H / SZ_W
   input  [31:0] wdata;     // right-aligned write value
   input   [1:0] mode;      // USER / SUPERVISOR / MACHINE
   input   [3:0] master;    // bench r/v_hmaster tag (no DUT input)
   output [31:0] rdata;     // right-aligned read value
   output        resp;      // hresp of the completing cycle
   begin
      ahb_call(port, write, addr, size, wdata, mode, master, AX_RAW, 1'b0, OK, 32'h0, 32'h0, rdata, resp);
   end
endtask

genvar gp;
generate
for (gp = 0; gp < 2; gp = gp + 1) begin : g_ahb_drv
   reg     [3:0] prot;
   reg           smode;
   reg    [31:0] lane_wdata;
   reg    [31:0] raw;
   reg    [31:0] rd;
   reg           resp;
   integer       waits;
   reg           done;
   wire          hready = (gp == PORT_R) ? r_hready : v_hready;

   always begin
      wait (ax_req[gp] !== ax_ack[gp]);
      ax_prot_r  = $random(ax_prot_seed);
      prot       = {ax_prot_r[3:2], (ax_mode[gp] != USER), ax_prot_r[0]};
      smode      = (ax_mode[gp] == SUPERVISOR);
      lane_wdata = (ax_size[gp] == SZ_B) ? {4{ax_wdata[gp][7:0]}}  :
                   (ax_size[gp] == SZ_H) ? {2{ax_wdata[gp][15:0]}} : ax_wdata[gp];

      // Address phase (the bus is idle: hready must be high)
      @(negedge free_clk);
      waits = 0;
      while (hready !== 1'b1 && waits < AHB_MAX_WAIT) begin
         @(negedge free_clk);
         waits = waits + 1;
      end
      if (gp == PORT_R) begin
         r_hsel = 1'b1; r_haddr = ax_addr[gp]; r_htrans = 2'b10; r_hwrite = ax_write[gp];
         r_hsize = {1'b0, ax_size[gp]}; r_hprot = prot; r_hsmode = smode; r_hmaster = ax_master[gp];
      end else begin
         v_hsel = 1'b1; v_haddr = ax_addr[gp]; v_htrans = 2'b10; v_hwrite = ax_write[gp];
         v_hsize = {1'b0, ax_size[gp]}; v_hprot = prot; v_hsmode = smode; v_hmaster = ax_master[gp];
      end
      @(posedge free_clk);

      // Data phase
      if (gp == PORT_R) begin
         r_hsel = 1'b0; r_htrans = 2'b00; r_hwrite = 1'b0;
         if (ax_write[gp]) r_hwdata = lane_wdata;
      end else begin
         v_hsel = 1'b0; v_htrans = 2'b00; v_hwrite = 1'b0;
         if (ax_write[gp]) v_hwdata = lane_wdata;
      end
      waits = 0;
      done  = 1'b0;
      raw   = 32'h0;
      resp  = 1'b0;
      while (!done) begin
         @(negedge free_clk);
         if (hready === 1'b1) begin
            done = 1'b1;
            resp = (gp == PORT_R) ? r_hresp  : v_hresp;
            raw  = (gp == PORT_R) ? r_hrdata : v_hrdata;
         end else begin
            waits = waits + 1;
            if (waits >= AHB_MAX_WAIT) begin
               $display("ERROR: AHB %s transfer hung -- address 0x%h %t", (gp == PORT_R) ? "r-port" : "v-port", ax_addr[gp], $time);
               error = error + 1;
               done  = 1'b1;
               resp  = 1'bx;
            end
         end
      end
      @(posedge free_clk);
      ahb_last_waits = waits;

      ax_rdata[gp] = (ax_size[gp] == SZ_B) ? ((raw >> (8*ax_addr[gp][1:0])) & 32'hFF)   :
                     (ax_size[gp] == SZ_H) ? ((raw >> (16*ax_addr[gp][1]))  & 32'hFFFF) : raw;
      ax_resp[gp]  = resp;

      cover_ahb(gp, ax_size[gp], resp, waits);

      // Checks of the wrappers below
      rd = ax_rdata[gp] & ax_mask[gp];
      if (ax_kind[gp] == AX_WRITE) begin
         if (ax_exp_resp[gp] !== OK) tb_checks = tb_checks + 1;
         if (resp !== ax_exp_resp[gp]) begin
            $display("ERROR: AHB %s write response -- address 0x%h -- hresp %b / expected %b %t",
                     (gp == PORT_R) ? "r-port" : "v-port", ax_addr[gp], resp, ax_exp_resp[gp], $time);
            error = error + 1;
         end
      end else if (ax_kind[gp] == AX_READ) begin
         if (ax_check[gp] || (ax_exp_resp[gp] !== OK)) tb_checks = tb_checks + 1;
         if (resp !== ax_exp_resp[gp]) begin
            $display("ERROR: AHB %s read response -- address 0x%h -- hresp %b / expected %b %t",
                     (gp == PORT_R) ? "r-port" : "v-port", ax_addr[gp], resp, ax_exp_resp[gp], $time);
            error = error + 1;
         end else if (ax_check[gp] && (rd !== (ax_exp_data[gp] & ax_mask[gp]))) begin
            $display("ERROR: AHB %s read data -- address 0x%h -- read 0x%h / expected 0x%h (mask 0x%h) %t",
                     (gp == PORT_R) ? "r-port" : "v-port", ax_addr[gp], rd, ax_exp_data[gp] & ax_mask[gp], ax_mask[gp], $time);
            error = error + 1;
         end else if (ax_check[gp]) begin
            $display("OK:    AHB %s read  -- address 0x%h -- value 0x%h %t",
                     (gp == PORT_R) ? "r-port" : "v-port", ax_addr[gp], rd, $time);
         end
      end else if (ax_kind[gp] == AX_READ_VAL) begin
         if (resp !== OK) begin
            $display("ERROR: AHB %s read response -- address 0x%h -- unexpected ERROR %t",
                     (gp == PORT_R) ? "r-port" : "v-port", ax_addr[gp], $time);
            error = error + 1;
         end
      end
      ax_ack[gp] = ax_req[gp];
   end
end
endgenerate


//============================================================================
// Checked wrappers
//============================================================================

// Write, checking the response
task ahb_write_x;
   input         port;
   input  [31:0] addr;
   input  [31:0] data;
   input   [1:0] size;
   input   [1:0] mode;
   input   [3:0] master;
   input         exp_resp;
   reg    [31:0] dummy;
   reg           resp;
   begin
      ahb_call(port, 1'b1, addr, size, data, mode, master, AX_WRITE, 1'b0, exp_resp, 32'h0, 32'h0, dummy, resp);
   end
endtask

// Read, checking the response and (when check = 1) the data under mask
task ahb_read_x;
   input         port;
   input  [31:0] addr;
   input  [31:0] exp_data;
   input  [31:0] mask;
   input   [1:0] size;
   input   [1:0] mode;
   input   [3:0] master;
   input         check;
   input         exp_resp;
   reg    [31:0] data;
   reg           resp;
   begin
      ahb_call(port, 1'b0, addr, size, 32'h0, mode, master, AX_READ, check, exp_resp, exp_data, mask, data, resp);
   end
endtask

// Read and return the value (expects OKAY)
task ahb_read_val;
   input         port;
   input  [31:0] addr;
   input   [1:0] size;
   output [31:0] data;
   reg           resp;
   begin
      ahb_call(port, 1'b0, addr, size, 32'h0, MACHINE, HART_MASTER, AX_READ_VAL, 1'b0, OK, 32'h0, 32'hFFFF_FFFF, data, resp);
   end
endtask


//============================================================================
// Register port shorthands (word, MACHINE, hart master, OKAY expected)
//============================================================================
// A GPU_CTRL or CTRL write may flush the GPU FIFO: the GPU model then no longer
// knows which SET_SRC reached the decoder (gpu_src_fmt re-sends it)
reg gpu_flush_hint = 1'b0;

task reg_wr;
   input  [31:0] addr;
   input  [31:0] data;
   begin
      if ((addr == 32'h108) || (addr == 32'h010)) gpu_flush_hint = 1'b1;
      ahb_write_x(PORT_R, addr, data, SZ_W, MACHINE, HART_MASTER, OK);
   end
endtask

task reg_rd;
   input  [31:0] addr;
   input  [31:0] exp_data;
   begin
      ahb_read_x(PORT_R, addr, exp_data, 32'hFFFF_FFFF, SZ_W, MACHINE, HART_MASTER, 1'b1, OK);
   end
endtask

task reg_rd_mask;
   input  [31:0] addr;
   input  [31:0] exp_data;
   input  [31:0] mask;
   begin
      ahb_read_x(PORT_R, addr, exp_data, mask, SZ_W, MACHINE, HART_MASTER, 1'b1, OK);
   end
endtask

task reg_rd_val;
   input  [31:0] addr;
   output [31:0] data;
   begin
      ahb_read_val(PORT_R, addr, SZ_W, data);
   end
endtask

// Poll a register until (value & mask) == exp, at most max_reads reads
task reg_poll;
   input  [31:0] addr;
   input  [31:0] mask;
   input  [31:0] exp_data;
   input  integer max_reads;
   reg    [31:0] data;
   integer       nr;
   begin
      nr   = 0;
      data = ~exp_data;
      while (((data & mask) !== (exp_data & mask)) && (nr < max_reads)) begin
         reg_rd_val(addr, data);
         nr = nr + 1;
      end
      tb_checks = tb_checks + 1;
      if ((data & mask) !== (exp_data & mask)) begin
         $display("ERROR: register poll -- address 0x%h -- 0x%h & 0x%h never reached 0x%h %t",
                  addr, data, mask, exp_data & mask, $time);
         error = error + 1;
      end
   end
endtask


//============================================================================
// VRAM window shorthands (MACHINE, hart master, OKAY expected)
//============================================================================
task vram_wr;
   input  [31:0] addr;
   input  [31:0] data;
   input   [1:0] size;
   begin
      ahb_write_x(PORT_V, addr, data, size, MACHINE, HART_MASTER, OK);
   end
endtask

task vram_rd;
   input  [31:0] addr;
   input  [31:0] exp_data;
   input   [1:0] size;
   begin
      ahb_read_x(PORT_V, addr, exp_data, 32'hFFFF_FFFF, size, MACHINE, HART_MASTER, 1'b1, OK);
   end
endtask

task vram_rd_val;
   input  [31:0] addr;
   input   [1:0] size;
   output [31:0] data;
   begin
      ahb_read_val(PORT_V, addr, size, data);
   end
endtask
