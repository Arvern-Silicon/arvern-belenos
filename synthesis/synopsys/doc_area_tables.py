#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    doc_area_tables
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : doc_area_tables.py
# Module Description : Render Markdown area tables (kGates per block) from the
#                      results_sweep/<label>/report.area_analysis.txt files.
#----------------------------------------------------------------------------
"""Render the belenos area tables from synthesis results.

    ./run_syn -rtl_sweep                          # in the Synopsys container (or a
                                                  # local Docker driver, run_syn_d:
                                                  # git-ignored, not in the repository)
    python3 doc_area_tables.py                    # the five personas
    python3 doc_area_tables.py dif0 dif3 gpu0     # any labels
    python3 doc_area_tables.py --all              # every config in results_sweep/
    python3 doc_area_tables.py --features         # cost of each feature (config differences)

Columns are configs (looked up by label in results_sweep/<label>/, the
directory run_syn writes; --all orders them as rtl_configs.py does, then any
other labels such as <label>_sync), rows are the report_area.tcl blocks in
kGates (NAND2 equivalent / 1000). Directories starting with '_' (e.g. the
_stale/ archive) are ignored.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SWEEP = os.path.join(HERE, 'results_sweep')
sys.path.insert(0, os.path.join(HERE, '..', '..', 'sim', 'rtl_sim', 'bin'))
import rtl_configs  # noqa: E402
ROW_RE = re.compile(r'^([A-Za-z][^|\n]*?)\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*[\d.]+%\s*\|\s*(\d+)', re.M)


def load(path):
    t = open(path).read()
    rows = [(m.group(1).strip(), int(m.group(2)), int(m.group(3))) for m in ROW_RE.finditer(t)]
    get = lambda pat: int(re.search(pat, t).group(1))
    return {
        'rows': [r for r in rows if not r[0].startswith('TOTAL')],
        'total': get(r'Total NAND2 equivalent:\s*(\d+)'),
        'comb': get(r'Combinational:\s*(\d+)'),
        'seq': get(r'Sequential:\s*(\d+)'),
        'flops': get(r'flops\):\s*(\d+)'),
    }


def find_results():
    """{label: report path} for every results_sweep/<label>/ with an area report."""
    by_label = {}
    for d in glob.glob(os.path.join(SWEEP, '*')):
        label = os.path.basename(d)
        rep = os.path.join(d, 'report.area_analysis.txt')
        if label.startswith('_') or not os.path.exists(rep):
            continue
        by_label[label] = rep
    return by_label


def config_order(labels):
    """Labels in rtl_configs.py order, then the others (retired, _sync) by name."""
    rank = {label: i for i, (label, _) in enumerate(rtl_configs.CONFIGS)}
    return sorted(labels, key=lambda l: (rank.get(l, len(rank)), l))


# The area ladder, without a display driver (DIF_TYPE 0): light to ultra, one
# feature added at each step (each label is the previous one plus that
# feature, rtl_configs.AREA_STEPS; dif0 is classic); the cost of a step is the
# difference of the two totals, all from the same sweep
LADDER = [
    ("**`light` persona**: display controller, one LUT bank", "light_bdi"),
    ("second LUT bank (`LUT_BANKS` = 2)", "lut2_bdi"),
    ("GPU (`GPU_EN`): fills, copies, spans, colour expansion, textured spans, command lists: **`essential` persona**", "gpu_bdi"),
    ("x/y coordinates, clip window and affine blit (`GPU_XY_EN`)", "xy_bdi"),
    ("gradient fill (`GPU_GRAD_EN`)", "grad_bdi"),
    ("lines and dashes (`GPU_LINE_EN`)", "line_bdi"),
    ("palette remap (`GPU_REMAP_EN`)", "remap_bdi"),
    ("mask plane (`GPU_MPLANE_EN`)", "mplane_bdi"),
    ("immediate source (`GPU_IMM_EN`)", "imm_bdi"),
    ("hardware cursor (`CURSOR_EN`): **`classic` persona**", "dif0"),
    ("alpha blending (`GPU_BLEND_EN`)", "blend_bdi"),
    ("command FIFO of 16 words (`GPU_FIFO_AW` = 4)", "fifo16_bdi"),
    ("run-ahead (`GPU_RUNAHEAD_EN`)", "runahead_bdi"),
    ("bilinear sampling (`GPU_BILINEAR_EN`): **`performance` persona**", "performance_bdi"),
    ("triangles (`GPU_TRI_EN`)", "tri_bdi"),
    ("command FIFO of 32 words (`GPU_FIFO_AW` = 5): **`ultra` persona**", "ultra_bdi"),
]

# The personas of the block table: (column, label), without a display driver
PERSONA_COLS = [("light", "light_bdi"), ("essential", "gpu_bdi"), ("classic", "dif0"),
                ("performance", "performance_bdi"), ("ultra", "ultra_bdi")]

# The display drivers, on classic: (driver, its build, the build it adds to).
# A row whose base is dif0 is the whole driver; the others are an option of it
DRIVERS = [
    ("DBI over SPI (`DIF_TYPE` 1)", "dif1", "dif0"),
    ("DBI over the 8080 bus (`DIF_TYPE` 2, the default)", "classic", "dif0"),
    ("DBI, both buses and the PHY select (`DIF_TYPE` 3)", "dif3", "dif0"),
    ("DPI without a scaler (`DIF_TYPE` 4, `DPI_SCALER` 0)", "dif4_noscale", "dif0"),
    ("DPI, nearest-neighbour scaler (`DPI_SCALER` 1, the default)", "dif4", "dif0"),
    ("DPI, nearest and bilinear scaler (`DPI_SCALER` 2)", "dif4_bilinear", "dif0"),
    ("+ panel timing on its own pixel clock (`DPI_PCLK_SEP` 1)", "dif4_pclk", "dif4_bilinear"),
    ("HDMI without DDC nor data islands (`DIF_TYPE` 5, `DPI_DDC_EN` 0, `DPI_ISLAND_EN` 0)", "dif5_noddc", "dif0"),
    ("HDMI with DDC and data islands (the defaults)", "dif5", "dif0"),
    ("+ panel timing on its own pixel clock (`DPI_PCLK_SEP` 1)", "hdmi_pclk", "dif5"),
    ("+ audio (`DPI_AUDIO_EN` 1)", "dif5_audio", "hdmi_pclk"),
]


def features(found):
    need = sorted(({l for _, l in LADDER} | {l for _, a, b in DRIVERS for l in (a, b)}) - set(found))
    if need:
        sys.exit(f"doc_area_tables.py: no results for {need}")
    tot = {l: load(found[l])['total'] for l in found}
    k = lambda g: f"{g / 1000.0:.1f}"
    d = lambda a, b: f"{(tot[a] - tot[b]) / 1000.0:+.1f}"
    print("| Step | Adds (kGates) | Total (kGates) |")
    print("|---|---:|---:|")
    prev = None
    for name, l in LADDER:
        print(f"| {name} | {'—' if prev is None else d(l, prev)} | {k(tot[l])} |")
        prev = l
    print()
    print("| Display driver | Adds (kGates) |")
    print("|---|---:|")
    for name, a, b in DRIVERS:
        print(f"| {name} | {d(a, b)} |")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    found = find_results()
    if '--features' in sys.argv:
        features(found)
        return
    if '--all' in sys.argv:
        labels = config_order(found)
    else:
        labels = args or [l for _, l in PERSONA_COLS]
    missing = [l for l in labels if l not in found]
    if missing:
        sys.exit(f"doc_area_tables.py: no results_sweep/<label>/report.area_analysis.txt for {missing}")
    data = {l: load(found[l]) for l in labels}

    k = lambda g: f"{g / 1000.0:.1f}"
    names = [r[0] for r in data[labels[0]]['rows']]
    head = dict((l, c) for c, l in PERSONA_COLS)
    print("| Block | " + " | ".join(head.get(l, l) for l in labels) + " |")
    print("|---|" + "---:|" * len(labels))
    for i, name in enumerate(names):
        if all(data[l]['rows'][i][1] == 0 for l in labels):
            continue                    # a block absent from every column (the display driver)
        print(f"| {name} | " + " | ".join(k(data[l]['rows'][i][1]) for l in labels) + " |")
    print("| **Total (kGates)** | " + " | ".join(f"**{k(data[l]['total'])}**" for l in labels) + " |")
    print("| Combinational | " + " | ".join(k(data[l]['comb']) for l in labels) + " |")
    print("| Sequential | " + " | ".join(k(data[l]['seq']) for l in labels) + " |")
    print("| Flop count | " + " | ".join(f"{data[l]['flops']:,}" for l in labels) + " |")


if __name__ == '__main__':
    main()
