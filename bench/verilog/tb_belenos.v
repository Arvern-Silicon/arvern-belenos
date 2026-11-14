//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    tb_belenos
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_belenos.v
// Module Description : Belenos block-level testbench. Parameter-driven DUT
//                      instantiation: every DUT parameter <P> is set from the
//                      define BLNS_<P> (defaults = the RTL defaults), so the
//                      sweep runner overrides them with -D flags. Provides
//                      the clock (optionally through an ICG model driven by
//                      hclk_en_o, BLNS_ICG_EN=1), the reset, two AHB-Lite
//                      managers (register port and VRAM window), the VRAM and
//                      LUT macro models, ILI9341 8080 and SPI panel models,
//                      and `includes the selected stimulus file (symlinked as
//                      stimulus.v by the runner).
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef BLNS_VRAM_WORDS
   `define BLNS_VRAM_WORDS      38400
`endif
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
`ifndef BLNS_DIF_TYPE
   `define BLNS_DIF_TYPE        2
`endif
`ifndef BLNS_DPI_LB_AW
   `define BLNS_DPI_LB_AW       10
`endif
`ifndef BLNS_DPI_SCALER
   `define BLNS_DPI_SCALER      1
`endif
`ifndef BLNS_DPI_PCLK_SEP
   `define BLNS_DPI_PCLK_SEP    0
`endif
`ifndef BLNS_DPI_DDC_EN
   `define BLNS_DPI_DDC_EN      1
`endif
`ifndef BLNS_DPI_ISLAND_EN
   `define BLNS_DPI_ISLAND_EN   1
`endif
`ifndef BLNS_DPI_AUDIO_EN
   `define BLNS_DPI_AUDIO_EN    0
`endif
`ifndef BLNS_CURSOR_EN
   `define BLNS_CURSOR_EN       1
`endif
`ifndef BLNS_PRIV_CHECK_EN
   `define BLNS_PRIV_CHECK_EN   0
`endif
`ifndef BLNS_ASYNC_RST_EN
   `define BLNS_ASYNC_RST_EN    1
`endif
// Bench only: 1 = hclk goes through an ICG model enabled by hclk_en_o
`ifndef BLNS_VRAM_POISON
   `define BLNS_VRAM_POISON     0
`endif
`ifndef BLNS_ICG_EN
   `define BLNS_ICG_EN          0
`endif
// Bench only: DPI pixel-clock half period in 100 ps units (73 = 7.3 ns; HCLK
// is 10 ns), the value the tests start with and return to
`ifndef BLNS_PCLK_HALF
   `define BLNS_PCLK_HALF       73
`endif
// Bench only: 1 = synchroniser jitter (`ARV_SYNC_JITTER, added by
// bin/test_config.py: arv_synchronizer captures a changed bit one edge late at random)
`ifndef BLNS_SYNC_JITTER
   `define BLNS_SYNC_JITTER     0
`endif
// Bench only: the fewest comparisons of the common check tasks (tb_checks) a
// test must make to pass (run_config.json min_checks)
`ifndef BLNS_MIN_CHECKS
   `define BLNS_MIN_CHECKS      1
`endif
// Bench only: 1 = the VRAM and LUT macro models (and the VRAM read pipeline)
// on the free-running clock instead of the gated hclk
`ifndef BLNS_MACRO_FREECLK
   `define BLNS_MACRO_FREECLK   0
`endif

module  tb_belenos;

// DUT parameters
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
parameter DIF_TYPE         = `BLNS_DIF_TYPE;
parameter DPI_LB_AW        = `BLNS_DPI_LB_AW;
parameter DPI_SCALER       = `BLNS_DPI_SCALER;
parameter DPI_PCLK_SEP     = `BLNS_DPI_PCLK_SEP;
parameter DPI_DDC_EN       = `BLNS_DPI_DDC_EN;
parameter DPI_ISLAND_EN    = `BLNS_DPI_ISLAND_EN;
parameter DPI_AUDIO_EN     = `BLNS_DPI_AUDIO_EN;
parameter CURSOR_EN        = `BLNS_CURSOR_EN;
parameter PRIV_CHECK_EN    = `BLNS_PRIV_CHECK_EN;
parameter ASYNC_RST_EN     = `BLNS_ASYNC_RST_EN;
parameter ICG_EN           = `BLNS_ICG_EN;
parameter VRAM_POISON      = `BLNS_VRAM_POISON;   // bench only: no read data held between reads
parameter PCLK_HALF        = `BLNS_PCLK_HALF;     // bench only: pixel-clock half period (100 ps)
parameter SYNC_JITTER      = `BLNS_SYNC_JITTER;   // bench only: synchroniser jitter
parameter MACRO_FREECLK    = `BLNS_MACRO_FREECLK; // bench only: VRAM/LUT macros on the free-running clock

// The window's read latency: the macro's, plus the data register (the
// arbiter's with VRAM_RD_REG_EN, the window's own without): wait states of a
// read the read-ahead buffer misses
localparam integer VWIN_RD_L = VRAM_RD_LAT + 1;

// Derived values the tests use (VRAM_AW as the DUT derives it)
localparam VRAM_AW         = (VRAM_WORDS > 8388608) ? 24 : (VRAM_WORDS > 4194304) ? 23 : (VRAM_WORDS > 2097152) ? 22 :
                             (VRAM_WORDS > 1048576) ? 21 : (VRAM_WORDS > 524288) ? 20 : (VRAM_WORDS > 262144) ? 19 :
                             (VRAM_WORDS > 131072) ? 18 : (VRAM_WORDS > 65536) ? 17 : (VRAM_WORDS > 32768) ? 16 :
                             (VRAM_WORDS > 16384) ? 15 : (VRAM_WORDS > 8192) ? 14 : (VRAM_WORDS > 4096) ? 13 :
                             (VRAM_WORDS > 2048) ? 12 : (VRAM_WORDS > 1024) ? 11 : (VRAM_WORDS > 512) ? 10 :
                             (VRAM_WORDS > 256) ? 9 : (VRAM_WORDS > 128) ? 8 : (VRAM_WORDS > 64) ? 7 :
                             (VRAM_WORDS > 32) ? 6 : (VRAM_WORDS > 16) ? 5 : (VRAM_WORDS > 8) ? 4 :
                             (VRAM_WORDS > 4) ? 3 : (VRAM_WORDS > 2) ? 2 : 1;
localparam GPU_FIFO_DEPTH  = 1 << GPU_FIFO_AW;    // the GPU command FIFO
localparam HAS_SPI         = (DIF_TYPE == 1) || (DIF_TYPE == 3);   // DBI_SPI, DBI_PAR_SPI
localparam HAS_8080        = (DIF_TYPE == 2) || (DIF_TYPE == 3);   // DBI_PAR, DBI_PAR_SPI
localparam HAS_DBI         = HAS_SPI || HAS_8080;
localparam HAS_DPI         = (DIF_TYPE == 4) || (DIF_TYPE == 5);
localparam HAS_TMDS        = (DIF_TYPE == 5);
localparam HAS_DDC         = HAS_TMDS && (DPI_DDC_EN != 0);
localparam HAS_ISLAND      = HAS_TMDS && (DPI_ISLAND_EN != 0);
localparam HAS_AUDIO       = HAS_ISLAND && (DPI_AUDIO_EN != 0);
localparam DPI_NB          = (DPI_SCALER == 2) ? 3 : 2;   // DPI line-buffer banks

// Clock period (ns)
localparam CLK_HALF        = 5;
// Pixel clock against the default PCLK_HALF (73), rounded up: how many times
// slower (timeouts, polls that span a frame) and faster (CLK_DIV that keeps a
// test's pixel rate within the stream; dpi_tasks.v dpi_div). Both 1 by default.
localparam PCLK_SLOW       = (PCLK_HALF + 72) / 73;
localparam PCLK_FAST       = (72 + PCLK_HALF) / PCLK_HALF;


//
// Wire & Register definition
//------------------------------

// Clock / Reset
reg                  free_clk;
wire                 hclk;
wire                 hclk_en;
reg                  hresetn;

// Register port (manager side, before the input delay)
reg           [31:0] r_haddr;
reg                  r_hsel;
reg            [1:0] r_htrans;
reg                  r_hwrite;
reg            [2:0] r_hsize;
reg            [3:0] r_hprot;
reg                  r_hsmode;
reg            [3:0] r_hmaster;   // driven by the tasks, not connected: Belenos has no such input
reg           [31:0] r_hwdata;
wire          [31:0] r_hrdata;
wire                 r_hreadyout;
wire                 r_hresp;
wire                 r_hready;

// VRAM-window port (manager side, before the input delay)
reg           [31:0] v_haddr;
reg                  v_hsel;
reg            [1:0] v_htrans;
reg                  v_hwrite;
reg            [2:0] v_hsize;
reg            [3:0] v_hprot;
reg                  v_hsmode;
reg            [3:0] v_hmaster;   // as r_hmaster
reg           [31:0] v_hwdata;
wire          [31:0] v_hrdata;
wire                 v_hreadyout;
wire                 v_hresp;
wire                 v_hready;

// Fabric-side wait-state injection (holds hready low on that port)
reg                  r_force_stall;
reg                  v_force_stall;

// VRAM macro
wire                 vram_cen;
wire           [3:0] vram_wen;
wire   [VRAM_AW-1:0] vram_addr;
wire          [31:0] vram_din;
wire          [31:0] vram_dout;
reg           [31:0] vram_rd0;
reg           [31:0] vram_rd1;
reg           [31:0] vram_rd2;
reg           [31:0] vram_mem [0:VRAM_WORDS-1];

// LUT macro
wire                 lut_cen;
wire                 lut_wen;
wire           [8:0] lut_addr;
wire          [23:0] lut_din;
reg           [23:0] lut_dout;
reg           [23:0] lut_mem [0:511];

// Debug / interrupt
reg                  dbg_stoptime;
wire                 irq;

// 8080 panel
wire          [15:0] lcd_d_in;          // panel -> controller
wire          [15:0] lcd_d_out;         // controller -> panel
wire                 lcd_d_oe;
wire                 lcd_cs_n;
wire                 lcd_rd_n;
wire                 lcd_wr_n;
wire                 lcd_dc;

// SPI panel
wire                 spi_sck;
wire                 spi_mosi;
wire                 spi_miso;
wire                 spi_cs_n;
wire                 spi_dc;

// Shared panel control
wire                 lcd_reset_n;
wire                 lcd_on;
reg                  lcd_te;

// DPI panel, pixel clock and line-buffer macros
wire                 dpi_de;
wire                 dpi_hs;
wire                 dpi_vs;
wire          [23:0] dpi_rgb;
wire          [29:0] tmds;
wire                 dpi_clk_d0;
wire                 dpi_clk_d1;
reg                  dpi_pclk;
reg                  dpi_presetn;
reg                  dpi_detect;
real                 dpi_pclk_half;
real                 dpi_pclk_base;           // PCLK_HALF in ns: the tests' nominal pixel clock
wire  [DPI_NB-1:0]   dpi_lb_we;
wire [DPI_LB_AW-1:0] dpi_lb_waddr;
wire          [23:0] dpi_lb_wdata;
wire [DPI_LB_AW-1:0] dpi_lb_raddr;
reg [DPI_NB*24-1:0]  dpi_lb_rdata;

// BDI (exported; DIF_TYPE = 0 integrator tie-offs, ignored otherwise)
wire                 bdi_px_valid;
wire          [23:0] bdi_px_data;
wire                 bdi_px_last;
wire                 bdi_refresh_trig;
wire     [DIM_W-1:0] bdi_width;
wire     [DIM_W-1:0] bdi_height;
wire                 bdi_reg_sel;
wire           [5:0] bdi_reg_addr;
wire                 bdi_reg_wr;
wire          [31:0] bdi_reg_wdata;
// BDI core inputs, driven by the bench (defaults = the DIF_TYPE = 0
// integrator tie-offs; ignored by the DUT when DIF_TYPE != 0)
reg                  bdi_px_ready_drv;
reg                  bdi_refresh_active_drv;
reg           [31:0] bdi_reg_rdata_drv;
reg                  bdi_reg_ready_drv;
reg                  bdi_irq_drv;
reg                  bdi_busy_drv;

// Testbench variables
integer              tb_idx;
integer              tmp_seed;
integer              error;
integer              tb_checks     = 0;   // comparisons made by the common check tasks
integer              tb_min_checks = `BLNS_MIN_CHECKS;   // a test that passes with fewer fails (a test may raise it)
reg                  stimulus_done;


//
// Include files
//------------------------------

// Register map, verilog tasks & stimulus
`include "blns_defs.v"
`include "ahb_tasks.v"
`include "stimulus.v"

// Homegrown functional coverage
// The memory models and the coverage bins start with the first reset: before it,
// the coverage build's all-ones start state is not a state of the design
reg                  rst_seen;
wire                 model_on;
initial rst_seen = 1'b0;
always @(negedge hresetn) rst_seen = 1'b1;

`include "cover_monitor.v"
`include "perf_monitor.v"
`include "vram_arb_check.v"
`include "gpu_inv_check.v"

probes_gpu #(.GPU_EN(GPU_EN)) probes_gpu ();


//
// Generate Clock & Reset
//------------------------------

initial
  begin
     free_clk = 1'b0;
     forever #(CLK_HALF) free_clk = ~free_clk;
  end

// SoC-side ICG model (BLNS_ICG_EN=1): latch transparent while the clock is
// low; the CRG holds the clock running during reset.
reg hclk_en_latch;
always @(free_clk or hclk_en or hresetn)
  if (~free_clk) hclk_en_latch <= hclk_en | ~hresetn;

assign hclk = (ICG_EN != 0) ? (free_clk & hclk_en_latch) : free_clk;

// The VRAM and LUT macros sit on the gated hclk, or with MACRO_FREECLK on the
// free-running clock (both allowed by the integration guide)
wire mclk = (MACRO_FREECLK != 0) ? free_clk : hclk;

// Reset: a falling edge (the asynchronous resets need one), held across
// several clock edges so the synchronous-reset build reaches its reset values
// too. Tests start with `@(posedge reset_done)`: an edge, not a level, since
// the coverage build starts every variable at 1.
reg                  reset_done;
initial
  begin
     reset_done = 1'b0;
     hresetn    = 1'b1;
     #23;
     hresetn    = 1'b0;
     #(20*CLK_HALF*2);
     hresetn    = 1'b1;
     repeat(5) @(posedge free_clk);
     reset_done = 1'b1;
  end

// The panel models count from the end of the power-on reset: before it the
// panel pins carry the start state (random under Verilator), not the design's
initial begin
    @(negedge hresetn); @(posedge hresetn_d);
    u_lcd8080.anomaly_count = 0; u_lcd8080.anomaly_total = 0;
    u_lcdspi.anomaly_count  = 0; u_lcdspi.anomaly_total  = 0;
end

`ifdef ARV_COV_RESET_ZERO
// Coverage counts start once the power-on reset is released (the Verilator
// coverage flow starts every flop at 1 so the asynchronous reset sees an edge).
initial begin
    @(negedge hresetn); @(posedge hresetn);
    $c("Verilated::threadContextp()->coveragep()->zero();");
end
`endif

// Variables initialization
initial
  begin
     tmp_seed      = `SEED;
     tmp_seed      = $urandom(tmp_seed);
     error         = 0;
     stimulus_done = 0;

     r_haddr       = 32'h0;  r_hsel  = 1'b0;  r_htrans = 2'b00;  r_hwrite = 1'b0;
     r_hsize       = 3'b010; r_hprot = 4'h0;  r_hsmode = 1'b0;   r_hmaster = 4'h0;
     r_hwdata      = 32'h0;
     v_haddr       = 32'h0;  v_hsel  = 1'b0;  v_htrans = 2'b00;  v_hwrite = 1'b0;
     v_hsize       = 3'b010; v_hprot = 4'h0;  v_hsmode = 1'b0;   v_hmaster = 4'h0;
     v_hwdata      = 32'h0;
     r_force_stall = 1'b0;
     v_force_stall = 1'b0;
     dbg_stoptime  = 1'b0;
     lcd_te        = 1'b0;
     bdi_px_ready_drv       = 1'b1;
     bdi_refresh_active_drv = 1'b0;
     bdi_reg_rdata_drv      = 32'h0000_0000;
     bdi_reg_ready_drv      = 1'b1;
     bdi_irq_drv            = 1'b0;
     bdi_busy_drv           = 1'b0;
  end

// Every input the bench drives reaches the DUT 1 ns after the bench sets it, so
// the value the DUT samples never depends on the simulator's process order
// (Icarus and Verilator differ). hready stays combinational: AHB requires it
// in the same cycle as hreadyout.
wire          [31:0] r_haddr_d;
wire                 r_hsel_d;
wire           [1:0] r_htrans_d;
wire                 r_hwrite_d;
wire           [2:0] r_hsize_d;
wire           [3:0] r_hprot_d;
wire                 r_hsmode_d;
wire          [31:0] r_hwdata_d;
wire                 r_force_stall_d;
wire          [31:0] v_haddr_d;
wire                 v_hsel_d;
wire           [1:0] v_htrans_d;
wire                 v_hwrite_d;
wire           [2:0] v_hsize_d;
wire           [3:0] v_hprot_d;
wire                 v_hsmode_d;
wire          [31:0] v_hwdata_d;
wire                 v_force_stall_d;
wire                 hresetn_d;
wire                 dbg_stoptime_d;
wire                 lcd_te_d;
wire                 bdi_px_ready_d;
wire                 bdi_refresh_active_d;
wire          [31:0] bdi_reg_rdata_d;
wire                 bdi_reg_ready_d;
wire                 bdi_irq_d;
wire                 bdi_busy_d;
assign #1 r_haddr_d       = r_haddr;
assign #1 r_hsel_d        = r_hsel;
assign #1 r_htrans_d      = r_htrans;
assign #1 r_hwrite_d      = r_hwrite;
assign #1 r_hsize_d       = r_hsize;
assign #1 r_hprot_d       = r_hprot;
assign #1 r_hsmode_d      = r_hsmode;
assign #1 r_hwdata_d      = r_hwdata;
assign #1 r_force_stall_d = r_force_stall;
assign #1 v_haddr_d       = v_haddr;
assign #1 v_hsel_d        = v_hsel;
assign #1 v_htrans_d      = v_htrans;
assign #1 v_hwrite_d      = v_hwrite;
assign #1 v_hsize_d       = v_hsize;
assign #1 v_hprot_d       = v_hprot;
assign #1 v_hsmode_d      = v_hsmode;
assign #1 v_hwdata_d      = v_hwdata;
assign #1 v_force_stall_d = v_force_stall;
assign #1 hresetn_d       = hresetn;

assign model_on = (hresetn_d === 1'b1) & rst_seen;
assign #1 dbg_stoptime_d  = dbg_stoptime;
assign #1 lcd_te_d        = lcd_te;
assign #1 bdi_px_ready_d       = bdi_px_ready_drv;
assign #1 bdi_refresh_active_d = bdi_refresh_active_drv;
assign #1 bdi_reg_rdata_d      = bdi_reg_rdata_drv;
assign #1 bdi_reg_ready_d      = bdi_reg_ready_drv;
assign #1 bdi_irq_d            = bdi_irq_drv;
assign #1 bdi_busy_d           = bdi_busy_drv;

// One subordinate per bus: hready follows the port's own hreadyout.
assign r_hready = r_hreadyout & ~r_force_stall_d;
assign v_hready = v_hreadyout & ~v_force_stall_d;


//
// VRAM model: synchronous, 32-bit, active-low chip enable and byte write
// enables (all 1 = read), VRAM_RD_LAT-cycle read latency, VRAM_WORDS deep.
//----------------------------------------
integer vram_init_idx;
initial
  begin
     for (vram_init_idx = 0; vram_init_idx < VRAM_WORDS; vram_init_idx = vram_init_idx + 1)
       vram_mem[vram_init_idx] = 32'h0000_0000;
     vram_rd0 = 32'h0000_0000;
     vram_rd1 = 32'h0000_0000;
     vram_rd2 = 32'h0000_0000;
  end

// Accesses while reset is asserted are ignored (a synchronous-reset build
// reaches its idle outputs only after a few clock edges).
// VRAM_POISON (bench only): the macro contract holds the read data until the
// next read; a stricter macro (or a memory with variable latency) does not.
// Random data in every cycle but a read's data cycle shows a requester that
// samples the data late (a read overrides it below, in the same block).
always @(posedge mclk)
  begin
  if ((VRAM_POISON != 0) && model_on)
    vram_rd0 <= $random;
  if ((vram_cen === 1'b0) && model_on)
    begin
       if ({{(32-VRAM_AW){1'b0}}, vram_addr} >= VRAM_WORDS)
         begin
            $display("ERROR: VRAM model -- access beyond VRAM_WORDS: word 0x%h %t", vram_addr, $time);
            error = error + 1;
         end
       else if (vram_wen !== 4'hF)
         begin
            if (vram_wen[0] === 1'b0) vram_mem[vram_addr][ 7: 0] <= vram_din[ 7: 0];
            if (vram_wen[1] === 1'b0) vram_mem[vram_addr][15: 8] <= vram_din[15: 8];
            if (vram_wen[2] === 1'b0) vram_mem[vram_addr][23:16] <= vram_din[23:16];
            if (vram_wen[3] === 1'b0) vram_mem[vram_addr][31:24] <= vram_din[31:24];
         end
       else
         vram_rd0 <= vram_mem[vram_addr];
    end
  end

// VRAM_RD_LAT > 1: the macro's output pipeline (a block RAM's output
// registers), every stage loaded in every cycle
always @(posedge mclk)
  begin
     vram_rd1 <= vram_rd0;
     vram_rd2 <= vram_rd1;
  end
assign vram_dout = (VRAM_RD_LAT >= 3) ? vram_rd2 : (VRAM_RD_LAT == 2) ? vram_rd1 : vram_rd0;

// The refresh's stage B meets each fetched word with its read data valid: a
// token that would wait for its word (a memory slower than VRAM_RD_LAT says)
// would drop its pixel
`define TB_BKF dut.u_core.u_backend.blns_bk_fetch_inst
always @(posedge hclk)
  if (model_on && (`TB_BKF.b_valid === 1'b1) && (`TB_BKF.b_new === 1'b1) &&
      (`TB_BKF.load_i === 1'b0) && (`TB_BKF.vrvalid_i !== 1'b1))
    begin
       $display("ERROR: refresh stage B -- fetched word without its read data %t", $time);
       error = error + 1;
    end


//
// LUT model: 512 x 24, synchronous, active-low chip and write enables,
// one-cycle read latency.
//----------------------------------------
integer lut_init_idx;
initial
  begin
     for (lut_init_idx = 0; lut_init_idx < 512; lut_init_idx = lut_init_idx + 1)
       lut_mem[lut_init_idx] = 24'h00_0000;
     lut_dout = 24'h00_0000;
  end

always @(posedge mclk)
  if ((lut_cen === 1'b0) && model_on)
    begin
       if (lut_wen === 1'b0) lut_mem[lut_addr] <= lut_din;
       else                  lut_dout          <= lut_mem[lut_addr];
    end


//
// Panel models (ILI9341)
//----------------------------------------
ili9341_8080_model u_lcd8080 (
    .reset_n_i   ( lcd_reset_n ),
    .cs_n_i      ( lcd_cs_n    ),
    .dc_i        ( lcd_dc      ),
    .wr_n_i      ( lcd_wr_n    ),
    .rd_n_i      ( lcd_rd_n    ),
    .d_i         ( lcd_d_out   ),
    .d_oe_i      ( lcd_d_oe    ),
    .d_o         ( lcd_d_in    )
);

ili9341_spi_model u_lcdspi (
    .reset_n_i   ( lcd_reset_n ),
    .cs_n_i      ( spi_cs_n    ),
    .dc_i        ( spi_dc      ),
    .sck_i       ( spi_sck     ),
    .mosi_i      ( spi_mosi    ),
    .miso_o      ( spi_miso    )
);


//
// DPI: pixel clock and reset, line-buffer macros (one write port on hclk, one
// read port on the pixel-domain clock), the DDR clock output register and the
// panel model
//----------------------------------------
initial begin
   dpi_pclk      = 1'b0;
   dpi_presetn   = 1'b0;
   dpi_detect    = 1'b1;
   dpi_pclk_base = PCLK_HALF / 10.0;
   dpi_pclk_half = dpi_pclk_base;
   if (HAS_DPI && (DPI_PCLK_SEP != 0))
     $display("DPI pixel clock: half period %0.1f ns, pclk/hclk %0.2f", dpi_pclk_base, CLK_HALF / dpi_pclk_base);
   if (SYNC_JITTER != 0)
     $display("Synchroniser jitter on (ARV_SYNC_JITTER)");
end
// dpi_pclk_stop (set by a test, at a falling edge) holds the pixel clock low:
// a PLL that loses lock
reg dpi_pclk_stop;
initial dpi_pclk_stop = 1'b0;
always #(dpi_pclk_half) if (!dpi_pclk_stop) dpi_pclk = ~dpi_pclk;

// Released synchronously to the pixel clock, asserted with hresetn, or alone
// while a test sets dpi_prst_force (a pixel-domain-only reset: dpi_preset);
// held until the power-on reset has started (rst_seen), so that a fast pixel
// clock does not release it before the hclk domain is ever reset
reg dpi_prst_q;
reg dpi_prst_force;
initial dpi_prst_force = 1'b0;
always @(posedge dpi_pclk or negedge hresetn_d or posedge dpi_prst_force)
  if (!hresetn_d || dpi_prst_force || !rst_seen) begin dpi_prst_q <= 1'b0; dpi_presetn <= 1'b0; end
  else                              begin dpi_prst_q <= 1'b1; dpi_presetn <= dpi_prst_q; end

wire dpi_pdom = (DPI_PCLK_SEP != 0) ? dpi_pclk : hclk;

reg     [23:0] dpi_lb_mem [0:DPI_NB*(1<<DPI_LB_AW)-1];
integer        dpi_lb_b;
always @(posedge hclk)
  for (dpi_lb_b = 0; dpi_lb_b < DPI_NB; dpi_lb_b = dpi_lb_b + 1)
    if (dpi_lb_we[dpi_lb_b] === 1'b1) dpi_lb_mem[dpi_lb_b*(1<<DPI_LB_AW) + dpi_lb_waddr] <= dpi_lb_wdata;
always @(posedge dpi_pdom)
  for (dpi_lb_b = 0; dpi_lb_b < DPI_NB; dpi_lb_b = dpi_lb_b + 1)
    dpi_lb_rdata[dpi_lb_b*24 +: 24] <= dpi_lb_mem[dpi_lb_b*(1<<DPI_LB_AW) + dpi_lb_raddr];

// DDR output register: d0 in the first half of the period, d1 in the second
reg dpi_ddr1, dpi_clk_pin;
initial begin dpi_ddr1 = 1'b0; dpi_clk_pin = 1'b0; end
always @(posedge dpi_pdom) begin dpi_clk_pin <= dpi_clk_d0; dpi_ddr1 <= dpi_clk_d1; end
always @(negedge dpi_pdom) dpi_clk_pin <= dpi_ddr1;

// Clock held low until reset_done: the coverage build's all-ones start state
// would otherwise give the panel a first sample when the reset asserts
dpi_panel_model #(.W_MAX(1312), .H_MAX(720)) u_dpipanel (
    .clk_i       ( dpi_clk_pin & reset_done ),
    .de_i        ( dpi_de      ),
    .hs_i        ( dpi_hs      ),
    .vs_i        ( dpi_vs      ),
    .rgb_i       ( dpi_rgb     )
);

// HDMI DDC: open-drain lines with pull-ups, the monitor's EDID behind them
wire                 ddc_scl_pd;
wire                 ddc_sda_pd;
tri1                 ddc_scl;
tri1                 ddc_sda;
assign ddc_scl = ddc_scl_pd ? 1'b0 : 1'bz;
assign ddc_sda = ddc_sda_pd ? 1'b0 : 1'bz;

ddc_eeprom_model u_edid (
    .scl         ( ddc_scl     ),
    .sda         ( ddc_sda     )
);

// HDMI audio: the I2S source (clock master)
wire                 i2s_bclk;
wire                 i2s_lrck;
wire                 i2s_sd;

i2s_src_model u_i2s (
    .bclk_o      ( i2s_bclk    ),
    .lrck_o      ( i2s_lrck    ),
    .sd_o        ( i2s_sd      )
);

// HDMI (DIF_TYPE = 5): the TMDS symbols decoded against the DPI pins
generate
    if (HAS_TMDS) begin : g_tmdsrx
        tmds_rx_model #(.AUDIO(HAS_AUDIO ? 1 : 0)) u_tmdsrx (
            .clk_i       ( dpi_pdom                                          ),
            .en_i        ( (DPI_PCLK_SEP != 0) ? dpi_presetn : hresetn_d     ),
            .tmds_i      ( tmds                                              ),
            .de_i        ( dut.G_DPI.u_dpi.tmds_de                           ),
            .hs_i        ( dpi_hs                                            ),
            .vs_i        ( dpi_vs                                            ),
            .rgb_i       ( dpi_rgb                                           )
        );
    end else begin : g_tmdsrx
        // Never enabled: the tests' g_tmdsrx.u_tmdsrx references elaborate in
        // every build (Verilator rejects a reference to an absent block)
        tmds_rx_model u_tmdsrx (
            .clk_i       ( 1'b0                                              ),
            .en_i        ( 1'b0                                              ),
            .tmds_i      ( 30'd0                                             ),
            .de_i        ( 1'b0                                              ),
            .hs_i        ( 1'b0                                              ),
            .vs_i        ( 1'b0                                              ),
            .rgb_i       ( 24'd0                                             )
        );
    end
endgenerate


//
// BELENOS INSTANCE
//----------------------------------
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
    .DIF_TYPE             ( DIF_TYPE           ),
    .DPI_LB_AW            ( DPI_LB_AW          ),
    .DPI_SCALER           ( DPI_SCALER         ),
    .DPI_PCLK_SEP         ( DPI_PCLK_SEP       ),
    .DPI_DDC_EN           ( DPI_DDC_EN         ),
    .DPI_ISLAND_EN        ( DPI_ISLAND_EN      ),
    .DPI_AUDIO_EN         ( DPI_AUDIO_EN       ),
    .CURSOR_EN            ( CURSOR_EN          ),
    .PRIV_CHECK_EN        ( PRIV_CHECK_EN      ),
    .ASYNC_RST_EN         ( ASYNC_RST_EN       )
) dut (
    .hclk_i               ( hclk               ),
    .hresetn_i            ( hresetn_d          ),
    .hclk_en_o            ( hclk_en            ),

    .r_hsel_i             ( r_hsel_d           ),
    .r_haddr_i            ( r_haddr_d[11:0]    ),
    .r_htrans_i           ( r_htrans_d         ),
    .r_hwrite_i           ( r_hwrite_d         ),
    .r_hsize_i            ( r_hsize_d          ),
    .r_hprot_i            ( r_hprot_d          ),
    .r_hsmode_i           ( r_hsmode_d         ),
    .r_hready_i           ( r_hready           ),
    .r_hwdata_i           ( r_hwdata_d         ),
    .r_hrdata_o           ( r_hrdata           ),
    .r_hreadyout_o        ( r_hreadyout        ),
    .r_hresp_o            ( r_hresp            ),

    .v_hsel_i             ( v_hsel_d           ),
    .v_haddr_i            ( v_haddr_d[VRAM_AW+1:0] ),
    .v_htrans_i           ( v_htrans_d         ),
    .v_hwrite_i           ( v_hwrite_d         ),
    .v_hsize_i            ( v_hsize_d          ),
    .v_hprot_i            ( v_hprot_d          ),
    .v_hsmode_i           ( v_hsmode_d         ),
    .v_hready_i           ( v_hready           ),
    .v_hwdata_i           ( v_hwdata_d         ),
    .v_hrdata_o           ( v_hrdata           ),
    .v_hreadyout_o        ( v_hreadyout        ),
    .v_hresp_o            ( v_hresp            ),

    .vram_cen_o           ( vram_cen           ),
    .vram_wen_o           ( vram_wen           ),
    .vram_addr_o          ( vram_addr          ),
    .vram_din_o           ( vram_din           ),
    .vram_dout_i          ( vram_dout          ),

    .lut_cen_o            ( lut_cen            ),
    .lut_wen_o            ( lut_wen            ),
    .lut_addr_o           ( lut_addr           ),
    .lut_din_o            ( lut_din            ),
    .lut_dout_i           ( lut_dout           ),

    .dbg_stoptime_i       ( dbg_stoptime_d     ),
    .irq_o                ( irq                ),

    .lcd_d_i              ( lcd_d_in           ),
    .lcd_d_o              ( lcd_d_out          ),
    .lcd_d_oe_o           ( lcd_d_oe           ),
    .lcd_cs_n_o           ( lcd_cs_n           ),
    .lcd_rd_n_o           ( lcd_rd_n           ),
    .lcd_wr_n_o           ( lcd_wr_n           ),
    .lcd_dc_o             ( lcd_dc             ),

    .spi_sck_o            ( spi_sck            ),
    .spi_mosi_o           ( spi_mosi           ),
    .spi_miso_i           ( spi_miso           ),
    .spi_cs_n_o           ( spi_cs_n           ),
    .spi_dc_o             ( spi_dc             ),

    .lcd_reset_n_o        ( lcd_reset_n        ),
    .lcd_on_o             ( lcd_on             ),
    .lcd_te_i             ( lcd_te_d           ),

    .dpi_de_o             ( dpi_de             ),
    .dpi_hs_o             ( dpi_hs             ),
    .dpi_vs_o             ( dpi_vs             ),
    .dpi_rgb_o            ( dpi_rgb            ),
    .dpi_clk_d0_o         ( dpi_clk_d0         ),
    .dpi_clk_d1_o         ( dpi_clk_d1         ),
    .dpi_pclk_i           ( (DPI_PCLK_SEP != 0) ? dpi_pclk    : 1'b0 ),
    .dpi_presetn_i        ( (DPI_PCLK_SEP != 0) ? dpi_presetn : 1'b0 ),
    .panel_detect_i       ( dpi_detect         ),
    .tmds_o               ( tmds               ),
    .ddc_scl_i            ( ddc_scl            ),
    .ddc_sda_i            ( ddc_sda            ),
    .ddc_scl_pd_o         ( ddc_scl_pd         ),
    .ddc_sda_pd_o         ( ddc_sda_pd         ),
    .i2s_bclk_i           ( i2s_bclk           ),
    .i2s_lrck_i           ( i2s_lrck           ),
    .i2s_sd_i             ( i2s_sd             ),
    .dpi_lb_we_o          ( dpi_lb_we          ),
    .dpi_lb_waddr_o       ( dpi_lb_waddr       ),
    .dpi_lb_wdata_o       ( dpi_lb_wdata       ),
    .dpi_lb_raddr_o       ( dpi_lb_raddr       ),
    .dpi_lb_rdata_i       ( dpi_lb_rdata       ),

    .bdi_px_valid_o       ( bdi_px_valid       ),
    .bdi_px_data_o        ( bdi_px_data        ),
    .bdi_px_last_o        ( bdi_px_last        ),
    .bdi_px_ready_i       ( bdi_px_ready_d     ),
    .bdi_refresh_trig_o   ( bdi_refresh_trig   ),
    .bdi_refresh_active_i ( bdi_refresh_active_d ),
    .bdi_width_o          ( bdi_width          ),
    .bdi_height_o         ( bdi_height         ),
    .bdi_reg_sel_o        ( bdi_reg_sel        ),
    .bdi_reg_addr_o       ( bdi_reg_addr       ),
    .bdi_reg_wr_o         ( bdi_reg_wr         ),
    .bdi_reg_wdata_o      ( bdi_reg_wdata      ),
    .bdi_reg_rdata_i      ( bdi_reg_rdata_d    ),
    .bdi_reg_ready_i      ( bdi_reg_ready_d    ),
    .bdi_irq_i            ( bdi_irq_d          ),
    .bdi_busy_i           ( bdi_busy_d         )
);


// Always-on contract monitors (AHB ports, clock request, macro ports, X on outputs)
`include "contract_check.v"


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_belenos.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_belenos.trn");
          $recordvars;
       `else
          $dumpfile("tb_belenos.vcd");
          $dumpvars(0, tb_belenos);
       `endif
     `endif
   `endif
  end


//
// End of simulation
//----------------------------------------

// Scaled by PCLK_SLOW when PCLK_HALF makes the pixel clock slower than the default
initial // Timeout
  begin
   `ifdef NO_TIMEOUT
   `else
     `ifdef VERY_LONG_TIMEOUT
       #(200000000 * PCLK_SLOW);
     `else
     `ifdef LONG_TIMEOUT
       #(20000000 * PCLK_SLOW);
     `else
       #(2000000 * PCLK_SLOW);
     `endif
     `endif
       $display(" ===============================================");
       $display("|               SIMULATION FAILED               |");
       $display("|              (simulation Timeout)             |");
       $display(" ===============================================");
       $display("");
       tb_extra_report;
       $finish;
   `endif
  end

// The refresh fetch's registered need_fetch (blns_bk_fetch u_no_fetch) equals
// the word compare it stands for, in every cycle of every build
integer bkf_mismatch;
initial bkf_mismatch = 0;
always @(posedge hclk)
  if (model_on &&
      (dut.u_core.u_backend.blns_bk_fetch_inst.need_fetch !==
       (~dut.u_core.u_backend.blns_bk_fetch_inst.lw_valid |
        (dut.u_core.u_backend.blns_bk_fetch_inst.wa != dut.u_core.u_backend.blns_bk_fetch_inst.lw_addr))))
    begin
       bkf_mismatch = bkf_mismatch + 1;
       if (bkf_mismatch <= 4)
         $display("ERROR: refresh fetch -- registered need_fetch differs from the word compare %t", $time);
       error = error + 1;
    end

initial // Normal end of test
  begin
     @(posedge stimulus_done);
     tmds_check;
     tb_model_check;

     $display(" ===============================================");
     if (error!=0)
       begin
          $display("|               SIMULATION FAILED               |");
          $display("|     (some verilog stimulus checks failed)     |");
       end
     else
       begin
          $display("|               SIMULATION PASSED               |");
       end
     $display(" ===============================================");
     $display("");
     tb_extra_report;
     $finish;
  end


//
// Tasks Definition
//------------------------------

   task tb_error;
      input [80*8-1:0] error_string;
      begin
         $display("ERROR: %0s %t", error_string, $time);
         error = error+1;
      end
   endtask

   // HDMI: the TMDS checker's errors count in every test
   task tmds_check;
      begin
         if (HAS_TMDS) begin
            $display("TMDS: %0d data and %0d control symbols checked, %0d errors",
                     g_tmdsrx.u_tmdsrx.data_sym, g_tmdsrx.u_tmdsrx.ctl_sym, g_tmdsrx.u_tmdsrx.errors);
            error = error + g_tmdsrx.u_tmdsrx.errors;
         end
      end
   endtask

   task tb_extra_report;
      begin
         $display("");
         cover_report;
         perf_report;
         vram_arb_check_report;
         gpu_inv_check_report;
         cc_report;
         $display("CHECKS: %0d (minimum %0d)", tb_checks, tb_min_checks);
         probes_gpu.close;
         $display("");
         $display("SIMULATION SEED: %d", `SEED);
         $display("");
      end
   endtask

   // A skip after a failed check is a failure: the checks a test makes
   // before deciding the build lacks its feature still count
   task tb_skip_finish;
      input [65*8-1:0] skip_string;
      begin
         tb_min_checks = 0;           // a skip needs no comparison
         tb_model_check;
         $display(" ===============================================");
         if (error!=0)
           begin
              $display("|               SIMULATION FAILED               |");
              $display("|   (checks failed before the test skipped)     |");
           end
         else
           $display("|               SIMULATION SKIPPED              |");
         $display("%0s", skip_string);
         $display(" ===============================================");
         $display("");
         tb_extra_report;
         $finish;
      end
   endtask


endmodule
