/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      startup.S (bench/lvgl_bench)
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * C runtime of the LVGL benchmark bench firmware (bare-metal RV32I):
 *   0. double-trap boot sequence (arm mnstatus.NMIE, then clear mstatush.MDT)
 *   1. the trap vector, the stack pointer
 *   2. .data copied from its image in the code memory, .bss zeroed
 *   3. main(); its return value ends the simulation (the bench's EXIT)
 * Any trap is an error of the run: the cause, the PC and mtval go to the
 * console and the simulation ends (EXIT 3).
 *----------------------------------------------------------------------------*/

.section .init, "ax"
.globl _start
_start:
    csrsi 0x744, 8                   /* mnstatus.NMIE = 1                   */
    csrw  mstatush, x0               /* mstatus.MDT   = 0                   */
    la    t0, lb_trap_entry
    csrw  mtvec, t0
    la    sp, _stack_end

    la    a0, __romdatastart
    la    a1, __datastart
    la    a2, __romdatacopysize
    beqz  a2, 2f
1:  lw    t0, 0(a0)
    sw    t0, 0(a1)
    addi  a0, a0, 4
    addi  a1, a1, 4
    addi  a2, a2, -4
    bgtz  a2, 1b

2:  la    a0, __bssstart
    la    a1, __bssend
    sub   a2, a1, a0
    beqz  a2, 3f
4:  sw    x0, 0(a0)
    addi  a0, a0, 4
    addi  a2, a2, -4
    bnez  a2, 4b

3:  call  main
    li    t0, 0x10000004             /* the bench's EXIT register           */
    sw    a0, 0(t0)
    j     .

    .text
    .p2align 2
    .globl lb_trap_entry
lb_trap_entry:
    csrr  a0, mcause
    csrr  a1, mepc
    csrr  a2, mtval
    call  lb_trap
    j     .
