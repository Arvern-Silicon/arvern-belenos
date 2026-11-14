#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    gen_rtl_params
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : gen_rtl_params.py
# Module Description : Generate rtl_params.tcl for one belenos RTL config of
#                      sim/rtl_sim/bin/rtl_configs.py (label or 1-based index).
#----------------------------------------------------------------------------
"""
Generate the synthesis rtl_params.tcl for one belenos configuration.

The configuration set is sim/rtl_sim/bin/rtl_configs.py -- the same one the
simulation sweep, the Verilator lint sweep and VC Static use -- so a config
label means the same netlist to every flow. The RTL defaults are read from the
top module (rtl/verilog/belenos.v); the config's overrides are applied on top.

Output (rtl_params.tcl):
    RTL_CONFIG_LABEL      label of the selected config
    RTL_PARAM_<NAME>      one per top-level parameter (default or override)
    ELABORATE_PARAMS      -parameters string for `elaborate`, overridden
                          parameters only (as ${RTL_PARAM_<NAME>} references,
                          so a later edit of one RTL_PARAM_ line is what gets
                          elaborated); "" for the RTL defaults

Usage:
    python3 gen_rtl_params.py [--rtl-config LABEL|N] [--with-sync-reset] [--output PATH]
    python3 gen_rtl_params.py --list-configs
    python3 gen_rtl_params.py --index-of LABEL|N
"""

import argparse
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT  = (SCRIPT_DIR / '..' / '..').resolve()
sys.path.insert(0, str(REPO_ROOT / 'sim' / 'rtl_sim' / 'bin'))
import rtl_configs  # noqa: E402

TOP_MODULE = getattr(rtl_configs, 'TOP_MODULE', 'belenos')
CONFIGS    = rtl_configs.CONFIGS
# The synthesis-only area steps, numbered after the configs (not in -list_configs)
ALL        = CONFIGS + list(getattr(rtl_configs, 'AREA_STEPS', []))
RTL_TOP    = REPO_ROOT / 'rtl' / 'verilog' / f'{TOP_MODULE}.v'


def verilog_int(text):
    """Decimal value of a Verilog integer literal (plain or sized based)."""
    t = text.strip().replace('_', '')
    m = re.fullmatch(r"(?:\d+)?'([bBdDhHoO])([0-9a-fA-FxXzZ]+)", t)
    if m:
        base = {'b': 2, 'd': 10, 'h': 16, 'o': 8}[m.group(1).lower()]
        return int(m.group(2), base)
    return int(t)


# Parameters whose default is an expression of other parameters (not set by configs)
DERIVED = {
    'VRAM_AW': lambda p: max(1, (int(p['VRAM_WORDS']) - 1).bit_length()),   # ceil(log2), at least 1
}


def rtl_defaults():
    """Ordered {name: value} of the top module's parameter defaults."""
    try:
        # Explicit UTF-8: the Python of the synthesis container defaults to ASCII.
        src = RTL_TOP.read_text(encoding='utf-8')
    except OSError as exc:
        sys.exit(f"gen_rtl_params.py: cannot read {RTL_TOP}: {exc}")
    m = re.search(r'module\s+' + TOP_MODULE + r'\s*#\s*\((.*?)\)\s*\(', src, re.S)
    if not m:
        sys.exit(f"gen_rtl_params.py: no parameter list found for module {TOP_MODULE}")
    params = {}
    for line in m.group(1).splitlines():
        code = line.split('//', 1)[0]
        p = re.search(r'parameter\s+(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^,]+)', code)
        if p and p.group(1) in DERIVED:
            params[p.group(1)] = None
        elif p:
            params[p.group(1)] = verilog_int(p.group(2))
    return params


def resolve(sel):
    """(index, label, overrides) for a 1-based index or a config label."""
    if sel is None:
        sel = '1'
    if str(sel).isdigit():
        i = int(sel)
        if not 1 <= i <= len(ALL):
            sys.exit(f"gen_rtl_params.py: --rtl-config {i} out of range (valid: 1..{len(ALL)})")
        return (i,) + tuple(ALL[i - 1])
    for i, (label, ov) in enumerate(ALL, 1):
        if label == sel:
            return i, label, ov
    known = ', '.join(lbl for lbl, _ in ALL)
    sys.exit(f"gen_rtl_params.py: unknown config '{sel}' (known: {known})")


def generate_tcl(label, overrides, output_path, with_sync_reset=False):
    defaults = rtl_defaults()
    ov = dict(overrides)
    if with_sync_reset:
        ov['ASYNC_RST_EN'] = 0
    unknown = sorted(set(ov) - set(defaults))
    if unknown:
        sys.exit(f"gen_rtl_params.py: config '{label}' overrides unknown parameter(s) {unknown}")

    lines = [
        "##############################################################################",
        "#                                                                            #",
        "#                  RTL PARAMETERS FROM rtl_configs.py                        #",
        "#                                                                            #",
        "#  Auto-generated by gen_rtl_params.py -- do not edit.                       #",
        "#  Source: sim/rtl_sim/bin/rtl_configs.py over the defaults of belenos.v     #",
        "#                                                                            #",
        "##############################################################################",
        "",
        f'set RTL_CONFIG_LABEL "{label}{" (sync reset)" if with_sync_reset else ""}"',
        "",
    ]
    eff = dict(defaults, **ov)
    for name, dflt in defaults.items():
        if dflt is None:
            lines.append(f"# (derived from the other parameters)")
            lines.append(f"set RTL_PARAM_{name} {DERIVED[name](eff)}")
        elif name in ov:
            lines.append(f"# (config override, RTL default={dflt})")
            lines.append(f"set RTL_PARAM_{name} {ov[name]}")
        else:
            lines.append(f"set RTL_PARAM_{name} {dflt}")
    lines.append("")
    lines.append("# elaborate -parameters string: overridden parameters only")
    if ov:
        assigns = ','.join(f"{k}=${{RTL_PARAM_{k}}}" for k in sorted(ov))
        lines.append(f'set ELABORATE_PARAMS "-parameters \\"{assigns}\\""')
    else:
        lines.append('set ELABORATE_PARAMS ""')
    lines.append("")
    Path(output_path).write_text('\n'.join(lines))

    print(f"Generated: {output_path}  (config: {label})")
    for name, dflt in defaults.items():
        tag = f"  (override, default={dflt})" if name in ov else ""
        print(f"  {name:18s} = {ov.get(name, dflt)}{tag}")


def main():
    ap = argparse.ArgumentParser(description='Generate rtl_params.tcl for one belenos RTL config')
    ap.add_argument('--rtl-config', metavar='LABEL_OR_N',
                    help='config label or 1-based index from sim/rtl_sim/bin/rtl_configs.py '
                         '(default: 1 = "default", the RTL defaults)')
    ap.add_argument('--with-sync-reset', action='store_true',
                    help='force ASYNC_RST_EN=0 on top of the selected config')
    ap.add_argument('--output', default=str(SCRIPT_DIR / 'rtl_params.tcl'),
                    help='output TCL file (default: ./rtl_params.tcl)')
    ap.add_argument('--list-configs', action='store_true',
                    help='print "<idx>\\t<label>\\t<overrides>" for every config and exit')
    ap.add_argument('--index-of', metavar='LABEL_OR_N',
                    help='print "<idx>\\t<label>" for one config and exit (validation helper)')
    args = ap.parse_args()

    if args.list_configs:
        print(f"# belenos RTL config set ({len(CONFIGS)} configs, sim/rtl_sim/bin/rtl_configs.py)")
        for i, (label, ov) in enumerate(CONFIGS, 1):
            desc = ' '.join(f"{k}={v}" for k, v in sorted(ov.items())) or '(RTL defaults)'
            print(f"{i}\t{label}\t{desc}")
        return
    if args.index_of is not None:
        i, label, _ = resolve(args.index_of)
        print(f"{i}\t{label}")
        return

    _, label, ov = resolve(args.rtl_config)
    generate_tcl(label, ov, args.output, args.with_sync_reset)


if __name__ == '__main__':
    main()
