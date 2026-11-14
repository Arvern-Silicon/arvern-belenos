/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_dbi.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Transport of the built-in MIPI-DBI driver (DIF_TYPE 1-3): bus set-up,
 * panel power and reset pins, commands with parameters, full-screen fill and
 * refresh synchronisation. Panel-specific sequences live in sw/panel/.
 *----------------------------------------------------------------------------*/
#include "blns_priv.h"

#if !BLNS_HW_OFF(DBI)

#define PARAM_FIFO_DEPTH  16u
#define RD_STROBE_MIN_NS  90u      /* ILI9341 t_RDH; also covers t_RDL and t_RC */

/* The smallest RD_DIV whose read strobe (2*RD_DIV + 1 cycles low and high)
 * lasts RD_STROBE_MIN_NS at hclk_hz, at least clk_div (reads never faster than
 * with RD_DIV = 0), 15 at most; 0 (follow CLK_DIV) when hclk_hz is unknown. */
static uint32_t dbi_rd_div(const blns_t *dev, uint32_t clk_div)
{
    if (dev->hclk_hz == 0u)
        return 0u;
    uint32_t khz    = (dev->hclk_hz + 999u) / 1000u;
    uint32_t cycles = (RD_STROBE_MIN_NS * khz + 999999u) / 1000000u;
    uint32_t rd     = cycles / 2u;                  /* 2*rd + 1 >= cycles */
    if (rd < clk_div)
        rd = clk_div;
    if (rd == 0u)
        rd = 1u;
    return (rd > 15u) ? 15u : rd;
}

BLNS_COLD blns_status_t blns_dbi_config(blns_t *dev, const blns_dbi_config_t *cfg)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    if (cfg->clk_div > 15u || cfg->rd_div > 15u || (cfg->spi && dev->caps.dif_type == BLNS_DIF_DBI_PAR) ||
        (!cfg->spi && dev->caps.dif_type == BLNS_DIF_DBI_SPI))
        return BLNS_ERR_PARAM;
    BLNS_DIF_TypeDef *d = &dev->regs->DIF;
    uint32_t rd = cfg->rd_div ? cfg->rd_div : dbi_rd_div(dev, cfg->clk_div);
    uint32_t v = d->CFG & (BLNS_DIF_CFG_LCD_ON_Msk | BLNS_DIF_CFG_LCD_RESET_Msk);
    v |= ((uint32_t) cfg->clk_div << BLNS_DIF_CFG_CLK_DIV_Pos) |
         (rd << BLNS_DIF_CFG_RD_DIV_Pos) |
         (cfg->spi       ? BLNS_DIF_CFG_PHY_SPI_Msk   : 0u) |
         (cfg->hw_window ? BLNS_DIF_CFG_HW_WINDOW_Msk : 0u);
    d->CFG = v;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dbi_power(blns_t *dev, bool on)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    BLNS_DIF_TypeDef *d = &dev->regs->DIF;
    d->CFG = on ? (d->CFG | BLNS_DIF_CFG_LCD_ON_Msk) : (d->CFG & ~BLNS_DIF_CFG_LCD_ON_Msk);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dbi_reset(blns_t *dev, bool assert)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    BLNS_DIF_TypeDef *d = &dev->regs->DIF;
    d->CFG = assert ? (d->CFG | BLNS_DIF_CFG_LCD_RESET_Msk) : (d->CFG & ~BLNS_DIF_CFG_LCD_RESET_Msk);
    return BLNS_OK;
}

/* Poll until no bit of mask is set in DIF_STATUS */
static blns_status_t dif_wait(blns_t *dev, uint32_t mask)
{
    uint32_t polls = 0u;
    while (BLNS_REG_RD(dev, DIF.STATUS) & mask)
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dbi_cmd(blns_t *dev, uint8_t cmd, const uint8_t *param, unsigned count)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    if (count > 255u)
        return BLNS_ERR_PARAM;
    if (count && !param)
        return BLNS_ERR_PARAM;

    /* One-deep command slot: a write while it is occupied would be dropped.
     * Pre-load what fits in the parameter FIFO, queue the command, then feed
     * the rest as the command drains the FIFO, each write after PARAM_FULL
     * reads 0 (a write to a full FIFO is dropped and sets PARAM_OVFL). A
     * timeout before the command is queued sends nothing; after it, the
     * command goes with fewer parameters than announced (the panel then
     * needs a reset). */
    blns_status_t st = dif_wait(dev, BLNS_DIF_STATUS_CMD_PENDING_Msk | BLNS_DIF_STATUS_PARAM_LEVEL_Msk);
    if (st != BLNS_OK)
        return st;
    unsigned first = (count < PARAM_FIFO_DEPTH) ? count : PARAM_FIFO_DEPTH;
    for (unsigned i = 0; i < first; i++)
        BLNS_REG_WR(dev, DIF.PARAM, param[i]);
    BLNS_REG_WR(dev, DIF.CMD, (count << BLNS_DIF_CMD_NPARAM_Pos) | cmd);
    for (unsigned i = first; i < count; i++) {
        st = dif_wait(dev, BLNS_DIF_STATUS_PARAM_FULL_Msk);
        if (st != BLNS_OK)
            return st;
        BLNS_REG_WR(dev, DIF.PARAM, param[i]);
    }
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dbi_fill(blns_t *dev, uint32_t rgb888)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    blns_status_t st = dif_wait(dev, BLNS_DIF_STATUS_DFILL_PEND_Msk);
    if (st != BLNS_OK)
        return st;
    dev->regs->DIF.DFILL = rgb888 & 0x00FFFFFFu;
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_dbi_sync(blns_t *dev, uint16_t scanline, bool scan_sync, bool te_sync)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    if (scanline > BLNS_DIF_SYNC_SCANLINE_Msk ||
        (scan_sync && (dev->caps.dif_type == BLNS_DIF_DBI_SPI || (dev->regs->DIF.CFG & BLNS_DIF_CFG_PHY_SPI_Msk))))
        return BLNS_ERR_PARAM;              /* the SPI PHY ignores the scanline sync */
    dev->regs->DIF.SYNC = ((uint32_t) scanline & BLNS_DIF_SYNC_SCANLINE_Msk) |
                          (scan_sync ? BLNS_DIF_SYNC_SCAN_EN_Msk : 0u) |
                          (te_sync   ? BLNS_DIF_SYNC_TE_EN_Msk   : 0u);
    return BLNS_OK;
}

blns_status_t blns_dbi_wait_idle(blns_t *dev)
{
    if (!BLNS_HAS(dev, DBI))
        return BLNS_ERR_ABSENT;
    return dif_wait(dev, BLNS_DIF_STATUS_BUSY_Msk | BLNS_DIF_STATUS_CMD_PENDING_Msk |
                         BLNS_DIF_STATUS_DFILL_BUSY_Msk | BLNS_DIF_STATUS_DFILL_PEND_Msk);
}

#endif /* DBI */
