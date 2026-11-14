/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      lv_conf.h (bench/lvgl_bench)
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * LVGL v9.6 configuration of the LVGL benchmark bench. Every option not
 * named here keeps LVGL's default (lv_conf_internal.h, the values of
 * lv_conf_template.h): this file is the list of the bench's deviations from
 * the default configuration, each with its reason. doc/performance.md lists
 * them with the results.
 *----------------------------------------------------------------------------*/
#ifndef LV_CONF_H
#define LV_CONF_H

/* Memory pool: the benchmark asks for at least 128 KB ("It's recommended to
 * have at least 128kB RAM for the benchmark", lv_demo_benchmark.c); the
 * default is 64 KB. */
#define LV_MEM_SIZE                         (128U * 1024U)

/* The benchmark's measurement: the system monitor and its performance
 * monitor (lv_demo_benchmark's Kconfig implies both; without them the
 * benchmark measures nothing). The on-screen label stays on (LOG_MODE 0,
 * the default): the log mode would also remove the benchmark's 48-pixel
 * header and change every scene's layout. */
#define LV_USE_SYSMON                       1
#define LV_USE_PERF_MONITOR                 1

/* Logging to the bench console, at the level the benchmark asks for ("Set
 * LV_LOG_LEVEL at least to LV_LOG_LEVEL_WARN"): the warnings, and LVGL's
 * own LV_LOG output. */
#define LV_USE_LOG                          1
#define LV_LOG_LEVEL                        LV_LOG_LEVEL_WARN

/* A failed assertion ends the simulation (the default handler spins for
 * ever); no effect on a run without one. */
#define LV_ASSERT_USE_CUSTOM_INCLUDE        1
#define LV_ASSERT_CUSTOM_INCLUDE            "lb_assert.h"

/* The fonts the benchmark requires (lv_demo_benchmark.c #error otherwise;
 * 14 is a default font already) */
#define LV_FONT_MONTSERRAT_20               1
#define LV_FONT_MONTSERRAT_24               1
#define LV_FONT_MONTSERRAT_26               1

/* The demos: the benchmark, and the widgets demo it runs as its last scene */
#define LV_USE_DEMO_BENCHMARK               1
#define LV_USE_DEMO_WIDGETS                 1

/* Layers (opacity, transforms) are rendered in chunks: at least 1/20 of the
 * screen, as the benchmark warns otherwise ("LV_DRAW_LAYER_SIMPLE_BUF_SIZE is
 * small making opa_layered slow"). The default, 24 KB, covers 480 x 272
 * (13 KB); LB_LAYER_BUF (the Makefile, from the resolution) raises it above
 * 480 x 384 (800 x 480 at 16 bpp: 38 KB). */
#ifdef LB_LAYER_BUF
#define LV_DRAW_LAYER_SIMPLE_BUF_SIZE       LB_LAYER_BUF
#endif

/* Not LVGL's options: the extensions of the Belenos draw unit
 * (sw/lvgl/lv_belenos.h), built in every persona's firmware (each uses
 * what its GPU has; main.c turns them on): rounded shapes split between
 * the GPU and the CPU, the VRAM pool (images and glyph masks staged there,
 * LVGL's RGB565 layers in it), and the draws the GPU rounds as it does
 * (opacity, labels, gradients: LB_APPROX) */
#define LV_BELENOS_USE_CORNERS              1
#define LV_BELENOS_USE_POOL                 1
#define LV_BELENOS_USE_APPROX               1

#endif /* LV_CONF_H */
