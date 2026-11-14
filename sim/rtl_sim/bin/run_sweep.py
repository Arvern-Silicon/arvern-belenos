#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    run_sweep.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Run every (config, test) pair of a sweep mode of bin/test_config.py (every
# enabled test whose `requires` holds, in every shared config; each sim_*
# config's own test list), or of one config (--rtl-config). For each pair, in
# its own work directory WORK/<run>/<config>/<test>/:
#   1. Symlink the test stimulus to stimulus.v
#   2. Build with Icarus (iverilog, every parameter as a -D define, + NODUMP
#      + SEED) or, with --sim verilator, with Verilator (random initial
#      values: --x-initial unique, +verilator+rand+reset+2 seeded per run)
#   3. Execute the resulting simulation
#   4. Log to log_runs/<run>/<config>/<test>.log
#
# Every invocation is a run of its own, <run> = <date>-<time>_<pid>: its work
# directory, filelist and logs are its own, so several sweeps (and ./run) can
# go in one checkout at once. log_sweep is a link to the newest run's logs
# (log_sweep/summary.log, log_sweep/<config>/<test>.log). Finished runs beyond
# the newest LOG_KEEP (default 10) are pruned; a run still going is never
# touched.
#
# A run fails (FAIL) on a FAILED banner, on an ERROR: line anywhere in its log
# (a checker outside the test's error count), and passes only with a PASSED
# banner. At the end, print a per-config summary table and an overall pass/fail
# count. Exit non-zero if any test failed.
#----------------------------------------------------------------------------

import argparse
import os
import random
import re
import time
from concurrent.futures import ThreadPoolExecutor
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import test_config                                           # noqa: E402
import coverage                                              # noqa: E402

CWD = Path.cwd()
RUN_ID = time.strftime("%Y%m%d-%H%M%S") + f"_{os.getpid()}"
LOG_RUNS = CWD / "log_runs"
LOG_ROOT = LOG_RUNS / RUN_ID                     # this run's logs
LOG_LINK = CWD / "log_sweep"                     # -> the newest run's logs
WORK_ROOT = CWD / "WORK" / RUN_ID                # this run's work directories
SUBMIT_F = WORK_ROOT / "submit_sim.f"
BENCH_SUBMIT_F = (CWD / "../../../bench/verilog/submit.f").resolve()
SRC_DIR = (CWD / "../src").resolve()
FLATTEN = SCRIPT_DIR / "flatten_filelist.py"
COV_PUBLIC = SCRIPT_DIR / "cov_public.vlt"
LOG_KEEP = int(os.environ.get("LOG_KEEP", "10"))
RUNNING = ".running"                             # holds the pid of a run in progress


def regenerate_filelist():
    subprocess.run([str(FLATTEN), str(BENCH_SUBMIT_F), str(SUBMIT_F)], check=True,
                   stdout=subprocess.DEVNULL)


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _running(d):
    try:
        return _alive(int((d / RUNNING).read_text().split()[0]))
    except (OSError, ValueError, IndexError):
        return False


def start_logs():
    """Create this run's log directory, point log_sweep at it, prune old runs."""
    LOG_RUNS.mkdir(exist_ok=True)
    # A log_sweep directory of the single-directory layout becomes a run of its own
    if LOG_LINK.is_dir() and not LOG_LINK.is_symlink():
        LOG_LINK.rename(LOG_RUNS / time.strftime("legacy-%Y%m%d-%H%M%S",
                                                 time.localtime(LOG_LINK.stat().st_mtime)))
    LOG_ROOT.mkdir()
    (LOG_ROOT / RUNNING).write_text(f"{os.getpid()}\n")
    tmp = CWD / f".log_sweep.{os.getpid()}"
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(Path("log_runs") / RUN_ID)
    os.replace(tmp, LOG_LINK)                    # atomic: a reader sees the old or the new run
    finished = sorted((d for d in LOG_RUNS.iterdir()
                       if d.is_dir() and d != LOG_ROOT and not _running(d)),
                      key=lambda d: d.stat().st_mtime)
    for d in finished[:max(0, len(finished) - LOG_KEEP)]:
        shutil.rmtree(d, ignore_errors=True)


def classify(log_text):
    """PASS / FAIL / SKIP / INCONCLUSIVE from a run's log."""
    # An ERROR: line (a checker outside the test's own error count, a model,
    # the bench) fails the run whatever the banner says
    has_error = re.search(r"^ERROR:", log_text, re.M) is not None
    if "SIMULATION FAILED" in log_text:
        return "FAIL"
    if "SIMULATION PASSED" in log_text:
        return "FAIL" if has_error else "PASS"
    # A test that opted out via tb_skip_finish (incompatible with this config)
    # prints its own banner. Classifying it separately is what keeps
    # INCONCLUSIVE meaningful: without this, a deliberate skip and a crashed or
    # hung simulation land in the same bucket and neither can be spotted.
    if "SIMULATION SKIPPED" in log_text:
        return "FAIL" if has_error else "SKIP"
    return "INCONCLUSIVE"


def build_cmds(sim, defines, seed, tdefs=()):
    """(build command, run command) of one pair, run in its work directory."""
    defs = test_config.defines(defines) + list(tdefs)
    if sim == "verilator":
        # As bin/runcov without the coverage: cov_public.vlt keeps the bench
        # variables the processes share public (the gated-clock scheduling);
        # every variable starts at a random value drawn from the run's seed
        build = ["verilator", "--binary", "--timing", "--x-initial", "unique", "--x-assign", "unique",
                 "-Wno-fatal", "-Wno-TIMESCALEMOD", "-Wno-LATCH", "-Wno-WIDTHEXPAND", "--quiet-exit",
                 "-MAKEFLAGS", "OPT_FAST=-O1", "-MAKEFLAGS", "OPT_SLOW=-O0", "-MAKEFLAGS", "OPT_GLOBAL=-O0"]
        build += [f"+define+{d}" for d in defs]
        build += [f"+define+SEED={seed}", "+define+NODUMP", "+define+NOTRACE", "+incdir+.",
                  str(COV_PUBLIC), "-f", str(SUBMIT_F), "--top-module", "tb_belenos",
                  "--Mdir", "obj_dir", "-o", "simv"]
        run = ["./obj_dir/simv", "+verilator+rand+reset+2", f"+verilator+seed+{seed % 2147483646 + 1}"]
    else:
        # Each -D is given as one shell token (-DKEY=VAL)
        build = ["iverilog", "-o", "simv", "-c", str(SUBMIT_F)]
        build += [f"-D{d}" for d in defs]
        build += [f"-DSEED={seed}", "-DNODUMP", "-DNOTRACE"]
        run = ["./simv"]
    return build, run


def run_one(config_label, defines, test, log_dir, work_dir, seed, sim="iverilog"):
    """Compile and run one (config, test) in its own work directory (its own
    stimulus.v link and simulation), so runs can go in parallel."""
    log_path = log_dir / f"{test}.log"
    src = SRC_DIR / f"{test}.v"
    if not src.exists():
        log_path.write_text(f"SKIP: stimulus file not found: ../src/{test}.v\n")
        return "MISS"
    run_dir = work_dir
    run_dir.mkdir(parents=True, exist_ok=True)
    link = run_dir / "stimulus.v"
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(src)

    compile_cmd, run_cmd = build_cmds(sim, defines, seed, test_config.test_defines(test))
    with log_path.open("w") as fh:
        fh.write("CONFIG: " + config_label + "\n")
        fh.write("DEFINES: " + " ".join(test_config.defines(defines)) + "\n")
        fh.write("TEST: " + test + "\n")
        fh.write("CMD: " + " ".join(compile_cmd) + "\n")
        fh.write("-" * 78 + "\n")
        fh.flush()
        rc = subprocess.run(compile_cmd, stdout=fh, stderr=subprocess.STDOUT, cwd=run_dir).returncode
        if rc != 0:
            shutil.rmtree(run_dir, ignore_errors=True)
            return "COMPILE_FAIL"
        # Run
        fh.write("-" * 78 + " RUN " + " ".join(run_cmd) + "\n")
        fh.flush()
        subprocess.run(run_cmd, stdout=fh, stderr=subprocess.STDOUT, cwd=run_dir)
    shutil.rmtree(run_dir, ignore_errors=True)
    return classify(log_path.read_text(errors="ignore"))


def fmt_defines(params):
    """The parameters that differ from the default build."""
    return test_config._fmt(params)


def main():
    ap = argparse.ArgumentParser(description="belenos simulation sweep")
    ap.add_argument("-j", "--jobs", type=int, default=1,
                    help="parallel runs (each in its own WORK/<run>/<config>/<test> directory)")
    ap.add_argument("--sim", default="iverilog", choices=("iverilog", "verilator"),
                    help="simulator: Icarus (default) or Verilator with random initial values")
    ap.add_argument("--seed", type=int, default=None,
                    help="master seed: the per-run seeds are drawn from it (reproducible sweep)")
    ap.add_argument("--sweep-mode", default="all", choices=test_config.SWEEP_MODES,
                    help="all (default), personas, shared (the rtl_configs.py set), sim, deployed, "
                         "release (personas + deployed), smoke (smoke_* everywhere), fast (default + tang_hdmi + the ultra blend / triangle tests)")
    ap.add_argument("--rtl-config", default=None,
                    help="one config only: index or label (./run_all -list_configs) or 'default'")
    args = ap.parse_args()

    try:
        # BLNS_DEFINES overrides single parameters of every config
        if args.rtl_config is not None:
            label, params, tl = test_config.resolve(args.rtl_config)
            params = test_config.env_overrides(params)
            plan = [(label, params, test_config.tests_for(params, tl))]
        else:
            # BLNS_DEFINES overrides single parameters of every build; the tests
            # are chosen again on the overridden parameters
            tl_of = {c[1]: c[4] for c in test_config.configs()}
            plan = []
            for l, p, _ in test_config.sweep(args.sweep_mode):
                p = test_config.env_overrides(p)
                tl = test_config.tests_for(p, tl_of.get(l))
                if args.sweep_mode == "smoke":
                    tl = [t for t in tl if t.startswith("smoke_")]
                if args.sweep_mode == "fast" and l == "ultra":
                    tl = [t for t in tl if t in test_config.FAST_ULTRA]
                plan.append((l, p, tl))
    except test_config.ConfigError as exc:
        sys.exit(f"ERROR: {exc}")

    if args.sim == "verilator" and "OBJCACHE" not in os.environ and shutil.which("ccache"):
        os.environ["OBJCACHE"] = str(SCRIPT_DIR / "objcache_nopch")
    start_logs()
    WORK_ROOT.mkdir(parents=True)
    regenerate_filelist()
    master = args.seed if args.seed is not None else random.randint(0, 2**31 - 1)
    rng = random.Random(master)
    print(f"  run {RUN_ID}: logs in log_runs/{RUN_ID} (log_sweep), simulator {args.sim}, master seed {master}")

    jobs = []
    for config_label, defines, test_list in plan:
        config_dir = LOG_ROOT / config_label
        config_dir.mkdir()
        for test in test_list:
            jobs.append((config_label, defines, test, config_dir, rng.randint(0, 2**31 - 1)))

    def work(config_label, test):
        return WORK_ROOT / config_label / test

    all_results = []
    try:
        if args.jobs <= 1:
            current = None
            for config_label, defines, test, config_dir, seed in jobs:
                if config_label != current:
                    print(f"\n=== config: {config_label}  ({fmt_defines(defines)})")
                    current = config_label
                print(f"  {test:<28}", end=" ", flush=True)
                status = run_one(config_label, defines, test, config_dir, work(config_label, test),
                                 seed, args.sim)
                print(status)
                all_results.append((config_label, defines, test, status))
        else:
            def job(j):
                config_label, defines, test, config_dir, seed = j
                status = run_one(config_label, defines, test, config_dir, work(config_label, test),
                                 seed, args.sim)
                print(f"  {config_label:<16} {test:<28} {status}", flush=True)
                return (config_label, defines, test, status)
            with ThreadPoolExecutor(max_workers=args.jobs) as pool:
                all_results = list(pool.map(job, jobs))
    finally:
        shutil.rmtree(WORK_ROOT, ignore_errors=True)
        (LOG_ROOT / RUNNING).unlink(missing_ok=True)

    # Summary
    print()
    print("=" * 90)
    print(f"  belenos simulation sweep -- {len(all_results)} (config, test) runs")
    print("=" * 90)
    summary_lines = [f"run {RUN_ID}, simulator {args.sim}, master seed {master}"]
    summary_lines.append(f"{'CONFIG':<14} {'TEST':<28} {'DEFINES':<32} STATUS")
    summary_lines.append("-" * 90)
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0,
              "COMPILE_FAIL": 0, "INCONCLUSIVE": 0, "MISS": 0}
    for cfg, defines, test, status in all_results:
        counts[status] = counts.get(status, 0) + 1
        summary_lines.append(f"{cfg:<14} {test:<28} {fmt_defines(defines):<32} {status}")
    summary_lines.append("-" * 90)
    # Every category is shown, INCONCLUSIVE included: it fails the exit status
    # just like FAIL, COMPILE_FAIL and MISS.
    summary_lines.append(
        f"  total: {len(all_results)}    "
        f"passed: {counts['PASS']}    failed: {counts['FAIL']}    "
        f"skipped: {counts['SKIP']}    inconclusive: {counts['INCONCLUSIVE']}    "
        f"compile-fail: {counts['COMPILE_FAIL']}    missing: {counts['MISS']}"
    )
    summary = "\n".join(summary_lines)
    print(summary)
    (LOG_ROOT / "summary.log").write_text(summary + "\n")

    # Suite-level functional-coverage gate (teeth: fails the regression).
    # Gated on the full sweep only: a subset need not reach every bin.
    full = args.rtl_config is None and args.sweep_mode == "all"
    missing_bins = coverage.report(LOG_ROOT, single_config=not full)
    if not full:
        missing_bins = []

    failed = counts["FAIL"] + counts["COMPILE_FAIL"] + counts["INCONCLUSIVE"] + counts["MISS"]
    sys.exit(0 if (failed == 0 and not missing_bins) else 1)


if __name__ == "__main__":
    main()
