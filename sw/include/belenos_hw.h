/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      belenos_hw.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Compile-time platform features (included by belenos.h).
 *
 * The build may name a platform header, which then states what the
 * bitstream(s) the firmware runs on are built with:
 *
 *     CFLAGS += -DBLNS_PLATFORM_HEADER='"tang_blns.h"'
 *
 * The header is named by the build, never picked up by its name from the
 * include path, so a firmware is configured only where its Makefile says so
 * and every file of it (driver and application) sees the same set. In it,
 * each optional feature is one macro with three states:
 *
 *     #define BLNS_HW_GPU_REMAP 1    present: the driver does not test caps
 *     #define BLNS_HW_GPU_REMAP 0    absent: its calls are inline returns of
 *                                    BLNS_ERR_ABSENT and their code is not
 *                                    compiled
 *     (not defined)                  detected at run time from BLNS_CFG /
 *                                    BLNS_CFG2 / DPI_CAPS (blns_t.caps)
 *
 *   BLNS_HW_GPU         GPU (BLNS_CFG.GPU)
 *   BLNS_HW_GPU_XY      x/y destinations, clip, affine blits (CFG2.XY)
 *   BLNS_HW_GPU_GRAD    gradients (CFG2.GRAD)
 *   BLNS_HW_GPU_BLEND   alpha blending, EXPAND coverage masks (CFG2.BLEND)
 *   BLNS_HW_GPU_TRI     triangles (CFG2.TRI; needs XY)
 *   BLNS_HW_GPU_REMAP   palette remap (CFG2.REMAP)
 *   BLNS_HW_GPU_MPLANE  mask plane (CFG2.MPLANE)
 *   BLNS_HW_GPU_IMM     immediate source (CFG2.IMM)
 *   BLNS_HW_GPU_LINE    lines (CFG2.LINE; needs XY)
 *   BLNS_HW_GPU_BILINEAR bilinear texture sampling (CFG2.BILINEAR; needs XY)
 *   BLNS_HW_LUT         colour LUT (BLNS_CFG.LUT)
 *   BLNS_HW_LUT2        a second LUT bank (BLNS_CFG.LUT2; needs LUT)
 *   BLNS_HW_DPI         built-in DPI driver (DIF_TYPE 4 or 5)
 *   BLNS_HW_DBI         built-in DBI transport (DIF_TYPE 1 to 3)
 *   BLNS_HW_DPI_DDC     HDMI DDC (DPI_CAPS.DDC; needs DPI)
 *   BLNS_HW_DPI_ISLAND  HDMI mode, InfoFrames (DPI_CAPS.ISLAND; needs DPI)
 *   BLNS_HW_DPI_AUDIO   HDMI audio, generic packet (DPI_CAPS.AUDIO; needs ISLAND)
 *   BLNS_HW_CURSOR      hardware cursor (BLNS_CFG.CURSOR; independent of the GPU)
 *
 * A feature whose parent is 0 is 0 too (BLNS_HW_GPU 0: every GPU feature).
 * blns_init() compares every macro set to 0 or 1 with the hardware and
 * returns BLNS_ERR_CONFIG on a difference: firmware and bitstream cannot
 * silently disagree. The macros never change a structure's layout, so files
 * built with and without them may be linked together (a file without them
 * only detects at run time). The GPU calls of a build with BLNS_HW_GPU 0
 * keep their symbols, each reduced to a few-byte return of BLNS_ERR_ABSENT.
 *----------------------------------------------------------------------------*/
#ifndef BELENOS_HW_H
#define BELENOS_HW_H

#ifdef BLNS_PLATFORM_HEADER
#include BLNS_PLATFORM_HEADER
#endif

/* BLNS__HW_<F>: -1 run-time detection, 0 absent, 1 present. A macro of the
 * platform must be 0 or 1. */
#define BLNS__HW_CHECK(v)   ((v) == 0 || (v) == 1)

#ifndef BLNS_HW_GPU
#define BLNS__HW_GPU (-1)
#elif BLNS__HW_CHECK(BLNS_HW_GPU)
#define BLNS__HW_GPU BLNS_HW_GPU
#else
#error "BLNS_HW_GPU must be 0, 1 or undefined"
#endif

/* The GPU features: 0 when the GPU is absent, else their own macros */
#if BLNS__HW_GPU == 0
#  if (defined(BLNS_HW_GPU_XY) && BLNS_HW_GPU_XY) || (defined(BLNS_HW_GPU_GRAD) && BLNS_HW_GPU_GRAD) || \
      (defined(BLNS_HW_GPU_BLEND) && BLNS_HW_GPU_BLEND) || (defined(BLNS_HW_GPU_TRI) && BLNS_HW_GPU_TRI) || \
      (defined(BLNS_HW_GPU_REMAP) && BLNS_HW_GPU_REMAP) || (defined(BLNS_HW_GPU_MPLANE) && BLNS_HW_GPU_MPLANE) || \
      (defined(BLNS_HW_GPU_IMM) && BLNS_HW_GPU_IMM) || (defined(BLNS_HW_GPU_LINE) && BLNS_HW_GPU_LINE) || \
      (defined(BLNS_HW_GPU_BILINEAR) && BLNS_HW_GPU_BILINEAR)
#    error "a BLNS_HW_GPU_* feature set to 1 with BLNS_HW_GPU 0"
#  endif
#  define BLNS__HW_GPU_XY     0
#  define BLNS__HW_GPU_GRAD   0
#  define BLNS__HW_GPU_BLEND  0
#  define BLNS__HW_GPU_TRI    0
#  define BLNS__HW_GPU_REMAP  0
#  define BLNS__HW_GPU_MPLANE 0
#  define BLNS__HW_GPU_IMM    0
#  define BLNS__HW_GPU_LINE   0
#  define BLNS__HW_GPU_BILINEAR 0
#else
#  ifndef BLNS_HW_GPU_XY
#    define BLNS__HW_GPU_XY (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_XY)
#    define BLNS__HW_GPU_XY BLNS_HW_GPU_XY
#  else
#    error "BLNS_HW_GPU_XY must be 0, 1 or undefined"
#  endif
#  ifndef BLNS_HW_GPU_GRAD
#    define BLNS__HW_GPU_GRAD (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_GRAD)
#    define BLNS__HW_GPU_GRAD BLNS_HW_GPU_GRAD
#  else
#    error "BLNS_HW_GPU_GRAD must be 0, 1 or undefined"
#  endif
#  ifndef BLNS_HW_GPU_BLEND
#    define BLNS__HW_GPU_BLEND (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_BLEND)
#    define BLNS__HW_GPU_BLEND BLNS_HW_GPU_BLEND
#  else
#    error "BLNS_HW_GPU_BLEND must be 0, 1 or undefined"
#  endif
#  if BLNS__HW_GPU_XY == 0
#    if defined(BLNS_HW_GPU_TRI) && BLNS_HW_GPU_TRI
#      error "BLNS_HW_GPU_TRI 1 needs BLNS_HW_GPU_XY"
#    endif
#    define BLNS__HW_GPU_TRI 0
#  elif !defined(BLNS_HW_GPU_TRI)
#    define BLNS__HW_GPU_TRI (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_TRI)
#    define BLNS__HW_GPU_TRI BLNS_HW_GPU_TRI
#  else
#    error "BLNS_HW_GPU_TRI must be 0, 1 or undefined"
#  endif
#  ifndef BLNS_HW_GPU_REMAP
#    define BLNS__HW_GPU_REMAP (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_REMAP)
#    define BLNS__HW_GPU_REMAP BLNS_HW_GPU_REMAP
#  else
#    error "BLNS_HW_GPU_REMAP must be 0, 1 or undefined"
#  endif
#  ifndef BLNS_HW_GPU_MPLANE
#    define BLNS__HW_GPU_MPLANE (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_MPLANE)
#    define BLNS__HW_GPU_MPLANE BLNS_HW_GPU_MPLANE
#  else
#    error "BLNS_HW_GPU_MPLANE must be 0, 1 or undefined"
#  endif
#  ifndef BLNS_HW_GPU_IMM
#    define BLNS__HW_GPU_IMM (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_IMM)
#    define BLNS__HW_GPU_IMM BLNS_HW_GPU_IMM
#  else
#    error "BLNS_HW_GPU_IMM must be 0, 1 or undefined"
#  endif
#  if BLNS__HW_GPU_XY == 0
#    if defined(BLNS_HW_GPU_LINE) && BLNS_HW_GPU_LINE
#      error "BLNS_HW_GPU_LINE 1 needs BLNS_HW_GPU_XY"
#    endif
#    define BLNS__HW_GPU_LINE 0
#  elif !defined(BLNS_HW_GPU_LINE)
#    define BLNS__HW_GPU_LINE (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_LINE)
#    define BLNS__HW_GPU_LINE BLNS_HW_GPU_LINE
#  else
#    error "BLNS_HW_GPU_LINE must be 0, 1 or undefined"
#  endif
#  if BLNS__HW_GPU_XY == 0
#    if defined(BLNS_HW_GPU_BILINEAR) && BLNS_HW_GPU_BILINEAR
#      error "BLNS_HW_GPU_BILINEAR 1 needs BLNS_HW_GPU_XY"
#    endif
#    define BLNS__HW_GPU_BILINEAR 0
#  elif !defined(BLNS_HW_GPU_BILINEAR)
#    define BLNS__HW_GPU_BILINEAR (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_GPU_BILINEAR)
#    define BLNS__HW_GPU_BILINEAR BLNS_HW_GPU_BILINEAR
#  else
#    error "BLNS_HW_GPU_BILINEAR must be 0, 1 or undefined"
#  endif
#endif

#ifndef BLNS_HW_LUT
#define BLNS__HW_LUT (-1)
#elif BLNS__HW_CHECK(BLNS_HW_LUT)
#define BLNS__HW_LUT BLNS_HW_LUT
#else
#error "BLNS_HW_LUT must be 0, 1 or undefined"
#endif
#if BLNS__HW_LUT == 0
#  if defined(BLNS_HW_LUT2) && BLNS_HW_LUT2
#    error "BLNS_HW_LUT2 1 needs BLNS_HW_LUT"
#  endif
#  define BLNS__HW_LUT2 0
#elif !defined(BLNS_HW_LUT2)
#  define BLNS__HW_LUT2 (-1)
#elif BLNS__HW_CHECK(BLNS_HW_LUT2)
#  define BLNS__HW_LUT2 BLNS_HW_LUT2
#else
#  error "BLNS_HW_LUT2 must be 0, 1 or undefined"
#endif

#ifndef BLNS_HW_DBI
#define BLNS__HW_DBI (-1)
#elif BLNS__HW_CHECK(BLNS_HW_DBI)
#define BLNS__HW_DBI BLNS_HW_DBI
#else
#error "BLNS_HW_DBI must be 0, 1 or undefined"
#endif
#ifndef BLNS_HW_DPI
#define BLNS__HW_DPI (-1)
#elif BLNS__HW_CHECK(BLNS_HW_DPI)
#define BLNS__HW_DPI BLNS_HW_DPI
#else
#error "BLNS_HW_DPI must be 0, 1 or undefined"
#endif
#if BLNS__HW_DBI == 1 && BLNS__HW_DPI == 1
#error "BLNS_HW_DBI and BLNS_HW_DPI cannot both be 1 (one DIF_TYPE)"
#endif

#if BLNS__HW_DPI == 0
#  if (defined(BLNS_HW_DPI_DDC) && BLNS_HW_DPI_DDC) || (defined(BLNS_HW_DPI_ISLAND) && BLNS_HW_DPI_ISLAND) || \
      (defined(BLNS_HW_DPI_AUDIO) && BLNS_HW_DPI_AUDIO)
#    error "a BLNS_HW_DPI_* feature set to 1 with BLNS_HW_DPI 0"
#  endif
#  define BLNS__HW_DPI_DDC    0
#  define BLNS__HW_DPI_ISLAND 0
#  define BLNS__HW_DPI_AUDIO  0
#else
#  ifndef BLNS_HW_DPI_DDC
#    define BLNS__HW_DPI_DDC (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_DPI_DDC)
#    define BLNS__HW_DPI_DDC BLNS_HW_DPI_DDC
#  else
#    error "BLNS_HW_DPI_DDC must be 0, 1 or undefined"
#  endif
#  ifndef BLNS_HW_DPI_ISLAND
#    define BLNS__HW_DPI_ISLAND (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_DPI_ISLAND)
#    define BLNS__HW_DPI_ISLAND BLNS_HW_DPI_ISLAND
#  else
#    error "BLNS_HW_DPI_ISLAND must be 0, 1 or undefined"
#  endif
#  if BLNS__HW_DPI_ISLAND == 0
#    if defined(BLNS_HW_DPI_AUDIO) && BLNS_HW_DPI_AUDIO
#      error "BLNS_HW_DPI_AUDIO 1 needs BLNS_HW_DPI_ISLAND"
#    endif
#    define BLNS__HW_DPI_AUDIO 0
#  elif !defined(BLNS_HW_DPI_AUDIO)
#    define BLNS__HW_DPI_AUDIO (-1)
#  elif BLNS__HW_CHECK(BLNS_HW_DPI_AUDIO)
#    define BLNS__HW_DPI_AUDIO BLNS_HW_DPI_AUDIO
#  else
#    error "BLNS_HW_DPI_AUDIO must be 0, 1 or undefined"
#  endif
#endif

#ifndef BLNS_HW_CURSOR
#define BLNS__HW_CURSOR (-1)
#elif BLNS__HW_CHECK(BLNS_HW_CURSOR)
#define BLNS__HW_CURSOR BLNS_HW_CURSOR
#else
#error "BLNS_HW_CURSOR must be 0, 1 or undefined"
#endif

/* The run-time test of each feature (what caps says) */
#define BLNS__CAP_GPU(d)         ((d)->caps.gpu)
#define BLNS__CAP_GPU_XY(d)      ((d)->caps.gpu_xy)
#define BLNS__CAP_GPU_GRAD(d)    ((d)->caps.gpu_grad)
#define BLNS__CAP_GPU_BLEND(d)   ((d)->caps.gpu_blend)
#define BLNS__CAP_GPU_TRI(d)     ((d)->caps.gpu_tri)
#define BLNS__CAP_GPU_REMAP(d)   ((d)->caps.gpu_remap)
#define BLNS__CAP_GPU_MPLANE(d)  ((d)->caps.gpu_mplane)
#define BLNS__CAP_GPU_IMM(d)     ((d)->caps.gpu_imm)
#define BLNS__CAP_GPU_LINE(d)    ((d)->caps.gpu_line)
#define BLNS__CAP_GPU_BILINEAR(d) ((d)->caps.gpu_bilinear)
#define BLNS__CAP_LUT(d)         ((d)->caps.lut_banks != 0u)
#define BLNS__CAP_LUT2(d)        ((d)->caps.lut_banks == 2u)
/* (one evaluation of d each: a range test on the DIF_TYPE codes) */
#define BLNS__CAP_DPI(d)         ((uint8_t) ((d)->caps.dif_type - BLNS_DIF_DPI) <= BLNS_DIF_HDMI - BLNS_DIF_DPI)
#define BLNS__CAP_DBI(d)         ((uint8_t) ((d)->caps.dif_type - BLNS_DIF_DBI_SPI) <= \
                                  BLNS_DIF_DBI_PAR_SPI - BLNS_DIF_DBI_SPI)
#define BLNS__CAP_DPI_DDC(d)     ((d)->caps.dpi_ddc)
#define BLNS__CAP_DPI_ISLAND(d)  ((d)->caps.dpi_island)
#define BLNS__CAP_DPI_AUDIO(d)   ((d)->caps.dpi_audio)
#define BLNS__CAP_CURSOR(d)      ((d)->caps.cursor)

/* Whether feature F (GPU, GPU_XY, ..., GPU_BILINEAR, ..., DPI_AUDIO, CURSOR) is there: a constant when
 * the platform states it, else the caps test. The one place the three states
 * are resolved; the driver tests every feature through it, and an
 * application may too. */
#define BLNS_HAS(dev, F) \
    (BLNS__HW_##F < 0 ? (bool) BLNS__CAP_##F(dev) : (BLNS__HW_##F != 0))

/* For #if: the feature is stated absent (its calls become inline stubs) */
#define BLNS_HW_OFF(F)  (BLNS__HW_##F == 0)

#endif /* BELENOS_HW_H */
