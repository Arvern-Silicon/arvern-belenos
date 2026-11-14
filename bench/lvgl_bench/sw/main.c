/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      main.c (bench/lvgl_bench)
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * LVGL benchmark bench firmware: LVGL v9.6's lv_demo_benchmark, unmodified,
 * on Belenos (lv_belenos.c), in the bench of verilog/tb_lvgl_bench.v.
 *
 *   display   LB_W x LB_H RGB565, frame 0 at pixel address 0, shown 1:1 by
 *             the DPI driver (on hclk, CLK_DIV from the bench's 111 MHz: a
 *             real panel's rate, so the refresh reads the VRAM as on a
 *             board). DIRECT flush (LVGL renders into the frame), with the
 *             GPU draw unit when the build has a GPU; LB_FLUSH_CPU: the CPU
 *             flush (PARTIAL, a draw buffer of a tenth of the screen in the
 *             data memory, copied by the CPU), the software renderer alone
 *   draw unit its extensions (lv_conf.h): the VRAM after the frame (the
 *             second frame's room, LB_W x LB_H x 2 bytes) is its pool, with
 *             LVGL's layers in it; LB_APPROX (cfg.approx, GRAD | TRANSFORM
 *             by default: the gradients and the rotated / scaled images of
 *             the personas that have them, lv_belenos.h; the blending is
 *             exact in every mode; 0: only what the GPU draws as LVGL does)
 *   time      LVGL's clock is the bench's lockstep clock: it moves by
 *             LV_DEF_REFR_PERIOD per pass of the main loop (one
 *             lv_timer_handler call), so every pass refreshes the display
 *             once and every build renders the same frames, each one
 *             LV_DEF_REFR_PERIOD of animation after the last, whatever
 *             its drawing costs (LB_TICK_REAL: the bench's millisecond
 *             counter, real time at 111 MHz, instead)
 *   measure   the display events LVGL's system monitor uses (render and
 *             flush start and end), timed with the bench's cycle counter;
 *             one "LB F" line per rendered frame on the console with the
 *             scene, the cycles and the VRAM counters (bin/lvgl_bench.py
 *             reduces them). The scene is the benchmark's: its scene timer
 *             (the last timer lv_demo_benchmark creates, at the head of
 *             LVGL's list) fires once per scene change. At the end, the
 *             benchmark's end callback lists the scenes ("LB S") and the
 *             conditions its summary screen warns about ("LB WARN"), and
 *             the summary in LVGL's CSV format from the cycle counts ("LB
 *             CSV"); with LB_TICK_REAL it then shows LVGL's own summary
 *             (lv_demo_benchmark_summary_display: LVGL's own CSV on the
 *             console). Not with the lockstep clock: LVGL's millisecond
 *             figures read 0 there (the clock stands still while a frame
 *             renders), and the summary's compiler-optimisation probe
 *             spins until its 1024-round give-up, about a billion cycles.
 *   console   the bench's TTY register; LVGL's log too
 *----------------------------------------------------------------------------*/
#include "lvgl.h"
#include "lvgl_private.h"
#include "demos/lv_demos.h"
#include "lv_belenos.h"
#include "lb_assert.h"

#ifndef LB_PERSONA
#define LB_PERSONA      "unnamed"
#endif
#ifndef LB_DUMP_FRAME
#define LB_DUMP_FRAME   0u              /* n > 0: dump each scene's n-th frame */
#endif
#ifndef LB_APPROX
#define LB_APPROX       (LV_BELENOS_APPROX_GRAD | LV_BELENOS_APPROX_TRANSFORM)
#endif

/*------------------------------- bench --------------------------------------*/

#define LB_REG(off)     (*(volatile uint32_t *) (0x10000000u + (off)))
#define LB_TTY          LB_REG(0x00)
#define LB_EXIT         LB_REG(0x04)
#define LB_MS           LB_REG(0x08)
#define LB_DUMP         LB_REG(0x0C)
#define LB_CYC_LO       LB_REG(0x10)
#define LB_CYC_HI       LB_REG(0x14)
#define LB_DUMP_PANEL   LB_REG(0x18)
#define LB_CNT(i)       LB_REG(0x20 + 4u * (i))   /* GPU_BUSY .. V_WAIT */
#define LB_PANEL_FRM    LB_REG(0x3C)
#define LB_CLK_HZ       LB_REG(0x40)
#define LB_CFG          LB_REG(0x44)
#define LB_PROF         LB_REG(0x48)   /* the bench's CPU profile (LB_PROFILE models) */
#define LB_NCNT         7u              /* GPU_BUSY, BK, WIN_RD, WIN_WR, GPU_RD, GPU_WR, V_WAIT */

#define BLNS_REG_BASE   0x10050000u
#define BLNS_VRAM_BASE  0x82000000u

static void lb_puts(const char *s)
{
    while (*s)
        LB_TTY = (uint32_t) (uint8_t) *s++;
}

static void lb_printf(const char *fmt, ...)
{
    char    buf[192];
    va_list ap;
    va_start(ap, fmt);
    lv_vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    lb_puts(buf);
}

static void lb_exit(uint32_t code)
{
    LB_EXIT = code;
    for (;;)
        ;
}

void lb_assert_failed(void)
{
    lb_puts("LB ERROR: LVGL assertion failed\n");
    lb_exit(2u);
}

void lb_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    lb_printf("LB ERROR: trap, mcause 0x%x, mepc 0x%x, mtval 0x%x\n", (unsigned) mcause, (unsigned) mepc,
              (unsigned) mtval);
    lb_exit(3u);
}

static void log_cb(lv_log_level_t level, const char *buf)
{
    (void) level;
    lb_puts(buf);
}

/* Every GPU recovery of the driver (the link wraps blns_gpu_recover): a
 * fault the glue redraws on the CPU would skew the timing, so a run with
 * one is reported (bin/lvgl_bench.py fails it) */
static uint32_t gpu_recovers;
blns_status_t   __real_blns_gpu_recover(blns_t *dev);
blns_status_t   __wrap_blns_gpu_recover(blns_t *dev)
{
    gpu_recovers++;
    return __real_blns_gpu_recover(dev);
}

/*------------------------------- time ---------------------------------------*/

#ifdef LB_TICK_REAL
static uint32_t tick_cb(void) { return LB_MS; }
#else
static uint32_t lockstep_ms;
static uint32_t tick_cb(void) { return lockstep_ms; }
#endif

/*------------------------------- Belenos ------------------------------------*/

static blns_t blns;

/* The panel timing of the preset (BLNS_DPI_480X272 / BLNS_DPI_800X480,
 * other sizes with the 800 x 480 porches), CLK_DIV for a ~57-60 Hz frame
 * rate from the bench clock */
static blns_status_t video_init(uint16_t w, uint16_t h, uint32_t hz)
{
    const blns_config_t cfg = { .reg_base = BLNS_REG_BASE, .vram_base = BLNS_VRAM_BASE, .hclk_hz = hz };
    blns_status_t st = blns_init(&blns, &cfg);
    if (st != BLNS_OK)
        return st;
    blns_dpi_timing_t t = BLNS_DPI_800X480;
    if (w == 480u && h == 272u) {
        const blns_dpi_timing_t p = BLNS_DPI_480X272;
        t = p;
    }
    t.h_act = w;
    t.v_act = h;
    const uint32_t total = (uint32_t) (w + t.h_fp + t.h_sync + t.h_bp) * (uint32_t) (h + t.v_fp + t.v_sync + t.v_bp);
    uint32_t div = hz / (total * 60u);  /* the smallest divider at or below 60 Hz */
    if (div * total * 60u < hz)
        div++;
    t.clk_div = (uint8_t) (div > 16u ? 15u : div - 1u);
    blns_set_mode(&blns, BLNS_BPP_16);
    blns_set_size(&blns, w, h);
    blns_set_frame(&blns, 0, 0);
    blns_select_frame(&blns, 0);
    if (BLNS_HAS(&blns, GPU))
        blns_gpu_enable(&blns, true);
    st = blns_dpi_config(&blns, &t);
    if (st == BLNS_OK)
        st = blns_dpi_image(&blns, w, h, 0, 0);
    if (st == BLNS_OK)
        st = blns_dpi_enable(&blns, true);
    lb_printf("LB DPI: %ux%u, %u x %u total, CLK_DIV %u, %u.%02u Hz\n", (unsigned) w, (unsigned) h,
              (unsigned) (w + t.h_fp + t.h_sync + t.h_bp), (unsigned) (h + t.v_fp + t.v_sync + t.v_bp),
              (unsigned) t.clk_div, (unsigned) (hz / ((t.clk_div + 1u) * total)),
              (unsigned) ((hz / ((t.clk_div + 1u) * (total / 100u))) % 100u));
    return st;
}

/*------------------------------- measurement --------------------------------*/

static lv_timer_t *scene_timer;         /* the benchmark's scene timer */
static uint32_t    scene_run;           /* its last_run, to see it fire */
static uint32_t    scene;               /* the scene being rendered */
static uint32_t    scene_frames;        /* frames rendered in it */
static volatile bool done;              /* the benchmark's end callback ran */

static uint32_t t_refr, t_render, t_flush0, flush_in, flush_out, frames, areas, px;
/* Per scene, the frames after its first: count, render and flush cycles */
#define LB_SCENES_MAX 32u
static uint32_t sc_n[LB_SCENES_MAX];
static uint64_t sc_render[LB_SCENES_MAX], sc_flush[LB_SCENES_MAX];
static uint32_t c0[LB_NCNT];
static bool     rendering, rendered;

static uint32_t inv_px(lv_display_t *disp, uint32_t *n)
{
    uint32_t s = 0;
    *n = 0;
    for (uint32_t i = 0; i < disp->inv_p; i++)
        if (!disp->inv_area_joined[i]) {
            s += (uint32_t) lv_area_get_size(&disp->inv_areas[i]);
            (*n)++;
        }
    return s;
}

static void scene_check(void)
{
    if (done || !scene_timer)
        return;
    if (scene_timer->last_run != scene_run) {
        LB_PROF      = scene;           /* the scene's profile (and its set-up's before the first) */
        scene_run    = scene_timer->last_run;
        scene++;
        scene_frames = 0;
    }
}

static void disp_event_cb(lv_event_t *e)
{
    const uint32_t     t    = LB_CYC_LO;
    lv_display_t      *disp = lv_event_get_target(e);
    switch (lv_event_get_code(e)) {
    case LV_EVENT_REFR_START:
        t_refr   = t;
        rendered = false;
        scene_check();
        break;
    case LV_EVENT_RENDER_START:
        px        = inv_px(disp, &areas);
        flush_in  = flush_out = 0;
        rendering = true;
        for (uint32_t i = 0; i < LB_NCNT; i++)
            c0[i] = LB_CNT(i);
        t_render  = LB_CYC_LO;
        break;
    case LV_EVENT_FLUSH_START:
    case LV_EVENT_FLUSH_WAIT_START:
        t_flush0 = t;
        break;
    case LV_EVENT_FLUSH_FINISH:
    case LV_EVENT_FLUSH_WAIT_FINISH:
        if (rendering) flush_in  += t - t_flush0;
        else           flush_out += t - t_flush0;
        break;
    case LV_EVENT_RENDER_READY: {
        const uint32_t r = t - t_render;
        uint32_t       c[LB_NCNT];
        for (uint32_t i = 0; i < LB_NCNT; i++)
            c[i] = LB_CNT(i) - c0[i];
        rendering = false;
        rendered  = true;
        frames++;
        scene_frames++;
        /* scene tick refr render(-flush) flush px areas busy bk win_rd win_wr gpu_rd gpu_wr v_wait */
        lb_printf("LB F %u %u %u %u %u %u %u %u %u %u %u %u %u %u\n", (unsigned) scene,
                  (unsigned) lv_tick_get(), (unsigned) (t - t_refr), (unsigned) (r - flush_in),
                  (unsigned) flush_in, (unsigned) px, (unsigned) areas, (unsigned) c[0], (unsigned) c[1],
                  (unsigned) c[2], (unsigned) c[3], (unsigned) c[4], (unsigned) c[5], (unsigned) c[6]);
        if (scene_frames > 1u && scene < LB_SCENES_MAX) {
            sc_n[scene]++;
            sc_render[scene] += r - flush_in;
            sc_flush[scene]  += flush_in;
        }
        if (LB_DUMP_FRAME != 0u && scene_frames == LB_DUMP_FRAME)
            LB_DUMP = scene;
        break;
    }
    case LV_EVENT_REFR_READY:
        if (flush_out) {
            lb_printf("LB W %u %u\n", (unsigned) scene, (unsigned) flush_out);
            if (scene_frames > 1u && scene < LB_SCENES_MAX)
                sc_flush[scene] += flush_out;
        }
        break;
    default:
        break;
    }
}

/* x in hundredths, as "<int>.<2 digits>" */
static const char *fix2(char *b, uint32_t x)
{
    lv_snprintf(b, 16, "%u.%02u", (unsigned) (x / 100u), (unsigned) (x % 100u));
    return b;
}

/* LVGL's CSV summary (lv_demo_benchmark_summary_display's format), from the
 * cycle counts at the bench clock: the time per frame in ms, the frame rate
 * it allows (not capped at 1000 / LV_DEF_REFR_PERIOD as LVGL's FPS is), no
 * CPU load (the lockstep clock has no idle time) */
static void summary_csv(const lv_demo_benchmark_summary_t *s)
{
    const uint32_t per10us = LB_CLK_HZ / 100000u;        /* cycles per 10 us */
    uint64_t       t_r = 0, t_f = 0, fps = 0;
    uint32_t       nv = 0;
    char           a[16], b[16], c[16], d[16];
    lb_printf("LB CSV: Benchmark Summary (%d.%d.%d, cycles at %u Hz)\n", LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR,
              LVGL_VERSION_PATCH, (unsigned) LB_CLK_HZ);
    lb_puts("LB CSV: Name, Avg. CPU, Avg. FPS, Avg. time, render time, flush time\n");
    for (uint32_t i = 0; s->scenes[i].create_cb && i < LB_SCENES_MAX; i++) {
        if (!sc_n[i])
            continue;
        const uint32_t r  = (uint32_t) (sc_render[i] / sc_n[i] / per10us);   /* hundredths of ms */
        const uint32_t f  = (uint32_t) (sc_flush[i] / sc_n[i] / per10us);
        const uint32_t fp = (r + f) ? 10000000u / (r + f) : 0u;             /* hundredths of FPS */
        lb_printf("LB CSV: %s, -, %s, %s, %s, %s\n", s->scenes[i].name, fix2(a, fp), fix2(b, r + f), fix2(c, r),
                  fix2(d, f));
        t_r += r;
        t_f += f;
        fps += fp;
        nv++;
    }
    if (nv)
        lb_printf("LB CSV: All scenes avg., -, %s, %s, %s, %s\n", fix2(a, (uint32_t) (fps / nv)),
                  fix2(b, (uint32_t) ((t_r + t_f) / nv)), fix2(c, (uint32_t) (t_r / nv)), fix2(d, (uint32_t) (t_f / nv)));
}

static void end_cb(const lv_demo_benchmark_summary_t *s)
{
    LB_PROF = scene;                    /* the last scene's profile */
    done    = true;
    for (uint32_t i = 0; s->scenes[i].create_cb; i++)
        lb_printf("LB S %u %u %s\n", (unsigned) i, (unsigned) s->scenes[i].scene_time, s->scenes[i].name);
    summary_csv(s);
    lv_mem_monitor_t m;
    lv_mem_monitor(&m);
    lb_printf("LB MEM: pool %u, peak %u, frag %u%%\n", (unsigned) m.total_size, (unsigned) m.max_used,
              (unsigned) m.frag_pct);
    /* add_warnings() of lv_demo_benchmark.c, but its optimisation probe */
    lv_display_t  *disp   = lv_display_get_default();
    const uint32_t screen = (uint32_t) lv_display_get_horizontal_resolution(disp) *
                            (uint32_t) lv_display_get_vertical_resolution(disp) *
                            lv_color_format_get_size(lv_display_get_color_format(disp));
    if (LV_USE_ASSERT_OBJ || LV_USE_CHECK_ARG || LV_USE_ASSERT_MEM_INTEGRITY)
        lb_puts("LB WARN: an LVGL assertion option that slows rendering is on\n");
    if (lv_display_get_draw_buf_size(disp) < screen / 10u)
        lb_puts("LB WARN: draw buffer smaller than 1/10 of the screen\n");
    if (LV_DRAW_LAYER_SIMPLE_BUF_SIZE < screen / 20u)
        lb_puts("LB WARN: LV_DRAW_LAYER_SIMPLE_BUF_SIZE smaller than 1/20 of the screen\n");
    if (LV_USE_LOG && LV_LOG_LEVEL < LV_LOG_LEVEL_WARN)
        lb_puts("LB WARN: LV_LOG_LEVEL below LV_LOG_LEVEL_WARN\n");
#ifdef LB_TICK_REAL
    lv_demo_benchmark_summary_display(s);
#endif
}

/*------------------------------- main ---------------------------------------*/

int main(void)
{
    const uint32_t cfg = LB_CFG, hz = LB_CLK_HZ;
    const uint16_t w = (uint16_t) (cfg & 0xFFFFu), h = (uint16_t) (cfg >> 16);

    lb_printf("LB START: persona %s, %ux%u RGB565, LVGL %d.%d.%d\n", LB_PERSONA, (unsigned) w, (unsigned) h,
              LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR, LVGL_VERSION_PATCH);
    const blns_status_t st = video_init(w, h, hz);
    if (st != BLNS_OK) {
        lb_printf("LB ERROR: Belenos set-up: status %d\n", (int) st);
        lb_exit(1u);
    }

    lv_init();
    lv_log_register_print_cb(log_cb);
    lv_tick_set_cb(tick_cb);

#ifdef LB_FLUSH_CPU
    /* a tenth of the screen (LVGL's recommendation), whole lines */
    static uint32_t draw_buf[((480u * 2u * 28u) > (800u * 2u * 48u) ? 480u * 2u * 28u : 800u * 2u * 48u) / 4u];
    const uint32_t  lines = (h + 9u) / 10u;
    lv_belenos_config_t lcfg = { .dev = &blns, .frame = 0, .width = w, .height = h,
                                 .flush = LV_BELENOS_FLUSH_CPU, .buf = { draw_buf, NULL },
                                 .buf_bytes = (uint32_t) w * 2u * lines };
    if (lcfg.buf_bytes > sizeof(draw_buf)) {
        lb_puts("LB ERROR: draw buffer too small for the resolution\n");
        lb_exit(1u);
    }
#else
    /* the pool: the VRAM after the frame */
    const uint32_t frame_bytes = (uint32_t) w * h * 2u;
    const lv_belenos_config_t lcfg = { .dev = &blns, .frame = 0, .width = w, .height = h,
                                       .flush = LV_BELENOS_FLUSH_DIRECT,
                                       .gpu_draw = BLNS_HAS(&blns, GPU),
                                       .pool = (void *) (blns_vram8(&blns) + frame_bytes),
                                       .pool_bytes = blns.caps.vram_words * 4u - frame_bytes,
                                       .pool_layers = true, .approx = LB_APPROX };
#endif
    lv_display_t *disp = lv_belenos_create(&lcfg);
    if (!disp) {
        lb_puts("LB ERROR: lv_belenos_create failed\n");
        lb_exit(1u);
    }
    lv_display_add_event_cb(disp, disp_event_cb, LV_EVENT_ALL, NULL);
    lb_printf("LB CFG: flush %s, GPU draw unit %s, draw buffer %u bytes, GPU FIFO %u words\n",
              lcfg.flush == LV_BELENOS_FLUSH_CPU ? "CPU" : "DIRECT", lcfg.gpu_draw ? "on" : "off",
              (unsigned) lv_display_get_draw_buf_size(disp), (unsigned) blns.caps.gpu_fifo_depth);
#ifndef LB_FLUSH_CPU
    if (lcfg.gpu_draw)
        lb_printf("LB CFG: draw unit pool %u bytes (layers in it), approx 0x%x (gradients %s, transforms %s), "
                  "blending %s\n",
                  (unsigned) lcfg.pool_bytes, (unsigned) lcfg.approx,
                  (lcfg.approx & LV_BELENOS_APPROX_GRAD) && BLNS_HAS(&blns, GPU_GRAD) ? "on" : "off",
                  !((lcfg.approx & LV_BELENOS_APPROX_TRANSFORM) && BLNS_HAS(&blns, GPU_XY)) ? "off" :
                  !BLNS_HAS(&blns, GPU_BLEND) ? "nearest, RGB565 opaque, antialias off" :
                  BLNS_HAS(&blns, GPU_BILINEAR) ? "bilinear (antialias) and nearest" : "nearest, antialias off",
                  BLNS_HAS(&blns, GPU_BLEND) ? "exact (MIX5)" : "absent");
#endif

    lv_demo_benchmark_set_end_cb(end_cb);
    lv_demo_benchmark();
    scene_timer = lv_timer_get_next(NULL);
    if (!scene_timer || scene_timer->period != 3000u) {
        lb_puts("LB ERROR: the benchmark's scene timer is not at the head of the timer list\n");
        lb_exit(1u);
    }
    scene_run = scene_timer->last_run;

    const uint32_t c_lo = LB_CYC_LO, c_hi = LB_CYC_HI;
    lb_printf("LB RUN: at cycle %u:%u\n", (unsigned) c_hi, (unsigned) c_lo);
    while (!done) {
        lv_timer_handler();
#ifndef LB_TICK_REAL
        lockstep_ms += LV_DEF_REFR_PERIOD;
#endif
    }
#ifdef LB_TICK_REAL
    lv_timer_handler();                 /* the summary screen once */
#endif
    LB_DUMP_PANEL = 0u;
    const uint32_t e_lo = LB_CYC_LO, e_hi = LB_CYC_HI;
    lb_printf("LB END: %u frames, at cycle %u:%u, panel frames %u, GPU recoveries %u\n", (unsigned) frames,
              (unsigned) e_hi, (unsigned) e_lo, (unsigned) LB_PANEL_FRM, (unsigned) gpu_recovers);
    if (gpu_recovers)
        lb_puts("LB ERROR: the GPU was recovered: the CPU redrew what it did not draw\n");
    lb_exit(0u);
    return 0;
}
