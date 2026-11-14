/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_gpu.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * GPU command helpers. Each operation is one command sequence, pushed once
 * the FIFO has room for all of it, or, longer than the FIFO, command by
 * command as room appears: no word is pushed into a full FIFO (it would be
 * dropped), and a wait that ends stops the sequence between two commands. The per-item calls have an
 * inline fast path in belenos.h; the blns__gpu_* functions here are their
 * general case.
 *----------------------------------------------------------------------------*/
#include "blns_priv.h"

#define GST_SIZE    BLNS__GST_SIZE
#define GST_FILL    BLNS__GST_FILL
#define GST_TRANSP  BLNS__GST_TRANSP
#define GST_MASK    BLNS__GST_MASK
#define GST_SRC     BLNS__GST_SRC
#define GST_TEX     BLNS__GST_TEX
#define GST_CUR     BLNS__GST_CUR
#define GST_XYDST   BLNS__GST_XYDST
#define GST_XYPOS   BLNS__GST_XYPOS
#define GST_STEP    BLNS__GST_STEP
#define SES_FILL    BLNS__SES_FILL
#define SES_EXP     BLNS__SES_EXP
#define SES_TEX     BLNS__SES_TEX
#define SES_SPAN    BLNS__SES_SPAN
#define GST_PEN     BLNS__GST_PEN

BLNS_ALWAYS_INLINE uint32_t exec_word(uint32_t op, const blns_surf_t *src, const blns_surf_t *dst, blns_rop_t rop)
{
    uint32_t w = op | ((uint32_t) rop & BLNS_GPU_EXEC_ROP_Msk) |
                 (((uint32_t) dst->swap << BLNS_GPU_EXEC_DST_SWAP_Pos) & BLNS_GPU_EXEC_DST_SWAP_Msk);
    if (src)
        w |= ((uint32_t) src->swap << BLNS_GPU_EXEC_SRC_SWAP_Pos) & BLNS_GPU_EXEC_SRC_SWAP_Msk;
    return w;
}

BLNS_ALWAYS_INLINE uint32_t size_word(uint16_t width, uint16_t height)
{
    return BLNS_GPU_OP_SET_SIZE |
           (((uint32_t) height << BLNS_GPU_SIZE_H_Pos) & BLNS_GPU_SIZE_H_Msk) |
           (((uint32_t) width  << BLNS_GPU_SIZE_W_Pos) & BLNS_GPU_SIZE_W_Msk);
}

// A rectangle size: 1 to draw, 0 nothing to draw (a side of 0), -1 too large
BLNS_ALWAYS_INLINE int size_chk(const blns_t *dev, uint32_t width, uint32_t height)
{
    if (width == 0u || height == 0u)
        return 0;
    return (width > dev->caps.size_max || height > dev->caps.size_max) ? -1 : 1;
}
#define SIZE_GUARD(dev, w, h)                                       \
    do {                                                            \
        const int z_ = size_chk(dev, w, h);                         \
        if (z_ <= 0)                                                \
            return (z_ < 0) ? BLNS_ERR_PARAM : BLNS_OK;             \
    } while (0)

//==========================================================
// Settings the GPU keeps from one command to the next: a helper sends one
// only when it differs from the value last pushed (gst_*, BLNS__GST_* bits).
// EXEC_SPAN and EXEC_TEXSPAN set the size too (width x 1). The session bits
// (BLNS__SES_*) say that the settings are those of a per-item session; they
// drop when a setting changes.
//==========================================================
BLNS_ALWAYS_INLINE unsigned put_size(const blns_t *dev, uint32_t *w, uint32_t size)
{
    if ((dev->gst_known & GST_SIZE) && dev->gst_size == size)
        return 0u;
    w[0] = size;
    return 1u;
}

BLNS_ALWAYS_INLINE unsigned put_fill(const blns_t *dev, uint32_t *w, uint32_t colour)
{
    if ((dev->gst_known & GST_FILL) && dev->gst_fill == colour)
        return 0u;
    w[0] = BLNS_GPU_OP_SET_FILL;
    w[1] = colour;
    return 2u;
}

BLNS_ALWAYS_INLINE unsigned put_transp(const blns_t *dev, uint32_t *w, uint32_t colour)
{
    if ((dev->gst_known & GST_TRANSP) && dev->gst_transp == colour)
        return 0u;
    w[0] = BLNS_GPU_OP_SET_TRANSP;
    w[1] = colour;
    return 2u;
}

BLNS_ALWAYS_INLINE unsigned put_src(const blns_t *dev, uint32_t *w, uint32_t word, uint32_t addr)
{
    if ((dev->gst_known & GST_SRC) && dev->gst_src == word && dev->gst_src_addr == addr)
        return 0u;
    w[0] = word;
    w[1] = addr;
    return 2u;
}

#if !BLNS_HW_OFF(GPU_MPLANE)
static unsigned put_mask(const blns_t *dev, uint32_t *w, uint32_t addr, bool inv)
{
    if ((dev->gst_known & GST_MASK) && dev->gst_mask == addr && dev->gst_minv == inv)
        return 0u;
    w[0] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_MASK_PLANE | (inv ? BLNS_GPU_AUX_INV_Msk : 0u);
    w[1] = addr;
    return 2u;
}
#endif

BLNS_ALWAYS_INLINE void known(blns_t *dev, uint16_t set, uint16_t clear)
{
    dev->gst_known = (uint16_t) ((dev->gst_known | set) & ~clear);
}

BLNS_ALWAYS_INLINE void got_size(blns_t *dev, uint32_t size)
{
    if (!(dev->gst_known & GST_SIZE) || dev->gst_size != size)
        known(dev, 0u, SES_EXP);
    dev->gst_size = size;
    known(dev, GST_SIZE, 0u);
}

// EXEC_SPAN and EXEC_TEXSPAN leave the size at width x 1
BLNS_ALWAYS_INLINE void lost_size(blns_t *dev)
{
    known(dev, 0u, GST_SIZE | SES_EXP);
}

BLNS_ALWAYS_INLINE void got_fill(blns_t *dev, uint32_t colour)
{
    if (!(dev->gst_known & GST_FILL) || dev->gst_fill != colour)
        known(dev, 0u, SES_EXP);
    dev->gst_fill = colour;
    known(dev, GST_FILL, 0u);
    if (colour == dev->ses_fill)
        known(dev, SES_FILL, 0u);
    else
        known(dev, 0u, SES_FILL);
}

BLNS_ALWAYS_INLINE void got_transp(blns_t *dev, uint32_t colour)
{
    if (!(dev->gst_known & GST_TRANSP) || dev->gst_transp != colour)
        known(dev, 0u, SES_EXP | SES_TEX);
    dev->gst_transp = colour;
    known(dev, GST_TRANSP, 0u);
}

BLNS_ALWAYS_INLINE void got_src(blns_t *dev, uint32_t word, uint32_t addr)
{
    if (!(dev->gst_known & GST_SRC) || dev->gst_src != word || dev->gst_src_addr != addr)
        known(dev, 0u, SES_TEX);
    dev->gst_src      = word;
    dev->gst_src_addr = addr;
    known(dev, GST_SRC, 0u);
}

#if !BLNS_HW_OFF(GPU_MPLANE)
static void got_mask(blns_t *dev, uint32_t addr, bool inv)
{
    dev->gst_mask = addr;
    dev->gst_minv = inv;
    known(dev, GST_MASK, 0u);
}
#endif

// The session colour of spans, x/y fills and triangles
static void ses_fill_set(blns_t *dev, uint32_t colour)
{
    dev->ses_fill = colour;
    if ((dev->gst_known & GST_FILL) && dev->gst_fill == colour)
        known(dev, SES_FILL, 0u);
    else
        known(dev, 0u, SES_FILL);
}

// REMAP field of an EXEC (FILL, COPY, COPY_TRANSP, EXPAND) or of SET_TEX: the
// feature built, a defined mode
static blns_status_t remap_ok(const blns_t *dev, unsigned remap)
{
    if (remap == BLNS_REMAP_OFF)
        return BLNS_OK;
    if (!BLNS_HAS(dev, GPU_REMAP))
        return BLNS_ERR_ABSENT;
    if (remap > BLNS_REMAP_DST)
        return BLNS_ERR_PARAM;
    /* the table pointer must be one the API set: nothing else is defined */
    return (dev->aux_set & BLNS__AUX_REMAP) ? BLNS_OK : BLNS_ERR_STATE;
}

// A session's remap (texture: SET_TEX, expansion: EXEC_EXPAND): checked at
// each draw, as the session outlives the table pointer (RESET_STATE, a
// recover, blns_gpu_forget and a list without BLNS_LIST_INHERIT make it
// unknown; each of them also forgets the session values, so the inline fast
// paths, which skip this check, never run before a call that makes it)
static blns_status_t ses_remap_ok(const blns_t *dev, uint32_t word, uint32_t remap_msk)
{
    return ((word & remap_msk) == 0u || (dev->aux_set & BLNS__AUX_REMAP)) ? BLNS_OK : BLNS_ERR_STATE;
}

// The SET_AUX pointers the API set (remap table, mask and alpha planes): marked when
// pushed (or recorded: the list then sets them at each call), all unknown
// after RESET_STATE, a recover (a SET_AUX still in the FIFO is flushed, a cut
// one may leave INV changed and the base not) and blns_gpu_forget
#if !BLNS_HW_OFF(GPU_REMAP) || !BLNS_HW_OFF(GPU_MPLANE) || !BLNS_HW_OFF(GPU_BLEND)
static void aux_mark(blns_t *dev, uint8_t bits)
{
    dev->aux_set |= bits;
    if (dev->rec) {
        dev->rec_aux_set |= bits;
        dev->rec_aux_clr &= (uint8_t) ~bits;
    }
}
#endif

static void aux_reset(blns_t *dev)
{
    dev->aux_set = 0u;
    if (dev->rec) {
        dev->rec_aux_set = 0u;
        dev->rec_aux_clr = BLNS__AUX_REMAP | BLNS__AUX_MASK | BLNS__AUX_ALPHA;
    }
}

// Address-mode destination: the span / expand / tex_span helpers move the GPU
// destination base by a delta from the base last pushed
BLNS_ALWAYS_INLINE void cursor_set(blns_t *dev, uint32_t addr, uint16_t pitch)
{
    dev->cur_base  = addr;
    dev->cur_pitch = pitch;
    known(dev, GST_CUR, GST_XYDST | GST_XYPOS);         /* an address destination leaves x/y mode */
}

// The delta from the base last pushed, when it fits (and, for the walks
// that span lines, the pitch is the session's: 'pitch'; 0 for a span)
BLNS_ALWAYS_INLINE bool cursor_delta(const blns_t *dev, uint32_t addr, uint16_t pitch, int32_t *delta)
{
    *delta = (int32_t) (addr - dev->cur_base);
    return (dev->gst_known & GST_CUR) && (pitch == 0u || dev->cur_pitch == pitch) &&
           *delta >= BLNS_GPU_SPAN_DELTA_MIN && *delta <= BLNS_GPU_SPAN_DELTA_MAX;
}

// Pitch 0 resolved here, to the display pitch of the call: the GPU would take
// the frame width of a later moment (decode, set-up or start, per field)
BLNS_ALWAYS_INLINE uint16_t frame_pitch(const blns_t *dev, uint16_t pitch)
{
    return (pitch != 0u) ? pitch : blns_display_pitch(dev);
}

#if !BLNS_HW_OFF(GPU_XY)
static bool xy_ok(int x, int y)
{
    return x >= BLNS_GPU_XY_MIN && x <= BLNS_GPU_XY_MAX && y >= BLNS_GPU_XY_MIN && y <= BLNS_GPU_XY_MAX;
}
#endif

#if !BLNS_HW_OFF(GPU_TRI)
// Vertices: 12.4 fixed point in 16 bits
static bool vtx_ok(int32_t x, int32_t y)
{
    return x >= -32768 && x <= 32767 && y >= -32768 && y <= 32767;
}
#endif

// Pixel-value arithmetic (gradient, shade, EXPAND ramp) adds to the pixel as a
// number: a palette index, not an RGB565 colour
static bool palette_mode(const blns_t *dev)
{
    return dev->mode != BLNS_BPP_16;
}

#if !BLNS_HW_OFF(GPU_REMAP)
// A fill of the destination through the remap table (REMAP DST): palette
// modes only (16 bpp: no remap, a plain FILL); after the caller's entry
// check 'st'
static blns_status_t remap_dst_ok(const blns_t *dev, blns_status_t st)
{
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_REMAP))
        return BLNS_ERR_ABSENT;
    if (!(dev->aux_set & BLNS__AUX_REMAP))
        return BLNS_ERR_STATE;              /* no blns_gpu_remap_table */
    return palette_mode(dev) ? BLNS_OK : BLNS_ERR_PARAM;
}
#endif

//==========================================================
// The stream
//==========================================================

// GPU_FENCE := the last tag pushed (a FENCE with that tag, not AUTO), into
// the FIFO a flush has just emptied (GPU on)
static void fence_fix(blns_t *dev)
{
    if (dev->fence_fix && dev->gpu_on) {
        BLNS_CMD_WRITE(dev, BLNS_GPU_OP_FENCE | dev->fence_tag);
        dev->fence_fix = false;
        dev->fifo_free = 0u;                /* read GPU_STAT again */
    }
}

// The stream flushed, in the owner's context: the recover (ABORT, CLEAR_ERR
// and DISCARD in one write: whatever the push side still owed, an operand or
// immediate data, is dropped with the rest), or GPU_EN = 0 ('off'). Whatever
// the GPU still had (queued, drawing, stopped on an error) is lost.
// Every setting is unknown after, the pointers too (a SET_AUX may have been
// flushed, a cut one may leave INV changed and the base not), a spill ends.
// When work was dropped, the fences pushed before read dropped
// (blns_gpu_fence_status: a new stamp, GPU_FENCE at the loss in fence_b);
// the next fence covers the work lost after the last fence when there was
// any (BLNS__FENCED clear, or forgotten: fence_lag); GPU_FENCE is moved to
// the last tag pushed (fence_fix) so that no tag is reused and
// blns_gpu_fence_done is true for the dropped ones.
static BLNS_COLD BLNS_NOINLINE void flush(blns_t *dev, bool off)
{
    BLNS_TypeDef  *r    = dev->regs;
    dev->recover_req    = 0u;               /* a request arriving from now on is kept */
    const uint32_t stat = r->GPU.STAT;
    const bool     lost = (stat & (BLNS_GPU_STAT_BUSY_Msk | BLNS_GPU_STAT_ERR_Msk)) ||
                          !(stat & BLNS_GPU_STAT_EMPTY_Msk);
    if (off) {
        BLNS_REG_WR(dev, CTRL, r->CTRL & ~BLNS_CTRL_GPU_EN_Msk);
        dev->gpu_on = false;
    } else
        BLNS_REG_WR(dev, GPU.CTRL, BLNS_GPU_CTRL_ABORT_Msk | BLNS_GPU_CTRL_CLEAR_ERR_Msk |
                                   BLNS_GPU_CTRL_DISCARD_Msk);
    if (lost) {
        dev->fence_b   = r->GPU.FENCE & BLNS_GPU_FENCE_TAG_Msk;
        dev->epoch     = (uint8_t) (dev->epoch + 1u);
        dev->fence_lag = !(dev->gst_known & BLNS__FENCED);
        dev->fence_fix = dev->fence_b != dev->fence_tag;
    }
    blns__forget(dev);
    dev->aux_set       = 0u;
    dev->rec_aux_saved = 0u;
    dev->skip     = 0u;
    dev->fifo_free = 0u;                    /* read GPU_STAT again */
    fence_fix(dev);
    blns__gate(dev);
}

// A call stopped inside a command (a raw push, immediate data): the stream
// made whole (GPU_CTRL.DISCARD), in the owner's context. The GPU drops the
// cut command when it reaches it; what was queued before runs. Its marker may
// take a FIFO word; every setting is unknown (a cut command's word may have
// changed some).
static BLNS_COLD void discard(blns_t *dev)
{
    BLNS_REG_WR(dev, GPU.CTRL, BLNS_GPU_CTRL_DISCARD_Msk);
    blns__forget(dev);
    dev->fifo_free = 0u;                    /* read GPU_STAT again */
}

// Entry of every call that pushes: no GPU, or a recover requested (from any
// context) performed first
BLNS_ALWAYS_INLINE blns_status_t enter(blns_t *dev)
{
    if (!BLNS_HAS(dev, GPU))
        return BLNS_ERR_ABSENT;
    if (dev->recover_req)
        flush(dev, false);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_gpu_recover(blns_t *dev)
{
    if (!BLNS_HAS(dev, GPU))
        return BLNS_ERR_ABSENT;
    flush(dev, false);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_gpu_discard(blns_t *dev)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    discard(dev);
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_gpu_enable(blns_t *dev, bool enable)
{
    if (!BLNS_HAS(dev, GPU))
        return enable ? BLNS_ERR_ABSENT : BLNS_OK;
    if (dev->rec)
        return BLNS_ERR_STATE;
    if (!enable || dev->recover_req)
        flush(dev, !enable);                /* off, or the recover requested first */
    if (!enable)
        return BLNS_OK;
    BLNS_REG_WR(dev, CTRL, dev->regs->CTRL | BLNS_CTRL_GPU_EN_Msk);
    dev->gpu_on = true;
    dev->skip   = 0u;
    fence_fix(dev);                         /* the tags lost while off */
    blns__gate(dev);
    return blns_gpu_reset_state(dev);       /* nothing of a previous program */
}

static BLNS_NOINLINE blns_status_t push_slow(blns_t *dev, const uint32_t *words, unsigned count, bool cmds);

// The common case first: pushing (not recording nor skipping), the room
// already counted. The ERR bit is tested where a call waits for room (the
// FIFO of a stopped GPU does not drain): words that fit are pushed, and the
// recover drops them. 'cmds': the words are whole commands (a helper's);
// otherwise raw words or immediate data.
BLNS_ALWAYS_INLINE blns_status_t push_any(blns_t *dev, const uint32_t *words, unsigned count, bool cmds)
{
    known(dev, 0u, BLNS__FENCED);
    if (dev->fast && (count <= dev->fifo_free ||
                      count <= (dev->fifo_free = (uint16_t) FIELD_GET(dev->regs->GPU.STAT, BLNS_GPU_STAT_FREE)))) {
        for (unsigned i = 0; i < count; i++)
            BLNS_CMD_WRITE(dev, words[i]);
        dev->fifo_free -= (uint16_t) count;
        return BLNS_OK;
    }
    return push_slow(dev, words, count, cmds);
}

static blns_status_t push(blns_t *dev, const uint32_t *words, unsigned count)
{
    return push_any(dev, words, count, true);
}

static blns_status_t push_raw(blns_t *dev, const uint32_t *words, unsigned count)
{
    return push_any(dev, words, count, false);
}

// Words of the command word w with its operand: the GPU's parsing rule
// (opcodes 1, 2, 4, 5, 7; SET_EXT subs 1, 2, 4, 5, 9-13; EXEC_FILL LINE)
static unsigned cmd_words(uint32_t w)
{
    const uint32_t op = w >> 28;
    if (op == 0x6u)
        return ((0x3E36u >> ((w >> 24) & 0xFu)) & 1u) + 1u;
    if (op == 0x8u)
        return (w & BLNS_GPU_EXEC_LINE_Msk) ? 2u : 1u;
    return ((0xB6u >> op) & 1u) + 1u;
}

// The words of a helper's call that go into the FIFO together, from w[0]:
// one command and its operand; SET_SRC IMM with the commands up to the copy
// or EXEC_EXPAND that takes it (a call never stops with the source armed:
// the next copy would take words as data). At most 'left' words.
static unsigned unit_words(const uint32_t *w, unsigned left, unsigned depth)
{
    unsigned n = cmd_words(w[0]);
    if ((w[0] >> 28) == 0x1u && (w[0] & BLNS_GPU_SRC_IMM_Msk))
        for (unsigned k = n; k < left;) {
            const uint32_t op = w[k] >> 28;
            k += cmd_words(w[k]);
            if (op == 0x9u || op == 0xAu || op == 0xCu) {
                if (k <= depth)
                    n = k;
                break;
            }
        }
    return (n < left) ? n : left;
}

// A call stopped after 'sent' words: every setting unknown (some of the call
// are in the GPU); raw words or data may stop inside a command: the stream is
// then made whole (discard)
static BLNS_COLD blns_status_t push_stop(blns_t *dev, bool sent, bool cmds, blns_status_t st)
{
    blns__forget(dev);
    if (sent && !cmds)
        discard(dev);
    return st;
}

// Into the FIFO. GPU_STAT is read only when the free words counted since
// the last read do not cover what is waited for (the FIFO only drains in
// between). A call that fits the FIFO waits for room for all of it before its
// first word. A longer one fills the FIFO while the GPU drains it: a helper's
// whole commands (unit_words) as room appears, so it stops only between two
// commands; raw words and data as many as there is room for, so they may
// stop inside a command (push_stop). Non-blocking, a longer call returns
// BLNS_ERR_BUSY unless the FIFO is empty, then goes on as a blocking one (it
// waits only for the GPU to take its own words). wait_polls counts the polls
// without progress: it starts again at each group of words pushed.
static BLNS_NOINLINE blns_status_t push_fifo(blns_t *dev, const uint32_t *words, unsigned count, bool cmds)
{
    BLNS_TypeDef *r = dev->regs;
    if (!dev->gpu_on) {
        blns__forget(dev);
        return BLNS_ERR_GPU;
    }
    const unsigned depth = dev->caps.gpu_fifo_depth;
    const bool     whole = count <= depth;
    bool           first = true;
    while (count) {
        const unsigned unit = whole ? count : cmds ? unit_words(words, count, depth) : 1u;
        const unsigned need = (first && !whole && dev->nonblock) ? depth : unit;   /* room waited for */
        uint32_t       polls = 0u;
        while (dev->fifo_free < need) {
            const uint32_t stat = r->GPU.STAT;
            if ((stat & BLNS_GPU_STAT_ERR_Msk) || dev->recover_req)
                return push_stop(dev, !first, cmds, BLNS_ERR_GPU);  /* stopped (or to be): no draining */
            dev->fifo_free = (uint16_t) FIELD_GET(stat, BLNS_GPU_STAT_FREE);
            if (dev->fifo_free >= need)
                break;
            if (dev->nonblock && first)
                return BLNS_ERR_BUSY;
            if (blns__wait_over(dev, &polls))
                return first ? BLNS_ERR_TIMEOUT : push_stop(dev, true, cmds, BLNS_ERR_TIMEOUT);
        }
        unsigned n = unit;
        if (!cmds)
            n = (count < dev->fifo_free) ? count : dev->fifo_free;
        else
            while (n < count) {
                const unsigned u = unit_words(&words[n], count - n, depth);
                if (n + u > dev->fifo_free)
                    break;
                n += u;
            }
        for (unsigned i = 0; i < n; i++)
            BLNS_CMD_WRITE(dev, words[i]);
        dev->fifo_free -= (uint16_t) n;
        words += n;
        count -= n;
        first = false;
    }
    return BLNS_OK;
}

static BLNS_NOINLINE blns_status_t push_slow(blns_t *dev, const uint32_t *words, unsigned count, bool cmds)
{
    if (dev->rec) {                         /* recording: into the list, whole calls only */
        blns_gpu_list_t   *l = dev->rec;
        volatile uint32_t *v = (volatile uint32_t *) dev->vram;
        if (l->overflow || count > l->capacity - l->count) {
            l->overflow = true;
            return BLNS_OK;                 /* the caller's state follows as if pushed */
        }
        for (unsigned i = 0; i < count; i++)
            v[l->addr + l->count + i] = words[i];
        l->count += count;
        l->pushes++;
        return BLNS_OK;
    }
    if (dev->skip) {                        /* already in the list being spilled */
        if (--dev->skip == 0u)
            blns__gate(dev);
        return BLNS_OK;
    }
    return push_fifo(dev, words, count, cmds);
}

// Raw words may change any setting, the pointers included: the helpers
// re-send them
blns_status_t blns_gpu_push(blns_t *dev, const uint32_t *words, unsigned count)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    blns__forget(dev);
    aux_reset(dev);
    return push_raw(dev, words, count);
}

void blns_gpu_forget(blns_t *dev)
{
    blns__forget(dev);
    dev->aux_set       = 0u;                /* the pointers too: set them again */
    dev->rec_aux_saved = 0u;
}

unsigned blns_gpu_space(blns_t *dev)
{
    if (!BLNS_HAS(dev, GPU))
        return 0u;
    dev->fifo_free = (uint16_t) FIELD_GET(dev->regs->GPU.STAT, BLNS_GPU_STAT_FREE);
    return dev->fifo_free;
}

//==========================================================
// Rectangles
//==========================================================
blns_status_t blns_gpu_fill(blns_t *dev, const blns_surf_t *dst, uint16_t width, uint16_t height,
                            uint32_t colour, blns_rop_t rop)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size  = size_word(width, height);
    const uint16_t pitch = frame_pitch(dev, dst->pitch);
    const bool     keyed = rop >= BLNS_ROP_ZERO_IF_S;   /* ops 13-15 compare S with SET_TRANSP */
    uint32_t       w[8];
    unsigned       n = put_size(dev, w, size);
    w[n++] = BLNS_GPU_OP_SET_DST | pitch;
    w[n++] = dst->addr;
    n += put_fill(dev, &w[n], colour);
    if (keyed)
        n += put_transp(dev, &w[n], 0u);
    w[n++] = exec_word(BLNS_GPU_OP_EXEC_FILL, 0, dst, rop);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst->addr, pitch);
        got_size(dev, size);
        got_fill(dev, colour);
        if (keyed)
            got_transp(dev, 0u);
    }
    return st;
}

void blns_gpu_colour_set(blns_t *dev, uint32_t colour)
{
    ses_fill_set(dev, colour);
}

blns_status_t blns_gpu_span_begin(blns_t *dev, blns_pa_t addr, uint16_t pitch, uint32_t colour)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    pitch = frame_pitch(dev, pitch);
    uint32_t w[4];
    w[0] = BLNS_GPU_OP_SET_DST | pitch;
    w[1] = addr;
    unsigned n = 2u + put_fill(dev, &w[2], colour);
    st = push(dev, w, n);
    if (st == BLNS_OK) {                    /* the session only once sent */
        dev->span_pitch = pitch;
        dev->ses_set   |= BLNS__SESSION_SPAN;
        ses_fill_set(dev, colour);
        cursor_set(dev, addr, pitch);
        got_fill(dev, colour);
        known(dev, SES_SPAN, 0u);
    }
    return st;
}

blns_status_t blns__gpu_span(blns_t *dev, blns_pa_t addr, uint16_t width)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!(dev->ses_set & BLNS__SESSION_SPAN))
        return BLNS_ERR_STATE;              /* no blns_gpu_span_begin */
    SIZE_GUARD(dev, width, 1u);
    int32_t    delta;
    uint32_t   w[5];
    unsigned   n    = put_fill(dev, w, dev->ses_fill);
    const bool near = cursor_delta(dev, addr, 0u, &delta);
    if (!near) {
        w[n++] = BLNS_GPU_OP_SET_DST | dev->span_pitch;
        w[n++] = addr;
        delta  = 0;
    }
    w[n++] = BLNS_GPU_OP_EXEC_SPAN | blns__delta(delta) | width;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        if (near)
            dev->cur_base = addr;           /* the pitch stays the one pushed */
        else
            cursor_set(dev, addr, dev->span_pitch);
        got_fill(dev, dev->ses_fill);
        lost_size(dev);
        known(dev, SES_SPAN, 0u);
    }
    return st;
}

blns_status_t blns_gpu_spans(blns_t *dev, const blns_span_t *s, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        blns_status_t st = blns_gpu_span(dev, s[i].addr, s[i].width);
        if (st != BLNS_OK)
            return st;
    }
    return BLNS_OK;
}

//==========================================================
// Colour expansion
//==========================================================

// Words of an immediate source of w x h pixels of 2^l2 bits, packed with no
// row padding: ceil(w * h / pixels per word) (w * h + 31 < 2^32 for 16-bit sizes)
static uint32_t imm_words(uint32_t w, uint32_t h, unsigned l2)
{
    return (w * h + (32u >> l2) - 1u) >> (5u - l2);
}

// The session of blns_gpu_expand / _xy, built in *x (committed by the caller
// on BLNS_OK): EXEC_EXPAND fields, source format, size and colours; the
// destination pitch of an earlier expand_begin kept
static blns_status_t expand_cfg(blns_t *dev, const blns_expand_t *e, uint32_t colour, uint32_t bg,
                                blns__exp_ses_t *x)
{
    if (e->mask && !BLNS_HAS(dev, GPU_BLEND))
        return BLNS_ERR_ABSENT;
    blns_status_t st = remap_ok(dev, e->remap);
    if (st != BLNS_OK)
        return st;
    const int z = size_chk(dev, e->width, e->height);
    if (e->depth > BLNS_EXP_8BPP || z < 0)
        return BLNS_ERR_PARAM;
    if (e->depth != BLNS_EXP_1BPP && !e->mask && !palette_mode(dev))
        return BLNS_ERR_PARAM;              /* the ramp fill + (v - 1) is palette-only */
    x->src_pitch = e->src_pitch;
    x->w         = e->width;
    x->imm_n     = imm_words(e->width, e->height, e->depth);
    x->fmt       = ((uint32_t) e->depth + BLNS_FMT_1BPP) << BLNS_GPU_SRC_FMT_Pos;
    x->word      = (e->opaque ? BLNS_GPU_EXP_OPAQUE_Msk : 0u) |
                   (e->mask   ? BLNS_GPU_EXP_MASK_Msk   : 0u) |
                   (((uint32_t) e->swap  << BLNS_GPU_EXEC_DST_SWAP_Pos) & BLNS_GPU_EXEC_DST_SWAP_Msk) |
                   (((uint32_t) e->rop   << BLNS_GPU_EXP_ROP_Pos)       & BLNS_GPU_EXP_ROP_Msk) |
                   (((uint32_t) e->remap << BLNS_GPU_EXEC_REMAP_Pos)    & BLNS_GPU_EXEC_REMAP_Msk);
    x->size      = size_word(e->width, e->height);
    x->fill      = colour;
    x->bg        = bg;
    x->opaque    = e->opaque;
    x->empty     = z == 0;
    x->pitch     = dev->exp.pitch;
    known(dev, 0u, SES_EXP);                /* the GPU's are not the new session's */
    return BLNS_OK;
}

// The expansion session's size and colours, where they changed
static unsigned exp_put(const blns_t *dev, const blns__exp_ses_t *x, uint32_t *w)
{
    if ((dev->gst_known & SES_EXP) || x->empty)
        return 0u;
    unsigned n = put_size(dev, w, x->size);
    n += put_fill(dev, &w[n], x->fill);
    if (x->opaque)
        n += put_transp(dev, &w[n], x->bg);
    return n;
}

static void exp_got(blns_t *dev)
{
    if (dev->exp.empty)
        return;
    got_size(dev, dev->exp.size);
    got_fill(dev, dev->exp.fill);
    if (dev->exp.opaque)
        got_transp(dev, dev->exp.bg);
    known(dev, SES_EXP, 0u);
}

// The session committed (after its call returned BLNS_OK)
static void exp_commit(blns_t *dev, const blns__exp_ses_t *x)
{
    dev->exp      = *x;
    dev->ses_set |= BLNS__SESSION_EXP;
    exp_got(dev);
}

// Entry of the per-glyph calls: the session (and, in address mode, its
// destination pitch), its remap still valid
static blns_status_t exp_ready(const blns_t *dev, bool dst)
{
    if (!(dev->ses_set & BLNS__SESSION_EXP) || (dst && dev->exp.pitch == 0u))
        return BLNS_ERR_STATE;              /* no blns_gpu_expand_begin (/ _set) */
    return ses_remap_ok(dev, dev->exp.word, BLNS_GPU_EXEC_REMAP_Msk);
}

blns_status_t blns_gpu_expand_begin(blns_t *dev, const blns_expand_t *e, blns_pa_t dst,
                                    uint16_t dst_pitch, uint32_t colour, uint32_t bg)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    blns__exp_ses_t x;
    st = expand_cfg(dev, e, colour, bg, &x);
    if (st != BLNS_OK)
        return st;
    x.pitch = frame_pitch(dev, dst_pitch);
    uint32_t w[7];
    unsigned n = exp_put(dev, &x, w);
    w[n++] = BLNS_GPU_OP_SET_DST | x.pitch;
    w[n++] = dst;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst, x.pitch);
        exp_commit(dev, &x);
    }
    return st;
}

blns_status_t blns__gpu_expand(blns_t *dev, blns_pa_t src, blns_pa_t dst)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    st = exp_ready(dev, true);
    if (st != BLNS_OK || dev->exp.empty)
        return st;
    int32_t  delta;
    uint32_t w[10];
    unsigned n = exp_put(dev, &dev->exp, w);
    if (!cursor_delta(dev, dst, dev->exp.pitch, &delta)) {
        w[n++] = BLNS_GPU_OP_SET_DST | dev->exp.pitch;
        w[n++] = dst;
        delta  = 0;
    }
    w[n++] = BLNS_GPU_OP_SET_SRC | dev->exp.fmt | dev->exp.src_pitch;
    w[n++] = src;
    w[n++] = BLNS_GPU_OP_EXEC_EXPAND | dev->exp.word | blns__delta(delta);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst, dev->exp.pitch);
        exp_got(dev);
        known(dev, 0u, GST_SRC | SES_TEX);  /* SET_SRC: the glyph's */
    }
    return st;
}

#if !BLNS_HW_OFF(GPU_IMM)
//==========================================================
// Immediate source (SET_SRC IMM): the source words follow the EXEC in the
// command stream. Not in a list (a list carries no data) nor while a spilled
// list is skipped.
//==========================================================
static blns_status_t imm_ok(const blns_t *dev)
{
    if (!BLNS_HAS(dev, GPU_IMM))
        return BLNS_ERR_ABSENT;
    if (dev->rec || dev->skip)
        return BLNS_ERR_PARAM;
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(GPU_IMM)
// The command words, then the n data words, both with the FIFO's FREE counted.
// The data is one call, word by word: a timeout or a GPU error before its
// last word leaves data owed (the GPU would take the next words pushed as
// that data), so the rectangle is discarded: here when no data word was
// sent, by push_stop otherwise (this second one is then a no-op).
static blns_status_t imm_push(blns_t *dev, const uint32_t *w, unsigned nw,
                              const uint32_t *data, uint32_t n)
{
    blns_status_t st = push(dev, w, nw);
    if (st != BLNS_OK || n == 0u)
        return st;
    const bool nb = dev->nonblock;
    dev->nonblock = false;
    st = push_raw(dev, data, n);
    dev->nonblock = nb;
    if (st != BLNS_OK)
        discard(dev);
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_IMM)
blns_status_t blns_gpu_expand_imm(blns_t *dev, blns_pa_t dst, const uint32_t *data)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    st = exp_ready(dev, true);
    if (st != BLNS_OK)
        return st;
    st = imm_ok(dev);
    if (st != BLNS_OK || dev->exp.empty)
        return st;
    if (dev->exp.imm_n > BLNS_GPU_IMM_N_Msk || !data)
        return BLNS_ERR_PARAM;
    int32_t  delta;
    uint32_t w[10];
    unsigned n = exp_put(dev, &dev->exp, w);
    if (!cursor_delta(dev, dst, dev->exp.pitch, &delta)) {
        w[n++] = BLNS_GPU_OP_SET_DST | dev->exp.pitch;
        w[n++] = dst;
        delta  = 0;
    }
    w[n++] = BLNS_GPU_OP_SET_SRC | BLNS_GPU_SRC_IMM_Msk | dev->exp.fmt;
    w[n++] = dev->exp.imm_n;
    w[n++] = BLNS_GPU_OP_EXEC_EXPAND | dev->exp.word | blns__delta(delta);
    st = imm_push(dev, w, n, data, dev->exp.imm_n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst, dev->exp.pitch);
        exp_got(dev);
        known(dev, 0u, GST_SRC | SES_TEX);
    }
    return st;
}
#endif

//==========================================================
// Textures
//==========================================================
static uint32_t tex_word(const blns_tex_t *t)
{
    return BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_TEX |
           ((uint32_t) (t->log2_w & 0xFu) << BLNS_GPU_TEX_L2W_Pos) |
           ((uint32_t) (t->log2_h & 0xFu) << BLNS_GPU_TEX_L2H_Pos) |
           (t->transp     ? BLNS_GPU_TEX_TRANSP_Msk     : 0u) |
           (t->free_pitch ? BLNS_GPU_TEX_FREE_PITCH_Msk : 0u) |
           (t->bound      ? BLNS_GPU_TEX_BOUND_Msk      : 0u) |
           ((uint32_t) (t->swap & 7u) << BLNS_GPU_TEX_SWAP_Pos) |
           (((uint32_t) t->remap << BLNS_GPU_TEX_REMAP_Pos) & BLNS_GPU_TEX_REMAP_Msk);
}

// An RGB565A8 source (a blit's or a texture's src_alpha): the feature built,
// the alpha plane one the API set (the mask-plane rules)
static blns_status_t a8_ok(const blns_t *dev, bool src_alpha)
{
    if (!src_alpha)
        return BLNS_OK;
    if (!BLNS_HAS(dev, GPU_BLEND))
        return BLNS_ERR_ABSENT;
    return (dev->aux_set & BLNS__AUX_ALPHA) ? BLNS_OK : BLNS_ERR_STATE;
}

// The SET_SRC word of a surface source: its pitch and format (src_alpha
// refused without blending)
static uint32_t src_word(uint16_t pitch, bool src_alpha)
{
    return BLNS_GPU_OP_SET_SRC | pitch |
           ((src_alpha && !BLNS_HW_OFF(GPU_BLEND)) ? (BLNS_FMT_RGB565A8 << BLNS_GPU_SRC_FMT_Pos) : 0u);
}

// The texture session (source, transparent colour, box, filter, SET_TEX with
// the shade), built in *x (committed by the caller on BLNS_OK); the
// destination pitch of an earlier tex_begin and the step kept
static blns_status_t tex_cfg(blns_t *dev, const blns_tex_t *t, uint8_t shade, blns__tex_ses_t *x)
{
    if ((t->bound && !BLNS_HAS(dev, GPU_XY)) || (t->bilinear && !BLNS_HAS(dev, GPU_BILINEAR)) ||
        (t->border_transparent && !BLNS_HAS(dev, GPU_BLEND)))
        return BLNS_ERR_ABSENT;
    blns_status_t st = remap_ok(dev, t->remap);
    if (st == BLNS_OK)
        st = a8_ok(dev, t->src_alpha);
    if (st != BLNS_OK)
        return st;
    if ((shade != 0u && !palette_mode(dev)) ||
        (!t->free_pitch && (t->log2_w > BLNS_GPU_TEX_L2_MAX || t->log2_h > BLNS_GPU_TEX_L2_MAX)) ||
        (t->bound && (t->box_w > BLNS_GPU_TEXBOX_MAX || t->box_h > BLNS_GPU_TEXBOX_MAX)) ||
        (t->border_transparent && !t->bound))
        return BLNS_ERR_PARAM;              /* the fields would wrap */
    x->src       = src_word(t->free_pitch ? frame_pitch(dev, t->pitch) : t->pitch, t->src_alpha);
    /* without bilinear sampling built the GPU's filter is 0: nothing to send */
    x->filt      = !BLNS_HAS(dev, GPU_BILINEAR) ? 0u :
                   (uint8_t) ((t->bilinear ? BLNS_GPU_AUX_BILINEAR_Msk : 0u) |
                              (t->border_transparent ? BLNS_GPU_AUX_TBORDER_Msk : 0u));
    x->addr      = t->addr;
    x->word      = tex_word(t);
    x->shade     = (uint32_t) shade << BLNS_GPU_TEX_SHADE_Pos;
    x->box       = t->bound ? (BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_TEXBOX | BLNS_GPU_XY(t->box_w, t->box_h)) : 0u;
    x->transp    = t->transparent;
    x->transp_on = t->transp;
    x->step      = dev->tex.step;
    x->pitch     = dev->tex.pitch;
    known(dev, 0u, SES_TEX | GST_TEX);      /* SET_TEX and the box always sent */
    return BLNS_OK;
}

// SET_TEX of the session with 'shade', its box and its filter: the box goes
// with every SET_TEX sent while GST_TEX is not known (a forget, RESET_STATE,
// a list), so GST_TEX known means the GPU has the session's box too; the
// filter (TEX_FILTER, bilinear built) then, and whenever it changes
// (gst_filt: the GPU's while GST_TEX is known)
static unsigned tex_word_put(const blns_t *dev, const blns__tex_ses_t *x, uint32_t shade, uint32_t *w)
{
    const uint32_t tw   = x->word | shade;
    const bool     filt = BLNS_HAS(dev, GPU_BILINEAR) && (!(dev->gst_known & GST_TEX) || dev->gst_filt != x->filt);
    if ((dev->gst_known & GST_TEX) && dev->gst_tex == tw && !filt)
        return 0u;
    unsigned n = 0;
    if (x->box && !(dev->gst_known & GST_TEX))
        w[n++] = x->box;
    if (filt) {
        w[n++] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_TEX_FILTER | x->filt;
        w[n++] = 0u;
    }
    w[n++] = tw;
    return n;
}

// The texture session's settings, where they changed; with_step: the step
// of blns_gpu_tex_step too (spans; texrect and triangles send their own)
static unsigned tex_put(const blns_t *dev, const blns__tex_ses_t *x, uint32_t *w, bool with_step)
{
    if ((dev->gst_known & SES_TEX) && with_step)
        return 0u;
    unsigned n = put_src(dev, w, x->src, x->addr);
    if (x->transp_on)
        n += put_transp(dev, &w[n], x->transp);
    n += tex_word_put(dev, x, x->shade, &w[n]);
    if (with_step && (!(dev->gst_known & GST_STEP) || dev->gst_step != x->step)) {
        w[n++] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_STEP;
        w[n++] = x->step;
    }
    return n;
}

static void tex_got(blns_t *dev, bool with_step)
{
    got_src(dev, dev->tex.src, dev->tex.addr);
    if (dev->tex.transp_on)
        got_transp(dev, dev->tex.transp);
    dev->gst_tex  = dev->tex.word | dev->tex.shade;
    dev->gst_filt = dev->tex.filt;
    known(dev, GST_TEX, 0u);
    if (with_step) {
        dev->gst_step = dev->tex.step;
        known(dev, GST_STEP | SES_TEX, 0u);
    }
}

static void tex_commit(blns_t *dev, const blns__tex_ses_t *x)
{
    dev->tex      = *x;
    dev->ses_set |= BLNS__SESSION_TEX;
    tex_got(dev, false);
}

// Entry of the texture draws: the session (and, for tex_span, its
// destination pitch), its remap table and alpha plane still valid
static blns_status_t tex_ready(const blns_t *dev, bool dst)
{
    if (!(dev->ses_set & BLNS__SESSION_TEX) || (dst && dev->tex.pitch == 0u) ||
        ((dev->tex.src & BLNS_GPU_SRC_FMT_Msk) && !(dev->aux_set & BLNS__AUX_ALPHA)))
        return BLNS_ERR_STATE;              /* no blns_gpu_tex_begin (/ _set), or no alpha plane */
    return ses_remap_ok(dev, dev->tex.word, BLNS_GPU_TEX_REMAP_Msk);
}

blns_status_t blns_gpu_tex_set(blns_t *dev, const blns_tex_t *t, uint8_t shade)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    blns__tex_ses_t x;
    st = tex_cfg(dev, t, shade, &x);
    if (st != BLNS_OK)
        return st;
    uint32_t w[12];
    unsigned n = tex_put(dev, &x, w, false);
    st = push(dev, w, n);
    if (st == BLNS_OK)
        tex_commit(dev, &x);
    return st;
}

blns_status_t blns_gpu_tex_begin(blns_t *dev, const blns_tex_t *t, blns_pa_t dst,
                                 uint16_t dst_pitch, uint8_t shade)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    blns__tex_ses_t x;
    st = tex_cfg(dev, t, shade, &x);
    if (st != BLNS_OK)
        return st;
    x.pitch = frame_pitch(dev, dst_pitch);
    uint32_t w[14];
    unsigned n = tex_put(dev, &x, w, false);
    w[n++] = BLNS_GPU_OP_SET_DST | x.pitch;
    w[n++] = dst;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst, x.pitch);
        tex_commit(dev, &x);
    }
    return st;
}

// The GPU's SET_TEX becomes the session's with the new shade: SES_TEX stays
// as it was (source, box, step unchanged)
blns_status_t blns_gpu_tex_shade(blns_t *dev, uint8_t shade)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!(dev->ses_set & BLNS__SESSION_TEX))
        return BLNS_ERR_STATE;              /* no blns_gpu_tex_begin / _set */
    if (shade != 0u && !palette_mode(dev))
        return BLNS_ERR_PARAM;
    const uint32_t sh = (uint32_t) shade << BLNS_GPU_TEX_SHADE_Pos;
    uint32_t       w[4];
    const unsigned n  = tex_word_put(dev, &dev->tex, sh, w);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        dev->tex.shade = sh;
        dev->gst_tex   = dev->tex.word | sh;
        dev->gst_filt  = dev->tex.filt;
        known(dev, GST_TEX, 0u);
    }
    return st;
}

blns_status_t blns_gpu_tex_step(blns_t *dev, int16_t du, int16_t dv)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!(dev->ses_set & BLNS__SESSION_TEX))
        return BLNS_ERR_STATE;              /* no blns_gpu_tex_begin / _set */
    const uint32_t step = ((uint32_t) (uint16_t) du << 16) | (uint16_t) dv;
    const uint32_t w[2] = { BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_STEP, step };
    st = push(dev, w, 2);
    if (st == BLNS_OK) {
        dev->tex.step = step;
        dev->gst_step = step;
        known(dev, GST_STEP, 0u);
    }
    return st;
}

blns_status_t blns__gpu_tex_span(blns_t *dev, blns_pa_t dst, uint16_t n, uint16_t u0, uint16_t v0)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    st = tex_ready(dev, true);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, n, 1u);
    int32_t  delta;
    uint32_t w[18];
    unsigned k = tex_put(dev, &dev->tex, w, true);
    if (!cursor_delta(dev, dst, dev->tex.pitch, &delta)) {
        w[k++] = BLNS_GPU_OP_SET_DST | dev->tex.pitch;
        w[k++] = dst;
        delta  = 0;
    }
    w[k++] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_UV;
    w[k++] = ((uint32_t) u0 << 16) | v0;
    w[k++] = BLNS_GPU_OP_EXEC_TEXSPAN | blns__delta(delta) | n;
    st = push(dev, w, k);
    if (st == BLNS_OK) {
        cursor_set(dev, dst, dev->tex.pitch);
        tex_got(dev, true);
        lost_size(dev);
    }
    return st;
}

#if !BLNS_HW_OFF(GPU_REMAP)
//==========================================================
// Palette remap, mask plane, blits
//==========================================================
BLNS_COLD blns_status_t blns_gpu_remap_table(blns_t *dev, blns_wa_t table)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_REMAP))
        return BLNS_ERR_ABSENT;
    if ((table % BLNS_GPU_REMAP_TABLE_ALIGN) != 0u || table >= dev->caps.vram_words)
        return BLNS_ERR_PARAM;
    const uint32_t w[2] = { BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_REMAP_TABLE, table };
    st = push(dev, w, 2);
    if (st == BLNS_OK)
        aux_mark(dev, BLNS__AUX_REMAP);
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_MPLANE)
BLNS_COLD blns_status_t blns_gpu_mask_plane(blns_t *dev, blns_ba_t mask, bool invert)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_MPLANE))
        return BLNS_ERR_ABSENT;
    if ((mask >> 5) >= dev->caps.vram_words)
        return BLNS_ERR_PARAM;
    uint32_t w[2];
    unsigned n = put_mask(dev, w, mask, invert);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        got_mask(dev, mask, invert);
        aux_mark(dev, BLNS__AUX_MASK);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_BLEND)
BLNS_COLD blns_status_t blns_gpu_alpha_plane(blns_t *dev, uint32_t alpha)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_BLEND))
        return BLNS_ERR_ABSENT;
    if ((alpha >> 2) >= dev->caps.vram_words)
        return BLNS_ERR_PARAM;
    const uint32_t w[2] = { BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_ALPHA_PLANE, alpha };
    st = push(dev, w, 2);
    if (st == BLNS_OK)
        aux_mark(dev, BLNS__AUX_ALPHA);
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_BLEND)
// A setting of the driver: the SET_ALPHA words carry it (blns_gpu_alpha)
BLNS_COLD blns_status_t blns_gpu_blend_rule(blns_t *dev, blns_mix_t rule)
{
    if (rule == BLNS_MIX_ROUND || rule == BLNS_MIX5) {
        if (rule != BLNS_MIX_ROUND && !BLNS_HAS(dev, GPU_BLEND))
            return BLNS_ERR_ABSENT;
        dev->mix = (uint8_t) rule;
        return BLNS_OK;
    }
    return BLNS_ERR_PARAM;
}
#endif

// The options of a blit: its EXEC opcode and REMAP / MPLANE fields (its
// format: src_word)
static blns_status_t blit_cfg(const blns_t *dev, const blns_blit_t *b, uint32_t *op)
{
    if (b->mplane && !BLNS_HAS(dev, GPU_MPLANE))
        return BLNS_ERR_ABSENT;
    if (b->src_alpha && !BLNS_HAS(dev, GPU_BLEND))
        return BLNS_ERR_ABSENT;
    if (b->src_alpha && b->mplane)
        return BLNS_ERR_PARAM;              /* one auxiliary plane per copy (cause 1) */
    if (b->mplane && !(dev->aux_set & BLNS__AUX_MASK))
        return BLNS_ERR_STATE;              /* no blns_gpu_mask_plane since the GPU's was lost */
    blns_status_t st = remap_ok(dev, b->remap);
    if (st == BLNS_OK)
        st = a8_ok(dev, b->src_alpha);
    if (st != BLNS_OK)
        return st;
    *op = (b->transp ? BLNS_GPU_OP_EXEC_COPY_TRANSP : BLNS_GPU_OP_EXEC_COPY) |
          (((uint32_t) b->remap << BLNS_GPU_EXEC_REMAP_Pos) & BLNS_GPU_EXEC_REMAP_Msk) |
          (b->mplane ? BLNS_GPU_EXEC_MPLANE_Msk : 0u);
    return BLNS_OK;
}

// A blit's colours: the transparent one (ops 13-15 compare S with it too),
// the fill colour (op 15 writes it)
static unsigned blit_put(const blns_t *dev, const blns_blit_t *b, uint32_t *w)
{
    unsigned n = 0u;
    if (b->transp || b->rop >= BLNS_ROP_ZERO_IF_S)
        n = put_transp(dev, w, b->transparent);
    if (b->rop == BLNS_ROP_FILL_IF_S)
        n += put_fill(dev, &w[n], dev->ses_fill);
    return n;
}

static void blit_got(blns_t *dev, const blns_blit_t *b)
{
    if (b->transp || b->rop >= BLNS_ROP_ZERO_IF_S)
        got_transp(dev, b->transparent);
    if (b->rop == BLNS_ROP_FILL_IF_S)
        got_fill(dev, dev->ses_fill);
}

// A blit; 'pre' (0: none) is a word pushed with it, first (the frame wait of
// a present: both go, or neither: 7 words at most, within any FIFO)
static blns_status_t blit_do(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                             uint16_t width, uint16_t height, const blns_blit_t *b, uint32_t pre)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    uint32_t op;
    st = blit_cfg(dev, b, &op);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size   = size_word(width, height);
    const uint32_t srcw   = src_word(frame_pitch(dev, src->pitch), b->src_alpha);
    const uint16_t dpitch = frame_pitch(dev, dst->pitch);
    uint32_t       w[13];
    unsigned       n = 0;
    if (pre)
        w[n++] = pre;
    n += put_size(dev, &w[n], size);
    n += blit_put(dev, b, &w[n]);
    n += put_src(dev, &w[n], srcw, src->addr);
    w[n++] = BLNS_GPU_OP_SET_DST | dpitch;
    w[n++] = dst->addr;
    w[n++] = exec_word(op, src, dst, b->rop);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst->addr, dpitch);
        got_size(dev, size);
        got_src(dev, srcw, src->addr);
        blit_got(dev, b);
    }
    return st;
}

blns_status_t blns_gpu_blit(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                            uint16_t width, uint16_t height, const blns_blit_t *b)
{
    return blit_do(dev, src, dst, width, height, b, 0u);
}

#if !BLNS_HW_OFF(GPU_IMM)
blns_status_t blns_gpu_blit_imm(blns_t *dev, const blns_surf_t *dst, uint16_t width, uint16_t height,
                                const blns_blit_t *b, const uint32_t *data)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    st = imm_ok(dev);
    if (st != BLNS_OK)
        return st;
    if (b->src_alpha)
        return BLNS_ERR_PARAM;              /* no alpha in the pushed data (cause 1) */
    uint32_t op;
    st = blit_cfg(dev, b, &op);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t nd = imm_words(width, height, (unsigned) dev->mode);   /* log2 bpp = mode */
    if (!data || nd > BLNS_GPU_IMM_N_Msk || nd > dev->caps.vram_words)
        return BLNS_ERR_PARAM;
    const uint32_t size   = size_word(width, height);
    const uint16_t dpitch = frame_pitch(dev, dst->pitch);
    uint32_t       w[11];
    unsigned       n = put_size(dev, w, size);
    n += blit_put(dev, b, &w[n]);
    w[n++] = BLNS_GPU_OP_SET_DST | dpitch;
    w[n++] = dst->addr;
    w[n++] = BLNS_GPU_OP_SET_SRC | BLNS_GPU_SRC_IMM_Msk;        /* SRC_FMT 0: the destination's; */
    w[n++] = nd;                                                /* just before its EXEC (unit_words) */
    w[n++] = exec_word(op, 0, dst, b->rop);                     /* no source swap */
    st = imm_push(dev, w, n, data, nd);
    if (st == BLNS_OK) {
        cursor_set(dev, dst->addr, dpitch);
        got_size(dev, size);
        known(dev, 0u, GST_SRC | SES_TEX);
        blit_got(dev, b);
    }
    return st;
}
#endif

blns_status_t blns_gpu_copy(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                            uint16_t width, uint16_t height, blns_rop_t rop)
{
    const blns_blit_t b = { rop, false, 0u, false, BLNS_REMAP_OFF, false };
    return blns_gpu_blit(dev, src, dst, width, height, &b);
}

blns_status_t blns_gpu_copy_transp(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                                   uint16_t width, uint16_t height, blns_rop_t rop,
                                   uint32_t transparent)
{
    const blns_blit_t b = { rop, true, transparent, false, BLNS_REMAP_OFF, false };
    return blns_gpu_blit(dev, src, dst, width, height, &b);
}

#if !BLNS_HW_OFF(GPU_REMAP)
blns_status_t blns_gpu_remap_rect(blns_t *dev, const blns_surf_t *dst, uint16_t width, uint16_t height)
{
    blns_status_t st = remap_dst_ok(dev, enter(dev));
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size   = size_word(width, height);
    const uint16_t dpitch = frame_pitch(dev, dst->pitch);
    uint32_t       w[4];
    unsigned       n = put_size(dev, w, size);
    w[n++] = BLNS_GPU_OP_SET_DST | dpitch;
    w[n++] = dst->addr;
    w[n++] = exec_word(BLNS_GPU_OP_EXEC_FILL, 0, dst, BLNS_ROP_S) |
             ((uint32_t) BLNS_REMAP_DST << BLNS_GPU_EXEC_REMAP_Pos);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        cursor_set(dev, dst->addr, dpitch);
        got_size(dev, size);
    }
    return st;
}
#endif

blns_status_t blns_gpu_present_copy(blns_t *dev, const blns_surf_t *src, const blns_surf_t *dst,
                                    uint16_t width, uint16_t height, blns_present_t policy, bool *waited)
{
    bool wait = (policy == BLNS_PRESENT_VSYNC) ||
                (policy == BLNS_PRESENT_ADAPTIVE && !blns_dpi_copy_now(dev));
    if (wait && !blns_frames_flowing(dev))
        wait = false;                       /* no frames flow: at once (the GPU would wait for ever) */
    if (waited)
        *waited = wait;
    const blns_blit_t b = { BLNS_ROP_S, false, 0u, false, BLNS_REMAP_OFF, false };
    return blit_do(dev, src, dst, width, height, &b,
                   wait ? (BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_EXT2 | BLNS_GPU_EXT2_WAIT_REFR) : 0u);
}

//==========================================================
// Fences, waits, errors
//==========================================================

// The tag returned for hardware tag t: the stream stamp in [31:24] (one
// behind for the first fence after a loss of unfenced work: that fence's
// work was dropped)
static uint32_t fence_stamp(blns_t *dev, uint32_t t)
{
    const uint32_t e = (uint32_t) (uint8_t) (dev->epoch - (dev->fence_lag ? 1u : 0u));
    dev->fence_lag = false;
    return (e << 24) | t;
}

// FENCE AUTO: GPU_FENCE + 1 when reached, wherever the word runs from
blns_status_t blns_gpu_fence(blns_t *dev, bool irq, uint32_t *tag)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    const uint32_t w = BLNS_GPU_OP_FENCE | BLNS_GPU_FENCE_AUTO_Msk | (irq ? BLNS_GPU_FENCE_IRQ_Msk : 0u);
    if (dev->rec || dev->skip) {
        // recorded: counted at each call of the list (a spilled call is
        // already in it); the tag returned is one already reached
        blns_gpu_list_t *l = dev->rec;
        st = push(dev, &w, 1);
        if (l && !l->overflow)
            l->fences++;
        if (tag && st == BLNS_OK)
            *tag = ((uint32_t) dev->epoch << 24) | (dev->regs->GPU.FENCE & BLNS_GPU_FENCE_TAG_Msk);
        return st;
    }
    const uint32_t t = (dev->fence_tag + 1u) & BLNS_GPU_FENCE_TAG_Msk;
    st = push(dev, &w, 1);
    if (st != BLNS_OK)
        return st;
    dev->fence_tag = t;
    known(dev, BLNS__FENCED, 0u);
    const uint32_t stamped = fence_stamp(dev, t);
    if (tag)
        *tag = stamped;
    return BLNS_OK;
}

blns_status_t blns_gpu_wait_refresh(blns_t *dev)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!blns_frames_flowing(dev))
        return BLNS_ERR_STATE;              /* the GPU would wait for ever */
    const uint32_t w = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_EXT2 | BLNS_GPU_EXT2_WAIT_REFR;
    return push(dev, &w, 1);
}

blns_status_t blns_gpu_reset_state(blns_t *dev)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    const uint32_t w = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_EXT2 | BLNS_GPU_EXT2_RESET_STATE;
    st = push(dev, &w, 1);
    blns__forget(dev);                      /* every setting is the reset one */
    aux_reset(dev);                         /* the pointers 0: set them again */
    dev->mix = BLNS_MIX_ROUND;              /* MIX5 0: the rule of the next SET_ALPHA too */
    if (st == BLNS_OK) {                    /* the line pen at (0, 0) */
        dev->pen_x = 0;
        dev->pen_y = 0;
        known(dev, GST_PEN, 0u);
    }
    return st;
}

bool blns_gpu_fifo_low(const blns_t *dev)
{
    if (!BLNS_HAS(dev, GPU))
        return false;
    uint32_t free = FIELD_GET(dev->regs->GPU.STAT, BLNS_GPU_STAT_FREE);
    return free > dev->fifo_thr;
}

void blns_gpu_fifo_low_set(blns_t *dev, unsigned free_above)
{
    if (!BLNS_HAS(dev, GPU))
        return;
    const unsigned depth = dev->caps.gpu_fifo_depth;
    dev->fifo_thr = (uint16_t) ((free_above < depth) ? free_above : depth);   /* the register's saturation */
    BLNS_REG_WR(dev, GPU.FIFO_LOW, dev->fifo_thr);
}

blns_status_t blns_gpu_wait_space(blns_t *dev, unsigned words)
{
    BLNS_TypeDef *r = dev->regs;
    if (!BLNS_HAS(dev, GPU))
        return BLNS_ERR_ABSENT;
    if (words > dev->caps.gpu_fifo_depth)
        return BLNS_ERR_PARAM;
    if (!dev->gpu_on)
        return BLNS_ERR_GPU;
    uint32_t      polls = 0u;
    bool          thr   = false;            /* THRESH moved to words - 1 */
    blns_status_t st;
    for (;;) {
        if (dev->recover_req)
            flush(dev, false);              /* requested (before or meanwhile): then empty */
        const uint32_t stat = r->GPU.STAT;
        const uint32_t free = FIELD_GET(stat, BLNS_GPU_STAT_FREE);
        if (free >= words) {
            dev->fifo_free = (uint16_t) free;
            st = BLNS_OK;
            break;
        }
        if (stat & BLNS_GPU_STAT_ERR_Msk) {
            st = BLNS_ERR_GPU;
            break;
        }
        if (!thr) {                         /* then GPU_STAT again: the write re-arms the event */
            BLNS_REG_WR(dev, GPU.FIFO_LOW, words - 1u);
            thr = true;
            continue;
        }
        if (blns__wait_over(dev, &polls)) {
            st = BLNS_ERR_TIMEOUT;
            break;
        }
    }
    if (thr)
        BLNS_REG_WR(dev, GPU.FIFO_LOW, dev->fifo_thr);
    return st;
}

blns_status_t blns_gpu_wait_fifo_low(blns_t *dev)
{
    BLNS_TypeDef *r = dev->regs;
    if (!BLNS_HAS(dev, GPU))
        return BLNS_ERR_ABSENT;
    if (!dev->gpu_on)
        return BLNS_ERR_GPU;
    uint32_t polls = 0u;
    for (;;) {
        if (dev->recover_req)
            flush(dev, false);              /* requested (before or meanwhile): then empty */
        uint32_t stat = r->GPU.STAT;
        uint32_t free = FIELD_GET(stat, BLNS_GPU_STAT_FREE);
        if (free > dev->fifo_thr) {
            dev->fifo_free = (uint16_t) free;
            return BLNS_OK;
        }
        if (stat & BLNS_GPU_STAT_ERR_Msk)
            return BLNS_ERR_GPU;
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    }
}

// blns_gpu_fence_done, GPU_FENCE read through BLNS_REG_RD (a host test
// sees the reads of the fence status)
static bool fence_reached(const blns_t *dev, uint32_t tag)
{
    return ((BLNS_REG_RD(dev, GPU.FENCE) - tag) & BLNS_GPU_FENCE_TAG_Msk) < (1u << 23);
}

// The stamp tells the stream: the current one (GPU_FENCE decides), the one
// before the last loss (reached before it, or dropped), an older one
// (dropped, conservatively). GPU_FENCE first (one read while the GPU runs);
// GPU_STAT only when the tag is not reached.
blns_status_t blns_gpu_fence_status(const blns_t *dev, uint32_t tag)
{
    if (!BLNS_HAS(dev, GPU))
        return BLNS_ERR_ABSENT;
    const uint8_t age = (uint8_t) (dev->epoch - (uint8_t) (tag >> 24));
    if (age != 0u)
        return (age == 1u && ((dev->fence_b - tag) & BLNS_GPU_FENCE_TAG_Msk) < (1u << 23)) ? BLNS_OK
                                                                                          : BLNS_ERR_DROPPED;
    if (fence_reached(dev, tag))
        return BLNS_OK;
    const uint32_t stat = BLNS_REG_RD(dev, GPU.STAT);
    if ((stat & BLNS_GPU_STAT_ERR_Msk) || dev->recover_req || !dev->gpu_on)
        return BLNS_ERR_GPU;
    if (!(stat & BLNS_GPU_STAT_BUSY_Msk) && !fence_reached(dev, tag))
        return BLNS_ERR_STATE;              /* idle: no fence will reach it */
    return BLNS_ERR_BUSY;
}

blns_status_t blns_gpu_wait_fence(blns_t *dev, uint32_t tag)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    uint32_t polls = 0u, f = dev->regs->GPU.FENCE;
    while ((st = blns_gpu_fence_status(dev, tag)) == BLNS_ERR_BUSY) {
        if (dev->recover_req) {             /* requested meanwhile: the fence is dropped */
            flush(dev, false);
            continue;
        }
        if (dev->regs->GPU.FENCE != f) {    /* progress: the poll limit starts again */
            f     = dev->regs->GPU.FENCE;
            polls = 0u;
        }
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    }
    return st;
}

BLNS_COLD void blns_gpu_error(const blns_t *dev, blns_gpu_err_t *err)
{
    uint32_t stat = dev->regs->GPU.STAT;
    err->cause  = (uint8_t) FIELD_GET(stat, BLNS_GPU_STAT_ERR_CAUSE);
    err->opcode = (uint8_t) FIELD_GET(stat, BLNS_GPU_STAT_ERR_OPCODE);
    err->word   = dev->regs->GPU.ERR;
}

blns_status_t blns_gpu_wait(blns_t *dev)
{
    BLNS_TypeDef *r = dev->regs;
    if (!BLNS_HAS(dev, GPU))
        return BLNS_ERR_ABSENT;
    uint32_t polls = 0u;
    for (;;) {
        if (dev->recover_req)
            flush(dev, false);              /* requested (before or meanwhile): then idle */
        uint32_t stat = r->GPU.STAT;
        if (stat & BLNS_GPU_STAT_ERR_Msk)
            return BLNS_ERR_GPU;
        if (!(stat & BLNS_GPU_STAT_BUSY_Msk))
            return BLNS_OK;
        if (blns__wait_over(dev, &polls))
            return BLNS_ERR_TIMEOUT;
    }
}

//==========================================================
// Command lists
//==========================================================
BLNS_COLD blns_status_t blns_gpu_list_begin(blns_t *dev, blns_gpu_list_t *list, unsigned flags)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (dev->rec)
        return BLNS_ERR_STATE;
    if (list->capacity > dev->caps.list_max || list->addr > dev->caps.vram_words ||
        list->capacity > dev->caps.vram_words - list->addr)
        return BLNS_ERR_PARAM;
    list->count    = 0;
    list->pushes   = 0;
    list->overflow = false;
    list->fences   = 0;
    list->aux_set  = 0u;
    list->aux_clr  = 0u;
    dev->rec_aux_saved = dev->aux_set;      /* the caller's, back at list_end */
    dev->rec_aux_set   = 0u;
    dev->rec_aux_clr   = 0u;
    if (!(flags & BLNS_LIST_INHERIT))
        dev->aux_set = 0u;                  /* a list sets the pointers it uses */
    dev->rec       = list;
    blns__gate(dev);
    blns__forget(dev);                      /* the list sends every setting it uses */
    if (!(flags & BLNS_LIST_INHERIT)) {     /* mode state that changes what is drawn */
        if (BLNS_HAS(dev, GPU_XY))
            blns_gpu_clip(dev, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MIN, BLNS_GPU_XY_MAX, BLNS_GPU_XY_MAX);
        if (BLNS_HAS(dev, GPU_BLEND))
            blns_gpu_alpha(dev, false, 255u);
        if (BLNS_HAS(dev, GPU_GRAD))
            blns_gpu_gradient(dev, false, 0u, false, 0);
        if (BLNS_HAS(dev, GPU_LINE))
            blns_gpu_line_solid(dev);
        list->pushes = 0;                   /* not replayed by a spill */
    }
    return BLNS_OK;
}

BLNS_COLD blns_status_t blns_gpu_list_end(blns_t *dev)
{
    blns_gpu_list_t *l = dev->rec;
    if (!l)
        return BLNS_ERR_STATE;
    dev->rec = NULL;
    l->aux_set   = dev->rec_aux_set;
    l->aux_clr   = dev->rec_aux_clr;
    dev->aux_set = dev->rec_aux_saved;      /* the GPU's are the caller's until a call */
    blns__gate(dev);
    blns__forget(dev);                      /* the FIFO stream does not follow the list */
    return l->overflow ? BLNS_ERR_FULL : BLNS_OK;
}

// Never recorded nor dropped by a spill (a CALL is not one of the recorded
// calls): straight into the FIFO
blns_status_t blns_gpu_list_call(blns_t *dev, blns_gpu_list_t *list, bool irq)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (dev->rec)
        return BLNS_ERR_STATE;              /* no CALL inside a list */
    const uint32_t lf = (list->count != 0u) ? list->fences : 0u;
    const uint32_t t  = (dev->fence_tag + lf + 1u) & BLNS_GPU_FENCE_TAG_Msk;
    uint32_t       w[3];
    unsigned       n = 0;
    if (list->count != 0u) {
        w[n++] = BLNS_GPU_OP_CALL | list->count;
        w[n++] = list->addr;
    }
    w[n++] = BLNS_GPU_OP_FENCE | BLNS_GPU_FENCE_AUTO_Msk | (irq ? BLNS_GPU_FENCE_IRQ_Msk : 0u);
    BLNS_WMB();                             /* the list's window writes before the CALL */
    st = push_fifo(dev, w, n, true);
    if (list->count != 0u)
        blns__forget(dev);                  /* the list leaves the decoder in its own state */
    if (st != BLNS_OK)
        return st;
    if (list->count != 0u)                  /* the pointers the list sets or resets */
        dev->aux_set = (uint8_t) ((dev->aux_set & ~list->aux_clr) | list->aux_set);
    dev->fence_tag = t;
    known(dev, BLNS__FENCED, 0u);           /* (the list's words before it) */
    list->tag      = fence_stamp(dev, t);
    list->called   = true;
    return BLNS_OK;
}

blns_status_t blns_gpu_list_wait(blns_t *dev, const blns_gpu_list_t *list)
{
    return list->called ? blns_gpu_wait_fence(dev, list->tag) : BLNS_OK;
}

BLNS_COLD blns_status_t blns_gpu_list_spill(blns_t *dev, const blns_gpu_list_t *list)
{
    if (dev->rec)
        return BLNS_ERR_STATE;
    dev->skip = list->pushes;
    blns__gate(dev);
    blns__forget(dev);                      /* as at blns_gpu_list_begin */
    return BLNS_OK;
}

#if !BLNS_HW_OFF(GPU_XY)
//==========================================================
// x/y destinations, clip window, affine blit, gradient
//==========================================================
blns_status_t blns_gpu_xy_begin(blns_t *dev, blns_pa_t origin, uint16_t pitch, uint32_t colour)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_XY))
        return BLNS_ERR_ABSENT;
    pitch = frame_pitch(dev, pitch);
    uint32_t w[4];
    w[0] = BLNS_GPU_OP_SET_DST | BLNS_GPU_DST_XY_Msk | pitch;
    w[1] = origin;
    unsigned n = 2u + put_fill(dev, &w[2], colour);
    st = push(dev, w, n);
    if (st == BLNS_OK) {                    /* the surface only once sent */
        dev->xy_origin = origin;
        dev->xy_pitch  = pitch;
        dev->xy_set    = true;
        ses_fill_set(dev, colour);
        got_fill(dev, colour);
        dev->xy_x = 0;                      /* SET_DST.XY starts at (0, 0) */
        dev->xy_y = 0;
        known(dev, GST_XYDST | GST_XYPOS, GST_CUR);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
BLNS_COLD blns_status_t blns_gpu_clip(blns_t *dev, int x0, int y0, int x1, int y1)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_XY))
        return BLNS_ERR_ABSENT;
    if (!xy_ok(x0, y0) || !xy_ok(x1, y1))
        return BLNS_ERR_PARAM;
    const uint32_t w[2] = { BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_CLIP | BLNS_GPU_XY(x0, y0),
                            BLNS_GPU_XY(x1, y1) };
    return push(dev, w, 2);
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
// Entry of the x/y calls
static blns_status_t xy_enter(blns_t *dev, int x, int y)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_XY))
        return BLNS_ERR_ABSENT;
    if (!dev->xy_set)
        return BLNS_ERR_STATE;
    return xy_ok(x, y) ? BLNS_OK : BLNS_ERR_PARAM;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
// The x/y surface again when another destination came in between, then
// SET_XY unless (x, y) is the position already
static unsigned xy_move(const blns_t *dev, int x, int y, uint32_t *w)
{
    unsigned n   = 0;
    bool     pos = (dev->gst_known & GST_XYPOS) && dev->xy_x == x && dev->xy_y == y;
    if (!(dev->gst_known & GST_XYDST)) {
        w[n++] = BLNS_GPU_OP_SET_DST | BLNS_GPU_DST_XY_Msk | dev->xy_pitch;
        w[n++] = dev->xy_origin;
        pos    = (x == 0 && y == 0);
    }
    if (!pos)
        w[n++] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_XY | BLNS_GPU_XY(x, y);
    return n;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
static void xy_got(blns_t *dev, int x, int y)
{
    dev->xy_x = (int16_t) x;
    dev->xy_y = (int16_t) y;
    known(dev, GST_XYDST | GST_XYPOS, GST_CUR);
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
// Same row as the position: DELTA moves x
static bool xy_delta(const blns_t *dev, int x, int y, int32_t *dx)
{
    *dx = (int32_t) x - dev->xy_x;
    return (dev->gst_known & GST_XYPOS) && dev->xy_y == y &&
           *dx >= BLNS_GPU_SPAN_DELTA_MIN && *dx <= BLNS_GPU_SPAN_DELTA_MAX;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns__gpu_span_xy(blns_t *dev, int x, int y, uint16_t width)
{
    blns_status_t st = xy_enter(dev, x, y);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, 1u);
    uint32_t w[6];
    int32_t  dx;
    unsigned n = put_fill(dev, w, dev->ses_fill);
    if (!xy_delta(dev, x, y, &dx)) {
        n += xy_move(dev, x, y, &w[n]);
        dx = 0;
    }
    w[n++] = BLNS_GPU_OP_EXEC_SPAN | blns__delta(dx) | width;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        xy_got(dev, x, y);
        got_fill(dev, dev->ses_fill);
        lost_size(dev);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns__gpu_fill_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height)
{
    blns_status_t st = xy_enter(dev, x, y);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size = size_word(width, height);
    uint32_t       w[7];
    unsigned       n = put_fill(dev, w, dev->ses_fill);
    n += xy_move(dev, x, y, &w[n]);
    n += put_size(dev, &w[n], size);
    w[n++] = BLNS_GPU_OP_EXEC_FILL;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        xy_got(dev, x, y);
        got_fill(dev, dev->ses_fill);
        got_size(dev, size);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns_gpu_fills_xy(blns_t *dev, const blns_rect_t *r, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        blns_status_t st = blns_gpu_fill_xy(dev, r[i].x, r[i].y, r[i].width, r[i].height);
        if (st != BLNS_OK)
            return st;
    }
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
// The texture walk of a TEXRECT (a rectangle or a triangle): the first
// texel, the step per pixel and per row
static unsigned uv_put(uint32_t *w, uint16_t u0, uint16_t v0, int16_t du, int16_t dv, int16_t du_r, int16_t dv_r)
{
    w[0] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_UV;
    w[1] = ((uint32_t) u0 << 16) | v0;
    w[2] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_STEP;
    w[3] = ((uint32_t) (uint16_t) du << 16) | (uint16_t) dv;
    w[4] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_STEP_ROW;
    w[5] = ((uint32_t) (uint16_t) du_r << 16) | (uint16_t) dv_r;
    return 6u;
}

blns_status_t blns_gpu_texrect_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height,
                                  uint16_t u0, uint16_t v0, int16_t du, int16_t dv,
                                  int16_t du_r, int16_t dv_r)
{
    blns_status_t st = xy_enter(dev, x, y);
    if (st != BLNS_OK)
        return st;
    st = tex_ready(dev, false);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size = size_word(width, height);
    uint32_t       w[22];
    unsigned       n = tex_put(dev, &dev->tex, w, false);
    n += xy_move(dev, x, y, &w[n]);
    n += put_size(dev, &w[n], size);
    n += uv_put(&w[n], u0, v0, du, dv, du_r, dv_r);
    w[n++] = BLNS_GPU_OP_EXEC_TEXRECT;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        xy_got(dev, x, y);
        tex_got(dev, false);
        got_size(dev, size);
        known(dev, 0u, GST_STEP | SES_TEX);     /* its own step */
    }
    return st;
}

// round(v / 2^sh), v signed (the shift of a negative value as a floor)
static int64_t fx_round(int64_t v, unsigned sh)
{
    const int64_t a = v + ((int64_t) 1 << (sh - 1u));
    return (a >= 0) ? (a >> sh) : -((-a + ((int64_t) 1 << sh) - 1) >> sh);
}

// A 1/65536 step as 5.11 (false: out of its range)
static bool fx_step(int32_t s, int16_t *r)
{
    const int64_t v = fx_round(s, 5u);
    *r = (int16_t) v;
    return v >= INT16_MIN && v <= INT16_MAX;
}

#define FX_TILE 64

blns_status_t blns_gpu_texrect_fx_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height,
                                     int64_t u_at_xy, int64_t v_at_xy, int32_t du, int32_t dv,
                                     int32_t du_r, int32_t dv_r)
{
    blns_status_t st = xy_enter(dev, x, y);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    int16_t s[4];
    const int xl = x + ((width - 1) & ~(FX_TILE - 1)), yl = y + ((height - 1) & ~(FX_TILE - 1));
    if (!fx_step(du, &s[0]) || !fx_step(dv, &s[1]) || !fx_step(du_r, &s[2]) || !fx_step(dv_r, &s[3]) ||
        !xy_ok(xl, yl))
        return BLNS_ERR_PARAM;              /* nothing pushed */
    for (int j = 0; j < height; j += FX_TILE)
        for (int i = 0; i < width; i += FX_TILE) {
            /* the tile's start from the model (10.6, wrapping as the walker does) */
            const int64_t u = u_at_xy + (int64_t) du * i + (int64_t) du_r * j;
            const int64_t v = v_at_xy + (int64_t) dv * i + (int64_t) dv_r * j;
            st = blns_gpu_texrect_xy(dev, x + i, y + j, (uint16_t) ((width - i < FX_TILE) ? width - i : FX_TILE),
                                     (uint16_t) ((height - j < FX_TILE) ? height - j : FX_TILE),
                                     (uint16_t) fx_round(u, 10u), (uint16_t) fx_round(v, 10u), s[0], s[1], s[2], s[3]);
            if (st != BLNS_OK)
                return st;
        }
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
// Blits in x/y mode: the source surface as in address mode, the destination
// at (x, y) of the blns_gpu_xy_begin surface, clipped by the window
static uint32_t exec_xy(uint32_t op, const blns_surf_t *src, uint8_t swap, blns_rop_t rop)
{
    const blns_surf_t dst = { 0u, 0u, swap };
    return exec_word(op, src, &dst, rop);
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns_gpu_blit_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                               uint16_t width, uint16_t height, uint8_t swap, const blns_blit_t *b)
{
    blns_status_t st = xy_enter(dev, x, y);
    if (st != BLNS_OK)
        return st;
    uint32_t op;
    st = blit_cfg(dev, b, &op);
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size = size_word(width, height);
    const uint32_t srcw = src_word(frame_pitch(dev, src->pitch), b->src_alpha);
    uint32_t       w[11];
    unsigned       n = xy_move(dev, x, y, w);
    n += put_size(dev, &w[n], size);
    n += blit_put(dev, b, &w[n]);
    n += put_src(dev, &w[n], srcw, src->addr);
    w[n++] = exec_xy(op, src, swap, b->rop);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        xy_got(dev, x, y);
        got_size(dev, size);
        got_src(dev, srcw, src->addr);
        blit_got(dev, b);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns_gpu_copy_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                               uint16_t width, uint16_t height, uint8_t swap, blns_rop_t rop)
{
    const blns_blit_t b = { rop, false, 0u, false, BLNS_REMAP_OFF, false };
    return blns_gpu_blit_xy(dev, src, x, y, width, height, swap, &b);
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns_gpu_copy_transp_xy(blns_t *dev, const blns_surf_t *src, int x, int y,
                                      uint16_t width, uint16_t height, uint8_t swap, blns_rop_t rop,
                                      uint32_t transparent)
{
    const blns_blit_t b = { rop, true, transparent, false, BLNS_REMAP_OFF, false };
    return blns_gpu_blit_xy(dev, src, x, y, width, height, swap, &b);
}
#endif

#if !BLNS_HW_OFF(GPU_REMAP)
blns_status_t blns_gpu_remap_rect_xy(blns_t *dev, int x, int y, uint16_t width, uint16_t height)
{
    blns_status_t st = remap_dst_ok(dev, xy_enter(dev, x, y));
    if (st != BLNS_OK)
        return st;
    SIZE_GUARD(dev, width, height);
    const uint32_t size = size_word(width, height);
    uint32_t       w[5];
    unsigned       n = xy_move(dev, x, y, w);
    n += put_size(dev, &w[n], size);
    w[n++] = BLNS_GPU_OP_EXEC_FILL | ((uint32_t) BLNS_REMAP_DST << BLNS_GPU_EXEC_REMAP_Pos);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        xy_got(dev, x, y);
        got_size(dev, size);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns_gpu_expand_set(blns_t *dev, const blns_expand_t *e, uint32_t colour, uint32_t bg)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_XY))
        return BLNS_ERR_ABSENT;
    blns__exp_ses_t x;
    st = expand_cfg(dev, e, colour, bg, &x);
    if (st != BLNS_OK)
        return st;
    uint32_t w[5];
    unsigned n = exp_put(dev, &x, w);
    st = push(dev, w, n);
    if (st == BLNS_OK)
        exp_commit(dev, &x);
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns__gpu_expand_xy(blns_t *dev, blns_pa_t src, int x, int y)
{
    blns_status_t st = xy_enter(dev, x, y);
    if (st != BLNS_OK)
        return st;
    st = exp_ready(dev, false);
    if (st != BLNS_OK || dev->exp.empty)
        return st;
    uint32_t w[11];
    int32_t  dx;
    unsigned n = exp_put(dev, &dev->exp, w);
    if (!xy_delta(dev, x, y, &dx)) {
        n += xy_move(dev, x, y, &w[n]);
        dx = 0;
    }
    w[n++] = BLNS_GPU_OP_SET_SRC | dev->exp.fmt | dev->exp.src_pitch;
    w[n++] = src;
    w[n++] = BLNS_GPU_OP_EXEC_EXPAND | dev->exp.word | blns__delta(dx);
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        xy_got(dev, x, y);
        exp_got(dev);
        known(dev, 0u, GST_SRC | SES_TEX);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_XY)
blns_status_t blns_gpu_text_xy(blns_t *dev, int x, int y, const blns_pa_t *src,
                               const int16_t *advance, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        blns_status_t st = blns_gpu_expand_xy(dev, src[i], x, y);
        if (st != BLNS_OK)
            return st;
        x += advance ? advance[i] : (int) dev->exp.w;
    }
    return BLNS_OK;
}
#endif

#if !BLNS_HW_OFF(GPU_GRAD)
BLNS_COLD blns_status_t blns_gpu_gradient(blns_t *dev, bool enable, uint16_t n, bool per_pixel, int step)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_GRAD))
        return enable ? BLNS_ERR_ABSENT : BLNS_OK;
    if (enable && (!palette_mode(dev) || step < -8 || step > 7 || n > 0xFFFu))
        return BLNS_ERR_PARAM;
    const uint32_t w = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_GRAD | ((uint32_t) n & 0xFFFu) |
                       (per_pixel ? BLNS_GPU_GRAD_AXIS_Msk : 0u) |
                       (((uint32_t) step & 0xFu) << BLNS_GPU_GRAD_STEP_Pos) |
                       (enable ? BLNS_GPU_GRAD_EN_Msk : 0u);
    return push(dev, &w, 1);
}
#endif

#if !BLNS_HW_OFF(GPU_GRAD)
BLNS_COLD blns_status_t blns_gpu_gradient_rgb(blns_t *dev, bool enable, uint16_t n, bool per_pixel,
                                    int dr, int dg, int db)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_GRAD))
        return enable ? BLNS_ERR_ABSENT : BLNS_OK;
    if (!enable)
        return blns_gpu_gradient(dev, false, 0u, false, 0);
    if (palette_mode(dev) || n > 0xFFFu || dr < -512 || dr > 511 || dg < -512 || dg > 511 ||
        db < -512 || db > 511)
        return BLNS_ERR_PARAM;
    const uint32_t w[3] = {
        BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_GRAD_RGB,
        (((uint32_t) dr & 0x3FFu) << 20) | (((uint32_t) dg & 0x3FFu) << 10) | ((uint32_t) db & 0x3FFu),
        BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_GRAD | ((uint32_t) n & 0xFFFu) |
            (per_pixel ? BLNS_GPU_GRAD_AXIS_Msk : 0u) | BLNS_GPU_GRAD_EN_Msk | BLNS_GPU_GRAD_RGB_Msk
    };
    return push(dev, w, 3);
}
#endif

#if !BLNS_HW_OFF(GPU_BLEND)
BLNS_COLD blns_status_t blns_gpu_alpha(blns_t *dev, bool enable, uint8_t alpha)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_BLEND))
        return enable ? BLNS_ERR_ABSENT : BLNS_OK;
    const uint32_t w = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_ALPHA | alpha |
                       (enable ? BLNS_GPU_ALPHA_EN_Msk : 0u) | (dev->mix ? BLNS_GPU_ALPHA_MIX5_Msk : 0u);
    return push(dev, &w, 1);
}
#endif

#if !BLNS_HW_OFF(GPU_TRI)
// The three vertices of a triangle (false: one outside the 12.4 range)
static bool vtx_put(uint32_t *w, const int32_t x[3], const int32_t y[3])
{
    for (unsigned i = 0; i < 3u; i++) {
        if (!vtx_ok(x[i], y[i]))
            return false;
        w[2u * i]      = BLNS_GPU_OP_SET_EXT | (BLNS_GPU_EXT_V0 + i * (BLNS_GPU_EXT_V1 - BLNS_GPU_EXT_V0));
        w[2u * i + 1u] = ((uint32_t) (uint16_t) y[i] << 16) | (uint16_t) x[i];
    }
    return true;
}
#endif

#if !BLNS_HW_OFF(GPU_TRI)
// Triangles: the x/y surface (sent again when another destination came in
// between); the walk starts at the triangle's box: the position is lost
static blns_status_t tri_enter(blns_t *dev)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_TRI))
        return BLNS_ERR_ABSENT;
    return dev->xy_set ? BLNS_OK : BLNS_ERR_STATE;
}
#endif

#if !BLNS_HW_OFF(GPU_TRI)
static unsigned tri_dst(const blns_t *dev, uint32_t *w)
{
    if (dev->gst_known & GST_XYDST)
        return 0u;
    w[0] = BLNS_GPU_OP_SET_DST | BLNS_GPU_DST_XY_Msk | dev->xy_pitch;
    w[1] = dev->xy_origin;
    return 2u;
}
#endif

#if !BLNS_HW_OFF(GPU_TRI)
// EXEC_FILL TRI: in the session colour (remap off), or the destination
// through the remap table (REMAP DST: the fill colour is not used)
static blns_status_t tri_fill(blns_t *dev, const int32_t x[3], const int32_t y[3], unsigned remap)
{
    uint32_t w[11];
    unsigned n = (remap == BLNS_REMAP_OFF) ? put_fill(dev, w, dev->ses_fill) : 0u;
    n += tri_dst(dev, &w[n]);
    if (!vtx_put(&w[n], x, y))
        return BLNS_ERR_PARAM;
    n += 6u;
    w[n++] = BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_TRI_Msk | ((uint32_t) remap << BLNS_GPU_EXEC_REMAP_Pos);
    blns_status_t st = push(dev, w, n);
    if (st == BLNS_OK) {
        if (remap == BLNS_REMAP_OFF)
            got_fill(dev, dev->ses_fill);
        known(dev, GST_XYDST, GST_XYPOS | GST_CUR);
    }
    return st;
}

blns_status_t blns_gpu_tri_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                              int32_t x2, int32_t y2)
{
    blns_status_t st = tri_enter(dev);
    if (st != BLNS_OK)
        return st;
    const int32_t x[3] = { x0, x1, x2 }, y[3] = { y0, y1, y2 };
    return tri_fill(dev, x, y, BLNS_REMAP_OFF);
}
#endif

#if !BLNS_HW_OFF(GPU_TRI) && !BLNS_HW_OFF(GPU_REMAP)
blns_status_t blns_gpu_remap_tri_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                                    int32_t x2, int32_t y2)
{
    blns_status_t st = remap_dst_ok(dev, tri_enter(dev));
    if (st != BLNS_OK)
        return st;
    const int32_t x[3] = { x0, x1, x2 }, y[3] = { y0, y1, y2 };
    return tri_fill(dev, x, y, BLNS_REMAP_DST);
}
#endif

#if !BLNS_HW_OFF(GPU_TRI)
blns_status_t blns_gpu_tritex_xy(blns_t *dev, const int32_t x[3], const int32_t y[3],
                                 uint16_t u0, uint16_t v0, int16_t du, int16_t dv,
                                 int16_t du_r, int16_t dv_r)
{
    blns_status_t st = tri_enter(dev);
    if (st != BLNS_OK)
        return st;
    st = tex_ready(dev, false);
    if (st != BLNS_OK)
        return st;
    uint32_t w[26];
    unsigned n = tex_put(dev, &dev->tex, w, false);
    n += tri_dst(dev, &w[n]);
    if (!vtx_put(&w[n], x, y))
        return BLNS_ERR_PARAM;
    n += 6u;
    n += uv_put(&w[n], u0, v0, du, dv, du_r, dv_r);
    w[n++] = BLNS_GPU_OP_EXEC_TEXRECT | BLNS_GPU_EXEC_TRI_Msk;
    st = push(dev, w, n);
    if (st == BLNS_OK) {
        tex_got(dev, false);
        known(dev, GST_XYDST, GST_XYPOS | GST_CUR | GST_STEP | SES_TEX);
    }
    return st;
}
#endif

#if !BLNS_HW_OFF(GPU_LINE)
//==========================================================
// Lines
//==========================================================
static const blns_line_t line_plain;        /* opt NULL: solid, op S, no remap */

BLNS_COLD blns_status_t blns_gpu_line_pattern(blns_t *dev, uint32_t pattern, unsigned len)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_LINE))
        return BLNS_ERR_ABSENT;
    if (len == 0u || len > BLNS_GPU_LINE_LEN_MAX)
        return BLNS_ERR_PARAM;
    const uint32_t w[2] = { BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_LINE_PATTERN |
                            ((len - 1u) << BLNS_GPU_AUX_LEN_Pos), pattern };
    return push(dev, w, 2);
}

// Entry of the line calls: the feature, the x/y surface, the options
static blns_status_t line_enter(blns_t *dev, const blns_line_t *o)
{
    blns_status_t st = enter(dev);
    if (st != BLNS_OK)
        return st;
    if (!BLNS_HAS(dev, GPU_LINE))
        return BLNS_ERR_ABSENT;
    if (!dev->xy_set)
        return BLNS_ERR_STATE;
    if (o->aa && !BLNS_HAS(dev, GPU_BLEND))
        return BLNS_ERR_ABSENT;
    st = remap_ok(dev, o->remap);
    if (st != BLNS_OK)
        return st;
    return (o->rop <= BLNS_ROP_FILL_IF_S) ? BLNS_OK : BLNS_ERR_PARAM;
}

// End points: 12.4 fixed point in 16 bits
static bool line_pt_ok(int32_t x, int32_t y)
{
    return x >= -32768 && x <= 32767 && y >= -32768 && y <= 32767;
}

static uint32_t line_pt(int32_t x, int32_t y)
{
    return ((uint32_t) (uint16_t) y << 16) | (uint16_t) x;
}

// The words before a line from (x0, y0): the colours, the x/y surface when
// another destination came in between, the pen unless the last line ended
// at (x0, y0). The SET_XY position is neither used nor changed.
static unsigned line_pre(const blns_t *dev, uint32_t *w, int32_t x0, int32_t y0, const blns_line_t *o)
{
    unsigned n = put_fill(dev, w, dev->ses_fill);
    if (o->opaque || o->rop >= BLNS_ROP_ZERO_IF_S)      /* ops 13-15 compare with it too */
        n += put_transp(dev, &w[n], o->opaque ? o->bg : 0u);
    if (!(dev->gst_known & GST_XYDST)) {
        w[n++] = BLNS_GPU_OP_SET_DST | BLNS_GPU_DST_XY_Msk | dev->xy_pitch;
        w[n++] = dev->xy_origin;
    }
    if (!(dev->gst_known & GST_PEN) || dev->pen_x != x0 || dev->pen_y != y0) {
        w[n++] = BLNS_GPU_OP_SET_EXT | BLNS_GPU_EXT_AUX | BLNS_GPU_AUX_LINE_PEN;
        w[n++] = line_pt(x0, y0);
    }
    return n;
}

// The line itself: EXEC_FILL LINE and its end point
static unsigned line_put(uint32_t *w, int32_t x1, int32_t y1, const blns_line_t *o, bool no_last, bool ph_rst)
{
    w[0] = BLNS_GPU_OP_EXEC_FILL | BLNS_GPU_EXEC_LINE_Msk | o->rop |
           (((uint32_t) o->remap << BLNS_GPU_EXEC_REMAP_Pos) & BLNS_GPU_EXEC_REMAP_Msk) |
           (o->aa ? BLNS_GPU_LINE_AA_Msk : 0u) | (no_last ? BLNS_GPU_LINE_NO_LAST_Msk : 0u) |
           (o->opaque ? BLNS_GPU_LINE_OPAQUE_Msk : 0u) | (ph_rst ? BLNS_GPU_LINE_PH_RST_Msk : 0u);
    w[1] = line_pt(x1, y1);
    return 2u;
}

// Pushed: the settings of line_pre, the pen at the last end point
static void line_got(blns_t *dev, const blns_line_t *o, int32_t x1, int32_t y1)
{
    got_fill(dev, dev->ses_fill);
    if (o->opaque || o->rop >= BLNS_ROP_ZERO_IF_S)
        got_transp(dev, o->opaque ? o->bg : 0u);
    if (!(dev->gst_known & GST_XYDST))      /* SET_DST: the position (0, 0), not tracked */
        known(dev, GST_XYDST, GST_XYPOS | GST_CUR);
    dev->pen_x = (int16_t) x1;
    dev->pen_y = (int16_t) y1;
    known(dev, GST_PEN, 0u);
}

// One segment, end points checked: one push
static blns_status_t line_seg(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                              const blns_line_t *o, bool no_last, bool ph_rst)
{
    uint32_t w[10];
    unsigned n = line_pre(dev, w, x0, y0, o);
    n += line_put(&w[n], x1, y1, o, no_last, ph_rst);
    blns_status_t st = push(dev, w, n);
    if (st == BLNS_OK)
        line_got(dev, o, x1, y1);
    return st;
}

blns_status_t blns_gpu_line_xy(blns_t *dev, int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                               const blns_line_t *opt)
{
    const blns_line_t *o  = opt ? opt : &line_plain;
    blns_status_t      st = line_enter(dev, o);
    if (st != BLNS_OK)
        return st;
    if (!line_pt_ok(x0, y0) || !line_pt_ok(x1, y1))
        return BLNS_ERR_PARAM;
    return line_seg(dev, x0, y0, x1, y1, o, o->no_last, o->phase_reset);
}

blns_status_t blns_gpu_line_px(blns_t *dev, int x0, int y0, int x1, int y1, const blns_line_t *opt)
{
    const blns_line_t *o  = opt ? opt : &line_plain;
    blns_status_t      st = line_enter(dev, o);
    if (st != BLNS_OK)
        return st;
    if (!xy_ok(x0, y0) || !xy_ok(x1, y1))
        return BLNS_ERR_PARAM;
    return line_seg(dev, BLNS_SUB(x0) + 8, BLNS_SUB(y0) + 8, BLNS_SUB(x1) + 8, BLNS_SUB(y1) + 8, o,
                    o->no_last, o->phase_reset);
}

// The segments of a checked polyline: NO_LAST on all but the last one of an
// open polyline; PH_RST on the first
static blns_status_t polyline(blns_t *dev, const int32_t *xy, unsigned n, bool closed, const blns_line_t *o)
{
    const unsigned segs = closed ? n : n - 1u;
    for (unsigned k = 0; k < segs; k++) {
        const unsigned j  = (k + 1u == n) ? 0u : k + 1u;
        blns_status_t  st = line_seg(dev, xy[2u * k], xy[2u * k + 1u], xy[2u * j], xy[2u * j + 1u], o,
                                     closed || k + 1u < segs || o->no_last, k == 0u && o->phase_reset);
        if (st != BLNS_OK)
            return st;
    }
    return BLNS_OK;
}

blns_status_t blns_gpu_polyline_xy(blns_t *dev, const int32_t *xy, unsigned n, bool closed,
                                   const blns_line_t *opt)
{
    const blns_line_t *o  = opt ? opt : &line_plain;
    blns_status_t      st = line_enter(dev, o);
    if (st != BLNS_OK)
        return st;
    if (n < 2u)
        return BLNS_OK;
    if (!xy)
        return BLNS_ERR_PARAM;
    for (unsigned i = 0; i < n; i++)
        if (!line_pt_ok(xy[2u * i], xy[2u * i + 1u]))
            return BLNS_ERR_PARAM;
    return polyline(dev, xy, n, closed, o);
}

blns_status_t blns_gpu_rect_outline_xy(blns_t *dev, int x, int y, unsigned w, unsigned h,
                                       const blns_line_t *opt)
{
    const blns_line_t *o  = opt ? opt : &line_plain;
    blns_status_t      st = line_enter(dev, o);
    if (st != BLNS_OK)
        return st;
    if (!xy_ok(x, y) || w > 4096u || h > 4096u)
        return BLNS_ERR_PARAM;
    if (w == 0u || h == 0u)
        return BLNS_OK;
    const int x1 = x + (int) w - 1, y1 = y + (int) h - 1;
    if (!xy_ok(x1, y1))
        return BLNS_ERR_PARAM;
    const int32_t px0 = BLNS_SUB(x) + 8, py0 = BLNS_SUB(y) + 8, px1 = BLNS_SUB(x1) + 8, py1 = BLNS_SUB(y1) + 8;
    if (w == 1u || h == 1u)                 /* one line: each pixel once */
        return line_seg(dev, px0, py0, px1, py1, o, false, o->phase_reset);
    /* the closed polyline of the corners, in one push (16 words at most) */
    const int32_t xy[8] = { px0, py0, px1, py0, px1, py1, px0, py1 };
    uint32_t      cw[16];
    unsigned      n = line_pre(dev, cw, px0, py0, o);
    for (unsigned k = 0; k < 4u; k++)
        n += line_put(&cw[n], xy[(2u * k + 2u) & 7u], xy[(2u * k + 3u) & 7u], o, true, k == 0u && o->phase_reset);
    st = push(dev, cw, n);
    if (st == BLNS_OK)
        line_got(dev, o, px0, py0);
    return st;
}
#endif

static int16_t grad_511(int64_t num, int64_t den)
{
    /* (u in 10.6, x / y in 12.4): texels per pixel = 4 num / den; in 5.11: 512
     * num / den, rounded half away from zero whatever the winding (den > 0
     * first) */
    int64_t n = num * 512;
    if (den < 0) {
        n   = -n;
        den = -den;
    }
    int64_t q = (n >= 0) ? (n + den / 2) / den : (n - den / 2) / den;
    if (q > 32767)  q = 32767;
    if (q < -32768) q = -32768;
    return (int16_t) q;
}

BLNS_COLD bool blns_gpu_tri_uv_gradients(const int32_t x[3], const int32_t y[3],
                               const int32_t u[3], const int32_t v[3], int16_t g[4])
{
    const int64_t x1 = x[1] - x[0], y1 = y[1] - y[0], x2 = x[2] - x[0], y2 = y[2] - y[0];
    const int64_t den = x1 * y2 - x2 * y1;
    if (den == 0)
        return false;
    const int64_t u1 = u[1] - u[0], u2 = u[2] - u[0], v1 = v[1] - v[0], v2 = v[2] - v[0];
    g[0] = grad_511(u1 * y2 - u2 * y1, den);    /* du / dx */
    g[1] = grad_511(v1 * y2 - v2 * y1, den);    /* dv / dx */
    g[2] = grad_511(x1 * u2 - x2 * u1, den);    /* du / dy */
    g[3] = grad_511(x1 * v2 - x2 * v1, den);    /* dv / dy */
    return true;
}
