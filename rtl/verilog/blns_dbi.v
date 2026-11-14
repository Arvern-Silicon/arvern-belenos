//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_dbi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_dbi.v
// Module Description : MIPI-DBI display driver (ILI9341 / ST7789 command set) attached
//                      through the BDI contract, with 8080-16 and 4-wire SPI physical layers.
//----------------------------------------------------------------------------
`default_nettype none

module  blns_dbi #(
    parameter                 DIF_TYPE     = 2,     // 1 = SPI, 2 = 8080, 3 = both (runtime select)
    parameter                 DIM_W        = 10,    // width/height field width
    parameter                 ASYNC_RST_EN = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (
    input  wire               hclk_i,               // clock
    input  wire               hresetn_i,            // active-low reset (style per ASYNC_RST_EN)
    input  wire               px_valid_i,           // BDI pixel available
    input  wire        [23:0] px_data_i,            // BDI pixel (RGB888)
    input  wire               px_last_i,            // final pixel of the frame
    output wire               px_ready_o,           // pixel taken
    input  wire               refresh_trig_i,       // frame request (1 cycle)
    output wire               refresh_active_o,     // sending a frame
    output wire               size_hold_o,          // refresh started, before its frame
    input  wire   [DIM_W-1:0] width_i,              // display width
    input  wire   [DIM_W-1:0] height_i,             // display height
    output wire   [DIM_W-1:0] win_width_o,          // size the current operation took at its start
    output wire   [DIM_W-1:0] win_height_o,         // (the held size while size_hold_o is set)
    input  wire               reg_sel_i,            // BDI register transfer pending
    input  wire         [5:0] reg_addr_i,           // word offset in the BDI window ([5]: page at 0x200, unmapped here)
    input  wire               reg_wr_i,             // 1 = write
    input  wire        [31:0] reg_wdata_i,          // write data
    output wire        [31:0] reg_rdata_o,          // read data (valid with ready)
    output wire               reg_ready_o,          // transfer completes
    output wire               irq_o,                // driver interrupt (level)
    output wire               busy_o,               // driver busy
    input  wire        [15:0] lcd_d_i,              // 8080 data in
    output wire        [15:0] lcd_d_o,              // 8080 data out
    output wire               lcd_d_oe_o,           // 8080 data output enable
    output wire               lcd_cs_n_o,           // 8080 chip select
    output wire               lcd_rd_n_o,           // 8080 read strobe
    output wire               lcd_wr_n_o,           // 8080 write strobe
    output wire               lcd_dc_o,             // 8080 data/command (0 = command)
    output wire               spi_sck_o,            // SPI clock
    output wire               spi_mosi_o,           // SPI data out
    input  wire               spi_miso_i,           // SPI data in
    output wire               spi_cs_n_o,           // SPI chip select
    output wire               spi_dc_o,             // SPI data/command (0 = command)
    output wire               lcd_reset_n_o,        // panel reset
    output wire               lcd_on_o,             // panel power/backlight on
    input  wire               lcd_te_i              // panel tearing-effect output
);

//=============================================================================
// 1)  PARAMETERS
//=============================================================================

// pragma translate_off
generate
    if ((DIF_TYPE < 1) || (DIF_TYPE > 3)) begin : CHECK_DIF_TYPE
        initial $fatal(1, "blns_dbi: DIF_TYPE (%0d) must be 1..3.", DIF_TYPE);
    end
    if ((DIM_W < 4) || (DIM_W > 16)) begin : CHECK_DIM_W
        initial $fatal(1, "blns_dbi: DIM_W (%0d) must be 4..16.", DIM_W);
    end
endgenerate
// pragma translate_on

localparam       SPI_EN    = (DIF_TYPE == 1) || (DIF_TYPE == 3);   // SPI PHY present
localparam       P8080_EN  = (DIF_TYPE == 2) || (DIF_TYPE == 3);   // 8080 PHY present
localparam       PSEL_EN   = (DIF_TYPE == 3);                      // runtime PHY select
localparam       ARST_EN   = (ASYNC_RST_EN != 0);

// Register word offsets (BDI window 0x180 + 4*n)
localparam [5:0] A_CFG      = 6'd0,
                 A_SYNC     = 6'd1,
                 A_CMD      = 6'd2,
                 A_PARAM    = 6'd3,
                 A_DFILL    = 6'd4,
                 A_STATUS   = 6'd5,
                 A_IRQ_EN   = 6'd6,
                 A_IRQ_FLAG = 6'd7;

//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

// Registers
wire                      cfg_lcd_on;
wire                      cfg_lcd_reset;
wire                      cfg_phy_sel;
wire                [3:0] cfg_clk_div;
wire                [3:0] cfg_rd_div;
wire                [3:0] rd_div_eff;       // read strobe divider: RD_DIV, or CLK_DIV when RD_DIV = 0
wire                      cfg_hw_win;
wire                [3:0] op_clk_div;       // CLK_DIV of the operation in progress
wire                [3:0] op_rd_div;        // read strobe divider of the operation in progress
wire                      op_hw_win;        // HW_WINDOW_EN of the operation in progress
wire                      op_hw_win_eff;    // the same, or DIF_CFG's in the idle cycle (start decision)
wire                [9:0] sync_scanline;
wire                      sync_scan_en;
wire                      sync_te_en;
wire                [2:0] irq_en;
wire                [2:0] irq_flag;
wire                      phy_spi;          // SPI PHY in use (frozen while busy)
wire                      phy_spi_eff;      // PHY in use, or being latched in the idle cycle
wire                      te_sync;
wire                      te_q;

// Register access
wire                      sel_cfg;
wire                      sel_sync;
wire                      sel_cmd;
wire                      sel_param;
wire                      sel_dfill;
wire                      sel_status;
wire                      sel_irq_en;
wire                      sel_irq_flag;
wire                      ovfl_set;
wire                      param_ovfl_set;
wire                      param_ovfl_clr;
wire                      param_ovfl;
wire                      cmd_free;
wire                      dfill_free;
wire                      reg_ready;
wire                      reg_wr;
wire                      cfg_wr;
wire                      sync_wr;
wire                      cmd_wr;
wire                      param_wr;
wire                      dfill_wr;
wire                      irq_en_wr;
wire                      irq_flag_wr;
wire               [31:0] cfg_rd;
wire               [31:0] sync_rd;
wire               [31:0] status_rd;

// Engine
wire                      eng_busy;
wire                      cmd_pend;
wire                      dfill_pend;
wire                      refr_pend;
wire                      param_full;
wire                [4:0] param_level;
wire                      refr_busy;
wire                      wait_sync;
wire                      dfill_busy;
wire                      eng_done;
wire                      status_busy;
wire                      te_rise;
wire                      scan_sync_en;
wire                      phy_spi_en;
wire                      phy_spi_nxt;
wire                      cfg_phy_sel_nxt;
wire                [2:0] irq_flag_set;
wire                      irq_flag_en;
wire                [2:0] irq_flag_nxt;

// PHY item interface
wire                      txn;
wire                      xfer_valid;
wire                      xfer_rd;
wire                      xfer_dc;
wire                      xfer_px;
wire               [15:0] xfer_data;
wire                      xfer_ready;
wire                      phy_idle;
wire                      rd_valid;
wire                [7:0] rd_data;
wire                      p80_sel;
wire                      p80_ready;
wire                      p80_idle;
wire                      p80_rd_valid;
wire                [7:0] p80_rd_data;
wire                      spi_sel;
wire                      spi_ready;
wire                      spi_idle;

//=============================================================================
// 3)  REGISTER ACCESS
//=============================================================================

assign sel_cfg      = (reg_addr_i == A_CFG);
assign sel_sync     = (reg_addr_i == A_SYNC);
assign sel_cmd      = (reg_addr_i == A_CMD);
assign sel_param    = (reg_addr_i == A_PARAM);
assign sel_dfill    = (reg_addr_i == A_DFILL);
assign sel_status   = (reg_addr_i == A_STATUS);
assign sel_irq_en   = (reg_addr_i == A_IRQ_EN);
assign sel_irq_flag = (reg_addr_i == A_IRQ_FLAG);

// No wait states: a command / fill write to an occupied slot, or a parameter
// write to a full FIFO, completes at once and is dropped (CMD_OVFL / PARAM_OVFL)
assign reg_ready    = reg_sel_i;
assign reg_ready_o  = reg_ready;

// Side effects in the completion cycle only
assign reg_wr       = reg_ready & reg_wr_i;
assign cfg_wr       = reg_wr & sel_cfg;
assign sync_wr      = reg_wr & sel_sync;
assign cmd_wr       = reg_wr & sel_cmd   & cmd_free;
assign param_wr     = reg_wr & sel_param & ~param_full;
assign dfill_wr     = reg_wr & sel_dfill & dfill_free;
assign ovfl_set     = reg_wr & ((sel_cmd & ~cmd_free) | (sel_dfill & ~dfill_free));
assign param_ovfl_set = reg_wr & sel_param & param_full;
assign param_ovfl_clr = reg_wr & sel_status & reg_wdata_i[7];
assign irq_en_wr    = reg_wr & sel_irq_en;
assign irq_flag_wr  = reg_wr & sel_irq_flag;

//-----------------------------------------------------------------------------
// DIF_CFG: [0] LCD_ON, [1] LCD_RESET, [2] PHY_SEL, [7:4] RD_DIV, [11:8] CLK_DIV,
// [12] HW_WINDOW_EN
//-----------------------------------------------------------------------------
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cfg_lcd_on (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cfg_wr), .d_i(reg_wdata_i[0]),    .q_o(cfg_lcd_on));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cfg_lcd_reset (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cfg_wr), .d_i(reg_wdata_i[1]),    .q_o(cfg_lcd_reset));

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_cfg_clk_div (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cfg_wr), .d_i(reg_wdata_i[11:8]), .q_o(cfg_clk_div));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cfg_hw_win (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cfg_wr), .d_i(reg_wdata_i[12]),   .q_o(cfg_hw_win));

generate
    if (PSEL_EN) begin : g_phy_sel
        assign cfg_phy_sel_nxt = reg_wdata_i[2];

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cfg_phy_sel (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cfg_wr), .d_i(cfg_phy_sel_nxt), .q_o(cfg_phy_sel));

        // The PHY in use follows PHY_SEL while the engine is idle: the edge that
        // starts an operation also latches its PHY, which then holds until the
        // operation (including the PHY's last item) has completed.
        assign phy_spi_en  = ~eng_busy;
        assign phy_spi_nxt = cfg_phy_sel;

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_phy_spi (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(phy_spi_en), .d_i(phy_spi_nxt), .q_o(phy_spi));
    end else begin : g_no_phy_sel
        assign cfg_phy_sel     = SPI_EN ? 1'b1 : 1'b0;
        assign phy_spi         = SPI_EN ? 1'b1 : 1'b0;
        assign cfg_phy_sel_nxt = 1'b0;
        assign phy_spi_en      = 1'b0;
        assign phy_spi_nxt     = 1'b0;
        wire   phy_sel_unused  = cfg_phy_sel_nxt | phy_spi_en | phy_spi_nxt;
    end
endgenerate

// RD_DIV: the 8080 read strobe's divider (0 = CLK_DIV); RAZ/WI without the 8080 PHY
generate
    if (P8080_EN) begin : g_rd_div
        arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_cfg_rd_div (
            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(cfg_wr), .d_i(reg_wdata_i[7:4]), .q_o(cfg_rd_div));
    end else begin : g_no_rd_div
        assign cfg_rd_div = 4'h0;
    end
endgenerate

assign rd_div_eff    = (cfg_rd_div != 4'h0) ? cfg_rd_div : cfg_clk_div;

// Operation settings: CLK_DIV, the read divider and HW_WINDOW_EN follow DIF_CFG
// while the engine is idle and hold from the edge that starts an operation
// (refresh, fill or command) to its end, as the PHY in use does. The start
// decision, taken in the idle cycle, reads DIF_CFG's HW_WINDOW_EN directly.
arv_ipdff #(.WIDTH(9), .ARST_EN(ARST_EN)) u_op_cfg (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~eng_busy),
    .d_i({cfg_clk_div, rd_div_eff, cfg_hw_win}), .q_o({op_clk_div, op_rd_div, op_hw_win}));

assign op_hw_win_eff = eng_busy ? op_hw_win : cfg_hw_win;

assign lcd_on_o      = cfg_lcd_on;
assign lcd_reset_n_o = ~cfg_lcd_reset;

//-----------------------------------------------------------------------------
// DIF_SYNC: [9:0] SCANLINE, [15] SCAN_SYNC_EN, [16] TE_SYNC_EN
//-----------------------------------------------------------------------------
arv_ipdff #(.WIDTH(10), .ARST_EN(ARST_EN)) u_sync_scanline (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sync_wr), .d_i(reg_wdata_i[9:0]), .q_o(sync_scanline));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sync_scan_en (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sync_wr), .d_i(reg_wdata_i[15]),  .q_o(sync_scan_en));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sync_te_en (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sync_wr), .d_i(reg_wdata_i[16]),  .q_o(sync_te_en));

// Scanline polling only on the 8080 PHY
// The start decision is taken in the idle cycle: use the PHY being latched.
assign phy_spi_eff  = phy_spi_en ? phy_spi_nxt : phy_spi;
assign scan_sync_en = sync_scan_en & ~phy_spi_eff;

//-----------------------------------------------------------------------------
// DIF_STATUS [7] PARAM_OVFL: a parameter write to a full FIFO was dropped
// (sticky, W1C, set wins)
//-----------------------------------------------------------------------------
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_param_ovfl (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(param_ovfl_set | param_ovfl_clr), .d_i(param_ovfl_set), .q_o(param_ovfl));

//-----------------------------------------------------------------------------
// DIF_IRQ_EN / DIF_IRQ_FLAG: [0] CMD_DONE, [1] TE, [2] CMD_OVFL (any dropped
// command, fill or parameter write; W1C, set wins)
//-----------------------------------------------------------------------------
arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_irq_en (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(irq_en_wr), .d_i(reg_wdata_i[2:0]), .q_o(irq_en));

assign irq_flag_set = {ovfl_set | param_ovfl_set, te_rise, eng_done};
assign irq_flag_en  = irq_flag_wr | (|irq_flag_set);
assign irq_flag_nxt = irq_flag_set | (irq_flag & ~({3{irq_flag_wr}} & reg_wdata_i[2:0]));

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_irq_flag (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(irq_flag_en), .d_i(irq_flag_nxt), .q_o(irq_flag));

assign irq_o = |(irq_flag & irq_en);

//-----------------------------------------------------------------------------
// Read data
//-----------------------------------------------------------------------------
assign status_busy = eng_busy | cmd_pend | dfill_pend;

assign cfg_rd    = {19'd0, cfg_hw_win, cfg_clk_div, cfg_rd_div, 1'b0, cfg_phy_sel, cfg_lcd_reset, cfg_lcd_on};
assign sync_rd   = {15'd0, sync_te_en, sync_scan_en, 5'd0, sync_scanline};
assign status_rd = {19'd0, param_level, param_ovfl, dfill_pend, dfill_busy, wait_sync, refr_busy, param_full, cmd_pend, status_busy};

assign reg_rdata_o = ({32{sel_cfg}}      & cfg_rd)                |
                     ({32{sel_sync}}     & sync_rd)               |
                     ({32{sel_status}}   & status_rd)             |
                     ({32{sel_irq_en}}   & {29'd0, irq_en})       |
                     ({32{sel_irq_flag}} & {29'd0, irq_flag})     ;

// TE enabled as an interrupt keeps the clock running so its edges are seen
assign busy_o = status_busy | refr_pend | irq_en[1];

//=============================================================================
// 4)  TEARING-EFFECT INPUT
//=============================================================================

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_te_sync (
    .clk_i   ( hclk_i    ),
    .rst_n_i ( hresetn_i ),
    .async_i ( lcd_te_i  ),
    .sync_o  ( te_sync   )
);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_te_q (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(te_sync), .q_o(te_q));

assign te_rise = te_sync & ~te_q;

//=============================================================================
// 5)  COMMAND ENGINE
//=============================================================================

blns_dbi_engine #(
    .SCAN_EN          ( P8080_EN         ),
    .PAR16_EN         ( P8080_EN         ),
    .DIM_W            ( DIM_W            ),
    .ASYNC_RST_EN     ( ARST_EN          )
) blns_dbi_engine_inst (
// CLOCK & RESET
    .hclk_i           ( hclk_i           ),
    .hresetn_i        ( hresetn_i        ),
// REGISTER WRITES
    .cmd_wr_i         ( cmd_wr           ),
    .cmd_wdata_i      ( reg_wdata_i[15:0]),
    .param_wr_i       ( param_wr         ),
    .param_wdata_i    ( reg_wdata_i[15:0]),
    .dfill_wr_i       ( dfill_wr         ),
    .dfill_wdata_i    ( reg_wdata_i[23:0]),
// CONFIGURATION
    .hw_window_en_i   ( op_hw_win_eff    ),
    .scan_sync_en_i   ( scan_sync_en     ),
    .te_sync_en_i     ( sync_te_en       ),
    .scanline_i       ( sync_scanline    ),
    .te_rise_i        ( te_rise          ),
// STATUS
    .busy_o           ( eng_busy         ),
    .cmd_pend_o       ( cmd_pend         ),
    .dfill_pend_o     ( dfill_pend       ),
    .cmd_free_o       ( cmd_free         ),
    .dfill_free_o     ( dfill_free       ),
    .refr_pend_o      ( refr_pend        ),
    .param_full_o     ( param_full       ),
    .param_level_o    ( param_level      ),
    .refr_busy_o      ( refr_busy        ),
    .wait_sync_o      ( wait_sync        ),
    .dfill_busy_o     ( dfill_busy       ),
    .done_o           ( eng_done         ),
// BDI PIXEL STREAM AND FRAME CONTROL
    .px_valid_i       ( px_valid_i       ),
    .px_data_i        ( px_data_i        ),
    .px_last_i        ( px_last_i        ),
    .px_ready_o       ( px_ready_o       ),
    .refresh_trig_i   ( refresh_trig_i   ),
    .refresh_active_o ( refresh_active_o ),
    .size_hold_o      ( size_hold_o      ),
    .width_i          ( width_i          ),
    .height_i         ( height_i         ),
    .win_w_o          ( win_width_o      ),
    .win_h_o          ( win_height_o     ),
// PHY ITEM INTERFACE
    .txn_o            ( txn              ),
    .xfer_valid_o     ( xfer_valid       ),
    .xfer_rd_o        ( xfer_rd          ),
    .xfer_dc_o        ( xfer_dc          ),
    .xfer_px_o        ( xfer_px          ),
    .xfer_data_o      ( xfer_data        ),
    .xfer_ready_i     ( xfer_ready       ),
    .phy_idle_i       ( phy_idle         ),
    .rd_valid_i       ( rd_valid         ),
    .rd_data_i        ( rd_data          )
);

//=============================================================================
// 6)  PHYSICAL LAYERS
//=============================================================================

assign p80_sel    = P8080_EN & ~phy_spi;
assign spi_sel    = SPI_EN   &  phy_spi;

assign xfer_ready = (p80_sel & p80_ready) | (spi_sel & spi_ready);
assign phy_idle   = (~p80_sel | p80_idle) & (~spi_sel | spi_idle);
assign rd_valid   = p80_sel & p80_rd_valid;
assign rd_data    = {8{p80_sel}} & p80_rd_data;

generate
    if (P8080_EN) begin : g_8080
        blns_dbi_8080 #(
            .ASYNC_RST_EN ( ARST_EN             )
        ) blns_dbi_8080_inst (
        // CLOCK & RESET
            .hclk_i       ( hclk_i              ),
            .hresetn_i    ( hresetn_i           ),
        // CONTROL
            .en_i         ( p80_sel             ),
            .clk_div_i    ( op_clk_div          ),
            .rd_div_i     ( op_rd_div           ),
        // ITEM INTERFACE
            .txn_i        ( txn & p80_sel       ),
            .xfer_valid_i ( xfer_valid & p80_sel),
            .xfer_rd_i    ( xfer_rd             ),
            .xfer_dc_i    ( xfer_dc             ),
            .xfer_data_i  ( xfer_data           ),
            .xfer_ready_o ( p80_ready           ),
            .idle_o       ( p80_idle            ),
            .rd_valid_o   ( p80_rd_valid        ),
            .rd_data_o    ( p80_rd_data         ),
        // 8080 PANEL
            .lcd_d_i      ( lcd_d_i             ),
            .lcd_d_o      ( lcd_d_o             ),
            .lcd_d_oe_o   ( lcd_d_oe_o          ),
            .lcd_cs_n_o   ( lcd_cs_n_o          ),
            .lcd_rd_n_o   ( lcd_rd_n_o          ),
            .lcd_wr_n_o   ( lcd_wr_n_o          ),
            .lcd_dc_o     ( lcd_dc_o            )
        );
    end else begin : g_no_8080
        assign p80_ready    = 1'b0;
        assign p80_idle     = 1'b1;
        assign p80_rd_valid = 1'b0;
        assign p80_rd_data  = 8'h00;
        assign lcd_d_o      = 16'h0000;
        assign lcd_d_oe_o   = 1'b0;
        assign lcd_cs_n_o   = 1'b1;
        assign lcd_rd_n_o   = 1'b1;
        assign lcd_wr_n_o   = 1'b1;
        assign lcd_dc_o     = 1'b0;
        wire   [15:0] lcd_d_unused   = lcd_d_i;
        wire          xfer_rd_unused = xfer_rd;
        wire    [3:0] rd_div_unused  = op_rd_div;
    end
endgenerate

generate
    if (SPI_EN) begin : g_spi
        blns_dbi_spi #(
            .ASYNC_RST_EN ( ARST_EN             )
        ) blns_dbi_spi_inst (
        // CLOCK & RESET
            .hclk_i       ( hclk_i              ),
            .hresetn_i    ( hresetn_i           ),
        // CONTROL
            .en_i         ( spi_sel             ),
            .clk_div_i    ( op_clk_div          ),
        // ITEM INTERFACE
            .txn_i        ( txn & spi_sel       ),
            .xfer_valid_i ( xfer_valid & spi_sel),
            .xfer_dc_i    ( xfer_dc             ),
            .xfer_px_i    ( xfer_px             ),
            .xfer_data_i  ( xfer_data           ),
            .xfer_ready_o ( spi_ready           ),
            .idle_o       ( spi_idle            ),
        // SPI PANEL
            .spi_sck_o    ( spi_sck_o           ),
            .spi_mosi_o   ( spi_mosi_o          ),
            .spi_miso_i   ( spi_miso_i          ),
            .spi_cs_n_o   ( spi_cs_n_o          ),
            .spi_dc_o     ( spi_dc_o            )
        );
    end else begin : g_no_spi
        assign spi_ready  = 1'b0;
        assign spi_idle   = 1'b1;
        assign spi_sck_o  = 1'b0;
        assign spi_mosi_o = 1'b0;
        assign spi_cs_n_o = 1'b1;
        assign spi_dc_o   = 1'b0;
        wire   spi_miso_unused = spi_miso_i;
        wire   xfer_px_unused  = xfer_px;
    end
endgenerate

// [31:24] unused ([16] is TE_SYNC_EN, [23:16] the fill colour's red)
wire   [7:0] reg_wdata_unused = reg_wdata_i[31:24];

endmodule // blns_dbi

`default_nettype wire
