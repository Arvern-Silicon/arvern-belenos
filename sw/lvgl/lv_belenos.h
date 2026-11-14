/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      lv_belenos.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * LVGL v9 display driver and GPU draw unit for Belenos at 16 bpp (RGB565).
 *
 * The driver puts LVGL's rendering into a frame in the VRAM that the refresh
 * shows, in one of three ways:
 *
 *   CPU    PARTIAL mode, the draw buffer in the CPU's RAM; flush copies the
 *          area into the frame through the VRAM window (blns_vram_write_rect:
 *          32-bit writes when the area and the buffer allow). Invalidated
 *          areas are widened to even columns so that every row is whole words.
 *   GPU    PARTIAL mode, the draw buffer(s) in the VRAM (LVGL renders through
 *          the VRAM window); flush is one GPU COPY from the buffer into the
 *          frame, followed by a FENCE; LVGL waits for the fence before it
 *          renders into that buffer again, and the last area of a frame is
 *          waited for at once (the frame is whole when LVGL's refresh
 *          returns). With two buffers LVGL renders the next area while the GPU
 *          copies the last one. A copy the GPU did not complete (stopped on an
 *          error, dropped by a recover, still running when a wait ends) is
 *          stopped and done again by the CPU; a GPU without room (BUSY, a wait
 *          hook's timeout) or disabled leaves the copy to the CPU.
 *   DIRECT DIRECT mode: LVGL renders into the frame itself through the VRAM
 *          window (buf[] unused, LVGL's stride the frame's pitch); no copy at
 *          all, only what changed is redrawn. Without a second frame the
 *          panel may show an area while it is redrawn (a tear).
 * The rows of a draw buffer are LVGL's stride apart (LV_DRAW_BUF_STRIDE_ALIGN),
 * buffers aligned as LVGL wants them (LV_DRAW_BUF_ALIGN).
 *
 * GPU draw unit (gpu_draw, with the GPU or DIRECT way: the GPU reads and
 * writes only the VRAM, so it can draw only into a draw buffer there). An
 * LVGL draw unit next to LVGL's software renderer; it takes the draw tasks
 * the GPU renders exactly as the software renderer does, pixel for pixel,
 * with fills and copies (and the immediate source, caps.gpu_imm):
 *   FILL          opaque (opa >= LV_OPA_MAX), no gradient; with a radius
 *                 only when the clipped area misses the four corners (there
 *                 the rounded rectangle is a plain one); with
 *                 LV_DRAW_SW_COMPLEX 0 (no rounded shape drawn) radius 0 only
 *   BORDER        opaque, all four sides, sides that do not meet, corners
 *                 missed as for FILL: up to four rectangles
 *   IMAGE, LAYER  blits of RGB565 pixels (an image descriptor's data,
 *                 stride 0 meaning w x 2 as for LVGL; a layer's buffer), the
 *                 size of the area, at full opacity, with no rotation,
 *                 scale, skew, recolour, colour key, mask, clip radius,
 *                 tiling, premultiplied alpha or other blend mode. In the
 *                 VRAM: a GPU copy. In
 *                 the CPU's memory (ROM, RAM, a layer on LVGL's heap), with
 *                 the immediate source: the CPU pushes the pixels through
 *                 GPU_CMD (blns_gpu_blit_imm), in order with the GPU's
 *                 drawing, when the drawn area is one row or whole rows of
 *                 an image without row padding, at most 1024 pixels (a
 *                 pushed word costs the CPU more than the software
 *                 renderer's copy; LVGL's per-image work, saved, pays for
 *                 that up to there), starts on a 32-bit word and is read
 *                 with nothing past the source (data_size)
 * With blending (caps.gpu_blend), the GPU's MIX5 rule is LVGL's
 * (lv_color_16_16_mix: a 5-bit factor, truncated; LV_OPA_MIX2), so these are
 * drawn exactly too:
 *   FILL, BORDER  as above at an opacity LV_OPA_MIN < opa < LV_OPA_MAX
 *   IMAGE, LAYER  RGB565 blits as above at such an opacity; RGB565A8 images
 *                 in the VRAM (the GPU's per-pixel alpha, SRC_FMT 5), at any
 *                 opacity (SET_ALPHA EN only below LV_OPA_MAX, as LVGL)
 * Everything else stays with the software renderer: anti-aliased edges
 * (rounded corners, arcs, lines), shadows, gradients (LVGL interpolates in
 * RGB888 and rounds per pixel, the GPU steps RGB565 fields in fixed point:
 * not the same pixels), rotated and scaled images (but with the approximate
 * extension below), images in the CPU's memory without the immediate source
 * (or the pool below), and the image cases above it does not push. The unit
 * does not use the palette remap (no effect at 16 bpp) nor the mask plane
 * (LVGL's masks and alpha are 8-bit coverage, not a 1-bit plane in the
 * VRAM).
 *
 * Extensions, each compiled only when its option is 1 (lv_conf.h or -D;
 * all 0 by default: the unit above, nothing more) and, where it needs one,
 * the GPU feature is built (the platform header, belenos_hw.h):
 *   LV_BELENOS_USE_CORNERS  exact. A rounded FILL or BORDER whose clipped
 *                 area meets its corners: the GPU draws the straight parts
 *                 (plain rectangles), the software renderer the four
 *                 corner squares (after the GPU is done with what it has
 *                 queued over them)
 *   LV_BELENOS_USE_POOL  exact. A region of the VRAM the unit owns (pool,
 *                 pool_bytes): RGB565 images in the CPU's memory are staged
 *                 there once (a CPU copy) and then drawn by GPU copies,
 *                 tiled ones too, instead of the immediate source (an image
 *                 whose header has LV_IMAGE_FLAGS_MODIFIABLE is not staged;
 *                 after changing the pixels of one that was,
 *                 lv_belenos_drop_images); with blending (caps.gpu_blend),
 *                 RGB565A8 images in the CPU's memory are staged as they
 *                 are, ARGB8888 ones (anywhere) converted to RGB565A8 with
 *                 LVGL's truncation (LV_COLOR_24_TO_16: LVGL's ARGB8888
 *                 blend truncates the same way), all drawn exactly with the
 *                 GPU's per-pixel alpha, tiled ones too; and labels (A1 to
 *                 A8 glyphs of LVGL's bitmap fonts) are drawn exactly by
 *                 EXEC_EXPAND MASK from their coverage masks staged in the
 *                 pool. With pool_layers, the unit allocates LVGL's RGB565
 *                 layers there before LVGL does, so the GPU draws into them
 *                 and copies them. When the pool is full, the GPU is waited
 *                 for and every staged image and glyph dropped; what still
 *                 does not fit is drawn by the CPU (a layer: in LVGL's heap)
 *   LV_BELENOS_USE_APPROX  the GPU's arithmetic instead of LVGL's, each kind
 *                 only when cfg.approx asks for it (LV_BELENOS_APPROX_*):
 *     GRAD (caps.gpu_grad): opaque horizontal and vertical gradients of
 *                 fills: runs of 64 rows or columns at most in one stop
 *                 interval, each a SET_GRAD_RGB ramp from LVGL's colour at
 *                 its start towards LVGL's just past it (a steeper ramp
 *                 than SET_GRAD_RGB takes: one plain row or column at a
 *                 time): within 2 per field of LVGL's
 *     TRANSFORM (caps.gpu_xy): rotated and scaled IMAGE tasks (no skew,
 *                 tiling, recolour, colour key, clip radius or mask; NORMAL
 *                 blend mode) of the formats above (ARGB8888 staged: the
 *                 pool), up to 512 x 512: LVGL's set-up of
 *                 lv_draw_sw_transform replicated (its sine table, steps and
 *                 start, the right and bottom clamp of a scale without
 *                 rotation as a second blit), one EXEC_TEXRECT with BOUND per
 *                 tile of 64 x 64 at most, each tile seeded from LVGL's
 *                 1/65536-texel model (blns_gpu_texrect_fx_xy). antialias
 *                 (LVGL's default): bilinear sampling with transparent taps
 *                 outside the image (caps.gpu_bilinear and caps.gpu_blend);
 *                 off: nearest (an RGB565 image at full opacity needs no
 *                 blending). LVGL itself switches between two bilinear
 *                 kernels that differ by up to 5 in G; the GPU's differs
 *                 from either by at most 3, 5, 3 per field (R, G, B) at the
 *                 same sample point, plus the position term: the walk drifts
 *                 by less than 0.024 texel from LVGL's model and LVGL floors
 *                 its own point twice to 1/256, so the GPU samples within
 *                 1/32 texel of LVGL's point (one step of the 5-bit
 *                 weights): at most 2/32 of the contrast of the neighbouring
 *                 texels (near the image's edge, where LVGL or the GPU may
 *                 skip the pixel, the contrast); nearest: a texel within
 *                 1/32 texel of LVGL's sample point
 * Blended draws (opacity, images with alpha, labels, transforms) are not
 * idempotent: a batch the GPU did not draw, which the CPU draws again, may
 * have been drawn partly; the area of such a task is invalidated after the
 * refresh (LV_EVENT_REFR_READY), so the next refresh draws it again whole.
 * Labels are left to the software renderer in non-blocking mode (a label
 * cut by BUSY would be iterated again from its first glyph).
 * Ordering: the tasks the unit takes are pushed to the GPU and marked
 * QUEUED, one FENCE behind each batch, at most two batches in flight
 * (gpu_commands.md, "Fences"); LVGL then gives the software renderer
 * no task whose area meets a queued one, and the unit marks them FINISHED
 * once blns_gpu_fence_status reports their fences reached. The flush comes
 * after every task is FINISHED, so the GPU is idle on the frame by then.
 * A batch the GPU did not draw (stopped on an error after it was accepted,
 * dropped by a recover from any context, a wait that ended) is drawn again
 * by the CPU (the software renderer's functions) once the GPU is recovered
 * or idle: never FINISHED with wrong pixels. A GPU without room (non-blocking
 * BUSY, a wait hook's timeout before anything was sent) is no fault: the
 * task waits for LVGL's next dispatch round, and so does an immediate blit
 * whose data a timeout cut (discarded: sent again whole). When LVGL has nothing else to
 * do, the unit waits for its fence with blns_gpu_wait_fence, through the
 * wait hook (where an OS sleeps), not in LVGL's dispatch loop.
 *
 * The driver only depends on LVGL (v9, not bundled with the IP) and the
 * Belenos driver API (belenos.h); the draw unit includes LVGL's internal
 * headers (src/draw/..., src/core/..., src/display/lv_display_private.h,
 * src/misc/lv_area_private.h), so LVGL's root directory must be on the
 * include path, as for lvgl.h. The board sets Belenos up (mode BLNS_BPP_16,
 * size, display interface, frame pointer, GPU enabled for the GPU way and
 * the draw unit) and gives the frame's place here. The driver keeps no
 * global state; it runs in the context that owns the blns_t (another one
 * may only request a recover: blns_gpu_recover_request, blns_irq_service).
 * The draw unit draws for its display only; LVGL keeps its draw units
 * until lv_deinit, so a deleted display's unit is taken again by the next
 * display created with gpu_draw.
 * Host test: sw/test (make lvgl), against LVGL's software renderer.
 *----------------------------------------------------------------------------*/
#ifndef LV_BELENOS_H
#define LV_BELENOS_H

#include <stdint.h>
#include "lvgl.h"
#include "belenos.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef LV_BELENOS_USE_CORNERS
#define LV_BELENOS_USE_CORNERS  0
#endif
#ifndef LV_BELENOS_USE_POOL
#define LV_BELENOS_USE_POOL     0
#endif
#ifndef LV_BELENOS_USE_APPROX
#define LV_BELENOS_USE_APPROX   0
#endif

/* cfg.approx: the draws the GPU rounds differently from LVGL (LV_BELENOS_USE_APPROX);
 * 0x01 (BLEND before MIX5: those draws are exact now) is not used */
#define LV_BELENOS_APPROX_GRAD      0x02u   /* horizontal / vertical gradients (gpu_grad) */
#define LV_BELENOS_APPROX_TRANSFORM 0x04u   /* rotated / scaled images (gpu_xy; gpu_bilinear) */

typedef enum {
    LV_BELENOS_FLUSH_CPU = 0,   /* draw buffer in RAM, the CPU copies        */
    LV_BELENOS_FLUSH_GPU = 1,   /* draw buffer(s) in VRAM, the GPU copies    */
    LV_BELENOS_FLUSH_DIRECT = 2 /* LVGL renders into the frame               */
} lv_belenos_flush_t;

typedef struct {
    blns_t            *dev;     /* Belenos handle (blns_init done)           */
    uint32_t           frame;   /* pixel address of the frame's (0, 0)       */
    uint16_t           pitch;   /* frame line stride in pixels; 0 = width    */
    int32_t            width;   /* display size in pixels                    */
    int32_t            height;
    lv_belenos_flush_t flush;
    /* The GPU draw unit (GPU or DIRECT flush, caps.gpu; NULL from create
     * otherwise): the GPU draws the tasks it can render bit for bit */
    bool               gpu_draw;
    /* CPU: buf[0] in RAM (buf[1] NULL). GPU: buf[0] and optionally buf[1]
     * in the VRAM window (pointers into blns_vram8(dev)). Aligned to
     * LV_DRAW_BUF_ALIGN, buf_bytes (the size of each) at least one line of
     * LVGL's stride. DIRECT: none (the frame). */
    void              *buf[2];
    uint32_t           buf_bytes;
#if LV_BELENOS_USE_POOL
    /* The draw unit's VRAM pool: bytes [pool, pool + pool_bytes) of the VRAM
     * window (a pointer into blns_vram8(dev), 4-byte aligned; NULL or 0
     * bytes: none), apart from the frame and the buffers */
    void              *pool;
    uint32_t           pool_bytes;
    bool               pool_layers;     /* LVGL's RGB565 layers in the pool too */
#endif
#if LV_BELENOS_USE_APPROX
    /* The draw unit's draws rounded as the GPU does: LV_BELENOS_APPROX_* (0: none) */
    uint8_t            approx;
#endif
} lv_belenos_config_t;

/* Create the LVGL display (lv_init done). NULL on a bad configuration (a
 * buffer LVGL would refuse, a buffer or the frame not wholly in the VRAM,
 * the GPU way or the draw unit with the GPU disabled) or when LVGL's memory
 * is short. lv_display_delete frees what it allocated. */
lv_display_t *lv_belenos_create(const lv_belenos_config_t *cfg);

/* The flush callback lv_belenos_create installs: a wrapper may replace it
 * (lv_display_set_flush_cb) and call this one, e.g. to time the flushes. */
void lv_belenos_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map);

#if LV_BELENOS_USE_POOL
/* Forget the images staged in the display's pool (their pixels changed in
 * the CPU's memory): the GPU is waited for first. Not while LVGL renders. */
void lv_belenos_drop_images(lv_display_t *disp);
#endif

#ifdef __cplusplus
}
#endif

#endif /* LV_BELENOS_H */
