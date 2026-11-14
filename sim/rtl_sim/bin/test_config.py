#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    test_config.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Loader for run/run_config.json and the simulation config set, shared by
# ./run, ./run_all, run_sweep.py, runcov and cov_const_cfg.py.
#
# Configs, numbered from 1:
#   1..N      the shared configs of rtl_configs.CONFIGS (the same numbering as
#             run_lint -sweep, run_vclint -rtl_config and run_syn -rtl_config),
#             overrides of the RTL defaults; every enabled test whose
#             `requires` holds runs in each of them (sim_configs.SHARED_TEST_LISTS
#             narrows a few)
#   N+1..     the sim_* configs of sim_configs.SIM_ONLY_CONFIGS, overrides of
#             the default build, each with its own test list
# "default" (no -rtl_config) is the default build: run_config.json defaults.
#
# Every build gets every parameter as a BLNS_<P> define, so the values the
# `requires` expressions were evaluated on are the values the bench builds.
#
#   test_config.py --list-configs        index, label and parameters
#   test_config.py --pairs [MODE]        "<label>:<test>" for a sweep mode
#   test_config.py --defines SEL         BLNS_<P>=<v> list of one config
#   test_config.py --tests SEL           the tests that run in one config
#   test_config.py --list-tests          every test with its requires
#   test_config.py --applies TEST [SEL]  exit 1 if TEST's requires fails
#   test_config.py --test-defines TEST   the bench defines of one test
#                                        (BLNS_MIN_CHECKS from min_checks)
#----------------------------------------------------------------------------

import json
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import rtl_configs                                             # noqa: E402
import sim_configs                                             # noqa: E402

RUN_CONFIG = SCRIPT_DIR.parent / "run" / "run_config.json"
SWEEP_MODES = ("all", "personas", "shared", "sim", "deployed", "release", "smoke", "fast")
# Tiers (bin/run_sweep.py --sweep-mode, ./run_all -tier):
#   T0 smoke     the smoke_* tests in every config (elaboration and bring-up
#                of every parameter combination, minutes)
#   T1 fast      the default build and the shipped Tang HDMI build, every test,
#                and the ultra build with the tests of the features neither has
#                (FAST_ULTRA: blending, triangles, and the run-ahead's
#                DISCARD in the set-up stage, RGB565A8, MIX5 and bilinear
#                sampling)
#   T2 release   the personas and the deployed builds, every test, and the
#                sim_* configs of sim_configs.RELEASE_EXTRA with their lists
#   T3 all       every config with every applicable test, plus the
#                functional-coverage gate (and ./run_all -cov at a release)
#   deployed     the deployed builds of rtl_configs.DEPLOYED alone


class ConfigError(Exception):
    pass


def _load():
    with RUN_CONFIG.open() as fh:
        cfg = json.load(fh)
    params = cfg["rtl_config"]
    build = {p: e["default"] for p, e in params.items()}
    rtl = {p: e.get("rtl_default", e["default"]) for p, e in params.items()}
    tests = []
    for t in cfg["tests"]:
        req = t.get("requires", "").strip()
        if req:
            try:
                code = compile(req, f"requires of {t['name']}", "eval")
                eval(code, {"__builtins__": {}}, dict(build))
            except Exception as exc:
                raise ConfigError(f"run_config.json: test {t['name']}: malformed requires "
                                  f"'{req}': {exc}")
            t = dict(t, _code=code)
        tests.append(t)
    return params, build, rtl, tests


PARAMS, DEFAULT_BUILD, RTL_DEFAULTS, TESTS = _load()
TEST_NAMES = [t["name"] for t in TESTS]


def _check(label, overrides):
    for p in overrides:
        if p not in PARAMS:
            raise ConfigError(f"config {label}: unknown parameter {p}")


def configs():
    """[(index, label, kind, params, test_list or None)]; kind = shared / sim."""
    out = []
    for label, ov in rtl_configs.CONFIGS:
        _check(label, ov)
        out.append((len(out) + 1, label, "shared", dict(RTL_DEFAULTS, **ov),
                    sim_configs.SHARED_TEST_LISTS.get(label)))
    for label, ov, tl in sim_configs.SIM_ONLY_CONFIGS:
        _check(label, ov)
        unknown = [t for t in tl if t not in TEST_NAMES]
        if unknown:
            raise ConfigError(f"config {label}: unknown tests {unknown}")
        out.append((len(out) + 1, label, "sim", dict(DEFAULT_BUILD, **ov), tl))
    return out


def env_overrides(params):
    """Apply BLNS_DEFINES ("BLNS_<P>=<v> ...", the manual override of ./run)."""
    out = dict(params)
    for d in os.environ.get("BLNS_DEFINES", "").split():
        k, _, v = d.partition("=")
        if d in EXTRA_DEFINES.values() or k in TEST_DEFINES:
            continue                                   # added by defines() or test_defines(), not a parameter
        k = k[5:] if k.startswith("BLNS_") else k
        if k not in PARAMS:
            raise ConfigError(f"BLNS_DEFINES: unknown parameter {k}")
        out[k] = int(v, 0) if v.lstrip("-").isdigit() or v.startswith("0x") else v
    return out


def resolve(sel):
    """(label, params, test_list or None) for None/'default', an index or a label."""
    if sel in (None, "", "default"):
        return "default", dict(DEFAULT_BUILD), None
    cl = configs()
    if str(sel).isdigit():
        i = int(sel)
        if not 1 <= i <= len(cl):
            raise ConfigError(f"config index {i} out of range 1..{len(cl)}")
        _, label, _, p, tl = cl[i - 1]
        return label, p, tl
    for _, label, _, p, tl in cl:
        if label == sel:
            return label, p, tl
    raise ConfigError(f"unknown config '{sel}' (./run_all -list_configs)")


def applies(test, params):
    t = TESTS[TEST_NAMES.index(test)]
    return "_code" not in t or bool(eval(t["_code"], {"__builtins__": {}}, dict(params)))


def tests_for(params, test_list=None, enabled_only=True):
    names = test_list if test_list is not None else TEST_NAMES
    out = []
    for t in TESTS:
        if t["name"] in names and (t.get("enabled", True) or not enabled_only) \
                and applies(t["name"], params):
            out.append(t["name"])
    return out


# Plain defines a bench-only parameter adds for the RTL below the bench
# (SYNC_JITTER=1: the arv_synchronizer metastability model)
EXTRA_DEFINES = {"SYNC_JITTER": "ARV_SYNC_JITTER"}


TEST_DEFINES = ("BLNS_MIN_CHECKS",)

# T1 runs these in the ultra build: blending and triangles are in neither the
# default nor the Tang HDMI build
FAST_ULTRA = ("gpu_blend", "gpu_blend_x", "gpu_tri", "gpu_tritex", "gpu_rstream", "gpu_discard",
              "gpu_mix5", "gpu_a8_copy", "gpu_a8_tex", "gpu_a8_err",
              "gpu_bil_basic", "gpu_bil_edges", "gpu_bil_mixd", "gpu_bil_cache", "gpu_bil_err",
              "gpu_perf", "gpu_texrect", "gpu_retain")


def test_defines(test):
    """Bench defines of one test (run_config.json): its minimum check count."""
    t = TESTS[TEST_NAMES.index(test)] if test in TEST_NAMES else {}
    return [f"BLNS_MIN_CHECKS={int(t['min_checks'])}"] if "min_checks" in t else []


def defines(params):
    out = [f"BLNS_{p}={v}" for p, v in sorted(params.items())]
    return out + [d for p, d in sorted(EXTRA_DEFINES.items()) if params.get(p)]


def sweep(mode="all"):
    """[(label, params, [tests])] for a sweep mode."""
    if mode not in SWEEP_MODES:
        raise ConfigError(f"unknown sweep mode '{mode}' (one of {', '.join(SWEEP_MODES)})")
    personas = {label for label, _ in rtl_configs.PERSONAS}
    deployed = {label for label, _ in rtl_configs.DEPLOYED}
    out = []
    if mode == "fast":
        out.append(("default", dict(DEFAULT_BUILD), tests_for(DEFAULT_BUILD)))
    for _, label, kind, p, tl in configs():
        if mode == "personas" and label not in personas:
            continue
        if mode == "shared" and kind != "shared":
            continue
        if mode == "sim" and kind != "sim":
            continue
        if mode == "deployed" and label not in deployed:
            continue
        if mode == "release" and label not in personas | deployed | set(sim_configs.RELEASE_EXTRA):
            continue
        if mode == "fast" and label not in ("tang_hdmi", "ultra"):
            continue
        tests = tests_for(p, tl)
        if mode == "fast" and label == "ultra":
            tests = [t for t in tests if t in FAST_ULTRA]
        if mode == "smoke":
            tests = [t for t in tests if t.startswith("smoke_")]
        out.append((label, p, tests))
    return out


def _fmt(params):
    diff = {p: v for p, v in params.items() if v != DEFAULT_BUILD[p]}
    return " ".join(f"{p}={v}" for p, v in sorted(diff.items())) or "(default build)"


def main(argv):
    try:
        if argv[:1] == ["--list-configs"]:
            print(f"# {len(configs())} configs; parameters shown where they differ from the default build")
            print(f"0\tdefault\t{_fmt(DEFAULT_BUILD)}")
            for i, label, kind, p, tl in configs():
                n = len(tests_for(p, tl))
                print(f"{i}\t{label}\t[{kind}, {n} tests] {_fmt(p)}")
        elif argv[:1] == ["--pairs"]:
            for label, _, tl in sweep(argv[1] if len(argv) > 1 else "all"):
                for t in tl:
                    print(f"{label}:{t}")
        elif argv[:1] == ["--defines"]:
            print(" ".join(defines(env_overrides(resolve(argv[1] if len(argv) > 1 else None)[1]))))
        elif argv[:1] == ["--test-defines"]:
            print(" ".join(test_defines(argv[1] if len(argv) > 1 else "")))
        elif argv[:1] == ["--list-tests"]:
            for t in TESTS:
                req = t.get("requires", "")
                state = "" if t.get("enabled", True) else " [disabled]"
                print(f"  {t['name']:22} {t['description']}{state}" + (f"  [requires: {req}]" if req else ""))
        elif argv[:1] == ["--tests"]:
            label, p, tl = resolve(argv[1] if len(argv) > 1 else None)
            print(" ".join(tests_for(p, tl)))
        elif argv[:1] == ["--applies"]:
            label, p, _ = resolve(argv[2] if len(argv) > 2 else None)
            p = env_overrides(p)
            t = TESTS[TEST_NAMES.index(argv[1])] if argv[1] in TEST_NAMES else None
            if t is None:
                print(f"unknown test {argv[1]}")
                return 2
            if not applies(argv[1], p):
                print(f"{argv[1]} does not apply to {label} (requires: {t['requires']})")
                return 1
        else:
            print(__doc__ or "usage: test_config.py --list-configs | --pairs [MODE] | "
                  "--defines SEL | --tests SEL | --applies TEST [SEL]")
            return 2
    except ConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
