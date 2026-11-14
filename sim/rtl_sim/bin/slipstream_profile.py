#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    slipstream_profile.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : slipstream_profile.py
# Module Description : CPU + GPU profile of a SoC simulation: fuses the CPU
#                      trace (asphalt.log), the GPU trace (slipstream.log, same
#                      cycle basis) and the firmware symbols. Every GPU_CMD
#                      store is matched to the word it pushed (w), so each
#                      command, and the primitive it starts, is charged to the
#                      function that issued it (a command-list word to the
#                      function that pushed its CALL).
#----------------------------------------------------------------------------
"""CPU + GPU profile from asphalt.log + slipstream.log + the firmware ELF.

    slipstream_profile.py --asphalt asphalt.log --slipstream slipstream.log --elf fw.elf
                          [--blns-base 0x10050000] [--vram-base 0x82000000 --vram-size N]
                          [--from C] [--to C] [--frames | --marks] [--top N] [--mhz F]
                          [--annotate FUNCTION] [--lines]

Per function: CPU cycles, GPU words pushed, primitives started, the GPU drawing
cycles and pixels they cost, Belenos register reads (status polling) and VRAM
window accesses. Per display frame (--frames) or per interval between the
firmware's trace markers ("# mark <n>" rows, --marks): length, GPU busy share,
work done, the busiest functions. --annotate: every instruction of a function
with its count, cycles and source line; --lines: CPU cycles per source line.
The cycle window [--from, --to) applies to both traces. Loops collapsed in
asphalt.log ("# repeat:" rows) are counted in full.
"""
import argparse
import bisect
import heapq
import re
import shutil
import subprocess
import sys
from collections import defaultdict

# asphalt.log fixed columns (probes_instructions.v formats); fallback: split on 2+ spaces
SPLIT2 = re.compile(r'\s{2,}')
NOTE_MARK = re.compile(r'^# mark (\d+)')
NOTE_REP = re.compile(r'^# repeat: (\d+) lines left out \(loop of (\d+) lines at 0x([0-9a-f]+)\), cycles (\d+)\.\.(\d+)')
# Calls write ra; returns jump to ra (RVC and Zcmp forms included)
CALL = re.compile(r'^(JALR? x1,|C\.JALR? |CM\.JALT )')
RET = re.compile(r'^(JALR x0,0\(x1\)|C\.JR x1\b|CM\.POPRETZ? )')
TRAP = re.compile(r'\s(EXC:\S+|IRQ:\S+|NMI)\s')
XRET = re.compile(r'^(MRET|SRET|MNRET)\b')


def flow(mnem, line):
    """'C' call, 'R' return, 'X' xRET, plus 'T' when the row is a trap handler's entry."""
    k = 'C' if CALL.match(mnem) else 'R' if RET.match(mnem) else 'X' if XRET.match(mnem) else ''
    if ('EXC:' in line or 'IRQ:' in line or 'NMI' in line) and TRAP.search(line):
        k += 'T'
    return k

SS_ROW = re.compile(r'^\s*(\d+)\s{2}(CMD|GO |END|LST|ERR|CTL|PSH|FRM|BSY|IDL|WAI)(?:\s{2}(.*))?$')
SS_PSH = re.compile(r'^w=(\d+)\s+([0-9a-fA-F]{8})\s+(used=\d+|DROP)')
SS_CMD = re.compile(r'^(FIFO|L:0x[0-9a-f]+)\s+w=(\d+)\s+q=(\S+)\s+([0-9a-f]{8})(?:\s([0-9a-f]{8}))?\s+(\S+)(.*)$')
SS_ID = re.compile(r'#(\d+)')
SS_GO = re.compile(r'^#(\d+)\s+(\w+)\s+(\d+)x(\d+)\s+setup=(\d+)')
SS_END = re.compile(r'^#(\d+)\s+(\w+)\s+(\w+)\s+total=(\d+)(?:\s+draw=(\d+)\s+px=(\d+)\s+rd=(\d+)\s+wr=(\d+)\s+wait=(\d+))?')


def symbols(elf, nm):
    out = subprocess.run([nm, '-n', '--defined-only', elf], capture_output=True, text=True, check=True).stdout
    addrs, names = [], []
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3 and f[1] in 'tTwW':
            addrs.append(int(f[0], 16))
            names.append(f[2])
    return addrs, names


def asphalt_rows(path, lo, hi):
    """(cycle, pc, mem, addr, data, flow) in cycle order (rows are written at completion:
    a short reorder window restores dispatch order). Notes come as rows too: a marker
    (cycle of its store, '~mark', n) and a collapsed loop (last cycle, '~rep', lines,
    loop length)."""
    heap = []
    last = 0
    with open(path, errors='replace') as fh:
        for line in fh:
            if not line or not line.strip():
                continue
            if line[0] == '#':
                m = NOTE_MARK.match(line)
                if m and last >= lo:
                    heapq.heappush(heap, (last, '~mark', int(m.group(1)), 0, '', ''))
                r = NOTE_REP.match(line)
                if r and int(r.group(5)) >= lo:
                    heapq.heappush(heap, (int(r.group(5)), '~rep', int(r.group(1)), int(r.group(2)), '', ''))
                continue
            if line[28:30] == '0x' and line[86:87] in 'RW-':
                try:
                    cyc = int(line[0:12])
                except ValueError:
                    continue
                pc, mem, addr, data = line[28:38], line[86:87], line[92:102], line[104:114]
                fl = flow(line[52:84], line)
            else:
                f = SPLIT2.split(line.strip())
                if len(f) < 8 or not f[0].isdigit():
                    continue
                cyc, pc, mem, addr, data = int(f[0]), f[2], f[5][:1], f[6], f[7]
                fl = flow(f[4], line)
            last = cyc
            if cyc < lo:
                continue
            heapq.heappush(heap, (cyc, pc, mem, addr, data, fl))
            if len(heap) > 256:
                r = heapq.heappop(heap)
                if r[0] >= hi:
                    break
                yield r
    while heap:
        r = heapq.heappop(heap)
        if r[0] < hi:
            yield r


def read_slipstream(path, lo, hi):
    push = {}                       # w -> (cycle, word, dropped)
    prims = {}                      # id -> dict
    busy, frames, waits = [], [], []
    bsy = wts = None
    last = 0
    with open(path) as fh:
        for line in fh:
            if line.startswith('#'):
                continue
            m = SS_ROW.match(line.rstrip('\n'))
            if not m:
                continue
            cyc, tag, text = int(m.group(1)), m.group(2).strip(), m.group(3) or ''
            last = cyc
            if tag == 'PSH':
                p = SS_PSH.match(text)
                if p:
                    push[int(p.group(1))] = (cyc, int(p.group(2), 16), p.group(3) == 'DROP')
            elif tag == 'CMD':
                c = SS_CMD.match(text)
                if c and c.group(6).startswith('EXEC_') and '(cut' not in text:
                    i = SS_ID.search(c.group(7))
                    if i:
                        prims[int(i.group(1))] = dict(w=int(c.group(2)), exec=cyc, kind=c.group(6),
                                                      lst=c.group(1) != 'FIFO')
            elif tag == 'GO':
                g = SS_GO.match(text)
                if g and int(g.group(1)) in prims:
                    prims[int(g.group(1))].update(go=cyc, setup=int(g.group(5)))
            elif tag == 'END':
                e = SS_END.match(text)
                if e and int(e.group(1)) in prims:
                    p = prims[int(e.group(1))]
                    p.update(end=cyc, how=e.group(3), kind=e.group(2))
                    if e.group(5) is not None:
                        p.update(draw=int(e.group(5)), px=int(e.group(6)), rd=int(e.group(7)),
                                 wr=int(e.group(8)), wait=int(e.group(9)))
            elif tag == 'WAI':
                if text.startswith('start'):
                    wts = cyc
                elif wts is not None:
                    waits.append((wts, cyc))
                    wts = None
            elif tag == 'BSY':
                bsy = cyc
            elif tag == 'IDL':
                if bsy is not None:
                    busy.append((bsy, cyc))
                bsy = None
            elif tag == 'FRM' and text.startswith('start'):
                frames.append(cyc)
    if bsy is not None:
        busy.append((bsy, last))
    if wts is not None:
        waits.append((wts, last))
    # Window
    prims = {k: v for k, v in prims.items() if lo <= v['exec'] < hi}
    busy = [(max(a, lo), min(b, hi)) for a, b in busy if b > lo and a < hi]
    waits = [(max(a, lo), min(b, hi)) for a, b in waits if b > lo and a < hi]
    return push, prims, busy, waits, frames, last


def src_lines(elf, nm, pcs):
    """pc -> 'file:line' (addr2line next to nm)."""
    tool = nm[:-2] + 'addr2line' if nm.endswith('nm') else 'addr2line'
    pcs = sorted(pcs)
    out = subprocess.run([tool, '-e', elf], input='\n'.join(f'{p:x}' for p in pcs),
                         capture_output=True, text=True).stdout.splitlines()
    res = {}
    for p, l in zip(pcs, out):
        l = l.split(' (')[0]
        res[p] = l.rsplit('/', 1)[-1] if l and not l.startswith('??') else '?'
    return res


def disasm(elf, nm, lo, hi):
    """pc -> instruction text, for [lo, hi)."""
    tool = nm[:-2] + 'objdump' if nm.endswith('nm') else 'objdump'
    out = subprocess.run([tool, '-d', '--no-show-raw-insn', f'--start-address=0x{lo:x}',
                          f'--stop-address=0x{hi:x}', elf], capture_output=True, text=True).stdout
    res = {}
    for line in out.splitlines():
        m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', line)
        if m:
            res[int(m.group(1), 16)] = ' '.join(m.group(2).split())
    return res


def overlap(intervals, a, b):
    return sum(max(0, min(y, b) - max(x, a)) for x, y in intervals)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--asphalt', default='asphalt.log')
    ap.add_argument('--slipstream', default='slipstream.log')
    ap.add_argument('--elf', required=True)
    ap.add_argument('--nm', help='nm binary (default: riscv-none-elf-nm on the PATH)')
    ap.add_argument('--blns-base', type=lambda x: int(x, 0), default=0x10050000,
                    help='Belenos register port base (default 0x10050000, GPU_CMD = base + 0x100)')
    ap.add_argument('--vram-base', type=lambda x: int(x, 0), default=0x82000000)
    ap.add_argument('--vram-size', type=lambda x: int(x, 0), default=0x01000000)
    ap.add_argument('--from', dest='lo', type=int, default=0, help='first cycle')
    ap.add_argument('--to', dest='hi', type=int, default=1 << 62, help='end cycle (excluded)')
    ap.add_argument('--frames', action='store_true', help='per display frame table')
    ap.add_argument('--marks', action='store_true', help='per interval between trace markers')
    ap.add_argument('--annotate', metavar='FUNCTION', help='per-instruction profile of a function')
    ap.add_argument('--lines', action='store_true', help='CPU cycles per source line')
    ap.add_argument('--top', type=int, default=15, help='functions listed (default 15)')
    ap.add_argument('--mhz', type=float, default=50.0, help='clock for the time column (default 50)')
    args = ap.parse_args()

    nm = args.nm or shutil.which('riscv-none-elf-nm') or shutil.which('riscv64-unknown-elf-nm')
    if not nm:
        sys.exit('slipstream_profile.py: no riscv nm found (--nm)')
    addrs, names = symbols(args.elf, nm)

    def func(pc):
        i = bisect.bisect_right(addrs, pc) - 1
        return names[i] if i >= 0 else '?'

    push, prims, busy, waits, frames, ss_last = read_slipstream(args.slipstream, args.lo, args.hi)
    cmd_addr = args.blns_base + 0x100
    reg_lo, reg_hi = args.blns_base, args.blns_base + 0x1000
    vr_lo, vr_hi = args.vram_base, args.vram_base + args.vram_size

    cpu = defaultdict(int)          # function -> cycles (self)
    acc = defaultdict(int)          # (callers, function) -> cycles
    ninstr = defaultdict(int)
    nreg = defaultdict(int)         # Belenos register reads
    nvram = defaultdict(int)        # VRAM window accesses
    w_key = {}                      # GPU_CMD write number -> (function, callers)
    fr_cpu = defaultdict(lambda: defaultdict(int))
    mismatch = 0
    w = 0
    first = last = None
    prev = None                     # (cycle, function, callers)
    pc_cache = {}
    stack = []                      # shadow call stack: the callers
    depth_max = 0
    ret_empty = 0
    ctx = frozenset()

    pc_n = defaultdict(int)         # per instruction: executions, cycles
    pc_cyc = defaultdict(int)
    recent = []                     # the last 16 rows' pcs (a collapsed loop's iteration)
    marks = []                      # (cycle, marker value)
    w_sync = False

    def frame_of(c):
        return bisect.bisect_right(frames, c) - 1

    # GPU_CMD writes before the window still count for w; a trace started later
    # (asphalt.log window) is aligned on its first GPU_CMD store's PSH row
    for row in asphalt_rows(args.asphalt, 0, args.hi):
        cyc, pcs, mem, addr, data, fl = row
        if pcs == '~mark':
            if cyc >= args.lo:
                marks.append((cyc, mem))
            continue
        if pcs == '~rep':
            n, per = mem, addr
            if cyc >= args.lo and prev is not None:
                it = recent[-per:]
                for i, (q, qf, qr, qv) in enumerate(it):
                    k = n // per + (1 if i < n % per else 0)
                    pc_n[q] += k
                    ninstr[qf] += k
                    nreg[qf] += k * qr
                    nvram[qf] += k * qv
            continue
        f = pc_cache.get(pcs) or pc_cache.setdefault(pcs, func(int(pcs, 16)))
        if 'T' in fl and prev is not None and len(stack) < 256:
            stack.append(prev[1])               # a trap handler "called" from the interrupted function
            ctx = frozenset(stack)
        if mem == 'W' and addr.startswith('0x') and int(addr, 16) == cmd_addr:
            if not w_sync:
                w_sync = True
                dv = int(data, 16) if data.startswith('0x') else None
                cand = [k for k, v in sorted(push.items()) if v[0] >= cyc and (dv is None or v[1] == dv)]
                w = cand[0] if cand else 0
            w_key[w] = (f, ctx)
            if w in push and data.startswith('0x') and int(data, 16) != push[w][1]:
                mismatch += 1
            w += 1
        if cyc >= args.lo:
            if first is None:
                first = cyc
            if prev is not None:
                d = cyc - prev[0]
                cpu[prev[1]] += d
                acc[(prev[2], prev[1])] += d
                pc_cyc[prev[3]] += d
                if args.marks:
                    fr_cpu[prev[4]][prev[1]] += d
                elif frames:
                    fr_cpu[frame_of(prev[0])][prev[1]] += d
            prev = (cyc, f, ctx, pcs, len(marks))
            last = cyc
            ninstr[f] += 1
            pc_n[pcs] += 1
            isr = isv = 0
            if mem in 'RW' and addr.startswith('0x'):
                a = int(addr, 16)
                if mem == 'R' and reg_lo <= a < reg_hi:
                    isr = 1
                elif vr_lo <= a < vr_hi:
                    isv = 1
            nreg[f] += isr
            nvram[f] += isv
            recent.append((pcs, f, isr, isv))
            if len(recent) > 16:
                del recent[0]
        else:
            prev = (cyc, f, ctx, pcs, 0)
        if 'C' in fl and len(stack) < 256:
            stack.append(f)
            ctx = frozenset(stack)
            depth_max = max(depth_max, len(stack))
        elif 'R' in fl or 'X' in fl:
            if stack:
                stack.pop()
                ctx = frozenset(stack)
            else:
                ret_empty += 1
    if first is None:
        sys.exit('slipstream_profile.py: no asphalt row in the window')
    span = last - first
    # slipstream.log may cover more than asphalt.log (a windowed trace)
    prims = {k: v for k, v in prims.items() if first <= v['exec'] <= last}

    incl = defaultdict(int)
    for (callers, f), d in acc.items():
        for g in callers | {f}:
            incl[g] += d

    # GPU work, charged to the pushing function and every caller on its stack
    gw = defaultdict(lambda: defaultdict(int))
    for wn, (f, callers) in w_key.items():
        if wn in push and not push[wn][2] and first <= push[wn][0] <= last:
            for g in callers | {f}:
                gw[g]['words'] += 1
    for p in prims.values():
        f, callers = w_key.get(p['w'], ('?', frozenset()))
        for g in callers | {f}:
            k = gw[g]
            k['prims'] += 1
            k['listed'] += p['lst']
            for fld in ('draw', 'px', 'wait'):
                k[fld] += p.get(fld, 0)

    gwait = overlap(waits, first, last)                 # WAIT_REFR_DONE: busy, but idle
    gbusy = overlap(busy, first, last) - gwait
    gdraw = sum(p.get('draw', 0) for p in prims.values())
    nwr = sum(1 for x in push.values() if first <= x[0] <= last)
    print(f'Window: cycles {first} .. {last} ({span} cycles, {span / args.mhz / 1000:.2f} ms at {args.mhz:g} MHz)')
    print(f'  GPU busy {gbusy} cycles ({100 * gbusy / span:.1f} %), drawing {gdraw} '
          f'({100 * gdraw / span:.1f} %)'
          + (f', waiting for a frame end {gwait} ({100 * gwait / span:.1f} %)' if waits else '')
          + f'; {len(prims)} primitives, {nwr} GPU_CMD writes'
          + (f'; {mismatch} store/push data mismatches' if mismatch else ''))
    nmiss = sum(1 for i in range(w) if i not in push)
    if nmiss:
        print(f'  note: {nmiss} of the {w} GPU_CMD stores in asphalt.log have no PSH row in slipstream.log '
              f'(a trace cut short, or another bus manager writing GPU_CMD)')

    print(f'  call stack: self cycles {sum(cpu.values())} of {span}, deepest {depth_max}, '
          f'{ret_empty} returns with an empty stack, {len(stack)} frames open at the end'
          + ('  (inclusive columns unreliable)' if ret_empty > 2 or depth_max >= 256 else ''))
    print()
    print('  CPU (self: in the function; incl: with its callees)')
    print(f'  {"function":30} {"self cyc":>10} {"self %":>7} {"incl %":>7} {"instr":>9} {"reg rd":>7} {"vram":>7}')
    for f in sorted(cpu, key=lambda x: -cpu[x])[:args.top]:
        print(f'  {f[:30]:30} {cpu[f]:10} {100 * cpu[f] / span:7.1f} {100 * incl[f] / span:7.1f} '
              f'{ninstr[f]:9} {nreg[f]:7} {nvram[f]:7}')

    if gw:
        print()
        print('  GPU work by issuing function (with its callees)')
        print(f'  {"function":30} {"gpu wr":>8} {"prims":>7} {"listed":>7} {"draw":>10} {"draw %":>7} '
              f'{"px":>10} {"cyc/px":>7} {"wait":>7}')
        for f in sorted(gw, key=lambda x: -gw[x]['draw'])[:args.top]:
            k = gw[f]
            cpp = f'{k["draw"] / k["px"]:.2f}' if k['px'] else '-'
            print(f'  {f[:30]:30} {k["words"]:8} {k["prims"]:7} {k["listed"]:7} {k["draw"]:10} '
                  f'{100 * k["draw"] / span:7.1f} {k["px"]:10} {cpp:>7} {k["wait"]:7}')

    # Primitives by kind
    kinds = defaultdict(lambda: defaultdict(int))
    for p in prims.values():
        k = kinds[p['kind']]
        k['n'] += 1
        for fld in ('setup', 'draw', 'px', 'rd', 'wr', 'wait'):
            k[fld] += p.get(fld, 0)
    if kinds:
        print()
        print(f'  {"primitive":10} {"n":>7} {"setup":>9} {"draw":>10} {"px":>10} {"cyc/px":>7} '
              f'{"rd":>8} {"wr":>8} {"wait":>7}')
        for kd, k in sorted(kinds.items(), key=lambda x: -x[1]['draw']):
            cpp = f'{k["draw"] / k["px"]:.2f}' if k['px'] else '-'
            print(f'  {kd:10} {k["n"]:7} {k["setup"]:9} {k["draw"]:10} {k["px"]:10} {cpp:>7} '
                  f'{k["rd"]:8} {k["wr"]:8} {k["wait"]:7}')

    if args.frames or args.marks:
        print()
        starts = [first] + [c for c, _ in marks] if args.marks else frames
        label = ['start'] + [str(n) for _, n in marks] if args.marks else [str(i) for i in range(len(frames))]
        if args.marks and not marks:
            print('  no trace marker in asphalt.log (no "# mark" row)')
        elif not starts:
            print('  no display frame in slipstream.log (no FRM row)')
        else:
            bounds = starts + [last if args.marks else ss_last]
            print(f'  {"mark" if args.marks else "frame":>5} {"start":>11} {"cycles":>9} {"ms":>7} {"gpu busy":>8} {"wait":>6} '
                  f'{"prims":>6} {"px":>9}  top functions (cpu %)')
            for i in range(len(starts)):
                a, b = bounds[i], bounds[i + 1]
                if b <= first or a >= last or b <= a:
                    continue
                n = b - a
                fp = [p for p in prims.values() if a <= p['exec'] < b]
                tops = sorted(fr_cpu[i].items(), key=lambda x: -x[1])[:3]
                tf = ', '.join(f'{f} {100 * c / n:.0f}' for f, c in tops)
                wt = overlap(waits, a, b)
                print(f'  {label[i]:>5} {a:11} {n:9} {n / args.mhz / 1000:7.2f} {100 * (overlap(busy, a, b) - wt) / n:7.1f}% '
                      f'{100 * wt / n:5.1f}% '
                      f'{len(fp):6} {sum(p.get("px", 0) for p in fp):9}  {tf}')
    if args.annotate:
        print()
        if args.annotate not in names:
            print(f'  --annotate: no function {args.annotate} in the ELF')
        else:
            i = names.index(args.annotate)
            lo = addrs[i]
            hi = next((a for a in addrs[i + 1:] if a > lo), lo + 0x10000)
            dis = disasm(args.elf, nm, lo, hi)
            src = src_lines(args.elf, nm, dis.keys())
            tot = sum(pc_cyc[f'0x{p:08x}'] for p in dis)
            print(f'  {args.annotate}: {tot} cycles in the window, per instruction (cycles = until the next one)')
            print(f'  {"pc":>10} {"count":>9} {"cycles":>10} {"%":>6}  {"instruction":34} source')
            for p in sorted(dis):
                k = f'0x{p:08x}'
                n, c = pc_n.get(k, 0), pc_cyc.get(k, 0)
                pct = f'{100 * c / tot:6.1f}' if tot else '     -'
                print(f'  {p:10x} {n:9} {c:10} {pct}  {dis[p][:34]:34} {src.get(p, "")}')

    if args.lines:
        print()
        src = src_lines(args.elf, nm, [int(k, 16) for k in pc_cyc])
        by = defaultdict(lambda: [0, 0, ''])
        for k, c in pc_cyc.items():
            pcv = int(k, 16)
            e = by[src.get(pcv, '?')]
            e[0] += c
            e[1] += pc_n.get(k, 0)
            e[2] = e[2] or func(pcv)
        print(f'  {"source line":36} {"cycles":>10} {"%":>6} {"instr":>9}  function')
        for l, (c, n, fn) in sorted(by.items(), key=lambda x: -x[1][0])[:args.top]:
            print(f'  {l[:36]:36} {c:10} {100 * c / span:6.1f} {n:9}  {fn}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
