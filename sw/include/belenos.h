/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      belenos.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Belenos driver API.
 *
 *   blns_*          controller: identification, mode, frame buffers, refresh,
 *                   colour LUT, interrupts, debug freeze, VRAM access (belenos.c)
 *   blns_gpu_*      GPU command helpers and command lists      (blns_gpu.c)
 *   blns_dbi_*      built-in MIPI-DBI transport (DIF_TYPE 1-3) (blns_dbi.c)
 *   blns_dpi_*      built-in MIPI-DPI driver (DIF_TYPE 4, and 5 = HDMI) (blns_dpi.c;
 *                   the DDC and the EDID: blns_ddc.c; hot-plug: blns_hotplug.c)
 *
 * Panel drivers (sw/panel/) sit on top of the DBI transport. The driver keeps
 * no global state: every call takes the device handle filled by blns_init().
 *
 * Conventions (stable within a major version from 1.0.0; the 0.x previews may
 * change them):
 *   - Addresses: blns_pa_t is a pixel address (depth-dependent: pixel n of
 *     the VRAM at the current depth), blns_wa_t a 32-bit word address (command
 *     lists, the remap table), blns_ba_t a bit address (a 1-bpp pixel address:
 *     the mask plane). blns_vram_pa() / blns_vram_ptr() convert.
 *   - Every call that can fail returns blns_status_t; void calls have no
 *     precondition. A feature not built returns BLNS_ERR_ABSENT with nothing
 *     written, so a library can fall back to its own renderer.
 *   - Sizes are uint16_t (0 draws nothing), x/y positions int (-2048 .. 2047),
 *     triangle vertices int32_t in 1/16 pixel, walks (swap) uint8_t BLNS_SWAP_*.
 *   - Naming: blns_gpu_*_begin sets a destination (and the session values of
 *     the per-item calls that follow), blns_gpu_*_set sets session values
 *     without a destination; the per-item calls (span, expand, tex_span and
 *     their _xy forms, fill_xy, ...) re-send whatever another call changed in
 *     between.
 *   - Optional features are detected at run time (caps), or stated at compile
 *     time by a platform header (belenos_hw.h: BLNS_HW_*, BLNS_HAS).
 *   - Waits poll status bits; each poll calls the wait hook of blns_config_t,
 *     which may end the wait (BLNS_ERR_TIMEOUT), and wait_polls bounds them.
 *   - Public structures grow only at the end, and a zero field keeps the
 *     earlier behaviour: initialise them with designated initialisers (or
 *     zero them), and rebuild the driver with the application (source
 *     compatibility, not binary).
 *   - Contexts: see "Concurrency" below.
 *----------------------------------------------------------------------------*/
#ifndef BELENOS_H
#define BELENOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "belenos_regs.h"
#include "belenos_hw.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Small helpers of the header and the fast paths are always inlined (-Os
 * would keep them as calls); BLNS_NOINLINE keeps a rare path out of them */
#if defined(__GNUC__) || defined(__clang__)
#define BLNS_ALWAYS_INLINE  static inline __attribute__((always_inline))
#define BLNS_NOINLINE       __attribute__((noinline))
#else
#define BLNS_ALWAYS_INLINE  static inline
#define BLNS_NOINLINE
#endif

/*---------------------------------------------------------------------------
 * Types
 *---------------------------------------------------------------------------*/
typedef enum {
    BLNS_OK          =  0,
    BLNS_ERR_PARAM   = -1,      /* argument out of range for this build      */
    BLNS_ERR_ID      = -2,      /* no Belenos (or an unsupported version) at the base address */
    BLNS_ERR_ABSENT  = -3,      /* feature not built (GPU or GPU feature, LUT, driver) */
    BLNS_ERR_GPU     = -4,      /* GPU disabled or stopped on an error
                                 * (GPU_STAT.ERR): the call is not sent (or, a
                                 * call longer than the FIFO, not all of it), a
                                 * fence is not reached. A recover requested
                                 * while a call waits for FIFO room ends that
                                 * call; the next call performs the recover
                                 * (what the call sent is dropped) and is sent */
    BLNS_ERR_STATE   = -5,      /* call out of order: no session or surface
                                 * begun, a pointer (remap table, mask plane,
                                 * alpha plane) not set, no frames flowing for a wait that
                                 * needs them, a fence tag no fence will
                                 * reach                                      */
    BLNS_ERR_BUS     = -6,      /* no answer on the DDC (NACK, or SCL held low) */
    BLNS_ERR_FULL    = -7,      /* a command list overflowed                 */
    BLNS_ERR_TIMEOUT = -8,      /* a wait ended by the wait hook or wait_polls */
    BLNS_ERR_BUSY    = -9,      /* non-blocking mode: no room now, nothing sent */
    BLNS_ERR_CONFIG  = -10,     /* blns_init: the platform header (BLNS_HW_*) and
                                 * the hardware's configuration differ */
    BLNS_ERR_DROPPED = -11      /* blns_gpu_fence_status: a recover (or GPU_EN = 0)
                                 * dropped work pushed before the fence; it may
                                 * be partly drawn: draw it again */
} blns_status_t;

typedef uint32_t blns_pa_t;     /* pixel address                              */
typedef uint32_t blns_wa_t;     /* VRAM word address (byte address / 4)       */
typedef uint32_t blns_ba_t;     /* VRAM bit address (1-bpp pixel address)     */

typedef enum {                  /* CTRL.GFX_MODE */
    BLNS_BPP_1  = 0,
    BLNS_BPP_2  = 1,
    BLNS_BPP_4  = 2,
    BLNS_BPP_8  = 3,
    BLNS_BPP_16 = 4
} blns_mode_t;

/* Scan / walk direction (DISP_CFG, GPU surfaces): OR of these */
#define BLNS_SWAP_NONE   0u
#define BLNS_SWAP_CL     BLNS_SWAP_CL_Msk       /* column-major              */
#define BLNS_SWAP_Y      BLNS_SWAP_Y_Msk        /* bottom to top             */
#define BLNS_SWAP_X      BLNS_SWAP_X_Msk        /* right to left             */

typedef enum {                  /* GPU raster operations: S source (fill colour for a fill), D destination */
    BLNS_ROP_S          = 0,    /* S                                  */
    BLNS_ROP_NOT_S      = 1,    /* ~S                                 */
    BLNS_ROP_NOT_D      = 2,    /* ~D                                 */
    BLNS_ROP_AND        = 3,    /* S & D                              */
    BLNS_ROP_OR         = 4,    /* S | D                              */
    BLNS_ROP_XOR        = 5,    /* S ^ D                              */
    BLNS_ROP_NAND       = 6,    /* ~(S & D)                           */
    BLNS_ROP_NOR        = 7,    /* ~(S | D)                           */
    BLNS_ROP_XNOR       = 8,    /* ~(S ^ D)                           */
    BLNS_ROP_NOT_S_AND_D = 9,   /* ~S & D                             */
    BLNS_ROP_S_AND_NOT_D = 10,  /* S & ~D                             */
    BLNS_ROP_NOT_S_OR_D = 11,   /* ~S | D                             */
    BLNS_ROP_S_OR_NOT_D = 12,   /* S | ~D                             */
    BLNS_ROP_ZERO_IF_S  = 13,   /* 0 where S is not transparent (ops 13-15:
                                 * transparent = 'transparent' of a blit or
                                 * copy_transp, 0 for a fill or a copy)    */
    BLNS_ROP_ONES_IF_S  = 14,   /* all ones where S is not transparent */
    BLNS_ROP_FILL_IF_S  = 15    /* fill colour where S is not transparent (a
                                 * fill: its colour; an expansion: its colour; a
                                 * copy or blit: the session colour of
                                 * blns_gpu_colour_set) */
} blns_rop_t;

typedef enum {                  /* palette remap through the SET_AUX REMAP_TABLE table */
    BLNS_REMAP_OFF      = 0,
    BLNS_REMAP_SRC      = 1,    /* S' = T[S]: the source colour through the table */
    BLNS_REMAP_DST      = 2     /* S' = T[D]: the destination pixel through the table */
} blns_remap_t;

/* Store barrier between VRAM window writes and a later register-port write
 * that makes the GPU or the refresh read them (a CALL of a list just written,
 * a GPU copy of an upload). The default is a compiler barrier, enough when the
 * two ports sit on one ordered AHB-Lite path (as on aRVern); an integrator
 * with a posted bridge or a write buffer in front of the window defines
 * BLNS_WMB() before including this header (on RISC-V: fence w,w). The window
 * must be uncached. */
#ifndef BLNS_WMB
#if defined(__GNUC__) || defined(__clang__)
#define BLNS_WMB()  __asm__ volatile ("" ::: "memory")
#else
#define BLNS_WMB()  ((void) 0)
#endif
#endif

typedef struct {                /* blns_init() arguments */
    uintptr_t reg_base;         /* register port (4 KB)                       */
    uintptr_t vram_base;        /* VRAM window                                */
    uint32_t  hclk_hz;          /* Belenos clock, for blns_refresh_rate()     */
    /* Waits (all of them: GPU FIFO space, GPU idle, fences, frames, flips,
     * DPI updates, HDMI audio and packets, DBI): called once per poll; true
     * ends the wait with BLNS_ERR_TIMEOUT. Service audio, USB or hot-plug
     * there, yield to an RTOS, count a watchdog. NULL: plain polling. */
    bool    (*wait_hook)(void *ctx);
    void     *wait_ctx;
    uint32_t  wait_polls;       /* polls before BLNS_ERR_TIMEOUT (0: no limit) */
} blns_config_t;

typedef struct {                /* build configuration (BLNS_CFG, BLNS_CFG2, DPI_CAPS) */
    uint32_t  vram_words;       /* VRAM depth in 32-bit words                 */
    uint8_t   frame_nr;         /* frame pointers                             */
    uint8_t   lut_banks;        /* 0 without LUT, 1 or 2                      */
    uint8_t   dif_type;         /* display driver, BLNS_DIF_*                 */
    uint8_t   dim_w;            /* width/height field width                   */
    bool      priv_check;       /* user-mode accesses refused                 */
    bool      cursor;           /* hardware cursor (blns_cursor_*)            */
    bool      gpu;              /* GPU present                                */
    uint16_t  gpu_fifo_depth;   /* GPU command FIFO words                     */
    bool      gpu_xy;           /* x/y destinations, clip window, affine blits */
    bool      gpu_grad;         /* gradient fills                             */
    bool      gpu_blend;        /* alpha blending (16 bpp), RGB565A8 sources, MIX5 */
    bool      gpu_tri;          /* triangles                                  */
    bool      gpu_remap;        /* palette remap (SET_AUX REMAP_TABLE, REMAP fields) */
    bool      gpu_mplane;       /* mask plane on copies                       */
    bool      gpu_imm;          /* immediate source (blns_gpu_blit_imm)       */
    /* Limits */
    uint16_t  size_max;         /* largest rectangle side and span: 2^min(dim_w, 14) - 1 */
    uint32_t  list_max;         /* largest command list in words              */
    /* DPI driver (DIF_TYPE 4/5; 0 otherwise): DPI_CAPS and its fields */
    uint32_t  dpi_caps;
    uint8_t   dpi_scaler;       /* 0 none, 1 nearest, 2 nearest and bilinear  */
    bool      dpi_ddc;          /* HDMI DDC (EDID)                            */
    bool      dpi_island;       /* HDMI mode (AVI InfoFrame)                  */
    bool      dpi_audio;        /* HDMI audio and the generic packet          */
    bool      gpu_line;         /* lines (blns_gpu_line_xy; anti-aliased with gpu_blend) */
    bool      gpu_bilinear;     /* bilinear texture sampling (blns_tex_t.bilinear; needs gpu_xy) */
} blns_caps_t;

typedef struct {                /* a GPU command list in VRAM (CALL)          */
    blns_wa_t addr;             /* where it starts                            */
    uint32_t  capacity;         /* words available at addr                    */
    uint32_t  count;            /* words recorded                             */
    uint32_t  pushes;           /* driver calls recorded (whole commands)     */
    bool      overflow;         /* the calls after 'pushes' did not fit       */
    uint32_t  fences;           /* fences recorded (FENCE AUTO): each call of
                                 * the list moves the fence tag by it          */
    uint32_t  tag;              /* fence tag pushed behind its last call      */
    bool      called;           /* tag is valid (false: never called, not busy) */
    uint8_t   aux_set, aux_clr; /* BLNS__AUX_* pointers the list sets / resets
                                 * (RESET_STATE): applied at each call        */
} blns_gpu_list_t;

/* The sessions of the per-item calls (private, in blns_t): set by their
 * *_begin / *_set call, committed only when that call returns BLNS_OK */
typedef struct {
    uint32_t          size, fill, bg; /* SET_SIZE word, colour, background      */
    uint32_t          word;      /* EXEC_EXPAND fields                         */
    uint32_t          fmt;       /* SET_SRC.SRC_FMT of the source              */
    uint32_t          imm_n;     /* data words of one blns_gpu_expand_imm glyph */
    uint16_t          src_pitch, w;
    uint16_t          pitch;     /* destination pitch (expand_begin; 0: none)  */
    bool              opaque;
    bool              empty;     /* a side of 0: the draws push nothing        */
} blns__exp_ses_t;

typedef struct {
    uint32_t          src, addr; /* SET_SRC word and texture base              */
    uint32_t          word;      /* SET_TEX word (shade 0)                     */
    uint32_t          shade;
    uint32_t          box;       /* SET_TEXBOX word, 0 without bound           */
    uint32_t          step;      /* SET_STEP operand of blns_gpu_tex_step      */
    uint32_t          transp;
    uint16_t          pitch;     /* destination pitch (tex_begin; 0: none)     */
    bool              transp_on;
    uint8_t           filt;      /* SET_AUX TEX_FILTER [1:0] (0 without bilinear) */
} blns__tex_ses_t;

typedef struct {                /* device handle: every field is read-only for
                                 * the application; the ones after pix_double
                                 * are private */
    BLNS_TypeDef     *regs;
    volatile uint8_t *vram;
    uint32_t          hclk_hz;
    uint32_t          version;  /* BLNS_ID (kept on BLNS_ERR_ID)              */
    blns_caps_t       caps;
    blns_mode_t       mode;     /* current depth (CTRL.GFX_MODE)              */
    uint16_t          width;    /* display size (DISP_SIZE)                   */
    uint16_t          height;
    uint16_t          refr_pitch; /* REFR_PITCH (0: the frame width)          */
    bool              pix_double; /* DISP_CFG.PIX_DOUBLE                      */
    /* waits */
    bool            (*wait_hook)(void *ctx);
    void             *wait_ctx;
    uint32_t          wait_polls;
    /* GPU stream */
    bool              gpu_on;    /* CTRL.GPU_EN as last written               */
    bool              fast;      /* GPU on, not recording, nothing skipped    */
    bool              nonblock;  /* blns_set_nonblocking                      */
    volatile uint8_t  recover_req; /* blns_gpu_recover_request (any context)  */
    uint8_t           epoch;     /* stream losses (recover, GPU_EN = 0): the
                                  * tag stamp of blns_gpu_fence_status        */
    bool              fence_lag; /* the next fence covers lost work           */
    bool              fence_fix; /* GPU_FENCE := fence_tag still to be pushed  */
    uint16_t          fifo_free; /* GPU FIFO words known to be free           */
    uint16_t          fifo_thr;  /* GPU_FIFO_LOW.THRESH as last written       */
    blns_gpu_list_t  *rec;       /* list being recorded                       */
    uint32_t          skip;      /* driver calls to drop (list spill)         */
    uint32_t          fence_tag; /* tag of the last fence pushed (24 bits)    */
    uint32_t          fence_b;   /* GPU_FENCE when the stream was last lost   */
    /* GPU settings as last pushed (sent again only when they change) */
    uint16_t          gst_known; /* BLNS__GST_*: which are known              */
    uint16_t          cur_pitch; /* address-mode destination base and pitch  */
    blns_pa_t         cur_base;
    int16_t           xy_x, xy_y; /* x/y position                             */
    uint32_t          gst_size, gst_fill, gst_transp, gst_mask;
    bool              gst_minv;
    uint32_t          gst_src, gst_src_addr; /* SET_SRC word and operand      */
    uint32_t          gst_tex;   /* SET_TEX word (with the shade)             */
    uint32_t          gst_step;  /* SET_STEP operand as last pushed           */
    int16_t           pen_x, pen_y; /* line pen (12.4) as last pushed (BLNS__GST_PEN) */
    /* sessions of the per-item calls */
    uint16_t          span_pitch; /* destination pitch of span_begin          */
    uint32_t          ses_fill;  /* span, x/y fill and triangle colour        */
    blns_pa_t         xy_origin; /* x/y surface                               */
    uint16_t          xy_pitch;
    bool              xy_set;    /* blns_gpu_xy_begin called                  */
    blns__exp_ses_t   exp;
    blns__tex_ses_t   tex;
    /* pointers and sessions set through the API (the GPU's values are known) */
    uint8_t           aux_set;   /* BLNS__AUX_*: remap table, mask plane      */
    uint8_t           rec_aux_set, rec_aux_clr, rec_aux_saved; /* while recording */
    uint8_t           ses_set;   /* BLNS__SESSION_*: span, expansion, texture */
    /* blns_lut_present */
    uint16_t          lut_frame;
    bool              lut_pending;
    /* hardware cursor: the position asked (blns_cursor_move) and the corner
     * of the frame sent in that surface (blns_cursor_origin) */
    int16_t           crs_x, crs_y, crs_ox, crs_oy;
    /* blend rule of the SET_ALPHA words (blns_gpu_blend_rule: BLNS_MIX_*) and
     * the TEX_FILTER as last pushed (known with BLNS__GST_TEX) */
    uint8_t           mix;
    uint8_t           gst_filt;
} blns_t;

/* Shadow bits of gst_known (private; the inline fast paths test them: their
 * masks are kept below 0x800, one immediate in RV32) */
#define BLNS__GST_SIZE      0x0001u
#define BLNS__GST_FILL      0x0002u
#define BLNS__FENCED        0x0004u     /* the last word pushed is a FENCE (cleared by every push) */
#define BLNS__SES_SPAN      0x0008u     /* a span session is begun (kept until forgotten) */
#define BLNS__GST_SRC       0x0010u
#define BLNS__GST_TEX       0x0020u
#define BLNS__GST_CUR       0x0040u     /* address-mode destination cur_base / cur_pitch */
#define BLNS__GST_XYDST     0x0080u     /* destination = the x/y surface     */
#define BLNS__GST_XYPOS     0x0100u     /* x/y position xy_x, xy_y           */
#define BLNS__SES_FILL      0x0200u     /* SET_FILL = ses_fill               */
#define BLNS__SES_EXP       0x0400u     /* size, fill, bg = the expansion's  */
#define BLNS__SES_TEX       0x0800u     /* source, SET_TEX, transparent, box, step = the texture's */
#define BLNS__GST_STEP      0x1000u
#define BLNS__GST_TRANSP    0x2000u
#define BLNS__GST_MASK      0x4000u
#define BLNS__GST_PEN       0x8000u     /* line pen pen_x, pen_y             */

/* Pointers set through the API (aux_set) and sessions begun (ses_set) */
#define BLNS__AUX_REMAP     0x01u       /* SET_AUX REMAP_TABLE (blns_gpu_remap_table) */
#define BLNS__AUX_MASK      0x02u       /* SET_AUX MASK_PLANE (blns_gpu_mask_plane)   */
#define BLNS__AUX_ALPHA     0x04u       /* SET_AUX ALPHA_PLANE (blns_gpu_alpha_plane) */
#define BLNS__SESSION_SPAN  0x01u       /* blns_gpu_span_begin                        */
#define BLNS__SESSION_EXP   0x02u       /* blns_gpu_expand_begin / _set               */
#define BLNS__SESSION_TEX   0x04u       /* blns_gpu_tex_begin / _set                  */

typedef struct {                /* a GPU surface: where a rectangle starts and how lines step */
    blns_pa_t addr;             /* pixel address of the first pixel visited   */
    uint16_t  pitch;            /* line stride in pixels; 0 = the display pitch (at the call) */
    uint8_t   swap;             /* BLNS_SWAP_* walk direction                 */
} blns_surf_t;

/*---------------------------------------------------------------------------
 * Controller (belenos.c)
 *---------------------------------------------------------------------------*/

/* Bind the handle, check the ID, read the build configuration and put the
 * controller in a known state: refresh stopped, interrupts off, GPU disabled
 * (blns_gpu_enable then resets every GPU setting), frame 0 at pixel address
 * 0, LUT off, orientation and pixel doubling off, REFR_PITCH 0, the hardware
 * cursor hidden at (0, 0) with its hotspot at (0, 0). Kept as the
 * previous program left them, and read back into the handle: the depth and
 * the display size (DISP_SIZE). Kept running on purpose: the DPI timing, the
 * HDMI link and its InfoFrames, so a chained program does not blank the
 * monitor. BLNS_ERR_ID: dev->version holds the ID read. BLNS_ERR_CONFIG: a
 * feature the platform header states (BLNS_HW_*, belenos_hw.h) differs from
 * the hardware (dev->caps holds what was read; nothing is written). */
blns_status_t blns_init(blns_t *dev, const blns_config_t *cfg);

blns_status_t blns_set_mode(blns_t *dev, blns_mode_t mode);
blns_status_t blns_set_size(blns_t *dev, uint16_t width, uint16_t height);
blns_status_t blns_set_orientation(blns_t *dev, uint8_t swap);
/* Pixel doubling: the refresh shows a ceil(W/2) x ceil(H/2) frame (pitch
 * ceil(W/2)) at W x H; the default GPU pitch follows */
void          blns_set_pix_double(blns_t *dev, bool enable);
/* Refresh line pitch in source pixels (0 = the frame width), taken at the next
 * frame start: a frame window into a wider surface (hardware scrolling). The
 * display pitch then is this one: blns_pixel_addr and pitch 0 of the GPU
 * calls follow it. */
void          blns_set_pitch(blns_t *dev, uint16_t pitch);
/* The display line pitch: REFR_PITCH when set, else the frame width (halved,
 * rounded up, with pixel doubling) */
BLNS_ALWAYS_INLINE uint16_t blns_display_pitch(const blns_t *dev)
{
    if (dev->refr_pitch != 0u)
        return dev->refr_pitch;
    return dev->pix_double ? (uint16_t) ((dev->width + 1u) / 2u) : dev->width;
}

/* Frame pointers (pixel addresses) and their routing */
blns_status_t blns_set_frame(blns_t *dev, unsigned n, blns_pa_t addr);
blns_status_t blns_select_frame(blns_t *dev, unsigned refresh);

/* Refresh: a period in hclk cycles (timer: 1 .. 2^28 - 1, else BLNS_ERR_PARAM),
 * a frame rate, or one frame on demand */
blns_status_t blns_refresh_period(blns_t *dev, uint32_t cycles);
blns_status_t blns_refresh_rate(blns_t *dev, uint32_t frames_per_second);
void          blns_refresh_stop(blns_t *dev);
void          blns_refresh_once(blns_t *dev);
bool          blns_refresh_running(const blns_t *dev);

/* Frames reach the panel: the refresh timer runs, or the DPI driver is on */
bool          blns_frames_flowing(const blns_t *dev);
/* Wait for the end of the next frame sent to the panel (FRAME_NUM; IRQ_FLAG
 * is left alone). BLNS_ERR_STATE when no frames flow. */
blns_status_t blns_wait_frame(blns_t *dev);
/* Wait for n frames (FRAME_NUM: any number of such waits coexist, FRAME_CNT
 * is left to the application); BLNS_ERR_STATE when frames do not flow, or
 * stop flowing before the n-th (a one-shot refresh) */
blns_status_t blns_wait_frames(blns_t *dev, uint16_t n);
/* Frames sent so far (FRAME_NUM, 16 bits, wrapping): non-blocking pacing,
 * (uint16_t) (blns_frame_num(dev) - n0) >= k */
static inline uint16_t blns_frame_num(const blns_t *dev)
{
    return (uint16_t) (dev->regs->FRAME_NUM & BLNS_FRAME_NUM_Msk);
}
/* Whether the last frame sent ended before its last pixel (STATUS.REFR_ABANDONED:
 * a DPI driver abandons a frame the refresh is too slow to deliver in time) */
static inline bool blns_frame_abandoned(const blns_t *dev)
{
    return (dev->regs->STATUS & BLNS_STATUS_REFR_ABANDONED_Msk) != 0u;
}
/* Double buffering: show frame 'show' from the next refresh on, and return
 * once no frame reads the buffer shown before: as soon as the refresh has
 * latched 'show' (FRAME_SEL.LATCHED), at once when flipping between frames
 * (and at once when no frames flow) */
blns_status_t blns_flip(blns_t *dev, unsigned show);
/* The same without waiting: blns_flip_done() tells when the buffer shown
 * before is free (FRAME_SEL.LATCHED), blns_flip_wait() waits for it (with the
 * wait hook and poll limit; at once when no frames flow) */
blns_status_t blns_flip_async(blns_t *dev, unsigned show);
bool          blns_flip_done(const blns_t *dev);
blns_status_t blns_flip_wait(blns_t *dev);

/* Colour: programmable LUT (RGB888 entries) and hardware palettes */
#if BLNS_HW_OFF(LUT)
static inline blns_status_t blns_lut_load(blns_t *dev, unsigned bank, unsigned first,
                                          const uint32_t *rgb888, unsigned count)
{ (void) dev; (void) bank; (void) first; (void) rgb888; (void) count; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_lut_load(blns_t *dev, unsigned bank, unsigned first,
                            const uint32_t *rgb888, unsigned count);
#endif
#if BLNS_HW_OFF(LUT)
static inline blns_status_t blns_lut_select(blns_t *dev, bool enable, unsigned bank)
{ (void) dev; (void) bank; return enable ? BLNS_ERR_ABSENT : BLNS_OK; }
#else
blns_status_t blns_lut_select(blns_t *dev, bool enable, unsigned bank);
#endif
/* Double-buffered palette: entries 0 .. count-1 into the bank the refresh
 * does not use, then that bank selected (and the LUT enabled): shown from
 * the next frame, without a tear. A second call waits until the first one
 * has been taken (one frame start). With one bank: loaded in place. */
#if BLNS_HW_OFF(LUT)
static inline blns_status_t blns_lut_present(blns_t *dev, const uint32_t *rgb888, unsigned count)
{ (void) dev; (void) rgb888; (void) count; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_lut_present(blns_t *dev, const uint32_t *rgb888, unsigned count);
#endif
/* Hardware palette (palette 0-7, bg and fg 0-15, else BLNS_ERR_PARAM) */
blns_status_t blns_hw_palette(blns_t *dev, unsigned palette, unsigned bg, unsigned fg);
/* Palette rotation: pixel values first..last look up the entry 'offset'
 * further on in that range (wrapping), from the next frame on */
#if BLNS_HW_OFF(LUT)
static inline blns_status_t blns_lut_rotate(blns_t *dev, uint8_t first, uint8_t last,
                                            uint8_t offset)
{ (void) dev; (void) first; (void) last; (void) offset; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_lut_rotate(blns_t *dev, uint8_t first, uint8_t last, uint8_t offset);
#endif

/* Hardware cursor (caps.cursor, else BLNS_ERR_ABSENT): 32 x 32 pixels at 2 bpp
 * (0 transparent, 1-3 the RGB888 colours, no LUT) over the frame the refresh
 * sends, in its source pixels: it turns with the orientation and is doubled
 * and scaled with the picture. The shape block, the position, the hotspot
 * and show are taken at the next frame start (a move never tears), the
 * colours at once; a DBI panel shows a change with the next refresh.
 * Shape: 32 rows of 64 bits (rows[2j] pixels 0-15 of row j, rows[2j+1]
 * pixels 16-31, 2 bpp, pixel 0 in the low bits), written by rows and by
 * columns (the copy a CL swap reads) into the 128 words at word address
 * 'block' (a multiple of 128 inside the VRAM, else BLNS_ERR_PARAM), then
 * selected. To change a shape on screen without a torn frame, write it to
 * another block (blns_cursor_select switches back to one already written). */
#define BLNS_CURSOR_WORDS 128u      /* VRAM words of a shape block */
#if BLNS_HW_OFF(CURSOR)
static inline blns_status_t blns_cursor_shape(blns_t *dev, blns_wa_t block, const uint32_t rows[64])
{ (void) dev; (void) block; (void) rows; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_select(blns_t *dev, blns_wa_t block)
{ (void) dev; (void) block; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_colours(blns_t *dev, uint32_t c1, uint32_t c2, uint32_t c3)
{ (void) dev; (void) c1; (void) c2; (void) c3; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_hotspot(blns_t *dev, unsigned hx, unsigned hy)
{ (void) dev; (void) hx; (void) hy; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_move(blns_t *dev, int16_t x, int16_t y)
{ (void) dev; (void) x; (void) y; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_move_panel(blns_t *dev, int px, int py)
{ (void) dev; (void) px; (void) py; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_origin(blns_t *dev, int16_t x0, int16_t y0)
{ (void) dev; (void) x0; (void) y0; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_cursor_show(blns_t *dev, bool on)
{ (void) dev; return on ? BLNS_ERR_ABSENT : BLNS_OK; }
#else
blns_status_t blns_cursor_shape(blns_t *dev, blns_wa_t block, const uint32_t rows[64]);
blns_status_t blns_cursor_select(blns_t *dev, blns_wa_t block);
/* Colours 1-3, RGB888 ([31:24] ignored) */
blns_status_t blns_cursor_colours(blns_t *dev, uint32_t c1, uint32_t c2, uint32_t c3);
/* The shape pixel that points (0 .. 31 each, else BLNS_ERR_PARAM) */
blns_status_t blns_cursor_hotspot(blns_t *dev, unsigned hx, unsigned hy);
/* The hotspot's position: a pixel of the frame sent (source pixels, off-screen
 * and negative allowed), less the origin */
blns_status_t blns_cursor_move(blns_t *dev, int16_t x, int16_t y);
/* The same from a panel pixel: the DPI image placement and steps inverted
 * (without the DPI driver the panel takes the stream 1:1), then the
 * orientation and pixel doubling */
blns_status_t blns_cursor_move_panel(blns_t *dev, int px, int py);
/* A windowed refresh (frame pointer, DISP_SIZE and REFR_PITCH on the
 * sub-rectangle at (x0, y0) of a surface): positions are then surface pixels
 * and the cursor stays where it is on the surface; (0, 0) by default. Hide
 * the cursor instead with blns_cursor_show(dev, false). */
blns_status_t blns_cursor_origin(blns_t *dev, int16_t x0, int16_t y0);
blns_status_t blns_cursor_show(blns_t *dev, bool on);
#endif

/* Interrupts: enable mask, pending flags, clear (BLNS_IRQ_*_Msk; an unknown
 * bit in the enable mask: BLNS_ERR_PARAM). blns_irq_enable writes the whole
 * mask: OR the sources already enabled into it to add one. */
blns_status_t blns_irq_enable(blns_t *dev, uint32_t mask);
uint32_t      blns_irq_status(const blns_t *dev);
void          blns_irq_clear(blns_t *dev, uint32_t mask);
/* Interrupt service: read the pending flags of 'mask', clear them and return
 * them. With BLNS_IRQ_GPU_ERR among them a recover is requested
 * (blns_gpu_recover_request: the owner of dev performs it at its next GPU
 * call). Safe in an interrupt handler. */
uint32_t      blns_irq_service(blns_t *dev, uint32_t mask);

/* Non-blocking mode: a GPU call that does not find room for all of its words
 * in the FIFO, or a DPI setter while an earlier update is pending, returns
 * BLNS_ERR_BUSY with nothing sent and nothing changed (a GPU call longer than
 * the FIFO: unless the FIFO is empty, then it goes on as when blocking; lists
 * being recorded are not affected): a game goes on with CPU work while a
 * present waits for the frame end */
void          blns_set_nonblocking(blns_t *dev, bool on);

/* Debug freeze while the core is halted (DBG_CTRL) */
void          blns_debug_freeze(blns_t *dev, bool refresh, bool gpu);

/*---------------------------------------------------------------------------
 * VRAM access
 *---------------------------------------------------------------------------*/
/* Pixel address of (x, y) in a frame starting at 'base', with the display
 * pitch (blns_display_pitch: REFR_PITCH when set, else the frame width) */
static inline blns_pa_t blns_pixel_addr(const blns_t *dev, blns_pa_t base, uint32_t x, uint32_t y)
{
    return base + y * blns_display_pitch(dev) + x;
}

/* VRAM window views. The pixel indexing of blns_vram16 assumes a
 * little-endian CPU (as the VRAM's byte order is). */
static inline volatile uint8_t  *blns_vram8 (const blns_t *dev) { return dev->vram; }
static inline volatile uint16_t *blns_vram16(const blns_t *dev) { return (volatile uint16_t *) dev->vram; }
static inline volatile uint32_t *blns_vram32(const blns_t *dev) { return (volatile uint32_t *) dev->vram; }

/* Pixel address <-> pointer into the window, at the current depth (below 8 bpp
 * the pointer is the byte that holds the pixel) */
static inline volatile void *blns_vram_ptr(const blns_t *dev, blns_pa_t pa)
{
    return (volatile void *) (dev->vram + (dev->mode == BLNS_BPP_16 ? pa * 2u : pa >> (3u - (unsigned) dev->mode)));
}
static inline blns_pa_t blns_vram_pa(const blns_t *dev, const volatile void *p)
{
    const uint32_t off = (uint32_t) ((const volatile uint8_t *) p - dev->vram);
    return dev->mode == BLNS_BPP_16 ? off / 2u : off << (3u - (unsigned) dev->mode);
}
static inline bool blns_vram_contains(const blns_t *dev, const volatile void *p)
{
    const volatile uint8_t *b = (const volatile uint8_t *) p;
    return b >= dev->vram && (size_t) (b - dev->vram) < (size_t) dev->caps.vram_words * 4u;
}
static inline blns_wa_t blns_vram_wa(const blns_t *dev, const volatile void *p)
{
    return (blns_wa_t) ((uint32_t) ((const volatile uint8_t *) p - dev->vram) / 4u);
}
/* The bit address (1-bpp pixel address: EXPAND sources, the mask plane) of
 * the first bit of the byte at 'p' */
static inline blns_ba_t blns_vram_ba(const blns_t *dev, const volatile void *p)
{
    return (blns_ba_t) ((uint32_t) ((const volatile uint8_t *) p - dev->vram) * 8u);
}

/* A surface for a width x height GPU rectangle (the sizes of the GPU call)
 * whose top-left pixel on screen is 'top_left', walked by 'swap': addr
 * becomes the first pixel visited (the right column with BLNS_SWAP_X, the
 * bottom row with BLNS_SWAP_Y). With BLNS_SWAP_CL the run (width) is
 * vertical: the rectangle covers height columns and width lines. Pitch 0 is
 * the display pitch, resolved here (the address depends on it) and stored. */
static inline blns_surf_t blns_surf_rect(const blns_t *dev, blns_pa_t top_left, uint16_t pitch,
                                         uint16_t width, uint16_t height, uint8_t swap)
{
    const uint32_t cols = (swap & BLNS_SWAP_CL) ? height : width;
    const uint32_t rows = (swap & BLNS_SWAP_CL) ? width : height;
    blns_surf_t s;
    s.pitch = pitch ? pitch : blns_display_pitch(dev);
    s.addr  = top_left + ((swap & BLNS_SWAP_X) && cols ? cols - 1u : 0u) +
                         ((swap & BLNS_SWAP_Y) && rows ? (rows - 1u) * s.pitch : 0u);
    s.swap  = swap;
    return s;
}

/* CPU -> VRAM rectangle at 16 bpp (or 8 bpp: 'bytes' rows): width pixels of
 * height rows from 'src' (src_stride bytes apart) to pixel address 'pa'
 * (pitch pixels apart, 0 = the display pitch); 32-bit stores when the row
 * and the source allow, unrolled, a BLNS_WMB() at the end. Below 8 bpp:
 * BLNS_ERR_PARAM. The read counterpart copies a rectangle out (screenshots).
 * Both take the source first, then the destination, as the GPU copies. */
blns_status_t blns_vram_write_rect(blns_t *dev, const void *src, uint32_t src_stride, blns_pa_t pa,
                                   uint16_t pitch, uint16_t width, uint16_t height);
blns_status_t blns_vram_read_rect(const blns_t *dev, blns_pa_t pa, uint16_t pitch, void *dst,
                                  uint32_t dst_stride, uint16_t width, uint16_t height);
/* ARGB8888 -> RGB565A8 for staging: colours truncated as LV_COLOR_24_TO_16
 * (the rule that makes the GPU's blend bit-exact with LVGL's ARGB8888 path),
 * alphas copied. 'rgb' and 'a8' point into the VRAM window (or anywhere);
 * pitches in pixels; a BLNS_WMB() at the end. */
void          blns_argb8888_to_rgb565a8(uint16_t *rgb, uint8_t *a8, unsigned pitch,
                                        const uint32_t *argb, unsigned src_pitch,
                                        unsigned w, unsigned h);

/*---------------------------------------------------------------------------
 * GPU (blns_gpu.c)
 *---------------------------------------------------------------------------*/
/* Enable: every GPU setting back to its reset value (RESET_STATE), so nothing
 * of a previous program (clip, gradient, alpha, texture) leaks in */
blns_status_t blns_gpu_enable(blns_t *dev, bool enable);

/* Push command words, waiting for FIFO space. The helpers then re-send every
 * setting (destination, x/y position, size, colours). A call of up to the
 * FIFO depth waits for room for all of it before the first word: a timeout
 * sends nothing. A longer one writes words as room appears (the driver does
 * not parse raw words: a call may start or end inside a command): a timeout
 * or a GPU error in it ends it with blns_gpu_discard, so the stream stays in
 * step (the command it cut is dropped, the words before it run). A helper
 * call longer than the FIFO (a textured triangle or an affine blit sending
 * every setting again can exceed 16 words; in an 8-word FIFO outlines,
 * blits, triangles and textured spans too) goes command by command, each
 * with its operand (SET_SRC IMM with its EXEC): a timeout returns
 * BLNS_ERR_TIMEOUT between two commands, every setting sent again by the
 * next call; the commands sent run (an outline may be partly drawn). A
 * timeout inside immediate data discards the rectangle it cut (the pixels
 * already drawn stay). Non-blocking, a call longer than the FIFO returns
 * BLNS_ERR_BUSY unless the FIFO is empty. */
blns_status_t blns_gpu_push(blns_t *dev, const uint32_t *words, unsigned count);
/* The helpers send SET_SIZE, SET_FILL, SET_TRANSP, SET_SRC, SET_TEX and the
 * line pen only when they change, and count the free FIFO words between GPU_STAT reads. When
 * something else changed the GPU settings (another bus manager, a list called
 * by other means) call blns_gpu_forget: the helpers then send every setting
 * again. Only this driver may write GPU_CMD (another writer breaks the count). */
void          blns_gpu_forget(blns_t *dev);
/* Free FIFO words now (GPU_STAT.FREE, also refreshing the count); 0 without
 * a GPU */
unsigned      blns_gpu_space(blns_t *dev);
/* Wait until 'words' FIFO words are free (blocking, polling with the wait
 * hook; BLNS_ERR_PARAM above caps.gpu_fifo_depth, BLNS_ERR_GPU when the
 * decoder stopped or the GPU is disabled). Before its first hook call it sets
 * GPU_FIFO_LOW.THRESH to words - 1 (the write re-arms the event), so a hook
 * that sleeps until a Belenos interrupt with BLNS_IRQ_GPU_FIFO_LOW enabled
 * wakes when the words fit; the threshold of blns_gpu_fifo_low_set is
 * written back at the end (which may raise the flag again). */
blns_status_t blns_gpu_wait_space(blns_t *dev, unsigned words);
/* Make a cut stream whole without flushing (GPU_CTRL.DISCARD): when the last
 * words pushed stop inside a command (an operand or immediate data still
 * owed, or SET_SRC IMM without its EXEC), the GPU drops that command when it
 * reaches it (the settings its command word set are kept; a cut immediate
 * rectangle is abandoned, the pixels already drawn stay) and the complete
 * work queued before it runs. Nothing happens otherwise. The driver calls it
 * itself where a call stops inside a command (a timeout or a GPU error in a
 * raw push or in immediate data). Owner context only: from another context
 * it could cut a command the owner is pushing (blns_gpu_recover_request is
 * the way there). Every setting is sent again by the next call.
 * BLNS_ERR_ABSENT without a GPU. */
blns_status_t blns_gpu_discard(blns_t *dev);


/* Rectangles: width or height 0 draws nothing (BLNS_OK); above
 * caps.size_max: BLNS_ERR_PARAM */
blns_status_t blns_gpu_fill(blns_t *dev, const blns_surf_t *dst, uint16_t width, uint16_t height,
                            uint32_t colour, blns_rop_t rop);
blns_status_t blns_gpu_copy(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                            uint16_t width, uint16_t height, blns_rop_t rop);
blns_status_t blns_gpu_copy_transp(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                                   uint16_t width, uint16_t height, blns_rop_t rop,
                                   uint32_t transparent);
/* Palette remap (caps.gpu_remap, else BLNS_ERR_ABSENT): the table is one byte
 * per entry (entry i at byte i, the low bpp bits used) at 'table', a multiple
 * of 64 words (BLNS_ERR_PARAM otherwise, or past the VRAM). Always sent
 * (never cached): call it again after changing the table's contents. No
 * effect at 16 bpp. A remap (blit, expansion, texture, remap_rect,
 * remap_tri_xy) before this call returns BLNS_ERR_STATE with nothing sent:
 * the pointer must be one the API set. An expansion or texture session
 * begun with a remap is checked at each draw (expand, tex_span, texrect_xy,
 * tritex_xy, ...): the session outlives the pointer. It is unknown again
 * after RESET_STATE (blns_gpu_enable(true),
 * blns_gpu_reset_state), blns_gpu_recover (a SET_AUX still in the FIFO is
 * flushed) and blns_gpu_forget; GPU_EN = 0 keeps it. A list without
 * BLNS_LIST_INHERIT starts with it unknown (it sets its own); the pointers a
 * list sets or resets apply to the caller at each blns_gpu_list_call. */
#if BLNS_HW_OFF(GPU_REMAP)
static inline blns_status_t blns_gpu_remap_table(blns_t *dev, blns_wa_t table)
{ (void) dev; (void) table; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_remap_table(blns_t *dev, blns_wa_t table);
#endif
/* Mask plane (caps.gpu_mplane, else BLNS_ERR_ABSENT): 'mask' is the bit
 * address (1-bpp pixel address) of the mask bit of the source's first pixel;
 * the mask's pitch is the source pitch in pixels. invert: draw where the bit
 * is 0. A blit with mplane before it: BLNS_ERR_STATE, the same rules as the
 * remap table. */
#if BLNS_HW_OFF(GPU_MPLANE)
static inline blns_status_t blns_gpu_mask_plane(blns_t *dev, blns_ba_t mask, bool invert)
{ (void) dev; (void) mask; (void) invert; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_mask_plane(blns_t *dev, blns_ba_t mask, bool invert);
#endif
/* Blend rule (caps.gpu_blend, else BLNS_ERR_ABSENT; BLNS_MIX_ROUND is always
 * accepted): BLNS_MIX_ROUND (reset) rounds an 8-bit factor; BLNS_MIX5 is
 * LVGL's (5-bit factor (a + 4) >> 3, truncated; coverage x A as (c * A) >>
 * 8): bit-exact with lv_color_16_16_mix. Sent with the next SET_ALPHA word
 * (blns_gpu_alpha), tracked as a setting: nothing is pushed here. A session
 * setting: kept by a recover and by lists, back to BLNS_MIX_ROUND at
 * blns_gpu_reset_state (blns_gpu_enable(true)). */
typedef enum { BLNS_MIX_ROUND = 0, BLNS_MIX5 = 1 } blns_mix_t;
#if BLNS_HW_OFF(GPU_BLEND)
static inline blns_status_t blns_gpu_blend_rule(blns_t *dev, blns_mix_t rule)
{ (void) dev; return (rule != BLNS_MIX_ROUND) ? BLNS_ERR_ABSENT : BLNS_OK; }
#else
blns_status_t blns_gpu_blend_rule(blns_t *dev, blns_mix_t rule);
#endif
/* Alpha plane of an RGB565A8 source (caps.gpu_blend, else BLNS_ERR_ABSENT):
 * 'alpha' is the byte address of the alpha of the source's first pixel (the
 * copy's src->addr, or texel (0, 0) of a texture); its pitch is the source
 * pitch in pixels (the alpha of source pixel p at alpha + (p - base)); past
 * the VRAM: BLNS_ERR_PARAM. Always sent (2 words). A blit or texture with
 * src_alpha before it: BLNS_ERR_STATE, the same rules as the remap table (a
 * texture session begun with src_alpha is checked at each draw). */
#if BLNS_HW_OFF(GPU_BLEND)
static inline blns_status_t blns_gpu_alpha_plane(blns_t *dev, uint32_t alpha)
{ (void) dev; (void) alpha; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_alpha_plane(blns_t *dev, uint32_t alpha);
#endif
/* The alpha byte address of pixel 'px' of an image whose pixel 'base' has its
 * alpha at byte 'plane' (LVGL layout: plane = 2 * base + stride * h, the alpha
 * pitch = the pitch) */
static inline uint32_t blns_alpha_of(blns_pa_t px, blns_pa_t base, uint32_t plane)
{ return plane + (uint32_t) (px - base); }
typedef struct {                /* blns_gpu_blit options (zero: a plain copy, op S) */
    blns_rop_t   rop;           /* BLNS_ROP_FILL_IF_S: the session colour
                                 * (blns_gpu_colour_set) where S is not
                                 * transparent, a one-colour silhouette          */
    bool         transp;        /* skip source pixels equal to 'transparent'  */
    uint32_t     transparent;   /* also the colour ops 13-15 compare with      */
    bool         mplane;        /* only where the mask plane allows (blns_gpu_mask_plane) */
    blns_remap_t remap;         /* through the table of blns_gpu_remap_table  */
    bool         src_alpha;     /* RGB565A8: each pixel blended with its alpha
                                 * (blns_gpu_alpha_plane; caps.gpu_blend; no
                                 * effect below 16 bpp); with mplane or the
                                 * immediate source: BLNS_ERR_PARAM            */
} blns_blit_t;
/* A copy with every option: blns_gpu_copy and copy_transp are this with
 * mplane false, remap off and no src_alpha. A feature not built:
 * BLNS_ERR_ABSENT before anything is pushed. */
blns_status_t blns_gpu_blit(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                            uint16_t width, uint16_t height, const blns_blit_t *b);
/* Immediate source (caps.gpu_imm, else BLNS_ERR_ABSENT): a copy whose source
 * pixels are pushed through GPU_CMD behind the command, in order with the
 * GPU's drawing (no staging in VRAM, no fence). 'data' holds width x height
 * pixels at the current depth, packed row after row with no padding (rows
 * are not word-aligned: pixel k at bit (k * bpp) % 32 of word k * bpp / 32,
 * little-endian), ceil(width * height * bpp / 32) words. The options of b
 * apply (transparency, raster op, remap; the mask plane with the mask pitch
 * = width); dst->swap mirrors (no source swap). Not in a list (BLNS_ERR_PARAM:
 * a list carries no data). The words are pushed with the FIFO's FREE counted
 * as for every helper. */
#if BLNS_HW_OFF(GPU_IMM)
static inline blns_status_t blns_gpu_blit_imm(blns_t *dev, const blns_surf_t *dst, uint16_t width,
                                              uint16_t height, const blns_blit_t *b,
                                              const uint32_t *data)
{ (void) dev; (void) dst; (void) width; (void) height; (void) b; (void) data;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_blit_imm(blns_t *dev, const blns_surf_t *dst, uint16_t width, uint16_t height,
                                const blns_blit_t *b, const uint32_t *data);
#endif
/* The remap table applied to a rectangle of the destination (FILL, DST remap,
 * op S): fades, tints, shadows. Palette depths only (at 16 bpp the GPU would
 * fill the rectangle: BLNS_ERR_PARAM); blns_gpu_remap_rect_xy (x/y) and
 * blns_gpu_remap_tri_xy (a triangle) alike */
#if BLNS_HW_OFF(GPU_REMAP)
static inline blns_status_t blns_gpu_remap_rect(blns_t *dev, const blns_surf_t *dst, uint16_t width,
                                                uint16_t height)
{ (void) dev; (void) dst; (void) width; (void) height; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_remap_rect(blns_t *dev, const blns_surf_t *dst, uint16_t width, uint16_t height);
#endif

/* The colour of the spans, x/y fills, triangles and op-15 copies
 * (BLNS_ROP_FILL_IF_S: a silhouette) that follow (the session colour of
 * span_begin / xy_begin), without a destination. Nothing is pushed until a
 * call draws. */
void          blns_gpu_colour_set(blns_t *dev, uint32_t colour);

/* Spans: one-pixel-high runs in the session colour (ROP S, no swaps).
 * span_begin sets the colour and the surface pitch; each span costs one FIFO
 * word, or three when its start is more than 8191 pixels away from the
 * previous destination; a width of 0 draws nothing. The per-item calls
 * (span, expand, tex_span) keep their session (colour, size, source,
 * texture) across other calls: what a fill or a copy changed in between is
 * sent again. Before their session they return BLNS_ERR_STATE: span after
 * span_begin; the address-mode expand and expand_imm after expand_begin
 * (its destination pitch), expand_xy and text_xy after expand_begin or _set;
 * tex_span after tex_begin (its destination pitch), tex_shade, tex_step,
 * texrect and tritex after tex_begin or _set. Each session (span, expansion,
 * texture) keeps its own destination pitch. A *_begin / *_set call that does
 * not return BLNS_OK changes no session. Sessions are the driver's and
 * survive recover, enable and lists (blns_init clears them). */
blns_status_t blns_gpu_span_begin(blns_t *dev, blns_pa_t addr, uint16_t pitch, uint32_t colour);
blns_status_t blns__gpu_span(blns_t *dev, blns_pa_t addr, uint16_t width);
/* Colour expansion (text, icons): a 1/2/4 bpp source in VRAM drawn in the
 * current depth. Value 0 is transparent (or the background with opaque),
 * value v the colour + v - 1 (palette depths: a 2/4/8 bpp source without mask
 * is refused at 16 bpp, BLNS_ERR_PARAM). expand_begin sets the rectangle size, the
 * colours and the destination surface; each blns_gpu_expand() then draws one
 * glyph from 'src' (source pixel address) at 'dst': three FIFO words, five
 * when 'dst' is more than 8191 pixels from the previous destination. A
 * glyph size with a side of 0 draws nothing (each draw returns BLNS_OK with
 * nothing pushed); above caps.size_max: BLNS_ERR_PARAM. */
typedef struct {
    uint16_t     width, height; /* glyph size in pixels                       */
    uint16_t     src_pitch;     /* source line stride in source pixels; 0 = width (packed) */
    uint8_t      depth;         /* BLNS_EXP_1BPP / 2BPP / 4BPP / 8BPP         */
    bool         opaque;        /* value 0 writes 'bg' instead of nothing     */
    bool         mask;          /* 16 bpp: values are coverage (blend 'colour') */
    uint8_t      swap;          /* BLNS_SWAP_* of the destination walk        */
    blns_rop_t   rop;           /* raster op on the expanded colour (0 = S); ops 13-15
                                 * write 0, ones or 'colour' where the value is not 0
                                 * (a one-colour silhouette with 15)          */
    blns_remap_t remap;         /* the expanded colour (SRC) or the
                                 * destination (DST) through the remap table  */
} blns_expand_t;
#define BLNS_EXP_1BPP    0u
#define BLNS_EXP_2BPP    1u
#define BLNS_EXP_4BPP    2u
#define BLNS_EXP_8BPP    3u
blns_status_t blns_gpu_expand_begin(blns_t *dev, const blns_expand_t *e, blns_pa_t dst,
                                    uint16_t dst_pitch, uint32_t colour, uint32_t bg);
blns_status_t blns__gpu_expand(blns_t *dev, blns_pa_t src, blns_pa_t dst);
/* The same with the glyph pushed through GPU_CMD (caps.gpu_imm, else
 * BLNS_ERR_ABSENT; not in a list, BLNS_ERR_PARAM): 'data' holds the
 * width x height values of expand_begin, packed with no row padding
 * (ceil(width * height * depth / 32) words, as blns_gpu_blit_imm); the
 * src_pitch of expand_begin is ignored. 1-bpp fonts from ROM. */
#if BLNS_HW_OFF(GPU_IMM)
static inline blns_status_t blns_gpu_expand_imm(blns_t *dev, blns_pa_t dst, const uint32_t *data)
{ (void) dev; (void) dst; (void) data; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_expand_imm(blns_t *dev, blns_pa_t dst, const uint32_t *data);
#endif
/* Textured spans (scaled / rotated images, texture mapping): a run of N
 * pixels reading the texture at (u, v), stepped by (du, dv) per pixel. u, v
 * are unsigned 10.6 texel coordinates, du, dv signed 5.11 steps (BLNS_UV(),
 * BLNS_STEP()). A power-of-two texture wraps; a free-pitch one does not. */
typedef struct {
    blns_pa_t    addr;          /* texture base pixel address                 */
    uint16_t     pitch;         /* free_pitch: line stride (0 = display pitch) */
    uint8_t      log2_w, log2_h; /* power-of-two size (ignored with free_pitch)*/
    bool         free_pitch;
    bool         transp;        /* skip texels equal to 'transparent'         */
    uint32_t     transparent;
    uint8_t      swap;          /* BLNS_SWAP_* of the run (CL: vertical)      */
    bool         bound;         /* skip texels outside box_w x box_h (u, v signed) */
    uint16_t     box_w, box_h;  /* the texture box with bound (up to 512 x 512) */
    blns_remap_t remap;         /* texel + shade (SRC) or the destination (DST)
                                 * through the remap table                     */
    bool         src_alpha;     /* RGB565A8 texture: each texel blended with its
                                 * alpha (blns_gpu_alpha_plane; caps.gpu_blend) */
    bool         bilinear;      /* bilinear sampling (caps.gpu_bilinear, else
                                 * BLNS_ERR_ABSENT; nearest below 16 bpp, and
                                 * with transp without caps.gpu_blend)         */
    bool         border_transparent; /* with bound (else BLNS_ERR_PARAM): taps
                                 * outside the box transparent (anti-aliased
                                 * edges; caps.gpu_blend), else clamped        */
} blns_tex_t;
#define BLNS_UV(f)       ((uint16_t) ((f) * 64.0f))      /* constant expressions only */
#define BLNS_STEP(f)     ((int16_t) ((f) * 2048.0f))
/* Texture, destination surface and shade (texel + shade: palette depths, a
 * non-zero shade is refused at 16 bpp, BLNS_ERR_PARAM; log2_w / log2_h above
 * 10, or a box above 512 x 512 with bound: BLNS_ERR_PARAM); then per span.
 * The filter (bilinear, border_transparent) is sent with the texture when it
 * changes (SET_AUX TEX_FILTER, 2 words). Bilinear sampling: the taps at
 * (u - 1/2, v - 1/2) + {0, 1}^2 with 5-bit weights, premultiplied by their
 * alpha; a power-of-two texture wraps, a free-pitch one reads on (bound
 * keeps the taps in the box). */
blns_status_t blns_gpu_tex_begin(blns_t *dev, const blns_tex_t *t, blns_pa_t dst,
                                 uint16_t dst_pitch, uint8_t shade);
/* The texture, transparency and shade without a destination (x/y mode) */
blns_status_t blns_gpu_tex_set(blns_t *dev, const blns_tex_t *t, uint8_t shade);
blns_status_t blns_gpu_tex_shade(blns_t *dev, uint8_t shade);                /* 1 word  */
blns_status_t blns_gpu_tex_step(blns_t *dev, int16_t du, int16_t dv);       /* 2 words */
/* One span from (u0, v0): 3 words, 5 when 'dst' is far from the previous one */
blns_status_t blns__gpu_tex_span(blns_t *dev, blns_pa_t dst, uint16_t n, uint16_t u0, uint16_t v0);

/* x/y destinations (LVGL-style coordinates): 'origin' is pixel (0, 0) of the
 * surface, 'pitch' its line stride (0 = display pitch), 'colour' the session
 * colour; every rectangle then starts at a signed (x, y) (-2048 .. 2047,
 * else BLNS_ERR_PARAM: clip to the visible area first) and is clipped by the
 * window set with blns_gpu_clip (inclusive; reset: no clipping). An
 * address-mode call (blns_gpu_fill, span_begin, ...) in between is fine: the
 * next x/y call sends the surface again. Without blns_gpu_xy_begin first:
 * BLNS_ERR_STATE. */
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_xy_begin(blns_t *dev, blns_pa_t origin, uint16_t pitch,
                                              uint32_t colour)
{ (void) dev; (void) origin; (void) pitch; (void) colour; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_xy_begin(blns_t *dev, blns_pa_t origin, uint16_t pitch, uint32_t colour);
#endif
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_clip(blns_t *dev, int x0, int y0, int x1, int y1)
{ (void) dev; (void) x0; (void) y0; (void) x1; (void) y1; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_clip(blns_t *dev, int x0, int y0, int x1, int y1);
#endif
#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns__gpu_span_xy(blns_t *dev, int x, int y, uint16_t width);
#endif
#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns__gpu_fill_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height);
#endif
/* Affine blit: W x H at (x, y) from the texture of blns_gpu_tex_set, starting
 * at (u0, v0) (10.6), stepped by (du, dv) per pixel and (du_r, dv_r) per row
 * (signed 5.11); with t->bound, texels outside the box are skipped */
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_texrect_xy(blns_t *dev, int x, int y, uint16_t width,
                                                uint16_t height, uint16_t u0, uint16_t v0,
                                                int16_t du, int16_t dv, int16_t du_r, int16_t dv_r)
{ (void) dev; (void) x; (void) y; (void) width; (void) height; (void) u0; (void) v0; (void) du;
  (void) dv; (void) du_r; (void) dv_r; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_texrect_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height,
                                  uint16_t u0, uint16_t v0, int16_t du, int16_t dv,
                                  int16_t du_r, int16_t dv_r);
#endif
/* Affine blit with exact start values from a 1/65536-texel model (LVGL's):
 * texel (u, v) of pixel (x + i, y + j) is (u_at_xy + du i + du_r j, v_at_xy +
 * dv i + dv_r j) / 65536. The driver splits the rectangle into tiles of at
 * most 64 x 64 and seeds each tile's (u0, v0) from that model (int64,
 * rounded to 10.6; the steps rounded to 5.11), so the walk drifts by less
 * than 0.03 texel. A step outside the 5.11 range (|step| >= 16 texels), or
 * a tile outside -2048 .. 2047: BLNS_ERR_PARAM with nothing pushed. One
 * blns_gpu_texrect_xy per tile: an error, BLNS_ERR_BUSY or BLNS_ERR_TIMEOUT
 * may come after earlier tiles were drawn. */
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_texrect_fx_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height,
                                                   int64_t u_at_xy, int64_t v_at_xy, int32_t du, int32_t dv,
                                                   int32_t du_r, int32_t dv_r)
{ (void) dev; (void) x; (void) y; (void) width; (void) height; (void) u_at_xy; (void) v_at_xy; (void) du;
  (void) dv; (void) du_r; (void) dv_r; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_texrect_fx_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height,
                                     int64_t u_at_xy, int64_t v_at_xy,  /* 1/65536 texel */
                                     int32_t du, int32_t dv, int32_t du_r, int32_t dv_r);
#endif
/* Blits in x/y mode: the width x height rectangle of 'src' (pixel address of
 * its first pixel, pitch, walk) drawn at (x, y), the first pixel visited as
 * for every x/y call, walked by 'swap' (BLNS_SWAP_*: a mirrored sprite), and
 * clipped by the window (only the visible part of the source is read).
 * copy_transp skips source pixels equal to 'transparent' (sprites). */
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_copy_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                                             uint16_t width, uint16_t height, uint8_t swap,
                                             blns_rop_t rop)
{ (void) dev; (void) src; (void) x; (void) y; (void) width; (void) height; (void) swap; (void) rop;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_copy_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                               uint16_t width, uint16_t height, uint8_t swap, blns_rop_t rop);
#endif
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_copy_transp_xy(blns_t *dev, const blns_surf_t *src, int x,
                                                    int y, uint16_t width, uint16_t height,
                                                    uint8_t swap, blns_rop_t rop,
                                                    uint32_t transparent)
{ (void) dev; (void) src; (void) x; (void) y; (void) width; (void) height; (void) swap; (void) rop;
  (void) transparent; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_copy_transp_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                                      uint16_t width, uint16_t height, uint8_t swap, blns_rop_t rop,
                                      uint32_t transparent);
#endif
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_blit_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                                             uint16_t width, uint16_t height, uint8_t swap,
                                             const blns_blit_t *b)
{ (void) dev; (void) src; (void) x; (void) y; (void) width; (void) height; (void) swap; (void) b;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_blit_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                               uint16_t width, uint16_t height, uint8_t swap, const blns_blit_t *b);
#endif
#if BLNS_HW_OFF(GPU_REMAP)
static inline blns_status_t blns_gpu_remap_rect_xy(blns_t *dev, int x, int y, uint16_t width,
                                                   uint16_t height)
{ (void) dev; (void) x; (void) y; (void) width; (void) height; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_remap_rect_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height);
#endif
/* Colour expansion in x/y mode (glyphs, 1/2/4/8 bpp sprites): expand_set
 * takes the glyph size, format, colours, walk and op of 'e' without a
 * destination; each blns_gpu_expand_xy then draws one glyph from 'src' at
 * (x, y): 3 FIFO words on the row of the previous one, 4 elsewhere. */
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_expand_set(blns_t *dev, const blns_expand_t *e,
                                                uint32_t colour, uint32_t bg)
{ (void) dev; (void) e; (void) colour; (void) bg; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_expand_set(blns_t *dev, const blns_expand_t *e, uint32_t colour, uint32_t bg);
#endif
#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns__gpu_expand_xy(blns_t *dev, blns_pa_t src, int x, int y);
#endif
/* FILL / SPAN gradient: fill + STEP (-8 .. 7) every n lines (per_pixel false)
 * or every n pixels along the run, a palette ramp (refused at 16 bpp,
 * BLNS_ERR_PARAM); enable false: plain fills */
#if BLNS_HW_OFF(GPU_GRAD)
static inline blns_status_t blns_gpu_gradient(blns_t *dev, bool enable, uint16_t n, bool per_pixel,
                                              int step)
{ (void) dev; (void) n; (void) per_pixel; (void) step; return enable ? BLNS_ERR_ABSENT : BLNS_OK; }
#else
blns_status_t blns_gpu_gradient(blns_t *dev, bool enable, uint16_t n, bool per_pixel, int step);
#endif
/* FILL / SPAN gradient at 16 bpp, per channel: every RGB565 field of the fill
 * colour + its step (dr, dg, db: -512 .. 511, in 1/64 of a field unit) every n
 * lines (per_pixel false) or every n pixels along the run, saturated; refused
 * below 16 bpp (BLNS_ERR_PARAM), BLNS_ERR_ABSENT without gpu_grad;
 * enable false: plain fills */
#if BLNS_HW_OFF(GPU_GRAD)
static inline blns_status_t blns_gpu_gradient_rgb(blns_t *dev, bool enable, uint16_t n,
                                                  bool per_pixel, int dr, int dg, int db)
{ (void) dev; (void) n; (void) per_pixel; (void) dr; (void) dg; (void) db;
  return enable ? BLNS_ERR_ABSENT : BLNS_OK; }
#else
blns_status_t blns_gpu_gradient_rgb(blns_t *dev, bool enable, uint16_t n, bool per_pixel,
                                    int dr, int dg, int db);
#endif
/* Blending (16 bpp): every draw mixes with the destination by 'alpha'
 * (0 .. 255, 255 = opaque); EXPAND with mask = true takes its source values as
 * coverage, an RGB565A8 source (src_alpha) its alpha bytes, times 'alpha'
 * when enabled. Ops 0-12 blend S, ops 13-15 their constant (0, ones, the
 * colour) where S is not transparent. enable false: plain writes. The word
 * carries the rule of blns_gpu_blend_rule (MIX5). */
#if BLNS_HW_OFF(GPU_BLEND)
static inline blns_status_t blns_gpu_alpha(blns_t *dev, bool enable, uint8_t alpha)
{ (void) dev; (void) alpha; return enable ? BLNS_ERR_ABSENT : BLNS_OK; }
#else
blns_status_t blns_gpu_alpha(blns_t *dev, bool enable, uint8_t alpha);
#endif
/* Flat triangle in x/y mode, in the session colour; vertices in 1/16 pixel
 * (12.4: pixel x = BLNS_SUB(x), -32768 .. 32767, else BLNS_ERR_PARAM),
 * clipped by the window */
#define BLNS_SUB(v)      ((int32_t) ((v) * 16))
#if BLNS_HW_OFF(GPU_TRI)
static inline blns_status_t blns_gpu_tri_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1,
                                            int32_t y1, int32_t x2, int32_t y2)
{ (void) dev; (void) x0; (void) y0; (void) x1; (void) y1; (void) x2; (void) y2;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_tri_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                              int32_t x2, int32_t y2);
#endif
/* The remap table applied to a triangle of the destination (EXEC_FILL TRI,
 * REMAP DST, op S): a shadow or a tint of any polygon. Vertices and clipping
 * as blns_gpu_tri_xy; the rules of blns_gpu_remap_rect */
#if BLNS_HW_OFF(GPU_TRI) || BLNS_HW_OFF(GPU_REMAP)
static inline blns_status_t blns_gpu_remap_tri_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1,
                                                  int32_t y1, int32_t x2, int32_t y2)
{ (void) dev; (void) x0; (void) y0; (void) x1; (void) y1; (void) x2; (void) y2;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_remap_tri_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                                    int32_t x2, int32_t y2);
#endif
/* Textured triangle in x/y mode (affine), from the texture of blns_gpu_tex_set
 * (its remap included): vertices x[3], y[3] in 1/16 pixel, (u0, v0) at vertex
 * 0 (10.6; signed with bound), (du, dv) per pixel and (du_r, dv_r) per row
 * (signed 5.11) */
#if BLNS_HW_OFF(GPU_TRI)
static inline blns_status_t blns_gpu_tritex_xy(blns_t *dev, const int32_t x[3], const int32_t y[3],
                                               uint16_t u0, uint16_t v0, int16_t du, int16_t dv,
                                               int16_t du_r, int16_t dv_r)
{ (void) dev; (void) x; (void) y; (void) u0; (void) v0; (void) du; (void) dv; (void) du_r;
  (void) dv_r; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_tritex_xy(blns_t *dev, const int32_t x[3], const int32_t y[3],
                                 uint16_t u0, uint16_t v0, int16_t du, int16_t dv,
                                 int16_t du_r, int16_t dv_r);
#endif
/* The four gradients of blns_gpu_tritex_xy from the (u, v) of each vertex
 * (10.6): du_dx, dv_dx, du_dy, dv_dy (5.11, rounded, saturated); false when
 * the triangle is degenerate */
bool          blns_gpu_tri_uv_gradients(const int32_t x[3], const int32_t y[3],
                                        const int32_t u[3], const int32_t v[3], int16_t g[4]);

/* Lines in x/y mode (caps.gpu_line, else BLNS_ERR_ABSENT), in the session
 * colour, clipped by the window; before blns_gpu_xy_begin: BLNS_ERR_STATE.
 * opt NULL: a solid line, op S, no remap. */
typedef struct {                /* blns_gpu_line_xy options (zero: solid, op S, no remap) */
    uint8_t  rop;               /* BLNS_ROP_* (ops 13-15 compare the colour with
                                 * SET_TRANSP: bg with opaque, else 0)          */
    uint8_t  remap;             /* BLNS_REMAP_OFF / SRC / DST (caps.gpu_remap)  */
    bool     aa;                /* anti-aliased: caps.gpu_blend, else BLNS_ERR_ABSENT;
                                   drawn solid below 16 bpp                     */
    bool     no_last;           /* the end pixel left out                       */
    bool     opaque;            /* dash gaps in 'bg' instead of skipped         */
    bool     phase_reset;       /* pattern phase 0 before this line             */
    uint16_t bg;                /* gap colour with opaque (SET_TRANSP, sent when changed) */
} blns_line_t;
/* Pattern: bit i = phase i, 1 draws; len 1 .. 32 (else BLNS_ERR_PARAM); resets
 * the phase. Always sent. blns_gpu_line_solid(): pattern ~0, len 32 (the reset
 * value; also set at the start of a list without BLNS_LIST_INHERIT) */
#if BLNS_HW_OFF(GPU_LINE)
static inline blns_status_t blns_gpu_line_pattern(blns_t *dev, uint32_t pattern, unsigned len)
{ (void) dev; (void) pattern; (void) len; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_line_pattern(blns_t *dev, uint32_t pattern, unsigned len);
#endif
static inline blns_status_t blns_gpu_line_solid(blns_t *dev) { return blns_gpu_line_pattern(dev, ~0u, 32u); }
/* One line, end points in 1/16 pixel (12.4: -32768 .. 32767, else
 * BLNS_ERR_PARAM; BLNS_SUB(x) + 8 is the centre of pixel x: blns_gpu_line_px()
 * does it). The pen (the GPU's start point) is tracked: LINE_PEN is pushed
 * only when (x0, y0) is not where the last line ended, so a connected segment
 * costs 2 words. The pattern phase carries from one line to the next. */
#if BLNS_HW_OFF(GPU_LINE)
static inline blns_status_t blns_gpu_line_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                                             const blns_line_t *opt)
{ (void) dev; (void) x0; (void) y0; (void) x1; (void) y1; (void) opt; return BLNS_ERR_ABSENT; }
static inline blns_status_t blns_gpu_line_px(blns_t *dev, int x0, int y0, int x1, int y1,
                                             const blns_line_t *opt)
{ (void) dev; (void) x0; (void) y0; (void) x1; (void) y1; (void) opt; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_line_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                               const blns_line_t *opt);
/* The same between pixel centres (x/y positions -2048 .. 2047) */
blns_status_t blns_gpu_line_px(blns_t *dev, int x0, int y0, int x1, int y1, const blns_line_t *opt);
#endif
/* Polyline of n points (xy[2n]: x0, y0, x1, y1, ... in 1/16 pixel): NO_LAST
 * on every segment but the last (which takes opt->no_last), or on all when
 * closed (the closing segment added), so each joint is drawn once; phase_reset
 * applies to the first segment, the phase carries across the corners. Every
 * point is checked before anything is pushed; then a batch, one push per
 * segment (2 words each after the first) as blns_gpu_fills_xy: an error or a
 * BLNS_ERR_BUSY / BLNS_ERR_TIMEOUT may come after earlier segments were sent.
 * n < 2: nothing drawn. */
#if BLNS_HW_OFF(GPU_LINE)
static inline blns_status_t blns_gpu_polyline_xy(blns_t *dev, const int32_t *xy, unsigned n, bool closed,
                                                 const blns_line_t *opt)
{ (void) dev; (void) xy; (void) n; (void) closed; (void) opt; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_polyline_xy(blns_t *dev, const int32_t *xy, unsigned n, bool closed,
                                   const blns_line_t *opt);
#endif
/* Outline of the w x h rectangle at (x, y) (the closed polyline of its corner
 * pixel centres: every edge pixel once, a dashed focus frame); w or h 0
 * draws nothing, w or h 1 is one line; its far corner outside -2048 .. 2047:
 * BLNS_ERR_PARAM. One push (at most 16 words: into a smaller FIFO command by
 * command, so a timeout may come after some edges were drawn). */
#if BLNS_HW_OFF(GPU_LINE)
static inline blns_status_t blns_gpu_rect_outline_xy(blns_t *dev, int x, int y, unsigned w, unsigned h,
                                                     const blns_line_t *opt)
{ (void) dev; (void) x; (void) y; (void) w; (void) h; (void) opt; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_rect_outline_xy(blns_t *dev, int x, int y, unsigned w, unsigned h,
                                       const blns_line_t *opt);
#endif

/* Batches: one call for many items, one FIFO check per FIFO-full (each item
 * as its single call: blns_gpu_span, fill_xy, expand_xy) */
typedef struct { blns_pa_t addr; uint16_t width; } blns_span_t;
typedef struct { int16_t x, y; uint16_t width, height; } blns_rect_t;
blns_status_t blns_gpu_spans(blns_t *dev, const blns_span_t *s, unsigned n);
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_fills_xy(blns_t *dev, const blns_rect_t *r, unsigned n)
{ (void) dev; (void) r; (void) n; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_fills_xy(blns_t *dev, const blns_rect_t *r, unsigned n);
#endif
/* n glyphs on one row from (x, y): glyph i from src[i], then x += advance[i]
 * (advance NULL: the glyph width of expand_set) */
#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_text_xy(blns_t *dev, int x, int y, const blns_pa_t *src,
                                             const int16_t *advance, unsigned n)
{ (void) dev; (void) x; (void) y; (void) src; (void) advance; (void) n; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_gpu_text_xy(blns_t *dev, int x, int y, const blns_pa_t *src,
                               const int16_t *advance, unsigned n);
#endif

/* Fences: a FENCE completes when every command before it is complete; it
 * then sets GPU_FENCE and, with irq, raises BLNS_IRQ_GPU_FENCE. The driver
 * pushes FENCE AUTO (GPU_FENCE + 1): a fence recorded in a list counts at
 * every call of that list, so GPU_FENCE never goes back. The tags are
 * predicted by counting the fences pushed and called (24 bits, wrapping:
 * blns_gpu_fence_done compares in that order, up to 2^23 fences in flight);
 * raw blns_gpu_push fences, or a list called by other means, break the
 * count. A tag also carries, in bits [31:24], the stream it was pushed in
 * (blns_gpu_fence_status). While recording, *tag is a tag already reached
 * (the list's fences are known only at a call: list->tag). tag may be NULL;
 * it is written only on BLNS_OK. */
blns_status_t blns_gpu_fence(blns_t *dev, bool irq, uint32_t *tag);
/* GPU FIFO low water (BLNS_ERR_ABSENT without a GPU): return once more than
 * GPU_FIFO_LOW.THRESH FIFO words are free (half the FIFO unless
 * blns_gpu_fifo_low_set changed it). BLNS_IRQ_GPU_FIFO_LOW is raised when
 * FREE rises above it: an RTOS producer enables it (blns_irq_enable) and
 * sleeps instead of calling this; blns_gpu_fifo_low tells the current state.
 * BLNS_ERR_GPU when the decoder stopped. */
bool          blns_gpu_fifo_low(const blns_t *dev);
blns_status_t blns_gpu_wait_fifo_low(blns_t *dev);
/* The threshold itself, for a producer that manages the interrupt: the event
 * when FREE rises above free_above (the write re-arms: it fires at once if
 * FREE is already above). caps.gpu_fifo_depth or more: never (kept as the
 * depth). blns_init sets half the FIFO (the reset value); kept by
 * blns_gpu_enable and blns_gpu_recover. No effect without a GPU. */
void          blns_gpu_fifo_low_set(blns_t *dev, unsigned free_above);
/* The commands pushed after it wait for the end of a frame sent to the panel
 * (the one in progress, else the next): the CPU goes on at once, a FENCE
 * behind the drawing tells when it is done. BLNS_ERR_STATE with nothing
 * pushed when no frames flow (the GPU would wait for ever). */
blns_status_t blns_gpu_wait_refresh(blns_t *dev);
/* Every GPU setting (surfaces, size, colours, x/y, clip, texture and its
 * filter, gradient, alpha and MIX5, vertices) back to its reset value, in one
 * word; the pointers (remap table, mask and alpha planes) unknown again, the
 * blend rule back to BLNS_MIX_ROUND */
blns_status_t blns_gpu_reset_state(blns_t *dev);
/* One register read: safe anywhere. True once the GPU is done with the work
 * pushed before the fence: drawn, or dropped by a recover (the driver then
 * moves GPU_FENCE past the dropped tags); blns_gpu_fence_status tells which */
static inline bool blns_gpu_fence_done(const blns_t *dev, uint32_t tag)
{
    /* reached when GPU_FENCE is at or after tag, modulo 2^24 */
    return ((dev->regs->GPU.FENCE - tag) & BLNS_GPU_FENCE_TAG_Msk) < (1u << 23);
}
/* What became of the work pushed before a fence (or a list's tag):
 *   BLNS_OK           drawn (the fence was reached)
 *   BLNS_ERR_BUSY     not reached yet, the GPU runs
 *   BLNS_ERR_GPU      not reached, and will not be: the GPU stopped on an
 *                     error, is disabled, or a recover is requested; after
 *                     blns_gpu_recover the fence reads BLNS_ERR_DROPPED
 *   BLNS_ERR_DROPPED  a recover (or GPU_EN = 0) dropped work pushed before
 *                     the fence: what it covers may be partly drawn
 *   BLNS_ERR_STATE    the GPU is idle and the tag unreached (a tag no fence
 *                     will reach: raw fences, a foreign list)
 * The work a fence covers starts after the fence before it: a fence pushed
 * after a recover that dropped unfenced work reads BLNS_ERR_DROPPED too.
 * Exact for a fence pushed before at most one such loss; one pushed before
 * two or more reads BLNS_ERR_DROPPED even when it was reached first
 * (conservative), and the stamp wraps after 256 losses. No register write:
 * any context may call it (from another context the result can lag the
 * owner's last recover). */
blns_status_t blns_gpu_fence_status(const blns_t *dev, uint32_t tag);
/* Wait until the fence is reached: BLNS_OK, or the first other status of
 * blns_gpu_fence_status (not BLNS_ERR_BUSY), BLNS_ERR_TIMEOUT (wait_polls
 * polls without GPU_FENCE moving, or the wait hook). A recover requested
 * meanwhile is performed (the fence then reads BLNS_ERR_DROPPED). */
blns_status_t blns_gpu_wait_fence(blns_t *dev, uint32_t tag);
/* The last GPU error: BLNS_GPU_ERR_* cause, the opcode and the word that
 * stopped the decoder (BLNS_GPU_ERR_BOUNDS: the EXEC of the rectangle;
 * BLNS_GPU_ERR_CALL_BOUNDS: the list address) */
typedef struct {
    uint8_t   cause;
    uint8_t   opcode;
    uint32_t  word;
} blns_gpu_err_t;
void          blns_gpu_error(const blns_t *dev, blns_gpu_err_t *err);
/* Wait until the FIFO is empty and nothing is drawn (a recover requested
 * meanwhile is performed: the GPU is then idle) */
blns_status_t blns_gpu_wait(blns_t *dev);
/* Abandon the work in progress, flush the FIFO and clear an error, in the
 * owner's context: one GPU_CTRL write, ABORT, CLEAR_ERR and DISCARD (the
 * stream back in step, whatever was owed). The fences pushed before it read
 * BLNS_ERR_DROPPED (blns_gpu_fence_status) and blns_gpu_fence_done; the next
 * call sends every setting again. BLNS_ERR_ABSENT without a GPU. */
blns_status_t blns_gpu_recover(blns_t *dev);
/* Any context (an interrupt handler, a watchdog task): ask the owner of dev
 * for blns_gpu_recover. Nothing is written to the GPU here, so a call being
 * pushed completes as pushed; the owner's next GPU call (the inline fast paths
 * included) performs the recover first, and the waits in progress end
 * (BLNS_ERR_GPU for a call waiting for FIFO room; blns_gpu_wait and
 * blns_gpu_wait_fence perform it). */
static inline void blns_gpu_recover_request(blns_t *dev)
{
    dev->recover_req = 1u;
}

/* Command lists: between blns_gpu_list_begin and blns_gpu_list_end every
 * blns_gpu_* call is written into the list (VRAM window writes, no FIFO wait)
 * instead of being pushed; blns_gpu_list_call then runs it with a single
 * push. The first span of a list sends its full destination, and the
 * session calls inside the list set texture, expansion and colours; the list
 * starts by resetting the clip window, blending, the gradient and the line
 * pattern (those that are built), so a list does not depend on what ran before it. With
 * BLNS_LIST_INHERIT it starts with no prologue and inherits them from the
 * caller. Lists are owned by one software client at a time, as the GPU is.
 * Do not change a list while the GPU executes it (blns_gpu_list_busy):
 * dynamic content uses two lists in turn. list->addr + capacity must lie in
 * the VRAM (BLNS_ERR_PARAM). */
#define BLNS_LIST_INHERIT   (1u << 0)
blns_status_t blns_gpu_list_begin(blns_t *dev, blns_gpu_list_t *list, unsigned flags);
blns_status_t blns_gpu_list_end(blns_t *dev);   /* BLNS_ERR_FULL: the list overflowed */
/* CALL the list then a FENCE AUTO, in one push (a BLNS_WMB() first):
 * list->tag is reached when the list has run (with irq: BLNS_IRQ_GPU_FENCE).
 * An empty list pushes the fence only. */
blns_status_t blns_gpu_list_call(blns_t *dev, blns_gpu_list_t *list, bool irq);
/* The GPU has not finished the last call of the list (its fence) */
static inline bool blns_gpu_list_busy(const blns_t *dev, const blns_gpu_list_t *list)
{
    return list->called && !blns_gpu_fence_done(dev, list->tag);
}
blns_status_t blns_gpu_list_wait(blns_t *dev, const blns_gpu_list_t *list);
/* A list that overflowed holds the driver calls recorded before the first one
 * that did not fit (whole commands): it can still be called. To finish the
 * drawing from the FIFO, call blns_gpu_list_spill() after blns_gpu_list_call()
 * and run the same calls again: the ones already in the list are dropped.
 * BLNS_ERR_STATE while recording. */
blns_status_t blns_gpu_list_spill(blns_t *dev, const blns_gpu_list_t *list);

/* Present a frame by a whole-frame GPU copy (src into the displayed dst, ROP
 * S): BLNS_PRESENT_ADAPTIVE copies at once when blns_dpi_copy_now() (a tear
 * at worst, rather than a frame late), else after the end of the frame being
 * sent; BLNS_PRESENT_VSYNC always after the frame end; BLNS_PRESENT_NOW at
 * once. The wait is queued in the GPU stream (blns_gpu_wait_refresh(); at
 * once when no frames flow): the CPU goes on, blns_gpu_wait() or a fence
 * tells when the copy is done. The wait and the copy are one push: both are
 * sent, or neither. *waited (may be NULL) tells whether it waits for the
 * frame end. Without DPI, ADAPTIVE copies at once. In non-blocking
 * mode the next calls return BLNS_ERR_BUSY instead of waiting behind the
 * frame end once the FIFO is full. */
typedef enum {
    BLNS_PRESENT_ADAPTIVE = 0,
    BLNS_PRESENT_VSYNC    = 1,
    BLNS_PRESENT_NOW      = 2
} blns_present_t;
blns_status_t blns_gpu_present_copy(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                                    uint16_t width, uint16_t height, blns_present_t policy, bool *waited);

/* Every GPU_CMD store of the driver goes through BLNS_CMD_WRITE, and the
 * register accesses whose order the hardware model of a host unit test
 * (sw/test) must see (CTRL, GPU_CTRL, the hot-plug and DDC registers, the
 * GPU_FENCE / GPU_STAT reads of blns_gpu_fence_status, the DIF_STATUS,
 * DIF_PARAM and DIF_CMD accesses of the DBI drivers' waits and blns_dbi_cmd)
 * through BLNS_REG_WR / BLNS_REG_RD: the test defines them to drive its
 * model. 'field' is a register of BLNS_TypeDef (e.g. GPU.CTRL). */
#ifndef BLNS_CMD_WRITE
#define BLNS_CMD_WRITE(dev, w)  ((dev)->regs->GPU.CMD = (w))
#endif
#ifndef BLNS_REG_WR
#define BLNS_REG_WR(dev, field, v)  ((dev)->regs->field = (v))
#endif
#ifndef BLNS_REG_RD
#define BLNS_REG_RD(dev, field)     ((dev)->regs->field)
#endif

/*---------------------------------------------------------------------------
 * GPU fast paths: the per-item calls, inline. The common case (no list being
 * recorded, the FIFO room already counted, the session values in place, the
 * destination near the previous one) stores the words straight into GPU_CMD;
 * everything else takes the blns__gpu_* call, which behaves the same.
 *---------------------------------------------------------------------------*/
BLNS_ALWAYS_INLINE bool blns__fast(blns_t *dev, unsigned words)
{
    if (!dev->fast || dev->recover_req)
        return false;
    if (dev->fifo_free >= words)
        return true;
    /* the count is used up: GPU_STAT.FREE once, as the general path would */
    dev->fifo_free = (uint16_t) ((dev->regs->GPU.STAT & BLNS_GPU_STAT_FREE_Msk) >> BLNS_GPU_STAT_FREE_Pos);
    return dev->fifo_free >= words;
}
BLNS_ALWAYS_INLINE bool blns__in(int32_t v, int32_t lo, int32_t hi)
{
    return (uint32_t) (v - lo) <= (uint32_t) (hi - lo);
}
BLNS_ALWAYS_INLINE bool blns__size_ok(const blns_t *dev, uint32_t n)
{
    return n - 1u < dev->caps.size_max;            /* 1 .. size_max */
}
BLNS_ALWAYS_INLINE uint32_t blns__delta(int32_t d)
{
    return ((uint32_t) d << BLNS_GPU_SPAN_DELTA_Pos) & BLNS_GPU_SPAN_DELTA_Msk;
}

static inline blns_status_t blns_gpu_span(blns_t *dev, blns_pa_t addr, uint16_t width)
{
    const int32_t d = (int32_t) (addr - dev->cur_base);
    if (blns__fast(dev, 1u) &&
        (dev->gst_known & (BLNS__GST_CUR | BLNS__SES_FILL | BLNS__SES_SPAN)) ==
            (BLNS__GST_CUR | BLNS__SES_FILL | BLNS__SES_SPAN) &&
        blns__in(d, BLNS_GPU_SPAN_DELTA_MIN, BLNS_GPU_SPAN_DELTA_MAX) && blns__size_ok(dev, width)) {
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_EXEC_SPAN | blns__delta(d) | width);
        dev->fifo_free--;
        dev->cur_base   = addr;
        dev->gst_known &= (uint16_t) ~(BLNS__GST_SIZE | BLNS__SES_EXP | BLNS__FENCED);
        return BLNS_OK;
    }
    return blns__gpu_span(dev, addr, width);
}

static inline blns_status_t blns_gpu_expand(blns_t *dev, blns_pa_t src, blns_pa_t dst)
{
    const int32_t d = (int32_t) (dst - dev->cur_base);
    if (blns__fast(dev, 3u) &&
        (dev->gst_known & (BLNS__GST_CUR | BLNS__SES_EXP)) == (BLNS__GST_CUR | BLNS__SES_EXP) &&
        dev->cur_pitch == dev->exp.pitch && blns__in(d, BLNS_GPU_SPAN_DELTA_MIN, BLNS_GPU_SPAN_DELTA_MAX)) {
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_SET_SRC | dev->exp.fmt | dev->exp.src_pitch);
        BLNS_CMD_WRITE(dev, src);
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_EXEC_EXPAND | dev->exp.word | blns__delta(d));
        dev->fifo_free -= 3u;
        dev->cur_base   = dst;
        dev->gst_known &= (uint16_t) ~(BLNS__GST_SRC | BLNS__SES_TEX | BLNS__FENCED);
        return BLNS_OK;
    }
    return blns__gpu_expand(dev, src, dst);
}

static inline blns_status_t blns_gpu_tex_span(blns_t *dev, blns_pa_t dst, uint16_t n, uint16_t u0,
                                              uint16_t v0)
{
    const int32_t d = (int32_t) (dst - dev->cur_base);
    if (blns__fast(dev, 3u) &&
        (dev->gst_known & (BLNS__GST_CUR | BLNS__SES_TEX)) == (BLNS__GST_CUR | BLNS__SES_TEX) &&
        dev->cur_pitch == dev->tex.pitch && blns__in(d, BLNS_GPU_SPAN_DELTA_MIN, BLNS_GPU_SPAN_DELTA_MAX) &&
        blns__size_ok(dev, n)) {
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_UV);
        BLNS_CMD_WRITE(dev, ((uint32_t) u0 << 16) | v0);
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_EXEC_TEXSPAN | blns__delta(d) | n);
        dev->fifo_free -= 3u;
        dev->cur_base   = dst;
        dev->gst_known &= (uint16_t) ~(BLNS__GST_SIZE | BLNS__SES_EXP | BLNS__FENCED);
        return BLNS_OK;
    }
    return blns__gpu_tex_span(dev, dst, n, u0, v0);
}

#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_span_xy(blns_t *dev, int x, int y, uint16_t width)
{ (void) dev; (void) x; (void) y; (void) width; return BLNS_ERR_ABSENT; }
#else
static inline blns_status_t blns_gpu_span_xy(blns_t *dev, int x, int y, uint16_t width)
{
    const int32_t dx = (int32_t) x - dev->xy_x;
    if (blns__fast(dev, 1u) &&
        (dev->gst_known & (BLNS__GST_XYPOS | BLNS__SES_FILL)) == (BLNS__GST_XYPOS | BLNS__SES_FILL) &&
        y == dev->xy_y && blns__in(dx, BLNS_GPU_SPAN_DELTA_MIN, BLNS_GPU_SPAN_DELTA_MAX) &&
        blns__in(x, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX) && blns__size_ok(dev, width)) {
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_EXEC_SPAN | blns__delta(dx) | width);
        dev->fifo_free--;
        dev->xy_x       = (int16_t) x;
        dev->gst_known &= (uint16_t) ~(BLNS__GST_SIZE | BLNS__SES_EXP | BLNS__FENCED);
        return BLNS_OK;
    }
    return blns__gpu_span_xy(dev, x, y, width);
}
#endif

#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_fill_xy(blns_t *dev, int x, int y, uint16_t width,
                                             uint16_t height)
{ (void) dev; (void) x; (void) y; (void) width; (void) height; return BLNS_ERR_ABSENT; }
#else
static inline blns_status_t blns_gpu_fill_xy(blns_t *dev, int x, int y, uint16_t width,
                                             uint16_t height)
{
    const uint32_t size = BLNS_GPU_OP_SET_SIZE | ((uint32_t) height << BLNS_GPU_SIZE_H_Pos) | width;
    if (blns__fast(dev, 3u) &&
        (dev->gst_known & (BLNS__GST_XYDST | BLNS__SES_FILL)) == (BLNS__GST_XYDST | BLNS__SES_FILL) &&
        blns__in(x, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX) && blns__in(y, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX) &&
        blns__size_ok(dev, width) && blns__size_ok(dev, height)) {
        uint16_t           k   = dev->gst_known & (uint16_t) ~BLNS__FENCED;
        unsigned           n   = 1u;
        if (!(k & BLNS__GST_XYPOS) || dev->xy_x != x || dev->xy_y != y) {
            BLNS_CMD_WRITE(dev, BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_XY | BLNS_GPU_XY(x, y));
            dev->xy_x = (int16_t) x;
            dev->xy_y = (int16_t) y;
            k |= BLNS__GST_XYPOS;
            n++;
        }
        if (!(k & BLNS__GST_SIZE) || dev->gst_size != size) {
            BLNS_CMD_WRITE(dev, size);
            dev->gst_size = size;
            k = (uint16_t) ((k | BLNS__GST_SIZE) & ~BLNS__SES_EXP);
            n++;
        }
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_EXEC_FILL);
        dev->gst_known  = k;
        dev->fifo_free -= (uint16_t) n;
        return BLNS_OK;
    }
    return blns__gpu_fill_xy(dev, x, y, width, height);
}
#endif

#if BLNS_HW_OFF(GPU_XY)
static inline blns_status_t blns_gpu_expand_xy(blns_t *dev, blns_pa_t src, int x, int y)
{ (void) dev; (void) src; (void) x; (void) y; return BLNS_ERR_ABSENT; }
#else
static inline blns_status_t blns_gpu_expand_xy(blns_t *dev, blns_pa_t src, int x, int y)
{
    const int32_t dx = (int32_t) x - dev->xy_x;
    if (blns__fast(dev, 3u) &&
        (dev->gst_known & (BLNS__GST_XYPOS | BLNS__SES_EXP)) == (BLNS__GST_XYPOS | BLNS__SES_EXP) &&
        y == dev->xy_y && blns__in(dx, BLNS_GPU_SPAN_DELTA_MIN, BLNS_GPU_SPAN_DELTA_MAX) &&
        blns__in(x, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX)) {
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_SET_SRC | dev->exp.fmt | dev->exp.src_pitch);
        BLNS_CMD_WRITE(dev, src);
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_EXEC_EXPAND | dev->exp.word | blns__delta(dx));
        dev->fifo_free -= 3u;
        dev->xy_x       = (int16_t) x;
        dev->gst_known &= (uint16_t) ~(BLNS__GST_SRC | BLNS__SES_TEX | BLNS__FENCED);
        return BLNS_OK;
    }
    return blns__gpu_expand_xy(dev, src, x, y);
}
#endif

/*---------------------------------------------------------------------------
 * Built-in DBI transport (blns_dbi.c). Every call: BLNS_ERR_ABSENT unless
 * DIF_TYPE is 1-3.
 *---------------------------------------------------------------------------*/
typedef struct {
    bool     spi;               /* PHY: false = 8080, true = SPI (DIF_TYPE 3 only selects) */
    uint8_t  clk_div;           /* bus timing, DIF_CFG.CLK_DIV (0-15)          */
    bool     hw_window;         /* CASET/PASET before each refresh and fill    */
    uint8_t  rd_div;            /* 8080 read strobe, DIF_CFG.RD_DIV (1-15);
                                 * 0 = derived from hclk_hz: the smallest with
                                 * RD low and high >= 90 ns (ILI9341 t_RDH, so
                                 * the scanline sync reads right), at least
                                 * clk_div; with hclk_hz = 0 the reads follow
                                 * clk_div (RD_DIV = 0)                        */
} blns_dbi_config_t;

#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_config(blns_t *dev, const blns_dbi_config_t *cfg)
{ (void) dev; (void) cfg; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_config(blns_t *dev, const blns_dbi_config_t *cfg);
#endif
#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_power(blns_t *dev, bool on)
{ (void) dev; (void) on; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_power(blns_t *dev, bool on);                 /* lcd_on_o      */
#endif
#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_reset(blns_t *dev, bool assert)
{ (void) dev; (void) assert; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_reset(blns_t *dev, bool assert);             /* lcd_reset_n_o */
#endif
/* Send a command with its 8-bit parameters (0 to 255, else BLNS_ERR_PARAM) */
#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_cmd(blns_t *dev, uint8_t cmd, const uint8_t *param,
                                         unsigned count)
{ (void) dev; (void) cmd; (void) param; (void) count; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_cmd(blns_t *dev, uint8_t cmd, const uint8_t *param, unsigned count);
#endif
/* Fill the panel memory with one RGB888 colour */
#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_fill(blns_t *dev, uint32_t rgb888)
{ (void) dev; (void) rgb888; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_fill(blns_t *dev, uint32_t rgb888);
#endif
/* Scanline / TE synchronisation of the refresh (scan_sync: 8080 only,
 * BLNS_ERR_PARAM on the SPI PHY, which ignores it) */
#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_sync(blns_t *dev, uint16_t scanline, bool scan_sync,
                                          bool te_sync)
{ (void) dev; (void) scanline; (void) scan_sync; (void) te_sync; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_sync(blns_t *dev, uint16_t scanline, bool scan_sync, bool te_sync);
#endif
/* Wait until no command, fill or refresh is in progress or queued */
#if BLNS_HW_OFF(DBI)
static inline blns_status_t blns_dbi_wait_idle(blns_t *dev)
{ (void) dev; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dbi_wait_idle(blns_t *dev);
#endif

/*---------------------------------------------------------------------------
 * Built-in DPI driver (blns_dpi.c, blns_ddc.c, blns_hotplug.c). Every call:
 * BLNS_ERR_ABSENT unless DIF_TYPE is 4 or 5. The panel timing, the image and the border are
 * staged: blns_dpi_config() / blns_dpi_image() / blns_dpi_border() write
 * them, and the driver takes them at its next frame start (or when it is
 * enabled). A call made while an earlier one is still pending waits for that
 * frame start (BLNS_ERR_BUSY instead in non-blocking mode); a call that
 * changes nothing returns at once.
 *---------------------------------------------------------------------------*/
typedef struct {
    uint8_t  clk_div;           /* pixel-domain cycles per pixel - 1 (0-15)    */
    uint16_t h_act;             /* active pixels per line                      */
    uint16_t h_fp, h_sync, h_bp;/* front porch, HSYNC width, back porch        */
    uint16_t v_act;             /* active lines                                */
    uint16_t v_fp, v_sync, v_bp;/* front porch, VSYNC width, back porch (lines) */
    uint8_t  flags;             /* BLNS_DPI_* polarity and order flags         */
} blns_dpi_timing_t;

#define BLNS_DPI_HS_HIGH     0x01u     /* HSYNC active high (default low)        */
#define BLNS_DPI_VS_HIGH     0x02u     /* VSYNC active high (default low)        */
#define BLNS_DPI_DE_LOW      0x04u     /* data enable active low                 */
#define BLNS_DPI_EDGE_FALL   0x08u     /* the panel samples on the falling edge  */
#define BLNS_DPI_BGR         0x10u     /* blue in dpi_rgb_o[23:16]               */

/* Example presets. The standard modes are exact for their pixel clock (640 x
 * 480 at 60 Hz on 25.175 MHz, 720 x 480 at 59.94 Hz, CTA-861 VIC 2 and 3, on
 * 27 MHz); the panel ones are those of the boards they were tuned on (a 480 x
 * 272 4.3" panel at a quarter of a 33 MHz clock on the Tang Console, an 800 x
 * 480 panel at 33 MHz): CLK_DIV depends on the pixel-domain clock of the build. */
#define BLNS_DPI_480X272     { 3u, 480u,  8u,  4u, 43u, 272u,  4u, 10u, 12u, 0u }
#define BLNS_DPI_800X480     { 0u, 800u, 40u, 48u, 40u, 480u, 13u,  3u, 29u, 0u }
#define BLNS_DPI_640X480_60  { 0u, 640u, 16u, 96u, 48u, 480u, 10u,  2u, 33u, 0u }
#define BLNS_DPI_720X480_60  { 0u, 720u, 16u, 62u, 60u, 480u,  9u,  6u, 30u, 0u }

#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_config(blns_t *dev, const blns_dpi_timing_t *t)
{ (void) dev; (void) t; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_config(blns_t *dev, const blns_dpi_timing_t *t);
#endif
/* Show the src_w x src_h frame as a dst_w x dst_h image, centred (0 x 0: 1:1) */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_image(blns_t *dev, uint16_t src_w, uint16_t src_h,
                                           uint16_t dst_w, uint16_t dst_h)
{ (void) dev; (void) src_w; (void) src_h; (void) dst_w; (void) dst_h; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_image(blns_t *dev, uint16_t src_w, uint16_t src_h, uint16_t dst_w, uint16_t dst_h);
#endif
/* The largest image of the frame's shape that fits the active area, centred */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_fit(blns_t *dev, uint16_t src_w, uint16_t src_h)
{ (void) dev; (void) src_w; (void) src_h; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_fit(blns_t *dev, uint16_t src_w, uint16_t src_h);
#endif
/* The frame as a picture of shape picture_x100 (width / height x 100; 0: the
 * frame's own, square pixels) on a display that stretches the signal to the
 * shape display_x100 (0: the signal's own shape, a display that does not
 * stretch): h_act x picture / display signal pixels wide and all the lines,
 * or the full width and fewer lines when that is wider than the signal;
 * centred, an even width. */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_image_aspect(blns_t *dev, uint16_t src_w, uint16_t src_h,
                                                  uint16_t picture_x100, uint16_t display_x100)
{ (void) dev; (void) src_w; (void) src_h; (void) picture_x100; (void) display_x100;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_image_aspect(blns_t *dev, uint16_t src_w, uint16_t src_h,
                                    uint16_t picture_x100, uint16_t display_x100);
#endif
/* The board's picture policy, in one place: the frame, its picture shape,
 * and whether the display stretches the signal to its own shape (from the
 * EDID read with 'quarter', or fallback_x100 when there is none). */
typedef struct {
    uint16_t src_w, src_h;      /* the frame                                  */
    uint16_t picture_x100;      /* the picture's shape (0: the frame's)       */
    bool     stretch;           /* the display stretches the signal (HDMI TVs and monitors) */
    uint16_t fallback_x100;     /* the display's shape without an EDID (stretch) */
    void   (*quarter)(void);    /* DDC quarter-bit delay (NULL: no EDID read) */
} blns_picture_t;
/* Place the picture; *settled (may be NULL): the display's shape is known
 * (from the EDID, or not needed); when false, place it again once a monitor
 * answers (blns_dpi_hotplug_poll does with hp->picture). */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_picture(blns_t *dev, const blns_picture_t *p, bool *settled)
{ (void) dev; (void) p; (void) settled; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_picture(blns_t *dev, const blns_picture_t *p, bool *settled);
#endif
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_border(blns_t *dev, uint32_t rgb888)
{ (void) dev; (void) rgb888; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_border(blns_t *dev, uint32_t rgb888);
#endif
/* Bilinear (true) or nearest-neighbour scaling (DPI_SCALER = 2 builds) */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_filter(blns_t *dev, bool bilinear)
{ (void) dev; (void) bilinear; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_filter(blns_t *dev, bool bilinear);
#endif
/* Colour bars instead of the frames */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_test(blns_t *dev, bool on)
{ (void) dev; (void) on; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_test(blns_t *dev, bool on);
#endif
/* Panel power (LCD_ON) and the panel timing (DPI_EN) */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_enable(blns_t *dev, bool on)
{ (void) dev; (void) on; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_enable(blns_t *dev, bool on);
#endif
/* Panel detected (DIF_STATUS.PRESENT; false without a DPI driver) */
static inline bool blns_dpi_present(const blns_t *dev)
{
    return BLNS_HAS(dev, DPI) && (dev->regs->DPI.STATUS & BLNS_DPI_STATUS_PRESENT_Msk) != 0u;
}

/* The panel line being scanned (DPI_STATUS.LINE: 0 at the first active line) */
static inline uint16_t blns_dpi_scan_line(const blns_t *dev)
{
    return (uint16_t) ((dev->regs->DPI.STATUS & BLNS_DPI_STATUS_LINE_Msk) >> BLNS_DPI_STATUS_LINE_Pos);
}
/* The panel lines of the image, [top, bottom), from the placement registers */
#if BLNS_HW_OFF(DPI)
static inline blns_status_t blns_dpi_image_rows(const blns_t *dev, uint16_t *top, uint16_t *bottom)
{ (void) dev; (void) top; (void) bottom; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_image_rows(const blns_t *dev, uint16_t *top, uint16_t *bottom);
#endif
/* HDMI hot-plug (DIF_TYPE 5): a monitor may only accept a link that starts
 * once it is ready, so the link is restarted (LCD_ON off for off_ms, then on;
 * the scan goes on) when
 *   - the hot-plug line comes back (after low_ms low, quiet_ms after the
 *     previous restart: a TV may drop it while it locks) and stays up for
 *     settle_ms;
 *   - the line stays low with the link on: every probe_every_ms the link is
 *     off for at most probe_ms, and a monitor that is there raises the line
 *     (no probe within wake_ms of a restart: a monitor waking from standby
 *     holds the line low meanwhile);
 *   - the application asks (force, e.g. a key held): at any time; with the
 *     line low the probes then stop until it changes.
 * Nothing happens while the line is up. Call blns_dpi_hotplug_poll() every few
 * milliseconds with a millisecond time; it returns BLNS_HP_RESTARTED in the
 * call that turns the link back on. With hp->picture set, that call also
 * places the picture again (blns_dpi_picture) while hp->settled is false (no
 * EDID yet), and sets hp->settled; a placement refused (an update pending)
 * is tried again at the next polls. blns_dpi_hotplug_init() takes the example
 * timing below when hp->off_ms is 0 (the values the Tang Console boards were
 * tuned with), and keeps picture and settled. */
typedef enum { BLNS_HP_NONE = 0, BLNS_HP_RESTARTED = 1 } blns_hp_event_t;
typedef struct {
    uint32_t  low_ms, quiet_ms, settle_ms, off_ms, probe_every_ms, probe_ms, wake_ms;
    /* state */
    uint8_t   state;
    bool      present_q, no_probes;
    uint32_t  t0, low_t0, on_t0, poll_t;
    uint32_t  restarts;
    /* picture placement after a restart (NULL: none) */
    const blns_picture_t *picture;
    bool      settled;
    /* state */
    bool      forced;                   /* force seen outside IDLE: taken there */
    bool      place;                    /* a placement refused: tried again */
} blns_hotplug_t;
#if BLNS_HW_OFF(DPI)
static inline void blns_dpi_hotplug_init(blns_t *dev, blns_hotplug_t *hp,
                                         uint32_t now_ms) { (void) dev; (void) hp; (void) now_ms; }
#else
void            blns_dpi_hotplug_init(blns_t *dev, blns_hotplug_t *hp, uint32_t now_ms);
#endif
#if BLNS_HW_OFF(DPI)
static inline blns_hp_event_t blns_dpi_hotplug_poll(blns_t *dev, blns_hotplug_t *hp,
                                                    uint32_t now_ms, bool force)
{ (void) dev; (void) hp; (void) now_ms; (void) force; return BLNS_HP_NONE; }
#else
blns_hp_event_t blns_dpi_hotplug_poll(blns_t *dev, blns_hotplug_t *hp, uint32_t now_ms, bool force);
#endif

/* Presenting a new frame by a whole-frame copy now tears little: the scan is
 * past the image, or in its first third (the copy, at a pixel per cycle or
 * better, overtakes it). Otherwise wait for the frame end first (in the GPU
 * stream: blns_gpu_wait_refresh()). True without a DPI driver. */
#if BLNS_HW_OFF(DPI)
static inline bool blns_dpi_copy_now(const blns_t *dev)
{ (void) dev; return true; }
#else
bool          blns_dpi_copy_now(const blns_t *dev);
#endif

/* HDMI DDC (caps.dpi_ddc, else BLNS_ERR_ABSENT): the monitor's EDID over I2C,
 * the master in software on the two open-drain lines of DPI_DDC. quarter()
 * waits a quarter of a bit time (2.5 us for 100 kHz); the monitor may
 * stretch SCL. The EDID fields follow VESA E-EDID 1.4: base block 0, and
 * block 1 when the base block announces an extension. */
#define BLNS_EDID_ADDR       0x50u     /* 7-bit I2C address of the EDID          */
#define BLNS_EDID_BLOCK      128u

typedef struct {
    uint8_t  raw[2u * BLNS_EDID_BLOCK]; /* blocks 0 and 1 as read                */
    uint8_t  blocks;                   /* valid blocks: 0, 1 or 2                */
    uint16_t width_mm, height_mm;      /* screen size (0: unknown)               */
    uint16_t aspect_x100;              /* width / height x 100 (0: unknown)      */
    uint16_t pref_w, pref_h;           /* preferred mode (0: none)               */
    uint32_t pref_pclk_khz;            /* its pixel clock                        */
    uint8_t  quant_select;             /* 1: the sink honours the AVI RGB quantization
                                        * range (CTA-861 Video Capability Data Block,
                                        * QS bit, in a CTA extension block 1)      */
} blns_edid_t;

/* n bytes at offset from the device at addr7 (BLNS_ERR_BUS without an answer) */
#if BLNS_HW_OFF(DPI_DDC)
static inline blns_status_t blns_dpi_ddc_read(blns_t *dev, void (*quarter)(void), uint8_t addr7,
                                              uint8_t offset, uint8_t *buf, unsigned n)
{ (void) dev; (void) quarter; (void) addr7; (void) offset; (void) buf; (void) n;
  return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_ddc_read(blns_t *dev, void (*quarter)(void), uint8_t addr7, uint8_t offset,
                                uint8_t *buf, unsigned n);
#endif
/* Read and parse the EDID (BLNS_ERR_PARAM: no valid base block) */
#if BLNS_HW_OFF(DPI_DDC)
static inline blns_status_t blns_dpi_edid_read(blns_t *dev, void (*quarter)(void),
                                               blns_edid_t *edid)
{ (void) dev; (void) quarter; (void) edid; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_edid_read(blns_t *dev, void (*quarter)(void), blns_edid_t *edid);
#endif
/* Parse the edid->blocks blocks already in edid->raw */
blns_status_t blns_dpi_edid_parse(blns_edid_t *edid);

/* HDMI mode (caps.dpi_island, else BLNS_ERR_ABSENT): HDMI signalling instead
 * of DVI, with an AVI InfoFrame sent once per frame; taken at the next start
 * of vertical blanking, with a timing whose CLK_DIV is 0 (else the link stays
 * DVI). NULL: back to DVI, which also stops audio and the generic packet
 * (their enables are cleared; set them again after a later call). */
#define BLNS_AVI_PICTURE_4_3   1u      /* picture aspect ratio (M1:M0)           */
#define BLNS_AVI_PICTURE_16_9  2u
#define BLNS_AVI_ACTIVE_SAME   8u      /* active format (R3:R0): as the picture  */
#define BLNS_AVI_ACTIVE_4_3    9u      /*   4:3, centred                         */
#define BLNS_AVI_ACTIVE_16_9  10u      /*   16:9, centred                        */
#define BLNS_AVI_ACTIVE_14_9  11u      /*   14:9, centred                        */
#define BLNS_AVI_QUANT_DEFAULT 0u      /* RGB quantization range (Q1:Q0): the    */
                                       /*   format's default (CE: limited)      */
#define BLNS_AVI_QUANT_LIMITED 1u      /*   16-235                               */
#define BLNS_AVI_QUANT_FULL    2u      /*   0-255 (a PC-style framebuffer)       */

/* The quantization range for a framebuffer drawn in 0-255: FULL when the
 * sink's EDID says it honours the field, else the default (a sink that does
 * not ignores the field). A NULL or unparsed EDID gives the default. */
static inline uint8_t blns_avi_quant_auto(const blns_edid_t *edid)
{
    return (edid != NULL && edid->blocks != 0u && edid->quant_select) ? BLNS_AVI_QUANT_FULL
                                                                     : BLNS_AVI_QUANT_DEFAULT;
}

typedef struct {
    uint8_t vic;                       /* CTA-861 video code (1: 640 x 480 at 60 Hz, 0: none) */
    uint8_t picture;                   /* BLNS_AVI_PICTURE_*                     */
    uint8_t active;                    /* BLNS_AVI_ACTIVE_*                      */
    uint8_t quant;                     /* BLNS_AVI_QUANT_* (0: the default)      */
} blns_avi_t;

/* HDMI mode with the AVI InfoFrame of these fields (NULL: back to DVI). New
 * fields while it is sent take effect at the next frame start (an UPDATE),
 * without a gap. The call first waits for a start or an UPDATE in progress
 * (the hardware ignores the fields then; BLNS_ERR_BUSY when non-blocking).
 * quant: BLNS_AVI_QUANT_FULL for a PC-style framebuffer (0-255) on a CE
 * timing (a VIC other than 0 and 1, whose default range is 16-235), if the
 * sink's EDID allows it (video capability data block, QS = 1). */
#if BLNS_HW_OFF(DPI_ISLAND)
static inline blns_status_t blns_dpi_hdmi(blns_t *dev, const blns_avi_t *avi)
{ (void) dev; (void) avi; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_hdmi(blns_t *dev, const blns_avi_t *avi);
#endif

/* HDMI audio (caps.dpi_audio, else BLNS_ERR_ABSENT): the I2S input sent as
 * 2-channel audio sample packets, with clock regeneration packets (N, the CTS
 * measured from the stream) and the audio InfoFrame. Nothing is sent unless
 * HDMI mode is on (blns_dpi_hdmi()) with a timing whose CLK_DIV is 0.
 * n: a multiple of 128, such that N / 128 audio frames last fewer than 2^20
 * pixel clocks (a longer measurement is dropped); the usual values are 4096 at
 * 32 kHz, 6272 at 44.1 kHz and 6144 at 48 kHz, and since the CTS is measured
 * any such N works. fs and wl: the channel-status codes. The call clears AUD
 * and writes DPI_AUD until it reads back (the hardware ignores the writes
 * until the pixel domain has stopped audio). NULL: audio off. */
#define BLNS_AUD_FS_44K1       0x0u    /* channel status, sampling frequency     */
#define BLNS_AUD_FS_48K        0x2u
#define BLNS_AUD_FS_32K        0x3u
#define BLNS_AUD_WL_16         0x2u    /* channel status, word length (max 20)  */
#define BLNS_AUD_WL_24         0xBu    /*   24 bits (max 24)                     */

typedef struct {
    uint32_t n;                        /* clock regeneration N                   */
    uint8_t  fs;                       /* BLNS_AUD_FS_*                          */
    uint8_t  wl;                       /* BLNS_AUD_WL_*                          */
} blns_audio_t;

#if BLNS_HW_OFF(DPI_AUDIO)
static inline blns_status_t blns_dpi_hdmi_audio(blns_t *dev, const blns_audio_t *a)
{ (void) dev; (void) a; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_hdmi_audio(blns_t *dev, const blns_audio_t *a);
#endif
/* DPI_AUD_STAT: the last CTS measured, and whether a frame was lost */
#if BLNS_HW_OFF(DPI_AUDIO)
static inline uint32_t blns_dpi_hdmi_audio_cts(blns_t *dev, bool *lost)
{ (void) dev; if (lost) *lost = false; return 0u; }
#else
uint32_t      blns_dpi_hdmi_audio_cts(blns_t *dev, bool *lost);
#endif

/* The generic packet (caps.dpi_audio; HDMI mode on), sent once per frame: header HB0-HB2
 * and PB0-PB27 as given (an InfoFrame carries its checksum in PB0). NULL:
 * stop sending it. blns_dpi_hdmi_spd() sends a Source Product Description
 * InfoFrame: vendor (up to 8 characters), product (up to 16), the CTA-861
 * source type (BLNS_SPD_*). Changing a packet already being sent waits for one
 * frame start and leaves out the packet of that frame. */
#define BLNS_SPD_DIGITAL_STB   0x01u
#define BLNS_SPD_DVD           0x02u
#define BLNS_SPD_GAME          0x08u
#define BLNS_SPD_PC            0x09u

#if BLNS_HW_OFF(DPI_AUDIO)
static inline blns_status_t blns_dpi_hdmi_packet(blns_t *dev, const uint8_t hdr[3],
                                                 const uint8_t pb[28])
{ (void) dev; (void) hdr; (void) pb; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_hdmi_packet(blns_t *dev, const uint8_t hdr[3], const uint8_t pb[28]);
#endif
#if BLNS_HW_OFF(DPI_AUDIO)
static inline blns_status_t blns_dpi_hdmi_spd(blns_t *dev, const char *vendor, const char *product,
                                              uint8_t source)
{ (void) dev; (void) vendor; (void) product; (void) source; return BLNS_ERR_ABSENT; }
#else
blns_status_t blns_dpi_hdmi_spd(blns_t *dev, const char *vendor, const char *product, uint8_t source);
#endif

/*---------------------------------------------------------------------------
 * Concurrency
 *
 * One context owns a blns_t: every call that takes a non-const blns_t * runs
 * in that context only (the GPU helpers keep the FIFO count, the shadows and
 * the list state in it). From any context (an interrupt handler, another
 * task) these are safe:
 *   blns_irq_status, blns_irq_clear, blns_irq_service,
 *   blns_gpu_recover_request, blns_gpu_fence_done, blns_gpu_fence_status,
 *   blns_gpu_list_busy, blns_frame_num, blns_frame_abandoned, blns_flip_done,
 *   blns_dpi_scan_line, blns_dpi_present, blns_gpu_fifo_low,
 *   blns_refresh_running, blns_frames_flowing.
 * A recover is the owner's: another context requests it
 * (blns_gpu_recover_request, blns_irq_service on GPU_ERR), and the owner
 * performs it at its next GPU call, so a FIFO it is pushing is never flushed
 * under it. blns_gpu_enable(false) from another context breaks the stream
 * (the next word pushed is decoded as a command). Interrupt-driven waits:
 * enable BLNS_IRQ_GPU_FENCE / REFR_DONE / GPU_FIFO_LOW, call
 * blns_irq_service in the handler, and let the wait hook sleep until it has
 * run.
 *---------------------------------------------------------------------------*/

#ifdef __cplusplus
}
#endif

#endif /* BELENOS_H */
