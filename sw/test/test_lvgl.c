/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      test_lvgl.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Host test of the LVGL glue (sw/lvgl/lv_belenos.c): real LVGL v9.6 and the
 * driver against the model of test_driver.c (blns_model_impl.h).
 *
 * Every scene is rendered twice: by a plain LVGL display with its buffer in
 * RAM (the reference: LVGL's software renderer, no Belenos code at all), and
 * through lv_belenos.c in one of its ways (DIRECT, GPU flush, CPU flush; with
 * or without the GPU draw unit). The frames must be equal pixel for pixel.
 * The GPU runs in a test draw unit (the "clock", asked after the Belenos unit
 * in every dispatch round): a few words per round, so that batches and flush
 * copies are still in flight when LVGL goes on; the wait hook runs it too.
 * Images in the CPU's memory go to the GPU through the immediate source when
 * the model has it (run_t.imm), else to the software renderer.
 * Faults: a recover requested as from an interrupt handler before any word
 * (blns_gpu_recover_request), at any read of the fence status (GPU_FENCE,
 * GPU_STAT) or just after it, the decoder stopped at any EXEC (cause 5, an
 * error after acceptance), non-blocking mode, a wait that times out.
 * Each test runs in a child process, each render with a time limit: a hang
 * is a failure.
 *
 *   make -C sw/test lvgl   (LVGL v9.6.0 fetched into lvgl_src/ on first use;
 *                           LVGL=<path> for another copy)
 *----------------------------------------------------------------------------*/
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include "blns_model_impl.h"
#include "lvgl.h"
#include "lv_belenos.h"
#include "src/draw/lv_draw_private.h"   /* lv_draw_unit_t: the GPU's clock */
#include "src/draw/sw/lv_draw_sw_grad.h" /* lv_draw_sw_grad_color_calculate: a gradient's bound */
#include "src/draw/lv_draw_image_private.h" /* lv_image_buf_get_transformed_area: a transform's area */

#define H        120
#define W_DEF    160
#define ROWS     20                     /* rows of a GPU flush buffer      */
#define HANG_S   20u                    /* time limit of a render (seconds) */

static unsigned fails, checks;

#define CHECK(c) do {                                                           \
        checks++;                                                               \
        if (!(c)) {                                                             \
            fails++;                                                            \
            printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);               \
        }                                                                       \
    } while (0)

/*---------------------------------------------------------------------------
 * Runs
 *---------------------------------------------------------------------------*/
enum { WAY_REF, WAY_DIRECT, WAY_GPU, WAY_CPU };
enum { SC_UI, SC_IMG, SC_IMG0, SC_ODD, SC_RECTS, SC_TWO, SC_RAM,
       /* the extensions (lv_belenos.h) */
       SC_OPA, SC_TEXT, SC_ROUND, SC_POOL, SC_LAYER, SC_GRAD,
       /* alpha images (RGB565A8, ARGB8888), a rotated or scaled image */
       SC_A8, SC_XFORM };

typedef struct {
    int      way;
    bool     gpu_draw;
    bool     nonblock;
    unsigned fifo_aw;           /* FIFO of 2^fifo_aw words (0: the default)  */
    unsigned step;              /* words decoded per dispatch round (0: all) */
    unsigned tiles;
    int      scene;
    int      img;               /* SC_RAM: the image (IM_*)                  */
    bool     imm;               /* the GPU has the immediate source          */
    int32_t  w;                 /* display width (0: W_DEF)                  */
    int      irq_at;            /* a recover requested before this word (-1: none) */
    int      irq_round;         /* ... or between two calls: at this dispatch round */
    unsigned stop_exec;         /* the decoder stops at this EXEC (0: never) */
    int      timeout_at;        /* from this word, one wait with a full FIFO times out */
    int      rd_at;             /* a recover requested at this read of the fence status (-1: none) */
    bool     rd_next;           /* ... before the next word pushed after that read instead */
    int      ret_at;            /* ... as this fence-status call of the glue returns (-1: none) */
    /* the extensions */
    bool     blend;             /* the GPU has blending                      */
    bool     bilinear;          /* ... bilinear sampling                     */
    int      xf;                /* SC_XFORM: the transform (xfs[])           */
    bool     pool;              /* a VRAM pool (LV_BELENOS_USE_POOL)          */
    bool     layers;            /* ... LVGL's layers in it                   */
    uint32_t pool_bytes;        /* ... its size (0: the rest of the VRAM)     */
    uint8_t  approx;            /* cfg.approx (LV_BELENOS_USE_APPROX)         */
} run_t;

typedef struct {
    unsigned words, execs, imm_execs, aborts, discards, rounds, all_rounds, polls, timeouts, rds, rets;
    unsigned exp_execs, blend_execs, grad_execs, copy_execs, a8_execs, tex_execs, bil_execs;
    bool     created;
} stats_t;

static const run_t RUN0 = { .irq_at = -1, .irq_round = -1, .timeout_at = -1, .rd_at = -1, .ret_at = -1 };

#define FRAME_MAX (W_DEF * H)
static uint16_t ref_px[FRAME_MAX], got_px[FRAME_MAX];

static uint32_t tick_ms;
static uint32_t tick_cb(void) { return tick_ms; }

/* The GPU's clock */
static unsigned clock_step, clock_rounds, clock_all;
static int      clock_irq;
static int32_t clock_dispatch(lv_draw_unit_t *u, lv_layer_t *l)
{
    (void) u;
    clock_rounds += l->all_tasks_added;     /* rounds once LVGL only waits for the tasks */
    if ((int) clock_all++ == clock_irq)
        blns_gpu_recover_request(&dev);     /* "an interrupt" between two GPU calls */
    model_step(clock_step ? clock_step : ~0u);
    return LV_DRAW_UNIT_IDLE;
}

/* Faults */
static bool     timeout_armed;
static unsigned timeouts;
static void irq_recover(void) { blns_gpu_recover_request(&dev); }
static void irq_arm_timeout(void) { timeout_armed = true; }
/* A recover at the rd_at-th read of the fence status (the glue's
 * blns_gpu_fence_status, or the one of a blns_gpu_wait_fence): just after
 * the read, or once the call returned, before the next word is pushed (the
 * unit's next push after its check) */
static int  rd_at;
static bool rd_next;
static void rd_recover(void)
{
    if ((int) m.gpu_rds - 1 != rd_at)
        return;
    if (rd_next) {
        m.irq_at = (int) m.words;
        m.irq    = irq_recover;
    } else {
        blns_gpu_recover_request(&dev);
    }
}
/* The glue's blns_gpu_fence_status (its object is built with
 * -Dblns_gpu_fence_status=lvt_fence_status): a recover requested as the
 * ret_at-th call returns, before the unit's next GPU call; between the two
 * the glue reads no register, so no read hook lands there */
blns_status_t lvt_fence_status(const blns_t *d, uint32_t tag);
static int      ret_at;
static unsigned rets;
blns_status_t lvt_fence_status(const blns_t *d, uint32_t tag)
{
    const blns_status_t st = blns_gpu_fence_status(d, tag);
    if ((int) rets++ == ret_at)
        blns_gpu_recover_request(&dev);
    return st;
}
/* A wait for FIFO room (the driver's count of the free words is the FIFO's:
 * just read, nothing decoded since) times out once */
static bool hook_timeout(void *ctx)
{
    if (timeout_armed && m.qn && dev.fifo_free == m.depth - m.qn) {
        timeout_armed = false;
        timeouts++;
        hook_polls++;
        return true;
    }
    return hook(ctx);
}

/* VRAM: the frame at 0, the GPU flush's buffers after it, an image after
 * them, an RGB565A8 image after it */
static uint32_t frame_bytes(int32_t w) { return ((uint32_t) w * H * 2u + 63u) & ~63u; }
static uint32_t buf_bytes(int32_t w) { return (uint32_t) w * 2u * ROWS; }
static uint32_t img_byte(int32_t w) { return (frame_bytes(w) + 2u * ((buf_bytes(w) + 63u) & ~63u) + 63u) & ~63u; }
static uint32_t a8v_byte(int32_t w) { return img_byte(w) + 4096u; }
static uint32_t pool_byte(int32_t w) { return img_byte(w) + 8192u; }   /* the extensions' pool: after the images */

/*---------------------------------------------------------------------------
 * Scenes
 *---------------------------------------------------------------------------*/
#define IMG_W 64
#define IMG_H 32
static lv_image_dsc_t img_dsc;

static lv_obj_t *box(lv_obj_t *p, int32_t x, int32_t y, int32_t w, int32_t h, uint32_t c, int32_t radius)
{
    lv_obj_t *o = lv_obj_create(p);
    lv_obj_remove_style_all(o);
    lv_obj_set_pos(o, x, y);
    lv_obj_set_size(o, w, h);
    lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(o, lv_color_hex(c), 0);
    lv_obj_set_style_radius(o, radius, 0);
    return o;
}

static void scene_image(int32_t w, bool stride0)
{
    volatile uint16_t *px = (volatile uint16_t *) ((uint8_t *) vram + img_byte(w));
    for (uint32_t y = 0; y < IMG_H; y++)
        for (uint32_t x = 0; x < IMG_W; x++)
            px[y * IMG_W + x] = (uint16_t) (((x / 2u) << 11) | ((y * 2u) << 5) | ((x ^ y) & 0x1Fu));
    memset(&img_dsc, 0, sizeof img_dsc);
    img_dsc.header.magic  = LV_IMAGE_HEADER_MAGIC;
    img_dsc.header.cf     = LV_COLOR_FORMAT_RGB565;
    img_dsc.header.w      = IMG_W;
    img_dsc.header.h      = IMG_H;
    img_dsc.header.stride = stride0 ? 0u : IMG_W * 2u;  /* 0: LVGL takes w x 2 */
    img_dsc.data_size     = IMG_W * IMG_H * 2u;
    img_dsc.data          = (const uint8_t *) px;
    lv_obj_t *img = lv_image_create(lv_screen_active());
    lv_image_set_src(img, &img_dsc);
    lv_obj_set_pos(img, 21, 50);
}

/* An RGB565 image in the CPU's memory (not the VRAM): the immediate source.
 * The second frame redraws a 20 x 6 part of it alone (a box over it
 * hidden): its rows are not packed, the software renderer draws them */
enum { IM_PLAIN, IM_BIG, IM_TOP, IM_CLIP, IM_MISAL, IM_ODD, IM_ODDW };
static const struct { int32_t x, y; uint32_t w, h, off; } ims[] = {
    [IM_PLAIN] = {  21,  50, 32, 16, 0 },   /* 512 pixels: one push                     */
    [IM_BIG]   = {  21,  50, 64, 32, 0 },   /* 2048 pixels: more than IMM_PX_MAX (1024) */
    [IM_TOP]   = {  21,  -4, 32, 16, 0 },   /* off the top: whole rows, one push         */
    [IM_CLIP]  = {  -6,  50, 32, 16, 0 },   /* off the left edge: rows not packed        */
    [IM_MISAL] = {  21,  50, 32, 16, 2 },   /* data half a word off                      */
    [IM_ODD]   = {  21,  50, 17, 15, 0 },   /* 255 pixels: a read past the end           */
    [IM_ODDW]  = {  21,  50, 17, 16, 0 },   /* 272 pixels, stride 34: one push           */
};
static int      img_var;
static uint32_t ram_px[IMG_W * IMG_H / 2u + 1u];    /* sized for the largest, + the offset */
static uint16_t odd_px[17 * 15];                    /* exactly IM_ODD's pixels */
static lv_obj_t *ram_hole;

static void scene_ram(int phase)
{
    const int32_t x = ims[img_var].x, y = ims[img_var].y;
    if (phase == 1) {
        lv_obj_set_hidden(ram_hole, true);
        return;
    }
    const uint32_t w = ims[img_var].w, h = ims[img_var].h;
    uint16_t *px = img_var == IM_ODD ? odd_px : (uint16_t *) (void *) ((uint8_t *) ram_px + ims[img_var].off);
    for (uint32_t j = 0; j < h; j++)
        for (uint32_t i = 0; i < w; i++)
            px[j * w + i] = (uint16_t) (((i / 2u) << 11) | ((j * 2u) << 5) | ((i ^ j) & 0x1Fu));
    memset(&img_dsc, 0, sizeof img_dsc);
    img_dsc.header.magic  = LV_IMAGE_HEADER_MAGIC;
    img_dsc.header.cf     = LV_COLOR_FORMAT_RGB565;
    img_dsc.header.w      = w;
    img_dsc.header.h      = h;
    img_dsc.header.stride = w * 2u;
    img_dsc.data_size     = w * h * 2u;
    img_dsc.data          = (const uint8_t *) px;
    box(lv_screen_active(), 10, 45, 100, 40, 0x808080u, 0);  /* under it (a GPU fill) */
    lv_obj_t *img = lv_image_create(lv_screen_active());
    lv_image_set_src(img, &img_dsc);
    lv_obj_set_pos(img, x, y);
    box(lv_screen_active(), 40, 70, 30, 20, 0x00C0C0u, 0);   /* over it */
    ram_hole = box(lv_screen_active(), 29, y + 8, 20, 6, 0xFF00FFu, 0);
}

/* The extensions' scenes */
static lv_obj_t *opa_box(lv_obj_t *p, int32_t x, int32_t y, int32_t w, int32_t h, uint32_t c, int32_t radius,
                         lv_opa_t opa)
{
    lv_obj_t *o = box(p, x, y, w, h, c, radius);
    lv_obj_set_style_bg_opa(o, opa, 0);
    return o;
}

static lv_obj_t *label(lv_obj_t *p, int32_t x, int32_t y, const char *txt, uint32_t c)
{
    lv_obj_t *l = lv_label_create(p);
    lv_label_set_text(l, txt);
    lv_obj_set_pos(l, x, y);
    lv_obj_set_style_text_color(l, lv_color_hex(c), 0);
    return l;
}

/* An RGB565 image in RAM (not the VRAM): staged in the pool */
static uint16_t      pool_px[40 * 24];
static lv_image_dsc_t pool_dsc, mod_dsc;
static void pool_image_init(void)
{
    for (uint32_t j = 0; j < 24; j++)
        for (uint32_t i = 0; i < 40; i++)
            pool_px[j * 40 + i] = (uint16_t) (((i * 3u / 4u) << 11) | ((j * 2u + i) << 5) | ((i * j) & 0x1Fu));
    memset(&pool_dsc, 0, sizeof pool_dsc);
    pool_dsc.header.magic  = LV_IMAGE_HEADER_MAGIC;
    pool_dsc.header.cf     = LV_COLOR_FORMAT_RGB565;
    pool_dsc.header.w      = 40;
    pool_dsc.header.h      = 24;
    pool_dsc.header.stride = 80;
    pool_dsc.data_size     = sizeof pool_px;
    pool_dsc.data          = (const uint8_t *) pool_px;
    mod_dsc = pool_dsc;                                 /* the same pixels, said to change */
    mod_dsc.header.flags |= LV_IMAGE_FLAGS_MODIFIABLE;
}


/* Alpha images: RGB565A8 in the VRAM (read there) and in RAM (staged in the
 * pool), ARGB8888 in RAM (staged as RGB565A8): every class of alpha (0, the
 * ones LVGL rounds away (1 .. 3), 252 .. 255 around its copy threshold, the
 * rest) and colour */
#define A8_W 30
#define A8_H 20
static uint8_t        a8_ram[A8_W * A8_H * 3];         /* LVGL's layout: colours, then the alphas */
static uint32_t       argb_px[A8_W * A8_H];
static lv_image_dsc_t a8v_dsc, a8r_dsc, argb_dsc;

static uint8_t a8_alpha(uint32_t i, uint32_t j)
{
    static const uint8_t cls[8] = { 0, 255, 252, 253, 3, 128, 254, 1 };
    const uint32_t k = (i * 37u + j * 11u) % 9u;
    return k < 8u ? cls[k] : (uint8_t) (i * j * 13u + 7u);
}

static uint16_t a8_colour(uint32_t i, uint32_t j)
{
    return (uint16_t) (((i + j) & 31u) << 11 | ((i * 2u + j * 3u) & 63u) << 5 | ((i * j) & 31u));
}

static void a8_dsc(lv_image_dsc_t *d, lv_color_format_t cf, const uint8_t *px)
{
    memset(d, 0, sizeof *d);
    d->header.magic  = LV_IMAGE_HEADER_MAGIC;
    d->header.cf     = cf;
    d->header.w      = A8_W;
    d->header.h      = A8_H;
    d->header.stride = A8_W * (cf == LV_COLOR_FORMAT_ARGB8888 ? 4u : 2u);
    d->data_size     = A8_W * A8_H * (cf == LV_COLOR_FORMAT_ARGB8888 ? 4u : 3u);
    d->data          = px;
}

static void alpha_images_init(int32_t w)
{
    uint8_t *v = (uint8_t *) vram + a8v_byte(w);
    for (uint32_t j = 0; j < A8_H; j++)
        for (uint32_t i = 0; i < A8_W; i++) {
            const uint16_t c = a8_colour(i, j), c2 = a8_colour(A8_W - 1u - i, j);
            ((uint16_t *) (void *) v)[j * A8_W + i]   = c;
            v[A8_W * A8_H * 2u + j * A8_W + i]         = a8_alpha(i, j);
            ((uint16_t *) (void *) a8_ram)[j * A8_W + i] = c2;
            a8_ram[A8_W * A8_H * 2u + j * A8_W + i]    = a8_alpha(j, i);
            argb_px[j * A8_W + i] = (uint32_t) a8_alpha(i + 3u, j) << 24 | (i * 9u) << 16 | (j * 13u) << 8 | (i * j + 5u);
        }
    a8_dsc(&a8v_dsc, LV_COLOR_FORMAT_RGB565A8, v);
    a8_dsc(&a8r_dsc, LV_COLOR_FORMAT_RGB565A8, a8_ram);
    a8_dsc(&argb_dsc, LV_COLOR_FORMAT_ARGB8888, (const uint8_t *) argb_px);
}

static lv_obj_t *image(lv_obj_t *p, const lv_image_dsc_t *d, int32_t x, int32_t y, lv_opa_t opa)
{
    lv_obj_t *img = lv_image_create(p);
    lv_image_set_src(img, d);
    lv_obj_set_pos(img, x, y);
    lv_obj_set_style_image_opa(img, opa, 0);
    return img;
}

/* A rotated or scaled image (the transform xfs[xf_var]) alone over the
 * screen's colour: what the bound of a transformed pixel is computed from */
enum { XF_565, XF_A8, XF_ARGB, XF_LAYER };     /* (a layer: an opaque box, A8_W x A8_H) */
/* (LVGL renders a transformed layer as ARGB8888: the CPU's, exact) */
typedef struct {
    int      fmt;
    int32_t  rot, sx, sy;               /* 0.1 degree, scale (256: 1)        */
    int32_t  px, py;                    /* pivot (-1: the image's centre)    */
    bool     aa;
    uint8_t  opa;
    int32_t  x, y;
} xf_t;
static const xf_t xfs[] = {
    { XF_A8,   1,    256, 256, -1, -1, true,  255, 60, 50 },  /* 0.1 degree */
    { XF_A8,   300,  256, 256, -1, -1, true,  255, 60, 50 },
    { XF_ARGB, 450,  256, 256, -1, -1, true,  255, 60, 50 },
    { XF_565,  900,  256, 256, -1, -1, true,  255, 60, 50 },
    { XF_A8,   1800, 256, 256, 0,  0,  true,  255, 70, 60 },  /* about a corner */
    { XF_ARGB, 2700, 300, 300, 30, 20, true,  200, 60, 40 },  /* about the far corner, at 200 */
    { XF_A8,   3590, 256, 256, -10, 40, true, 128, 50, 40 },  /* a pivot outside, at 128 */
    { XF_565,  1234, 384, 384, -1, -1, true,  255, 60, 50 },
    { XF_A8,   0,    128, 128, -1, -1, true,  255, 60, 50 },  /* 0.5: scaled only */
    { XF_ARGB, 0,    1024, 1024, 0, 0, true,  255, 30, 20 },  /* 4: the clamp */
    { XF_565,  0,    600, 200, -1, -1, true,  255, 60, 50 },  /* x and y apart */
    { XF_A8,   0,    450, 330, 5, 3,  true,   200, 40, 30 },
    { XF_565,  0,    200, 640, -1, -1, true,  128, 60, 30 },
    { XF_A8,   625,  180, 230, -1, -1, true,  255, 60, 50 },  /* rotated and scaled */
    { XF_565,  300,  256, 256, -1, -1, false, 255, 60, 50 },  /* nearest */
    { XF_A8,   2200, 300, 300, -1, -1, false, 200, 60, 50 },
    { XF_ARGB, 0,    700, 700, 0, 0,  false,  255, 20, 10 },
    { XF_565,  0,    320, 320, -1, -1, false, 255, 60, 50 },
};
static const xf_t xf_layers[] = {
    { XF_LAYER, 300, 256, 256, 15, 10, true,  255, 60, 50 },
    { XF_LAYER, 0,   384, 300, 0, 0,   true,  255, 40, 30 },
};
#define XF_BOX 0xC04020u                /* the layer's box */
static int       xf_var;
static lv_obj_t *xf_obj;                /* the image                         */
static lv_area_t xf_coords;             /* ... its coordinates as LVGL drew it */

static const xf_t *xf_get(int k)
{
    return (k < (int) (sizeof xfs / sizeof xfs[0])) ? &xfs[k] : &xf_layers[k - (int) (sizeof xfs / sizeof xfs[0])];
}

static const lv_image_dsc_t *xf_dsc(int fmt)
{
    return fmt == XF_565 ? &img_dsc : fmt == XF_A8 ? &a8v_dsc : &argb_dsc;
}

static void scene_xform(int32_t w)
{
    const xf_t *x = xf_get(xf_var);
    scene_image(w, false);                              /* the RGB565 image in the VRAM (img_dsc) */
    lv_obj_delete(lv_obj_get_child(lv_screen_active(), -1));
    alpha_images_init(w);
    if (x->fmt == XF_565) {                             /* 24 x 16 of it */
        img_dsc.header.w = 24;
        img_dsc.header.h = 16;
    }
    if (x->fmt == XF_LAYER) {                           /* an object's transform: its layer */
        lv_obj_t *o = xf_obj = box(lv_screen_active(), x->x, x->y, A8_W, A8_H, XF_BOX, 0);
        lv_obj_set_style_transform_pivot_x(o, x->px, 0);
        lv_obj_set_style_transform_pivot_y(o, x->py, 0);
        lv_obj_set_style_transform_scale_x(o, x->sx, 0);
        lv_obj_set_style_transform_scale_y(o, x->sy, 0);
        lv_obj_set_style_transform_rotation(o, x->rot, 0);
        return;
    }
    lv_obj_t *img = xf_obj = image(lv_screen_active(), xf_dsc(x->fmt), x->x, x->y, x->opa);
    if (x->px >= 0 || x->py >= 0)
        lv_image_set_pivot(img, x->px, x->py);
    lv_image_set_scale_x(img, (uint32_t) x->sx);
    lv_image_set_scale_y(img, (uint32_t) x->sy);
    lv_image_set_rotation(img, x->rot);
    lv_image_set_antialias(img, x->aa);
}

static lv_obj_t *moved;                 /* the object a second frame moves */
static void scene_ext(int sc, int phase, int32_t w)
{
    lv_obj_t *scr = lv_screen_active();
    switch (sc) {
    case SC_OPA:                        /* opacity: fills, borders, images, an overlay */
        if (phase == 0) {
            box(scr, 10, 10, 60, 40, 0x20C040u, 0);
            opa_box(scr, 30, 25, 70, 50, 0xF04010u, 0, LV_OPA_50);
            opa_box(scr, 80, 5, 40, 90, 0x1030F0u, 0, 200);
            lv_obj_t *b = opa_box(scr, 5, 70, 60, 40, 0xE0E0E0u, 10, LV_OPA_70);   /* rounded, translucent */
            lv_obj_set_style_border_width(b, 3, 0);
            lv_obj_set_style_border_color(b, lv_color_hex(0x00FFFFu), 0);
            lv_obj_set_style_border_opa(b, LV_OPA_40, 0);
            scene_image(w, false);                      /* in the VRAM, at 60 % */
            lv_obj_t *img = lv_obj_get_child(scr, -1);
            lv_obj_set_style_image_opa(img, 153, 0);
            lv_obj_set_pos(img, 90, 60);
            moved = opa_box(scr, 0, 0, w, H, 0x808000u, 0, LV_OPA_20);            /* an overlay */
        } else {
            lv_obj_set_pos(moved, 7, 3);
        }
        break;
    case SC_TEXT:                       /* labels: clipped, translucent, underlined, over a box */
        if (phase == 0) {
            box(scr, 50, 40, 70, 30, 0x2050A0u, 0);
            label(scr, 4, 4, "Hello LVGL! 123\nWorld, gpq_", 0xFFFFFFu);
            moved = label(scr, -6, 34, "Clipped left", 0xFFD020u);
            lv_obj_t *l = label(scr, 52, 46, "On a box", 0x10F010u);
            lv_obj_set_style_text_opa(l, LV_OPA_60, 0);
            l = label(scr, 10, 80, "Under", 0xFF8080u);
            lv_obj_set_style_text_decor(l, LV_TEXT_DECOR_UNDERLINE, 0);
            label(scr, 100, H - 8, "Bottom", 0xA0A0FFu);   /* cut by the screen's edge */
        } else {
            lv_label_set_text(moved, "Clipped again!");     /* the glyphs already staged */
            lv_obj_set_pos(moved, -3, 36);
        }
        break;
    case SC_ROUND:                      /* rounded fills and borders, clipped */
        if (phase == 0) {
            for (int i = 0; i < 4; i++) {
                lv_obj_t *o = box(scr, -10 + i * 42, 8 + (i & 1) * 50, 46, 44, 0x30A050u + (uint32_t) i * 0x202000u,
                                  6 + i * 4);
                lv_obj_set_style_border_width(o, 1 + i, 0);
                lv_obj_set_style_border_color(o, lv_color_hex(0xF08020u), 0);
            }
            moved = box(scr, 20, 70, 90, 46, 0xD0D0D0u, LV_RADIUS_CIRCLE);
            box(scr, 120, 100, 30, 30, 0x4040FFu, 15);
        } else {
            lv_obj_set_pos(moved, 26, 73);
        }
        break;
    case SC_POOL:                       /* RGB565 images in RAM: staged, tiled; one said to change */
        if (phase == 0) {
            pool_image_init();
            for (int i = 0; i < 3; i++) {
                lv_obj_t *img = lv_image_create(scr);
                lv_image_set_src(img, &pool_dsc);
                lv_obj_set_pos(img, 5 + i * 45, 5 + i * 7);
            }
            lv_obj_t *t = lv_image_create(scr);         /* tiled over 70 x 50, offset */
            lv_image_set_src(t, &pool_dsc);
            lv_obj_set_size(t, 70, 50);
            lv_image_set_inner_align(t, LV_IMAGE_ALIGN_TILE);
            lv_image_set_offset_x(t, 13);
            lv_image_set_offset_y(t, 5);
            lv_obj_set_pos(t, 30, 50);
            moved = t;
            lv_obj_t *mi = lv_image_create(scr);
            lv_image_set_src(mi, &mod_dsc);
            lv_obj_set_pos(mi, 110, 90);
        } else {
            lv_obj_set_pos(moved, 25, 62);
        }
        break;
    case SC_LAYER:                      /* a translucent layer: its children drawn into it */
        if (phase == 0) {
            lv_obj_t *o = box(scr, 15, 15, 120, 90, 0x3070D0u, 0);
            lv_obj_set_style_opa_layered(o, LV_OPA_60, 0);
            box(o, 10, 10, 40, 30, 0xF0F020u, 0);
            lv_obj_t *r = box(o, 60, 30, 50, 40, 0x20F0A0u, 8);
            lv_obj_set_style_border_width(r, 2, 0);
            label(o, 8, 60, "Layer", 0xFFFFFFu);
            moved = box(scr, 100, 70, 40, 30, 0xFF2020u, 0);
            lv_obj_set_style_opa_layered(moved, 255, 0);
            lv_obj_set_style_transform_scale(moved, 256, 0);
        } else {
            lv_obj_set_pos(moved, 104, 75);
        }
        break;
    case SC_GRAD:                       /* horizontal and vertical gradients */
        if (phase == 0) {
            lv_obj_t *o = box(scr, 5, 5, 100, 50, 0xFF0000u, 0);
            lv_obj_set_style_bg_grad_color(o, lv_color_hex(0x0020FFu), 0);
            lv_obj_set_style_bg_grad_dir(o, LV_GRAD_DIR_HOR, 0);
            o = box(scr, 110, 5, 45, 110, 0x10F010u, 0);
            lv_obj_set_style_bg_grad_color(o, lv_color_hex(0x401080u), 0);
            lv_obj_set_style_bg_grad_dir(o, LV_GRAD_DIR_VER, 0);
            lv_obj_set_style_bg_main_stop(o, 60, 0);
            lv_obj_set_style_bg_grad_stop(o, 200, 0);
            static lv_grad_dsc_t g3;            /* (LV_GRADIENT_MAX_STOPS: 2) */
            lv_grad_init_stops(&g3, (const lv_color_t[]) { lv_color_hex(0xFFFF00u), lv_color_hex(0xFF00FFu) }, NULL,
                               (const uint8_t[]) { 40, 220 }, 2);
            g3.dir = LV_GRAD_DIR_HOR;
            moved = box(scr, -8, 60, 110, 30, 0, 12);
            lv_obj_set_style_bg_grad(moved, &g3, 0);
            box(scr, 5, 95, 100, 20, 0x000000u, 0);
            lv_obj_set_style_bg_grad_color(lv_obj_get_child(scr, -1), lv_color_hex(0xFFFFFFu), 0);
            lv_obj_set_style_bg_grad_dir(lv_obj_get_child(scr, -1), LV_GRAD_DIR_HOR, 0);
            o = box(scr, 60, 30, 40, 24, 0x000000u, 0);     /* a sharp edge: steeper than SET_GRAD_RGB */
            lv_obj_set_style_bg_grad_color(o, lv_color_hex(0xFFFFFFu), 0);
            lv_obj_set_style_bg_grad_dir(o, LV_GRAD_DIR_VER, 0);
            lv_obj_set_style_bg_main_stop(o, 120, 0);
            lv_obj_set_style_bg_grad_stop(o, 130, 0);
        } else {
            lv_obj_set_pos(moved, -4, 63);
        }
        break;
    case SC_A8:                         /* alpha images at 255, 200, 128: clipped, tiled, over a box */
        if (phase == 0) {
            alpha_images_init(w);
            box(scr, 20, 20, 60, 50, 0xC08040u, 0);
            image(scr, &a8v_dsc, -7, 5, 255);
            moved = image(scr, &a8r_dsc, 40, 30, 200);
            image(scr, &argb_dsc, 90, 10, 128);
            image(scr, &argb_dsc, 100, 105, 255);          /* cut by the screen's edge */
            lv_obj_t *t = image(scr, &argb_dsc, 10, 70, 255);
            lv_obj_set_size(t, 70, 45);                     /* tiled, offset */
            lv_image_set_inner_align(t, LV_IMAGE_ALIGN_TILE);
            lv_image_set_offset_x(t, 7);
            lv_image_set_offset_y(t, 3);
            image(scr, &a8v_dsc, 120, 40, 128);
            image(scr, &a8r_dsc, 125, 75, 254);
            image(scr, &argb_dsc, 60, 60, 253);
        } else {
            lv_obj_set_pos(moved, 43, 33);
        }
        break;
    case SC_XFORM:
        if (phase == 0)
            scene_xform(w);
        break;
    default:
        break;
    }
}

/* phase 0: the first frame; phase 1: changes for a second one. 'reveal':
 * the second frame redraws the middle of a rounded card alone (with
 * LV_DRAW_SW_COMPLEX 0 LVGL draws nothing there, though the card covers the
 * area: the pixels are what the buffer held, the same in DIRECT mode only) */
static lv_obj_t *inner;
static bool      reveal;
static void scene(int sc, int phase, int32_t w)
{
    lv_obj_t *scr = lv_screen_active();
    if (phase == 0)
        lv_obj_set_style_bg_color(scr, lv_color_hex(0x203040), 0);
    switch (sc) {
    case SC_UI:
    case SC_TWO:
        if (phase == 0) {
            lv_obj_t *o = lv_obj_create(scr);   /* the default theme's card */
            lv_obj_set_pos(o, 5, 5);
            lv_obj_set_size(o, 90, 60);
            lv_obj_set_style_radius(o, 12, 0);
            lv_obj_set_style_border_width(o, 3, 0);
            lv_obj_set_style_border_color(o, lv_color_hex(0xF08020), 0);
            lv_obj_set_style_bg_color(o, lv_color_hex(0x30A050), 0);
            lv_obj_set_style_shadow_width(o, 0, 0);
            lv_obj_t *b = lv_obj_create(scr);
            lv_obj_set_pos(b, 100, 10);
            lv_obj_set_size(b, 50, 100);
            lv_obj_set_style_radius(b, 0, 0);
            lv_obj_set_style_border_width(b, 5, 0);
            lv_obj_set_style_border_color(b, lv_color_hex(0x1050F0), 0);
            lv_obj_set_style_bg_color(b, lv_color_hex(0xE0E0E0), 0);
            lv_obj_t *p = lv_obj_create(scr);   /* partly off-screen */
            lv_obj_set_pos(p, -20, 80);
            lv_obj_set_size(p, 70, 60);
            lv_obj_set_style_radius(p, 25, 0);
            lv_obj_set_style_border_width(p, 2, 0);
            lv_obj_t *btn = lv_button_create(scr);
            lv_obj_set_pos(btn, 55, 75);
            lv_obj_set_size(btn, 40, 30);
            lv_obj_t *l = lv_label_create(btn);
            lv_label_set_text(l, "Ok");
            lv_obj_center(l);
            for (int i = 0; i < 6; i++)         /* plain rectangles: GPU fills */
                box(scr, 4 + i * 17, 112 - (i & 1) * 3, 9 + i, 5, 0x102030u * (uint32_t) (i + 1), 0);
            inner = box(o, 20, 12, 12, 9, 0xFFFFFFu, 0);
        }
        if (sc == SC_TWO && phase == 1 && reveal)
            lv_obj_set_hidden(inner, true);
        if (sc == SC_TWO && phase == 1) {       /* the second frame: a few areas */
            box(scr, 31, 31, 5, 9, 0xFF0000u, 0);
            box(scr, 120, 60, 13, 7, 0x00FF00u, 0);
            box(scr, 60, 100, 26, 3, 0x0000FFu, 0);
        }
        break;
    case SC_IMG:
    case SC_IMG0:
        if (phase == 0) {
            scene_image(w, sc == SC_IMG0);
            box(scr, 90, 20, 40, 30, 0xC0C000u, 0);
        }
        break;
    case SC_ODD:
        /* small areas of every width mod 8, at odd and even columns */
        if (phase == 1)
            for (int i = 0; i < 8; i++)
                box(scr, 3 + i * 19 + (i & 1), 10 + (i % 3) * 30, 1 + i, 7 + i, 0x00FF00u + (uint32_t) i * 0x1F0000u, 0);
        else
            box(scr, 0, 0, w, H, 0x404040u, 0);
        break;
    case SC_RAM:
        scene_ram(phase);
        break;
    case SC_RECTS:
        if (phase == 0)
            for (int i = 0; i < 12; i++)
                box(scr, (i % 4) * 38 + 2, (i / 4) * 38 + 2, 34, 34, 0x0810F0u * (uint32_t) (i + 1), 0);
        break;
    default:
        scene_ext(sc, phase, w);
        break;
    }
}

static bool two_frames(int sc) { return sc == SC_ODD || sc == SC_TWO || sc == SC_RAM || sc >= SC_OPA; }

/*---------------------------------------------------------------------------
 * Rendering
 *---------------------------------------------------------------------------*/
static void model_setup(const run_t *r)
{
    setup_fifo(BLNS_DIF_DPI, (r->imm ? BLNS_CFG2_IMM_Msk : 0u) | (r->blend ? BLNS_CFG2_BLEND_Msk : 0u) |
                             (r->bilinear ? BLNS_CFG2_BILINEAR_Msk : 0u),
               r->fifo_aw ? r->fifo_aw : MODEL_FIFO_AW);
    if (blns_gpu_enable(&dev, true) != BLNS_OK) {
        printf("blns_gpu_enable failed\n");
        exit(1);
    }
    blns_set_nonblocking(&dev, r->nonblock);
    dev.wait_hook = hook_timeout;
    timeout_armed = false;
    clock_step    = r->step;
    clock_rounds  = 0u;
    clock_all     = 0u;
    clock_irq     = r->irq_round;
    timeouts      = 0u;
    if (r->irq_at >= 0) {
        m.irq_at = r->irq_at;
        m.irq    = irq_recover;
    } else if (r->timeout_at >= 0) {
        m.irq_at = r->timeout_at;
        m.irq    = irq_arm_timeout;
    }
    m.stop_exec = r->stop_exec;
    rd_at       = r->rd_at;
    rd_next     = r->rd_next;
    m.gpu_rd    = (r->rd_at >= 0) ? rd_recover : NULL;
    ret_at      = r->ret_at;
    rets        = 0u;
}

static void lvgl_start(void)
{
    lv_init();
    lv_tick_set_cb(tick_cb);
    lv_draw_unit_t *u = lv_draw_create_unit(sizeof(*u));     /* asked after Belenos' */
    u->name        = "CLOCK";
    u->dispatch_cb = clock_dispatch;
}

/* The reference: LVGL's software renderer into RAM */
static uint8_t  ref_buf[(W_DEF * 2 + 64) * H + 64] __attribute__((aligned(64)));
static int32_t  ref_w;
static void ref_flush(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
    const uint32_t stride = lv_display_get_buf_active(d)->header.stride;
    for (int32_t y = a->y1; y <= a->y2; y++)
        for (int32_t x = a->x1; x <= a->x2; x++)
            ref_px[y * ref_w + x] = ((const uint16_t *) (px + (uint32_t) y * stride))[x];
    lv_display_flush_ready(d);
}

static void render_ref(const run_t *r)
{
    const int32_t w = r->w ? r->w : W_DEF;
    alarm(HANG_S);
    run_t q = RUN0;
    model_setup(&q);                            /* the image in the VRAM */
    lvgl_start();
    ref_w   = w;
    img_var = r->img;
    xf_var  = r->xf;
    reveal  = LV_DRAW_SW_COMPLEX || r->way == WAY_DIRECT;
    memset(ref_px, 0xAA, sizeof ref_px);
    lv_display_t *d = lv_display_create(w, H);
    lv_display_set_color_format(d, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(d, ref_buf, NULL, sizeof ref_buf, LV_DISPLAY_RENDER_MODE_DIRECT);
    lv_display_set_flush_cb(d, ref_flush);
    scene(r->scene, 0, w);
    lv_refr_now(d);
    if (r->scene == SC_XFORM)
        lv_obj_get_coords(xf_obj, &xf_coords);
    if (two_frames(r->scene)) {
        scene(r->scene, 1, w);
        lv_refr_now(d);
    }
    lv_deinit();
}

static lv_belenos_config_t glue_cfg(const run_t *r, int32_t w)
{
    static uint32_t cpu_buf[W_DEF * 24 / 2 + 16] __attribute__((aligned(64)));
    lv_belenos_config_t c = { .dev = &dev, .frame = 0u, .pitch = (uint16_t) w, .width = w, .height = H,
                              .gpu_draw = r->gpu_draw };
    switch (r->way) {
    case WAY_GPU:
        c.flush     = LV_BELENOS_FLUSH_GPU;
        c.buf_bytes = buf_bytes(w);
        c.buf[0]    = (uint8_t *) vram + frame_bytes(w);
        c.buf[1]    = (uint8_t *) vram + frame_bytes(w) + ((buf_bytes(w) + 63u) & ~63u);
        break;
    case WAY_CPU:
        c.flush     = LV_BELENOS_FLUSH_CPU;
        c.buf_bytes = (uint32_t) w * 2u * 24u;
        c.buf[0]    = cpu_buf;
        break;
    default:
        c.flush = LV_BELENOS_FLUSH_DIRECT;
        break;
    }
#if LV_BELENOS_USE_POOL
    if (r->pool) {
        c.pool        = (uint8_t *) vram + pool_byte(w);
        c.pool_bytes  = r->pool_bytes ? r->pool_bytes : MODEL_WORDS * 4u - pool_byte(w);
        c.pool_layers = r->layers;
    }
#endif
#if LV_BELENOS_USE_APPROX
    c.approx = r->approx;
#endif
    return c;
}

static void render(const run_t *r, stats_t *s)
{
    const int32_t w = r->w ? r->w : W_DEF;
    alarm(HANG_S);
    model_setup(r);
    lvgl_start();
    const lv_belenos_config_t c = glue_cfg(r, w);
    lv_display_t *d = lv_belenos_create(&c);
    s->created = d != NULL;
    img_var    = r->img;
    xf_var     = r->xf;
    reveal     = LV_DRAW_SW_COMPLEX || r->way == WAY_DIRECT;
    if (d) {
        if (r->tiles)
            lv_display_set_tile_cnt(d, r->tiles);
        scene(r->scene, 0, w);
        lv_refr_now(d);
        if (two_frames(r->scene)) {
            scene(r->scene, 1, w);
            lv_refr_now(d);
        }
        if (r->approx || r->blend)              /* what a fault left blended twice: drawn again */
            lv_refr_now(d);
    }
    model_run();                                /* what is still queued: drawn */
    for (int32_t i = 0; i < w * H; i++)
        got_px[i] = ((const uint16_t *) vram)[i];
    s->words  = m.words;
    s->execs  = m.execs;
    s->imm_execs = m.imm_execs;
    s->aborts = m.aborts;
    s->discards = m.discards;
    s->rounds = clock_rounds;
    s->all_rounds = clock_all;
    s->timeouts = timeouts;
    s->polls  = hook_polls;
    s->rds    = m.gpu_rds;
    s->rets   = rets;
    s->exp_execs   = m.exp_execs;
    s->blend_execs = m.blend_execs;
    s->grad_execs  = m.grad_execs;
    s->copy_execs  = m.copy_execs;
    s->a8_execs    = m.a8_execs;
    s->tex_execs   = m.tex_execs;
    s->bil_execs   = m.bil_execs;
    lv_deinit();
}

static unsigned diff_px(int32_t w)
{
    unsigned n = 0;
    for (int32_t i = 0; i < w * H; i++)
        n += got_px[i] != ref_px[i];
    return n;
}

/* Render 'r' and compare with the reference already rendered: differing pixels */
static unsigned run_diff(const run_t *r, stats_t *s)
{
    render(r, s);
    return diff_px(r->w ? r->w : W_DEF);
}

static unsigned run_check(const run_t *r, stats_t *s)
{
    render_ref(r);
    const unsigned n = run_diff(r, s);
    if (n)
        printf("  %u pixels differ (way %d, scene %d, gpu_draw %d)\n", n, r->way, r->scene, r->gpu_draw);
    return n;
}

/*---------------------------------------------------------------------------
 * Tests
 *---------------------------------------------------------------------------*/

/* Every way and scene, no fault: pixel for pixel the software renderer */
static void test_plain(void)
{
    static const struct { int way; bool gpu; } ways[] = {
        { WAY_DIRECT, false }, { WAY_DIRECT, true }, { WAY_GPU, false }, { WAY_GPU, true }, { WAY_CPU, false },
    };
    static const int scenes[] = { SC_UI, SC_IMG, SC_TWO, SC_RECTS };
    for (unsigned i = 0; i < sizeof ways / sizeof ways[0]; i++)
        for (unsigned j = 0; j < sizeof scenes / sizeof scenes[0]; j++)
            for (unsigned step = 0; step <= 3; step += 3) {
                run_t   r = RUN0;
                stats_t s;
                r.way = ways[i].way; r.gpu_draw = ways[i].gpu; r.scene = scenes[j]; r.step = step;
                CHECK(run_check(&r, &s) == 0 && s.created);
                CHECK(s.aborts == 0);
            }
    run_t   r = RUN0;                           /* tiles: one layer each */
    stats_t s;
    r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_UI; r.tiles = 4; r.step = 2;
    CHECK(run_check(&r, &s) == 0);
}

/* L1: the decoder stops on an error after it accepted the batch (cause 5):
 * the tasks must not stay QUEUED (lv_refr_now never returned) */
static void test_error_after_acceptance(void)
{
    run_t   r = RUN0;
    stats_t s0, s;
    r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_RECTS; r.step = 4;
    render_ref(&r);
    CHECK(run_diff(&r, &s0) == 0);
    for (unsigned e = s0.execs - 2u; e <= s0.execs; e++) {  /* in the last batch: no call follows */
        r.stop_exec = e;
        CHECK(run_diff(&r, &s) == 0);
        CHECK(s.aborts >= 1);                   /* recovered */
    }
}

/* L2: a recover requested from "an interrupt handler" while a batch is in
 * flight drops it: it must be drawn again, not retired as drawn */
static void test_recover_batch(void)
{
    run_t   r = RUN0;
    stats_t s0, s;
    r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_RECTS; r.step = 2;
    render_ref(&r);
    CHECK(run_diff(&r, &s0) == 0);
    /* a recover once the first batch's fence is pushed, the next one not yet:
     * a word in the middle of the run */
    unsigned bad = 0;
    for (int k = (int) s0.words / 4; k < (int) s0.words; k += (int) s0.words / 4) {
        r.irq_at = k;
        const unsigned n = run_diff(&r, &s);
        if (n)
            printf("  recover before word %d: %u pixels differ\n", k, n);
        bad += n != 0;
    }
    CHECK(bad == 0);
}

/* L3: the GPU flush's copy stops after acceptance: the area is copied again
 * and the GPU recovered (later flushes not lost into a stopped FIFO) */
static void test_flush_error(void)
{
    run_t   r = RUN0;
    stats_t s0, s;
    r.way = WAY_GPU; r.scene = SC_UI; r.step = 3;
    render_ref(&r);
    CHECK(run_diff(&r, &s0) == 0);
    unsigned bad = 0;
    for (unsigned e = 1; e <= s0.execs; e++) {  /* every EXEC is a flush copy here */
        r.stop_exec = e;
        const unsigned n = run_diff(&r, &s);
        if (n)
            printf("  copy %u stopped: %u pixels differ\n", e, n);
        bad += n != 0;
    }
    CHECK(bad == 0);
}

/* L4: an RGB565 image in the VRAM with stride 0 (LVGL: w x 2) */
static void test_image_stride0(void)
{
    run_t   r = RUN0;
    stats_t s;
    r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_IMG0;
    CHECK(run_check(&r, &s) == 0);
    r.way = WAY_GPU;
    CHECK(run_check(&r, &s) == 0);
}

/* L5: the draw buffer's stride is LVGL's (LV_DRAW_BUF_STRIDE_ALIGN): areas
 * of every width, the GPU and the CPU flush; DIRECT on a frame whose pitch
 * is not LVGL's stride of its width */
static void test_stride(void)
{
    static const int ways[] = { WAY_GPU, WAY_CPU, WAY_DIRECT };
    for (unsigned i = 0; i < sizeof ways / sizeof ways[0]; i++)
        for (int gpu = 0; gpu <= (ways[i] != WAY_CPU); gpu++) {
            run_t   r = RUN0;
            stats_t s;
            r.way = ways[i]; r.gpu_draw = gpu; r.scene = SC_ODD;
            CHECK(run_check(&r, &s) == 0 && s.created);
            r.w = 154;                          /* 308 bytes: not a multiple of 8 */
            CHECK(run_check(&r, &s) == 0 && s.created);
        }
}

/* L6: create refuses what LVGL or the hardware would not take, and a deleted
 * display leaves nothing behind (its memory, its draw unit) */
static unsigned others_flushes;
static void other_flush(lv_display_t *d, const lv_area_t *a, uint8_t *px)
{
    (void) a;
    (void) px;
    others_flushes++;
    lv_display_flush_ready(d);
}

static uint32_t mem_used(void)
{
    lv_mem_monitor_t mon;
    lv_mem_monitor(&mon);
    return (uint32_t) (mon.total_size - mon.free_size);
}

/* The glue's lv_display_add_event_cb (its object is built with
 * -Dlv_display_add_event_cb=lvt_display_add_event_cb): the add_fail-th call
 * fails as LVGL's does out of memory (NULL, nothing added) */
lv_event_dsc_t *lvt_display_add_event_cb(lv_display_t *d, lv_event_cb_t cb, lv_event_code_t filter, void *user);
static int      add_fail = -1;
static unsigned adds;
lv_event_dsc_t *lvt_display_add_event_cb(lv_display_t *d, lv_event_cb_t cb, lv_event_code_t filter, void *user)
{
    if ((int) adds++ == add_fail)
        return NULL;
    return lv_display_add_event_cb(d, cb, filter, user);
}

static unsigned displays(void)
{
    unsigned n = 0;
    for (lv_display_t *d = lv_display_get_next(NULL); d; d = lv_display_get_next(d))
        n++;
    return n;
}

static void test_create(void)
{
    run_t r = RUN0;
    r.way = WAY_GPU; r.gpu_draw = true;
    model_setup(&r);
    lvgl_start();
    lv_belenos_config_t c = glue_cfg(&r, W_DEF);
    const uint32_t vbytes = MODEL_WORDS * 4u;

    lv_belenos_config_t b = c;                  /* the buffer's end past the VRAM */
    b.buf[0] = (uint8_t *) vram + vbytes - 1024u;
    b.buf[1] = NULL;
    CHECK(lv_belenos_create(&b) == NULL);
    b = c;                                      /* the frame's end past the VRAM */
    b.frame = (vbytes - 1024u) / 2u;
    CHECK(lv_belenos_create(&b) == NULL);
    b = c;
    b.flush = LV_BELENOS_FLUSH_CPU;
    b.gpu_draw = false;
    b.buf[0] = ref_buf;
    b.buf[1] = NULL;
    b.frame = (vbytes - 1024u) / 2u;
    CHECK(lv_belenos_create(&b) == NULL);
    b = c;                                      /* a buffer LVGL's alignment refuses */
    b.buf[0] = (uint8_t *) c.buf[0] + 4;
    b.buf[1] = NULL;
    CHECK((lv_belenos_create(&b) == NULL) == (LV_DRAW_BUF_ALIGN > 4));
    b = c;                                      /* too small for one line */
    b.buf_bytes = W_DEF * 2u - 2u;
    CHECK(lv_belenos_create(&b) == NULL);
    blns_gpu_enable(&dev, false);               /* the GPU off: no GPU way, no draw unit */
    CHECK(lv_belenos_create(&c) == NULL);
    b = c;
    b.flush = LV_BELENOS_FLUSH_DIRECT;
    CHECK(lv_belenos_create(&b) == NULL);
    blns_gpu_enable(&dev, true);

    /* create, render, delete, twice: the memory comes back */
    /* create, render, delete: what is left is what a plain LVGL display
     * leaves (LVGL keeps some memory per display), the unit taken again */
    uint32_t       grow[2];
    const uint32_t units0 = lv_draw_get_unit_count();
    for (int k = 0; k < 2; k++) {
        uint32_t used[3];
        for (int i = 0; i < 3; i++) {
            lv_display_t *d;
            if (k) {
                d = lv_belenos_create(&c);
                CHECK(d != NULL);
                if (!d)
                    break;
            } else {
                d = lv_display_create(W_DEF, H);
                lv_display_set_color_format(d, LV_COLOR_FORMAT_RGB565);
                lv_display_set_buffers(d, ref_buf, NULL, sizeof ref_buf, LV_DISPLAY_RENDER_MODE_DIRECT);
                lv_display_set_flush_cb(d, other_flush);
            }
            scene(SC_RECTS, 0, W_DEF);
            lv_refr_now(d);
            lv_display_delete(d);
            used[i] = mem_used();
        }
        grow[k] = used[2] - used[1];
    }
    if (grow[1] > grow[0])
        printf("  memory left per display: %u bytes, %u with LVGL alone\n", (unsigned) grow[1], (unsigned) grow[0]);
    CHECK(grow[1] <= grow[0]);
    if (lv_draw_get_unit_count() != units0 + 1u)
        printf("  draw units: %u, %u before\n", (unsigned) lv_draw_get_unit_count(), (unsigned) units0);
    CHECK(lv_draw_get_unit_count() == units0 + 1u);     /* one Belenos unit, taken again */

    /* an event callback LVGL cannot add (out of memory) in every way: NULL
     * or a working display, and nothing left behind once it is deleted (its
     * state, the display, the unit bound to it) */
    static const int fail_ways[] = { WAY_CPU, WAY_DIRECT, WAY_GPU };
    for (unsigned i = 0; i < 3; i++) {
        run_t q = RUN0;
        q.way = fail_ways[i]; q.gpu_draw = q.way != WAY_CPU;
        const lv_belenos_config_t oc = glue_cfg(&q, W_DEF);
        uint32_t used0 = 0, n_adds = 0;
        for (int pass = 0; pass < 2; pass++) {          /* the first: LVGL's first-display state */
            used0 = mem_used();
            adds  = 0u;
            lv_display_t *d = lv_belenos_create(&oc);
            n_adds = adds;
            scene(SC_RECTS, 0, W_DEF);
            lv_refr_now(d);
            lv_display_delete(d);
        }
        const uint32_t kept = mem_used() - used0;       /* what a create, render, delete keeps */
        unsigned nulls = 0, bad = 0;
        for (int k = 0; k < (int) n_adds; k++) {
            const uint32_t before = mem_used();
            const unsigned ndisp  = displays();
            add_fail = k;
            adds     = 0u;
            lv_display_t *d = lv_belenos_create(&oc);
            add_fail = -1;
            nulls += !d;
            if (d) {
                scene(SC_RECTS, 0, W_DEF);
                lv_refr_now(d);
                lv_display_delete(d);
            }
            const uint32_t left = mem_used() - before;
            /* (kept varies by a few of LVGL's allocator headers with the
             * order of the allocations: a leak of the driver, its unit or a
             * display is larger) */
            if (left > kept + 64u || displays() != ndisp) {
                bad++;
                printf("  way %d, event callback %d refused: %s, %u bytes and %u displays left\n", q.way, k,
                       d ? "created" : "NULL", (unsigned) (left - kept), displays() - ndisp);
            }
        }
        lv_display_t *d = lv_belenos_create(&oc);       /* the unit free again */
        CHECK(d != NULL);
        lv_display_delete(d);
        printf("  way %d: %u event callbacks, %u refusals gave NULL, %u left something\n", q.way,
               (unsigned) n_adds, nulls, bad);
        CHECK(n_adds > 0 && bad == 0);
    }
    CHECK(lv_draw_get_unit_count() == units0 + 1u);
    lv_deinit();
}

/* L7: in non-blocking mode a full FIFO (BUSY: nothing sent) is no GPU fault:
 * no recover, nothing redrawn by the CPU; nor a wait that times out before
 * anything was sent */
static void test_busy(void)
{
    static const int ways[] = { WAY_DIRECT, WAY_GPU };
    for (unsigned i = 0; i < 2; i++) {
        run_t   r = RUN0;
        stats_t s;
        r.way = ways[i]; r.gpu_draw = true; r.scene = SC_UI; r.nonblock = true; r.fifo_aw = 3; r.step = 1;
        CHECK(run_check(&r, &s) == 0);
        CHECK(s.aborts == 0);
        r.scene = SC_RECTS;
        CHECK(run_check(&r, &s) == 0);
        CHECK(s.aborts == 0);
    }
    /* a timeout of the first FIFO wait after word k (nothing sent) */
    run_t   r = RUN0;
    stats_t s0, s;
    r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_RECTS; r.fifo_aw = 3; r.step = 1;
    render_ref(&r);
    CHECK(run_diff(&r, &s0) == 0);
    unsigned bad = 0, rec = 0, fired = 0;
    for (int k = 0; k < (int) s0.words; k++) {
        r.timeout_at = k;
        bad += run_diff(&r, &s) != 0;
        rec += s.aborts != 0;
        fired += s.timeouts;
    }
    CHECK(fired > s0.words / 2u);               /* the timeouts happened */
    CHECK(bad == 0);
    CHECK(rec == 0);
    if (rec)
        printf("  %u of %u timeouts recovered\n", rec, s0.words);
}

/* L8: the unit draws for its display only; a deleted display's unit draws no
 * more; with nothing else to do it waits through the wait hook (where an OS
 * sleeps) instead of a dispatch loop; rounded shapes as the software
 * renderer draws them (nothing with LV_DRAW_SW_COMPLEX 0) */
static void test_unit(void)
{
    run_t r = RUN0;
    r.way = WAY_DIRECT; r.gpu_draw = true;
    model_setup(&r);
    lvgl_start();
    lv_belenos_config_t c = glue_cfg(&r, W_DEF);
    lv_display_t *d = lv_belenos_create(&c);
    CHECK(d != NULL);
    /* another display, its buffer in the VRAM too (after the frame) */
    lv_display_t *o = lv_display_create(W_DEF, H);
    lv_display_set_color_format(o, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(o, (uint8_t *) vram + frame_bytes(W_DEF), NULL, buf_bytes(W_DEF),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(o, other_flush);
    lv_display_set_default(o);
    scene(SC_RECTS, 0, W_DEF);
    unsigned w0 = m.words;
    lv_refr_now(o);
    CHECK(others_flushes > 0);
    CHECK(m.words == w0);                       /* not drawn by the GPU */
    lv_display_delete(d);
    lv_obj_invalidate(lv_screen_active());
    w0 = m.words;
    lv_refr_now(o);
    CHECK(m.words == w0);
    lv_deinit();

    /* waiting: a slow GPU (a word per round) behind a deep FIFO, every task the GPU's */
    run_t   q = RUN0;
    stats_t s;
    q.way = WAY_DIRECT; q.gpu_draw = true; q.scene = SC_RECTS; q.step = 1; q.fifo_aw = 7;
    CHECK(run_check(&q, &s) == 0);
    printf("  slow GPU: %u words, %u dispatch rounds waiting, %u hook polls\n", s.words, s.rounds, s.polls);
    CHECK(s.rounds <= 4u);                      /* a few: not one per word */
    CHECK(s.polls > 0);

    /* rounded shapes (with LV_DRAW_SW_COMPLEX 0 the software renderer skips
     * them): the middle of a rounded card redrawn alone */
    q.scene   = SC_TWO;
    q.step    = 0;
    q.fifo_aw = 0;
    CHECK(run_check(&q, &s) == 0);
}

/* L9: images in the CPU's memory with the immediate source: pushed by the
 * GPU where the drawn rows are packed, at most IMM_PX_MAX pixels, the push
 * starts on a word and reads no byte past the image; the software
 * renderer's otherwise; without the immediate source, or for an image in
 * the VRAM, nothing pushed. Pixel for pixel the same in every way, a GPU
 * fill under and over the image */
static void test_imm(void)
{
    /* the immediate EXECs of each image in DIRECT mode (the first frame:
     * the whole image; the second: a part of its rows, not pushed) */
    static const unsigned direct_execs[] = {
        [IM_PLAIN] = 1, [IM_BIG] = 0, [IM_TOP] = 1, [IM_CLIP] = 0, [IM_MISAL] = 0, [IM_ODD] = 0, [IM_ODDW] = 1,
    };
    /* ... with the GPU flush: the image in strips of ROWS rows (y 40-59,
     * 60-79, 80-99), each strip's part pushed on its own (IM_BIG: its
     * first 10 rows and last 2, not the 20 between; IM_ODD: the first 170 pixels, the last 85 would read
     * past the image; IM_TOP: rows 0-11, one strip) */
    static const unsigned gpu_execs[] = {
        [IM_PLAIN] = 2, [IM_BIG] = 2, [IM_TOP] = 1, [IM_CLIP] = 0, [IM_MISAL] = 0, [IM_ODD] = 1, [IM_ODDW] = 2,
    };
    static const struct { int way; bool gpu; } ways[] = {
        { WAY_DIRECT, true }, { WAY_GPU, true }, { WAY_DIRECT, false }, { WAY_CPU, false },
    };
    for (unsigned i = 0; i < sizeof ways / sizeof ways[0]; i++)
        for (int im = IM_PLAIN; im <= IM_ODDW; im++)
            for (unsigned step = 0; step <= 3; step += 3) {
                run_t   r = RUN0;
                stats_t s;
                r.way = ways[i].way; r.gpu_draw = ways[i].gpu; r.scene = SC_RAM; r.img = im; r.step = step;
                r.imm = true;
                CHECK(run_check(&r, &s) == 0 && s.created);
                CHECK(s.aborts == 0);
                const unsigned want = !ways[i].gpu ? 0u : ways[i].way == WAY_DIRECT ? direct_execs[im] : gpu_execs[im];
                if (s.imm_execs != want)
                    printf("  way %d, image %d: %u immediate EXECs, %u expected\n", r.way, im, s.imm_execs, want);
                CHECK(s.imm_execs == want);
                r.imm = false;                  /* no immediate source: the software renderer's */
                CHECK(run_check(&r, &s) == 0 && s.imm_execs == 0);
            }
    run_t   r = RUN0;                           /* in the VRAM: a copy, not pushed */
    stats_t s;
    r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_IMG; r.imm = true;
    CHECK(run_check(&r, &s) == 0 && s.imm_execs == 0);
    r.way = WAY_DIRECT; r.scene = SC_RAM; r.tiles = 4; r.step = 2;     /* tiles: one layer each */
    CHECK(run_check(&r, &s) == 0 && s.imm_execs > 0);
}

/* L10: faults with immediate blits in flight: a recover requested before
 * every word (in the data too) and at every dispatch round, the decoder
 * stopped at every EXEC, a timeout of every FIFO wait (in the data: the
 * blit discarded, the stream in step, the task sent again), non-blocking
 * mode with a FIFO shorter than the data (no fault) */
static void test_imm_faults(void)
{
    static const struct { int way; int img; unsigned step; } sw[] = {
        { WAY_DIRECT, IM_PLAIN, 2 }, { WAY_GPU, IM_PLAIN, 5 }, { WAY_DIRECT, IM_ODDW, 3 },
    };
    for (unsigned i = 0; i < sizeof sw / sizeof sw[0]; i++) {
        run_t   r = RUN0;
        stats_t s0, s;
        r.way = sw[i].way; r.gpu_draw = true; r.scene = SC_RAM; r.img = sw[i].img; r.step = sw[i].step;
        r.imm = true;
        render_ref(&r);
        CHECK(run_diff(&r, &s0) == 0 && s0.imm_execs > 0);
        unsigned bad_irq = 0, bad_stop = 0, bad_to = 0, fired = 0, rec = 0, disc = 0;
        for (int k = 0; k <= (int) s0.words; k++) {
            r.irq_at = k;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_irq < 3)
                printf("  way %d image %d: recover before word %d: %u pixels differ\n", r.way, r.img, k, n);
            bad_irq += n != 0;
        }
        r.irq_at = -1;
        for (int k = 0; k <= (int) s0.all_rounds; k++) {
            r.irq_round = k;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_irq < 3)
                printf("  way %d image %d: recover at round %d: %u pixels differ\n", r.way, r.img, k, n);
            bad_irq += n != 0;
        }
        r.irq_round = -1;
        for (unsigned e = 1; e <= s0.execs; e++) {
            r.stop_exec = e;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_stop < 3)
                printf("  way %d image %d: stop at EXEC %u: %u pixels differ\n", r.way, r.img, e, n);
            bad_stop += n != 0;
        }
        r.stop_exec = 0;
        r.fifo_aw   = 3;
        render_ref(&r);
        CHECK(run_diff(&r, &s0) == 0);
        for (int k = 0; k < (int) s0.words; k++) {
            r.timeout_at = k;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_to < 3)
                printf("  way %d image %d: timeout after word %d: %u pixels differ\n", r.way, r.img, k, n);
            bad_to += n != 0;
            fired += s.timeouts;
            rec += s.aborts != 0;
            disc += s.discards != 0;
        }
        printf("  way %d image %d: %u words, %u rounds, %u EXECs (%u immediate); %u / %u bad; "
               "%u timeouts, %u discarded, %u recovered, %u bad\n", r.way, r.img, s0.words, s0.all_rounds,
               s0.execs, s0.imm_execs, bad_irq, bad_stop, fired, disc, rec, bad_to);
        CHECK(bad_irq == 0 && bad_stop == 0 && bad_to == 0);
        CHECK(fired > s0.words / 2u && disc > 0);   /* timeouts in the data: discarded */
        r.timeout_at = -1;
        r.nonblock   = true;                    /* BUSY before a push: no fault */
        r.step       = 1;
        CHECK(run_check(&r, &s) == 0 && s.aborts == 0 && s.imm_execs > 0);
    }
}

/* Sweeps: a recover requested before every word and at every dispatch
 * round (between two calls: a batch dropped, the next one pushed after the
 * recover and drawn), the decoder stopped at every EXEC, in the DIRECT and
 * GPU ways with the draw unit */
static void test_sweep(void)
{
    static const struct { int way; int scene; unsigned step; } sw[] = {
        { WAY_DIRECT, SC_UI, 2 }, { WAY_GPU, SC_UI, 2 }, { WAY_GPU, SC_TWO, 5 }, { WAY_DIRECT, SC_TWO, 1 },
    };
    for (unsigned i = 0; i < sizeof sw / sizeof sw[0]; i++) {
        run_t   r = RUN0;
        stats_t s0, s;
        r.way = sw[i].way; r.gpu_draw = true; r.scene = sw[i].scene; r.step = sw[i].step;
        render_ref(&r);
        CHECK(run_diff(&r, &s0) == 0);
        unsigned bad_irq = 0, bad_stop = 0;
        for (int k = 0; k <= (int) s0.words; k++) {
            r.irq_at = k;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_irq < 3)
                printf("  way %d scene %d: recover before word %d: %u pixels differ\n", r.way, r.scene, k, n);
            bad_irq += n != 0;
        }
        r.irq_at = -1;
        for (int k = 0; k <= (int) s0.all_rounds; k++) {
            r.irq_round = k;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_irq < 3)
                printf("  way %d scene %d: recover at round %d: %u pixels differ\n", r.way, r.scene, k, n);
            bad_irq += n != 0;
        }
        r.irq_round = -1;
        for (unsigned e = 1; e <= s0.execs; e++) {
            r.stop_exec = e;
            const unsigned n = run_diff(&r, &s);
            if (n && bad_stop < 3)
                printf("  way %d scene %d: stop at EXEC %u: %u pixels differ\n", r.way, r.scene, e, n);
            bad_stop += n != 0;
        }
        printf("  way %d scene %d: %u words, %u rounds, %u EXECs; %u / %u bad\n", r.way, r.scene, s0.words,
               s0.all_rounds, s0.execs, bad_irq, bad_stop);
        CHECK(bad_irq == 0 && bad_stop == 0);
    }
}

/* A recover requested at every read of the fence status (GPU_FENCE,
 * GPU_STAT), before the first word pushed after it, and as the glue's
 * blns_gpu_fence_status returns (before the unit's next push): the batches
 * still in flight are then dropped (the older one too when two are) and must
 * be drawn again, not retired on the newer fence */
static void test_fence_read(void)
{
    static const struct { int way; int scene; unsigned step; unsigned fifo_aw; } sw[] = {
        { WAY_DIRECT, SC_RECTS, 2, 0 }, { WAY_DIRECT, SC_UI, 2, 0 }, { WAY_GPU, SC_UI, 2, 0 },
        { WAY_GPU, SC_TWO, 5, 0 }, { WAY_DIRECT, SC_TWO, 1, 0 }, { WAY_DIRECT, SC_RECTS, 1, 7 },
        { WAY_DIRECT, SC_RAM, 2, 0 }, { WAY_GPU, SC_RAM, 5, 0 },   /* immediate blits */
    };
    static const char *const mode[3] = { "at a read", "after a read", "at a return" };
    for (unsigned i = 0; i < sizeof sw / sizeof sw[0]; i++) {
        run_t   r = RUN0;
        stats_t s0, s;
        r.way = sw[i].way; r.gpu_draw = true; r.scene = sw[i].scene; r.step = sw[i].step;
        r.fifo_aw = sw[i].fifo_aw;
        r.imm     = sw[i].scene == SC_RAM;
        render_ref(&r);
        CHECK(run_diff(&r, &s0) == 0);
        CHECK(s0.rds > 0 && s0.rets > 0);       /* the glue reads the fence status */
        unsigned bad[3] = { 0 }, fired[3] = { 0 };
        for (int md = 0; md < 3; md++) {
            const int n_at = (md < 2) ? (int) s0.rds : (int) s0.rets;
            for (int k = 0; k < n_at; k++) {
                r.rd_at   = (md < 2) ? k : -1;
                r.rd_next = md == 1;
                r.ret_at  = (md == 2) ? k : -1;
                const unsigned n = run_diff(&r, &s);
                if (n && bad[md] < 3)
                    printf("  way %d scene %d: recover %s %d: %u pixels differ\n", r.way, r.scene, mode[md], k, n);
                bad[md]   += n != 0;
                fired[md] += s.aborts != 0;
            }
            CHECK(fired[md] > 0);
        }
        printf("  way %d scene %d: %u reads, %u calls; recovered / bad: %u / %u, %u / %u, %u / %u\n", r.way,
               r.scene, s0.rds, s0.rets, fired[0], bad[0], fired[1], bad[1], fired[2], bad[2]);
        CHECK(bad[0] == 0 && bad[1] == 0 && bad[2] == 0);
    }
}

#if LV_BELENOS_USE_POOL || LV_BELENOS_USE_APPROX || LV_BELENOS_USE_CORNERS
/*---------------------------------------------------------------------------
 * The extensions (lv_belenos.h): the exact ones pixel for pixel, the
 * approximate ones (cfg.approx) within the bound per RGB565 field
 *---------------------------------------------------------------------------*/

/* Pixels beyond the tolerance of a field (R, G, B), and the largest
 * difference of each field */
typedef struct {
    unsigned n;
    int      max[3];
} tol_t;

static tol_t diff_tol(int32_t w, const int tol[3])
{
    tol_t t = { 0, { 0, 0, 0 } };
    for (int32_t i = 0; i < w * H; i++) {
        const int f[3][2] = { { got_px[i] >> 11, ref_px[i] >> 11 }, { (got_px[i] >> 5) & 0x3F, (ref_px[i] >> 5) & 0x3F },
                              { got_px[i] & 0x1F, ref_px[i] & 0x1F } };
        bool out = false;
        for (int c = 0; c < 3; c++) {
            const int d = abs(f[c][0] - f[c][1]);
            if (d > t.max[c])
                t.max[c] = d;
            out |= d > tol[c];
        }
        t.n += out;
    }
    return t;
}

/* The bound of the scenes: two blends over each other at most (a field of
 * a blended fill or blit within 1 of LVGL's, a glyph's within 1, 2, 1) */
static const int TOL0[3] = { 0, 0, 0 };
static const int TOL2[3] = { 2, 3, 2 };

static tol_t ext_run(const run_t *r, stats_t *s, const int tol[3])
{
    render_ref(r);
    render(r, s);
    return diff_tol(r->w ? r->w : W_DEF, tol);
}

/* X1: the exact extensions (rounded corners split, the pool: staged and
 * tiled images, alpha images, glyphs, layers in the VRAM; blending with
 * MIX5), and the approximate ones off: pixel for pixel the software
 * renderer; without blending in the GPU too */
static void test_ext_exact(void)
{
    static const int scenes[] = { SC_UI, SC_TWO, SC_ROUND, SC_POOL, SC_LAYER, SC_RAM, SC_IMG, SC_OPA, SC_TEXT, SC_GRAD,
                                  SC_A8 };
    static const int ways[]   = { WAY_DIRECT, WAY_GPU };
    for (unsigned i = 0; i < sizeof ways / sizeof ways[0]; i++)
        for (unsigned j = 0; j < sizeof scenes / sizeof scenes[0]; j++)
            for (int pool = 0; pool <= 2; pool++)
                for (unsigned step = 0; step <= 3; step += 3)
                for (int blend = 1; blend >= (step ? 1 : 0); blend--) {
                    run_t   r = RUN0;
                    stats_t s;
                    r.way = ways[i]; r.gpu_draw = true; r.scene = scenes[j]; r.step = step;
                    r.pool = pool > 0; r.layers = pool == 2; r.blend = blend != 0; r.imm = true;
                    const tol_t t = ext_run(&r, &s, TOL0);
                    if (t.n)
                        printf("  way %d scene %d pool %d step %u blend %d: %u pixels differ (max %d %d %d)\n", r.way,
                               r.scene, pool, step, blend, t.n, t.max[0], t.max[1], t.max[2]);
                    CHECK(t.n == 0 && s.created && s.aborts == 0 && s.grad_execs == 0);
                    if (!blend)                 /* the opacities are the software renderer's */
                        CHECK(s.blend_execs == 0 && s.exp_execs == 0 && s.a8_execs == 0);
                    if (blend && scenes[j] == SC_OPA)
                        CHECK(s.blend_execs > 0);
                    if (blend && scenes[j] == SC_TEXT)
                        CHECK(pool ? s.exp_execs > 10u : s.exp_execs == 0);   /* glyphs: from the pool */
                    if (blend && scenes[j] == SC_LAYER && pool == 2)
                        CHECK(s.blend_execs > 0);       /* the layer blended by the GPU */
                    if (blend && scenes[j] == SC_A8)    /* in the VRAM: always; staged: with the pool */
                        CHECK(s.a8_execs >= (pool ? 8u : 2u));
                    if (scenes[j] == SC_POOL && pool) { /* staged: copies; the one said to change pushed */
                        if (s.copy_execs < 8u || s.imm_execs > 2u)
                            printf("  way %d pool %d step %u: %u copies, %u pushed\n", r.way, pool, step,
                                   s.copy_execs, s.imm_execs);
                        CHECK(s.copy_execs >= 8u && s.imm_execs <= 2u);
                    }
                }
}

#if LV_BELENOS_USE_APPROX
/* X2: the approximate gradients: within the bound, the GPU draws them (its
 * EXECs counted); the other scenes stay exact with cfg.approx set */
static void test_ext_approx(void)
{
    static const int scenes[] = { SC_OPA, SC_TEXT, SC_LAYER, SC_GRAD, SC_UI, SC_POOL, SC_ROUND, SC_A8 };
    static const int ways[]   = { WAY_DIRECT, WAY_GPU };
    int worst[3] = { 0, 0, 0 }, per[SC_XFORM + 1][3];
    memset(per, 0, sizeof per);
    for (unsigned i = 0; i < sizeof ways / sizeof ways[0]; i++)
        for (unsigned j = 0; j < sizeof scenes / sizeof scenes[0]; j++)
            for (int pool = 0; pool <= 2; pool++)
                for (unsigned step = 0; step <= 3; step += 3) {
                    run_t   r = RUN0;
                    stats_t s;
                    r.way = ways[i]; r.gpu_draw = true; r.scene = scenes[j]; r.step = step;
                    r.pool = pool > 0; r.layers = pool == 2; r.blend = true; r.imm = true;
                    r.approx = LV_BELENOS_APPROX_GRAD | LV_BELENOS_APPROX_TRANSFORM;
                    const tol_t t = ext_run(&r, &s, scenes[j] == SC_GRAD ? TOL2 : TOL0);
                    if (t.n)
                        printf("  way %d scene %d pool %d step %u: %u pixels beyond (max %d %d %d)\n", r.way, r.scene,
                               pool, step, t.n, t.max[0], t.max[1], t.max[2]);
                    CHECK(t.n == 0 && s.created && s.aborts == 0);
                    for (int c = 0; c < 3; c++) {
                        worst[c] = LV_MAX(worst[c], t.max[c]);
                        per[scenes[j]][c] = LV_MAX(per[scenes[j]][c], t.max[c]);
                    }
                    if (scenes[j] == SC_GRAD)       /* (LV_DRAW_SW_COMPLEX 0: LVGL draws no gradient) */
                        CHECK((s.grad_execs > 0) == (LV_DRAW_SW_COMPLEX != 0));
                }
    for (unsigned j = 0; j < sizeof scenes / sizeof scenes[0]; j++)
        printf("  scene %d: largest difference per field %d %d %d\n", scenes[j], per[scenes[j]][0], per[scenes[j]][1],
               per[scenes[j]][2]);
    printf("  largest difference per field: %d %d %d\n", worst[0], worst[1], worst[2]);
}

/* X7: rotated and scaled images (cfg.approx TRANSFORM) within the bound of
 * the specification (5.3), pixel by pixel: the GPU's pixel is LVGL's, or
 *   antialias: within the kernel bound (3 / 5 / 3 per field: LVGL's kernels
 *     and the GPU's at the same sample point) plus the position term, 2 / 32
 *     of the contrast of the texels around the sample (composited over the
 *     background as LVGL blends them): the GPU's walk and LVGL's sample point
 *     are less than 1/32 texel apart, a step of the 5-bit weights; near the
 *     image's edge (the sample within 1/32 texel of it, where LVGL may skip a
 *     pixel the GPU draws faintly, or the other way) the whole contrast;
 *   nearest: the texel (blended as LVGL) at a point within 1/32 texel of
 *     LVGL's sample point.
 * LVGL's sample point is computed here from lv_draw_sw_transform's set-up
 * (written again, not the glue's) */
typedef struct {
    unsigned n, beyond, edge;           /* pixels differing, beyond the bound, at an edge */
    int      max[3];                    /* the largest difference per field */
} xchk_t;

static void xf_image(const xf_t *x, int32_t *w, int32_t *h)
{
    *w = x->fmt == XF_565 ? 24 : A8_W;
    *h = x->fmt == XF_565 ? 16 : A8_H;
}

/* Texel (i, j) as the GPU reads it: RGB565 (ARGB8888: truncated) and alpha */
static uint16_t xf_texel(const xf_t *x, int32_t i, int32_t j, int *a)
{
    const uint8_t *v = (const uint8_t *) vram;
    if (x->fmt == XF_LAYER) {
        *a = 255;
        return lv_color_to_u16(lv_color_hex(XF_BOX));
    }
    if (x->fmt == XF_565) {
        *a = 255;
        return ((const uint16_t *) (const void *) (v + img_byte(W_DEF)))[j * IMG_W + i];
    }
    if (x->fmt == XF_A8) {
        *a = v[a8v_byte(W_DEF) + A8_W * A8_H * 2u + (uint32_t) (j * A8_W + i)];
        return ((const uint16_t *) (const void *) (v + a8v_byte(W_DEF)))[j * A8_W + i];
    }
    const uint32_t p = argb_px[j * A8_W + i];
    *a = (int) (p >> 24);
    return (uint16_t) (((p >> 8) & 0xF800u) | ((p >> 5) & 0x07E0u) | ((p >> 3) & 0x1Fu));
}

/* LVGL's blend of a texel over the background (lv_draw_sw_blend_to_rgb565) */
static uint16_t xf_comp(uint16_t c, int a, int opa, uint16_t bg)
{
    const int al = opa >= LV_OPA_MAX ? a : LV_OPA_MIX2(a, opa);
    if (al == 0)
        return bg;
    return (opa >= LV_OPA_MAX && a >= LV_OPA_MAX) ? c : lv_color_16_16_mix(c, bg, (uint8_t) al);
}

/* The pivot: lv_image's default, the middle of its first and last pixels */
static int32_t xf_pivot(const xf_t *x, int32_t size, bool horiz)
{
    if (x->px >= 0 || x->py >= 0)
        return horiz ? x->px : x->py;
    return (size - 1) * 50 / 100;
}

/* The area LVGL draws: the transformed area of the image (screen coordinates) */
static lv_area_t xf_area(const xf_t *x)
{
    int32_t    w, h;
    lv_area_t  a;
    xf_image(x, &w, &h);
    const lv_point_t pv = { xf_pivot(x, w, true), xf_pivot(x, h, false) };
    lv_image_buf_get_transformed_area(&a, w, h, x->rot, (uint16_t) x->sx, (uint16_t) x->sy, &pv);
    lv_area_move(&a, xf_coords.x1, xf_coords.y1);
    return a;
}

static uint16_t xf_at(const xf_t *x, int32_t i, int32_t j, uint16_t bg)
{
    int32_t w, h;
    int     a;
    xf_image(x, &w, &h);
    if (i < 0 || i >= w || j < 0 || j >= h)
        return bg;
    const uint16_t c = xf_texel(x, i, j, &a);
    return xf_comp(c, a, x->opa, bg);
}

/* LVGL's sample point of image-local pixel (xi, yi), 1/256 texel (+ 0x80) */
static void xf_pos(const xf_t *x, int32_t xi, int32_t yi, int32_t *xs, int32_t *ys)
{
    int32_t w, h;
    xf_image(x, &w, &h);
    const int32_t px = xf_pivot(x, w, true), py = xf_pivot(x, h, false);
    const int32_t angle = -x->rot, al = angle / 10, ah = al + 1, ar = angle - al * 10;
    int32_t       sn = (lv_trigo_sin((int16_t) al) * (10 - ar) + lv_trigo_sin((int16_t) ah) * ar) / 10;
    int32_t       cs = (lv_trigo_sin((int16_t) (al + 90)) * (10 - ar) + lv_trigo_sin((int16_t) (ah + 90)) * ar) / 10;
    sn >>= LV_TRIGO_SHIFT - 10;
    cs >>= LV_TRIGO_SHIFT - 10;
    if (angle == 0) {
        sn = 0;
        cs = 1024;
    }
    const int32_t sxx = (int32_t) (((int64_t) cs * 16384) / x->sx), sxy = (int32_t) ((-(int64_t) sn * 16384) / x->sx);
    const int32_t syx = (int32_t) (((int64_t) sn * 16384) / x->sy), syy = (int32_t) (((int64_t) cs * 16384) / x->sy);
    const int64_t xin0 = -(int64_t) px, yin0 = -(int64_t) py;
    const int32_t x0 = (int32_t) (((cs * xin0 - sn * yin0) * 64) / x->sx) + px * 256 + 0x80;
    const int32_t y0 = (int32_t) (((sn * xin0 + cs * yin0) * 64) / x->sy) + py * 256 + 0x80;
    int32_t       ysr = y0 + (int32_t) (((int64_t) syy * yi) >> 8);
    if (x->rot == 0 && ysr > (h - 1) * 256 + 0x80)
        ysr = (h - 1) * 256 + 0x80;
    *xs = x0 + (int32_t) (((int64_t) sxy * yi) >> 8) + ((sxx * xi) >> 8);
    *ys = ysr + ((syx * xi) >> 8);
    if (x->rot == 0 && *xs > (w - 1) * 256 + 0x80)
        *xs = (w - 1) * 256 + 0x80;
}

/* LVGL's sample point and the GPU's are less than XF_E / 256 = 1/32 texel
 * apart: the GPU's start rounded to 1/128 and its steps to 1/4096 over a
 * 64-pixel tile (0.024), LVGL's two floors of 1/256 (0.008) */
#define XF_E 8

static int fld(uint16_t c, int f) { return f == 0 ? c >> 11 : f == 1 ? (c >> 5) & 63 : c & 31; }

static xchk_t xform_check(const xf_t *x)
{
    static const int kb[3] = { 3, 5, 3 };
    const uint16_t   bg = lv_color_to_u16(lv_color_hex(0x203040));
    int32_t          w, h;
    xchk_t           c = { 0, 0, 0, { 0, 0, 0 } };
    const lv_area_t  ar = xf_area(x);
    xf_image(x, &w, &h);
    for (int32_t Y = 0; Y < H; Y++)
        for (int32_t X = 0; X < W_DEF; X++) {
            const uint16_t g = got_px[Y * W_DEF + X], l = ref_px[Y * W_DEF + X];
            if (X < ar.x1 || X > ar.x2 || Y < ar.y1 || Y > ar.y2) {     /* not drawn */
                c.n += g != l;
                c.beyond += g != l;
                continue;
            }
            if (g == l)
                continue;
            c.n++;
            int d[3];
            for (int f = 0; f < 3; f++) {
                d[f]     = abs(fld(g, f) - fld(l, f));
                c.max[f] = LV_MAX(c.max[f], d[f]);
            }
            int32_t xs, ys;
            xf_pos(x, X - xf_coords.x1, Y - xf_coords.y1, &xs, &ys);
            if (!x->aa) {                       /* a texel within 1/32 of LVGL's point */
                bool ok = false;
                for (int dy = -XF_E; dy <= XF_E && !ok; dy += XF_E)
                    for (int dx = -XF_E; dx <= XF_E && !ok; dx += XF_E)
                        ok = xf_at(x, (xs + dx) >> 8, (ys + dy) >> 8, bg) == g;
                c.beyond += !ok;
                continue;
            }
            /* the contrast around the sample, composited */
            int lo[3] = { 99, 99, 99 }, hi[3] = { -1, -1, -1 };
            const int32_t i0 = ((xs - 128) >> 8) - 1, j0 = ((ys - 128) >> 8) - 1;
            for (int32_t j = j0; j <= j0 + 3; j++)
                for (int32_t i = i0; i <= i0 + 3; i++) {
                    const uint16_t v = xf_at(x, i, j, bg);
                    for (int f = 0; f < 3; f++) {
                        lo[f] = LV_MIN(lo[f], fld(v, f));
                        hi[f] = LV_MAX(hi[f], fld(v, f));
                    }
                }
            const bool in = (xs >> 8) >= 0 && (xs >> 8) < w && (ys >> 8) >= 0 && (ys >> 8) < h;
            bool       edge = false;
            for (int k = -XF_E; k <= XF_E; k += 2 * XF_E)
                edge |= (((xs + k) >> 8) >= 0 && ((xs + k) >> 8) < w && (ys >> 8) >= 0 && (ys >> 8) < h) != in ||
                        ((xs >> 8) >= 0 && (xs >> 8) < w && ((ys + k) >> 8) >= 0 && ((ys + k) >> 8) < h) != in;
            c.edge += edge;
            bool out = false;
            for (int f = 0; f < 3; f++)
                out |= d[f] > kb[f] + (edge ? hi[f] - lo[f] : (2 * (hi[f] - lo[f]) + 31) / 32);
            c.beyond += out;
        }
    return c;
}

static void test_xform(void)
{
    int      kmax[2][3] = { { 0, 0, 0 }, { 0, 0, 0 } };
    unsigned px[2] = { 0, 0 }, diff[2] = { 0, 0 };
    for (unsigned i = 0; i < sizeof xfs / sizeof xfs[0]; i++)
        for (int way = WAY_DIRECT; way <= WAY_GPU; way++)
            for (unsigned step = 0; step <= (way == WAY_DIRECT ? 3u : 0u); step += 3) {
                run_t   r = RUN0;
                stats_t s;
                r.way = way; r.gpu_draw = true; r.scene = SC_XFORM; r.xf = (int) i; r.step = step;
                r.blend = true; r.bilinear = true; r.pool = true; r.imm = true;
                r.approx = LV_BELENOS_APPROX_TRANSFORM;
                render_ref(&r);
                render(&r, &s);
                const xchk_t c  = xform_check(&xfs[i]);
                const int    aa = xfs[i].aa;
                const bool good = c.beyond == 0 && s.created && s.aborts == 0 && s.tex_execs > 0 && (s.bil_execs > 0) == aa;
                if (!good)
                    printf("  transform %u way %d step %u: created %d, %u aborts, %u textures, %u bilinear\n", i, way, step,
                           s.created, s.aborts, s.tex_execs, s.bil_execs);
                if (c.beyond || (way == WAY_DIRECT && step == 0))
                    printf("  transform %2u (%s, rot %4d, scale %4d %4d, opa %3u, way %d step %u): %4u pixels differ, "
                           "largest %d %d %d, %u at an edge, %u beyond\n", i, aa ? "bilinear" : "nearest ",
                           (int) xfs[i].rot, (int) xfs[i].sx, (int) xfs[i].sy, xfs[i].opa, way, step, c.n, c.max[0],
                           c.max[1], c.max[2], c.edge, c.beyond);
                CHECK(c.beyond == 0 && s.created && s.aborts == 0 && s.tex_execs > 0 && (s.bil_execs > 0) == aa);
                for (int f = 0; f < 3; f++)
                    kmax[aa][f] = LV_MAX(kmax[aa][f], c.max[f]);
                diff[aa] += c.n;
                px[aa]++;
            }
    printf("  bilinear: %u renders, %u pixels differ in all, largest %d %d %d; nearest: %u renders, %u pixels, "
           "largest %d %d %d\n", px[1], diff[1], kmax[1][0], kmax[1][1], kmax[1][2], px[0], diff[0], kmax[0][0],
           kmax[0][1], kmax[0][2]);
    /* a transformed layer: LVGL's ARGB8888, the CPU's (exact) */
    for (unsigned i = 0; i < sizeof xf_layers / sizeof xf_layers[0]; i++) {
        run_t   r = RUN0;
        stats_t s;
        r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_XFORM; r.xf = (int) (sizeof xfs / sizeof xfs[0] + i);
        r.blend = true; r.bilinear = true; r.pool = true; r.layers = true; r.imm = true;
        r.approx = LV_BELENOS_APPROX_TRANSFORM;
        CHECK(run_check(&r, &s) == 0 && s.tex_execs == 0);
    }
    /* without bilinear sampling, without blending, without the flag: the
     * CPU's (exact), but the nearest RGB565 image at full opacity */
    for (unsigned i = 0; i < sizeof xfs / sizeof xfs[0]; i++)
        for (int k = 0; k < 3; k++) {
            run_t   r = RUN0;
            stats_t s;
            r.way = WAY_DIRECT; r.gpu_draw = true; r.scene = SC_XFORM; r.xf = (int) i;
            r.blend = k != 1; r.bilinear = k != 0; r.pool = true; r.imm = true;
            r.approx = (k == 2) ? 0u : LV_BELENOS_APPROX_TRANSFORM;
            render_ref(&r);
            render(&r, &s);
            const bool   gpu = k < 2 && !xfs[i].aa && (k == 0 || (xfs[i].fmt == XF_565 && xfs[i].opa == 255));
            const xchk_t c   = xform_check(&xfs[i]);
            if (c.beyond || (s.tex_execs > 0) != gpu || (!gpu && c.n))
                printf("  transform %u case %d: %u differ, %u beyond, %u textures\n", i, k, c.n, c.beyond, s.tex_execs);
            CHECK(c.beyond == 0 && (s.tex_execs > 0) == gpu && (gpu || c.n == 0));
        }
}

#endif
#endif

/* X0: with blending in the GPU (MIX5), the opacities, alpha images in the
 * VRAM and labels (with the pool) pixel for pixel the software renderer, in
 * every configuration of the glue (blending is not an extension) */
static void test_blend_exact(void)
{
    static const int scenes[] = { SC_OPA, SC_A8, SC_TEXT, SC_LAYER, SC_UI };
    static const int ways[]   = { WAY_DIRECT, WAY_GPU };
    for (unsigned i = 0; i < sizeof ways / sizeof ways[0]; i++)
        for (unsigned j = 0; j < sizeof scenes / sizeof scenes[0]; j++)
            for (unsigned step = 0; step <= 3; step += 3) {
                run_t   r = RUN0;
                stats_t s;
                r.way = ways[i]; r.gpu_draw = true; r.scene = scenes[j]; r.step = step; r.blend = true; r.imm = true;
                const unsigned n = run_check(&r, &s);
                CHECK(n == 0 && s.created && s.aborts == 0);
                if (scenes[j] == SC_OPA)
                    CHECK(s.blend_execs > 0);
                if (scenes[j] == SC_A8)
                    CHECK(s.a8_execs >= 2u);    /* the ones in the VRAM */
            }
}

/* X3: one blend under MIX5 is LVGL's: lv_color_16_16_mix against the
 * model's blend (its fac and comb under SET_ALPHA MIX5), a fill or blit's
 * opacity, a glyph's coverage (4 bpp: 17 v; 8 bpp: v) times its opacity, an
 * A8 byte times the opacity (LV_OPA_MIX2) */
static void test_blend_mix5(void)
{
    setup(BLNS_DIF_DPI, BLNS_CFG2_BLEND_Msk);
    m.alpha = BLNS_GPU_ALPHA_MIX5_Msk;
    unsigned long n = 0, bad = 0;
    uint32_t      x = 12345u;
    for (uint32_t k = 0; k < 3000000u; k++) {
        x = x * 1664525u + 1013904223u;
        const uint16_t s = (uint16_t) (x >> 16);
        x = x * 1664525u + 1013904223u;
        const uint16_t d = (uint16_t) (x >> 16);
        x = x * 1664525u + 1013904223u;
        const int opa = (int) (x >> 24), v8 = (int) ((x >> 16) & 0xFF), v4 = (int) ((x >> 12) & 0xF);
        if (opa > LV_OPA_MIN && opa < LV_OPA_MAX) {     /* a fill / blit */
            const int32_t a = fac(opa);
            n++;
            bad += lv_color_16_16_mix(s, d, (uint8_t) opa) != (a ? (uint16_t) blend565(s, d, a) : d);
        }
        for (int depth = 4; depth <= 8; depth += 4) {   /* a glyph, an A8 byte */
            const int gopa = (opa > LV_OPA_MIN) ? opa : 255;
            const int cov  = depth == 4 ? 17 * v4 : v8;
            const int mix  = gopa >= LV_OPA_MAX ? cov : LV_OPA_MIX2(cov, gopa);
            const int32_t a = fac(gopa >= LV_OPA_MAX ? cov : comb(cov, gopa));
            n++;
            bad += (mix ? lv_color_16_16_mix(s, d, (uint8_t) mix) : d) != (a ? (uint16_t) blend565(s, d, a) : d);
        }
    }
    printf("  MIX5: %lu blends, %lu differ from lv_color_16_16_mix\n", n, bad);
    CHECK(bad == 0u);
}

#if LV_BELENOS_USE_POOL || LV_BELENOS_USE_APPROX || LV_BELENOS_USE_CORNERS
#if LV_DRAW_SW_COMPLEX
/* X5: the bound of a gradient, LVGL's colour (lv_draw_sw_grad_color_calculate)
 * against the GPU's ramps as the glue lays them out (runs in one stop
 * interval of GRAD_RUN = 64 at most, each from LVGL's colour at its start
 * towards LVGL's just past it; a ramp steeper than SET_GRAD_RGB takes: one
 * plain row) and the model computes them (grad_ch), on random two-stop
 * gradients of 2 to 1024 rows, sharp ones included */
static uint16_t lvgl_grad(const lv_grad_dsc_t *g, int32_t range, int32_t i)
{
    lv_color_t c;
    lv_opa_t   o;
    lv_draw_sw_grad_color_calculate(g, range, i, &c, &o);
    return lv_color_to_u16(c);
}

static void test_grad_bound(void)
{
    int      mx[3] = { 0, 0, 0 };
    unsigned steep = 0;
    uint32_t x = 777u;
    static const int sh[3] = { 11, 5, 0 }, mk[3] = { 0x1F, 0x3F, 0x1F };
    for (unsigned n = 0; n < 3000u; n++) {
        lv_grad_dsc_t g;
        memset(&g, 0, sizeof g);
        g.stops_count = 2;
        x = x * 1664525u + 1013904223u;
        g.stops[0].color = lv_color_hex(x >> 8);
        x = x * 1664525u + 1013904223u;
        g.stops[1].color = lv_color_hex(x >> 8);
        g.stops[0].opa = g.stops[1].opa = 255;
        x = x * 1664525u + 1013904223u;
        const uint8_t f0 = (uint8_t) (x >> 24), f1 = (uint8_t) (x >> 16);
        g.stops[0].frac = (n % 4u == 0u) ? 0 : LV_MIN(f0, f1);
        g.stops[1].frac = (n % 4u == 0u) ? 255 : (n % 4u == 1u) ? (uint8_t) LV_MIN(255, g.stops[0].frac + 2) : LV_MAX(f0, f1);
        x = x * 1664525u + 1013904223u;
        const int32_t range = 2 + (int32_t) ((x >> 8) % 1023u);
        g.dir = LV_GRAD_DIR_VER;
        for (int32_t i = 0; i < range;) {
            int32_t p0 = INT32_MIN, p1 = INT32_MAX;
            for (unsigned k = 0; k < 2u; k++) {
                const int32_t sv = (g.stops[k].frac * range) >> 8;
                if (sv <= i)
                    p0 = sv;
                else {
                    p1 = sv;
                    break;
                }
            }
            const uint16_t c0 = lvgl_grad(&g, range, i);
            int32_t        end;
            int            d[3] = { 0, 0, 0 };
            if (p0 == INT32_MIN || p1 == INT32_MAX) {
                end = (p1 != INT32_MAX) ? p1 - 1 : (i == p0) ? i : range - 1;
            } else {
                end = LV_MIN(p1 - 1, i + 63);
                const int32_t  len = end + 1 - i;
                const uint16_t c1  = lvgl_grad(&g, range, end + 1);
                for (int c = 0; c < 3; c++) {
                    const int32_t num = (((c1 >> sh[c]) & mk[c]) - ((c0 >> sh[c]) & mk[c])) * 64;
                    d[c] = (int) ((num >= 0) ? (num + len / 2) / len : -((-num + len / 2) / len));
                }
                if (d[0] < -512 || d[0] > 511 || d[1] < -512 || d[1] > 511 || d[2] < -512 || d[2] > 511) {
                    end = i;
                    d[0] = d[1] = d[2] = 0;
                    steep++;
                }
            }
            for (int32_t k = i; k <= end; k++) {
                const uint16_t l = lvgl_grad(&g, range, k);
                for (int c = 0; c < 3; c++) {
                    const int v = grad_ch((c0 >> sh[c]) & mk[c], k - i, d[c], mk[c]);
                    mx[c] = LV_MAX(mx[c], abs(v - ((l >> sh[c]) & mk[c])));
                }
            }
            i = end + 1;
        }
    }
    printf("  gradients: the largest difference per field %d %d %d (%u steep rows)\n", mx[0], mx[1], mx[2], steep);
    CHECK(steep > 0);
    CHECK(mx[0] <= 2 && mx[1] <= 2 && mx[2] <= 2);
}
#endif

/* X4: faults with the extensions' tasks in flight: a recover before every
 * word, the decoder stopped at every EXEC, a timeout at every FIFO wait; a
 * pool too small for all (dropped, refilled, the CPU's when it does not
 * fit). Exact scenes stay exact; blended ones are within the bound once the
 * refresh after the fault has drawn them again */
/* Pixels beyond the bound of the scene of 'r' (the frame rendered) */
static unsigned beyond(const run_t *r, const int tol[3])
{
#if LV_BELENOS_USE_APPROX
    if (r->scene == SC_XFORM)
        return xform_check(&xfs[r->xf]).beyond;
#else
    (void) r;
#endif
    return diff_tol(W_DEF, tol).n;
}

static void test_ext_faults(void)
{
    static const struct { int scene; int way; unsigned step; uint8_t approx; int pool; uint32_t bytes; } sw[] = {
        { SC_ROUND, WAY_DIRECT, 2, 0, 0, 0 },        { SC_POOL, WAY_DIRECT, 2, 0, 1, 0 },
        { SC_POOL, WAY_GPU, 3, 0, 1, 2048 },          { SC_LAYER, WAY_DIRECT, 3, 0, 2, 0 },
        { SC_OPA, WAY_DIRECT, 2, 0, 1, 0 },           { SC_TEXT, WAY_DIRECT, 3, 0, 1, 0 },
        { SC_TEXT, WAY_GPU, 5, 0, 1, 1024 },          { SC_LAYER, WAY_DIRECT, 2, 0, 2, 0 },
        { SC_A8, WAY_DIRECT, 3, 0, 1, 0 },            { SC_A8, WAY_GPU, 4, 0, 1, 3072 },
#if LV_BELENOS_USE_APPROX
        { SC_GRAD, WAY_DIRECT, 2, LV_BELENOS_APPROX_GRAD, 0, 0 },
        { SC_XFORM, WAY_DIRECT, 3, LV_BELENOS_APPROX_TRANSFORM, 1, 1 },
        { SC_XFORM, WAY_GPU, 2, LV_BELENOS_APPROX_TRANSFORM, 1, 15 },
#endif
    };
    for (unsigned i = 0; i < sizeof sw / sizeof sw[0]; i++) {
        run_t   r = RUN0;
        stats_t s0, s;
        r.way = sw[i].way; r.gpu_draw = true; r.scene = sw[i].scene; r.step = sw[i].step;
        r.approx = sw[i].approx; r.pool = sw[i].pool > 0; r.layers = sw[i].pool == 2; r.pool_bytes = sw[i].bytes;
        r.blend = true; r.imm = true; r.bilinear = true;
        if (r.scene == SC_XFORM) {              /* (bytes: the transform) */
            r.xf         = (int) sw[i].bytes;
            r.pool_bytes = 0u;
        }
        const int *tol = (r.approx & LV_BELENOS_APPROX_GRAD) ? TOL2 : TOL0;
        render_ref(&r);
        render(&r, &s0);
        CHECK(beyond(&r, tol) == 0);
        unsigned bad_irq = 0, bad_stop = 0, bad_to = 0;
        for (int k = 0; k <= (int) s0.words; k++) {
            r.irq_at = k;
            render(&r, &s);
            const unsigned n = beyond(&r, tol);
            if (n && bad_irq < 3)
                printf("  scene %d way %d: recover before word %d: %u pixels beyond\n", r.scene, r.way, k, n);
            bad_irq += n != 0;
        }
        r.irq_at = -1;
        for (unsigned e = 1; e <= s0.execs; e++) {
            r.stop_exec = e;
            render(&r, &s);
            const unsigned n = beyond(&r, tol);
            if (n && bad_stop < 3)
                printf("  scene %d way %d: stop at EXEC %u: %u pixels beyond\n", r.scene, r.way, e, n);
            bad_stop += n != 0;
        }
        r.stop_exec = 0;
        r.fifo_aw   = 3;
        render(&r, &s0);
        for (int k = 0; k < (int) s0.words; k++) {
            r.timeout_at = k;
            render(&r, &s);
            const unsigned n = beyond(&r, tol);
            if (n && bad_to < 3)
                printf("  scene %d way %d: timeout after word %d: %u pixels beyond\n", r.scene, r.way, k, n);
            bad_to += n != 0;
        }
        printf("  scene %d way %d approx %u pool %d/%u: %u words, %u EXECs; %u / %u / %u bad\n", r.scene, r.way,
               r.approx, sw[i].pool, (unsigned) sw[i].bytes, s0.words, s0.execs, bad_irq, bad_stop, bad_to);
        CHECK(bad_irq == 0 && bad_stop == 0 && bad_to == 0);
    }
}
#endif

/*---------------------------------------------------------------------------
 * Main: each test in a child process with a time limit
 *---------------------------------------------------------------------------*/
static void on_alarm(int sig)
{
    (void) sig;
    static const char msg[] = "  HANG: no return within the time limit\n";
    (void) !write(1, msg, sizeof msg - 1);
    _exit(3);
}

int main(int argc, char **argv)
{
    const long only = (argc > 1) ? strtol(argv[1], NULL, 10) : -1;
    static const struct { const char *name; void (*fn)(void); } tests[] = {
        { "plain scenes, every way",       test_plain },
        { "error after acceptance (L1)",   test_error_after_acceptance },
        { "recover, batch in flight (L2)", test_recover_batch },
        { "flush copy stopped (L3)",       test_flush_error },
        { "image stride 0 (L4)",           test_image_stride0 },
        { "LVGL's stride (L5)",            test_stride },
        { "create, delete (L6)",           test_create },
        { "busy, timeout (L7)",            test_busy },
        { "unit binding, waits (L8)",      test_unit },
        { "fault sweeps (L1, L2, L3)",     test_sweep },
        { "recover at a fence read (L2)",  test_fence_read },
        { "immediate source (L9)",         test_imm },
        { "immediate source faults (L10)", test_imm_faults },
        { "blending, exact (X0)",          test_blend_exact },
        { "one blend is LVGL's (X3)",      test_blend_mix5 },
#if LV_BELENOS_USE_POOL || LV_BELENOS_USE_APPROX || LV_BELENOS_USE_CORNERS
        { "extensions, exact (X1)",        test_ext_exact },
#if LV_BELENOS_USE_APPROX
        { "extensions, approximate (X2)",  test_ext_approx },
        { "transformed images (X7)",       test_xform },
#if LV_DRAW_SW_COMPLEX
        { "a gradient's bound (X5)",       test_grad_bound },
#endif
#endif
        { "extensions, faults (X4)",       test_ext_faults },
#endif
    };
    unsigned failed = 0, ran = 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    for (unsigned i = 0; i < sizeof tests / sizeof tests[0]; i++) {
        if (only >= 0 && (long) i != only)
            continue;
        ran++;
        const pid_t pid = fork();
        if (pid == 0) {
            signal(SIGALRM, on_alarm);
            alarm(HANG_S);
            tests[i].fn();
            printf("  (%u checks)\n", checks);
            _exit(fails ? 1 : 0);
        }
        int st = 0;
        waitpid(pid, &st, 0);
        const bool ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
        failed += !ok;
        printf("%-36s %s\n", tests[i].name, ok ? "ok" : "FAILED");
    }
    printf("%u tests, %u failed (LV_DRAW_BUF_STRIDE_ALIGN %d, LV_DRAW_BUF_ALIGN %d, LV_DRAW_SW_COMPLEX %d)\n", ran,
           failed, LV_DRAW_BUF_STRIDE_ALIGN, LV_DRAW_BUF_ALIGN, LV_DRAW_SW_COMPLEX);
    return failed ? 1 : 0;
}
