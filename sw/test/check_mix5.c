/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      check_mix5.c
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Host check of the GPU's MIX5 blend rule (SET_ALPHA [9]) against LVGL's:
 * LVGL v9.6.0's lv_color_16_16_mix, lv_color_24_16_mix and LV_OPA_MIX2
 * (their arithmetic quoted below; LVGL is MIT-licensed, (c) LVGL Kft) against
 * the GPU's per-field formula, which must give the same pixels:
 *   factor m = (alpha + 4) >> 3, out = d + floor((s - d) m / 32) per RGB565
 *   field; x o A = (x A) >> 8; not written at m = 0.
 * Exhaustive per field (every s, d of the field, every alpha, the other
 * fields random), exhaustive on LVGL's shortcut (c1 = c2), random pairs for
 * the rest; the rounded rule's combination ((x A + 127) 257 + 256) >> 16 is
 * round(x A / 255) everywhere; the no-destination-read rule of an A8 pixel
 * (spec 3.1) only where the pixel is written as s. 0 differences required.
 *
 *   make -C sw/test   (part of the default run)
 *----------------------------------------------------------------------------*/
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* LVGL v9.6.0 misc/lv_color.c lv_color_16_16_mix */
static uint16_t lv_16_16_mix(uint16_t c1, uint16_t c2, uint8_t mix)
{
    if (mix == 255)
        return c1;
    if (mix == 0)
        return c2;
    if (c1 == c2)
        return c1;
    const uint32_t m  = ((uint32_t) mix + 4u) >> 3;
    const uint32_t bg = (c2 | ((uint32_t) c2 << 16)) & 0x7E0F81Fu;
    const uint32_t fg = (c1 | ((uint32_t) c1 << 16)) & 0x7E0F81Fu;
    const uint32_t r  = ((((fg - bg) * m) >> 5) + bg) & 0x7E0F81Fu;
    return (uint16_t) ((r >> 16) | r);
}

/* LVGL v9.6.0 draw/sw/blend: LV_COLOR_24_TO_16 and lv_color_24_16_mix (c1:
 * B, G, R bytes) */
static uint16_t lv_24_to_16(const uint8_t *c)
{
    return (uint16_t) (((c[2] & 0xF8u) << 8) + ((c[1] & 0xFCu) << 3) + ((c[0] & 0xF8u) >> 3));
}

static uint16_t lv_24_16_mix(const uint8_t *c1, uint16_t c2, uint8_t mix)
{
    const uint16_t c  = lv_24_to_16(c1);
    const uint32_t m  = ((uint32_t) mix + 4u) >> 3;
    const uint32_t bg = (c2 | ((uint32_t) c2 << 16)) & 0x7E0F81Fu;
    const uint32_t fg = (c | ((uint32_t) c << 16)) & 0x7E0F81Fu;
    const uint32_t r  = ((((fg - bg) * m) >> 5) + bg) & 0x7E0F81Fu;
    return (uint16_t) ((r >> 16) | r);
}

/* LVGL v9.6.0 LV_OPA_MIX2 */
static uint8_t lv_opa_mix2(int a1, int a2) { return (uint8_t) ((a1 * a2) >> 8); }

/* The GPU (gpu_commands.md, blending; SPEC_alpha_bilinear 2.1) */
static int gpu_field(int s, int d, int alpha)
{
    const int m = (alpha + 4) >> 3, x = (s - d) * m;
    return d + (x >= 0 ? x / 32 : -((-x + 31) / 32));          /* floor */
}

static uint16_t gpu_mix5(uint16_t s, uint16_t d, int alpha)
{
    if (((alpha + 4) >> 3) == 0)
        return d;                                               /* not written */
    return (uint16_t) ((gpu_field(s >> 11, d >> 11, alpha) << 11) |
                       (gpu_field((s >> 5) & 63, (d >> 5) & 63, alpha) << 5) | gpu_field(s & 31, d & 31, alpha));
}

static int gpu_comb5(int x, int A) { return (x * A) >> 8; }
static int gpu_comb_round(int x, int A) { return ((x * A + 127) * 257 + 256) >> 16; }

static uint32_t rx = 7u;
static uint32_t rnd(void)
{
    rx = rx * 1664525u + 1013904223u;
    return rx >> 8;
}

int main(void)
{
    unsigned long n = 0, bad = 0;
    /* per field, exhaustive: every value pair of the field, every alpha */
    static const int sh[3] = { 11, 5, 0 }, mk[3] = { 31, 63, 31 };
    for (int f = 0; f < 3; f++)
        for (int s = 0; s <= mk[f]; s++)
            for (int d = 0; d <= mk[f]; d++)
                for (int a = 0; a < 256; a++)
                    for (int k = 0; k < 2; k++) {
                        const uint16_t o  = (uint16_t) (rnd() & ~((uint32_t) mk[f] << sh[f]));
                        const uint16_t c1 = (uint16_t) (((uint32_t) s << sh[f]) | (k ? o : 0u));
                        const uint16_t c2 = (uint16_t) (((uint32_t) d << sh[f]) | (k ? (uint16_t) rnd() & ~((uint32_t) mk[f] << sh[f]) : 0u));
                        n++;
                        bad += lv_16_16_mix(c1, c2, (uint8_t) a) != gpu_mix5(c1, c2, a);
                    }
    /* LVGL's c1 = c2 shortcut, exhaustive */
    for (uint32_t c = 0; c < 65536u; c++)
        for (int a = 0; a < 256; a++) {
            n++;
            bad += lv_16_16_mix((uint16_t) c, (uint16_t) c, (uint8_t) a) != gpu_mix5((uint16_t) c, (uint16_t) c, a);
        }
    /* random pairs; ARGB8888 truncated (staging) then mixed */
    for (uint32_t i = 0; i < 4000000u; i++) {
        const uint16_t c1 = (uint16_t) rnd(), c2 = (uint16_t) rnd();
        const int      a  = (int) (rnd() & 0xFFu);
        const uint8_t  c24[3] = { (uint8_t) rnd(), (uint8_t) rnd(), (uint8_t) rnd() };
        n += 2u;
        bad += lv_16_16_mix(c1, c2, (uint8_t) a) != gpu_mix5(c1, c2, a);
        bad += lv_24_16_mix(c24, c2, (uint8_t) a) != gpu_mix5(lv_24_to_16(c24), c2, a);
    }
    printf("mix5: %lu cases, %lu differ (lv_color_16_16_mix, lv_color_24_16_mix)\n", n, bad);
    /* coverage x A: MIX5 is LV_OPA_MIX2; the rounded rule rounds x A / 255 */
    unsigned long cb = 0;
    for (int x = 0; x < 256; x++)
        for (int A = 0; A < 256; A++) {
            cb += gpu_comb5(x, A) != lv_opa_mix2(x, A);
            cb += gpu_comb_round(x, A) != (2 * x * A + 255) / 510;
        }
    printf("x o A: %lu differ (LV_OPA_MIX2, round(x A / 255))\n", cb);
    /* an A8 pixel read no destination (spec 3.1): only where it is written
     * as s (MIX5: m = 32; rounded: alpha 255), for every byte b, EN, A */
    unsigned long nd = 0;
    for (int b = 0; b < 256; b++)
        for (int en = 0; en < 2; en++)
            for (int A = 0; A < 256; A++) {
                const bool m5_nd = (!en && b >= 252) || (en && A == 255 && b >= 253);
                const bool rd_nd = b == 255 && (!en || A == 255);
                const int  a5 = en ? gpu_comb5(b, A) : b, ar = en ? gpu_comb_round(b, A) : b;
                nd += m5_nd && ((a5 + 4) >> 3) != 32;
                nd += rd_nd && ar != 255;
            }
    printf("no-D rule: %lu pixels read no D but are not written as s\n", nd);
    return (bad || cb || nd) ? 1 : 0;
}
