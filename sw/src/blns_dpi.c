/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_dpi.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Built-in MIPI-DPI driver (DIF_TYPE 4, and 5 = HDMI): panel timing, image placement and
 * scaling, border, test bars, enable; for HDMI, HDMI mode with the AVI InfoFrame,
 * the audio and the other packets (the DDC and the EDID: blns_ddc.c; the
 * hot-plug machine: blns_hotplug.c). The staged registers are taken at the
 * driver's next frame start: every function that writes them requests the
 * update when the driver runs.
 *----------------------------------------------------------------------------*/
#include "blns_priv.h"

#if !BLNS_HW_OFF(DPI)

/* Wait until the staged registers are writable: UPDATE reads 1 exactly while
 * writes to them are ignored (an UPDATE not yet taken, the start after DPI_EN,
 * or the stop after DPI_EN is cleared with an UPDATE pending, until the pixel
 * domain has stopped). At most one panel frame; BLNS_ERR_BUSY at once in
 * non-blocking mode */
static blns_status_t dpi_wait_taken(blns_t *dev)
{
    BLNS_DPI_TypeDef *d     = &dev->regs->DPI;
    uint32_t          polls = 0u;
    while (d->CTRL & BLNS_DPI_CTRL_UPDATE_Msk) {
        if (dev->nonblock)
            return BLNS_ERR_BUSY;
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    }
    return BLNS_OK;
}

/* Ask a running driver to take the staged registers at its next frame start
 * (staged after dpi_wait_taken) */
static void dpi_commit(blns_t *dev)
{
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    if (d->CFG & BLNS_DPI_CFG_EN_Msk)
        d->CTRL = (d->CTRL & BLNS_DPI_CTRL_TEST_Msk) | BLNS_DPI_CTRL_UPDATE_Msk;
}

BLNS_COLD blns_status_t blns_dpi_config(blns_t *dev, const blns_dpi_timing_t *t)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    if (t->clk_div > 15u || t->h_act == 0u || t->h_act > 4095u || t->v_act == 0u || t->v_act > 4095u ||
        t->h_sync == 0u || t->v_sync == 0u || t->h_fp > 1023u || t->h_sync > 1023u || t->h_bp > 1023u ||
        t->v_fp > 1023u || t->v_sync > 1023u || t->v_bp > 1023u)
        return BLNS_ERR_PARAM;
    BLNS_DPI_TypeDef *d  = &dev->regs->DPI;
    blns_status_t     st = dpi_wait_taken(dev);
    if (st != BLNS_OK)
        return st;
    d->H_ACT   = t->h_act;
    d->H_BLANK = (uint32_t) t->h_fp | ((uint32_t) t->h_sync << 10) | ((uint32_t) t->h_bp << 20);
    d->V_ACT   = t->v_act;
    d->V_BLANK = (uint32_t) t->v_fp | ((uint32_t) t->v_sync << 10) | ((uint32_t) t->v_bp << 20);
    uint32_t v = d->CFG & (BLNS_DPI_CFG_LCD_ON_Msk | BLNS_DPI_CFG_LCD_RESET_Msk |
                           BLNS_DPI_CFG_EN_Msk | BLNS_DPI_CFG_FILTER_Msk);
    v |= ((uint32_t) t->clk_div << BLNS_DPI_CFG_CLK_DIV_Pos) |
         ((t->flags & BLNS_DPI_EDGE_FALL) ? BLNS_DPI_CFG_PCLK_EDGE_Msk : 0u) |
         ((t->flags & BLNS_DPI_HS_HIGH)   ? BLNS_DPI_CFG_HS_POL_Msk    : 0u) |
         ((t->flags & BLNS_DPI_VS_HIGH)   ? BLNS_DPI_CFG_VS_POL_Msk    : 0u) |
         ((t->flags & BLNS_DPI_DE_LOW)    ? BLNS_DPI_CFG_DE_POL_Msk    : 0u) |
         ((t->flags & BLNS_DPI_BGR)       ? BLNS_DPI_CFG_BGR_Msk       : 0u);
    d->CFG = v;
    dpi_commit(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dpi_image(blns_t *dev, uint16_t src_w, uint16_t src_h, uint16_t dst_w, uint16_t dst_h)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    const bool scaler = dev->caps.dpi_scaler != 0u;
    if (dst_w > 4095u || dst_h > 4095u || ((dst_w != 0u || dst_h != 0u) && !scaler))
        return BLNS_ERR_PARAM;
    uint32_t sx = (dst_w && src_w) ? ((uint32_t) src_w << 12) / dst_w : 0x1000u;
    uint32_t sy = (dst_h && src_h) ? ((uint32_t) src_h << 12) / dst_h : 0x1000u;
    if (sx > 0xFFFFu || sy > 0xFFFFu)
        return BLNS_ERR_PARAM;
    const uint32_t size  = (uint32_t) dst_w | ((uint32_t) dst_h << 16);
    const uint32_t scale = sx | (sy << 16);
    if (d->IMG_SIZE == size && d->IMG_POS == BLNS_DPI_IMG_POS_CENTRE_Msk && (!scaler || d->SCALE == scale))
        return BLNS_OK;                     /* staged already */
    blns_status_t st = dpi_wait_taken(dev);
    if (st != BLNS_OK)
        return st;
    d->IMG_SIZE = size;
    d->IMG_POS  = BLNS_DPI_IMG_POS_CENTRE_Msk;
    if (scaler)
        d->SCALE = scale;
    dpi_commit(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dpi_fit(blns_t *dev, uint16_t src_w, uint16_t src_h)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    if (src_w == 0u || src_h == 0u)
        return BLNS_ERR_PARAM;
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    uint32_t pw = d->H_ACT & 0xFFFu, ph = d->V_ACT & 0xFFFu;
    if (pw == 0u || ph == 0u)
        return BLNS_ERR_STATE;              /* no timing yet */
    uint32_t w = pw, h = ph;
    if ((uint32_t) src_w * ph > (uint32_t) src_h * pw)
        h = (pw * src_h) / src_w;
    else
        w = (ph * src_w) / src_h;
    if (w == src_w && h == src_h)
        return blns_dpi_image(dev, src_w, src_h, 0u, 0u);
    return blns_dpi_image(dev, src_w, src_h, (uint16_t) w, (uint16_t) h);
}

/* The picture of shape picture_x100 on a display that stretches the signal
 * to display_x100: w / h_act = picture / display, at most the full width
 * (then fewer lines); without a picture shape, the frame's: w = h_act x
 * (src_w / src_h) / display, in that order (the boards' arithmetic) */
BLNS_COLD blns_status_t blns_dpi_image_aspect(blns_t *dev, uint16_t src_w, uint16_t src_h,
                                    uint16_t picture_x100, uint16_t display_x100)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    if (src_w == 0u || src_h == 0u)
        return BLNS_ERR_PARAM;
    BLNS_DPI_TypeDef *d  = &dev->regs->DPI;
    const uint32_t    pw = d->H_ACT & 0xFFFu, ph = d->V_ACT & 0xFFFu;
    if (pw == 0u || ph == 0u)
        return BLNS_ERR_STATE;              /* no timing yet */
    const uint32_t disp = display_x100 ? display_x100 : (pw * 100u) / ph;
    // pw * 100 * src_w fits 32 bits for any frame up to 10488 pixels wide
    // (pw < 4096); wider ones divide first
    const uint32_t p100 = pw * 100u;
    uint32_t       w    = picture_x100 ? (pw * picture_x100) / disp
                        : (src_w <= 0xFFFFFFFFu / p100) ? (p100 * src_w / src_h) / disp
                                                        : (p100 / src_h * src_w) / disp;
    uint32_t       h    = ph;
    if (w > pw) {                           /* wider than the display: fewer lines */
        h = (ph * pw) / w;
        w = pw;
    }
    w &= ~1u;
    if (w == src_w && h == src_h)
        return blns_dpi_image(dev, src_w, src_h, 0u, 0u);
    return blns_dpi_image(dev, src_w, src_h, (uint16_t) w, (uint16_t) h);
}

// Stretching display: its shape from the EDID (else the fallback); not
// stretching: the frame's shape fitted (blns_dpi_fit), or the picture's
BLNS_COLD blns_status_t blns_dpi_picture(blns_t *dev, const blns_picture_t *p, bool *settled)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    if (settled)
        *settled = true;
    if (!p->stretch)
        return p->picture_x100 ? blns_dpi_image_aspect(dev, p->src_w, p->src_h, p->picture_x100, 0u)
                               : blns_dpi_fit(dev, p->src_w, p->src_h);
    const uint16_t a = p->quarter ? blns__edid_aspect(dev, p->quarter) : 0u;
    if (settled)
        *settled = a != 0u;
    return blns_dpi_image_aspect(dev, p->src_w, p->src_h, p->picture_x100, a ? a : p->fallback_x100);
}

BLNS_COLD blns_status_t blns_dpi_border(blns_t *dev, uint32_t rgb888)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    rgb888 &= 0xFFFFFFu;
    if (dev->regs->DPI.BORDER == rgb888)
        return BLNS_OK;                     /* staged already */
    blns_status_t st = dpi_wait_taken(dev);
    if (st != BLNS_OK)
        return st;
    dev->regs->DPI.BORDER = rgb888;
    dpi_commit(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dpi_filter(blns_t *dev, bool bilinear)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    if (bilinear && dev->caps.dpi_scaler != 2u)
        return BLNS_ERR_ABSENT;
    if (((d->CFG & BLNS_DPI_CFG_FILTER_Msk) != 0u) == bilinear)
        return BLNS_OK;
    blns_status_t st = dpi_wait_taken(dev);
    if (st != BLNS_OK)
        return st;
    d->CFG = bilinear ? (d->CFG | BLNS_DPI_CFG_FILTER_Msk) : (d->CFG & ~BLNS_DPI_CFG_FILTER_Msk);
    dpi_commit(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dpi_test(blns_t *dev, bool on)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    if (((d->CTRL & BLNS_DPI_CTRL_TEST_Msk) != 0u) == on)
        return BLNS_OK;
    blns_status_t st = dpi_wait_taken(dev);
    if (st != BLNS_OK)
        return st;
    d->CTRL = on ? BLNS_DPI_CTRL_TEST_Msk : 0u;
    dpi_commit(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dpi_enable(blns_t *dev, bool on)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    uint32_t m = BLNS_DPI_CFG_LCD_ON_Msk | BLNS_DPI_CFG_EN_Msk;
    d->CFG = on ? (d->CFG | m) : (d->CFG & ~m);
    return BLNS_OK;
}

#endif /* DPI */

/*----------------------------------------------------------------------------
 * HDMI mode: the AVI InfoFrame is built by the hardware from DPI_HDMI's fields
 *----------------------------------------------------------------------------*/

#if !BLNS_HW_OFF(DPI_ISLAND)
BLNS_COLD blns_status_t blns_dpi_hdmi(blns_t *dev, const blns_avi_t *avi)
{
    if (!BLNS_HAS(dev, DPI_ISLAND))
        return BLNS_ERR_ABSENT;
    BLNS_DPI_TypeDef  *d = &dev->regs->DPI;
    BLNS_HDMI_TypeDef *h = &dev->regs->HDMI;
    if (avi == 0) {
        h->HDMI = 0u;
        return BLNS_OK;
    }
    if (avi->vic > 127u || avi->picture > 3u || avi->active > 15u || avi->quant > BLNS_AVI_QUANT_FULL)
        return BLNS_ERR_PARAM;

    const uint32_t fields = ((uint32_t) avi->picture << BLNS_DPI_HDMI_PICTURE_Pos) |
                            ((uint32_t) avi->quant   << BLNS_DPI_HDMI_QUANT_Pos)   |
                            ((uint32_t) avi->active  << BLNS_DPI_HDMI_ACTIVE_Pos)  |
                            ((uint32_t) avi->vic     << BLNS_DPI_HDMI_VIC_Pos)     |
                            (h->HDMI & (BLNS_DPI_HDMI_AUD_Msk | BLNS_DPI_HDMI_GP_Msk));
    /* The pixel domain sends a copy of the fields, taken when AVI rises, at
     * an UPDATE and at a start: writes to them are ignored while an UPDATE
     * is pending or the driver is starting (UPDATE reads 1), so wait for
     * that first; with the InfoFrame already on, new fields and an UPDATE */
    blns_status_t st = dpi_wait_taken(dev);
    if (st != BLNS_OK)
        return st;
    if ((h->HDMI & BLNS_DPI_HDMI_AVI_Msk) && (d->CFG & BLNS_DPI_CFG_EN_Msk)) {
        h->HDMI = fields | BLNS_DPI_HDMI_EN_Msk | BLNS_DPI_HDMI_AVI_Msk;
        dpi_commit(dev);
        return BLNS_OK;
    }
    h->HDMI = fields | BLNS_DPI_HDMI_EN_Msk;
    h->HDMI = fields | BLNS_DPI_HDMI_EN_Msk | BLNS_DPI_HDMI_AVI_Msk;
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(DPI_AUDIO)
BLNS_COLD blns_status_t blns_dpi_hdmi_audio(blns_t *dev, const blns_audio_t *a)
{
    if (!BLNS_HAS(dev, DPI_AUDIO))
        return BLNS_ERR_ABSENT;
    BLNS_HDMI_TypeDef *h = &dev->regs->HDMI;
    if (a && ((a->n == 0u) || (a->n & 127u) || (a->n > BLNS_DPI_AUD_N_Msk) || (a->fs > 15u) || (a->wl > 15u)))
        return BLNS_ERR_PARAM;
    /* The pixel domain reads N and the channel status while audio is on
     * there, and the hardware ignores DPI_AUD writes until then: AUD off,
     * then the new values written until they read back */
    h->HDMI = h->HDMI & ~BLNS_DPI_HDMI_AUD_Msk;
    if (a == 0)
        return BLNS_OK;
    const uint32_t aud = (a->n << BLNS_DPI_AUD_N_Pos) | ((uint32_t) a->fs << BLNS_DPI_AUD_FS_Pos) |
                         ((uint32_t) a->wl << BLNS_DPI_AUD_WL_Pos);
    uint32_t polls = 0u;
    for (;;) {
        h->AUD = aud;
        if (h->AUD == aud)
            break;
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;        /* audio stays off */
    }
    h->HDMI = h->HDMI | BLNS_DPI_HDMI_AUD_Msk;
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(DPI_AUDIO)
uint32_t blns_dpi_hdmi_audio_cts(blns_t *dev, bool *lost)
{
    if (!BLNS_HAS(dev, DPI_AUDIO)) {
        if (lost)
            *lost = false;
        return 0u;
    }
    const uint32_t st = dev->regs->HDMI.AUD_STAT;
    if (lost)
        *lost = (st & BLNS_DPI_AUD_STAT_LOST_Msk) != 0u;
    return (st & BLNS_DPI_AUD_STAT_CTS_Msk) >> BLNS_DPI_AUD_STAT_CTS_Pos;
}
#endif

#if !BLNS_HW_OFF(DPI_AUDIO)
BLNS_COLD blns_status_t blns_dpi_hdmi_packet(blns_t *dev, const uint8_t hdr[3], const uint8_t pb[28])
{
    if (!BLNS_HAS(dev, DPI_AUDIO))
        return BLNS_ERR_ABSENT;
    BLNS_DPI_TypeDef  *d = &dev->regs->DPI;
    BLNS_HDMI_TypeDef *h = &dev->regs->HDMI;
    if (hdr == 0 || pb == 0) {
        h->HDMI = h->HDMI & ~BLNS_DPI_HDMI_GP_Msk;
        return BLNS_OK;
    }
    /* The pixel domain reads the registers while GP is set (writes are
     * ignored then): GP clear, seen by the pixel domain by the next frame,
     * the new bytes, GP set */
    if (h->HDMI & BLNS_DPI_HDMI_GP_Msk) {
        h->HDMI = h->HDMI & ~BLNS_DPI_HDMI_GP_Msk;
        if (d->CFG & BLNS_DPI_CFG_EN_Msk) {
            const uint32_t f     = d->FRAMES;
            uint32_t       polls = 0u;
            while (d->FRAMES == f && (d->CFG & BLNS_DPI_CFG_EN_Msk))
                if (blns__wait_over(dev, &polls))
                    return BLNS_ERR_TIMEOUT;    /* the packet stays off */
        }
    }
    h->PKT[0] = (uint32_t) hdr[0] | ((uint32_t) hdr[1] << 8) | ((uint32_t) hdr[2] << 16);
    for (unsigned w = 0; w < 7u; w++)
        h->PKT[1u + w] = (uint32_t) pb[4u*w] | ((uint32_t) pb[4u*w + 1u] << 8) |
                         ((uint32_t) pb[4u*w + 2u] << 16) | ((uint32_t) pb[4u*w + 3u] << 24);
    h->HDMI = h->HDMI | BLNS_DPI_HDMI_GP_Msk;
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(DPI_AUDIO)
BLNS_COLD blns_status_t blns_dpi_hdmi_spd(blns_t *dev, const char *vendor, const char *product, uint8_t source)
{
    /* CTA-861 Source Product Description InfoFrame: type 0x83, version 1,
     * 25 bytes: vendor name (PB1-PB8), product description (PB9-PB24), source
     * information (PB25); PB0 makes the bytes sum to 0 */
    const uint8_t hdr[3] = { 0x83u, 0x01u, 25u };
    uint8_t pb[28] = { 0 };
    for (unsigned i = 0; vendor && i < 8u && vendor[i]; i++)
        pb[1u + i] = (uint8_t) vendor[i];
    for (unsigned i = 0; product && i < 16u && product[i]; i++)
        pb[9u + i] = (uint8_t) product[i];
    pb[25] = source;
    uint8_t sum = (uint8_t) (hdr[0] + hdr[1] + hdr[2]);
    for (unsigned i = 1; i < 28u; i++)
        sum = (uint8_t) (sum + pb[i]);
    pb[0] = (uint8_t) (0u - sum);
    return blns_dpi_hdmi_packet(dev, hdr, pb);
}
#endif

#if !BLNS_HW_OFF(DPI)
/*---------------------------------------------------------------------------
 * Scan position
 *---------------------------------------------------------------------------*/
blns_status_t blns_dpi_image_rows(const blns_t *dev, uint16_t *top, uint16_t *bottom)
{
    if (!BLNS_HAS(dev, DPI))
        return BLNS_ERR_ABSENT;
    const BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    const uint32_t ph  = d->V_ACT & 0xFFFu;
    uint32_t       h   = (d->IMG_SIZE >> 16) & 0xFFFu;
    if (h == 0u)                                        /* 0: the frame size */
        h = (dev->regs->DISP_SIZE >> 16) & 0xFFFFu;
    if (h > ph)
        h = ph;
    const uint32_t pos = d->IMG_POS;
    const uint32_t y0  = (pos & BLNS_DPI_IMG_POS_CENTRE_Msk) ? (ph - h) / 2u : ((pos >> 16) & 0xFFFu);
    *top    = (uint16_t) y0;
    *bottom = (uint16_t) ((y0 + h > ph) ? ph : y0 + h);
    return BLNS_OK;
}

bool blns_dpi_copy_now(const blns_t *dev)
{
    uint16_t top, bot;
    if (blns_dpi_image_rows(dev, &top, &bot) != BLNS_OK)
        return true;
    const uint16_t line = blns_dpi_scan_line(dev);
    return line >= bot || line < top + (bot - top) / 3u;
}

#endif /* DPI */
