/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_model_impl.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * The register and VRAM model of the host tests, included once by each test
 * program (test_driver.c, test_lvgl.c): its state is static to that program.
 * The driver files reach it through blns_model.h.
 *----------------------------------------------------------------------------*/
#ifndef BLNS_MODEL_IMPL_H
#define BLNS_MODEL_IMPL_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "belenos.h"

/*---------------------------------------------------------------------------
 * Model
 *
 * The GPU as the RTL behaves at its register port (blns_gpu_dec.v):
 *   - the push side tracks the words pushed: whether the next one is an
 *     operand (push_owed), and the immediate data words owed after an
 *     armed EXEC (tagged: never decoded as commands);
 *   - ABORT / CLEAR_ERR flush the FIFO and disarm the immediate source; an
 *     operand still owed by the push side is then discarded when it comes;
 *     the data count is kept (the data words are dropped);
 *   - GPU_EN = 0 flushes and resets the push side (the next word pushed is a
 *     command); words pushed with GPU_EN = 0, or into a full FIFO, are
 *     dropped (GPU_OVFL);
 *   - DISCARD resets the push side too; when the stream was partial (an
 *     operand or data owed, the immediate source armed) and neither a flush
 *     in the same write nor ERR, a marker enters the FIFO (pending while it
 *     is full: FREE 0, pushes dropped); the decoder there drops the command
 *     waiting for its operand, disarms, and abandons the immediate copy whose
 *     data it cut;
 *   - GPU_FIFO_LOW: THRESH (reset depth / 2, saturated at the depth);
 *   - an invalid word (opcode 0) or a rectangle reaching VRAM_WORDS (cause
 *     5) stops the decoder (GPU_STAT.ERR): the FIFO no longer drains;
 *   - fills, spans and op-S copies write their pixels (8 and 16 bpp, every
 *     swap), so walks and pitches are checked as pixels; an immediate op-S
 *     copy (address mode) draws the data words as the decoder takes them,
 *     a flush abandons it; at 16 bpp with SET_ALPHA EN (a BLEND build) they
 *     blend, op-S fills and spans take the SET_GRAD / SET_GRAD_RGB ramp, and
 *     an op-S EXEC_EXPAND from the VRAM (address mode) draws its values
 *     (MASK: the coverage blend of the fill colour), as gpu_model.v does
 *     (bench/verilog: gpu_blend565, gpu_a_mask, gpu_x_gval, gpu_d_expand);
 *   - SET_ALPHA MIX5 (LVGL's rule: a 5-bit factor, truncated; coverage x A
 *     as (c A) >> 8) applies to every blend of a BLEND build; RGB565A8
 *     sources (SRC_FMT 5, SET_AUX ALPHA_PLANE): op-S copies (address mode,
 *     COPY_TRANSP's key first) blend each pixel with its alpha byte;
 *   - textures (EXEC_TEXSPAN, EXEC_TEXRECT; not the triangle) draw at 16 bpp
 *     with remap off, nearest or bilinear (SET_AUX TEX_FILTER: the taps, their
 *     weights and premultiplied blend, BOUND's clamp or transparent border,
 *     keyed taps, SRC_FMT 5), in address or x/y mode (the clip window), from
 *     the closed forms of the specification (as gpu_model.v); a texel, tap
 *     or alpha byte at or past VRAM_WORDS is cause 5, the pixels before it
 *     drawn;
 *   - lines (EXEC_FILL LINE) draw every pixel (8 and 16 bpp: raster ops,
 *     SET_TRANSP, blending, remap, clip window, pattern, AA) from the closed
 *     forms of the specification; the pen, pattern and phase follow their
 *     reset rules;
 *   - the commands of a feature not built in BLNS_CFG2 that the driver may
 *     send (lines, SET_AUX, EXPAND MASK) are refused as the RTL does (cause 2
 *     without the operand taken; cause 1 for reserved encodings).
 * The decoder runs when the test (or the wait hook) calls model_run (or
 * model_step: a few words at a time). A test may stop the decoder at the n-th
 * EXEC as the RTL does on an error after acceptance (stop_exec: cause 5).
 *---------------------------------------------------------------------------*/
#ifndef MODEL_WORDS
#define MODEL_WORDS 16384u
#endif
#ifndef MODEL_FIFO_AW
#define MODEL_FIFO_AW 3u    /* GPU command FIFO of 8 words: the RTL default */
#endif
#define LOG_MAX     1024u

static BLNS_TypeDef regs;
static uint32_t     vram[MODEL_WORDS];
static blns_t       dev;

#define RW(reg)  (*(volatile uint32_t *) &(reg))      /* the model writes read-only registers */

typedef struct {
    uint32_t op;                /* EXEC opcode                                */
    uint32_t addr;              /* first pixel drawn                          */
    uint32_t pitch, w, h;
    uint32_t fill, transp;
    uint32_t src, src_pitch, src_fmt;
    uint32_t tex, step, texbox;
    uint32_t imm;               /* immediate data words taken (0: VRAM source) */
    uint32_t word;              /* the EXEC word itself                       */
    uint32_t opnd;              /* a line's end point; pen: its start         */
    uint32_t pen;
} draw_t;

static struct {
    uint32_t q[256];
    uint8_t  qt[256];           /* tag: 1 immediate data (push side), 2 a DISCARD
                                 * marker, 3 one cutting an immediate copy   */
    unsigned qn, depth;
    bool     mpend;             /* a marker waits for FIFO room               */
    uint8_t  mtag;              /* ... its tag                                */
    uint32_t thresh;            /* GPU_FIFO_LOW.THRESH                        */
    unsigned discards;          /* GPU_CTRL writes with DISCARD               */
    unsigned markers;           /* markers queued                             */
    bool     gpu_en;
    /* push side */
    bool     owed, nsel, arm, pact;
    uint32_t pcnt;
    /* decoder */
    bool     skip;              /* discard the next operand (after a flush)   */
    uint32_t pend;              /* command waiting for its operand            */
    bool     err, imm_arm;
    uint32_t imm_n;
    /* the immediate op-S copy being drawn: its walk, the next pixel */
    bool     ir;
    uint32_t ir_addr, ir_pitch, ir_swap, ir_w, ir_h, ir_k;
    int32_t  ir_a;              /* ... its blend factor (-1: none)            */
    /* settings */
    uint32_t fill, transp, w, h;
    uint32_t dst, dpitch;
    bool     xy;
    int32_t  x, y;
    uint32_t src, spitch, sfmt;
    uint32_t tex, step, texbox;
    uint32_t uv, rstep;         /* SET_UV, SET_STEP_ROW operands              */
    int32_t  clip[4];           /* x0, y0, x1, y1 inclusive                   */
    uint32_t alpha;             /* SET_ALPHA word [8:0]                       */
    uint32_t grad, grad_rgb;    /* SET_GRAD word, SET_GRAD_RGB operand        */
    uint32_t remap_tab;         /* SET_AUX REMAP_TABLE word address           */
    uint32_t a8;                /* SET_AUX ALPHA_PLANE byte address           */
    uint32_t filt;              /* SET_AUX TEX_FILTER [1:0]                   */
    uint32_t pen;               /* line pen {y, x} 12.4                       */
    uint32_t pat, len, phase;   /* line pattern, LEN, phase                   */
    unsigned lines, line_px;    /* lines decoded, pixels they wrote           */
    draw_t   d[LOG_MAX];
    unsigned nd;
    bool     log_full, overflow;
    unsigned words;             /* words pushed in total                      */
    unsigned dropped;           /* data words dropped by the decoder          */
    unsigned en_pulses;         /* GPU_EN 1 -> 0 writes                       */
    unsigned aborts;            /* GPU_CTRL writes with ABORT or CLEAR_ERR    */
    unsigned execs;             /* EXECs decoded                              */
    unsigned imm_execs;         /* ... of them with the immediate source      */
    unsigned exp_execs;         /* ... EXEC_EXPAND (drawn as pixels)           */
    unsigned blend_execs;       /* ... FILL / SPAN / COPY blended              */
    unsigned grad_execs;        /* ... FILL / SPAN with a gradient            */
    unsigned copy_execs;        /* ... COPY from the VRAM                      */
    unsigned a8_execs;          /* ... COPY / textures with SRC_FMT 5 drawn    */
    unsigned tex_execs;         /* ... textures drawn (16 bpp)                 */
    unsigned bil_execs;         /* ... of them bilinear                        */
    unsigned tex_px, tap_rd;    /* texture pixels written, taps read           */
    unsigned stop_exec;         /* stop (cause 5) at this EXEC (1, 2, ...; 0: never) */
    /* an "interrupt" before word irq_at is pushed */
    int      irq_at;
    void   (*irq)(void);
    /* hot-plug: called at each read of DPI.STATUS / DPI.IRQ_FLAG */
    void   (*hp_rd)(void);
    /* the fence status: called at each read of GPU.FENCE / GPU.STAT through
     * BLNS_REG_RD (blns_gpu_fence_status), after gpu_rds counts it */
    void   (*gpu_rd)(void);
    unsigned gpu_rds;
    /* DBI parameter FIFO (16 entries) and command slot, drained by one
     * parameter at each DIF_STATUS read while a command needs one */
    uint32_t dq[16], dq_n;
    bool     dcmd;              /* a command is queued or in progress         */
    uint32_t dcmd_left;         /* its parameters not yet sent                */
    uint32_t dsent[256], dsent_n; /* the parameters sent to the panel, in order */
    unsigned dovfl;             /* DIF_PARAM writes dropped (FIFO full)       */
} m;

static void line_state_reset(void)
{
    m.clip[0] = m.clip[1] = -2048;
    m.clip[2] = m.clip[3] = 2047;
    m.alpha = m.remap_tab = m.pen = m.a8 = m.filt = 0u;
    m.grad = m.grad_rgb = 0u;
    m.pat   = ~0u;
    m.len   = 32u;
    m.phase = 0u;
}

static void model_reset(void)
{
    const unsigned depth = m.depth;
    const bool     en    = m.gpu_en;
    memset(&m, 0, sizeof m);
    m.depth  = depth ? depth : 1u << MODEL_FIFO_AW;
    m.thresh = m.depth / 2u;
    m.gpu_en = en;
    m.w = m.h = 1u;
    m.irq_at = -1;
    line_state_reset();
}

static void model_stat(void)
{
    const unsigned free = m.mpend ? 0u : m.depth - m.qn;          /* a pending marker holds the room */
    RW(regs.GPU.STAT) = (free << BLNS_GPU_STAT_FREE_Pos) | (m.qn << BLNS_GPU_STAT_USED_Pos) |
                        (m.qn ? 0u : BLNS_GPU_STAT_EMPTY_Msk) |
                        ((m.qn >= m.depth || m.mpend) ? BLNS_GPU_STAT_FULL_Msk : 0u) |
                        ((m.qn || m.err) ? BLNS_GPU_STAT_BUSY_Msk : 0u) |
                        (m.err ? BLNS_GPU_STAT_ERR_Msk : 0u) |
                        (regs.GPU.STAT & (BLNS_GPU_STAT_ERR_CAUSE_Msk | BLNS_GPU_STAT_ERR_OPCODE_Msk));
}

static bool needs_operand(uint32_t w)
{
    const uint32_t op = w >> 28, sub = (w >> 24) & 0xFu;
    switch (op) {
    case 0x1: case 0x2: case 0x4: case 0x5: case 0x7:
        return true;
    case 0x8:                   /* LINE: an operand in every build */
        return (w & BLNS_GPU_EXEC_LINE_Msk) != 0u;
    case 0x6:
        return sub == 1u || sub == 2u || sub == 4u || sub == 5u || (sub >= 9u && sub <= 0xDu);
    default:
        return false;
    }
}

static int32_t delta_of(uint32_t w)
{
    int32_t d = (int32_t) ((w >> 14) & 0x3FFFu);
    return (d & 0x2000) ? d - 0x4000 : d;
}

static void gpu_error(uint32_t cause, uint32_t w)
{
    m.err = true;
    RW(regs.GPU.ERR)  = w;
    RW(regs.GPU.STAT) = (regs.GPU.STAT & ~(BLNS_GPU_STAT_ERR_CAUSE_Msk | BLNS_GPU_STAT_ERR_OPCODE_Msk)) |
                        (cause << BLNS_GPU_STAT_ERR_CAUSE_Pos) | ((w >> 28) << BLNS_GPU_STAT_ERR_OPCODE_Pos);
    regs.IRQ_FLAG |= BLNS_IRQ_GPU_ERR_Msk;
    if (cause == BLNS_GPU_ERR_BOUNDS)
        m.phase = 0u;           /* a cause-5 fault resets the line pattern phase */
}

/* The features of the build (BLNS_CFG2) */
static bool built(uint32_t msk)
{
    return (regs.CFG2 & msk) == msk;
}

static bool line_built(void)
{
    return built(BLNS_CFG2_LINE_Msk | BLNS_CFG2_XY_Msk);
}

static bool bil_built(void)
{
    return built(BLNS_CFG2_BILINEAR_Msk | BLNS_CFG2_XY_Msk);
}

/* VRAM_AW: the word address width of the model's VRAM */
static unsigned model_aw(void)
{
    unsigned aw = 0;
    while ((1u << aw) < MODEL_WORDS)
        aw++;
    return aw;
}

/* A command word with an operand refused at the decoder (before the operand
 * is taken): 0, or its cause (precedence 2 over 1) */
static uint32_t refused(uint32_t w)
{
    const uint32_t op = w >> 28;
    if (op == 0x8 && (w & BLNS_GPU_EXEC_LINE_Msk)) {
        const bool     tri   = (w & BLNS_GPU_EXEC_TRI_Msk) != 0u;
        const uint32_t remap = (w & BLNS_GPU_EXEC_REMAP_Msk) >> BLNS_GPU_EXEC_REMAP_Pos;
        if (!line_built() || (tri && !built(BLNS_CFG2_TRI_Msk | BLNS_CFG2_XY_Msk)) ||
            ((w & BLNS_GPU_LINE_AA_Msk) && !built(BLNS_CFG2_BLEND_Msk)) ||
            ((remap == 1u || remap == 2u) && !built(BLNS_CFG2_REMAP_Msk)))
            return BLNS_GPU_ERR_ABSENT;
        return (tri || remap == 3u) ? BLNS_GPU_ERR_INVALID : 0u;
    }
    if (op == 0x6 && ((w >> 24) & 0xFu) == 0xDu) {     /* SET_AUX */
        switch ((w & BLNS_GPU_AUX_SEL_Msk) >> BLNS_GPU_AUX_SEL_Pos) {
        case 0: return built(BLNS_CFG2_REMAP_Msk) ? 0u : BLNS_GPU_ERR_ABSENT;
        case 1: return built(BLNS_CFG2_MPLANE_Msk) ? 0u : BLNS_GPU_ERR_ABSENT;
        case 2: case 3: return line_built() ? 0u : BLNS_GPU_ERR_ABSENT;
        case 4: return (built(BLNS_CFG2_BLEND_Msk) && (w & 0xFFFFu) == 0u) ? 0u : BLNS_GPU_ERR_ABSENT;
        case 5: return (bil_built() && (!(w & BLNS_GPU_AUX_TBORDER_Msk) || built(BLNS_CFG2_BLEND_Msk)))
                       ? 0u : BLNS_GPU_ERR_ABSENT;
        default: return BLNS_GPU_ERR_INVALID;
        }
    }
    if (op == 0x1) {                                    /* SET_SRC: SRC_FMT 5 absent, 6-15 reserved */
        const uint32_t f = (w & BLNS_GPU_SRC_FMT_Msk) >> BLNS_GPU_SRC_FMT_Pos;
        return (f > 5u) ? BLNS_GPU_ERR_FORMAT : (f == 5u && !built(BLNS_CFG2_BLEND_Msk)) ? BLNS_GPU_ERR_ABSENT : 0u;
    }
    return 0u;
}

/* Pixels: the walk of a rectangle (the first pixel visited, the run along x,
 * or along y with CL, a swap reversing its axis) */
static unsigned model_bpp(void)
{
    const uint32_t mode = regs.CTRL & BLNS_CTRL_GFX_MODE_Msk;
    return (mode & 4u) ? 16u : 1u << mode;
}

static int32_t walk_px(uint32_t base, uint32_t pitch, uint32_t swap, uint32_t i, uint32_t r)
{
    const int32_t run  = (swap & BLNS_SWAP_CL) ? ((swap & BLNS_SWAP_Y) ? -(int32_t) pitch : (int32_t) pitch)
                                               : ((swap & BLNS_SWAP_X) ? -1 : 1);
    const int32_t line = (swap & BLNS_SWAP_CL) ? ((swap & BLNS_SWAP_X) ? -1 : 1)
                                               : ((swap & BLNS_SWAP_Y) ? -(int32_t) pitch : (int32_t) pitch);
    return (int32_t) base + (int32_t) i * run + (int32_t) r * line;
}

static uint32_t px_get(int32_t pa)
{
    return model_bpp() == 16u ? ((uint16_t *) vram)[pa] : ((uint8_t *) vram)[pa];
}

static void px_set(int32_t pa, uint32_t v)
{
    if (model_bpp() == 16u)
        ((uint16_t *) vram)[pa] = (uint16_t) v;
    else
        ((uint8_t *) vram)[pa] = (uint8_t) v;
}

/* The rectangle reaches VRAM_WORDS (or starts below 0): cause 5 */
static bool walk_ok(uint32_t base, uint32_t pitch, uint32_t swap, uint32_t w, uint32_t h)
{
    const int32_t lim = (int32_t) (MODEL_WORDS * (32u / model_bpp()));
    const int32_t c[4] = { walk_px(base, pitch, swap, 0u, 0u), walk_px(base, pitch, swap, w - 1u, 0u),
                           walk_px(base, pitch, swap, 0u, h - 1u), walk_px(base, pitch, swap, w - 1u, h - 1u) };
    for (unsigned i = 0; i < 4u; i++)
        if (c[i] < 0 || c[i] >= lim)
            return false;
    return true;
}

static void exec(uint32_t w);
static void line(uint32_t c, uint32_t end);
static void a8_copy(uint32_t w, uint32_t addr, uint32_t pitch, uint32_t swap);
static void tex_draw(uint32_t w, uint32_t addr, uint32_t pitch);
static int32_t sx16(uint32_t v);

/* The blend rule (gpu_blend565; SET_ALPHA MIX5): per RGB565 field
 * d + ((s - d) a + r) >> 8 with the factor a 0 .. 256 and r = 128, or with
 * MIX5 a = 8 m, m = (alpha + 4) >> 3, and r = 0 */
static int64_t fdiv(int64_t a, int64_t b);
static int32_t blend_ch(int32_t d, int32_t s, int32_t a);
static bool mix5(void)
{
    return (m.alpha & BLNS_GPU_ALPHA_MIX5_Msk) && built(BLNS_CFG2_BLEND_Msk);
}

/* x o A (a coverage, an A8 byte, a tap's alpha with SET_ALPHA EN) */
static int32_t comb(int32_t x, int32_t A)
{
    return mix5() ? (x * A) >> 8 : (((x * A + 127) * 257 + 256) >> 16);
}

/* The factor of an alpha 0 .. 255 (0: not written) */
static int32_t fac(int32_t alpha)
{
    return mix5() ? 8 * ((alpha + 4) >> 3) : (alpha >= 255 ? 256 : alpha);
}

static uint32_t blend565(uint32_t s, uint32_t d, int32_t a)
{
    if (a >= 256)
        return s & 0xFFFFu;
    return ((uint32_t) blend_ch((int32_t) (d >> 11), (int32_t) ((s >> 11) & 0x1Fu), a) << 11) |
           ((uint32_t) blend_ch((int32_t) ((d >> 5) & 0x3Fu), (int32_t) ((s >> 5) & 0x3Fu), a) << 5) |
           (uint32_t) blend_ch((int32_t) (d & 0x1Fu), (int32_t) (s & 0x1Fu), a);
}

/* SET_ALPHA as the blend factor of a FILL / SPAN / COPY pixel: -1 no blending */
static int32_t blend_a(void)
{
    if (model_bpp() != 16u || !(m.alpha & BLNS_GPU_ALPHA_EN_Msk) || !built(BLNS_CFG2_BLEND_Msk))
        return -1;
    return fac((int32_t) (m.alpha & 0xFFu));
}

/* Write S at pa, blended by a (-1: plain; 0: nothing written) */
static void px_put(int32_t pa, uint32_t s, int32_t a)
{
    if (a < 0)
        px_set(pa, s);
    else if (a > 0)
        px_set(pa, blend565(s, px_get(pa), a));
}

/* The gradient value of walk position k of a w-wide rectangle (gpu_x_gval) */
static int32_t grad_ch(int32_t base, int32_t q, int32_t d, int32_t max)
{
    int32_t acc = q * d;
    if (acc > 8191)
        acc = 8191;
    if (acc < -8192)
        acc = -8192;
    const int32_t v = base + ((acc >= 0) ? acc / 64 : -((-acc + 63) / 64));
    return v < 0 ? 0 : v > max ? max : v;
}

static int32_t sx10(uint32_t v)
{
    const int32_t x = (int32_t) (v & 0x3FFu);
    return (x & 0x200) ? x - 0x400 : x;
}

static uint32_t grad_val(uint32_t k, uint32_t w)
{
    if (!(m.grad & BLNS_GPU_GRAD_EN_Msk) || !built(BLNS_CFG2_GRAD_Msk))
        return m.fill;
    const uint32_t n   = (m.grad & BLNS_GPU_GRAD_N_Msk) ? (m.grad & BLNS_GPU_GRAD_N_Msk) : 1u;
    const uint32_t idx = (m.grad & BLNS_GPU_GRAD_AXIS_Msk) ? k % w : k / w;
    const int32_t  q   = (int32_t) (idx / n);
    if ((m.grad & BLNS_GPU_GRAD_RGB_Msk) && model_bpp() == 16u)
        return ((uint32_t) grad_ch((int32_t) ((m.fill >> 11) & 0x1Fu), q, sx10(m.grad_rgb >> 20), 31) << 11) |
               ((uint32_t) grad_ch((int32_t) ((m.fill >> 5) & 0x3Fu), q, sx10(m.grad_rgb >> 10), 63) << 5) |
               (uint32_t) grad_ch((int32_t) (m.fill & 0x1Fu), q, sx10(m.grad_rgb), 31);
    int32_t step = (int32_t) ((m.grad & BLNS_GPU_GRAD_STEP_Msk) >> BLNS_GPU_GRAD_STEP_Pos);
    if (step & 8)
        step -= 16;
    return m.fill + (uint32_t) (q * step);
}

/* A source value of 1, 2, 4 or 8 bpp at source pixel address pa */
static uint32_t src_val(uint32_t pa, unsigned bpp)
{
    const uint32_t wd = pa / (32u / bpp), off = (pa % (32u / bpp)) * bpp;
    return wd < MODEL_WORDS ? (vram[wd] >> off) & ((1u << bpp) - 1u) : 0u;
}

static int32_t sx12(uint32_t v)
{
    const int32_t x = (int32_t) (v & 0xFFFu);
    return (x & 0x800) ? x - 0x1000 : x;
}

static void feed(uint32_t w)
{
    if (m.pend) {
        const uint32_t c = m.pend;
        m.pend = 0u;
        switch (c >> 28) {
        case 0x1:
            m.spitch = c & 0xFFFFu;
            m.sfmt   = (c >> 16) & 0xFu;
            if (c & BLNS_GPU_SRC_IMM_Msk) {     /* armed: N, the source base kept */
                m.imm_arm = true;
                m.imm_n   = w & 0xFFFFFFu;
            } else {
                m.imm_arm = false;
                m.src     = w;
            }
            break;
        case 0x2: m.dst = w; m.dpitch = c & 0xFFFFu; m.xy = (c >> 16) & 1u; m.x = m.y = 0; break;
        case 0x4: m.fill = w; break;
        case 0x5: m.transp = w; break;
        case 0x7:
            for (uint32_t i = 0; i < (c & 0xFFFFFFu) && !m.err; i++)
                feed(vram[w + i]);
            break;
        case 0x6:
            if (((c >> 24) & 0xFu) == 1u)
                m.uv = w;
            if (((c >> 24) & 0xFu) == 2u)
                m.step = w;
            if (((c >> 24) & 0xFu) == 5u)
                m.rstep = w;
            if (((c >> 24) & 0xFu) == 0xCu)
                m.grad_rgb = w;
            if (((c >> 24) & 0xFu) == 4u) {         /* SET_CLIP x1, y1 */
                m.clip[2] = sx12(w);
                m.clip[3] = sx12(w >> 12);
            }
            if (((c >> 24) & 0xFu) == 0xDu)
                switch ((c & BLNS_GPU_AUX_SEL_Msk) >> BLNS_GPU_AUX_SEL_Pos) {
                case 0: m.remap_tab = w; break;
                case 2: m.pen = w; break;
                case 4: m.a8 = w & ((1u << (model_aw() + 2u)) - 1u); break;
                case 3: m.pat = w; break;
                default: break;
                }
            break;
        case 0x8:
            line(c, w);
            break;
        }
        return;
    }
    if (needs_operand(w)) {
        const uint32_t cause = refused(w);
        if (cause) {                /* the operand is not taken */
            gpu_error(cause, w);
            return;
        }
        if (w >> 28 == 0x6 && ((w >> 24) & 0xFu) == 4u) {   /* SET_CLIP x0, y0: the word */
            m.clip[0] = sx12(w);
            m.clip[1] = sx12(w >> 12);
        }
        if (w >> 28 == 0x6 && ((w >> 24) & 0xFu) == 0xDu &&
            (w & BLNS_GPU_AUX_SEL_Msk) == BLNS_GPU_AUX_LINE_PATTERN) {
            m.len   = ((w & BLNS_GPU_AUX_LEN_Msk) >> BLNS_GPU_AUX_LEN_Pos) + 1u;   /* LEN, the phase: the word */
            m.phase = 0u;
        }
        if (w >> 28 == 0x6 && ((w >> 24) & 0xFu) == 0xDu && (w & BLNS_GPU_AUX_SEL_Msk) == BLNS_GPU_AUX_TEX_FILTER)
            m.filt = w & (BLNS_GPU_AUX_BILINEAR_Msk | BLNS_GPU_AUX_TBORDER_Msk);    /* the filter: the word */
        m.pend = w;
        return;
    }
    exec(w);
}

/*---------------------------------------------------------------------------
 * RGB565A8 copies and textures (16 bpp)
 *---------------------------------------------------------------------------*/
/* The alpha byte of source pixel pa (the A8 plane of SET_AUX ALPHA_PLANE:
 * pointer + (pa - SET_SRC base), modulo 2^(VRAM_AW + 5)); false: its word
 * is at or past VRAM_WORDS */
static bool a8_byte(uint32_t pa, uint32_t *b)
{
    const uint32_t a = (m.a8 + pa - m.src) & ((1u << (model_aw() + 5u)) - 1u);
    if ((a >> 2) >= MODEL_WORDS)
        return false;
    *b = ((const uint8_t *) vram)[a];
    return true;
}

/* A 16-bpp pixel of the VRAM at pixel address pa (false: past it) */
static bool px16(uint32_t pa, uint32_t *v)
{
    pa &= (1u << (model_aw() + 5u)) - 1u;
    if ((pa >> 1) >= MODEL_WORDS)
        return false;
    *v = ((const uint16_t *) vram)[pa];
    return true;
}

/* An op-S COPY / COPY_TRANSP of an RGB565A8 source (address mode): the key on
 * the raw colour (its alpha byte read first), then the blend with the byte
 * (x A with SET_ALPHA EN) */
static void a8_copy(uint32_t w, uint32_t addr, uint32_t pitch, uint32_t swap)
{
    const uint32_t ssw = (w >> 8) & 7u, sp = m.spitch ? m.spitch : (regs.DISP_SIZE & 0xFFFFu);
    const bool     en  = (m.alpha & BLNS_GPU_ALPHA_EN_Msk) != 0u;
    const int32_t  A   = (int32_t) (m.alpha & 0xFFu);
    for (uint32_t r = 0; r < m.h; r++)
        for (uint32_t i = 0; i < m.w; i++) {
            const uint32_t spa = (uint32_t) walk_px(m.src, sp, ssw, i, r);
            uint32_t       s, b;
            if (!px16(spa, &s) || !a8_byte(spa, &b)) {
                gpu_error(BLNS_GPU_ERR_BOUNDS, w);      /* the pixels before it drawn */
                return;
            }
            if ((w >> 28) == 0xAu && s == (m.transp & 0xFFFFu))
                continue;                               /* keyed */
            px_put(walk_px(addr, pitch, swap, i, r), s, fac(en ? comb((int32_t) b, A) : (int32_t) b));
        }
}

static int32_t s21(uint32_t v)
{
    v &= 0x1FFFFFu;
    return (v & 0x100000u) ? (int32_t) v - 0x200000 : (int32_t) v;
}

/* EXEC_TEXSPAN / EXEC_TEXRECT at 16 bpp, remap off (w: the EXEC word; addr,
 * pitch: the destination of address mode): pixel (c, r) of the walk at
 * (u, v) = (u0 + r du' + c du, v0 + r dv' + c dv) in 10.11, nearest or
 * bilinear (SET_AUX TEX_FILTER) */
static void tex_draw(uint32_t w, uint32_t addr, uint32_t pitch)
{
    const uint32_t t     = m.tex;
    const unsigned lw    = ((t & 0xFu) > 10u) ? 10u : (t & 0xFu), lh = (((t >> 4) & 0xFu) > 10u) ? 10u : ((t >> 4) & 0xFu);
    const bool     ten   = (t & BLNS_GPU_TEX_TRANSP_Msk) != 0u;
    const bool     fpit  = (t & BLNS_GPU_TEX_FREE_PITCH_Msk) != 0u;
    const bool     bound = (t & BLNS_GPU_TEX_BOUND_Msk) != 0u;
    const uint32_t sw    = (t >> BLNS_GPU_TEX_SWAP_Pos) & 7u;
    const uint32_t shade = (t & BLNS_GPU_TEX_SHADE_Msk) >> BLNS_GPU_TEX_SHADE_Pos;
    const uint32_t tp    = fpit ? (m.spitch ? m.spitch : (regs.DISP_SIZE & 0xFFFFu)) : (1u << lw);
    const int32_t  TW    = ((m.texbox & 0xFFFu) > 512u) ? 512 : (int32_t) (m.texbox & 0xFFFu);
    const int32_t  TH    = (((m.texbox >> 12) & 0xFFFu) > 512u) ? 512 : (int32_t) ((m.texbox >> 12) & 0xFFFu);
    const uint32_t umask = fpit ? 0x3FFu : (1u << lw) - 1u, vmask = fpit ? 0x3FFu : (1u << lh) - 1u;
    const bool     blend = built(BLNS_CFG2_BLEND_Msk);
    const bool     a8    = m.sfmt == BLNS_FMT_RGB565A8 && blend;
    const bool     en    = (m.alpha & BLNS_GPU_ALPHA_EN_Msk) && blend;
    const int32_t  A     = (int32_t) (m.alpha & 0xFFu);
    /* bilinear: built; without blending a keyed texture is sampled nearest */
    const bool     bil   = (m.filt & BLNS_GPU_AUX_BILINEAR_Msk) && bil_built() && !(ten && !blend);
    const bool     tb    = (m.filt & BLNS_GPU_AUX_TBORDER_Msk) && bound && blend;
    const int32_t  du    = sx16(m.step >> 16), dv = sx16(m.step), dur = sx16(m.rstep >> 16), dvr = sx16(m.rstep);
    const uint32_t key   = m.transp & 0xFFFFu;
    m.tex_execs++;
    m.bil_execs += bil;
    m.a8_execs  += a8;
    for (uint32_t k = 0; k < m.w * m.h; k++) {
        const uint32_t c = k % m.w, r = k / m.w;
        int32_t        dpa;
        if (m.xy) {                                 /* the walk from (x, y), clipped */
            const int32_t ii = (int32_t) c, jj = (int32_t) r;
            int32_t       px, py;
            if (!(sw & BLNS_SWAP_CL)) {
                px = m.x + ((sw & BLNS_SWAP_X) ? -ii : ii);
                py = m.y + ((sw & BLNS_SWAP_Y) ? -jj : jj);
            } else {
                py = m.y + ((sw & BLNS_SWAP_Y) ? -ii : ii);
                px = m.x + ((sw & BLNS_SWAP_X) ? -jj : jj);
            }
            if (px < m.clip[0] || px > m.clip[2] || py < m.clip[1] || py > m.clip[3])
                continue;
            dpa = (int32_t) m.dst + py * (int32_t) pitch + px;
        } else {
            dpa = walk_px(addr, pitch, sw, c, r);
        }
        const uint32_t ua = ((m.uv >> 16) << 5) + (uint32_t) ((int32_t) r * dur + (int32_t) c * du);
        const uint32_t va = ((m.uv & 0xFFFFu) << 5) + (uint32_t) ((int32_t) r * dvr + (int32_t) c * dv);
        if (bound) {                                /* the pixel skip: floor(u), floor(v) in the box */
            const int32_t fu = s21(ua) >> 11, fv = s21(va) >> 11;
            if (fu < 0 || fu >= TW || fv < 0 || fv >= TH)
                continue;
        }
        if (!bil) {
            int32_t  ui = bound ? (s21(ua) >> 11) : (int32_t) ((ua & 0x1FFFFFu) >> 11);
            int32_t  vi = bound ? (s21(va) >> 11) : (int32_t) ((va & 0x1FFFFFu) >> 11);
            if (!fpit) {                            /* a power-of-two texture wraps (in the box too) */
                ui &= (int32_t) umask;
                vi &= (int32_t) vmask;
            }
            const uint32_t spa = m.src + (uint32_t) vi * tp + (uint32_t) ui;
            uint32_t       tx, b = 255u;
            if (!px16(spa, &tx) || (a8 && !a8_byte(spa, &b))) {
                gpu_error(BLNS_GPU_ERR_BOUNDS, w);
                return;
            }
            if (ten && tx == key)
                continue;
            const int32_t al = a8 ? (en ? comb((int32_t) b, A) : (int32_t) b) : en ? A : -1;
            px_put(dpa, (tx + shade) & 0xFFFFu, (al < 0) ? -1 : fac(al));
            m.tex_px++;
            continue;
        }
        /* bilinear: the taps at (u - 1/2, v - 1/2) + {0, 1}^2, 5-bit weights */
        const uint32_t up = ua - 1024u, vp = va - 1024u;
        const int32_t  x0 = bound ? (s21(up) >> 11) : (int32_t) ((up & 0x1FFFFFu) >> 11);
        const int32_t  y0 = bound ? (s21(vp) >> 11) : (int32_t) ((vp & 0x1FFFFFu) >> 11);
        const int32_t  fx = (int32_t) ((((up >> 3) & 0xFFu) + 4u) >> 3), fy = (int32_t) ((((vp >> 3) & 0xFFu) + 4u) >> 3);
        const int32_t  wx[2] = { 32 - fx, fx }, wy[2] = { 32 - fy, fy };
        int64_t        S = 0, P[3] = { 0, 0, 0 };
        for (int i = 0; i < 2; i++)
            for (int j = 0; j < 2; j++) {
                const int32_t kk = wx[j] * wy[i];
                if (kk == 0)
                    continue;                       /* weight 0: not read */
                int32_t x = x0 + j, y = y0 + i;     /* with BOUND x0 is in [-1, TW - 1]: */
                if (bound) {                        /* x0 + 1 = TW (512 too) clamps to TW - 1 */
                    if (tb && (x < 0 || x >= TW || y < 0 || y >= TH))
                        continue;                   /* transparent: not read */
                    x = (x < 0) ? 0 : (x >= TW) ? TW - 1 : x;
                    y = (y < 0) ? 0 : (y >= TH) ? TH - 1 : y;
                } else {
                    x &= 0x3FF;
                    y &= 0x3FF;
                }
                if (!fpit) {
                    x &= (int32_t) umask;
                    y &= (int32_t) vmask;
                }
                const uint32_t spa = m.src + (uint32_t) y * tp + (uint32_t) x;
                uint32_t       tx, b = 255u;
                if (!px16(spa, &tx) || (a8 && !a8_byte(spa, &b))) {
                    gpu_error(BLNS_GPU_ERR_BOUNDS, w);  /* this pixel not drawn */
                    return;
                }
                m.tap_rd++;
                int32_t a = (int32_t) b;
                if (ten && blend && tx == key)
                    a = 0;                          /* a keyed tap: transparent */
                if (en)
                    a = comb(a, A);
                const int64_t e = ((int64_t) kk * (a + (a >> 7))) >> 8;
                S    += e;
                P[0] += e * (int64_t) (tx >> 11);
                P[1] += e * (int64_t) ((tx >> 5) & 0x3Fu);
                P[2] += e * (int64_t) (tx & 0x1Fu);
            }
        static const unsigned sh[3] = { 11u, 5u, 0u }, mk[3] = { 0x1Fu, 0x3Fu, 0x1Fu };
        uint32_t out = 0u;
        if (blend) {                                /* premultiplied: d + (Pm - d a256 + r) >> 8 */
            const int64_t a256 = S >> 2;
            if (a256 == 0)
                continue;                           /* not written */
            const uint32_t d = px_get(dpa);
            for (int f = 0; f < 3; f++) {
                const int64_t pm = mix5() ? P[f] >> 2 : (P[f] + 2) >> 2;
                const int64_t dc = (int64_t) ((d >> sh[f]) & mk[f]);
                out |= ((uint32_t) (dc + fdiv(pm - dc * a256 + (mix5() ? 0 : 128), 256)) & mk[f]) << sh[f];
            }
        } else {                                    /* every tap opaque: the straight colour */
            for (int f = 0; f < 3; f++)
                out |= ((uint32_t) ((P[f] + 512) >> 10) & mk[f]) << sh[f];
        }
        px_set(dpa, out);
        m.tex_px++;
    }
}

static void exec(uint32_t w)
{
    const uint32_t op = w >> 28;
    if (op == 0x0) {
        gpu_error(1u, w);
        return;
    }
    if (op == 0x3) {                                    /* 0 is stored as 1 */
        m.w = (w & 0x3FFFu) ? (w & 0x3FFFu) : 1u;
        m.h = ((w >> 14) & 0x3FFFu) ? ((w >> 14) & 0x3FFFu) : 1u;
        return;
    }
    if (op == 0x6) {
        const uint32_t sub = (w >> 24) & 0xFu;
        if (sub == 0u)
            m.tex = w;
        else if (sub == 6u)
            m.texbox = w & 0xFFFFFFu;
        else if (sub == 3u) {
            int32_t x = (int32_t) (w & 0xFFFu), y = (int32_t) ((w >> 12) & 0xFFFu);
            m.x = (x & 0x800) ? x - 0x1000 : x;
            m.y = (y & 0x800) ? y - 0x1000 : y;
        } else if (sub == 8u) {
            m.alpha = w & 0x3FFu;
        } else if (sub == 7u) {
            m.grad = w & 0x7FFFFu;
        } else if (sub == 0xFu && (w & 0xFF0000u) == BLNS_GPU_EXT2_RESET_STATE) {
            line_state_reset();
            m.fill = m.transp = m.src = m.spitch = m.sfmt = m.tex = m.step = m.texbox = m.uv = m.rstep = 0u;
            m.w = m.h = 1u;
            m.dst = m.dpitch = 0u;
            m.xy = false;
            m.x = m.y = 0;
        }
        return;
    }
    if (op == 0xF) {
        RW(regs.GPU.FENCE) = (w & BLNS_GPU_FENCE_AUTO_Msk) ? ((regs.GPU.FENCE + 1u) & 0xFFFFFFu)
                                                            : (w & 0xFFFFFFu);
        return;
    }
    if (op < 0x8)
        return;
    /* EXEC */
    if (op == 0xC && (w & BLNS_GPU_EXP_MASK_Msk) && !built(BLNS_CFG2_BLEND_Msk)) {
        gpu_error(BLNS_GPU_ERR_ABSENT, w);
        return;
    }
    /* RGB565A8 (SRC_FMT 5, a BLEND build): not EXPAND's (cause 3); a copy
     * takes neither the mask plane nor the immediate source (cause 1) */
    const bool a8 = m.sfmt == BLNS_FMT_RGB565A8 && built(BLNS_CFG2_BLEND_Msk);
    if (op == 0xC && a8) {
        gpu_error(BLNS_GPU_ERR_FORMAT, w);
        return;
    }
    if ((op == 0x9 || op == 0xA) && a8 && ((w & BLNS_GPU_EXEC_MPLANE_Msk) || m.imm_arm)) {
        gpu_error(BLNS_GPU_ERR_INVALID, w);
        return;
    }
    if (++m.execs == m.stop_exec) {
        gpu_error(BLNS_GPU_ERR_BOUNDS, w);          /* injected: nothing of it is drawn */
        return;
    }
    const bool has_delta = (op == 0xB || op == 0xC || op == 0xD || op == 0xE);
    const int32_t d = has_delta ? delta_of(w) : 0;
    if (op == 0xB || op == 0xD) {
        m.w = w & 0x3FFFu;
        m.h = 1u;
    }
    uint32_t addr;
    if (m.xy) {
        m.x += d;
        addr = m.dst + (uint32_t) (m.y * (int32_t) m.dpitch + m.x);
    } else {
        m.dst += (uint32_t) d;
        addr = m.dst;
    }
    const uint32_t pitch = m.dpitch ? m.dpitch : (regs.DISP_SIZE & 0xFFFFu);
    const uint32_t swap  = (op == 0xB || (w & BLNS_GPU_EXEC_TRI_Msk)) ? 0u
                         : (w & BLNS_GPU_EXEC_DST_SWAP_Msk) >> BLNS_GPU_EXEC_DST_SWAP_Pos;
    const bool     imm   = m.imm_arm && (op == 0x9 || op == 0xA || op == 0xC);
    if (imm) {
        m.imm_arm = false;
        m.imm_execs++;
    }
    if (!(w & BLNS_GPU_EXEC_TRI_Msk) && !walk_ok(addr, pitch, swap, m.w, m.h)) {
        gpu_error(BLNS_GPU_ERR_BOUNDS, w);          /* nothing of it is drawn here */
        return;
    }
    if (m.nd < LOG_MAX) {
        m.d[m.nd++] = (draw_t) { op, addr, m.dpitch, m.w, m.h, m.fill, m.transp, m.src, m.spitch,
                                 m.sfmt, m.tex, m.step, m.texbox, imm ? m.imm_n : 0u, w, 0u, 0u };
    } else {
        m.log_full = true;
    }
    /* pixels: op S fills and spans (a gradient, blending), op S copies
     * from VRAM (address mode; blending), op S expansions from VRAM
     * (address mode; MASK) */
    const int32_t ba = blend_a();
    m.blend_execs += ba >= 0 && (op == 0x8 || op == 0x9 || op == 0xB);
    m.grad_execs  += (m.grad & BLNS_GPU_GRAD_EN_Msk) && (op == 0x8 || op == 0xB);
    m.exp_execs   += op == 0xC;
    m.copy_execs  += op == 0x9 && !imm;
    if ((op == 0x8 || op == 0xB) && (w & 0xFu) == 0u && !(w & (BLNS_GPU_EXEC_TRI_Msk | BLNS_GPU_EXEC_REMAP_Msk)))
        for (uint32_t r = 0; r < m.h; r++)
            for (uint32_t i = 0; i < m.w; i++)
                px_put(walk_px(addr, pitch, swap, i, r), grad_val(r * m.w + i, m.w), ba);
    const bool a8px = a8 && model_bpp() == 16u;      /* below 16 bpp SRC_FMT 5 acts as 0 */
    if (op == 0x9 && (w & 0xFu) == 0u && !imm && !m.xy && !a8px) {
        const uint32_t ssw = (w >> 8) & 7u, sp = m.spitch ? m.spitch : (regs.DISP_SIZE & 0xFFFFu);
        for (uint32_t r = 0; r < m.h; r++)
            for (uint32_t i = 0; i < m.w; i++)
                px_put(walk_px(addr, pitch, swap, i, r), px_get(walk_px(m.src, sp, ssw, i, r)), ba);
    }
    if ((op == 0x9 || op == 0xA) && (w & 0xFu) == 0u && !imm && !m.xy && a8px) {
        m.a8_execs++;
        a8_copy(w, addr, pitch, swap);
    }
    if ((op == 0xD || (op == 0xE && !(w & BLNS_GPU_EXEC_TRI_Msk))) && model_bpp() == 16u &&
        !(m.tex & BLNS_GPU_TEX_REMAP_Msk))
        tex_draw(w, addr, pitch);
    if (op == 0xC && (((w >> 8) & 0xFu) == 0u) && !imm && !m.xy && m.sfmt >= 1u && m.sfmt <= 4u) {
        const unsigned sbpp = 1u << (m.sfmt - 1u);
        const uint32_t sp   = m.spitch ? m.spitch : m.w;
        const bool     msk  = (w & BLNS_GPU_EXP_MASK_Msk) && model_bpp() == 16u && built(BLNS_CFG2_BLEND_Msk);
        const bool     en   = (m.alpha & BLNS_GPU_ALPHA_EN_Msk) != 0u;
        const int32_t  A    = (int32_t) (m.alpha & 0xFFu);
        for (uint32_t r = 0; r < m.h; r++)
            for (uint32_t i = 0; i < m.w; i++) {
                const uint32_t v  = src_val(m.src + r * sp + i, sbpp);
                const int32_t  pa = walk_px(addr, pitch, swap, i, r);
                if (msk) {                          /* gpu_a_mask: the coverage alpha */
                    int32_t am = (sbpp == 1u) ? (v ? 255 : 0) : (sbpp == 2u) ? (int32_t) v * 85
                               : (sbpp == 4u) ? (int32_t) v * 17 : (int32_t) v;
                    if (en)
                        am = comb(am, A);
                    px_put(pa, m.fill, fac(am));
                } else if (v || (w & BLNS_GPU_EXP_OPAQUE_Msk)) {
                    px_put(pa, v ? m.fill + v - 1u : m.transp, ba);
                }
            }
    }
    if (op == 0x9 && (w & 0xFu) == 0u && imm && !m.xy && model_bpp() >= 8u &&
        !(w & (BLNS_GPU_EXEC_REMAP_Msk | BLNS_GPU_EXEC_MPLANE_Msk))) {
        m.ir      = true;                       /* its pixels: the data words that follow */
        m.ir_addr = addr;
        m.ir_pitch = pitch;
        m.ir_swap = swap;
        m.ir_w    = m.w;
        m.ir_h    = m.h;
        m.ir_k    = 0u;
        m.ir_a    = blend_a();
    }
}

/*---------------------------------------------------------------------------
 * Lines (EXEC_FILL LINE), from the closed forms of the specification
 *---------------------------------------------------------------------------*/
static int64_t fdiv(int64_t a, int64_t b)          /* floor(a / b), b > 0 */
{
    const int64_t q = a / b;
    return (a % b != 0 && a < 0) ? q - 1 : q;
}

static int32_t sx16(uint32_t v)
{
    const int32_t x = (int32_t) (v & 0xFFFFu);
    return (x & 0x8000) ? x - 0x10000 : x;
}

static int32_t blend_ch(int32_t d, int32_t s, int32_t a)
{
    return d + (int32_t) fdiv((int64_t) (s - d) * a + (mix5() ? 0 : 128), 256);
}

/* One pixel of a line in colour S (cov: the AA coverage, -1 solid); false:
 * stopped (cause 5) */
static bool line_pixel(uint32_t c, int32_t x, int32_t y, uint32_t S, int cov)
{
    if (x < m.clip[0] || x > m.clip[2] || y < m.clip[1] || y > m.clip[3])
        return true;
    const unsigned bpp   = model_bpp();
    const uint32_t ones  = (bpp == 16u) ? 0xFFFFu : 0xFFu;
    const uint32_t rop   = c & 0xFu;
    const uint32_t remap = (c & BLNS_GPU_EXEC_REMAP_Msk) >> BLNS_GPU_EXEC_REMAP_Pos;
    S &= ones;
    if (rop >= 13u && S == (m.transp & ones))
        return true;                                /* ops 13-15: S transparent */
    const uint32_t k = (rop == 13u) ? 0u : (rop == 14u) ? ones : (m.fill & ones);
    const bool     en = (m.alpha & BLNS_GPU_ALPHA_EN_Msk) != 0u;
    const bool     blend = bpp == 16u && (en || cov >= 0) && built(BLNS_CFG2_BLEND_Msk);
    int32_t        a = 256;
    if (blend) {
        const int32_t A = (int32_t) (m.alpha & 0xFFu);
        a = fac((cov < 0) ? A : en ? comb(cov, A) : cov);
        if (a == 0)
            return true;                            /* no read, no write */
    }
    const int64_t pitch = m.dpitch ? m.dpitch : (regs.DISP_SIZE & 0xFFFFu);
    const int64_t pa    = (int64_t) m.dst + (int64_t) y * pitch + x;
    if (pa < 0 || pa >= (int64_t) (MODEL_WORDS * (32u / bpp))) {
        gpu_error(BLNS_GPU_ERR_BOUNDS, c);
        return false;
    }
    const uint32_t D = px_get((int32_t) pa);
    uint32_t       v;
    if (blend) {
        const uint32_t s = (rop >= 13u) ? k : S;
        v = ((uint32_t) blend_ch((int32_t) (D >> 11), (int32_t) (s >> 11), a) << 11) |
            ((uint32_t) blend_ch((int32_t) ((D >> 5) & 0x3Fu), (int32_t) ((s >> 5) & 0x3Fu), a) << 5) |
            (uint32_t) blend_ch((int32_t) (D & 0x1Fu), (int32_t) (s & 0x1Fu), a);
    } else {
        uint32_t s = S;
        if (bpp < 16u && remap == 1u)
            s = ((const uint8_t *) vram)[m.remap_tab * 4u + S] & ones;
        else if (bpp < 16u && remap == 2u)
            s = ((const uint8_t *) vram)[m.remap_tab * 4u + D] & ones;
        switch (rop) {
        case 0:  v = s; break;
        case 1:  v = ~s; break;
        case 2:  v = ~D; break;
        case 3:  v = s & D; break;
        case 4:  v = s | D; break;
        case 5:  v = s ^ D; break;
        case 6:  v = ~(s & D); break;
        case 7:  v = ~(s | D); break;
        case 8:  v = ~(s ^ D); break;
        case 9:  v = ~s & D; break;
        case 10: v = s & ~D; break;
        case 11: v = ~s | D; break;
        case 12: v = s | ~D; break;
        default: v = k; break;
        }
    }
    px_set((int32_t) pa, v & ones);
    m.line_px++;
    return true;
}

/* The line from the pen to 'end' (c: the EXEC word) */
static void line(uint32_t c, uint32_t end)
{
    const uint32_t p0 = m.pen;
    m.pen = end;                                    /* every operand taken moves the pen */
    m.lines++;
    if (c & BLNS_GPU_LINE_PH_RST_Msk)
        m.phase = 0u;
    if (++m.execs == m.stop_exec) {
        gpu_error(BLNS_GPU_ERR_BOUNDS, c);          /* injected: nothing of it is drawn */
        return;
    }
    if (m.nd < LOG_MAX) {
        m.d[m.nd++] = (draw_t) { 0x8, m.dst, m.dpitch, 0u, 0u, m.fill, m.transp, m.src, m.spitch,
                                 m.sfmt, m.tex, m.step, m.texbox, 0u, c, end, p0 };
    } else {
        m.log_full = true;
    }
    if (!m.xy)
        return;                                     /* address mode: nothing drawn, no phase */
    const int32_t  X0 = sx16(p0), Y0 = sx16(p0 >> 16), X1 = sx16(end), Y1 = sx16(end >> 16);
    const bool     nolast = (c & BLNS_GPU_LINE_NO_LAST_Msk) != 0u;
    const bool     opaque = (c & BLNS_GPU_LINE_OPAQUE_Msk) != 0u;
    const bool     aa     = (c & BLNS_GPU_LINE_AA_Msk) && model_bpp() == 16u;
    uint32_t       ph     = m.phase;
    if (!aa) {
        const int32_t a0 = (int32_t) fdiv(X0, 16), b0 = (int32_t) fdiv(Y0, 16);
        const int32_t a1 = (int32_t) fdiv(X1, 16), b1 = (int32_t) fdiv(Y1, 16);
        const bool    xm = abs(a1 - a0) >= abs(b1 - b0);
        const int32_t P0 = xm ? a0 : b0, P1 = xm ? a1 : b1, Q0 = xm ? b0 : a0, Q1 = xm ? b1 : a1;
        const int32_t D  = abs(P1 - P0), s = (P1 >= P0) ? 1 : -1;
        const int32_t n  = nolast ? D : D + 1;
        for (int32_t k = 0; k < n; k++) {
            const bool    bit = ((m.pat >> ph) & 1u) != 0u;
            ph = (ph + 1u) % m.len;
            const int32_t p = P0 + s * k;
            int32_t       q = Q0;
            if (D) {                                /* nearest, a half toward the smaller */
                const int64_t num = (int64_t) Q0 * D + (int64_t) k * (Q1 - Q0);
                q = (int32_t) -fdiv(-(2 * num - D), 2 * (int64_t) D);
            }
            if ((bit || opaque) && !line_pixel(c, xm ? p : q, xm ? q : p, bit ? m.fill : m.transp, -1))
                return;                             /* cause 5: the phase is 0 */
        }
    } else {
        const int64_t dX = (int64_t) X1 - X0, dY = (int64_t) Y1 - Y0;
        const bool    xm = llabs(dX) >= llabs(dY);
        const int64_t P0 = xm ? X0 : Y0, P1 = xm ? X1 : Y1, Q0 = xm ? Y0 : X0;
        const int64_t dP = P1 - P0, dQ = xm ? dY : dX;
        const int64_t Gs = dP ? ((dQ < 0) ? -1 : 1) * ((llabs(dQ) * 65536) / llabs(dP)) : 0;
        const int64_t i0 = fdiv(P0, 16), i1 = fdiv(P1, 16), s = (dP < 0) ? -1 : 1;
        const int64_t n  = llabs(i1 - i0) + 1 - (nolast ? 1 : 0);
        const int64_t d0 = s * (16 * i0 + 8 - P0);
        const int64_t M0 = Q0 * 4096 + fdiv(Gs * d0, 16);
        for (int64_t k = 0; k < n; k++) {
            const bool    bit = ((m.pat >> ph) & 1u) != 0u;
            ph = (ph + 1u) % m.len;
            const int64_t T   = M0 + k * Gs - 32768;
            const int64_t r   = fdiv(T, 65536);
            const int     f   = (int) ((T - r * 65536) >> 8);
            const int32_t col = (int32_t) (i0 + s * k), r0 = (int32_t) r;
            if (!bit && !opaque)
                continue;
            const uint32_t S = bit ? m.fill : m.transp;
            if (!line_pixel(c, xm ? col : r0, xm ? r0 : col, S, 255 - f) ||
                !line_pixel(c, xm ? col : r0 + 1, xm ? r0 + 1 : col, S, f))
                return;
        }
    }
    m.phase = ph;
}

/* A data word taken by the immediate copy being drawn (pixel k of the
 * rectangle at bit k * bpp % 32 of word k * bpp / 32, rows packed; 8 and
 * 16 bpp) */
static bool imm_take(uint32_t v)
{
    if (!m.ir)
        return false;
    const unsigned bpp = model_bpp();
    for (unsigned b = 0; b < 32u && m.ir; b += bpp) {
        const uint32_t k = m.ir_k++;
        px_put(walk_px(m.ir_addr, m.ir_pitch, m.ir_swap, k % m.ir_w, k / m.ir_w), (v >> b) & ((1u << bpp) - 1u),
               m.ir_a);
        m.ir = m.ir_k < m.ir_w * m.ir_h;
    }
    return true;
}

/* The push side (blns_gpu_dec.v, g_push_imm): which words are data */
void model_cmd(uint32_t w)
{
    if ((int) m.words == m.irq_at && m.irq) {
        m.irq_at = -1;
        m.irq();
    }
    m.words++;
    if (!m.gpu_en || m.qn >= m.depth || m.mpend) {
        if (m.gpu_en)
            m.overflow = true;      /* a word into a full FIFO is dropped */
        regs.IRQ_FLAG |= BLNS_IRQ_GPU_OVFL_Msk;
        return;
    }
    const uint8_t data = m.pact ? 1u : 0u;
    if (m.pact) {
        if (--m.pcnt == 0u)
            m.pact = false;
    } else if (m.owed) {
        m.owed = false;
        if (m.nsel) {
            m.nsel = false;
            m.pcnt = w & 0xFFFFFFu;
            m.arm  = true;
        }
    } else {
        const uint32_t op = w >> 28;
        m.owed = needs_operand(w);
        if (op == 0x1) {
            m.nsel = (w & BLNS_GPU_SRC_IMM_Msk) != 0u;
            m.arm  = false;
        }
        if ((op == 0x9 || op == 0xA || op == 0xC) && m.arm) {
            m.arm  = false;
            m.pact = m.pcnt != 0u;
        }
    }
    m.q[m.qn]  = w;
    m.qt[m.qn] = data;
    m.qn++;
    model_stat();
}

/* The decoder: until the FIFO is empty, it stops on an error, or 'max'
 * words are taken */
static void model_step(unsigned max)
{
    unsigned i = 0;
    for (; i < m.qn && i < max && !m.err && m.gpu_en; i++) {
        if (m.qt[i] == 1u) {        /* immediate data: taken or dropped, never decoded */
            if (!imm_take(m.q[i]))
                m.dropped++;
            continue;
        }
        if (m.qt[i] == 3u)          /* a marker cutting the immediate copy: abandoned */
            m.ir = false;
        while (m.ir)                /* a data count short of the rectangle: 0 for the rest */
            imm_take(0u);
        if (m.qt[i] >= 2u) {        /* a DISCARD marker: the cut command dropped, disarmed */
            m.pend    = 0u;
            m.skip    = false;
            m.imm_arm = false;
            continue;
        }
        if (m.skip) {               /* the operand of a command cut by a flush */
            m.skip = false;
            continue;
        }
        feed(m.q[i]);
    }
    memmove(m.q, m.q + i, (m.qn - i) * sizeof m.q[0]);
    memmove(m.qt, m.qt + i, (m.qn - i) * sizeof m.qt[0]);
    m.qn -= i;
    if (m.mpend && m.qn < m.depth) {    /* the pending marker: at the first room */
        m.q[m.qn]  = 0u;
        m.qt[m.qn] = m.mtag;
        m.qn++;
        m.mpend = false;
    }
    model_stat();
}

static void model_run(void)
{
    model_step(~0u);
}

static void model_flush(void)
{
    m.qn      = 0;
    m.mpend   = false;
    m.pend    = 0u;
    m.imm_arm = false;
    m.ir      = false;
}

/* The DDC: an EDID EEPROM at 0x50 on the two open-drain lines, bit by bit
 * on the edges of SCL; ddc.t counts the quarter-bit delays */
enum { I2C_IDLE, I2C_ADDR, I2C_SACK, I2C_WBYTE, I2C_RBYTE, I2C_RACK };
static struct {
    bool     scl_m, sda_m;      /* the master's lines (true: released)        */
    bool     sda_s;             /* the device's SDA (true: released)          */
    int      st;
    unsigned bit;
    uint8_t  sh, offset;
    bool     rd, ack, sel;
    uint8_t  mem[256];
    unsigned t, scl_up_t;
    unsigned setup_min;         /* shortest START set-up after SCL rose (quarters) */
    unsigned starts, stops;
} ddc;

static bool ddc_sda_line(void) { return ddc.sda_m && ddc.sda_s; }
static void ddc_quarter(void) { ddc.t++; }
static void ddc_out(void) { ddc.sda_s = ((ddc.mem[ddc.offset] >> (7u - ddc.bit)) & 1u) != 0u; }

static void ddc_lines_set(uint32_t v)
{
    const bool scl0 = ddc.scl_m, sda0 = ddc_sda_line();
    ddc.scl_m = !(v & BLNS_DPI_DDC_SCL_LOW_Msk);
    ddc.sda_m = !(v & BLNS_DPI_DDC_SDA_LOW_Msk);
    const bool scl1 = ddc.scl_m, sda1 = ddc_sda_line();
    if (scl0 && scl1 && sda0 && !sda1) {                /* START */
        if (ddc.t - ddc.scl_up_t < ddc.setup_min)
            ddc.setup_min = ddc.t - ddc.scl_up_t;
        ddc.starts++;
        ddc.st = I2C_ADDR; ddc.bit = 0u; ddc.sh = 0u; ddc.sda_s = true;
        return;
    }
    if (scl0 && scl1 && !sda0 && sda1) {                /* STOP */
        ddc.stops++;
        ddc.st = I2C_IDLE; ddc.sda_s = true;
        return;
    }
    if (!scl0 && scl1) {                                /* SCL rises: sampled */
        ddc.scl_up_t = ddc.t;
        if (ddc.st == I2C_ADDR || ddc.st == I2C_WBYTE) {
            ddc.sh = (uint8_t) ((ddc.sh << 1) | (sda1 ? 1u : 0u));
            ddc.bit++;
        } else if (ddc.st == I2C_RBYTE) {
            ddc.bit++;
        } else if (ddc.st == I2C_RACK) {
            ddc.ack = !sda1;
        }
        return;
    }
    if (scl0 && !scl1) {                                /* SCL falls: the device drives */
        switch (ddc.st) {
        case I2C_ADDR:
        case I2C_WBYTE:
            if (ddc.bit == 8u) {
                if (ddc.st == I2C_ADDR) {
                    ddc.sel = (ddc.sh >> 1) == BLNS_EDID_ADDR;
                    ddc.rd  = (ddc.sh & 1u) != 0u;
                } else {
                    ddc.offset = ddc.sh;
                    ddc.rd     = false;
                }
                ddc.sda_s = !ddc.sel;                   /* ACK */
                ddc.st    = ddc.sel ? I2C_SACK : I2C_IDLE;
            }
            break;
        case I2C_SACK:
            ddc.sda_s = true;
            ddc.bit   = 0u;
            ddc.sh    = 0u;
            ddc.st    = ddc.rd ? I2C_RBYTE : I2C_WBYTE;
            if (ddc.rd)
                ddc_out();
            break;
        case I2C_RBYTE:
            if (ddc.bit < 8u) {
                ddc_out();
            } else {
                ddc.sda_s = true;                       /* the master's ACK slot */
                ddc.st    = I2C_RACK;
            }
            break;
        case I2C_RACK:
            ddc.offset++;
            ddc.bit = 0u;
            ddc.st  = ddc.ack ? I2C_RBYTE : I2C_IDLE;
            if (ddc.ack)
                ddc_out();
            break;
        default:
            break;
        }
    }
}

static uint32_t ddc_read_reg(void)
{
    return (ddc.scl_m ? BLNS_DPI_DDC_SCL_IN_Msk : 0u) | (ddc_sda_line() ? BLNS_DPI_DDC_SDA_IN_Msk : 0u);
}

/* The register window 0x180 holds the DBI driver's registers (DIF_TYPE 1-3) */
static bool model_is_dbi(void)
{
    const uint32_t t = (regs.CFG & BLNS_CFG_DIF_TYPE_Msk) >> BLNS_CFG_DIF_TYPE_Pos;
    return t >= BLNS_DIF_DBI_SPI && t <= BLNS_DIF_DBI_PAR_SPI;
}

void model_reg_wr(volatile uint32_t *reg, uint32_t v)
{
    if (reg == &regs.GPU.CTRL) {
        const bool clear = (v & BLNS_GPU_CTRL_CLEAR_ERR_Msk) != 0u, abort = (v & BLNS_GPU_CTRL_ABORT_Msk) != 0u;
        const bool disc  = (v & BLNS_GPU_CTRL_DISCARD_Msk) != 0u && m.gpu_en;
        if (clear || abort) {
            m.aborts++;
            m.phase = 0u;                                           /* stream state */
            const bool go = m.gpu_en && ((clear && m.err) || !m.err);   /* flush_go */
            m.qn    = 0;                                            /* the FIFO: flushed */
            m.mpend = false;
            m.nsel = m.arm = false;
            m.ir   = false;                                         /* abandoned */
            if (go) {
                m.pend    = 0u;
                m.imm_arm = false;
                m.skip    = m.owed && !disc;                        /* skip_go */
                if (clear)
                    m.err = false;
            }
        }
        if (disc) {                 /* after the flush: the push side resynchronised */
            m.discards++;
            const bool part = m.owed || m.pact || m.arm;
            const uint8_t tag = m.pact ? 3u : 2u;
            m.owed = m.nsel = m.arm = m.pact = false;
            m.pcnt = 0u;
            if (part && !clear && !abort && !m.err) {               /* the marker, at the cut */
                m.markers++;
                if (m.qn < m.depth) {
                    m.q[m.qn]  = 0u;
                    m.qt[m.qn] = tag;
                    m.qn++;
                } else {
                    m.mpend = true;
                    m.mtag  = tag;
                }
            }
        }
        model_stat();
        return;                                                     /* GPU_CTRL reads 0 */
    }
    if (reg == &regs.GPU.FIFO_LOW) {
        const uint32_t t = v & BLNS_GPU_FIFO_LOW_THRESH_Msk;
        m.thresh = (t < m.depth) ? t : m.depth;
        *reg     = m.thresh;
        return;
    }
    if (reg == &regs.CTRL) {
        const bool en = (v & BLNS_CTRL_GPU_EN_Msk) != 0u;
        if (!en) {                  /* GPU_EN = 0: flush, the stream reset, ERR cleared */
            if (m.gpu_en)
                m.en_pulses++;
            model_flush();
            m.phase = 0u;
            m.owed = m.nsel = m.arm = m.pact = m.skip = m.err = false;
            m.pcnt = 0u;
        }
        m.gpu_en = en;
        *reg     = v;
        model_stat();
        return;
    }
    if (reg == &regs.DPI.IRQ_FLAG) {
        *reg &= ~v;                 /* write 1 to clear */
        return;
    }
    if (reg == &regs.HDMI.DDC) {
        *reg = v;
        ddc_lines_set(v);
        return;
    }
    if (reg == &regs.DIF.PARAM && model_is_dbi()) {
        if (m.dq_n == 16u) {        /* full: dropped, PARAM_OVFL */
            m.dovfl++;
            regs.DIF.STATUS |= BLNS_DIF_STATUS_PARAM_OVFL_Msk;
        } else
            m.dq[m.dq_n++] = v & 0xFFFFu;
        return;
    }
    if (reg == &regs.DIF.CMD && model_is_dbi()) {
        if (!m.dcmd) {
            m.dcmd      = true;
            m.dcmd_left = (v & BLNS_DIF_CMD_NPARAM_Msk) >> BLNS_DIF_CMD_NPARAM_Pos;
        }
        return;
    }
    if (reg == &regs.DIF.STATUS && model_is_dbi()) {
        regs.DIF.STATUS &= ~(v & BLNS_DIF_STATUS_PARAM_OVFL_Msk);   /* W1C */
        return;
    }
    *reg = v;
}

/* DIF_STATUS of the DBI model: one parameter sent per read */
static uint32_t dif_status_rd(void)
{
    if (m.dcmd && m.dcmd_left && m.dq_n) {
        if (m.dsent_n < 256u)
            m.dsent[m.dsent_n++] = m.dq[0];
        memmove(&m.dq[0], &m.dq[1], (m.dq_n - 1u) * sizeof m.dq[0]);
        m.dq_n--;
        m.dcmd_left--;
    }
    if (m.dcmd && !m.dcmd_left)
        m.dcmd = false;
    return (regs.DIF.STATUS & BLNS_DIF_STATUS_PARAM_OVFL_Msk) | (m.dcmd ? BLNS_DIF_STATUS_CMD_PENDING_Msk : 0u) |
           ((m.dq_n == 16u) ? BLNS_DIF_STATUS_PARAM_FULL_Msk : 0u) | (m.dq_n << BLNS_DIF_STATUS_PARAM_LEVEL_Pos);
}

uint32_t model_reg_rd(const volatile uint32_t *reg)
{
    if ((reg == &regs.DPI.STATUS || reg == &regs.DPI.IRQ_FLAG) && m.hp_rd) {
        const uint32_t v = *reg;
        m.hp_rd();                  /* what happens just after this read */
        return v;
    }
    if (reg == &regs.HDMI.DDC)
        return ddc_read_reg();
    if (reg == &regs.DIF.STATUS && model_is_dbi())
        return dif_status_rd();
    if (reg == &regs.GPU.FENCE || reg == &regs.GPU.STAT) {
        const uint32_t v = *reg;
        m.gpu_rds++;
        if (m.gpu_rd)
            m.gpu_rd();             /* what happens just after this read */
        return v;
    }
    return *reg;
}

static unsigned hook_polls, hook_limit, hook_step;    /* hook_step: words decoded per poll, 0 = all */
static bool     hook_runs_gpu = true;

static bool hook(void *ctx)
{
    (void) ctx;
    hook_polls++;
    if (hook_runs_gpu)
        model_step(hook_step ? hook_step : ~0u);
    return hook_limit && hook_polls >= hook_limit;
}

/* The model's build configuration: the default one (GPU with XY, GRAD and
 * TRI, two LUT banks, a scaler, the cursor), adjusted to the features the platform header
 * of this build states (sw/test/plat_*.h), so that blns_init accepts it */
#define HW_SET(F, word, bit)  ((BLNS__HW_##F == 1) ? ((word) | (bit)) : (BLNS__HW_##F == 0) ? ((word) & ~(bit)) : (word))

static uint32_t model_cfg(uint32_t dif_type)
{
    uint32_t c = BLNS_CFG_GPU_Msk | BLNS_CFG_LUT_Msk | BLNS_CFG_LUT2_Msk | BLNS_CFG_CURSOR_Msk |
                 (13u << BLNS_CFG_DIM_W_M1_Pos) | (1u << BLNS_CFG_FRAME_NR_M1_Pos) |
                 (dif_type << BLNS_CFG_DIF_TYPE_Pos);
    c = HW_SET(GPU, c, BLNS_CFG_GPU_Msk);
    c = HW_SET(CURSOR, c, BLNS_CFG_CURSOR_Msk);
    c = HW_SET(LUT, c, BLNS_CFG_LUT_Msk);
    return HW_SET(LUT2, c, BLNS_CFG_LUT2_Msk);
}

static uint32_t model_cfg2(unsigned fifo_aw)
{
    uint32_t c = fifo_aw | BLNS_CFG2_XY_Msk | BLNS_CFG2_GRAD_Msk | BLNS_CFG2_TRI_Msk;
    c = HW_SET(GPU_XY, c, BLNS_CFG2_XY_Msk);
    c = HW_SET(GPU_GRAD, c, BLNS_CFG2_GRAD_Msk);
    c = HW_SET(GPU_BLEND, c, BLNS_CFG2_BLEND_Msk);
    c = HW_SET(GPU_TRI, c, BLNS_CFG2_TRI_Msk);
    c = HW_SET(GPU_REMAP, c, BLNS_CFG2_REMAP_Msk);
    c = HW_SET(GPU_MPLANE, c, BLNS_CFG2_MPLANE_Msk);
    c = HW_SET(GPU_IMM, c, BLNS_CFG2_IMM_Msk);
    c = HW_SET(GPU_LINE, c, BLNS_CFG2_LINE_Msk);
    return HW_SET(GPU_BILINEAR, c, BLNS_CFG2_BILINEAR_Msk);
}

static uint32_t model_dpi_caps(void)
{
    uint32_t c = (1u << BLNS_DPI_CAPS_SCALER_Pos) | BLNS_DPI_CAPS_DDC_Msk | BLNS_DPI_CAPS_AUDIO_Msk;
    c = HW_SET(DPI_DDC, c, BLNS_DPI_CAPS_DDC_Msk);
    c = HW_SET(DPI_ISLAND, c, BLNS_DPI_CAPS_ISLAND_Msk);
    return HW_SET(DPI_AUDIO, c, BLNS_DPI_CAPS_AUDIO_Msk);
}

/* The display driver the build allows: 'want' unless the platform says
 * otherwise (a DPI-only build gets DPI, a DBI-only one DBI) */
static uint32_t model_dif(uint32_t want)
{
    const bool dpi = want == BLNS_DIF_DPI || want == BLNS_DIF_HDMI;
    const bool dbi = want >= BLNS_DIF_DBI_SPI && want <= BLNS_DIF_DBI_PAR_SPI;
    if ((BLNS__HW_DPI == 1 && !dpi) || (BLNS__HW_DBI == 0 && dbi))
        return (BLNS__HW_DPI_DDC == 1 || BLNS__HW_DPI_ISLAND == 1) ? BLNS_DIF_HDMI : BLNS_DIF_DPI;
    if ((BLNS__HW_DBI == 1 && !dbi) || (BLNS__HW_DPI == 0 && dpi))
        return BLNS_DIF_DBI_PAR;
    if (want == BLNS_DIF_DPI && (BLNS__HW_DPI_DDC == 1 || BLNS__HW_DPI_ISLAND == 1))
        return BLNS_DIF_HDMI;                       /* DPI with the HDMI options */
    return want;
}

static void setup_fifo(uint32_t dif_type, uint32_t cfg2_extra, unsigned fifo_aw)
{
    dif_type = model_dif(dif_type);
    memset(&regs, 0, sizeof regs);
    memset(vram, 0, sizeof vram);
    memset(&ddc, 0, sizeof ddc);
    ddc.scl_m = ddc.sda_m = ddc.sda_s = true;
    ddc.setup_min = ~0u;
    m.depth  = 1u << fifo_aw;
    m.gpu_en = false;
    model_reset();
    RW(regs.ID)         = 0x00010000u;
    RW(regs.CFG)        = model_cfg(dif_type);
    RW(regs.CFG2)       = model_cfg2(fifo_aw) | cfg2_extra;
    RW(regs.DPI.CAPS)   = (dif_type == BLNS_DIF_DPI || dif_type == BLNS_DIF_HDMI) ? model_dpi_caps() : 0u;
    RW(regs.VRAM_WORDS) = MODEL_WORDS;
    regs.DISP_SIZE      = (240u << 16) | 320u;                  /* left by a previous program */
    regs.CTRL           = BLNS_BPP_16;
    model_stat();
    hook_polls = hook_limit = hook_step = 0u;
    hook_runs_gpu = true;
    const blns_config_t cfg = { .reg_base = (uintptr_t) &regs, .vram_base = (uintptr_t) vram,
                                .hclk_hz = 50000000u, .wait_hook = hook };
    if (blns_init(&dev, &cfg) != BLNS_OK) {
        printf("blns_init failed\n");
        exit(1);
    }
}

static void setup(uint32_t dif_type, uint32_t cfg2_extra)
{
    setup_fifo(dif_type, cfg2_extra, MODEL_FIFO_AW);
}

/* blns_init again on the model as it is (a program started by another one) */
static void reinit(void)
{
    const blns_config_t cfg = { .reg_base = (uintptr_t) &regs, .vram_base = (uintptr_t) vram,
                                .hclk_hz = 50000000u, .wait_hook = hook };
    if (blns_init(&dev, &cfg) != BLNS_OK) {
        printf("blns_init failed\n");
        exit(1);
    }
}

#endif /* BLNS_MODEL_IMPL_H */
