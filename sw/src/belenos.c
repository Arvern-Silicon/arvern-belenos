/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      belenos.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Controller: identification, mode, frame buffers, refresh, colour LUT,
 * interrupts, debug freeze and VRAM rectangle copies.
 *----------------------------------------------------------------------------*/
#include "blns_priv.h"

/* Supported BLNS_ID major version */
#define BLNS_MAJOR_SUPPORTED  0u

/* Interrupt enable bits that exist */
#define IRQ_ALL_Msk  (BLNS_IRQ_REFR_DONE_Msk | BLNS_IRQ_REFR_START_Msk | BLNS_IRQ_FRAME_CNT_DONE_Msk | \
                      BLNS_IRQ_GPU_DONE_Msk | BLNS_IRQ_GPU_IDLE_Msk | BLNS_IRQ_GPU_OVFL_Msk |           \
                      BLNS_IRQ_GPU_ERR_Msk | BLNS_IRQ_DIF_Msk | BLNS_IRQ_GPU_FENCE_Msk |                \
                      BLNS_IRQ_GPU_FIFO_LOW_Msk)

BLNS_COLD blns_status_t blns_init(blns_t *dev, const blns_config_t *cfg)
{
    if (!dev || !cfg || !cfg->reg_base)
        return BLNS_ERR_PARAM;

    *dev = (blns_t) { 0 };
    dev->regs       = (BLNS_TypeDef *) cfg->reg_base;
    dev->vram       = (volatile uint8_t *) cfg->vram_base;
    dev->hclk_hz    = cfg->hclk_hz;
    dev->wait_hook  = cfg->wait_hook;
    dev->wait_ctx   = cfg->wait_ctx;
    dev->wait_polls = cfg->wait_polls;

    BLNS_TypeDef *r = dev->regs;
    dev->version = r->ID;
    if (FIELD_GET(dev->version, BLNS_ID_MAJOR) != BLNS_MAJOR_SUPPORTED || dev->version == 0u)
        return BLNS_ERR_ID;

    uint32_t c  = r->CFG;
    uint32_t c2 = r->CFG2;                          /* 0 without a GPU */
    blns_caps_t *k = &dev->caps;
    k->vram_words     = r->VRAM_WORDS & BLNS_VRAM_WORDS_Msk;
    k->frame_nr       = (uint8_t) (FIELD_GET(c, BLNS_CFG_FRAME_NR_M1) + 1u);
    k->lut_banks      = (c & BLNS_CFG_LUT_Msk) ? ((c & BLNS_CFG_LUT2_Msk) ? 2u : 1u) : 0u;
    k->dif_type       = (uint8_t) FIELD_GET(c, BLNS_CFG_DIF_TYPE);
    k->dim_w          = (uint8_t) (FIELD_GET(c, BLNS_CFG_DIM_W_M1) + 1u);
    k->priv_check     = (c & BLNS_CFG_PRIV_CHECK_Msk) != 0u;
    k->cursor         = (c & BLNS_CFG_CURSOR_Msk) != 0u;
    k->gpu            = (c & BLNS_CFG_GPU_Msk) != 0u;
    k->gpu_fifo_depth = k->gpu ? (uint16_t) (1u << FIELD_GET(c2, BLNS_CFG2_FIFO_AW)) : 0u;
    k->gpu_xy         = (c2 & BLNS_CFG2_XY_Msk)     != 0u;
    k->gpu_grad       = (c2 & BLNS_CFG2_GRAD_Msk)   != 0u;
    k->gpu_blend      = (c2 & BLNS_CFG2_BLEND_Msk)  != 0u;
    k->gpu_tri        = (c2 & BLNS_CFG2_TRI_Msk)    != 0u;
    k->gpu_remap      = (c2 & BLNS_CFG2_REMAP_Msk)  != 0u;
    k->gpu_mplane     = (c2 & BLNS_CFG2_MPLANE_Msk) != 0u;
    k->gpu_imm        = (c2 & BLNS_CFG2_IMM_Msk)    != 0u;
    k->gpu_line       = (c2 & BLNS_CFG2_LINE_Msk)   != 0u;
    k->gpu_bilinear   = (c2 & BLNS_CFG2_BILINEAR_Msk) != 0u;   /* (reads 1 only with XY) */
    k->size_max       = (uint16_t) ((1u << ((k->dim_w < 14u) ? k->dim_w : 14u)) - 1u);
    k->list_max       = k->gpu ? BLNS_GPU_CALL_N_MAX : 0u;
    if (k->dif_type == BLNS_DIF_DPI || k->dif_type == BLNS_DIF_HDMI) {
        k->dpi_caps   = r->DPI.CAPS;
        k->dpi_scaler = (uint8_t) FIELD_GET(k->dpi_caps, BLNS_DPI_CAPS_SCALER);
        k->dpi_ddc    = (k->dpi_caps & BLNS_DPI_CAPS_DDC_Msk)    != 0u;
        k->dpi_island = (k->dpi_caps & BLNS_DPI_CAPS_ISLAND_Msk) != 0u;
        k->dpi_audio  = (k->dpi_caps & BLNS_DPI_CAPS_AUDIO_Msk)  != 0u;
    }

    /* The features the platform header states (belenos_hw.h) must be the
     * hardware's: a firmware built for another bitstream stops here, before
     * anything is written */
#define HW_MATCH(F)  (BLNS__HW_##F < 0 || (BLNS__HW_##F != 0) == (bool) BLNS__CAP_##F(dev))
    /* the GPU features are CFG2 bits (caps as decoded above): one masked
     * compare with the bits the header states, and their values */
#define HW_C2(F, b)  ((BLNS__HW_##F >= 0) ? (b) : 0u)
#define HW_V2(F, b)  ((BLNS__HW_##F == 1) ? (b) : 0u)
    const uint32_t c2_set = HW_C2(GPU_XY, BLNS_CFG2_XY_Msk) | HW_C2(GPU_GRAD, BLNS_CFG2_GRAD_Msk) |
                            HW_C2(GPU_BLEND, BLNS_CFG2_BLEND_Msk) | HW_C2(GPU_TRI, BLNS_CFG2_TRI_Msk) |
                            HW_C2(GPU_REMAP, BLNS_CFG2_REMAP_Msk) | HW_C2(GPU_MPLANE, BLNS_CFG2_MPLANE_Msk) |
                            HW_C2(GPU_IMM, BLNS_CFG2_IMM_Msk) | HW_C2(GPU_LINE, BLNS_CFG2_LINE_Msk) |
                            HW_C2(GPU_BILINEAR, BLNS_CFG2_BILINEAR_Msk);
    const uint32_t c2_val = HW_V2(GPU_XY, BLNS_CFG2_XY_Msk) | HW_V2(GPU_GRAD, BLNS_CFG2_GRAD_Msk) |
                            HW_V2(GPU_BLEND, BLNS_CFG2_BLEND_Msk) | HW_V2(GPU_TRI, BLNS_CFG2_TRI_Msk) |
                            HW_V2(GPU_REMAP, BLNS_CFG2_REMAP_Msk) | HW_V2(GPU_MPLANE, BLNS_CFG2_MPLANE_Msk) |
                            HW_V2(GPU_IMM, BLNS_CFG2_IMM_Msk) | HW_V2(GPU_LINE, BLNS_CFG2_LINE_Msk) |
                            HW_V2(GPU_BILINEAR, BLNS_CFG2_BILINEAR_Msk);
    if (!HW_MATCH(GPU) || (c2 & c2_set) != c2_val ||
        !HW_MATCH(LUT) || !HW_MATCH(LUT2) || !HW_MATCH(DPI) || !HW_MATCH(DBI) ||
        !HW_MATCH(DPI_DDC) || !HW_MATCH(DPI_ISLAND) || !HW_MATCH(DPI_AUDIO) || !HW_MATCH(CURSOR))
        return BLNS_ERR_CONFIG;
#undef HW_V2
#undef HW_C2
#undef HW_MATCH

    /* Known state: refresh stopped, interrupts off, GPU disabled (flushed),
     * the depth kept; the display size kept (read back below) */
    /* GFX_MODE 5-7 left by a previous program: the hardware decodes bit 2
     * as 16 bpp, and so does the handle (written back as 4) */
    uint32_t m = FIELD_GET(r->CTRL, BLNS_CTRL_GFX_MODE);
    dev->mode  = (m & 4u) ? BLNS_BPP_16 : (blns_mode_t) m;
    r->REFRESH    = 0u;
    r->IRQ_EN     = 0u;
    r->IRQ_FLAG   = BLNS_IRQ_W1C_Msk;
    BLNS_REG_WR(dev, CTRL, (uint32_t) dev->mode << BLNS_CTRL_GFX_MODE_Pos);
    r->DBG_CTRL   = 0u;
    r->DISP_CFG   = 0u;
    r->FRAME_SEL  = 0u;
    r->REFR_PITCH = 0u;
    r->FRAME_PTR[0] = 0u;
    r->LUT_CFG    = 0xFu << BLNS_LUT_CFG_HW_FG_Pos;         /* reset value: FG white */
    r->LUT_ROT    = 0u;
    if (k->cursor) {
        r->CURSOR_CTRL = 0u;
        r->CURSOR_POS  = 0u;
    }

    uint32_t s  = r->DISP_SIZE;
    dev->width  = (uint16_t) FIELD_GET(s, BLNS_DISP_SIZE_WIDTH);
    dev->height = (uint16_t) FIELD_GET(s, BLNS_DISP_SIZE_HEIGHT);
    dev->fence_tag = r->GPU.FENCE & BLNS_GPU_FENCE_TAG_Msk;
    if (k->gpu) {                                           /* GPU_FIFO_LOW: its reset value */
        dev->fifo_thr   = (uint16_t) (k->gpu_fifo_depth / 2u);
        BLNS_REG_WR(dev, GPU.FIFO_LOW, dev->fifo_thr);
    }
    blns__gate(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_set_mode(blns_t *dev, blns_mode_t mode)
{
    if ((unsigned) mode > (unsigned) BLNS_BPP_16)
        return BLNS_ERR_PARAM;
    BLNS_TypeDef *r = dev->regs;
    BLNS_REG_WR(dev, CTRL, (r->CTRL & ~BLNS_CTRL_GFX_MODE_Msk) | ((uint32_t) mode << BLNS_CTRL_GFX_MODE_Pos));
    dev->mode = mode;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_set_size(blns_t *dev, uint16_t width, uint16_t height)
{
    uint32_t max = (1u << dev->caps.dim_w) - 1u;
    if (width == 0u || height == 0u || width > max || height > max)
        return BLNS_ERR_PARAM;
    dev->regs->DISP_SIZE = ((uint32_t) height << BLNS_DISP_SIZE_HEIGHT_Pos) | width;
    dev->width  = width;
    dev->height = height;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_set_orientation(blns_t *dev, uint8_t swap)
{
    if (swap & ~(BLNS_SWAP_CL | BLNS_SWAP_Y | BLNS_SWAP_X))
        return BLNS_ERR_PARAM;
    BLNS_TypeDef *r = dev->regs;
    r->DISP_CFG = (r->DISP_CFG & BLNS_DISP_CFG_PIX_DOUBLE_Msk) | swap;
    return BLNS_OK;
}

BLNS_COLD void blns_set_pix_double(blns_t *dev, bool enable)
{
    BLNS_TypeDef *r = dev->regs;
    dev->pix_double = enable;
    r->DISP_CFG = enable ? (r->DISP_CFG |  BLNS_DISP_CFG_PIX_DOUBLE_Msk)
                         : (r->DISP_CFG & ~BLNS_DISP_CFG_PIX_DOUBLE_Msk);
}

/*---------------------------------------------------------------------------
 * Frame buffers
 *---------------------------------------------------------------------------*/
BLNS_COLD void blns_set_pitch(blns_t *dev, uint16_t pitch)
{
    dev->regs->REFR_PITCH = pitch;
    dev->refr_pitch       = pitch;
}

BLNS_COLD blns_status_t blns_set_frame(blns_t *dev, unsigned n, blns_pa_t addr)
{
    if (n >= dev->caps.frame_nr)
        return BLNS_ERR_PARAM;
    dev->regs->FRAME_PTR[n] = addr;
    return BLNS_OK;
}

blns_status_t blns_select_frame(blns_t *dev, unsigned refresh)
{
    if (refresh >= dev->caps.frame_nr)
        return BLNS_ERR_PARAM;
    dev->regs->FRAME_SEL = refresh << BLNS_FRAME_SEL_REFR_Pos;
    return BLNS_OK;
}

/*---------------------------------------------------------------------------
 * Refresh
 *---------------------------------------------------------------------------*/
BLNS_COLD blns_status_t blns_refresh_period(blns_t *dev, uint32_t cycles)
{
    if (cycles == 0u || cycles > (BLNS_REFRESH_PERIOD_Msk >> BLNS_REFRESH_PERIOD_Pos))
        return BLNS_ERR_PARAM;
    dev->regs->REFRESH = (cycles << BLNS_REFRESH_PERIOD_Pos) | BLNS_REFRESH_START_Msk;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_refresh_rate(blns_t *dev, uint32_t frames_per_second)
{
    if (frames_per_second == 0u || dev->hclk_hz == 0u)
        return BLNS_ERR_PARAM;
    return blns_refresh_period(dev, dev->hclk_hz / frames_per_second);
}

void blns_refresh_stop(blns_t *dev)
{
    dev->regs->REFRESH = 0u;
}

void blns_refresh_once(blns_t *dev)
{
    dev->regs->REFRESH = BLNS_REFRESH_START_Msk;            /* PERIOD = 0: manual */
}

bool blns_refresh_running(const blns_t *dev)
{
    return ((dev->regs->REFRESH & BLNS_REFRESH_START_Msk) != 0u) ||
           ((dev->regs->STATUS  & BLNS_STATUS_REFRESH_ACTIVE_Msk) != 0u);
}

/* Frames reach the panel: the refresh timer runs (DBI, exported BDI), or the
 * DPI driver is enabled (it takes a frame per panel frame without the timer) */
bool blns_frames_flowing(const blns_t *dev)
{
    if (blns_refresh_running(dev))
        return true;
    return BLNS_HAS(dev, DPI) && (dev->regs->DPI.CFG & BLNS_DPI_CFG_EN_Msk) != 0u;
}

blns_status_t blns_wait_frame(blns_t *dev)
{
    return blns_wait_frames(dev, 1u);
}

// n frame ends counted from now (FRAME_NUM): any number of such waits run
// side by side, FRAME_CNT stays the application's, no short gap between two
// frames is missed. IRQ_FLAG (REFR_DONE) is left to the interrupt handler.
// Frames that stop flowing meanwhile (a one-shot refresh done, the refresh
// stopped) end the wait: BLNS_ERR_STATE unless the count was reached.
blns_status_t blns_wait_frames(blns_t *dev, uint16_t n)
{
    const uint16_t n0    = blns_frame_num(dev);
    uint32_t       polls = 0u;
    while ((uint16_t) (blns_frame_num(dev) - n0) < n) {
        if (!blns_frames_flowing(dev))
            return ((uint16_t) (blns_frame_num(dev) - n0) < n) ? BLNS_ERR_STATE : BLNS_OK;
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    }
    return BLNS_OK;
}

blns_status_t blns_flip(blns_t *dev, unsigned show)
{
    blns_status_t st = blns_flip_async(dev, show);
    return (st != BLNS_OK) ? st : blns_flip_wait(dev);
}

blns_status_t blns_flip_wait(blns_t *dev)
{
    uint32_t polls = 0u;
    while (!blns_flip_done(dev) && blns_frames_flowing(dev))     /* else nothing reads the old buffer */
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    return BLNS_OK;
}

blns_status_t blns_flip_async(blns_t *dev, unsigned show)
{
    if (show >= dev->caps.frame_nr)
        return BLNS_ERR_PARAM;
    dev->regs->FRAME_SEL = show << BLNS_FRAME_SEL_REFR_Pos;
    return BLNS_OK;
}

// FRAME_SEL.LATCHED is the index the refresh took for the frame in progress
// (between frames, the one the next frame takes): once it is the one
// selected, no frame reads the buffer shown before
bool blns_flip_done(const blns_t *dev)
{
    uint32_t sel = dev->regs->FRAME_SEL;
    return FIELD_GET(sel, BLNS_FRAME_SEL_LATCHED) == FIELD_GET(sel, BLNS_FRAME_SEL_REFR);
}

#if !BLNS_HW_OFF(LUT)
/*---------------------------------------------------------------------------
 * Colour
 *---------------------------------------------------------------------------*/
BLNS_COLD blns_status_t blns_lut_load(blns_t *dev, unsigned bank, unsigned first,
                            const uint32_t *rgb888, unsigned count)
{
    if (!BLNS_HAS(dev, LUT))
        return BLNS_ERR_ABSENT;
    if (bank >= (BLNS_HAS(dev, LUT2) ? 2u : 1u) || first > 256u || count > 256u - first || (count && !rgb888))
        return BLNS_ERR_PARAM;
    volatile uint32_t *lut = dev->regs->LUT[bank];
    for (unsigned i = 0; i < count; i++)
        lut[first + i] = rgb888[i];
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(LUT)
BLNS_COLD blns_status_t blns_lut_rotate(blns_t *dev, uint8_t first, uint8_t last, uint8_t offset)
{
    if (!BLNS_HAS(dev, LUT))
        return BLNS_ERR_ABSENT;
    dev->regs->LUT_ROT = ((uint32_t) offset << BLNS_LUT_ROT_OFFSET_Pos) |
                         ((uint32_t) last   << BLNS_LUT_ROT_LAST_Pos)   |
                         ((uint32_t) first  << BLNS_LUT_ROT_FIRST_Pos);
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(LUT)
BLNS_COLD blns_status_t blns_lut_select(blns_t *dev, bool enable, unsigned bank)
{
    if (!BLNS_HAS(dev, LUT))
        return enable ? BLNS_ERR_ABSENT : BLNS_OK;
    if (bank >= (BLNS_HAS(dev, LUT2) ? 2u : 1u))
        return BLNS_ERR_PARAM;
    BLNS_TypeDef *r = dev->regs;
    uint32_t v = r->LUT_CFG & ~(BLNS_LUT_CFG_SW_LUT_EN_Msk | BLNS_LUT_CFG_REFR_BANK_Msk);
    if (enable)
        v |= BLNS_LUT_CFG_SW_LUT_EN_Msk;
    if (bank)
        v |= BLNS_LUT_CFG_REFR_BANK_Msk;
    r->LUT_CFG = v;
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(LUT)
// The refresh takes REFR_BANK at a frame start: the bank shown before is free
// once a frame has ended after the select (FRAME_NUM moved)
blns_status_t blns_lut_present(blns_t *dev, const uint32_t *rgb888, unsigned count)
{
    if (!BLNS_HAS(dev, LUT))
        return BLNS_ERR_ABSENT;
    if (count > 256u || (count && !rgb888))
        return BLNS_ERR_PARAM;
    if (!BLNS_HAS(dev, LUT2)) {
        blns_lut_load(dev, 0u, 0u, rgb888, count);
        return blns_lut_select(dev, true, 0u);
    }
    if (dev->lut_pending) {                 /* (no frames flowing: none reads the bank) */
        uint32_t polls = 0u;
        while (blns_frame_num(dev) == dev->lut_frame && blns_frames_flowing(dev))
            if (blns__wait_over(dev, &polls))
                return BLNS_ERR_TIMEOUT;
    }
    const unsigned hidden = (dev->regs->LUT_CFG & BLNS_LUT_CFG_REFR_BANK_Msk) ? 0u : 1u;
    blns_lut_load(dev, hidden, 0u, rgb888, count);
    blns_lut_select(dev, true, hidden);
    dev->lut_frame   = blns_frame_num(dev);
    dev->lut_pending = true;
    return BLNS_OK;
}
#endif

BLNS_COLD blns_status_t blns_hw_palette(blns_t *dev, unsigned palette, unsigned bg, unsigned fg)
{
    if (palette > 7u || bg > 15u || fg > 15u)
        return BLNS_ERR_PARAM;
    BLNS_TypeDef *r = dev->regs;
    uint32_t v = r->LUT_CFG & (BLNS_LUT_CFG_SW_LUT_EN_Msk | BLNS_LUT_CFG_REFR_BANK_Msk);
    v |= (palette << BLNS_LUT_CFG_HW_PALETTE_Pos) | (bg << BLNS_LUT_CFG_HW_BG_Pos) |
         (fg << BLNS_LUT_CFG_HW_FG_Pos);
    r->LUT_CFG = v;
    return BLNS_OK;
}

#if !BLNS_HW_OFF(CURSOR)
/*---------------------------------------------------------------------------
 * Hardware cursor
 *---------------------------------------------------------------------------*/
static bool cursor_block_ok(const blns_t *dev, blns_wa_t block)
{
    return (block % BLNS_CURSOR_ADDR_ALIGN) == 0u && block <= dev->caps.vram_words &&
           dev->caps.vram_words - block >= BLNS_CURSOR_WORDS;
}

static int16_t clamp16(int32_t v)
{
    return (int16_t) ((v < -32768) ? -32768 : (v > 32767) ? 32767 : v);
}

/* floor(v / 2^s) for any sign */
static int32_t floor_shift(int32_t v, unsigned s)
{
    return (v >= 0) ? (v >> s) : -(int32_t) ((((uint32_t) -v) + (1u << s) - 1u) >> s);
}

BLNS_COLD blns_status_t blns_cursor_shape(blns_t *dev, blns_wa_t block, const uint32_t rows[64])
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    if (!rows || !cursor_block_ok(dev, block))
        return BLNS_ERR_PARAM;
    volatile uint32_t *v = blns_vram32(dev) + block;
    for (unsigned j = 0; j < 64u; j++)
        v[j] = rows[j];
    /* the copy by columns: column i at words 64 + 2i, 65 + 2i, its pixel k
     * being pixel i of row k */
    for (unsigned i = 0; i < 32u; i++) {
        uint32_t col[2] = { 0u, 0u };
        for (unsigned k = 0; k < 32u; k++) {
            const uint32_t px = (rows[2u * k + i / 16u] >> (2u * (i % 16u))) & 3u;
            col[k / 16u] |= px << (2u * (k % 16u));
        }
        v[64u + 2u * i]      = col[0];
        v[64u + 2u * i + 1u] = col[1];
    }
    dev->regs->CURSOR_ADDR = block;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_cursor_select(blns_t *dev, blns_wa_t block)
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    if (!cursor_block_ok(dev, block))
        return BLNS_ERR_PARAM;
    dev->regs->CURSOR_ADDR = block;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_cursor_colours(blns_t *dev, uint32_t c1, uint32_t c2, uint32_t c3)
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    BLNS_TypeDef *r = dev->regs;
    r->CURSOR_COL[0] = c1 & 0xFFFFFFu;
    r->CURSOR_COL[1] = c2 & 0xFFFFFFu;
    r->CURSOR_COL[2] = c3 & 0xFFFFFFu;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_cursor_hotspot(blns_t *dev, unsigned hx, unsigned hy)
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    if (hx > 31u || hy > 31u)
        return BLNS_ERR_PARAM;
    BLNS_TypeDef *r = dev->regs;
    r->CURSOR_CTRL = (r->CURSOR_CTRL & BLNS_CURSOR_CTRL_EN_Msk) |
                     (hx << BLNS_CURSOR_CTRL_HOT_X_Pos) | (hy << BLNS_CURSOR_CTRL_HOT_Y_Pos);
    return BLNS_OK;
}

static void cursor_pos(blns_t *dev)
{
    const int16_t x = clamp16((int32_t) dev->crs_x - dev->crs_ox);
    const int16_t y = clamp16((int32_t) dev->crs_y - dev->crs_oy);
    dev->regs->CURSOR_POS = ((uint32_t) (uint16_t) y << BLNS_CURSOR_POS_Y_Pos) | (uint16_t) x;
}

blns_status_t blns_cursor_move(blns_t *dev, int16_t x, int16_t y)
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    dev->crs_x = x;
    dev->crs_y = y;
    cursor_pos(dev);
    return BLNS_OK;
}

blns_status_t blns_cursor_move_panel(blns_t *dev, int px, int py)
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    const BLNS_TypeDef *r = dev->regs;
    const uint32_t swap = r->DISP_CFG & (BLNS_SWAP_CL | BLNS_SWAP_Y | BLNS_SWAP_X);
    int32_t sx = px, sy = py;                       /* pixel and line of the stream */
    if (BLNS_HAS(dev, DPI)) {
        /* the image: its size (0: the frame's, transposed with CL), corner and steps */
        const uint32_t pw = r->DPI.H_ACT & 0xFFFu, ph = r->DPI.V_ACT & 0xFFFu;
        const uint32_t sz = r->DPI.IMG_SIZE, pos = r->DPI.IMG_POS;
        uint32_t iw = sz & BLNS_DPI_IMG_SIZE_W_Msk, ih = (sz & BLNS_DPI_IMG_SIZE_H_Msk) >> BLNS_DPI_IMG_SIZE_H_Pos;
        if (iw == 0u)
            iw = (swap & BLNS_SWAP_CL) ? dev->height : dev->width;
        if (ih == 0u)
            ih = (swap & BLNS_SWAP_CL) ? dev->width : dev->height;
        if (iw > pw)
            iw = pw;
        if (ih > ph)
            ih = ph;
        const bool     centre = (pos & BLNS_DPI_IMG_POS_CENTRE_Msk) != 0u;
        const uint32_t x0 = centre ? (pw - iw) / 2u : (pos & BLNS_DPI_IMG_POS_X_Msk);
        const uint32_t y0 = centre ? (ph - ih) / 2u : (pos & BLNS_DPI_IMG_POS_Y_Msk) >> BLNS_DPI_IMG_POS_Y_Pos;
        const uint32_t sc = r->DPI.SCALE;
        const uint32_t stx = dev->caps.dpi_scaler ? (sc & BLNS_DPI_SCALE_X_Msk) : 0x1000u;
        const uint32_t sty = dev->caps.dpi_scaler ? (sc & BLNS_DPI_SCALE_Y_Msk) >> BLNS_DPI_SCALE_Y_Pos : 0x1000u;
        sx = floor_shift((px - (int32_t) x0) * (int32_t) stx, 12u);
        sy = floor_shift((py - (int32_t) y0) * (int32_t) sty, 12u);
    }
    /* the stream is the frame walked in scan order: back to frame pixels */
    if (dev->pix_double) {
        sx = floor_shift(sx, 1u);
        sy = floor_shift(sy, 1u);
    }
    const int32_t fw = dev->pix_double ? (dev->width + 1) / 2 : dev->width;
    const int32_t fh = dev->pix_double ? (dev->height + 1) / 2 : dev->height;
    const int32_t si = (swap & BLNS_SWAP_CL) ? sy : sx;   /* along x */
    const int32_t sl = (swap & BLNS_SWAP_CL) ? sx : sy;   /* along y */
    const int32_t x  = (swap & BLNS_SWAP_X) ? fw - 1 - si : si;
    const int32_t y  = (swap & BLNS_SWAP_Y) ? fh - 1 - sl : sl;
    return blns_cursor_move(dev, clamp16(x + dev->crs_ox), clamp16(y + dev->crs_oy));
}

blns_status_t blns_cursor_origin(blns_t *dev, int16_t x0, int16_t y0)
{
    if (!BLNS_HAS(dev, CURSOR))
        return BLNS_ERR_ABSENT;
    dev->crs_ox = x0;
    dev->crs_oy = y0;
    cursor_pos(dev);
    return BLNS_OK;
}

blns_status_t blns_cursor_show(blns_t *dev, bool on)
{
    if (!BLNS_HAS(dev, CURSOR))
        return on ? BLNS_ERR_ABSENT : BLNS_OK;
    BLNS_TypeDef *r = dev->regs;
    r->CURSOR_CTRL = (r->CURSOR_CTRL & ~BLNS_CURSOR_CTRL_EN_Msk) | (on ? BLNS_CURSOR_CTRL_EN_Msk : 0u);
    return BLNS_OK;
}
#endif

/*---------------------------------------------------------------------------
 * Interrupts and debug
 *---------------------------------------------------------------------------*/
BLNS_COLD blns_status_t blns_irq_enable(blns_t *dev, uint32_t mask)
{
    if (mask & ~IRQ_ALL_Msk)
        return BLNS_ERR_PARAM;
    dev->regs->IRQ_EN = mask;
    return BLNS_OK;
}

uint32_t blns_irq_status(const blns_t *dev)
{
    return dev->regs->IRQ_FLAG;
}

void blns_irq_clear(blns_t *dev, uint32_t mask)
{
    dev->regs->IRQ_FLAG = mask & BLNS_IRQ_W1C_Msk;
}

uint32_t blns_irq_service(blns_t *dev, uint32_t mask)
{
    const uint32_t f = dev->regs->IRQ_FLAG & mask;
    dev->regs->IRQ_FLAG = f & BLNS_IRQ_W1C_Msk;
    if (f & BLNS_IRQ_GPU_ERR_Msk)
        blns_gpu_recover_request(dev);      /* the owner recovers at its next GPU call */
    return f;
}

void blns_set_nonblocking(blns_t *dev, bool on)
{
    dev->nonblock = on;
}

BLNS_COLD void blns_debug_freeze(blns_t *dev, bool refresh, bool gpu)
{
    dev->regs->DBG_CTRL = (refresh ? BLNS_DBG_CTRL_FREEZE_REFRESH_Msk : 0u) |
                          (gpu     ? BLNS_DBG_CTRL_FREEZE_GPU_Msk     : 0u);
}

/*---------------------------------------------------------------------------
 * VRAM rectangle copies
 *---------------------------------------------------------------------------*/
#if defined(__GNUC__) || defined(__clang__)
typedef uint32_t __attribute__((may_alias)) u32a_t;
typedef uint16_t __attribute__((may_alias)) u16a_t;
#else
typedef uint32_t u32a_t;
typedef uint16_t u16a_t;
#endif

// n bytes, the widest stores the two alignments allow (the window takes byte,
// halfword and word writes)
static void row_copy(volatile uint8_t *d, const uint8_t *s, uint32_t n)
{
    const uintptr_t mis = ((uintptr_t) d ^ (uintptr_t) s);
    if ((mis & 3u) == 0u) {
        if (((uintptr_t) d & 1u) && n) {
            *d++ = *s++;
            n--;
        }
        if (((uintptr_t) d & 2u) && n >= 2u) {
            *(volatile uint16_t *) d = *(const u16a_t *) s;
            d += 2; s += 2; n -= 2u;
        }
        volatile uint32_t *dw = (volatile uint32_t *) d;
        const u32a_t      *sw = (const u32a_t *) s;
        for (; n >= 16u; n -= 16u, dw += 4, sw += 4) {
            const uint32_t a = sw[0], b = sw[1], c = sw[2], e = sw[3];
            dw[0] = a;
            dw[1] = b;
            dw[2] = c;
            dw[3] = e;
        }
        for (; n >= 4u; n -= 4u)
            *dw++ = *sw++;
        d = (volatile uint8_t *) dw;
        s = (const uint8_t *) sw;
    } else if ((mis & 1u) == 0u) {
        if (((uintptr_t) d & 1u) && n) {
            *d++ = *s++;
            n--;
        }
    }
    if ((((uintptr_t) d | (uintptr_t) s) & 1u) == 0u)
        for (; n >= 2u; n -= 2u, d += 2, s += 2)
            *(volatile uint16_t *) d = *(const u16a_t *) s;
    while (n--)
        *d++ = *s++;
}

static void row_read(uint8_t *d, const volatile uint8_t *s, uint32_t n)
{
    if (((((uintptr_t) d | (uintptr_t) s) | n) & 3u) == 0u) {
        u32a_t                  *dw = (u32a_t *) d;
        const volatile uint32_t *sw = (const volatile uint32_t *) s;
        for (; n; n -= 4u)
            *dw++ = *sw++;
        return;
    }
    while (n--)
        *d++ = *s++;
}

// Bytes per pixel of a rectangle (8 and 16 bpp only; 0: a side of 0,
// nothing to copy), its pitch, the CPU buffer given
static blns_status_t rect_geometry(const blns_t *dev, blns_pa_t pa, uint16_t *pitch, uint16_t width,
                                   uint16_t height, const void *buf, uint32_t *bpp)
{
    *bpp = 0u;
    if (dev->mode != BLNS_BPP_8 && dev->mode != BLNS_BPP_16)
        return BLNS_ERR_PARAM;
    if (*pitch == 0u)
        *pitch = blns_display_pitch(dev);
    if (width == 0u || height == 0u)
        return BLNS_OK;
    if (!buf)
        return BLNS_ERR_PARAM;
    *bpp = (dev->mode == BLNS_BPP_16) ? 2u : 1u;
    // in pixels, 32-bit (no 64-bit arithmetic pulled from libgcc)
    const uint32_t vram_px = dev->caps.vram_words * (4u / *bpp);
    const uint32_t span    = (uint32_t) (height - 1u) * *pitch + width;
    if (pa > vram_px || span > vram_px - pa) {
        *bpp = 0u;
        return BLNS_ERR_PARAM;
    }
    return BLNS_OK;
}

blns_status_t blns_vram_write_rect(blns_t *dev, const void *src, uint32_t src_stride, blns_pa_t pa,
                                   uint16_t pitch, uint16_t width, uint16_t height)
{
    uint32_t      bpp;
    blns_status_t st = rect_geometry(dev, pa, &pitch, width, height, src, &bpp);
    if (bpp == 0u)
        return st;
    volatile uint8_t *d = dev->vram + pa * bpp;
    const uint8_t    *s = (const uint8_t *) src;
    for (uint32_t y = 0; y < height; y++, d += (uint32_t) pitch * bpp, s += src_stride)
        row_copy(d, s, width * bpp);
    BLNS_WMB();
    return BLNS_OK;
}

blns_status_t blns_vram_read_rect(const blns_t *dev, blns_pa_t pa, uint16_t pitch, void *dst,
                                  uint32_t dst_stride, uint16_t width, uint16_t height)
{
    uint32_t      bpp;
    blns_status_t st = rect_geometry(dev, pa, &pitch, width, height, dst, &bpp);
    if (bpp == 0u)
        return st;
    const volatile uint8_t *s = dev->vram + pa * bpp;
    uint8_t                *d = (uint8_t *) dst;
    for (uint32_t y = 0; y < height; y++, s += (uint32_t) pitch * bpp, d += dst_stride)
        row_read(d, s, width * bpp);
    return BLNS_OK;
}

/* LV_COLOR_24_TO_16: each field truncated */
void blns_argb8888_to_rgb565a8(uint16_t *rgb, uint8_t *a8, unsigned pitch, const uint32_t *argb,
                               unsigned src_pitch, unsigned w, unsigned h)
{
    for (unsigned y = 0; y < h; y++, rgb += pitch, a8 += pitch, argb += src_pitch)
        for (unsigned x = 0; x < w; x++) {
            const uint32_t c = argb[x];
            rgb[x] = (uint16_t) (((c >> 8) & 0xF800u) | ((c >> 5) & 0x07E0u) | ((c >> 3) & 0x001Fu));
            a8[x]  = (uint8_t) (c >> 24);
        }
    BLNS_WMB();
}
