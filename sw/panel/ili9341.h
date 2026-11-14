/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      ili9341.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * ILI9341 panel driver (e.g. the Terasic LT24 module) over the Belenos DBI
 * transport, 16 bits per pixel. Configure the bus with blns_dbi_config()
 * first.
 *----------------------------------------------------------------------------*/
#ifndef ILI9341_H
#define ILI9341_H

#include "belenos.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ILI9341_WIDTH        240u       /* native portrait resolution */
#define ILI9341_HEIGHT       320u

/* MADCTL (memory access control) bits */
#define ILI9341_MADCTL_MY    0x80u      /* row address order          */
#define ILI9341_MADCTL_MX    0x40u      /* column address order       */
#define ILI9341_MADCTL_MV    0x20u      /* row / column exchange      */
#define ILI9341_MADCTL_ML    0x10u      /* vertical refresh order     */
#define ILI9341_MADCTL_BGR   0x08u      /* BGR colour filter order    */

typedef struct {
    void     (*delay_ms)(uint32_t ms);  /* platform delay, needed by the reset and sleep-out sequence */
    uint8_t    madctl;                  /* ILI9341_MADCTL_* (orientation, colour order) */
    uint16_t   win_width;               /* panel window set once at init (columns), 0 = none */
    uint16_t   win_height;              /* (rows); with DIF_CFG.HW_WINDOW_EN = 0 it stays for every refresh */
    bool       clear;                   /* fill the panel memory at init           */
    uint32_t   clear_rgb888;            /* colour of that fill                     */
} ili9341_config_t;

/* Reset, sleep out, 16 bpp, orientation, optional window and clear, display on.
 * The fill uses DISP_SIZE: set it (blns_set_size) before calling. */
blns_status_t ili9341_init(blns_t *dev, const ili9341_config_t *cfg);

/* Set the column (x0..x1) and row (y0..y1) window of the panel memory */
blns_status_t ili9341_set_window(blns_t *dev, uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1);

blns_status_t ili9341_display_on(blns_t *dev, bool on);

#ifdef __cplusplus
}
#endif

#endif /* ILI9341_H */
