//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_gpu_tri_setup
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_gpu_tri_setup.v
// Module Description : Triangle set-up for the scan-line walk. The signed area
//                      orders the vertices (v1 and v2 swapped when negative);
//                      each edge a -> b then bounds the rows of the box whose
//                      pixel centre Y lies within its own y extent: with
//                      E(px) = dx (Y - ay) - dy (16 px + 8 - ax) > 0 (or = 0 on
//                      a top or left edge), a rising edge (dy > 0) gives the
//                      last pixel of the row, floor((n - t) / 16dy), a falling
//                      one the first, -floor((n - t) / 16|dy|) (n = E's
//                      constant part, t = 0 on a top / left edge, else 1).
//                      The engine steps each bound by the exact quotient and
//                      remainder of 16 dx / 16|dy| per row. A horizontal edge
//                      only removes the row its centre lies on (unless it is a
//                      top edge). Products on the set-up's multiplier, its
//                      operands registered (a product is ready the cycle after
//                      its operands), divisions on magnitudes, two quotient
//                      bits per cycle: 3 cycles for the area, 19 per sloped
//                      edge. The set-up's gradient phase (a rectangle, never
//                      while a triangle is set up) uses the same divider
//                      through the GRADIENT DIVISION port.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_gpu_tri_setup #(
    parameter                    DIM_W        = 10,   // width/height field width
    parameter                    ASYNC_RST_EN = 1'b1  // 1=async active-low reset, 0=synchronous reset
) (
// CLOCK & RESET
    input  wire                  hclk_i,              // clock
    input  wire                  hresetn_i,           // active-low reset

// CONTROL
    input  wire                  start_i,             // start (1 cycle, box registered)
    input  wire                  abort_i,             // abandon
    output wire                  busy_o,              // running
    output wire                  degen_o,             // zero area (valid when done)

// TRIANGLE
    input  wire           [95:0] tri_v_i,             // {v2, v1, v0}, each {y, x} signed 12.4
    input  wire           [15:0] box_x_i,             // first box column (signed)
    input  wire           [15:0] box_y_i,             // first box row (signed)
    input  wire    [DIM_W-1:0]   box_h_i,             // box rows

// SHARED MULTIPLIER (18 x 18 signed; operands 0 when idle: blns_gpu_setup
// ORs them into its own, exclusive by its sequence)
    output wire           [17:0] mul_a_o,             // operand a
    output wire           [17:0] mul_b_o,             // operand b
    input  wire           [35:0] mul_p_i,             // a * b

// GRADIENT DIVISION (blns_gpu_setup's gradient phase: only while idle; a load
// may come with start_i, the triangle reloads the divider at T_E3)
    input  wire                  gdiv_ld_i,           // load the dividend and the divisor
    input  wire                  gdiv_step_i,         // one step: two quotient bits
    input  wire           [17:0] gdiv_dvd_i,          // dividend x 16, aligned to the steps made
    input  wire           [11:0] gdiv_n_i,            // divisor (B = 16 N)
    output wire           [13:0] gdiv_quo_o,          // quotient (after the steps)
    output wire           [11:0] gdiv_rem_o,          // remainder

// EDGES (stable after busy_o falls)
    output wire [3*(49+2*DIM_W)-1:0] edges_o,          // 3 x {kind, sq, sr / 16, |dy|, first row, last row}
    output wire          [3*36-1:0] starts_o           // 3 x {x, r} at the first row
);

//=============================================================================
// 1)  PARAMETERS AND STATES
//=============================================================================
localparam       EW      = 85 + 2*DIM_W;               // bits per edge

localparam [3:0] T_IDLE  = 4'd0;
localparam [3:0] T_A1    = 4'd1;                       // (x1 - x0) (y2 - y0)
localparam [3:0] T_A2    = 4'd2;                       // - (y1 - y0) (x2 - x0)
localparam [3:0] T_A3    = 4'd9;                       // order
localparam [3:0] T_E1    = 4'd3;                       // edge: dx (Ys - ay)
localparam [3:0] T_E2    = 4'd4;                       // - dy (8 - ax)
localparam [3:0] T_E3    = 4'd10;                      // n = ... - t
localparam [3:0] T_D1    = 4'd5;                       // n / B
localparam [3:0] T_F1    = 4'd6;                       // floor: start bound
localparam [3:0] T_D2    = 4'd7;                       // 16 dx / B
localparam [3:0] T_F2    = 4'd8;                       // floor: step

localparam [1:0] K_NONE  = 2'd0;
localparam [1:0] K_LEFT  = 2'd1;
localparam [1:0] K_RIGHT = 2'd2;
localparam [1:0] K_HROW  = 2'd3;                       // horizontal: drop one row

wire [3:0] st;
wire       st_a1 = (st == T_A1);
wire       st_a2 = (st == T_A2);
wire       st_a3 = (st == T_A3);
wire       st_e1 = (st == T_E1);
wire       st_e2 = (st == T_E2);
wire       st_e3 = (st == T_E3);
wire       st_d1 = (st == T_D1);
wire       st_f1 = (st == T_F1);
wire       st_d2 = (st == T_D2);
wire       st_f2 = (st == T_F2);

//=============================================================================
// 2)  VERTICES AND THE CURRENT EDGE
//=============================================================================
wire [17:0] v0x = {{2{tri_v_i[15]}}, tri_v_i[15:0]};
wire [17:0] v0y = {{2{tri_v_i[31]}}, tri_v_i[31:16]};
wire [17:0] v1x = {{2{tri_v_i[47]}}, tri_v_i[47:32]};
wire [17:0] v1y = {{2{tri_v_i[63]}}, tri_v_i[63:48]};
wire [17:0] v2x = {{2{tri_v_i[79]}}, tri_v_i[79:64]};
wire [17:0] v2y = {{2{tri_v_i[95]}}, tri_v_i[95:80]};

wire        swap;                                       // area negative: v1 <-> v2
wire  [1:0] k;                                          // edge index
wire [17:0] p1x = swap ? v2x : v1x;
wire [17:0] p1y = swap ? v2y : v1y;
wire [17:0] p2x = swap ? v1x : v2x;
wire [17:0] p2y = swap ? v1y : v2y;

// edge k: p0 -> p1, p1 -> p2, p2 -> p0
wire        k0  = (k == 2'd0);
wire        k1  = (k == 2'd1);
wire [17:0] ax  = k0 ? v0x : k1 ? p1x : p2x;
wire [17:0] ay  = k0 ? v0y : k1 ? p1y : p2y;
wire [17:0] bx  = k0 ? p1x : k1 ? p2x : v0x;
wire [17:0] by  = k0 ? p1y : k1 ? p2y : v0y;
wire [17:0] edx = bx - ax;
wire [17:0] edy = by - ay;
wire        dy_z   = (edy == 18'd0);
wire        dy_neg = edy[17];
// top edge: horizontal going right; left edge: going up
wire        tie    = (dy_z & ~edx[17] & (edx != 18'd0)) | dy_neg;

// Rows of the box whose centre lies within [min(ay, by), max(ay, by)]
wire [17:0] ylo    = dy_neg ? by : ay;
wire [17:0] yhi    = dy_neg ? ay : by;
wire [17:0] by0    = {{2{box_y_i[15]}}, box_y_i};
wire [17:0] bh18   = {{(18-DIM_W){1'b0}}, box_h_i};
wire [17:0] ylo_p7 = ylo + 18'd7;
wire [17:0] yhi_m8 = yhi - 18'd8;
wire [17:0] rs_rel = {{4{ylo_p7[17]}}, ylo_p7[17:4]} - by0;   // first row, box-relative
wire [17:0] re_rel = {{4{yhi_m8[17]}}, yhi_m8[17:4]} - by0;   // last row
wire [17:0] bh_m1  = bh18 - 18'd1;
wire [17:0] rs_c   = rs_rel[17] ? 18'd0 : rs_rel;
wire [17:0] re_c   = ($signed(re_rel) > $signed(bh_m1)) ? bh_m1 : re_rel;
wire        e_rows = ~re_c[17] & ($signed(rs_c) <= $signed(re_c));
// horizontal edge: the row whose centre is ay, dropped unless a top edge
wire [17:0] hy_m8  = ay - 18'd8;
wire [17:0] h_rel  = {{4{hy_m8[17]}}, hy_m8[17:4]} - by0;
wire        h_drop = dy_z & ~tie & (hy_m8[3:0] == 4'h0) & ~h_rel[17] & ($signed(h_rel) < $signed(bh18));

// first row's centre and the products: ys = 16 max(first row, by0) + 8 (the
// box row by0 + rs_c without the round trip; box rows are inside the 12-bit
// clip window, so 14 bits hold the row)
wire [17:0] ys_px  = rs_rel[17] ? by0 : {{4{ylo_p7[17]}}, ylo_p7[17:4]};
wire [17:0] ys     = {ys_px[13:0], 4'h8};
wire [17:0] ys_ay  = ys - ay;
wire [17:0] c8_ax  = 18'd8 - ax;

//=============================================================================
// 3)  MULTIPLIER OPERANDS AND THE DIVIDEND
//=============================================================================
// The operands of a state are registered: its product comes a cycle later
wire [17:0] op_a    = ({18{st_a1}} & (v1x - v0x)) | ({18{st_a2}} & (v1y - v0y)) |
                      ({18{st_e1}} & edx)         | ({18{st_e2}} & edy);
wire [17:0] op_b    = ({18{st_a1}} & (v2y - v0y)) | ({18{st_a2}} & (v2x - v0x)) |
                      ({18{st_e1}} & ys_ay)       | ({18{st_e2}} & c8_ax);
wire [17:0] op_a_q;
wire [17:0] op_b_q;
wire        busy;

arv_ipdff #(.WIDTH(36), .ARST_EN(ASYNC_RST_EN)) u_op (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(busy), .d_i({op_a, op_b}), .q_o({op_a_q, op_b_q}));

assign mul_a_o = {18{busy}} & op_a_q;
assign mul_b_o = {18{busy}} & op_b_q;

wire [35:0] acc;                                        // first product of a pair
wire [35:0] pair    = acc - mul_p_i;                    // the area (its sign: u_ord)
// n - t = acc - p - (1 - tie) = acc + ~p + tie, one sum with a carry-in; its
// negation -(n - t) = p + ~acc + 2 - tie, a second sum beside it: the
// magnitude is a select, no negate after the product
wire [35:0] n_start = acc + ~mul_p_i + {35'd0, tie};    // n - t
wire [35:0] n_neg   = mul_p_i + ~acc + {34'd0, ~tie, tie};
wire [35:0] dx16    = {{14{edx[17]}}, edx, 4'h0};      // 16 dx
// (the gradient's sign: not used, it reads the quotient and remainder only)
wire        dvd_neg = st_e3 ? n_start[35] : dx16[35];   // signed dividend (E3 / F1)
// the gradient dividend on the inner leg: E3's leg, from the product, keeps
// its depth
wire [35:0] dvd_mag = st_e3     ? (n_start[35] ? n_neg : n_start) :
                      gdiv_ld_i ? {18'h00000, gdiv_dvd_i} :
                                  (dx16[35] ? (36'd0 - dx16) : dx16);
// |dy| < 2^16: the vertices are 12.4 in 16 bits (+-2048 pixels)
wire [17:0] dy_mag  = dy_neg ? (18'd0 - edy) : edy;
// B = 16 |dy| (16 N for the gradient), registered at E3: the steps and the
// floor (D1 to F2, the edge fixed) read it from a flop
wire [15:0] bq;
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_bq (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_e3 | gdiv_ld_i),
             .d_i(st_e3 ? dy_mag[15:0] : {4'h0, gdiv_n_i}), .q_o(bq));
wire [19:0] bd      = {bq, 4'h0};

arv_ipdff #(.WIDTH(36), .ARST_EN(ASYNC_RST_EN)) u_acc (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_a2 | st_e2), .d_i(mul_p_i), .q_o(acc));

//=============================================================================
// 4)  DIVIDER: |dividend| / B, 14 quotient bits, 2 per cycle
//=============================================================================
// The remainder starts with the dividend's bits above the quotient (smaller
// than B for the start bound; for the step only when the edge is stepped).
// The start bound fits the 14 quotient bits because the first row's centre
// lies inside the edge's y range, so the crossing lies inside its x range
// (|q| <= 2049 for vertices in +-2048 pixels): a wider coordinate format must
// widen the quotient. The gradient (dividend x 16 < 2^18, B = 16 N) leaves
// a remainder 16 (dividend mod N) and its quotient in the low bits.
wire [20:0] d_rem;
wire [13:0] d_quo;                                      // quotient bits / dividend bits left
wire        d_neg;
wire  [2:0] d_cnt;
wire [20:0] r_s1    = {d_rem[19:0], d_quo[13]};
wire        g1      = (r_s1 >= {1'b0, bd});
wire [20:0] r_1     = g1 ? (r_s1 - {1'b0, bd}) : r_s1;
wire [20:0] r_s2    = {r_1[19:0], d_quo[12]};
wire        g2      = (r_s2 >= {1'b0, bd});
wire [20:0] r_2     = g2 ? (r_s2 - {1'b0, bd}) : r_s2;
// exclusive: the gradient's load and steps come only while idle (T_IDLE)
wire        d_ld    = st_e3 | st_f1 | gdiv_ld_i;        // load the dividend
wire        d_last  = (d_cnt == 3'd6);
wire [20:0] rem_nxt = d_ld ? dvd_mag[34:14] : r_2;
wire [13:0] quo_nxt = d_ld ? dvd_mag[13:0]  : {d_quo[11:0], g1, g2};
wire  [2:0] cnt_nxt = d_ld ? 3'd0 : (d_cnt + 3'd1);
wire        neg_nxt = d_ld ? dvd_neg : d_neg;

arv_ipdff #(.WIDTH(39), .ARST_EN(ASYNC_RST_EN)) u_div (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(d_ld | st_d1 | st_d2 | gdiv_step_i),
             .d_i({rem_nxt, quo_nxt, neg_nxt, cnt_nxt}), .q_o({d_rem, d_quo, d_neg, d_cnt}));

// floor of a negative dividend: q = -q - 1, r = B - r (r != 0), else q = -q
wire        r_nz    = (d_rem != 21'd0);
wire [14:0] q_pos   = {1'b0, d_quo};
wire [14:0] q_flr   = ~d_neg ? q_pos : r_nz ? ~q_pos : (15'd0 - q_pos);
wire [19:0] r_flr   = (d_neg & r_nz) ? (bd - d_rem[19:0]) : d_rem[19:0];

//=============================================================================
// 5)  EDGE REGISTERS
//=============================================================================
// x: the bound relative to the box (right: q - x0, left: q + x0, the first
// pixel being -x)
wire [15:0] q16     = {q_flr[14], q_flr};
wire [15:0] x_rel   = dy_neg ? (q16 + box_x_i) : (q16 - box_x_i);
wire [1:0]  kind_e  = dy_z ? (h_drop ? K_HROW : K_NONE) : ~e_rows ? K_NONE : dy_neg ? K_LEFT : K_RIGHT;
wire        sloped  = ~dy_z & e_rows;
wire        e_done  = st_e1 & ~sloped;                  // horizontal or off the box: no division

wire [EW-1:0] e0;
wire [EW-1:0] e1;
wire [EW-1:0] e2;
wire [DIM_W-1:0] rs_d = dy_z ? h_rel[DIM_W-1:0] : rs_c[DIM_W-1:0];
// {kind, x, r, sq, sr / 16 (16 dx and B are multiples of 16), |dy| (B = 16 |dy|), first row, last row}
wire          wr_hdr = st_e1;                           // kind and rows
wire          wr_x   = st_f1;
wire          wr_s   = st_f2;
wire [EW-1:0] e_cur  = k0 ? e0 : k1 ? e1 : e2;
wire [EW-1:0] e_nxt  = {wr_hdr ? kind_e : e_cur[EW-1 -: 2],
                        wr_x   ? x_rel  : e_cur[EW-3 -: 16],
                        wr_x   ? r_flr  : e_cur[EW-19 -: 20],
                        wr_s   ? q_flr  : e_cur[EW-39 -: 15],
                        wr_s   ? r_flr[19:4] : e_cur[EW-54 -: 16],
                        wr_hdr ? dy_mag[15:0] : e_cur[EW-70 -: 16],
                        wr_hdr ? rs_d   : e_cur[2*DIM_W-1 -: DIM_W],
                        wr_hdr ? re_c[DIM_W-1:0] : e_cur[DIM_W-1:0]};
wire          e_wr   = wr_hdr | wr_x | wr_s;

arv_ipdff #(.WIDTH(EW), .ARST_EN(ASYNC_RST_EN)) u_e0 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(e_wr & k0), .d_i(e_nxt), .q_o(e0));
arv_ipdff #(.WIDTH(EW), .ARST_EN(ASYNC_RST_EN)) u_e1 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(e_wr & k1), .d_i(e_nxt), .q_o(e1));
arv_ipdff #(.WIDTH(EW), .ARST_EN(ASYNC_RST_EN)) u_e2 (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(e_wr & (k == 2'd2)), .d_i(e_nxt), .q_o(e2));

//=============================================================================
// 6)  SEQUENCE
//=============================================================================
wire        degen;
wire        a_neg  = pair[35];
wire        a_zero = (acc == mul_p_i);                  // pair == 0, without the subtract
wire        k_last = (k == 2'd2);
wire        e_end  = e_done | st_f2;                    // the edge is set up
// Priority: start > area > edges
wire        ord_en = start_i | st_a3;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_ord (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ord_en),
             .d_i(start_i ? 2'b00 : {a_neg, a_zero}), .q_o({swap, degen}));
wire        k_en   = start_i | e_end;
wire  [1:0] k_nxt  = start_i ? 2'd0 : (k + 2'd1);
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_k (
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(k_en), .d_i(k_nxt), .q_o(k));

wire        st_en  = abort_i | start_i | (st != T_IDLE);
wire  [3:0] st_nxt = abort_i                ? T_IDLE :
                     start_i                ? T_A1   :
                     st_a1                  ? T_A2   :
                     st_a2                  ? T_A3   :
                     (st_a3 & a_zero)       ? T_IDLE :
                     st_a3                  ? T_E1   :
                     (e_end & k_last)       ? T_IDLE :
                     e_done                 ? T_E1   :
                     st_e1                  ? T_E2   :
                     st_e2                  ? T_E3   :
                     st_e3                  ? T_D1   :
                     (st_d1 & ~d_last)      ? T_D1   :
                     st_d1                  ? T_F1   :
                     st_f1                  ? T_D2   :
                     (st_d2 & ~d_last)      ? T_D2   :
                     st_d2                  ? T_F2   :
                     st_f2                  ? T_E1   :
                                              T_IDLE;                 // (the codes 11-15: not used)
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_st (                        // resets to T_IDLE (0)
             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(st_en), .d_i(st_nxt), .q_o(st));

//=============================================================================
// 7)  OUTPUTS
//=============================================================================
assign busy    = (st != T_IDLE);
assign busy_o  = busy;
assign degen_o = degen;
// static part {kind, sq, sr, |dy|, rows} and the start {x, r}
assign edges_o  = {e2[EW-1 -: 2], e2[EW-39:0], e1[EW-1 -: 2], e1[EW-39:0], e0[EW-1 -: 2], e0[EW-39:0]};
assign starts_o = {e2[EW-3 -: 36], e1[EW-3 -: 36], e0[EW-3 -: 36]};
assign gdiv_quo_o = d_quo;
assign gdiv_rem_o = d_rem[15:4];

//=============================================================================
// 8)  LINT CLEANUP
//=============================================================================
wire  [3:0] div_unused  = {dvd_mag[35], dy_mag[17:16], r_1[20]};   // |dividend| < 2^35, |dy| < 2^16
wire  [3:0] ys_unused   = ys_px[17:14];                     // the row fits 14 bits
wire [34:0] pair_unused = pair[34:0];                       // its sign only (a_zero: acc == mul_p_i)
wire  [3:0] sr_unused   = r_flr[3:0];                       // the step remainder is a multiple of 16
wire  [7:0] y_frac_unused = {ylo_p7[3:0], yhi_m8[3:0]};             // pixel rows only

endmodule // blns_gpu_tri_setup

`default_nettype wire
