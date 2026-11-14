//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_bk_hwcol
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_bk_hwcol.v
// Module Description : Backend hardware colour (combinational): 16 bpp RGB565, RGB332,
//                      CGA 16-colour index, 2 bpp palettes and BG/FG, expanded to RGB888.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_bk_hwcol (
// PIXEL
    input  wire    [15:0] raw_i,            // zero-extended pixel value

// LATCHED FRAME CONFIGURATION
    input  wire     [4:0] bpp_1hot_i,       // {16, 8, 4, 2, 1} bpp
    input  wire     [2:0] hw_palette_i,
    input  wire     [3:0] hw_bg_i,
    input  wire     [3:0] hw_fg_i,

// COLOUR
    output wire    [23:0] rgb_o
);

wire bpp1  = bpp_1hot_i[0];
wire bpp2  = bpp_1hot_i[1];
wire bpp4  = bpp_1hot_i[2];
wire bpp8  = bpp_1hot_i[3];
wire bpp16 = bpp_1hot_i[4];

// 2 bpp palettes, colour index for pixel values 01 / 10 / 11 (00 = BG)
wire [1:0] v2   = raw_i[1:0];
wire       pv1  = (v2 == 2'b01);
wire       pv2  = (v2 == 2'b10);
wire       pv3  = (v2 == 2'b11);
wire       pal0 = (hw_palette_i == 3'd0);
wire       pal1 = (hw_palette_i == 3'd1);
wire       pal2 = (hw_palette_i == 3'd2);
wire       pal3 = (hw_palette_i == 3'd3);
wire       pal4 = (hw_palette_i == 3'd4);
wire       pal5 = (hw_palette_i[2] & (hw_palette_i[1:0] != 2'b00));   // 5, and 6 / 7 behave as 5

wire [3:0] pal_idx = ({4{pal0 & pv1}} & 4'd10) | ({4{pal0 & pv2}} & 4'd12) | ({4{pal0 & pv3}} & 4'd14) |
                     ({4{pal1 & pv1}} & 4'd2 ) | ({4{pal1 & pv2}} & 4'd4 ) | ({4{pal1 & pv3}} & 4'd6 ) |
                     ({4{pal2 & pv1}} & 4'd11) | ({4{pal2 & pv2}} & 4'd13) | ({4{pal2 & pv3}} & 4'd15) |
                     ({4{pal3 & pv1}} & 4'd3 ) | ({4{pal3 & pv2}} & 4'd5 ) | ({4{pal3 & pv3}} & 4'd7 ) |
                     ({4{pal4 & pv1}} & 4'd11) | ({4{pal4 & pv2}} & 4'd12) | ({4{pal4 & pv3}} & 4'd15) |
                     ({4{pal5 & pv1}} & 4'd3 ) | ({4{pal5 & pv2}} & 4'd4 ) | ({4{pal5 & pv3}} & 4'd7 );

wire       use_bg  = (bpp2 & (v2 == 2'b00)) | (bpp1 & ~raw_i[0]);
wire       use_fg  =  bpp1 &  raw_i[0];
wire [3:0] cga_idx = ({4{bpp4}}           & raw_i[3:0]) |
                     ({4{bpp2 & ~use_bg}} & pal_idx   ) |
                     ({4{use_bg}}         & hw_bg_i   ) |
                     ({4{use_fg}}         & hw_fg_i   );

// CGA 16-colour table (RGB565)
localparam [255:0] CGA_TABLE = {16'hFFFF, 16'hFFEB, 16'hFABF, 16'hFAAB,   // 15..12
                                16'h5FFF, 16'h5FEB, 16'h5ABF, 16'h5AAB,   // 11..8
                                16'hAD75, 16'hAAA0, 16'hA815, 16'hA800,   //  7..4
                                16'h0575, 16'h0560, 16'h0015, 16'h0000};  //  3..0

wire [15:0] cga_or [0:16];
assign cga_or[0] = 16'h0000;
genvar gc;
generate
    for (gc = 0; gc < 16; gc = gc + 1) begin : g_cga
        assign cga_or[gc+1] = cga_or[gc] | ({16{cga_idx == gc[3:0]}} & CGA_TABLE[16*gc +: 16]);
    end
endgenerate

// RGB332 -> RGB565 by replicating the top bits of each field (as RGB565 ->
// RGB888 below): R 3 -> 5, G 3 -> 6, B 2 -> 5
wire [15:0] rgb332_565 = {raw_i[7:5], raw_i[7:6],
                          raw_i[4:2], raw_i[4:2],
                          raw_i[1:0], raw_i[1:0], raw_i[1]};

wire        bpp_idx = bpp4 | bpp2 | bpp1;
wire [15:0] hw_565  = ({16{bpp16  }} & raw_i     ) |
                      ({16{bpp8   }} & rgb332_565) |
                      ({16{bpp_idx}} & cga_or[16]);

// RGB565 -> RGB888
wire [23:0] hw_888  = {hw_565[15:11], hw_565[15:13],
                       hw_565[10:5],  hw_565[10:9],
                       hw_565[4:0],   hw_565[4:2]};

assign rgb_o = hw_888;

endmodule // blns_bk_hwcol

`default_nettype wire
