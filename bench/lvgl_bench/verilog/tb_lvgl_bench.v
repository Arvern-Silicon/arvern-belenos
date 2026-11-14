//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    tb_lvgl_bench
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_lvgl_bench.v
// Module Description : LVGL benchmark bench: an aRVern core in aRVern's
//                      Performance persona (RV32I, M with a 1-cycle
//                      multiplier and a 12-cycle divider, Zba/Zbb/Zbs/Zbc,
//                      Zca + Zcb, Zicntr, no taken-branch bubble), Belenos, and
//                      behavioural zero-wait memories, all on one clock
//                      (9 ns, 111 MHz). Every Belenos parameter <P> is set
//                      from the define BLNS_<P> (as tb_belenos.v; the
//                      persona comes from bin/lvgl_bench.py); the display is
//                      the built-in DPI driver on hclk (DIF_TYPE 4,
//                      DPI_PCLK_SEP 0) and the bench's DPI panel model, so
//                      the refresh reads the frame from the VRAM at the
//                      panel's rate. LB_W x LB_H is the frame size the
//                      firmware reads back (BENCH_CFG); the VRAM holds two
//                      such RGB565 frames unless BLNS_VRAM_WORDS says
//                      otherwise.
//
//                      Data-bus map (the instruction bus reaches the code
//                      memory only):
//                        0x1000_0000  bench registers (below)
//                        0x1005_0000  Belenos register port (4 KB)
//                        0x2000_0000  code memory, LB_CODE_SIZE bytes, loaded
//                                     from +code=<file> (text, rodata, the
//                                     data section's image)
//                        0x8000_0000  data memory, LB_RAM_SIZE bytes
//                        0x8200_0000  Belenos VRAM window
//                      Bench registers (32-bit, zero-wait):
//                        0x00 TTY        W: one character to the console
//                        0x04 EXIT       W: end of the simulation (0 = pass)
//                        0x08 MS         R: hclk cycles / LB_MS_CYCLES
//                        0x0C DUMP       W: n: the RGB565 frame at VRAM pixel
//                                        0 (what the firmware drew) to
//                                        frame_<n>.ppm
//                        0x18 DUMP_PANEL W: n: the panel model's last frame
//                                        (what the refresh showed) to
//                                        panel_<n>.ppm
//                        0x10 CYC_LO     R: cycle counter [31:0] (latches
//                                        [63:32] for CYC_HI)
//                        0x14 CYC_HI     R: [63:32] at the last CYC_LO read
//                        0x20 GPU_BUSY   R: cycles with GPU_STAT.BUSY
//                        0x24 VR_BK      R: VRAM grants to the refresh
//                        0x28 VR_WIN_RD  R: ... window reads (with read-ahead)
//                        0x2C VR_WIN_WR  R: ... window writes
//                        0x30 VR_GPU_RD  R: ... GPU reads
//                        0x34 VR_GPU_WR  R: ... GPU writes
//                        0x38 V_WAIT     R: VRAM-window wait cycles
//                        0x3C PANEL_FRM  R: frames the panel received
//                        0x40 CLK_HZ     R: the clock the bench stands for
//                        0x44 CFG        R: [15:0] LB_W, [31:16] LB_H
//                        0x48 PROF       W: n: with LB_PROFILE, the cycles
//                                        since the last write per 4-byte
//                                        code address (the last instruction
//                                        fetched: stalls count to it), one
//                                        "LB P n <word address> <cycles>"
//                                        line each; no effect without
//                      Every counter is a free-running 32-bit count from
//                      the end of reset.
//----------------------------------------------------------------------------
`include "timescale.v"

// Frame size (the firmware's resolution) and the VRAM it needs
`ifndef LB_W
   `define LB_W                 480
`endif
`ifndef LB_H
   `define LB_H                 272
`endif
`ifndef BLNS_VRAM_WORDS
   `define BLNS_VRAM_WORDS      (`LB_W * `LB_H)
`endif
`ifndef LB_CODE_SIZE
   `define LB_CODE_SIZE         (4 * 1024 * 1024)
`endif
`ifndef LB_RAM_SIZE
   `define LB_RAM_SIZE          (1024 * 1024)
`endif
// The clock: 9 ns (Belenos's Design Compiler period), MS = cycles / 111 000
`ifndef LB_CLK_HZ
   `define LB_CLK_HZ            111000000
`endif
`ifndef LB_MS_CYCLES
   `define LB_MS_CYCLES         111000
`endif
// Simulation limit in ms of simulated time (0 = none)
`ifndef LB_TIMEOUT_MS
   `define LB_TIMEOUT_MS        0
`endif

// Belenos parameters (defaults = the RTL defaults, the display = DPI on hclk)
`ifndef BLNS_VRAM_RD_LAT
   `define BLNS_VRAM_RD_LAT     1
`endif
`ifndef BLNS_VRAM_RD_REG_EN
   `define BLNS_VRAM_RD_REG_EN  0
`endif
`ifndef BLNS_DIM_W
   `define BLNS_DIM_W           10
`endif
`ifndef BLNS_FRAME_NR
   `define BLNS_FRAME_NR        2
`endif
`ifndef BLNS_LUT_EN
   `define BLNS_LUT_EN          1
`endif
`ifndef BLNS_LUT_BANKS
   `define BLNS_LUT_BANKS       2
`endif
`ifndef BLNS_GPU_EN
   `define BLNS_GPU_EN          1
`endif
`ifndef BLNS_GPU_XY_EN
   `define BLNS_GPU_XY_EN       1
`endif
`ifndef BLNS_GPU_GRAD_EN
   `define BLNS_GPU_GRAD_EN     1
`endif
`ifndef BLNS_GPU_BLEND_EN
   `define BLNS_GPU_BLEND_EN    0
`endif
`ifndef BLNS_GPU_TRI_EN
   `define BLNS_GPU_TRI_EN      0
`endif
`ifndef BLNS_GPU_RUNAHEAD_EN
   `define BLNS_GPU_RUNAHEAD_EN 0
`endif
`ifndef BLNS_GPU_REMAP_EN
   `define BLNS_GPU_REMAP_EN    1
`endif
`ifndef BLNS_GPU_MPLANE_EN
   `define BLNS_GPU_MPLANE_EN   1
`endif
`ifndef BLNS_GPU_IMM_EN
   `define BLNS_GPU_IMM_EN      1
`endif
`ifndef BLNS_GPU_LINE_EN
   `define BLNS_GPU_LINE_EN     1
`endif
`ifndef BLNS_GPU_BILINEAR_EN
   `define BLNS_GPU_BILINEAR_EN 0
`endif
`ifndef BLNS_GPU_FIFO_AW
   `define BLNS_GPU_FIFO_AW     3
`endif
`ifndef BLNS_CURSOR_EN
   `define BLNS_CURSOR_EN       1
`endif
`ifndef BLNS_DPI_LB_AW
   `define BLNS_DPI_LB_AW       10
`endif
`ifndef BLNS_DPI_SCALER
   `define BLNS_DPI_SCALER      0
`endif

module  tb_lvgl_bench;

// Bench parameters
parameter LB_W             = `LB_W;
parameter LB_H             = `LB_H;
parameter CODE_SIZE        = `LB_CODE_SIZE;
parameter RAM_SIZE         = `LB_RAM_SIZE;
parameter CLK_HZ           = `LB_CLK_HZ;
parameter MS_CYCLES        = `LB_MS_CYCLES;
parameter TIMEOUT_MS       = `LB_TIMEOUT_MS;

// Belenos parameters
parameter VRAM_WORDS       = `BLNS_VRAM_WORDS;
parameter VRAM_RD_LAT      = `BLNS_VRAM_RD_LAT;
parameter VRAM_RD_REG_EN   = `BLNS_VRAM_RD_REG_EN;
parameter DIM_W            = `BLNS_DIM_W;
parameter FRAME_NR         = `BLNS_FRAME_NR;
parameter LUT_EN           = `BLNS_LUT_EN;
parameter LUT_BANKS        = `BLNS_LUT_BANKS;
parameter GPU_EN           = `BLNS_GPU_EN;
parameter GPU_XY_EN        = `BLNS_GPU_XY_EN;
parameter GPU_GRAD_EN      = `BLNS_GPU_GRAD_EN;
parameter GPU_BLEND_EN     = `BLNS_GPU_BLEND_EN;
parameter GPU_TRI_EN       = `BLNS_GPU_TRI_EN;
parameter GPU_RUNAHEAD_EN  = `BLNS_GPU_RUNAHEAD_EN;
parameter GPU_REMAP_EN     = `BLNS_GPU_REMAP_EN;
parameter GPU_MPLANE_EN    = `BLNS_GPU_MPLANE_EN;
parameter GPU_IMM_EN       = `BLNS_GPU_IMM_EN;
parameter GPU_LINE_EN      = `BLNS_GPU_LINE_EN;
parameter GPU_BILINEAR_EN  = `BLNS_GPU_BILINEAR_EN;
parameter GPU_FIFO_AW      = `BLNS_GPU_FIFO_AW;
parameter CURSOR_EN        = `BLNS_CURSOR_EN;
parameter DPI_LB_AW        = `BLNS_DPI_LB_AW;
parameter DPI_SCALER       = `BLNS_DPI_SCALER;
localparam DPI_NB          = (DPI_SCALER == 2) ? 3 : 2;

localparam VRAM_AW         = (VRAM_WORDS > 8388608) ? 24 : (VRAM_WORDS > 4194304) ? 23 : (VRAM_WORDS > 2097152) ? 22 :
                             (VRAM_WORDS > 1048576) ? 21 : (VRAM_WORDS > 524288) ? 20 : (VRAM_WORDS > 262144) ? 19 :
                             (VRAM_WORDS > 131072) ? 18 : (VRAM_WORDS > 65536) ? 17 : (VRAM_WORDS > 32768) ? 16 :
                             (VRAM_WORDS > 16384) ? 15 : (VRAM_WORDS > 8192) ? 14 : (VRAM_WORDS > 4096) ? 13 :
                             (VRAM_WORDS > 2048) ? 12 : (VRAM_WORDS > 1024) ? 11 : (VRAM_WORDS > 512) ? 10 :
                             (VRAM_WORDS > 256) ? 9 : (VRAM_WORDS > 128) ? 8 : (VRAM_WORDS > 64) ? 7 :
                             (VRAM_WORDS > 32) ? 6 : (VRAM_WORDS > 16) ? 5 : (VRAM_WORDS > 8) ? 4 :
                             (VRAM_WORDS > 4) ? 3 : (VRAM_WORDS > 2) ? 2 : 1;

// Belenos arbiter requesters (blns_vram_arb in belenos_core.v)
localparam VRQ_WIN         = 0;
localparam VRQ_GPU         = 1;
localparam VRQ_BK          = 2;
localparam VRQ_WP          = 3;


//
// Clock and reset
//------------------------------
reg         hclk;
reg         hresetn;
initial begin
    hclk = 1'b0;
    forever #4.5 hclk = ~hclk;
end
initial begin
    hresetn = 1'b0;
    repeat (20) @(posedge hclk);
    #1 hresetn = 1'b1;
end


//
// aRVern core: aRVern's Performance persona, exactly (the arvern repository's
// sim/rtl_sim/bin/rtl_sweep_configs.py, PERSONAS "performance"; its
// published figures are in doc/benchmarking_guide.md section 2.1)
//------------------------------
wire [31:0] inst_haddr;
wire  [1:0] inst_htrans;
wire [31:0] inst_hrdata;
wire [31:0] data_haddr;
wire  [1:0] data_htrans;
wire        data_hwrite;
wire  [2:0] data_hsize;
wire [31:0] data_hwdata;
wire [31:0] data_hrdata;
wire        data_hready;
wire        data_hresp;
wire        blns_irq;

wire  [2:0] inst_hburst_unused, data_hburst_unused;
wire        inst_hmastlock_unused, data_hmastlock_unused;
wire  [3:0] inst_hprot_unused, data_hprot;
wire  [2:0] inst_hsize_unused;
wire        inst_hsmode_unused, data_hsmode;
wire [31:0] inst_hwdata_unused;
wire        inst_hwrite_unused;
wire        hclk_en_unused, data_hmaster_unused, lockup_unused, time_req_unused;
wire        dbg_mode_unused, dbg_halted_unused, dbg_stoptime_unused, dbg_ndmreset_unused;
wire        dmi_pready_unused, dmi_pslverr_unused;
wire [31:0] dmi_prdata_unused;
wire [10:0] ccsr_bank_unused;
wire [63:0] ccsr_reg_sel_unused;
wire [31:0] ccsr_wdata_unused;
wire        ccsr_wen_unused;

arvern #(
    .RV32E_EN            ( 0 ),
    .SU_MODE_EN          ( 1 ),
    .PMP_NR              ( 4 ),
    .ZICNTR_EN           ( 1 ),
    .ZIHPM_NR            ( 0 ),
    .B_EXTENSION         ( 4 ),
    .C_EXTENSION         ( 2 ),
    .M_EXTENSION         ( 2 ),
    .MUL_TYPE            ( 1 ),
    .DIV_TYPE            ( 1 ),
    .CCSR_EN             ( 0 ),
    .SINGLE_CYCLE_BRANCH ( 1 ),
    .ASYNC_RST_EN        ( 1 ),
    .DEBUG_EN            ( 0 ),
    .DM_TRIGGER_NR       ( 0 )
) u_cpu (
    .hclk_i                ( hclk                  ),
    .hresetn_i             ( hresetn               ),
    .dbgresetn_i           ( hresetn               ),
    .hclk_en_o             ( hclk_en_unused        ),

    .inst_hrdata_i         ( inst_hrdata           ),
    .inst_hready_i         ( 1'b1                  ),
    .inst_hresp_i          ( 1'b0                  ),
    .inst_haddr_o          ( inst_haddr            ),
    .inst_hburst_o         ( inst_hburst_unused    ),
    .inst_hmastlock_o      ( inst_hmastlock_unused ),
    .inst_hprot_o          ( inst_hprot_unused     ),
    .inst_hsize_o          ( inst_hsize_unused     ),
    .inst_hsmode_o         ( inst_hsmode_unused    ),
    .inst_htrans_o         ( inst_htrans           ),
    .inst_hwdata_o         ( inst_hwdata_unused    ),
    .inst_hwrite_o         ( inst_hwrite_unused    ),

    .data_hrdata_i         ( data_hrdata           ),
    .data_hready_i         ( data_hready           ),
    .data_hresp_i          ( data_hresp            ),
    .data_haddr_o          ( data_haddr            ),
    .data_hburst_o         ( data_hburst_unused    ),
    .data_hmastlock_o      ( data_hmastlock_unused ),
    .data_hprot_o          ( data_hprot            ),
    .data_hsize_o          ( data_hsize            ),
    .data_hsmode_o         ( data_hsmode           ),
    .data_htrans_o         ( data_htrans           ),
    .data_hwdata_o         ( data_hwdata           ),
    .data_hwrite_o         ( data_hwrite           ),

    .ccsr_rdata_i          ( 32'h0                 ),
    .ccsr_bank_o           ( ccsr_bank_unused      ),
    .ccsr_reg_sel_o        ( ccsr_reg_sel_unused   ),
    .ccsr_wdata_o          ( ccsr_wdata_unused     ),
    .ccsr_wen_o            ( ccsr_wen_unused       ),

    .data_hmaster_o        ( data_hmaster_unused   ),
    .dbg_debug_mode_o      ( dbg_mode_unused       ),
    .dbg_halted_o          ( dbg_halted_unused     ),
    .dbg_stoptime_o        ( dbg_stoptime_unused   ),
    .dbg_ndmreset_o        ( dbg_ndmreset_unused   ),
    .dmi_psel_i            ( 1'b0                  ),
    .dmi_penable_i         ( 1'b0                  ),
    .dmi_paddr_i           ( 9'h0                  ),
    .dmi_pwrite_i          ( 1'b0                  ),
    .dmi_pwdata_i          ( 32'h0                 ),
    .dmi_pprot_i           ( 3'h0                  ),
    .dmi_pready_o          ( dmi_pready_unused     ),
    .dmi_prdata_o          ( dmi_prdata_unused     ),
    .dmi_pslverr_o         ( dmi_pslverr_unused    ),

    .irq_m_software_i      ( 1'b0                  ),
    .irq_s_software_i      ( 1'b0                  ),
    .irq_m_timer_i         ( 1'b0                  ),
    .irq_m_external_i      ( 1'b0                  ),
    .irq_s_external_i      ( 1'b0                  ),
    .irq_platform_i        ( {15'h0000, blns_irq}  ),

    .hartid_i              ( 8'h00                 ),
    .reset_vector_i        ( 32'h2000_0000         ),
    .lockup_o              ( lockup_unused         ),
    .nmi_i                 ( 1'b0                  ),
    .time_req_o            ( time_req_unused       ),
    .time_gnt_i            ( 1'b1                  ),
    .time_val_i            ( 64'h0                 ),
    .hpm_platform_events_i ( 8'h00                 )
);


//
// Data-bus decoder: the address phase selects, the data phase muxes the
// response of the subordinate selected in the address phase
//------------------------------
localparam S_NONE = 3'd0, S_BENCH = 3'd1, S_BREG = 3'd2, S_CODE = 3'd3, S_RAM = 3'd4, S_VRAM = 3'd5;

function [2:0] decode;
    input [31:0] a;
    begin
        if      (a[31:12] == 20'h10000)                                     decode = S_BENCH;
        else if (a[31:12] == 20'h10050)                                     decode = S_BREG;
        else if ((a >= 32'h2000_0000) && (a < 32'h2000_0000 + CODE_SIZE))   decode = S_CODE;
        else if ((a >= 32'h8000_0000) && (a < 32'h8000_0000 + RAM_SIZE))    decode = S_RAM;
        else if ((a >= 32'h8200_0000) && (a < 32'h8200_0000 + VRAM_WORDS*4)) decode = S_VRAM;
        else                                                                decode = S_NONE;
    end
endfunction

wire  [2:0] sel_a  = decode(data_haddr);
wire        trans  = data_htrans[1];
reg   [2:0] sel_d;
always @(posedge hclk)
    if (!hresetn)          sel_d <= S_NONE;
    else if (data_hready)  sel_d <= trans ? sel_a : S_NONE;

always @(posedge hclk)
    if (hresetn && data_hready && trans && (sel_a == S_NONE)) begin
        $display("ERROR: data access to an unmapped address 0x%h %t", data_haddr, $time);
        $finish;
    end

wire [31:0] bench_hrdata, code_hrdata, ram_hrdata, breg_hrdata, vram_hrdata;
wire        breg_hreadyout, breg_hresp, vram_hreadyout, vram_hresp;

assign data_hrdata = (sel_d == S_BENCH) ? bench_hrdata :
                     (sel_d == S_BREG)  ? breg_hrdata  :
                     (sel_d == S_CODE)  ? code_hrdata  :
                     (sel_d == S_RAM)   ? ram_hrdata   :
                     (sel_d == S_VRAM)  ? vram_hrdata  : 32'h0;
assign data_hready = (sel_d == S_BREG)  ? breg_hreadyout :
                     (sel_d == S_VRAM)  ? vram_hreadyout : 1'b1;
assign data_hresp  = (sel_d == S_BREG)  ? breg_hresp     :
                     (sel_d == S_VRAM)  ? vram_hresp     : 1'b0;


//
// Code memory (instruction port + data port) and data memory
//------------------------------
lb_ahb_mem #(.SIZE(CODE_SIZE), .INIT_EN(1)) u_code (
    .hclk_i      ( hclk                               ),
    .hresetn_i   ( hresetn                            ),
    .a_hsel_i    ( 1'b1                               ),
    .a_haddr_i   ( inst_haddr - 32'h2000_0000         ),
    .a_htrans_i  ( inst_htrans                        ),
    .a_hready_i  ( 1'b1                               ),
    .a_hrdata_o  ( inst_hrdata                        ),
    .b_hsel_i    ( sel_a == S_CODE                    ),
    .b_haddr_i   ( data_haddr - 32'h2000_0000         ),
    .b_htrans_i  ( data_htrans                        ),
    .b_hwrite_i  ( data_hwrite                        ),
    .b_hsize_i   ( data_hsize                         ),
    .b_hready_i  ( data_hready                        ),
    .b_hwdata_i  ( data_hwdata                        ),
    .b_hrdata_o  ( code_hrdata                        )
);

wire [31:0] ram_a_unused;
lb_ahb_mem #(.SIZE(RAM_SIZE), .INIT_EN(0)) u_ram (
    .hclk_i      ( hclk                               ),
    .hresetn_i   ( hresetn                            ),
    .a_hsel_i    ( 1'b0                               ),
    .a_haddr_i   ( 32'h0                              ),
    .a_htrans_i  ( 2'b00                              ),
    .a_hready_i  ( 1'b1                               ),
    .a_hrdata_o  ( ram_a_unused                       ),
    .b_hsel_i    ( sel_a == S_RAM                     ),
    .b_haddr_i   ( data_haddr - 32'h8000_0000         ),
    .b_htrans_i  ( data_htrans                        ),
    .b_hwrite_i  ( data_hwrite                        ),
    .b_hsize_i   ( data_hsize                         ),
    .b_hready_i  ( data_hready                        ),
    .b_hwdata_i  ( data_hwdata                        ),
    .b_hrdata_o  ( ram_hrdata                         )
);


//
// Belenos, its VRAM and LUT macros (VRAM_RD_LAT-cycle synchronous SRAM, as
// bench/verilog/tb_belenos.v), DPI line buffers and the panel model
//------------------------------
wire                 vram_cen;
wire           [3:0] vram_wen;
wire   [VRAM_AW-1:0] vram_addr;
wire          [31:0] vram_din;
reg           [31:0] vram_rd0, vram_rd1, vram_rd2;
reg           [31:0] vram_mem [0:VRAM_WORDS-1];
wire          [31:0] vram_dout;
wire                 lut_cen;
wire                 lut_wen;
wire           [8:0] lut_addr;
wire          [23:0] lut_din;
reg           [23:0] lut_dout;
reg           [23:0] lut_mem [0:511];
wire                 dpi_de, dpi_hs, dpi_vs;
wire          [23:0] dpi_rgb;
wire                 dpi_clk_d0, dpi_clk_d1;
wire    [DPI_NB-1:0] dpi_lb_we;
wire [DPI_LB_AW-1:0] dpi_lb_waddr;
wire          [23:0] dpi_lb_wdata;
wire [DPI_LB_AW-1:0] dpi_lb_raddr;
reg [DPI_NB*24-1:0]  dpi_lb_rdata;

integer vram_init_idx;
initial begin
    for (vram_init_idx = 0; vram_init_idx < VRAM_WORDS; vram_init_idx = vram_init_idx + 1)
        vram_mem[vram_init_idx] = 32'h0000_0000;
    for (vram_init_idx = 0; vram_init_idx < 512; vram_init_idx = vram_init_idx + 1)
        lut_mem[vram_init_idx] = 24'h00_0000;
    vram_rd0 = 32'h0; vram_rd1 = 32'h0; vram_rd2 = 32'h0; lut_dout = 24'h0;
end

always @(posedge hclk)
    if (vram_cen === 1'b0) begin
        if (vram_wen !== 4'hF) begin
            if (vram_wen[0] === 1'b0) vram_mem[vram_addr][ 7: 0] <= vram_din[ 7: 0];
            if (vram_wen[1] === 1'b0) vram_mem[vram_addr][15: 8] <= vram_din[15: 8];
            if (vram_wen[2] === 1'b0) vram_mem[vram_addr][23:16] <= vram_din[23:16];
            if (vram_wen[3] === 1'b0) vram_mem[vram_addr][31:24] <= vram_din[31:24];
        end else
            vram_rd0 <= vram_mem[vram_addr];
    end
always @(posedge hclk) begin
    vram_rd1 <= vram_rd0;
    vram_rd2 <= vram_rd1;
end
assign vram_dout = (VRAM_RD_LAT >= 3) ? vram_rd2 : (VRAM_RD_LAT == 2) ? vram_rd1 : vram_rd0;

always @(posedge hclk)
    if (lut_cen === 1'b0) begin
        if (lut_wen === 1'b0) lut_mem[lut_addr] <= lut_din;
        else                  lut_dout          <= lut_mem[lut_addr];
    end

reg     [23:0] dpi_lb_mem [0:DPI_NB*(1<<DPI_LB_AW)-1];
integer        dpi_lb_b;
always @(posedge hclk)
    for (dpi_lb_b = 0; dpi_lb_b < DPI_NB; dpi_lb_b = dpi_lb_b + 1) begin
        if (dpi_lb_we[dpi_lb_b] === 1'b1) dpi_lb_mem[dpi_lb_b*(1<<DPI_LB_AW) + dpi_lb_waddr] <= dpi_lb_wdata;
        dpi_lb_rdata[dpi_lb_b*24 +: 24] <= dpi_lb_mem[dpi_lb_b*(1<<DPI_LB_AW) + dpi_lb_raddr];
    end

// DDR clock output register: d0 in the first half of the period, d1 in the second
reg dpi_ddr1, dpi_clk_pin;
initial begin dpi_ddr1 = 1'b0; dpi_clk_pin = 1'b0; end
always @(posedge hclk) begin dpi_clk_pin <= dpi_clk_d0; dpi_ddr1 <= dpi_clk_d1; end
always @(negedge hclk) dpi_clk_pin <= dpi_ddr1;

dpi_panel_model #(.W_MAX(LB_W), .H_MAX(LB_H)) u_panel (
    .clk_i       ( dpi_clk_pin & hresetn ),
    .de_i        ( dpi_de                ),
    .hs_i        ( dpi_hs                ),
    .vs_i        ( dpi_vs                ),
    .rgb_i       ( dpi_rgb               )
);

wire [15:0] lcd_d_unused;
wire        lcd_d_oe_unused, lcd_cs_n_unused, lcd_rd_n_unused, lcd_wr_n_unused, lcd_dc_unused;
wire        lcd_reset_n_unused, lcd_on_unused;
wire        spi_sck_unused, spi_mosi_unused, spi_cs_n_unused, spi_dc_unused;
wire [29:0] tmds_unused;
wire        ddc_scl_pd_unused, ddc_sda_pd_unused;
wire        bdi_px_valid_unused, bdi_px_last_unused, bdi_refresh_trig_unused;
wire [23:0] bdi_px_data_unused;
wire [DIM_W-1:0] bdi_width_unused, bdi_height_unused;
wire        bdi_reg_sel_unused, bdi_reg_wr_unused;
wire  [5:0] bdi_reg_addr_unused;
wire [31:0] bdi_reg_wdata_unused;
wire        blns_hclk_en_unused;

belenos #(
    .VRAM_WORDS           ( VRAM_WORDS         ),
    .VRAM_RD_LAT          ( VRAM_RD_LAT        ),
    .VRAM_RD_REG_EN       ( VRAM_RD_REG_EN     ),
    .DIM_W                ( DIM_W              ),
    .FRAME_NR             ( FRAME_NR           ),
    .LUT_EN               ( LUT_EN             ),
    .LUT_BANKS            ( LUT_BANKS          ),
    .GPU_EN               ( GPU_EN             ),
    .GPU_XY_EN            ( GPU_XY_EN          ),
    .GPU_GRAD_EN          ( GPU_GRAD_EN        ),
    .GPU_BLEND_EN         ( GPU_BLEND_EN       ),
    .GPU_TRI_EN           ( GPU_TRI_EN         ),
    .GPU_RUNAHEAD_EN      ( GPU_RUNAHEAD_EN    ),
    .GPU_REMAP_EN         ( GPU_REMAP_EN       ),
    .GPU_MPLANE_EN        ( GPU_MPLANE_EN      ),
    .GPU_IMM_EN           ( GPU_IMM_EN         ),
    .GPU_LINE_EN          ( GPU_LINE_EN        ),
    .GPU_BILINEAR_EN      ( GPU_BILINEAR_EN    ),
    .GPU_FIFO_AW          ( GPU_FIFO_AW        ),
    .DIF_TYPE             ( 4                  ),
    .DPI_LB_AW            ( DPI_LB_AW          ),
    .DPI_SCALER           ( DPI_SCALER         ),
    .DPI_PCLK_SEP         ( 0                  ),
    .CURSOR_EN            ( CURSOR_EN          ),
    .PRIV_CHECK_EN        ( 0                  ),
    .ASYNC_RST_EN         ( 1                  )
) dut (
    .hclk_i               ( hclk                         ),
    .hresetn_i            ( hresetn                      ),
    .hclk_en_o            ( blns_hclk_en_unused          ),

    .r_hsel_i             ( sel_a == S_BREG              ),
    .r_haddr_i            ( data_haddr[11:0]             ),
    .r_htrans_i           ( data_htrans                  ),
    .r_hwrite_i           ( data_hwrite                  ),
    .r_hsize_i            ( data_hsize                   ),
    .r_hprot_i            ( data_hprot                   ),
    .r_hsmode_i           ( data_hsmode                  ),
    .r_hready_i           ( data_hready                  ),
    .r_hwdata_i           ( data_hwdata                  ),
    .r_hrdata_o           ( breg_hrdata                  ),
    .r_hreadyout_o        ( breg_hreadyout               ),
    .r_hresp_o            ( breg_hresp                   ),

    .v_hsel_i             ( sel_a == S_VRAM              ),
    .v_haddr_i            ( data_haddr[VRAM_AW+1:0]      ),
    .v_htrans_i           ( data_htrans                  ),
    .v_hwrite_i           ( data_hwrite                  ),
    .v_hsize_i            ( data_hsize                   ),
    .v_hprot_i            ( data_hprot                   ),
    .v_hsmode_i           ( data_hsmode                  ),
    .v_hready_i           ( data_hready                  ),
    .v_hwdata_i           ( data_hwdata                  ),
    .v_hrdata_o           ( vram_hrdata                  ),
    .v_hreadyout_o        ( vram_hreadyout               ),
    .v_hresp_o            ( vram_hresp                   ),

    .vram_cen_o           ( vram_cen                     ),
    .vram_wen_o           ( vram_wen                     ),
    .vram_addr_o          ( vram_addr                    ),
    .vram_din_o           ( vram_din                     ),
    .vram_dout_i          ( vram_dout                    ),

    .lut_cen_o            ( lut_cen                      ),
    .lut_wen_o            ( lut_wen                      ),
    .lut_addr_o           ( lut_addr                     ),
    .lut_din_o            ( lut_din                      ),
    .lut_dout_i           ( lut_dout                     ),

    .dbg_stoptime_i       ( 1'b0                         ),
    .irq_o                ( blns_irq                     ),

    .lcd_d_i              ( 16'h0000                     ),
    .lcd_d_o              ( lcd_d_unused                 ),
    .lcd_d_oe_o           ( lcd_d_oe_unused              ),
    .lcd_cs_n_o           ( lcd_cs_n_unused              ),
    .lcd_rd_n_o           ( lcd_rd_n_unused              ),
    .lcd_wr_n_o           ( lcd_wr_n_unused              ),
    .lcd_dc_o             ( lcd_dc_unused                ),
    .spi_sck_o            ( spi_sck_unused               ),
    .spi_mosi_o           ( spi_mosi_unused              ),
    .spi_miso_i           ( 1'b0                         ),
    .spi_cs_n_o           ( spi_cs_n_unused              ),
    .spi_dc_o             ( spi_dc_unused                ),
    .lcd_reset_n_o        ( lcd_reset_n_unused           ),
    .lcd_on_o             ( lcd_on_unused                ),
    .lcd_te_i             ( 1'b0                         ),

    .dpi_de_o             ( dpi_de                       ),
    .dpi_hs_o             ( dpi_hs                       ),
    .dpi_vs_o             ( dpi_vs                       ),
    .dpi_rgb_o            ( dpi_rgb                      ),
    .dpi_clk_d0_o         ( dpi_clk_d0                   ),
    .dpi_clk_d1_o         ( dpi_clk_d1                   ),
    .dpi_pclk_i           ( 1'b0                         ),
    .dpi_presetn_i        ( 1'b0                         ),
    .panel_detect_i       ( 1'b1                         ),
    .tmds_o               ( tmds_unused                  ),
    .ddc_scl_i            ( 1'b1                         ),
    .ddc_sda_i            ( 1'b1                         ),
    .ddc_scl_pd_o         ( ddc_scl_pd_unused            ),
    .ddc_sda_pd_o         ( ddc_sda_pd_unused            ),
    .i2s_bclk_i           ( 1'b0                         ),
    .i2s_lrck_i           ( 1'b0                         ),
    .i2s_sd_i             ( 1'b0                         ),
    .dpi_lb_we_o          ( dpi_lb_we                    ),
    .dpi_lb_waddr_o       ( dpi_lb_waddr                 ),
    .dpi_lb_wdata_o       ( dpi_lb_wdata                 ),
    .dpi_lb_raddr_o       ( dpi_lb_raddr                 ),
    .dpi_lb_rdata_i       ( dpi_lb_rdata                 ),

    .bdi_px_valid_o       ( bdi_px_valid_unused          ),
    .bdi_px_data_o        ( bdi_px_data_unused           ),
    .bdi_px_last_o        ( bdi_px_last_unused           ),
    .bdi_px_ready_i       ( 1'b1                         ),
    .bdi_refresh_trig_o   ( bdi_refresh_trig_unused      ),
    .bdi_refresh_active_i ( 1'b0                         ),
    .bdi_width_o          ( bdi_width_unused             ),
    .bdi_height_o         ( bdi_height_unused            ),
    .bdi_reg_sel_o        ( bdi_reg_sel_unused           ),
    .bdi_reg_addr_o       ( bdi_reg_addr_unused          ),
    .bdi_reg_wr_o         ( bdi_reg_wr_unused            ),
    .bdi_reg_wdata_o      ( bdi_reg_wdata_unused         ),
    .bdi_reg_rdata_i      ( 32'h0                        ),
    .bdi_reg_ready_i      ( 1'b1                         ),
    .bdi_irq_i            ( 1'b0                         ),
    .bdi_busy_i           ( 1'b0                         )
);


//
// Bench counters
//------------------------------
`define LB_ARB dut.u_core.u_vram_arb

reg  [63:0] cnt_cyc;
reg  [31:0] cnt_ms, ms_div;
reg  [31:0] cnt_gpu_busy, cnt_bk, cnt_win_rd, cnt_win_wr, cnt_gpu_rd, cnt_gpu_wr, cnt_v_wait;
wire        gpu_busy;

generate
    if (GPU_EN != 0) begin : g_gpu_busy
        assign gpu_busy = dut.u_core.G_GPU.u_gpu.busy_o;
    end else begin : g_no_gpu
        assign gpu_busy = 1'b0;
    end
endgenerate

always @(posedge hclk)
    if (!hresetn) begin
        cnt_cyc    <= 64'h0;  cnt_ms     <= 32'h0;  ms_div       <= 32'h0;
        cnt_bk     <= 32'h0;  cnt_win_rd <= 32'h0;  cnt_win_wr   <= 32'h0;
        cnt_gpu_rd <= 32'h0;  cnt_gpu_wr <= 32'h0;  cnt_gpu_busy <= 32'h0;
        cnt_v_wait <= 32'h0;
    end else begin
        cnt_cyc <= cnt_cyc + 64'h1;
        if (ms_div == MS_CYCLES - 1) begin ms_div <= 32'h0; cnt_ms <= cnt_ms + 32'h1; end
        else                                 ms_div <= ms_div + 32'h1;
        if (`LB_ARB.gnt_o[VRQ_BK])                                  cnt_bk     <= cnt_bk     + 32'h1;
        if ((`LB_ARB.gnt_o[VRQ_WIN] && !`LB_ARB.we_i[VRQ_WIN]) ||
             `LB_ARB.gnt_o[VRQ_WP])                                 cnt_win_rd <= cnt_win_rd + 32'h1;
        if ( `LB_ARB.gnt_o[VRQ_WIN] &&  `LB_ARB.we_i[VRQ_WIN])      cnt_win_wr <= cnt_win_wr + 32'h1;
        if ( `LB_ARB.gnt_o[VRQ_GPU] && !`LB_ARB.we_i[VRQ_GPU])      cnt_gpu_rd <= cnt_gpu_rd + 32'h1;
        if ( `LB_ARB.gnt_o[VRQ_GPU] &&  `LB_ARB.we_i[VRQ_GPU])      cnt_gpu_wr <= cnt_gpu_wr + 32'h1;
        if (gpu_busy)                                               cnt_gpu_busy <= cnt_gpu_busy + 32'h1;
        if ((sel_d == S_VRAM) && !vram_hreadyout)                   cnt_v_wait <= cnt_v_wait + 32'h1;
    end


//
// Bench registers
//------------------------------
reg   [7:0] bench_addr_q;
reg         bench_wr_q;
reg  [31:0] cyc_hi_q;
always @(posedge hclk)
    if (!hresetn) begin
        bench_addr_q <= 8'h0;
        bench_wr_q   <= 1'b0;
    end else if (data_hready) begin
        bench_wr_q   <= trans && (sel_a == S_BENCH) && data_hwrite;
        if (trans && (sel_a == S_BENCH))
            bench_addr_q <= data_haddr[7:0];
    end

assign bench_hrdata = (bench_addr_q == 8'h08) ? cnt_ms                :
                      (bench_addr_q == 8'h10) ? cnt_cyc[31:0]         :
                      (bench_addr_q == 8'h14) ? cyc_hi_q              :
                      (bench_addr_q == 8'h20) ? cnt_gpu_busy          :
                      (bench_addr_q == 8'h24) ? cnt_bk                :
                      (bench_addr_q == 8'h28) ? cnt_win_rd            :
                      (bench_addr_q == 8'h2C) ? cnt_win_wr            :
                      (bench_addr_q == 8'h30) ? cnt_gpu_rd            :
                      (bench_addr_q == 8'h34) ? cnt_gpu_wr            :
                      (bench_addr_q == 8'h38) ? cnt_v_wait            :
                      (bench_addr_q == 8'h3C) ? u_panel.frames        :
                      (bench_addr_q == 8'h40) ? CLK_HZ                :
                      (bench_addr_q == 8'h44) ? {LB_H[15:0], LB_W[15:0]} : 32'h0;

// CYC_HI holds the upper half seen by the last CYC_LO read
always @(posedge hclk)
    if (!hresetn)                                               cyc_hi_q <= 32'h0;
    else if ((sel_d == S_BENCH) && !bench_wr_q && (bench_addr_q == 8'h10)) cyc_hi_q <= cnt_cyc[63:32];

// Console: characters to stdout (CR dropped), flushed at each line end
always @(posedge hclk)
    if (bench_wr_q && data_hready) begin
        case (bench_addr_q)
            8'h00: begin
                if (data_hwdata[7:0] != 8'h0D)
                    $write("%c", data_hwdata[7:0]);
                if (data_hwdata[7:0] == 8'h0A)
                    $fflush;
            end
            8'h04: begin
                $display("EXIT: code %0d at cycle %0d", data_hwdata, cnt_cyc);
                if (data_hwdata == 32'h0) begin
                    $display(" ===============================================");
                    $display("|               SIMULATION PASSED               |");
                    $display(" ===============================================");
                end else begin
                    $display(" ===============================================");
                    $display("|               SIMULATION FAILED               |");
                    $display(" ===============================================");
                end
                $finish;
            end
            8'h0C: dump_frame(data_hwdata, 1'b0);
            8'h18: dump_frame(data_hwdata, 1'b1);
`ifdef LB_PROFILE
            8'h48: begin
                foreach (prof[k])
                    $display("LB P %0d %h %0d", data_hwdata, k, prof[k]);
                prof.delete();
            end
`endif
            default: ;
        endcase
    end

`ifdef LB_PROFILE
// The CPU's profile: each cycle counted to the code word fetched last
int unsigned prof [int unsigned];
reg   [29:0] prof_pc = 30'h0;
always @(posedge hclk) begin
    if (inst_htrans[1])
        prof_pc <= inst_haddr[31:2];
    prof[{2'b00, prof_pc}] = prof[{2'b00, prof_pc}] + 1;
end
`endif

// A frame as a binary PPM: the VRAM's (RGB565 at pixel 0) or the panel's
task dump_frame;
    input [31:0] n;
    input        panel;
    integer fd, i;
    reg [8*64-1:0] fname;
    reg     [15:0] px;
    begin
        if (panel) $sformat(fname, "panel_%0d.ppm", n);
        else       $sformat(fname, "frame_%0d.ppm", n);
        fd = $fopen(fname, "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", LB_W, LB_H);
        for (i = 0; i < LB_W * LB_H; i = i + 1)
            if (panel)
                $fwrite(fd, "%c%c%c", u_panel.fb[i][23:16], u_panel.fb[i][15:8], u_panel.fb[i][7:0]);
            else begin
                px = i[0] ? vram_mem[i/2][31:16] : vram_mem[i/2][15:0];
                $fwrite(fd, "%c%c%c", {px[15:11], px[15:13]}, {px[10:5], px[10:9]}, {px[4:0], px[4:2]});
            end
        $fclose(fd);
        $display("DUMP: %0s (panel frames %0d)", fname, u_panel.frames);
    end
endtask

// Optional time limit
initial
    if (TIMEOUT_MS != 0) begin
        #(TIMEOUT_MS * 1000000.0);
        $display("ERROR: simulation timeout after %0d ms", TIMEOUT_MS);
        $display(" ===============================================");
        $display("|               SIMULATION FAILED               |");
        $display("|              (simulation Timeout)             |");
        $display(" ===============================================");
        $finish;
    end

endmodule // tb_lvgl_bench
