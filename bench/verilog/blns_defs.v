//----------------------------------------------------------------------------
//          _    _           Family:    aRVern Graphic Controller
//         / \__/ \          Module:    blns_defs
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : blns_defs.v
// Module Description : Belenos register map for the tests (`included into
//                      tb_belenos). Register-port byte offsets.
//----------------------------------------------------------------------------

// VRAM arbiter requester slots (belenos_core RQ_*), for the bench monitors
localparam        VRQ_WIN       = 0;
localparam        VRQ_GPU       = 1;
localparam        VRQ_BK        = 2;
localparam        VRQ_WP        = 3;

// Global registers
localparam [31:0] BLNS_ID       = 32'h000;
localparam [31:0] BLNS_CFG      = 32'h004;
localparam [31:0] BLNS_CFG2     = 32'h008;
localparam [31:0] CTRL          = 32'h010;
localparam [31:0] STATUS        = 32'h014;
localparam [31:0] IRQ_EN        = 32'h018;
localparam [31:0] IRQ_FLAG      = 32'h01C;
localparam [31:0] DISP_SIZE     = 32'h020;
localparam [31:0] DISP_CFG      = 32'h024;
localparam [31:0] FRAME_CNT     = 32'h028;
localparam [31:0] REFRESH       = 32'h02C;
localparam [31:0] FRAME_SEL     = 32'h030;
localparam [31:0] DBG_CTRL      = 32'h034;
localparam [31:0] FRAME_NUM     = 32'h038;         // RO [15:0] frames sent
localparam [31:0] REFR_PITCH    = 32'h03C;
localparam [31:0] FRAME0_PTR    = 32'h040;
localparam [31:0] FRAME1_PTR    = 32'h044;
localparam [31:0] FRAME2_PTR    = 32'h048;
localparam [31:0] FRAME3_PTR    = 32'h04C;
localparam [31:0] LUT_CFG       = 32'h050;
localparam [31:0] LUT_ROT       = 32'h054;
localparam [31:0] CURSOR_CTRL   = 32'h058;
localparam [31:0] CURSOR_POS    = 32'h05C;
localparam [31:0] CURSOR_ADDR   = 32'h060;
localparam [31:0] CURSOR_COL1   = 32'h064;
localparam [31:0] CURSOR_COL2   = 32'h068;
localparam [31:0] CURSOR_COL3   = 32'h06C;

// GPU
localparam [31:0] GPU_CMD       = 32'h100;
localparam [31:0] GPU_STAT      = 32'h104;
localparam [31:0] GPU_CTRL      = 32'h108;
localparam [31:0] GPU_LIST      = 32'h10C;
localparam [31:0] GPU_FENCE     = 32'h110;
localparam [31:0] GPU_ERR       = 32'h114;
localparam [31:0] GPU_FIFO_LOW  = 32'h118;

// GPU opcodes ([31:28])
localparam  [3:0] OP_SET_SRC    = 4'h1;
localparam  [3:0] OP_SET_DST    = 4'h2;
localparam  [3:0] OP_SET_SIZE   = 4'h3;
localparam  [3:0] OP_SET_FILL   = 4'h4;
localparam  [3:0] OP_SET_TRANSP = 4'h5;
localparam  [3:0] OP_EXEC_FILL  = 4'h8;
localparam  [3:0] OP_EXEC_COPY  = 4'h9;
localparam  [3:0] OP_EXEC_COPYT = 4'hA;
localparam  [3:0] OP_EXEC_SPAN  = 4'hB;
localparam  [3:0] OP_EXEC_EXP   = 4'hC;
localparam  [3:0] OP_CALL       = 4'h7;          // [23:0] N, operand: list word address
localparam  [3:0] OP_SET_EXT    = 4'h6;          // [27:24] 0 SET_TEX, 1 SET_UV (+op), 2 SET_STEP (+op)

// SET_EXT sub-commands ([27:24])
localparam  [3:0] EXT_SET_TEX      = 4'h0;
localparam  [3:0] EXT_SET_UV       = 4'h1;       // + operand
localparam  [3:0] EXT_SET_STEP     = 4'h2;       // + operand
localparam  [3:0] EXT_SET_XY       = 4'h3;       // [11:0] x, [23:12] y (signed)
localparam  [3:0] EXT_SET_CLIP     = 4'h4;       // [11:0] x0, [23:12] y0; + operand [11:0] x1, [23:12] y1
localparam  [3:0] EXT_SET_STEP_ROW = 4'h5;       // + operand [31:16] du', [15:0] dv'
localparam  [3:0] EXT_SET_TEXBOX   = 4'h6;       // [11:0] TW, [23:12] TH
localparam  [3:0] EXT_SET_GRAD     = 4'h7;       // [11:0] N, [12] AXIS, [16:13] STEP, [17] EN, [18] RGB
localparam  [3:0] EXT_SET_GRGB     = 4'hC;       // SET_GRAD_RGB; operand [29:20] dR, [19:10] dG, [9:0] dB
localparam  [3:0] EXT_SET_AUX      = 4'hD;       // [23:20] SEL: 0 REMAP_TABLE, 1 MASK_PLANE ([16] INV); + operand
localparam  [3:0] EXT_SET_EXT2     = 4'hF;       // [23:16] code: 1 WAIT_REFR_DONE, 2 RESET_STATE
localparam  [7:0] X2_WAIT_REFR     = 8'h01;
localparam  [7:0] X2_RESET_STATE   = 8'h02;
localparam  [3:0] OP_EXEC_TEX   = 4'hD;
localparam  [3:0] OP_EXEC_TEXRECT = 4'hE;        // [27:14] DELTA, SET_SIZE W x H
localparam  [3:0] OP_FENCE      = 4'hF;

// DBI driver (BDI register window)
localparam [31:0] DIF_CFG       = 32'h180;
localparam [31:0] DIF_SYNC      = 32'h184;
localparam [31:0] DIF_CMD       = 32'h188;
localparam [31:0] DIF_PARAM     = 32'h18C;
localparam [31:0] DIF_DFILL     = 32'h190;
localparam [31:0] DIF_STATUS    = 32'h194;
localparam [31:0] DIF_IRQ_EN    = 32'h198;
localparam [31:0] DIF_IRQ_FLAG  = 32'h19C;
// DPI driver (DIF_TYPE = 4): the window's own registers
localparam [31:0] DPI_H_ACT     = 32'h1A0;
localparam [31:0] DPI_H_BLANK   = 32'h1A4;
localparam [31:0] DPI_V_ACT     = 32'h1A8;
localparam [31:0] DPI_V_BLANK   = 32'h1AC;
localparam [31:0] DPI_IMG_SIZE  = 32'h1B0;
localparam [31:0] DPI_IMG_POS   = 32'h1B4;
localparam [31:0] DPI_SCALE     = 32'h1B8;
localparam [31:0] DPI_BORDER    = 32'h1BC;
localparam [31:0] DPI_CTRL      = 32'h1C0;
localparam [31:0] DPI_FRAMES    = 32'h1C4;
localparam [31:0] DPI_DDC       = 32'h200;            // HDMI page (0x200)
localparam [31:0] DPI_HDMI      = 32'h204;
localparam [31:0] DPI_AUD       = 32'h208;
localparam [31:0] DPI_AUD_ST    = 32'h20C;
localparam [31:0] DPI_PKT0      = 32'h210;
localparam [31:0] DPI_CAPS      = 32'h1FC;

// LUT window
localparam [31:0] LUT_BASE      = 32'h800;

// Field values
localparam [31:0] BLNS_VERSION_EXP = 32'h0001_0000;
// BLNS_CFG: [4:0] VRAM_AW, [5] LUT, [6] LUT2, [8:7] FRAME_NR - 1, [12:9]
// DIM_W - 1, [15:13] DIF_TYPE, [16] PRIV_CHECK, [17] GPU, [18] CURSOR
localparam [31:0] BLNS_CFG_EXP  = (VRAM_AW & 32'h1F)                                  |
                                  ((LUT_EN != 0)                        ? 32'h20 : 0) |
                                  (((LUT_EN != 0) && (LUT_BANKS == 2))  ? 32'h40 : 0) |
                                  (((FRAME_NR - 1) & 3) << 7)                         |
                                  (((DIM_W - 1) & 15)   << 9)                         |
                                  ((DIF_TYPE & 7)       << 13)                        |
                                  ((PRIV_CHECK_EN != 0)                 ? 32'h10000 : 0) |
                                  ((GPU_EN != 0)                        ? 32'h20000 : 0) |
                                  ((CURSOR_EN != 0)                     ? 32'h40000 : 0);
// BLNS_CFG2 (0 without a GPU): [3:0] FIFO_AW, [4] XY, [5] GRAD, [6] BLEND,
// [7] TRI (with XY), [8] REMAP, [9] MPLANE, [10] IMM, [11] LINE (with XY),
// [12] BILINEAR (with XY)
localparam [31:0] BLNS_CFG2_EXP = (GPU_EN == 0) ? 32'h0 :
                                  ((GPU_FIFO_AW & 15)                                    |
                                   ((GPU_XY_EN     != 0)                      ? 32'h010 : 0) |
                                   ((GPU_GRAD_EN   != 0)                      ? 32'h020 : 0) |
                                   ((GPU_BLEND_EN  != 0)                      ? 32'h040 : 0) |
                                   (((GPU_TRI_EN != 0) && (GPU_XY_EN != 0))   ? 32'h080 : 0) |
                                   ((GPU_REMAP_EN  != 0)                      ? 32'h100 : 0) |
                                   ((GPU_MPLANE_EN != 0)                      ? 32'h200 : 0) |
                                   ((GPU_IMM_EN    != 0)                      ? 32'h400 : 0) |
                                   (((GPU_LINE_EN != 0) && (GPU_XY_EN != 0))  ? 32'h800 : 0) |
                                   (((GPU_BILINEAR_EN != 0) && (GPU_XY_EN != 0)) ? 32'h1000 : 0));
localparam [31:0] CFG2_XY       = 32'h010;
localparam [31:0] CFG2_GRAD     = 32'h020;
localparam [31:0] CFG2_BLEND    = 32'h040;
localparam [31:0] CFG2_TRI      = 32'h080;
localparam [31:0] CFG2_REMAP    = 32'h100;
localparam [31:0] CFG2_MPLANE   = 32'h200;
localparam [31:0] CFG2_IMM      = 32'h400;
localparam [31:0] CFG2_LINE     = 32'h800;
localparam [31:0] CFG2_BILINEAR = 32'h1000;
localparam  [2:0] GFX_1BPP      = 3'd0;
localparam  [2:0] GFX_2BPP      = 3'd1;
localparam  [2:0] GFX_4BPP      = 3'd2;
localparam  [2:0] GFX_8BPP      = 3'd3;
localparam  [2:0] GFX_16BPP     = 3'd4;
