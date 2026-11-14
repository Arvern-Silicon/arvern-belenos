//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_px_l
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_px_l.v
// Module Description : GPU pixel engine, bilinear stage L (built with
//                      GPU_BILINEAR_EN): between F and W, a pipeline of two
//                      registers joined by valid / ready, accumulating a
//                      pixel's taps (in order, the last one carrying the
//                      pixel's destination):
//                      L1 the tap from F: texel, alpha a, weight k (0 ..
//                         1024); its premultiplied weight e = (k * a') >> 8,
//                         a' = a + (a >> 7) (with blending; without it every
//                         tap is opaque: e = k);
//                      L2 e and the texel: S += e, P_c += e * c_c per RGB565
//                         field; at the pixel's last tap its token for W:
//                         with blending alpha256 = S >> 2 and the
//                         premultiplied colour Pm_c = P_c >> 2 (MIX5) or
//                         (P_c + 2) >> 2, the destination needed unless
//                         alpha256 = 256, nothing written at 0; without, the
//                         straight colour (P_c + 512) >> 10.
//                      The two multiplies are in different cycles. A
//                      skipped pixel's token passes with nothing written.
//                      clr_i (start, abort) drops the taps and the partial
//                      sums.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_px_l #(
    parameter                    WA_W          = 17,  // destination word address width (VRAM_AW + 1)
    parameter                    GPU_BLEND_EN  = 1,   // tap alphas and the premultiplied result
    parameter                    ASYNC_RST_EN  = 1'b1 // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  clr_i,               // drop everything (start, abort)
    input  wire                  mix5_i,              // MIX5: the premultiplied colour truncated

// TAP IN (from F)
    input  wire                  in_v_i,              // a tap taken by L1 this cycle (only when in_free_o)
    output wire                  in_free_o,           // L1 can take a tap
    input  wire           [15:0] in_tex_i,            // the tap's texel (RGB565)
    input  wire            [7:0] in_a_i,              // its alpha
    input  wire           [10:0] in_k_i,              // its weight
    input  wire                  in_last_i,           // the pixel's last tap: the fields below
    input  wire                  in_skip_i,           // ... the pixel is skipped (no tap)
    input  wire       [WA_W-1:0] in_dwa_i,            // ... its destination word
    input  wire                  in_dhi_i,            // ... its pixel in the upper half

// PIXEL OUT (to W)
    input  wire                  out_free_i,          // the F -> W register takes a token
    output wire                  out_v_o,             // a pixel token this cycle (loaded when out_free_i)
    output wire       [WA_W-1:0] out_dwa_o,           // its destination word
    output wire                  out_dhi_o,           // ... upper half
    output wire                  out_noop_o,          // nothing written (skipped, alpha256 = 0)
    output wire                  out_nd_o,            // the destination is read (alpha256 < 256)
    output wire            [8:0] out_a256_o,          // alpha256 (0 .. 256)
    output wire           [41:0] out_pm_o,            // premultiplied colour {R, G, B}, 14 bits each
    output wire           [15:0] out_pix_o,           // straight colour (no blending)
    output wire                  busy_o               // a tap or a partial sum held
);

//=============================================================================
// 1)  L1: THE TAP
//=============================================================================
localparam BLEND_USE = (GPU_BLEND_EN != 0);

wire              l1_v;
wire              l2_v;
wire              l2_go;                                 // L2 consumed (section 2)
wire              l1_go    = l1_v & (~l2_v | l2_go);
assign            in_free_o = ~l1_v | l1_go;

wire       [15:0] l1_tex;
wire        [7:0] l1_a;
wire       [10:0] l1_k;
wire              l1_last;
wire              l1_skip;
wire   [WA_W-1:0] l1_dwa;
wire              l1_dhi;
// Priority: clear > a new tap > moved on
wire              l1_v_nxt = ~clr_i & (in_v_i | (l1_v & ~l1_go));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_l1_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(l1_v_nxt), .q_o(l1_v));
arv_ipdff #(.WIDTH(WA_W + 38), .ARST_EN(ASYNC_RST_EN)) u_l1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(in_v_i),
             .d_i({in_tex_i, in_a_i, in_k_i, in_last_i, in_skip_i, in_dwa_i, in_dhi_i}),
             .q_o({l1_tex, l1_a, l1_k, l1_last, l1_skip, l1_dwa, l1_dhi}));

// e = (k * a') >> 8 (0 .. 1024); a skipped pixel's token adds nothing
wire       [10:0] l1_e;
generate
    if (BLEND_USE) begin : g_e
        wire  [8:0] a_p   = {1'b0, l1_a} + {8'h00, l1_a[7]};
        wire [19:0] k_a   = {9'h000, l1_k} * {11'h000, a_p};
        assign      l1_e  = {11{~l1_skip}} & k_a[18:8];
        wire  [8:0] ka_unused = {k_a[19], k_a[7:0]};
    end else begin : g_e_opq
        assign      l1_e  = {11{~l1_skip}} & l1_k;
        wire  [7:0] a_unused = l1_a;                       // GPU_BLEND_EN = 0: every tap opaque
        wire        mix5_unused = mix5_i;                  // ... and no MIX5 (rnd)
    end
endgenerate

//=============================================================================
// 2)  L2: THE SUMS
//=============================================================================
wire       [10:0] l2_e;
wire       [15:0] l2_tex;
wire              l2_last;
wire              l2_skip;
wire   [WA_W-1:0] l2_dwa;
wire              l2_dhi;
assign            l2_go    = l2_v & (~l2_last | out_free_i);
wire              l2_v_nxt = ~clr_i & (l1_go | (l2_v & ~l2_go));
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_l2_v (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(l2_v_nxt), .q_o(l2_v));
arv_ipdff #(.WIDTH(WA_W + 30), .ARST_EN(ASYNC_RST_EN)) u_l2 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(l1_go),
             .d_i({l1_e, l1_tex, l1_last, l1_skip, l1_dwa, l1_dhi}),
             .q_o({l2_e, l2_tex, l2_last, l2_skip, l2_dwa, l2_dhi}));

// The sums with this tap: S <= 1024, P_r, P_b <= 1024 * 31, P_g <= 1024 * 63
wire       [10:0] acc_s;
wire       [14:0] acc_r;
wire       [15:0] acc_g;
wire       [14:0] acc_b;
wire       [15:0] p_r      = {5'h00, l2_e} * {11'h000, l2_tex[15:11]};
wire       [16:0] p_g      = {6'h00, l2_e} * {11'h000, l2_tex[10:5]};
wire       [15:0] p_b      = {5'h00, l2_e} * {11'h000, l2_tex[4:0]};
wire       [11:0] sum_s    = {1'b0, acc_s} + {1'b0, l2_e};
wire       [15:0] sum_r    = {1'b0, acc_r} + p_r;
wire       [16:0] sum_g    = {1'b0, acc_g} + p_g;
wire       [15:0] sum_b    = {1'b0, acc_b} + p_b;
// Priority: clear / the pixel's last tap (back to 0) > a tap added
wire              acc_en   = clr_i | l2_go;
wire              acc_z    = clr_i | l2_last;
arv_ipdff #(.WIDTH(57), .ARST_EN(ASYNC_RST_EN)) u_acc (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(acc_en),
             .d_i(acc_z ? 57'd0 : {sum_s[10:0], sum_r[14:0], sum_g[15:0], sum_b[14:0]}),
             .q_o({acc_s, acc_r, acc_g, acc_b}));

// The pixel token (the sums with its last tap)
wire        [8:0] a256     = sum_s[10:2];
wire              rnd      = BLEND_USE & ~mix5_i;
wire       [15:0] pm_r     = sum_r + {14'h0000, rnd, 1'b0};
wire       [16:0] pm_g     = sum_g + {15'h0000, rnd, 1'b0};
wire       [15:0] pm_b     = sum_b + {14'h0000, rnd, 1'b0};
wire       [15:0] sc_r     = sum_r + 16'd512;
wire       [16:0] sc_g     = sum_g + 17'd512;
wire       [15:0] sc_b     = sum_b + 16'd512;
assign out_v_o    = l2_v & l2_last;
assign out_dwa_o  = l2_dwa;
assign out_dhi_o  = l2_dhi;
assign out_noop_o = l2_skip | (BLEND_USE & (a256 == 9'd0));
assign out_nd_o   = BLEND_USE & (a256 != 9'h100);
assign out_a256_o = a256;
assign out_pm_o   = {pm_r[15:2], pm_g[15:2], pm_b[15:2]};
assign out_pix_o  = {sc_r[14:10], sc_g[15:10], sc_b[14:10]};
// (the taps of a pixel follow one another in F: the partial sums need no flag)
assign busy_o     = l1_v | l2_v;

//=============================================================================
// 3)  LINT CLEANUP
//=============================================================================
// (the sums' top bits: never set; the fractions dropped)
wire [45:0] sum_unused = {sum_s[11], sum_s[1:0], sum_r[15], sum_g[16], sum_b[15],
                          pm_r[1:0], pm_g[16], pm_g[1:0], pm_b[1:0],
                          sc_r[15], sc_r[9:0], sc_g[16], sc_g[9:0], sc_b[15], sc_b[9:0]};

endmodule // blns_gpu_px_l

`default_nettype wire
