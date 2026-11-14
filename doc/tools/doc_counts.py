#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    doc_counts.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : doc_counts.py
# Module Description : The test, configuration, run and tier counts of the
#                      simulation and verification guides, generated from the code the
#                      regression runs (sim/rtl_sim/bin/test_config.py:
#                      run_config.json, rtl_configs.py, sim_configs.py).
#----------------------------------------------------------------------------
"""Generate the counts of doc/simulation_guide.md and doc/verification_guide.md.

    python3 doc/tools/doc_counts.py            # print the counts
    python3 doc/tools/doc_counts.py --update   # rewrite the generated blocks
    python3 doc/tools/doc_counts.py --check    # exit 1 if a block is stale

A generated block sits between two marker lines of its guide (GUIDES):

    <!-- doc_counts:begin NAME -->
    ...
    <!-- doc_counts:end NAME -->

Run --update after adding a test (run_config.json) or a configuration
(rtl_configs.py, sim_configs.py); nothing else in the guides holds a count.
"""
import collections
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
# Each generated block and the guide that holds it (exactly once)
GUIDES = {
    "tests": ROOT / "doc" / "verification_guide.md",
    "bins": ROOT / "doc" / "verification_guide.md",
    "configs": ROOT / "doc" / "simulation_guide.md",
    "tiers": ROOT / "doc" / "simulation_guide.md",
}
sys.path.insert(0, str(ROOT / "sim" / "rtl_sim" / "bin"))
import rtl_configs                                             # noqa: E402
import sim_configs                                             # noqa: E402
import test_config as tc                                       # noqa: E402

# The order of the test groups in the guide (a new prefix is appended)
GROUPS = ["smoke", "regs", "gpu", "bk", "dbi", "dpi"]

# ./run_all tier: (sweep mode, option, content)
TIERS = [
    ("T0", "smoke", "`-tier T0`", "the `smoke_*` tests in every configuration"),
    ("T1", "fast", "`-fast` (the default)", "every test of the default build and of the shipped Tang HDMI build, the blending, per-pixel alpha, triangle, random-stream and discard tests and the bilinear tests in the ultra build"),
    ("T2", "release", "`-tier T2`", "the personas and the deployed builds, the Tang HDMI build with the clock gate and under jitter, bilinear without blending (`classic_bil`), the F bound error's prefix behind run-ahead, a two-cycle macro, the DPI refresh and a small VRAM (`sim_bnd_*`), the random command stream with four seeds in six builds"),
    ("T3", "all", "`-tier T3`, `-rtl_sweep`", "every configuration, and the functional-coverage gate"),
]


def num(n):
    """Thousands with a space, as the guide writes them (4 003)."""
    return f"{n:,}".replace(",", " ")


def runs(mode):
    return sum(len(t) for _, _, t in tc.sweep(mode))


def counts():
    enabled = [t["name"] for t in tc.TESTS if t.get("enabled", True)]
    groups = collections.Counter(n.split("_")[0] for n in enabled)
    order = GROUPS + sorted(g for g in groups if g not in GROUPS)
    return {
        "tests": len(tc.TESTS),
        "enabled": len(enabled),
        "groups": [(g, groups[g]) for g in order if groups[g]],
        "shared": len(rtl_configs.CONFIGS),
        "sim": len(sim_configs.SIM_ONLY_CONFIGS),
        "configs": len(tc.configs()),
        "personas": [label for label, _ in rtl_configs.PERSONAS],
        "deployed": [label for label, _ in rtl_configs.DEPLOYED],
        "modes": {m: (len(tc.sweep(m)), runs(m)) for m in tc.SWEEP_MODES},
        "bins": len(sim_configs.MANDATORY_COVER_BINS),
        "sweep_only_bins": len(sim_configs.SWEEP_ONLY_COVER_BINS),
    }


def blocks(c):
    disabled = c["tests"] - c["enabled"]
    tests = (f"The {c['enabled']} enabled directed tests in `sim/rtl_sim/src/`"
             + (f" ({disabled} more disabled)" if disabled else "") + ", by group: "
             + ", ".join(f"`{g}_*` {n}" for g, n in c["groups"]) + ".")
    configs = (f"The sweep has {c['configs']} configurations "
               f"({num(c['modes']['all'][1])} test runs): the {c['shared']} shared "
               f"configurations and the {c['sim']} simulation-only ones below.")
    rows = ["| Tier | `./run_all` | Configurations | Runs | Content |", "|---|---|---:|---:|---|"]
    for tier, mode, opt, text in TIERS:
        ncfg, nrun = c["modes"][mode]
        rows.append(f"| {tier} | {opt} | {ncfg} | {num(nrun)} | {text} |")
    ncfg, nrun = c["modes"]["deployed"]
    rows.append(f"| — | `-deployed` | {ncfg} | {num(nrun)} | the deployed builds alone |")
    bins = (f"Mandatory bins: {c['bins']} (`MANDATORY_COVER_BINS` in "
            f"`sim/rtl_sim/bin/sim_configs.py`), of which {c['sweep_only_bins']} are required "
            f"only of the full sweep (`SWEEP_ONLY_COVER_BINS`).")
    return {"tests": tests, "configs": configs, "tiers": "\n".join(rows), "bins": bins}


def show(c):
    print(f"tests: {c['tests']} ({c['enabled']} enabled)")
    for g, n in c["groups"]:
        print(f"  {g}_*: {n}")
    print(f"configurations: {c['configs']} ({c['shared']} shared in rtl_configs.py, "
          f"{c['sim']} sim-only in sim_configs.py)")
    print(f"  personas: {', '.join(c['personas'])}; deployed: {', '.join(c['deployed'])}")
    print("sweep modes (configurations, runs):")
    for m, (ncfg, nrun) in c["modes"].items():
        print(f"  {m:9} {ncfg:4} {nrun:6}")
    print("tiers: " + ", ".join(f"{t} = {m} ({runs(m)} runs)" for t, m, _, _ in TIERS))
    print(f"coverage bins: {c['bins']} mandatory, {c['sweep_only_bins']} of them full-sweep only")


def rewrite(text, gen, path):
    for name, body in gen.items():
        pat = re.compile(r"(<!-- doc_counts:begin %s -->\n)(.*?)(\n<!-- doc_counts:end %s -->)"
                         % (name, name), re.S)
        found = len(pat.findall(text))
        if found != 1:
            raise SystemExit(f"doc_counts: {found} markers for {name} in {path.name} (want 1)")
        text = pat.sub(lambda m: m.group(1) + "\n" + body + "\n" + m.group(3), text)
    return text


def main(argv):
    c = counts()
    if not argv:
        show(c)
        return 0
    if argv[0] not in ("--check", "--update"):
        print(__doc__)
        return 2
    gen = blocks(c)
    for name in gen:
        if name not in GUIDES:
            raise SystemExit(f"doc_counts: no guide for block {name}")
    changed = 0
    for path in sorted(set(GUIDES.values())):
        mine = {n: b for n, b in gen.items() if GUIDES[n] == path}
        old = path.read_text()
        new = rewrite(old, mine, path)
        for other in set(gen) - set(mine):     # a block belongs to one guide only
            if f"<!-- doc_counts:begin {other} -->" in old:
                raise SystemExit(f"doc_counts: block {other} also in {path.name}")
        if new == old:
            continue
        if argv[0] == "--check":
            print(f"doc_counts: {path.relative_to(ROOT)} is stale: run doc/tools/doc_counts.py --update")
        else:
            path.write_text(new)
            print(f"doc_counts: updated {path.relative_to(ROOT)}")
        changed += 1
    if not changed:
        print("doc_counts: up to date")
    return 1 if argv[0] == "--check" and changed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
