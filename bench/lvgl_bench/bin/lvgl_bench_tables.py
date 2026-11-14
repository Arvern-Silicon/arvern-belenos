#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    lvgl_bench_tables.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : lvgl_bench_tables.py
# Module Description : The LVGL benchmark tables of doc/performance.md, from
#                      the per-scene results of the bench
#                      (results/<W>x<H>/<persona>.csv, lvgl_bench.py).
#----------------------------------------------------------------------------
"""Generate the LVGL benchmark tables of doc/performance.md.

    python3 bench/lvgl_bench/bin/lvgl_bench_tables.py            # print them
    python3 bench/lvgl_bench/bin/lvgl_bench_tables.py --update   # rewrite the blocks
    python3 bench/lvgl_bench/bin/lvgl_bench_tables.py --check    # exit 1 if one is stale

A generated block sits between two marker lines of doc/performance.md:

    <!-- lvgl_bench:begin NAME -->
    ...
    <!-- lvgl_bench:end NAME -->

NAME: headline (every resolution), summary_<W>x<H>, time_<W>x<H>, cycles_<W>x<H>, gpu_<W>x<H> for each
resolution with results, flush_<W>x<H> where the software baseline was also
run with the CPU flush (light_cpu.csv: lvgl_bench.py run --persona light
--flush cpu --tag cpu), frames_<W>x<H> (the dumped frames against light's:
results/<W>x<H>/frames.csv, lvgl_bench.py frames), profile_<W>x<H> (the CPU
profiles: <persona>_profile.csv, lvgl_bench.py run --profile).
A resolution without results leaves its blocks as they are.
"""
import csv
import re
import sys
from pathlib import Path

HERE  = Path(__file__).resolve().parent
BENCH = HERE.parent
ROOT  = BENCH.parent.parent
RES   = BENCH / "results"
DOC   = ROOT / "doc" / "performance.md"

sys.path.insert(0, str(ROOT / "sim" / "rtl_sim" / "bin"))
from rtl_configs import PERSONAS            # noqa: E402

CLK_HZ   = 111e6
BASE     = "light"                          # the software baseline
INLINE   = set()                            # blocks inside a table cell (none today)
ORDER    = [p for p, _ in PERSONAS]


def load(res):
    """{persona: (rows, comment lines)} of one resolution"""
    out = {}
    for p in ORDER:
        f = RES / res / f"{p}.csv"
        if not f.exists():
            continue
        lines = f.read_text().splitlines()
        notes = [l[2:] for l in lines if l.startswith("# ")]
        rows  = list(csv.DictReader([l for l in lines if not l.startswith("#")]))
        for r in rows:
            for k in r:
                if k != "name":
                    r[k] = float(r[k])
        out[p] = (rows, notes)
    return out


def frame(r):
    return r["render"] + r["flush"]


def ms(c):
    return c / CLK_HZ * 1e3


def fmt_ms(c):
    v = ms(c)
    return f"{v:.2f}" if v < 10 else f"{v:.1f}"


def kcyc(c):
    return f"{c / 1e3:,.0f}".replace(",", " ")


def pct(x):
    return f"{100 * x:.0f} %"


def share(r):
    w = r["gpu_wr"] + r["win_wr"]
    return r["gpu_wr"] / w if w else 0.0


def avg(rows, fn):
    rows = [r for r in rows if r["frames"] > 0]
    return sum(fn(r) for r in rows) / len(rows) if rows else 0.0


def head(personas):
    return ("| Scene | " + " | ".join(f"**{p}**" for p in personas) + " |\n" +
            "|---|" + "---:|" * len(personas) + "\n")


def t_summary(data):
    ps = [p for p in ORDER if p in data]
    base = data.get(BASE)
    out = ("| Persona | Time per frame, ms | Frame rate, FPS | Cycles per frame, k | Speed-up | "
           "Frame-buffer writes by the GPU | GPU busy |\n|---|---:|---:|---:|---:|---:|---:|\n")
    for p in ps:
        rows = data[p][0]
        t = avg(rows, frame)
        sp = (avg(base[0], frame) / t) if base and t else 0
        fps = avg(rows, lambda r: CLK_HZ / frame(r))
        busy = avg(rows, lambda r: r["gpu_busy"] / frame(r))
        out += (f"| **{p}** | {fmt_ms(t)} | {fps:.0f} | {kcyc(t)} | "
                f"{'—' if p == BASE else f'× {sp:.2f}'} | {pct(avg(rows, share))} | {pct(busy)} |\n")
    return out


def t_time(data):
    ps = [p for p in ORDER if p in data]
    base = {r["name"]: r for r in data[BASE][0]} if BASE in data else {}
    out = head(ps)
    names = [r["name"] for r in data[ps[0]][0]]
    for n in names + ["All scenes avg."]:
        cells = []
        for p in ps:
            rows = data[p][0]
            if n == "All scenes avg.":
                t = avg(rows, frame)
                tb = avg(base.values(), frame) if base else 0
            else:
                r = next(r for r in rows if r["name"] == n)
                t = frame(r)
                tb = frame(base[n]) if n in base else 0
            c = fmt_ms(t)
            if p != BASE and tb and t:
                c += f" (× {tb / t:.2f})"
            cells.append(c)
        label = f"**{n}**" if n == "All scenes avg." else n
        out += f"| {label} | " + " | ".join(cells) + " |\n"
    return out


def t_cycles(data):
    ps = [p for p in ORDER if p in data]
    out = ("| Scene | Frames | Invalidated pixels | " + " | ".join(f"**{p}**" for p in ps) + " |\n" +
           "|---|---:|---:|" + "---:|" * len(ps) + "\n")
    first = data[ps[0]][0]
    for i, r0 in enumerate(first):
        cells = [kcyc(frame(data[p][0][i])) for p in ps]
        out += f"| {r0['name']} | {r0['frames']:.0f} | {r0['px']:,.0f} | ".replace(",", " ") + " | ".join(cells) + " |\n"
    return out


def t_gpu(data):
    ps = [p for p in ORDER if p in data and p != BASE]
    out = ("| Scene | " + " | ".join(f"**{p}**" for p in ps) + " | Refresh, share of the VRAM cycles |\n" +
           "|---|" + "---:|" * len(ps) + "---:|\n")
    first = data[ps[0]][0]
    for i, r0 in enumerate(first):
        cells = [f"{pct(share(data[p][0][i]))} / {pct(data[p][0][i]['gpu_busy'] / frame(data[p][0][i]))}"
                 for p in ps]
        bk = data[BASE][0][i] if BASE in data else r0
        out += f"| {r0['name']} | " + " | ".join(cells) + f" | {pct(bk['bk'] / max(1, frame(bk)))} |\n"
    return out


def t_flush(res, data):
    """The software baseline with the CPU flush (light_cpu.csv) against DIRECT"""
    f = RES / res / f"{BASE}_cpu.csv"
    if BASE not in data or not f.exists():
        return None
    lines = f.read_text().splitlines()
    cpu = list(csv.DictReader([l for l in lines if not l.startswith("#")]))
    for r in cpu:
        for k in r:
            if k != "name":
                r[k] = float(r[k])
    d = data[BASE][0]
    out = ("| Scene | DIRECT, ms | CPU flush, ms (render + flush) | CPU flush / DIRECT |\n"
           "|---|---:|---:|---:|\n")
    for a, b in zip(d, cpu):
        out += (f"| {a['name']} | {fmt_ms(frame(a))} | {fmt_ms(frame(b))} ({fmt_ms(b['render'])} + "
                f"{fmt_ms(b['flush'])}) | {frame(b) / frame(a):.2f} |\n")
    ta, tb = avg(d, frame), avg(cpu, frame)
    out += f"| **All scenes avg.** | {fmt_ms(ta)} | {fmt_ms(tb)} | {tb / ta:.2f} |\n"
    return out


def t_frames(res, data):
    """Per scene: the pixels of the dumped frame that differ from light's, and
    the largest difference per RGB565 field"""
    f = RES / res / "frames.csv"
    if not f.exists():
        return None
    rows = list(csv.DictReader([l for l in f.read_text().splitlines() if not l.startswith("#")]))
    ps = [p for p in ORDER if p != BASE and any(r["persona"] == p for r in rows)]
    names = {int(r["scene"]): r["name"] for r in (data[BASE][0] if BASE in data else [])}
    out = head(ps)
    for sc in sorted({int(r["scene"]) for r in rows}):
        cells = []
        for p in ps:
            r = next((r for r in rows if r["persona"] == p and int(r["scene"]) == sc), None)
            if not r:
                cells.append("—")
            elif int(r["differ"]) == 0:
                cells.append("0")
            else:
                cells.append(f"{int(r['differ']):,} ({r['max_r']}, {r['max_g']}, {r['max_b']})".replace(",", " ", 1))
        out += f"| {names.get(sc, sc)} | " + " | ".join(cells) + " |\n"
    return out


def drv_functions():
    """The functions of the Belenos driver and its LVGL glue (sw/src, sw/lvgl)"""
    names = set()
    for f in list((ROOT / "sw" / "src").glob("*.c")) + [ROOT / "sw" / "lvgl" / "lv_belenos.c"]:
        for m in re.finditer(r"^[A-Za-z_][\w \*]*?\b(\w+)\s*\([^;]*$", f.read_text(), re.M):
            names.add(m.group(1))
    return names


def category(fn, drv):
    base = fn.split(".")[0]
    if base in drv:
        return "drv"
    if re.match(r"(lv_draw_sw_|sw_|lv_draw_mask|circ_|lv_font_get_bitmap|lv_color_|rgb565_|argb8888_|"
                r"lv_draw_buf_clear|blend_|transform_)", base):
        return "sw"
    if re.match(r"(lv_text_|lv_font_|get_glyph_dsc|lv_draw_label|lv_draw_unit_draw_letter|lv_bidi|draw_letter)", base):
        return "text"
    return "lvgl"


CATS = [("sw", "LVGL's software renderer (blends, masks, transforms, glyph bitmaps)"),
        ("text", "text layout and glyph look-up (LVGL)"),
        ("lvgl", "the rest of LVGL (objects, styles, events, layout, draw tasks, memory)"),
        ("drv", "the Belenos driver and its draw unit")]


def t_profile(res):
    """Where the CPU's cycles go over the whole run, per profiled persona
    (<persona>_profile.csv), in four groups of functions"""
    drv = drv_functions()
    profs = {}
    for p in ORDER:
        f = RES / res / f"{p}_profile.csv"
        if f.exists():
            acc = {}
            for r in csv.DictReader([l for l in f.read_text().splitlines() if not l.startswith("#")]):
                acc[r["function"]] = acc.get(r["function"], 0) + int(r["cycles"])
            profs[p] = acc
    if not profs:
        return None
    ps = list(profs)
    base = sum(profs[BASE].values()) if BASE in profs else 0
    out = ("| CPU cycles of the run | " + " | ".join(f"**{p}**" for p in ps) + " |\n|---|" +
           "---:|" * len(ps) + "\n")
    for key, label in CATS + [("other", "functions below 0.2 % of a scene each")]:
        cells = []
        for p in ps:
            n = sum(v for fn, v in profs[p].items()
                    if (key == "other" and fn == "(other)") or (key != "other" and fn != "(other)" and
                                                                category(fn, drv) == key))
            cells.append(f"{n / 1e6:,.0f} M ({100 * n / sum(profs[p].values()):.0f} %)".replace(",", " "))
        out += f"| {label} | " + " | ".join(cells) + " |\n"
    cells = [f"{sum(profs[p].values()) / 1e6:,.0f} M".replace(",", " ") +
             (f" (× {base / sum(profs[p].values()):.2f})" if base and p != BASE else "") for p in ps]
    out += "| **total** | " + " | ".join(cells) + " |\n"
    top = []
    for p in ps:
        acc = {fn: v for fn, v in profs[p].items() if fn != "(other)"}
        tot = sum(profs[p].values())
        top.append(", ".join(f"`{fn}` {100 * v / tot:.0f} %" for fn, v in sorted(acc.items(), key=lambda kv: -kv[1])[:5]))
    out += "| largest functions | " + " | ".join(top) + " |\n"
    return out


def t_headline():
    """All scenes avg. per persona and resolution, with the speed-up"""
    rows = []
    for d in sorted(RES.glob("*x*"), key=lambda d: int(d.name.split("x")[0])) if RES.exists() else []:
        data = load(d.name)
        if not data:
            continue
        tb = avg(data[BASE][0], frame) if BASE in data else 0
        cells = []
        for p in ORDER:
            if p not in data:
                cells.append("—")
                continue
            t = avg(data[p][0], frame)
            cells.append(fmt_ms(t) + (f" (× {tb / t:.2f})" if p != BASE and tb else ""))
        w, h = d.name.split("x")
        rows.append(f"| All scenes avg., ms per frame at 111 MHz, {w} × {h} | " + " | ".join(cells) + " |")
    if not rows:
        return None
    return ("| | " + " | ".join(f"`{p}`" for p in ORDER) + " |\n|---|" + "---:|" * len(ORDER) + "\n" +
            "\n".join(rows) + "\n")


def blocks():
    out = {}
    hl = t_headline()
    if hl:
        out["headline"] = hl
    for d in sorted(RES.glob("*x*")) if RES.exists() else []:
        data = load(d.name)
        if not data:
            continue
        out[f"summary_{d.name}"] = t_summary(data)
        out[f"time_{d.name}"]    = t_time(data)
        out[f"cycles_{d.name}"]  = t_cycles(data)
        if any(p != BASE for p in data):
            out[f"gpu_{d.name}"] = t_gpu(data)
        fl = t_flush(d.name, data)
        if fl:
            out[f"flush_{d.name}"] = fl
        fr = t_frames(d.name, data)
        if fr:
            out[f"frames_{d.name}"] = fr
        pr = t_profile(d.name)
        if pr:
            out[f"profile_{d.name}"] = pr
    return out


def main(update=False, check=False):
    bl = blocks()
    if not (update or check):
        for k, v in bl.items():
            print(f"== {k}\n{v}")
        return 0
    text = DOC.read_text()
    new = text
    for k, v in bl.items():
        pat = re.compile(rf"(<!-- lvgl_bench:begin {re.escape(k)} -->\n)(.*?)(<!-- lvgl_bench:end {re.escape(k)} -->)",
                         re.S)
        if not (pat.search(new) or (k in INLINE and f"lvgl_bench:begin {k} -->" in new)):
            print(f"lvgl_bench_tables: no block {k} in {DOC.name}")
            continue
        if k in INLINE:                     # a block inside a table cell: one line
            pat = re.compile(rf"(<!-- lvgl_bench:begin {re.escape(k)} -->)(.*?)(<!-- lvgl_bench:end {re.escape(k)} -->)")
            new = pat.sub(lambda m: m.group(1) + v + m.group(3), new)
        else:
            new = pat.sub(lambda m: m.group(1) + "\n" + v + "\n" + m.group(3), new)
    if check:
        if new != text:
            print(f"lvgl_bench_tables: {DOC.name} is stale (run with --update)")
            return 1
        return 0
    if new != text:
        DOC.write_text(new)
        print(f"lvgl_bench_tables: {DOC.name} updated")
    return 0


if __name__ == "__main__":
    sys.exit(main(update="--update" in sys.argv, check="--check" in sys.argv))
