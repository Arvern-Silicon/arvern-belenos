//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    lb_ahb_mem
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : lb_ahb_mem.v
// Module Description : LVGL benchmark bench: behavioural zero-wait AHB-Lite
//                      memory, SIZE bytes, with two subordinate ports on one
//                      array: port A (the instruction bus, read only) and
//                      port B (the data bus, reads and byte/half/word
//                      writes). Both are always ready (HREADYOUT = 1, OKAY):
//                      the address phase is registered, read data comes
//                      from the array in the data phase, a write lands at
//                      the end of its data phase. A port's transfer outside
//                      the array is an error of the bench ($finish).
//                      With INIT_EN the image named by the plusarg
//                      +code=<file> is loaded with $readmemh (one 32-bit
//                      word per line from word 0) after the zero fill.
//----------------------------------------------------------------------------

module lb_ahb_mem #(
    parameter SIZE      = 1048576,          // bytes (a multiple of 4)
    parameter INIT_EN   = 0                 // 1: load +code=<file>
) (
    input  wire        hclk_i,
    input  wire        hresetn_i,

// Port A: instruction fetch (read only)
    input  wire        a_hsel_i,
    input  wire [31:0] a_haddr_i,
    input  wire  [1:0] a_htrans_i,
    input  wire        a_hready_i,
    output wire [31:0] a_hrdata_o,

// Port B: data
    input  wire        b_hsel_i,
    input  wire [31:0] b_haddr_i,
    input  wire  [1:0] b_htrans_i,
    input  wire        b_hwrite_i,
    input  wire  [2:0] b_hsize_i,
    input  wire        b_hready_i,
    input  wire [31:0] b_hwdata_i,
    output wire [31:0] b_hrdata_o
);

localparam WORDS = SIZE / 4;

reg  [31:0] mem [0:WORDS-1];

integer         init_idx;
reg [8*256-1:0] init_file;
initial begin
    for (init_idx = 0; init_idx < WORDS; init_idx = init_idx + 1)
        mem[init_idx] = 32'h0000_0000;
    if (INIT_EN != 0) begin
        if ($value$plusargs("code=%s", init_file))
            $readmemh(init_file, mem);
        else begin
            $display("ERROR: lb_ahb_mem: no +code=<file> image");
            $finish;
        end
    end
end

//
// Port A
//------------------------------
reg  [31:0] a_addr_q;
always @(posedge hclk_i or negedge hresetn_i)
    if (!hresetn_i)                                     a_addr_q <= 32'h0;
    else if (a_hready_i && a_hsel_i && a_htrans_i[1]) begin
        if (a_haddr_i[31:2] >= WORDS) begin
            $display("ERROR: lb_ahb_mem port A: fetch beyond the memory at 0x%h %t", a_haddr_i, $time);
            $finish;
        end
        a_addr_q <= a_haddr_i;
    end

assign a_hrdata_o = mem[a_addr_q[31:2]];

//
// Port B
//------------------------------
reg  [31:0] b_addr_q;
reg         b_wr_q;
reg   [2:0] b_size_q;
always @(posedge hclk_i or negedge hresetn_i)
    if (!hresetn_i) begin
        b_addr_q <= 32'h0;
        b_wr_q   <= 1'b0;
        b_size_q <= 3'b010;
    end else if (b_hready_i) begin
        b_wr_q <= b_hsel_i && b_htrans_i[1] && b_hwrite_i;
        if (b_hsel_i && b_htrans_i[1]) begin
            if (b_haddr_i[31:2] >= WORDS) begin
                $display("ERROR: lb_ahb_mem port B: access beyond the memory at 0x%h %t", b_haddr_i, $time);
                $finish;
            end
            b_addr_q <= b_haddr_i;
            b_size_q <= b_hsize_i;
        end
    end

// Byte lanes of the write in its data phase (little-endian)
wire  [3:0] b_be = (b_size_q == 3'b000) ? (4'b0001 << b_addr_q[1:0]) :
                   (b_size_q == 3'b001) ? (b_addr_q[1] ? 4'b1100 : 4'b0011) : 4'b1111;

always @(posedge hclk_i)
    if (b_wr_q && b_hready_i) begin
        if (b_be[0]) mem[b_addr_q[31:2]][ 7: 0] <= b_hwdata_i[ 7: 0];
        if (b_be[1]) mem[b_addr_q[31:2]][15: 8] <= b_hwdata_i[15: 8];
        if (b_be[2]) mem[b_addr_q[31:2]][23:16] <= b_hwdata_i[23:16];
        if (b_be[3]) mem[b_addr_q[31:2]][31:24] <= b_hwdata_i[31:24];
    end

assign b_hrdata_o = mem[b_addr_q[31:2]];

endmodule // lb_ahb_mem
