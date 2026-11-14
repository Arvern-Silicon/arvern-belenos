/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      check_bilinear.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Host check of the GPU's bilinear arithmetic (SPEC_alpha_bilinear 2.2)
 * against LVGL v9.6.0's two RGB565A8 kernels (draw/sw/lv_draw_sw_transform.c:
 * rgb565a8_row_fast, for uniform alphas, and the alpha-weighted
 * transform_alpha_weights of row_checked and of mixed alphas; their
 * arithmetic quoted below, LVGL is MIT-licensed, (c) LVGL Kft), each followed
 * by LVGL's mix (lv_color_16_16_mix). The same taps, fractions and
 * destination for both sides; the GPU: 5-bit weights k = wx wy, e = (k a') >>
 * 8 with a' = a + (a >> 7), the premultiplied blend with MIX5 (truncated).
 * A regression of the specification's bounds: the largest difference per
 * RGB565 field of each kind of taps must stay within the table of 2.2
 * (opaque 1 / 1 / 1 against row_fast, 2 / 4 / 2 against row_checked; image
 * edges 3 / 5 / 3, smooth images 2 / 3 / 2, random alphas 3 / 5 / 3), and
 * LVGL's two kernels within 5 of G of each other on opaque taps.
 *
 *   make -C sw/test   (part of the default run)
 *----------------------------------------------------------------------------*/
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CASES 2000000u

/* LVGL v9.6.0 transform_norm_inv: (32 << 8) / sum */
static const uint16_t inv_t[257] = {
    0, 8192, 4096, 2730, 2048, 1638, 1365, 1170, 1024, 910, 819, 744, 682, 630, 585, 546, 512, 481, 455,
    431, 409, 390, 372, 356, 341, 327, 315, 303, 292, 282, 273, 264, 256, 248, 240, 234, 227, 221, 215,
    210, 204, 199, 195, 190, 186, 182, 178, 174, 170, 167, 163, 160, 157, 154, 151, 148, 146, 143, 141,
    138, 136, 134, 132, 130, 128, 126, 124, 122, 120, 118, 117, 115, 113, 112, 110, 109, 107, 106, 105,
    103, 102, 101, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 87, 86, 85, 84, 83, 82, 81, 81, 80,
    79, 78, 78, 77, 76, 75, 75, 74, 73, 73, 72, 71, 71, 70, 70, 69, 68, 68, 67, 67, 66, 66, 65, 65, 64,
    64, 63, 63, 62, 62, 61, 61, 60, 60, 59, 59, 58, 58, 58, 57, 57, 56, 56, 56, 55, 55, 54, 54, 54, 53,
    53, 53, 52, 52, 52, 51, 51, 51, 50, 50, 50, 49, 49, 49, 49, 48, 48, 48, 47, 47, 47, 47, 46, 46, 46,
    46, 45, 45, 45, 45, 44, 44, 44, 44, 43, 43, 43, 43, 42, 42, 42, 42, 42, 41, 41, 41, 41, 40, 40, 40,
    40, 40, 39, 39, 39, 39, 39, 39, 38, 38, 38, 38, 38, 37, 37, 37, 37, 37, 37, 36, 36, 36, 36, 36, 36,
    35, 35, 35, 35, 35, 35, 35, 34, 34, 34, 34, 34, 34, 33, 33, 33, 33, 33, 33, 33, 33, 32, 32, 32, 32,
    32, 32, 32, 32
};

/* LVGL v9.6.0 transform_alpha_weights */
static uint32_t lv_weights(const uint8_t *a, uint32_t fx, uint32_t fy, uint32_t *t)
{
    const uint32_t ifx = 256u - fx, ify = 256u - fy;
    const uint32_t u00 = (((ifx * ify) >> 8) * (a[0] + (a[0] >> 7))) >> 8;
    const uint32_t u01 = (((fx * ify) >> 8) * (a[1] + (a[1] >> 7))) >> 8;
    const uint32_t u10 = (((ifx * fy) >> 8) * (a[2] + (a[2] >> 7))) >> 8;
    const uint32_t u11 = (((fx * fy) >> 8) * (a[3] + (a[3] >> 7))) >> 8;
    const uint32_t sum = u00 + u01 + u10 + u11;
    if (!sum) {
        t[0] = t[1] = t[2] = t[3] = 0u;
        return 0u;
    }
    const uint32_t inv = inv_t[sum];
    const uint32_t c1 = (u00 * inv) >> 8, c2 = ((u00 + u01) * inv) >> 8, c3 = ((u00 + u01 + u10) * inv) >> 8;
    const uint32_t c4 = (sum * inv) >> 8;
    t[0] = c1;
    t[1] = c2 - c1;
    t[2] = c3 - c2;
    t[3] = c4 - c3;
    const uint32_t rem = 32u - c4;
    if (rem) {
        uint32_t m = 0, best = u00;
        if (u01 > best) { best = u01; m = 1; }
        if (u10 > best) { best = u10; m = 2; }
        if (u11 > best) m = 3;
        t[m] += rem;
    }
    return sum > 255u ? 255u : sum;
}

static uint32_t P(uint16_t c) { return (c | ((uint32_t) c << 16)) & 0x7E0F81Fu; }
static uint16_t U(uint32_t r) { return (uint16_t) (r | (r >> 16)); }

/* LVGL v9.6.0 row_fast's opaque lerp (5-bit weights, separable) */
static uint16_t lv_fast(const uint16_t *c, uint32_t fx, uint32_t fy)
{
    const uint32_t fx5 = (fx + 4u) >> 3, fy5 = (fy + 4u) >> 3;
    const uint32_t top = ((P(c[0]) * (32u - fx5) + P(c[1]) * fx5) >> 5) & 0x7E0F81Fu;
    const uint32_t bot = ((P(c[2]) * (32u - fx5) + P(c[3]) * fx5) >> 5) & 0x7E0F81Fu;
    return U(((top * (32u - fy5) + bot * fy5) >> 5) & 0x7E0F81Fu);
}

/* ... and the weighted sum of the alpha weights */
static uint16_t lv_weighted(const uint16_t *c, const uint32_t *t)
{
    return U(((P(c[0]) * t[0] + P(c[1]) * t[1] + P(c[2]) * t[2] + P(c[3]) * t[3]) >> 5) & 0x7E0F81Fu);
}

/* lv_color_16_16_mix (the shortcuts as LVGL's callers take them) */
static uint16_t lv_mix(uint16_t s, uint16_t d, uint32_t a)
{
    const uint32_t m = (a + 4u) >> 3;
    return U(((((P(s) - P(d)) * m) >> 5) + P(d)) & 0x7E0F81Fu);
}

/* LVGL: the transform (uniform alphas: row_fast, else the weights; edges and
 * row_checked: the weights), then the image blend at opa 255 */
static uint16_t lvgl_px(const uint16_t *c, const uint8_t *a, uint32_t fx, uint32_t fy, uint16_t d, int checked)
{
    uint32_t al;
    uint16_t col;
    if (!checked && a[0] == a[1] && a[0] == a[2] && a[0] == a[3]) {
        al = a[0];
        if (!al)
            return d;
        col = lv_fast(c, fx, fy);
    } else {
        uint32_t t[4];
        al = lv_weights(a, fx, fy, t);
        if (!al)
            return d;
        col = lv_weighted(c, t);
    }
    return (al >= 253u) ? col : lv_mix(col, d, al);
}

/* The GPU: the tap MAC and the premultiplied blend, MIX5 (r = 0) */
static int chv(uint16_t c, int f) { return f == 0 ? (c >> 11) : f == 1 ? ((c >> 5) & 63) : (c & 31); }
static uint16_t gpu_px(const uint16_t *c, const uint8_t *a, uint32_t fx, uint32_t fy, uint16_t d)
{
    const uint32_t fx5 = (fx + 4u) >> 3, fy5 = (fy + 4u) >> 3;
    const uint32_t wx[2] = { 32u - fx5, fx5 }, wy[2] = { 32u - fy5, fy5 };
    uint32_t       S = 0, Pc[3] = { 0, 0, 0 };
    for (int i = 0; i < 4; i++) {
        const uint32_t e = (wx[i & 1] * wy[i >> 1] * (a[i] + (a[i] >> 7u))) >> 8;
        S += e;
        for (int f = 0; f < 3; f++)
            Pc[f] += e * (uint32_t) chv(c[i], f);
    }
    const int a256 = (int) (S >> 2);
    if (!a256)
        return d;
    static const int sh[3] = { 11, 5, 0 };
    uint16_t o = 0;
    for (int f = 0; f < 3; f++) {
        const int dv = chv(d, f), x = (int) (Pc[f] >> 2) - dv * a256;
        o |= (uint16_t) ((dv + (x >= 0 ? x / 256 : -((-x + 255) / 256))) << sh[f]);
    }
    return o;
}

static uint32_t rx = 11u;
static uint32_t rnd(void)
{
    rx = rx * 1664525u + 1013904223u;
    return rx >> 8;
}

static int clampi(int v, int hi) { return v < 0 ? 0 : v > hi ? hi : v; }

int main(void)
{
    /* kind: 0 opaque (row_fast), 1 alphas 0 / 255 (an image edge), 2 mixed,
     * 3 random alphas, 4 smooth image with mixed alphas, 5 opaque against
     * row_checked; 6: LVGL's row_fast against its row_checked, opaque */
    static const char *const name[7] = { "opaque, row_fast", "alpha 0 / 255", "mixed alpha", "random alpha",
                                         "smooth, mixed alpha", "opaque, row_checked", "LVGL fast / checked" };
    static const int bound[7][3] = { { 1, 1, 1 }, { 3, 5, 3 }, { 3, 5, 3 }, { 3, 5, 3 }, { 2, 3, 2 }, { 2, 4, 2 },
                                     { 63, 5, 63 } };
    int failed = 0;
    for (int kind = 0; kind < 7; kind++) {
        unsigned long diff = 0;
        int           mx[3] = { 0, 0, 0 };
        for (uint32_t it = 0; it < CASES; it++) {
            uint16_t       c[4], d = (uint16_t) rnd();
            uint8_t        a[4];
            const uint32_t fx = rnd() & 255u, fy = rnd() & 255u;
            for (int i = 0; i < 4; i++) {
                c[i] = (uint16_t) rnd();
                const uint32_t r = rnd();
                a[i] = (kind == 0 || kind >= 5) ? 255u : kind == 1 ? ((r & 1u) ? 255u : 0u)
                     : (kind == 2 || kind == 4) ? (uint8_t) ((r % 4u == 0) ? 0u : (r % 4u == 1) ? 255u : (rnd() & 255u))
                     : (uint8_t) (r & 255u);
            }
            if (kind == 4)                          /* neighbours close to the first texel */
                for (int i = 1; i < 4; i++)
                    c[i] = (uint16_t) ((clampi((c[0] >> 11) + (int) (rnd() % 5u) - 2, 31) << 11) |
                                       (clampi(((c[0] >> 5) & 63) + (int) (rnd() % 9u) - 4, 63) << 5) |
                                       clampi((c[0] & 31) + (int) (rnd() % 5u) - 2, 31));
            const uint16_t l = (kind == 6) ? lvgl_px(c, a, fx, fy, d, 0) : lvgl_px(c, a, fx, fy, d, kind == 5);
            const uint16_t h = (kind == 6) ? lvgl_px(c, a, fx, fy, d, 1) : gpu_px(c, a, fx, fy, d);
            if (l != h) {
                diff++;
                for (int f = 0; f < 3; f++) {
                    const int e = abs(chv(l, f) - chv(h, f));
                    mx[f] = e > mx[f] ? e : mx[f];
                }
            }
        }
        const int ok = mx[0] <= bound[kind][0] && mx[1] <= bound[kind][1] && mx[2] <= bound[kind][2];
        printf("bilinear %-20s: %5.1f %% differ, largest %d / %d / %d (bound %d / %d / %d)%s\n", name[kind],
               100.0 * (double) diff / CASES, mx[0], mx[1], mx[2], bound[kind][0], bound[kind][1], bound[kind][2],
               ok ? "" : "  BEYOND");
        failed |= !ok;
    }
    return failed;
}
