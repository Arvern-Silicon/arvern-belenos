/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      lv_belenos.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * LVGL v9 display driver and GPU draw unit for Belenos at 16 bpp (see
 * lv_belenos.h).
 *----------------------------------------------------------------------------*/
#include "lv_belenos.h"
/* LVGL's internals (paths from LVGL's root, as lvgl.h) */
#include "src/draw/sw/lv_draw_sw.h"         /* lv_draw_unit_t, lv_draw_task_t, lv_draw_sw_* */
#include "src/misc/lv_area_private.h"       /* lv_area_intersect */
#include "src/core/lv_refr_private.h"       /* lv_refr_get_disp_refreshing */
#include "src/core/lv_global.h"             /* the draw units (a detached one is taken again) */
#include "src/display/lv_display_private.h" /* the display's layers */

/* The extensions built (lv_belenos.h): the option, and the GPU feature
 * unless the platform header says it is absent. Blending (MIX5: exact) is
 * part of the unit wherever the GPU may have it */
#define LVB_CORNERS (LV_BELENOS_USE_CORNERS && LV_DRAW_SW_COMPLEX)
#define LVB_POOL    LV_BELENOS_USE_POOL
#define LVB_BLEND   (!BLNS_HW_OFF(GPU_BLEND))
#define LVB_GLYPHS  (LVB_POOL && LVB_BLEND)
#define LVB_ARGB    (LVB_POOL && LVB_BLEND)         /* ARGB8888 images staged as RGB565A8 */
#define LVB_GRAD    (LV_BELENOS_USE_APPROX && !BLNS_HW_OFF(GPU_GRAD) && LV_DRAW_SW_COMPLEX)
#define LVB_XFORM   (LV_BELENOS_USE_APPROX && !BLNS_HW_OFF(GPU_XY))
#define LVB_STATE   (LVB_BLEND || LVB_GRAD)     /* GPU modes the unit sets and clears */
#define LVB_CPU     (LVB_CORNERS || LVB_POOL)  /* a task the unit takes, then draws on the CPU */
#define LVB_RECT    (LVB_CORNERS || LVB_STATE) /* FILL / BORDER beyond plain opaque rectangles */

#if LVB_POOL
#include "src/draw/lv_draw_buf_private.h"   /* LVGL's draw buffer allocator */
#endif
#if LVB_GRAD
#include "src/draw/sw/lv_draw_sw_grad.h"     /* lv_draw_sw_grad_color_calculate */
#endif
#if LVB_GLYPHS
#include "src/draw/lv_draw_label_private.h" /* lv_draw_glyph_dsc_t */
#include "src/draw/sw/blend/lv_draw_sw_blend_private.h"
#endif

typedef struct lv_belenos_unit lv_belenos_unit_t;

#if LVB_POOL
#define POOL_BLKS   64u                 /* blocks in use at most                */
#define POOL_IMAGES 16u                 /* images staged at most                */
enum { POOL_LAYER, POOL_CACHE };        /* a block: LVGL's layer, or a staged image / glyph run */
typedef struct {
    uint32_t off, len;                  /* bytes from the pool's start          */
    uint8_t  kind;
} pool_blk_t;
typedef struct {
    const uint8_t *data;                /* the image's pixels (NULL: a free slot) */
    uint32_t       stride;
    uint16_t       w, h;
    uint8_t        cf;                  /* its LV_COLOR_FORMAT_*                  */
    uint8_t       *px;                  /* staged: w x h RGB565 pixels, rows w
                                         * apart; RGB565A8 (from RGB565A8 or
                                         * ARGB8888): rows (w + 1) & ~1 apart,
                                         * then the alpha plane, rows as many
                                         * bytes apart (LVGL's layout)         */
} pool_img_t;
typedef struct pool_state {
    pool_blk_t     blk[POOL_BLKS];      /* the blocks in use, by offset         */
    uint32_t       nblk;
    pool_img_t     img[POOL_IMAGES];    /* the staged images                    */
    uint8_t        img_next;            /* the slot replaced next (round robin) */
} pool_state_t;
#endif
#if LVB_GLYPHS
#define GLYPH_SLOTS 256u                /* glyph masks staged at most (3/4 of it) */
#define GLYPH_RUN   2048u               /* bytes allocated at a time for them    */
typedef struct {
    const lv_font_t *font;              /* LVGL's resolved font (NULL: free)     */
    uint32_t         id;                /* its glyph index                       */
    uint8_t         *px;                /* the mask, w x h values packed         */
    uint16_t         w, h;
    uint8_t          depth;             /* BLNS_EXP_4BPP or BLNS_EXP_8BPP        */
} pool_glyph_t;
#endif

typedef struct lv_belenos {
    lv_belenos_config_t cfg;
    lv_display_t       *disp;
    lv_belenos_unit_t  *unit;           /* the draw unit drawing for it, or NULL */
    /* GPU way: the copy in flight (its fence, and what to copy again) */
    bool                fenced;
    uint32_t            fence;
    lv_area_t           area;
    const uint8_t      *px;
    uint32_t            stride;
#if LVB_POOL
    /* the VRAM pool: its blocks in use (by offset), the staged images */
    uint8_t            *pool;
    uint32_t            pool_bytes;
    struct pool_state  *ps;             /* its blocks and staged images (allocated with a pool) */
    struct lv_belenos  *next_pool;      /* the list of the pools (pool_free)    */
#endif
#if LVB_GLYPHS
    pool_glyph_t       *glyph;          /* GLYPH_SLOTS (open addressing), NULL: no labels */
    uint32_t            nglyph;
    uint8_t            *run;            /* where the next glyph mask goes ...    */
    uint32_t            run_left;       /* ... and the bytes left there          */
#endif
#if LVB_BLEND
    /* blended tasks the CPU drew again after a GPU fault: redrawn whole by
     * the next refresh (invalidated at LV_EVENT_REFR_READY) */
    bool                repair_on;
    lv_area_t           repair;
#endif
} lv_belenos_t;

static uint16_t frame_pitch(const lv_belenos_config_t *c)
{
    return c->pitch ? c->pitch : (uint16_t) c->width;
}

/* Bytes [p, p + n) in the VRAM window, p pixel-aligned (n > 0) */
static bool in_vram(const blns_t *dev, const void *p, uint32_t n)
{
    const uintptr_t off = (uintptr_t) p - (uintptr_t) blns_vram8(dev);
    const uint32_t  len = dev->caps.vram_words * 4u;
    return n && !((uintptr_t) p & 1u) && blns_vram_contains(dev, p) && n <= len - (uint32_t) off;
}

/* The GPU drew nothing of what is queued, or may still draw some of it:
 * nothing of it left in the GPU (what remains drawn, else abandoned) */
static void gpu_idle(blns_t *dev)
{
    if (blns_gpu_wait(dev) != BLNS_OK)
        (void) blns_gpu_recover(dev);
}

#if LVB_STATE
static bool unit_plain(lv_belenos_unit_t *u);
#endif

/*------------------------------- display ------------------------------------*/

/* Widen an invalidated area to even columns: every row of the draw buffer
 * and of the frame is then whole 32-bit words (CPU way) */
static void round_cb(lv_event_t *e)
{
    const lv_belenos_t *drv = lv_event_get_user_data(e);
    lv_area_t          *a   = lv_event_get_invalidated_area(e);
    a->x1 &= ~1;
    a->x2 |= 1;
    if (a->x2 >= drv->cfg.width)                /* an odd display width */
        a->x2 = drv->cfg.width - 1;
}

/* The CPU copies an area of the draw buffer (rows 'stride' bytes apart) */
static void cpu_copy(const lv_belenos_t *drv, const lv_area_t *a, const uint8_t *px, uint32_t stride)
{
    const uint16_t pitch = frame_pitch(&drv->cfg);
    (void) blns_vram_write_rect(drv->cfg.dev, px, stride, drv->cfg.frame + (uint32_t) a->y1 * pitch + (uint32_t) a->x1,
                                pitch, (uint16_t) lv_area_get_width(a), (uint16_t) lv_area_get_height(a));
}

/* The options of a plain blit (op S): the frame copies, the image blits */
static const blns_blit_t plain_blit = { BLNS_ROP_S, false, 0u, false, BLNS_REMAP_OFF, false };

/* GPU way: one COPY and its FENCE, kept (flush_settle). False when nothing
 * of it is in flight: the CPU copies */
static bool gpu_copy(lv_belenos_t *drv, const lv_area_t *a, const uint8_t *px, uint32_t stride)
{
    blns_t        *dev   = drv->cfg.dev;
    const uint16_t pitch = frame_pitch(&drv->cfg);
    const uint16_t w     = (uint16_t) lv_area_get_width(a);
    const uint16_t h     = (uint16_t) lv_area_get_height(a);
    const blns_surf_t s  = { blns_vram_pa(dev, px), (uint16_t) (stride / 2u), BLNS_SWAP_NONE };
    const blns_surf_t d  = { drv->cfg.frame + (uint32_t) a->y1 * pitch + (uint32_t) a->x1, pitch, BLNS_SWAP_NONE };
    if (!dev->gpu_on)
        return false;
#if LVB_STATE
    if (drv->unit && !unit_plain(drv->unit))
        return false;                           /* blending or a gradient still on */
#endif
    for (int tries = 0; tries < 2; tries++) {
        blns_status_t st = blns_gpu_blit(dev, &s, &d, w, h, &plain_blit);
        if (st == BLNS_OK) {
            if (blns_gpu_fence(dev, false, &drv->fence) != BLNS_OK) {
                gpu_idle(dev);                  /* the copy without its fence: let it end */
                return false;
            }
            drv->fenced = true;
            drv->area   = *a;
            drv->px     = px;
            drv->stride = stride;
            return true;
        }
        if (st != BLNS_ERR_GPU && st != BLNS_ERR_STATE)
            return false;                       /* no room now (BUSY, TIMEOUT): nothing sent */
        /* a stopped GPU: recover once and retry, else every later flush
         * would fall back to the CPU */
        (void) blns_gpu_recover(dev);
    }
    return false;
}

/* GPU way: the copy in flight done. One the GPU did not complete (stopped,
 * dropped by a recover, or still at it when the wait ends) is stopped and
 * the CPU copies the area again: the buffer is LVGL's once this returns */
static void flush_settle(lv_belenos_t *drv)
{
    if (!drv->fenced)
        return;
    drv->fenced = false;
    blns_t             *dev = drv->cfg.dev;
    const blns_status_t st  = blns_gpu_wait_fence(dev, drv->fence);
    if (st == BLNS_OK)
        return;
    if (st == BLNS_ERR_GPU || st == BLNS_ERR_TIMEOUT)
        (void) blns_gpu_recover(dev);
    else
        gpu_idle(dev);                          /* dropped: what came after it ends first */
    cpu_copy(drv, &drv->area, drv->px, drv->stride);
}

void lv_belenos_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    lv_belenos_t *drv = lv_display_get_driver_data(disp);
    if (drv->cfg.flush != LV_BELENOS_FLUSH_DIRECT) {
        /* LVGL's stride of this area (LV_DRAW_BUF_STRIDE_ALIGN) */
        const uint32_t stride = lv_display_get_buf_active(disp)->header.stride;
        if (drv->cfg.flush == LV_BELENOS_FLUSH_GPU && gpu_copy(drv, area, px_map, stride)) {
            if (!lv_display_flush_is_last(disp))
                return;                         /* flush_wait_cb waits */
            flush_settle(drv);                  /* the frame whole when LVGL returns */
        } else {
            cpu_copy(drv, area, px_map, stride);
        }
    }
    lv_display_flush_ready(disp);
}

static void flush_wait_cb(lv_display_t *disp)
{
    flush_settle(lv_display_get_driver_data(disp));
}

/*------------------------------- VRAM pool ----------------------------------*
 * A first-fit allocator over the pool (the block list in RAM, sorted by
 * offset), for three users: LVGL's RGB565 layers (cfg.pool_layers), the
 * staged images and the glyph masks. The
 * two caches are dropped together, after a wait for the GPU (which may still
 * read them), when an allocation does not fit; a layer is freed by LVGL once
 * the task drawing it is FINISHED (the GPU done with it).
 *----------------------------------------------------------------------------*/
#if LVB_POOL
static void *pool_get(lv_belenos_t *drv, uint32_t len, uint8_t kind)
{
    len = (len + 3u) & ~3u;
    if (!drv->ps || !len || drv->ps->nblk >= POOL_BLKS)
        return NULL;
    uint32_t at = 0;
    for (uint32_t i = 0;; i++) {
        const uint32_t end = (i < drv->ps->nblk) ? drv->ps->blk[i].off : drv->pool_bytes;
        if (end - at >= len) {
            lv_memmove(&drv->ps->blk[i + 1u], &drv->ps->blk[i], (drv->ps->nblk - i) * sizeof drv->ps->blk[0]);
            drv->ps->blk[i].off  = at;
            drv->ps->blk[i].len  = len;
            drv->ps->blk[i].kind = kind;
            drv->ps->nblk++;
            return drv->pool + at;
        }
        if (i >= drv->ps->nblk)
            return NULL;
        at = drv->ps->blk[i].off + drv->ps->blk[i].len;
    }
}

static bool pool_has(const lv_belenos_t *drv, const void *p)
{
    return drv->ps && (const uint8_t *) p >= drv->pool && (const uint8_t *) p < drv->pool + drv->pool_bytes;
}

static void pool_put(lv_belenos_t *drv, const void *p)
{
    const uint32_t off = (uint32_t) ((const uint8_t *) p - drv->pool);
    for (uint32_t i = 0; i < drv->ps->nblk; i++)
        if (drv->ps->blk[i].off == off) {
            drv->ps->nblk--;
            lv_memmove(&drv->ps->blk[i], &drv->ps->blk[i + 1u], (drv->ps->nblk - i) * sizeof drv->ps->blk[0]);
            return;
        }
}

/* Every staged image and glyph dropped, once the GPU no longer reads them:
 * false when the wait for it fails (nothing dropped) */
static bool pool_drop(lv_belenos_t *drv)
{
    if (!drv->ps || blns_gpu_wait(drv->cfg.dev) != BLNS_OK)
        return false;
    uint32_t n = 0;
    for (uint32_t i = 0; i < drv->ps->nblk; i++)
        if (drv->ps->blk[i].kind != POOL_CACHE)
            drv->ps->blk[n++] = drv->ps->blk[i];
    drv->ps->nblk = n;
    lv_memzero(drv->ps->img, sizeof drv->ps->img);
    drv->ps->img_next = 0;
#if LVB_GLYPHS
    if (drv->glyph)
        lv_memzero(drv->glyph, GLYPH_SLOTS * sizeof drv->glyph[0]);
    drv->nglyph   = 0;
    drv->run      = NULL;
    drv->run_left = 0;
#endif
    return true;
}

/* pool_get for the caches, dropping them once when it does not fit */
static void *pool_cache(lv_belenos_t *drv, uint32_t len)
{
    void *p = pool_get(drv, len, POOL_CACHE);
    if (!p && pool_drop(drv))
        p = pool_get(drv, len, POOL_CACHE);
    return p;
}

/* The staged pitch of an image in pixels (and of its alpha plane in bytes) */
static uint32_t pool_pitch(uint8_t cf, uint32_t w)
{
    return (cf == LV_COLOR_FORMAT_RGB565) ? w : (w + 1u) & ~1u;
}

static uint32_t pool_img_bytes(uint8_t cf, uint32_t w, uint32_t h)
{
    return pool_pitch(cf, w) * h * ((cf == LV_COLOR_FORMAT_RGB565) ? 2u : 3u);
}

/* An image of the CPU's memory staged in the pool (now, the first time):
 * RGB565 as it is, RGB565A8 as it is (colour rows, then the alpha plane),
 * ARGB8888 converted to RGB565A8 (LVGL's truncation); NULL when it does not
 * fit */
static const uint8_t *pool_image(lv_belenos_t *drv, const lv_image_dsc_t *img, uint32_t stride)
{
    const uint16_t w = (uint16_t) img->header.w, h = (uint16_t) img->header.h;
    const uint8_t  cf = (uint8_t) img->header.cf;
    for (unsigned i = 0; i < POOL_IMAGES; i++) {
        const pool_img_t *e = &drv->ps->img[i];
        if (e->data == img->data && e->stride == stride && e->w == w && e->h == h && e->cf == cf)
            return e->px;
    }
    if (drv->ps->img[drv->ps->img_next].data && !pool_drop(drv))
        return NULL;                            /* every slot taken: the cache starts again */
    uint8_t *px = pool_cache(drv, pool_img_bytes(cf, w, h));
    blns_t  *dev = drv->cfg.dev;
    if (!px)
        return NULL;
    const uint32_t pitch = pool_pitch(cf, w);
#if LVB_ARGB
    if (cf == LV_COLOR_FORMAT_ARGB8888) {
        blns_argb8888_to_rgb565a8((uint16_t *) (void *) px, px + pitch * 2u * h, pitch,
                                  (const uint32_t *) (const void *) img->data, stride / 4u, w, h);
    } else
#endif
    if (blns_vram_write_rect(dev, img->data, stride, blns_vram_pa(dev, px), (uint16_t) pitch, w, h) != BLNS_OK) {
        pool_put(drv, px);
        return NULL;
    }
#if LVB_BLEND
    if (cf == LV_COLOR_FORMAT_RGB565A8) {       /* the alpha plane: LVGL's rows stride / 2 apart */
        const uint8_t     *a = img->data + stride * h;
        volatile uint8_t  *d = px + pitch * 2u * h;
        for (uint32_t y = 0; y < h; y++, a += stride / 2u, d += pitch)
            for (uint32_t x = 0; x < w; x++)
                d[x] = a[x];
        BLNS_WMB();
    }
#endif
    pool_img_t *e = &drv->ps->img[drv->ps->img_next];   /* (pool_cache may have dropped the cache) */
    drv->ps->img_next = (uint8_t) ((drv->ps->img_next + 1u) % POOL_IMAGES);
    e->data   = img->data;
    e->stride = stride;
    e->w      = w;
    e->h      = h;
    e->cf     = cf;
    e->px     = px;
    return px;
}

void lv_belenos_drop_images(lv_display_t *disp)
{
    lv_belenos_t *drv = disp ? lv_display_get_driver_data(disp) : NULL;
    if (drv && drv->pool && !pool_drop(drv)) {
        gpu_idle(drv->cfg.dev);                 /* a stopped GPU: nothing of it reads them */
        (void) pool_drop(drv);
    }
}

/* LVGL's RGB565 layers in the pool (pool_layers): the unit allocates the
 * buffer of a layer it is dispatched for before LVGL does, with its own
 * allocator (LVGL's but for where the pixels go), which LVGL frees with the
 * layer. The allocator takes no context: the pool it allocates from is
 * set around the call; a buffer is freed into the pool that holds it (the
 * displays with a pool are listed; that of a deleted one is not) */
static lv_belenos_t          *pool_cur;        /* the pool of the allocation in progress */
static lv_belenos_t          *pools;           /* the drivers with a pool               */
static lv_draw_buf_handlers_t pool_handlers;   /* LVGL's, with pool_malloc / pool_free  */

static void *pool_malloc(size_t size, lv_color_format_t cf)
{
    (void) cf;
    return pool_cur ? pool_get(pool_cur, (uint32_t) size + LV_DRAW_BUF_ALIGN - 1u, POOL_LAYER) : NULL;
}

static void pool_free(void *p)
{
    for (lv_belenos_t *d = pools; d; d = d->next_pool)
        if (pool_has(d, p)) {
            pool_put(d, p);
            return;
        }
}

/* The layer's buffer in the pool (the caches dropped if it does not fit):
 * false when it does not fit (LVGL allocates it in RAM then) */
static bool pool_layer(lv_belenos_t *drv, lv_layer_t *layer)
{
    if (!drv->ps || !drv->cfg.pool_layers || layer->color_format != LV_COLOR_FORMAT_RGB565)
        return false;
    if (!pool_handlers.buf_malloc_cb) {
        pool_handlers               = *lv_draw_buf_get_handlers();
        pool_handlers.buf_malloc_cb = pool_malloc;
        pool_handlers.buf_free_cb   = pool_free;
    }
    const uint32_t w = (uint32_t) lv_area_get_width(&layer->buf_area);
    const uint32_t h = (uint32_t) lv_area_get_height(&layer->buf_area);
    pool_cur = drv;
    lv_draw_buf_t *b = lv_draw_buf_create_ex(&pool_handlers, w, h, LV_COLOR_FORMAT_RGB565, LV_STRIDE_AUTO);
    if (!b && pool_drop(drv))
        b = lv_draw_buf_create_ex(&pool_handlers, w, h, LV_COLOR_FORMAT_RGB565, LV_STRIDE_AUTO);
    pool_cur = NULL;
    if (!b)
        return false;
    layer->draw_buf     = b;
    layer->buffer_owned = true;
    LV_GLOBAL_DEFAULT()->draw_info.used_memory_for_layers += h * b->header.stride;    /* as LVGL counts it */
    return true;
}

static void pool_list(lv_belenos_t *drv, bool add)
{
    lv_belenos_t **pp = &pools;
    while (*pp && *pp != drv)
        pp = &(*pp)->next_pool;
    if (add && !*pp)
        *pp = drv;
    else if (!add && *pp)
        *pp = drv->next_pool;
}
#endif

/*------------------------------- draw unit ----------------------------------*
 * The tasks it takes are pushed to the GPU and marked QUEUED: LVGL then
 * gives the software unit no task whose area meets one of them, and gives
 * this unit its next ones (the GPU runs them in order). A FENCE behind each
 * batch, at most two batches in flight; once the GPU has passed their fences
 * the tasks are FINISHED. A batch the GPU did not draw (stopped on an error,
 * dropped by a recover, a wait that ended) is drawn again by the CPU: every
 * queued task, in their order, with the software renderer's functions (the
 * tasks are opaque: drawing one again over a part the GPU drew gives the
 * same pixels). A GPU without room (BUSY, a TIMEOUT before anything was
 * sent) only ends the round: a task none of whose rectangles was sent stays
 * WAITING for the next one; a border cut between two rectangles is QUEUED
 * and goes on from there (sent again whole, it could never fit a FIFO that
 * drains slower than the unit pushes). A TIMEOUT in the data of an
 * immediate blit discards it (the stream stays in step): the task waits for
 * the next round and is sent again whole (a copy: the same pixels).
 * Extensions: a task the unit took but finds it cannot push after all (no
 * room in the pool, a layer allocated in RAM) is drawn by the CPU at once,
 * once the GPU has drawn what is queued (LVGL lets this unit take tasks over
 * its own queued ones); the CPU's part of a task (rounded corners, a glyph
 * that does not fit) likewise. A blended task drawn again by the CPU after
 * a fault may be blended twice where the GPU drew it: its area is redrawn by
 * the next refresh.
 *----------------------------------------------------------------------------*/

#define UNIT_SCORE  50u                 /* preference_score: 100 is the software unit */

static const char unit_name[] = "BELENOS";

#if LVB_STATE
#define ST_OFF      0x100u              /* unit_t alpha / grad: the mode off     */
#define ST_UNKNOWN  0x200u              /* ... not known (after a fault)         */
#define ST_MIX      0x400u              /* alpha: MIX5, EN off (per-pixel alpha, coverage) */
#endif

struct lv_belenos_unit {
    lv_draw_unit_t base;                /* first: LVGL's view of the unit       */
    lv_belenos_t  *drv;                 /* the display it draws for (NULL: none) */
    lv_layer_t    *layer;               /* where the queued tasks draw          */
    uint32_t       fence[2];            /* tags behind the batches in flight    */
    uint8_t        fences;              /* ... how many                         */
    bool           unfenced;            /* tasks pushed behind the last fence   */
    uint32_t       queued;              /* tasks pushed, not retired            */
    lv_draw_task_t *part;               /* a task partly pushed (a border) ...  */
    unsigned       piece;               /* ... the rectangle it goes on with    */
#if LV_BELENOS_USE_APPROX
    uint8_t        approx;              /* cfg.approx, the GPU features built   */
#endif
#if LVB_STATE
    uint16_t       alpha;               /* SET_ALPHA as pushed: A (EN, MIX5), ST_MIX,
                                         * ST_OFF (ROUND), ST_UNKNOWN           */
    uint16_t       grad;                /* SET_GRAD: ST_OFF, 0 on, ST_UNKNOWN    */
#endif
};

/* The layer's buffer: RGB565 in the VRAM. Without a buffer yet, one LVGL
 * will allocate in the pool (pool_layers; checked again at dispatch) */
static bool layer_in_vram(const lv_belenos_unit_t *u, const blns_t *dev, const lv_layer_t *l)
{
    const lv_draw_buf_t *b = l->draw_buf;
#if LVB_POOL
    if (!b)
        return l->color_format == LV_COLOR_FORMAT_RGB565 && u->drv->pool && u->drv->cfg.pool_layers;
#endif
    (void) u;
    return b && l->color_format == LV_COLOR_FORMAT_RGB565 && !(b->header.stride & 1u) &&
           in_vram(dev, b->data, (uint32_t) b->header.stride * b->header.h);
}

/* Whether the clipped area 'a' misses the four rout x rout corner squares of
 * 'c', rout the radius as LVGL limits it (there a rounded rectangle and its
 * border are plain rectangles: no mask, no anti-aliasing). Without
 * LV_DRAW_SW_COMPLEX the software renderer draws no rounded shape at all. */
#if LV_DRAW_SW_COMPLEX
static int32_t rout_of(const lv_area_t *c, int32_t radius)
{
    const int32_t s = LV_MIN(lv_area_get_width(c), lv_area_get_height(c)) >> 1;
    return LV_MIN(radius, s);
}
#endif

static bool clear_of_corners(const lv_area_t *c, int32_t radius, const lv_area_t *a)
{
#if LV_DRAW_SW_COMPLEX
    const int32_t rout = rout_of(c, radius);
    return (a->y1 >= c->y1 + rout && a->y2 <= c->y2 - rout) ||
           (a->x1 >= c->x1 + rout && a->x2 <= c->x2 - rout);
#else
    (void) c;
    (void) a;
    return radius == 0;
#endif
}

#if LVB_CORNERS
/* The CPU draws the corners, the GPU the rest: when the corners are at most
 * a quarter of the area (else the software renderer draws it all) */
static bool corners_ok(const lv_area_t *c, int32_t radius)
{
    const int32_t rout = rout_of(c, radius);
    return 16 * rout * rout <= lv_area_get_width(c) * lv_area_get_height(c);
}
#endif

#if LVB_BLEND
/* An opacity the GPU blends as LVGL (MIX5, caps.gpu_blend), or full */
static bool opa_ok(const blns_t *dev, lv_opa_t opa)
{
    return opa >= LV_OPA_MAX || (opa > LV_OPA_MIN && BLNS_HAS(dev, GPU_BLEND));
}
#endif

/* Pixels of an immediate blit at most: the CPU pushes a word in about 8
 * cycles where the software renderer copies one in about 5, and saves its
 * per-image set-up (about 1100 cycles); even at about 1100 pixels */
#define IMM_PX_MAX 1024u

/* Source of an image or layer blit: RGB565 pixels the size of the task's
 * area (a tile's with tile); a stride of 0 is w x 2 (LVGL's rule for an
 * image without one) */
typedef struct {
    const uint8_t *p;                   /* pixel (0, 0)                         */
    uint32_t       stride;              /* bytes from a row to the next         */
    uint32_t       bytes;               /* bytes readable from p                */
    bool           imm;                 /* not in the VRAM: the immediate source */
#if LVB_BLEND
    uint8_t        cf;                  /* LV_COLOR_FORMAT_RGB565, RGB565A8 or ARGB8888 */
    const uint8_t *a8;                  /* RGB565A8 (as drawn): the alpha of pixel (0, 0) */
#endif
#if LVB_POOL
    uint16_t       w, h;                /* the image's size                     */
    bool           pool;                /* not in the VRAM: staged in the pool   */
    bool           later;               /* a layer whose buffer LVGL allocates later */
#endif
} blit_src_t;
#if LVB_BLEND
#define SRC_CF(s)           ((s)->cf)
#define SRC_A8(s)           ((s)->a8)
#else
#define SRC_CF(s)           ((void) (s), LV_COLOR_FORMAT_RGB565)
#define SRC_A8(s)           ((void) (s), (const uint8_t *) NULL)
#endif

/* The formats the unit draws: RGB565; with blending RGB565A8 (the GPU's
 * per-pixel alpha), and with the pool ARGB8888 (staged as RGB565A8) */
static bool cf_ok(const blns_t *dev, const lv_image_header_t *h)
{
    (void) dev;
    if (h->cf == LV_COLOR_FORMAT_RGB565)
        return true;
#if LVB_BLEND
    return (h->cf == LV_COLOR_FORMAT_RGB565A8 || (LVB_ARGB && h->cf == LV_COLOR_FORMAT_ARGB8888)) &&
           !(h->flags & LV_IMAGE_FLAGS_PREMULTIPLIED) && BLNS_HAS(dev, GPU_BLEND);
#else
    return false;
#endif
}

/* The source: in the VRAM (the GPU reads it), else staged in the pool, else
 * with the immediate source, anywhere the CPU reads (pushed through
 * GPU_CMD). False: none. An ARGB8888 image is always staged (the GPU reads
 * RGB565A8 only); an RGB565A8 one in the VRAM is read where it is (its alpha
 * plane after the colour rows, LVGL's layout), else staged. */
static bool blit_src(const lv_belenos_unit_t *u, const blns_t *dev, const lv_draw_task_t *t, blit_src_t *src)
{
    (void) u;
    const lv_draw_image_dsc_t *d   = t->draw_dsc;
    const lv_image_header_t   *h;
#if LVB_POOL
    src->imm   = false;                         /* (a layer drawn later) */
    src->pool  = false;
    src->later = false;
#endif
#if LVB_BLEND
    src->cf = LV_COLOR_FORMAT_RGB565;
    src->a8 = NULL;
#endif
    if (t->type == LV_DRAW_TASK_TYPE_LAYER) {
        const lv_layer_t    *l = d->src;
        const lv_draw_buf_t *b = l->draw_buf;
        if (!b) {
#if LVB_POOL
            /* children not drawn yet: in the pool, or the CPU at dispatch */
            src->later = layer_in_vram(u, dev, l) && lv_area_get_width(&l->buf_area) == lv_area_get_width(&t->area) &&
                         lv_area_get_height(&l->buf_area) == lv_area_get_height(&t->area);
            return src->later;
#else
            return false;
#endif
        }
        h          = &b->header;
        src->p     = b->data;
        src->bytes = b->data_size;
    } else {
        const lv_image_dsc_t *img = d->src;
        if (lv_image_src_get_type(img) != LV_IMAGE_SRC_VARIABLE)
            return false;
        h          = &img->header;
        src->p     = img->data;
        src->bytes = img->data_size;
    }
    const bool     argb = LVB_ARGB && h->cf == LV_COLOR_FORMAT_ARGB8888;
    const uint32_t s    = h->stride ? h->stride : h->w * (argb ? 4u : 2u);
#if LVB_POOL
    const bool tile = d->tile;                  /* the tiles: the image's size */
#else
    const bool tile = false;
#endif
    if (!cf_ok(dev, h) || (h->flags & LV_IMAGE_FLAGS_COMPRESSED) || (s & (argb ? 3u : 1u)) ||
        (!tile && (h->w != lv_area_get_width(&t->area) || h->h != lv_area_get_height(&t->area))) || !src->p)
        return false;
    src->stride = s;
#if LVB_POOL
    src->w      = (uint16_t) h->w;
    src->h      = (uint16_t) h->h;
#endif
#if LVB_BLEND
    src->cf     = (uint8_t) h->cf;
    if (h->cf == LV_COLOR_FORMAT_RGB565A8)
        src->a8 = src->p + s * h->h;
    /* RGB565A8: the colour rows and the alpha plane in the VRAM, else staged */
    const uint32_t bytes = (h->cf == LV_COLOR_FORMAT_RGB565A8) ? s * h->h + s / 2u * h->h : s * h->h;
    src->imm    = argb || !in_vram(dev, src->p, bytes);
#else
    src->imm    = !in_vram(dev, src->p, s * h->h);
#endif
#if LVB_POOL
    /* an image of the CPU's memory that does not change (and fits); an
     * ARGB8888 one (4-byte aligned) wherever it is */
    if (src->imm && t->type == LV_DRAW_TASK_TYPE_IMAGE && u->drv->pool &&
        !(h->flags & LV_IMAGE_FLAGS_MODIFIABLE) && !(argb && ((uintptr_t) src->p & 3u)) &&
        pool_img_bytes((uint8_t) h->cf, h->w, h->h) <= u->drv->pool_bytes / 2u) {
        src->imm  = false;
        src->pool = true;
        return true;
    }
#endif
#if LVB_BLEND
    if (src->imm && h->cf != LV_COLOR_FORMAT_RGB565)
        return false;                           /* no alpha in the immediate source */
#endif
    return !src->imm || BLNS_HAS(dev, GPU_IMM);
}

#if LVB_BLEND
/* The alpha byte address of source pixel 'pa' of an RGB565A8 source */
static uint32_t a8_of(const blns_t *dev, const blit_src_t *src, blns_pa_t pa)
{
    return blns_alpha_of(pa, blns_vram_pa(dev, src->p), (uint32_t) ((uintptr_t) src->a8 - (uintptr_t) blns_vram8(dev)));
}
#endif

/* The part of the task's area drawn: in its clip area and its layer */
static bool blit_area(const lv_draw_task_t *t, lv_area_t *a)
{
    return lv_area_intersect(a, &t->area, &t->clip_area) && lv_area_intersect(a, a, &t->target_layer->buf_area);
}

/* Byte offset in the source of the first pixel of the drawn area 'a' */
static uint32_t imm_first(const lv_draw_task_t *t, const blit_src_t *src, const lv_area_t *a)
{
    return (uint32_t) (a->y1 - t->area.y1) * src->stride + (uint32_t) (a->x1 - t->area.x1) * 2u;
}

/* Whether the immediate source pushes the drawn area: its rows packed (one
 * row, or whole rows of an image without padding: the GPU takes the pixels
 * with no row stride), at most IMM_PX_MAX pixels, starting on a word, and
 * read with nothing past the source (an odd number of pixels reads the half
 * word after them) */
static bool imm_fits(const lv_draw_task_t *t, const blit_src_t *src)
{
    lv_area_t a;
    if (!blit_area(t, &a))
        return true;                    /* nothing drawn */
    const uint32_t w     = (uint32_t) lv_area_get_width(&a);
    const uint32_t n     = w * (uint32_t) lv_area_get_height(&a);
    const uint32_t first = imm_first(t, src, &a);
    return (n == w || (w == (uint32_t) lv_area_get_width(&t->area) && src->stride == w * 2u)) &&
           n <= IMM_PX_MAX && !(((uintptr_t) src->p + first) & 3u) && first + (n + 1u) / 2u * 4u <= src->bytes;
}

#if LVB_GLYPHS
/* A label the GPU draws: LVGL's bitmap fonts (fallbacks too), no rotation
 * nor outline */
static bool label_ok(const lv_belenos_unit_t *u, const lv_draw_label_dsc_t *d)
{
    if (!u->drv->glyph || !BLNS_HAS(u->drv->cfg.dev, GPU_BLEND) || u->drv->cfg.dev->nonblock ||
        d->opa <= LV_OPA_MIN || d->rotation != 0 || d->outline_stroke_width > 0 || !d->font)
        return false;
    for (const lv_font_t *f = d->font; f; f = f->fallback)
        if (f->get_glyph_bitmap != lv_font_get_bitmap_fmt_txt)
            return false;
    return true;
}
#endif

#if LVB_GRAD
/* A gradient the GPU draws (cfg.approx GRAD): horizontal or vertical,
 * opaque stops */
static bool grad_ok(const lv_belenos_unit_t *u, const lv_grad_dsc_t *g)
{
    if (!(u->approx & LV_BELENOS_APPROX_GRAD) || (g->dir != LV_GRAD_DIR_HOR && g->dir != LV_GRAD_DIR_VER) ||
        g->stops_count < 2u)
        return false;
    for (unsigned i = 0; i < g->stops_count; i++)
        if (g->stops[i].opa < LV_OPA_MAX || (i && g->stops[i].frac < g->stops[i - 1u].frac))
            return false;
    return true;
}
#endif


#if LVB_XFORM
/*------------------------------- transforms ---------------------------------*
 * LVGL's set-up of lv_draw_sw_transform (lv_draw_sw_transform.c) replicated:
 * the source position of destination pixel (x, y), image-local, is
 *     xs = x0_ups + ((sxy y) >> 8) + ((sxx x) >> 8)   (1/256 texel, + 0x80)
 * and ys likewise; the unit takes it as 256 x0_ups + sxy y + sxx x in
 * 1/65536 (without LVGL's two floors: approximate), seeds each tile from it
 * (blns_gpu_texrect_fx_xy), and, scaled without rotation, reproduces LVGL's
 * clamp of xs and ys to the last texel centre with a blit of constant u (v)
 * over the clamped columns (rows).
 *----------------------------------------------------------------------------*/
typedef struct {
    int32_t x0_ups, y0_ups;             /* LVGL's start (1/256 texel)            */
    int32_t sxx, sxy, syx, syy;         /* its steps (1/65536 texel per pixel)   */
    int32_t xc, yc;                     /* the first clamped column, row (no clamp: INT32_MAX) */
    int32_t xs_clamp, ys_clamp;         /* the clamped xs, ys (1/256)            */
} xform_t;

#define XF_STEP_MAX (16 * 65536 - 16)   /* the GPU's 5.11 steps: under 16 texels */

/* x >= 0 smallest with floor(s x / 256) > k (s > 0) */
static int32_t xform_first(int64_t k, int64_t s)
{
    const int64_t n = 256 * (k + 1);
    return (n <= 0) ? 0 : (int32_t) ((n + s - 1) / s);
}

static bool xform_set(const lv_draw_image_dsc_t *d, int32_t w, int32_t h, xform_t *x)
{
    const int32_t angle = -d->rotation;
    const int32_t lo = angle / 10, hi = lo + 1, rem = angle - lo * 10;
    int32_t sinma = (lv_trigo_sin((int16_t) lo) * (10 - rem) + lv_trigo_sin((int16_t) hi) * rem) / 10;
    int32_t cosma = (lv_trigo_sin((int16_t) (lo + 90)) * (10 - rem) + lv_trigo_sin((int16_t) (hi + 90)) * rem) / 10;
    sinma = sinma >> (LV_TRIGO_SHIFT - 10);
    cosma = cosma >> (LV_TRIGO_SHIFT - 10);
    if (angle == 0) {                           /* LVGL's exact values at 0 */
        sinma = 0;
        cosma = 1024;
    }
    if (d->scale_x <= 0 || d->scale_y <= 0)
        return false;
    x->sxx = (int32_t) (((int64_t) cosma * 16384) / d->scale_x);
    x->sxy = (int32_t) ((-(int64_t) sinma * 16384) / d->scale_x);
    x->syx = (int32_t) (((int64_t) sinma * 16384) / d->scale_y);
    x->syy = (int32_t) (((int64_t) cosma * 16384) / d->scale_y);
    const int64_t xin0 = -(int64_t) d->pivot.x, yin0 = -(int64_t) d->pivot.y;
    x->x0_ups = (int32_t) (((cosma * xin0 - sinma * yin0) * 64) / d->scale_x) + d->pivot.x * 256 + 0x80;
    x->y0_ups = (int32_t) (((sinma * xin0 + cosma * yin0) * 64) / d->scale_y) + d->pivot.y * 256 + 0x80;
    x->xc = x->yc = INT32_MAX;
    x->xs_clamp = (w - 1) * 256 + 0x80;
    x->ys_clamp = (h - 1) * 256 + 0x80;
    if (d->rotation == 0) {                     /* scaled only: sxy = syx = 0, sxx, syy > 0 */
        x->xc = xform_first((int64_t) x->xs_clamp - x->x0_ups, x->sxx);
        x->yc = xform_first((int64_t) x->ys_clamp - x->y0_ups, x->syy);
    }
    return x->sxx > -XF_STEP_MAX && x->sxx < XF_STEP_MAX && x->sxy > -XF_STEP_MAX && x->sxy < XF_STEP_MAX &&
           x->syx > -XF_STEP_MAX && x->syx < XF_STEP_MAX && x->syy > -XF_STEP_MAX && x->syy < XF_STEP_MAX;
}

/* A rotated or scaled image the GPU draws (cfg.approx TRANSFORM):
 * antialias, bilinear with the transparent border (blending); without it,
 * nearest (RGB565 pixels at full opacity need no blending). Its size: the
 * task's area (LVGL's src_w, src_h). Not a layer: LVGL renders a transformed
 * layer as ARGB8888 (its area is wider than its object's), which the GPU
 * does not read */
static bool xform_ok(const lv_belenos_unit_t *u, const blns_t *dev, const lv_draw_task_t *t, const blit_src_t *src)
{
    const lv_draw_image_dsc_t *d = t->draw_dsc;
    const int32_t              w = lv_area_get_width(&t->area), h = lv_area_get_height(&t->area);
    xform_t                    x;
    if (!(u->approx & LV_BELENOS_APPROX_TRANSFORM) || t->type != LV_DRAW_TASK_TYPE_IMAGE || d->tile || src->imm ||
        w > (int32_t) BLNS_GPU_TEXBOX_MAX ||
        h > (int32_t) BLNS_GPU_TEXBOX_MAX || !xform_set(d, w, h, &x))
        return false;
    if (d->antialias)
        return BLNS_HAS(dev, GPU_BILINEAR) && BLNS_HAS(dev, GPU_BLEND);
    return (SRC_CF(src) == LV_COLOR_FORMAT_RGB565 && d->opa >= LV_OPA_MAX) || BLNS_HAS(dev, GPU_BLEND);
}
#define XFORM_OK(u, dev, t, s) xform_ok(u, dev, t, s)
#else
#define XFORM_OK(u, dev, t, s) ((void) (s), false)
#endif

/* What the GPU draws as the software renderer does (bit for bit) without
 * blending: opaque plain fills, the straight parts of rounded ones, opaque
 * borders, and image or layer blits at full opacity with no transform,
 * recolour, mask or tiling (from the VRAM, or with the immediate source
 * from the CPU's memory); with the extensions, more (lv_belenos.h) */
#if LVB_BLEND
#define OPA_OK(u, o)        ((void) (u), opa_ok(dev, o))
#else
#define OPA_OK(u, o)        ((void) (u), (o) >= LV_OPA_MAX)
#endif
#if LVB_GRAD
#define GRAD_OK(u, dev, d)  ((d)->grad.dir == LV_GRAD_DIR_NONE || \
                             (BLNS_HAS(dev, GPU_GRAD) && (d)->opa >= LV_OPA_MAX && grad_ok(u, &(d)->grad)))
#else
#define GRAD_OK(u, dev, d)  ((d)->grad.dir == LV_GRAD_DIR_NONE)
#endif
#if LVB_CORNERS
#define CORNERS_OK(c, r, w) ((w) <= rout_of(c, r) && corners_ok(c, r))
#else
#define CORNERS_OK(c, r, w) false
#endif

static bool gpu_can(const lv_belenos_unit_t *u, const blns_t *dev, const lv_draw_task_t *t)
{
    lv_area_t a;
    /* (a transformed image draws its transformed area: _real_area) */
    if (!layer_in_vram(u, dev, t->target_layer) ||
        !lv_area_intersect(&a, (LVB_XFORM && t->type == LV_DRAW_TASK_TYPE_IMAGE) ? &t->_real_area : &t->area,
                           &t->clip_area))
        return false;
    switch (t->type) {
        case LV_DRAW_TASK_TYPE_FILL: {
            const lv_draw_fill_dsc_t *d = t->draw_dsc;
            return OPA_OK(u, d->opa) && GRAD_OK(u, dev, d) &&
                   (CORNERS_OK(&t->area, d->radius, 0) || clear_of_corners(&t->area, d->radius, &a));
        }
        case LV_DRAW_TASK_TYPE_BORDER: {
            const lv_draw_border_dsc_t *d = t->draw_dsc;
            /* the sides do not meet (else the software renderer's split differs) */
            return OPA_OK(u, d->opa) && d->side == LV_BORDER_SIDE_FULL && d->width > 0 &&
                   d->width * 2 < lv_area_get_width(&t->area) && d->width * 2 < lv_area_get_height(&t->area) &&
                   (CORNERS_OK(&t->area, d->radius, d->width) || clear_of_corners(&t->area, d->radius, &a));
        }
        case LV_DRAW_TASK_TYPE_IMAGE:
        case LV_DRAW_TASK_TYPE_LAYER: {
            const lv_draw_image_dsc_t *d = t->draw_dsc;
            blit_src_t src;
            if (LVB_XFORM && (d->rotation != 0 || d->scale_x != LV_SCALE_NONE || d->scale_y != LV_SCALE_NONE))
                return OPA_OK(u, d->opa) && d->recolor_opa <= LV_OPA_MIN && d->skew_x == 0 && d->skew_y == 0 &&
                       d->blend_mode == LV_BLEND_MODE_NORMAL && d->clip_radius == 0 && !d->bitmap_mask_src &&
                       !d->colorkey && blit_src(u, dev, t, &src) && XFORM_OK(u, dev, t, &src);
#if LVB_POOL
            /* tiles: copies from the VRAM or the pool */
            return OPA_OK(u, d->opa) && d->recolor_opa <= LV_OPA_MIN && d->rotation == 0 &&
                   d->scale_x == LV_SCALE_NONE && d->scale_y == LV_SCALE_NONE && d->skew_x == 0 &&
                   d->skew_y == 0 && d->blend_mode == LV_BLEND_MODE_NORMAL && d->clip_radius == 0 &&
                   !d->bitmap_mask_src && !d->colorkey && blit_src(u, dev, t, &src) &&
                   (d->tile ? !src.imm && !src.later : !src.imm || imm_fits(t, &src));
#else
            return OPA_OK(u, d->opa) && d->recolor_opa <= LV_OPA_MIN && d->rotation == 0 &&
                   d->scale_x == LV_SCALE_NONE && d->scale_y == LV_SCALE_NONE && d->skew_x == 0 &&
                   d->skew_y == 0 && d->blend_mode == LV_BLEND_MODE_NORMAL && !d->tile &&
                   d->clip_radius == 0 && !d->bitmap_mask_src && !d->colorkey &&
                   blit_src(u, dev, t, &src) && (!src.imm || imm_fits(t, &src));
#endif
        }
#if LVB_GLYPHS
        case LV_DRAW_TASK_TYPE_LABEL:
            return label_ok(u, t->draw_dsc);
#endif
        default:
            return false;
    }
}

/* The unit draws for its display only, while it is being refreshed */
static bool unit_on(const lv_belenos_unit_t *u)
{
    return u->drv && u->drv->disp && lv_refr_get_disp_refreshing() == u->drv->disp;
}

static int32_t unit_evaluate(lv_draw_unit_t *du, lv_draw_task_t *t)
{
    const lv_belenos_unit_t *u = (const lv_belenos_unit_t *) du;
    if (t->preference_score > UNIT_SCORE && unit_on(u) && u->drv->cfg.dev->gpu_on && gpu_can(u, u->drv->cfg.dev, t)) {
        t->preference_score       = UNIT_SCORE;
        t->preferred_draw_unit_id = (uint8_t) du->idx;
    }
    return 0;
}

/*------------------------------- GPU modes ----------------------------------*
 * Blending and gradients are GPU state the unit sets for a task and clears
 * before a plain one and at the end of each dispatch round (before its
 * fence): between rounds they are off, as the flush copy and every other
 * user of the GPU expect. After a fault they are not known: cleared again.
 * The unit blends with LVGL's rule (MIX5, blns_gpu_blend_rule): SET_ALPHA EN
 * with A = opa below LV_OPA_MAX (LVGL's threshold), EN off for a per-pixel
 * alpha or a coverage alone (ST_MIX); off, the rounded rule again (ST_OFF).
 *----------------------------------------------------------------------------*/
#if LVB_STATE
static blns_status_t set_alpha(lv_belenos_unit_t *u, uint16_t want)
{
#if LVB_BLEND
    if (u->alpha == want)
        return BLNS_OK;
    blns_t       *dev = u->drv->cfg.dev;
    blns_status_t st  = blns_gpu_blend_rule(dev, want == ST_OFF ? BLNS_MIX_ROUND : BLNS_MIX5);
    if (st == BLNS_OK)
        st = blns_gpu_alpha(dev, want < ST_OFF, (uint8_t) want);
    if (st == BLNS_OK)
        u->alpha = want;
    return st;
#else
    (void) u;
    (void) want;
    return BLNS_OK;
#endif
}

static blns_status_t grad_off(lv_belenos_unit_t *u)
{
#if LVB_GRAD
    if (u->grad == ST_OFF)
        return BLNS_OK;
    const blns_status_t st = blns_gpu_gradient(u->drv->cfg.dev, false, 0u, false, 0);
    if (st == BLNS_OK)
        u->grad = ST_OFF;
    return st;
#else
    (void) u;
    return BLNS_OK;
#endif
}

/* The modes for a draw at opacity 'opa', no gradient */
static blns_status_t set_opa(lv_belenos_unit_t *u, lv_opa_t opa)
{
    blns_status_t st = grad_off(u);
    if (st == BLNS_OK)
        st = set_alpha(u, opa >= LV_OPA_MAX ? ST_OFF : opa);
    return st;
}

/* Both modes off: false when they could not be pushed */
static bool unit_plain(lv_belenos_unit_t *u)
{
    return set_opa(u, LV_OPA_COVER) == BLNS_OK;
}
#endif

/*------------------------------- pushing ------------------------------------*/

/* The surface of the layer at (x, y) */
static blns_surf_t layer_at(const blns_t *dev, const lv_layer_t *l, int32_t x, int32_t y)
{
    const uint16_t    pitch = (uint16_t) (l->draw_buf->header.stride / 2u);
    const blns_surf_t d     = { blns_vram_pa(dev, l->draw_buf->data) + (uint32_t) (y - l->buf_area.y1) * pitch +
                                (uint32_t) (x - l->buf_area.x1), pitch, BLNS_SWAP_NONE };
    return d;
}

/* Fill the part of 'r' in the task's clip area */
static blns_status_t gpu_rect(blns_t *dev, const lv_draw_task_t *t, const lv_area_t *r, uint16_t c)
{
    const lv_layer_t *l = t->target_layer;
    lv_area_t         a;
    if (!lv_area_intersect(&a, r, &t->clip_area) || !lv_area_intersect(&a, &a, &l->buf_area))
        return BLNS_OK;
    const uint16_t    pitch = (uint16_t) (l->draw_buf->header.stride / 2u);
    const blns_surf_t d = { blns_vram_pa(dev, l->draw_buf->data) + (uint32_t) (a.y1 - l->buf_area.y1) * pitch +
                            (uint32_t) (a.x1 - l->buf_area.x1), pitch, BLNS_SWAP_NONE };
    return blns_gpu_fill(dev, &d, (uint16_t) lv_area_get_width(&a), (uint16_t) lv_area_get_height(&a), c,
                         BLNS_ROP_S);
}

#if LVB_CPU
static void fail(lv_belenos_unit_t *u, blns_status_t st);

/* The CPU draws in the task's layer now (a part of a task, or a task the
 * GPU cannot draw after all): what the GPU has queued that meets 'a' must
 * be drawn first. Not OK: the GPU stopped (the caller fails the batches) */
static blns_status_t cpu_turn(lv_belenos_unit_t *u, const lv_draw_task_t *t, const lv_area_t *a, unsigned n)
{
    if (!a)                                     /* (a glyph: after the label's own too) */
        return blns_gpu_wait(u->drv->cfg.dev);
    /* the queued tasks are before t (a later one LVGL gave this unit first
     * is independent of t: it does not meet it) */
    uint32_t left = u->queued;
    for (const lv_draw_task_t *q = t->target_layer->draw_task_head; q && q != t && left; q = q->next)
        if (q->state == LV_DRAW_TASK_STATE_QUEUED && q->draw_unit == &u->base) {
            left--;
            for (unsigned i = 0; i < n; i++) {
                lv_area_t x;
                if (lv_area_intersect(&x, &q->_real_area, &a[i]))
                    return blns_gpu_wait(u->drv->cfg.dev);
            }
        }
    return BLNS_OK;
}
#endif

#if LVB_CORNERS
/* The task's area in the clip area and its layer: the four rout x rout
 * corner squares (corners) or the straight parts between them (bands: the
 * rectangles the GPU draws, plain pixels), drawn by the CPU (the software
 * renderer's function, clipped to each). The corners are drawn when the
 * task is pushed, after the GPU has drawn what is queued over them (after a
 * fault, the CPU has drawn it: fail); after a fault the CPU draws the bands
 * again, not the corners (their anti-aliased edges would blend twice) */
static void rect_parts(const lv_draw_task_t *t, int32_t rout, lv_area_t r[4], unsigned *n);

static void cpu_parts(lv_draw_task_t *t, const lv_area_t *q, unsigned n)
{
    const lv_area_t clip = t->clip_area;
    for (unsigned i = 0; i < n; i++) {
        lv_area_t a;
        if (!lv_area_intersect(&a, &q[i], &clip) || !lv_area_intersect(&a, &a, &t->target_layer->buf_area))
            continue;
        t->clip_area = a;
        if (t->type == LV_DRAW_TASK_TYPE_FILL)
            lv_draw_sw_fill(t, t->draw_dsc, &t->area);
        else
            lv_draw_sw_border(t, t->draw_dsc, &t->area);
    }
    t->clip_area = clip;
}

static void cpu_corners(lv_belenos_unit_t *u, lv_draw_task_t *t, int32_t rout)
{
    const lv_area_t *c    = &t->area;
    const lv_area_t  q[4] = {
        { c->x1, c->y1, c->x1 + rout - 1, c->y1 + rout - 1 }, { c->x2 - rout + 1, c->y1, c->x2, c->y1 + rout - 1 },
        { c->x1, c->y2 - rout + 1, c->x1 + rout - 1, c->y2 }, { c->x2 - rout + 1, c->y2 - rout + 1, c->x2, c->y2 },
    };
    const blns_status_t st = cpu_turn(u, t, q, 4u);
    if (st != BLNS_OK)
        fail(u, st);                            /* the CPU draws what is queued first */
    cpu_parts(t, q, 4u);
}

/* The corners of a FILL or BORDER the unit splits: 0 (none) or rout */
static int32_t task_rout(const lv_draw_task_t *t)
{
    const int32_t radius = t->type == LV_DRAW_TASK_TYPE_FILL ? ((const lv_draw_fill_dsc_t *) t->draw_dsc)->radius
                         : t->type == LV_DRAW_TASK_TYPE_BORDER ? ((const lv_draw_border_dsc_t *) t->draw_dsc)->radius : 0;
    lv_area_t a;
    if (!radius || !lv_area_intersect(&a, &t->area, &t->clip_area) || clear_of_corners(&t->area, radius, &a))
        return 0;
    return rout_of(&t->area, radius);
}
#endif

#if LVB_GRAD
/* A gradient fill of the part of 'r' in the task's clip area: LVGL's
 * colour at its first row (vertical) or column (horizontal), then the GPU's
 * per-channel ramp from it towards LVGL's colour at the end of the stop
 * interval it is in, one rectangle per interval */
static uint16_t grad_colour(const lv_grad_dsc_t *g, int32_t range, int32_t i)
{
    lv_color_t c;
    lv_opa_t   o;
    lv_draw_sw_grad_color_calculate(g, range, i, &c, &o);
    return lv_color_to_u16(c);
}

/* A run of the gradient from row or column i (at most to hi): LVGL's colour
 * at i, and the GPU's ramp towards LVGL's colour just past the run, in 1/64
 * of a field per row or column. A run stays in one stop interval and spans
 * GRAD_RUN at most (the ramp's rounding drifts less than half a field); a
 * ramp steeper than SET_GRAD_RGB takes (8 fields a step) is one row or
 * column (a plain fill) */
#define GRAD_RUN 64

typedef struct {
    int32_t  end;                       /* the run's last row or column     */
    uint16_t f0;                        /* its colour at i                  */
    int      d[3];                      /* R, G, B steps (0: a plain fill)  */
} grad_run_t;

static void grad_run(const lv_grad_dsc_t *g, int32_t range, int32_t i, int32_t hi, grad_run_t *run)
{
    int32_t p0 = INT32_MIN, p1 = INT32_MAX;     /* the stop interval of i, as LVGL finds it */
    for (unsigned k = 0; k < g->stops_count; k++) {
        const int32_t s = (g->stops[k].frac * range) >> 8;
        if (s <= i)
            p0 = s;
        else {
            p1 = s;
            break;
        }
    }
    run->f0   = grad_colour(g, range, i);
    run->d[0] = run->d[1] = run->d[2] = 0;
    if (p0 == INT32_MIN || p1 == INT32_MAX) {   /* before the first stop, after the last: plain */
        /* (at the last stop itself LVGL may take the first stop's colour:
         * stops at one position) */
        run->end = (p1 != INT32_MAX) ? LV_MIN(hi, p1 - 1) : (i == p0) ? i : hi;
        return;
    }
    run->end = LV_MIN(LV_MIN(hi, p1 - 1), i + GRAD_RUN - 1);
    const int32_t  len = run->end + 1 - i;
    const uint16_t f1  = grad_colour(g, range, run->end + 1);
    static const uint8_t sh[3] = { 11, 5, 0 }, mk[3] = { 0x1F, 0x3F, 0x1F };
    for (unsigned c = 0; c < 3u; c++) {
        const int32_t num = ((int32_t) ((f1 >> sh[c]) & mk[c]) - (int32_t) ((run->f0 >> sh[c]) & mk[c])) * 64;
        const int32_t d   = (num >= 0) ? (num + len / 2) / len : -((-num + len / 2) / len);
        if (d < -512 || d > 511) {              /* too steep: this row or column alone, plain */
            run->end  = i;
            run->d[0] = run->d[1] = run->d[2] = 0;
            return;
        }
        run->d[c] = (int) d;
    }
}

static blns_status_t gpu_grad_rect(lv_belenos_unit_t *u, const lv_draw_task_t *t, const lv_area_t *r)
{
    blns_t                   *dev = u->drv->cfg.dev;
    const lv_draw_fill_dsc_t *d   = t->draw_dsc;
    const lv_grad_dsc_t      *g   = &d->grad;
    const bool                ver = g->dir == LV_GRAD_DIR_VER;
    const lv_area_t          *c   = &t->area;
    const int32_t             range = ver ? lv_area_get_height(c) : lv_area_get_width(c);
    const int32_t             base  = ver ? c->y1 : c->x1;
    lv_area_t                 a;
    if (!lv_area_intersect(&a, r, &t->clip_area) || !lv_area_intersect(&a, &a, &t->target_layer->buf_area))
        return BLNS_OK;
    const int32_t hi = (ver ? a.y2 : a.x2) - base;
    for (int32_t i = (ver ? a.y1 : a.x1) - base; i <= hi;) {
        grad_run_t run;
        grad_run(g, range, i, hi, &run);
        lv_area_t b = a;
        if (ver) {
            b.y1 = base + i;
            b.y2 = base + run.end;
        } else {
            b.x1 = base + i;
            b.x2 = base + run.end;
        }
        blns_status_t st = set_alpha(u, ST_OFF);
        if (st == BLNS_OK) {
            if (run.d[0] || run.d[1] || run.d[2]) {
                st = blns_gpu_gradient_rgb(dev, true, 1u, !ver, run.d[0], run.d[1], run.d[2]);
                u->grad = (st == BLNS_OK) ? 0u : ST_UNKNOWN;
            } else {
                st = grad_off(u);
            }
        }
        if (st == BLNS_OK) {
            const blns_surf_t s = layer_at(dev, t->target_layer, b.x1, b.y1);
            st = blns_gpu_fill(dev, &s, (uint16_t) lv_area_get_width(&b), (uint16_t) lv_area_get_height(&b), run.f0,
                               BLNS_ROP_S);
        }
        if (st != BLNS_OK)
            return st;
        i = run.end + 1;
    }
    return BLNS_OK;
}
#endif

#if LVB_RECT
/* One rectangle of a FILL or BORDER task ('r', clipped here), at the task's opacity */
static blns_status_t task_rect(lv_belenos_unit_t *u, const lv_draw_task_t *t, const lv_area_t *r, lv_color_t col,
                               lv_opa_t opa)
{
#if LVB_GRAD
    if (t->type == LV_DRAW_TASK_TYPE_FILL && ((const lv_draw_fill_dsc_t *) t->draw_dsc)->grad.dir != LV_GRAD_DIR_NONE)
        return gpu_grad_rect(u, t, r);
#endif
#if LVB_STATE
    const blns_status_t st = set_opa(u, opa);
    if (st != BLNS_OK)
        return st;
#else
    (void) opa;
#endif
    return gpu_rect(u->drv->cfg.dev, t, r, lv_color_to_u16(col));
}
#endif

#if LVB_POOL
/* The tiles of a tiled image (LVGL's lv_draw_image_tiled_helper): tile k
 * from 'tile', its area in *a; false past the last */
static bool tile_at(const lv_draw_task_t *t, const blit_src_t *src, unsigned k, lv_area_t *a)
{
    const lv_draw_image_dsc_t *d = t->draw_dsc;
    const lv_area_t           *c = &t->area;
    const lv_area_t o = (lv_area_get_width(&d->image_area) >= 0) ? d->image_area : *c;
    const int32_t   nx = (c->x2 - o.x1) / src->w + 1;
    if (c->x2 < o.x1 || c->y2 < o.y1)
        return false;
    const int32_t ty = (int32_t) k / nx, tx = (int32_t) k % nx;
    a->x1 = o.x1 + tx * src->w;
    a->y1 = o.y1 + ty * src->h;
    a->x2 = a->x1 + src->w - 1;
    a->y2 = a->y1 + src->h - 1;
    return a->y1 <= c->y2;
}
#endif

/* The drawn area 'a' of a blit, its source's (0, 0) at 'o' */
static blns_status_t blit_one(blns_t *dev, const lv_draw_task_t *t, const blit_src_t *src, const lv_area_t *a,
                              const lv_area_t *o)
{
    const uint16_t    w = (uint16_t) lv_area_get_width(a);
    const uint16_t    h = (uint16_t) lv_area_get_height(a);
    const blns_surf_t d = layer_at(dev, t->target_layer, a->x1, a->y1);
    if (src->imm) {                             /* pushed through GPU_CMD */
        /* a timeout in its data discards the blit (the stream in
         * step): pushed again whole, as with no room (BLNS_ROP_S) */
        return blns_gpu_blit_imm(dev, &d, w, h, &plain_blit, (const uint32_t *) (const void *) (src->p + imm_first(t, src, a)));
    }
    const uint16_t    sp = (uint16_t) (src->stride / 2u);
    const blns_surf_t s  = { blns_vram_pa(dev, src->p) + (uint32_t) (a->y1 - o->y1) * sp + (uint32_t) (a->x1 - o->x1),
                             sp, BLNS_SWAP_NONE };
#if LVB_BLEND
    if (src->a8) {                              /* RGB565A8: the alpha of its first pixel */
        const blns_status_t st = blns_gpu_alpha_plane(dev, a8_of(dev, src, s.addr));
        if (st != BLNS_OK)
            return st;
        static const blns_blit_t opt = { .src_alpha = true };
        return blns_gpu_blit(dev, &s, &d, w, h, &opt);
    }
#endif
    return blns_gpu_blit(dev, &s, &d, w, h, &plain_blit);
}

/* The source as the GPU reads it: staged in the pool now if it must be
 * (BLNS_ERR_ABSENT: it does not fit, the CPU draws it), RGB565 or RGB565A8 */
static blns_status_t blit_prep(lv_belenos_unit_t *u, const lv_draw_task_t *t, blit_src_t *src)
{
    (void) u;
    (void) t;
    (void) src;
#if LVB_POOL
    if (src->pool) {
        const uint8_t *p = pool_image(u->drv, ((const lv_draw_image_dsc_t *) t->draw_dsc)->src, src->stride);
        if (!p)
            return BLNS_ERR_ABSENT;
        const uint32_t pitch = pool_pitch(SRC_CF(src), src->w);
        src->p      = p;
        src->stride = pitch * 2u;
#if LVB_BLEND
        if (src->cf != LV_COLOR_FORMAT_RGB565)
            src->a8 = p + pitch * 2u * src->h;
#endif
    }
#endif
    return BLNS_OK;
}

#if LVB_STATE
/* The SET_ALPHA state of an image draw: per-pixel alpha (RGB565A8, or a
 * transform's taps: MIX5), and EN below LV_OPA_MAX */
static uint16_t img_alpha(lv_opa_t opa, bool alpha)
{
    return (opa < LV_OPA_MAX) ? opa : alpha ? ST_MIX : ST_OFF;
}
#endif

/* An image or layer blit: tile 'piece' on (one, without tiling) */
static blns_status_t gpu_blit(lv_belenos_unit_t *u, blns_t *dev, lv_draw_task_t *t, unsigned *piece)
{
    const lv_draw_image_dsc_t *dd  = t->draw_dsc;
    const lv_layer_t          *l   = t->target_layer;
    const lv_area_t           *c   = &t->area;
    blit_src_t                 src;
    lv_area_t                  a;
    (void) dd;
    if (!blit_src(u, dev, t, &src))
#if LVB_POOL
        return (t->type == LV_DRAW_TASK_TYPE_LAYER && !((const lv_layer_t *) dd->src)->draw_buf) ? BLNS_OK
               : BLNS_ERR_ABSENT;               /* a layer left empty; else no source after all: the CPU */
#else
        return BLNS_OK;                         /* a layer left empty, nothing drawn */
#endif
#if LVB_POOL
    if (src.later)                              /* its children drew nothing in it */
        return BLNS_OK;
    if (src.imm && (dd->tile || !imm_fits(t, &src)))
        return BLNS_ERR_ABSENT;                 /* a layer that went to RAM: the CPU */
#endif
    blns_status_t st = blit_prep(u, t, &src);   /* (does not fit: the CPU) */
    if (st != BLNS_OK)
        return st;
#if LVB_STATE
    st = grad_off(u);
    if (st == BLNS_OK)
        st = set_alpha(u, img_alpha(dd->opa, SRC_A8(&src) != NULL));
    if (st != BLNS_OK)
        return st;
#endif
#if LVB_POOL
    lv_area_t tile = *c;
    for (;; (*piece)++) {
        if (dd->tile) {
            if (!tile_at(t, &src, *piece, &tile))
                return BLNS_OK;
            if (!lv_area_intersect(&a, &tile, c) || !lv_area_intersect(&a, &a, &t->clip_area) ||
                !lv_area_intersect(&a, &a, &l->buf_area))
                continue;
        } else if (*piece || !blit_area(t, &a)) {
            return BLNS_OK;
        }
        const blns_status_t bs = blit_one(dev, t, &src, &a, &tile);
        if (bs != BLNS_OK || src.imm)
            return bs;
    }
#else
    (void) piece;
    (void) l;
    if (!blit_area(t, &a))
        return BLNS_OK;
    return blit_one(dev, t, &src, &a, c);
#endif
}


#if LVB_XFORM
/* One rectangle of a transformed image's walk: its first pixel and size
 * (image-local), (u, v) there and the steps (1/65536 texel) */
typedef struct {
    int32_t x, y, w, h;
    int64_t u, v;
    int32_t du, dv, du_r, dv_r;
} xf_rect_t;

/* The rectangles of the drawn area 'a' (image-local): the walk, and with
 * LVGL's clamp (scaled only) the clamped columns and rows (constant u, v)
 * and their corner */
static unsigned xform_rects(const xform_t *x, const lv_area_t *a, xf_rect_t r[4])
{
    const int32_t xs[3] = { a->x1, LV_CLAMP(a->x1, x->xc, a->x2 + 1), a->x2 + 1 };
    const int32_t ys[3] = { a->y1, LV_CLAMP(a->y1, x->yc, a->y2 + 1), a->y2 + 1 };
    unsigned      n = 0;
    for (int j = 0; j < 2; j++)
        for (int i = 0; i < 2; i++) {
            if (xs[i + 1] <= xs[i] || ys[j + 1] <= ys[j])
                continue;
            xf_rect_t *q = &r[n++];
            q->x    = xs[i];
            q->y    = ys[j];
            q->w    = xs[i + 1] - xs[i];
            q->h    = ys[j + 1] - ys[j];
            q->du   = i ? 0 : x->sxx;
            q->du_r = i ? 0 : x->sxy;
            q->dv   = j ? 0 : x->syx;
            q->dv_r = j ? 0 : x->syy;
            q->u    = i ? (int64_t) x->xs_clamp * 256
                        : (int64_t) x->x0_ups * 256 + (int64_t) x->sxy * q->y + (int64_t) x->sxx * q->x;
            q->v    = j ? (int64_t) x->ys_clamp * 256
                        : (int64_t) x->y0_ups * 256 + (int64_t) x->syy * q->y + (int64_t) x->syx * q->x;
        }
    return n;
}

#define XF_TILE 64

/* A rotated or scaled image: the texture (BOUND, the image's box), its
 * filter (bilinear and the transparent border with antialias), then one
 * EXEC_TEXRECT per tile of XF_TILE x XF_TILE at most, tile 'piece' on, each
 * seeded from LVGL's model; the area drawn: the transformed area in the clip
 * area and the layer (outside the image BOUND skips the pixels) */
static blns_status_t gpu_xform(lv_belenos_unit_t *u, blns_t *dev, lv_draw_task_t *t, unsigned *piece)
{
    const lv_draw_image_dsc_t *d = t->draw_dsc;
    const lv_layer_t          *l = t->target_layer;
    const int32_t              w = lv_area_get_width(&t->area), h = lv_area_get_height(&t->area);
    blit_src_t                 src;
    xform_t                    x;
    lv_area_t                  a;
    if (!blit_src(u, dev, t, &src) || src.imm || !xform_set(d, w, h, &x))
        return BLNS_ERR_ABSENT;                 /* (the CPU) */
    blns_status_t st = blit_prep(u, t, &src);
    if (st != BLNS_OK)
        return st;
    if (!lv_area_intersect(&a, &t->_real_area, &t->clip_area) || !lv_area_intersect(&a, &a, &l->buf_area))
        return BLNS_OK;
    const bool     aa    = d->antialias, a8 = SRC_A8(&src) != NULL;
    const uint16_t pitch = (uint16_t) (l->draw_buf->header.stride / 2u);
    const blns_tex_t tx  = { .addr = blns_vram_pa(dev, src.p), .pitch = (uint16_t) (src.stride / 2u),
                             .free_pitch = true, .bound = true, .box_w = (uint16_t) w, .box_h = (uint16_t) h,
                             .src_alpha = a8, .bilinear = aa, .border_transparent = aa };
    st = grad_off(u);
    if (st == BLNS_OK)
        st = set_alpha(u, img_alpha(d->opa, aa || a8));
#if LVB_BLEND
    if (st == BLNS_OK && a8)
        st = blns_gpu_alpha_plane(dev, a8_of(dev, &src, tx.addr));
#endif
    if (st == BLNS_OK)
        st = blns_gpu_xy_begin(dev, blns_vram_pa(dev, l->draw_buf->data), pitch, 0u);
    if (st == BLNS_OK)
        st = blns_gpu_clip(dev, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX, BLNS_GPU_XY_MAX);
    if (st == BLNS_OK)
        st = blns_gpu_tex_set(dev, &tx, 0u);
    if (st != BLNS_OK)
        return st;
    lv_area_move(&a, -t->area.x1, -t->area.y1);         /* image-local, as LVGL's */
    xf_rect_t      r[4];
    const unsigned n = xform_rects(&x, &a, r);
    unsigned       k = 0;
    for (unsigned i = 0; i < n; i++)
        for (int32_t ty = 0; ty < r[i].h; ty += XF_TILE)
            for (int32_t tx0 = 0; tx0 < r[i].w; tx0 += XF_TILE, k++) {
                if (k < *piece)
                    continue;                   /* drawn already */
                const xf_rect_t *q = &r[i];
                st = blns_gpu_texrect_fx_xy(dev, t->area.x1 + q->x + tx0 - l->buf_area.x1,
                                            t->area.y1 + q->y + ty - l->buf_area.y1,
                                            (uint16_t) LV_MIN(XF_TILE, q->w - tx0), (uint16_t) LV_MIN(XF_TILE, q->h - ty),
                                            q->u + (int64_t) q->du * tx0 + (int64_t) q->du_r * ty,
                                            q->v + (int64_t) q->dv * tx0 + (int64_t) q->dv_r * ty,
                                            q->du, q->dv, q->du_r, q->dv_r);
                if (st != BLNS_OK)
                    return st;
                *piece = k + 1u;
            }
    return BLNS_OK;
}
#endif

#if LVB_GLYPHS
/*------------------------------- labels -------------------------------------*
 * The unit iterates the label's glyphs as the software renderer does
 * (lv_draw_label_iterate_characters) and draws each with one EXEC_EXPAND
 * MASK from its coverage mask, staged in the pool at its first use: 4 bpp
 * when LVGL's A8 values are multiples of 17 (A1, A2, A4 fonts), else 8 bpp;
 * the GPU's alpha is the coverage (17 v at 4 bpp), times the label's
 * opacity. The fills of the label (selection, underline, strike-through)
 * are GPU fills. A glyph that does not fit in the pool, and a placeholder,
 * are drawn by the CPU (cpu_turn first). A label cut by a TIMEOUT goes on
 * at the glyph after the last one sent (the iteration from the start, the
 * glyphs before it skipped).
 *----------------------------------------------------------------------------*/
typedef struct {
    lv_belenos_unit_t *u;
    unsigned           skip;            /* callbacks done before (a resumed label) */
    unsigned           n;               /* callbacks done                        */
    blns_status_t      st;              /* the first that was not OK: the rest skipped */
    /* the expansion session as last begun: size, source pitch, depth, colour */
    uint32_t           ses;
    uint16_t           ses_c;
    uint16_t           pitch;
} label_ctx_t;

static label_ctx_t *label_ctx;          /* the label being pushed (the callback has no context) */

static uint32_t glyph_hash(const lv_font_t *f, uint32_t id)
{
    return (((uint32_t) (uintptr_t) f >> 2) ^ (id * 0x9E3779B1u)) >> 8 & (GLYPH_SLOTS - 1u);
}

static pool_glyph_t *glyph_find(lv_belenos_t *drv, const lv_font_t *f, uint32_t id)
{
    for (uint32_t i = glyph_hash(f, id);; i = (i + 1u) & (GLYPH_SLOTS - 1u)) {
        pool_glyph_t *e = &drv->glyph[i];
        if (!e->font || (e->font == f && e->id == id))
            return e;
    }
}

/* Room for a glyph mask in the pool (runs of GLYPH_RUN bytes, a larger mask
 * alone): NULL when it does not fit */
static uint8_t *glyph_room(lv_belenos_t *drv, uint32_t bytes)
{
    bytes = (bytes + 3u) & ~3u;
    if (bytes > GLYPH_RUN / 4u)
        return pool_cache(drv, bytes);
    if (drv->run_left < bytes) {
        uint8_t *r = pool_cache(drv, GLYPH_RUN);   /* (may drop the cache: run reset) */
        if (!r)
            return NULL;
        drv->run      = r;
        drv->run_left = GLYPH_RUN;
    }
    uint8_t *p = drv->run;
    drv->run      += bytes;
    drv->run_left -= bytes;
    return p;
}

/* The glyph's mask in the pool (staged now from LVGL's A8 bitmap if it is
 * not): NULL when it does not fit or LVGL has no bitmap for it */
static const pool_glyph_t *glyph_get(lv_belenos_t *drv, lv_draw_glyph_dsc_t *g)
{
    lv_font_glyph_dsc_t *gd = g->g;
    pool_glyph_t        *e  = glyph_find(drv, gd->resolved_font, gd->gid.index);
    if (e->font)
        return e;
    lv_draw_buf_t *b = g->_draw_buf;
    gd->req_raw_bitmap = 0;
    if (!b || !lv_font_get_glyph_bitmap(gd, b))
        return NULL;
    const uint32_t w = gd->box_w, h = gd->box_h, stride = b->header.stride;
    const uint8_t *a8 = b->data;
    bool           q4 = true;               /* every value a multiple of 17: 4 bpp */
    for (uint32_t y = 0; y < h && q4; y++)
        for (uint32_t x = 0; x < w; x++)
            if (a8[y * stride + x] % 17u) {
                q4 = false;
                break;
            }
    if (drv->nglyph >= GLYPH_SLOTS * 3u / 4u && !pool_drop(drv))
        return NULL;
    const uint32_t bytes = q4 ? (w * h + 1u) / 2u : w * h;
    uint8_t       *px    = glyph_room(drv, bytes);
    if (!px)
        return NULL;
    /* packed, LSB first, written a word at a time */
    volatile uint32_t *dst = (volatile uint32_t *) (void *) px;
    uint32_t           word = 0, bits = 0;
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) {
            const uint32_t v = a8[y * stride + x];
            word |= (q4 ? v / 17u : v) << bits;
            bits += q4 ? 4u : 8u;
            if (bits == 32u) {
                *dst++ = word;
                word   = 0;
                bits   = 0;
            }
        }
    if (bits)
        *dst = word;
    BLNS_WMB();
    e = glyph_find(drv, gd->resolved_font, gd->gid.index);    /* (the table may have been dropped) */
    e->font  = gd->resolved_font;
    e->id    = gd->gid.index;
    e->px    = px;
    e->w     = (uint16_t) w;
    e->h     = (uint16_t) h;
    e->depth = q4 ? BLNS_EXP_4BPP : BLNS_EXP_8BPP;
    drv->nglyph++;
    return e;
}

/* A glyph the CPU draws: the software renderer's way (lv_draw_sw_letter.c) */
static blns_status_t cpu_glyph(lv_belenos_unit_t *u, lv_draw_task_t *t, lv_draw_glyph_dsc_t *g)
{
    blns_status_t st = cpu_turn(u, t, NULL, 0u);
    if (st != BLNS_OK)
        return st;
    if (g->format == LV_FONT_GLYPH_FORMAT_NONE) {
#if LV_USE_FONT_PLACEHOLDER
        if (g->bg_coords) {
            lv_draw_border_dsc_t bd;
            lv_draw_border_dsc_init(&bd);
            bd.opa   = g->opa;
            bd.color = g->color;
            bd.width = 1;
            lv_draw_sw_border(t, &bd, g->bg_coords);
        }
#endif
        return BLNS_OK;
    }
    g->g->req_raw_bitmap = 0;
    const lv_draw_buf_t *b = lv_font_get_glyph_bitmap(g->g, g->_draw_buf) ? g->_draw_buf : NULL;
    if (!b)
        return BLNS_OK;                         /* LVGL logs it and draws nothing */
    lv_area_t mask_area = *g->letter_coords;
    mask_area.x2 = mask_area.x1 + (int32_t) lv_draw_buf_width_to_stride((uint32_t) lv_area_get_width(&mask_area),
                                                                        LV_COLOR_FORMAT_A8) - 1;
    lv_draw_sw_blend_dsc_t bd;
    lv_memzero(&bd, sizeof bd);
    bd.color       = g->color;
    bd.opa         = g->opa;
    bd.mask_buf    = b->data;
    bd.mask_area   = &mask_area;
    bd.mask_stride = (int32_t) b->header.stride;
    bd.blend_area  = g->letter_coords;
    bd.mask_res    = LV_DRAW_SW_MASK_RES_CHANGED;
    lv_draw_sw_blend(t, &bd);
    return BLNS_OK;
}

static blns_status_t gpu_glyph(label_ctx_t *c, lv_draw_task_t *t, lv_draw_glyph_dsc_t *g)
{
    lv_belenos_unit_t *u   = c->u;
    blns_t            *dev = u->drv->cfg.dev;
    const lv_layer_t  *l   = t->target_layer;
    lv_area_t          a;
    if (g->format < LV_FONT_GLYPH_FORMAT_A1 || g->format > LV_FONT_GLYPH_FORMAT_A8)
        return cpu_glyph(u, t, g);              /* none: the placeholder */
    if (!lv_area_intersect(&a, g->letter_coords, &t->clip_area) || !lv_area_intersect(&a, &a, &l->buf_area))
        return BLNS_OK;
    const pool_glyph_t *e = glyph_get(u->drv, g);
    if (!e)
        return cpu_glyph(u, t, g);
    blns_status_t st = set_alpha(u, g->opa >= LV_OPA_MAX ? ST_MIX : g->opa);
    if (st != BLNS_OK)
        return st;
    const uint32_t    bpp = (e->depth == BLNS_EXP_4BPP) ? 4u : 8u;
    const uint32_t    src = (uint32_t) (e->px - blns_vram8(dev)) * 8u / bpp +
                            (uint32_t) (a.y1 - g->letter_coords->y1) * e->w + (uint32_t) (a.x1 - g->letter_coords->x1);
    const blns_surf_t d   = layer_at(dev, l, a.x1, a.y1);
    const uint16_t    w   = (uint16_t) lv_area_get_width(&a), h = (uint16_t) lv_area_get_height(&a);
    const uint32_t    ses = (uint32_t) w | (uint32_t) h << 12 | (uint32_t) e->w << 24 | (uint32_t) e->depth << 30;
    const uint16_t    col = lv_color_to_u16(g->color);
    if (ses != c->ses || col != c->ses_c || d.pitch != c->pitch) {
        const blns_expand_t x = { .width = w, .height = h, .src_pitch = e->w, .depth = e->depth, .mask = true };
        st = blns_gpu_expand_begin(dev, &x, d.addr, d.pitch, col, 0u);
        if (st != BLNS_OK)
            return st;
        c->ses   = ses;
        c->ses_c = col;
        c->pitch = d.pitch;
    }
    return blns_gpu_expand(dev, src, d.addr);
}

static void label_cb(lv_draw_task_t *t, lv_draw_glyph_dsc_t *g, lv_draw_fill_dsc_t *f, const lv_area_t *fa)
{
    label_ctx_t *c = label_ctx;
    if (c->st != BLNS_OK || c->n++ < c->skip)
        return;
    blns_status_t st = BLNS_OK;
    if (g)
        st = gpu_glyph(c, t, g);
    else if (f && fa && f->opa > LV_OPA_MIN)
        st = task_rect(c->u, t, fa, f->color, f->opa);
    if (st != BLNS_OK) {
        c->st = st;
        c->n--;                                 /* not done: from there on the next time */
    }
}

static blns_status_t gpu_label(lv_belenos_unit_t *u, lv_draw_task_t *t, unsigned *piece)
{
    label_ctx_t c = { .u = u, .skip = *piece, .st = BLNS_OK, .ses = ~0u };
    label_ctx = &c;
    lv_draw_label_iterate_characters(t, t->draw_dsc, &t->area, label_cb);
    label_ctx = NULL;
    *piece = c.n;
    return c.st;
}
#endif

#if LVB_RECT
/* The rectangles of a FILL or BORDER, without the corners rout x rout
 * (rout 0: none). FILL: one rectangle, or the middle band and the top and
 * bottom ones between the corners. BORDER: top, bottom, left, right as the
 * software renderer splits it, shortened by the corners */
static void rect_parts(const lv_draw_task_t *t, int32_t rout, lv_area_t r[4], unsigned *n)
{
    const lv_area_t *c = &t->area;
    if (t->type == LV_DRAW_TASK_TYPE_FILL) {
        if (!rout) {
            r[0] = *c;
            *n   = 1;
            return;
        }
        r[0] = (lv_area_t) { c->x1, c->y1 + rout, c->x2, c->y2 - rout };
        r[1] = (lv_area_t) { c->x1 + rout, c->y1, c->x2 - rout, c->y1 + rout - 1 };
        r[2] = (lv_area_t) { c->x1 + rout, c->y2 - rout + 1, c->x2 - rout, c->y2 };
        *n   = 3;
        return;
    }
    const int32_t bw = ((const lv_draw_border_dsc_t *) t->draw_dsc)->width;
    const int32_t e  = LV_MAX(rout, bw);
    r[0] = (lv_area_t) { c->x1 + rout, c->y1, c->x2 - rout, c->y1 + bw - 1 };
    r[1] = (lv_area_t) { c->x1 + rout, c->y2 - bw + 1, c->x2 - rout, c->y2 };
    r[2] = (lv_area_t) { c->x1, c->y1 + e, c->x1 + bw - 1, c->y2 - e };
    r[3] = (lv_area_t) { c->x2 - bw + 1, c->y1 + e, c->x2, c->y2 - e };
    *n   = 4;
}
#endif

/* Push the task from rectangle *piece on; not OK: *piece is the one not
 * sent. BLNS_ERR_ABSENT with *piece 0: the GPU cannot draw it after all */
static blns_status_t gpu_draw(lv_belenos_unit_t *u, blns_t *dev, lv_draw_task_t *t, unsigned *piece)
{
    const lv_area_t *c = &t->area;
    switch (t->type) {
#if !LVB_RECT
        case LV_DRAW_TASK_TYPE_FILL: {
            const lv_draw_fill_dsc_t *d = t->draw_dsc;
            return gpu_rect(dev, t, c, lv_color_to_u16(d->color));
        }
        case LV_DRAW_TASK_TYPE_BORDER: {
            /* top, bottom, left, right: as the software renderer splits it */
            const lv_draw_border_dsc_t *d = t->draw_dsc;
            const uint16_t  col  = lv_color_to_u16(d->color);
            const int32_t   bw   = d->width;
            const lv_area_t r[4] = {
                { c->x1, c->y1, c->x2, c->y1 + bw - 1 }, { c->x1, c->y2 - bw + 1, c->x2, c->y2 },
                { c->x1, c->y1 + bw, c->x1 + bw - 1, c->y2 - bw }, { c->x2 - bw + 1, c->y1 + bw, c->x2, c->y2 - bw },
            };
            for (; *piece < 4u; (*piece)++) {
                const blns_status_t st = gpu_rect(dev, t, &r[*piece], col);
                if (st != BLNS_OK)
                    return st;
            }
            return BLNS_OK;
        }
#else
        case LV_DRAW_TASK_TYPE_FILL:
        case LV_DRAW_TASK_TYPE_BORDER: {
            const bool    fill   = t->type == LV_DRAW_TASK_TYPE_FILL;
            const int32_t radius = fill ? ((const lv_draw_fill_dsc_t *) t->draw_dsc)->radius
                                        : ((const lv_draw_border_dsc_t *) t->draw_dsc)->radius;
            const lv_color_t col = fill ? ((const lv_draw_fill_dsc_t *) t->draw_dsc)->color
                                        : ((const lv_draw_border_dsc_t *) t->draw_dsc)->color;
            const lv_opa_t   opa = fill ? ((const lv_draw_fill_dsc_t *) t->draw_dsc)->opa
                                        : ((const lv_draw_border_dsc_t *) t->draw_dsc)->opa;
            lv_area_t     a;
            int32_t       rout = 0;             /* the corners the CPU draws (0: none) */
            lv_area_t     r[4];
            unsigned      n;
            if (!lv_area_intersect(&a, c, &t->clip_area))
                return BLNS_OK;
#if LVB_CORNERS
            rout = task_rout(t);
            (void) radius;
            if (rout && *piece == 0u) {         /* rectangle 0: the CPU's corners */
                cpu_corners(u, t, rout);
                *piece = 1u;
            }
            const unsigned first = rout ? 1u : 0u;
#else
            (void) radius;
            const unsigned first = 0u;
#endif
            rect_parts(t, rout, r, &n);
            for (; *piece < n + first; (*piece)++) {
                const blns_status_t st = task_rect(u, t, &r[*piece - first], col, opa);
                if (st != BLNS_OK)
                    return st;
            }
            return BLNS_OK;
        }
#endif
#if LVB_GLYPHS
        case LV_DRAW_TASK_TYPE_LABEL:
            return gpu_label(u, t, piece);
#endif
        default:                                /* IMAGE, LAYER */
#if LVB_XFORM
            if (t->type == LV_DRAW_TASK_TYPE_IMAGE) {
                const lv_draw_image_dsc_t *d = t->draw_dsc;
                if (d->rotation != 0 || d->scale_x != LV_SCALE_NONE || d->scale_y != LV_SCALE_NONE)
                    return gpu_xform(u, dev, t, piece);
            }
#endif
            return gpu_blit(u, dev, t, piece);
    }
}

/* The same with the CPU: the software renderer's functions */
static void cpu_draw(lv_draw_task_t *t)
{
    switch (t->type) {
        case LV_DRAW_TASK_TYPE_FILL:   lv_draw_sw_fill(t, t->draw_dsc, &t->area);   break;
        case LV_DRAW_TASK_TYPE_BORDER: lv_draw_sw_border(t, t->draw_dsc, &t->area); break;
        case LV_DRAW_TASK_TYPE_IMAGE:  lv_draw_sw_image(t, t->draw_dsc, &t->area);  break;
#if LVB_GLYPHS
        case LV_DRAW_TASK_TYPE_LABEL:  lv_draw_sw_label(t, t->draw_dsc, &t->area);  break;
#endif
        default:                       lv_draw_sw_layer(t, t->draw_dsc, &t->area);  break;
    }
}

#if LVB_BLEND
/* Whether drawing the task again over itself changes it (blended) */
static bool blended(const lv_draw_task_t *t)
{
    switch (t->type) {
        case LV_DRAW_TASK_TYPE_FILL:   return ((const lv_draw_fill_dsc_t *) t->draw_dsc)->opa < LV_OPA_MAX;
        case LV_DRAW_TASK_TYPE_BORDER: return ((const lv_draw_border_dsc_t *) t->draw_dsc)->opa < LV_OPA_MAX;
        case LV_DRAW_TASK_TYPE_LABEL:  return true;
        default: {                     /* (an image with alpha, a transform: edges blended) */
            const lv_draw_image_dsc_t *d = t->draw_dsc;
            return d->opa < LV_OPA_MAX || (t->type == LV_DRAW_TASK_TYPE_IMAGE && d->header.cf != LV_COLOR_FORMAT_RGB565) ||
                   d->rotation != 0 || d->scale_x != LV_SCALE_NONE || d->scale_y != LV_SCALE_NONE;
        }
    }
}

static void repair_cb(lv_event_t *e)
{
    lv_belenos_t *drv = lv_event_get_user_data(e);
    if (drv->repair_on) {
        drv->repair_on = false;
        lv_display_t *d = drv->disp;
        lv_area_t     a = drv->repair;
        if (d && lv_area_intersect(&a, &a, &(lv_area_t) { 0, 0, drv->cfg.width - 1, drv->cfg.height - 1 }))
            lv_inv_area(d, &a);
    }
}
#endif

/* Every queued task FINISHED; with 'cpu' (the GPU did not draw them) the
 * CPU draws them first, in their order */
static void retire(lv_belenos_unit_t *u, bool cpu)
{
    for (lv_draw_task_t *t = u->layer->draw_task_head; t; t = t->next)
        if (t->state == LV_DRAW_TASK_STATE_QUEUED && t->draw_unit == &u->base) {
            if (cpu) {
#if LVB_CORNERS
                const int32_t rout = task_rout(t);
                if (rout) {                     /* its corners drawn already: the rest */
                    lv_area_t r[4];
                    unsigned  n;
                    rect_parts(t, rout, r, &n);
                    cpu_parts(t, r, n);
                } else
#endif
                cpu_draw(t);
#if LVB_BLEND
                if (blended(t)) {               /* perhaps blended twice: drawn again next time */
                    lv_belenos_t *drv = u->drv;
                    if (drv->repair_on)
                        lv_area_join(&drv->repair, &drv->repair, &t->_real_area);
                    else
                        drv->repair = t->_real_area;
                    drv->repair_on = true;
                }
#endif
            }
            t->state = LV_DRAW_TASK_STATE_FINISHED;
        }
    u->queued   = 0;
    u->fences   = 0;
    u->unfenced = false;
    u->part     = NULL;
    lv_draw_dispatch_request();                 /* the tasks behind them are free now */
}

/* The batches in flight are lost or in doubt ('st', not BUSY): nothing of
 * them left in the GPU, then the CPU draws them */
static void fail(lv_belenos_unit_t *u, blns_status_t st)
{
    blns_t *dev = u->drv->cfg.dev;
    if (st == BLNS_ERR_DROPPED)
        gpu_idle(dev);                          /* recovered: what came after it ends first */
    else
        (void) blns_gpu_recover(dev);           /* stopped, a wait ended */
#if LVB_STATE
    u->alpha = ST_UNKNOWN;                      /* the GPU's modes: cleared again */
    u->grad  = ST_UNKNOWN;
#endif
#if LVB_CPU
    if (!u->queued) {                           /* (the CPU's turn in a task: none queued) */
        u->part = NULL;
        return;
    }
#endif
    retire(u, true);
}

static void push_fence(lv_belenos_unit_t *u)
{
    uint32_t            tag;
    const blns_status_t st = blns_gpu_fence(u->drv->cfg.dev, false, &tag);
    if (st == BLNS_OK) {
        u->fence[u->fences++] = tag;
        u->unfenced           = false;
    } else if (st != BLNS_ERR_BUSY && st != BLNS_ERR_TIMEOUT) {
        fail(u, st);
    }
}

/* What became of the batches in flight (with 'wait': once they end) */
static void settle(lv_belenos_unit_t *u, bool wait)
{
    blns_t *dev = u->drv->cfg.dev;
    if (!u->queued)
        return;
    if (u->unfenced) {
        push_fence(u);
        if (u->unfenced || !u->queued)
            return;
    }
    while (u->fences) {
        const blns_status_t st = wait ? blns_gpu_wait_fence(dev, u->fence[0])
                                      : blns_gpu_fence_status(dev, u->fence[0]);
        if (st == BLNS_ERR_BUSY)
            return;                             /* the GPU is at it */
        if (st != BLNS_OK) {
            fail(u, st);
            return;
        }
        u->fence[0] = u->fence[1];
        u->fences--;
    }
    if (!u->part)                               /* (a border's last rectangles still to come) */
        retire(u, false);
}

/* Another unit has a task it can take now, or one in progress */
static bool others_busy(const lv_belenos_unit_t *u)
{
    for (lv_layer_t *l = u->drv->disp->layer_head; l; l = l->next)
        for (lv_draw_task_t *t = l->draw_task_head; t; t = t->next) {
            if (t->preferred_draw_unit_id == u->base.idx)
                continue;
            if (t->state == LV_DRAW_TASK_STATE_IN_PROGRESS ||
                (t->state == LV_DRAW_TASK_STATE_WAITING &&
                 lv_draw_get_next_available_task(l, NULL, t->preferred_draw_unit_id)))
                return true;
        }
    return false;
}

#if LVB_CPU
/* A task taken but not pushed (BLNS_ERR_ABSENT): the CPU draws it now,
 * after what the GPU has queued under it */
static void cpu_task(lv_belenos_unit_t *u, lv_draw_task_t *t)
{
    const blns_status_t st = cpu_turn(u, t, &t->_real_area, 1u);
    if (st != BLNS_OK)
        fail(u, st);
    cpu_draw(t);
    t->state     = LV_DRAW_TASK_STATE_FINISHED;
    t->draw_unit = &u->base;
    lv_draw_dispatch_request();
}
#endif

/* Push a task (or the rest of the one partly pushed): false when the round
 * ends here (no room, or the GPU refused) */
static bool push_task(lv_belenos_unit_t *u, lv_draw_task_t *t)
{
    const bool          more  = t == u->part;
    unsigned            piece = more ? u->piece : 0u;
    const blns_status_t st    = gpu_draw(u, u->drv->cfg.dev, t, &piece);
    const bool          room  = st != BLNS_ERR_BUSY && st != BLNS_ERR_TIMEOUT;
#if LVB_CPU
    if (st == BLNS_ERR_ABSENT && !more && piece == 0u) {
        cpu_task(u, t);                         /* the GPU cannot draw it after all */
        return true;
    }
#endif
    if (!room && !more && piece == 0u)
        return false;                           /* nothing of it sent: it waits for the next round */
    if (!more) {
        t->state     = LV_DRAW_TASK_STATE_QUEUED;
        t->draw_unit = &u->base;
        u->layer     = t->target_layer;
        u->queued++;
    }
    u->unfenced = true;
    u->part     = room ? NULL : t;
    u->piece    = piece;
    if (st == BLNS_OK)
        return true;
    if (room)
        fail(u, st);                            /* stopped */
    return false;
}

static int32_t unit_dispatch(lv_draw_unit_t *du, lv_layer_t *layer)
{
    lv_belenos_unit_t *u = (lv_belenos_unit_t *) du;
    if (!unit_on(u))
        return LV_DRAW_UNIT_IDLE;
    settle(u, false);
    if (u->queued && u->layer != layer)         /* busy on another layer */
        return LV_DRAW_UNIT_IDLE;
#if LVB_POOL
    /* a layer not allocated yet (taken as in the pool at evaluation): in
     * the pool, else in RAM (the CPU draws its tasks then) */
    if (!layer->draw_buf && layer->draw_task_head && !pool_layer(u->drv, layer) && !lv_draw_layer_alloc_buf(layer))
        return LV_DRAW_UNIT_IDLE;               /* LVGL's memory short: the next time */
#endif
    const uint32_t  queued = u->queued;
    /* at most two fences in flight: tasks are pushed only below that (a
     * fence then always has its place) */
    bool            go     = u->fences < 2u && (!u->part || push_task(u, u->part));
    lv_draw_task_t *t      = NULL;
#if LVB_CPU
    int32_t         cpu    = 0;                 /* tasks the CPU drew */
    while (go && (t = lv_draw_get_next_available_task(layer, t, (uint8_t) du->idx)) != NULL)
        if (t->preferred_draw_unit_id == du->idx) {
#if LVB_POOL
            if (!layer_in_vram(u, u->drv->cfg.dev, layer)) {     /* it went to RAM: the CPU draws */
                cpu_task(u, t);
                cpu++;
                continue;
            }
#endif
            go = push_task(u, t);
            cpu += t->state == LV_DRAW_TASK_STATE_FINISHED;
        }
    const int32_t taken = (int32_t) (u->queued - queued) + cpu;
#else
    while (go && (t = lv_draw_get_next_available_task(layer, t, (uint8_t) du->idx)) != NULL)
        if (t->preferred_draw_unit_id == du->idx)
            go = push_task(u, t);
    const int32_t taken = (int32_t) (u->queued - queued);
#endif
#if LVB_STATE
    if (u->unfenced && !u->part)
        (void) unit_plain(u);                   /* the modes off before the fence */
#endif
    if (u->unfenced)
        push_fence(u);
    if (taken > 0) {
        lv_draw_dispatch_request();             /* poll the fence on the next round */
        return taken;
    }
    /* nothing else to do (no task to come, none for another unit): wait for
     * the GPU through the wait hook instead of LVGL's dispatch loop */
    if (u->queued && layer->all_tasks_added && !others_busy(u))
        settle(u, true);
    return LV_DRAW_UNIT_IDLE;
}

/* A unit for the display: a detached one (its display deleted) again, else
 * a new one (LVGL keeps its draw units until lv_deinit) */
static lv_belenos_unit_t *unit_attach(lv_belenos_t *drv)
{
    lv_belenos_unit_t *u = NULL;
    for (lv_draw_unit_t *x = LV_GLOBAL_DEFAULT()->draw_info.unit_head; x && !u; x = x->next)
        if (x->name == unit_name && !((lv_belenos_unit_t *) x)->drv)
            u = (lv_belenos_unit_t *) x;
    if (!u) {
        u = lv_draw_create_unit(sizeof(*u));
        if (!u)
            return NULL;
        u->base.name        = unit_name;
        u->base.evaluate_cb = unit_evaluate;
        u->base.dispatch_cb = unit_dispatch;
    }
    u->drv    = drv;
    u->queued = 0;
    u->fences = 0;
    u->part   = NULL;
#if LV_BELENOS_USE_APPROX
    const blns_t *dev = drv->cfg.dev;
    u->approx = (uint8_t) (drv->cfg.approx & ((BLNS_HAS(dev, GPU_GRAD) ? LV_BELENOS_APPROX_GRAD : 0u) |
                                              (BLNS_HAS(dev, GPU_XY) ? LV_BELENOS_APPROX_TRANSFORM : 0u)));
#endif
#if LVB_STATE
    u->alpha  = ST_UNKNOWN;
    u->grad   = ST_UNKNOWN;
#endif
    return u;
}

/*------------------------------- create -------------------------------------*/

/* The driver's memory */
static void lv_belenos_free(lv_belenos_t *drv)
{
#if LVB_POOL
    lv_free(drv->ps);
#endif
#if LVB_GLYPHS
    lv_free(drv->glyph);
#endif
    lv_free(drv);
}

static void delete_cb(lv_event_t *e)
{
    lv_belenos_t *drv = lv_event_get_user_data(e);
    flush_settle(drv);                          /* the GPU reads the buffers no more */
    if (drv->unit)
        drv->unit->drv = NULL;
#if LVB_POOL
    if (drv->pool)
        gpu_idle(drv->cfg.dev);                 /* nor the pool */
    pool_list(drv, false);
#endif
    lv_belenos_free(drv);
}

/* A buffer LVGL takes (LV_DRAW_BUF_ALIGN), in the VRAM for the GPU way */
static bool buf_ok(const lv_belenos_config_t *cfg, void *b, uint32_t bytes)
{
    return !((uintptr_t) b & 1u) && lv_draw_buf_align(b, LV_COLOR_FORMAT_RGB565) == b &&
           (cfg->flush != LV_BELENOS_FLUSH_GPU || in_vram(cfg->dev, b, bytes));
}

lv_display_t *lv_belenos_create(const lv_belenos_config_t *cfg)
{
    if (!cfg || !cfg->dev || cfg->width <= 0 || cfg->height <= 0 || cfg->width > 0xFFFF ||
        cfg->dev->mode != BLNS_BPP_16 || cfg->flush > LV_BELENOS_FLUSH_DIRECT ||
        (cfg->pitch && cfg->pitch < cfg->width) || cfg->frame >= cfg->dev->caps.vram_words * 2u ||
        ((cfg->flush == LV_BELENOS_FLUSH_GPU || cfg->gpu_draw) && (!cfg->dev->caps.gpu || !cfg->dev->gpu_on)) ||
        (cfg->gpu_draw && cfg->flush == LV_BELENOS_FLUSH_CPU))
        return NULL;
    blns_t        *dev    = cfg->dev;
    const uint32_t pitch  = frame_pitch(cfg);
    void          *fb     = (void *) blns_vram_ptr(dev, cfg->frame);
    void          *buf[2] = { cfg->buf[0], cfg->buf[1] };
    uint32_t       bytes  = cfg->buf_bytes;
    uint32_t       stride = LV_STRIDE_AUTO;
    lv_display_render_mode_t mode = LV_DISPLAY_RENDER_MODE_PARTIAL;
    /* the whole frame in the VRAM */
    if (!in_vram(dev, fb, (pitch * (uint32_t) (cfg->height - 1) + (uint32_t) cfg->width) * 2u))
        return NULL;
#if LVB_POOL
    /* the pool: in the VRAM, word-aligned */
    const bool pool = cfg->gpu_draw && cfg->pool && cfg->pool_bytes;
    if (pool && (((uintptr_t) cfg->pool & 3u) || !in_vram(dev, cfg->pool, cfg->pool_bytes)))
        return NULL;
#endif
    if (cfg->flush == LV_BELENOS_FLUSH_DIRECT) {
        /* LVGL renders into the frame itself, rows at its pitch */
        buf[0] = fb;
        buf[1] = NULL;
        stride = pitch * 2u;
        bytes  = stride * (uint32_t) cfg->height;
        mode   = LV_DISPLAY_RENDER_MODE_DIRECT;
        if (!in_vram(dev, fb, bytes) || lv_draw_buf_align(fb, LV_COLOR_FORMAT_RGB565) != fb)
            return NULL;
    } else if (!buf[0] || !buf_ok(cfg, buf[0], bytes) || (buf[1] && !buf_ok(cfg, buf[1], bytes)) ||
               bytes < lv_draw_buf_width_to_stride((uint32_t) cfg->width, LV_COLOR_FORMAT_RGB565)) {
        return NULL;                            /* LVGL would refuse them, or not a line */
    }
    lv_belenos_t *drv = lv_malloc_zeroed(sizeof(*drv));
    if (!drv)
        return NULL;
    drv->cfg = *cfg;
#if LVB_POOL
    if (pool) {
        drv->ps = lv_malloc_zeroed(sizeof *drv->ps);
        if (!drv->ps) {
            lv_free(drv);
            return NULL;
        }
        drv->pool       = cfg->pool;
        drv->pool_bytes = cfg->pool_bytes & ~3u;
    }
#endif
#if LVB_GLYPHS
    if (pool && BLNS_HAS(dev, GPU_BLEND)) {
        drv->glyph = lv_malloc_zeroed(GLYPH_SLOTS * sizeof drv->glyph[0]);
        if (!drv->glyph) {
            lv_belenos_free(drv);
            return NULL;
        }
    }
#endif
    if (cfg->gpu_draw && !(drv->unit = unit_attach(drv))) {
        lv_belenos_free(drv);
        return NULL;
    }
    /* delete_cb first: from there on lv_display_delete frees all (LVGL
     * refuses a callback out of memory) */
    lv_display_t *disp = lv_display_create(cfg->width, cfg->height);
    if (!disp || !lv_display_add_event_cb(disp, delete_cb, LV_EVENT_DELETE, drv)) {
        if (disp)
            lv_display_delete(disp);
        if (drv->unit)
            drv->unit->drv = NULL;
        lv_belenos_free(drv);
        return NULL;
    }
    drv->disp = disp;
    lv_display_set_driver_data(disp, drv);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    /* checked above as LVGL checks them (it would refuse them silently) */
    lv_display_set_buffers_with_stride(disp, buf[0], buf[1], bytes, stride, mode);
    lv_display_set_flush_cb(disp, lv_belenos_flush_cb);
    if (cfg->flush == LV_BELENOS_FLUSH_GPU)
        lv_display_set_flush_wait_cb(disp, flush_wait_cb);
    else if (cfg->flush == LV_BELENOS_FLUSH_CPU)    /* refused: unrounded rows, copied as well */
        (void) lv_display_add_event_cb(disp, round_cb, LV_EVENT_INVALIDATE_AREA, drv);
#if LVB_BLEND
    /* refused (out of memory): a fault's double blend stays until redrawn */
    if (drv->unit && BLNS_HAS(dev, GPU_BLEND))
        (void) lv_display_add_event_cb(disp, repair_cb, LV_EVENT_REFR_READY, drv);
#endif
#if LVB_POOL
    if (pool)
        pool_list(drv, true);
#endif
    return disp;
}
