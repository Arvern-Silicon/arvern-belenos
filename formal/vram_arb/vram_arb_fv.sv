//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    vram_arb_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of blns_vram_arb with the Belenos requester map
// (belenos_core.v): 0 window (host), 1 GPU (normal, aged, tagged), 2 refresh
// (urgent-capable, else normal; tagged with the cursor, BK_TAG), 3 window
// read ahead (idle-only).
//
// Environment (the arbiter's port rules, assumed):
//   - a request is held until granted ("req_i: held until granted");
//   - urgent only on the urgent-capable slot, and only with its request;
//   - a slot that is not built (RQ_EN) never requests;
//   - no request while the reset is asserted (every requester shares it).
// Every other input (write flag, byte enables, address, data, tag, the
// macro's read data, the reset) is free in every cycle.
//
// The reference model is black-box, written from the documented policy
// (doc/integration_guide.md "VRAM arbitration", the module header): it
// counts the GPU's losses to the window itself, follows every read granted
// through its own shift register of the read latency, and samples the
// macro's read data RD_LAT cycles after the grant.
//----------------------------------------------------------------------------
`default_nettype none
module vram_arb_fv #(
    parameter RD_LAT       = 1,
    parameter RD_REG_EN    = 0,
    parameter GPU_EN       = 1,
    parameter BK_TAG       = 1,
    parameter ASYNC_RST_EN = 1
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire    [3:0] req,
    input  wire    [3:0] urgent,
    input  wire    [3:0] we,
    input  wire   [15:0] be,
    input  wire   [11:0] addr,
    input  wire  [127:0] wdata,
    input  wire    [3:0] tag,
    input  wire   [31:0] dout
);

localparam       AW       = 3;
localparam       AGE_MAX  = 7;
localparam       RD_L     = RD_LAT + RD_REG_EN;
localparam [3:0] RQ_EN    = (GPU_EN != 0) ? 4'b1111 : 4'b1101;
localparam [3:0] URG_MASK = 4'b0100;
localparam [3:0] TAG_MASK = RQ_EN & ((BK_TAG != 0) ? 4'b0110 : 4'b0010);
localparam       WIN = 0, GPU = 1, BK = 2, WP = 3;

wire       [3:0] gnt;
wire       [3:0] rvalid;
wire       [3:0] rvalid_nxt;
reg        [3:0] rvalid_nxt_q = 4'b0000;    // rvalid_nxt_o, one cycle later
always @(posedge clk)
    rvalid_nxt_q <= rst_n ? rvalid_nxt : 4'b0000;
wire             rtag;
wire      [31:0] rdata;
wire             rd_pend;
wire             cen;
wire       [3:0] wen;
wire    [AW-1:0] maddr;
wire      [31:0] din;

blns_vram_arb #(
    .VRAM_AW      ( AW           ),
    .RQ_N         ( 4            ),
    .RQ_EN        ( RQ_EN        ),
    .URG_MASK     ( URG_MASK     ),
    .HOST_MASK    ( 4'b0001      ),
    .IDLE_MASK    ( 4'b1000      ),
    .AGE_IDX      ( GPU          ),
    .AGE_MAX      ( AGE_MAX      ),
    .TAG_MASK     ( TAG_MASK     ),
    .RD_LAT       ( RD_LAT       ),
    .RD_REG_EN    ( RD_REG_EN    ),
    .ASYNC_RST_EN ( ASYNC_RST_EN )
) u_dut (
    .hclk_i       ( clk     ),
    .hresetn_i    ( rst_n   ),
    .req_i        ( req     ),
    .urgent_i     ( urgent  ),
    .we_i         ( we      ),
    .be_i         ( be      ),
    .addr_i       ( addr    ),
    .wdata_i      ( wdata   ),
    .tag_i        ( tag     ),
    .gnt_o        ( gnt     ),
    .rvalid_o     ( rvalid  ),
    .rvalid_nxt_o ( rvalid_nxt ),
    .rtag_o       ( rtag    ),
    .rdata_o      ( rdata   ),
    .rd_pend_o    ( rd_pend ),
    .vram_cen_o   ( cen     ),
    .vram_wen_o   ( wen     ),
    .vram_addr_o  ( maddr   ),
    .vram_din_o   ( din     ),
    .vram_dout_i  ( dout    )
);

// White-box probe (connected by the driver): the arbiter's lost-cycle counter
wire       [2:0] p_age_wait;

//=============================================================================
// ENVIRONMENT
//=============================================================================
reg              past_ok = 1'b0;          // a cycle out of reset before this one
always @(posedge clk) past_ok <= rst_n;

always @(*) begin
    if ($initstate) assume (!rst_n);
    assume ((urgent & ~URG_MASK) == 4'b0000);
    assume ((urgent & ~req) == 4'b0000);
    assume ((req & ~RQ_EN) == 4'b0000);
    if (!rst_n) assume (req == 4'b0000);
end

reg        [3:0] req_q = 4'b0000;           // last cycle's requests not granted
always @(posedge clk) req_q <= rst_n ? (req & ~gnt) : 4'b0000;

always @(*)
    if (rst_n) assume ((req_q & ~req) == 4'b0000);

//=============================================================================
// REFERENCE MODEL
//=============================================================================
wire             urg     = req[BK] & urgent[BK];        // an urgent refresh this cycle
wire       [3:0] rd_gnt  = gnt & ~we & RQ_EN;           // a read granted

// GPU losses to the window in a row (urgent cycles hold the count)
reg        [3:0] lost;
// Cycles each requester has waited, urgent cycles not counted
reg        [3:0] gpu_wait;
reg        [3:0] win_wait;
// Every read granted: valid, requester, tag (stage k = granted k+1 cycles ago)
reg   [RD_L-1:0] h_v;
reg [2*RD_L-1:0] h_id;
reg   [RD_L-1:0] h_tag;
reg       [31:0] h_data;                                 // the macro's data of the read at stage RD_LAT-1

wire       [1:0] g_id    = rd_gnt[1] ? 2'd1 : rd_gnt[2] ? 2'd2 : rd_gnt[3] ? 2'd3 : 2'd0;

always @(posedge clk) begin
    if (!rst_n) begin
        lost     <= 4'd0;
        gpu_wait <= 4'd0;
        win_wait <= 4'd0;
        h_v      <= {RD_L{1'b0}};
    end else begin
        lost     <= (~req[GPU] | gnt[GPU]) ? 4'd0 : gnt[WIN] ? lost + 4'd1 : lost;
        gpu_wait <= (~req[GPU] | gnt[GPU]) ? 4'd0 : urg ? gpu_wait : gpu_wait + 4'd1;
        win_wait <= (~req[WIN] | gnt[WIN]) ? 4'd0 : urg ? win_wait : win_wait + 4'd1;
        h_v      <= {h_v, |rd_gnt};
    end
    h_id  <= {h_id, g_id};
    h_tag <= {h_tag, |(rd_gnt & tag & TAG_MASK)};
    if (h_v[RD_LAT-1]) h_data <= dout;
end

wire             l_v     = h_v[RD_L-1];
wire       [1:0] l_id    = h_id[2*RD_L-1 -: 2];
wire       [3:0] l_hot   = l_v ? ((4'b0001 << l_id) & RQ_EN) : 4'b0000;

//=============================================================================
// PROPERTIES
//=============================================================================
always @(*) begin
    if (rst_n) begin
        // Grants
        a_onehot:       assert ((gnt & (gnt - 4'd1)) == 4'b0000);
        a_gnt_req:      assert ((gnt & ~req) == 4'b0000);
        a_work:         assert ((req == 4'b0000) || (gnt != 4'b0000));
        // Priority: urgent refresh > window > GPU > refresh > read ahead, the
        // GPU taking the cycle after AGE_MAX losses in a row to the window
        a_urgent:       assert (!urg || gnt[BK]);
        a_win:          assert (!(req[WIN] && !urg && !(req[GPU] && lost == AGE_MAX)) || gnt[WIN]);
        a_gpu_aged:     assert (!(req[GPU] && !urg && lost == AGE_MAX) || gnt[GPU]);
        a_gpu_normal:   assert (!(req[GPU] && !urg && !req[WIN]) || gnt[GPU]);
        a_bk_normal:    assert (!(req[BK] && !req[WIN] && !req[GPU]) || gnt[BK]);
        a_idle_only:    assert (gnt[WP] == (req[WP] && (req[2:0] == 3'b000)));
        // Starvation bounds, in cycles without an urgent refresh: the GPU waits
        // at most AGE_MAX, the window at most 1 (the GPU's aged cycle)
        a_gpu_starve:   assert (gpu_wait <= AGE_MAX);
        a_win_starve:   assert (win_wait <= 1);
        a_lost_bound:   assert (lost <= AGE_MAX);
        // Macro access: the granted requester's
        a_cen:          assert (cen == (gnt == 4'b0000));
        if (gnt[WIN]) a_mux_win: assert (maddr == addr[0*AW +: AW] && din == wdata[0*32 +: 32] &&
                                         wen == ~(be[0*4 +: 4] & {4{we[WIN]}}));
        if (gnt[GPU]) a_mux_gpu: assert (maddr == addr[1*AW +: AW] && din == wdata[1*32 +: 32] &&
                                         wen == ~(be[1*4 +: 4] & {4{we[GPU]}}));
        if (gnt[BK])  a_mux_bk:  assert (maddr == addr[2*AW +: AW] && din == wdata[2*32 +: 32] &&
                                         wen == ~(be[2*4 +: 4] & {4{we[BK]}}));
        if (gnt[WP])  a_mux_wp:  assert (maddr == addr[3*AW +: AW] && din == wdata[3*32 +: 32] &&
                                         wen == ~(be[3*4 +: 4] & {4{we[WP]}}));
        if (gnt == 4'b0000) a_idle: assert (wen == 4'hF);
        // Read return: RD_LAT + RD_REG_EN cycles after the grant, to the
        // requester granted, with its tag and the macro's data
        a_rvalid:       assert (rvalid == l_hot);
        // ... announced one cycle ahead
        a_rvalid_nxt:   assert (rvalid == rvalid_nxt_q);
        if (l_v && TAG_MASK != 4'b0000) a_rtag: assert (rtag == h_tag[RD_L-1]);
        if (l_v && RD_REG_EN != 0)      a_rdata_reg: assert (rdata == h_data);
        if (l_v && RD_REG_EN == 0)      a_rdata:     assert (rdata == dout);
        // Read in flight: granted in cycles t-RD_L .. t-1 (0 in the grant
        // cycle itself, 1 in the cycle its data returns)
        a_rd_pend:      assert (rd_pend == (h_v != {RD_L{1'b0}}));
        // White-box link (helps the induction): the arbiter's counter is the
        // model's count of losses
        if (GPU_EN != 0) a_age_link: assert ({1'b0, p_age_wait} == lost);
    end
end

// Lost-count invariants of the model (induction strengthening)
always @(*)
    if (rst_n) begin
        a_wait_link:  assert (gpu_wait == lost);
        if (!req[GPU]) h_lost_idle: assert (lost == 4'd0);
        if (win_wait != 4'd0) h_win_link: assert (lost == 4'd0);   // the window waits only the GPU's aged cycle
    end

//=============================================================================
// COVERS: every antecedent above is reachable
//=============================================================================
always @(posedge clk)
    if (rst_n && past_ok) begin
        c_rv_win:     cover (rvalid[WIN]);
        c_rv_bk:      cover (rvalid[BK]);
        c_rv_wp:      cover (rvalid[WP]);
        c_rv_back:    cover (l_v && h_v[0] && h_v[RD_L-1]);
        c_urgent:     cover (urg && req[WIN] && gnt[BK]);
        if (BK_TAG != 0)
            c_rv_bk_tag:  cover (rvalid[BK] && rtag);
        if (GPU_EN != 0) begin
            c_win_wait:   cover (win_wait == 1);
            c_rv_gpu_tag: cover (rvalid[GPU] && rtag);
            c_gpu_aged:   cover (req[GPU] && lost == AGE_MAX && req[WIN] && gnt[GPU]);
            c_gpu_urgent: cover (req[GPU] && lost == AGE_MAX && urg);
        end
    end

endmodule

`default_nettype wire
