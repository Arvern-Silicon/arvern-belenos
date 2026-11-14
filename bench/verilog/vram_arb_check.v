//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    vram_arb_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : vram_arb_check.v
// Module Description : Passive VRAM-arbiter checker (`included into
//                      tb_belenos, always on). On every hclk edge out of
//                      reset (model_on), from the arbiter's requester ports
//                      and the VRAM macro pins:
//                        - grants: one at most, only to a requester that
//                          requests; urgent only with its request; the class
//                          order of blns_vram_arb (urgent > host > normal >
//                          idle-only, the lower index first in a class) and
//                          its aging: the GPU loses at most AGE_MAX cycles in
//                          a row to the window (urgent cycles not counted),
//                          then takes the next one (the counter here only
//                          observes the grants);
//                        - macro access: the granted requester's address,
//                          byte enables (non-zero on a write, none on a read)
//                          and write data, the enable only with a grant;
//                        - reads: every read granted gives exactly one read
//                          data valid, to its requester, exactly VRAM_RD_LAT +
//                          VRAM_RD_REG_EN cycles later (so in grant order),
//                          with the tag it was granted with (the GPU, and the
//                          refresh with the cursor) and the word the VRAM
//                          model read at the grant (writes take effect at
//                          their grant, in grant order); no read data valid
//                          without a read granted, none for a write;
//                        - the refresh slot (pixel and cursor reads on one
//                          requester): a request not granted is held with
//                          its address and tag while the backend may request
//                          (it drops only as a frame ends).
//                      A violation prints an ERROR line (the first VAC_SHOW
//                      ones) and counts in the bench's error count.
//                      vram_arb_check_report prints the accesses checked.
//----------------------------------------------------------------------------

`define VAC_ARB dut.u_core.u_vram_arb

localparam        VAC_L        = VRAM_RD_LAT + VRAM_RD_REG_EN;   // read latency seen by the requesters
localparam        VAC_AGE_MAX  = 7;     // blns_vram_arb AGE_MAX (belenos_core keeps the default)
localparam        VAC_SHOW     = 10;    // ERROR lines printed (every error counts)
localparam  [3:0] VAC_M_WIN    = 4'b0001 << VRQ_WIN;
localparam  [3:0] VAC_M_GPU    = 4'b0001 << VRQ_GPU;
localparam  [3:0] VAC_M_BK     = 4'b0001 << VRQ_BK;
localparam  [3:0] VAC_M_WP     = 4'b0001 << VRQ_WP;

// The arbiter's requester ports
wire           [3:0] vac_req    = `VAC_ARB.req_i;
wire           [3:0] vac_urg    = `VAC_ARB.urgent_i;
wire           [3:0] vac_we     = `VAC_ARB.we_i;
wire          [15:0] vac_be     = `VAC_ARB.be_i;
wire [4*VRAM_AW-1:0] vac_addr   = `VAC_ARB.addr_i;
wire         [127:0] vac_wdata  = `VAC_ARB.wdata_i;
wire           [3:0] vac_tag    = `VAC_ARB.tag_i;
wire           [3:0] vac_gnt    = `VAC_ARB.gnt_o;
wire           [3:0] vac_rvalid = `VAC_ARB.rvalid_o;
wire                 vac_rtag   = `VAC_ARB.rtag_o;
wire          [31:0] vac_rdata  = `VAC_ARB.rdata_o;

// Reads in flight: a ring indexed by the hclk edge of the grant
reg                  vac_v    [0:7];    // a read granted at that edge
reg            [1:0] vac_id   [0:7];    // ... its requester
reg                  vac_tg   [0:7];    // ... its tag
reg    [VRAM_AW-1:0] vac_a    [0:7];    // ... its word address
reg                  vac_dv   [0:7];    // ... the VRAM model read it (in range)
reg           [31:0] vac_d    [0:7];    // ... the word the model read

integer              vac_n;             // hclk edges out of reset
integer              vac_k;
integer              vac_e;
integer              vac_errors;
integer              vac_age;           // the GPU's losses in a row to the window
integer              vac_rd   [0:3];    // reads checked, per requester
integer              vac_wr   [0:3];    // writes checked, per requester
integer              vac_tag1;          // GPU reads with tag 1
integer              vac_btag1;         // refresh reads with tag 1 (the cursor's)
reg                  vac_bk_pend;       // the refresh slot's request last edge, not granted
reg    [VRAM_AW-1:0] vac_bk_a;          // ... its address
reg                  vac_bk_t;          // ... its tag
reg            [1:0] vac_gi;            // the requester granted
reg            [3:0] vac_exp;           // the grant expected
reg                  vac_urg_bk;
reg                  vac_aged;

initial begin
   vac_n      = 0;
   vac_errors = 0;
   vac_age    = 0;
   vac_tag1   = 0;
   vac_btag1  = 0;
   vac_bk_pend = 1'b0;
   vac_bk_a   = {VRAM_AW{1'b0}};
   vac_bk_t   = 1'b0;
   for (vac_k = 0; vac_k < 8; vac_k = vac_k + 1) begin
      vac_v[vac_k] = 1'b0; vac_id[vac_k] = 2'd0; vac_tg[vac_k] = 1'b0;
      vac_a[vac_k] = {VRAM_AW{1'b0}}; vac_dv[vac_k] = 1'b0; vac_d[vac_k] = 32'h0;
   end
   for (vac_k = 0; vac_k < 4; vac_k = vac_k + 1) begin
      vac_rd[vac_k] = 0; vac_wr[vac_k] = 0;
   end
end

task vac_fail;
   input [64*8-1:0] what;
   input      [1:0] rq;
   input     [31:0] addr;
   input     [31:0] expv;
   input     [31:0] actv;
   begin
      vac_errors = vac_errors + 1;
      error      = error + 1;
      if (vac_errors <= VAC_SHOW)
         $display("ERROR: VRAM arbiter -- %0s: requester %0d word 0x%h expected 0x%h actual 0x%h %t",
                  what, rq, addr, expv, actv, $time);
   end
endtask

always @(posedge hclk)
  if (model_on !== 1'b1) begin
     // Reset: the arbiter's read shift register clears
     for (vac_k = 0; vac_k < 8; vac_k = vac_k + 1) vac_v[vac_k] = 1'b0;
     vac_age = 0;
     vac_bk_pend = 1'b0;
  end else begin
     //------------------------------------------------------------------
     // Reads in flight: the word the model read at the last edge's grant
     // (its read register before this edge), then the read due now
     //------------------------------------------------------------------
     vac_e = (vac_n + 7) % 8;
     if (vac_v[vac_e] && vac_dv[vac_e]) vac_d[vac_e] = vram_rd0;

     vac_e   = (vac_n + 8 - VAC_L) % 8;
     vac_exp = vac_v[vac_e] ? (4'b0001 << vac_id[vac_e]) : 4'b0000;
     if (vac_rvalid !== vac_exp) begin
        if (vac_v[vac_e])
           vac_fail("read data valid not to the read granted L cycles ago", vac_id[vac_e], vac_a[vac_e], vac_exp, vac_rvalid);
        else
           vac_fail("read data valid without a read granted L cycles ago", 2'd0, 32'h0, vac_exp, vac_rvalid);
     end else if (vac_v[vac_e]) begin
        if (((vac_id[vac_e] == VRQ_GPU) || ((vac_id[vac_e] == VRQ_BK) && (CURSOR_EN != 0))) && (vac_rtag !== vac_tg[vac_e]))
           vac_fail("read tag", vac_id[vac_e], vac_a[vac_e], vac_tg[vac_e], vac_rtag);
        if (vac_dv[vac_e] && (vac_rdata !== vac_d[vac_e]))
           vac_fail("read data", vac_id[vac_e], vac_a[vac_e], vac_d[vac_e], vac_rdata);
     end
     vac_v[vac_e] = 1'b0;

     //------------------------------------------------------------------
     // Grants
     //------------------------------------------------------------------
     vac_urg_bk = (vac_req[VRQ_BK] === 1'b1) && (vac_urg[VRQ_BK] === 1'b1);
     vac_aged   = (vac_age == VAC_AGE_MAX);
     if ((^{vac_req, vac_urg, vac_gnt}) === 1'bx)
        vac_fail("request, urgent or grant unknown", 2'd0, 32'h0, {20'h0, vac_req, vac_urg, vac_gnt}, 32'h0);
     else begin
        if ((vac_gnt & (vac_gnt - 4'd1)) != 4'd0)
           vac_fail("more than one grant", 2'd0, 32'h0, 32'h0, vac_gnt);
        if ((vac_gnt & ~vac_req) != 4'd0)
           vac_fail("grant without a request", 2'd0, 32'h0, vac_req, vac_gnt);
        if ((vac_urg & ~vac_req) != 4'd0)
           vac_fail("urgent without its request", 2'd0, 32'h0, vac_req, vac_urg);
        if (vac_age > VAC_AGE_MAX)
           vac_fail("GPU starved past AGE_MAX by the window", VRQ_GPU, 32'h0, VAC_AGE_MAX, vac_age);
        // The grant the classes give: urgent, else the window (unless the
        // GPU lost AGE_MAX cycles in a row to it), else the normal class in
        // index order, else the idle-only requester
        if (vac_urg_bk)                                   vac_exp = VAC_M_BK;
        else if (vac_req[VRQ_WIN] && !vac_aged)           vac_exp = VAC_M_WIN;
        else if (vac_req[VRQ_GPU])                        vac_exp = VAC_M_GPU;
        else if (vac_req[VRQ_BK])                         vac_exp = VAC_M_BK;
        else if (vac_req[VRQ_WIN])                        vac_exp = 4'b0000;   // aged GPU dropped its request: nobody
        else if (vac_req[VRQ_WP])                         vac_exp = VAC_M_WP;
        else                                              vac_exp = 4'b0000;
        if (vac_gnt !== vac_exp)
           vac_fail("grant against the class order", 2'd0, {28'h0, vac_req}, vac_exp, vac_gnt);
        // The GPU's losses in a row to the window (urgent cycles held)
        if ((vac_req[VRQ_GPU] !== 1'b1) || (vac_gnt[VRQ_GPU] === 1'b1)) vac_age = 0;
        else if (vac_gnt[VRQ_WIN] === 1'b1)                              vac_age = vac_age + 1;
     end

     //------------------------------------------------------------------
     // Macro access: the granted requester's
     //------------------------------------------------------------------
     vac_gi = vac_gnt[1] ? 2'd1 : vac_gnt[2] ? 2'd2 : vac_gnt[3] ? 2'd3 : 2'd0;
     if (vram_cen !== ~|vac_gnt)
        vac_fail("macro enable against the grants", vac_gi, vram_addr, ~|vac_gnt, vram_cen);
     vac_v[vac_n % 8] = 1'b0;
     if (|vac_gnt) begin
        if (vram_addr !== vac_addr[vac_gi*VRAM_AW +: VRAM_AW])
           vac_fail("macro address", vac_gi, vac_addr[vac_gi*VRAM_AW +: VRAM_AW], vac_addr[vac_gi*VRAM_AW +: VRAM_AW], vram_addr);
        if (vac_we[vac_gi] === 1'b1) begin
           vac_wr[vac_gi] = vac_wr[vac_gi] + 1;
           if (vac_be[vac_gi*4 +: 4] === 4'h0)
              vac_fail("write without byte enables", vac_gi, vram_addr, 32'hF, vac_be[vac_gi*4 +: 4]);
           if (vram_wen !== ~vac_be[vac_gi*4 +: 4])
              vac_fail("macro write enables", vac_gi, vram_addr, ~vac_be[vac_gi*4 +: 4], vram_wen);
           if (vram_din !== vac_wdata[vac_gi*32 +: 32])
              vac_fail("macro write data", vac_gi, vram_addr, vac_wdata[vac_gi*32 +: 32], vram_din);
        end else begin
           vac_rd[vac_gi] = vac_rd[vac_gi] + 1;
           if (vram_wen !== 4'hF)
              vac_fail("macro write enables on a read", vac_gi, vram_addr, 32'hF, vram_wen);
           if ((vac_gi == VRQ_GPU) && (vac_tag[VRQ_GPU] === 1'b1)) vac_tag1 = vac_tag1 + 1;
           if ((vac_gi == VRQ_BK)  && (vac_tag[VRQ_BK]  === 1'b1)) vac_btag1 = vac_btag1 + 1;
           vac_v[vac_n % 8]  = 1'b1;
           vac_id[vac_n % 8] = vac_gi;
           vac_tg[vac_n % 8] = vac_tag[vac_gi];
           vac_a[vac_n % 8]  = vram_addr;
           vac_dv[vac_n % 8] = ({{(32-VRAM_AW){1'b0}}, vram_addr} < VRAM_WORDS);
        end
     end
     //------------------------------------------------------------------
     // The refresh slot: held until granted while the backend may request
     //------------------------------------------------------------------
     if (vac_bk_pend && (dut.u_core.u_backend.active_dly === 1'b1) &&
         ((vac_req[VRQ_BK] !== 1'b1) || (vac_addr[VRQ_BK*VRAM_AW +: VRAM_AW] !== vac_bk_a) || (vac_tag[VRQ_BK] !== vac_bk_t)))
        vac_fail("refresh request dropped or changed before its grant", VRQ_BK, vac_bk_a,
                 {vac_bk_t, vac_bk_a}, {vac_tag[VRQ_BK], vac_addr[VRQ_BK*VRAM_AW +: VRAM_AW]});
     vac_bk_pend = (vac_req[VRQ_BK] === 1'b1) && (vac_gnt[VRQ_BK] !== 1'b1);
     vac_bk_a    = vac_addr[VRQ_BK*VRAM_AW +: VRAM_AW];
     vac_bk_t    = vac_tag[VRQ_BK];
     vac_n = vac_n + 1;
  end

task vram_arb_check_report;
   begin
      $display("VRAM ARB CHECK: rd win=%0d gpu=%0d bk=%0d wp=%0d wr win=%0d gpu=%0d gpu_tag1=%0d bk_tag1=%0d lat=%0d errors=%0d",
               vac_rd[VRQ_WIN], vac_rd[VRQ_GPU], vac_rd[VRQ_BK], vac_rd[VRQ_WP],
               vac_wr[VRQ_WIN], vac_wr[VRQ_GPU], vac_tag1, vac_btag1, VAC_L, vac_errors);
   end
endtask
