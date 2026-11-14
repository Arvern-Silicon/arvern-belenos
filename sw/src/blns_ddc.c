/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_ddc.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * HDMI DDC: the I2C master in software on the DPI_DDC lines, the EDID read
 * through it, and the EDID parser (no hardware: always built).
 *----------------------------------------------------------------------------*/
#include "blns_priv.h"

#if !BLNS_HW_OFF(DPI_DDC)
#define DDC_STRETCH_MAX  10000u     /* quarter bit times SCL may be held low */

typedef struct {
    blns_t           *dev;
    void            (*quarter)(void);
} ddc_bus_t;

static void ddc_lines(const ddc_bus_t *b, bool scl, bool sda)
{
    BLNS_REG_WR(b->dev, HDMI.DDC, (scl ? 0u : BLNS_DPI_DDC_SCL_LOW_Msk) | (sda ? 0u : BLNS_DPI_DDC_SDA_LOW_Msk));
}

static bool ddc_sda(const ddc_bus_t *b)
{
    return (BLNS_REG_RD(b->dev, HDMI.DDC) & BLNS_DPI_DDC_SDA_IN_Msk) != 0u;
}

/* Release SCL and wait until it is high (the monitor may stretch it) */
static bool ddc_scl_high(const ddc_bus_t *b, bool sda)
{
    ddc_lines(b, true, sda);
    for (unsigned i = 0; i < DDC_STRETCH_MAX; i++) {
        if (BLNS_REG_RD(b->dev, HDMI.DDC) & BLNS_DPI_DDC_SCL_IN_Msk)
            return true;
        b->quarter();
    }
    return false;
}

/* START, or a repeated START: SDA falls while SCL is high, with the 4.7 us
 * set-up (two quarters at 100 kHz) and 4 us hold of standard mode */
static void ddc_stop(const ddc_bus_t *b);
static int  ddc_bit(const ddc_bus_t *b, bool out);

static bool ddc_start(const ddc_bus_t *b)
{
    ddc_lines(b, false, true);
    b->quarter();
    if (!ddc_scl_high(b, true))
        return false;
    b->quarter(); b->quarter();
    if (!ddc_sda(b)) {
        // SDA held low by a device cut in the middle of a byte it sends (a
        // reset during a read): up to nine clocks with SDA released, until the
        // device lets it go at its ACK slot (I2C bus clear), then a STOP
        for (unsigned i = 0; i < 9u && !ddc_sda(b); i++)
            if (ddc_bit(b, true) < 0)
                return false;
        ddc_stop(b);
        if (!ddc_sda(b) || !ddc_scl_high(b, true))
            return false;
        b->quarter(); b->quarter();
    }
    ddc_lines(b, true, false);
    b->quarter(); b->quarter();
    ddc_lines(b, false, false);
    b->quarter();
    return true;
}

static void ddc_stop(const ddc_bus_t *b)
{
    ddc_lines(b, false, false);
    b->quarter();
    (void) ddc_scl_high(b, false);
    b->quarter(); b->quarter();
    ddc_lines(b, true, true);
    b->quarter(); b->quarter();
}

/* One bit: SDA set while SCL is low, sampled while SCL is high; -1 when SCL
 * stays low */
static int ddc_bit(const ddc_bus_t *b, bool out)
{
    ddc_lines(b, false, out);
    b->quarter();
    if (!ddc_scl_high(b, out))
        return -1;
    b->quarter();
    int in = ddc_sda(b);
    b->quarter();
    ddc_lines(b, false, out);
    b->quarter();
    return in;
}

/* A byte out: true when the device acknowledged it */
static bool ddc_put(const ddc_bus_t *b, uint8_t v)
{
    for (int i = 7; i >= 0; i--)
        if (ddc_bit(b, ((v >> i) & 1u) != 0u) < 0)
            return false;
    return ddc_bit(b, true) == 0;
}

/* A byte in, then ACK (more to come) or NACK; -1 when SCL stays low */
static int ddc_get(const ddc_bus_t *b, bool ack)
{
    unsigned v = 0u;
    for (int i = 0; i < 8; i++) {
        int bit = ddc_bit(b, true);
        if (bit < 0)
            return -1;
        v = (v << 1) | (unsigned) bit;
    }
    return (ddc_bit(b, !ack) < 0) ? -1 : (int) v;
}

BLNS_COLD blns_status_t blns_dpi_ddc_read(blns_t *dev, void (*quarter)(void), uint8_t addr7, uint8_t offset,
                                uint8_t *buf, unsigned n)
{
    if (!BLNS_HAS(dev, DPI_DDC))
        return BLNS_ERR_ABSENT;
    if (quarter == 0 || addr7 > 0x7Fu || (n != 0u && buf == 0))
        return BLNS_ERR_PARAM;
    const ddc_bus_t b = { dev, quarter };
    bool ok = ddc_start(&b) && ddc_put(&b, (uint8_t) (addr7 << 1)) && ddc_put(&b, offset);
    if (ok && n != 0u)                  /* n = 0: the address and offset only (no read phase,
                                         * which a STOP could not end while the device drives
                                         * its first bit) */
        ok = ddc_start(&b) && ddc_put(&b, (uint8_t) ((addr7 << 1) | 1u));
    for (unsigned i = 0; ok && i < n; i++) {
        int v = ddc_get(&b, i + 1u < n);
        if (v < 0)
            ok = false;
        else
            buf[i] = (uint8_t) v;
    }
    ddc_stop(&b);
    return ok ? BLNS_OK : BLNS_ERR_BUS;
}

#endif /* DPI_DDC */

/* The EDID parser needs no hardware: always built */
static bool edid_block_ok(const uint8_t *blk)
{
    uint8_t sum = 0u;
    for (unsigned i = 0; i < BLNS_EDID_BLOCK; i++)
        sum = (uint8_t) (sum + blk[i]);
    return sum == 0u;
}

BLNS_COLD blns_status_t blns_dpi_edid_parse(blns_edid_t *e)
{
    static const uint8_t header[8] = { 0x00u, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0x00u };
    const uint8_t *b = e->raw;
    e->width_mm = e->height_mm = e->aspect_x100 = 0u;
    e->pref_w = e->pref_h = 0u;
    e->pref_pclk_khz = 0u;
    e->quant_select = 0u;
    if (e->blocks == 0u || !edid_block_ok(b))
        return BLNS_ERR_PARAM;
    for (unsigned i = 0; i < 8u; i++)
        if (b[i] != header[i])
            return BLNS_ERR_PARAM;
    if (e->blocks > 1u && !edid_block_ok(b + BLNS_EDID_BLOCK))
        e->blocks = 1u;

    /* The first detailed timing descriptor (bytes 54-71): the preferred mode
     * and the image size in mm */
    const uint8_t *t = b + 54;
    uint32_t pclk = (uint32_t) t[0] | ((uint32_t) t[1] << 8);
    if (pclk != 0u) {
        e->pref_pclk_khz = pclk * 10u;
        e->pref_w    = (uint16_t) (t[2]  | ((t[4]  & 0xF0u) << 4));
        e->pref_h    = (uint16_t) (t[5]  | ((t[7]  & 0xF0u) << 4));
        e->width_mm  = (uint16_t) (t[12] | ((t[14] & 0xF0u) << 4));
        e->height_mm = (uint16_t) (t[13] | ((t[14] & 0x0Fu) << 8));
    }
    /* Else the screen size in cm (bytes 21-22); with one of them zero the
     * other codes the aspect ratio (landscape (b21 + 99) / 100, portrait
     * 100 / (b22 + 99)) */
    if (e->width_mm == 0u || e->height_mm == 0u) {
        e->width_mm = e->height_mm = 0u;
        if (b[21] != 0u && b[22] != 0u) {
            e->width_mm  = (uint16_t) (b[21] * 10u);
            e->height_mm = (uint16_t) (b[22] * 10u);
        } else if (b[21] != 0u) {
            e->aspect_x100 = (uint16_t) (b[21] + 99u);
        } else if (b[22] != 0u) {
            e->aspect_x100 = (uint16_t) (10000u / (b[22] + 99u));
        }
    }
    if (e->width_mm != 0u && e->height_mm != 0u) {
        const uint32_t a = ((uint32_t) e->width_mm * 100u + e->height_mm / 2u) / e->height_mm;
        e->aspect_x100 = (a <= 0xFFFFu) ? (uint16_t) a : 0u;    /* malformed sizes: unknown */
    }

    /* A CTA-861 extension (tag 0x02) in block 1: its data block collection
     * runs from byte 4 to the detailed-timing offset d (byte 2). The Video
     * Capability Data Block (extended tag 7, extended code 0x00) carries QS,
     * bit 6 of its first payload byte. Blocks that overrun d end the walk. */
    if (e->blocks > 1u) {
        const uint8_t *x = b + BLNS_EDID_BLOCK;
        const unsigned d = x[2];
        if (x[0] == 0x02u && d >= 4u && d <= BLNS_EDID_BLOCK - 1u) {
            for (unsigned i = 4u; i < d; ) {
                const unsigned tag = x[i] >> 5, len = x[i] & 0x1Fu;
                if (i + 1u + len > d)
                    break;
                if (tag == 7u && len >= 2u && x[i + 1u] == 0x00u)
                    e->quant_select = (uint8_t) ((x[i + 2u] >> 6) & 1u);
                i += 1u + len;
            }
        }
    }
    return BLNS_OK;
}

#if !BLNS_HW_OFF(DPI_DDC)
BLNS_COLD uint16_t blns__edid_aspect(blns_t *dev, void (*quarter)(void))
{
    blns_edid_t e;
    return (blns_dpi_edid_read(dev, quarter, &e) == BLNS_OK) ? e.aspect_x100 : 0u;
}

BLNS_COLD blns_status_t blns_dpi_edid_read(blns_t *dev, void (*quarter)(void), blns_edid_t *e)
{
    e->blocks = 0u;
    blns_status_t st = blns_dpi_ddc_read(dev, quarter, BLNS_EDID_ADDR, 0u, e->raw, BLNS_EDID_BLOCK);
    if (st != BLNS_OK)
        return st;
    e->blocks = 1u;
    if (e->raw[126] != 0u &&
        blns_dpi_ddc_read(dev, quarter, BLNS_EDID_ADDR, BLNS_EDID_BLOCK, e->raw + BLNS_EDID_BLOCK,
                          BLNS_EDID_BLOCK) == BLNS_OK)
        e->blocks = 2u;
    return blns_dpi_edid_parse(e);
}
#endif
