//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    belenos
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : belenos.v
// Module Description : Belenos graphic controller top level: belenos_core plus
//                      the built-in display driver selected by DIF_TYPE:
//                      0 BDI (none, the BDI is exported for an external
//                      driver), 1 DBI_SPI, 2 DBI_PAR (8080-16), 3 DBI_PAR_SPI
//                      (both DBI buses), 4 DPI (parallel RGB), 5 HDMI (DPI
//                      with TMDS symbols for a serialiser).
//----------------------------------------------------------------------------
`default_nettype none

module  belenos #(
    parameter                   VRAM_WORDS       = 38400,   // VRAM depth in 32-bit words (1 - 2^24)
    parameter                   VRAM_AW          = (VRAM_WORDS > 8388608) ? 24 : (VRAM_WORDS > 4194304) ? 23 : (VRAM_WORDS > 2097152) ? 22 : (VRAM_WORDS > 1048576) ? 21 :
                                                   (VRAM_WORDS > 524288)  ? 20 : (VRAM_WORDS > 262144)  ? 19 : (VRAM_WORDS > 131072)  ? 18 : (VRAM_WORDS > 65536)   ? 17 :
                                                   (VRAM_WORDS > 32768)   ? 16 : (VRAM_WORDS > 16384)   ? 15 : (VRAM_WORDS > 8192)    ? 14 : (VRAM_WORDS > 4096)    ? 13 :
                                                   (VRAM_WORDS > 2048)    ? 12 : (VRAM_WORDS > 1024)    ? 11 : (VRAM_WORDS > 512)     ? 10 : (VRAM_WORDS > 256)     ? 9  :
                                                   (VRAM_WORDS > 128)     ? 8  : (VRAM_WORDS > 64)      ? 7  : (VRAM_WORDS > 32)      ? 6  : (VRAM_WORDS > 16)      ? 5  :
                                                   (VRAM_WORDS > 8)       ? 4  : (VRAM_WORDS > 4)       ? 3  : (VRAM_WORDS > 2)       ? 2  :  1,   // VRAM word-address width, ceil(log2(VRAM_WORDS)): derived, leave at the default
    parameter                   VRAM_RD_LAT      = 1,       // VRAM macro read latency in cycles (1-3): data that many cycles after the access (1 = plain synchronous SRAM)
    parameter                   VRAM_RD_REG_EN   = 0,       // VRAM read data registered: 0=used as the macro delivers it, 1=one more read cycle (slow macros)
    parameter                   DIM_W            = 10,      // Width/height field width in bits (4-16): sizes up to 2^DIM_W - 1 pixels
    parameter                   FRAME_NR         = 2,       // Number of frame pointers (1, 2 or 4)
    parameter                   LUT_EN           = 1,       // Programmable colour LUT: 0=absent, 1=present
    parameter                   LUT_BANKS        = 2,       // LUT banks of 256 entries (1 or 2, needs LUT_EN)
    parameter                   GPU_EN           = 1,       // GPU: 0=absent, 1=present
    parameter                   GPU_XY_EN        = 1,       // GPU x/y coordinates and clip window (SET_DST XY, SET_XY, SET_CLIP), affine blits (EXEC_TEXRECT, SET_STEP_ROW, SET_TEXBOX, SET_TEX BOUND)
    parameter                   GPU_GRAD_EN      = 1,       // GPU gradient fills (SET_GRAD)
    parameter                   GPU_BLEND_EN     = 0,       // GPU alpha blending at 16 bpp (SET_ALPHA, EXPAND masks)
    parameter                   GPU_TRI_EN       = 0,       // GPU triangles (SET_V0..V2, EXEC_FILL TRI), needs GPU_XY_EN
    parameter                   GPU_RUNAHEAD_EN  = 0,       // GPU run-ahead: decode and set up the next primitive while one draws
    parameter                   GPU_REMAP_EN     = 1,       // GPU palette remap (SET_AUX REMAP_TABLE, the REMAP fields of EXEC and SET_TEX)
    parameter                   GPU_MPLANE_EN    = 1,       // GPU mask plane on copies (SET_AUX MASK_PLANE, EXEC_COPY MPLANE)
    parameter                   GPU_IMM_EN       = 1,       // GPU immediate source (SET_SRC IMM: COPY / COPY_TRANSP / EXPAND data from GPU_CMD)
    parameter                   GPU_LINE_EN      = 1,       // GPU lines (EXEC_FILL LINE, SET_AUX LINE_PEN / LINE_PATTERN), needs GPU_XY_EN
    parameter                   GPU_BILINEAR_EN  = 0,       // GPU bilinear texture sampling (SET_AUX TEX_FILTER), needs GPU_XY_EN
    parameter                   GPU_FIFO_AW      = 3,       // GPU command FIFO: 2^GPU_FIFO_AW words (3..6, 8 to 64)
    parameter                   DIF_TYPE         = 2,       // Built-in display driver: 0=BDI (none, BDI exported), 1=DBI_SPI, 2=DBI_PAR (8080), 3=DBI_PAR_SPI, 4=DPI, 5=HDMI
    parameter                   DPI_LB_AW        = 10,      // DPI line-buffer address width: 2^DPI_LB_AW source pixels per line (9-12)
    parameter                   DPI_SCALER       = 1,       // DPI scaler: 0=none, 1=nearest neighbour, 2=nearest and bilinear
    parameter                   DPI_PCLK_SEP     = 0,       // DPI panel timing: 0=on hclk_i, 1=on dpi_pclk_i
    parameter                   DPI_DDC_EN       = 1,       // HDMI DDC register (DIF_TYPE 5): 0=absent, 1=present
    parameter                   DPI_ISLAND_EN    = 1,       // HDMI mode, guard bands and InfoFrame data islands (DIF_TYPE 5): 0=absent, 1=present
    parameter                   DPI_AUDIO_EN     = 0,       // HDMI audio from an I2S input and the generic packet (needs DPI_ISLAND_EN): 0=absent, 1=present
    parameter                   CURSOR_EN        = 1,       // Hardware cursor (32 x 32, 2 bpp, overlaid on the refresh): 0=absent, 1=present
    parameter                   PRIV_CHECK_EN    = 0,       // User-mode accesses on both ports: 0=allowed, 1=refused
    parameter                   ASYNC_RST_EN     = 1'b1     // Reset: 1=asynchronous active-low, 0=synchronous
) (
    input  wire                 hclk_i,                     // clock
    input  wire                 hresetn_i,                  // active-low reset
    output wire                 hclk_en_o,                  // clock-gate enable

// Register port (AHB-Lite subordinate)
    input  wire                 r_hsel_i,                   // select
    input  wire          [11:0] r_haddr_i,
    input  wire           [1:0] r_htrans_i,
    input  wire                 r_hwrite_i,                 // write
    input  wire           [2:0] r_hsize_i,
    input  wire           [3:0] r_hprot_i,                  // [1] privileged (PRIV_CHECK_EN)
    input  wire                 r_hsmode_i,                 // aRVern S-mode sideband (unused)
    input  wire                 r_hready_i,                 // the fabric's HREADY (not this port's HREADYOUT)
    input  wire          [31:0] r_hwdata_i,
    output wire          [31:0] r_hrdata_o,
    output wire                 r_hreadyout_o,              // a flop (bdi_reg_ready_i in the BDI window with DIF_TYPE = 0)
    output wire                 r_hresp_o,

// VRAM-window port (AHB-Lite subordinate)
    input  wire                 v_hsel_i,                   // select
    input  wire   [VRAM_AW+1:0] v_haddr_i,
    input  wire           [1:0] v_htrans_i,
    input  wire                 v_hwrite_i,                 // write
    input  wire           [2:0] v_hsize_i,
    input  wire           [3:0] v_hprot_i,                  // [1] privileged (PRIV_CHECK_EN)
    input  wire                 v_hsmode_i,                 // aRVern S-mode sideband (unused)
    input  wire                 v_hready_i,                 // the fabric's HREADY (not this port's HREADYOUT)
    input  wire          [31:0] v_hwdata_i,
    output wire          [31:0] v_hrdata_o,
    output wire                 v_hreadyout_o,              // from flops only
    output wire                 v_hresp_o,

// VRAM macro (synchronous, VRAM_RD_LAT-cycle read latency)
    output wire                 vram_cen_o,
    output wire           [3:0] vram_wen_o,
    output wire   [VRAM_AW-1:0] vram_addr_o,
    output wire          [31:0] vram_din_o,
    input  wire          [31:0] vram_dout_i,

// LUT macro (512 x 24, synchronous, 1-cycle read latency)
    output wire                 lut_cen_o,
    output wire                 lut_wen_o,
    output wire           [8:0] lut_addr_o,
    output wire          [23:0] lut_din_o,
    input  wire          [23:0] lut_dout_i,

// Debug / interrupt
    input  wire                 dbg_stoptime_i,
    output wire                 irq_o,

// Belenos Display Interface (used when DIF_TYPE = 0; doc/display_interface.md). The
// inputs come from flops in the driver: bdi_refresh_active_i reaches
// bdi_px_valid_o and STATUS, bdi_reg_ready_i / bdi_reg_rdata_i reach
// r_hreadyout_o / r_hrdata_o in the same cycle
    output wire                 bdi_px_valid_o,
    output wire          [23:0] bdi_px_data_o,
    output wire                 bdi_px_last_o,
    input  wire                 bdi_px_ready_i,
    output wire                 bdi_refresh_trig_o,
    input  wire                 bdi_refresh_active_i,
    output wire     [DIM_W-1:0] bdi_width_o,
    output wire     [DIM_W-1:0] bdi_height_o,
    output wire                 bdi_reg_sel_o,
    output wire           [5:0] bdi_reg_addr_o,
    output wire                 bdi_reg_wr_o,
    output wire          [31:0] bdi_reg_wdata_o,
    input  wire          [31:0] bdi_reg_rdata_i,
    input  wire                 bdi_reg_ready_i,
    input  wire                 bdi_irq_i,
    input  wire                 bdi_busy_i,

// SPI panel (DIF_TYPE 1/3)
    output wire                 spi_sck_o,
    output wire                 spi_mosi_o,
    input  wire                 spi_miso_i,
    output wire                 spi_cs_n_o,
    output wire                 spi_dc_o,

// 8080 panel (DIF_TYPE 2/3)
    input  wire          [15:0] lcd_d_i,
    output wire          [15:0] lcd_d_o,
    output wire                 lcd_d_oe_o,
    output wire                 lcd_cs_n_o,
    output wire                 lcd_rd_n_o,
    output wire                 lcd_wr_n_o,
    output wire                 lcd_dc_o,

// Shared panel control
    output wire                 lcd_reset_n_o,
    output wire                 lcd_on_o,
    input  wire                 lcd_te_i,

// DPI panel (DIF_TYPE 4/5)
    output wire                 dpi_de_o,
    output wire                 dpi_hs_o,
    output wire                 dpi_vs_o,
    output wire          [23:0] dpi_rgb_o,
    output wire                 dpi_clk_d0_o,               // panel clock, first half of the period (DDR output register)
    output wire                 dpi_clk_d1_o,               // panel clock, second half
    input  wire                 dpi_pclk_i,                 // pixel clock (DPI_PCLK_SEP = 1)
    input  wire                 dpi_presetn_i,              // pixel-domain reset, released on dpi_pclk_i (DPI_PCLK_SEP = 1)
    input  wire                 panel_detect_i,             // panel present (asynchronous; tie 1 without)

// DPI line-buffer macros (DIF_TYPE 4/5): one write port on hclk_i, one read port on the pixel-domain clock
    output wire    [((DPI_SCALER == 2) ? 3 : 2)-1:0] dpi_lb_we_o,
    output wire                      [DPI_LB_AW-1:0] dpi_lb_waddr_o,
    output wire                               [23:0] dpi_lb_wdata_o,
    output wire                      [DPI_LB_AW-1:0] dpi_lb_raddr_o,
    input  wire [((DPI_SCALER == 2) ? 3 : 2)*24-1:0] dpi_lb_rdata_i,

// HDMI (DIF_TYPE 5): TMDS symbols on the pixel-domain clock, {red, green, blue}, bit 0 sent first
    output wire          [29:0] tmds_o,

// HDMI DDC (DIF_TYPE 5, DPI_DDC_EN = 1): open-drain lines, the I2C master runs in software
    input  wire                 ddc_scl_i,                  // SCL level (asynchronous)
    input  wire                 ddc_sda_i,                  // SDA level (asynchronous)
    output wire                 ddc_scl_pd_o,               // SCL pulled low (open-drain pad enable)
    output wire                 ddc_sda_pd_o,               // SDA pulled low

// HDMI audio (DIF_TYPE 5, DPI_AUDIO_EN = 1): I2S input, Belenos the clock slave
    input  wire                 i2s_bclk_i,                 // bit clock (asynchronous, at most a quarter of the pixel clock)
    input  wire                 i2s_lrck_i,                 // word clock (asynchronous; low = left)
    input  wire                 i2s_sd_i                    // data (asynchronous)

);


//=============================================================================
// 1)  PARAMETER CHECKS
//=============================================================================

// Each rule once, as a localparam: the simulation message below and, for the
// tools that skip it (ASIC and FPGA synthesis), PARAM_ERR (their OR)
localparam ERR_VRAM        = (VRAM_WORDS < 1) || (VRAM_AW < 1) || (VRAM_AW > 24) || (VRAM_WORDS > (1 << VRAM_AW)) ||
                             ((VRAM_AW > 1) && (VRAM_WORDS <= (1 << (VRAM_AW-1))));
localparam ERR_DIM_W       = (DIM_W < 4) || (DIM_W > 16);
localparam ERR_FRAME_NR    = (FRAME_NR != 1) && (FRAME_NR != 2) && (FRAME_NR != 4);
localparam ERR_GPU_FIFO_AW = (GPU_FIFO_AW < 3) || (GPU_FIFO_AW > 6);
localparam ERR_LUT_EN      = (LUT_EN != 0) && (LUT_EN != 1);
localparam ERR_LUT_BANKS   = (LUT_BANKS != 1) && (LUT_BANKS != 2);
localparam ERR_GPU_EN      = (GPU_EN != 0) && (GPU_EN != 1);
localparam ERR_DIF_TYPE    = (DIF_TYPE < 0) || (DIF_TYPE > 5);
localparam ERR_DDC_EN      = (DPI_DDC_EN != 0) && (DPI_DDC_EN != 1);
localparam ERR_ISLAND_EN   = (DPI_ISLAND_EN != 0) && (DPI_ISLAND_EN != 1);
localparam ERR_AUDIO_EN    = (DPI_AUDIO_EN != 0) && (DPI_AUDIO_EN != 1);
// HDMI audio rides in the HDMI data islands: without them it would be left
// out of the build without a word
localparam ERR_AUDIO_DEP   = (DPI_AUDIO_EN == 1) && ((DIF_TYPE != 5) || (DPI_ISLAND_EN != 1));
localparam ERR_PRIV        = (PRIV_CHECK_EN != 0) && (PRIV_CHECK_EN != 1);
localparam ERR_CURSOR      = (CURSOR_EN != 0) && (CURSOR_EN != 1);
localparam ERR_ASYNC_RST   = (ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1);
localparam ERR_RD_REG      = (VRAM_RD_REG_EN != 0) && (VRAM_RD_REG_EN != 1);
localparam ERR_RD_LAT      = (VRAM_RD_LAT < 1) || (VRAM_RD_LAT > 3);
localparam ERR_GPU_FEAT    = ((GPU_XY_EN != 0) && (GPU_XY_EN != 1)) ||
                             ((GPU_GRAD_EN != 0) && (GPU_GRAD_EN != 1)) || ((GPU_BLEND_EN != 0) && (GPU_BLEND_EN != 1)) ||
                             ((GPU_TRI_EN != 0) && (GPU_TRI_EN != 1)) || ((GPU_RUNAHEAD_EN != 0) && (GPU_RUNAHEAD_EN != 1)) ||
                             ((GPU_REMAP_EN != 0) && (GPU_REMAP_EN != 1)) || ((GPU_MPLANE_EN != 0) && (GPU_MPLANE_EN != 1)) ||
                             ((GPU_IMM_EN != 0) && (GPU_IMM_EN != 1)) || ((GPU_LINE_EN != 0) && (GPU_LINE_EN != 1)) ||
                             ((GPU_BILINEAR_EN != 0) && (GPU_BILINEAR_EN != 1));
localparam ERR_DPI         = (DPI_LB_AW < 9) || (DPI_LB_AW > 12) || (DPI_SCALER < 0) || (DPI_SCALER > 2) ||
                             ((DPI_PCLK_SEP != 0) && (DPI_PCLK_SEP != 1));

// pragma translate_off
generate
    if (ERR_VRAM) begin : CHECK_VRAM
        initial $fatal(1, "belenos: VRAM_AW (%0d) must satisfy 2^(VRAM_AW-1) < VRAM_WORDS (%0d) <= 2^VRAM_AW, VRAM_AW <= 24.", VRAM_AW, VRAM_WORDS);
    end
    if (ERR_DIM_W) begin : CHECK_DIM_W
        initial $fatal(1, "belenos: DIM_W (%0d) must be 4..16.", DIM_W);
    end
    if (ERR_FRAME_NR) begin : CHECK_FRAME_NR
        initial $fatal(1, "belenos: FRAME_NR (%0d) must be 1, 2 or 4.", FRAME_NR);
    end
    if (ERR_GPU_FIFO_AW) begin : CHECK_GPU_FIFO_AW
        initial $fatal(1, "belenos: GPU_FIFO_AW (%0d) must be 3..6.", GPU_FIFO_AW);
    end
    if (ERR_LUT_EN) begin : CHECK_LUT_EN
        initial $fatal(1, "belenos: LUT_EN (%0d) must be 0 or 1.", LUT_EN);
    end
    if (ERR_LUT_BANKS) begin : CHECK_LUT_BANKS
        initial $fatal(1, "belenos: LUT_BANKS (%0d) must be 1 or 2.", LUT_BANKS);
    end
    if (ERR_GPU_EN) begin : CHECK_GPU_EN
        initial $fatal(1, "belenos: GPU_EN (%0d) must be 0 or 1.", GPU_EN);
    end
    if (ERR_DIF_TYPE) begin : CHECK_DIF_TYPE
        initial $fatal(1, "belenos: DIF_TYPE (%0d) must be 0 (BDI), 1 (DBI_SPI), 2 (DBI_PAR), 3 (DBI_PAR_SPI), 4 (DPI) or 5 (HDMI).", DIF_TYPE);
    end
    if (ERR_DDC_EN) begin : CHECK_DPI_DDC_EN
        initial $fatal(1, "belenos: DPI_DDC_EN (%0d) must be 0 or 1.", DPI_DDC_EN);
    end
    if (ERR_ISLAND_EN) begin : CHECK_DPI_ISLAND_EN
        initial $fatal(1, "belenos: DPI_ISLAND_EN (%0d) must be 0 or 1.", DPI_ISLAND_EN);
    end
    if (ERR_AUDIO_EN) begin : CHECK_DPI_AUDIO_EN
        initial $fatal(1, "belenos: DPI_AUDIO_EN (%0d) must be 0 or 1.", DPI_AUDIO_EN);
    end
    if (ERR_AUDIO_DEP) begin : CHECK_DPI_AUDIO_DEP
        initial $fatal(1, "belenos: DPI_AUDIO_EN = 1 needs DIF_TYPE = 5 and DPI_ISLAND_EN = 1 (DIF_TYPE %0d, DPI_ISLAND_EN %0d).", DIF_TYPE, DPI_ISLAND_EN);
    end
    if (ERR_CURSOR) begin : CHECK_CURSOR_EN
        initial $fatal(1, "belenos: CURSOR_EN (%0d) must be 0 or 1.", CURSOR_EN);
    end
    if (ERR_PRIV) begin : CHECK_PRIV_CHECK_EN
        initial $fatal(1, "belenos: PRIV_CHECK_EN (%0d) must be 0 or 1.", PRIV_CHECK_EN);
    end
    if (ERR_ASYNC_RST) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "belenos: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
    if (ERR_RD_REG) begin : CHECK_VRAM_RD_REG_EN
        initial $fatal(1, "belenos: VRAM_RD_REG_EN (%0d) must be 0 or 1.", VRAM_RD_REG_EN);
    end
    if (ERR_RD_LAT) begin : CHECK_VRAM_RD_LAT
        initial $fatal(1, "belenos: VRAM_RD_LAT (%0d) must be 1..3.", VRAM_RD_LAT);
    end
    if (ERR_GPU_FEAT) begin : CHECK_GPU_FEATURES
        initial $fatal(1, "belenos: GPU_XY_EN, GPU_GRAD_EN, GPU_BLEND_EN, GPU_TRI_EN, GPU_RUNAHEAD_EN, GPU_REMAP_EN, GPU_MPLANE_EN, GPU_IMM_EN, GPU_LINE_EN and GPU_BILINEAR_EN must be 0 or 1.");
    end
    if (ERR_DPI) begin : CHECK_DPI_PARAMS
        initial $fatal(1, "belenos: DPI_LB_AW (%0d) must be 9..12, DPI_SCALER (%0d) 0..2, DPI_PCLK_SEP (%0d) 0 or 1.", DPI_LB_AW, DPI_SCALER, DPI_PCLK_SEP);
    end
    // Triangles need the x/y coordinates: without them they are left out (a
    // TRI command is then an invalid command, as for any absent feature)
    if ((GPU_EN == 1) && (GPU_TRI_EN == 1) && (GPU_XY_EN == 0)) begin : NOTE_TRI_WITHOUT_XY
        initial $display("belenos: note: GPU_TRI_EN = 1 without GPU_XY_EN: triangles are not built.");
    end
    if ((GPU_EN == 1) && (GPU_LINE_EN == 1) && (GPU_XY_EN == 0)) begin : NOTE_LINE_WITHOUT_XY
        initial $display("belenos: note: GPU_LINE_EN = 1 without GPU_XY_EN: lines are not built.");
    end
    if ((GPU_EN == 1) && (GPU_BILINEAR_EN == 1) && (GPU_XY_EN == 0)) begin : NOTE_BILINEAR_WITHOUT_XY
        initial $display("belenos: note: GPU_BILINEAR_EN = 1 without GPU_XY_EN: bilinear sampling is not built.");
    end
endgenerate
// pragma translate_on

// The same checks for the synthesis and FPGA tools, which skip the block
// above: an illegal value instantiates a module that does not exist, so every
// tool stops at elaboration (the simulation tools report the message above
// first).
localparam PARAM_ERR = ERR_VRAM || ERR_DIM_W || ERR_FRAME_NR || ERR_GPU_FIFO_AW || ERR_LUT_EN || ERR_LUT_BANKS ||
                       ERR_GPU_EN || ERR_DIF_TYPE || ERR_DDC_EN || ERR_ISLAND_EN || ERR_AUDIO_EN || ERR_AUDIO_DEP ||
                       ERR_PRIV || ERR_ASYNC_RST || ERR_RD_REG || ERR_RD_LAT || ERR_GPU_FEAT || ERR_DPI || ERR_CURSOR;
generate
    if (PARAM_ERR) begin : ILLEGAL_PARAMETER
        belenos_illegal_parameter_value u_illegal_parameter_value ();
    end
endgenerate

// Display drivers (DIF_TYPE; 0 = none, the BDI is exported)
localparam              DIF_DBI_SPI     = 1;        // DBI over SPI
localparam              DIF_DBI_PAR     = 2;        // DBI over the 8080-16 bus
localparam              DIF_DBI_PAR_SPI = 3;        // DBI over both buses
localparam              DIF_DPI         = 4;        // parallel RGB
localparam              DIF_HDMI        = 5;        // parallel RGB and TMDS symbols
localparam              DBI_EN          = (DIF_TYPE == DIF_DBI_SPI) || (DIF_TYPE == DIF_DBI_PAR) ||
                                          (DIF_TYPE == DIF_DBI_PAR_SPI);
localparam              DPI_EN          = (DIF_TYPE == DIF_DPI) || (DIF_TYPE == DIF_HDMI);
localparam              TMDS_EN         = (DIF_TYPE == DIF_HDMI);
localparam              DDC_EN          = TMDS_EN && (DPI_DDC_EN != 0);
localparam              ISLAND_EN       = TMDS_EN && (DPI_ISLAND_EN != 0);
localparam              AUDIO_EN        = ISLAND_EN && (DPI_AUDIO_EN != 0);
localparam              DPI_NB          = (DPI_SCALER == 2) ? 3 : 2;


//=============================================================================
// 2)  CORE
//=============================================================================

wire                    px_ready;
wire                    refresh_active;
wire                    size_hold;
wire             [31:0] reg_rdata;
wire                    reg_ready;
wire                    dif_irq;
wire                    dif_busy;
wire                    dpi_cl_swap;
wire        [DIM_W-1:0] dpi_line_len_m1;
wire        [DIM_W-1:0] dbi_win_width;
wire        [DIM_W-1:0] dbi_win_height;

belenos_core #(
    .VRAM_WORDS           ( VRAM_WORDS        ),
    .VRAM_AW              ( VRAM_AW           ),
    .VRAM_RD_LAT          ( VRAM_RD_LAT       ),
    .VRAM_RD_REG_EN       ( VRAM_RD_REG_EN    ),
    .DIM_W                ( DIM_W             ),
    .FRAME_NR             ( FRAME_NR          ),
    .LUT_EN               ( LUT_EN            ),
    .LUT_BANKS            ( LUT_BANKS         ),
    .GPU_EN               ( GPU_EN            ),
    .GPU_XY_EN            ( GPU_XY_EN         ),
    .GPU_GRAD_EN          ( GPU_GRAD_EN       ),
    .GPU_BLEND_EN         ( GPU_BLEND_EN      ),
    .GPU_TRI_EN           ( GPU_TRI_EN        ),
    .GPU_RUNAHEAD_EN      ( GPU_RUNAHEAD_EN   ),
    .GPU_REMAP_EN         ( GPU_REMAP_EN      ),
    .GPU_MPLANE_EN        ( GPU_MPLANE_EN     ),
    .GPU_IMM_EN           ( GPU_IMM_EN        ),
    .GPU_LINE_EN          ( GPU_LINE_EN       ),
    .GPU_BILINEAR_EN      ( GPU_BILINEAR_EN   ),
    .GPU_FIFO_AW          ( GPU_FIFO_AW       ),
    .DIF_TYPE             ( DIF_TYPE          ),
    .CURSOR_EN            ( CURSOR_EN         ),
    .PRIV_CHECK_EN        ( PRIV_CHECK_EN     ),
    .ASYNC_RST_EN         ( ASYNC_RST_EN      )
) u_core (
    .hclk_i               ( hclk_i            ),
    .hresetn_i            ( hresetn_i         ),
    .hclk_en_o            ( hclk_en_o         ),
    .r_hsel_i             ( r_hsel_i          ),
    .r_haddr_i            ( r_haddr_i         ),
    .r_htrans_i           ( r_htrans_i        ),
    .r_hwrite_i           ( r_hwrite_i        ),
    .r_hsize_i            ( r_hsize_i         ),
    .r_hprot_i            ( r_hprot_i         ),
    .r_hsmode_i           ( r_hsmode_i        ),
    .r_hready_i           ( r_hready_i        ),
    .r_hwdata_i           ( r_hwdata_i        ),
    .r_hrdata_o           ( r_hrdata_o        ),
    .r_hreadyout_o        ( r_hreadyout_o     ),
    .r_hresp_o            ( r_hresp_o         ),
    .v_hsel_i             ( v_hsel_i          ),
    .v_haddr_i            ( v_haddr_i         ),
    .v_htrans_i           ( v_htrans_i        ),
    .v_hwrite_i           ( v_hwrite_i        ),
    .v_hsize_i            ( v_hsize_i         ),
    .v_hprot_i            ( v_hprot_i         ),
    .v_hsmode_i           ( v_hsmode_i        ),
    .v_hready_i           ( v_hready_i        ),
    .v_hwdata_i           ( v_hwdata_i        ),
    .v_hrdata_o           ( v_hrdata_o        ),
    .v_hreadyout_o        ( v_hreadyout_o     ),
    .v_hresp_o            ( v_hresp_o         ),
    .vram_cen_o           ( vram_cen_o        ),
    .vram_wen_o           ( vram_wen_o        ),
    .vram_addr_o          ( vram_addr_o       ),
    .vram_din_o           ( vram_din_o        ),
    .vram_dout_i          ( vram_dout_i       ),
    .lut_cen_o            ( lut_cen_o         ),
    .lut_wen_o            ( lut_wen_o         ),
    .lut_addr_o           ( lut_addr_o        ),
    .lut_din_o            ( lut_din_o         ),
    .lut_dout_i           ( lut_dout_i        ),
    .dbg_stoptime_i       ( dbg_stoptime_i    ),
    .irq_o                ( irq_o             ),
    .bdi_px_valid_o       ( bdi_px_valid_o    ),
    .bdi_px_data_o        ( bdi_px_data_o     ),
    .bdi_px_last_o        ( bdi_px_last_o     ),
    .bdi_px_ready_i       ( px_ready          ),
    .bdi_refresh_trig_o   ( bdi_refresh_trig_o),
    .bdi_refresh_active_i ( refresh_active    ),
    .dbi_size_hold_i      ( size_hold         ),
    .dbi_win_width_i      ( dbi_win_width     ),
    .dbi_win_height_i     ( dbi_win_height    ),
    .bdi_width_o          ( bdi_width_o       ),
    .bdi_height_o         ( bdi_height_o      ),
    .bdi_reg_sel_o        ( bdi_reg_sel_o     ),
    .bdi_reg_addr_o       ( bdi_reg_addr_o    ),
    .bdi_reg_wr_o         ( bdi_reg_wr_o      ),
    .bdi_reg_wdata_o      ( bdi_reg_wdata_o   ),
    .bdi_reg_rdata_i      ( reg_rdata         ),
    .bdi_reg_ready_i      ( reg_ready         ),
    .bdi_irq_i            ( dif_irq           ),
    .bdi_busy_i           ( dif_busy          ),
    .dpi_cl_swap_o        ( dpi_cl_swap       ),
    .dpi_line_len_m1_o    ( dpi_line_len_m1   )
);


//=============================================================================
// 3)  DISPLAY DRIVER
//=============================================================================

generate
    if (DBI_EN) begin : G_DBI
        blns_dbi #(
            .DIF_TYPE         ( DIF_TYPE           ),
            .DIM_W            ( DIM_W              ),
            .ASYNC_RST_EN     ( ASYNC_RST_EN       )
        ) u_dbi (
            .hclk_i           ( hclk_i             ),
            .hresetn_i        ( hresetn_i          ),
            .px_valid_i       ( bdi_px_valid_o     ),
            .px_data_i        ( bdi_px_data_o      ),
            .px_last_i        ( bdi_px_last_o      ),
            .px_ready_o       ( px_ready           ),
            .refresh_trig_i   ( bdi_refresh_trig_o ),
            .refresh_active_o ( refresh_active     ),
            .size_hold_o      ( size_hold          ),
            .width_i          ( bdi_width_o        ),
            .height_i         ( bdi_height_o       ),
            .win_width_o      ( dbi_win_width      ),
            .win_height_o     ( dbi_win_height     ),
            .reg_sel_i        ( bdi_reg_sel_o      ),
            .reg_addr_i       ( bdi_reg_addr_o     ),
            .reg_wr_i         ( bdi_reg_wr_o       ),
            .reg_wdata_i      ( bdi_reg_wdata_o    ),
            .reg_rdata_o      ( reg_rdata          ),
            .reg_ready_o      ( reg_ready          ),
            .irq_o            ( dif_irq            ),
            .busy_o           ( dif_busy           ),
            .lcd_d_i          ( lcd_d_i            ),
            .lcd_d_o          ( lcd_d_o            ),
            .lcd_d_oe_o       ( lcd_d_oe_o         ),
            .lcd_cs_n_o       ( lcd_cs_n_o         ),
            .lcd_rd_n_o       ( lcd_rd_n_o         ),
            .lcd_wr_n_o       ( lcd_wr_n_o         ),
            .lcd_dc_o         ( lcd_dc_o           ),
            .spi_sck_o        ( spi_sck_o          ),
            .spi_mosi_o       ( spi_mosi_o         ),
            .spi_miso_i       ( spi_miso_i         ),
            .spi_cs_n_o       ( spi_cs_n_o         ),
            .spi_dc_o         ( spi_dc_o           ),
            .lcd_reset_n_o    ( lcd_reset_n_o      ),
            .lcd_on_o         ( lcd_on_o           ),
            .lcd_te_i         ( lcd_te_i           )
        );
        wire   [36:0] bdi_ext_unused = {bdi_px_ready_i, bdi_refresh_active_i, bdi_reg_rdata_i,
                                        bdi_reg_ready_i, bdi_irq_i, bdi_busy_i};
        // DPI pins idle, line-buffer macros unused
        assign dpi_de_o       = 1'b0;
        assign dpi_hs_o       = 1'b1;
        assign dpi_vs_o       = 1'b1;
        assign dpi_rgb_o      = 24'h000000;
        assign dpi_clk_d0_o   = 1'b0;
        assign dpi_clk_d1_o   = 1'b0;
        assign dpi_lb_we_o    = {DPI_NB{1'b0}};
        assign dpi_lb_waddr_o = {DPI_LB_AW{1'b0}};
        assign dpi_lb_wdata_o = 24'h000000;
        assign dpi_lb_raddr_o = {DPI_LB_AW{1'b0}};
        assign tmds_o         = 30'h0;
        assign ddc_scl_pd_o   = 1'b0;
        assign ddc_sda_pd_o   = 1'b0;
        wire   dpi_unused     = dpi_pclk_i | dpi_presetn_i | panel_detect_i | (|dpi_lb_rdata_i) | dpi_cl_swap |
                                ddc_scl_i  | ddc_sda_i     | i2s_bclk_i     | i2s_lrck_i        | i2s_sd_i    ;
        wire   [DIM_W-1:0] dpi_line_len_unused = dpi_line_len_m1;
    end else if (DPI_EN) begin : G_DPI
        blns_dpi #(
            .DIM_W            ( DIM_W              ),
            .LB_AW            ( DPI_LB_AW          ),
            .SCALER           ( DPI_SCALER         ),
            .PCLK_SEP         ( DPI_PCLK_SEP       ),
            .TMDS_EN          ( TMDS_EN            ),
            .DDC_EN           ( DDC_EN             ),
            .ISLAND_EN        ( ISLAND_EN          ),
            .AUDIO_EN         ( AUDIO_EN           ),
            .ASYNC_RST_EN     ( ASYNC_RST_EN       )
        ) u_dpi (
            .hclk_i           ( hclk_i             ),
            .hresetn_i        ( hresetn_i          ),
            .px_valid_i       ( bdi_px_valid_o     ),
            .px_data_i        ( bdi_px_data_o      ),
            .px_last_i        ( bdi_px_last_o      ),
            .px_ready_o       ( px_ready           ),
            .refresh_trig_i   ( bdi_refresh_trig_o ),
            .refresh_active_o ( refresh_active     ),
            .width_i          ( bdi_width_o        ),
            .height_i         ( bdi_height_o       ),
            .cl_swap_i        ( dpi_cl_swap        ),
            .line_len_m1_i    ( dpi_line_len_m1    ),
            .reg_sel_i        ( bdi_reg_sel_o      ),
            .reg_addr_i       ( bdi_reg_addr_o     ),
            .reg_wr_i         ( bdi_reg_wr_o       ),
            .reg_wdata_i      ( bdi_reg_wdata_o    ),
            .reg_rdata_o      ( reg_rdata          ),
            .reg_ready_o      ( reg_ready          ),
            .irq_o            ( dif_irq            ),
            .busy_o           ( dif_busy           ),
            .lcd_reset_n_o    ( lcd_reset_n_o      ),
            .lcd_on_o         ( lcd_on_o           ),
            .dpi_pclk_i       ( dpi_pclk_i         ),
            .dpi_presetn_i    ( dpi_presetn_i      ),
            .dpi_de_o         ( dpi_de_o           ),
            .dpi_hs_o         ( dpi_hs_o           ),
            .dpi_vs_o         ( dpi_vs_o           ),
            .dpi_rgb_o        ( dpi_rgb_o          ),
            .dpi_clk_d0_o     ( dpi_clk_d0_o       ),
            .dpi_clk_d1_o     ( dpi_clk_d1_o       ),
            .panel_detect_i   ( panel_detect_i     ),
            .tmds_o           ( tmds_o             ),
            .ddc_scl_i        ( ddc_scl_i          ),
            .ddc_sda_i        ( ddc_sda_i          ),
            .ddc_scl_pd_o     ( ddc_scl_pd_o       ),
            .ddc_sda_pd_o     ( ddc_sda_pd_o       ),
            .i2s_bclk_i       ( i2s_bclk_i         ),
            .i2s_lrck_i       ( i2s_lrck_i         ),
            .i2s_sd_i         ( i2s_sd_i           ),
            .dpi_lb_we_o      ( dpi_lb_we_o        ),
            .dpi_lb_waddr_o   ( dpi_lb_waddr_o     ),
            .dpi_lb_wdata_o   ( dpi_lb_wdata_o     ),
            .dpi_lb_raddr_o   ( dpi_lb_raddr_o     ),
            .dpi_lb_rdata_i   ( dpi_lb_rdata_i     )
        );
        assign size_hold      = 1'b0;
        assign dbi_win_width  = {DIM_W{1'b0}};
        assign dbi_win_height = {DIM_W{1'b0}};
        assign lcd_d_o        = 16'h0000;
        assign lcd_d_oe_o     = 1'b0;
        assign lcd_cs_n_o     = 1'b1;
        assign lcd_rd_n_o     = 1'b1;
        assign lcd_wr_n_o     = 1'b1;
        assign lcd_dc_o       = 1'b0;
        assign spi_sck_o      = 1'b0;
        assign spi_mosi_o     = 1'b0;
        assign spi_cs_n_o     = 1'b1;
        assign spi_dc_o       = 1'b0;
        wire   [36:0] bdi_ext_unused = {bdi_px_ready_i, bdi_refresh_active_i, bdi_reg_rdata_i,
                                        bdi_reg_ready_i, bdi_irq_i, bdi_busy_i};
        wire   [18:0] dbi_pins_unused = {lcd_d_i, spi_miso_i, lcd_te_i, 1'b0};
    end else begin : G_NO_DBI
        assign px_ready       = bdi_px_ready_i;
        assign refresh_active = bdi_refresh_active_i;
        assign size_hold      = 1'b0;
        assign dbi_win_width  = {DIM_W{1'b0}};
        assign dbi_win_height = {DIM_W{1'b0}};
        assign reg_rdata      = bdi_reg_rdata_i;
        assign reg_ready      = bdi_reg_ready_i;
        assign dif_irq        = bdi_irq_i;
        assign dif_busy       = bdi_busy_i;
        assign lcd_d_o        = 16'h0000;
        assign lcd_d_oe_o     = 1'b0;
        assign lcd_cs_n_o     = 1'b1;
        assign lcd_rd_n_o     = 1'b1;
        assign lcd_wr_n_o     = 1'b1;
        assign lcd_dc_o       = 1'b0;
        assign spi_sck_o      = 1'b0;
        assign spi_mosi_o     = 1'b0;
        assign spi_cs_n_o     = 1'b1;
        assign spi_dc_o       = 1'b0;
        assign lcd_reset_n_o  = 1'b1;
        assign lcd_on_o       = 1'b0;
        wire   [18:0] pins_unused = {lcd_d_i, spi_miso_i, lcd_te_i, 1'b0};
        assign dpi_de_o       = 1'b0;
        assign dpi_hs_o       = 1'b1;
        assign dpi_vs_o       = 1'b1;
        assign dpi_rgb_o      = 24'h000000;
        assign dpi_clk_d0_o   = 1'b0;
        assign dpi_clk_d1_o   = 1'b0;
        assign dpi_lb_we_o    = {DPI_NB{1'b0}};
        assign dpi_lb_waddr_o = {DPI_LB_AW{1'b0}};
        assign dpi_lb_wdata_o = 24'h000000;
        assign dpi_lb_raddr_o = {DPI_LB_AW{1'b0}};
        assign tmds_o         = 30'h0;
        assign ddc_scl_pd_o   = 1'b0;
        assign ddc_sda_pd_o   = 1'b0;
        wire   dpi_unused     = dpi_pclk_i | dpi_presetn_i | panel_detect_i | (|dpi_lb_rdata_i) | dpi_cl_swap |
                                ddc_scl_i  | ddc_sda_i     | i2s_bclk_i     | i2s_lrck_i        | i2s_sd_i    ;
        wire   [DIM_W-1:0] dpi_line_len_unused = dpi_line_len_m1;
    end
endgenerate

endmodule // belenos

`default_nettype wire
