//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    belenos_core
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : belenos_core.v
// Module Description : Belenos graphic controller core: register and VRAM
//                      ports, GPU, display backend, arbiters. The
//                      display driver attaches through the BDI signals.
//----------------------------------------------------------------------------
`default_nettype none

module  belenos_core #(
    parameter                   VRAM_WORDS       = 38400,   // VRAM depth in 32-bit words
    parameter                   VRAM_AW          = 16,      // VRAM word-address width (2^(VRAM_AW-1) < VRAM_WORDS <= 2^VRAM_AW)
    parameter                   VRAM_RD_LAT      = 1,       // VRAM macro read latency in cycles (1-3)
    parameter                   VRAM_RD_REG_EN   = 0,       // VRAM read data registered (one more read cycle)
    parameter                   DIM_W            = 10,      // width/height field width
    parameter                   FRAME_NR         = 2,       // frame pointers (1, 2 or 4)
    parameter                   LUT_EN           = 1,       // programmable LUT present
    parameter                   LUT_BANKS        = 2,       // LUT banks (1/2)
    parameter                   GPU_EN           = 1,       // GPU present
    parameter                   GPU_XY_EN        = 1,       // GPU x/y destinations and clip, affine blits
    parameter                   GPU_GRAD_EN      = 1,       // GPU gradient fill
    parameter                   GPU_BLEND_EN     = 0,       // GPU alpha blending (16 bpp)
    parameter                   GPU_TRI_EN       = 0,       // GPU triangle fill
    parameter                   GPU_RUNAHEAD_EN  = 0,       // GPU set-up of the next primitive while one draws
    parameter                   GPU_REMAP_EN     = 1,       // GPU palette remap
    parameter                   GPU_MPLANE_EN    = 1,       // GPU mask plane on copies
    parameter                   GPU_IMM_EN       = 1,       // GPU immediate source (SET_SRC IMM)
    parameter                   GPU_LINE_EN      = 1,       // GPU lines (needs GPU_XY_EN)
    parameter                   GPU_BILINEAR_EN  = 0,       // GPU bilinear texture sampling (needs GPU_XY_EN)
    parameter                   GPU_FIFO_AW      = 3,       // GPU command FIFO: 2^GPU_FIFO_AW words
    parameter                   DIF_TYPE         = 2,       // built-in display driver (reported in BLNS_CFG)
    parameter                   CURSOR_EN        = 1,       // hardware cursor
    parameter                   PRIV_CHECK_EN    = 0,       // deny U-mode accesses
    parameter                   ASYNC_RST_EN     = 1'b1     // 1=async active-low reset, 0=synchronous reset
) (
    input  wire                 hclk_i,                     // clock
    input  wire                 hresetn_i,                  // active-low reset
    output wire                 hclk_en_o,                  // clock-gate enable

// Register port (AHB-Lite subordinate)
    input  wire                 r_hsel_i,
    input  wire          [11:0] r_haddr_i,
    input  wire           [1:0] r_htrans_i,
    input  wire                 r_hwrite_i,
    input  wire           [2:0] r_hsize_i,
    input  wire           [3:0] r_hprot_i,
    input  wire                 r_hsmode_i,
    input  wire                 r_hready_i,
    input  wire          [31:0] r_hwdata_i,
    output wire          [31:0] r_hrdata_o,
    output wire                 r_hreadyout_o,
    output wire                 r_hresp_o,

// VRAM-window port (AHB-Lite subordinate)
    input  wire                 v_hsel_i,
    input  wire   [VRAM_AW+1:0] v_haddr_i,
    input  wire           [1:0] v_htrans_i,
    input  wire                 v_hwrite_i,
    input  wire           [2:0] v_hsize_i,
    input  wire           [3:0] v_hprot_i,
    input  wire                 v_hsmode_i,
    input  wire                 v_hready_i,
    input  wire          [31:0] v_hwdata_i,
    output wire          [31:0] v_hrdata_o,
    output wire                 v_hreadyout_o,
    output wire                 v_hresp_o,

// VRAM macro
    output wire                 vram_cen_o,
    output wire           [3:0] vram_wen_o,
    output wire   [VRAM_AW-1:0] vram_addr_o,
    output wire          [31:0] vram_din_o,
    input  wire          [31:0] vram_dout_i,

// LUT macro
    output wire                 lut_cen_o,
    output wire                 lut_wen_o,
    output wire           [8:0] lut_addr_o,
    output wire          [23:0] lut_din_o,
    input  wire          [23:0] lut_dout_i,

// Debug / interrupt
    input  wire                 dbg_stoptime_i,
    output wire                 irq_o,

// Belenos Display Interface (BDI)
    output wire                 bdi_px_valid_o,
    output wire          [23:0] bdi_px_data_o,
    output wire                 bdi_px_last_o,
    input  wire                 bdi_px_ready_i,
    output wire                 bdi_refresh_trig_o,
    input  wire                 bdi_refresh_active_i,
    input  wire                 dbi_size_hold_i,     // built-in driver: refresh started, before its frame
    input  wire     [DIM_W-1:0] dbi_win_width_i,     // built-in DBI driver: the size taken at the refresh start
    input  wire     [DIM_W-1:0] dbi_win_height_i,    //   (held while dbi_size_hold_i is set)
    output wire     [DIM_W-1:0] bdi_width_o,
    output wire     [DIM_W-1:0] bdi_height_o,
    output wire                 dpi_cl_swap_o,       // built-in DPI driver: DISP_CFG.CL_SWAP
    output wire     [DIM_W-1:0] dpi_line_len_m1_o,   // built-in DPI driver: the frame's line length - 1
                                                     //   (the backend's, latched while bdi_refresh_active_i = 0)
    output wire                 bdi_reg_sel_o,
    output wire           [5:0] bdi_reg_addr_o,
    output wire                 bdi_reg_wr_o,
    output wire          [31:0] bdi_reg_wdata_o,
    input  wire          [31:0] bdi_reg_rdata_i,
    input  wire                 bdi_reg_ready_i,
    input  wire                 bdi_irq_i,
    input  wire                 bdi_busy_i
);


//=============================================================================
// 1)  WIRES
//=============================================================================

localparam              PA_W = VRAM_AW + 5;

// Register bus
wire                    rb_valid;
wire                    rb_wr;
wire             [11:2] rb_addr;
wire             [31:0] rb_wdata;
wire                    rb_wr_nxt;
wire             [11:2] rb_addr_nxt;
wire                    rb_ready_nxt_lut;
wire                    rb_sel_regs;
wire                    rb_sel_gpu;
wire                    rb_sel_bdi;
wire                    rb_sel_lut;
wire             [31:0] rb_rdata_regs;
wire                    rb_ready_regs;
wire             [31:0] rb_rdata_gpu;
wire                    rb_ready_gpu;
wire             [31:0] rb_rdata_lut;
wire                    rb_ready_lut;
wire                    r_active;
wire                    v_active;

// Configuration
wire              [2:0] gfx_mode;
wire                    gpu_en;
wire        [DIM_W-1:0] disp_width;
wire        [DIM_W-1:0] disp_height;
wire              [2:0] disp_cfg;
wire                    pix_double;
wire        [DIM_W-1:0] frame_width;
wire             [23:0] lut_rot;
wire         [PA_W-1:0] refr_frame_base;
wire             [15:0] refr_pitch;
wire                    sw_lut_en;
wire                    refr_bank;
wire              [2:0] hw_palette;
wire              [3:0] hw_bg;
wire              [3:0] hw_fg;
wire                    freeze_gpu;
wire                    cur_en;
wire              [9:0] cur_hot;
wire             [31:0] cur_pos;
wire      [VRAM_AW-1:0] cur_addr;
wire             [23:0] cur_col1;
wire             [23:0] cur_col2;
wire             [23:0] cur_col3;
wire                    refresh_running;
wire                    refr_done_evt;
wire                    refr_active_q;      // refresh_active one cycle late: the backend's flop
                                            // (u_active_dly), also blns_refresh's and the clock request's

// Status / events
wire                    gpu_busy;
wire                    gpu_err;
wire                    gpu_done_evt;
wire                    gpu_fence_evt;
wire                    gpu_idle_evt;
wire                    gpu_ovfl_evt;
wire                    gpu_err_evt;
wire                    gpu_fifo_low_evt;

// VRAM requesters: one slot each of the arbiter's packed vectors, the index
// also its priority inside its class (blns_vram_arb)
localparam              RQ_WIN   = 0;        // AHB window          host class
localparam              RQ_GPU   = 1;        // GPU                 normal, aged against the window
localparam              RQ_BK    = 2;        // backend (refresh)   urgent-capable, else normal; tagged with the cursor
localparam              RQ_WP    = 3;        // window read ahead   idle-only
localparam              RQ_N     = 4;
localparam   [RQ_N-1:0] RQ_ONE   = {{(RQ_N-1){1'b0}}, 1'b1};
localparam   [RQ_N-1:0] RQ_BUILT = (GPU_EN != 0) ? {RQ_N{1'b1}} : ~(RQ_ONE << RQ_GPU);
localparam   [RQ_N-1:0] RQ_TAGD  = RQ_BUILT & ((RQ_ONE << RQ_GPU) |                // with a read tag
                                              ((CURSOR_EN != 0) ? (RQ_ONE << RQ_BK) : {RQ_N{1'b0}}));

wire         [RQ_N-1:0] v_req;
wire         [RQ_N-1:0] v_urgent;
wire         [RQ_N-1:0] v_we;
wire       [4*RQ_N-1:0] v_be;
wire [VRAM_AW*RQ_N-1:0] v_addr;
wire      [32*RQ_N-1:0] v_wdata;
wire         [RQ_N-1:0] v_tag;
wire         [RQ_N-1:0] v_gnt;
wire         [RQ_N-1:0] v_rvalid;
wire         [RQ_N-1:0] v_rvalid_nxt;                // next cycle's v_rvalid (the window's registered HREADYOUT)
wire              [1:0] v_rvalid_nxt_unused = {v_rvalid_nxt[RQ_BK], v_rvalid_nxt[RQ_GPU]};   // (the window's only)
wire                    v_rtag;

// Read-only requesters, the urgent input of those that are not urgent-capable
// and the read tag of those without one (the GPU's tells its list reads, the
// backend's its cursor reads)
assign                  v_urgent[RQ_WIN]               = 1'b0;
assign                  v_urgent[RQ_GPU]               = 1'b0;
assign                  v_urgent[RQ_WP]                = 1'b0;
assign                  v_we[RQ_BK]                    = 1'b0;
assign                  v_be[RQ_BK*4 +: 4]             = 4'h0;
assign                  v_wdata[RQ_BK*32 +: 32]        = 32'h0000_0000;
assign                  v_we[RQ_WP]                    = 1'b0;
assign                  v_be[RQ_WP*4 +: 4]             = 4'h0;
assign                  v_wdata[RQ_WP*32 +: 32]        = 32'h0000_0000;
assign                  v_tag[RQ_WIN]                  = 1'b0;
assign                  v_tag[RQ_WP]                   = 1'b0;

// VRAM read data (registered in the arbiter with VRAM_RD_REG_EN), and the read
// latency every requester sees
localparam              VRAM_RD_L = VRAM_RD_LAT + VRAM_RD_REG_EN;
wire             [31:0] vram_rdata;

// The GPU's macro writes, that invalidate the window's read ahead (its own
// writes the window sees itself): the write address comes from a flop, not
// through the arbiter's address mux
wire      [VRAM_AW-1:0] gpu_vwaddr;
wire                    gpu_mwr = v_gnt[RQ_GPU] & v_we[RQ_GPU] & (|v_be[RQ_GPU*4 +: 4]);

// The window's posted write, that holds the register port until it is made
// (register effects follow the window writes before them)
wire                    vw_pend;
wire                    vw_pend_nxt;

// LUT requester (backend)
wire                    bk_lreq;
wire                    bk_lreq_nxt;
wire              [8:0] bk_laddr;
wire                    bk_lgnt;
wire                    bk_lrvalid;


//=============================================================================
// 2)  REGISTER PORT
//=============================================================================

blns_ahb_reg #(
    .GPU_EN           ( GPU_EN           ),
    .LUT_EN           ( LUT_EN           ),
    .PRIV_CHECK_EN    ( PRIV_CHECK_EN    ),
    .BDI_EXT_EN       ( DIF_TYPE == 0    ),
    .ASYNC_RST_EN     ( ASYNC_RST_EN     )
) u_ahb_reg (
    .hclk_i             ( hclk_i           ),
    .hresetn_i          ( hresetn_i        ),
    .hsel_i             ( r_hsel_i         ),
    .haddr_i            ( r_haddr_i        ),
    .htrans_i           ( r_htrans_i       ),
    .hwrite_i           ( r_hwrite_i       ),
    .hsize_i            ( r_hsize_i        ),
    .hprot_i            ( r_hprot_i        ),
    .hsmode_i           ( r_hsmode_i       ),
    .hready_i           ( r_hready_i       ),
    .hwdata_i           ( r_hwdata_i       ),
    .hrdata_o           ( r_hrdata_o       ),
    .hreadyout_o        ( r_hreadyout_o    ),
    .hresp_o            ( r_hresp_o        ),
    .active_o           ( r_active         ),
    .vw_pend_i          ( vw_pend          ),
    .vw_pend_nxt_i      ( vw_pend_nxt      ),
    .rb_valid_o         ( rb_valid         ),
    .rb_wr_o            ( rb_wr            ),
    .rb_addr_o          ( rb_addr          ),
    .rb_wdata_o         ( rb_wdata         ),
    .rb_wr_nxt_o        ( rb_wr_nxt        ),
    .rb_addr_nxt_o      ( rb_addr_nxt      ),
    .rb_sel_regs_o      ( rb_sel_regs      ),
    .rb_sel_gpu_o       ( rb_sel_gpu       ),
    .rb_sel_bdi_o       ( rb_sel_bdi       ),
    .rb_sel_lut_o       ( rb_sel_lut       ),
    .rb_rdata_regs_i    ( rb_rdata_regs    ),
    .rb_rdata_gpu_i     ( rb_rdata_gpu     ),
    .rb_rdata_bdi_i     ( bdi_reg_rdata_i  ),
    .rb_ready_bdi_i     ( bdi_reg_ready_i  ),
    .rb_rdata_lut_i     ( rb_rdata_lut     ),
    .rb_ready_nxt_lut_i ( rb_ready_nxt_lut )
);

// The port's HREADYOUT is decided one cycle ahead (blns_ahb_reg): the register
// and GPU windows complete in their first cycle (their ready is the transfer
// itself), the LUT window gives its ready one cycle ahead. The same-cycle
// readies are left for the bench, which checks the registered HREADYOUT
// against them.
wire              [2:0] rb_ready_unused  = {rb_ready_regs, rb_ready_gpu, rb_ready_lut};
wire              [8:0] rb_addr_nxt_unused = {rb_addr_nxt[11], rb_addr_nxt[9:2]};

assign  bdi_reg_sel_o   = rb_valid & rb_sel_bdi;
// BDI register word offset: [4:0] within a 32-word page, [5] the page (0 at
// 0x180, 1 at 0x200)
assign  bdi_reg_addr_o  = {rb_addr[9], rb_addr[6:2]};
assign  bdi_reg_wr_o    = rb_wr;
assign  bdi_reg_wdata_o = rb_wdata;


//=============================================================================
// 3)  GLOBAL REGISTERS
//=============================================================================

blns_regs #(
    .VRAM_AW            ( VRAM_AW            ),
    .VRAM_WORDS         ( VRAM_WORDS         ),
    .DIM_W              ( DIM_W              ),
    .FRAME_NR           ( FRAME_NR           ),
    .LUT_EN             ( LUT_EN             ),
    .LUT_BANKS          ( LUT_BANKS          ),
    .GPU_EN             ( GPU_EN             ),
    .GPU_XY_EN          ( GPU_XY_EN          ),
    .GPU_GRAD_EN        ( GPU_GRAD_EN        ),
    .GPU_BLEND_EN       ( GPU_BLEND_EN       ),
    .GPU_TRI_EN         ( GPU_TRI_EN         ),
    .GPU_REMAP_EN       ( GPU_REMAP_EN       ),
    .GPU_MPLANE_EN      ( GPU_MPLANE_EN      ),
    .GPU_IMM_EN         ( GPU_IMM_EN         ),
    .GPU_LINE_EN        ( GPU_LINE_EN        ),
    .GPU_BILINEAR_EN    ( GPU_BILINEAR_EN    ),
    .GPU_FIFO_AW        ( GPU_FIFO_AW        ),
    .DIF_TYPE           ( DIF_TYPE           ),
    .CURSOR_EN          ( CURSOR_EN          ),
    .PRIV_CHECK_EN      ( PRIV_CHECK_EN      ),
    .ASYNC_RST_EN       ( ASYNC_RST_EN       )
) u_regs (
    .hclk_i             ( hclk_i             ),
    .hresetn_i          ( hresetn_i          ),
    .rb_valid_i         ( rb_valid           ),
    .rb_sel_i           ( rb_sel_regs        ),
    .rb_wr_i            ( rb_wr              ),
    .rb_addr_i          ( rb_addr[6:2]       ),
    .rb_wdata_i         ( rb_wdata           ),
    .rb_rdata_o         ( rb_rdata_regs      ),
    .rb_ready_o         ( rb_ready_regs      ),
    .gfx_mode_o         ( gfx_mode           ),
    .gpu_en_o           ( gpu_en             ),
    .disp_width_o       ( disp_width         ),
    .disp_height_o      ( disp_height        ),
    .disp_cfg_o         ( disp_cfg           ),
    .pix_double_o       ( pix_double         ),
    .frame_width_o      ( frame_width        ),
    .refr_frame_base_o  ( refr_frame_base    ),
    .refr_pitch_o       ( refr_pitch         ),
    .sw_lut_en_o        ( sw_lut_en          ),
    .refr_bank_o        ( refr_bank          ),
    .hw_palette_o       ( hw_palette         ),
    .hw_bg_o            ( hw_bg              ),
    .hw_fg_o            ( hw_fg              ),
    .lut_rot_o          ( lut_rot            ),
    .freeze_gpu_o       ( freeze_gpu         ),
    .cur_en_o           ( cur_en             ),
    .cur_hot_o          ( cur_hot            ),
    .cur_pos_o          ( cur_pos            ),
    .cur_addr_o         ( cur_addr           ),
    .cur_col1_o         ( cur_col1           ),
    .cur_col2_o         ( cur_col2           ),
    .cur_col3_o         ( cur_col3           ),
    .dbg_stoptime_i     ( dbg_stoptime_i     ),
    .refresh_active_i   ( bdi_refresh_active_i ),
    .refresh_active_q_i ( refr_active_q      ),
    .px_last_i          ( bdi_px_valid_o & bdi_px_ready_i & bdi_px_last_o ),
    .refresh_trig_o     ( bdi_refresh_trig_o ),
    .refresh_running_o  ( refresh_running    ),
    .refr_done_evt_o    ( refr_done_evt      ),
    .gpu_busy_i         ( gpu_busy           ),
    .gpu_err_i          ( gpu_err            ),
    .dif_busy_i         ( bdi_busy_i         ),
    .gpu_done_evt_i     ( gpu_done_evt       ),
    .gpu_fence_evt_i    ( gpu_fence_evt      ),
    .gpu_idle_evt_i     ( gpu_idle_evt       ),
    .gpu_ovfl_evt_i     ( gpu_ovfl_evt       ),
    .gpu_err_evt_i      ( gpu_err_evt        ),
    .gpu_fifo_low_evt_i ( gpu_fifo_low_evt   ),
    .dif_irq_i          ( bdi_irq_i          ),
    .irq_o              ( irq_o              )
);

// Display size seen by the display driver and the backend. With the DBI driver,
// DISP_SIZE is held from the cycle the driver starts a refresh (and latches the
// window size) until its frame starts (the backend latches the pixel count), so
// both come from one size. Otherwise DISP_SIZE passes through; the backend
// latches it at the start of each frame.
// The held size is the driver's own copy (dbi_win_*_i, blns_dbi_engine
// u_win_size): it loads DISP_SIZE at the start of the refresh, the idle
// cycle before the hold rises (no hold there, so it takes DISP_SIZE
// itself), and does not change until the engine is idle again, past the
// hold. That is the value DISP_SIZE had in the last cycle without the hold.
localparam              SIZE_HOLD_EN = (DIF_TYPE >= 1) && (DIF_TYPE <= 3);
wire                    size_hold = SIZE_HOLD_EN & dbi_size_hold_i;
wire                    size_hold_unused = dbi_size_hold_i & ~SIZE_HOLD_EN;

wire        [DIM_W-1:0] frame_disp_width  = size_hold ? dbi_win_width_i  : disp_width;
wire        [DIM_W-1:0] frame_disp_height = size_hold ? dbi_win_height_i : disp_height;

assign  bdi_width_o  = frame_disp_width;
assign  dpi_cl_swap_o = disp_cfg[0];
assign  bdi_height_o = frame_disp_height;



//=============================================================================
// 4)  VRAM WINDOW PORT AND ARBITER
//=============================================================================

blns_ahb_vram #(
    .VRAM_AW       ( VRAM_AW       ),
    .VRAM_WORDS    ( VRAM_WORDS    ),
    .PRIV_CHECK_EN ( PRIV_CHECK_EN ),
    .RD_REG_EN     ( VRAM_RD_REG_EN ),
    .ASYNC_RST_EN  ( ASYNC_RST_EN  )
) u_ahb_vram (
    .hclk_i        ( hclk_i        ),
    .hresetn_i     ( hresetn_i     ),
    .hsel_i        ( v_hsel_i      ),
    .haddr_i       ( v_haddr_i     ),
    .htrans_i      ( v_htrans_i    ),
    .hwrite_i      ( v_hwrite_i    ),
    .hsize_i       ( v_hsize_i     ),
    .hprot_i       ( v_hprot_i     ),
    .hsmode_i      ( v_hsmode_i    ),
    .hready_i      ( v_hready_i    ),
    .hwdata_i      ( v_hwdata_i    ),
    .hrdata_o      ( v_hrdata_o    ),
    .hreadyout_o   ( v_hreadyout_o ),
    .hresp_o       ( v_hresp_o     ),
    .active_o      ( v_active      ),
    .wb_pend_o     ( vw_pend       ),
    .wb_pend_nxt_o ( vw_pend_nxt   ),
    .vreq_o        ( v_req[RQ_WIN]                       ),
    .vwe_o         ( v_we[RQ_WIN]                        ),
    .vbe_o         ( v_be[RQ_WIN*4 +: 4]                 ),
    .vaddr_o       ( v_addr[RQ_WIN*VRAM_AW +: VRAM_AW]   ),
    .vwdata_o      ( v_wdata[RQ_WIN*32 +: 32]            ),
    .vgnt_i        ( v_gnt[RQ_WIN]                       ),
    .vrvalid_i     ( v_rvalid[RQ_WIN]                    ),
    .vrvalid_nxt_i ( v_rvalid_nxt[RQ_WIN]                ),
    .vrdata_i      ( vram_rdata    ),
    .wp_vreq_o     ( v_req[RQ_WP]                        ),
    .wp_vaddr_o    ( v_addr[RQ_WP*VRAM_AW +: VRAM_AW]    ),
    .wp_vgnt_i     ( v_gnt[RQ_WP]                        ),
    .wp_vrvalid_i  ( v_rvalid[RQ_WP]                     ),
    .wp_vrvalid_nxt_i ( v_rvalid_nxt[RQ_WP]              ),
    .mwr_i         ( gpu_mwr       ),
    .mwaddr_i      ( gpu_vwaddr    )
);

// A VRAM read in flight, whichever requester made it (clock request)
wire                    vram_rd_pend;

blns_vram_arb #(
    .VRAM_AW       ( VRAM_AW               ),
    .RQ_N          ( RQ_N                  ),
    .RQ_EN         ( RQ_BUILT              ),
    .URG_MASK      ( RQ_ONE << RQ_BK       ),
    .HOST_MASK     ( RQ_ONE << RQ_WIN      ),
    .IDLE_MASK     ( RQ_ONE << RQ_WP       ),
    .AGE_IDX       ( RQ_GPU                ),
    .TAG_MASK      ( RQ_TAGD               ),
    .RD_LAT        ( VRAM_RD_LAT           ),
    .RD_REG_EN     ( VRAM_RD_REG_EN        ),
    .ASYNC_RST_EN  ( ASYNC_RST_EN          )
) u_vram_arb (
    .hclk_i        ( hclk_i        ),
    .hresetn_i     ( hresetn_i     ),
    .req_i         ( v_req         ),
    .urgent_i      ( v_urgent      ),
    .we_i          ( v_we          ),
    .be_i          ( v_be          ),
    .addr_i        ( v_addr        ),
    .wdata_i       ( v_wdata       ),
    .tag_i         ( v_tag         ),
    .gnt_o         ( v_gnt         ),
    .rvalid_o      ( v_rvalid      ),
    .rvalid_nxt_o  ( v_rvalid_nxt  ),
    .rtag_o        ( v_rtag        ),
    .rdata_o       ( vram_rdata    ),
    .rd_pend_o     ( vram_rd_pend  ),
    .vram_cen_o    ( vram_cen_o    ),
    .vram_wen_o    ( vram_wen_o    ),
    .vram_addr_o   ( vram_addr_o   ),
    .vram_din_o    ( vram_din_o    ),
    .vram_dout_i   ( vram_dout_i   )
);


//=============================================================================
// 5)  GPU
//=============================================================================

generate
    if (GPU_EN != 0) begin : G_GPU
        blns_gpu #(
            .VRAM_WORDS     ( VRAM_WORDS     ),
            .VRAM_AW        ( VRAM_AW        ),
            .DIM_W          ( DIM_W          ),
            .GPU_XY_EN      ( GPU_XY_EN      ),
            .GPU_GRAD_EN    ( GPU_GRAD_EN    ),
            .GPU_BLEND_EN   ( GPU_BLEND_EN   ),
            .GPU_TRI_EN     ( GPU_TRI_EN     ),
            .GPU_RUNAHEAD_EN( GPU_RUNAHEAD_EN),
            .GPU_REMAP_EN   ( GPU_REMAP_EN   ),
            .GPU_MPLANE_EN  ( GPU_MPLANE_EN  ),
            .GPU_IMM_EN     ( GPU_IMM_EN     ),
            .GPU_LINE_EN    ( GPU_LINE_EN    ),
            .GPU_BILINEAR_EN( GPU_BILINEAR_EN),
            .GPU_FIFO_AW    ( GPU_FIFO_AW    ),
            .RD_LAT         ( VRAM_RD_L      ),
            .ASYNC_RST_EN   ( ASYNC_RST_EN   )
        ) u_gpu (
            .hclk_i         ( hclk_i         ),
            .hresetn_i      ( hresetn_i      ),
            .rb_valid_i     ( rb_valid       ),
            .rb_sel_i       ( rb_sel_gpu     ),
            .rb_wr_i        ( rb_wr          ),
            .rb_addr_i      ( rb_addr[4:2]   ),
            .rb_wdata_i     ( rb_wdata       ),
            .rb_rdata_o     ( rb_rdata_gpu   ),
            .rb_ready_o     ( rb_ready_gpu   ),
            .gfx_mode_i     ( gfx_mode       ),
            .disp_width_i   ( frame_width    ),
            .gpu_en_i       ( gpu_en         ),
            .freeze_i       ( freeze_gpu     ),
            .refr_done_i    ( refr_done_evt  ),
            .vreq_o         ( v_req[RQ_GPU]                     ),
            .vwe_o          ( v_we[RQ_GPU]                      ),
            .vbe_o          ( v_be[RQ_GPU*4 +: 4]               ),
            .vaddr_o        ( v_addr[RQ_GPU*VRAM_AW +: VRAM_AW] ),
            .vwaddr_o       ( gpu_vwaddr                        ),
            .vwdata_o       ( v_wdata[RQ_GPU*32 +: 32]          ),
            .vtag_o         ( v_tag[RQ_GPU]                     ),
            .vgnt_i         ( v_gnt[RQ_GPU]                     ),
            .vrvalid_i      ( v_rvalid[RQ_GPU]                  ),
            .vrtag_i        ( v_rtag                            ),
            .vrdata_i       ( vram_rdata     ),
            .busy_o         ( gpu_busy       ),
            .err_o          ( gpu_err        ),
            .done_evt_o     ( gpu_done_evt   ),
            .fence_evt_o    ( gpu_fence_evt  ),
            .idle_evt_o     ( gpu_idle_evt   ),
            .ovfl_evt_o     ( gpu_ovfl_evt   ),
            .err_evt_o      ( gpu_err_evt    ),
            .fifo_low_evt_o ( gpu_fifo_low_evt )
        );
    end else begin : G_NO_GPU
        assign rb_rdata_gpu = 32'h0000_0000;
        assign rb_ready_gpu = 1'b1;
        assign v_req[RQ_GPU]                     = 1'b0;
        assign v_we[RQ_GPU]                      = 1'b0;
        assign v_be[RQ_GPU*4 +: 4]               = 4'h0;
        assign v_addr[RQ_GPU*VRAM_AW +: VRAM_AW] = {VRAM_AW{1'b0}};
        assign gpu_vwaddr                        = {VRAM_AW{1'b0}};
        assign v_wdata[RQ_GPU*32 +: 32]          = 32'h0000_0000;
        assign v_tag[RQ_GPU]                     = 1'b0;
        assign gpu_busy     = 1'b0;
        assign gpu_err      = 1'b0;
        assign gpu_done_evt = 1'b0;
        assign gpu_fence_evt = 1'b0;
        assign gpu_idle_evt = 1'b0;
        assign gpu_ovfl_evt = 1'b0;
        assign gpu_err_evt  = 1'b0;
        assign gpu_fifo_low_evt = 1'b0;
        wire   [6:0] gpu_unused = {gpu_en, freeze_gpu, refr_done_evt, v_gnt[RQ_GPU], v_rvalid[RQ_GPU], v_rtag, rb_sel_gpu};
        // Default GPU pitch: unused here without the GPU (the backend's
        // source width without the DBI size hold)
        wire   [DIM_W-1:0] frame_width_unused = frame_width;
    end
endgenerate


//=============================================================================
// 6)  DISPLAY BACKEND AND LUT
//=============================================================================

blns_backend #(
    .VRAM_AW          ( VRAM_AW              ),
    .DIM_W            ( DIM_W                ),
    .LUT_EN           ( LUT_EN               ),
    .LUT_BANKS        ( LUT_BANKS            ),
    .CURSOR_EN        ( CURSOR_EN            ),
    .RD_LAT           ( VRAM_RD_L            ),
    .FRAME_W_EN       ( !SIZE_HOLD_EN        ),
    .ASYNC_RST_EN     ( ASYNC_RST_EN         )
) u_backend (
    .hclk_i           ( hclk_i               ),
    .hresetn_i        ( hresetn_i            ),
    .gfx_mode_i       ( gfx_mode             ),
    .disp_width_i     ( frame_disp_width     ),
    .disp_height_i    ( frame_disp_height    ),
    .disp_cfg_i       ( disp_cfg             ),
    .pix_double_i     ( pix_double           ),
    .frame_width_i    ( frame_width          ),
    .frame_base_i     ( refr_frame_base      ),
    .pitch_i          ( refr_pitch           ),
    .sw_lut_en_i      ( sw_lut_en            ),
    .refr_bank_i      ( refr_bank            ),
    .hw_palette_i     ( hw_palette           ),
    .hw_bg_i          ( hw_bg                ),
    .hw_fg_i          ( hw_fg                ),
    .lut_rot_i        ( lut_rot              ),
    .cur_en_i         ( cur_en               ),
    .cur_hot_i        ( cur_hot              ),
    .cur_pos_i        ( cur_pos              ),
    .cur_addr_i       ( cur_addr             ),
    .cur_col1_i       ( cur_col1             ),
    .cur_col2_i       ( cur_col2             ),
    .cur_col3_i       ( cur_col3             ),
    .vreq_o           ( v_req[RQ_BK]                     ),
    .vurgent_o        ( v_urgent[RQ_BK]                  ),
    .vaddr_o          ( v_addr[RQ_BK*VRAM_AW +: VRAM_AW] ),
    .vtag_o           ( v_tag[RQ_BK]                     ),
    .vgnt_i           ( v_gnt[RQ_BK]                     ),
    .vrvalid_i        ( v_rvalid[RQ_BK]                  ),
    .vrtag_i          ( v_rtag               ),
    .vrdata_i         ( vram_rdata           ),
    .lreq_o           ( bk_lreq              ),
    .lreq_nxt_o       ( bk_lreq_nxt          ),
    .laddr_o          ( bk_laddr             ),
    .lgnt_i           ( bk_lgnt              ),
    .lrvalid_i        ( bk_lrvalid           ),
    .lrdata_i         ( lut_dout_i           ),
    .px_valid_o       ( bdi_px_valid_o       ),
    .px_data_o        ( bdi_px_data_o        ),
    .px_last_o        ( bdi_px_last_o        ),
    .px_ready_i       ( bdi_px_ready_i       ),
    .refresh_active_i ( bdi_refresh_active_i ),
    .active_dly_o     ( refr_active_q        ),
    .line_len_m1_o    ( dpi_line_len_m1_o    )
);

generate
    if (LUT_EN != 0) begin : G_LUT
        blns_lut #(
            .LUT_BANKS    ( LUT_BANKS     ),
            .ASYNC_RST_EN ( ASYNC_RST_EN  )
        ) u_lut (
            .hclk_i         ( hclk_i           ),
            .hresetn_i      ( hresetn_i        ),
            .rb_valid_i     ( rb_valid         ),
            .rb_sel_i       ( rb_sel_lut       ),
            .rb_wr_i        ( rb_wr            ),
            .rb_addr_i      ( rb_addr[10:2]    ),
            .rb_wdata_i     ( rb_wdata         ),
            .rb_rdata_o     ( rb_rdata_lut     ),
            .rb_ready_o     ( rb_ready_lut     ),
            .rb_wr_nxt_i    ( rb_wr_nxt        ),
            .rb_bank_nxt_i  ( rb_addr_nxt[10]  ),
            .rb_ready_nxt_o ( rb_ready_nxt_lut ),
            .bk_lreq_i      ( bk_lreq          ),
            .bk_lreq_nxt_i  ( bk_lreq_nxt      ),
            .bk_laddr_i     ( bk_laddr         ),
            .bk_lgnt_o      ( bk_lgnt          ),
            .bk_lrvalid_o   ( bk_lrvalid       ),
            .lut_cen_o      ( lut_cen_o        ),
            .lut_wen_o      ( lut_wen_o        ),
            .lut_addr_o     ( lut_addr_o       ),
            .lut_din_o      ( lut_din_o        ),
            .lut_dout_i     ( lut_dout_i       )
        );
    end else begin : G_NO_LUT
        assign rb_rdata_lut = 32'h0000_0000;
        assign rb_ready_lut = 1'b1;
        assign rb_ready_nxt_lut = 1'b1;
        assign bk_lgnt      = 1'b0;
        assign bk_lrvalid   = 1'b0;
        assign lut_cen_o    = 1'b1;
        assign lut_wen_o    = 1'b1;
        assign lut_addr_o   = 9'h000;
        assign lut_din_o    = 24'h00_0000;
        wire   [14:0] lut_unused = {bk_lreq, bk_laddr, rb_sel_lut, rb_addr[10:7]};
        wire    [2:0] lut_nxt_unused = {bk_lreq_nxt, rb_wr_nxt, rb_addr_nxt[10]};
    end
endgenerate


//=============================================================================
// 7)  CLOCK REQUEST
//=============================================================================

// The LUT window decodes bits [10:2]; bit 11 is consumed by the port decoder.
wire                    rb_addr_unused = rb_addr[11];

// One extra edge after bus activity: a register write lands on the edge that
// ends its data phase, and the blocks that copy configuration (the backend's
// per-frame latch) need the following edge to see it. Likewise one edge after
// a frame ends (refr_active_q): it records the end of the frame.
wire                    bus_active      = r_active | v_active;
wire                    bus_active_q;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_bus_active_q (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(bus_active), .q_o(bus_active_q));

// One extra edge after the GPU's busy falls: GPU_IDLE is raised in the first
// cycle the GPU is no longer busy, and IRQ_FLAG needs that edge.
wire                    gpu_busy_q;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_gpu_busy_q (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(gpu_busy), .q_o(gpu_busy_q));

// A VRAM read in flight keeps the clock until its data returns, for every
// requester: with the macros on the free-running clock the data does not wait.
// The backend is busy while bdi_refresh_active_i is high: that is seen through
// refr_active_q, not combinationally (the driver's busy covers the rising
// edge: bdi_busy_i, or the built-in driver's busy while it runs a frame).
// The reset generator requests the clock during a synchronous reset.
//
// Invariant: every IRQ_FLAG set event and every state update lands in a cycle
// the request covers. The terms that cover each event:
//   - REFR_START: bdi_busy_i (the driver holds it from before the frame);
//   - REFR_DONE, FRAME_CNT_DONE, FRAME_NUM, REFR_ABANDONED: refr_active_q;
//   - GPU_DONE, GPU_FENCE, GPU_ERR, GPU_FIFO_LOW: gpu_busy (the GPU is busy
//     in their cycle); GPU_FIFO_LOW re-armed by a GPU_FIFO_LOW write: the
//     cycle after the write, bus_active_q; GPU_IDLE: gpu_busy_q; GPU_OVFL and
//     the W1C writes: bus_active;
//   - DIF: a level from the driver, whose own events land under bdi_busy_i
//     or a bus access.
// A new event source adds its term here.
assign  hclk_en_o = bus_active | bus_active_q | gpu_busy | gpu_busy_q | vram_rd_pend |
                    refr_active_q | refresh_running | bdi_busy_i;

endmodule // belenos_core

`default_nettype wire
