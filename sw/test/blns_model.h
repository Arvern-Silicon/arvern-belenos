/*----------------------------------------------------------------------------
 *          _    _           Family:    aRVern Graphic Controller
 *         / \__/ \          File:      blns_model.h
 *        /   /\   \         --------------------------------------------
 *    ===/   /=========      Copyright: (c) 2026, aRVern-dev
 *      /   / RV \   \       Contact:   arvernsilicon@gmail.com
 *     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * Full license text is available in the LICENSE file at the repository root.
 *----------------------------------------------------------------------------
 * Host unit test of the driver: included before belenos.h in every driver
 * file (-include), it routes the GPU_CMD stores and the register accesses
 * whose order matters (BLNS_REG_WR / BLNS_REG_RD: CTRL, GPU_CTRL, the
 * hot-plug and DDC registers, the fence status reads) to the model.
 *----------------------------------------------------------------------------*/
#ifndef BLNS_MODEL_H
#define BLNS_MODEL_H

#include <stdint.h>

void     model_cmd(uint32_t w);
void     model_reg_wr(volatile uint32_t *reg, uint32_t v);
uint32_t model_reg_rd(const volatile uint32_t *reg);
#define BLNS_CMD_WRITE(dev, w)      model_cmd(w)
#define BLNS_REG_WR(dev, field, v)  model_reg_wr(&(dev)->regs->field, (v))
#define BLNS_REG_RD(dev, field)     model_reg_rd(&(dev)->regs->field)

#endif
