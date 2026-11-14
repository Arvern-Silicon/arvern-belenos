#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    check_deployed.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Compare the deployed builds of rtl_configs.DEPLOYED with the Belenos
# instance parameters of the boards in arvern-soc (checked out next to this
# repository). Each board file sets BLNS_<P> parameters, some of them derived
# from BOARD_* parameters by a ternary; the BOARD_* values of each deployed
# build are given below.
#
# Then compare each board's driver platform header (bsp/<board>_blns.h, the
# BLNS_HW_* macros of sw/include/belenos_hw.h) with the same parameters: a
# feature the header states (0 or 1) must be what every build of that board
# has (one Tang firmware runs on the panel and the HDMI bitstreams, so a
# feature that differs between them must stay undefined, detected at run
# time). blns_init() makes the same check on the hardware (BLNS_ERR_CONFIG).
#
#   check_deployed.py [--soc PATH]   exit 0: all match (or arvern-soc absent,
#                                    with a note); 1: a mismatch
#----------------------------------------------------------------------------

import argparse
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import rtl_configs                                             # noqa: E402
import test_config                                             # noqa: E402

REPO = SCRIPT_DIR.parents[2]
DEFAULT_SOC = REPO.parent / "arvern-soc"

# label: (board file relative to arvern-soc, BOARD_* overrides)
BOARDS = {
    "tang_hdmi":  ("fpga/sipeed_tang_console_138k/rtl/verilog/arvern_fpga.v",
                   {"BOARD_HDMI": 1, "BOARD_HDMI_AUDIO": 1}),
    "tang_panel": ("fpga/sipeed_tang_console_138k/rtl/verilog/arvern_fpga.v",
                   {"BOARD_HDMI": 0}),
    "de0":        ("fpga/alteral_de0_nano_soc/rtl/verilog/arvern_fpga.v", {}),
}

# Driver platform header of each build (relative to arvern-soc)
PLATFORM = {
    "tang_hdmi":  "fpga/sipeed_tang_console_138k/software/bsp/tang_blns.h",
    "tang_panel": "fpga/sipeed_tang_console_138k/software/bsp/tang_blns.h",
    "de0":        "fpga/alteral_de0_nano_soc/software/bsp/de0_blns.h",
}

# BLNS_HW_<F> from the Belenos parameters (as BLNS_CFG / CFG2 / DPI_CAPS show them)
def _hw_features(p):
    gpu  = p["GPU_EN"] != 0
    dif  = p["DIF_TYPE"]
    isl  = dif == 5 and p["DPI_ISLAND_EN"] != 0
    return {
        "GPU":        gpu,
        "GPU_XY":     gpu and p["GPU_XY_EN"] != 0,
        "GPU_GRAD":   gpu and p["GPU_GRAD_EN"] != 0,
        "GPU_BLEND":  gpu and p["GPU_BLEND_EN"] != 0,
        "GPU_TRI":    gpu and p["GPU_TRI_EN"] != 0 and p["GPU_XY_EN"] != 0,
        "GPU_REMAP":  gpu and p["GPU_REMAP_EN"] != 0,
        "GPU_MPLANE": gpu and p["GPU_MPLANE_EN"] != 0,
        "GPU_IMM":    gpu and p["GPU_IMM_EN"] != 0,
        "GPU_LINE":   gpu and p["GPU_LINE_EN"] != 0 and p["GPU_XY_EN"] != 0,
        "CURSOR":     p["CURSOR_EN"] != 0,
        "LUT":        p["LUT_EN"] != 0,
        "LUT2":       p["LUT_EN"] != 0 and p["LUT_BANKS"] == 2,
        "DPI":        dif in (4, 5),
        "DBI":        1 <= dif <= 3,
        "DPI_DDC":    dif == 5 and p["DPI_DDC_EN"] != 0,
        "DPI_ISLAND": isl,
        "DPI_AUDIO":  isl and p["DPI_AUDIO_EN"] != 0,
    }


# A feature stated 0 makes these 0 too (belenos_hw.h)
_HW_IMPLIED = {
    "GPU":        ("GPU_XY", "GPU_GRAD", "GPU_BLEND", "GPU_TRI", "GPU_REMAP", "GPU_MPLANE", "GPU_IMM", "GPU_LINE"),
    "GPU_XY":     ("GPU_TRI", "GPU_LINE"),
    "LUT":        ("LUT2",),
    "DPI":        ("DPI_DDC", "DPI_ISLAND", "DPI_AUDIO"),
    "DPI_ISLAND": ("DPI_AUDIO",),
}

_HW_DEF = re.compile(r"^\s*#\s*define\s+BLNS_HW_(\w+)\s+(\S+)", re.M)


def check_platform(soc):
    """The platform headers against the board parameters: the number of
    mismatches"""
    bad, per_header = 0, {}
    for label, _ in rtl_configs.DEPLOYED:
        rel, over = BOARDS[label]
        eff = dict(test_config.RTL_DEFAULTS)
        eff.update(board_params(soc / rel, over))
        per_header.setdefault(PLATFORM[label], []).append((label, _hw_features(eff)))
    for hdr, builds in per_header.items():
        path = soc / hdr
        if not path.exists():
            print(f"MISMATCH {hdr}: missing (builds {', '.join(l for l, _ in builds)})")
            bad += 1
            continue
        stated = dict(_HW_DEF.findall(path.read_text()))
        implied = {c for parent, kids in _HW_IMPLIED.items() if stated.get(parent) == "0" for c in kids}
        for f, v in sorted(stated.items()):
            if f not in builds[0][1]:
                print(f"MISMATCH {hdr}: BLNS_HW_{f} is not a feature of belenos_hw.h")
                bad += 1
            elif v not in ("0", "1"):
                print(f"MISMATCH {hdr}: BLNS_HW_{f} = {v}, must be 0 or 1")
                bad += 1
            else:
                for label, hw in builds:
                    if hw[f] != (v == "1"):
                        print(f"MISMATCH {hdr}: BLNS_HW_{f} = {v}, {label} has {int(hw[f])}")
                        bad += 1
        for f in sorted(builds[0][1]):
            vals = {hw[f] for _, hw in builds}
            if f not in stated and f not in implied and len(vals) == 1:
                print(f"  {hdr}: BLNS_HW_{f} left to run time, every build has {int(vals.pop())}")
    print("platform headers: " + ("match the boards" if not bad else f"{bad} mismatch(es)"))
    return bad


# Parameters the board does not set: the RTL defaults apply
NOT_SET_OK = {"DPI_DDC_EN", "DPI_ISLAND_EN"}

_DECL = re.compile(r"^\s*(?:parameter|localparam)\s+(\w+)\s*=\s*(.+?);", re.M)


def _num(tok):
    tok = tok.strip()
    m = re.fullmatch(r"\d*'([bdh])([0-9a-fA-F_]+)", tok)
    if m:
        return int(m.group(2).replace("_", ""), {"b": 2, "d": 10, "h": 16}[m.group(1)])
    return None


def _eval(expr, env):
    """A Verilog constant expression of the kind the board files use: numbers,
    names, comparisons, && || and one level of ?: (nested in parentheses)."""
    e = re.sub(r"\d*'[bdh][0-9a-fA-F_]+", lambda m: str(_num(m.group(0))), expr)
    e = e.replace("&&", " and ").replace("||", " or ").replace("$clog2", "_clog2")
    # cond ? a : b  ->  (a if cond else b), outermost first
    while "?" in e:
        q = e.index("?")
        c = e.index(":", q)
        e = f"(({e[q + 1:c]}) if ({e[:q]}) else ({e[c + 1:]}))"
    return eval(e, {"__builtins__": {}, "_clog2": lambda v: max(1, (v - 1).bit_length())}, env)


def board_params(path, board_over):
    text = path.read_text()
    env, out = {}, {}
    for name, expr in _DECL.findall(text):
        if name in board_over:
            env[name] = board_over[name]
            continue
        try:
            env[name] = _eval(expr, env)
        except Exception:
            continue
        if name.startswith("BLNS_"):
            out[name[5:]] = env[name]
    if "ASYNC_RST_EN" in env:
        out["ASYNC_RST_EN"] = env["ASYNC_RST_EN"]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--soc", default=str(DEFAULT_SOC))
    args = ap.parse_args()
    soc = Path(args.soc)
    if not soc.is_dir():
        print(f"NOTE: {soc} not found: deployed builds not checked")
        return 0
    bad = 0
    for label, params in rtl_configs.DEPLOYED:
        rel, over = BOARDS[label]
        board = board_params(soc / rel, over)
        for p, v in sorted(params.items()):
            if p not in board:
                if p not in NOT_SET_OK and p not in ("VRAM_AW",):
                    print(f"  {label}: {p} = {v} here, not set by {rel}")
                continue
            if board[p] != v:
                print(f"MISMATCH {label}: {p} = {v} here, {board[p]} in {rel}")
                bad += 1
        for p, v in sorted(board.items()):
            if p not in params and test_config.RTL_DEFAULTS.get(p) == v:
                continue                                       # left at the RTL default
            if p not in params and p not in ("VRAM_AW", "DPI_NB"):
                print(f"MISMATCH {label}: {p} = {v} in {rel}, absent here")
                bad += 1
    print("deployed builds: " + ("match the boards" if not bad else f"{bad} mismatch(es)"))
    bad += check_platform(soc)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
