//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    ili9341_8080_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ili9341_8080_model.v
// Module Description : Behavioural ILI9341 panel, 8080-series 16-bit MCU
//                      interface (IM = 0001: commands and parameters on
//                      D[7:0], one RGB565 pixel per strobe on D[15:0]).
//                      Write data is latched on the rising edge of WRX while
//                      CSX is low; D/CX = 0 selects a command. Read data is
//                      driven while CSX and RDX are low and advances on the
//                      rising edge of RDX.
//
//                      Decoded commands:
//                        0x2A CASET  4 parameters SC[15:8] SC[7:0] EC[15:8] EC[7:0]
//                        0x2B PASET  4 parameters SP[15:8] SP[7:0] EP[15:8] EP[7:0]
//                        0x2C RAMWR  pointer to (SC, SP); each data write stores
//                                    one pixel and advances column first,
//                                    wrapping inside the window
//                        0x45 Get_Scanline  reads: dummy, {6'b0, GTS[9:8]},
//                                    GTS[7:0]; GTS = `scanline`, set by the
//                                    tests or, with scan_auto = 1, advanced
//                                    every scan_period ns modulo scan_total
//                                    (a panel scanning its lines)
//                      Other commands are counted and their parameters ignored.
//
//                      Captured state the tests read hierarchically:
//                        fb[y*W + x]       frame memory (RGB565)
//                        px_log[n]         every pixel written, in order
//                        px_count          number of pixels written
//                        cmd_count         number of command bytes
//                        last_cmd          last command byte
//                        rd_count          number of read strobes
//                        anomaly_count     protocol violations: bus contention,
//                                          read during a non-read command, D or
//                                          D/CX changing in the same time step
//                                          as the WRX rising edge (no hold)
//                        anomaly_total     the same, never cleared: the bench
//                                          fails a test that ends with it non-zero
//
//                      AC timing checks (off by default: the protocol tests run
//                      the bus faster than a real panel takes it). A test sets
//                      the minima it wants checked, in ns, 0 = not checked:
//                        t_wrl_min, t_wrh_min  WRX low / high pulse width
//                        t_rdl_min, t_rdh_min  RDX low / high pulse width
//                        t_wc_min,  t_rc_min   write / read cycle (falling edge
//                                              to falling edge)
//                        t_cs_min,  t_rcs_min  CSX falling edge to the first
//                                              WRX / RDX strobe of the CSX low
//                                              period: to its rising edge (the
//                                              data sheet figure), or to its
//                                              falling edge when ac_cs_fall_ref
//                                              is 1 (panels that specify it so)
//                        t_hz_min              host releases D (d_oe_i low) at
//                                              least this long before RDX falls
//                      and the read data timing (also 0 = off):
//                        t_rat_max             read access time: D is X from RDX
//                                              falling until t_rat_max later
//                        t_rod_max             output disable time: the panel
//                                              keeps driving D for t_rod_max after
//                                              RDX rises; the host driving D in
//                                              that time is a violation
//                      (ILI9341 V1.11 Table 18.3.1: t_WRL / t_WRH 15, t_WC 66,
//                      t_RDL 45, t_RDH 90, t_RC 160, t_CS 15, t_RCS 45,
//                      t_RAT 40 max, t_ROD 80 max). A high phase and a cycle are measured between two
//                      strobes of the same kind in one CSX low period.
//                      Violations count in ac_count (and are printed), not in
//                      anomaly_count: the test checks it.
//----------------------------------------------------------------------------
`include "timescale.v"

module  ili9341_8080_model #(
    parameter               W      = 320,   // columns (320: a landscape window, end column >= 256)
    parameter               H      = 320,   // rows
    parameter               LOG_NR = 4096   // pixel log depth
) (
    input  wire             reset_n_i,      // RESX
    input  wire             cs_n_i,         // CSX
    input  wire             dc_i,           // D/CX
    input  wire             wr_n_i,         // WRX
    input  wire             rd_n_i,         // RDX
    input  wire      [15:0] d_i,            // data from the host
    input  wire             d_oe_i,         // host drives D
    output wire      [15:0] d_o             // data to the host (reads)
);

reg              [15:0] fb     [0:W*H-1];

`ifdef ARV_VSCREEN
// Virtual screen (Verilator DPI, see the board bench): every pixel written to
// the panel memory is forwarded to the screen window.
import "DPI-C" function void vscreen_px(input int panel, input int x, input int y, input int rgb565);
`endif
reg              [15:0] px_log [0:LOG_NR-1];
integer                 px_count;
integer                 cmd_count;
integer                 anomaly_count;
reg                     wide_ok = 1'b0;   // 1: a pixel outside the W x H memory is dropped, not an anomaly
integer                 anomaly_total;     // anomalies since time 0 (tests may clear anomaly_count)
integer                 rd_count;
integer                 ac_count;          // AC timing violations (see the header)
realtime                t_wrl_min, t_wrh_min, t_rdl_min, t_rdh_min, t_wc_min, t_rc_min;
realtime                t_cs_min, t_rcs_min, t_hz_min, t_rat_max, t_rod_max;
realtime                ac_cs_fall, ac_oe_fall, rod_rise;
reg                     ac_wr_first, ac_rd_first;   // no WRX / RDX strobe yet in this CSX low period
reg                     ac_cs_fall_ref;             // t_CS / t_RCS to the strobe's falling edge (1) or rising edge (0)
reg                     rod_on;                     // panel output still on after RDX rose (t_rod_max)
reg              [15:0] d_q;                        // panel output value (X before t_rat_max)
realtime                ac_wr_fall, ac_wr_rise, ac_rd_fall, ac_rd_rise;
realtime                ac_wrl_seen, ac_wrh_seen, ac_rdl_seen, ac_rdh_seen;   // shortest widths measured
realtime                wr_rise_time;
realtime                d_change_time;
reg               [7:0] last_cmd;
reg               [9:0] scanline;
reg                     scan_auto;
integer                 scan_period;
integer                 scan_total;

reg               [7:0] cmd;
integer                 param_idx;
integer                 rd_idx;
reg              [15:0] sc, ec, sp, ep;
reg              [15:0] col, row;
reg              [15:0] rd_data;
reg              [15:0] rd_q;           // read value, latched when RDX falls

integer                 ii;

initial
  begin
     for (ii = 0; ii < W*H; ii = ii + 1) fb[ii] = 16'h0000;
     px_count      = 0;
     cmd_count     = 0;
     anomaly_count = 0;
     anomaly_total = 0;
     rd_count      = 0;
     ac_count      = 0;
     t_wrl_min = 0.0; t_wrh_min = 0.0; t_rdl_min = 0.0; t_rdh_min = 0.0; t_wc_min = 0.0; t_rc_min = 0.0;
     t_cs_min  = 0.0; t_rcs_min = 0.0; t_hz_min  = 0.0; t_rat_max = 0.0; t_rod_max = 0.0;
     ac_cs_fall = -1.0; ac_oe_fall = -1.0; ac_wr_first = 1'b0; ac_rd_first = 1'b0; ac_cs_fall_ref = 1'b0;
     rod_on = 1'b0; d_q = 16'h0000; rod_rise = -1.0;
     ac_wr_fall = -1.0; ac_wr_rise = -1.0; ac_rd_fall = -1.0; ac_rd_rise = -1.0;
     ac_wrl_seen = 1.0e9; ac_wrh_seen = 1.0e9; ac_rdl_seen = 1.0e9; ac_rdh_seen = 1.0e9;
     wr_rise_time  = -1.0;
     d_change_time = -1.0;
     last_cmd      = 8'h00;
     scanline      = 10'd0;
     scan_auto     = 1'b0;
     scan_period   = 1000;
     scan_total    = 330;
     cmd           = 8'h00;
     param_idx     = 0;
     rd_idx        = 0;
     sc = 16'd0;  ec = W-1;  sp = 16'd0;  ep = H-1;
     col = 16'd0; row = 16'd0;
  end

// Free-running scan counter (scan_auto)
always
  begin
     #(scan_period);
     if (scan_auto)
       scanline = (scanline >= scan_total - 1) ? 10'd0 : scanline + 10'd1;
  end

// AC timing: pulse widths and cycle times of the strobes, per CSX low period
task ac_check;
   input realtime t;
   input realtime t_min;
   input [8*8-1:0] what;
   begin
      if ((t_min > 0.0) && (t < t_min)) begin
         ac_count = ac_count + 1;
         if (ac_count <= 8)
           $display("INFO:  ILI9341 8080 model AC violation: %0s = %0.1f ns < %0.1f ns at %t", what, t, t_min, $realtime);
      end
   end
endtask

always @(posedge cs_n_i)
  begin
     ac_wr_fall = -1.0; ac_wr_rise = -1.0; ac_rd_fall = -1.0; ac_rd_rise = -1.0;
  end

always @(negedge cs_n_i)
  begin
     ac_cs_fall = $realtime; ac_wr_first = 1'b1; ac_rd_first = 1'b1;
  end

always @(negedge d_oe_i) ac_oe_fall = $realtime;

// Host release before RDX falls, checked 0.1 ns after the edge so that a
// release in the same time step is seen whatever the event order (it counts
// as 0, as does no release)
realtime                hz_rd_fall;
always @(negedge rd_n_i)
  if ((cs_n_i === 1'b0) && (t_hz_min > 0.0))
    begin
       hz_rd_fall = $realtime;
       #0.1;
       ac_check(((d_oe_i === 1'b0) && (ac_oe_fall >= 0.0) && (ac_oe_fall < hz_rd_fall)) ?
                hz_rd_fall - ac_oe_fall : 0.0, t_hz_min, "t_HZ");
    end

// The host drives D again while the panel's output is still on after RDX rose
always @(posedge d_oe_i)
  if (rod_on && (t_rod_max > 0.0))
    ac_check($realtime - rod_rise, t_rod_max, "t_ROD");

always @(negedge wr_n_i)
  if (cs_n_i === 1'b0)
    begin
       if (ac_wr_rise >= 0.0) begin
          ac_check($realtime - ac_wr_rise, t_wrh_min, "t_WRH");
          if ($realtime - ac_wr_rise < ac_wrh_seen) ac_wrh_seen = $realtime - ac_wr_rise;
       end
       if (ac_wr_fall >= 0.0) ac_check($realtime - ac_wr_fall, t_wc_min, "t_WC");
       ac_wr_fall = $realtime;
       ac_rd_fall = -1.0; ac_rd_rise = -1.0;
    end

always @(wr_n_i)
  if ((cs_n_i === 1'b0) && ac_wr_first && (wr_n_i === !ac_cs_fall_ref))
    begin
       ac_check($realtime - ac_cs_fall, t_cs_min, "t_CS");
       ac_wr_first = 1'b0;
    end

always @(posedge wr_n_i)
  if ((cs_n_i === 1'b0) && (ac_wr_fall >= 0.0))
    begin
       ac_check($realtime - ac_wr_fall, t_wrl_min, "t_WRL");
       if ($realtime - ac_wr_fall < ac_wrl_seen) ac_wrl_seen = $realtime - ac_wr_fall;
       ac_wr_rise = $realtime;
    end

always @(negedge rd_n_i)
  if (cs_n_i === 1'b0)
    begin
       if (ac_rd_rise >= 0.0) begin
          ac_check($realtime - ac_rd_rise, t_rdh_min, "t_RDH");
          if ($realtime - ac_rd_rise < ac_rdh_seen) ac_rdh_seen = $realtime - ac_rd_rise;
       end
       if (ac_rd_fall >= 0.0) ac_check($realtime - ac_rd_fall, t_rc_min, "t_RC");
       ac_rd_fall = $realtime;
       ac_wr_fall = -1.0; ac_wr_rise = -1.0;
    end

always @(rd_n_i)
  if ((cs_n_i === 1'b0) && ac_rd_first && (rd_n_i === !ac_cs_fall_ref))
    begin
       ac_check($realtime - ac_cs_fall, t_rcs_min, "t_RCS");
       ac_rd_first = 1'b0;
    end

always @(posedge rd_n_i)
  if ((cs_n_i === 1'b0) && (ac_rd_fall >= 0.0))
    begin
       ac_check($realtime - ac_rd_fall, t_rdl_min, "t_RDL");
       if ($realtime - ac_rd_fall < ac_rdl_seen) ac_rdl_seen = $realtime - ac_rd_fall;
       ac_rd_rise = $realtime;
    end

// Hardware reset: window and command state back to their defaults
always @(negedge reset_n_i)
  begin
     cmd = 8'h00; param_idx = 0; rd_idx = 0;
     sc = 16'd0;  ec = W-1;  sp = 16'd0;  ep = H-1;
     col = 16'd0; row = 16'd0;
  end

// Hold check: D and D/CX must not change in the time step of the WRX rising
// edge (whichever of the two events the simulator evaluates first).
always @(d_i or dc_i)
  begin
     d_change_time = $realtime;
     if ((d_change_time == wr_rise_time) && (cs_n_i === 1'b0))
       begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
  end

// Write cycles
always @(posedge wr_n_i)
  if ((cs_n_i === 1'b0) && (reset_n_i !== 1'b0))
    begin
       wr_rise_time = $realtime;
       if (d_change_time == wr_rise_time)
         begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
       if (dc_i === 1'b0)
         begin
            cmd       = d_i[7:0];
            last_cmd  = d_i[7:0];
            cmd_count = cmd_count + 1;
            param_idx = 0;
            rd_idx    = 0;
            if (cmd == 8'h2C) begin
               col = sc;
               row = sp;
            end
         end
       else
         begin
            case (cmd)
              8'h2A : begin
                         case (param_idx)
                           0: sc[15:8] = d_i[7:0];
                           1: sc[7:0]  = d_i[7:0];
                           2: ec[15:8] = d_i[7:0];
                           3: ec[7:0]  = d_i[7:0];
                           default: begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
                         endcase
                         param_idx = param_idx + 1;
                      end
              8'h2B : begin
                         case (param_idx)
                           0: sp[15:8] = d_i[7:0];
                           1: sp[7:0]  = d_i[7:0];
                           2: ep[15:8] = d_i[7:0];
                           3: ep[7:0]  = d_i[7:0];
                           default: begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
                         endcase
                         param_idx = param_idx + 1;
                      end
              8'h2C : begin
                         if ((col < W) && (row < H)) begin
                           fb[row*W + col] = d_i;
`ifdef ARV_VSCREEN
                           vscreen_px(0, col, row, {16'h0000, d_i});
`endif
                         end else if (!wide_ok)
                           begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
                         if (px_count < LOG_NR)
                           px_log[px_count] = d_i;
                         px_count = px_count + 1;
                         if (col >= ec) begin
                            col = sc;
                            row = (row >= ep) ? sp : row + 16'd1;
                         end else begin
                            col = col + 16'd1;
                         end
                      end
              default: param_idx = param_idx + 1;
            endcase
         end
    end

// Read cycles
always @*
  if (cmd == 8'h45)
    case (rd_idx)
      0       : rd_data = 16'h0000;                       // dummy read
      1       : rd_data = {14'h0000, scanline[9:8]};
      2       : rd_data = {8'h00,    scanline[7:0]};
      default : rd_data = 16'h0000;
    endcase
  else
    rd_data = 16'h0000;

always @(posedge rd_n_i)
  if ((cs_n_i === 1'b0) && (reset_n_i !== 1'b0))
    begin
       if (dc_i === 1'b0)
         begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end     // read data is only valid with D/CX high
       if (cmd != 8'h45)
         begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
       rd_idx   = rd_idx + 1;
       rd_count = rd_count + 1;
    end

wire                    panel_drive = ((cs_n_i === 1'b0) && (rd_n_i === 1'b0)) || rod_on;

// Bus contention: host and panel driving D at once. Checked 1 ns after the
// panel starts driving (its output turn-on time), so the result does not
// depend on the order in which the simulator updates RDX and the host's
// output enable when both change on the same clock edge.
always @(posedge panel_drive)
  begin
     #1;
     if ((d_oe_i === 1'b1) && panel_drive)
       begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
  end

// The panel latches its output when RDX falls and holds it to the end of the
// strobe (a scan counter that moves during the strobe does not tear a byte).
// With t_rat_max set, D is X until the access time has passed; with t_rod_max
// set, the panel keeps driving for that long after RDX rises.
always @(negedge rd_n_i)
  begin
     rd_q = rd_data;
     if (t_rat_max > 0.0) begin
        d_q = 16'hxxxx;
        d_q <= #(t_rat_max) rd_q;
     end else
        d_q = rd_q;
     rod_on = 1'b0;
  end

always @(posedge rd_n_i)
  if ((cs_n_i === 1'b0) && (t_rod_max > 0.0))
    begin
       rod_on   = 1'b1;
       rod_rise = $realtime;
       rod_on <= #(t_rod_max) 1'b0;
    end

assign d_o = panel_drive ? d_q : 16'h0000;

endmodule
