/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      ili9341.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * ILI9341 panel driver over the Belenos DBI transport.
 *----------------------------------------------------------------------------*/
#include "ili9341.h"

#define CMD_SLEEP_OUT   0x11u
#define CMD_DISPLAY_OFF 0x28u
#define CMD_DISPLAY_ON  0x29u
#define CMD_CASET       0x2Au
#define CMD_PASET       0x2Bu
#define CMD_MADCTL      0x36u
#define CMD_COLMOD      0x3Au
#define COLMOD_16BPP    0x55u

blns_status_t ili9341_set_window(blns_t *dev, uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1)
{
    const uint8_t col[4] = {(uint8_t) (x0 >> 8), (uint8_t) x0, (uint8_t) (x1 >> 8), (uint8_t) x1};
    const uint8_t row[4] = {(uint8_t) (y0 >> 8), (uint8_t) y0, (uint8_t) (y1 >> 8), (uint8_t) y1};
    blns_status_t st = blns_dbi_cmd(dev, CMD_CASET, col, 4);
    if (st == BLNS_OK)
        st = blns_dbi_cmd(dev, CMD_PASET, row, 4);
    return st;
}

blns_status_t ili9341_display_on(blns_t *dev, bool on)
{
    return blns_dbi_cmd(dev, on ? CMD_DISPLAY_ON : CMD_DISPLAY_OFF, 0, 0);
}

blns_status_t ili9341_init(blns_t *dev, const ili9341_config_t *cfg)
{
    if (!cfg || !cfg->delay_ms)
        return BLNS_ERR_PARAM;
    if (dev->caps.dif_type < BLNS_DIF_DBI_SPI || dev->caps.dif_type > BLNS_DIF_DBI_PAR_SPI)
        return BLNS_ERR_ABSENT;

    /* Power, then a reset pulse; the panel needs 120 ms after reset and after
     * sleep out before the next command. Every DBI status (a wait hook's
     * BLNS_ERR_TIMEOUT included) ends the sequence. */
    blns_status_t st = blns_dbi_power(dev, true);
    if (st == BLNS_OK)
        st = blns_dbi_reset(dev, true);
    if (st != BLNS_OK)
        return st;
    cfg->delay_ms(10);
    st = blns_dbi_reset(dev, false);
    if (st != BLNS_OK)
        return st;
    cfg->delay_ms(120);

    st = blns_dbi_cmd(dev, CMD_SLEEP_OUT, 0, 0);
    if (st == BLNS_OK)
        st = blns_dbi_wait_idle(dev);
    if (st != BLNS_OK)
        return st;
    cfg->delay_ms(120);

    const uint8_t colmod = COLMOD_16BPP;
    const uint8_t madctl = cfg->madctl;
    st = blns_dbi_cmd(dev, CMD_COLMOD, &colmod, 1);
    if (st == BLNS_OK)
        st = blns_dbi_cmd(dev, CMD_MADCTL, &madctl, 1);
    if (st == BLNS_OK && cfg->win_width && cfg->win_height)
        st = ili9341_set_window(dev, 0, 0, (uint16_t) (cfg->win_width - 1u), (uint16_t) (cfg->win_height - 1u));
    if (st == BLNS_OK)
        st = blns_dbi_wait_idle(dev);
    if (st == BLNS_OK && cfg->clear) {
        st = blns_dbi_fill(dev, cfg->clear_rgb888);
        if (st == BLNS_OK)
            st = blns_dbi_wait_idle(dev);
    }
    if (st == BLNS_OK)
        st = ili9341_display_on(dev, true);
    if (st == BLNS_OK)
        st = blns_dbi_wait_idle(dev);
    return st;
}
