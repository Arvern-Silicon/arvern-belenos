#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    cov_const_cfg.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
"""Repository-specific settings of cov_const.py (belenos).

TOP                 top module elaborated by Yosys
rtl_files()         RTL sources, absolute paths (filelist.f, nested -f followed)
coverage_configs()  [(label, {PARAM: value})] -- every DUT parameterisation the
                    coverage sweep builds (runcov: bin/test_config.py, mode
                    COV_MODE, default all); a bit is waived only if it is
                    constant in all of them. Bench-only switches (ICG_EN) are
                    dropped; VRAM_AW is derived by the RTL.
"""
import os

_BIN = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.normpath(os.path.join(_BIN, '..', '..', '..', 'rtl', 'verilog'))

TOP = 'belenos'


def _read(flist):
    out, base = [], os.path.dirname(flist)
    for l in open(flist):
        l = l.strip()
        if not l or l.startswith('//') or l.startswith('+'):
            continue
        if l.startswith('-f'):
            out += _read(os.path.normpath(os.path.join(base, l[2:].strip())))
        elif not l.startswith('-'):
            out.append(os.path.normpath(os.path.join(base, l)))
    return out


def rtl_files():
    return _read(os.path.join(RTL_DIR, 'filelist.f'))


def coverage_configs():
    import sys
    sys.path.insert(0, _BIN)
    import test_config
    seen, out = set(), []
    for label, params, tests in test_config.sweep(os.environ.get('COV_MODE', 'all')):
        if not tests:
            continue
        p = {k: v for k, v in params.items()
             if not test_config.PARAMS[k].get('bench_only')}
        key = tuple(sorted(p.items()))
        if key not in seen:
            seen.add(key)
            out.append((label, p))
    return out
