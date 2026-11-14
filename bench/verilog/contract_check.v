//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    contract_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : contract_check.v
// Module Description : Always-on contract monitors (`included into
//                      tb_belenos). Every violation prints an ERROR line (the
//                      first CC_SHOW of each kind) and counts in the bench's
//                      error count, so it fails whatever test is running.
//                        - Port contract of the AHB-Lite subordinates, both
//                          ports, on every hclk edge: hreadyout and hresp
//                          never X; with no data phase in progress, hreadyout
//                          high and OKAY; an ERROR is two cycles (hreadyout
//                          low then high, hresp high in both, held while the
//                          fabric stalls the second one), never one; read data
//                          known on the active byte lanes of a completing
//                          OKAY read.
//                        - Clock request (hclk_en_o low): no VRAM or LUT
//                          macro enable, no line-buffer write, both
//                          hreadyout high (sampled on the free-running
//                          clock); and, with the macros on the free-running
//                          clock (MACRO_FREECLK) where the read data is valid
//                          only VRAM_RD_LAT cycles after the read
//                          (VRAM_RD_LAT > 1 or VRAM_POISON), no VRAM read
//                          still in flight: the data would move on while
//                          Belenos is not clocked.
//                        - Macro ports: no X on the VRAM and LUT enables; no X
//                          address, write enable or (enabled lanes of) write
//                          data with an enable active; LUT_EN = 0 never
//                          enables the LUT; LUT_BANKS = 1 never addresses
//                          bank 1.
//                        - Outputs: no X on the control outputs once the
//                          reset is done; no X on a data bus while it is
//                          qualified (dpi_rgb with DE, the BDI pixel with its
//                          valid, the BDI register bus with its select, the
//                          8080 bus while driven).
//                        - Register invariants the area merges rest on
//                          (every hclk edge Belenos sees): a bench shadow
//                          of each register a merge removed, loaded as the
//                          removed register was, equals the source that now
//                          replaces it (see that section).
//                      cc_report prints the counts. The bins r_hresp_err and
//                      v_hresp_err are raised here, by a well-formed ERROR.
//----------------------------------------------------------------------------

localparam integer CC_SHOW = 5;          // ERROR lines printed per kind

integer cc_ahb_viol;                     // AHB port contract
integer cc_gate_viol;                    // clock request
integer cc_gate_cyc;                     // cycles sampled with hclk_en_o low
integer cc_macro_viol;                   // VRAM / LUT macro port
integer cc_x_viol;                       // X on outputs
integer cc_err_ok;                       // well-formed ERROR responses seen
integer cc_inv_viol;                     // register invariants (area merges)
initial begin
   cc_ahb_viol   = 0;
   cc_gate_viol  = 0;
   cc_gate_cyc   = 0;
   cc_macro_viol = 0;
   cc_x_viol     = 0;
   cc_err_ok     = 0;
   cc_inv_viol   = 0;
end

task cc_fail;
   input integer    kind;                // 0 AHB, 1 clock request, 2 macro, 3 X, 4 invariant
   input [72*8-1:0] what;
   integer          n;
   begin
      error = error + 1;
      case (kind)
        0: begin cc_ahb_viol   = cc_ahb_viol   + 1; n = cc_ahb_viol;   end
        1: begin cc_gate_viol  = cc_gate_viol  + 1; n = cc_gate_viol;  end
        2: begin cc_macro_viol = cc_macro_viol + 1; n = cc_macro_viol; end
        4: begin cc_inv_viol   = cc_inv_viol   + 1; n = cc_inv_viol;   end
        default: begin cc_x_viol = cc_x_viol + 1; n = cc_x_viol;      end
      endcase
      if (n <= CC_SHOW)
        $display("ERROR: contract -- %0s %t", what, $time);
   end
endtask


//
// AHB-Lite subordinate port contract, per port (0 = register port, 1 = VRAM
// window), sampled on the hclk edges Belenos sees
//----------------------------------------
genvar cc_p;
generate
for (cc_p = 0; cc_p < 2; cc_p = cc_p + 1) begin : g_cc_ahb
   wire        hsel   = (cc_p == 0) ? r_hsel_d    : v_hsel_d;
   wire  [1:0] htrans = (cc_p == 0) ? r_htrans_d  : v_htrans_d;
   wire        hwrite = (cc_p == 0) ? r_hwrite_d  : v_hwrite_d;
   wire  [2:0] hsize  = (cc_p == 0) ? r_hsize_d   : v_hsize_d;
   wire  [1:0] hal    = (cc_p == 0) ? r_haddr_d[1:0] : v_haddr_d[1:0];
   wire        hready = (cc_p == 0) ? r_hready    : v_hready;
   wire        hrdyo  = (cc_p == 0) ? r_hreadyout : v_hreadyout;
   wire        hresp  = (cc_p == 0) ? r_hresp     : v_hresp;
   wire [31:0] hrdata = (cc_p == 0) ? r_hrdata    : v_hrdata;
   reg         dph;                      // a transfer is in its data phase
   reg         dwr;                      // ... a write
   reg   [1:0] al;                       // ... its address bits [1:0]
   reg   [2:0] dsz;                      // ... its size
   reg   [1:0] est;                    // ERROR: 0 none, 1 first cycle seen, 2 second cycle stalled
   wire [31:0] dlanes = (dsz[1:0] == 2'd0) ? (32'hFF   << (8*al)) :
                        (dsz[1:0] == 2'd1) ? (32'hFFFF << (16*al[1])) : 32'hFFFF_FFFF;
   initial begin dph = 1'b0; dwr = 1'b0; al = 2'b00; dsz = 3'd2; est = 2'd0; end

   always @(posedge hclk)
     if (model_on !== 1'b1) begin
        dph = 1'b0;
        est = 2'd0;
     end else begin
        if ((hrdyo !== 1'b0 && hrdyo !== 1'b1) || (hresp !== 1'b0 && hresp !== 1'b1))
          cc_fail(0, (cc_p == 0) ? "r-port hreadyout or hresp is X" : "v-port hreadyout or hresp is X");
        else if (!dph) begin
           if ((hrdyo !== 1'b1) || (hresp !== 1'b0))
             cc_fail(0, (cc_p == 0) ? "r-port hreadyout low or ERROR with no data phase" :
                                      "v-port hreadyout low or ERROR with no data phase");
           est = 2'd0;
        end else begin
           case (est)
             2'd0:
               if (hresp === 1'b1) begin
                  if (hrdyo === 1'b0) est = 2'd1;
                  else cc_fail(0, (cc_p == 0) ? "r-port one-cycle ERROR (no first cycle with hreadyout low)" :
                                                "v-port one-cycle ERROR (no first cycle with hreadyout low)");
               end
             default:
               if ((hresp !== 1'b1) || (hrdyo !== 1'b1)) begin
                  cc_fail(0, (cc_p == 0) ? "r-port ERROR second cycle missing (hresp and hreadyout high)" :
                                           "v-port ERROR second cycle missing (hresp and hreadyout high)");
                  est = 2'd0;
               end else if (hready === 1'b1) begin
                  cc_err_ok = cc_err_ok + 1;
                  if (cc_p == 0) cov_r_hresp_err = 1'b1;
                  else           cov_v_hresp_err = 1'b1;
                  est = 2'd0;
               end else
                  est = 2'd2;            // the fabric stalls the second cycle: held
           endcase
           // Read data on the active lanes of a completing OKAY read
           if ((hready === 1'b1) && (hrdyo === 1'b1) && (hresp === 1'b0) && !dwr &&
               ((^(hrdata & dlanes)) === 1'bx))
             cc_fail(0, (cc_p == 0) ? "r-port read data X on an OKAY read" : "v-port read data X on an OKAY read");
        end
        // The next data phase (the address phase is accepted with hready)
        if (hready === 1'b1) begin
           dph = (hsel === 1'b1) && (htrans[1] === 1'b1);
           dwr = hwrite;
           al  = hal;
           dsz = hsize;
        end
     end
end
endgenerate


//
// Clock request, macro ports and outputs, sampled on the free-running clock
//----------------------------------------
integer cc_rd_age;                       // free-running edges since the last VRAM read
initial cc_rd_age = 1000;

always @(posedge free_clk)
  if ((model_on === 1'b1) && (reset_done === 1'b1)) begin
     // Clock request low: nothing may need the clock
     if (hclk_en === 1'b0) begin
        cc_gate_cyc = cc_gate_cyc + 1;
        if ((vram_cen !== 1'b1) || (lut_cen !== 1'b1) || ((|dpi_lb_we) !== 1'b0))
          cc_fail(1, "VRAM, LUT or line-buffer enable active while hclk_en_o = 0");
        if ((r_hreadyout !== 1'b1) || (v_hreadyout !== 1'b1))
          cc_fail(1, "hreadyout low while hclk_en_o = 0");
        if ((MACRO_FREECLK != 0) && ((VRAM_RD_LAT > 1) || (VRAM_POISON != 0)) && (cc_rd_age < VRAM_RD_LAT))
          cc_fail(1, "VRAM read in flight (VRAM_RD_LAT cycles) while hclk_en_o = 0");
     end
     // A read sampled by the macro at this edge (a free-running edge Belenos sees)
     if ((ICG_EN == 0) || (hclk_en_latch === 1'b1))
       cc_rd_age = ((vram_cen === 1'b0) && (vram_wen === 4'hF)) ? 0 : cc_rd_age + 1;

     // Macro ports
     if ((vram_cen !== 1'b0) && (vram_cen !== 1'b1))
       cc_fail(2, "vram_cen_o is X");
     else if (vram_cen === 1'b0) begin
        if (((^vram_addr) === 1'bx) || ((^vram_wen) === 1'bx))
          cc_fail(2, "VRAM address or write enables X with vram_cen_o active");
        else if ((^(vram_din & {{8{~vram_wen[3]}}, {8{~vram_wen[2]}}, {8{~vram_wen[1]}}, {8{~vram_wen[0]}}})) === 1'bx)
          cc_fail(2, "VRAM write data X on an enabled byte lane");
     end
     if ((lut_cen !== 1'b0) && (lut_cen !== 1'b1))
       cc_fail(2, "lut_cen_o is X");
     else if (lut_cen === 1'b0) begin
        if (LUT_EN == 0)
          cc_fail(2, "LUT enabled in a build without the LUT (LUT_EN = 0)");
        if (((^lut_addr) === 1'bx) || ((lut_wen !== 1'b0) && (lut_wen !== 1'b1)))
          cc_fail(2, "LUT address or write enable X with lut_cen_o active");
        else if ((lut_wen === 1'b0) && ((^lut_din) === 1'bx))
          cc_fail(2, "LUT write data X");
        if ((LUT_BANKS == 1) && (lut_addr[8] !== 1'b0))
          cc_fail(2, "LUT bank 1 addressed with LUT_BANKS = 1");
     end

     // Outputs
     if ((^{irq, hclk_en, r_hreadyout, r_hresp, v_hreadyout, v_hresp, vram_cen, lut_cen,
            lcd_cs_n, lcd_wr_n, lcd_rd_n, lcd_dc, lcd_d_oe, spi_sck, spi_cs_n, spi_dc, spi_mosi,
            lcd_reset_n, lcd_on, dpi_de, dpi_hs, dpi_vs, dpi_clk_d0, dpi_clk_d1, dpi_lb_we,
            bdi_px_valid, bdi_refresh_trig, bdi_reg_sel, ddc_scl_pd, ddc_sda_pd}) === 1'bx)
       cc_fail(3, "X on a control output");
     if ((dpi_de === 1'b1) && ((^dpi_rgb) === 1'bx))
       cc_fail(3, "X on dpi_rgb_o with DE");
     if ((bdi_px_valid === 1'b1) && ((^{bdi_px_data, bdi_px_last}) === 1'bx))
       cc_fail(3, "X on the BDI pixel with bdi_px_valid_o");
     if ((bdi_reg_sel === 1'b1) && ((^{bdi_reg_addr, bdi_reg_wr, bdi_reg_wdata}) === 1'bx))
       cc_fail(3, "X on the BDI register bus with bdi_reg_sel_o");
     if ((lcd_d_oe === 1'b1) && ((^lcd_d_out) === 1'bx))
       cc_fail(3, "X on lcd_d_o while driven");
  end


//
// Register invariants the area merges rest on (registers merged into an
// equivalent source). Each register a merge removed is kept here as a bench
// shadow, loaded exactly as the removed register was (same data, enable and
// reset value, on the hclk edges Belenos sees), and compared in every cycle
// with the source that replaces it:
//   - refresh_active one cycle late: the backend's active_dly is the only
//     copy (blns_refresh and the clock request read it);
//   - DBI builds: while the driver holds the display size (size_hold), the
//     size the core passes on is the engine's window size, which equals the
//     size held from the last cycle without the hold;
//   - DPI builds: the line length the driver takes a frame with is the
//     backend fetch's latched line length (both loaded while
//     refresh_active = 0, from the same size and CL_SWAP);
//   - cursor: its reversal and column-copy bits follow the backend's latched
//     DISP_CFG swaps (both loaded while refresh_active = 0);
//   - non-DBI builds: the backend's source width is the GPU's default pitch
//     (FRAME_WIDTH), one incrementer for both;
//   - the backend's start offset (shift-add) is the product it replaced,
//     (H' - 1) x pitch of the latched frame mod 2^(VRAM_AW+5), whenever the
//     requests may be raised (go), and go rises DIM_W + 1 cycles after
//     refresh_active.
//----------------------------------------
reg              cc_act_q;               // refresh_active, one cycle late
reg  [DIM_W-1:0] cc_held_w;              // DBI: DISP_SIZE held from the last cycle without the hold
reg  [DIM_W-1:0] cc_held_h;
reg  [DIM_W-1:0] cc_ln_len;              // DPI: line length latched while refresh_active = 0
reg        [2:0] cc_cur_sw;              // cursor {rev_in, rev_ln, cl} latched while refresh_active = 0

wire             cc_ract  = dut.u_core.bdi_refresh_active_i;
wire       [2:0] cc_dcfg  = dut.u_core.disp_cfg;            // {X, Y, CL}
wire       [2:0] cc_bk_sw = dut.u_core.u_backend.cfg_swap;   // latched {X, Y, CL}
wire       [2:0] cc_sw_of_dcfg = {cc_dcfg[0]  ? cc_dcfg[1]  : cc_dcfg[2],
                                  cc_dcfg[0]  ? cc_dcfg[2]  : cc_dcfg[1],  cc_dcfg[0]};
wire       [2:0] cc_sw_of_bk   = {cc_bk_sw[0] ? cc_bk_sw[1] : cc_bk_sw[2],
                                  cc_bk_sw[0] ? cc_bk_sw[2] : cc_bk_sw[1], cc_bk_sw[0]};
wire [DIM_W-1:0] cc_one   = {{(DIM_W-1){1'b0}}, 1'b1};

always @(posedge hclk) begin
   if (model_on === 1'b1) begin
      // the one flop (backend) and what blns_refresh and the clock request read
      if ((dut.u_core.u_backend.active_dly !== cc_act_q) ||
          (dut.u_core.u_regs.u_refresh.active_q !== cc_act_q) || (dut.u_core.refr_active_q !== cc_act_q))
        cc_fail(4, "refresh_active one cycle late: the backend's active_dly or a reader of it differs");
   end
   if (hresetn_d !== 1'b1) begin
      cc_act_q  <= 1'b0;
      cc_held_w <= cc_one;
      cc_held_h <= cc_one;
      cc_ln_len <= {DIM_W{1'b0}};
      cc_cur_sw <= 3'b000;
   end else begin
      cc_act_q  <= cc_ract;
      if (dut.u_core.size_hold !== 1'b1) begin
         cc_held_w <= dut.u_core.disp_width;
         cc_held_h <= dut.u_core.disp_height;
      end
      if (cc_ract !== 1'b1) begin
         cc_ln_len <= dut.u_core.dpi_cl_swap_o ? dut.u_core.bdi_height_o : dut.u_core.bdi_width_o;
         cc_cur_sw <= cc_sw_of_dcfg;
      end
   end
end

generate
   if (HAS_DBI) begin : g_cc_inv_dbi
      always @(posedge hclk)
        if ((model_on === 1'b1) && (dut.u_core.size_hold === 1'b1)) begin
           if ({dut.u_core.bdi_width_o, dut.u_core.bdi_height_o} !== {cc_held_w, cc_held_h})
             cc_fail(4, "DBI size hold: the size passed on is not the held DISP_SIZE");
           if ({dut.G_DBI.u_dbi.blns_dbi_engine_inst.win_w, dut.G_DBI.u_dbi.blns_dbi_engine_inst.win_h} !==
               {cc_held_w, cc_held_h})
             cc_fail(4, "DBI size hold: the engine's window size is not the held DISP_SIZE");
        end
   end else begin : g_cc_inv_nodbi
      wire [DIM_W:0] cc_w_p1 = {1'b0, dut.u_core.disp_width} + {{DIM_W{1'b0}}, 1'b1};
      always @(posedge hclk)
        if ((model_on === 1'b1) &&
            ((dut.u_core.u_backend.src_width_in !== dut.u_core.frame_width) ||
             (dut.u_core.frame_width !== (dut.u_core.pix_double ? cc_w_p1[DIM_W:1] : dut.u_core.disp_width))))
          cc_fail(4, "the backend's source width is not FRAME_WIDTH");
   end
   if (HAS_DPI) begin : g_cc_inv_dpi
      always @(posedge hclk)
        if (model_on === 1'b1) begin
           if (dut.u_core.u_backend.blns_bk_fetch_inst.line_len_m1 !== (cc_ln_len - cc_one))
             cc_fail(4, "DPI: the backend's latched line length - 1 is not the frame's line length - 1");
           if (dut.G_DPI.u_dpi.u_dpi_bdi.line_len_m1_i !== (cc_ln_len - cc_one))
             cc_fail(4, "DPI: the line length - 1 blns_dpi_bdi takes is not the frame's line length - 1");
        end
   end
   begin : g_cc_inv_yofs
      reg  [63:0] cc_prod;
      integer     cc_ra_n;               // cycles of refresh_active so far
      always @(posedge hclk) begin
         cc_prod = ({48'd0, dut.u_core.u_backend.cfg_pitch} *
                    ({{(64-DIM_W){1'b0}}, dut.u_core.u_backend.cfg_src_height} - 64'd1)) & ((64'd1 << (VRAM_AW+5)) - 64'd1);
         if ((model_on === 1'b1) && (dut.u_core.u_backend.go === 1'b1) &&
             ({{(64-VRAM_AW-5){1'b0}}, dut.u_core.u_backend.yofs} !== cc_prod))
           cc_fail(4, "backend start offset: not (H' - 1) x pitch of the latched frame");
         if ((model_on === 1'b1) && (hresetn_d === 1'b1) &&
             (dut.u_core.u_backend.go !== ((cc_ra_n > DIM_W) && (cc_act_q === 1'b1))))
           cc_fail(4, "backend start offset: go not DIM_W + 1 cycles after refresh_active");
         cc_ra_n = (hresetn_d !== 1'b1) || (cc_ract !== 1'b1) ? 0 : cc_ra_n + 1;
      end
   end
   if (CURSOR_EN != 0) begin : g_cc_inv_cur
      always @(posedge hclk)
        if (model_on === 1'b1) begin
           if (cc_sw_of_bk !== cc_cur_sw)
             cc_fail(4, "cursor: the backend's latched swaps do not give the cursor's latched swaps");
           if ({dut.u_core.u_backend.g_cursor.blns_bk_cursor_inst.rev_in,
                dut.u_core.u_backend.g_cursor.blns_bk_cursor_inst.rev_ln,
                dut.u_core.u_backend.g_cursor.blns_bk_cursor_inst.cfg_cl} !== cc_cur_sw)
             cc_fail(4, "cursor: {rev_in, rev_ln, cfg_cl} is not the latched reversals and CL");
        end
   end
endgenerate


task cc_report;
   begin
      $display("CONTRACT CHECK: ahb=%0d gate=%0d (%0d cycles with hclk_en_o low) macro=%0d x=%0d inv=%0d, %0d well-formed ERRORs",
               cc_ahb_viol, cc_gate_viol, cc_gate_cyc, cc_macro_viol, cc_x_viol, cc_inv_viol, cc_err_ok);
   end
endtask


//
// End of test: the model counters that are not already in the error count,
// and the comparison count (called before the PASSED/FAILED banner, and by
// tb_skip_finish)
//----------------------------------------
task tb_model_check;
   begin
      if (u_lcd8080.anomaly_total != 0) begin
         $display("ERROR: 8080 panel model -- %0d protocol anomalies (contention, read outside RDDISCMD, no hold at WRX)",
                  u_lcd8080.anomaly_total);
         error = error + 1;
      end
      if (u_lcdspi.anomaly_total != 0) begin
         $display("ERROR: SPI panel model -- %0d protocol anomalies (byte cut short, no hold at SCL, bad parameter)",
                  u_lcdspi.anomaly_total);
         error = error + 1;
      end
      // Counted only while a test sets check (a test that expects a timing
      // disruption clears check, or restores the count, around it)
      if (u_dpipanel.errors != 0) begin
         $display("ERROR: DPI panel model -- %0d timing errors", u_dpipanel.errors);
         error = error + 1;
      end
      if ((g_tmdsrx.u_tmdsrx.asp_perr != 0) || (g_tmdsrx.u_tmdsrx.asp_ferr != 0) ||
          (g_tmdsrx.u_tmdsrx.acr_err != 0)) begin
         $display("ERROR: TMDS audio -- %0d subframe parity, %0d sample-packet layout, %0d clock-regeneration errors",
                  g_tmdsrx.u_tmdsrx.asp_perr, g_tmdsrx.u_tmdsrx.asp_ferr, g_tmdsrx.u_tmdsrx.acr_err);
         error = error + 1;
      end
      if (tb_checks < tb_min_checks) begin
         $display("ERROR: the test made %0d comparisons, fewer than its minimum %0d", tb_checks, tb_min_checks);
         error = error + 1;
      end
   end
endtask
