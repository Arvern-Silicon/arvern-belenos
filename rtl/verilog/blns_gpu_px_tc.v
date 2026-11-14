//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_px_tc
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_px_tc.v
// Module Description : GPU pixel engine, bilinear tap cache (stage F, built
//                      with GPU_BILINEAR_EN): four colour words, direct-
//                      mapped by (the tap's texel row parity, the word's
//                      parity), so a 2 x 2 footprint (two adjacent rows, two
//                      columns in one or two adjacent words) never evicts
//                      itself; each with a 16-bit alpha companion (the A8
//                      bytes of its two texels, a valid bit each) for an
//                      RGB565A8 texture. Looked up from the F token's
//                      registers; a miss is read by blns_gpu_px_fw (one read
//                      in flight, in F's request slot): the colour word
//                      (its address and entry recorded at the grant), then
//                      the A8 word of the texel when its byte is not valid.
//                      The read data fills the entry recorded (a colour
//                      fill clears the companion; an A8 fill sets the
//                      texel's byte and, when it is in the same A8 word,
//                      its neighbour's). Every entry is dropped at a
//                      command start and while held; an entry is dropped
//                      when W merges into its word or the write-back slot
//                      writes it, and a colour read overtaken in flight by
//                      such a write fills nothing (a texture must not
//                      overlap the destination: this keeps the cache
//                      coherent with the VRAM, it is not a feature).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_px_tc #(
    parameter                    VRAM_AW       = 16,  // VRAM word-address width
    parameter                    ASYNC_RST_EN  = 1'b1 // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  clr_i,               // drop every entry (command start, held)

// LOOK-UP (the F token)
    input  wire    [VRAM_AW-1:0] lk_wa_i,             // the tap's colour word
    input  wire                  lk_par_i,            // ... its texel row parity
    input  wire                  lk_slot_i,           // ... the texel's half of the word
    output wire                  hit_o,               // the colour word is held
    output wire           [31:0] data_o,              // ... its data
    output wire                  ahit_o,              // the texel's A8 byte is held (with hit_o)
    output wire            [7:0] abyte_o,             // ... its value

// FILLS (blns_gpu_px_fw: the read granted, its data)
    input  wire                  cgnt_i,              // the tap's colour word read granted
    input  wire                  agnt_i,              // the tap's A8 word read granted
    input  wire            [1:0] alane_i,             // ... the texel's byte in it
    input  wire                  apart_i,             // ... the other texel's byte is in it too (at alane_i +- 1)
    input  wire                  cfill_i,             // the colour word read returns (vrdata_i)
    input  wire                  afill_i,             // the A8 word read returns
    input  wire           [31:0] rdata_i,             // read data

// DROPS (writes to the VRAM by W)
    input  wire                  wm_i,                // W merges into a word ...
    input  wire    [VRAM_AW-1:0] wm_wa_i,             // ... this one
    input  wire                  ww_i,                // the write-back slot writes a word ...
    input  wire    [VRAM_AW-1:0] ww_wa_i,             // ... this one
    input  wire                  fly_i,               // a read is in flight (its data not yet back)
    output wire                  cok_o                // the colour data returning fills its entry (not overtaken)
);

//=============================================================================
// 1)  ENTRIES
//=============================================================================
// Entry e = {row parity, word parity}; its tag is the word address. The four
// entries side by side: e_wa[e*VRAM_AW +: VRAM_AW], ...
wire         [3:0] e_v;                                  // valid
wire [4*VRAM_AW-1:0] e_wa;
wire       [127:0] e_d;
wire         [7:0] e_av;                                 // companion valid {texel 1, texel 0}
wire        [63:0] e_a;                                  // companion bytes {texel 1, texel 0}

wire         [1:0] lk_e   = {lk_par_i, lk_wa_i[0]};

// The read in flight: its entry, word, texel and A8 lanes, recorded at the
// grant; overtaken by a write to its word (colour reads): its data dropped
wire         [1:0] f_e;
wire  [VRAM_AW-1:0] f_wa;
wire               f_slot;
wire         [1:0] f_lane;
wire               f_part;
wire               f_kill;
arv_ipdff #(.WIDTH(VRAM_AW + 6), .ARST_EN(ASYNC_RST_EN)) u_fly (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cgnt_i | agnt_i),
             .d_i({lk_e, lk_wa_i, lk_slot_i, alane_i, apart_i}), .q_o({f_e, f_wa, f_slot, f_lane, f_part}));
// (a write in the cycle of the data overtakes it too: the data is the word
// before that write)
wire               f_ovt  = (wm_i & (wm_wa_i == f_wa)) | (ww_i & (ww_wa_i == f_wa));
// Priority: a new read > overtaken in flight > its data
wire               f_kill_nxt = ~cgnt_i & ~agnt_i & fly_i & (f_kill | f_ovt);
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_f_kill (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
             .d_i(f_kill_nxt), .q_o(f_kill));
wire               c_ok   = cfill_i & ~f_kill & ~f_ovt;  // the colour data fills its entry
assign             cok_o  = c_ok;
// (the A8 bytes: the alpha plane lies outside the destination, never overtaken)
wire         [7:0] a_own  = rdata_i[{f_lane, 3'b000} +: 8];
wire         [1:0] a_nl   = f_slot ? (f_lane - 2'd1) : (f_lane + 2'd1);
wire         [7:0] a_oth  = rdata_i[{a_nl, 3'b000} +: 8];

genvar             ge;
generate
    for (ge = 0; ge < 4; ge = ge + 1) begin : g_ent
        wire               sel   = (f_e == ge);
        wire [VRAM_AW-1:0] wa    = e_wa[ge*VRAM_AW +: VRAM_AW];
        wire         [1:0] av    = e_av[2*ge +: 2];
        wire        [15:0] ab    = e_a[16*ge +: 16];
        wire               drop  = (wm_i & (wm_wa_i == wa)) | (ww_i & (ww_wa_i == wa));
        // Priority: clear > its colour fill > a drop
        wire               v_nxt = ~clr_i & ((sel & c_ok) | (e_v[ge] & ~drop));
        wire         [1:0] av_nxt = cfill_i ? 2'b00 : (av | (f_slot ? {1'b1, f_part} : {f_part, 1'b1}));
        wire        [15:0] a_nxt = f_slot ? {a_own, f_part ? a_oth : ab[7:0]} : {f_part ? a_oth : ab[15:8], a_own};
        arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(v_nxt), .q_o(e_v[ge]));
        arv_ipdff #(.WIDTH(VRAM_AW + 32), .ARST_EN(ASYNC_RST_EN)) u_cw (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sel & c_ok), .d_i({f_wa, rdata_i}),
             .q_o({e_wa[ge*VRAM_AW +: VRAM_AW], e_d[32*ge +: 32]}));
        arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_av (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sel & (cfill_i | afill_i)), .d_i(av_nxt), .q_o(e_av[2*ge +: 2]));
        arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_a (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sel & afill_i), .d_i(a_nxt), .q_o(e_a[16*ge +: 16]));
    end
endgenerate

//=============================================================================
// 2)  LOOK-UP
//=============================================================================
wire  [VRAM_AW-1:0] lk_tag = e_wa[lk_e*VRAM_AW +: VRAM_AW];
assign hit_o   = e_v[lk_e] & (lk_tag == lk_wa_i);
assign data_o  = e_d[32*lk_e +: 32];
wire         [1:0] lk_av = e_av[2*lk_e +: 2];
wire        [15:0] lk_a  = e_a[16*lk_e +: 16];
assign ahit_o  = lk_slot_i ? lk_av[1] : lk_av[0];
assign abyte_o = lk_slot_i ? lk_a[15:8] : lk_a[7:0];

endmodule // blns_gpu_px_tc

`default_nettype wire
