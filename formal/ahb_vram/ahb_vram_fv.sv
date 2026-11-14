//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    ahb_vram_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of the VRAM window (blns_ahb_vram): its read-ahead buffer,
// its posted write and its registered response, behind the real arbiter
// (blns_vram_arb, the Belenos requester map), with
// a free GPU (reads and writes, held until granted, its writes snooped as
// in belenos_core) and a free refresh (reads, urgent or not), an AHB-Lite
// manager with free transfers (address and control held while HREADY is
// low), and a VRAM macro of fixed latency modelled for one word: the solver
// picks the address A (a constant), the model keeps that word's content
// (written by every granted write to A with its byte enables) and returns
// it RD_LAT cycles after a read of A; other words read as free data.
//
// Properties:
//   - coherence (the dm_stale / pb_whit rules, the posted write): an AHB read
//     of A that completes OKAY, with no GPU write to A between its address
//     phase and its completion, returns A's content as the bus has written
//     it: the VRAM's, with the window's posted write over it, whether it is
//     served by the read-ahead buffer (no wait state), a read ahead in flight
//     or a demand read;
//   - writes: every window write that completes reaches the macro once, in
//     order, with its address, byte enables and data, either in its data
//     phase or as the posted write; wb_pend_o is set exactly while one is
//     posted, wb_pend_nxt_o is its next state;
//   - response: HREADYOUT equals the ready decoded from the same cycle's
//     state; idle cycles (also the first out of reset) are OKAY with no wait
//     state; an ERROR is two cycles (HREADYOUT low then high, HRESP high in
//     both); a transfer the refresh does not hold off completes within
//     2 x RD_L + 4 cycles;
//   - structural (the driver's comb_free step): HREADYOUT, HRESP and HRDATA
//     have no harness input in their combinational cone.
//----------------------------------------------------------------------------
`default_nettype none
module ahb_vram_fv #(
    parameter RD_LAT    = 1,
    parameter RD_REG_EN = 0,
    parameter WORDS     = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    // AHB manager
    input  wire        hsel,
    input  wire  [4:0] haddr,
    input  wire  [1:0] htrans,
    input  wire        hwrite,
    input  wire  [2:0] hsize,
    input  wire [31:0] hwdata,
    // GPU and refresh requesters
    input  wire        g_req,
    input  wire        g_we,
    input  wire  [3:0] g_be,
    input  wire  [2:0] g_addr,
    input  wire [31:0] g_wdata,
    input  wire        r_req,
    input  wire        r_urg,
    input  wire  [2:0] r_addr,
    input  wire [31:0] other_data                   // read data of the other words
);

localparam AW   = 3;
localparam RD_L = RD_LAT + RD_REG_EN;

(* anyconst *) wire [AW-1:0] A;                     // the tracked word

wire [31:0] hrdata;
wire        hreadyout, hresp, active;
wire        w_req, w_we, wp_req;
wire  [3:0] w_be;
wire [AW-1:0] w_addr, wp_addr;
wire [31:0] w_wdata;
wire  [3:0] gnt, rvalid;
wire        rtag;
wire [31:0] rdata;
wire        rd_pend, cen;
wire  [3:0] wen;
wire [AW-1:0] maddr;
wire [31:0] din;
wire [31:0] dout;
wire        mwr = gnt[1] & g_we & (|g_be);

wire  [3:0] rvalid_nxt;
wire        wb_pend, wb_pend_nxt;

blns_ahb_vram #(.VRAM_AW(AW), .VRAM_WORDS(WORDS), .PRIV_CHECK_EN(0), .RD_REG_EN(RD_REG_EN), .ASYNC_RST_EN(1)) u_win (
    .hclk_i(clk), .hresetn_i(rst_n), .hsel_i(hsel), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
    .hsize_i(hsize), .hprot_i(4'b0011), .hsmode_i(1'b0), .hready_i(hreadyout), .hwdata_i(hwdata),
    .hrdata_o(hrdata), .hreadyout_o(hreadyout), .hresp_o(hresp), .active_o(active),
    .wb_pend_o(wb_pend), .wb_pend_nxt_o(wb_pend_nxt),
    .vreq_o(w_req), .vwe_o(w_we), .vbe_o(w_be), .vaddr_o(w_addr), .vwdata_o(w_wdata),
    .vgnt_i(gnt[0]), .vrvalid_i(rvalid[0]), .vrvalid_nxt_i(rvalid_nxt[0]), .vrdata_i(rdata),
    .wp_vreq_o(wp_req), .wp_vaddr_o(wp_addr), .wp_vgnt_i(gnt[3]), .wp_vrvalid_i(rvalid[3]),
    .wp_vrvalid_nxt_i(rvalid_nxt[3]), .mwr_i(mwr), .mwaddr_i(g_addr));

blns_vram_arb #(
    .VRAM_AW(AW), .RQ_N(4), .RQ_EN(4'b1111), .URG_MASK(4'b0100), .HOST_MASK(4'b0001), .IDLE_MASK(4'b1000),
    .AGE_IDX(1), .AGE_MAX(7), .TAG_MASK(4'b0010), .RD_LAT(RD_LAT), .RD_REG_EN(RD_REG_EN), .ASYNC_RST_EN(1)
) u_arb (
    .hclk_i(clk), .hresetn_i(rst_n),
    .req_i({wp_req, r_req, g_req, w_req}), .urgent_i({1'b0, r_urg & r_req, 2'b00}),
    .we_i({1'b0, 1'b0, g_we, w_we}), .be_i({4'h0, 4'h0, g_be, w_be}),
    .addr_i({wp_addr, r_addr, g_addr, w_addr}), .wdata_i({32'h0, 32'h0, g_wdata, w_wdata}),
    .tag_i(4'b0000), .gnt_o(gnt), .rvalid_o(rvalid), .rvalid_nxt_o(rvalid_nxt), .rtag_o(rtag), .rdata_o(rdata), .rd_pend_o(rd_pend),
    .vram_cen_o(cen), .vram_wen_o(wen), .vram_addr_o(maddr), .vram_din_o(din), .vram_dout_i(dout));

//=============================================================================
// ENVIRONMENT
//=============================================================================
reg        rst_q = 1'b0;
reg        g_pend, r_pend;                       // a request not yet granted
reg        hold_q;                               // the AHB address phase is held
reg  [4:0] haddr_q;
reg  [1:0] htrans_q;
reg        hsel_q, hwrite_q;
reg  [2:0] hsize_q;
reg  [2:0] g_addr_q;
reg        g_we_q;
reg  [3:0] g_be_q;
reg [31:0] g_wdata_q;

always @(posedge clk) begin
    rst_q     <= rst_n;
    g_pend    <= rst_n & g_req & ~gnt[1];
    r_pend    <= rst_n & r_req & ~gnt[2];
    hold_q    <= rst_n & ~hreadyout;
    haddr_q   <= haddr;  htrans_q <= htrans; hsel_q <= hsel; hwrite_q <= hwrite; hsize_q <= hsize;
    g_addr_q  <= g_addr; g_we_q <= g_we; g_be_q <= g_be; g_wdata_q <= g_wdata;
end

always @(*) begin
    if ($initstate) assume (!rst_n);
    else            assume (rst_n);
    // Requests held until granted, with their access
    if (g_pend) assume (g_req && g_addr == g_addr_q && g_we == g_we_q && g_be == g_be_q && g_wdata == g_wdata_q);
    if (r_pend) assume (r_req);
    // AHB-Lite: the address phase is held while HREADY is low
    if (hold_q) assume (hsel == hsel_q && htrans == htrans_q && haddr == haddr_q &&
                        hwrite == hwrite_q && hsize == hsize_q);
end

//=============================================================================
// VRAM MODEL (one word)
//=============================================================================
reg [31:0] mem_a;                                // content of word A (free at reset: VRAM is not reset)
reg [RD_LAT-1:0] rd_a;                           // a read of A, per cycle of latency
reg [32*RD_LAT-1:0] rd_v;                        // ... the content it read
wire       m_wr  = !cen && (wen != 4'hF);
wire       m_rd  = !cen && (wen == 4'hF);
wire [31:0] mem_nxt = { wen[3] ? mem_a[31:24] : din[31:24], wen[2] ? mem_a[23:16] : din[23:16],
                        wen[1] ? mem_a[15:8]  : din[15:8],  wen[0] ? mem_a[7:0]   : din[7:0] };

always @(posedge clk) begin
    if (m_wr && maddr == A) mem_a <= mem_nxt;
    rd_a <= {rd_a, m_rd && maddr == A};
    rd_v <= {rd_v, mem_a};
end
assign dout = rd_a[RD_LAT-1] ? rd_v[32*RD_LAT-1 -: 32] : other_data;

//=============================================================================
// DATA PHASE (the harness's own view of the bus)
//=============================================================================
wire       aph     = hsel & htrans[1] & hreadyout;
wire       aph_err = hsize[2] | (hsize[1:0] == 2'b11) | (haddr[4:2] >= WORDS);
wire [3:0] aph_be  = (hsize[1:0] == 2'b00) ? (4'b0001 << haddr[1:0]) :
                     (hsize[1:0] == 2'b01) ? (haddr[1] ? 4'b1100 : 4'b0011) : 4'b1111;
reg        d_v, d_err, d_wrt;                    // data phase: valid, ERROR, write
reg [AW-1:0] d_addr;
reg  [3:0] d_be;
reg        d_rd, d_a, d_wr;                      // a read, of A, A written by the GPU meanwhile
reg        e_first;                              // the ERROR's first cycle is over
wire       a_gwrite = gnt[1] && g_we && (|g_be) && g_addr == A;

always @(posedge clk)
    if (!rst_n) begin
        d_v <= 1'b0; d_err <= 1'b0; d_wrt <= 1'b0; d_rd <= 1'b0; e_first <= 1'b0;
    end else begin
        if (hreadyout) begin
            d_v    <= aph;
            d_err  <= aph & aph_err;
            d_wrt  <= aph & hwrite & ~aph_err;
            d_rd   <= aph & ~hwrite & ~aph_err;
            d_addr <= haddr[4:2];
            d_be   <= aph_be;
            d_a    <= haddr[4:2] == A;
            d_wr   <= a_gwrite;
        end else begin
            d_wr   <= d_wr | a_gwrite;
        end
        e_first <= d_v && d_err && !hreadyout;
    end

//=============================================================================
// WRITES: the window's completed writes reach the macro once, in order
//=============================================================================
wire       w_done  = rst_q && d_wrt && hreadyout;    // a write completes (OKAY)
wire       w_made  = gnt[0] && w_we;                 // the window writes the macro
reg        q_v = 1'b0;                               // a completed write not yet made
reg [AW-1:0] q_addr;
reg  [3:0] q_be;
reg [31:0] q_data;
reg        pend_nxt_q = 1'b0;

always @(posedge clk) begin
    if (!rst_n) q_v <= 1'b0;
    else        q_v <= q_v ? !w_made : (w_done && !w_made);
    if (!q_v && w_done) begin
        q_addr <= d_addr; q_be <= d_be; q_data <= hwdata;
    end
    pend_nxt_q <= rst_n & wb_pend_nxt;
end

always @(*)
    if (rst_q) begin
        // made: the posted write, else the write completing now
        if (w_made && q_v)   a_wr_post: assert (w_addr == q_addr && w_be == q_be && w_wdata == q_data);
        if (w_made && !q_v)  a_wr_now:  assert (w_done && w_addr == d_addr && w_be == d_be && w_wdata == hwdata);
        // no write completes while one is posted (none lost)
        a_wr_room: assert (!(w_done && q_v));
        a_wb_pend: assert (wb_pend == q_v);
        a_wb_nxt:  assert (wb_pend == pend_nxt_q);
    end

//=============================================================================
// COHERENCE: a read returns A as written on the bus
//=============================================================================
reg [31:0] mem_a_ref;                            // A, with the posted write over it
always @(*) begin
    mem_a_ref = mem_a;
    if (q_v && q_addr == A) begin
        if (q_be[0]) mem_a_ref[7:0]   = q_data[7:0];
        if (q_be[1]) mem_a_ref[15:8]  = q_data[15:8];
        if (q_be[2]) mem_a_ref[23:16] = q_data[23:16];
        if (q_be[3]) mem_a_ref[31:24] = q_data[31:24];
    end
end

wire       done = rst_q && d_rd && d_a && hreadyout;

always @(*)
    if (done && !d_wr)
        a_coherent: assert (hrdata == mem_a_ref);

//=============================================================================
// RESPONSE
//=============================================================================
wire       p_err_done, p_rd_cmp;                 // probes: the ERROR's second cycle, a read's data
wire       ready_ref = (d_v && d_err) ? p_err_done :
                       !(d_v && !d_err && !(d_wrt ? !wb_pend : p_rd_cmp));

always @(*)
    if (rst_q) begin
        a_hready:  assert (hreadyout == ready_ref);
        a_resp:    assert (hresp == (d_v && d_err));
        if (d_v && d_err)
            a_err2: assert (hreadyout == e_first);
    end

// Out of reset too: no data phase, OKAY with no wait state
always @(*)
    if (rst_n)
        a_idle: assert (d_v || (hreadyout && !hresp));

//=============================================================================
// PROGRESS: a transfer the refresh does not hold off completes in a bounded
// time (the GPU's one aged cycle, the posted write, a read ahead in flight,
// the read latency and the window's data register)
//=============================================================================
localparam WAIT_MAX = 2 * RD_L + 4;
reg  [4:0] wcnt = 5'd0;                          // wait states of the data phase
reg        urg_seen = 1'b0;                      // an urgent refresh request during it
always @(posedge clk) begin
    wcnt     <= (!rst_n || hreadyout) ? 5'd0 : ((wcnt == 5'd31) ? wcnt : wcnt + 5'd1);
    urg_seen <= rst_n && !hreadyout && (urg_seen || (r_req && r_urg));
end
always @(*)
    if (rst_q && d_v && !urg_seen && !(r_req && r_urg))
        a_progress: assert (wcnt <= WAIT_MAX);

//=============================================================================
// COVERS
//=============================================================================
wire       p_pb_hit;                             // probe: a buffer hit
wire       p_wait_done, p_dm_ret;                // probes: a read ahead waited for returns, a demand read's data
reg        s_wait = 1'b0, s_dm = 1'b0;           // ... seen in this data phase
always @(posedge clk) begin
    s_wait <= rst_n & !hreadyout & (s_wait | p_wait_done);
    s_dm   <= rst_n & !hreadyout & (s_dm   | p_dm_ret);
end
wire       by_wait   = p_wait_done | s_wait;
wire       by_demand = p_dm_ret    | s_dm;
reg        written = 1'b0;                       // A written since reset
reg        posted_a = 1'b0;                      // a write of A posted, then made
always @(posedge clk) begin
    written  <= rst_n & (written | (m_wr && maddr == A));
    posted_a <= rst_n & (posted_a | (q_v && q_addr == A && w_made));
end
always @(posedge clk)
    if (rst_q) begin
        c_hit:         cover (done && !d_wr && p_pb_hit && !by_wait && !by_demand);
        c_wait:        cover (done && !d_wr && by_wait);
        c_demand:      cover (done && !d_wr && by_demand);
        c_hit_written: cover (done && !d_wr && p_pb_hit && !by_wait && !by_demand && written);
        c_post:        cover (w_done && !w_made);
        c_post_full:   cover (q_v && d_wrt && !hreadyout);
        c_post_hit:    cover (q_v && done && p_pb_hit && !by_wait && !by_demand);
        c_raw_posted:  cover (done && !d_wr && posted_a);
        c_err:         cover (d_v && d_err && hreadyout);
    end

endmodule

`default_nettype wire
