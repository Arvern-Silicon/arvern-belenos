//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_vram_arb
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_vram_arb.v
// Module Description : Video-memory arbiter: RQ_N requesters on one single-port
//                      32-bit macro. Each requester is one slot of packed
//                      vectors (req, urgent, we, be, addr, wdata in; gnt,
//                      rvalid out), and belongs to one class:
//                        - urgent-capable (URG_MASK): with urgent set it takes
//                          the cycle over everyone; otherwise normal;
//                        - host (HOST_MASK): the AHB window (one member: no
//                          round-robin state);
//                        - normal: every requester in no other class, served
//                          after the host class;
//                        - idle-only (IDLE_MASK): a cycle nobody else asks for.
//                      In a class the lower index goes first. Belenos map:
//                      urgent refresh > window > GPU > refresh > window read
//                      ahead. The normal requester AGE_IDX (the GPU) that has
//                      lost AGE_MAX cycles in a row to the host class takes the
//                      next one. Read data comes RD_LAT cycles after the grant
//                      (the macro's latency), one more with RD_REG_EN (the
//                      data registered here): one shift register follows every
//                      read granted with its requester index and tag, and gives
//                      the requester its read data valid (rvalid_o, rtag_o),
//                      and the next cycle's (rvalid_nxt_o).
//
//                      Invariants:
//                        - the host grant depends only on the host requests,
//                          the urgent inputs and the aging flop: never on a
//                          normal or idle-only request, never on an address
//                          compare. The window's request and the refresh's
//                          urgent are decoded from flops (pb_match and the
//                          fetch's need_fetch are precomputed, and the
//                          refresh requests on its active_dly flop, not on
//                          the driver's refresh_active input), so the host
//                          grant comes from flops only (a memory adapter
//                          keeps it so: a ready input ANDed into the grants
//                          must be a flop); the window takes it, and the read
//                          valids (rvalid_nxt_o one cycle ahead), into flops
//                          only: its AHB response does not depend on them in
//                          the same cycle;
//                        - an urgent input is set only while its request is;
//                        - the aging counter never wraps: at AGE_MAX the host
//                          class is blocked, so no further loss is counted.
//                      Known exceptions: the GPU's request and write flag
//                      pass a same-cycle read-ahead word-address compare in
//                      blns_gpu_px, and the window read ahead's request one in
//                      blns_ahb_vram (on_next); both reach the normal and
//                      idle-only grants, never the host grant.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_vram_arb #(
    parameter                    VRAM_AW      = 16,       // VRAM word-address width
    parameter                    RQ_N         = 4,        // requesters
    parameter         [RQ_N-1:0] RQ_EN        = 4'b1111,  // requester built (its read data valid decoded)
    parameter         [RQ_N-1:0] URG_MASK     = 4'b0100,  // urgent-capable (Belenos: the refresh)
    parameter         [RQ_N-1:0] HOST_MASK    = 4'b0001,  // host class (Belenos: the window)
    parameter         [RQ_N-1:0] IDLE_MASK    = 4'b1000,  // idle-only (Belenos: the window read ahead)
    parameter                    AGE_IDX      = 1,        // normal requester aged against the host class (Belenos: the GPU)
    parameter                    AGE_MAX      = 7,        // its losses in a row before it takes the next cycle (>= 1)
    parameter         [RQ_N-1:0] TAG_MASK     = 4'b0010,  // requester with a tag returned with its read data (Belenos: the GPU)
    parameter                    RD_LAT       = 1,        // macro read latency: data RD_LAT cycles after the access (1-3)
    parameter                    RD_REG_EN    = 0,        // read data registered here: valid one cycle later
    parameter                    ASYNC_RST_EN = 1'b1      // 1=async active-low reset, 0=synchronous reset
) (
    input  wire                    hclk_i,                // clock
    input  wire                    hresetn_i,             // active-low reset

// Requesters (slot i of each vector = requester i)
    input  wire         [RQ_N-1:0] req_i,                 // request (held until granted)
    input  wire         [RQ_N-1:0] urgent_i,              // urgent priority (urgent-capable only, with req_i)
    input  wire         [RQ_N-1:0] we_i,                  // 1 = write
    input  wire       [4*RQ_N-1:0] be_i,                  // byte enables
    input  wire [VRAM_AW*RQ_N-1:0] addr_i,                // word address
    input  wire      [32*RQ_N-1:0] wdata_i,               // write data
    input  wire         [RQ_N-1:0] tag_i,                 // read tag (TAG_MASK only), returned with the read data
    output wire         [RQ_N-1:0] gnt_o,                 // grant
    output wire         [RQ_N-1:0] rvalid_o,              // read data valid (in grant order)
    output wire         [RQ_N-1:0] rvalid_nxt_o,          // next cycle's rvalid_o
    output wire                    rtag_o,                // the returning read's tag (with rvalid_o)
    output wire             [31:0] rdata_o,               // read data (with rvalid_o)
    output wire                    rd_pend_o,             // a read granted and its data not yet returned

// VRAM macro
    output wire                    vram_cen_o,            // chip enable (active low)
    output wire              [3:0] vram_wen_o,            // byte write enables (active low)
    output wire      [VRAM_AW-1:0] vram_addr_o,           // word address
    output wire             [31:0] vram_din_o,            // write data
    input  wire             [31:0] vram_dout_i            // read data (RD_LAT cycles after the access)
);

localparam        [RQ_N-1:0] NRM_MASK = ~(HOST_MASK | IDLE_MASK);   // normal: no other class

// pragma translate_off
generate
    if (((HOST_MASK & IDLE_MASK) != {RQ_N{1'b0}}) || ((URG_MASK & ~NRM_MASK) != {RQ_N{1'b0}})) begin : CHECK_MASKS
        initial $fatal(1, "blns_vram_arb: HOST_MASK and IDLE_MASK must be disjoint and URG_MASK inside the normal class.");
    end
    if ((HOST_MASK & (HOST_MASK - 1'b1)) != {RQ_N{1'b0}}) begin : CHECK_HOST
        initial $fatal(1, "blns_vram_arb: the host class has one member at most.");
    end
    if ((AGE_IDX < 0) || (AGE_IDX >= RQ_N) || ((RQ_EN[AGE_IDX] != 1'b0) && (NRM_MASK[AGE_IDX] == 1'b0))) begin : CHECK_AGE_IDX
        initial $fatal(1, "blns_vram_arb: AGE_IDX (%0d) must be a requester of the normal class.", AGE_IDX);
    end
    if ((RD_LAT < 1) || (RD_LAT > 3) || ((RD_REG_EN != 0) && (RD_REG_EN != 1))) begin : CHECK_RD_LAT
        initial $fatal(1, "blns_vram_arb: RD_LAT (%0d) must be 1..3 and RD_REG_EN (%0d) 0 or 1.", RD_LAT, RD_REG_EN);
    end
endgenerate
// pragma translate_on
localparam                   AGE_W    = (AGE_MAX < 4) ? 2 : $clog2(AGE_MAX + 1);    // 2 bits at least: no empty replication
localparam                   RD_L     = RD_LAT + RD_REG_EN;                         // read latency seen by the requesters
localparam                   ID_W     = (RQ_N > 2) ? $clog2(RQ_N) : 1;              // requester index width


//=============================================================================
// 1)  GRANT
//=============================================================================

// Urgent requests; the host class yields to the urgent inputs themselves (set
// only with their request, both from flops), so its grant does not depend on
// the urgent requester's word-address compare
wire         [RQ_N-1:0] urg_req   =  req_i & urgent_i & URG_MASK;
wire                    urg_any   = |urg_req;
wire                    urg_blk   = |(urgent_i & URG_MASK);
// (urgent_i and tag_i outside URG_MASK and TAG_MASK: not read)
wire       [2*RQ_N-1:0] mask_unused = {urgent_i & ~URG_MASK, tag_i & ~TAG_MASK};
wire                    host_req  = |(req_i & HOST_MASK);
wire                    busy      = |(req_i & ~IDLE_MASK);           // an idle-only request waits

// Starvation bound (registered, so the host grant does not depend on the aged
// request): the cycle after the aged requester's AGE_MAX-th loss to the host
// class in a row, the urgent cycles in between not counted
wire                    age_first;

wire                    host_ok   = ~urg_blk & ~age_first;
wire                    nrm_ok    = ~urg_any & (~host_req | age_first);

genvar gi;
generate
    for (gi = 0; gi < RQ_N; gi = gi + 1) begin : g_gnt
        // Requesters ahead in the same class: the lower indices
        localparam [RQ_N-1:0] AHEAD = ~({RQ_N{1'b1}} << gi);
        wire       urg_gnt  = urg_req[gi]                       & ~|(urg_req           & AHEAD);
        wire       host_gnt = HOST_MASK[gi] & req_i[gi] & host_ok & ~|(req_i & HOST_MASK & AHEAD);
        wire       nrm_gnt  = NRM_MASK[gi]  & req_i[gi] & nrm_ok  & ~|(req_i & NRM_MASK  & AHEAD);
        wire       idle_gnt = IDLE_MASK[gi] & req_i[gi] & ~busy   & ~|(req_i & IDLE_MASK & AHEAD);
        assign gnt_o[gi] = urg_gnt | host_gnt | nrm_gnt | idle_gnt;
    end

    if ((RQ_EN[AGE_IDX] != 1'b0) && (AGE_MAX != 0)) begin : G_AGE
        wire  [AGE_W-1:0] age_wait;
        // Priority: a loss to the host class (count) > an urgent cycle (hold) >
        // a grant or no request (clear). At AGE_MAX the host class is blocked:
        // no loss.
        wire              age_lost     = req_i[AGE_IDX] & (|(gnt_o & HOST_MASK));
        wire              age_clr      = ~req_i[AGE_IDX] | gnt_o[AGE_IDX];
        wire              age_wait_en  = age_lost | (age_clr & (age_wait != {AGE_W{1'b0}}));
        wire  [AGE_W-1:0] age_wait_nxt = age_lost ? (age_wait + {{(AGE_W-1){1'b0}}, 1'b1}) : {AGE_W{1'b0}};
        arv_ipdff #(.WIDTH(AGE_W), .ARST_EN(ASYNC_RST_EN)) u_age_wait (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(age_wait_en), .d_i(age_wait_nxt), .q_o(age_wait));
        assign age_first = (age_wait == AGE_MAX[AGE_W-1:0]);
    end else begin : G_NO_AGE
        assign age_first = 1'b0;
    end
endgenerate


//=============================================================================
// 2)  MACRO ACCESS
//=============================================================================

// One grant at most, so each macro control is a flat AND-OR of the grants:
// per output bit, the grants ANDed with that bit of every requester, then one
// OR (no chain over the requesters). The write byte enables are masked with
// the requester's write flag before the mux, so the grants are the only late
// term. The chip enable uses the class grants, one level from the requests.
wire         [RQ_N-1:0] wbe_col [0:3];                       // per byte: each requester's write enable
wire         [RQ_N-1:0] addr_col[0:VRAM_AW-1];               // per address bit: each requester's bit
wire         [RQ_N-1:0] din_col [0:31];                      // per data bit: each requester's bit

genvar bi;
generate
    for (gi = 0; gi < RQ_N; gi = gi + 1) begin : g_col
        for (bi = 0; bi < 4; bi = bi + 1) begin : g_be
            assign wbe_col[bi][gi]  = we_i[gi] & be_i[gi*4 + bi];
        end
        for (bi = 0; bi < VRAM_AW; bi = bi + 1) begin : g_addr
            assign addr_col[bi][gi] = addr_i[gi*VRAM_AW + bi];
        end
        for (bi = 0; bi < 32; bi = bi + 1) begin : g_din
            assign din_col[bi][gi]  = wdata_i[gi*32 + bi];
        end
    end

    for (bi = 0; bi < 4; bi = bi + 1) begin : g_wen
        assign vram_wen_o[bi]  = ~(|(gnt_o & wbe_col[bi]));
    end
    for (bi = 0; bi < VRAM_AW; bi = bi + 1) begin : g_vaddr
        assign vram_addr_o[bi] =   |(gnt_o & addr_col[bi]);
    end
    for (bi = 0; bi < 32; bi = bi + 1) begin : g_vdin
        assign vram_din_o[bi]  =   |(gnt_o & din_col[bi]);
    end
endgenerate

// A grant in some class: the first requester of a class is granted when the
// class is
wire                    any_gnt     = urg_any                              |
                                      (host_req                & host_ok) |
                                      ((|(req_i & NRM_MASK))   & nrm_ok)  |
                                      ((|(req_i & IDLE_MASK))  & ~busy);
assign                  vram_cen_o  = ~any_gnt;


//=============================================================================
// 3)  READ RETURN (RD_LAT cycles after a read grant, one more with RD_REG_EN)
//=============================================================================

// One shift register, a stage per cycle of read latency, follows every read
// granted: valid, requester index (encoded) and tag. The macro delivers a
// read's data as it leaves stage RD_LAT-1 (rd_mac): the data register takes it
// there with RD_REG_EN. The requester takes it as it leaves the last stage.
// Reads return in grant order; a memory whose latency is not fixed would make
// this register a FIFO, popped by the memory's own read data valid.
wire         [RQ_N-1:0] rd_gnt  = gnt_o & ~we_i & RQ_EN;
wire         [ID_W-1:0] rd_idx  [0:RQ_N];
assign rd_idx[0] = {ID_W{1'b0}};

wire         [RD_L-1:0] rd_v;                                // stage valid
wire    [RD_L*ID_W-1:0] rd_id;                               // ... its requester
wire         [RD_L-1:0] rd_tag;                              // ... its tag
wire                    rd_mac;                              // the macro delivers read data

genvar si;
generate
    for (gi = 0; gi < RQ_N; gi = gi + 1) begin : g_idx
        localparam [ID_W-1:0] IDX = gi;
        assign rd_idx[gi+1] = rd_idx[gi] | ({ID_W{rd_gnt[gi]}} & IDX);
    end

    for (si = 0; si < RD_L; si = si + 1) begin : g_rd
        // Stage 0 takes the read granted, every other the stage before; the
        // index and tag load only with a valid
        wire            v_in;
        wire [ID_W-1:0] id_in;
        wire            tag_in;
        if (si == 0) begin : G_GNT
            assign v_in   = |rd_gnt;
            assign id_in  =  rd_idx[RQ_N];
            assign tag_in = |(rd_gnt & tag_i & TAG_MASK);
        end else begin : G_SHIFT
            assign v_in   =  rd_v[si-1];
            assign id_in  =  rd_id[(si-1)*ID_W +: ID_W];
            assign tag_in =  rd_tag[si-1];
        end
        arv_ipdff #(.WIDTH(1),    .ARST_EN(ASYNC_RST_EN)) u_rd_v (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(v_in),   .q_o(rd_v[si]));
        arv_ipdff #(.WIDTH(ID_W), .ARST_EN(ASYNC_RST_EN)) u_rd_id (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(v_in), .d_i(id_in),  .q_o(rd_id[si*ID_W +: ID_W]));
        if (TAG_MASK != {RQ_N{1'b0}}) begin : G_TAG
            arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_tag (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(v_in), .d_i(tag_in), .q_o(rd_tag[si]));
        end else begin : G_NO_TAG
            assign rd_tag[si] = 1'b0;
            wire   tag_in_unused = tag_in;
        end
    end

    // Read data valid: the last stage, decoded per requester built
    for (gi = 0; gi < RQ_N; gi = gi + 1) begin : g_rv
        localparam [ID_W-1:0] IDX = gi;
        if (RQ_EN[gi] != 1'b0) begin : G_RV
            assign rvalid_o[gi] = rd_v[RD_L-1] & (rd_id[(RD_L-1)*ID_W +: ID_W] == IDX);
        end else begin : G_NO_RV
            assign rvalid_o[gi] = 1'b0;
        end
    end

    // The same one cycle ahead, for a requester's registered response (the
    // window's HREADYOUT): the stage before the last, or the read grant
    // itself with a latency of one
    for (gi = 0; gi < RQ_N; gi = gi + 1) begin : g_rvn
        localparam [ID_W-1:0] IDX = gi;
        if (RQ_EN[gi] == 1'b0) begin : G_NO_RVN
            assign rvalid_nxt_o[gi] = 1'b0;
        end else if (RD_L > 1) begin : G_RVN
            assign rvalid_nxt_o[gi] = rd_v[RD_L-2] & (rd_id[(RD_L-2)*ID_W +: ID_W] == IDX);
        end else begin : G_RVN_GNT
            assign rvalid_nxt_o[gi] = rd_gnt[gi];
        end
    end

    // Read data: as the macro delivers it, or registered when it does
    assign rd_mac = rd_v[RD_LAT-1];
    if (RD_REG_EN != 0) begin : G_RD_REG
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_rdata (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rd_mac), .d_i(vram_dout_i), .q_o(rdata_o));
    end else begin : G_NO_RD_REG
        assign rdata_o = vram_dout_i;
        wire   rd_mac_unused = rd_mac;                         // the last stage's valid already
    end
endgenerate

assign                  rtag_o      = rd_tag[RD_L-1];

// Reads in flight: the clock must run until each returns (the macro may be
// on the free-running clock, so its data does not wait for the gated one)
assign                  rd_pend_o   = |rd_v;

endmodule // blns_vram_arb

`default_nettype wire
