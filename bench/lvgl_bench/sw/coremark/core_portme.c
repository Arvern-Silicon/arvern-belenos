/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      core_portme.c (bench/lvgl_bench)
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * CoreMark port of the LVGL benchmark bench (core_portme.h): the timing
 * functions on the bench's cycle counter (one tick per cycle,
 * EE_TICKS_PER_SEC the bench clock), ee_printf on the bench console, the
 * end of the run (EXIT 0 when the CRCs match). The result line "LB
 * COREMARK" gives the iterations, the cycles they took and CoreMark/MHz.
 *----------------------------------------------------------------------------*/
#include <stdarg.h>
#include <stdio.h>
#include "coremark.h"

#define LB_REG(off)     (*(volatile ee_u32 *) (0x10000000u + (off)))
#define LB_TTY          LB_REG(0x00)
#define LB_EXIT         LB_REG(0x04)
#define LB_CYC_LO       LB_REG(0x10)
#define LB_CLK_HZ       LB_REG(0x40)

#define EE_TICKS_PER_SEC 111000000u

volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static CORE_TICKS t_start, t_stop;

void start_time(void) { t_start = LB_CYC_LO; }
void stop_time(void)  { t_stop  = LB_CYC_LO; }
CORE_TICKS get_time(void) { return t_stop - t_start; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret) (ticks / EE_TICKS_PER_SEC); }

int ee_printf(const char *fmt, ...)
{
    char    buf[256];
    va_list ap;
    va_start(ap, fmt);
    const int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    for (const char *s = buf; *s; s++)
        LB_TTY = (ee_u32) (ee_u8) *s;
    return n;
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void) argc;
    (void) argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    const ee_u32 cyc = get_time();
    /* CoreMark/MHz = iterations / (cycles / 10^6), three decimals */
    const unsigned long long x1000 = (unsigned long long) ITERATIONS * 1000000000ull / cyc;
    ee_printf("LB COREMARK: %u iterations in %u cycles: %u.%03u CoreMark/MHz\n", (unsigned) ITERATIONS,
              (unsigned) cyc, (unsigned) (x1000 / 1000u), (unsigned) (x1000 % 1000u));
    p->portable_id = 0;
}

/* The startup's trap vector (startup.S) */
void lb_trap(ee_u32 mcause, ee_u32 mepc, ee_u32 mtval)
{
    ee_printf("LB ERROR: trap, mcause 0x%x, mepc 0x%x, mtval 0x%x\n", (unsigned) mcause, (unsigned) mepc,
              (unsigned) mtval);
    LB_EXIT = 3u;
    for (;;)
        ;
}
