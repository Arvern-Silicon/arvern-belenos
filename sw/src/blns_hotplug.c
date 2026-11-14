/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_hotplug.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * HDMI hot-plug: the state machine that restarts the link when a monitor is
 * plugged or wakes (blns_dpi_hotplug_init / blns_dpi_hotplug_poll); DETECT
 * is a write-1-to-clear flag.
 *----------------------------------------------------------------------------*/
#include "blns_priv.h"

#if !BLNS_HW_OFF(DPI)

enum { HP_IDLE, HP_SETTLE, HP_OFF, HP_PROBE };

static void hp_link(blns_t *dev, bool on)
{
    BLNS_DPI_TypeDef *d = &dev->regs->DPI;
    d->CFG = on ? (d->CFG | BLNS_DPI_CFG_LCD_ON_Msk) : (d->CFG & ~BLNS_DPI_CFG_LCD_ON_Msk);
}

// The picture placed again (hp->picture, no EDID yet): a placement refused
// (an update pending: BLNS_ERR_BUSY in non-blocking mode, a timeout) is
// tried again at the next poll
static void hp_picture(blns_t *dev, blns_hotplug_t *hp)
{
    hp->place = blns_dpi_picture(dev, hp->picture, &hp->settled) != BLNS_OK;
    if (hp->place)
        hp->settled = false;
}

BLNS_COLD void blns_dpi_hotplug_init(blns_t *dev, blns_hotplug_t *hp, uint32_t now_ms)
{
    if (hp->off_ms == 0u) {
        hp->low_ms = 1000u;  hp->quiet_ms = 5000u;  hp->settle_ms = 500u;  hp->off_ms = 1000u;
        hp->probe_every_ms = 2000u;  hp->probe_ms = 200u;  hp->wake_ms = 10000u;
    }
    hp->state     = HP_IDLE;
    hp->no_probes = false;
    hp->forced    = false;
    hp->place     = false;
    hp->t0 = hp->low_t0 = hp->on_t0 = hp->poll_t = now_ms;
    hp->restarts  = 0u;
    if (BLNS_HAS(dev, DPI))
        BLNS_REG_WR(dev, DPI.IRQ_FLAG, BLNS_DPI_IRQ_DETECT_Msk);
    hp->present_q = BLNS_HAS(dev, DPI) && (BLNS_REG_RD(dev, DPI.STATUS) & BLNS_DPI_STATUS_PRESENT_Msk);
}

BLNS_COLD blns_hp_event_t blns_dpi_hotplug_poll(blns_t *dev, blns_hotplug_t *hp, uint32_t now_ms, bool force)
{
    if (dev->caps.dif_type != BLNS_DIF_HDMI)
        return BLNS_HP_NONE;
    /* DETECT latches every change of the line: read and cleared before the
     * line is read, so a change after the clear is in the line read (and in
     * DETECT again, for the next poll) and none falls between the two. Two
     * since the previous poll (a program busy elsewhere) are taken as the
     * last one. */
    const uint32_t det = BLNS_REG_RD(dev, DPI.IRQ_FLAG) & BLNS_DPI_IRQ_DETECT_Msk;
    if (det)
        BLNS_REG_WR(dev, DPI.IRQ_FLAG, det);
    const bool present = (BLNS_REG_RD(dev, DPI.STATUS) & BLNS_DPI_STATUS_PRESENT_Msk) != 0u;
    if (det && present == hp->present_q) {
        if (present)
            hp->low_t0 = hp->poll_t;        /* it dropped and came back: low since then at most */
        hp->present_q = !present;
    }
    /* the line going low starts the low time in every state but SETTLE (a
     * bounce of the plug being settled keeps the low time before it) */
    if (!present && hp->present_q && hp->state != HP_SETTLE)
        hp->low_t0 = now_ms;
    hp->poll_t = now_ms;
    hp->forced = hp->forced || force;       /* kept until IDLE takes it */
    const uint32_t ms     = now_ms - hp->t0;
    const uint32_t low_ms = now_ms - hp->low_t0;
    const uint32_t on_ms  = now_ms - hp->on_t0;
    blns_hp_event_t ev = BLNS_HP_NONE;

    switch (hp->state) {
    case HP_IDLE:
        if (hp->forced) {
            hp->forced    = false;
            hp->no_probes = !present;       /* with the line low: no more probes */
            hp_link(dev, false);
            hp->t0    = now_ms;
            hp->state = HP_OFF;
        } else if (present && !hp->present_q) {
            hp->no_probes = false;
            if (low_ms >= hp->low_ms && on_ms >= hp->quiet_ms) {
                hp->t0    = now_ms;
                hp->state = HP_SETTLE;
            }
        } else if (!present && hp->present_q) {
            hp->t0 = now_ms;
            hp->no_probes = false;
        } else if (!present && ms >= hp->probe_every_ms && on_ms >= hp->wake_ms && !hp->no_probes) {
            hp_link(dev, false);
            hp->t0    = now_ms;
            hp->state = HP_PROBE;
        } else if (hp->place && present) {
            hp_picture(dev, hp);
        }
        break;
    case HP_PROBE:                          /* the link off: does a monitor answer? */
        if (present) {
            hp->t0    = now_ms;
            hp->state = HP_OFF;             /* then on again: a link that starts */
        } else if (ms >= hp->probe_ms) {
            hp_link(dev, true);
            hp->t0    = now_ms;
            hp->state = HP_IDLE;
        }
        break;
    case HP_SETTLE:
        if (!present) {
            hp->state = HP_IDLE;
        } else if (ms >= hp->settle_ms) {
            hp_link(dev, false);
            hp->t0    = now_ms;
            hp->state = HP_OFF;
        }
        break;
    default:                                /* HP_OFF */
        if (ms >= hp->off_ms) {
            hp_link(dev, true);
            hp->t0 = hp->on_t0 = now_ms;
            hp->restarts++;
            hp->state = HP_IDLE;
            ev = BLNS_HP_RESTARTED;
            if (hp->picture && !hp->settled && present)     /* the monitor answers now */
                hp_picture(dev, hp);
        }
        break;
    }
    hp->present_q = present;
    return ev;
}

#endif /* DPI */
