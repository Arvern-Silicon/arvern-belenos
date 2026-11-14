//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_regs
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_regs.v
// Module Description : Global registers (0x000-0x06C): identification, control,
//                      status, interrupts, display geometry, frame pointers,
//                      LUT configuration, debug freeze and refresh pacing,
//                      FRAME_NUM (frames sent), the frame index latched for
//                      the frame in progress (FRAME_SEL [5:4]) and the
//                      hardware cursor (CURSOR_EN).
//----------------------------------------------------------------------------
`default_nettype none

module  blns_regs #(
    parameter                   VRAM_AW         = 16,     // VRAM word-address width
    parameter                   VRAM_WORDS      = 38400,  // VRAM depth in 32-bit words (read back at 0x00C)
    parameter                   DIM_W           = 10,     // width/height field width
    parameter                   FRAME_NR        = 2,      // frame pointers (1, 2 or 4)
    parameter                   LUT_EN          = 1,      // programmable LUT present
    parameter                   LUT_BANKS       = 2,      // LUT banks (1/2)
    parameter                   GPU_EN          = 1,      // GPU present
    parameter                   GPU_XY_EN       = 1,      // GPU x/y destinations and clip, affine blits
    parameter                   GPU_GRAD_EN     = 1,      // GPU gradient fill
    parameter                   GPU_BLEND_EN    = 0,      // GPU alpha blending
    parameter                   GPU_TRI_EN      = 0,      // GPU triangle fill
    parameter                   GPU_REMAP_EN    = 1,      // GPU palette remap
    parameter                   GPU_MPLANE_EN   = 1,      // GPU mask plane
    parameter                   GPU_IMM_EN      = 1,      // GPU immediate source
    parameter                   GPU_LINE_EN     = 1,      // GPU lines (with XY)
    parameter                   GPU_BILINEAR_EN = 0,      // GPU bilinear sampling (with XY)
    parameter                   GPU_FIFO_AW     = 3,      // GPU command FIFO address width
    parameter                   DIF_TYPE        = 2,      // built-in display driver
    parameter                   CURSOR_EN       = 1,      // hardware cursor present
    parameter                   PRIV_CHECK_EN   = 0,      // U-mode accesses denied
    parameter                   ASYNC_RST_EN    = 1'b1    // 1=async active-low reset, 0=synchronous reset
) (
    input  wire                 hclk_i,                // clock
    input  wire                 hresetn_i,             // active-low reset

// Register bus
    input  wire                 rb_valid_i,            // transfer pending
    input  wire                 rb_sel_i,              // this slave is selected
    input  wire                 rb_wr_i,               // 1 = write
    input  wire           [6:2] rb_addr_i,             // word offset
    input  wire          [31:0] rb_wdata_i,            // write data
    output wire          [31:0] rb_rdata_o,            // read data
    output wire                 rb_ready_o,            // transfer completes

// Configuration outputs
    output wire           [2:0] gfx_mode_o,            // CTRL.GFX_MODE
    output wire                 gpu_en_o,              // CTRL.GPU_EN
    output wire     [DIM_W-1:0] disp_width_o,          // DISP_SIZE width
    output wire     [DIM_W-1:0] disp_height_o,         // DISP_SIZE height
    output wire           [2:0] disp_cfg_o,            // DISP_CFG {X,Y,CL}
    output wire                 pix_double_o,          // DISP_CFG.PIX_DOUBLE
    output wire     [DIM_W-1:0] frame_width_o,         // frame width: default GPU pitch
    output wire   [VRAM_AW+4:0] refr_frame_base_o,     // refresh frame pointer
    output wire          [15:0] refr_pitch_o,          // REFR_PITCH: refresh line pitch in pixels (0 = frame width)
    output wire                 sw_lut_en_o,           // LUT_CFG.SW_LUT_EN
    output wire                 refr_bank_o,           // LUT_CFG.REFR_BANK
    output wire           [2:0] hw_palette_o,          // LUT_CFG.HW_PALETTE
    output wire           [3:0] hw_bg_o,               // LUT_CFG.HW_BG
    output wire           [3:0] hw_fg_o,               // LUT_CFG.HW_FG
    output wire          [23:0] lut_rot_o,             // LUT_ROT {OFFSET, LAST, FIRST}
    output wire                 freeze_gpu_o,          // DBG_CTRL[1] & stoptime, registered
    output wire                 cur_en_o,              // CURSOR_CTRL.EN
    output wire           [9:0] cur_hot_o,             // CURSOR_CTRL {HOT_Y, HOT_X}
    output wire          [31:0] cur_pos_o,             // CURSOR_POS {Y, X}
    output wire   [VRAM_AW-1:0] cur_addr_o,            // CURSOR_ADDR (word address, [6:0] = 0)
    output wire          [23:0] cur_col1_o,            // CURSOR_COL1 (RGB888)
    output wire          [23:0] cur_col2_o,            // CURSOR_COL2
    output wire          [23:0] cur_col3_o,            // CURSOR_COL3

// Refresh pacing
    input  wire                 dbg_stoptime_i,        // core dcsr.stoptime & Debug Mode
    input  wire                 refresh_active_i,      // display driver is sending a frame
    input  wire                 refresh_active_q_i,    // refresh_active_i one cycle late (a flop: blns_backend)
    input  wire                 px_last_i,             // the frame's last pixel was taken (1 cycle)
    output wire                 refresh_trig_o,        // frame request (1 cycle)
    output wire                 refresh_running_o,     // REFRESH.START
    output wire                 refr_done_evt_o,       // a frame sent to the panel ended (1 cycle)

// Status and events
    input  wire                 gpu_busy_i,            // GPU busy
    input  wire                 gpu_err_i,             // GPU in error
    input  wire                 dif_busy_i,            // display driver busy
    input  wire                 gpu_done_evt_i,        // EXEC completed
    input  wire                 gpu_fence_evt_i,       // FENCE with IRQ reached
    input  wire                 gpu_idle_evt_i,        // GPU became idle
    input  wire                 gpu_ovfl_evt_i,        // GPU command dropped
    input  wire                 gpu_err_evt_i,         // GPU entered error
    input  wire                 gpu_fifo_low_evt_i,    // GPU FIFO FREE rose above half its depth (GPU_EN)
    input  wire                 dif_irq_i,             // display driver interrupt (level)
    output wire                 irq_o                  // interrupt (level)
);


//=============================================================================
// 1)  PARAMETERS
//=============================================================================

localparam             PA_W         = VRAM_AW + 5;
// BLNS_ID: [31:24] major, [23:16] minor, [15:8] patch. The register map, the
// command encoding, the parameters and the ports are frozen per major version:
// an incompatible change is a new major, an addition a new minor, a
// correction a new patch
localparam      [31:0] BLNS_VERSION = 32'h0001_0000;


// Identification: only what varies between builds and software can act on;
// fields packed from bit 0, the rest reads 0.
// BLNS_CFG: [4:0] VRAM_AW, [5] LUT, [6] LUT2, [8:7] FRAME_NR - 1, [12:9]
// DIM_W - 1, [15:13] DIF_TYPE, [16] PRIV_CHECK, [17] GPU, [18] CURSOR
localparam      [31:0] CFG_VRAM_AW  = VRAM_AW;
localparam      [31:0] CFG_FRAME_M1 = FRAME_NR - 1;
localparam      [31:0] CFG_FIFO_AW  = GPU_FIFO_AW;
localparam      [31:0] CFG_DIF_TYPE = DIF_TYPE;
localparam      [31:0] CFG_DIM_M1   = DIM_W - 1;

localparam      [31:0] BLNS_CFG     = ( CFG_VRAM_AW  & 32'h1F)                  |
                                      ((LUT_EN    != 0)   ? 32'h20 : 32'h0)     |
                                      ((LUT_EN != 0) && (LUT_BANKS == 2) ? 32'h40 : 32'h0) |
                                      ((CFG_FRAME_M1 & 32'h3)  <<  7)           |
                                      ((CFG_DIM_M1   & 32'hF)  <<  9)           |
                                      ((CFG_DIF_TYPE & 32'h7)  << 13)           |
                                      ((PRIV_CHECK_EN != 0) ? 32'h10000 : 32'h0) |
                                      ((GPU_EN    != 0)   ? 32'h20000 : 32'h0) |
                                      ((CURSOR_EN != 0)   ? 32'h40000 : 32'h0);
localparam      [31:0] CFG_VRAM_WORDS = VRAM_WORDS & 32'h01FF_FFFF;

// BLNS_CFG2 (GPU, 0 without one): [3:0] FIFO_AW, [4] XY, [5] GRAD, [6] BLEND,
// [7] TRI (with XY), [8] REMAP, [9] MPLANE, [10] IMM, [11] LINE (with XY),
// [12] BILINEAR (with XY)
localparam      [31:0] BLNS_CFG2    = (GPU_EN == 0) ? 32'h0000_0000 :
                                      (( CFG_FIFO_AW & 32'hF)                       |
                                       ((GPU_XY_EN     != 0) ? 32'h010 : 32'h0)     |
                                       ((GPU_GRAD_EN   != 0) ? 32'h020 : 32'h0)     |
                                       ((GPU_BLEND_EN  != 0) ? 32'h040 : 32'h0)     |
                                       ((GPU_TRI_EN != 0) && (GPU_XY_EN != 0) ? 32'h080 : 32'h0) |
                                       ((GPU_REMAP_EN  != 0) ? 32'h100 : 32'h0)     |
                                       ((GPU_MPLANE_EN != 0) ? 32'h200 : 32'h0)     |
                                       ((GPU_IMM_EN    != 0) ? 32'h400 : 32'h0)     |
                                       ((GPU_LINE_EN != 0) && (GPU_XY_EN != 0) ? 32'h800 : 32'h0) |
                                       ((GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0) ? 32'h1000 : 32'h0));

// Frame-select mask: as many index bits as frame pointers need.
localparam       [1:0] FSEL_MASK    = (FRAME_NR > 2) ? 2'b11 : (FRAME_NR == 2) ? 2'b01 : 2'b00;

// Word offsets
localparam       [4:0] A_ID         = 5'd0,
                       A_CFG        = 5'd1,
                       A_CFG2       = 5'd2,
                       A_VRAM_WORDS = 5'd3,
                       A_CTRL       = 5'd4,
                       A_STATUS     = 5'd5,
                       A_IRQ_EN     = 5'd6,
                       A_IRQ_FLAG   = 5'd7,
                       A_DISP_SIZE  = 5'd8,
                       A_DISP_CFG   = 5'd9,
                       A_FRAME_CNT  = 5'd10,
                       A_REFRESH    = 5'd11,
                       A_FRAME_SEL  = 5'd12,
                       A_DBG_CTRL   = 5'd13,
                       A_FRAME_NUM  = 5'd14,
                       A_REFR_PITCH = 5'd15,
                       A_FPTR0      = 5'd16,
                       A_FPTR1      = 5'd17,
                       A_FPTR2      = 5'd18,
                       A_FPTR3      = 5'd19,
                       A_LUT_CFG    = 5'd20,
                       A_LUT_ROT    = 5'd21,
                       A_CUR_CTRL   = 5'd22,
                       A_CUR_POS    = 5'd23,
                       A_CUR_ADDR   = 5'd24,
                       A_CUR_COL1   = 5'd25,
                       A_CUR_COL2   = 5'd26,
                       A_CUR_COL3   = 5'd27;


//=============================================================================
// 2)  ACCESS DECODE
//=============================================================================

wire                    xfer      =  rb_valid_i & rb_sel_i;
wire                    wr        =  xfer &  rb_wr_i;
wire              [4:0] adr       =  rb_addr_i;

assign                  rb_ready_o = xfer;

wire                    wr_ctrl      = wr & (adr == A_CTRL);
wire                    wr_irq_en    = wr & (adr == A_IRQ_EN);
wire                    wr_irq_flag  = wr & (adr == A_IRQ_FLAG);
wire                    wr_disp_size = wr & (adr == A_DISP_SIZE);
wire                    wr_disp_cfg  = wr & (adr == A_DISP_CFG);
wire                    wr_frame_cnt = wr & (adr == A_FRAME_CNT);
wire                    wr_refresh   = wr & (adr == A_REFRESH);
wire                    wr_frame_sel = wr & (adr == A_FRAME_SEL);
wire                    wr_dbg_ctrl  = wr & (adr == A_DBG_CTRL);
wire                    wr_refr_pitch = wr & (adr == A_REFR_PITCH);
wire                    wr_lut_cfg   = wr & (adr == A_LUT_CFG);
wire                    wr_lut_rot   = wr & (adr == A_LUT_ROT);
wire              [5:0] wr_cur       = {wr & (adr == A_CUR_COL3), wr & (adr == A_CUR_COL2),
                                        wr & (adr == A_CUR_COL1), wr & (adr == A_CUR_ADDR),
                                        wr & (adr == A_CUR_POS),  wr & (adr == A_CUR_CTRL)};
wire              [3:0] wr_fptr      = {wr & (adr == A_FPTR3), wr & (adr == A_FPTR2),
                                        wr & (adr == A_FPTR1), wr & (adr == A_FPTR0)};


//=============================================================================
// 3)  CONTROL AND CONFIGURATION REGISTERS
//=============================================================================

// CTRL: [2:0] GFX_MODE, [4] GPU_EN
wire              [3:0] ctrl;
wire              [3:0] ctrl_nxt  = {rb_wdata_i[4] & (GPU_EN != 0), rb_wdata_i[2:0]};
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_ctrl (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_ctrl), .d_i(ctrl_nxt), .q_o(ctrl));
assign                  gfx_mode_o = ctrl[2:0];
assign                  gpu_en_o   = ctrl[3];

// DISP_SIZE: width [DIM_W-1:0], height [16+DIM_W-1:16]; 0 is stored as 1
wire        [DIM_W-1:0] wsize     = rb_wdata_i[DIM_W-1:0];
wire        [DIM_W-1:0] hsize     = rb_wdata_i[16+DIM_W-1:16];
wire        [DIM_W-1:0] one       = {{(DIM_W-1){1'b0}}, 1'b1};
wire        [DIM_W-1:0] wsize_nxt = (wsize == {DIM_W{1'b0}}) ? one : wsize;
wire        [DIM_W-1:0] hsize_nxt = (hsize == {DIM_W{1'b0}}) ? one : hsize;
arv_ipdff #(.WIDTH(DIM_W), .RST_VAL({{(DIM_W-1){1'b0}}, 1'b1}), .ARST_EN(ASYNC_RST_EN)) u_disp_width (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_disp_size), .d_i(wsize_nxt), .q_o(disp_width_o));
arv_ipdff #(.WIDTH(DIM_W), .RST_VAL({{(DIM_W-1){1'b0}}, 1'b1}), .ARST_EN(ASYNC_RST_EN)) u_disp_height (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_disp_size), .d_i(hsize_nxt), .q_o(disp_height_o));

// DISP_CFG: [0] CL, [1] Y, [2] X, [4] PIX_DOUBLE
arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_disp_cfg (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_disp_cfg),
                           .d_i({rb_wdata_i[4], rb_wdata_i[2:0]}), .q_o({pix_double_o, disp_cfg_o}));

// Frame width: the source frame of a doubled picture is ceil(W/2) pixels wide
wire          [DIM_W:0] width_p1     = {1'b0, disp_width_o} + {{DIM_W{1'b0}}, 1'b1};
assign                  frame_width_o = pix_double_o ? width_p1[DIM_W:1] : disp_width_o;
wire                    width_p1_unused = width_p1[0];

// FRAME_SEL: [1:0] refresh (the index bits FRAME_NR needs), [5:4] LATCHED
wire              [1:0] frame_sel;
wire              [1:0] frame_sel_nxt = rb_wdata_i[1:0] & FSEL_MASK;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_frame_sel (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_frame_sel), .d_i(frame_sel_nxt), .q_o(frame_sel));

// FRAME_SEL [5:4] LATCHED: the index the refresh took for the frame in
// progress, or, between frames, the one the next frame takes. Loaded while
// REFRESH_ACTIVE = 0 and held during a frame: the timing of the backend's
// frame-pointer latch (blns_backend, section 1), so it names the pointer the
// refresh reads.
wire              [1:0] frame_sel_lat;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_frame_sel_lat (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(~refresh_active_i), .d_i(frame_sel), .q_o(frame_sel_lat));

// REFR_PITCH: [15:0] the refresh's line pitch in source pixels; 0 = the frame
// width (DISP_SIZE width, halved with PIX_DOUBLE). Latched at a frame start
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_refr_pitch (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_refr_pitch), .d_i(rb_wdata_i[15:0]), .q_o(refr_pitch_o));

// DBG_CTRL: [0] FREEZE_REFRESH, [1] FREEZE_GPU
wire              [1:0] dbg_ctrl;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_dbg_ctrl (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_dbg_ctrl), .d_i(rb_wdata_i[1:0]), .q_o(dbg_ctrl));

// The freeze is registered: dbg_stoptime_i comes from the core's debug
// logic, and the GPU's request logic would otherwise hang off it
wire                    freeze_refresh;
arv_ipdff #(.WIDTH(2), .ARST_EN(ASYNC_RST_EN)) u_freeze (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(dbg_ctrl & {2{dbg_stoptime_i}}), .q_o({freeze_gpu_o, freeze_refresh}));

// LUT_CFG: [0] SW_LUT_EN, [1] REFR_BANK, [6:4] HW_PALETTE, [11:8] HW_BG, [15:12] HW_FG
// (stored as {HW_FG, HW_BG, HW_PALETTE, REFR_BANK, SW_LUT_EN})
wire             [12:0] lut_cfg;
wire             [12:0] lut_cfg_nxt = {rb_wdata_i[15:8], rb_wdata_i[6:4],
                                       rb_wdata_i[1] & (LUT_EN != 0) & (LUT_BANKS == 2),
                                       rb_wdata_i[0] & (LUT_EN != 0)};
arv_ipdff #(.WIDTH(13), .RST_VAL(13'h1E00), .ARST_EN(ASYNC_RST_EN)) u_lut_cfg (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_lut_cfg), .d_i(lut_cfg_nxt), .q_o(lut_cfg));
assign                  sw_lut_en_o  = lut_cfg[0];
assign                  refr_bank_o  = lut_cfg[1];
assign                  hw_palette_o = lut_cfg[4:2];
assign                  hw_bg_o      = lut_cfg[8:5];
assign                  hw_fg_o      = lut_cfg[12:9];
wire             [31:0] lut_cfg_rd   = {16'h0000, lut_cfg[12:5], 1'b0, lut_cfg[4:2], 2'b00, lut_cfg[1:0]};

// LUT_ROT: [7:0] FIRST, [15:8] LAST, [23:16] OFFSET (read 0 without a LUT)
arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_lut_rot (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_lut_rot),
                           .d_i(rb_wdata_i[23:0] & {24{LUT_EN != 0}}), .q_o(lut_rot_o));


//=============================================================================
// 3b) HARDWARE CURSOR
//=============================================================================
// CURSOR_CTRL [0] EN, [12:8] HOT_X, [20:16] HOT_Y; CURSOR_POS {Y, X} (16 bits
// each, stored whole); CURSOR_ADDR [VRAM_AW-1:7] (a 128-word block);
// CURSOR_COL1-3 RGB888. The backend latches all but the colours at a frame
// start. Without CURSOR_EN they read 0 and ignore writes.
localparam              CA_W = (VRAM_AW > 7) ? (VRAM_AW - 7) : 1;    // CURSOR_ADDR field (1 bit at least)

wire             [31:0] cur_addr_rd;
wire             [31:0] cur_ctrl_rd;

generate
    if (CURSOR_EN != 0) begin : G_CURSOR
        wire     [10:0] cur_ctrl;          // {HOT_Y, HOT_X, EN}
        arv_ipdff #(.WIDTH(11), .ARST_EN(ASYNC_RST_EN)) u_cur_ctrl (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_cur[0]),
                           .d_i({rb_wdata_i[20:16], rb_wdata_i[12:8], rb_wdata_i[0]}), .q_o(cur_ctrl));
        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_cur_pos (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_cur[1]), .d_i(rb_wdata_i), .q_o(cur_pos_o));
        arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_cur_col1 (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_cur[3]), .d_i(rb_wdata_i[23:0]), .q_o(cur_col1_o));
        arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_cur_col2 (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_cur[4]), .d_i(rb_wdata_i[23:0]), .q_o(cur_col2_o));
        arv_ipdff #(.WIDTH(24), .ARST_EN(ASYNC_RST_EN)) u_cur_col3 (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_cur[5]), .d_i(rb_wdata_i[23:0]), .q_o(cur_col3_o));
        assign cur_en_o    = cur_ctrl[0];
        assign cur_hot_o   = cur_ctrl[10:1];
        assign cur_ctrl_rd = {11'h000, cur_ctrl[10:6], 3'b000, cur_ctrl[5:1], 7'b000_0000, cur_ctrl[0]};
        if (VRAM_AW > 7) begin : G_ADDR
            wire [CA_W-1:0] cur_addr;
            arv_ipdff #(.WIDTH(CA_W), .ARST_EN(ASYNC_RST_EN)) u_cur_addr (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_cur[2]), .d_i(rb_wdata_i[VRAM_AW-1:7]), .q_o(cur_addr));
            assign cur_addr_o  = {cur_addr, 7'b000_0000};
            assign cur_addr_rd = {{(32-VRAM_AW){1'b0}}, cur_addr, 7'b000_0000};
        end else begin : G_NO_ADDR
            // The whole VRAM is one block: the field is empty
            assign cur_addr_o  = {VRAM_AW{1'b0}};
            assign cur_addr_rd = 32'h0000_0000;
            wire   wr_cur_addr_unused = wr_cur[2];
        end
    end else begin : G_NO_CURSOR
        assign cur_en_o    = 1'b0;
        assign cur_hot_o   = 10'h000;
        assign cur_pos_o   = 32'h0000_0000;
        assign cur_addr_o  = {VRAM_AW{1'b0}};
        assign cur_col1_o  = 24'h00_0000;
        assign cur_col2_o  = 24'h00_0000;
        assign cur_col3_o  = 24'h00_0000;
        assign cur_ctrl_rd = 32'h0000_0000;
        assign cur_addr_rd = 32'h0000_0000;
        wire   [5:0] wr_cur_unused = wr_cur;
    end
endgenerate


//=============================================================================
// 4)  FRAME POINTERS
//=============================================================================

wire       [4*PA_W-1:0] fptr;

genvar n;
generate
    for (n = 0; n < 4; n = n + 1) begin : G_FPTR
        if (n < FRAME_NR) begin : G_ON
            arv_ipdff #(.WIDTH(PA_W), .ARST_EN(ASYNC_RST_EN)) u_fptr (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_fptr[n]), .d_i(rb_wdata_i[PA_W-1:0]),
                           .q_o(fptr[n*PA_W +: PA_W]));
        end else begin : G_OFF
            assign fptr[n*PA_W +: PA_W] = {PA_W{1'b0}};
            wire   wr_fptr_unused       = wr_fptr[n];
        end
    end
endgenerate

wire         [PA_W-1:0] fptr0 = fptr[0*PA_W +: PA_W];
wire         [PA_W-1:0] fptr1 = fptr[1*PA_W +: PA_W];
wire         [PA_W-1:0] fptr2 = fptr[2*PA_W +: PA_W];
wire         [PA_W-1:0] fptr3 = fptr[3*PA_W +: PA_W];

function [PA_W-1:0] fsel_mux;
    input       [1:0] sel;
    input  [PA_W-1:0] p0, p1, p2, p3;
    begin
        fsel_mux = ({PA_W{sel == 2'd0}} & p0) | ({PA_W{sel == 2'd1}} & p1) |
                   ({PA_W{sel == 2'd2}} & p2) | ({PA_W{sel == 2'd3}} & p3);
    end
endfunction

assign                  refr_frame_base_o  = fsel_mux(frame_sel[1:0], fptr0, fptr1, fptr2, fptr3);


//=============================================================================
// 5)  REFRESH PACING
//=============================================================================

wire             [31:0] refresh_rd;
wire             [15:0] frame_cnt;
wire                    refr_start_evt;
wire                    refr_done_evt;
wire                    frame_cnt_done_evt;
wire                    refr_abandoned;

blns_refresh #(.ASYNC_RST_EN(ASYNC_RST_EN)) u_refresh (
    .hclk_i               ( hclk_i             ),
    .hresetn_i            ( hresetn_i          ),
    .refresh_wr_i         ( wr_refresh         ),
    .frame_cnt_wr_i       ( wr_frame_cnt       ),
    .wdata_i              ( rb_wdata_i         ),
    .refresh_o            ( refresh_rd         ),
    .frame_cnt_o          ( frame_cnt          ),
    .freeze_i             ( freeze_refresh     ),
    .refresh_active_i     ( refresh_active_i   ),
    .refresh_active_q_i   ( refresh_active_q_i ),
    .px_last_i            ( px_last_i          ),
    .refresh_trig_o       ( refresh_trig_o     ),
    .running_o            ( refresh_running_o  ),
    .refr_start_evt_o     ( refr_start_evt     ),
    .refr_done_evt_o      ( refr_done_evt      ),
    .frame_cnt_done_evt_o ( frame_cnt_done_evt ),
    .abandoned_o          ( refr_abandoned     )
);


// FRAME_NUM: frames sent, +1 at every REFR_DONE event (also under the debug
// freeze, as the flag), wrapping at 16 bits; read only
wire             [15:0] frame_num;
wire             [15:0] frame_num_nxt = frame_num + 16'd1;
arv_ipdff #(.WIDTH(16), .ARST_EN(ASYNC_RST_EN)) u_frame_num (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(refr_done_evt), .d_i(frame_num_nxt), .q_o(frame_num));


//=============================================================================
// 6)  INTERRUPTS
//=============================================================================

// IRQ_FLAG: [0] REFR_DONE, [1] REFR_START, [2] FRAME_CNT_DONE, [4] GPU_DONE,
// [5] GPU_IDLE, [6] GPU_OVFL, [7] GPU_ERR, [9] GPU_FENCE, [10] GPU_FIFO_LOW
// (W1C, set wins; the GPU bits 0 without a GPU); [8] DIF (level).
// The W1C flags are stored without the reserved bit 3 and the DIF level:
// irq_flag = {GPU_FENCE, GPU_ERR, GPU_OVFL, GPU_IDLE, GPU_DONE, FRAME_CNT_DONE,
// REFR_START, REFR_DONE}.
wire              [7:0] irq_set   = {gpu_fence_evt_i, gpu_err_evt_i, gpu_ovfl_evt_i, gpu_idle_evt_i,
                                     gpu_done_evt_i, frame_cnt_done_evt, refr_start_evt, refr_done_evt};
assign                  refr_done_evt_o = refr_done_evt;
wire              [7:0] irq_flag;
wire              [7:0] irq_clr   = {rb_wdata_i[9], rb_wdata_i[7:4], rb_wdata_i[2:0]} & {8{wr_irq_flag}};
wire              [7:0] irq_flag_nxt = (irq_flag & ~irq_clr) | irq_set;
arv_ipdff #(.WIDTH(8), .ARST_EN(ASYNC_RST_EN)) u_irq_flag (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(irq_flag_nxt), .q_o(irq_flag));

// GPU_FIFO_LOW: a flag of its own (0 without a GPU, as the other GPU flags)
wire                    flow_flag;
wire                    flow_nxt  = (flow_flag & ~(wr_irq_flag & rb_wdata_i[10])) | gpu_fifo_low_evt_i;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_flow_flag (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(flow_nxt), .q_o(flow_flag));

// IRQ_EN: one enable per IRQ_FLAG bit (bit 3 reserved: no flop, reads 0)
wire              [9:0] irq_en_q;
wire              [9:0] irq_en_nxt = {rb_wdata_i[10:4], rb_wdata_i[2:0]};
arv_ipdff #(.WIDTH(10), .ARST_EN(ASYNC_RST_EN)) u_irq_en (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(wr_irq_en), .d_i(irq_en_nxt), .q_o(irq_en_q));
wire             [10:0] irq_en      = {irq_en_q[9:3], 1'b0, irq_en_q[2:0]};

wire             [10:0] irq_flag_rd = {flow_flag, irq_flag[7], dif_irq_i, irq_flag[6:3], 1'b0, irq_flag[2:0]};
assign                  irq_o       = |(irq_flag_rd & irq_en);


//=============================================================================
// 7)  READ BACK
//=============================================================================

wire             [31:0] status_rd   = {27'h0, refr_abandoned, dif_busy_i, gpu_err_i, gpu_busy_i, refresh_active_i};
wire             [31:0] size_rd     = {{(16-DIM_W){1'b0}}, disp_height_o, {(16-DIM_W){1'b0}}, disp_width_o};
wire             [31:0] fsel_rd     = {26'h0, frame_sel_lat, 2'b00, frame_sel};

function [31:0] pa_rd;
    input [PA_W-1:0] pa;
    begin
        pa_rd = {{(32-PA_W){1'b0}}, pa};
    end
endfunction

assign rb_rdata_o = ({32{adr == A_ID       }} & BLNS_VERSION                       ) |
                    ({32{adr == A_CFG      }} & BLNS_CFG                           ) |
                    ({32{adr == A_CFG2     }} & BLNS_CFG2                          ) |
                    ({32{adr == A_VRAM_WORDS}} & CFG_VRAM_WORDS                    ) |
                    ({32{adr == A_CTRL     }} & {27'h0, ctrl[3], 1'b0, ctrl[2:0]}  ) |
                    ({32{adr == A_STATUS   }} & status_rd                          ) |
                    ({32{adr == A_IRQ_EN   }} & {21'h0, irq_en}                    ) |
                    ({32{adr == A_IRQ_FLAG }} & {21'h0, irq_flag_rd}               ) |
                    ({32{adr == A_DISP_SIZE}} & size_rd                            ) |
                    ({32{adr == A_DISP_CFG }} & {27'h0, pix_double_o, 1'b0, disp_cfg_o}) |
                    ({32{adr == A_FRAME_CNT}} & {16'h0, frame_cnt}                 ) |
                    ({32{adr == A_REFRESH  }} & refresh_rd                         ) |
                    ({32{adr == A_FRAME_SEL}} & fsel_rd                            ) |
                    ({32{adr == A_DBG_CTRL }} & {30'h0, dbg_ctrl}                  ) |
                    ({32{adr == A_FRAME_NUM}} & {16'h0000, frame_num}              ) |
                    ({32{adr == A_REFR_PITCH}} & {16'h0000, refr_pitch_o}          ) |
                    ({32{adr == A_FPTR0    }} & pa_rd(fptr0)                       ) |
                    ({32{adr == A_FPTR1    }} & pa_rd(fptr1)                       ) |
                    ({32{adr == A_FPTR2    }} & pa_rd(fptr2)                       ) |
                    ({32{adr == A_FPTR3    }} & pa_rd(fptr3)                       ) |
                    ({32{adr == A_LUT_CFG  }} & lut_cfg_rd                         ) |
                    ({32{adr == A_LUT_ROT  }} & {8'h00, lut_rot_o}                 ) |
                    ({32{adr == A_CUR_CTRL }} & cur_ctrl_rd                        ) |
                    ({32{adr == A_CUR_POS  }} & cur_pos_o                          ) |
                    ({32{adr == A_CUR_ADDR }} & cur_addr_rd                        ) |
                    ({32{adr == A_CUR_COL1 }} & {8'h00, cur_col1_o}                ) |
                    ({32{adr == A_CUR_COL2 }} & {8'h00, cur_col2_o}                ) |
                    ({32{adr == A_CUR_COL3 }} & {8'h00, cur_col3_o}                );

endmodule // blns_regs

`default_nettype wire
