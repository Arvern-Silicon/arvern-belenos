/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_priv.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Driver internals shared by the sw/src files (not part of the API).
 *----------------------------------------------------------------------------*/
#ifndef BLNS_PRIV_H
#define BLNS_PRIV_H

#include "belenos.h"

#define FIELD_GET(v, f)  (((v) & f##_Msk) >> f##_Pos)

/* A rare path (set-up, recover, error handling): out of line and compiled for
 * size whatever the optimisation level of the build */
#if defined(__GNUC__) || defined(__clang__)
#define BLNS_COLD  __attribute__((cold))
#else
#define BLNS_COLD
#endif

/* One poll of a wait: true when the wait must end (BLNS_ERR_TIMEOUT): the
 * application's hook asked so, or wait_polls polls are done. *polls starts
 * at 0 for each wait. */
static inline bool blns__wait_over(const blns_t *dev, uint32_t *polls)
{
    if (dev->wait_hook && dev->wait_hook(dev->wait_ctx))
        return true;
    return dev->wait_polls != 0u && ++*polls >= dev->wait_polls;
}

/* The GPU fast-path gate (blns__fast in belenos.h): set whenever one of its
 * terms changes */
static inline void blns__gate(blns_t *dev)
{
    dev->fast = BLNS_HAS(dev, GPU) && dev->gpu_on && !dev->rec && dev->skip == 0u;
}

/* The display's shape from its EDID (blns_ddc.c; blns_dpi_picture): its
 * aspect ratio x 100, 0 when unknown (no answer, no size in the EDID) */
#if BLNS_HW_OFF(DPI_DDC)
static inline uint16_t blns__edid_aspect(blns_t *dev, void (*quarter)(void))
{
    (void) dev;
    (void) quarter;
    return 0u;
}
#else
uint16_t blns__edid_aspect(blns_t *dev, void (*quarter)(void));
#endif

/* Every GPU setting unknown: the helpers send them again */
static inline void blns__forget(blns_t *dev)
{
    dev->gst_known = 0u;
}

#endif /* BLNS_PRIV_H */
