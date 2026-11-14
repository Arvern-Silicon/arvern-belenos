//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dpi_ddc
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_ddc.v
// Module Description : HDMI DDC register (DPI_DDC): reset value (lines
//                      released and read high), write mask, each pull-down
//                      reaching its pin and the line level reading back; an
//                      I2C master run through the register reads the test
//                      EDID of ddc_eeprom_model (random read from offset 0,
//                      then across the block boundary), a wrong address gets
//                      no acknowledge, and a read with the monitor stretching
//                      SCL is still exact. Without the register (DPI_DDC_EN 0,
//                      or no HDMI): RAZ/WI, pins released, DPI_CAPS.DDC 0.
//----------------------------------------------------------------------------
`define LONG_TIMEOUT

`include "dpi_tasks.v"

reg  [31:0] v;
reg   [7:0] rx [0:15];
reg   [7:0] exp_b;
integer     i, n_bad;
reg         ack;
reg         ok;

// One register write per line state (bit-banged I2C, as the C driver does)
task ddc_lines;
   input scl;
   input sda;
   begin
      reg_wr(DPI_DDC, {30'd0, ~sda, ~scl});
   end
endtask

// Release SCL, then wait until it reads high (clock stretching)
task ddc_scl_high;
   input sda;
   integer t;
   begin
      ddc_lines(1'b1, sda);
      v = 32'h0;
      for (t = 0; (t < 2000) && !v[8]; t = t + 1) reg_rd_val(DPI_DDC, v);
      if (!v[8]) tb_error("DDC: SCL stays low");
   end
endtask

task ddc_start;
   begin
      ddc_lines(1'b0, 1'b1);
      ddc_scl_high(1'b1);
      ddc_lines(1'b1, 1'b0);
      ddc_lines(1'b0, 1'b0);
   end
endtask

task ddc_stop;
   begin
      ddc_lines(1'b0, 1'b0);
      ddc_scl_high(1'b0);
      ddc_lines(1'b1, 1'b1);
   end
endtask

task ddc_bit;
   input  out;
   output in;
   begin
      ddc_lines(1'b0, out);
      ddc_scl_high(out);
      reg_rd_val(DPI_DDC, v);
      in = v[9];
      ddc_lines(1'b0, out);
   end
endtask

task ddc_put;
   input  [7:0] b;
   output       acked;
   integer      k;
   reg          dummy;
   begin
      for (k = 7; k >= 0; k = k - 1) ddc_bit(b[k], dummy);
      ddc_bit(1'b1, dummy);
      acked = ~dummy;
   end
endtask

task ddc_get;
   input        more;
   output [7:0] b;
   integer      k;
   reg          bit_in;
   begin
      for (k = 7; k >= 0; k = k - 1) begin ddc_bit(1'b1, bit_in); b[k] = bit_in; end
      ddc_bit(~more, bit_in);
   end
endtask

// Random read of n bytes at off from addr7 into rx[]; ok = every byte acknowledged
task ddc_read;
   input [6:0] addr7;
   input [7:0] off;
   input integer n;
   integer     k;
   begin
      ddc_start;
      ddc_put({addr7, 1'b0}, ack);  ok = ack;
      if (ok) begin ddc_put(off, ack); ok = ack; end
      if (ok) begin ddc_start; ddc_put({addr7, 1'b1}, ack); ok = ack; end
      for (k = 0; ok && (k < n); k = k + 1) ddc_get(k + 1 < n, rx[k]);
      ddc_stop;
   end
endtask

task check_bytes;
   input [7:0] off;
   input integer n;
   integer     k;
   begin
      n_bad = 0;
      for (k = 0; k < n; k = k + 1)
         if (rx[k] !== u_edid.mem[(off + k) & 255]) n_bad = n_bad + 1;
      if (n_bad != 0) begin
         for (k = 0; k < n; k = k + 1) $display("  byte 0x%02x: read %02x, EDID %02x", (off + k) & 255, rx[k], u_edid.mem[(off + k) & 255]);
         tb_error("DDC: EDID bytes differ from the model");
      end
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|             DPI: HDMI DDC REGISTER            |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DPI)
         tb_skip_finish("|        (no DPI driver in this build)          |");

      if (!HAS_DDC) begin
         reg_rd(DPI_DDC, 32'h0);
         reg_wr(DPI_DDC, 32'hFFFF_FFFF);  reg_rd(DPI_DDC, 32'h0);
         if ((ddc_scl_pd !== 1'b0) || (ddc_sda_pd !== 1'b0)) tb_error("DDC: pins not released without the register");
         reg_rd_mask(DPI_CAPS, 32'h0, 32'h100);
      end else begin
         // Reset value, write mask, pins
         reg_rd(DPI_DDC, 32'h0000_0300);
         if ((ddc_scl_pd !== 1'b0) || (ddc_sda_pd !== 1'b0)) tb_error("DDC: pins not released at reset");
         // (the line levels read back through a 2-FF synchroniser)
         reg_wr(DPI_DDC, 32'hFFFF_FFFF);  repeat(4) @(posedge free_clk);
         reg_rd(DPI_DDC, 32'h0000_0003);
         if ((ddc_scl !== 1'b0) || (ddc_sda !== 1'b0)) tb_error("DDC: lines not pulled low");
         reg_wr(DPI_DDC, 32'h1);  repeat(4) @(posedge free_clk);  reg_rd(DPI_DDC, 32'h0000_0201);
         if ((ddc_scl !== 1'b0) || (ddc_sda !== 1'b1)) tb_error("DDC: SCL alone not pulled low");
         reg_wr(DPI_DDC, 32'h2);  repeat(4) @(posedge free_clk);  reg_rd(DPI_DDC, 32'h0000_0102);
         reg_wr(DPI_DDC, 32'h0);  repeat(4) @(posedge free_clk);  reg_rd(DPI_DDC, 32'h0000_0300);
         reg_rd_mask(DPI_CAPS, 32'h100, 32'h100);

         // EDID header (offset 0)
         ddc_read(7'h50, 8'h00, 8);
         if (!ok) tb_error("DDC: no acknowledge from the EDID");
         check_bytes(8'h00, 8);
         if ((rx[0] !== 8'h00) || (rx[1] !== 8'hFF) || (rx[7] !== 8'h00)) tb_error("DDC: not an EDID header");

         // Across the block boundary
         ddc_read(7'h50, 8'h7C, 8);
         if (!ok) tb_error("DDC: no acknowledge at offset 0x7C");
         check_bytes(8'h7C, 8);

         // No device at 0x51
         ddc_read(7'h51, 8'h00, 1);
         if (ok) tb_error("DDC: acknowledge from a missing device");

         // The monitor stretches SCL after every acknowledge
         u_edid.stretch_ns = 3000;
         ddc_read(7'h50, 8'h36, 4);
         if (!ok) tb_error("DDC: no acknowledge while stretching");
         check_bytes(8'h36, 4);
         u_edid.stretch_ns = 0;

         repeat(4) @(posedge free_clk);
         reg_rd(DPI_DDC, 32'h0000_0300);
         $display("DDC: %0d EDID bytes read through DPI_DDC", u_edid.sent);
      end

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
