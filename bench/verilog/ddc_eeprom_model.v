//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    ddc_eeprom_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ddc_eeprom_model.v
// Module Description : The monitor side of an HDMI DDC (bench model): an I2C
//                      slave at ADDR holding 256 bytes (the test EDID of
//                      ddc_edid_test.vh),
//                      random read (write the word offset, repeated start,
//                      read) with an auto-incrementing offset; other
//                      addresses get no acknowledge. With stretch_ns > 0 it
//                      holds SCL low that long after every acknowledge.
//                      Counts the bytes it sent.
//----------------------------------------------------------------------------
`timescale 1ns/1ps
module  ddc_eeprom_model #(
    parameter [6:0] ADDR = 7'h50                   // 7-bit I2C address
) (
    inout  wire     scl,                           // pulled up outside
    inout  wire     sda
);

reg   [7:0] mem [0:255];
reg         sda_low;
reg         scl_low;
reg   [2:0] st;
reg   [7:0] sh;
reg   [7:0] tx;
reg   [7:0] ptr;
reg         rd;
reg         addr_phase;
reg         mack;
integer     bitc;
integer     stretch_ns;
integer     sent;

localparam  IDLE = 3'd0, RXB = 3'd1, ACKS = 3'd2, TXB = 3'd3, ACKM = 3'd4;

assign sda = sda_low ? 1'b0 : 1'bz;
assign scl = scl_low ? 1'b0 : 1'bz;

initial begin
    `include "ddc_edid_test.vh"
    sda_low    = 1'b0;
    scl_low    = 1'b0;
    st         = IDLE;
    ptr        = 8'h00;
    stretch_ns = 0;
    sent       = 0;
end

// START (repeated START too) and STOP: SDA moving while SCL is high
always @(negedge sda) if (scl === 1'b1) begin
    st         = RXB;
    bitc       = 0;
    addr_phase = 1'b1;
    sda_low    = 1'b0;
end
always @(posedge sda) if (scl === 1'b1) begin
    st      = IDLE;
    sda_low = 1'b0;
end

always @(posedge scl) begin
    case (st)
        RXB:  begin sh = {sh[6:0], (sda === 1'b1)}; bitc = bitc + 1; end
        ACKM: mack = (sda === 1'b0);
        default: ;
    endcase
end

always @(negedge scl) begin
    case (st)
        RXB:  if (bitc == 8) begin
                  if (addr_phase) begin
                      addr_phase = 1'b0;
                      if (sh[7:1] == ADDR) begin rd = sh[0]; sda_low = 1'b1; st = ACKS; end
                      else st = IDLE;
                  end else begin
                      ptr = sh; sda_low = 1'b1; st = ACKS;
                  end
              end
        ACKS: begin
                  // the next state is set up first: SDA never moves while SCL is high
                  sda_low = 1'b0;
                  if (rd) begin tx = mem[ptr]; ptr = ptr + 8'd1; bitc = 0; sda_low = ~tx[7]; st = TXB; end
                  else    begin bitc = 0; st = RXB; end
                  if (stretch_ns > 0) begin scl_low = 1'b1; #(stretch_ns); scl_low = 1'b0; end
              end
        TXB:  begin
                  bitc = bitc + 1;
                  if (bitc < 8) sda_low = ~tx[7 - bitc];
                  else begin sda_low = 1'b0; sent = sent + 1; st = ACKM; end
              end
        ACKM: if (mack) begin tx = mem[ptr]; ptr = ptr + 8'd1; bitc = 0; sda_low = ~tx[7]; st = TXB; end
              else st = IDLE;
        default: ;
    endcase
end

endmodule // ddc_eeprom_model
