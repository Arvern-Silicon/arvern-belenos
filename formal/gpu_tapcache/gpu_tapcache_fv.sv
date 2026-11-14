//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    gpu_tapcache_fv
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Formal harness of blns_gpu_px_tc (the bilinear tap cache) against a shadow
// of one VRAM word chosen by the solver (trk, constant): the memory reads a
// word at the grant and returns it exactly RD_LAT cycles later; the write-back
// slot writes free data to a free word in any cycle (the GPU port issues one
// access per cycle: never in the cycle of a read grant). The look-up, the
// W merges, the clear and the data of the words other than trk are free.
// The contract of blns_gpu_px_fw (assumed): one read in flight (a grant only
// when none is pending), a colour read for the looked-up word and its entry,
// an A8 read for the looked-up texel's entry, the fill pulse of the kind
// granted exactly RD_LAT cycles after the grant.
//
// Properties: a hit on trk returns the shadow value (a_hit_data); no entry
// holds trk the cycle after a write to it (a_drop_write), after a clear
// (a_drop_clr); an A8 fill stores the texel's lane of the returned word, and
// its neighbour's when it shares the word (a_abyte, a_apart).
//----------------------------------------------------------------------------
`default_nettype none
module gpu_tapcache_fv #(
    parameter VRAM_AW      = 4,
    parameter RD_LAT       = 1,
    parameter ASYNC_RST_EN = 1
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clr,
    input  wire [VRAM_AW-1:0] lk_wa,
    input  wire               lk_par,
    input  wire               lk_slot,
    input  wire               cgnt,
    input  wire               agnt,
    input  wire         [1:0] alane,
    input  wire               wm,
    input  wire [VRAM_AW-1:0] wm_wa,
    input  wire               ww,
    input  wire [VRAM_AW-1:0] ww_wa,
    input  wire        [31:0] wdata,
    input  wire        [31:0] odata                 // the data of a word other than trk
);

(* anyconst *) wire [VRAM_AW-1:0] trk;

always @(*) if ($initstate) assume (!rst_n);

//----------------------------------------------------------------------------
// Memory and the read in flight
//----------------------------------------------------------------------------
reg        [31:0] sv;                            // the shadow of trk
reg               pend;                          // a read in flight
reg               pend_c;                        // ... a colour read
reg [VRAM_AW-1:0] pend_wa;
reg        [31:0] pend_d;                        // ... the word as read
reg         [2:0] pend_n;                        // cycles since its grant
wire              ret    = pend & (pend_n == RD_LAT - 1);
wire              cfill  = ret &  pend_c;
wire              afill  = ret & ~pend_c;
wire              fly    = pend & ~ret;
wire              apart  = lk_slot ? (alane != 2'd0) : (alane != 2'd3);
wire       [31:0] rdata  = ret ? pend_d : odata;

always @(*) begin
    assume (!(cgnt && agnt));
    if (pend)            assume (!cgnt && !agnt);
    if (cgnt || agnt)    assume (!ww);           // one access per cycle on the port
end

wire       [31:0] rd_now = (lk_wa == trk) ? sv : odata;
always @(posedge clk)
    if (!rst_n) begin
        pend <= 1'b0;
        sv   <= 32'd0;
    end else begin
        if (ww && ww_wa == trk) sv <= wdata;
        if (cgnt || agnt) begin
            pend    <= 1'b1;
            pend_c  <= cgnt;
            pend_wa <= lk_wa;
            pend_d  <= rd_now;
            pend_n  <= 3'd0;
        end else if (pend) begin
            if (ret) pend <= 1'b0;
            pend_n <= pend_n + 3'd1;
        end
    end

//----------------------------------------------------------------------------
// DUT
//----------------------------------------------------------------------------
wire              hit;
wire       [31:0] data;
wire              ahit;
wire        [7:0] abyte;
wire              cok;

blns_gpu_px_tc #(.VRAM_AW(VRAM_AW), .ASYNC_RST_EN(ASYNC_RST_EN)) u_dut (
    .hclk_i(clk), .hresetn_i(rst_n), .clr_i(clr),
    .lk_wa_i(lk_wa), .lk_par_i(lk_par), .lk_slot_i(lk_slot),
    .hit_o(hit), .data_o(data), .ahit_o(ahit), .abyte_o(abyte),
    .cgnt_i(cgnt), .agnt_i(agnt), .alane_i(alane), .apart_i(apart),
    .cfill_i(cfill), .afill_i(afill), .rdata_i(rdata),
    .wm_i(wm), .wm_wa_i(wm_wa), .ww_i(ww), .ww_wa_i(ww_wa), .fly_i(fly), .cok_o(cok));

// White-box probes: the entries, the read recorded, its kill flag
wire         [3:0] p_v;
wire [4*VRAM_AW-1:0] p_wa;
wire       [127:0] p_d;
wire [VRAM_AW-1:0] p_fwa;
wire               p_kill;
wire         [1:0] p_fe;
wire               p_fslot;
wire         [1:0] p_flane;
wire               p_fpart;

// The A8 fill just made: its entry, lane, texel, the returned word
reg                af_q;
reg          [1:0] af_e;
reg                af_slot;
reg          [1:0] af_lane;
reg                af_part;
reg         [31:0] af_d;
reg          [1:0] g_e;                          // the entry and texel of the read in flight
reg                g_slot;
reg          [1:0] g_lane;
reg                g_part;
always @(posedge clk)
    if (!rst_n) af_q <= 1'b0;
    else begin
        if (cgnt || agnt) begin
            g_e    <= {lk_par, lk_wa[0]};
            g_slot <= lk_slot;
            g_lane <= alane;
            g_part <= apart;
        end
        af_q    <= afill & ~clr;
        af_e    <= g_e;
        af_slot <= g_slot;
        af_lane <= g_lane;
        af_part <= g_part;
        af_d    <= rdata;
    end
wire         [1:0] af_nl = af_slot ? (af_lane - 2'd1) : (af_lane + 2'd1);

reg                past_ww_trk;
reg                past_clr;
reg                wrote;                        // trk written at some point
always @(posedge clk) begin
    past_ww_trk <= rst_n & ww & (ww_wa == trk);
    past_clr    <= rst_n & clr;
    wrote       <= rst_n & (wrote | (ww & (ww_wa == trk)));
end

// One copy per entry (labels must be unique)
always @(*)
    if (rst_n) begin
        if (past_ww_trk && p_wa[0*VRAM_AW +: VRAM_AW] == trk) a_drop_write_e0: assert (!p_v[0]);
        if (past_clr)                                          a_drop_clr_e0:   assert (!p_v[0]);
        if (p_v[0] && p_wa[0*VRAM_AW +: VRAM_AW] == trk)       h_ent_e0:        assert (p_d[0 +: 32] == sv);
        if (past_ww_trk && p_wa[1*VRAM_AW +: VRAM_AW] == trk) a_drop_write_e1: assert (!p_v[1]);
        if (past_clr)                                          a_drop_clr_e1:   assert (!p_v[1]);
        if (p_v[1] && p_wa[1*VRAM_AW +: VRAM_AW] == trk)       h_ent_e1:        assert (p_d[32 +: 32] == sv);
        if (past_ww_trk && p_wa[2*VRAM_AW +: VRAM_AW] == trk) a_drop_write_e2: assert (!p_v[2]);
        if (past_clr)                                          a_drop_clr_e2:   assert (!p_v[2]);
        if (p_v[2] && p_wa[2*VRAM_AW +: VRAM_AW] == trk)       h_ent_e2:        assert (p_d[64 +: 32] == sv);
        if (past_ww_trk && p_wa[3*VRAM_AW +: VRAM_AW] == trk) a_drop_write_e3: assert (!p_v[3]);
        if (past_clr)                                          a_drop_clr_e3:   assert (!p_v[3]);
        if (p_v[3] && p_wa[3*VRAM_AW +: VRAM_AW] == trk)       h_ent_e3:        assert (p_d[96 +: 32] == sv);
    end

always @(*)
    if (rst_n) begin
        if (hit && (lk_wa == trk))  a_hit_data:   assert (data == sv);
        // The fill taken as it arrives (by F) is the word as it is now
        if (cok && pend_wa == trk)  a_byp_data:   assert (rdata == sv);
        // Lemma: a colour read of trk in flight not killed carries its value
        if (pend && pend_c && pend_wa == trk && !p_kill)           h_fly:        assert (pend_d == sv);
        if (pend)                                                  h_fwa:        assert (p_fwa == pend_wa);
        if (pend)                                                  h_fe:         assert ((p_fe == g_e) && (p_fslot == g_slot) && (p_flane == g_lane) && (p_fpart == g_part));
        if (pend)                                                  h_ge:         assert (g_e[0] == pend_wa[0]);
        if (af_q && {lk_par, lk_wa[0]} == af_e && lk_slot == af_slot)
                                                                   a_abyte:      assert (ahit && abyte == af_d[{af_lane, 3'b000} +: 8]);
        if (af_q && af_part && {lk_par, lk_wa[0]} == af_e && lk_slot != af_slot)
                                                                   a_apart:      assert (ahit && abyte == af_d[{af_nl, 3'b000} +: 8]);
    end

always @(posedge clk)
    if (rst_n) begin
        c_hit:       cover (hit && lk_wa == trk && sv != 32'd0);
        c_refill:    cover (hit && lk_wa == trk && wrote && sv != 32'd0);
        c_apart:     cover (af_q && af_part && ahit);
    end

generate
    if (RD_LAT > 1) begin : g_c_kill
        always @(posedge clk)
            if (rst_n) c_kill: cover (cfill && p_kill && pend_wa == trk);
    end
endgenerate

endmodule

`default_nettype wire
