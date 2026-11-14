/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      belenos_regs.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Belenos register map: a structure overlaying the 4 KB register port and the
 * field position / mask macros of every register (CMSIS naming:
 * BLNS_<REG>_<FIELD>_Pos and _Msk). Reference: doc/register_map.md,
 * doc/programming_model.md and doc/gpu_commands.md.
 *----------------------------------------------------------------------------*/
#ifndef BELENOS_REGS_H
#define BELENOS_REGS_H

#include <stddef.h>
#include <stdint.h>

#define BLNS_IO  volatile               /* read-write register */
#define BLNS_I   volatile const         /* read-only register  */
#define BLNS_O   volatile               /* write-only register */

/*---------------------------------------------------------------------------
 * Register structures
 *---------------------------------------------------------------------------*/

/* GPU, at 0x100 */
typedef struct {
    BLNS_O  uint32_t CMD;               /* +0x00: push one command word (reads 0) */
    BLNS_I  uint32_t STAT;              /* +0x04 */
    BLNS_O  uint32_t CTRL;              /* +0x08: CLEAR_ERR / ABORT / DISCARD (reads 0) */
    BLNS_I  uint32_t LIST;              /* +0x0C: word address of the next list word */
    BLNS_I  uint32_t FENCE;             /* +0x10: TAG of the last FENCE reached */
    BLNS_I  uint32_t ERR;               /* +0x14: the word that stopped the decoder */
    BLNS_IO uint32_t FIFO_LOW;          /* +0x18: THRESH of the GPU_FIFO_LOW event */
            uint32_t RESERVED;          /* +0x1C */
} BLNS_GPU_TypeDef;

/* Built-in DBI display driver, at 0x180 (an external driver with DIF_TYPE = 0
 * defines its own registers in this window) */
typedef struct {
    BLNS_IO uint32_t CFG;               /* +0x00 */
    BLNS_IO uint32_t SYNC;              /* +0x04 */
    BLNS_O  uint32_t CMD;               /* +0x08 */
    BLNS_O  uint32_t PARAM;             /* +0x0C */
    BLNS_O  uint32_t DFILL;             /* +0x10 */
    BLNS_IO uint32_t STATUS;            /* +0x14: [7] PARAM_OVFL write 1 to clear */
    BLNS_IO uint32_t IRQ_EN;            /* +0x18 */
    BLNS_IO uint32_t IRQ_FLAG;          /* +0x1C: write 1 to clear */
            uint32_t RESERVED[24];      /* +0x20 .. +0x7C */
} BLNS_DIF_TypeDef;

/* Built-in DPI display driver, at 0x180 (DIF_TYPE = 4, and 5 with the TMDS encoder) */
typedef struct {
    BLNS_IO uint32_t CFG;               /* +0x00 */
    BLNS_IO uint32_t SYNC;              /* +0x04 */
            uint32_t RESERVED0[3];      /* +0x08 .. +0x10 */
    BLNS_I  uint32_t STATUS;            /* +0x14 */
    BLNS_IO uint32_t IRQ_EN;            /* +0x18 */
    BLNS_IO uint32_t IRQ_FLAG;          /* +0x1C: write 1 to clear */
    BLNS_IO uint32_t H_ACT;             /* +0x20 */
    BLNS_IO uint32_t H_BLANK;           /* +0x24 */
    BLNS_IO uint32_t V_ACT;             /* +0x28 */
    BLNS_IO uint32_t V_BLANK;           /* +0x2C */
    BLNS_IO uint32_t IMG_SIZE;          /* +0x30 */
    BLNS_IO uint32_t IMG_POS;           /* +0x34 */
    BLNS_IO uint32_t SCALE;             /* +0x38 */
    BLNS_IO uint32_t BORDER;            /* +0x3C */
    BLNS_IO uint32_t CTRL;              /* +0x40 */
    BLNS_I  uint32_t FRAMES;            /* +0x44 */
            uint32_t RESERVED1[13];     /* +0x48 .. +0x78 */
    BLNS_I  uint32_t CAPS;              /* +0x7C */
} BLNS_DPI_TypeDef;

/* HDMI page of the DPI driver, at 0x200 (DIF_TYPE = 5) */
typedef struct {
    BLNS_IO uint32_t DDC;               /* +0x00: HDMI DDC lines (DPI_CAPS.DDC) */
    BLNS_IO uint32_t HDMI;              /* +0x04: HDMI mode, AVI InfoFrame (DPI_CAPS.ISLAND) */
    BLNS_IO uint32_t AUD;               /* +0x08: HDMI audio N and channel status (DPI_CAPS.AUDIO) */
    BLNS_I  uint32_t AUD_STAT;          /* +0x0C: measured CTS, frames lost, audio on */
    BLNS_IO uint32_t PKT[8];            /* +0x10 .. +0x2C: generic packet: header, PB0-PB27 */
            uint32_t RESERVED[20];      /* +0x30 .. +0x7C */
} BLNS_HDMI_TypeDef;

/* The whole register port */
typedef struct {
    BLNS_I  uint32_t ID;                /* 0x000 */
    BLNS_I  uint32_t CFG;               /* 0x004 */
    BLNS_I  uint32_t CFG2;              /* 0x008 */
    BLNS_I  uint32_t VRAM_WORDS;        /* 0x00C: VRAM depth in words (RO) */
    BLNS_IO uint32_t CTRL;              /* 0x010 */
    BLNS_I  uint32_t STATUS;            /* 0x014 */
    BLNS_IO uint32_t IRQ_EN;            /* 0x018 */
    BLNS_IO uint32_t IRQ_FLAG;          /* 0x01C: bits 0-7, 9 and 10 write 1 to clear */
    BLNS_IO uint32_t DISP_SIZE;         /* 0x020 */
    BLNS_IO uint32_t DISP_CFG;          /* 0x024 */
    BLNS_IO uint32_t FRAME_CNT;         /* 0x028 */
    BLNS_IO uint32_t REFRESH;           /* 0x02C */
    BLNS_IO uint32_t FRAME_SEL;         /* 0x030 */
    BLNS_IO uint32_t DBG_CTRL;          /* 0x034 */
    BLNS_I  uint32_t FRAME_NUM;         /* 0x038: frames sent */
    BLNS_IO uint32_t REFR_PITCH;        /* 0x03C */
    BLNS_IO uint32_t FRAME_PTR[4];      /* 0x040 .. 0x04C */
    BLNS_IO uint32_t LUT_CFG;           /* 0x050 */
    BLNS_IO uint32_t LUT_ROT;           /* 0x054 */
    BLNS_IO uint32_t CURSOR_CTRL;       /* 0x058 */
    BLNS_IO uint32_t CURSOR_POS;        /* 0x05C */
    BLNS_IO uint32_t CURSOR_ADDR;       /* 0x060 */
    BLNS_IO uint32_t CURSOR_COL[3];     /* 0x064 .. 0x06C: colours 1-3, RGB888 */
            uint32_t RESERVED2[4];      /* 0x070 .. 0x07C */
            uint32_t RESERVED3[32];     /* 0x080 .. 0x0FC */
    BLNS_GPU_TypeDef GPU;               /* 0x100 .. 0x11C */
            uint32_t RESERVED4[24];     /* 0x120 .. 0x17C */
    union {
        BLNS_DIF_TypeDef DIF;           /* 0x180 .. 0x1FC: DBI driver */
        BLNS_DPI_TypeDef DPI;           /* 0x180 .. 0x1FC: DPI driver */
    };
    BLNS_HDMI_TypeDef HDMI;             /* 0x200 .. 0x27C: DPI driver, HDMI page */
            uint32_t RESERVED5[352];    /* 0x280 .. 0x7FC */
    BLNS_IO uint32_t LUT[2][256];       /* 0x800 .. 0xFFC: RGB888, [23:16] R [15:8] G [7:0] B */
} BLNS_TypeDef;

/* C11 _Static_assert, C++11 static_assert (the header compiles as both) */
#ifdef __cplusplus
#define BLNS_STATIC_ASSERT(c, msg)  static_assert(c, msg)
#else
#define BLNS_STATIC_ASSERT(c, msg)  _Static_assert(c, msg)
#endif

BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, CTRL)      == 0x010, "BLNS CTRL offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, DISP_SIZE) == 0x020, "BLNS DISP_SIZE offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, FRAME_SEL) == 0x030, "BLNS FRAME_SEL offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, FRAME_NUM) == 0x038, "BLNS FRAME_NUM offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, FRAME_PTR) == 0x040, "BLNS FRAME_PTR offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, LUT_CFG)   == 0x050, "BLNS LUT_CFG offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, LUT_ROT)   == 0x054, "BLNS LUT_ROT offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, CURSOR_CTRL) == 0x058, "BLNS CURSOR_CTRL offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, CURSOR_COL)  == 0x064, "BLNS CURSOR_COL offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, GPU)       == 0x100, "BLNS GPU offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, DIF)       == 0x180, "BLNS DIF offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, HDMI)      == 0x200, "BLNS HDMI offset");
BLNS_STATIC_ASSERT(offsetof(BLNS_TypeDef, LUT)       == 0x800, "BLNS LUT offset");
BLNS_STATIC_ASSERT(sizeof(BLNS_TypeDef)              == 0x1000, "BLNS register port size");

/*---------------------------------------------------------------------------
 * Field definitions
 *---------------------------------------------------------------------------*/
#define BLNS_FIELD(pos, width)          (((1u << (width)) - 1u) << (pos))

/* ID */
#define BLNS_ID_PATCH_Pos               8u
#define BLNS_ID_PATCH_Msk               BLNS_FIELD(8u, 8u)
#define BLNS_ID_MINOR_Pos               16u
#define BLNS_ID_MINOR_Msk               BLNS_FIELD(16u, 8u)
#define BLNS_ID_MAJOR_Pos               24u
#define BLNS_ID_MAJOR_Msk               BLNS_FIELD(24u, 8u)

/* CFG: the core (only what varies between builds; [31:19] read 0) */
#define BLNS_CFG_VRAM_AW_Pos            0u
#define BLNS_CFG_VRAM_AW_Msk            BLNS_FIELD(0u, 5u)
#define BLNS_CFG_LUT_Msk                (1u << 5)       /* programmable LUT */
#define BLNS_CFG_LUT2_Msk               (1u << 6)       /* second LUT bank */
#define BLNS_CFG_FRAME_NR_M1_Pos        7u
#define BLNS_CFG_FRAME_NR_M1_Msk        BLNS_FIELD(7u, 2u)
#define BLNS_CFG_DIM_W_M1_Pos           9u
#define BLNS_CFG_DIM_W_M1_Msk           BLNS_FIELD(9u, 4u)
#define BLNS_CFG_DIF_TYPE_Pos           13u             /* built-in display driver, BLNS_DIF_* */
#define BLNS_CFG_DIF_TYPE_Msk           BLNS_FIELD(13u, 3u)
#define BLNS_CFG_PRIV_CHECK_Msk         (1u << 16)      /* user-mode accesses refused */
#define BLNS_CFG_GPU_Msk                (1u << 17)      /* GPU present */
#define BLNS_CFG_CURSOR_Msk             (1u << 18)      /* hardware cursor present */
#define BLNS_VRAM_WORDS_Msk             0x01FFFFFFu

/* Built-in display drivers (BLNS_CFG.DIF_TYPE) */
#define BLNS_DIF_BDI                    0u              /* none: an external driver on the BDI */
#define BLNS_DIF_DBI_SPI                1u              /* MIPI-DBI over SPI */
#define BLNS_DIF_DBI_PAR                2u              /* MIPI-DBI over the 8080-16 bus */
#define BLNS_DIF_DBI_PAR_SPI            3u              /* MIPI-DBI over both buses */
#define BLNS_DIF_DPI                    4u              /* MIPI-DPI (parallel RGB) */
#define BLNS_DIF_HDMI                   5u              /* MIPI-DPI and the TMDS encoder (DVI, or HDMI with data islands) */

/* CFG2: the GPU (0 without one; [31:13] read 0) */
#define BLNS_CFG2_FIFO_AW_Pos           0u              /* command FIFO: 2^FIFO_AW words */
#define BLNS_CFG2_FIFO_AW_Msk           BLNS_FIELD(0u, 4u)
#define BLNS_CFG2_XY_Msk                (1u << 4)       /* x/y coordinates, clip window, affine blits */
#define BLNS_CFG2_GRAD_Msk              (1u << 5)       /* gradient fills (SET_GRAD, SET_GRAD_RGB) */
#define BLNS_CFG2_BLEND_Msk             (1u << 6)       /* blending at 16 bpp, EXPAND masks */
#define BLNS_CFG2_TRI_Msk               (1u << 7)       /* triangles */
#define BLNS_CFG2_REMAP_Msk             (1u << 8)       /* palette remap */
#define BLNS_CFG2_MPLANE_Msk            (1u << 9)       /* mask plane on copies */
#define BLNS_CFG2_IMM_Msk               (1u << 10)      /* immediate source */
#define BLNS_CFG2_LINE_Pos              11u
#define BLNS_CFG2_LINE_Msk              (1u << 11)      /* lines (anti-aliased with BLEND) */
#define BLNS_CFG2_BILINEAR_Msk          (1u << 12)      /* bilinear texture sampling (SET_AUX TEX_FILTER; only with XY) */

/* CTRL */
#define BLNS_CTRL_GFX_MODE_Pos          0u
#define BLNS_CTRL_GFX_MODE_Msk          BLNS_FIELD(0u, 3u)
#define BLNS_CTRL_GPU_EN_Msk            (1u << 4)

/* STATUS */
#define BLNS_STATUS_REFRESH_ACTIVE_Msk  (1u << 0)
#define BLNS_STATUS_GPU_BUSY_Msk        (1u << 1)
#define BLNS_STATUS_GPU_ERR_Msk         (1u << 2)
#define BLNS_STATUS_DIF_BUSY_Msk        (1u << 3)
#define BLNS_STATUS_REFR_ABANDONED_Msk  (1u << 4)

/* IRQ_EN / IRQ_FLAG */
#define BLNS_IRQ_REFR_DONE_Msk          (1u << 0)
#define BLNS_IRQ_REFR_START_Msk         (1u << 1)
#define BLNS_IRQ_FRAME_CNT_DONE_Msk     (1u << 2)
#define BLNS_IRQ_GPU_DONE_Msk           (1u << 4)
#define BLNS_IRQ_GPU_IDLE_Msk           (1u << 5)
#define BLNS_IRQ_GPU_OVFL_Msk           (1u << 6)
#define BLNS_IRQ_GPU_ERR_Msk            (1u << 7)
#define BLNS_IRQ_DIF_Msk                (1u << 8)
#define BLNS_IRQ_GPU_FENCE_Msk          (1u << 9)
#define BLNS_IRQ_GPU_FIFO_LOW_Msk       (1u << 10)      /* FREE rose above GPU.FIFO_LOW */
/* The write-1-to-clear flags (0x6F7): bit 3 is reserved, DIF [8] is a level */
#define BLNS_IRQ_W1C_Msk                (BLNS_IRQ_REFR_DONE_Msk | BLNS_IRQ_REFR_START_Msk | BLNS_IRQ_FRAME_CNT_DONE_Msk | \
                                         BLNS_IRQ_GPU_DONE_Msk  | BLNS_IRQ_GPU_IDLE_Msk   | BLNS_IRQ_GPU_OVFL_Msk       | \
                                         BLNS_IRQ_GPU_ERR_Msk   | BLNS_IRQ_GPU_FENCE_Msk  | BLNS_IRQ_GPU_FIFO_LOW_Msk)

/* DISP_SIZE */
#define BLNS_DISP_SIZE_WIDTH_Pos        0u
#define BLNS_DISP_SIZE_WIDTH_Msk        BLNS_FIELD(0u, 16u)
#define BLNS_DISP_SIZE_HEIGHT_Pos       16u
#define BLNS_DISP_SIZE_HEIGHT_Msk       BLNS_FIELD(16u, 16u)

/* Swap fields, shared by DISP_CFG and the GPU EXEC words */
#define BLNS_SWAP_CL_Msk                (1u << 0)
#define BLNS_SWAP_Y_Msk                 (1u << 1)
#define BLNS_SWAP_X_Msk                 (1u << 2)
#define BLNS_DISP_CFG_PIX_DOUBLE_Msk    (1u << 4)

/* FRAME_CNT: frame countdown */
#define BLNS_FRAME_CNT_Msk              BLNS_FIELD(0u, 16u)

/* REFRESH */
#define BLNS_REFRESH_START_Msk          (1u << 0)
#define BLNS_REFRESH_PERIOD_Pos         4u
#define BLNS_REFRESH_PERIOD_Msk         BLNS_FIELD(4u, 28u)

/* FRAME_SEL */
#define BLNS_FRAME_SEL_REFR_Pos         0u
#define BLNS_FRAME_SEL_REFR_Msk         BLNS_FIELD(0u, 2u)
#define BLNS_FRAME_SEL_LATCHED_Pos      4u              /* RO: the index the refresh took for the frame */
#define BLNS_FRAME_SEL_LATCHED_Msk      BLNS_FIELD(4u, 2u)  /* in progress */

/* FRAME_NUM */
#define BLNS_FRAME_NUM_Msk              BLNS_FIELD(0u, 16u)

/* REFR_PITCH: the refresh's line pitch in source pixels, 0 = the frame width */
#define BLNS_REFR_PITCH_Msk             BLNS_FIELD(0u, 16u)

/* DBG_CTRL */
#define BLNS_DBG_CTRL_FREEZE_REFRESH_Msk (1u << 0)
#define BLNS_DBG_CTRL_FREEZE_GPU_Msk    (1u << 1)

/* LUT_CFG */
#define BLNS_LUT_CFG_SW_LUT_EN_Msk      (1u << 0)
#define BLNS_LUT_CFG_REFR_BANK_Msk      (1u << 1)
#define BLNS_LUT_CFG_HW_PALETTE_Pos     4u
#define BLNS_LUT_CFG_HW_PALETTE_Msk     BLNS_FIELD(4u, 3u)
#define BLNS_LUT_CFG_HW_BG_Pos          8u
#define BLNS_LUT_CFG_HW_BG_Msk          BLNS_FIELD(8u, 4u)
#define BLNS_LUT_CFG_HW_FG_Pos          12u
#define BLNS_LUT_CFG_HW_FG_Msk          BLNS_FIELD(12u, 4u)

#define BLNS_LUT_ROT_FIRST_Pos          0u
#define BLNS_LUT_ROT_FIRST_Msk          BLNS_FIELD(0u, 8u)
#define BLNS_LUT_ROT_LAST_Pos           8u
#define BLNS_LUT_ROT_LAST_Msk           BLNS_FIELD(8u, 8u)
#define BLNS_LUT_ROT_OFFSET_Pos         16u
#define BLNS_LUT_ROT_OFFSET_Msk         BLNS_FIELD(16u, 8u)

/* Hardware cursor: CURSOR_CTRL, CURSOR_POS (signed source-frame pixel of the
 * hotspot), CURSOR_ADDR (word address of a 128-word shape block), CURSOR_COL[n]
 * (RGB888, the LUT entry format) */
#define BLNS_CURSOR_CTRL_EN_Msk         (1u << 0)
#define BLNS_CURSOR_CTRL_HOT_X_Pos      8u
#define BLNS_CURSOR_CTRL_HOT_X_Msk      BLNS_FIELD(8u, 5u)
#define BLNS_CURSOR_CTRL_HOT_Y_Pos      16u
#define BLNS_CURSOR_CTRL_HOT_Y_Msk      BLNS_FIELD(16u, 5u)
#define BLNS_CURSOR_POS_X_Pos           0u
#define BLNS_CURSOR_POS_X_Msk           BLNS_FIELD(0u, 16u)
#define BLNS_CURSOR_POS_Y_Pos           16u
#define BLNS_CURSOR_POS_Y_Msk           BLNS_FIELD(16u, 16u)
#define BLNS_CURSOR_ADDR_Pos            7u              /* [VRAM_AW-1:7]: a 128-word block */
#define BLNS_CURSOR_ADDR_Msk            BLNS_FIELD(7u, 17u)
#define BLNS_CURSOR_ADDR_ALIGN          128u            /* words: [6:0] read 0 */

/* LUT entries (LUT[bank][i]): RGB888, [31:24] read 0 */
#define BLNS_LUT_R_Pos                  16u
#define BLNS_LUT_R_Msk                  BLNS_FIELD(16u, 8u)
#define BLNS_LUT_G_Pos                  8u
#define BLNS_LUT_G_Msk                  BLNS_FIELD(8u, 8u)
#define BLNS_LUT_B_Pos                  0u
#define BLNS_LUT_B_Msk                  BLNS_FIELD(0u, 8u)

/* GPU STAT */
#define BLNS_GPU_STAT_FREE_Pos          0u
#define BLNS_GPU_STAT_FREE_Msk          BLNS_FIELD(0u, 8u)
#define BLNS_GPU_STAT_USED_Pos          8u
#define BLNS_GPU_STAT_USED_Msk          BLNS_FIELD(8u, 8u)
#define BLNS_GPU_STAT_EMPTY_Msk         (1u << 16)
#define BLNS_GPU_STAT_FULL_Msk          (1u << 17)
#define BLNS_GPU_STAT_WAIT_Msk          (1u << 18)      /* WAIT_REFR_DONE waiting */
#define BLNS_GPU_STAT_PRIM_BUSY_Msk      (1u << 20)
#define BLNS_GPU_STAT_BUSY_Msk          (1u << 21)
#define BLNS_GPU_STAT_ERR_Msk           (1u << 22)
#define BLNS_GPU_STAT_HELD_Msk          (1u << 23)
#define BLNS_GPU_STAT_LIST_Msk          (1u << 24)
#define BLNS_GPU_STAT_ERR_OPCODE_Pos    28u
#define BLNS_GPU_STAT_ERR_OPCODE_Msk    BLNS_FIELD(28u, 4u)
#define BLNS_GPU_STAT_ERR_CAUSE_Pos     25u             /* BLNS_GPU_ERR_* */
#define BLNS_GPU_STAT_ERR_CAUSE_Msk     BLNS_FIELD(25u, 3u)
#define BLNS_GPU_ERR_INVALID            1u              /* unknown opcode, sub-command or SET_EXT2 code */
#define BLNS_GPU_ERR_ABSENT             2u              /* a command of a feature not built */
#define BLNS_GPU_ERR_FORMAT             3u              /* a source / destination format not supported */
#define BLNS_GPU_ERR_LIST_CUT           4u              /* a list ends between a command and its operand */
#define BLNS_GPU_ERR_BOUNDS             5u              /* a rectangle reached the end of the VRAM */
#define BLNS_GPU_ERR_CALL_BOUNDS        6u              /* a CALL whose list does not fit in the VRAM */

/* GPU CTRL */
#define BLNS_GPU_CTRL_CLEAR_ERR_Msk     (1u << 0)
#define BLNS_GPU_CTRL_ABORT_Msk         (1u << 1)
#define BLNS_GPU_CTRL_DISCARD_Msk       (1u << 2)      /* make a cut stream whole (owner only) */

/* GPU FIFO_LOW: the event when FREE rises above THRESH (a value of the depth
 * or more reads back as the depth: never) */
#define BLNS_GPU_FIFO_LOW_THRESH_Pos    0u
#define BLNS_GPU_FIFO_LOW_THRESH_Msk    BLNS_FIELD(0u, 17u)

/* GPU command words: opcode [31:28] */
#define BLNS_GPU_OP_Pos                 28u
#define BLNS_GPU_OP_SET_SRC             (0x1u << 28)    /* [15:0] pitch, [19:16] SRC_FMT, [20] IMM; operand: base (IMM: N) */
#define BLNS_GPU_OP_SET_DST             (0x2u << 28)    /* [15:0] pitch, [16] XY ([19:17] 0); operand: base */
#define BLNS_GPU_OP_SET_SIZE            (0x3u << 28)    /* [13:0] width, [27:14] height */
#define BLNS_GPU_OP_SET_FILL            (0x4u << 28)    /* operand: colour */
#define BLNS_GPU_OP_SET_TRANSP          (0x5u << 28)    /* operand: colour */
#define BLNS_GPU_OP_EXEC_FILL           (0x8u << 28)
#define BLNS_GPU_OP_EXEC_COPY           (0x9u << 28)
#define BLNS_GPU_OP_EXEC_COPY_TRANSP    (0xAu << 28)
#define BLNS_GPU_OP_EXEC_SPAN           (0xBu << 28)    /* [27:14] delta, [13:0] width */
#define BLNS_GPU_OP_EXEC_EXPAND         (0xCu << 28)    /* [27:14] delta, [13:12] remap, [11:8] rop, [6:4] dst swaps, [3] mask, [2] opaque */
#define BLNS_GPU_OP_SET_EXT             (0x6u << 28)    /* [27:24] sub-command */
#define BLNS_GPU_OP_CALL                (0x7u << 28)    /* [23:0] N words; operand: list word address */
#define BLNS_GPU_CALL_N_MAX             0xFFFFFFu
#define BLNS_GPU_OP_EXEC_TEXSPAN        (0xDu << 28)    /* [27:14] delta, [13:0] N */
#define BLNS_GPU_OP_EXEC_TEXRECT        (0xEu << 28)    /* [27:14] delta; SET_SIZE W x H */
#define BLNS_GPU_DST_XY_Msk             (1u << 16)      /* SET_DST: x/y mode, operand = origin */
#define BLNS_GPU_EXT_TEX                (0x0u << 24)    /* SET_TEX, no operand */
#define BLNS_GPU_EXT_UV                 (0x1u << 24)    /* SET_UV, operand {u0, v0} 10.6 */
#define BLNS_GPU_EXT_STEP               (0x2u << 24)    /* SET_STEP, operand {du, dv} signed 5.11 */
#define BLNS_GPU_EXT_XY                 (0x3u << 24)    /* SET_XY [11:0] x, [23:12] y, signed */
#define BLNS_GPU_EXT_CLIP               (0x4u << 24)    /* SET_CLIP {y0, x0}, operand {y1, x1}, inclusive */
#define BLNS_GPU_EXT_STEP_ROW           (0x5u << 24)    /* SET_STEP_ROW, operand {du', dv'} signed 5.11 */
#define BLNS_GPU_EXT_TEXBOX             (0x6u << 24)    /* SET_TEXBOX [11:0] TW, [23:12] TH */
#define BLNS_GPU_EXT_GRAD               (0x7u << 24)    /* SET_GRAD [11:0] N, [12] AXIS, [16:13] STEP, [17] EN, [18] RGB */
#define BLNS_GPU_XY(x, y)               ((((uint32_t) (y) & 0xFFFu) << 12) | ((uint32_t) (x) & 0xFFFu))
#define BLNS_GPU_XY_X_Pos               0u              /* SET_XY, SET_CLIP word and operand: signed x */
#define BLNS_GPU_XY_X_Msk               BLNS_FIELD(0u, 12u)
#define BLNS_GPU_XY_Y_Pos               12u             /* ... signed y */
#define BLNS_GPU_XY_Y_Msk               BLNS_FIELD(12u, 12u)
#define BLNS_GPU_XY_MIN                 (-2048)
#define BLNS_GPU_XY_MAX                 2047
#define BLNS_GPU_GRAD_N_Pos             0u
#define BLNS_GPU_GRAD_N_Msk             BLNS_FIELD(0u, 12u)
#define BLNS_GPU_GRAD_AXIS_Msk          (1u << 12)
#define BLNS_GPU_GRAD_STEP_Pos          13u
#define BLNS_GPU_GRAD_STEP_Msk          BLNS_FIELD(13u, 4u)    /* signed */
#define BLNS_GPU_GRAD_EN_Msk            (1u << 17)
#define BLNS_GPU_GRAD_RGB_Msk           (1u << 18)      /* 16 bpp: per channel, the SET_GRAD_RGB steps */
#define BLNS_GPU_EXT_GRAD_RGB           (0xCu << 24)    /* SET_GRAD_RGB, operand [29:20] dR, [19:10] dG, [9:0] dB (1/64) */
#define BLNS_GPU_EXT_ALPHA              (0x8u << 24)    /* SET_ALPHA [7:0] A, [8] EN, [9] MIX5 (16 bpp) */
#define BLNS_GPU_ALPHA_EN_Msk           (1u << 8)
#define BLNS_GPU_ALPHA_MIX5_Msk         (1u << 9)       /* LVGL's blend rule (5-bit factor, truncated) for every blend */
#define BLNS_GPU_EXT_V0                 (0x9u << 24)    /* SET_V0..V2, operand {y, x} signed 12.4 */
#define BLNS_GPU_EXT_V1                 (0xAu << 24)
#define BLNS_GPU_EXT_V2                 (0xBu << 24)
#define BLNS_GPU_EXEC_TRI_Msk           (1u << 7)       /* EXEC_FILL / EXEC_TEXRECT: the triangle of V0..V2 */
#define BLNS_GPU_EXT_AUX                (0xDu << 24)    /* SET_AUX [23:20] SEL; operand (always, whatever SEL) */
#define BLNS_GPU_AUX_SEL_Pos            20u
#define BLNS_GPU_AUX_SEL_Msk            BLNS_FIELD(20u, 4u)
#define BLNS_GPU_AUX_REMAP_TABLE        (0x0u << 20)    /* operand: table word address, multiple of 64 */
#define BLNS_GPU_AUX_MASK_PLANE         (0x1u << 20)    /* [15:0] PITCH 0, [16] INV; operand: 1-bpp mask pixel address */
#define BLNS_GPU_AUX_INV_Msk            (1u << 16)      /* MASK_PLANE: drawn where the mask bit is 0 */
#define BLNS_GPU_AUX_LINE_PEN           (0x2u << 20)    /* operand: the line pen {y, x} signed 12.4 */
#define BLNS_GPU_AUX_LINE_PATTERN       (0x3u << 20)    /* [4:0] LEN - 1, the phase to 0; operand: pattern (bit i = phase i) */
#define BLNS_GPU_AUX_LEN_Pos            0u
#define BLNS_GPU_AUX_LEN_Msk            BLNS_FIELD(0u, 5u)
#define BLNS_GPU_AUX_ALPHA_PLANE        (0x4u << 20)    /* [15:0] PITCH 0; operand: byte address of the alpha of the SET_SRC base pixel (BLEND) */
#define BLNS_GPU_AUX_TEX_FILTER         (0x5u << 20)    /* [0] BILINEAR, [1] TBORDER (BLEND); operand ignored (write 0) */
#define BLNS_GPU_AUX_BILINEAR_Msk       (1u << 0)       /* TEX_FILTER: bilinear sampling (TEXSPAN, TEXRECT, textured TRI; 16 bpp) */
#define BLNS_GPU_AUX_TBORDER_Msk        (1u << 1)       /* ... with BOUND: taps outside the box transparent (else clamped) */
#define BLNS_GPU_LINE_LEN_MAX           32u
#define BLNS_GPU_EXEC_LINE_Msk          (1u << 24)      /* EXEC_FILL: a line from the pen; operand: end point {y, x} 12.4 */
#define BLNS_GPU_LINE_AA_Msk            (1u << 16)      /* EXEC_FILL LINE: anti-aliased (16 bpp, BLEND) */
#define BLNS_GPU_LINE_NO_LAST_Msk       (1u << 17)      /* ... the last step not drawn */
#define BLNS_GPU_LINE_OPAQUE_Msk        (1u << 18)      /* ... pattern gaps in the SET_TRANSP colour */
#define BLNS_GPU_LINE_PH_RST_Msk        (1u << 19)      /* ... the pattern phase to 0 first */
#define BLNS_GPU_REMAP_TABLE_ALIGN      64u             /* table word address alignment (256 bytes) */
#define BLNS_GPU_EXEC_REMAP_Pos         12u             /* EXEC_FILL / COPY / COPY_TRANSP / EXPAND: 0 off, 1 SRC, 2 DST */
#define BLNS_GPU_EXEC_REMAP_Msk         BLNS_FIELD(12u, 2u)
#define BLNS_GPU_EXEC_MPLANE_Msk        (1u << 11)      /* EXEC_COPY / COPY_TRANSP: the mask plane gates the pixels */
#define BLNS_GPU_TEX_L2W_Pos            0u
#define BLNS_GPU_TEX_L2H_Pos            4u
#define BLNS_GPU_TEX_L2_MAX             10u             /* log2 width / height: 0-10 */
#define BLNS_GPU_TEXBOX_MAX             512u            /* SET_TEXBOX TW / TH with BOUND */
#define BLNS_GPU_TEX_TRANSP_Msk         (1u << 8)
#define BLNS_GPU_TEX_SWAP_Pos           9u              /* BLNS_SWAP_* << 9 */
#define BLNS_GPU_TEX_FREE_PITCH_Msk     (1u << 12)
#define BLNS_GPU_TEX_BOUND_Msk          (1u << 13)
#define BLNS_GPU_TEX_SHADE_Pos          16u
#define BLNS_GPU_TEX_SHADE_Msk          BLNS_FIELD(16u, 8u)
#define BLNS_GPU_TEX_REMAP_Pos          14u             /* TEXSPAN / TEXRECT remap: 0 off, 1 SRC, 2 DST */
#define BLNS_GPU_TEX_REMAP_Msk          BLNS_FIELD(14u, 2u)
#define BLNS_GPU_OP_FENCE               (0xFu << 28)    /* [23:0] TAG, [24] IRQ */
#define BLNS_GPU_PITCH_Msk              BLNS_FIELD(0u, 16u)
#define BLNS_GPU_SIZE_W_Pos             0u
#define BLNS_GPU_SIZE_W_Msk             BLNS_FIELD(0u, 14u)
#define BLNS_GPU_SIZE_H_Pos             14u
#define BLNS_GPU_SIZE_H_Msk             BLNS_FIELD(14u, 14u)

#define BLNS_GPU_SPAN_W_Pos             0u
#define BLNS_GPU_SPAN_W_Msk             BLNS_FIELD(0u, 14u)
#define BLNS_GPU_SPAN_DELTA_Pos         14u
#define BLNS_GPU_SPAN_DELTA_Msk         BLNS_FIELD(14u, 14u)
#define BLNS_GPU_SPAN_DELTA_MIN         (-8192)
#define BLNS_GPU_SPAN_DELTA_MAX         8191

#define BLNS_GPU_SRC_FMT_Pos            16u             /* SET_SRC: BLNS_FMT_* */
#define BLNS_GPU_SRC_FMT_Msk            BLNS_FIELD(16u, 4u)
#define BLNS_GPU_SRC_IMM_Msk            (1u << 20)      /* immediate source (BLNS_CFG2_IMM): the next COPY / */
                                                        /* COPY_TRANSP / EXPAND reads the N words pushed after it */
#define BLNS_GPU_IMM_N_Msk              BLNS_FIELD(0u, 24u)  /* SET_SRC IMM operand: N */
#define BLNS_FMT_DST                    0u              /* source format = the destination's */
#define BLNS_FMT_1BPP                   1u              /* 1 / 2 / 4 / 8 bpp values (EXPAND) */
#define BLNS_FMT_2BPP                   2u
#define BLNS_FMT_4BPP                   3u
#define BLNS_FMT_8BPP                   4u
#define BLNS_FMT_RGB565A8               5u              /* RGB565 pixels, the alpha from SET_AUX ALPHA_PLANE (copies,
                                                         * textures; BLEND); 6-15 reserved */
#define BLNS_GPU_EXT_EXT2               (0xFu << 24)    /* SET_EXT2: [23:16] code, [15:0] immediate */
#define BLNS_GPU_EXT2_WAIT_REFR         (0x01u << 16)   /* the next commands wait for the end of a frame */
#define BLNS_GPU_EXT2_RESET_STATE       (0x02u << 16)   /* every setting back to its reset value */
#define BLNS_GPU_EXP_OPAQUE_Msk         (1u << 2)
#define BLNS_GPU_EXP_MASK_Msk           (1u << 3)      /* 16 bpp: the source is a coverage alpha */
#define BLNS_GPU_EXP_ROP_Pos            8u             /* [11:8] raster op on the expanded colour */
#define BLNS_GPU_EXP_ROP_Msk            BLNS_FIELD(8u, 4u)
#define BLNS_GPU_EXEC_ROP_Pos           0u
#define BLNS_GPU_EXEC_ROP_Msk           BLNS_FIELD(0u, 4u)
#define BLNS_GPU_EXEC_DST_SWAP_Pos      4u              /* BLNS_SWAP_* << 4 */
#define BLNS_GPU_EXEC_DST_SWAP_Msk      BLNS_FIELD(4u, 3u)
#define BLNS_GPU_EXEC_SRC_SWAP_Pos      8u              /* BLNS_SWAP_* << 8 */
#define BLNS_GPU_EXEC_SRC_SWAP_Msk      BLNS_FIELD(8u, 3u)
#define BLNS_GPU_FENCE_TAG_Msk          BLNS_FIELD(0u, 24u)
#define BLNS_GPU_FENCE_IRQ_Msk          (1u << 24)
#define BLNS_GPU_FENCE_AUTO_Msk         (1u << 25)      /* GPU_FENCE + 1, the tag ignored */

/* DIF_CFG */
#define BLNS_DIF_CFG_LCD_ON_Msk         (1u << 0)
#define BLNS_DIF_CFG_LCD_RESET_Msk      (1u << 1)
#define BLNS_DIF_CFG_PHY_SPI_Msk        (1u << 2)
#define BLNS_DIF_CFG_RD_DIV_Pos         4u              /* 8080 read strobe, 0 = CLK_DIV */
#define BLNS_DIF_CFG_RD_DIV_Msk         BLNS_FIELD(4u, 4u)
#define BLNS_DIF_CFG_CLK_DIV_Pos        8u
#define BLNS_DIF_CFG_CLK_DIV_Msk        BLNS_FIELD(8u, 4u)
#define BLNS_DIF_CFG_HW_WINDOW_Msk      (1u << 12)

/* DIF_SYNC */
#define BLNS_DIF_SYNC_SCANLINE_Pos      0u
#define BLNS_DIF_SYNC_SCANLINE_Msk      BLNS_FIELD(0u, 10u)
#define BLNS_DIF_SYNC_SCAN_EN_Msk       (1u << 15)
#define BLNS_DIF_SYNC_TE_EN_Msk         (1u << 16)

/* DIF_CMD */
#define BLNS_DIF_CMD_CMD_Pos            0u
#define BLNS_DIF_CMD_CMD_Msk            BLNS_FIELD(0u, 8u)
#define BLNS_DIF_CMD_NPARAM_Pos         8u
#define BLNS_DIF_CMD_NPARAM_Msk         BLNS_FIELD(8u, 8u)

/* DIF_STATUS */
#define BLNS_DIF_STATUS_BUSY_Msk        (1u << 0)
#define BLNS_DIF_STATUS_CMD_PENDING_Msk (1u << 1)
#define BLNS_DIF_STATUS_PARAM_FULL_Msk  (1u << 2)
#define BLNS_DIF_STATUS_REFRESH_BUSY_Msk (1u << 3)
#define BLNS_DIF_STATUS_WAIT_SYNC_Msk   (1u << 4)
#define BLNS_DIF_STATUS_DFILL_BUSY_Msk  (1u << 5)
#define BLNS_DIF_STATUS_DFILL_PEND_Msk  (1u << 6)
#define BLNS_DIF_STATUS_PARAM_OVFL_Msk  (1u << 7)   /* W1C: a DIF_PARAM write to a full FIFO was dropped */
#define BLNS_DIF_STATUS_PARAM_LEVEL_Pos 8u
#define BLNS_DIF_STATUS_PARAM_LEVEL_Msk BLNS_FIELD(8u, 5u)

/* DIF_IRQ_EN / DIF_IRQ_FLAG */
#define BLNS_DIF_IRQ_CMD_DONE_Msk       (1u << 0)
#define BLNS_DIF_IRQ_TE_Msk             (1u << 1)
#define BLNS_DIF_IRQ_CMD_OVFL_Msk       (1u << 2)

/* DPI driver: DIF_CFG */
#define BLNS_DPI_CFG_LCD_ON_Msk         (1u << 0)
#define BLNS_DPI_CFG_LCD_RESET_Msk      (1u << 1)
#define BLNS_DPI_CFG_EN_Msk             (1u << 3)
#define BLNS_DPI_CFG_CLK_DIV_Pos        8u
#define BLNS_DPI_CFG_CLK_DIV_Msk        BLNS_FIELD(8u, 4u)
#define BLNS_DPI_CFG_PCLK_EDGE_Msk      (1u << 16)
#define BLNS_DPI_CFG_HS_POL_Msk         (1u << 17)
#define BLNS_DPI_CFG_VS_POL_Msk         (1u << 18)
#define BLNS_DPI_CFG_DE_POL_Msk         (1u << 19)
#define BLNS_DPI_CFG_BGR_Msk            (1u << 20)
#define BLNS_DPI_CFG_FILTER_Msk         (1u << 21)

/* DPI driver: DIF_SYNC (13 bits, BLNS_DIF_SYNC_SCANLINE_Msk is the DBI's 10) */
#define BLNS_DPI_SYNC_SCANLINE_Pos      0u
#define BLNS_DPI_SYNC_SCANLINE_Msk      BLNS_FIELD(0u, 13u)

/* DPI driver: DPI_H_ACT / DPI_V_ACT, DPI_H_BLANK / DPI_V_BLANK */
#define BLNS_DPI_ACT_Msk                BLNS_FIELD(0u, 12u)
#define BLNS_DPI_BLANK_FP_Pos           0u              /* front porch */
#define BLNS_DPI_BLANK_FP_Msk           BLNS_FIELD(0u, 10u)
#define BLNS_DPI_BLANK_SYNC_Pos         10u             /* sync width */
#define BLNS_DPI_BLANK_SYNC_Msk         BLNS_FIELD(10u, 10u)
#define BLNS_DPI_BLANK_BP_Pos           20u             /* back porch */
#define BLNS_DPI_BLANK_BP_Msk           BLNS_FIELD(20u, 10u)

/* DPI driver: DPI_IMG_SIZE, DPI_IMG_POS, DPI_SCALE (4.12 steps), DPI_BORDER */
#define BLNS_DPI_IMG_SIZE_W_Pos         0u
#define BLNS_DPI_IMG_SIZE_W_Msk         BLNS_FIELD(0u, 12u)
#define BLNS_DPI_IMG_SIZE_H_Pos         16u
#define BLNS_DPI_IMG_SIZE_H_Msk         BLNS_FIELD(16u, 12u)
#define BLNS_DPI_IMG_POS_X_Pos          0u
#define BLNS_DPI_IMG_POS_X_Msk          BLNS_FIELD(0u, 12u)
#define BLNS_DPI_IMG_POS_Y_Pos          16u
#define BLNS_DPI_IMG_POS_Y_Msk          BLNS_FIELD(16u, 12u)
#define BLNS_DPI_SCALE_X_Pos            0u
#define BLNS_DPI_SCALE_X_Msk            BLNS_FIELD(0u, 16u)
#define BLNS_DPI_SCALE_Y_Pos            16u
#define BLNS_DPI_SCALE_Y_Msk            BLNS_FIELD(16u, 16u)
#define BLNS_DPI_BORDER_Msk             BLNS_FIELD(0u, 24u)

/* DPI driver: DIF_STATUS, DIF_IRQ_EN / DIF_IRQ_FLAG, DPI_CTRL, DPI_CAPS */
#define BLNS_DPI_STATUS_BUSY_Msk        (1u << 0)
#define BLNS_DPI_STATUS_REFRESH_BUSY_Msk (1u << 3)
#define BLNS_DPI_STATUS_VBLANK_Msk      (1u << 7)
#define BLNS_DPI_STATUS_PRESENT_Msk     (1u << 8)
#define BLNS_DPI_STATUS_LINE_Pos        16u
#define BLNS_DPI_STATUS_LINE_Msk        BLNS_FIELD(16u, 13u)
#define BLNS_DPI_IRQ_VBLANK_Msk         (1u << 3)
#define BLNS_DPI_IRQ_LINE_Msk           (1u << 4)
#define BLNS_DPI_IRQ_UNDERFLOW_Msk      (1u << 5)
#define BLNS_DPI_IRQ_DETECT_Msk         (1u << 6)
#define BLNS_DPI_CTRL_UPDATE_Msk        (1u << 0)
#define BLNS_DPI_CTRL_TEST_Msk          (1u << 1)
#define BLNS_DPI_IMG_POS_CENTRE_Msk     (1u << 31)
#define BLNS_DPI_CAPS_LB_AW_Pos         0u
#define BLNS_DPI_CAPS_LB_AW_Msk         BLNS_FIELD(0u, 4u)
#define BLNS_DPI_CAPS_SCALER_Pos        4u
#define BLNS_DPI_CAPS_SCALER_Msk        BLNS_FIELD(4u, 2u)
#define BLNS_DPI_CAPS_PCLK_SEP_Msk      (1u << 6)
#define BLNS_DPI_CAPS_TMDS_Msk          (1u << 7)
#define BLNS_DPI_CAPS_DDC_Msk           (1u << 8)
#define BLNS_DPI_CAPS_ISLAND_Msk        (1u << 9)
#define BLNS_DPI_CAPS_AUDIO_Msk         (1u << 10)
/* DPI_HDMI: HDMI mode (guard bands, data islands), the AVI InfoFrame once per
 * frame, and its fields */
#define BLNS_DPI_HDMI_EN_Msk            (1u << 0)
#define BLNS_DPI_HDMI_AVI_Msk           (1u << 1)
#define BLNS_DPI_HDMI_AUD_Msk           (1u << 2)
#define BLNS_DPI_HDMI_GP_Msk            (1u << 3)
#define BLNS_DPI_HDMI_PICTURE_Pos       4u
#define BLNS_DPI_HDMI_PICTURE_Msk       BLNS_FIELD(4u, 2u)
#define BLNS_DPI_HDMI_QUANT_Pos         6u
#define BLNS_DPI_HDMI_QUANT_Msk         BLNS_FIELD(6u, 2u)
#define BLNS_DPI_HDMI_ACTIVE_Pos        8u
#define BLNS_DPI_HDMI_ACTIVE_Msk        BLNS_FIELD(8u, 4u)
#define BLNS_DPI_HDMI_VIC_Pos           16u
#define BLNS_DPI_HDMI_VIC_Msk           BLNS_FIELD(16u, 7u)
/* DPI_AUD: clock regeneration N, channel-status sampling frequency and word
 * length (IEC 60958-3 bits 24-27 and 32-35), writes ignored while AUD is set
 * and until the pixel domain has stopped audio (read it back); DPI_AUD_STAT:
 * the last CTS measured, a frame lost since audio was enabled, audio on in
 * the pixel domain */
#define BLNS_DPI_AUD_N_Pos              0u
#define BLNS_DPI_AUD_N_Msk              BLNS_FIELD(0u, 20u)
#define BLNS_DPI_AUD_FS_Pos             24u
#define BLNS_DPI_AUD_FS_Msk             BLNS_FIELD(24u, 4u)
#define BLNS_DPI_AUD_WL_Pos             28u
#define BLNS_DPI_AUD_WL_Msk             BLNS_FIELD(28u, 4u)
#define BLNS_DPI_AUD_STAT_CTS_Pos       0u
#define BLNS_DPI_AUD_STAT_CTS_Msk       BLNS_FIELD(0u, 20u)
#define BLNS_DPI_AUD_STAT_LOST_Msk      (1u << 24)
#define BLNS_DPI_AUD_STAT_ACTIVE_Msk    (1u << 25)
/* DPI_DDC: the pull-downs (1 = line pulled low) and the line levels */
#define BLNS_DPI_DDC_SCL_LOW_Msk        (1u << 0)
#define BLNS_DPI_DDC_SDA_LOW_Msk        (1u << 1)
#define BLNS_DPI_DDC_SCL_IN_Msk         (1u << 8)
#define BLNS_DPI_DDC_SDA_IN_Msk         (1u << 9)

#endif /* BELENOS_REGS_H */
