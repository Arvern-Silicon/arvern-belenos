//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    dpi_panel_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dpi_panel_model.v
// Module Description : Parallel RGB (MIPI DPI) panel model for the DPI driver
//                      tests. Samples DE, HSYNC, VSYNC and the colour on the
//                      sampling edge of the panel clock (rising, or falling
//                      with edge_fall), with the polarities the test sets,
//                      stores the active pixels in fb (row-major, W_MAX x
//                      H_MAX) and checks the timing against h_*/v_* when
//                      check is set: H_ACT pixels per DE run, HSYNC H_FP
//                      pixels after the end of DE and H_SW long, V_ACT DE runs
//                      per frame, VSYNC edges on HSYNC leading edges (CEA-861)
//                      or, with a vertical back porch of 0, on the first DE
//                      rise, and VSYNC never active with DE; the blanking
//                      fields: H back porch (HSYNC end to DE), line total
//                      (HSYNC to HSYNC), VSYNC H_FP+1 HSYNC edges after the
//                      last active line's, V_SW lines long, V_BP lines before
//                      the first DE, and the frame total (VSYNC to VSYNC).
//                      A test that changes CLK_DIV with check set allows one
//                      line one pixel off (lt_slack, dpi_timing sets it).
//                      Each measurement needs both of its edges seen while
//                      check is set, so clearing check around a change (an
//                      UPDATE, a stop, a reset) also restarts them.
//                      vline is the line the panel is in, as the driver
//                      numbers them (0 = first active line, from its first
//                      pixel; V_ACT and up = the blanking).
//                      A frame ends with VSYNC: frames increments.
//----------------------------------------------------------------------------

module  dpi_panel_model #(
    parameter W_MAX = 128,
    parameter H_MAX = 64
) (
    input  wire        clk_i,             // panel clock (pin)
    input  wire        de_i,
    input  wire        hs_i,
    input  wire        vs_i,
    input  wire [23:0] rgb_i
);

// Set by the test
reg            edge_fall = 1'b0;
reg            hs_high   = 1'b0;
reg            vs_high   = 1'b0;
reg            de_low    = 1'b0;
reg            check     = 1'b0;
integer        h_act = 0, h_fp = 0, h_sw = 0, v_act = 0;
integer        h_bp = 0, v_fp = 0, v_sw = 0, v_bp = 0;
// A CLK_DIV change taken while check is set: the panel clock has one
// irregular period there, so one line may be one pixel short or long
integer        lt_slack = 0;

// Results
reg     [23:0] fb [0:W_MAX*H_MAX-1];
integer        frames = 0;
integer        errors = 0;
integer        lines  = 0;
integer        vline  = 0;              // line the panel is in (0 = first active line)
integer        blank_checks = 0;        // blanking measurements made (H back porch, totals, VSYNC)

wire           de_a = de_i ^ de_low;
wire           hs_a = hs_i ^ ~hs_high;
wire           vs_a = vs_i ^ ~vs_high;

reg            de_q = 1'b0, hs_q = 1'b0, vs_q = 1'b0;
reg            de_seen = 1'b0;
integer        x = 0, px = 0, de_end = 0, hs_beg = 0;
// Blanking measurements: HSYNC leading edges counted (hs_n), the edge or
// pixel each measurement starts from, and whether that start was seen
// while check was set
integer        hs_n = 0, hs_px = 0, hs_end = 0, hs_act = 0, vs_rise = 0, vs_fall = 0, ls_px = -1;
reg            ok_hs = 1'b0, ok_hse = 1'b0, ok_act = 1'b0, ok_vsr = 1'b0;
reg            vs_wait_de = 1'b0, vs_at_de = 1'b0, de_first = 1'b0;

task blank_err;
   input [8*40-1:0] what;
   input integer    got, exp;
   begin
      $display("ERROR: DPI panel -- %0s %0d, expected %0d %t", what, got, exp, $time);
      errors = errors + 1;
   end
endtask

task sample;
   begin
      px = px + 1;
      if (!check) begin
         ok_hs = 1'b0; ok_hse = 1'b0; ok_act = 1'b0; ok_vsr = 1'b0;
         vs_wait_de = 1'b0;
      end
      // HSYNC end, then the line start (first pixel position of a line,
      // active or blank) h_bp pixels later
      if (!hs_a && hs_q) begin
         hs_end = px; ok_hse = check;
         ls_px  = px + h_bp;
      end
      if (px == ls_px) vline = vline + 1;
      if (de_a && !de_q) begin
         if (de_first) vline = 0;                       // first active line of a frame
         de_first = 1'b0;
         if (ok_hse) begin
            blank_checks = blank_checks + 1;
            if (px - hs_end != h_bp) blank_err("H back porch of", px - hs_end, h_bp);
         end
         if (vs_wait_de) begin                          // V back porch: lines from VSYNC end
            vs_wait_de = 1'b0;
            blank_checks = blank_checks + 1;
            if (vs_at_de ? (v_bp != 0) : (hs_n - vs_fall != v_bp - 1))
               blank_err("V back porch (HSYNC edges) of", vs_at_de ? 0 : hs_n - vs_fall + 1, v_bp);
         end
      end
      if (hs_a && !hs_q) begin
         if (ok_hs) begin
            blank_checks = blank_checks + 1;
            if ((lt_slack > 0) && ((px - hs_px == h_act + h_fp + h_sw + h_bp - 1) ||
                                   (px - hs_px == h_act + h_fp + h_sw + h_bp + 1))) begin
               lt_slack = lt_slack - 1;
               $display("INFO:  DPI panel -- line of %0d pixels at a CLK_DIV change (HSYNC to HSYNC, panel line %0d) %t",
                        px - hs_px, vline, $time);
            end
            else if (px - hs_px != h_act + h_fp + h_sw + h_bp)
               blank_err("line of", px - hs_px, h_act + h_fp + h_sw + h_bp);
         end
         hs_n = hs_n + 1; hs_px = px; ok_hs = check;
         if (de_seen || (!de_a && de_q)) begin hs_act = hs_n; ok_act = check; end
      end
      if (vs_a && !vs_q) begin
         if (ok_act) begin
            blank_checks = blank_checks + 1;
            if (hs_n - hs_act != v_fp + 1) blank_err("V front porch (HSYNC edges) of", hs_n - hs_act - 1, v_fp);
         end
         if (ok_vsr) begin
            blank_checks = blank_checks + 1;
            if (hs_n - vs_rise != v_act + v_fp + v_sw + v_bp)
               blank_err("frame of (lines)", hs_n - vs_rise, v_act + v_fp + v_sw + v_bp);
         end
         vs_rise = hs_n; ok_vsr = check; ok_act = 1'b0;
      end
      if (!vs_a && vs_q) begin
         vs_at_de = de_a && !de_q && !(hs_a && !hs_q);
         if (ok_vsr) begin
            blank_checks = blank_checks + 1;
            if (hs_n - vs_rise != (vs_at_de ? v_sw - 1 : v_sw))
               blank_err("VSYNC of (lines)", hs_n - vs_rise + (vs_at_de ? 1 : 0), v_sw);
         end
         vs_fall = hs_n; vs_wait_de = check && ok_vsr; de_first = 1'b1;
         if (vs_at_de) begin                            // ended by the first pixel itself
            vs_wait_de = 1'b0; vline = 0; de_first = 1'b0;
            if (check && ok_vsr) begin
               blank_checks = blank_checks + 1;
               if (v_bp != 0) blank_err("V back porch (HSYNC edges) of", 0, v_bp);
            end
         end
      end
      if (de_a) begin
         if ((x < W_MAX) && (lines < H_MAX)) fb[lines*W_MAX + x] = rgb_i;
         x = x + 1;
      end
      if (!de_a && de_q) begin
         if (check && (x != h_act)) begin
            $display("ERROR: DPI panel -- line %0d has %0d pixels, expected %0d %t", lines, x, h_act, $time);
            errors = errors + 1;
         end
         lines = lines + 1; x = 0; de_end = px; de_seen = 1'b1;
      end
      if (hs_a && !hs_q) begin
         if (check && de_seen && (px - de_end != h_fp)) begin
            $display("ERROR: DPI panel -- HSYNC %0d pixels after DE, expected %0d %t", px - de_end, h_fp, $time);
            errors = errors + 1;
         end
         hs_beg = px; de_seen = 1'b0;
      end
      if (!hs_a && hs_q && check && (hs_beg != 0) && (px - hs_beg != h_sw)) begin
         $display("ERROR: DPI panel -- HSYNC of %0d pixels, expected %0d %t", px - hs_beg, h_sw, $time);
         errors = errors + 1;
      end
      // VSYNC moves with the HSYNC leading edge, or at the first active pixel
      // of the first line when the vertical back porch is 0
      if (check && (vs_a != vs_q) && !(hs_a && !hs_q) && !(de_a && !de_q)) begin
         $display("ERROR: DPI panel -- VSYNC edge %0d pixels after the HSYNC leading edge %t", px - hs_beg, $time);
         errors = errors + 1;
      end
      if (check && vs_a && de_a) begin
         $display("ERROR: DPI panel -- VSYNC active during active pixels %t", $time);
         errors = errors + 1;
      end
      if (vs_a && !vs_q) begin
         if (check && (lines != 0) && (lines != v_act)) begin
            $display("ERROR: DPI panel -- frame of %0d lines, expected %0d %t", lines, v_act, $time);
            errors = errors + 1;
         end
         if (lines != 0) frames = frames + 1;
         lines = 0;
      end
      de_q = de_a; hs_q = hs_a; vs_q = vs_a;
   end
endtask

always @(posedge clk_i) if (!edge_fall) sample;
always @(negedge clk_i) if (edge_fall)  sample;

endmodule // dpi_panel_model
