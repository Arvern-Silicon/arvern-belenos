//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    ili9341_spi_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ili9341_spi_model.v
// Module Description : Behavioural ILI9341 panel, 4-line 8-bit serial
//                      interface (IM = 0110), SPI mode 0. MOSI is sampled on
//                      the rising edge of SCL, MSB first; the interface resets
//                      while CSX is high (the bit counter restarts on a CSX
//                      falling edge). D/CX is sampled with the last bit (D0)
//                      of each byte; a D/CX change inside a byte counts as an
//                      anomaly, and so does SDI or D/CX changing in the same
//                      time step as an SCL rising edge (no hold). A pixel is
//                      two bytes, RGB565 high byte first.
//
//                      Decoded commands: 0x2A CASET, 0x2B PASET, 0x2C RAMWR
//                      (see ili9341_8080_model). Other commands are counted
//                      and their parameters ignored. MISO is not driven
//                      (reads are not modelled).
//
//                      Captured state the tests read hierarchically:
//                        fb[y*W + x], px_log[n], px_count, cmd_count,
//                        last_cmd, anomaly_count, byte_count;
//                        anomaly_total counts the anomalies too and is never
//                        cleared: the bench fails a test that ends with it
//                        non-zero
//----------------------------------------------------------------------------
`include "timescale.v"

module  ili9341_spi_model #(
    parameter               W      = 320,   // columns (320: a landscape window, end column >= 256)
    parameter               H      = 320,   // rows
    parameter               LOG_NR = 4096   // pixel log depth
) (
    input  wire             reset_n_i,      // RESX
    input  wire             cs_n_i,         // CSX
    input  wire             dc_i,           // D/CX
    input  wire             sck_i,          // SCL
    input  wire             mosi_i,         // SDI
    output wire             miso_o          // SDO
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
integer                 byte_count;
integer                 anomaly_count;
reg                     wide_ok = 1'b0;   // 1: a pixel outside the W x H memory is dropped, not an anomaly
integer                 anomaly_total;     // anomalies since time 0 (tests may clear anomaly_count)
realtime                sck_rise_time;
realtime                d_change_time;
reg               [7:0] last_cmd;

reg               [7:0] cmd;
integer                 param_idx;
reg              [15:0] sc, ec, sp, ep;
reg              [15:0] col, row;

integer                 bit_cnt;
reg               [7:0] shift;
reg                     dc_first;
reg               [7:0] px_hi;
reg                     px_half;

integer                 ii;

initial
  begin
     for (ii = 0; ii < W*H; ii = ii + 1) fb[ii] = 16'h0000;
     px_count      = 0;
     cmd_count     = 0;
     byte_count    = 0;
     anomaly_count = 0;
     anomaly_total = 0;
     sck_rise_time = -1.0;
     d_change_time = -1.0;
     last_cmd      = 8'h00;
     cmd           = 8'h00;
     param_idx     = 0;
     sc = 16'd0;  ec = W-1;  sp = 16'd0;  ep = H-1;
     col = 16'd0; row = 16'd0;
     bit_cnt  = 0;
     shift    = 8'h00;
     dc_first = 1'b0;
     px_hi    = 8'h00;
     px_half  = 1'b0;
  end

always @(negedge reset_n_i)
  begin
     cmd = 8'h00; param_idx = 0; px_half = 1'b0;
     sc = 16'd0;  ec = W-1;  sp = 16'd0;  ep = H-1;
     col = 16'd0; row = 16'd0;
  end

// CSX high: serial interface initialised
always @(posedge cs_n_i)
  begin
     if (bit_cnt != 0)
       begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end       // byte cut short
     bit_cnt = 0;
  end

task byte_received;
   input  [7:0] data;
   input        dc;
   begin
      byte_count = byte_count + 1;
      if (dc === 1'b0)
        begin
           cmd       = data;
           last_cmd  = data;
           cmd_count = cmd_count + 1;
           param_idx = 0;
           px_half   = 1'b0;
           if (cmd == 8'h2C) begin
              col = sc;
              row = sp;
           end
        end
      else
        case (cmd)
          8'h2A : begin
                     case (param_idx)
                       0: sc[15:8] = data;
                       1: sc[7:0]  = data;
                       2: ec[15:8] = data;
                       3: ec[7:0]  = data;
                       default: begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
                     endcase
                     param_idx = param_idx + 1;
                  end
          8'h2B : begin
                     case (param_idx)
                       0: sp[15:8] = data;
                       1: sp[7:0]  = data;
                       2: ep[15:8] = data;
                       3: ep[7:0]  = data;
                       default: begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
                     endcase
                     param_idx = param_idx + 1;
                  end
          8'h2C : begin
                     if (!px_half) begin
                        px_hi   = data;
                        px_half = 1'b1;
                     end else begin
                        px_half = 1'b0;
                        if ((col < W) && (row < H)) begin
                          fb[row*W + col] = {px_hi, data};
`ifdef ARV_VSCREEN
                          vscreen_px(1, col, row, {16'h0000, px_hi, data});
`endif
                        end else if (!wide_ok)
                          begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
                        if (px_count < LOG_NR)
                          px_log[px_count] = {px_hi, data};
                        px_count = px_count + 1;
                        if (col >= ec) begin
                           col = sc;
                           row = (row >= ep) ? sp : row + 16'd1;
                        end else begin
                           col = col + 16'd1;
                        end
                     end
                  end
          default: param_idx = param_idx + 1;
        endcase
   end
endtask

// Hold check: SDI and D/CX must not change in the time step of the SCL
// rising edge (whichever of the two events the simulator evaluates first).
always @(mosi_i or dc_i)
  begin
     d_change_time = $realtime;
     if ((d_change_time == sck_rise_time) && (cs_n_i === 1'b0))
       begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
  end

always @(posedge sck_i)
  if ((cs_n_i === 1'b0) && (reset_n_i !== 1'b0))
    begin
       sck_rise_time = $realtime;
       if (d_change_time == sck_rise_time)
         begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
       if (bit_cnt == 0)
         dc_first = dc_i;
       else if (dc_i !== dc_first)
         begin anomaly_count = anomaly_count + 1; anomaly_total = anomaly_total + 1; end
       shift   = {shift[6:0], mosi_i};
       bit_cnt = bit_cnt + 1;
       if (bit_cnt == 8) begin
          bit_cnt = 0;
          byte_received(shift, dc_i);
       end
    end

assign miso_o = 1'b0;

endmodule
