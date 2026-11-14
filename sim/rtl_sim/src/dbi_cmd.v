//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Test:      dbi_cmd
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbi_cmd.v
// Module Description : DBI driver generic commands on every PHY of the build
//                      (DIF_TYPE 1, 2, 3) at CLK_DIV 0, 1, 3 and 15: a command
//                      with 0, 1, 3 pre-loaded parameters, a command whose
//                      PARAM FIFO runs dry (CS held, no strobe, BUSY while it
//                      waits), a 40-parameter command streamed through the
//                      16-deep FIFO and one with the largest NPARAM, 255.
//                      With the parameters pre-loaded, WR is high exactly
//                      CLK_DIV+1 cycles between the 8080 strobes. The protocol monitors of dbi_model_ext
//                      check WR/RD/SCK phase lengths, D/CX per item and CS
//                      framing; the item log is checked item by item (one CS
//                      frame per command). CMD_DONE (through DIF_IRQ_EN,
//                      IRQ_EN.DIF and irq_o) must rise only once CS is
//                      released and the last item has reached the panel.
//----------------------------------------------------------------------------

`include "dbi_model_ext.v"

integer    phy_i, div_i, kk, mark, cyc0, cyc_lim;
reg        phy;
reg  [3:0] div;
reg [31:0] rd;
reg [15:0] pv;
integer    nitems_at_irq;
reg        cs_at_irq;

// Wait for irq_o high (at most `lim` cycles), sampling the pin state then
task wait_irq;
   input integer lim;
   integer       nn;
   begin
      nn = 0;
      while ((irq !== 1'b1) && (nn < lim)) begin
         @(negedge free_clk);
         nn = nn + 1;
      end
      nitems_at_irq = lg_n;
      cs_at_irq     = (phy == PHY_8080) ? lcd_cs_n : spi_cs_n;
      if (irq !== 1'b1) tb_error("irq_o (CMD_DONE) never rose");
   end
endtask

// CMD_DONE check after a command: irq_o rises with CS released and every
// expected item delivered; W1C then clears it.
task check_done;
   input [40*8-1:0] what;
   begin
      wait_irq(20000);
      if (cs_at_irq !== 1'b1) begin
         $display("ERROR: %0s -- CMD_DONE raised while CS still low %t", what, $time);
         error = error + 1;
      end
      if (nitems_at_irq - mark != ex_n) begin
         $display("ERROR: %0s -- CMD_DONE raised after %0d / %0d items %t", what, nitems_at_irq - mark, ex_n, $time);
         error = error + 1;
      end
      reg_rd_mask(IRQ_FLAG,     32'h0000_0100, 32'h0000_0100);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0000_0001, 32'h0000_0007);
      reg_wr(DIF_IRQ_FLAG, 32'h0000_0001);
      reg_rd_mask(DIF_IRQ_FLAG, 32'h0000_0000, 32'h0000_0007);
      reg_rd_mask(IRQ_FLAG,     32'h0000_0000, 32'h0000_0100);
      if (irq !== 1'b0) tb_error("irq_o still high after the CMD_DONE W1C");
      reg_rd_mask(DIF_STATUS, 32'h0000_0000, ST_BUSY | ST_CMD_PEND | ST_LEVEL);
      reg_rd_mask(IRQ_FLAG, 32'h0, 32'h3);            // a command is not a refresh
      reg_wr(IRQ_FLAG, 32'h3);
      dbi_check_log(mark, what);
   end
endtask

initial
   begin
      $display(" ===============================================");
      $display("|        DBI: GENERIC COMMANDS AND TIMING       |");
      $display(" ===============================================");
      @(posedge reset_done);

      if (!HAS_DBI)
         tb_skip_finish("|        (no DBI driver in this build)          |");

      reg_wr(IRQ_EN,     32'h0000_0100);       // IRQ_FLAG.DIF -> irq_o
      reg_wr(DIF_IRQ_EN, 32'h0000_0001);       // CMD_DONE
      reg_wr(IRQ_FLAG,   32'h0000_00FF);

      for (phy_i = 0; phy_i < 2; phy_i = phy_i + 1) begin
         phy = phy_i;
         if (((phy == PHY_8080) && HAS_8080) || ((phy == PHY_SPI) && HAS_SPI)) begin
            for (div_i = 0; div_i < 4; div_i = div_i + 1) begin
               div = (div_i == 0) ? 4'd0 : (div_i == 1) ? 4'd1 : (div_i == 2) ? 4'd3 : 4'd15;
               $display("INFO:  PHY %0s CLK_DIV %0d", (phy == PHY_8080) ? "8080" : "SPI", div);
               dif_cfg(phy, div, 1'b0, 1'b1, 1'b0);

               // 1. command without parameter
               mark = lg_n; exp_reset;
               exp_cmd(phy, 8'h11, 1'b1);
               reg_wr(DIF_CMD, 32'h0000_0011);
               check_done("cmd 0x11, 0 param");

               // 2. one pre-loaded parameter
               mark = lg_n; exp_reset;
               reg_wr(DIF_PARAM, 32'hABCD_0055);
               reg_rd_mask(DIF_STATUS, 32'h0000_0100, ST_LEVEL | ST_BUSY);
               exp_cmd(phy, 8'h3A, 1'b1);
               exp_par(phy, 16'h0055);
               reg_wr(DIF_CMD, 32'h0000_013A);
               check_done("cmd 0x3A, 1 param");

               // 3. three pre-loaded parameters, full 16-bit bus values
               mark = lg_n; exp_reset;
               reg_wr(DIF_PARAM, 32'h0000_1234);
               reg_wr(DIF_PARAM, 32'h0000_80AB);
               reg_wr(DIF_PARAM, 32'hFFFF_FFFF);
               reg_rd_mask(DIF_STATUS, 32'h0000_0300, ST_LEVEL | ST_BUSY);
               exp_cmd(phy, 8'h36, 1'b1);
               exp_par(phy, 16'h1234); exp_par(phy, 16'h80AB); exp_par(phy, 16'hFFFF);
               m8_wr_hi_max = 0;
               reg_wr(DIF_CMD, 32'hFFFF_0336);        // bits above [15:8] ignored
               check_done("cmd 0x36, 3 params");
               // pre-loaded parameters: WR high exactly CLK_DIV+1 between strobes
               if ((phy == PHY_8080) && (m8_wr_hi_max != div + 1)) begin
                  $display("ERROR: cmd 0x36 -- WR high up to %0d cycles between strobes / expected %0d %t", m8_wr_hi_max, div + 1, $time);
                  error = error + 1;
               end

               // 4. parameters supplied late: the engine waits with CS held
               mark = lg_n; exp_reset;
               exp_cmd(phy, 8'hB6, 1'b1);
               exp_par(phy, 16'h000A); exp_par(phy, 16'h0082);
               reg_wr(DIF_CMD, 32'h0000_02B6);
               repeat(40*(div+1) + 100) @(posedge free_clk);
               if (lg_n - mark != 1) tb_error("FIFO dry: items other than the command byte sent");
               if (((phy == PHY_8080) ? lcd_cs_n : spi_cs_n) !== 1'b0) tb_error("FIFO dry: CS not held low");
               reg_rd_mask(DIF_STATUS, ST_BUSY, ST_BUSY | ST_CMD_PEND | ST_LEVEL);
               reg_rd_mask(DIF_IRQ_FLAG, 32'h0, 32'h7);
               reg_wr(DIF_PARAM, 32'h0000_000A);
               repeat(40*(div+1) + 100) @(posedge free_clk);
               if (lg_n - mark != 2) tb_error("FIFO dry: first late parameter not sent alone");
               if (((phy == PHY_8080) ? lcd_cs_n : spi_cs_n) !== 1'b0) tb_error("FIFO dry: CS not held low after the first parameter");
               if (irq !== 1'b0) tb_error("CMD_DONE before the last parameter");
               reg_wr(DIF_PARAM, 32'h0000_0082);
               check_done("cmd 0xB6, params late");

               // 5. 40 parameters streamed through the 16-deep FIFO
               if (div <= 1) begin
                  mark = lg_n; exp_reset;
                  exp_cmd(phy, 8'hE0, 1'b1);
                  reg_wr(DIF_CMD, 32'h0000_28E0);
                  for (kk = 0; kk < 40; kk = kk + 1) begin
                     pv = (kk * 16'h0731) ^ 16'h5A5A;
                     exp_par(phy, pv);
                     reg_poll(DIF_STATUS, ST_PARAM_FULL, 32'h0, 2000);   // as blns_dbi_cmd
                     reg_wr(DIF_PARAM, {16'h0, pv});
                  end
                  check_done("cmd 0xE0, 40 params");
               end

               // 6. the largest NPARAM, 255 parameters
               if (div == 0) begin
                  mark = lg_n; exp_reset;
                  exp_cmd(phy, 8'hE1, 1'b1);
                  reg_wr(DIF_CMD, 32'h0000_FFE1);
                  for (kk = 0; kk < 255; kk = kk + 1) begin
                     pv = (kk * 16'h1D3B) ^ 16'hC3A5;
                     exp_par(phy, pv);
                     reg_poll(DIF_STATUS, ST_PARAM_FULL, 32'h0, 2000);
                     reg_wr(DIF_PARAM, {16'h0, pv});
                  end
                  check_done("cmd 0xE1, 255 params");
               end
               dif_wait_idle(100);
            end
         end
      end

      if (u_lcd8080.anomaly_count != 0) tb_error("8080 panel model saw protocol anomalies");
      if (u_lcdspi.anomaly_count  != 0) tb_error("SPI panel model saw protocol anomalies");
      $display("INFO:  longest WR high gap between command items: %0d cycles", m8_wr_hi_max);

      repeat(5) @(posedge free_clk);
      stimulus_done = 1;
   end
