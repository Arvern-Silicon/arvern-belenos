#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    check_reg_figures
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : check_reg_figures.py
# Module Description : Check the hand-written register figures
#                      (doc/img/reg_*.json, WaveDrom bit fields rendered to
#                      SVG by doc/img/render.py) against the field macros of
#                      sw/include/belenos_regs.h:
#                        - every named field has an entry in FIGURES below
#                          (a macro, a constant, or a waiver with a reason)
#                          and matches its macro in position and width;
#                        - every _Msk macro of the register's prefixes lies
#                          on named fields (none falls in a gap);
#                        - the fields add up to the register width;
#                        - the SVG holds every field name (rendered from the
#                          current JSON);
#                        - every figure is referenced by a Markdown file.
#                      Exit status 0 when all checks pass.
#----------------------------------------------------------------------------
"""
Usage:
    python3 doc/tools/check_reg_figures.py          # from anywhere in the repo
    python3 doc/tools/check_reg_figures.py -v       # also list what passed
"""

import glob
import html
import json
import os
import re
import sys

ROOT   = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
IMG    = os.path.join(ROOT, 'doc', 'img')
HEADER = os.path.join(ROOT, 'sw', 'include', 'belenos_regs.h')

# ---------------------------------------------------------------------------
# Figure table: figure -> the macro prefixes whose _Msk macros must all lie
# on named fields ('cover'), and one entry per field label:
#   'BLNS_X'                       field macro BLNS_X_Msk (or BLNS_X_Pos alone:
#                                  position only), or a plain mask macro BLNS_X
#   ('expr', 'python expression')  the field mask, from macros
#   ('const', 'BLNS_V'[, 'BLNS_F']) a constant cell: BLNS_V == number in the
#                                  label << field lsb (and the field is BLNS_F)
#   ('consts', ['BLNS_V', ...])    as const, for a label 'a/b/c' (hex digits)
#   ('waive', 'reason')            not checked
# ---------------------------------------------------------------------------
SW_D = 'BLNS_SWAP_{}_Msk << BLNS_GPU_EXEC_DST_SWAP_Pos'
SW_S = 'BLNS_SWAP_{}_Msk << BLNS_GPU_EXEC_SRC_SWAP_Pos'
SW_T = 'BLNS_SWAP_{}_Msk << BLNS_GPU_TEX_SWAP_Pos'
OP   = 'BLNS_GPU_OP'

FIGURES = {
    # --- core --------------------------------------------------------------
    'reg_blns_cfg': {'cover': ['BLNS_CFG_'], 'fields': {
        'VRAM_AW': 'BLNS_CFG_VRAM_AW', 'LUT': 'BLNS_CFG_LUT', 'LUT2': 'BLNS_CFG_LUT2',
        'FRAME_NR-1': 'BLNS_CFG_FRAME_NR_M1', 'DIM_W-1': 'BLNS_CFG_DIM_W_M1',
        'DIF_TYPE': 'BLNS_CFG_DIF_TYPE', 'PRIV_CHECK': 'BLNS_CFG_PRIV_CHECK', 'GPU': 'BLNS_CFG_GPU',
        'CURSOR': 'BLNS_CFG_CURSOR'}},
    'reg_blns_cfg2': {'cover': ['BLNS_CFG2_'], 'fields': {
        'FIFO_AW': 'BLNS_CFG2_FIFO_AW', 'XY': 'BLNS_CFG2_XY', 'GRAD': 'BLNS_CFG2_GRAD',
        'BLEND': 'BLNS_CFG2_BLEND', 'TRI': 'BLNS_CFG2_TRI', 'REMAP': 'BLNS_CFG2_REMAP',
        'MPLANE': 'BLNS_CFG2_MPLANE', 'IMM': 'BLNS_CFG2_IMM', 'LINE': 'BLNS_CFG2_LINE',
        'BILINEAR': 'BLNS_CFG2_BILINEAR'}},
    'reg_ctrl': {'cover': ['BLNS_CTRL_'], 'fields': {
        'GFX_MODE': 'BLNS_CTRL_GFX_MODE', 'GPU_EN': 'BLNS_CTRL_GPU_EN'}},
    'reg_status': {'cover': ['BLNS_STATUS_'], 'fields': {
        'REFRESH_ACTIVE': 'BLNS_STATUS_REFRESH_ACTIVE', 'GPU_BUSY': 'BLNS_STATUS_GPU_BUSY',
        'GPU_ERR': 'BLNS_STATUS_GPU_ERR', 'DIF_BUSY': 'BLNS_STATUS_DIF_BUSY',
        'REFR_ABANDONED': 'BLNS_STATUS_REFR_ABANDONED'}},
    'reg_irq': {'cover': ['BLNS_IRQ_'], 'fields': {
        'REFR_DONE': 'BLNS_IRQ_REFR_DONE', 'REFR_START': 'BLNS_IRQ_REFR_START',
        'FRAME_CNT_DONE': 'BLNS_IRQ_FRAME_CNT_DONE', 'GPU_DONE': 'BLNS_IRQ_GPU_DONE',
        'GPU_IDLE': 'BLNS_IRQ_GPU_IDLE', 'GPU_OVFL': 'BLNS_IRQ_GPU_OVFL', 'GPU_ERR': 'BLNS_IRQ_GPU_ERR',
        'DIF': 'BLNS_IRQ_DIF', 'GPU_FENCE': 'BLNS_IRQ_GPU_FENCE', 'GPU_FIFO_LOW': 'BLNS_IRQ_GPU_FIFO_LOW'}},
    'reg_disp_size': {'cover': ['BLNS_DISP_SIZE_'], 'fields': {
        'WIDTH  [DIM_W-1:0]': 'BLNS_DISP_SIZE_WIDTH', 'HEIGHT  [16+DIM_W-1:16]': 'BLNS_DISP_SIZE_HEIGHT'}},
    'reg_disp_cfg': {'cover': ['BLNS_SWAP_', 'BLNS_DISP_CFG_'], 'fields': {
        'CL_SWAP': 'BLNS_SWAP_CL', 'Y_SWAP': 'BLNS_SWAP_Y', 'X_SWAP': 'BLNS_SWAP_X',
        'PIX_DOUBLE': 'BLNS_DISP_CFG_PIX_DOUBLE'}},
    'reg_refresh': {'cover': ['BLNS_REFRESH_'], 'fields': {
        'START': 'BLNS_REFRESH_START', 'PERIOD (cycles; 0 = manual)': 'BLNS_REFRESH_PERIOD'}},
    'reg_frame_sel': {'cover': ['BLNS_FRAME_SEL_'], 'fields': {
        'REFR': 'BLNS_FRAME_SEL_REFR', 'LATCHED': 'BLNS_FRAME_SEL_LATCHED'}},
    'reg_lut_cfg': {'cover': ['BLNS_LUT_CFG_'], 'fields': {
        'SW_LUT_EN': 'BLNS_LUT_CFG_SW_LUT_EN', 'REFR_BANK': 'BLNS_LUT_CFG_REFR_BANK',
        'HW_PALETTE': 'BLNS_LUT_CFG_HW_PALETTE', 'HW_BG': 'BLNS_LUT_CFG_HW_BG', 'HW_FG': 'BLNS_LUT_CFG_HW_FG'}},
    'reg_lut_rot': {'cover': ['BLNS_LUT_ROT_'], 'fields': {
        'FIRST': 'BLNS_LUT_ROT_FIRST', 'LAST': 'BLNS_LUT_ROT_LAST', 'OFFSET': 'BLNS_LUT_ROT_OFFSET'}},
    'reg_cursor_ctrl': {'cover': ['BLNS_CURSOR_CTRL_'], 'fields': {
        'EN': 'BLNS_CURSOR_CTRL_EN', 'HOT_X': 'BLNS_CURSOR_CTRL_HOT_X', 'HOT_Y': 'BLNS_CURSOR_CTRL_HOT_Y'}},
    'reg_cursor_pos': {'cover': ['BLNS_CURSOR_POS_'], 'fields': {
        'X (signed)': 'BLNS_CURSOR_POS_X', 'Y (signed)': 'BLNS_CURSOR_POS_Y'}},
    'reg_cursor_addr': {'cover': ['BLNS_CURSOR_ADDR_'], 'fields': {
        '0': ('waive', 'reads 0: the block is 128-word aligned (BLNS_CURSOR_ADDR_ALIGN)'),
        'ADDR  [VRAM_AW-1:7]': 'BLNS_CURSOR_ADDR'}},
    # --- DBI driver (header names differ for four fields) -----------------
    'reg_dif_cfg': {'cover': ['BLNS_DIF_CFG_'], 'fields': {
        'LCD_ON': 'BLNS_DIF_CFG_LCD_ON', 'LCD_RESET': 'BLNS_DIF_CFG_LCD_RESET',
        'PHY_SEL': 'BLNS_DIF_CFG_PHY_SPI', 'RD_DIV': 'BLNS_DIF_CFG_RD_DIV', 'CLK_DIV': 'BLNS_DIF_CFG_CLK_DIV',
        'HW_WINDOW_EN': 'BLNS_DIF_CFG_HW_WINDOW'}},
    'reg_dif_sync': {'cover': ['BLNS_DIF_SYNC_'], 'fields': {
        'SCANLINE': 'BLNS_DIF_SYNC_SCANLINE', 'SCAN_SYNC_EN': 'BLNS_DIF_SYNC_SCAN_EN',
        'TE_SYNC_EN': 'BLNS_DIF_SYNC_TE_EN'}},
    'reg_dif_cmd': {'cover': ['BLNS_DIF_CMD_'], 'fields': {
        'COMMAND': 'BLNS_DIF_CMD_CMD', 'NPARAM': 'BLNS_DIF_CMD_NPARAM'}},
    'reg_dif_status': {'cover': ['BLNS_DIF_STATUS_'], 'fields': {
        'BUSY': 'BLNS_DIF_STATUS_BUSY', 'CMD_PENDING': 'BLNS_DIF_STATUS_CMD_PENDING',
        'PARAM_FULL': 'BLNS_DIF_STATUS_PARAM_FULL', 'REFRESH_BUSY': 'BLNS_DIF_STATUS_REFRESH_BUSY',
        'WAIT_SYNC': 'BLNS_DIF_STATUS_WAIT_SYNC', 'DFILL_BUSY': 'BLNS_DIF_STATUS_DFILL_BUSY',
        'DFILL_PENDING': 'BLNS_DIF_STATUS_DFILL_PEND', 'PARAM_OVFL': 'BLNS_DIF_STATUS_PARAM_OVFL',
        'PARAM_LEVEL': 'BLNS_DIF_STATUS_PARAM_LEVEL'}},
    # --- DPI driver ---------------------------------------------------------
    'reg_dpi_cfg': {'cover': ['BLNS_DPI_CFG_'], 'fields': {
        'LCD_ON': 'BLNS_DPI_CFG_LCD_ON', 'LCD_RESET': 'BLNS_DPI_CFG_LCD_RESET', 'DPI_EN': 'BLNS_DPI_CFG_EN',
        'CLK_DIV': 'BLNS_DPI_CFG_CLK_DIV', 'PCLK_EDGE': 'BLNS_DPI_CFG_PCLK_EDGE',
        'HS_POL': 'BLNS_DPI_CFG_HS_POL', 'VS_POL': 'BLNS_DPI_CFG_VS_POL', 'DE_POL': 'BLNS_DPI_CFG_DE_POL',
        'BGR': 'BLNS_DPI_CFG_BGR', 'FILTER': 'BLNS_DPI_CFG_FILTER'}},
    'reg_dpi_status': {'cover': ['BLNS_DPI_STATUS_'], 'fields': {
        'BUSY': 'BLNS_DPI_STATUS_BUSY', 'REFRESH_BUSY': 'BLNS_DPI_STATUS_REFRESH_BUSY',
        'VBLANK': 'BLNS_DPI_STATUS_VBLANK', 'PRESENT': 'BLNS_DPI_STATUS_PRESENT', 'LINE': 'BLNS_DPI_STATUS_LINE'}},
    'reg_dpi_blank': {'cover': ['BLNS_DPI_BLANK_'], 'fields': {
        'FRONT PORCH': 'BLNS_DPI_BLANK_FP', 'SYNC WIDTH': 'BLNS_DPI_BLANK_SYNC', 'BACK PORCH': 'BLNS_DPI_BLANK_BP'}},
    'reg_dpi_ctrl': {'cover': ['BLNS_DPI_CTRL_'], 'fields': {
        'UPDATE': 'BLNS_DPI_CTRL_UPDATE', 'TEST': 'BLNS_DPI_CTRL_TEST'}},
    'reg_dpi_caps': {'cover': ['BLNS_DPI_CAPS_'], 'fields': {
        'DPI_LB_AW': 'BLNS_DPI_CAPS_LB_AW', 'DPI_SCALER': 'BLNS_DPI_CAPS_SCALER',
        'PCLK_SEP': 'BLNS_DPI_CAPS_PCLK_SEP', 'TMDS': 'BLNS_DPI_CAPS_TMDS', 'DDC': 'BLNS_DPI_CAPS_DDC',
        'ISLAND': 'BLNS_DPI_CAPS_ISLAND', 'AUDIO': 'BLNS_DPI_CAPS_AUDIO'}},
    'reg_dpi_hdmi': {'cover': ['BLNS_DPI_HDMI_'], 'fields': {
        'HDMI': 'BLNS_DPI_HDMI_EN', 'AVI': 'BLNS_DPI_HDMI_AVI', 'AUD': 'BLNS_DPI_HDMI_AUD',
        'GP': 'BLNS_DPI_HDMI_GP', 'PICTURE': 'BLNS_DPI_HDMI_PICTURE', 'QUANT': 'BLNS_DPI_HDMI_QUANT',
        'ACTIVE': 'BLNS_DPI_HDMI_ACTIVE',
        'VIC': 'BLNS_DPI_HDMI_VIC'}},
    # --- GPU ----------------------------------------------------------------
    'reg_gpu_stat': {'cover': ['BLNS_GPU_STAT_'], 'fields': {
        'FREE': 'BLNS_GPU_STAT_FREE', 'USED': 'BLNS_GPU_STAT_USED', 'EMPTY': 'BLNS_GPU_STAT_EMPTY',
        'FULL': 'BLNS_GPU_STAT_FULL', 'WAIT': 'BLNS_GPU_STAT_WAIT', 'PRIM_BUSY': 'BLNS_GPU_STAT_PRIM_BUSY',
        'BUSY': 'BLNS_GPU_STAT_BUSY', 'ERR': 'BLNS_GPU_STAT_ERR', 'HELD': 'BLNS_GPU_STAT_HELD',
        'LIST': 'BLNS_GPU_STAT_LIST', 'ERR_CAUSE': 'BLNS_GPU_STAT_ERR_CAUSE',
        'ERR_OPCODE': 'BLNS_GPU_STAT_ERR_OPCODE'}},
    'reg_gpu_cmd_surface': {'cover': [], 'fields': {
        'PITCH (0 = frame width)': 'BLNS_GPU_PITCH', 'SRC_FMT': 'BLNS_GPU_SRC_FMT', 'IMM': 'BLNS_GPU_SRC_IMM',
        '0x1': ('const', 'BLNS_GPU_OP_SET_SRC', OP)}},
    'reg_gpu_cmd_dst': {'cover': [], 'fields': {
        'PITCH (0 = frame width)': 'BLNS_GPU_PITCH', 'XY': 'BLNS_GPU_DST_XY',
        '0x2': ('const', 'BLNS_GPU_OP_SET_DST', OP)}},
    'reg_gpu_cmd_size': {'cover': ['BLNS_GPU_SIZE_'], 'fields': {
        'WIDTH': 'BLNS_GPU_SIZE_W', 'HEIGHT': 'BLNS_GPU_SIZE_H',
        '0x3': ('const', 'BLNS_GPU_OP_SET_SIZE', OP)}},
    'reg_gpu_cmd_span': {'cover': ['BLNS_GPU_SPAN_'], 'fields': {
        'WIDTH': 'BLNS_GPU_SPAN_W', 'DELTA (signed)': 'BLNS_GPU_SPAN_DELTA',
        '0xB': ('const', 'BLNS_GPU_OP_EXEC_SPAN', OP)}},
    'reg_gpu_cmd_texspan': {'cover': [], 'fields': {
        'N': 'BLNS_GPU_SPAN_W',                     # EXEC_TEXSPAN [13:0] N: the span width field
        'DELTA (signed)': 'BLNS_GPU_SPAN_DELTA',
        '0xD': ('const', 'BLNS_GPU_OP_EXEC_TEXSPAN', OP)}},
    'reg_gpu_cmd_exec': {'cover': ['BLNS_GPU_EXEC_'], 'fields': {
        'PX_OP': 'BLNS_GPU_EXEC_ROP',
        'D.CL': ('expr', SW_D.format('CL')), 'D.Y': ('expr', SW_D.format('Y')), 'D.X': ('expr', SW_D.format('X')),
        'TRI (FILL)': 'BLNS_GPU_EXEC_TRI',
        'S.CL': ('expr', SW_S.format('CL')), 'S.Y': ('expr', SW_S.format('Y')), 'S.X': ('expr', SW_S.format('X')),
        'MPLANE (COPY)': 'BLNS_GPU_EXEC_MPLANE', 'REMAP': 'BLNS_GPU_EXEC_REMAP', 'LINE (FILL)': 'BLNS_GPU_EXEC_LINE',
        '0x8/9/A': ('consts', ['BLNS_GPU_OP_EXEC_FILL', 'BLNS_GPU_OP_EXEC_COPY', 'BLNS_GPU_OP_EXEC_COPY_TRANSP'], OP)}},
    'reg_gpu_cmd_expand': {'cover': ['BLNS_GPU_EXP_'], 'fields': {
        'OPQ': 'BLNS_GPU_EXP_OPAQUE', 'MASK': 'BLNS_GPU_EXP_MASK',
        'D.CL': ('expr', SW_D.format('CL')), 'D.Y': ('expr', SW_D.format('Y')), 'D.X': ('expr', SW_D.format('X')),
        'ROP': 'BLNS_GPU_EXP_ROP', 'REMAP': 'BLNS_GPU_EXEC_REMAP', 'DELTA (signed)': 'BLNS_GPU_SPAN_DELTA',
        '0xC': ('const', 'BLNS_GPU_OP_EXEC_EXPAND', OP)}},
    'reg_gpu_cmd_settex': {'cover': ['BLNS_GPU_TEX_'], 'fields': {
        'log2 W': 'BLNS_GPU_TEX_L2W', 'log2 H': 'BLNS_GPU_TEX_L2H', 'TR': 'BLNS_GPU_TEX_TRANSP',
        'D.CL': ('expr', SW_T.format('CL')), 'D.Y': ('expr', SW_T.format('Y')), 'D.X': ('expr', SW_T.format('X')),
        'FP': 'BLNS_GPU_TEX_FREE_PITCH', 'BOUND': 'BLNS_GPU_TEX_BOUND', 'REMAP': 'BLNS_GPU_TEX_REMAP',
        'SHADE': 'BLNS_GPU_TEX_SHADE',
        '0 (TEX)': ('const', 'BLNS_GPU_EXT_TEX'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_aux_mask': {'cover': ['BLNS_GPU_AUX_'], 'fields': {
        'PITCH (0 only)': 'BLNS_GPU_PITCH', 'INV': 'BLNS_GPU_AUX_INV',
        'SEL = 1': ('const', 'BLNS_GPU_AUX_MASK_PLANE', 'BLNS_GPU_AUX_SEL'),
        '13 (AUX)': ('const', 'BLNS_GPU_EXT_AUX'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_aux_alpha': {'cover': [], 'fields': {
        'PITCH (0 only)': 'BLNS_GPU_PITCH',
        'SEL = 4': ('const', 'BLNS_GPU_AUX_ALPHA_PLANE', 'BLNS_GPU_AUX_SEL'),
        '13 (AUX)': ('const', 'BLNS_GPU_EXT_AUX'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_aux_filter': {'cover': ['BLNS_GPU_AUX_BILINEAR', 'BLNS_GPU_AUX_TBORDER'], 'fields': {
        'BILINEAR': 'BLNS_GPU_AUX_BILINEAR', 'TBORDER': 'BLNS_GPU_AUX_TBORDER',
        'SEL = 5': ('const', 'BLNS_GPU_AUX_TEX_FILTER', 'BLNS_GPU_AUX_SEL'),
        '13 (AUX)': ('const', 'BLNS_GPU_EXT_AUX'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_alpha': {'cover': ['BLNS_GPU_ALPHA_'], 'fields': {
        'A': ('waive', 'no field macro: the low byte of the word (blns_gpu_alpha)'),
        'EN': 'BLNS_GPU_ALPHA_EN', 'MIX5': 'BLNS_GPU_ALPHA_MIX5',
        '8 (ALPHA)': ('const', 'BLNS_GPU_EXT_ALPHA'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_aux_remap': {'cover': [], 'fields': {
        'SEL = 0': ('const', 'BLNS_GPU_AUX_REMAP_TABLE', 'BLNS_GPU_AUX_SEL'),
        '13 (AUX)': ('const', 'BLNS_GPU_EXT_AUX'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_xy': {'cover': ['BLNS_GPU_XY_'], 'fields': {
        'X (signed)': 'BLNS_GPU_XY_X', 'Y (signed)': 'BLNS_GPU_XY_Y',
        '3 (XY)': ('const', 'BLNS_GPU_EXT_XY'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_clip': {'cover': ['BLNS_GPU_XY_'], 'fields': {
        'X0 (signed)': 'BLNS_GPU_XY_X', 'Y0 (signed)': 'BLNS_GPU_XY_Y',
        '4 (CLIP)': ('const', 'BLNS_GPU_EXT_CLIP'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_grad': {'cover': ['BLNS_GPU_GRAD_'], 'fields': {
        'N': 'BLNS_GPU_GRAD_N', 'AXIS': 'BLNS_GPU_GRAD_AXIS', 'STEP (signed)': 'BLNS_GPU_GRAD_STEP',
        'EN': 'BLNS_GPU_GRAD_EN', 'RGB': 'BLNS_GPU_GRAD_RGB',
        '7 (GRAD)': ('const', 'BLNS_GPU_EXT_GRAD'), '0x6': ('const', 'BLNS_GPU_OP_SET_EXT', OP)}},
    'reg_gpu_cmd_texrect': {'cover': [], 'fields': {
        'TRI': 'BLNS_GPU_EXEC_TRI', 'DELTA (signed)': 'BLNS_GPU_SPAN_DELTA',
        '0xE': ('const', 'BLNS_GPU_OP_EXEC_TEXRECT', OP)}},
    'reg_gpu_cmd_call': {'cover': [], 'fields': {
        'N (list length in words)': ('expr', 'BLNS_GPU_CALL_N_MAX'),
        'OP = 0x7': ('const', 'BLNS_GPU_OP_CALL', OP)}},
    'reg_gpu_cmd_fence': {'cover': ['BLNS_GPU_FENCE_'], 'fields': {
        'TAG': 'BLNS_GPU_FENCE_TAG', 'IRQ': 'BLNS_GPU_FENCE_IRQ', 'AUTO': 'BLNS_GPU_FENCE_AUTO',
        '0xF': ('const', 'BLNS_GPU_OP_FENCE', OP)}},
}


# ---------------------------------------------------------------------------
# Header: object-like #defines, evaluated on demand
# ---------------------------------------------------------------------------
def read_header(path):
    defs = {}
    text = open(path).read()
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'\\\n', ' ', text)                          # continued lines
    for line in text.splitlines():
        m = re.match(r'\s*#define\s+(BLNS_\w+)(\(?)\s*(.*)$', line)
        if not m or m.group(2) == '(':          # function-like macros skipped
            continue
        defs[m.group(1)] = m.group(3).strip()
    return defs


class Macros:
    def __init__(self, defs):
        self.defs = defs
        self.cache = {}

    def has(self, name):
        return name in self.defs

    def value(self, name):
        if name not in self.cache:
            body = self.defs[name]
            body = re.sub(r'\(\s*u?int\d+_t\s*\)', '', body)          # casts
            body = re.sub(r'\b(0x[0-9A-Fa-f]+|\d+)[uU][lL]*\b', r'\1', body)
            self.cache[name] = self.eval(body)
        return self.cache[name]

    def eval(self, expr):
        names = set(re.findall(r'\bBLNS_\w+\b', expr)) - {'BLNS_FIELD'}
        env = {'BLNS_FIELD': lambda pos, width: ((1 << width) - 1) << pos}
        for n in names:
            env[n] = self.value(n)
        return eval(expr, {'__builtins__': {}}, env)


# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------
def read_figure(path):
    """A WaveDrom source is a JavaScript object literal: quote the bare keys
    (after '{' or ',') and turn the single-quoted strings into JSON ones."""
    src = open(path).read()
    src = re.sub(r"'((?:[^'\\]|\\.)*)'", lambda m: json.dumps(m.group(1)), src)
    src = re.sub(r'([{,]\s*)([A-Za-z_]\w*)\s*:', r'\1"\2":', src)
    return json.loads(src)


def svg_texts(path):
    svg = open(path).read()
    return {html.unescape(re.sub(r'<[^>]*>', '', t)) for t in re.findall(r'<text[^>]*>(.*?)</text>', svg, re.S)}


def first_number(label):
    m = re.search(r'0x[0-9A-Fa-f]+|\d+', label)
    return int(m.group(0), 0) if m else None


def main():
    verbose = '-v' in sys.argv[1:]
    mac = Macros(read_header(HEADER))
    errors = []
    infos = []

    def err(fig, msg):
        errors.append('{}: {}'.format(fig, msg))

    def field_mask(fig, base):
        """Mask (and whether its width is known) of a field macro base."""
        if mac.has(base + '_Msk'):
            return mac.value(base + '_Msk'), True
        if mac.has(base + '_Pos'):
            return 1 << mac.value(base + '_Pos'), False
        if mac.has(base):
            return mac.value(base), True
        err(fig, 'no macro {}_Msk, {}_Pos or {}'.format(base, base, base))
        return None, False

    paths = sorted(glob.glob(os.path.join(IMG, 'reg_*.json')))
    for path in paths:
        fig = os.path.splitext(os.path.basename(path))[0]
        spec = FIGURES.get(fig)
        if spec is None:
            err(fig, 'not in the FIGURES table of {}'.format(os.path.basename(__file__)))
            continue
        try:
            reg = read_figure(path)
        except ValueError as e:
            err(fig, 'cannot parse: {}'.format(e))
            continue
        width = reg.get('config', {}).get('bits', 32)
        lsb = 0
        named = 0
        seen = set()
        for cell in reg['reg']:
            bits = cell['bits']
            mask = ((1 << bits) - 1) << lsb
            name = cell.get('name')
            if name is not None:
                named |= mask
                seen.add(name)
                entry = spec['fields'].get(name)
                where = '[{}:{}] {!r}'.format(lsb + bits - 1, lsb, name)
                if entry is None:
                    err(fig, '{}: no entry in FIGURES (a header field name?)'.format(where))
                elif isinstance(entry, str) or entry[0] == 'expr':
                    if isinstance(entry, str):
                        m, full = field_mask(fig, entry)
                    else:
                        m, full = mac.eval(entry[1]), True
                    if m is not None:
                        if full and m != mask:
                            err(fig, '{}: figure 0x{:08X}, header {} 0x{:08X}'.format(where, mask, entry, m))
                        elif not full and (m & -m) != (mask & -mask):
                            err(fig, '{}: figure lsb {}, header {} lsb {}'.format(
                                where, lsb, entry, (m & -m).bit_length() - 1))
                        elif not full:
                            infos.append('{}: {} position only (no _Msk)'.format(fig, where))
                elif entry[0] in ('const', 'consts'):
                    vals = ([first_number(name)] if entry[0] == 'const'
                            else [int(d, 16) for d in name.split('/')])
                    cmacs = [entry[1]] if entry[0] == 'const' else entry[1]
                    for cm, v in zip(cmacs, vals):
                        if not mac.has(cm):
                            err(fig, '{}: no macro {}'.format(where, cm))
                        elif mac.value(cm) != (v << lsb):
                            err(fig, '{}: {} = 0x{:08X}, figure {} << {}'.format(where, cm, mac.value(cm), v, lsb))
                    if len(entry) > 2:
                        m, full = field_mask(fig, entry[2])
                        if m is not None and ((full and m != mask) or (m & -m) != (mask & -mask)):
                            err(fig, '{}: field {} 0x{:08X}, figure 0x{:08X}'.format(where, entry[2], m, mask))
                elif entry[0] == 'waive':
                    infos.append('{}: {} not checked: {}'.format(fig, where, entry[1]))
            lsb += bits
        if lsb != width:
            err(fig, 'fields add up to {} bits, not {}'.format(lsb, width))
        for name in set(spec['fields']) - seen:
            err(fig, 'table entry {!r} is not in the figure'.format(name))
        # every _Msk macro of the register lies on named fields
        for prefix in spec['cover']:
            for name in sorted(mac.defs):
                if name.startswith(prefix) and name.endswith('_Msk'):
                    m = mac.value(name)
                    if m & ~named:
                        err(fig, '{} = 0x{:08X} has bits 0x{:08X} outside the named fields'.format(
                            name, m, m & ~named))
        # rendered from this JSON
        svg = os.path.join(IMG, fig + '.svg')
        if not os.path.isfile(svg):
            err(fig, 'no {}.svg (python3 doc/img/render.py {}.json)'.format(fig, fig))
        else:
            texts = svg_texts(svg)
            for cell in reg['reg']:
                if 'name' in cell and cell['name'] not in texts:
                    err(fig, '{}.svg lacks {!r}: re-render it (python3 doc/img/render.py {}.json)'.format(
                        fig, cell['name'], fig))

    # every figure is used
    md = ''
    for p in glob.glob(os.path.join(ROOT, '**', '*.md'), recursive=True):
        if 'private' not in os.path.relpath(p, ROOT).split(os.sep):   # doc/private (also under a /private/... checkout)
            md += open(p).read()
    for path in paths:
        fig = os.path.splitext(os.path.basename(path))[0]
        if 'img/{}.svg'.format(fig) not in md:
            err(fig, 'referenced by no Markdown file')

    if verbose:
        for i in infos:
            print('  info  ' + i)
    for e in errors:
        print('  ERROR ' + e)
    print('{} register figures, {} errors'.format(len(paths), len(errors)))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
