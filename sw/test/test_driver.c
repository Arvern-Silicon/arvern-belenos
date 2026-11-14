/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      test_driver.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Host unit test of the C driver against a register and VRAM model in RAM
 * (blns_model_impl.h).
 *
 * The register port is a BLNS_TypeDef in memory; the GPU_CMD stores and the
 * accesses of BLNS_REG_WR / BLNS_REG_RD reach the model (blns_model.h): a
 * FIFO and a command decoder that behave as the RTL at the register port
 * (flush, ABORT, GPU_EN, immediate data, errors), keep the GPU settings, log
 * every EXEC as a draw (operation, destination address, size, colours,
 * source) and write the pixels of fills, spans and copies; the hot-plug
 * flags write 1 to clear; an EDID EEPROM sits on the DDC lines. The tests
 * check what is drawn, not the exact words: the shadow cache, the sessions
 * of the per-item calls, the inline fast paths and the lists must all draw
 * the same thing as a plain sequence. The wait hook doubles as the GPU's
 * clock: each poll runs the decoder. After every test the FIFO must not
 * have overflowed and the draw log not be full.
 *
 *   make -C sw/test        (any C11 host compiler; exits 1 on a failure)
 *----------------------------------------------------------------------------*/
#include <math.h>
#include "blns_model_impl.h"

/*---------------------------------------------------------------------------
 * Checks
 *---------------------------------------------------------------------------*/
static unsigned fails, checks;

#define CHECK(c) do {                                                           \
        checks++;                                                               \
        if (!(c)) {                                                             \
            fails++;                                                            \
            printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);               \
        }                                                                       \
    } while (0)

static const draw_t *last(void)
{
    model_run();
    return m.nd ? &m.d[m.nd - 1u] : NULL;
}

static bool drew(const draw_t *d, uint32_t op, uint32_t addr, uint32_t w, uint32_t h)
{
    return d && d->op == op && d->addr == addr && d->w == w && d->h == h;
}

/*---------------------------------------------------------------------------
 * Tests
 *---------------------------------------------------------------------------*/

/* the display size read back, pitch 0 = that width; enable resets the
 * GPU settings */
static void test_init_state(void)
{
    setup(BLNS_DIF_DPI, 0u);
    CHECK(dev.width == 320u && dev.height == 240u && dev.mode == BLNS_BPP_16);
    CHECK(blns_display_pitch(&dev) == 320u);
    CHECK(blns_pixel_addr(&dev, 0u, 1u, 2u) == 641u);
    m.fill = 0x55u;                                     /* a setting of a previous program */
    CHECK(blns_gpu_enable(&dev, true) == BLNS_OK);
    model_run();
    CHECK(m.fill == 0u && m.words == 1u);               /* RESET_STATE */
    const blns_surf_t s = { 100u, 0u, BLNS_SWAP_NONE };
    CHECK(blns_gpu_fill(&dev, &s, 4u, 4u, 7u, BLNS_ROP_S) == BLNS_OK);
    CHECK(drew(last(), 0x8, 100u, 4u, 4u) && last()->pitch == 320u && last()->fill == 7u);
    blns_set_pitch(&dev, 512u);
    CHECK(blns_display_pitch(&dev) == 512u);
    CHECK(blns_gpu_fill(&dev, &s, 4u, 4u, 7u, BLNS_ROP_S) == BLNS_OK && last()->pitch == 512u);
}

/* zero and oversized sizes */
static void test_sizes(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const unsigned w0 = m.words;
    const blns_surf_t s = { 0u, 0u, BLNS_SWAP_NONE };
    CHECK(blns_gpu_fill(&dev, &s, 0u, 5u, 1u, BLNS_ROP_S) == BLNS_OK);
    CHECK(blns_gpu_copy(&dev, &s, &s, 5u, 0u, BLNS_ROP_S) == BLNS_OK);
    CHECK(blns_gpu_span_begin(&dev, 0u, 0u, 3u) == BLNS_OK);
    const unsigned w1 = m.words;
    CHECK(blns_gpu_span(&dev, 10u, 0u) == BLNS_OK);
    CHECK(m.words == w1);
    /* x/y: without GPU_XY every call is BLNS_ERR_ABSENT, nothing pushed */
    const bool xy = BLNS_HAS(&dev, GPU_XY);
#define XY_ST(st) (xy ? (st) : BLNS_ERR_ABSENT)
    CHECK(blns_gpu_xy_begin(&dev, 0u, 0u, 3u) == XY_ST(BLNS_OK));
    const unsigned w2 = m.words;
    CHECK(blns_gpu_fill_xy(&dev, 1, 1, 0u, 3u) == XY_ST(BLNS_OK));
    CHECK(blns_gpu_span_xy(&dev, 1, 1, 0u) == XY_ST(BLNS_OK));
    CHECK(w1 - w0 >= 2u && m.words == w2 && (xy || w2 == w1));  /* the empty calls pushed nothing */
    CHECK(blns_gpu_fill(&dev, &s, 16384u, 1u, 1u, BLNS_ROP_S) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_fill_xy(&dev, 1, 1, 1u, 16384u) == XY_ST(BLNS_ERR_PARAM));
    CHECK(blns_gpu_fill_xy(&dev, 2048, 1, 1u, 1u) == XY_ST(BLNS_ERR_PARAM));
#undef XY_ST
    model_run();
    CHECK(m.nd == 0u);
}

/* the per-item calls keep their session across a fill or a copy */
static void test_sessions(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    const blns_surf_t f = { 5000u, 0u, BLNS_SWAP_NONE }, src = { 9000u, 64u, BLNS_SWAP_NONE };

    /* spans: colour 3, a fill in 9 between two spans */
    CHECK(blns_gpu_span_begin(&dev, 1000u, 0u, 3u) == BLNS_OK);
    CHECK(blns_gpu_span(&dev, 1000u, 8u) == BLNS_OK && drew(last(), 0xB, 1000u, 8u, 1u) && last()->fill == 3u);
    CHECK(blns_gpu_fill(&dev, &f, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK && last()->fill == 9u);
    CHECK(blns_gpu_span(&dev, 1320u, 5u) == BLNS_OK && drew(last(), 0xB, 1320u, 5u, 1u) && last()->fill == 3u);
    CHECK(blns_gpu_span(&dev, 1330u, 6u) == BLNS_OK && drew(last(), 0xB, 1330u, 6u, 1u) && last()->fill == 3u);
    blns_gpu_colour_set(&dev, 4u);
    CHECK(blns_gpu_span(&dev, 1340u, 2u) == BLNS_OK && last()->fill == 4u);

    /* glyphs 8 x 12 in colour 2 on bg 6 (opaque); a fill and a span between */
    const blns_expand_t e = { .width = 8u, .height = 12u, .depth = BLNS_EXP_1BPP, .opaque = true };
    CHECK(blns_gpu_expand_begin(&dev, &e, 2000u, 0u, 2u, 6u) == BLNS_OK);
    CHECK(blns_gpu_expand(&dev, 100u, 2000u) == BLNS_OK && drew(last(), 0xC, 2000u, 8u, 12u) &&
          last()->fill == 2u && last()->transp == 6u && last()->src == 100u);
    CHECK(blns_gpu_fill(&dev, &f, 3u, 3u, 9u, BLNS_ROP_S) == BLNS_OK);
    CHECK(blns_gpu_span(&dev, 7000u, 30u) == BLNS_OK);
    CHECK(blns_gpu_expand(&dev, 200u, 2008u) == BLNS_OK && drew(last(), 0xC, 2008u, 8u, 12u) &&
          last()->fill == 2u && last()->transp == 6u && last()->src == 200u && last()->pitch == 320u);

    /* texture spans: a copy changes the source in between */
    const blns_tex_t t = { .addr = 12000u, .log2_w = 6u, .log2_h = 6u };
    CHECK(blns_gpu_tex_begin(&dev, &t, 3000u, 0u, 0u) == BLNS_OK);
    CHECK(blns_gpu_tex_step(&dev, 0x100, 0) == BLNS_OK);
    CHECK(blns_gpu_tex_span(&dev, 3000u, 16u, 0u, 0u) == BLNS_OK && drew(last(), 0xD, 3000u, 16u, 1u) &&
          last()->src == 12000u && last()->step == 0x01000000u);
    CHECK(blns_gpu_copy(&dev, &src, &f, 4u, 4u, BLNS_ROP_S) == BLNS_OK && last()->src == 9000u);
    const bool xy = BLNS_HAS(&dev, GPU_XY);
    CHECK(blns_gpu_texrect_xy(&dev, 0, 0, 1u, 1u, 0u, 0u, 5, 5, 0, 0) == (xy ? BLNS_ERR_STATE : BLNS_ERR_ABSENT));
    CHECK(blns_gpu_tex_span(&dev, 3320u, 16u, 0u, 64u) == BLNS_OK && drew(last(), 0xD, 3320u, 16u, 1u) &&
          last()->src == 12000u && last()->src_pitch == 0u && last()->step == 0x01000000u);

    /* x/y: an address-mode fill in between; the next x/y fill is on the
     * surface. Without GPU_XY: BLNS_ERR_ABSENT, nothing pushed. */
    if (!xy) {
        model_run();
        const unsigned w0 = m.words, n0 = m.nd;
        CHECK(blns_gpu_xy_begin(&dev, 20000u, 100u, 11u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_fill_xy(&dev, 5, 6, 3u, 2u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_span_xy(&dev, 7, 6, 4u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_expand_set(&dev, &e, 2u, 6u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_expand_xy(&dev, 300u, 30, 6) == BLNS_ERR_ABSENT);
        model_run();
        CHECK(m.words == w0 && m.nd == n0 && !m.overflow);
        return;
    }
    CHECK(blns_gpu_xy_begin(&dev, 20000u, 100u, 11u) == BLNS_OK);
    CHECK(blns_gpu_fill_xy(&dev, 5, 6, 3u, 2u) == BLNS_OK && drew(last(), 0x8, 20000u + 605u, 3u, 2u) &&
          last()->fill == 11u);
    CHECK(blns_gpu_fill(&dev, &f, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK);
    CHECK(blns_gpu_fill_xy(&dev, 5, 6, 3u, 2u) == BLNS_OK && drew(last(), 0x8, 20000u + 605u, 3u, 2u) &&
          last()->fill == 11u);
    CHECK(blns_gpu_span_xy(&dev, 7, 6, 4u) == BLNS_OK && drew(last(), 0xB, 20000u + 607u, 4u, 1u));
    CHECK(blns_gpu_span_xy(&dev, 20, 6, 4u) == BLNS_OK && drew(last(), 0xB, 20000u + 620u, 4u, 1u));
    CHECK(blns_gpu_fill_xy(&dev, 20, 6, 3u, 2u) == BLNS_OK && drew(last(), 0x8, 20000u + 620u, 3u, 2u));
    CHECK(blns_gpu_expand_set(&dev, &e, 2u, 6u) == BLNS_OK);
    CHECK(blns_gpu_expand_xy(&dev, 300u, 30, 6) == BLNS_OK && drew(last(), 0xC, 20000u + 630u, 8u, 12u) &&
          last()->fill == 2u);
    CHECK(blns_gpu_fill_xy(&dev, 0, 0, 1u, 1u) == BLNS_OK && last()->fill == 11u);
    CHECK(blns_gpu_expand_xy(&dev, 300u, 38, 6) == BLNS_OK && drew(last(), 0xC, 20000u + 638u, 8u, 12u) &&
          last()->fill == 2u);
    CHECK(!m.overflow);
}

/* The batches and the fast paths draw what the single calls draw */
static void test_batches(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    blns_gpu_span_begin(&dev, 0u, 0u, 1u);
    const blns_span_t sp[3] = { { 10u, 1u }, { 20u, 2u }, { 9000u + 20u, 3u } };
    CHECK(blns_gpu_spans(&dev, sp, 3u) == BLNS_OK);
    model_run();
    CHECK(m.nd == 3u && drew(&m.d[0], 0xB, 10u, 1u, 1u) && drew(&m.d[1], 0xB, 20u, 2u, 1u) &&
          drew(&m.d[2], 0xB, 9020u, 3u, 1u));
    const blns_rect_t r[2] = { { 1, 1, 2u, 2u }, { -1, 0, 3u, 1u } };
    const blns_expand_t e = { .width = 6u, .height = 8u, .depth = BLNS_EXP_1BPP };
    const blns_pa_t g[3] = { 64u, 128u, 192u };
    if (!BLNS_HAS(&dev, GPU_XY)) {                      /* BLNS_ERR_ABSENT, nothing pushed */
        const unsigned w0 = m.words;
        CHECK(blns_gpu_xy_begin(&dev, 1000u, 50u, 2u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_fills_xy(&dev, r, 2u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_expand_set(&dev, &e, 4u, 0u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_text_xy(&dev, 10, 2, g, NULL, 3u) == BLNS_ERR_ABSENT);
        model_run();
        CHECK(m.words == w0 && m.nd == 3u && !m.overflow);
        return;
    }
    blns_gpu_xy_begin(&dev, 1000u, 50u, 2u);
    CHECK(blns_gpu_fills_xy(&dev, r, 2u) == BLNS_OK);
    model_run();
    CHECK(m.nd == 5u && drew(&m.d[3], 0x8, 1051u, 2u, 2u) && drew(&m.d[4], 0x8, 999u, 3u, 1u));
    blns_gpu_expand_set(&dev, &e, 4u, 0u);
    CHECK(blns_gpu_text_xy(&dev, 10, 2, g, NULL, 3u) == BLNS_OK);
    model_run();
    CHECK(m.nd == 8u && drew(&m.d[5], 0xC, 1110u, 6u, 8u) && drew(&m.d[7], 0xC, 1122u, 6u, 8u) &&
          m.d[7].src == 192u);
    CHECK(!m.overflow);
}

/* a recover (any context) between calls makes the next call send its
 * settings again */
static void test_recover(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    CHECK(blns_gpu_span_begin(&dev, 4000u, 0u, 5u) == BLNS_OK);    /* queued, not run */
    blns_gpu_recover(&dev);                                         /* the hardware flush */
    CHECK(blns_gpu_span(&dev, 4010u, 3u) == BLNS_OK);
    CHECK(drew(last(), 0xB, 4010u, 3u, 1u) && last()->fill == 5u);
    const blns_expand_t e = { .width = 8u, .height = 8u, .depth = BLNS_EXP_1BPP };
    blns_gpu_expand_begin(&dev, &e, 100u, 0u, 1u, 0u);
    blns_gpu_recover(&dev);
    CHECK(blns_gpu_expand(&dev, 50u, 108u) == BLNS_OK && drew(last(), 0xC, 108u, 8u, 8u) && last()->fill == 1u);
}

/* bounded waits */
static void test_waits(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    /* no frames flow: WAIT_REFR_DONE refused, nothing pushed */
    const unsigned w0 = m.words;
    CHECK(blns_gpu_wait_refresh(&dev) == BLNS_ERR_STATE && m.words == w0);
    CHECK(blns_wait_frames(&dev, 1u) == BLNS_ERR_STATE);
    /* a GPU that never drains: the hook ends the wait */
    hook_runs_gpu = false;
    hook_limit    = 3u;
    uint32_t sz[64];
    const unsigned depth = m.depth;
    for (unsigned i = 0; i < depth; i++)
        sz[i] = BLNS_GPU_OP_SET_SIZE | 0x4004u;
    CHECK(blns_gpu_push(&dev, sz, depth) == BLNS_OK);  /* the FIFO full, nothing drains */
    CHECK(blns_gpu_wait(&dev) == BLNS_ERR_TIMEOUT && hook_polls == 3u);
    hook_polls = 0u;
    const blns_surf_t s = { 0u, 0u, BLNS_SWAP_NONE };
    CHECK(blns_gpu_fill(&dev, &s, 1u, 1u, 1u, BLNS_ROP_S) == BLNS_ERR_TIMEOUT && hook_polls == 3u);
    /* non-blocking: BUSY at once, nothing sent */
    blns_set_nonblocking(&dev, true);
    hook_polls = 0u;
    const unsigned w1 = m.words;
    CHECK(blns_gpu_fill(&dev, &s, 1u, 1u, 1u, BLNS_ROP_S) == BLNS_ERR_BUSY && hook_polls == 0u && m.words == w1);
    blns_set_nonblocking(&dev, false);
    /* frames flowing (DPI on): FRAME_NUM moves in the hook */
    hook_limit = 50u;
    regs.DPI.CFG = BLNS_DPI_CFG_EN_Msk;
    CHECK(blns_frames_flowing(&dev));
    CHECK(blns_wait_frames(&dev, 2u) == BLNS_ERR_TIMEOUT);     /* FRAME_NUM never moves */
    /* wait_polls without a hook (T5: the second blns_init checked) */
    const blns_config_t cfg = { .reg_base = (uintptr_t) &regs, .vram_base = (uintptr_t) vram, .wait_polls = 100u };
    CHECK(blns_init(&dev, &cfg) == BLNS_OK && !m.gpu_en);
    CHECK(blns_frames_flowing(&dev) && blns_wait_frames(&dev, 1u) == BLNS_ERR_TIMEOUT);
    CHECK(blns_gpu_enable(&dev, true) == BLNS_OK && blns_gpu_push(&dev, sz, depth - 1u) == BLNS_OK);
    CHECK(blns_gpu_wait(&dev) == BLNS_ERR_TIMEOUT);             /* nothing drains it */
}

/* the DPI and DBI calls check which driver is built (at run time, or
 * as inline stubs when the platform header says the driver is absent) */
static void test_presence(void)
{
#if BLNS__HW_DPI != 1
    setup(BLNS_DIF_DBI_SPI, 0u);
    regs.DIF.CFG = 0u;
    CHECK(blns_dpi_enable(&dev, true) == BLNS_ERR_ABSENT && regs.DIF.CFG == 0u);
    CHECK(blns_dpi_border(&dev, 0xFFu) == BLNS_ERR_ABSENT);
    CHECK(blns_dpi_test(&dev, true) == BLNS_ERR_ABSENT);
    CHECK(!blns_dpi_present(&dev));
    CHECK(blns_dbi_power(&dev, true) == BLNS_OK && (regs.DIF.CFG & BLNS_DIF_CFG_LCD_ON_Msk));
#endif
#if BLNS__HW_DBI != 1
    setup(BLNS_DIF_DPI, 0u);
    RW(regs.DPI.STATUS) = 1u;                       /* BUSY: the panel timing runs */
    CHECK(blns_dbi_wait_idle(&dev) == BLNS_ERR_ABSENT);
    CHECK(blns_dbi_power(&dev, true) == BLNS_ERR_ABSENT);
    CHECK(blns_dbi_sync(&dev, 0u, false, false) == BLNS_ERR_ABSENT);
#endif
#if BLNS__HW_DPI < 0 && BLNS__HW_DBI < 0
    setup(BLNS_DIF_BDI, 0u);
    CHECK(blns_dpi_enable(&dev, true) == BLNS_ERR_ABSENT && blns_dbi_reset(&dev, true) == BLNS_ERR_ABSENT);
#endif
    /* a GPU feature the build leaves out: ABSENT, nothing pushed */
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const unsigned w0 = m.words;
    const blns_surf_t s = { 0u, 0u, BLNS_SWAP_NONE };
    const blns_status_t remap = blns_gpu_remap_rect(&dev, &s, 4u, 4u);
    CHECK(m.words == w0 && (BLNS_HAS(&dev, GPU_REMAP) ? remap == BLNS_ERR_STATE      /* no table set */
                                                    : remap == BLNS_ERR_ABSENT));
    const blns_status_t alpha = blns_gpu_alpha(&dev, true, 128u);
    CHECK(BLNS_HAS(&dev, GPU_BLEND) ? alpha == BLNS_OK : alpha == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_alpha(&dev, false, 255u) == BLNS_OK);
}

/* The platform header against the hardware: blns_init refuses a bitstream
 * that differs (BLNS_ERR_CONFIG), before writing anything */
static void test_platform(void)
{
    setup(BLNS_DIF_DPI, 0u);
    const blns_config_t cfg = { .reg_base = (uintptr_t) &regs, .vram_base = (uintptr_t) vram, .wait_hook = hook };
    regs.REFRESH = 0x1235u;                         /* would be cleared by an accepted init */
    const uint32_t cfg2 = regs.CFG2, c = regs.CFG;
#if BLNS__HW_GPU_IMM >= 0
    RW(regs.CFG2) = cfg2 ^ BLNS_CFG2_IMM_Msk;       /* the immediate source the other way */
    CHECK(blns_init(&dev, &cfg) == BLNS_ERR_CONFIG && regs.REFRESH == 0x1235u &&
          dev.caps.gpu_imm == (BLNS__HW_GPU_IMM == 0));
#endif
#if BLNS__HW_GPU_LINE >= 0
    RW(regs.CFG2) = cfg2 ^ BLNS_CFG2_LINE_Msk;      /* lines the other way */
    CHECK(blns_init(&dev, &cfg) == BLNS_ERR_CONFIG && regs.REFRESH == 0x1235u &&
          dev.caps.gpu_line == (BLNS__HW_GPU_LINE == 0));
#endif
#if BLNS__HW_GPU_BILINEAR >= 0 && BLNS__HW_GPU_XY != 0     /* (without XY it reads 0 whatever the bit) */
    RW(regs.CFG2) = cfg2 ^ BLNS_CFG2_BILINEAR_Msk;  /* bilinear sampling the other way */
    CHECK(blns_init(&dev, &cfg) == BLNS_ERR_CONFIG && regs.REFRESH == 0x1235u &&
          dev.caps.gpu_bilinear == (BLNS__HW_GPU_BILINEAR == 0));
#endif
#if BLNS__HW_LUT2 >= 0
    RW(regs.CFG2) = cfg2;
    RW(regs.CFG)  = c ^ BLNS_CFG_LUT2_Msk;
    CHECK(blns_init(&dev, &cfg) == BLNS_ERR_CONFIG && regs.REFRESH == 0x1235u);
#endif
#if BLNS__HW_DPI >= 0
    RW(regs.CFG)  = (c & ~BLNS_CFG_DIF_TYPE_Msk) |
                    ((BLNS__HW_DPI ? BLNS_DIF_DBI_PAR : BLNS_DIF_DPI) << BLNS_CFG_DIF_TYPE_Pos);
    CHECK(blns_init(&dev, &cfg) == BLNS_ERR_CONFIG && regs.REFRESH == 0x1235u);
#endif
#if BLNS__HW_CURSOR >= 0
    RW(regs.CFG)  = c ^ BLNS_CFG_CURSOR_Msk;        /* the cursor the other way */
    CHECK(blns_init(&dev, &cfg) == BLNS_ERR_CONFIG && regs.REFRESH == 0x1235u &&
          dev.caps.cursor == (BLNS__HW_CURSOR == 0));
    RW(regs.CFG)  = c;
#endif
#if BLNS__HW_GPU_IMM < 0 && BLNS__HW_LUT2 < 0 && BLNS__HW_DPI < 0
    /* no platform header: any build is accepted, caps tell */
    RW(regs.CFG2) = cfg2 ^ BLNS_CFG2_IMM_Msk;
    CHECK(blns_init(&dev, &cfg) == BLNS_OK && BLNS_HAS(&dev, GPU_IMM) == ((cfg2 & BLNS_CFG2_IMM_Msk) == 0u));
#endif
    RW(regs.CFG)  = c;
    RW(regs.CFG2) = cfg2;
    CHECK(blns_init(&dev, &cfg) == BLNS_OK && regs.REFRESH == 0u);
}

/* fences inside lists, list tags */
static void test_lists(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    blns_gpu_list_t l = { .addr = 8000u, .capacity = 64u };
    uint32_t tag;
    RW(regs.GPU.FENCE) = 0x900000u;                 /* past 2^23: a tag 0 would read as pending */
    reinit();
    blns_gpu_enable(&dev, true);
    model_run();
    CHECK(!blns_gpu_list_busy(&dev, &l) && blns_gpu_list_wait(&dev, &l) == BLNS_OK);   /* never called */
    CHECK(blns_gpu_list_begin(&dev, &l, 0u) == BLNS_OK);
    blns_gpu_span_begin(&dev, 100u, 0u, 3u);
    blns_gpu_span(&dev, 104u, 2u);
    CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK && blns_gpu_fence_status(&dev, tag) == BLNS_OK);
    blns_gpu_span(&dev, 108u, 2u);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && l.fences == 1u && l.pushes == 4u);
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK && l.tag == 0x900002u);
    CHECK(blns_gpu_list_busy(&dev, &l));
    model_run();
    CHECK(!blns_gpu_list_busy(&dev, &l) && regs.GPU.FENCE == 0x900002u);
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK && l.tag == 0x900004u);
    CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK && tag == 0x900005u);
    CHECK(blns_gpu_wait_fence(&dev, tag) == BLNS_OK && regs.GPU.FENCE == 0x900005u);
    CHECK(m.nd == 4u && drew(&m.d[3], 0xB, 108u, 2u, 1u) && m.d[3].fill == 3u);
    /* overflow: BLNS_ERR_FULL; called, then spilled: every span drawn once */
    model_reset();
    blns_gpu_list_t s = { .addr = 9000u, .capacity = 12u };
    CHECK(blns_gpu_list_begin(&dev, &s, 0u) == BLNS_OK);
    for (int pass = 0; pass < 2; pass++) {
        blns_gpu_span_begin(&dev, 0u, 0u, 7u);
        for (unsigned i = 0; i < 10u; i++)
            blns_gpu_span(&dev, i * 10u, 1u);
        if (pass == 0) {
            CHECK(blns_gpu_list_end(&dev) == BLNS_ERR_FULL && s.overflow);
            CHECK(blns_gpu_list_call(&dev, &s, false) == BLNS_OK);
            CHECK(blns_gpu_list_spill(&dev, &s) == BLNS_OK);
        }
    }
    model_run();
    CHECK(m.nd == 10u);
    for (unsigned i = 0; i < 10u && i < m.nd; i++)
        CHECK(drew(&m.d[i], 0xB, i * 10u, 1u, 1u) && m.d[i].fill == 7u);
    /* a list past the VRAM */
    blns_gpu_list_t bad = { .addr = MODEL_WORDS - 4u, .capacity = 8u };
    CHECK(blns_gpu_list_begin(&dev, &bad, 0u) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_list_end(&dev) == BLNS_ERR_STATE);
}

/* argument checks of the controller calls */
static void test_controller(void)
{
    setup(BLNS_DIF_DPI, 0u);
    CHECK(blns_set_orientation(&dev, 0x8u) == BLNS_ERR_PARAM);
    CHECK(blns_set_orientation(&dev, BLNS_SWAP_X | BLNS_SWAP_Y) == BLNS_OK && regs.DISP_CFG == 6u);
    CHECK(blns_refresh_period(&dev, 0u) == BLNS_ERR_PARAM);
    CHECK(blns_refresh_period(&dev, 1u << 28) == BLNS_ERR_PARAM);
    CHECK(blns_hw_palette(&dev, 8u, 0u, 0u) == BLNS_ERR_PARAM);
    CHECK(blns_irq_enable(&dev, 1u << 20) == BLNS_ERR_PARAM);
    CHECK(blns_lut_load(&dev, 0u, 250u, vram, 7u) == BLNS_ERR_PARAM);
    /* double-buffered palette: the hidden bank, then selected */
    const uint32_t pal[2] = { 0x112233u, 0x445566u };
    CHECK(blns_lut_present(&dev, pal, 2u) == BLNS_OK && regs.LUT[1][1] == 0x445566u &&
          (regs.LUT_CFG & BLNS_LUT_CFG_REFR_BANK_Msk));
    CHECK(blns_lut_present(&dev, pal, 2u) == BLNS_OK && regs.LUT[0][0] == 0x112233u &&
          !(regs.LUT_CFG & BLNS_LUT_CFG_REFR_BANK_Msk));
    /* VRAM helpers */
    CHECK(blns_vram_pa(&dev, blns_vram_ptr(&dev, 1234u)) == 1234u);
    CHECK(blns_vram_contains(&dev, blns_vram_ptr(&dev, 0u)) && !blns_vram_contains(&dev, vram + MODEL_WORDS));
    const blns_surf_t r = blns_surf_rect(&dev, 100u, 320u, 10u, 5u, BLNS_SWAP_X | BLNS_SWAP_Y);
    CHECK(r.addr == 100u + 9u + 4u * 320u && r.swap == (BLNS_SWAP_X | BLNS_SWAP_Y));
    uint16_t img[3][5], back[3][5];
    for (unsigned y = 0; y < 3u; y++)
        for (unsigned x = 0; x < 5u; x++)
            img[y][x] = (uint16_t) (y * 16u + x + 1u);
    CHECK(blns_vram_write_rect(&dev, img, sizeof img[0], 641u, 0u, 5u, 3u) == BLNS_OK);
    const volatile uint16_t *v = blns_vram16(&dev);
    CHECK(v[641] == 1u && v[645] == 5u && v[641 + 320] == 17u && v[641 + 644] == 37u && v[640] == 0u && v[646] == 0u);
    CHECK(blns_vram_read_rect(&dev, 641u, 0u, back, sizeof back[0], 5u, 3u) == BLNS_OK &&
          memcmp(img, back, sizeof img) == 0);
    CHECK(blns_vram_write_rect(&dev, img, 10u, MODEL_WORDS * 2u - 2u, 0u, 5u, 1u) == BLNS_ERR_PARAM);
}

/* the picture policy of the boards (720 x 480 HDMI, a 16:9 display) */
static void test_picture(void)
{
    setup(BLNS_DIF_HDMI, 0u);
    const blns_dpi_timing_t t = BLNS_DPI_720X480_60;
    CHECK(blns_dpi_config(&dev, &t) == BLNS_OK);
    /* 320 x 200 at its own shape (16:10) stretched to 16:9: 646 x 480 */
    CHECK(blns_dpi_image_aspect(&dev, 320u, 200u, 0u, 178u) == BLNS_OK &&
          regs.DPI.IMG_SIZE == (646u | (480u << 16)));
    /* a 4:3 picture: 536 x 480 */
    CHECK(blns_dpi_image_aspect(&dev, 320u, 200u, 133u, 178u) == BLNS_OK &&
          regs.DPI.IMG_SIZE == (536u | (480u << 16)));
    /* no stretch: blns_dpi_fit's size */
    CHECK(blns_dpi_image_aspect(&dev, 320u, 200u, 0u, 0u) == BLNS_OK);
    const uint32_t a = regs.DPI.IMG_SIZE;
    CHECK(blns_dpi_fit(&dev, 320u, 200u) == BLNS_OK && (regs.DPI.IMG_SIZE & 0xFFFF0000u) == (a & 0xFFFF0000u));
    /* the policy without an EDID: the fallback shape, not settled */
    const blns_picture_t p = { .src_w = 320u, .src_h = 200u, .stretch = true, .fallback_x100 = 178u };
    bool settled = true;
    CHECK(blns_dpi_picture(&dev, &p, &settled) == BLNS_OK && !settled &&
          regs.DPI.IMG_SIZE == (646u | (480u << 16)));
    const blns_picture_t q = { .src_w = 320u, .src_h = 200u };
    CHECK(blns_dpi_picture(&dev, &q, &settled) == BLNS_OK && settled);
    /* unchanged values return at once even with an update pending */
    regs.DPI.CFG  = BLNS_DPI_CFG_EN_Msk;
    regs.DPI.CTRL = BLNS_DPI_CTRL_UPDATE_Msk;
    regs.DPI.BORDER = 0x123456u;
    hook_limit = 5u;
    CHECK(blns_dpi_border(&dev, 0x123456u) == BLNS_OK && hook_polls == 0u);
    CHECK(blns_dpi_border(&dev, 0x654321u) == BLNS_ERR_TIMEOUT);
    blns_set_nonblocking(&dev, true);
    CHECK(blns_dpi_border(&dev, 0x654321u) == BLNS_ERR_BUSY);
}

/* Op 15 (FILL_IF_S) on a copy: the session colour, not what a fill left */
static void test_silhouette(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    const blns_surf_t src = { 9000u, 16u, BLNS_SWAP_NONE }, f = { 5000u, 0u, BLNS_SWAP_NONE };
    const blns_surf_t d = { 100u, 0u, BLNS_SWAP_NONE };
    blns_gpu_colour_set(&dev, 7u);
    CHECK(blns_gpu_fill(&dev, &f, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK && last()->fill == 9u);
    CHECK(blns_gpu_copy_transp(&dev, &src, &d, 8u, 8u, BLNS_ROP_FILL_IF_S, 0u) == BLNS_OK &&
          drew(last(), 0xA, 100u, 8u, 8u) && last()->fill == 7u);
    const unsigned w0 = m.words;
    CHECK(blns_gpu_copy_transp(&dev, &src, &d, 8u, 8u, BLNS_ROP_FILL_IF_S, 0u) == BLNS_OK &&
          last()->fill == 7u && m.words - w0 == 3u);            /* SET_DST, base, EXEC: no SET_FILL */
    CHECK(blns_gpu_copy(&dev, &src, &d, 8u, 8u, BLNS_ROP_S) == BLNS_OK);
    CHECK(blns_gpu_fill(&dev, &f, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK);
    const blns_blit_t b = { .rop = BLNS_ROP_FILL_IF_S, .transp = true };
    CHECK(blns_gpu_blit(&dev, &src, &d, 8u, 8u, &b) == BLNS_OK && last()->fill == 7u);
#if !BLNS_HW_OFF(GPU_XY)
    blns_gpu_xy_begin(&dev, 20000u, 100u, 3u);                  /* session colour 3 */
    CHECK(blns_gpu_fill(&dev, &f, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK);
    CHECK(blns_gpu_copy_transp_xy(&dev, &src, 2, 1, 8u, 8u, BLNS_SWAP_NONE, BLNS_ROP_FILL_IF_S, 0u) == BLNS_OK &&
          drew(last(), 0xA, 20102u, 8u, 8u) && last()->fill == 3u);
#endif
    CHECK(!m.overflow);
}

/* blns_flip_wait and blns_vram_ba */
static void test_flip_wait(void)
{
    setup(BLNS_DIF_DPI, 0u);
    CHECK(blns_flip_wait(&dev) == BLNS_OK);                     /* no frames flow */
    regs.DPI.CFG = BLNS_DPI_CFG_EN_Msk;
    CHECK(blns_flip_async(&dev, 1u) == BLNS_OK);                /* LATCHED still 0 */
    hook_runs_gpu = false;
    hook_limit    = 4u;
    CHECK(blns_flip_wait(&dev) == BLNS_ERR_TIMEOUT && hook_polls == 4u);
    regs.FRAME_SEL = (1u << BLNS_FRAME_SEL_REFR_Pos) | (1u << BLNS_FRAME_SEL_LATCHED_Pos);
    CHECK(blns_flip_wait(&dev) == BLNS_OK);
    CHECK(blns_vram_ba(&dev, blns_vram8(&dev) + 100) == 800u);
}

/* Leftover state: ops 13-15 get a defined transparent colour; a remap or mask
 * plane blit needs its pointer set through the API; the per-item calls need
 * their session begun */
static void test_leftover(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    const blns_surf_t src = { 9000u, 16u, BLNS_SWAP_NONE }, d = { 100u, 0u, BLNS_SWAP_NONE };
    /* ops 13-15: a fill or a plain copy compares with transparent 0 */
    CHECK(blns_gpu_copy_transp(&dev, &src, &d, 4u, 4u, BLNS_ROP_S, 5u) == BLNS_OK && last()->transp == 5u);
    CHECK(blns_gpu_fill(&dev, &d, 4u, 4u, 3u, BLNS_ROP_ONES_IF_S) == BLNS_OK && last()->transp == 0u);
    unsigned w0 = m.words;
    CHECK(blns_gpu_fill(&dev, &d, 4u, 4u, 3u, BLNS_ROP_ZERO_IF_S) == BLNS_OK && m.words - w0 == 3u);
    CHECK(blns_gpu_copy_transp(&dev, &src, &d, 4u, 4u, BLNS_ROP_S, 5u) == BLNS_OK);
    CHECK(blns_gpu_copy(&dev, &src, &d, 4u, 4u, BLNS_ROP_ONES_IF_S) == BLNS_OK && last()->transp == 0u &&
          last()->op == 0x9);
    const blns_blit_t b13 = { .rop = BLNS_ROP_ZERO_IF_S, .transparent = 7u };
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &b13) == BLNS_OK && last()->transp == 7u);
    w0 = m.words;
    CHECK(blns_gpu_copy(&dev, &src, &d, 4u, 4u, BLNS_ROP_S) == BLNS_OK && m.words - w0 == 3u);  /* op 0: no SET_TRANSP */
#if !BLNS_HW_OFF(GPU_XY)
    blns_gpu_xy_begin(&dev, 20000u, 100u, 1u);
    CHECK(blns_gpu_copy_xy(&dev, &src, 1, 1, 4u, 4u, BLNS_SWAP_NONE, BLNS_ROP_FILL_IF_S) == BLNS_OK &&
          last()->transp == 0u && last()->fill == 1u);
#endif

    /* sessions: no per-item call before its session */
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    w0 = m.words;
    CHECK(blns_gpu_span(&dev, 10u, 4u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_expand(&dev, 0u, 10u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_tex_span(&dev, 10u, 4u, 0u, 0u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_tex_shade(&dev, 0u) == BLNS_ERR_STATE);
    CHECK(m.words == w0);
    blns_gpu_recover(&dev);                         /* sessions are the driver's: kept */
    CHECK(blns_gpu_span_begin(&dev, 0u, 0u, 2u) == BLNS_OK);
    blns_gpu_recover(&dev);
    CHECK(blns_gpu_span(&dev, 10u, 4u) == BLNS_OK && drew(last(), 0xB, 10u, 4u, 1u) && last()->fill == 2u);

#if BLNS__HW_GPU_REMAP != 0 && BLNS__HW_GPU_MPLANE != 0
    setup(BLNS_DIF_DPI, BLNS_CFG2_REMAP_Msk | BLNS_CFG2_MPLANE_Msk);
    blns_gpu_enable(&dev, true);
    model_run();
    const blns_blit_t rs = { .remap = BLNS_REMAP_SRC }, mp = { .mplane = true };
    const blns_expand_t e = { .width = 8u, .height = 8u, .depth = BLNS_EXP_1BPP, .remap = BLNS_REMAP_DST };
    w0 = m.words;
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_rect(&dev, &d, 4u, 4u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_expand_begin(&dev, &e, 0u, 0u, 1u, 0u) == BLNS_ERR_STATE);
    CHECK(m.words == w0);                           /* nothing sent */
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK && blns_gpu_mask_plane(&dev, 4096u, false) == BLNS_OK);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_OK && blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_OK);
    CHECK(blns_gpu_remap_rect(&dev, &d, 4u, 4u) == BLNS_ERR_PARAM);    /* 16 bpp: it would fill */
    CHECK(blns_set_mode(&dev, BLNS_BPP_8) == BLNS_OK);
    CHECK(blns_gpu_remap_rect(&dev, &d, 4u, 4u) == BLNS_OK);
    blns_gpu_recover(&dev);                         /* a SET_AUX may have been flushed */
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK && blns_gpu_mask_plane(&dev, 4096u, false) == BLNS_OK);
    blns_gpu_enable(&dev, false);                   /* GPU_EN = 0 keeps them; enable resets them */
    blns_gpu_enable(&dev, true);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    blns_gpu_forget(&dev);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    CHECK(blns_gpu_reset_state(&dev) == BLNS_OK && blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);

    /* lists: the rule at record time; a list's pointers apply at its call */
    blns_gpu_list_t l = { .addr = 8000u, .capacity = 64u };
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    CHECK(blns_gpu_list_begin(&dev, &l, 0u) == BLNS_OK);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);     /* a list sets its own */
    CHECK(blns_gpu_remap_table(&dev, 192u) == BLNS_OK && blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && l.aux_set == BLNS__AUX_REMAP);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_OK);              /* the caller's, kept */
    blns_gpu_forget(&dev);
    CHECK(blns_gpu_list_begin(&dev, &l, BLNS_LIST_INHERIT) == BLNS_OK);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);     /* inherited: unknown */
    CHECK(blns_gpu_mask_plane(&dev, 4096u, false) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && l.aux_set == BLNS__AUX_MASK);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_ERR_STATE);     /* not until the call */
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_OK);
    blns_gpu_list_t r = { .addr = 9000u, .capacity = 64u };
    CHECK(blns_gpu_list_begin(&dev, &r, BLNS_LIST_INHERIT) == BLNS_OK && blns_gpu_reset_state(&dev) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && r.aux_clr == (BLNS__AUX_REMAP | BLNS__AUX_MASK | BLNS__AUX_ALPHA));
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_OK);
    CHECK(blns_gpu_list_call(&dev, &r, false) == BLNS_OK && blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_ERR_STATE);

    /* a texture or expansion session with a remap: each draw needs the table
     * pointer still known (the session survives RESET_STATE, a recover, a
     * forget and a list without BLNS_LIST_INHERIT; the pointer does not) */
    const blns_tex_t    tr = { .addr = 9000u, .log2_w = 3u, .log2_h = 3u, .remap = BLNS_REMAP_SRC };
    const blns_expand_t er = { .width = 8u, .height = 8u, .depth = BLNS_EXP_1BPP, .remap = BLNS_REMAP_SRC };
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    CHECK(blns_gpu_tex_begin(&dev, &tr, 100u, 0u, 0u) == BLNS_OK && blns_gpu_tex_span(&dev, 100u, 4u, 0u, 0u) == BLNS_OK);
    CHECK(blns_gpu_expand_begin(&dev, &er, 100u, 0u, 1u, 0u) == BLNS_OK && blns_gpu_expand(&dev, 0u, 108u) == BLNS_OK);
    CHECK(blns_gpu_reset_state(&dev) == BLNS_OK);
    w0 = m.words;
    CHECK(blns_gpu_tex_span(&dev, 100u, 4u, 0u, 0u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_expand(&dev, 0u, 108u) == BLNS_ERR_STATE);
    CHECK(m.words == w0);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    CHECK(blns_gpu_tex_span(&dev, 100u, 4u, 0u, 0u) == BLNS_OK && blns_gpu_expand(&dev, 0u, 108u) == BLNS_OK);
    blns_gpu_recover(&dev);
    CHECK(blns_gpu_tex_span(&dev, 100u, 4u, 0u, 0u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    blns_gpu_forget(&dev);
    CHECK(blns_gpu_expand(&dev, 0u, 108u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    CHECK(blns_gpu_list_begin(&dev, &l, 0u) == BLNS_OK);
    CHECK(blns_gpu_tex_span(&dev, 100u, 4u, 0u, 0u) == BLNS_ERR_STATE);      /* a list sets its own */
    CHECK(blns_gpu_remap_table(&dev, 192u) == BLNS_OK && blns_gpu_tex_span(&dev, 100u, 4u, 0u, 0u) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK);
    CHECK(blns_gpu_expand(&dev, 0u, 108u) == BLNS_OK);                      /* the caller's, kept */
#if BLNS__HW_GPU_TRI != 0
    /* triangles: the table applied to a triangle of the destination (FILL
     * TRI, REMAP DST); a textured triangle takes its texture's remap */
    blns_gpu_xy_begin(&dev, 12000u, 100u, 1u);
    CHECK(blns_gpu_reset_state(&dev) == BLNS_OK);
    w0 = m.words;
    CHECK(blns_gpu_remap_tri_xy(&dev, 0, 0, BLNS_SUB(8), 0, 0, BLNS_SUB(8)) == BLNS_ERR_STATE);
    CHECK(blns_gpu_tex_set(&dev, &tr, 0u) == BLNS_ERR_STATE);
    CHECK(m.words == w0);
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    CHECK(blns_set_mode(&dev, BLNS_BPP_16) == BLNS_OK);
    CHECK(blns_gpu_remap_tri_xy(&dev, 0, 0, BLNS_SUB(8), 0, 0, BLNS_SUB(8)) == BLNS_ERR_PARAM);
    CHECK(blns_set_mode(&dev, BLNS_BPP_8) == BLNS_OK);
    CHECK(blns_gpu_remap_tri_xy(&dev, 0, 0, BLNS_SUB(8), 0, 0, BLNS_SUB(8)) == BLNS_OK && last()->op == 0x8 &&
          (last()->word & (BLNS_GPU_EXEC_TRI_Msk | BLNS_GPU_EXEC_REMAP_Msk | 0xFu)) ==
          (BLNS_GPU_EXEC_TRI_Msk | ((uint32_t) BLNS_REMAP_DST << BLNS_GPU_EXEC_REMAP_Pos)));
    CHECK(blns_gpu_remap_tri_xy(&dev, 0, 0, 40000, 0, 0, BLNS_SUB(8)) == BLNS_ERR_PARAM);
    const int32_t tx[3] = { 0, BLNS_SUB(8), 0 }, ty[3] = { 0, 0, BLNS_SUB(8) };
    CHECK(blns_gpu_tex_set(&dev, &tr, 0u) == BLNS_OK);
    CHECK(blns_gpu_tritex_xy(&dev, tx, ty, 0u, 0u, 2048, 0, 0, 2048) == BLNS_OK && last()->op == 0xE &&
          (last()->tex & BLNS_GPU_TEX_REMAP_Msk) == ((uint32_t) BLNS_REMAP_SRC << BLNS_GPU_TEX_REMAP_Pos));
    CHECK(blns_gpu_reset_state(&dev) == BLNS_OK);
    w0 = m.words;
    CHECK(blns_gpu_tritex_xy(&dev, tx, ty, 0u, 0u, 2048, 0, 0, 2048) == BLNS_ERR_STATE);
    CHECK(blns_gpu_texrect_xy(&dev, 0, 0, 4u, 4u, 0u, 0u, 2048, 0, 0, 2048) == BLNS_ERR_STATE);
    CHECK(blns_gpu_remap_tri_xy(&dev, 0, 0, BLNS_SUB(8), 0, 0, BLNS_SUB(8)) == BLNS_ERR_STATE);
    CHECK(m.words == w0);
#endif
#else
    /* the features stated absent: inline ABSENT */
    const blns_blit_t mp = { .mplane = true };
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &mp) == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_remap_rect(&dev, &d, 4u, 4u) == BLNS_ERR_ABSENT);
#endif
    CHECK(!m.overflow);
}

/*---------------------------------------------------------------------------
 * Recover, fences, errors
 *---------------------------------------------------------------------------*/
static bool draws_at(uint32_t addr, unsigned from)
{
    for (unsigned i = from; i < m.nd; i++)
        if (m.d[i].addr == addr)
            return true;
    return false;
}

/* An interrupt handler that services GPU_ERR (blns_irq_service) */
static void irq_service_err(void)
{
    regs.IRQ_FLAG |= BLNS_IRQ_GPU_ERR_Msk;
    (void) blns_irq_service(&dev, BLNS_IRQ_GPU_ERR_Msk);
}

/* G15 / T2-T3: the model's flush keeps the stream in step as the RTL does:
 * a command cut before its operand is pushed loses that operand */
static void test_model(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    model_cmd(BLNS_GPU_OP_SET_FILL);                    /* its operand not yet pushed */
    model_reg_wr(&regs.GPU.CTRL, BLNS_GPU_CTRL_ABORT_Msk | BLNS_GPU_CTRL_CLEAR_ERR_Msk);
    model_cmd(0x1234u);                                 /* the operand: discarded */
    model_cmd(BLNS_GPU_OP_EXEC_FILL);
    model_run();
    CHECK(m.nd == 1u && m.err == false);
    /* an invalid word stops the decoder: the FIFO no longer drains */
    model_cmd(0u);
    model_cmd(BLNS_GPU_OP_EXEC_FILL);
    model_run();
    CHECK(m.err && m.qn == 1u && (regs.GPU.STAT & BLNS_GPU_STAT_ERR_Msk) && m.nd == 1u);
    model_reg_wr(&regs.GPU.CTRL, BLNS_GPU_CTRL_ABORT_Msk);    /* ABORT alone keeps ERR */
    CHECK(m.err && m.qn == 0u);
    model_reg_wr(&regs.GPU.CTRL, BLNS_GPU_CTRL_CLEAR_ERR_Msk);
    CHECK(!m.err);
}

/* G1: a recover asked from an interrupt while a call pushes touches
 * nothing: the call completes as pushed, the next call performs the recover
 * (its fence reads dropped); no draw with flushed settings */
static void test_recover_irq(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    const blns_surf_t A = { 1000u, 64u, 0u }, B = { 2000u, 64u, 0u }, C = { 3000u, 64u, 0u };
    blns_gpu_fill(&dev, &A, 8u, 8u, 0x11u, BLNS_ROP_S);
    model_run();
    blns_gpu_fill(&dev, &B, 4u, 4u, 0x22u, BLNS_ROP_S);    /* queued, not drawn yet */
    const unsigned d0 = m.nd;
    m.irq    = irq_service_err;
    m.irq_at = (int) m.words + 1;                           /* after C's SET_DST word */
    CHECK(blns_gpu_fill(&dev, &C, 4u, 4u, 0x22u, BLNS_ROP_S) == BLNS_OK);
    uint32_t tag;
    CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK);
    model_run();
    bool bad = false;
    for (unsigned i = d0; i < m.nd; i++)
        bad |= !(m.d[i].w == 4u && m.d[i].h == 4u && m.d[i].fill == 0x22u);
    CHECK(!bad);
    CHECK(blns_gpu_fence_status(&dev, tag) == BLNS_ERR_DROPPED);   /* B and C were dropped */
    /* and the stream is in step: the next fill draws */
    const blns_surf_t E = { 7000u, 64u, 0u };
    CHECK(blns_gpu_fill(&dev, &E, 2u, 3u, 0x44u, BLNS_ROP_S) == BLNS_OK && drew(last(), 0x8, 7000u, 2u, 3u) &&
          last()->fill == 0x44u);
}

#if !BLNS_HW_OFF(GPU_IMM)
/* G2: an interrupt recover during immediate data, or between SET_SRC IMM
 * and its EXEC: no pixel data decoded as commands */
static void test_recover_imm(void)
{
    for (int k = 0; k < 2; k++) {
        setup_fifo(BLNS_DIF_DPI, BLNS_CFG2_IMM_Msk, 6u);
        if (!BLNS_HAS(&dev, GPU_IMM))
            return;
        blns_gpu_enable(&dev, true);
        model_run();
        static uint32_t data[32];
        for (unsigned i = 0; i < 32u; i++)
            data[i] = 0x80000000u;                          /* as words: EXEC_FILL */
        const blns_surf_t D = { 4000u, 64u, 0u };
        const blns_blit_t b = { BLNS_ROP_S, false, 0u, false, BLNS_REMAP_OFF, false };
        const unsigned d0 = m.nd;
        m.irq    = irq_service_err;
        m.irq_at = (int) m.words + (k == 0 ? 6 + 3 : 2);    /* 3 data words in / after N */
        CHECK(blns_gpu_blit_imm(&dev, &D, 8u, 8u, &b, data) == BLNS_OK);
        const blns_surf_t E = { 7000u, 64u, 0u };
        CHECK(blns_gpu_fill(&dev, &E, 2u, 2u, 5u, BLNS_ROP_S) == BLNS_OK);
        model_run();
        unsigned fills = 0;
        for (unsigned i = d0; i < m.nd; i++)
            fills += m.d[i].op == 0x8 && m.d[i].addr != 7000u;
        CHECK(fills == 0u && drew(&m.d[m.nd - 1u], 0x8, 7000u, 2u, 2u) && !m.err);
    }
}
#endif

/* G3: a long push cut between a command and its operand is discarded at
 * once (GPU_CTRL.DISCARD, its marker pending while the FIFO is full): the
 * next call goes on without a recover, its first word not taken as the
 * operand, the words queued before the cut still decoded */
static void test_recover_cut(void)
{
    setup_fifo(BLNS_DIF_DPI, 0u, 3u);                       /* FIFO of 8 words */
    blns_gpu_enable(&dev, true);
    model_run();
    const uint32_t w[10] = { BLNS_GPU_OP_SET_SIZE | 0x4004u, BLNS_GPU_OP_SET_SIZE | 0x4004u,
                             BLNS_GPU_OP_SET_SIZE | 0x4004u, BLNS_GPU_OP_SET_SIZE | 0x4004u,
                             BLNS_GPU_OP_SET_SIZE | 0x4004u, BLNS_GPU_OP_SET_SIZE | 0x4004u,
                             BLNS_GPU_OP_SET_SIZE | 0x4004u, BLNS_GPU_OP_SET_FILL, 0x99u,
                             BLNS_GPU_OP_EXEC_FILL };
    const unsigned pulses = m.en_pulses, aborts = m.aborts;
    hook_runs_gpu = false;
    hook_limit    = 3u;
    CHECK(blns_gpu_push(&dev, w, 10u) == BLNS_ERR_TIMEOUT && !m.owed);  /* cut after SET_FILL */
    CHECK(m.discards == 1u && m.markers == 1u && m.mpend && m.qn == 8u);  /* the FIFO full */
    CHECK((regs.GPU.STAT & BLNS_GPU_STAT_FREE_Msk) == 0u && (regs.GPU.STAT & BLNS_GPU_STAT_FULL_Msk));
    hook_runs_gpu = true;
    hook_limit    = 0u;
    const blns_surf_t E = { 7000u, 64u, 0u };
    CHECK(blns_gpu_fill(&dev, &E, 4u, 4u, 0x33u, BLNS_ROP_S) == BLNS_OK);
    model_run();
    CHECK(drew(last(), 0x8, 7000u, 4u, 4u) && last()->fill == 0x33u && last()->pitch == 64u && !m.err);
    CHECK(!m.mpend && m.qn == 0u && m.en_pulses == pulses && m.aborts == aborts && !m.overflow);
}

/* blns_gpu_discard and the recover: the marker only for a partial stream;
 * the recover is one GPU_CTRL write (ABORT, CLEAR_ERR, DISCARD), no GPU_EN
 * pulse, whatever the push side owed */
static void test_discard(void)
{
    setup_fifo(BLNS_DIF_DPI, 0u, 3u);
    blns_gpu_enable(&dev, true);
    model_run();
    CHECK(blns_gpu_discard(&dev) == BLNS_OK && m.discards == 1u && m.markers == 0u);  /* in step: nothing */
    model_cmd(BLNS_GPU_OP_SET_FILL);                        /* a raw word: its operand owed */
    CHECK(blns_gpu_discard(&dev) == BLNS_OK && m.markers == 1u && m.qn == 2u && !m.owed);
    model_cmd(BLNS_GPU_OP_EXEC_FILL);                       /* a command, not the operand */
    model_run();
    CHECK(m.qn == 0u && !m.err && m.nd == 1u && m.fill == 0u);
    const unsigned pulses = m.en_pulses, aborts = m.aborts, d0 = m.discards;
    model_cmd(BLNS_GPU_OP_SET_DST);                         /* owed again, then recovered */
    CHECK(blns_gpu_recover(&dev) == BLNS_OK);
    CHECK(m.aborts == aborts + 1u && m.discards == d0 + 1u && m.en_pulses == pulses && !m.owed && !m.skip);
    CHECK(m.markers == 1u && m.qn == 0u);                   /* the flush: no marker */
    const blns_surf_t E = { 7000u, 64u, 0u };
    CHECK(blns_gpu_fill(&dev, &E, 2u, 2u, 0x21u, BLNS_ROP_S) == BLNS_OK);
    model_run();
    CHECK(drew(last(), 0x8, 7000u, 2u, 2u) && last()->fill == 0x21u && !m.err);
    /* in ERR: no marker (the CLEAR_ERR flushes), the push side in step */
    model_cmd(0u);                                          /* invalid: ERR */
    model_run();
    model_cmd(BLNS_GPU_OP_SET_FILL);
    CHECK(m.err && blns_gpu_discard(&dev) == BLNS_OK && m.markers == 1u && !m.owed);
    CHECK(blns_gpu_recover(&dev) == BLNS_OK && !m.err);
    CHECK(blns_gpu_fill(&dev, &E, 2u, 2u, 0x22u, BLNS_ROP_S) == BLNS_OK);
    model_run();
    CHECK(drew(last(), 0x8, 7000u, 2u, 2u) && last()->fill == 0x22u && !m.err);
}

/* GPU_FIFO_LOW: the threshold set at init, saturated at the depth, read by
 * blns_gpu_fifo_low; blns_gpu_wait_space moves it to words - 1 while it
 * waits, then back */
static uint32_t thr_seen;
static bool thr_hook(void *ctx)
{
    if (hook_polls == 0u)
        thr_seen = regs.GPU.FIFO_LOW;                       /* at the first hook call */
    return hook(ctx);
}
static void test_fifo_low(void)
{
    setup_fifo(BLNS_DIF_DPI, 0u, 3u);                       /* FIFO of 8 words */
    blns_gpu_enable(&dev, true);
    model_run();
    CHECK(dev.fifo_thr == 4u && m.thresh == 4u && regs.GPU.FIFO_LOW == 4u);
    CHECK(blns_gpu_fifo_low(&dev));
    blns_gpu_fifo_low_set(&dev, 100u);                      /* the depth or more: never */
    CHECK(dev.fifo_thr == 8u && regs.GPU.FIFO_LOW == 8u && !blns_gpu_fifo_low(&dev));
    blns_gpu_fifo_low_set(&dev, 6u);
    CHECK(dev.fifo_thr == 6u && regs.GPU.FIFO_LOW == 6u && blns_gpu_fifo_low(&dev));
    hook_runs_gpu = false;
    for (unsigned i = 0; i < 3u; i++)
        CHECK(blns_gpu_fence(&dev, false, NULL) == BLNS_OK);  /* FREE 5 */
    CHECK(!blns_gpu_fifo_low(&dev));
    hook_runs_gpu = true;
    CHECK(blns_gpu_wait_fifo_low(&dev) == BLNS_OK);         /* the hook drains it */
    hook_runs_gpu = false;
    CHECK(blns_gpu_wait_space(&dev, 9u) == BLNS_ERR_PARAM);
    for (unsigned i = 0; i < 6u; i++)
        CHECK(blns_gpu_fence(&dev, false, NULL) == BLNS_OK);  /* FREE 2 */
    CHECK(blns_gpu_wait_space(&dev, 2u) == BLNS_OK && regs.GPU.FIFO_LOW == 6u);   /* fits: no change */
    hook_runs_gpu = true;
    hook_step     = 1u;
    hook_polls    = 0u;
    dev.wait_hook = thr_hook;
    thr_seen      = 0u;
    blns_gpu_fifo_low_set(&dev, 3u);
    CHECK(blns_gpu_wait_space(&dev, 7u) == BLNS_OK && dev.fifo_free >= 7u);
    CHECK(thr_seen == 6u && regs.GPU.FIFO_LOW == 3u);      /* words - 1 while waiting, then back */
    dev.wait_hook = hook;
    blns_gpu_fifo_low_set(&dev, 6u);
    hook_step = 0u;
    hook_limit = 1u;                                        /* a wait that ends: the threshold back too */
    hook_runs_gpu = false;
    hook_polls = 0u;
    for (unsigned i = 0; i < 8u; i++)
        (void) blns_gpu_fence(&dev, false, NULL);
    CHECK(blns_gpu_wait_space(&dev, 8u) == BLNS_ERR_TIMEOUT && regs.GPU.FIFO_LOW == 6u);
    hook_limit = 0u;
    hook_runs_gpu = true;
    model_run();
    CHECK(blns_gpu_recover(&dev) == BLNS_OK && dev.fifo_thr == 6u);   /* kept */
    CHECK(blns_gpu_enable(&dev, false) == BLNS_OK && blns_gpu_enable(&dev, true) == BLNS_OK && dev.fifo_thr == 6u);
    CHECK(blns_gpu_wait_space(&dev, 1u) == BLNS_OK);
}

/* G4: wait_polls counts the polls without progress, not a whole call */
static void test_poll_budget(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    dev.wait_polls = 10u;
    static uint32_t w[200];
    for (unsigned i = 0; i < 200u; i++)
        w[i] = BLNS_GPU_OP_SET_SIZE | 0x4004u;
    CHECK(blns_gpu_push(&dev, w, 200u) == BLNS_OK && m.discards == 0u);   /* the GPU drains at each poll */
    /* a fence far behind a long queue: GPU_FENCE moving counts as progress */
    uint32_t tag = 0u;
    for (unsigned i = 0; i < 20u; i++)
        CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK);
    CHECK(blns_gpu_wait_fence(&dev, tag) == BLNS_OK);
}

/* A long push writes into whatever room there is: a GPU draining two words a
 * poll, a budget of three polls without progress (waiting for a whole FIFO
 * of room would time out); a call that fits the FIFO still waits for room
 * for all of it (nothing written before) */
static void test_push_stream(void)
{
    setup_fifo(BLNS_DIF_DPI, 0u, 3u);                       /* FIFO of 8 words */
    blns_gpu_enable(&dev, true);
    model_run();
    static uint32_t w[40];
    for (unsigned i = 0; i < 40u; i++)
        w[i] = BLNS_GPU_OP_SET_SIZE | 0x4004u;
    hook_runs_gpu = false;
    CHECK(blns_gpu_push(&dev, w, 8u) == BLNS_OK && m.qn == 8u);  /* the FIFO full */
    hook_runs_gpu = true;
    hook_step     = 2u;
    dev.wait_polls = 3u;
    CHECK(blns_gpu_push(&dev, w, 40u) == BLNS_OK && m.discards == 0u);
    model_run();
    CHECK(m.qn == 0u && !m.err);
    /* a call that fits: nothing written until there is room for all of it */
    hook_runs_gpu = false;
    CHECK(blns_gpu_push(&dev, w, 6u) == BLNS_OK && m.qn == 6u);
    blns_set_nonblocking(&dev, true);
    const unsigned w0 = m.words;
    CHECK(blns_gpu_push(&dev, w, 4u) == BLNS_ERR_BUSY && m.words == w0 && m.qn == 6u);
    blns_set_nonblocking(&dev, false);
    model_run();
}

/* G5: a refused xy_begin changes nothing: the x/y draws keep the surface
 * the GPU has, before and after a forget */
static void test_xy_refused(void)
{
    setup(BLNS_DIF_DPI, 0u);
    if (!BLNS_HAS(&dev, GPU_XY))
        return;
    blns_gpu_enable(&dev, true);
    blns_gpu_xy_begin(&dev, 0u, 320u, 1u);
    blns_gpu_fill_xy(&dev, 0, 0, 2u, 2u);
    model_run();
    hook_runs_gpu = false;
    for (int i = 1; i <= (int) (m.depth - 2u) / 2; i++)
        blns_gpu_fill_xy(&dev, 10 * i, 0, 2u, 2u);          /* the FIFO but 2 words queued */
    blns_set_nonblocking(&dev, true);
    CHECK(blns_gpu_xy_begin(&dev, 8000u, 100u, 9u) == BLNS_ERR_BUSY);
    blns_set_nonblocking(&dev, false);
    hook_runs_gpu = true;
    model_run();
    CHECK(blns_gpu_fill_xy(&dev, 1, 1, 2u, 2u) == BLNS_OK && drew(last(), 0x8, 321u, 2u, 2u) && last()->fill == 1u);
    blns_gpu_forget(&dev);
    CHECK(blns_gpu_fill_xy(&dev, 1, 1, 2u, 2u) == BLNS_OK && drew(last(), 0x8, 321u, 2u, 2u) && last()->fill == 1u);
}

/* G6, G9, A1: a fence dropped by a recover reads dropped (wait_fence returns
 * at once), the tags are not reused, a fence reached before reads OK */
static void test_fence_drop(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    uint32_t t0, t1, t2;
    CHECK(blns_gpu_fence(&dev, false, &t0) == BLNS_OK);
    model_run();                                            /* t0 reached */
    hook_runs_gpu = false;
    CHECK(blns_gpu_fence(&dev, false, &t1) == BLNS_OK);    /* t1 still queued */
    CHECK(blns_gpu_fence_status(&dev, t1) == BLNS_ERR_BUSY);
    CHECK(blns_gpu_recover(&dev) == BLNS_OK);
    hook_runs_gpu = true;
    dev.wait_polls = 1000u;
    hook_polls = 0u;
    CHECK(blns_gpu_wait_fence(&dev, t1) == BLNS_ERR_DROPPED && hook_polls < 5u);
    CHECK(blns_gpu_fence_status(&dev, t0) == BLNS_OK);
    CHECK(blns_gpu_fence(&dev, false, &t2) == BLNS_OK);
    model_run();
    CHECK((t2 & BLNS_GPU_FENCE_TAG_Msk) != (t1 & BLNS_GPU_FENCE_TAG_Msk));       /* no tag reused */
    CHECK(blns_gpu_fence_done(&dev, t1) && blns_gpu_fence_status(&dev, t1) == BLNS_ERR_DROPPED);
    CHECK(blns_gpu_fence_status(&dev, t2) == BLNS_OK);
    /* two losses: a fence older than both reads dropped (conservative) */
    blns_gpu_recover(&dev);
    hook_runs_gpu = false;
    uint32_t t3;
    blns_gpu_fence(&dev, false, &t3);
    blns_gpu_recover(&dev);
    blns_gpu_fence(&dev, false, &t3);
    blns_gpu_recover(&dev);
    hook_runs_gpu = true;
    CHECK(blns_gpu_fence_status(&dev, t1) == BLNS_ERR_DROPPED);
}

/* A1 / L2: draws pushed, a recover requested (interrupt), then the fence:
 * the recover runs in the fence call and the fence reads dropped */
static void test_fence_lost_batch(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    hook_runs_gpu = false;
    const blns_surf_t A = { 1000u, 64u, 0u };
    blns_gpu_fill(&dev, &A, 8u, 8u, 0x11u, BLNS_ROP_S);    /* queued */
    irq_service_err();                                      /* GPU_ERR serviced elsewhere */
    uint32_t tag;
    CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK);
    hook_runs_gpu = true;
    model_run();
    CHECK(!draws_at(1000u, 0u) && blns_gpu_fence_status(&dev, tag) == BLNS_ERR_DROPPED);
    /* the batch after it is whole again */
    blns_gpu_fill(&dev, &A, 8u, 8u, 0x12u, BLNS_ROP_S);
    CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK && blns_gpu_wait_fence(&dev, tag) == BLNS_OK);
    CHECK(draws_at(1000u, 0u));
}

/* L1 basis (G15 / T2): an error after acceptance (cause 5): the fence reads
 * BLNS_ERR_GPU, and dropped after the recover */
static void test_fence_error(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const blns_surf_t far = { MODEL_WORDS * 2u - 4u, 64u, 0u };    /* past the VRAM */
    CHECK(blns_gpu_fill(&dev, &far, 8u, 8u, 1u, BLNS_ROP_S) == BLNS_OK);
    uint32_t tag;
    CHECK(blns_gpu_fence(&dev, false, &tag) == BLNS_OK);
    model_run();
    blns_gpu_err_t e;
    blns_gpu_error(&dev, &e);
    CHECK(e.cause == BLNS_GPU_ERR_BOUNDS && e.opcode == 0x8u);
    CHECK(blns_gpu_fence_status(&dev, tag) == BLNS_ERR_GPU && blns_gpu_wait_fence(&dev, tag) == BLNS_ERR_GPU);
    CHECK(blns_gpu_recover(&dev) == BLNS_OK && blns_gpu_fence_status(&dev, tag) == BLNS_ERR_DROPPED);
    /* an unreachable tag on an idle GPU: BLNS_ERR_STATE, not a wait for ever */
    model_run();
    CHECK(blns_gpu_fence_status(&dev, (dev.fence_tag + 5u) | ((uint32_t) dev.epoch << 24)) == BLNS_ERR_STATE);
}

/* G6: a list whose call was dropped is no longer busy; GPU_EN = 0 drops
 * like a recover */
static void test_fence_list_enable(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    blns_gpu_list_t l = { .addr = 8000u, .capacity = 64u };
    blns_gpu_list_begin(&dev, &l, BLNS_LIST_INHERIT);
    blns_gpu_span_begin(&dev, 100u, 0u, 3u);
    blns_gpu_span(&dev, 104u, 2u);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK);
    hook_runs_gpu = false;
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK && blns_gpu_list_busy(&dev, &l));
    blns_gpu_recover(&dev);
    hook_runs_gpu = true;
    model_run();
    CHECK(!blns_gpu_list_busy(&dev, &l) && blns_gpu_list_wait(&dev, &l) == BLNS_ERR_DROPPED);
    /* GPU_EN = 0 with a fence pending */
    uint32_t t1, t2;
    hook_runs_gpu = false;
    CHECK(blns_gpu_fence(&dev, false, &t1) == BLNS_OK);
    CHECK(blns_gpu_enable(&dev, false) == BLNS_OK && blns_gpu_fence_status(&dev, t1) == BLNS_ERR_DROPPED);
    hook_runs_gpu = true;
    CHECK(blns_gpu_enable(&dev, true) == BLNS_OK);
    CHECK(blns_gpu_fence(&dev, false, &t2) == BLNS_OK && blns_gpu_wait_fence(&dev, t2) == BLNS_OK);
    CHECK((t2 & BLNS_GPU_FENCE_TAG_Msk) != (t1 & BLNS_GPU_FENCE_TAG_Msk) && blns_gpu_fence_done(&dev, t1));
}

/* G8, G12, G14: a list call during a spill is pushed; the tag of a fence
 * recorded reads reached; a recover ends a spill */
static void test_fence_lists(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    RW(regs.GPU.FENCE) = 0x900000u;                         /* past 2^23 */
    reinit();
    dev.wait_polls = 1000u;                                 /* a wait never ends the test */
    blns_gpu_enable(&dev, true);
    model_run();
    blns_gpu_list_t l = { .addr = 10000u, .capacity = 8u };
    const blns_surf_t S = { 100u, 64u, 0u };
    CHECK(blns_gpu_list_begin(&dev, &l, BLNS_LIST_INHERIT) == BLNS_OK);
    uint32_t rt;
    CHECK(blns_gpu_fence(&dev, false, &rt) == BLNS_OK);
    CHECK(blns_gpu_fence_done(&dev, rt) && blns_gpu_fence_status(&dev, rt) == BLNS_OK);    /* G12 */
    blns_gpu_fill(&dev, &S, 2u, 2u, 1u, BLNS_ROP_S);
    blns_gpu_fill(&dev, &S, 4u, 4u, 2u, BLNS_ROP_S);       /* overflows */
    CHECK(blns_gpu_list_end(&dev) == BLNS_ERR_FULL);
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK);
    model_run();
    CHECK(blns_gpu_list_spill(&dev, &l) == BLNS_OK);
    const unsigned w0 = m.words;
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK && m.words > w0);      /* G8 */
    CHECK(blns_gpu_list_wait(&dev, &l) == BLNS_OK);
    /* G14: a recover during the spill ends it: the calls are drawn */
    blns_gpu_list_spill(&dev, &l);
    blns_gpu_recover(&dev);
    const unsigned d0 = m.nd;
    blns_gpu_fill(&dev, &S, 2u, 2u, 1u, BLNS_ROP_S);
    model_run();
    CHECK(m.nd == d0 + 1u);
}

/* G11: raw words may reset the pointers: a remap blit after them needs the
 * table again */
static void test_raw_push(void)
{
#if BLNS__HW_GPU_REMAP != 0
    setup(BLNS_DIF_DPI, BLNS_CFG2_REMAP_Msk);
    if (!BLNS_HAS(&dev, GPU_REMAP))
        return;
    blns_gpu_enable(&dev, true);
    const blns_surf_t src = { 9000u, 16u, 0u }, d = { 100u, 0u, 0u };
    const blns_blit_t rs = { .remap = BLNS_REMAP_SRC };
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK && blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_OK);
    const uint32_t rst = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_EXT2 | BLNS_GPU_EXT2_RESET_STATE;
    CHECK(blns_gpu_push(&dev, &rst, 1u) == BLNS_OK);
    CHECK(blns_gpu_blit(&dev, &src, &d, 4u, 4u, &rs) == BLNS_ERR_STATE);
#endif
}

/* G13: one ERR policy: tested where a call waits for FIFO room; words that
 * fit go in (the recover drops them) */
static void test_err_policy(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const uint32_t bad = 0u;
    CHECK(blns_gpu_push(&dev, &bad, 1u) == BLNS_OK);
    model_run();                                            /* stopped: cause 1 */
    const blns_surf_t s = { 100u, 0u, 0u };
    blns_status_t st = BLNS_OK;
    unsigned      n  = 0;
    while (st == BLNS_OK && n < 20u) {
        st = blns_gpu_fill(&dev, &s, 2u, 2u, 1u, BLNS_ROP_S);
        n++;
        model_run();
    }
    CHECK(st == BLNS_ERR_GPU && n > 1u && !m.overflow);
    CHECK(blns_gpu_recover(&dev) == BLNS_OK && blns_gpu_fill(&dev, &s, 2u, 2u, 1u, BLNS_ROP_S) == BLNS_OK);
    CHECK(drew(last(), 0x8, 100u, 2u, 2u));
}

/* D9: a present whose copy finds no room sends neither the wait nor the copy */
static void test_present(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    regs.DPI.CFG = BLNS_DPI_CFG_EN_Msk;                     /* frames flow */
    hook_runs_gpu = false;
    uint32_t sz[64];
    for (unsigned i = 0; i < m.depth - 2u; i++)
        sz[i] = BLNS_GPU_OP_SET_SIZE | 0x4004u;
    blns_gpu_push(&dev, sz, m.depth - 2u);                  /* 2 words free */
    blns_set_nonblocking(&dev, true);
    const blns_surf_t a = { 0u, 0u, 0u }, b = { 20000u, 0u, 0u };
    const unsigned w0 = m.words;
    bool waited = false;
    CHECK(blns_gpu_present_copy(&dev, &a, &b, 16u, 16u, BLNS_PRESENT_VSYNC, &waited) == BLNS_ERR_BUSY);
    CHECK(m.words == w0);
    blns_set_nonblocking(&dev, false);
    hook_runs_gpu = true;
    model_run();
    CHECK(blns_gpu_present_copy(&dev, &a, &b, 16u, 16u, BLNS_PRESENT_VSYNC, &waited) == BLNS_OK && waited);
    CHECK(drew(last(), 0x9, 20000u, 16u, 16u));
}

/* I2: frames that stop flowing end a frame wait */
static unsigned frame_hook_polls;
static bool frame_hook(void *ctx)
{
    (void) ctx;
    if (++frame_hook_polls == 1u) {                         /* the one-shot frame ends */
        RW(regs.FRAME_NUM) = regs.FRAME_NUM + 1u;
        regs.REFRESH       = 0u;
        RW(regs.STATUS)    = 0u;
    }
    return frame_hook_polls > 1000u;
}

static void test_wait_frames(void)
{
    setup(BLNS_DIF_DBI_PAR, 0u);
    dev.wait_hook = frame_hook;
    frame_hook_polls = 0u;
    blns_refresh_once(&dev);
    CHECK(blns_wait_frames(&dev, 2u) == BLNS_ERR_STATE && frame_hook_polls < 5u);
    regs.REFRESH = BLNS_REFRESH_START_Msk;
    frame_hook_polls = 0u;
    CHECK(blns_wait_frames(&dev, 1u) == BLNS_OK);
}

/*---------------------------------------------------------------------------
 * Sessions and drawing helpers (Groups 2 and 6)
 *---------------------------------------------------------------------------*/

/* D1: each session keeps its own destination pitch; the address-mode
 * per-item calls need their *_begin (tex_set / expand_set give none) */
static void test_session_pitch(void)
{
    setup(BLNS_DIF_DPI, 0u);
    CHECK(blns_set_mode(&dev, BLNS_BPP_8) == BLNS_OK);
    blns_gpu_enable(&dev, true);
    const blns_expand_t e = { .width = 8u, .height = 8u, .depth = BLNS_EXP_1BPP };
    CHECK(blns_gpu_expand_begin(&dev, &e, 0u, 320u, 5u, 0u) == BLNS_OK);
    const blns_tex_t t = { .addr = 0x1000u, .log2_w = 6u, .log2_h = 6u };
    CHECK(blns_gpu_tex_begin(&dev, &t, 50000u, 64u, 0u) == BLNS_OK);
    CHECK(blns_gpu_expand(&dev, 0x8000u, 320u * 100u + 8u) == BLNS_OK && last()->pitch == 320u);
    CHECK(blns_gpu_expand(&dev, 0x8040u, 320u * 100u + 16u) == BLNS_OK && last()->pitch == 320u &&
          last()->addr == 320u * 100u + 16u);
    CHECK(blns_gpu_tex_span(&dev, 50064u, 8u, 0u, 0u) == BLNS_OK && last()->pitch == 64u);
    /* tex_span after tex_set alone: no destination pitch */
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    blns_gpu_span_begin(&dev, 0u, 1000u, 1u);
    CHECK(blns_gpu_tex_set(&dev, &t, 0u) == BLNS_OK);
    const unsigned w0 = m.words;
    CHECK(blns_gpu_tex_span(&dev, 9000u, 16u, 0u, 0u) == BLNS_ERR_STATE && m.words == w0);
    CHECK(blns_gpu_expand_set(&dev, &e, 1u, 0u) == BLNS_OK || !BLNS_HAS(&dev, GPU_XY));
    CHECK(blns_gpu_expand(&dev, 0u, 9000u) == BLNS_ERR_STATE);
}

/* D8 / G7: the inline span needs span_begin as the out-of-line one does */
static void test_span_session(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    const blns_surf_t s = { 100u, 0u, 0u };
    CHECK(blns_gpu_fill(&dev, &s, 2u, 2u, 0u, BLNS_ROP_S) == BLNS_OK);   /* colour 0 = ses_fill 0 */
    CHECK(blns_gpu_span(&dev, 200u, 3u) == BLNS_ERR_STATE);
    CHECK(blns__gpu_span(&dev, 300u, 3u) == BLNS_ERR_STATE);
}

/* Commit on OK: a refused *_begin / *_set / step / shade changes no session */
static void test_session_commit(void)
{
    setup(BLNS_DIF_DPI, 0u);
    CHECK(blns_set_mode(&dev, BLNS_BPP_8) == BLNS_OK);
    blns_gpu_enable(&dev, true);
    CHECK(blns_gpu_span_begin(&dev, 1000u, 0u, 3u) == BLNS_OK);
    const blns_tex_t t = { .addr = 0x1000u, .log2_w = 6u, .log2_h = 6u };
    CHECK(blns_gpu_tex_begin(&dev, &t, 3000u, 0u, 0u) == BLNS_OK && blns_gpu_tex_step(&dev, 0x100, 0) == BLNS_OK);
    model_run();
    hook_runs_gpu = false;
    uint32_t sz[64];
    for (unsigned i = 0; i < m.depth; i++)
        sz[i] = BLNS_GPU_OP_SET_SIZE | 0x4004u;
    blns_gpu_push(&dev, sz, m.depth);                       /* no room */
    blns_set_nonblocking(&dev, true);
    CHECK(blns_gpu_span_begin(&dev, 5000u, 64u, 9u) == BLNS_ERR_BUSY);
    CHECK(blns_gpu_tex_step(&dev, 0x200, 0) == BLNS_ERR_BUSY);
    CHECK(blns_gpu_tex_shade(&dev, 2u) == BLNS_ERR_BUSY);
    blns_set_nonblocking(&dev, false);
    hook_runs_gpu = true;
    model_run();
    CHECK(blns_gpu_span(&dev, 1010u, 4u) == BLNS_OK && drew(last(), 0xB, 1010u, 4u, 1u) && last()->fill == 3u);
    CHECK(blns_gpu_tex_span(&dev, 3000u, 8u, 0u, 0u) == BLNS_OK && last()->step == 0x01000000u &&
          (last()->tex & BLNS_GPU_TEX_SHADE_Msk) == 0u);
}

/* D2: tex_shade after a RESET_STATE (and in a list) sends the box again */
static void test_tex_box(void)
{
#if !BLNS_HW_OFF(GPU_XY)
    setup(BLNS_DIF_DPI, 0u);
    if (!BLNS_HAS(&dev, GPU_XY))
        return;
    CHECK(blns_set_mode(&dev, BLNS_BPP_8) == BLNS_OK);
    blns_gpu_enable(&dev, true);
    const blns_tex_t t = { .addr = 0x1000u, .log2_w = 6u, .log2_h = 6u, .bound = true, .box_w = 40u, .box_h = 30u };
    const uint32_t box = BLNS_GPU_XY(40u, 30u);
    blns_gpu_xy_begin(&dev, 0u, 0u, 1u);
    CHECK(blns_gpu_tex_set(&dev, &t, 0u) == BLNS_OK);
    CHECK(blns_gpu_texrect_xy(&dev, 10, 10, 20u, 20u, 0u, 0u, 2048, 0, 0, 2048) == BLNS_OK && last()->texbox == box);
    blns_gpu_reset_state(&dev);
    blns_gpu_xy_begin(&dev, 0u, 0u, 1u);
    CHECK(blns_gpu_tex_shade(&dev, 3u) == BLNS_OK);
    CHECK(blns_gpu_texrect_xy(&dev, 10, 10, 20u, 20u, 0u, 0u, 2048, 0, 0, 2048) == BLNS_OK && last()->texbox == box);
    /* in a list */
    blns_gpu_list_t l = { .addr = 8192u, .capacity = 512u };
    CHECK(blns_gpu_list_begin(&dev, &l, 0u) == BLNS_OK);
    blns_gpu_xy_begin(&dev, 0u, 0u, 1u);
    blns_gpu_tex_shade(&dev, 3u);
    blns_gpu_texrect_xy(&dev, 10, 10, 20u, 20u, 0u, 0u, 2048, 0, 0, 2048);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK);
    blns_gpu_reset_state(&dev);
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK && last()->texbox == box);
    /* D7: fields that would wrap are refused */
    const blns_tex_t big = { .addr = 0x1000u, .log2_w = 16u, .log2_h = 6u };
    const blns_tex_t box4k = { .addr = 0x1000u, .log2_w = 6u, .log2_h = 6u, .bound = true, .box_w = 4096u, .box_h = 600u };
    CHECK(blns_gpu_tex_set(&dev, &big, 0u) == BLNS_ERR_PARAM && blns_gpu_tex_set(&dev, &box4k, 0u) == BLNS_ERR_PARAM);
#endif
}

/* D3: an expansion session with a side of 0 draws nothing */
static void test_expand_empty(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const blns_expand_t e0 = { .width = 0u, .height = 8u, .depth = BLNS_EXP_1BPP };
    CHECK(blns_gpu_expand_begin(&dev, &e0, 1000u, 0u, 5u, 0u) == BLNS_OK);
    CHECK(blns_gpu_expand(&dev, 0x8000u, 1000u) == BLNS_OK);
    CHECK(blns_gpu_expand(&dev, 0x8000u, 1008u) == BLNS_OK);
#if !BLNS_HW_OFF(GPU_IMM)
    if (BLNS_HAS(&dev, GPU_IMM))
        CHECK(blns_gpu_expand_imm(&dev, 1000u, NULL) == BLNS_OK);
#endif
    model_run();
    CHECK(m.nd == 0u);
}

/* D4: the UV gradients round alike for both windings */
static void test_tri_gradients(void)
{
    const int32_t x[3] = { 0, 160, 0 }, y[3] = { 0, 0, 160 }, xr[3] = { 0, 0, 160 }, yr[3] = { 0, 160, 0 };
    const int32_t u[3] = { 0, 3, 0 }, v[3] = { 0, 0, 0 }, ur[3] = { 0, 0, 3 };
    int16_t g[4], gr[4];
    CHECK(blns_gpu_tri_uv_gradients(x, y, u, v, g) && blns_gpu_tri_uv_gradients(xr, yr, ur, v, gr));
    CHECK(g[0] == 10 && gr[0] == 10);                       /* 9.6 */
    const int32_t un[3] = { 0, -3, 0 }, unr[3] = { 0, 0, -3 };
    CHECK(blns_gpu_tri_uv_gradients(x, y, un, v, g) && blns_gpu_tri_uv_gradients(xr, yr, unr, v, gr));
    CHECK(g[0] == -10 && gr[0] == -10);
}

/* D5, D6, T4: blns_surf_rect resolves pitch 0 and follows CL; the pixels of
 * the fills land in the rectangle */
static unsigned px_count(uint32_t v)
{
    unsigned n = 0;
    for (unsigned i = 0; i < MODEL_WORDS * 2u; i++)
        n += ((uint16_t *) vram)[i] == v;
    return n;
}

static void test_surf_rect(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    blns_surf_t r = blns_surf_rect(&dev, 1000u, 0u, 10u, 5u, BLNS_SWAP_Y);
    CHECK(r.addr == 1000u + 4u * 320u && r.pitch == 320u);
    r = blns_surf_rect(&dev, 1000u, 320u, 10u, 5u, BLNS_SWAP_CL | BLNS_SWAP_X);    /* 5 columns, 10 lines */
    CHECK(r.addr == 1000u + 4u);
    r = blns_surf_rect(&dev, 1000u, 320u, 10u, 5u, BLNS_SWAP_CL | BLNS_SWAP_Y);
    CHECK(r.addr == 1000u + 9u * 320u);
    /* the pixels: every walk of a 10 x 5 GPU rectangle covers the same area */
    for (uint8_t sw = 0; sw < 8u; sw++) {
        memset(vram, 0, sizeof vram);
        const blns_surf_t s = blns_surf_rect(&dev, 1000u, 0u, 10u, 5u, sw);
        CHECK(blns_gpu_fill(&dev, &s, 10u, 5u, 0x7777u, BLNS_ROP_S) == BLNS_OK);
        model_run();
        const volatile uint16_t *p = blns_vram16(&dev);
        const unsigned cols = (sw & BLNS_SWAP_CL) ? 5u : 10u, rows = (sw & BLNS_SWAP_CL) ? 10u : 5u;
        CHECK(px_count(0x7777u) == 50u && p[1000] == 0x7777u && p[1000 + (rows - 1u) * 320u + cols - 1u] == 0x7777u);
    }
    /* D10: a pointer far past the window is not in it */
    CHECK(!blns_vram_contains(&dev, (const volatile void *) ((uintptr_t) vram + ((uintptr_t) 1u << (sizeof(uintptr_t) > 4u ? 32u : 31u)))));
}

/* A5: BLNS_HAS evaluates its handle at most once */
static unsigned has_evals;
static const blns_t *has_dev(void)
{
    has_evals++;
    return &dev;
}

static void test_has_once(void)
{
    setup(BLNS_DIF_DPI, 0u);
    has_evals = 0u;
    const bool a = BLNS_HAS(has_dev(), DPI);
    const bool b = BLNS_HAS(has_dev(), DBI);
    CHECK(has_evals <= 2u && (a || !b));
}

/*---------------------------------------------------------------------------
 * Display (Group 5, I4-I7)
 *---------------------------------------------------------------------------*/

/* I4: GFX_MODE 5-7 left by a previous program is 16 bpp, as the hardware */
static void test_init_mode(void)
{
    setup(BLNS_DIF_DPI, 0u);
    regs.CTRL = 5u;
    const blns_config_t cfg = { .reg_base = (uintptr_t) &regs, .vram_base = (uintptr_t) vram, .wait_hook = hook };
    CHECK(blns_init(&dev, &cfg) == BLNS_OK && dev.mode == BLNS_BPP_16 &&
          (regs.CTRL & BLNS_CTRL_GFX_MODE_Msk) == BLNS_BPP_16);
}

/* I1: a plug landing between the two hot-plug reads of a poll */
static int hp_plug_at;
static void hp_plug(void)
{
    if (hp_plug_at > 0 && --hp_plug_at == 0) {          /* just after this read */
        RW(regs.DPI.STATUS) = BLNS_DPI_STATUS_PRESENT_Msk;
        regs.DPI.IRQ_FLAG  |= BLNS_DPI_IRQ_DETECT_Msk;
    }
}

static unsigned hp_run(blns_hotplug_t *hp, uint32_t *t, unsigned polls, bool force)
{
    unsigned r = 0;
    for (unsigned i = 0; i < polls; i++) {
        *t += 10u;
        r += blns_dpi_hotplug_poll(&dev, hp, *t, force) == BLNS_HP_RESTARTED;
    }
    return r;
}

static void hp_line(bool up)
{
    const bool was = (regs.DPI.STATUS & BLNS_DPI_STATUS_PRESENT_Msk) != 0u;
    RW(regs.DPI.STATUS) = up ? BLNS_DPI_STATUS_PRESENT_Msk : 0u;
    if (was != up)
        regs.DPI.IRQ_FLAG |= BLNS_DPI_IRQ_DETECT_Msk;
}

static void test_hotplug(void)
{
    if (BLNS__HW_DPI == 0)
        return;
    setup(BLNS_DIF_HDMI, 0u);
    if (dev.caps.dif_type != BLNS_DIF_HDMI)
        return;
    blns_hotplug_t hp = { .low_ms = 1000u, .quiet_ms = 5000u, .settle_ms = 500u, .off_ms = 1000u,
                          .probe_every_ms = 1000000u, .probe_ms = 200u, .wake_ms = 10000u };
    uint32_t t = 0;
    blns_dpi_hotplug_init(&dev, &hp, 0u);
    hp_run(&hp, &t, 6000u, false);                          /* low for 60 s */
    hp_plug_at = 1;
    m.hp_rd    = hp_plug;
    CHECK(hp_run(&hp, &t, 2000u, false) == 1u);             /* one restart */
    m.hp_rd = NULL;
    /* I9: force during SETTLE is kept until IDLE */
    hp_line(false);
    hp_run(&hp, &t, 600u, false);                           /* low 6 s */
    hp_line(true);
    hp_run(&hp, &t, 2u, false);                             /* SETTLE */
    CHECK(hp.state == 1u);
    CHECK(hp_run(&hp, &t, 1u, true) + hp_run(&hp, &t, 300u, false) == 2u);  /* the settle and the forced */
    /* I9: a short drop starting while the link is off (quiet_ms 0) is not
     * taken as a long one */
    blns_hotplug_t q = { .low_ms = 1000u, .quiet_ms = 0u, .settle_ms = 100u, .off_ms = 500u,
                         .probe_every_ms = 2000u, .probe_ms = 200u, .wake_ms = 10000u };
    t = 0;
    hp_line(true);
    blns_dpi_hotplug_init(&dev, &q, 0u);
    hp_line(false);
    hp_run(&q, &t, 300u, false);
    hp_line(true);
    unsigned n = 0;
    while (q.state != 2u && n++ < 100u)                     /* the plug: SETTLE, then the link off */
        hp_run(&q, &t, 1u, false);
    hp_line(false);                                         /* the TV drops the line meanwhile */
    CHECK(q.state == 2u && hp_run(&q, &t, 60u, false) == 1u);       /* restarted */
    hp_line(true);                                          /* low for about 0.6 s */
    CHECK(hp_run(&q, &t, 300u, false) == 0u);
    /* I8: a placement refused (an update pending) is tried again */
    static const blns_picture_t pic = { .src_w = 320u, .src_h = 240u };
    const blns_dpi_timing_t tm = BLNS_DPI_640X480_60;
    CHECK(blns_dpi_config(&dev, &tm) == BLNS_OK);
    q.picture = &pic;
    q.settled = false;
    regs.DPI.IMG_SIZE = 0u;
    regs.DPI.CFG |= BLNS_DPI_CFG_EN_Msk;
    regs.DPI.CTRL = BLNS_DPI_CTRL_UPDATE_Msk;               /* an update pending */
    blns_set_nonblocking(&dev, true);
    CHECK(hp_run(&q, &t, 1u, true) == 0u);
    CHECK(hp_run(&q, &t, 60u, false) == 1u && !q.settled && regs.DPI.IMG_SIZE == 0u);
    regs.DPI.CTRL = 0u;                                     /* taken */
    hp_run(&q, &t, 2u, false);
    CHECK(q.settled && regs.DPI.IMG_SIZE != 0u);
    blns_set_nonblocking(&dev, false);
}

/* I3, I10, I11: the DDC master: bus clear, repeated START set-up, n = 0 */
static void test_ddc(void)
{
#if !BLNS_HW_OFF(DPI_DDC)
    setup(BLNS_DIF_HDMI, 0u);
    if (!BLNS_HAS(&dev, DPI_DDC))
        return;
    static const uint8_t hdr[8] = { 0x00u, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0x00u };
    memcpy(ddc.mem, hdr, 8u);
    ddc.mem[21] = 52u;                                      /* 52 x 29 cm */
    ddc.mem[22] = 29u;
    uint8_t sum = 0u;
    for (unsigned i = 0; i < 127u; i++)
        sum = (uint8_t) (sum + ddc.mem[i]);
    ddc.mem[127] = (uint8_t) (0u - sum);
    blns_edid_t e;
    CHECK(blns_dpi_edid_read(&dev, ddc_quarter, &e) == BLNS_OK && e.aspect_x100 == 179u);
    CHECK(ddc.setup_min >= 2u);                             /* 4.7 us: two quarters */
    /* a device cut in the middle of a byte it sends holds SDA low */
    ddc.st = I2C_RBYTE; ddc.offset = 0u; ddc.bit = 2u; ddc.sda_s = false;
    CHECK(blns_dpi_edid_read(&dev, ddc_quarter, &e) == BLNS_OK && e.blocks == 1u);
    /* n = 0: the bus is left idle */
    uint8_t b;
    CHECK(blns_dpi_ddc_read(&dev, ddc_quarter, BLNS_EDID_ADDR, 0u, &b, 0u) == BLNS_OK);
    CHECK(ddc.st == I2C_IDLE && ddc.sda_s && ddc.scl_m && ddc.sda_m);
#endif
}

/* I5, I6, I7: SPD strings, EDID sizes, a fit without a timing */
static void test_dpi_params(void)
{
    if (BLNS__HW_DPI == 0)
        return;
    setup(BLNS_DIF_HDMI, 0u);
    CHECK(blns_dpi_fit(&dev, 320u, 240u) == BLNS_ERR_STATE);
    CHECK(blns_dpi_image_aspect(&dev, 320u, 240u, 0u, 0u) == BLNS_ERR_STATE);
    blns_edid_t e;
    memset(&e, 0, sizeof e);
    static const uint8_t hdr[8] = { 0x00u, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0x00u };
    memcpy(e.raw, hdr, 8u);
    uint8_t *d = e.raw + 54;
    d[0] = 0x01u; d[1] = 0x1Du; d[2] = 0x00u; d[4] = 0x50u; d[5] = 0xD0u; d[7] = 0x20u;
    d[12] = 0xFFu; d[13] = 0x06u; d[14] = 0xF0u;            /* 4095 x 6 mm */
    uint8_t sum = 0u;
    for (unsigned i = 0; i < 127u; i++)
        sum = (uint8_t) (sum + e.raw[i]);
    e.raw[127] = (uint8_t) (0u - sum);
    e.blocks   = 1u;
    CHECK(blns_dpi_edid_parse(&e) == BLNS_OK && e.aspect_x100 == 0u);
    CHECK(e.quant_select == 0u && blns_avi_quant_auto(&e) == BLNS_AVI_QUANT_DEFAULT);
    CHECK(blns_avi_quant_auto(NULL) == BLNS_AVI_QUANT_DEFAULT);
    /* CTA-861 extension in block 1: an audio block, then a Video Capability
     * Data Block (extended tag 7, code 0x00) with QS = 1 */
    {
        uint8_t *x = e.raw + BLNS_EDID_BLOCK;
        static const uint8_t qs1[] = { 0x02u, 0x03u, 0x0Bu, 0x00u,
                                       0x23u, 0x09u, 0x07u, 0x07u,       /* audio data block, 3 bytes */
                                       0xE2u, 0x00u, 0x40u };            /* VCDB: QS (bit 6) = 1      */
        for (unsigned qs = 0; qs < 3u; qs++) {
            memset(x, 0, BLNS_EDID_BLOCK);
            memcpy(x, qs1, sizeof qs1);
            if (qs == 0u) x[10] = 0x00u;                     /* QS = 0                     */
            if (qs == 2u) x[8]  = 0xEFu;                     /* length 15: overruns d, ignored */
            uint8_t s = 0u;
            for (unsigned i = 0; i < 127u; i++)
                s = (uint8_t) (s + x[i]);
            x[127]   = (uint8_t) (0u - s);
            e.blocks = 2u;
            CHECK(blns_dpi_edid_parse(&e) == BLNS_OK && e.blocks == 2u);
            CHECK(e.quant_select == (qs == 1u ? 1u : 0u));
            CHECK(blns_avi_quant_auto(&e) == (qs == 1u ? BLNS_AVI_QUANT_FULL : BLNS_AVI_QUANT_DEFAULT));
        }
    }
#if !BLNS_HW_OFF(DPI_AUDIO)
    if (BLNS_HAS(&dev, DPI_AUDIO)) {
        char *v = malloc(8u);                               /* 8 characters, no terminator */
        memcpy(v, "ABCDEFGH", 8u);
        CHECK(blns_dpi_hdmi_spd(&dev, v, "x", BLNS_SPD_PC) == BLNS_OK && (regs.HDMI.PKT[2] >> 24) == 'G');
        free(v);
    }
#endif
}

/* HDMI mode: the AVI fields with the RGB quantization range (QUANT, G8-1),
 * and DPI_AUD written until it reads back */
static void test_hdmi_avi(void)
{
#if !BLNS_HW_OFF(DPI_ISLAND)
    if (BLNS__HW_DPI == 0)
        return;
    setup(BLNS_DIF_HDMI, 0u);
    if (!BLNS_HAS(&dev, DPI_ISLAND))
        return;
    const blns_avi_t full = { .vic = 2u, .picture = BLNS_AVI_PICTURE_4_3, .active = BLNS_AVI_ACTIVE_SAME,
                              .quant = BLNS_AVI_QUANT_FULL };
    CHECK(blns_dpi_hdmi(&dev, &full) == BLNS_OK);
    CHECK(regs.HDMI.HDMI == ((2u << BLNS_DPI_HDMI_VIC_Pos) | (8u << BLNS_DPI_HDMI_ACTIVE_Pos) |
                             (BLNS_AVI_QUANT_FULL << BLNS_DPI_HDMI_QUANT_Pos) | (1u << BLNS_DPI_HDMI_PICTURE_Pos) |
                             BLNS_DPI_HDMI_EN_Msk | BLNS_DPI_HDMI_AVI_Msk));
    const blns_avi_t lim = { .vic = 2u, .picture = BLNS_AVI_PICTURE_4_3, .active = BLNS_AVI_ACTIVE_SAME,
                             .quant = BLNS_AVI_QUANT_LIMITED };
    CHECK(blns_dpi_hdmi(&dev, &lim) == BLNS_OK);
    CHECK((regs.HDMI.HDMI & BLNS_DPI_HDMI_QUANT_Msk) == (BLNS_AVI_QUANT_LIMITED << BLNS_DPI_HDMI_QUANT_Pos));
    const blns_avi_t bad = { .vic = 2u, .quant = 3u };
    CHECK(blns_dpi_hdmi(&dev, &bad) == BLNS_ERR_PARAM);
    const blns_avi_t dflt = { .vic = 1u, .picture = BLNS_AVI_PICTURE_4_3, .active = BLNS_AVI_ACTIVE_SAME };
    CHECK(blns_dpi_hdmi(&dev, &dflt) == BLNS_OK && (regs.HDMI.HDMI & BLNS_DPI_HDMI_QUANT_Msk) == 0u);
#if !BLNS_HW_OFF(DPI_AUDIO)
    if (BLNS_HAS(&dev, DPI_AUDIO)) {
        const blns_audio_t au = { .n = 6144u, .fs = BLNS_AUD_FS_48K, .wl = BLNS_AUD_WL_16 };
        CHECK(blns_dpi_hdmi_audio(&dev, &au) == BLNS_OK);
        CHECK(regs.HDMI.AUD == ((6144u << BLNS_DPI_AUD_N_Pos) | (BLNS_AUD_FS_48K << BLNS_DPI_AUD_FS_Pos) |
                                (BLNS_AUD_WL_16 << BLNS_DPI_AUD_WL_Pos)));
        CHECK((regs.HDMI.HDMI & BLNS_DPI_HDMI_AUD_Msk) != 0u);
        CHECK(blns_dpi_hdmi_audio(&dev, 0) == BLNS_OK && (regs.HDMI.HDMI & BLNS_DPI_HDMI_AUD_Msk) == 0u);
    }
#endif
#endif
}

/* I12: the scanline sync on the SPI PHY is refused */
static void test_dbi_sync(void)
{
#if BLNS__HW_DBI != 0 && BLNS__HW_DPI != 1
    setup(BLNS_DIF_DBI_SPI, 0u);
    if (!BLNS_HAS(&dev, DBI))
        return;
    CHECK(blns_dbi_sync(&dev, 10u, true, false) == BLNS_ERR_PARAM);
    CHECK(blns_dbi_sync(&dev, 10u, false, true) == BLNS_OK);
    setup(BLNS_DIF_DBI_PAR, 0u);
    CHECK(blns_dbi_sync(&dev, 10u, true, false) == BLNS_OK);
#endif
}

/* The DBI bus set-up: CLK_DIV for the writes, RD_DIV for the 8080 reads,
 * derived from hclk_hz when 0 (RD low and high >= 90 ns: ILI9341 t_RDH) */
static void test_dbi_config(void)
{
#if BLNS__HW_DBI != 0 && BLNS__HW_DPI != 1
    setup(BLNS_DIF_DBI_PAR, 0u);
    if (!BLNS_HAS(&dev, DBI))
        return;
    blns_dbi_config_t c = { .spi = false, .clk_div = 3u, .hw_window = true, .rd_div = 0u };
    #define RD_DIV_OF(v) (((v) & BLNS_DIF_CFG_RD_DIV_Msk) >> BLNS_DIF_CFG_RD_DIV_Pos)
    dev.hclk_hz = 111000000u;                       /* 9 ns: 2*5+1 = 11 cycles = 99 ns */
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 5u &&
          ((regs.DIF.CFG & BLNS_DIF_CFG_CLK_DIV_Msk) >> BLNS_DIF_CFG_CLK_DIV_Pos) == 3u &&
          (regs.DIF.CFG & BLNS_DIF_CFG_HW_WINDOW_Msk));
    dev.hclk_hz = 100000000u;                       /* 10 ns: 9 cycles = 90 ns */
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 4u);
    dev.hclk_hz = 20000000u;                        /* 50 ns: at least 1 */
    c.clk_div = 0u;
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 1u);
    dev.hclk_hz = 100000000u;                       /* never faster than CLK_DIV */
    c.clk_div = 8u;
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 8u);
    dev.hclk_hz = 1000000000u;                      /* saturates */
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 15u);
    dev.hclk_hz = 0u;                               /* unknown clock: reads follow CLK_DIV */
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 0u);
    c.rd_div = 7u;                                  /* explicit */
    CHECK(blns_dbi_config(&dev, &c) == BLNS_OK && RD_DIV_OF(regs.DIF.CFG) == 7u);
    c.rd_div = 16u;
    CHECK(blns_dbi_config(&dev, &c) == BLNS_ERR_PARAM);
    #undef RD_DIV_OF
#endif
}

/*---------------------------------------------------------------------------
 * Lines (EXEC_FILL LINE)
 *---------------------------------------------------------------------------*/
#define LO  2048u                   /* the x/y surface of the line tests */
#define LP  64u

#if BLNS__HW_GPU_LINE != 0
static uint32_t lcause(void)
{
    return (regs.GPU.STAT & BLNS_GPU_STAT_ERR_CAUSE_Msk) >> BLNS_GPU_STAT_ERR_CAUSE_Pos;
}
#endif

#define PX(v)  (BLNS_SUB(v) + 8)    /* pixel centre in 12.4 */

#if BLNS__HW_GPU_LINE <= 0
/* The calls of a build without lines: BLNS_ERR_ABSENT, nothing pushed */
static void line_absent(void)
{
    const int32_t xy[4] = { 8, 8, 40, 8 };
    const unsigned w0 = m.words;
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 4u) == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_line_solid(&dev) == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_line_xy(&dev, 8, 8, 40, 8, NULL) == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 0, NULL) == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_polyline_xy(&dev, xy, 2u, false, NULL) == BLNS_ERR_ABSENT);
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, NULL) == BLNS_ERR_ABSENT);
    CHECK(m.words == w0 && !BLNS_HAS(&dev, GPU_LINE));
}
#endif

/* caps.gpu_line and the ABSENT gating in each build */
static void test_line_caps(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    blns_gpu_xy_begin(&dev, LO, LP, 1u);
    model_run();
#if BLNS__HW_GPU_LINE == 0
    line_absent();                                  /* inline stubs */
#elif BLNS__HW_GPU_LINE < 0
    CHECK(!dev.caps.gpu_line);
    line_absent();
    setup(BLNS_DIF_DPI, BLNS_CFG2_LINE_Msk);
    CHECK(dev.caps.gpu_line && BLNS_HAS(&dev, GPU_LINE));
#else
    CHECK(dev.caps.gpu_line && BLNS_HAS(&dev, GPU_LINE));
#endif
#if BLNS__HW_GPU_LINE != 0 && BLNS__HW_GPU_BLEND < 0
    /* lines without blending: no AA */
    setup(BLNS_DIF_DPI, BLNS_CFG2_LINE_Msk);
    blns_gpu_enable(&dev, true);
    blns_gpu_xy_begin(&dev, LO, LP, 1u);
    model_run();
    const blns_line_t aa = { .aa = true };
    const unsigned w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 1, &aa) == BLNS_ERR_ABSENT && m.words == w0);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 1, NULL) == BLNS_OK && last()->opnd == ((24u << 16) | 72u));
#endif
}

#if BLNS__HW_GPU_LINE != 0
static uint32_t lpx(int x, int y)
{
    return px_get((int32_t) (LO + (uint32_t) (y * (int) LP + x)));
}

static void lclear(void)
{
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 64; x++)
            px_set((int32_t) (LO + (uint32_t) (y * (int) LP + x)), 0u);
}

static unsigned lcount(void)
{
    unsigned n = 0;
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 64; x++)
            n += lpx(x, y) != 0u;
    return n;
}

/* The pixels drawn are exactly 'n' points (x, y) of value v */
static bool lonly(const int (*pt)[2], unsigned n, uint32_t v)
{
    for (unsigned i = 0; i < n; i++)
        if (lpx(pt[i][0], pt[i][1]) != v)
            return false;
    return lcount() == n;
}

static void line_setup(void)
{
    setup(BLNS_DIF_DPI, BLNS_CFG2_LINE_Msk | BLNS_CFG2_BLEND_Msk | BLNS_CFG2_REMAP_Msk);
    blns_gpu_enable(&dev, true);
    model_run();
}

/* The words pushed: the pen only when needed, SET_TRANSP only when changed;
 * refusals with nothing pushed */
static void test_line_words(void)
{
    line_setup();
    unsigned w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 0, NULL) == BLNS_ERR_STATE);         /* no x/y surface */
    CHECK(blns_gpu_xy_begin(&dev, LO, LP, 1u) == BLNS_OK);
    model_run();
    w0 = m.words;
    CHECK(blns_gpu_line_xy(&dev, 0, 0, PX(4), PX(0), NULL) == BLNS_OK && m.words == w0 + 2u);  /* pen (0, 0): reset */
    CHECK(last()->pen == 0u && last()->opnd == ((8u << 16) | 72u) && (last()->word & ~0xFFFFu) ==
          (BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk));
    w0 = m.words;
    CHECK(blns_gpu_line_xy(&dev, PX(4), PX(0), PX(4), PX(5), NULL) == BLNS_OK && m.words == w0 + 2u);
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 9, 9, 12, 9, NULL) == BLNS_OK && m.words == w0 + 4u);  /* not connected */
    CHECK(last()->pen == (((uint32_t) PX(9) << 16) | (uint32_t) PX(9)));
    const blns_line_t op = { .opaque = true, .bg = 5u };
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 12, 9, 15, 9, &op) == BLNS_OK && m.words == w0 + 4u);  /* + SET_TRANSP */
    CHECK(last()->transp == 5u && (last()->word & BLNS_GPU_LINE_OPAQUE_Msk));
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 15, 9, 18, 9, &op) == BLNS_OK && m.words == w0 + 2u);  /* unchanged */
    const blns_line_t op6 = { .opaque = true, .bg = 6u }, x15 = { .rop = BLNS_ROP_FILL_IF_S };
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 18, 9, 21, 9, &op6) == BLNS_OK && m.words == w0 + 4u);
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 21, 9, 24, 9, &x15) == BLNS_OK && m.words == w0 + 4u && last()->transp == 0u);
    /* the session colour, sent when changed */
    blns_gpu_colour_set(&dev, 3u);
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 24, 9, 26, 9, NULL) == BLNS_OK && m.words == w0 + 4u && last()->fill == 3u);
    /* an address-mode call in between: the x/y surface sent again */
    const blns_surf_t f = { 9000u, 0u, BLNS_SWAP_NONE };
    CHECK(blns_gpu_fill(&dev, &f, 2u, 2u, 3u, BLNS_ROP_S) == BLNS_OK);
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 26, 9, 28, 9, NULL) == BLNS_OK && m.words == w0 + 4u && last());
    CHECK(m.xy && m.dst == LO && m.dpitch == LP && lpx(28, 9) == 3u);
    /* the pen forgotten at a recover, kept known at (0, 0) by RESET_STATE */
    blns_gpu_recover(&dev);
    w0 = m.words;
    CHECK(blns_gpu_line_px(&dev, 28, 9, 30, 9, NULL) == BLNS_OK && m.words == w0 + 8u);  /* fill, dst, pen */
    CHECK(blns_gpu_reset_state(&dev) == BLNS_OK);
    CHECK(blns_gpu_xy_begin(&dev, LO, LP, 1u) == BLNS_OK);
    w0 = m.words;
    CHECK(blns_gpu_line_xy(&dev, 0, 0, PX(3), 0, NULL) == BLNS_OK && m.words == w0 + 2u && last()->pen == 0u);
    blns_gpu_forget(&dev);
    w0 = m.words;
    CHECK(blns_gpu_line_xy(&dev, PX(3), 0, PX(5), 0, NULL) == BLNS_OK && m.words == w0 + 8u);
    /* refusals: nothing pushed */
    model_run();
    w0 = m.words;
    const blns_line_t bad_rop = { .rop = 16u }, bad_remap = { .remap = 3u }, src = { .remap = BLNS_REMAP_SRC };
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 0u) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 33u) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_xy(&dev, 0, 0, 32768, 0, NULL) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_xy(&dev, -32769, 0, 0, 0, NULL) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 2048, 0, NULL) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 0, &bad_rop) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 0, &bad_remap) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 0, &src) == BLNS_ERR_STATE);        /* no remap table */
    const int32_t pts[6] = { 0, 0, PX(4), 0, 40000, 0 };
    CHECK(blns_gpu_polyline_xy(&dev, pts, 3u, false, NULL) == BLNS_ERR_PARAM);  /* checked first */
    CHECK(blns_gpu_polyline_xy(&dev, pts, 1u, true, NULL) == BLNS_OK);
    CHECK(blns_gpu_polyline_xy(&dev, NULL, 0u, false, NULL) == BLNS_OK);
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 0u, 4u, NULL) == BLNS_OK);
    CHECK(blns_gpu_rect_outline_xy(&dev, 2040, 0, 9u, 4u, NULL) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_rect_outline_xy(&dev, -2049, 0, 9u, 4u, NULL) == BLNS_ERR_PARAM);
    CHECK(m.words == w0);
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 4u) == BLNS_OK && m.words == w0 + 2u);
    model_run();
    CHECK(m.len == 4u && m.pat == 3u);
    CHECK(blns_gpu_line_solid(&dev) == BLNS_OK && m.words == w0 + 4u);
    model_run();
    CHECK(m.len == 32u && m.pat == ~0u);
    /* non-blocking with a full FIFO: BLNS_ERR_BUSY, the pen not moved */
    hook_runs_gpu = false;
    blns_set_nonblocking(&dev, true);
    const blns_surf_t g = { 9000u, 0u, BLNS_SWAP_NONE };
    while (blns_gpu_fill(&dev, &g, 1u, 1u, 3u, BLNS_ROP_S) == BLNS_OK)
        ;
    CHECK(blns_gpu_line_xy(&dev, PX(5), 0, PX(9), 0, NULL) == BLNS_ERR_BUSY);
    blns_set_nonblocking(&dev, false);
    hook_runs_gpu = true;
    model_run();
    w0 = m.words;
    CHECK(blns_gpu_line_xy(&dev, PX(5), 0, PX(9), 0, NULL) == BLNS_OK && m.words == w0 + 6u);  /* dst, line */
    CHECK(!m.err);
}

/* Solid pixels: hand-computed sets, the direction symmetry, NO_LAST, clip */
static void test_line_pixels(void)
{
    line_setup();
    blns_gpu_xy_begin(&dev, LO, LP, 1u);
    /* (0, 0) - (4, 2): the halves at x = 1, 3 round to the smaller y */
    static const int a[5][2] = { { 0, 0 }, { 1, 0 }, { 2, 1 }, { 3, 1 }, { 4, 2 } };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 2, NULL) == BLNS_OK && last() && lonly(a, 5u, 1u));
    lclear();
    CHECK(blns_gpu_line_px(&dev, 4, 2, 0, 0, NULL) == BLNS_OK && last() && lonly(a, 5u, 1u));
    /* y-major, negative slope: (3, 0) - (0, 6): x = 3 - k / 2 */
    static const int b[7][2] = { { 3, 0 }, { 2, 1 }, { 2, 2 }, { 1, 3 }, { 1, 4 }, { 0, 5 }, { 0, 6 } };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 3, 0, 0, 6, NULL) == BLNS_OK && last() && lonly(b, 7u, 1u));
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 6, 3, 0, NULL) == BLNS_OK && last() && lonly(b, 7u, 1u));
    /* 45 degrees, sub-pixel end points: the pixels that contain them */
    static const int c[4][2] = { { 1, 1 }, { 2, 2 }, { 3, 3 }, { 4, 4 } };
    lclear();
    CHECK(blns_gpu_line_xy(&dev, 16, 31, 79, 64, NULL) == BLNS_OK && last() && lonly(c, 4u, 1u));
    /* NO_LAST: the end pixel left out; a point: one pixel, none with NO_LAST */
    const blns_line_t nl = { .no_last = true };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 2, &nl) == BLNS_OK && last() && lonly(a, 4u, 1u));
    lclear();
    unsigned p0 = m.line_px;
    CHECK(blns_gpu_line_px(&dev, 7, 7, 7, 7, NULL) == BLNS_OK && last() && lpx(7, 7) == 1u && m.line_px == p0 + 1u);
    CHECK(blns_gpu_line_px(&dev, 7, 7, 7, 7, &nl) == BLNS_OK && last() && m.line_px == p0 + 1u);
    /* random lines: both directions draw the same set, D + 1 pixels */
    uint32_t r = 12345u;
    bool same = true, count = true;
    static uint16_t fwd[64 * 64];
    for (unsigned t = 0; t < 40u; t++) {
        int32_t v[4];
        for (unsigned i = 0; i < 4u; i++) {
            r = r * 1103515245u + 12345u;
            v[i] = (int32_t) ((r >> 8) % (60u * 16u));
        }
        lclear();
        p0 = m.line_px;
        blns_gpu_line_xy(&dev, v[0], v[1], v[2], v[3], NULL);
        model_run();
        const int dx = abs((v[2] >> 4) - (v[0] >> 4)), dy = abs((v[3] >> 4) - (v[1] >> 4));
        count = count && m.line_px - p0 == (unsigned) ((dx > dy ? dx : dy) + 1) && lcount() == m.line_px - p0;
        for (int i = 0; i < 64 * 64; i++)
            fwd[i] = (uint16_t) lpx(i % 64, i / 64);
        lclear();
        blns_gpu_line_xy(&dev, v[2], v[3], v[0], v[1], NULL);
        model_run();
        for (int i = 0; i < 64 * 64; i++)
            same = same && fwd[i] == lpx(i % 64, i / 64);
    }
    CHECK(same && count);
    /* clipped pixels are skipped, the others drawn */
    lclear();
    CHECK(blns_gpu_clip(&dev, 2, 0, 5, 10) == BLNS_OK);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 9, 0, NULL) == BLNS_OK && last());
    static const int d[4][2] = { { 2, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 } };
    CHECK(lonly(d, 4u, 1u));
    CHECK(blns_gpu_clip(&dev, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX, BLNS_GPU_XY_MAX) == BLNS_OK);
    /* raster op: XOR twice clears */
    const blns_line_t x = { .rop = BLNS_ROP_XOR };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 3, 20, 9, &x) == BLNS_OK && last() && lcount() == 21u);
    CHECK(blns_gpu_line_px(&dev, 20, 9, 0, 3, &x) == BLNS_OK && last() && lcount() == 0u);
    /* past the VRAM: cause 5, the pixels before it drawn */
    CHECK(blns_gpu_xy_begin(&dev, MODEL_WORDS * 2u - 8u, 0u, 1u) == BLNS_OK);
    p0 = m.line_px;
    CHECK(blns_gpu_line_px(&dev, 0, 0, 15, 0, NULL) == BLNS_OK);
    model_run();
    CHECK(m.err && m.line_px == p0 + 8u &&
          lcause() == BLNS_GPU_ERR_BOUNDS);
    blns_gpu_recover(&dev);
    CHECK(!m.err);
}

/* Dashes: the phase per step, across lines, its resets; OPAQUE gaps */
static void test_line_dashes(void)
{
    line_setup();
    blns_gpu_xy_begin(&dev, LO, LP, 1u);
    const blns_line_t nl = { .no_last = true };
    lclear();
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 4u) == BLNS_OK);
    CHECK(blns_gpu_line_px(&dev, 0, 0, 10, 0, &nl) == BLNS_OK);             /* 10 steps: phase 2 after */
    CHECK(blns_gpu_line_px(&dev, 10, 0, 13, 0, NULL) == BLNS_OK && last());
    static const int a[8][2] = { { 0, 0 }, { 1, 0 }, { 4, 0 }, { 5, 0 }, { 8, 0 }, { 9, 0 }, { 12, 0 }, { 13, 0 } };
    CHECK(lonly(a, 8u, 1u) && m.phase == 2u);
    /* phase_reset: from phase 0 */
    const blns_line_t pr = { .phase_reset = true };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 2, 5, 2, &pr) == BLNS_OK && last());
    static const int b[4][2] = { { 0, 2 }, { 1, 2 }, { 4, 2 }, { 5, 2 } };
    CHECK(lonly(b, 4u, 1u) && m.phase == 2u);
    /* a recover: phase 0 (the hardware's flush), the pattern kept */
    blns_gpu_recover(&dev);
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 4, 5, 4, NULL) == BLNS_OK && last());
    static const int c[4][2] = { { 0, 4 }, { 1, 4 }, { 4, 4 }, { 5, 4 } };
    CHECK(lonly(c, 4u, 1u));
    /* OPAQUE: the gaps in bg */
    const blns_line_t op = { .opaque = true, .bg = 7u, .phase_reset = true };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 6, 5, 6, &op) == BLNS_OK && last());
    CHECK(lpx(0, 6) == 1u && lpx(1, 6) == 1u && lpx(2, 6) == 7u && lpx(3, 6) == 7u && lpx(4, 6) == 1u &&
          lpx(5, 6) == 1u && lcount() == 6u);
    /* op 15 with OPAQUE: S of a gap is SET_TRANSP, skipped */
    const blns_line_t o15 = { .rop = BLNS_ROP_FILL_IF_S, .opaque = true, .bg = 7u, .phase_reset = true };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 6, 5, 6, &o15) == BLNS_OK && last());
    static const int d[4][2] = { { 0, 6 }, { 1, 6 }, { 4, 6 }, { 5, 6 } };
    CHECK(lonly(d, 4u, 1u));
    /* the LINE_PATTERN word resets the phase; a line in address mode draws
     * nothing and keeps the phase, moves the pen; PH_RST applies there too */
    CHECK(blns_gpu_line_pattern(&dev, 0x1u, 3u) == BLNS_OK && last() && m.phase == 0u);
    CHECK(blns_gpu_line_px(&dev, 0, 8, 1, 8, NULL) == BLNS_OK && last() && m.phase == 2u);
    const unsigned p0 = m.line_px;
    const uint32_t raw[6] = { BLNS_GPU_OP_SET_DST | 64u, 9000u,
                              BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk, 0x01230456u,
                              BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | BLNS_GPU_LINE_PH_RST_Msk, 0x00100020u };
    CHECK(blns_gpu_push(&dev, raw, 4u) == BLNS_OK && last() && m.phase == 2u && m.pen == 0x01230456u);
    CHECK(blns_gpu_push(&dev, &raw[4], 2u) == BLNS_OK && last() && m.phase == 0u && m.pen == 0x00100020u);
    CHECK(m.line_px == p0 && !m.err);
    /* GPU_EN = 0: phase 0; pen and pattern kept (settings) */
    CHECK(blns_gpu_xy_begin(&dev, LO, LP, 1u) == BLNS_OK && blns_gpu_line_px(&dev, 0, 8, 1, 8, NULL) == BLNS_OK);
    CHECK(last() && m.phase == 2u);
    const uint32_t pen = m.pen;
    blns_gpu_enable(&dev, false);
    CHECK(m.phase == 0u && m.pen == pen && m.len == 3u);
    blns_gpu_enable(&dev, true);                    /* RESET_STATE: solid, pen (0, 0) */
    model_run();
    CHECK(m.pen == 0u && m.len == 32u && m.pat == ~0u);
}

/* AA (16 bpp, blending): the coverage pairs of a hand-computed line */
static uint32_t white_at(int a)                     /* white blended over black by alpha a */
{
    const int k = (a == 255) ? 256 : a;
    const uint32_t r = (uint32_t) ((31 * k + 128) >> 8), g = (uint32_t) ((63 * k + 128) >> 8);
    return (r << 11) | (g << 5) | r;
}

static void test_line_aa(void)
{
    line_setup();
    blns_gpu_xy_begin(&dev, LO, LP, 0xFFFFu);
    const blns_line_t aa = { .aa = true };
    /* (0, 0) - (4, 1), pixel centres: Gs = 1/4, f = 64 k */
    static const int px[8][3] = { { 0, 0, 255 }, { 1, 0, 191 }, { 1, 1, 64 }, { 2, 0, 127 }, { 2, 1, 128 },
                                  { 3, 0, 63 }, { 3, 1, 192 }, { 4, 1, 255 } };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 1, &aa) == BLNS_OK && last());
    bool ok = lcount() == 8u;
    for (unsigned i = 0; i < 8u; i++)
        ok = ok && lpx(px[i][0], px[i][1]) == white_at(px[i][2]);
    CHECK(ok && (last()->word & BLNS_GPU_LINE_AA_Msk));
    /* y-major mirror: the same pairs with x and y swapped */
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 1, 4, &aa) == BLNS_OK && last());
    ok = lcount() == 8u;
    for (unsigned i = 0; i < 8u; i++)
        ok = ok && lpx(px[i][1], px[i][0]) == white_at(px[i][2]);
    CHECK(ok);
    /* off a pixel centre (d0 = -5/16), right to left, the minor delta negative:
     * Gs = -39988, M0 = 307408 */
    static const int q[10][3] = { { 5, 4, 207 }, { 5, 5, 48 }, { 4, 3, 107 }, { 4, 4, 148 }, { 3, 2, 7 },
                                  { 3, 3, 248 }, { 2, 2, 163 }, { 2, 3, 92 }, { 1, 1, 63 }, { 1, 2, 192 } };
    lclear();
    CHECK(blns_gpu_line_xy(&dev, 83, 72, 24, 36, &aa) == BLNS_OK && last());
    ok = lcount() == 10u;
    for (unsigned i = 0; i < 10u; i++)
        ok = ok && lpx(q[i][0], q[i][1]) == white_at(q[i][2]);
    CHECK(ok);
    /* NO_LAST: the last column left out */
    const blns_line_t aan = { .aa = true, .no_last = true };
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 1, &aan) == BLNS_OK && last() && lcount() == 7u && lpx(4, 1) == 0u);
    /* SET_ALPHA: coverage x A / 255, rounded */
    CHECK(blns_gpu_alpha(&dev, true, 128u) == BLNS_OK);
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 1, &aa) == BLNS_OK && last());
    ok = true;
    for (unsigned i = 0; i < 8u; i++)
        ok = ok && lpx(px[i][0], px[i][1]) == white_at((px[i][2] * 128 + 127) / 255);
    CHECK(ok);
    /* a solid line with SET_ALPHA: blended by A */
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 3, 0, NULL) == BLNS_OK && last() && lpx(2, 0) == white_at(128) &&
          lcount() == 4u);
    CHECK(blns_gpu_alpha(&dev, false, 255u) == BLNS_OK);
    /* below 16 bpp: AA ignored, the solid pixels */
    CHECK(blns_set_mode(&dev, BLNS_BPP_8) == BLNS_OK);
    blns_gpu_xy_begin(&dev, LO, LP, 9u);
    lclear();
    static const int s[5][2] = { { 0, 0 }, { 1, 0 }, { 2, 1 }, { 3, 1 }, { 4, 2 } };
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 2, &aa) == BLNS_OK && last() && lonly(s, 5u, 9u));
    /* remap SRC at 8 bpp: the line colour through the table */
    ((uint8_t *) vram)[128u * 4u + 9u] = 0x42u;
    const blns_line_t rs = { .remap = BLNS_REMAP_SRC };
    CHECK(blns_gpu_remap_table(&dev, 128u) == BLNS_OK);
    lclear();
    CHECK(blns_gpu_line_px(&dev, 0, 0, 4, 2, &rs) == BLNS_OK && last() && lonly(s, 5u, 0x42u));
    CHECK(!m.err);
}

/* Polylines and outlines: each joint drawn once (XOR on 0), the phase across
 * corners, lists */
static void test_polyline(void)
{
    line_setup();
    blns_gpu_xy_begin(&dev, LO, LP, 1u);
    const blns_line_t x = { .rop = BLNS_ROP_XOR };
    /* open: (0, 0) - (5, 0) - (5, 5): 11 pixels, the corner once */
    const int32_t o[6] = { PX(0), PX(0), PX(5), PX(0), PX(5), PX(5) };
    lclear();
    unsigned w0 = m.words;
    CHECK(blns_gpu_polyline_xy(&dev, o, 3u, false, &x) == BLNS_OK && last());
    CHECK(lcount() == 11u && lpx(5, 0) == 1u && lpx(5, 5) == 1u && lpx(0, 0) == 1u);
    CHECK(m.words == w0 + 4u + 2u);                         /* pen and line, line */
    CHECK((m.d[m.nd - 2u].word & BLNS_GPU_LINE_NO_LAST_Msk) && !(last()->word & BLNS_GPU_LINE_NO_LAST_Msk));
    /* closed triangle */
    const int32_t t[6] = { PX(10), PX(10), PX(20), PX(12), PX(14), PX(20) };
    lclear();
    w0 = m.words;
    CHECK(blns_gpu_polyline_xy(&dev, t, 3u, true, &x) == BLNS_OK && last());
    CHECK(lcount() == 10u + 8u + 10u && m.words == w0 + 4u + 2u * 2u);
    CHECK(last()->word & BLNS_GPU_LINE_NO_LAST_Msk);
    /* outlines: the perimeter exactly */
    bool ok = true;
    for (unsigned w = 1; w <= 6u; w++)
        for (unsigned h = 1; h <= 6u; h++) {
            lclear();
            blns_gpu_rect_outline_xy(&dev, 3, 4, w, h, &x);
            model_run();
            const unsigned per = (w == 1u || h == 1u) ? w * h : 2u * (w + h) - 4u;
            bool edge = lcount() == per;
            for (unsigned yy = 0; yy < h; yy++)
                for (unsigned xx = 0; xx < w; xx++)
                    edge = edge && (lpx(3 + (int) xx, 4 + (int) yy) ==
                                    ((xx == 0u || yy == 0u || xx == w - 1u || yy == h - 1u) ? 1u : 0u));
            ok = ok && edge;
        }
    CHECK(ok);
    /* a dashed 4 x 4 focus frame: the phase carries across the corners */
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 4u) == BLNS_OK);
    lclear();
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, NULL) == BLNS_OK && last());
    static const int f[6][2] = { { 0, 0 }, { 1, 0 }, { 3, 1 }, { 3, 2 }, { 1, 3 }, { 0, 3 } };
    CHECK(lonly(f, 6u, 1u) && m.phase == 0u);
    /* phase_reset on the first segment only */
    const blns_line_t pr = { .phase_reset = true };
    CHECK(blns_gpu_line_px(&dev, 40, 0, 40, 0, NULL) == BLNS_OK && last() && m.phase == 1u);
    lclear();
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, &pr) == BLNS_OK && last() && lonly(f, 6u, 1u));
    CHECK((m.d[m.nd - 4u].word & BLNS_GPU_LINE_PH_RST_Msk) && !(last()->word & BLNS_GPU_LINE_PH_RST_Msk));
    /* recorded into a list: the same pixels; PH_RST passes through */
    blns_gpu_list_t l = { .addr = 8000u, .capacity = 64u };
    lclear();
    CHECK(blns_gpu_list_begin(&dev, &l, 0u) == BLNS_OK);
    CHECK(blns_gpu_line_pattern(&dev, 0x3u, 4u) == BLNS_OK);
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, &pr) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && l.count > 0u);
    model_run();
    CHECK(lcount() == 0u);                                  /* nothing drawn yet */
    CHECK(blns_gpu_line_px(&dev, 40, 0, 40, 0, NULL) == BLNS_OK && last() && m.phase == 1u);
    lclear();
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK);
    model_run();
    CHECK(lonly(f, 6u, 1u) && !m.err);
    /* a list without INHERIT starts solid */
    CHECK(blns_gpu_line_pattern(&dev, 0x1u, 2u) == BLNS_OK);
    blns_gpu_list_t s = { .addr = 8100u, .capacity = 64u };
    lclear();
    CHECK(blns_gpu_list_begin(&dev, &s, 0u) == BLNS_OK && blns_gpu_line_px(&dev, 0, 0, 7, 0, NULL) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && blns_gpu_list_call(&dev, &s, false) == BLNS_OK);
    model_run();
    CHECK(lcount() == 8u && m.len == 32u);
    /* an outline is one push: non-blocking with no room, nothing sent */
    hook_runs_gpu = false;
    blns_set_nonblocking(&dev, true);
    const blns_surf_t g = { 9000u, 0u, BLNS_SWAP_NONE };
    while (blns_gpu_fill(&dev, &g, 1u, 1u, 3u, BLNS_ROP_S) == BLNS_OK)
        ;
    w0 = m.words;
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, &x) == BLNS_ERR_BUSY && m.words == w0);
    blns_set_nonblocking(&dev, false);
    hook_runs_gpu = true;
    model_run();
    lclear();
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, &x) == BLNS_OK && last() && lcount() == 12u && !m.err);
    /* non-blocking into an empty FIFO: sent whole, longer than the FIFO or not */
    model_run();
    blns_set_nonblocking(&dev, true);
    lclear();
    CHECK(blns_gpu_rect_outline_xy(&dev, 0, 0, 4u, 4u, &x) == BLNS_OK);
    model_run();
    CHECK(lcount() == 12u && !m.err);
    blns_set_nonblocking(&dev, false);
}
#endif

/* The decoder's refusals (cause 2: a feature not built, no operand taken;
 * cause 1: reserved) and the push parser's operand rule in every build */
static void test_line_model(void)
{
#if BLNS__HW_GPU_LINE < 0 && BLNS__HW_GPU_BLEND < 0 && BLNS__HW_GPU_TRI < 0 && BLNS__HW_GPU_REMAP < 0
    static const struct { uint32_t cfg2, w; uint32_t cause; } c[] = {
        { 0u, BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk, 2u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_LINE_PEN, 2u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_LINE_PATTERN, 2u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_REMAP_TABLE, 2u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_ALPHA_PLANE, 2u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_TEX_FILTER, 2u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | (6u << BLNS_GPU_AUX_SEL_Pos), 1u },
        { 0u, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | (15u << BLNS_GPU_AUX_SEL_Pos), 1u },
        { BLNS_CFG2_BLEND_Msk, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_ALPHA_PLANE | 1u, 2u },
        { BLNS_CFG2_BLEND_Msk, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_TEX_FILTER, 2u },
        { BLNS_CFG2_BILINEAR_Msk, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_TEX_FILTER |
                                  BLNS_GPU_AUX_TBORDER_Msk, 2u },
        { 0u, BLNS_GPU_OP_SET_SRC | (BLNS_FMT_RGB565A8 << BLNS_GPU_SRC_FMT_Pos), 2u },
        { BLNS_CFG2_BLEND_Msk, BLNS_GPU_OP_SET_SRC | (6u << BLNS_GPU_SRC_FMT_Pos), 3u },
        { BLNS_CFG2_LINE_Msk, BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | BLNS_GPU_LINE_AA_Msk, 2u },
        { BLNS_CFG2_LINE_Msk, BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | BLNS_GPU_EXEC_TRI_Msk, 1u },
        { BLNS_CFG2_LINE_Msk, BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | (3u << BLNS_GPU_EXEC_REMAP_Pos), 1u },
        { BLNS_CFG2_LINE_Msk, BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | BLNS_GPU_EXEC_TRI_Msk |
                              BLNS_GPU_LINE_AA_Msk, 2u },
    };
    for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
        setup(BLNS_DIF_DPI, c[i].cfg2);
        blns_gpu_enable(&dev, true);
        model_run();
        model_cmd(c[i].w);
        CHECK(m.owed);                              /* the push side counts the operand */
        model_cmd(0x00100010u);
        model_run();
        CHECK(m.err && lcause() == c[i].cause && regs.GPU.ERR == c[i].w);
        CHECK(m.qn == 1u && m.lines == 0u);         /* the operand not taken */
        blns_gpu_recover(&dev);
        CHECK(!m.err && m.qn == 0u);
    }
    /* LINE with TRI in a build without triangles: cause 2 */
    setup_fifo(BLNS_DIF_DPI, 0u, 4u);
    RW(regs.CFG2) = 4u | BLNS_CFG2_XY_Msk | BLNS_CFG2_LINE_Msk;
    reinit();
    blns_gpu_enable(&dev, true);
    model_run();
    model_cmd(BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | BLNS_GPU_EXEC_TRI_Msk);
    model_run();
    CHECK(m.err && lcause() == 2u);
    blns_gpu_recover(&dev);
    /* EXPAND MASK without blending: cause 2 (the driver refuses it first) */
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const blns_expand_t e = { .width = 8u, .height = 8u, .depth = BLNS_EXP_4BPP, .mask = true };
    CHECK(blns_gpu_expand_begin(&dev, &e, 100u, 0u, 1u, 0u) == BLNS_ERR_ABSENT);
    model_cmd(BLNS_GPU_OP_EXEC_EXPAND | BLNS_GPU_EXP_MASK_Msk);
    model_run();
    CHECK(m.err && lcause() == 2u);
    blns_gpu_recover(&dev);
    /* a cut line: its operand discarded after ABORT | CLEAR_ERR (the push side
     * owed it); after the recover (DISCARD too) the next word is a command */
    setup(BLNS_DIF_DPI, BLNS_CFG2_LINE_Msk);
    blns_gpu_enable(&dev, true);
    model_run();
    model_cmd(BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk);
    model_reg_wr(&regs.GPU.CTRL, BLNS_GPU_CTRL_ABORT_Msk | BLNS_GPU_CTRL_CLEAR_ERR_Msk);
    model_cmd(0x00100010u);
    model_run();
    CHECK(!m.err && m.lines == 0u && m.pen == 0u);
    model_cmd(BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk);
    blns_gpu_recover(&dev);
    model_cmd(BLNS_GPU_OP_SET_SIZE | 0x14005u);
    model_run();
    CHECK(!m.err && m.lines == 0u && m.pen == 0u && m.w == 5u && m.h == 5u);
#endif
}


/* blns_dbi_cmd feeds the parameter FIFO only while PARAM_FULL reads 0:
 * every parameter reaches the panel in order and PARAM_OVFL is never set */
static void test_dbi_cmd_fifo(void)
{
#if BLNS__HW_DBI != 0 && BLNS__HW_DPI != 1
    static const unsigned counts[] = { 0u, 1u, 15u, 16u, 17u, 31u, 100u, 255u };
    uint8_t p[255];
    for (unsigned i = 0; i < sizeof p; i++)
        p[i] = (uint8_t) (i * 7u + 3u);
    for (unsigned k = 0; k < sizeof counts / sizeof counts[0]; k++) {
        setup(BLNS_DIF_DBI_SPI, 0u);
        if (!BLNS_HAS(&dev, DBI))
            return;
        CHECK(blns_dbi_cmd(&dev, 0x2Cu, p, counts[k]) == BLNS_OK);
        for (unsigned r = 0; m.dcmd && r < 1000u; r++)   /* let the model send the rest */
            (void) model_reg_rd(&regs.DIF.STATUS);
        CHECK(!m.dcmd);
        bool same = m.dsent_n == counts[k];
        for (unsigned i = 0; same && i < counts[k]; i++)
            same = m.dsent[i] == p[i];
        CHECK(same);
        CHECK(m.dovfl == 0u && !(regs.DIF.STATUS & BLNS_DIF_STATUS_PARAM_OVFL_Msk));
    }
    /* the model itself: a 17th write to a full FIFO is dropped and flagged, W1C */
    setup(BLNS_DIF_DBI_SPI, 0u);
    for (unsigned i = 0; i < 17u; i++)
        model_reg_wr(&regs.DIF.PARAM, i);
    CHECK(m.dovfl == 1u && (model_reg_rd(&regs.DIF.STATUS) & BLNS_DIF_STATUS_PARAM_OVFL_Msk));
    model_reg_wr(&regs.DIF.STATUS, BLNS_DIF_STATUS_PARAM_OVFL_Msk);
    CHECK(!(model_reg_rd(&regs.DIF.STATUS) & BLNS_DIF_STATUS_PARAM_OVFL_Msk));
#endif
}

/* The hardware cursor: shape block (rows and the column copy), colours,
 * hotspot, show, position (origin of a windowed refresh, panel pixels through
 * the DPI placement, the orientation and pixel doubling), absence */
#if BLNS__HW_CURSOR != 0
static uint32_t crs_px(const uint32_t *w, unsigned word0, unsigned k)
{
    return (w[word0 + k / 16u] >> (2u * (k % 16u))) & 3u;
}

static int32_t crs_floor(int32_t v, int32_t d)
{
    return (v >= 0) ? v / d : -((-v + d - 1) / d);
}
#endif

static void test_cursor(void)
{
    setup(BLNS_DIF_DPI, 0u);
#if BLNS__HW_CURSOR != 0
    CHECK(dev.caps.cursor && regs.CURSOR_CTRL == 0u && regs.CURSOR_POS == 0u);
    uint32_t rows[64];
    uint32_t s = 0x1234567u;
    for (unsigned j = 0; j < 64u; j++) {
        s = s * 1103515245u + 12345u;
        rows[j] = s ^ (j * 0x9E3779B9u);
    }
    CHECK(blns_cursor_shape(&dev, 1000u, rows) == BLNS_ERR_PARAM);           /* not 128-aligned */
    CHECK(blns_cursor_shape(&dev, MODEL_WORDS - 64u, rows) == BLNS_ERR_PARAM);  /* past the VRAM */
    CHECK(blns_cursor_shape(&dev, 1024u, NULL) == BLNS_ERR_PARAM && regs.CURSOR_ADDR == 0u);
    CHECK(blns_cursor_shape(&dev, MODEL_WORDS - 128u, rows) == BLNS_OK && regs.CURSOR_ADDR == MODEL_WORDS - 128u);
    CHECK(blns_cursor_shape(&dev, 1024u, rows) == BLNS_OK && regs.CURSOR_ADDR == 1024u);
    bool ok = true;
    for (unsigned j = 0; j < 64u; j++)
        ok = ok && vram[1024u + j] == rows[j];
    for (unsigned i = 0; i < 32u; i++)
        for (unsigned k = 0; k < 32u; k++)
            ok = ok && crs_px(vram, 1024u + 64u + 2u * i, k) == crs_px(rows, 2u * k, i);
    CHECK(ok);
    CHECK(blns_cursor_select(&dev, 64u) == BLNS_ERR_PARAM && regs.CURSOR_ADDR == 1024u);
    CHECK(blns_cursor_select(&dev, 0u) == BLNS_OK && regs.CURSOR_ADDR == 0u);
    CHECK(blns_cursor_colours(&dev, 0xFF123456u, 0x00ABCDEFu, 0x1u) == BLNS_OK &&
          regs.CURSOR_COL[0] == 0x123456u && regs.CURSOR_COL[1] == 0xABCDEFu && regs.CURSOR_COL[2] == 1u);
    CHECK(blns_cursor_hotspot(&dev, 32u, 0u) == BLNS_ERR_PARAM && blns_cursor_hotspot(&dev, 0u, 32u) == BLNS_ERR_PARAM);
    CHECK(blns_cursor_show(&dev, true) == BLNS_OK && regs.CURSOR_CTRL == BLNS_CURSOR_CTRL_EN_Msk);
    CHECK(blns_cursor_hotspot(&dev, 5u, 31u) == BLNS_OK && regs.CURSOR_CTRL == 0x001F0501u);
    CHECK(blns_cursor_show(&dev, false) == BLNS_OK && regs.CURSOR_CTRL == 0x001F0500u);
    CHECK(blns_cursor_move(&dev, -3, 1000) == BLNS_OK && regs.CURSOR_POS == 0x03E8FFFDu);
    /* windowed refresh at (10, 20) of the surface: the cursor stays there */
    CHECK(blns_cursor_origin(&dev, 10, 20) == BLNS_OK && regs.CURSOR_POS == ((980u << 16) | 0xFFF3u));
    CHECK(blns_cursor_move(&dev, 32767, -32768) == BLNS_OK && regs.CURSOR_POS == 0x80007FF5u);
    CHECK(blns_cursor_origin(&dev, 0, 0) == BLNS_OK && regs.CURSOR_POS == 0x80007FFFu);
    /* panel pixels: a 320 x 240 frame centred on a 480 x 272 panel at 362 x 272 */
    regs.DPI.H_ACT    = 480u;
    regs.DPI.V_ACT    = 272u;
    regs.DPI.IMG_SIZE = (272u << 16) | 362u;
    regs.DPI.IMG_POS  = BLNS_DPI_IMG_POS_CENTRE_Msk;
    regs.DPI.SCALE    = (3614u << 16) | 3614u;
    const int32_t stx = dev.caps.dpi_scaler ? 3614 : 4096;
    static const int pts[][2] = { { 59, 0 }, { 300, 135 }, { 0, 271 }, { 479, 3 } };
    for (unsigned n = 0; n < 4u; n++) {
        const int32_t fx = crs_floor((pts[n][0] - 59) * stx, 4096), fy = crs_floor(pts[n][1] * stx, 4096);
        CHECK(blns_cursor_move_panel(&dev, pts[n][0], pts[n][1]) == BLNS_OK &&
              regs.CURSOR_POS == (((uint32_t) (uint16_t) fy << 16) | (uint16_t) fx));
        /* X and Y swaps and pixel doubling */
        blns_set_orientation(&dev, BLNS_SWAP_X | BLNS_SWAP_Y);
        blns_set_pix_double(&dev, true);
        const int32_t dx = 159 - crs_floor(fx, 2), dy = 119 - crs_floor(fy, 2);
        CHECK(blns_cursor_move_panel(&dev, pts[n][0], pts[n][1]) == BLNS_OK &&
              regs.CURSOR_POS == (((uint32_t) (uint16_t) dy << 16) | (uint16_t) dx));
        /* CL swap: the stream line is a frame column (the image is the transposed frame) */
        blns_set_pix_double(&dev, false);
        blns_set_orientation(&dev, BLNS_SWAP_CL);
        CHECK(blns_cursor_move_panel(&dev, pts[n][0], pts[n][1]) == BLNS_OK &&
              regs.CURSOR_POS == (((uint32_t) (uint16_t) fx << 16) | (uint16_t) fy));
        blns_set_orientation(&dev, 0u);
    }
#endif
#if BLNS__HW_CURSOR <= 0
    /* absent: every call refused, hiding allowed, nothing written */
#if BLNS__HW_CURSOR < 0
    RW(regs.CFG) = regs.CFG & ~BLNS_CFG_CURSOR_Msk;
    reinit();
#endif
    regs.CURSOR_CTRL = regs.CURSOR_POS = regs.CURSOR_ADDR = regs.CURSOR_COL[0] = 0u;
    uint32_t r0[64] = { 0u };
    CHECK(!dev.caps.cursor && !BLNS_HAS(&dev, CURSOR));
    CHECK(blns_cursor_shape(&dev, 0u, r0) == BLNS_ERR_ABSENT && blns_cursor_select(&dev, 0u) == BLNS_ERR_ABSENT);
    CHECK(blns_cursor_colours(&dev, 1u, 2u, 3u) == BLNS_ERR_ABSENT && blns_cursor_hotspot(&dev, 1u, 1u) == BLNS_ERR_ABSENT);
    CHECK(blns_cursor_move(&dev, 1, 1) == BLNS_ERR_ABSENT && blns_cursor_move_panel(&dev, 1, 1) == BLNS_ERR_ABSENT);
    CHECK(blns_cursor_origin(&dev, 1, 1) == BLNS_ERR_ABSENT && blns_cursor_show(&dev, true) == BLNS_ERR_ABSENT);
    CHECK(blns_cursor_show(&dev, false) == BLNS_OK);
    CHECK(regs.CURSOR_CTRL == 0u && regs.CURSOR_POS == 0u && regs.CURSOR_ADDR == 0u && regs.CURSOR_COL[0] == 0u);
#endif
}

/*---------------------------------------------------------------------------
 * A helper longer than the FIFO stopped by a timeout: only whole commands
 * sent (no operand owed, the immediate source never left armed), the
 * settings cache what the GPU holds, the next calls draw as without the
 * timeout and no recover needed; a timeout in immediate data cuts the stream
 * (BLNS_ERR_STATE until the recover). Non-blocking: BLNS_ERR_BUSY with
 * nothing sent unless the FIFO is empty.
 *---------------------------------------------------------------------------*/

/* What the driver believes the GPU holds (gst_known) is what the model holds */
static bool cache_ok(void)
{
    const uint16_t k  = dev.gst_known;
    bool           ok = true;
    if (k & BLNS__GST_SIZE) {
        const uint32_t w = dev.gst_size & 0x3FFFu, h = (dev.gst_size >> 14) & 0x3FFFu;
        ok = ok && (w ? w : 1u) == m.w && (h ? h : 1u) == m.h;
    }
    if (k & BLNS__GST_FILL)
        ok = ok && dev.gst_fill == m.fill;
    if (k & BLNS__SES_FILL)
        ok = ok && dev.ses_fill == m.fill;
    if (k & BLNS__GST_TRANSP)
        ok = ok && dev.gst_transp == m.transp;
    if (k & BLNS__GST_SRC)
        ok = ok && (dev.gst_src & 0xFFFFu) == m.spitch && ((dev.gst_src >> 16) & 0xFu) == m.sfmt &&
             dev.gst_src_addr == m.src && !m.imm_arm;
    if (k & BLNS__GST_TEX)
        ok = ok && dev.gst_tex == m.tex;
    if (k & BLNS__GST_STEP)
        ok = ok && dev.gst_step == m.step;
    if (k & BLNS__GST_CUR)
        ok = ok && !m.xy && dev.cur_base == m.dst && dev.cur_pitch == m.dpitch;
    if (k & BLNS__GST_XYDST)
        ok = ok && m.xy && dev.xy_origin == m.dst && dev.xy_pitch == m.dpitch;
    if (k & BLNS__GST_XYPOS)
        ok = ok && m.x == dev.xy_x && m.y == dev.xy_y;
    if (k & BLNS__GST_PEN)
        ok = ok && m.pen == (((uint32_t) (uint16_t) dev.pen_y << 16) | (uint16_t) dev.pen_x);
    return ok;
}

/* Two draws the same in what the operation uses (a DELTA aside: it depends
 * on the cursor the driver knows) */
static bool draw_same(const draw_t *a, const draw_t *b)
{
    const uint32_t op   = a->op, rop = a->word & 0xFu;
    const bool     line = op == 0x8u && (a->word & BLNS_GPU_EXEC_LINE_Msk);
    const bool     copy = op == 0x9u || op == 0xAu;
    const bool     tex  = op == 0xDu || op == 0xEu;
    const bool     src  = copy || op == 0xCu || tex;
    const bool     fill = (op == 0x8u || op == 0xBu || op == 0xCu || (copy && rop == 15u));
    const bool     tr   = op == 0xAu || ((op == 0x8u || copy) && rop >= 13u) ||
                          (op == 0xCu && (a->word & BLNS_GPU_EXP_OPAQUE_Msk)) ||
                          (tex && (a->tex & BLNS_GPU_TEX_TRANSP_Msk)) || (line && (a->word & BLNS_GPU_LINE_OPAQUE_Msk));
    const uint32_t dm   = (op >= 0xBu && op <= 0xEu) ? ~(0x3FFFu << 14) : ~0u;
    return op == b->op && (a->word & dm) == (b->word & dm) && a->addr == b->addr && a->pitch == b->pitch &&
           (line || (a->w == b->w && a->h == b->h)) && (!fill || a->fill == b->fill) &&
           (!tr || a->transp == b->transp) &&
           (!src || (a->src == b->src && a->src_pitch == b->src_pitch && a->src_fmt == b->src_fmt && a->imm == b->imm)) &&
           (!tex || (a->tex == b->tex && a->step == b->step)) && (op != 0xEu || a->texbox == b->texbox) &&
           (!line || (a->opnd == b->opnd && a->pen == b->pen));
}

/* A case: phase 0 the calls before (the settings they leave cached differ
 * from the long call's), phase 1 the long call (its status in tc_st) */
static blns_status_t tc_st;
static uint32_t      tc_data[64];
static const blns_surf_t tc_a = { 1000u, 64u, 0u }, tc_b = { 3000u, 64u, 0u }, tc_s0 = { 6000u, 32u, 0u },
                         tc_s1 = { 7000u, 48u, 0u };

static bool tc_before_blit(void)
{
    const blns_blit_t k = { BLNS_ROP_S, true, 5u, false, BLNS_REMAP_OFF, false };
    return blns_gpu_fill(&dev, &tc_a, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK &&
           blns_gpu_blit(&dev, &tc_s0, &tc_b, 4u, 4u, &k) == BLNS_OK;
}

static bool tc_blit(int ph)                 /* 10 words */
{
    if (ph == 0)
        return tc_before_blit();
    const blns_blit_t o = { BLNS_ROP_FILL_IF_S, true, 6u, false, BLNS_REMAP_OFF, false };
    blns_gpu_colour_set(&dev, 12u);
    tc_st = blns_gpu_blit(&dev, &tc_s1, &tc_a, 5u, 3u, &o);
    return true;
}

static const blns_tex_t tc_tex = { .addr = 12000u, .log2_w = 6u, .log2_h = 6u, .transp = true, .transparent = 5u };

static bool tc_tex_span(int ph)             /* 9 words */
{
    if (ph == 0) {
        const blns_blit_t k = { BLNS_ROP_S, true, 7u, false, BLNS_REMAP_OFF, false };
        return blns_gpu_tex_begin(&dev, &tc_tex, 3000u, 0u, 0u) == BLNS_OK &&
               blns_gpu_tex_step(&dev, 0x100, 0) == BLNS_OK &&
               blns_gpu_tex_span(&dev, 3000u, 16u, 0u, 0u) == BLNS_OK &&
               blns_gpu_blit(&dev, &tc_s0, &tc_b, 4u, 4u, &k) == BLNS_OK;
    }
    tc_st = blns_gpu_tex_span(&dev, 3320u + 640u, 16u, 0u, 64u);
    return true;
}

static bool tc_texrect(int ph)              /* 15 words */
{
    if (ph == 0) {
        const blns_blit_t k = { BLNS_ROP_S, true, 7u, false, BLNS_REMAP_OFF, false };
        return blns_gpu_xy_begin(&dev, 20000u, 100u, 11u) == BLNS_OK &&
               blns_gpu_tex_set(&dev, &tc_tex, 0u) == BLNS_OK &&
               blns_gpu_fill_xy(&dev, 5, 6, 3u, 2u) == BLNS_OK &&
               blns_gpu_blit(&dev, &tc_s0, &tc_b, 4u, 4u, &k) == BLNS_OK;
    }
    tc_st = blns_gpu_texrect_xy(&dev, 7, 9, 6u, 5u, 64u, 0u, 0x200, 0, 0, 0x200);
    return true;
}

static bool tc_tritex(int ph)               /* 19 words */
{
    if (ph == 0)
        return tc_texrect(0);
    const int32_t x[3] = { BLNS_SUB(2), BLNS_SUB(12), BLNS_SUB(4) }, y[3] = { BLNS_SUB(3), BLNS_SUB(5), BLNS_SUB(14) };
    tc_st = blns_gpu_tritex_xy(&dev, x, y, 0u, 0u, 0x400, 0, 0, 0x400);
    return true;
}

static bool tc_outline(int ph)              /* 14 words, four EXECs */
{
    if (ph == 0) {
        blns_gpu_colour_set(&dev, 3u);
        return blns_gpu_xy_begin(&dev, 20000u, 100u, 3u) == BLNS_OK &&
               blns_gpu_line_px(&dev, 1, 1, 9, 1, NULL) == BLNS_OK &&
               blns_gpu_fill(&dev, &tc_a, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK;
    }
    const blns_line_t o = { .rop = BLNS_ROP_S, .opaque = true, .bg = 4u };
    blns_gpu_colour_set(&dev, 8u);
    tc_st = blns_gpu_rect_outline_xy(&dev, 20, 20, 6u, 5u, &o);
    return true;
}

static bool tc_blit_imm(int ph)             /* 10 words, then 32 data words */
{
    if (ph == 0)
        return tc_before_blit();
    const blns_blit_t o = { BLNS_ROP_FILL_IF_S, true, 6u, false, BLNS_REMAP_OFF, false };
    blns_gpu_colour_set(&dev, 12u);
    tc_st = blns_gpu_blit_imm(&dev, &tc_a, 8u, 8u, &o, tc_data);
    return true;
}

static bool tc_expand_imm(int ph)           /* 10 words, then 3 data words */
{
    const blns_expand_t e = { .width = 8u, .height = 12u, .depth = BLNS_EXP_1BPP, .opaque = true };
    if (ph == 0)
        return blns_gpu_expand_begin(&dev, &e, 2000u, 0u, 2u, 6u) == BLNS_OK &&
               blns_gpu_expand(&dev, 100u, 2000u) == BLNS_OK &&
               blns_gpu_fill(&dev, &tc_a, 4u, 4u, 9u, BLNS_ROP_S) == BLNS_OK &&
               blns_gpu_copy_transp(&dev, &tc_s0, &tc_b, 3u, 3u, BLNS_ROP_S, 7u) == BLNS_OK;
    tc_st = blns_gpu_expand_imm(&dev, 2008u + 3200u, tc_data);
    return true;
}

static void tc_setup(uint32_t extra)
{
    setup_fifo(BLNS_DIF_DPI, extra, 3u);                    /* FIFO of 8 words */
    blns_gpu_enable(&dev, true);
    model_run();
}

/* Every word position: k words queued before (the GPU stopped), then the
 * GPU taking 1 or 2 words a poll and the wait ending at poll 'lim' */
static void tc_sweep(const char *name, bool (*f)(int), uint32_t extra, unsigned min_words)
{
    for (unsigned i = 0; i < 64u; i++)
        tc_data[i] = 0x80000000u | i;                       /* as words: EXEC_FILL */
    draw_t   ref[8];
    unsigned nref;
    tc_setup(extra);
    CHECK(f(0));
    model_run();
    unsigned n0 = m.nd, w0;
    CHECK(f(0));
    w0 = m.words;
    f(1);
    const unsigned words = m.words - w0;                    /* with every setting sent again */
    CHECK(tc_st == BLNS_OK);
    model_run();
    nref = m.nd - n0;
    CHECK(nref >= 1u && nref <= 8u);
    if (nref > 8u)
        return;
    memcpy(ref, &m.d[n0], nref * sizeof ref[0]);
    unsigned bad = 0, partial = 0, cuts = 0, busy = 0;
    for (unsigned nb = 0; nb < 2u; nb++)
        for (unsigned step = 1; step <= 2u; step++)
            for (unsigned k = 0; k <= 8u; k++)
                for (unsigned lim = 1; lim <= 24u; lim++) {
                    tc_setup(extra);
                    bool good = f(0);
                    model_run();
                    hook_runs_gpu = false;
                    for (unsigned i = 0; i < k; i++)
                        good = good && blns_gpu_fence(&dev, false, NULL) == BLNS_OK;
                    hook_runs_gpu = true;
                    hook_step     = step;
                    hook_polls    = 0u;
                    hook_limit    = lim;
                    blns_set_nonblocking(&dev, nb != 0u);
                    w0 = m.words;
                    const unsigned d0 = m.discards;
                    f(1);
                    const blns_status_t st   = tc_st;
                    const unsigned      sent = m.words - w0;
                    blns_set_nonblocking(&dev, false);
                    hook_limit = 0u;
                    hook_step  = 0u;
                    good = good && (st == BLNS_OK || st == BLNS_ERR_TIMEOUT ||
                                    (nb && st == BLNS_ERR_BUSY && sent == 0u && k > 0u));
                    busy += st == BLNS_ERR_BUSY;
                    partial += st == BLNS_ERR_TIMEOUT && sent > 0u && m.discards == d0;
                    if (m.discards != d0) {                 /* in the data, the commands all sent: discarded */
                        cuts++;
                        good = good && st == BLNS_ERR_TIMEOUT && sent < words && m.markers > 0u;
                    }
                    good = good && !m.owed && !m.arm && !m.pact && (st != BLNS_ERR_TIMEOUT || sent <= words);
                    model_run();
                    good = good && cache_ok() && !m.err;
                    /* the next calls, no recover: as without the timeout */
                    n0   = m.nd;
                    good = good && f(0);
                    f(1);
                    good = good && tc_st == BLNS_OK;
                    model_run();
                    good = good && m.nd - n0 == nref && cache_ok() && !m.err && !m.overflow;
                    for (unsigned i = 0; good && i < nref; i++)
                        good = draw_same(&m.d[n0 + i], &ref[i]);
                    if (!good && bad++ == 0u)
                        printf("  %s: nb %u step %u k %u lim %u: st %d, %u words sent\n", name, nb, step, k, lim,
                               (int) st, sent);
                }
    if (bad || words < min_words || !partial || !busy)
        printf("  %s: %u bad, %u words, %u partial, %u busy\n", name, bad, words, partial, busy);
    CHECK(bad == 0u && words >= min_words && partial > 0u && busy > 0u);
    CHECK(cuts == 0u || (extra & BLNS_CFG2_IMM_Msk));
    CHECK(cuts > 0u || !(extra & BLNS_CFG2_IMM_Msk));       /* timeouts in the data: discarded */
}

static void test_timeout_cmds(void)
{
    const uint32_t imm  = BLNS_HW_OFF(GPU_IMM) ? 0u : BLNS_CFG2_IMM_Msk;
    const uint32_t line = BLNS_HW_OFF(GPU_LINE) ? 0u : BLNS_CFG2_LINE_Msk;
    tc_sweep("blit", tc_blit, 0u, 10u);
    tc_sweep("tex_span", tc_tex_span, 0u, 9u);
    tc_setup(imm | line);
    const bool xy = BLNS_HAS(&dev, GPU_XY), tri = BLNS_HAS(&dev, GPU_TRI);
    const bool has_line = BLNS_HAS(&dev, GPU_LINE), has_imm = BLNS_HAS(&dev, GPU_IMM);
    if (xy)
        tc_sweep("texrect_xy", tc_texrect, 0u, 15u);
    if (tri)
        tc_sweep("tritex_xy", tc_tritex, 0u, 19u);
    if (has_line)
        tc_sweep("rect_outline_xy", tc_outline, line, 14u);
    if (has_imm) {
        tc_sweep("blit_imm", tc_blit_imm, imm, 10u + 32u);
        tc_sweep("expand_imm", tc_expand_imm, imm, 10u + 3u);
    }
    /* a raw push longer than the FIFO still streams word by word: a timeout
     * may cut it (G3: discarded); one that fits: nothing sent */
    tc_setup(0u);
    hook_runs_gpu = false;
    const uint32_t w[2] = { BLNS_GPU_OP_SET_FILL, 1u };
    for (unsigned i = 0; i < 7u; i++)
        CHECK(blns_gpu_fence(&dev, false, NULL) == BLNS_OK);
    hook_limit = 2u;
    hook_polls = 0u;
    const unsigned w0 = m.words;
    CHECK(blns_gpu_push(&dev, w, 2u) == BLNS_ERR_TIMEOUT && m.words == w0 && m.discards == 0u && !m.owed);
    hook_runs_gpu = true;
    hook_limit    = 0u;
    model_run();
}

/*---------------------------------------------------------------------------
 * RGB565A8 sources, MIX5, bilinear sampling (SPEC_alpha_bilinear)
 *---------------------------------------------------------------------------*/

#if !BLNS_HW_OFF(GPU_BLEND) || !BLNS_HW_OFF(GPU_BILINEAR)
/* The references of these tests, from the specification's text (not the
 * model's code): the blend of one RGB565 pixel by an alpha 0 .. 255, the
 * rounded or LVGL's (MIX5) rule, and the combination x o A */
static uint16_t ref_mix(uint16_t s, uint16_t d, int alpha, bool m5)
{
    const int a = m5 ? 8 * ((alpha + 4) / 8) : (alpha == 255 ? 256 : alpha), r = m5 ? 0 : 128;
    if (a == 0)
        return d;
    static const int sh[3] = { 11, 5, 0 }, mk[3] = { 31, 63, 31 };
    uint16_t o = 0;
    for (int f = 0; f < 3; f++) {
        const int sv = (s >> sh[f]) & mk[f], dv = (d >> sh[f]) & mk[f];
        const int x  = (sv - dv) * a + r;
        o |= (uint16_t) ((dv + (x >= 0 ? x / 256 : -((-x + 255) / 256))) << sh[f]);
    }
    return o;
}

static int ref_comb(int x, int A, bool m5)
{
    return m5 ? x * A / 256 : (2 * x * A + 255) / 510;     /* floor(x A / 256), round(x A / 255) */
}

static uint32_t rnd_x = 1u;
static uint32_t rnd(void)
{
    rnd_x = rnd_x * 1664525u + 1013904223u;
    return rnd_x >> 8;
}

static uint16_t *px16p(uint32_t pa) { return &((uint16_t *) vram)[pa]; }
static uint8_t  *b8p(uint32_t b)    { return &((uint8_t *) vram)[b]; }
#endif

static void test_a8(void)
{
    const blns_surf_t src = { 1000u, 16u, BLNS_SWAP_NONE }, dst = { 3000u, 16u, BLNS_SWAP_NONE };
    const blns_blit_t a8  = { .src_alpha = true };
    const blns_tex_t  ta  = { .addr = 1000u, .log2_w = 4u, .log2_h = 4u, .src_alpha = true };
    const blns_tex_t  tbr = { .addr = 1000u, .log2_w = 4u, .log2_h = 4u, .bound = true, .box_w = 8u, .box_h = 8u,
                              .border_transparent = true };
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    if (!BLNS_HAS(&dev, GPU_BLEND)) {               /* absent: BLNS_ERR_ABSENT, nothing pushed */
        const unsigned w0 = m.words;
        CHECK(blns_gpu_blend_rule(&dev, BLNS_MIX5) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_blend_rule(&dev, BLNS_MIX_ROUND) == BLNS_OK);
        CHECK(blns_gpu_alpha_plane(&dev, 8000u) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_ERR_ABSENT);
        CHECK(blns_gpu_tex_set(&dev, &ta, 0u) == BLNS_ERR_ABSENT && blns_gpu_tex_set(&dev, &tbr, 0u) == BLNS_ERR_ABSENT);
        CHECK(m.words == w0);
    }
#if !BLNS_HW_OFF(GPU_BLEND)
    setup(BLNS_DIF_DPI, BLNS_CFG2_BLEND_Msk | BLNS_CFG2_MPLANE_Msk | BLNS_CFG2_IMM_Msk);
    blns_gpu_enable(&dev, true);
    model_run();
    CHECK(BLNS_HAS(&dev, GPU_BLEND));
    unsigned w0 = m.words;
    CHECK(blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_ERR_STATE);     /* no alpha plane */
    CHECK(blns_gpu_tex_set(&dev, &ta, 0u) == BLNS_ERR_STATE);
    CHECK(blns_gpu_alpha_plane(&dev, MODEL_WORDS * 4u) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_blend_rule(&dev, (blns_mix_t) 2) == BLNS_ERR_PARAM);
    CHECK(m.words == w0);
    /* the pointer: SET_AUX ALPHA_PLANE, always sent */
    CHECK(blns_gpu_alpha_plane(&dev, 20000u) == BLNS_OK && blns_gpu_alpha_plane(&dev, 20000u) == BLNS_OK);
    model_run();
    CHECK(m.words == w0 + 4u && m.a8 == 20000u && !m.err);
    /* pixels: a 16 x 4 source with every alpha class, over random pixels */
    static const uint8_t al[16] = { 0, 1, 3, 4, 7, 128, 200, 251, 252, 253, 254, 255, 64, 32, 250, 5 };
    for (uint32_t i = 0; i < 64u; i++) {
        *px16p(1000u + (i / 16u) * 16u + i % 16u) = (uint16_t) rnd();
        *b8p(20000u + (i / 16u) * 16u + i % 16u)  = (i < 16u) ? al[i] : (uint8_t) rnd();
    }
    static const struct { bool m5, en; int A; } cs[] = {
        { false, false, 0 }, { true, false, 0 }, { false, true, 128 }, { true, true, 128 }, { true, true, 255 },
        { false, true, 255 }, { true, true, 1 }, { true, true, 254 },
    };
    for (unsigned c = 0; c < sizeof cs / sizeof cs[0]; c++) {
        uint16_t d0[64];
        for (uint32_t i = 0; i < 64u; i++)
            *px16p(3000u + (i / 16u) * 16u + i % 16u) = d0[i] = (uint16_t) rnd();
        CHECK(blns_gpu_blend_rule(&dev, cs[c].m5 ? BLNS_MIX5 : BLNS_MIX_ROUND) == BLNS_OK);
        CHECK(blns_gpu_alpha(&dev, cs[c].en, (uint8_t) cs[c].A) == BLNS_OK);
        CHECK(blns_gpu_alpha_plane(&dev, blns_alpha_of(src.addr, 1000u, 20000u)) == BLNS_OK);
        CHECK(blns_gpu_blit(&dev, &src, &dst, 16u, 4u, &a8) == BLNS_OK && last()->src_fmt == BLNS_FMT_RGB565A8);
        unsigned bad = 0;
        for (uint32_t i = 0; i < 64u; i++) {
            const int      b  = *b8p(20000u + (i / 16u) * 16u + i % 16u);
            const int      av = cs[c].en ? ref_comb(b, cs[c].A, cs[c].m5) : b;
            const uint16_t ex = ref_mix(*px16p(1000u + (i / 16u) * 16u + i % 16u), d0[i], av, cs[c].m5);
            bad += *px16p(3000u + (i / 16u) * 16u + i % 16u) != ex;
        }
        if (bad)
            printf("  a8 copy case %u: %u pixels differ\n", c, bad);
        CHECK(bad == 0u && !m.err);
    }
    /* a sub-rectangle: the pointer of its first pixel, a swapped walk */
    const blns_surf_t sub = { 1000u + 16u + 2u, 16u, BLNS_SWAP_NONE }, sub_x = { 1000u + 16u + 9u, 16u, BLNS_SWAP_X };
    for (int k = 0; k < 2; k++) {
        const blns_surf_t *sv = k ? &sub_x : &sub;
        for (uint32_t i = 0; i < 64u; i++)
            *px16p(3000u + i) = 0x1234u;
        blns_gpu_alpha(&dev, false, 0u);
        CHECK(blns_gpu_alpha_plane(&dev, blns_alpha_of(sv->addr, 1000u, 20000u)) == BLNS_OK);
        CHECK(blns_gpu_blit(&dev, sv, &dst, 8u, 2u, &a8) == BLNS_OK);
        model_run();
        unsigned bad = 0;
        for (uint32_t j = 0; j < 2u; j++)
            for (uint32_t i = 0; i < 8u; i++) {
                const uint32_t sp = sv->addr + j * 16u + (k ? -i : i);
                bad += *px16p(3000u + j * 16u + i) != ref_mix(*px16p(sp), 0x1234u, *b8p(20000u + sp - 1000u), true);
            }
        CHECK(bad == 0u);
    }
    /* COPY_TRANSP: the key on the raw colour first */
    *px16p(1000u) = 0x0F0Fu;
    *b8p(20000u)  = 255u;
    *px16p(3000u) = 0x5555u;
    const blns_blit_t kt = { .transp = true, .transparent = 0x0F0Fu, .src_alpha = true };
    CHECK(blns_gpu_alpha_plane(&dev, 20000u) == BLNS_OK && blns_gpu_blit(&dev, &src, &dst, 1u, 1u, &kt) == BLNS_OK);
    model_run();
    CHECK(*px16p(3000u) == 0x5555u && !m.err);
    /* one plane per copy, no alpha in pushed data */
    const blns_blit_t mp = { .mplane = true, .src_alpha = true };
    CHECK(blns_gpu_mask_plane(&dev, 4096u, false) == BLNS_OK);
    w0 = m.words;
    CHECK(blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &mp) == BLNS_ERR_PARAM);
    const uint32_t data[2] = { 0u, 0u };
    CHECK(blns_gpu_blit_imm(&dev, &dst, 2u, 2u, &a8, data) == BLNS_ERR_PARAM && m.words == w0);
    /* the rule: in every SET_ALPHA word; a setting of the session (a recover
     * keeps it), RESET_STATE returns it to ROUND; the pointer is forgotten */
    CHECK(blns_gpu_blend_rule(&dev, BLNS_MIX5) == BLNS_OK && blns_gpu_alpha(&dev, false, 255u) == BLNS_OK);
    model_run();
    CHECK((m.alpha & BLNS_GPU_ALPHA_MIX5_Msk) && !(m.alpha & BLNS_GPU_ALPHA_EN_Msk));
    blns_gpu_recover(&dev);
    CHECK(blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_ERR_STATE);
    CHECK(blns_gpu_alpha(&dev, true, 9u) == BLNS_OK);
    model_run();
    CHECK(m.alpha == (BLNS_GPU_ALPHA_MIX5_Msk | BLNS_GPU_ALPHA_EN_Msk | 9u));
    CHECK(blns_gpu_reset_state(&dev) == BLNS_OK);
    model_run();
    CHECK(m.alpha == 0u && m.a8 == 0u);
    CHECK(blns_gpu_alpha(&dev, true, 9u) == BLNS_OK);
    model_run();
    CHECK(m.alpha == (BLNS_GPU_ALPHA_EN_Msk | 9u));
    CHECK(blns_gpu_alpha_plane(&dev, 20000u) == BLNS_OK);
    blns_gpu_forget(&dev);
    CHECK(blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_ERR_STATE);
    /* lists: a list sets its own pointer, which applies at its call */
    blns_gpu_list_t l = { .addr = 8000u, .capacity = 64u };
    CHECK(blns_gpu_alpha_plane(&dev, 20000u) == BLNS_OK);
    CHECK(blns_gpu_list_begin(&dev, &l, 0u) == BLNS_OK);
    CHECK(blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_ERR_STATE);
    CHECK(blns_gpu_alpha_plane(&dev, 20000u) == BLNS_OK && blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_OK);
    CHECK(blns_gpu_list_end(&dev) == BLNS_OK && l.aux_set == BLNS__AUX_ALPHA);
    blns_gpu_forget(&dev);
    CHECK(blns_gpu_list_call(&dev, &l, false) == BLNS_OK && blns_gpu_blit(&dev, &src, &dst, 4u, 4u, &a8) == BLNS_OK);
    model_run();
    CHECK(!m.err);
#if !BLNS_HW_OFF(GPU_XY)
    /* a texture session with src_alpha: the pointer checked at each draw */
    if (BLNS_HAS(&dev, GPU_XY)) {
        CHECK(blns_gpu_xy_begin(&dev, 3000u, 16u, 0u) == BLNS_OK && blns_gpu_tex_set(&dev, &ta, 0u) == BLNS_OK);
        CHECK(blns_gpu_texrect_xy(&dev, 0, 0, 4u, 4u, 0u, 0u, 2048, 0, 0, 2048) == BLNS_OK &&
              last()->src_fmt == BLNS_FMT_RGB565A8);
        blns_gpu_recover(&dev);
        CHECK(blns_gpu_texrect_xy(&dev, 0, 0, 4u, 4u, 0u, 0u, 2048, 0, 0, 2048) == BLNS_ERR_STATE);
        CHECK(blns_gpu_tex_set(&dev, &tbr, 0u) == BLNS_OK);                 /* (with bound: XY) */
        const blns_tex_t nb = { .addr = 1000u, .log2_w = 4u, .log2_h = 4u, .border_transparent = true };
        CHECK(blns_gpu_tex_set(&dev, &nb, 0u) == BLNS_ERR_PARAM);           /* a border needs bound */
    }
#endif
    /* an alpha byte past the VRAM: cause 5, the pixels before it drawn */
    model_run();
    const blns_surf_t s2 = { 1000u, 16u, BLNS_SWAP_NONE };
    CHECK(blns_gpu_alpha_plane(&dev, MODEL_WORDS * 4u - 2u) == BLNS_OK && blns_gpu_blit(&dev, &s2, &dst, 4u, 1u, &a8) == BLNS_OK);
    model_run();
    CHECK(m.err && ((regs.GPU.STAT & BLNS_GPU_STAT_ERR_CAUSE_Msk) >> BLNS_GPU_STAT_ERR_CAUSE_Pos) == BLNS_GPU_ERR_BOUNDS);
    blns_gpu_recover(&dev);
#endif
    /* staging: ARGB8888 truncated as LV_COLOR_24_TO_16, the alphas copied */
    static const uint32_t argb[3] = { 0x80FF0703u, 0x00123456u, 0xFF0408F8u };
    uint16_t rgb[6] = { 0 };
    uint8_t  a[6]   = { 0 };
    blns_argb8888_to_rgb565a8(rgb, a, 2u, argb, 1u, 1u, 3u);
    CHECK(rgb[0] == 0xF820u && a[0] == 0x80u && rgb[2] == 0x11AAu && a[2] == 0x00u && rgb[1] == 0u);
    blns_argb8888_to_rgb565a8(rgb, a, 1u, &argb[2], 1u, 1u, 1u);
    CHECK(rgb[0] == ((0x04u >> 3) << 11 | (0x08u >> 2) << 5 | (0xF8u >> 3)) && a[0] == 0xFFu);
}

#if !BLNS_HW_OFF(GPU_BILINEAR)
/* A bilinear pixel from the specification's text (DECISIONS 5): the walker's
 * (u, v) in 10.11, the taps, their weights and premultiplied alphas, the
 * blend over d (blend build) or the straight colour */
typedef struct {
    uint32_t base, pitch, a8;       /* texture pixel address, pitch, alpha plane byte of base */
    unsigned lw, lh;                /* power of two (free pitch: 0) */
    bool     free, bound, tb, a8on, blend, m5, en, ten;
    int      TW, TH, A;
    uint16_t key;
} bref_t;

static bool ref_bil(const bref_t *t, int32_t ua, int32_t va, uint16_t d, uint16_t *out, int *taps)
{
    const int32_t U = ua & 0x1FFFFF, V = va & 0x1FFFFF;
    const int32_t Us = (U >= 0x100000) ? U - 0x200000 : U, Vs = (V >= 0x100000) ? V - 0x200000 : V;
    if (t->bound) {
        const int32_t fu = (int32_t) floor(Us / 2048.0), fv = (int32_t) floor(Vs / 2048.0);
        if (fu < 0 || fu >= t->TW || fv < 0 || fv >= t->TH)
            return false;
    }
    const int32_t Up = ((t->bound ? Us : U) - 1024), Vp = ((t->bound ? Vs : V) - 1024);
    const int32_t x0 = (int32_t) floor(Up / 2048.0), y0 = (int32_t) floor(Vp / 2048.0);
    const int32_t fx = ((((Up % 2048) + 2048) % 2048 / 8) + 4) / 8, fy = ((((Vp % 2048) + 2048) % 2048 / 8) + 4) / 8;
    double S = 0;
    long   P[3] = { 0, 0, 0 }, Si = 0;
    *taps = 0;
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2; j++) {
            const int k = (j ? fx : 32 - fx) * (i ? fy : 32 - fy);
            if (!k)
                continue;
            int x = x0 + j, y = y0 + i;
            if (t->bound) {
                if (t->tb && (x < 0 || x >= t->TW || y < 0 || y >= t->TH))
                    continue;
                x = x < 0 ? 0 : x >= t->TW ? t->TW - 1 : x;
                y = y < 0 ? 0 : y >= t->TH ? t->TH - 1 : y;
            } else {
                x = ((x % 1024) + 1024) % 1024;
                y = ((y % 1024) + 1024) % 1024;
            }
            if (!t->free) {
                x %= 1 << t->lw;
                y %= 1 << t->lh;
            }
            const uint32_t p = t->base + (uint32_t) y * t->pitch + (uint32_t) x;
            const uint16_t c = *px16p(p);
            int            a = t->a8on ? *b8p(t->a8 + p - t->base) : 255;
            if (t->ten && t->blend && c == t->key)
                a = 0;
            if (t->en)
                a = ref_comb(a, t->A, t->m5);
            const long e = (long) k * (a + (a >= 128 ? 1 : 0)) / 256;
            Si += e;
            P[0] += e * (c >> 11);
            P[1] += e * ((c >> 5) & 63);
            P[2] += e * (c & 31);
            (*taps)++;
        }
    (void) S;
    static const int sh[3] = { 11, 5, 0 }, mk[3] = { 31, 63, 31 };
    uint16_t o = 0;
    if (!t->blend) {
        for (int f = 0; f < 3; f++)
            o |= (uint16_t) (((P[f] + 512) / 1024) << sh[f]);
        *out = o;
        return true;
    }
    const long a256 = Si / 4;
    if (!a256)
        return false;
    for (int f = 0; f < 3; f++) {
        const long pm = t->m5 ? P[f] / 4 : (P[f] + 2) / 4, dv = (d >> sh[f]) & mk[f];
        o |= (uint16_t) ((dv + (long) floor((pm - dv * a256 + (t->m5 ? 0 : 128)) / 256.0)) << sh[f]);
    }
    *out = o;
    return true;
}
#endif

static void test_bilinear(void)
{
    setup(BLNS_DIF_DPI, 0u);
    blns_gpu_enable(&dev, true);
    model_run();
    const blns_tex_t tb0 = { .addr = 2000u, .log2_w = 3u, .log2_h = 3u, .bilinear = true };
    if (!BLNS_HAS(&dev, GPU_BILINEAR)) {
        const unsigned w0 = m.words;
        CHECK(blns_gpu_tex_set(&dev, &tb0, 0u) == BLNS_ERR_ABSENT && m.words == w0);
        CHECK(!dev.caps.gpu_bilinear);
    }
#if !BLNS_HW_OFF(GPU_BILINEAR)
    for (int blend = 1; blend >= 0; blend--) {
#if BLNS__HW_GPU_BLEND == 1
        if (!blend)
            break;                                  /* (the platform states blending) */
#endif
        setup(BLNS_DIF_DPI, BLNS_CFG2_BILINEAR_Msk | (blend ? BLNS_CFG2_BLEND_Msk : 0u));
        blns_gpu_enable(&dev, true);
        model_run();
        CHECK(BLNS_HAS(&dev, GPU_BILINEAR) && dev.caps.gpu_bilinear && BLNS_HAS(&dev, GPU_BLEND) == (blend != 0));
        CHECK(blns_gpu_xy_begin(&dev, 6000u, 64u, 0u) == BLNS_OK);
        /* the filter: with the texture, again only when it changes or is unknown */
        unsigned w0 = m.words;
        CHECK(blns_gpu_tex_set(&dev, &tb0, 0u) == BLNS_OK);
        model_run();
        const unsigned n1 = m.words - w0;
        CHECK(m.filt == BLNS_GPU_AUX_BILINEAR_Msk && !m.err);
        w0 = m.words;
        CHECK(blns_gpu_tex_set(&dev, &tb0, 0u) == BLNS_OK && m.words - w0 == n1 - 2u);
        const blns_tex_t tn = { .addr = 2000u, .log2_w = 3u, .log2_h = 3u };
        CHECK(blns_gpu_tex_set(&dev, &tn, 0u) == BLNS_OK);
        model_run();
        CHECK(m.filt == 0u);
        CHECK(blns_gpu_tex_set(&dev, &tb0, 0u) == BLNS_OK);
        blns_gpu_forget(&dev);
        model_reg_wr(&regs.GPU.CTRL, 0u);
        m.filt = 0u;                                /* (as if another program changed it) */
        CHECK(blns_gpu_xy_begin(&dev, 6000u, 64u, 0u) == BLNS_OK && blns_gpu_tex_set(&dev, &tb0, 0u) == BLNS_OK);
        model_run();
        CHECK(m.filt == BLNS_GPU_AUX_BILINEAR_Msk);
        const blns_tex_t tbx = { .addr = 2000u, .log2_w = 3u, .log2_h = 3u, .bilinear = true, .bound = true,
                                 .box_w = 8u, .box_h = 8u, .border_transparent = true };
        CHECK(blns_gpu_tex_set(&dev, &tbx, 0u) == (blend ? BLNS_OK : BLNS_ERR_ABSENT));
        model_run();
        CHECK(!m.err && m.filt == (blend ? (BLNS_GPU_AUX_BILINEAR_Msk | BLNS_GPU_AUX_TBORDER_Msk)
                                         : BLNS_GPU_AUX_BILINEAR_Msk));
        const blns_tex_t big = { .addr = 2000u, .log2_w = 3u, .log2_h = 3u, .bilinear = true, .bound = true,
                                 .box_w = 513u, .box_h = 8u };
        CHECK(blns_gpu_tex_set(&dev, &big, 0u) == BLNS_ERR_PARAM);
        /* pixels: an 8 x 8 texture (and its alpha plane) under every filter
         * case, a 24 x 20 walk across it and around its box */
        for (uint32_t i = 0; i < 64u; i++) {
            *px16p(2000u + i) = (uint16_t) rnd();
            const uint32_t r = rnd() % 4u;
            *b8p(30000u + i)  = (uint8_t) (r == 0 ? 0 : r == 1 ? 255 : rnd());
        }
        *px16p(2000u + 9u) = 0x7BEFu;               /* the key */
        unsigned cases = 0, bad = 0, nt = 0;
        for (unsigned c = 0; c < 64u; c++) {
            const bool bound = c & 1u, tbo = (c & 2u) && bound && blend, a8on = (c & 4u) && blend;
            const bool m5 = (c & 8u) && blend, en = (c & 16u) && blend, ten = (c & 32u) != 0u;
            if ((c & 2u) && !tbo)
                continue;
            const blns_tex_t t = { .addr = 2000u, .log2_w = 3u, .log2_h = 3u, .bilinear = true, .bound = bound,
                                   .box_w = 6u, .box_h = 7u, .border_transparent = tbo, .src_alpha = a8on,
                                   .transp = ten, .transparent = 0x7BEFu };
            if (blend) {
                CHECK(blns_gpu_blend_rule(&dev, m5 ? BLNS_MIX5 : BLNS_MIX_ROUND) == BLNS_OK);
                CHECK(blns_gpu_alpha(&dev, en, 200u) == BLNS_OK);
                CHECK(blns_gpu_alpha_plane(&dev, 30000u) == BLNS_OK);
            }
            CHECK(blns_gpu_tex_set(&dev, &t, 0u) == BLNS_OK);
            uint16_t d0[24 * 20];
            for (uint32_t i = 0; i < 24u * 20u; i++)
                *px16p(6000u + (i / 24u) * 64u + i % 24u) = d0[i] = (uint16_t) rnd();
            /* u0 = -1.25, v0 = -0.875 (10.6, signed); du 0.37, dv 0.11, du' -0.05, dv' 0.41 */
            const int16_t du = 758, dv = 225, dur = -102, dvr = 840;
            const uint16_t u0 = (uint16_t) -80, v0 = (uint16_t) -56;
            CHECK(blns_gpu_texrect_xy(&dev, 0, 0, 24u, 20u, bound ? u0 : 64u, bound ? v0 : 32u, du, dv, dur, dvr) == BLNS_OK);
            const unsigned t0 = m.tap_rd;
            model_run();
            CHECK(!m.err);
            const bref_t rb = { 2000u, 8u, 30000u, 3u, 3u, false, bound, tbo, a8on, blend != 0, m5, en, ten, 6, 7, 200,
                                0x7BEFu };
            unsigned taps = 0;
            for (uint32_t i = 0; i < 24u * 20u; i++) {
                const int32_t  cc = (int32_t) (i % 24u), rr = (int32_t) (i / 24u);
                const int32_t  ua = (int16_t) (bound ? u0 : 64u) * 32 + rr * dur + cc * du;
                const int32_t  va = (int16_t) (bound ? v0 : 32u) * 32 + rr * dvr + cc * dv;
                uint16_t       ex = d0[i];
                int            tp = 0;
                const bool     nearest = ten && !blend;
                if (!nearest && !ref_bil(&rb, ua, va, d0[i], &ex, &tp))
                    ex = d0[i];
                taps += (unsigned) tp;
                if (!nearest)
                    bad += *px16p(6000u + (uint32_t) rr * 64u + (uint32_t) cc) != ex;
            }
            if (!(ten && !blend))
                CHECK(m.tap_rd - t0 == taps);       /* weight-0 and border taps not read */
            nt += taps;
            cases++;
        }
        if (bad)
            printf("  bilinear (blend %d): %u pixels differ\n", blend, bad);
        CHECK(bad == 0u && cases >= 16u && nt > 0u);
        /* texel-aligned: one tap, the texel itself (opaque: no leak) */
        CHECK(blns_gpu_blend_rule(&dev, BLNS_MIX_ROUND) == BLNS_OK && blns_gpu_alpha(&dev, false, 0u) == BLNS_OK);
        CHECK(blns_gpu_tex_set(&dev, &tb0, 0u) == BLNS_OK);
        unsigned t0 = m.tap_rd;
        CHECK(blns_gpu_texrect_xy(&dev, 0, 0, 4u, 1u, 32u, 96u, 2048, 0, 0, 0) == BLNS_OK);
        model_run();
        CHECK(m.tap_rd - t0 == 4u && *px16p(6000u) == *px16p(2000u + 8u) && *px16p(6003u) == *px16p(2000u + 11u));
    }
    /* blns_gpu_texrect_fx_xy: 64 x 64 tiles seeded from the 1/65536 model;
     * representable steps: the same pixels as one walk */
    setup(BLNS_DIF_DPI, BLNS_CFG2_BILINEAR_Msk);
    blns_gpu_enable(&dev, true);
    model_run();
    const blns_tex_t tw = { .addr = 20000u, .log2_w = 4u, .log2_h = 4u };
    for (uint32_t i = 0; i < 256u; i++)
        *px16p(20000u + i) = (uint16_t) rnd();
    CHECK(blns_gpu_xy_begin(&dev, 0u, 160u, 0u) == BLNS_OK && blns_gpu_tex_set(&dev, &tw, 0u) == BLNS_OK);
    unsigned n0 = m.nd;
    CHECK(blns_gpu_texrect_fx_xy(&dev, 3, 2, 150u, 70u, 65536 * 13 / 4, 65536 / 2, 32768, 8192, -4096, 49152) == BLNS_OK);
    model_run();
    CHECK(m.nd - n0 == 6u && m.d[n0].op == 0xEu && m.d[n0].w == 64u && m.d[n0 + 2u].w == 22u &&
          m.d[n0 + 3u].h == 6u && !m.err);
    static uint16_t got[160 * 72];
    for (uint32_t i = 0; i < 160u * 72u; i++)
        got[i] = *px16p(i);
    memset(vram, 0, 160u * 72u * 2u);
    CHECK(blns_gpu_texrect_xy(&dev, 3, 2, 150u, 70u, 208u, 32u, 1024, 256, -128, 1536) == BLNS_OK);
    model_run();
    unsigned diff = 0;
    for (uint32_t i = 0; i < 160u * 72u; i++)
        diff += got[i] != *px16p(i);
    CHECK(diff == 0u);
    n0 = m.nd;
    const unsigned w0 = m.words;
    CHECK(blns_gpu_texrect_fx_xy(&dev, 0, 0, 10u, 10u, 0, 0, 16 * 65536, 0, 0, 0) == BLNS_ERR_PARAM);
    CHECK(blns_gpu_texrect_fx_xy(&dev, 2000, 0, 100u, 10u, 0, 0, 0, 0, 0, 0) == BLNS_ERR_PARAM);
    CHECK(m.words == w0 && m.nd == n0);
#endif
#if BLNS_HW_OFF(GPU_XY)
    int64_t z = 0;
    CHECK(blns_gpu_texrect_fx_xy(&dev, 0, 0, 1u, 1u, z, z, 0, 0, 0, 0) == BLNS_ERR_ABSENT);
#endif
}

int main(int argc, char **argv)
{
    /* argument: the number of one test to run (all of them by default) */
    const long only = (argc > 1) ? strtol(argv[1], NULL, 10) : -1;
    static const struct { const char *name; void (*fn)(void); } tests[] = {
        { "init state",                test_init_state },
        { "sizes",                     test_sizes },
        { "sessions",                  test_sessions },
        { "batches, fast paths",       test_batches },
        { "recover",                   test_recover },
        { "waits",                     test_waits },
        { "presence",                  test_presence },
        { "lists",                     test_lists },
        { "controller",                test_controller },
        { "picture",                   test_picture },
        { "platform header",           test_platform },
        { "op 15 on copies",           test_silhouette },
        { "flip wait, bit address",    test_flip_wait },
        { "leftover state",            test_leftover },
        { "model: flush, errors",      test_model },
        { "recover from an irq",       test_recover_irq },
#if !BLNS_HW_OFF(GPU_IMM)
        { "recover, immediate data",   test_recover_imm },
#endif
        { "discard after a cut",       test_recover_cut },
        { "discard and recover",       test_discard },
        { "GPU_FIFO_LOW threshold",    test_fifo_low },
        { "polls without progress",    test_poll_budget },
        { "long push into partial room", test_push_stream },
        { "timeouts between commands", test_timeout_cmds },
        { "refused xy_begin",          test_xy_refused },
        { "dropped fences",            test_fence_drop },
        { "lost batch",                test_fence_lost_batch },
        { "error after acceptance",    test_fence_error },
        { "list, GPU_EN = 0",          test_fence_list_enable },
        { "spill, list tags",          test_fence_lists },
        { "raw push",                  test_raw_push },
        { "ERR policy",                test_err_policy },
        { "present in one push",       test_present },
        { "frame waits",               test_wait_frames },
        { "session pitch",             test_session_pitch },
        { "span session",              test_span_session },
        { "commit on OK",              test_session_commit },
        { "texture box",               test_tex_box },
        { "empty glyph",               test_expand_empty },
        { "UV gradients",              test_tri_gradients },
        { "surf_rect, pixels",         test_surf_rect },
        { "BLNS_HAS once",             test_has_once },
        { "GFX_MODE 5-7",              test_init_mode },
        { "hot-plug",                  test_hotplug },
        { "DDC",                       test_ddc },
        { "DPI params",                test_dpi_params },
        { "HDMI AVI / audio fields",   test_hdmi_avi },
        { "DBI sync",                  test_dbi_sync },
        { "DBI config (RD_DIV)",       test_dbi_config },
        { "DBI cmd FIFO",              test_dbi_cmd_fifo },
        { "line caps, gating",         test_line_caps },
#if BLNS__HW_GPU_LINE != 0
        { "line words",                test_line_words },
        { "line pixels",               test_line_pixels },
        { "line dashes",               test_line_dashes },
        { "line AA, remap",            test_line_aa },
        { "polyline, outline, lists",  test_polyline },
#endif
        { "line model: refusals",      test_line_model },
        { "hardware cursor",           test_cursor },
        { "RGB565A8, MIX5",            test_a8 },
        { "bilinear, fx tiles",        test_bilinear },
    };
    for (unsigned i = 0; i < sizeof tests / sizeof tests[0]; i++) {
        if (only >= 0 && (long) i != only)
            continue;
        const unsigned f0 = fails;
        tests[i].fn();
        CHECK(!m.overflow && !m.log_full);              /* T5: after every test, no silent cap */
        printf("%-36s %s\n", tests[i].name, fails == f0 ? "ok" : "FAILED");
    }
    printf("%u checks, %u failures (%s)\n", checks, fails,
#ifdef BLNS_PLATFORM_HEADER
           BLNS_PLATFORM_HEADER
#else
           "no platform header"
#endif
    );
    return fails ? 1 : 0;
}
