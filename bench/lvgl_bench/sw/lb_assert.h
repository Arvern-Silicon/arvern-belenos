/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      lb_assert.h (bench/lvgl_bench)
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * LVGL's assertion handler in the benchmark bench (lv_conf.h,
 * LV_ASSERT_CUSTOM_INCLUDE): report and end the simulation (main.c).
 *----------------------------------------------------------------------------*/
#ifndef LB_ASSERT_H
#define LB_ASSERT_H

void lb_assert_failed(void);
#define LV_ASSERT_HANDLER lb_assert_failed();

#endif /* LB_ASSERT_H */
