#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    lvgl_bench.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# LVGL benchmark bench: LVGL v9.6's lv_demo_benchmark on an aRVern core and
# Belenos (verilog/tb_lvgl_bench.v, sw/), one simulation per persona of
# sim/rtl_sim/bin/rtl_configs.py (PERSONAS) and resolution.
#
#   lvgl_bench.py run    [--res WxH] [--persona P[,P...]|all] [-j N]
#                        [--flush direct|cpu] [--tick lockstep|real]
#                        [--dump N] [--limit-ms MS] [--tag T] [--approx A]
#       builds the firmware (sw/Makefile, with the persona's platform
#       header) and the Verilator model, runs the simulations (at most N at
#       once, 3 by default) in run/<res>_<persona>[_<tag>]/, then reduces
#       each log to results/<res>/<persona>[_<tag>].csv. --approx: the draw
#       unit's cfg.approx (sw/main.c: 6 by default, GRAD | TRANSFORM: the
#       GPU's gradients and rotated / scaled images; blending is exact in
#       every mode; 0: only what it draws as LVGL does), with a --tag
#   lvgl_bench.py reduce [--res WxH] [--persona ...] [--tag T]
#       the reduction alone, from the logs already in run/
#   lvgl_bench.py coremark [--iter N]
#       EEMBC CoreMark (sw/coremark) on the same core and memories, in the
#       light model of 480x272 (built if absent): a check of the core,
#       run/coremark/coremark.csv (not published: the CPU's speed is the
#       arvern repository's to document)
#   lvgl_bench.py frames [--res WxH] [--tag T]
#       the frames dumped (--dump) by each GPU persona against light's (the
#       software renderer): pixels that differ and the largest difference of
#       each RGB565 field, per scene: results/<res>/frames.csv
#   lvgl_bench.py tables [--update] [--check]
#       the tables of doc/performance.md from the CSV files in results/
#       (lvgl_bench_tables.py)
#
# Every Belenos parameter of a persona goes to the bench as a BLNS_<P>
# define; the bench adds the display (the DPI driver on hclk, no scaler) and
# VRAM_WORDS = W x H (two RGB565 frames). The platform header of a persona
# (run/build/plat_<persona>.h, sw/include/belenos_hw.h) states each feature
# the persona builds or leaves out, so the driver compiles only what is
# there; blns_init() checks it against the hardware.
#
# A per-frame line of the firmware ("LB F") carries the scene, LVGL's clock,
# the cycles of the refresh, of the rendering (without the flushes inside
# it, as LVGL's system monitor counts it) and of the flushes, the
# invalidated pixels, and the VRAM counters over the rendering. The
# reduction keeps every frame but the first of each scene (the scene's
# set-up, a whole-screen redraw: the benchmark drops its first measurement
# of a scene as well) and averages per scene.
#----------------------------------------------------------------------------

import argparse
import concurrent.futures
import csv
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE  = Path(__file__).resolve().parent
BENCH = HERE.parent                         # bench/lvgl_bench
ROOT  = BENCH.parent.parent                 # the repository
RUN   = BENCH / "run"
RES   = BENCH / "results"

sys.path.insert(0, str(ROOT / "sim" / "rtl_sim" / "bin"))
from rtl_configs import PERSONAS            # noqa: E402

PERSONA_ORDER = [p for p, _ in PERSONAS]

# Belenos parameter -> platform-header feature (sw/include/belenos_hw.h)
HW_FEATURES = [
    ("GPU",        lambda p: p["GPU_EN"]),
    ("GPU_XY",     lambda p: p["GPU_EN"] and p["GPU_XY_EN"]),
    ("GPU_GRAD",   lambda p: p["GPU_EN"] and p["GPU_GRAD_EN"]),
    ("GPU_BLEND",  lambda p: p["GPU_EN"] and p["GPU_BLEND_EN"]),
    ("GPU_TRI",    lambda p: p["GPU_EN"] and p["GPU_XY_EN"] and p["GPU_TRI_EN"]),
    ("GPU_REMAP",  lambda p: p["GPU_EN"] and p["GPU_REMAP_EN"]),
    ("GPU_MPLANE", lambda p: p["GPU_EN"] and p["GPU_MPLANE_EN"]),
    ("GPU_IMM",    lambda p: p["GPU_EN"] and p["GPU_IMM_EN"]),
    ("GPU_LINE",   lambda p: p["GPU_EN"] and p["GPU_XY_EN"] and p["GPU_LINE_EN"]),
    ("GPU_BILINEAR", lambda p: p["GPU_EN"] and p["GPU_XY_EN"] and p.get("GPU_BILINEAR_EN", 0)),
    ("LUT",        lambda p: p["LUT_EN"]),
    ("LUT2",       lambda p: p["LUT_EN"] and p["LUT_BANKS"] == 2),
    ("CURSOR",     lambda p: p.get("CURSOR_EN", 1)),
    ("DPI",        lambda p: 1),
    ("DBI",        lambda p: 0),
    ("DPI_DDC",    lambda p: 0),
    ("DPI_ISLAND", lambda p: 0),
    ("DPI_AUDIO",  lambda p: 0),
]

VERILATOR_FLAGS = ["--binary", "--timing", "-O3", "--x-assign", "fast", "--x-initial", "fast",
                   "-Wno-fatal", "-Wno-TIMESCALEMOD", "-Wno-LATCH", "-Wno-WIDTHEXPAND",
                   "-Wno-WIDTHTRUNC", "-Wno-MULTIDRIVEN", "--quiet-exit",
                   "-MAKEFLAGS", "OPT_FAST=-O2 OPT_SLOW=-O1"]

FRAME_FIELDS = ["scene", "tick", "refr", "render", "flush", "px", "areas",
                "gpu_busy", "bk", "win_rd", "win_wr", "gpu_rd", "gpu_wr", "v_wait"]
CSV_FIELDS   = ["scene", "name", "scene_ms", "frames", "render", "flush", "refr", "px", "gpu_busy",
                "bk", "win_rd", "win_wr", "gpu_rd", "gpu_wr", "v_wait"]


def persona_params(name):
    for p, d in PERSONAS:
        if p == name:
            return d
    sys.exit(f"unknown persona {name} (rtl_configs.PERSONAS: {', '.join(PERSONA_ORDER)})")


def run_name(res, persona, tag):
    return f"{res}_{persona}" + (f"_{tag}" if tag else "")


def write_plat(persona, path):
    p = persona_params(persona)
    lines = ["/* Generated by bench/lvgl_bench/bin/lvgl_bench.py: the Belenos platform header",
             f" * (sw/include/belenos_hw.h) of the {persona} persona in the LVGL benchmark",
             " * bench (the DPI driver, no HDMI). */"]
    for f, fn in HW_FEATURES:
        lines.append(f"#define BLNS_HW_{f:<13s}{1 if fn(p) else 0}")
    text = "\n".join(lines) + "\n"
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def sh(cmd, cwd, log):
    with open(log, "w") as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        sys.exit(f"failed ({r.returncode}): {' '.join(map(str, cmd))}; see {log}")


def build_fw(res, persona, args):
    w, h = res.split("x")
    name = run_name(res, persona, args.tag)
    work = RUN / name
    work.mkdir(parents=True, exist_ok=True)
    bdir = RUN / "build"
    bdir.mkdir(parents=True, exist_ok=True)
    plat = bdir / f"plat_{persona}.h"
    write_plat(persona, plat)
    fw = bdir / name
    sh(["make", "-j8", f"OUT={fw}", f"LB_W={w}", f"LB_H={h}", f"PERSONA={persona}", f"PLAT={plat}",
        f"FLUSH={args.flush}", f"TICK={args.tick}", f"DUMP={args.dump}"] +
       ([f"APPROX={args.approx}"] if args.approx is not None else []),
       BENCH / "sw", work / "fw_build.log")


def build(res, persona, args):
    w, h = res.split("x")
    name = run_name(res, persona, args.tag)
    work = RUN / name
    fw = RUN / "build" / name
    # The model: the persona's parameters and the resolution
    defs = [f"+define+LB_W={w}", f"+define+LB_H={h}"]
    defs += [f"+define+BLNS_{k}={v}" for k, v in persona_params(persona).items()]
    if args.limit_ms:
        defs.append(f"+define+LB_TIMEOUT_MS={args.limit_ms}")
    if args.profile:
        defs.append("+define+LB_PROFILE")
    stamp = work / "model.defs"
    if not (work / "obj_dir" / "simv").exists() or not stamp.exists() or stamp.read_text() != " ".join(defs):
        subprocess.run([sys.executable, str(ROOT / "sim" / "rtl_sim" / "bin" / "flatten_filelist.py"),
                        str(BENCH / "verilog" / "submit.f"), str(work / "submit_flat.f")],
                       check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(work / "obj_dir", ignore_errors=True)
        sh(["verilator", *VERILATOR_FLAGS, *defs, "-f", "submit_flat.f", "--top-module", "tb_lvgl_bench",
            "--Mdir", "obj_dir", "-o", "simv", "-j", "4"], work, work / "verilator_build.log")
        stamp.write_text(" ".join(defs))
    return work, fw / "fw.hex"


def simulate(res, persona, args):
    work, hexf = build(res, persona, args)
    log = work / "sim.log"
    t0 = time.time()
    with open(log, "w") as f:
        subprocess.run([str(work / "obj_dir" / "simv"), f"+code={hexf}"], cwd=work, stdout=f,
                       stderr=subprocess.STDOUT)
    dt = time.time() - t0
    text = log.read_text(errors="replace")
    # A GPU recovery (the driver redrew on the CPU what the GPU did not
    # draw) skews the timing: the run fails, as on an LVGL assertion or a trap
    rec = re.search(r"GPU recoveries (\d+)", text)
    recoveries = int(rec.group(1)) if rec else None
    ok = ("SIMULATION PASSED" in text and "LB ERROR" not in text and "ERROR:" not in text
          and recoveries == 0)
    m = re.search(r"EXIT: code \d+ at cycle (\d+)", text)
    cyc = int(m.group(1)) if m else 0
    msg = f"{run_name(res, persona, args.tag)}: {'PASSED' if ok else 'FAILED'}, {cyc} cycles in {dt:.0f} s"
    if recoveries is None:
        msg += ", no GPU recovery count in the log"
    elif recoveries:
        msg += f", {recoveries} GPU recoveries"
    if dt > 0:
        msg += f" ({cyc / dt / 1e3:.0f} k cycles/s)"
    if ok:
        reduce_log(res, persona, args.tag)
        if args.profile:
            profile(res, persona, args.tag)
    return ok, msg


def parse_log(path):
    frames, scenes, info = [], {}, {}
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("LB F "):
            v = list(map(int, line.split()[2:]))
            frames.append(dict(zip(FRAME_FIELDS, v)))
        elif line.startswith("LB W "):
            s, c = map(int, line.split()[2:4])
            frames[-1]["flush"] += c          # flush outside the rendering (FLUSH_WAIT): LVGL counts it
        elif line.startswith("LB S "):
            _, _, i, t, name = line.split(" ", 4)
            scenes[int(i)] = (name, int(t))
        elif line.startswith(("LB START", "LB DPI", "LB CFG", "LB MEM", "LB WARN", "LB END", "EXIT:")):
            info.setdefault("lines", []).append(line)
    return frames, scenes, info


def reduce_log(res, persona, tag):
    name = run_name(res, persona, tag)
    frames, scenes, info = parse_log(RUN / name / "sim.log")
    if not scenes:
        sys.exit(f"{name}: no scene list in the log (the run did not finish)")
    rows = []
    for i in sorted(scenes):
        fr = [f for f in frames if f["scene"] == i][1:]
        n = len(fr)
        row = {"scene": i, "name": scenes[i][0], "scene_ms": scenes[i][1], "frames": n}
        for k in CSV_FIELDS[4:]:
            row[k] = round(sum(f[k] for f in fr) / n, 1) if n else 0
        rows.append(row)
    out = RES / res
    out.mkdir(parents=True, exist_ok=True)
    with open(out / f"{persona}{'_' + tag if tag else ''}.csv", "w", newline="") as f:
        f.write(f"# {name}: per-scene means of the frames after each scene's first, in cycles\n")
        for line in info.get("lines", []):
            f.write(f"# {line}\n")
        wr = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        wr.writeheader()
        wr.writerows(rows)


def profile(res, persona, tag):
    """The CPU profile of a run (--profile): cycles per function, per scene
    (render, flush and LVGL's timers: the whole time of the scene), to
    results/<res>/<persona>[_<tag>]_profile.csv"""
    name = run_name(res, persona, tag)
    elf = RUN / "build" / name / "fw.elf"
    syms = []
    for line in subprocess.run(["riscv-none-elf-nm", "-n", "-S", "--defined-only", str(elf)], capture_output=True,
                               text=True).stdout.splitlines():
        p = line.split()
        if len(p) == 4 and p[2] in "tTwW":
            syms.append((int(p[0], 16), int(p[1], 16), p[3]))
    starts = [a for a, _, _ in syms]
    import bisect
    acc = {}
    for line in (RUN / name / "sim.log").read_text(errors="replace").splitlines():
        if not line.startswith("LB P "):
            continue
        _, _, sc, wa, n = line.split()
        a = int(wa, 16) * 4
        i = bisect.bisect_right(starts, a) - 1
        fn = syms[i][2] if i >= 0 and a < syms[i][0] + max(syms[i][1], 1) else "?"
        key = (int(sc), fn)
        acc[key] = acc.get(key, 0) + int(n)
    out = RES / res
    with open(out / f"{persona}{'_' + tag if tag else ''}_profile.csv", "w", newline="") as f:
        f.write(f"# {name}: CPU cycles per function and scene (the bench's fetch profile)\n")
        wr = csv.writer(f)
        wr.writerow(["scene", "function", "cycles"])
        tot, other = {}, {}
        for (sc, fn), n in acc.items():
            tot[sc] = tot.get(sc, 0) + n
        for (sc, fn), n in sorted(acc.items(), key=lambda kv: (kv[0][0], -kv[1])):
            if n * 500 >= tot[sc]:              # 0.2 % of the scene or more
                wr.writerow([sc, fn, n])
            else:
                other[sc] = other.get(sc, 0) + n
        for sc, n in sorted(other.items()):
            wr.writerow([sc, "(other)", n])


def read_ppm(path):
    data = path.read_bytes()
    # "P6\n<w> <h>\n255\n" then RGB888 (each RGB565 field with its top bits repeated)
    hdr, pos = [], 0
    while len(hdr) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        hdr.append(data[pos:end])
        pos = end
    return int(hdr[1]), int(hdr[2]), data[pos + 1:]


def frames(args):
    """The dumped frames of each GPU persona against light's, per scene"""
    rows = []
    light = RUN / run_name(args.res, "light", "")
    for p in PERSONA_ORDER[1:]:
        d = RUN / run_name(args.res, p, args.tag)
        for f in sorted(light.glob("frame_*.ppm"), key=lambda x: int(x.stem.split("_")[1])):
            g = d / f.name
            if not g.exists():
                continue
            _, _, a = read_ppm(f)
            _, _, b = read_ppm(g)
            n, mx = 0, [0, 0, 0]
            for i in range(0, min(len(a), len(b)), 3):
                if a[i:i + 3] != b[i:i + 3]:
                    n += 1
                    for c, sh in ((0, 3), (1, 2), (2, 3)):
                        mx[c] = max(mx[c], abs((a[i + c] >> sh) - (b[i + c] >> sh)))
            rows.append({"persona": p, "scene": int(f.stem.split("_")[1]), "differ": n,
                         "max_r": mx[0], "max_g": mx[1], "max_b": mx[2]})
    out = RES / args.res
    out.mkdir(parents=True, exist_ok=True)
    with open(out / f"frames{'_' + args.tag if args.tag else ''}.csv", "w", newline="") as f:
        f.write(f"# {args.res}: the frames dumped (--dump) against light's: pixels that differ, "
                "the largest difference per RGB565 field\n")
        wr = csv.DictWriter(f, fieldnames=["persona", "scene", "differ", "max_r", "max_g", "max_b"])
        wr.writeheader()
        wr.writerows(rows)
    for r in rows:
        if r["differ"]:
            print(f"{r['persona']:12s} scene {r['scene']:2d}: {r['differ']:6d} pixels differ, "
                  f"at most {r['max_r']} {r['max_g']} {r['max_b']}")
    return 0


def coremark(args):
    out = RUN / "build" / "coremark"
    work = RUN / "coremark"
    work.mkdir(parents=True, exist_ok=True)
    sh(["make", "coremark", f"OUT={out}", f"CM_ITER={args.iter}"], BENCH / "sw", work / "build.log")
    args.tag, args.limit_ms = "", 0
    if not (RUN / "480x272_light" / "obj_dir" / "simv").exists():
        build_fw("480x272", "light", args)
    model, _ = build("480x272", "light", args)
    log = work / "sim.log"
    with open(log, "w") as f:
        subprocess.run([str(model / "obj_dir" / "simv"), f"+code={out / 'coremark.hex'}"], cwd=work,
                       stdout=f, stderr=subprocess.STDOUT)
    text = log.read_text(errors="replace")
    m = re.search(r"LB COREMARK: (\d+) iterations in (\d+) cycles: ([\d.]+) CoreMark/MHz", text)
    # The performance run's CRCs (EEMBC's known values); CoreMark's own
    # "Errors detected" also counts a run shorter than 10 s, which a
    # simulation is (the result is computed from the cycle count)
    crc_ok = all(re.search(rf"\[0\]{k}\s*: 0x{v}", text) for k, v in
                 (("crclist", "e714"), ("crcmatrix", "1fd7"), ("crcstate", "8e3a")))
    if not m or not crc_ok or "should be" in text:
        print(f"coremark: FAILED, see {log}")
        return 1
    ver = subprocess.run(["riscv-none-elf-gcc", "-dumpversion"], capture_output=True, text=True).stdout.strip()
    flags = re.search(r"Compiler flags\s*:\s*(.*)", text)
    with open(work / "coremark.csv", "w") as f:
        f.write("# EEMBC CoreMark on the LVGL benchmark bench's core (lvgl_bench.py coremark)\n")
        f.write("iterations,cycles,coremark_mhz,flags\n")
        f.write(f"{m.group(1)},{m.group(2)},{m.group(3)},riscv-none-elf-gcc {ver} "
                f"{flags.group(1).strip() if flags else ''}\n")
    print(f"coremark: {m.group(3)} CoreMark/MHz ({m.group(1)} iterations, {m.group(2)} cycles)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmd", choices=["run", "reduce", "tables", "coremark", "frames"])
    ap.add_argument("--iter", type=int, default=10)
    ap.add_argument("--res", default="480x272")
    ap.add_argument("--persona", default="all")
    ap.add_argument("-j", type=int, default=3)
    ap.add_argument("--flush", choices=["direct", "cpu"], default="direct")
    ap.add_argument("--tick", choices=["lockstep", "real"], default="lockstep")
    ap.add_argument("--dump", type=int, default=0)
    ap.add_argument("--limit-ms", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--approx", type=int, default=None)
    ap.add_argument("--profile", action="store_true")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if args.cmd == "tables":
        import lvgl_bench_tables
        sys.exit(lvgl_bench_tables.main(update=args.update, check=args.check))

    if args.cmd == "coremark":
        sys.exit(coremark(args))

    if args.cmd == "frames":
        sys.exit(frames(args))

    personas = PERSONA_ORDER if args.persona == "all" else args.persona.split(",")
    for p in personas:
        persona_params(p)
    if args.cmd == "reduce":
        for p in personas:
            reduce_log(args.res, p, args.tag)
        return

    # The firmware first, one after the other (the builds of one resolution
    # share LVGL's objects), then the models and the simulations in parallel
    for p in personas:
        build_fw(args.res, p, args)
    ok_all = True
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.j)) as ex:
        futs = [ex.submit(simulate, args.res, p, args) for p in personas]
        for fu in futs:
            ok, msg = fu.result()
            ok_all &= ok
            print(msg, flush=True)
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
