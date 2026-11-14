#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Module:    slipstream_summary.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : slipstream_summary.py
# Module Description : Summary and consistency check of a slipstream.log GPU
#                      trace: primitives per kind (cycles, pixels, cycles per
#                      pixel, VRAM accesses, refused cycles), the slowest
#                      primitives, errors. Checks that every primitive id is
#                      opened by one EXEC and closed by exactly one END, and,
#                      with --perf <simulation log>, that the traced accesses
#                      add up to the bench PERF: line.
#----------------------------------------------------------------------------
"""Summarise and check a Belenos slipstream.log.

    slipstream_summary.py [slipstream.log] [--perf sim.log] [--top N] [--quiet]

Exit status 1 when a check fails.
"""
import argparse
import re
import sys
from collections import OrderedDict, defaultdict

ROW = re.compile(r'^\s*(\d+)\s{2}(CMD|GO |END|LST|ERR|CTL|PSH|FRM|BSY|IDL|WAI)(?:\s{2}(.*))?$')
EXEC = re.compile(r'\bEXEC_\w+\s+#(\d+)')
GO = re.compile(r'^#(\d+)\s+(\w+)\s+(\d+)x(\d+)\s+setup=(\d+)')
END = re.compile(r'^#(\d+)\s+(\w+)\s+(\w+)\s+total=(\d+)'
                 r'(?:\s+draw=(\d+)\s+px=(\d+)\s+rd=(\d+)\s+wr=(\d+)\s+wait=(\d+))?')
PSH = re.compile(r'^w=(\d+)\s+[0-9a-f]{8}\s+(?:used=\d+|DROP)')
LST = re.compile(r'^(\w+)\s+words=(\d+)\s+rd=(\d+)')
PERF = re.compile(r'PERF:.*\bgpu_rd=(\d+)\s+gpu_wr=(\d+)')


def parse(path):
    rows = []
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            m = ROW.match(line.rstrip('\n'))
            if not m:
                rows.append((n, None, None, line.rstrip('\n')))
                continue
            rows.append((n, int(m.group(1)), m.group(2).strip(), m.group(3) or ''))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('trace', nargs='?', default='slipstream.log')
    ap.add_argument('--perf', help='simulation log holding the bench PERF: line')
    ap.add_argument('--top', type=int, default=5, help='slowest primitives listed (default 5)')
    ap.add_argument('--quiet', action='store_true', help='checks only')
    args = ap.parse_args()

    rows = parse(args.trace)
    errors = []
    prims = OrderedDict()                   # id -> dict
    lists = []
    errs = []
    ctl = defaultdict(int)
    ncmd = 0
    npsh = ndrop = nfrm = 0
    busy = 0
    busy_since = None
    wait = nwait = 0
    wait_since = None
    last_cyc = 0

    for n, cyc, tag, text in rows:
        if tag is None:
            errors.append(f'line {n}: unparsed row: {text}')
            continue
        last_cyc = cyc
        if tag == 'PSH':
            m = PSH.match(text)
            if not m:
                errors.append(f'line {n}: malformed PSH row: {text}')
                continue
            if int(m.group(1)) != npsh + ndrop:
                errors.append(f'line {n}: PSH w={m.group(1)}, expected w={npsh + ndrop}')
            if 'DROP' in text:
                ndrop += 1
            else:
                npsh += 1
        elif tag == 'BSY':
            busy_since = cyc
        elif tag == 'IDL':
            if busy_since is not None:
                busy += cyc - busy_since
            busy_since = None
        elif tag == 'WAI':
            if text.startswith('start'):
                if wait_since is not None:
                    errors.append(f'line {n}: WAI start while already waiting')
                wait_since = cyc
                nwait += 1
            elif text in ('end  frame', 'end  flush'):
                if wait_since is None:
                    errors.append(f'line {n}: WAI end without a start')
                else:
                    wait += cyc - wait_since
                wait_since = None
            else:
                errors.append(f'line {n}: malformed WAI row: {text}')
        elif tag == 'FRM':
            nfrm += text.startswith('start')
        elif tag == 'CMD':
            ncmd += 1
            m = EXEC.search(text)
            if m and '(cut' not in text:
                pid = int(m.group(1))
                if pid in prims:
                    errors.append(f'line {n}: id #{pid} decoded twice')
                prims[pid] = dict(exec_cyc=cyc, go=None, end=None, line=n)
        elif tag == 'GO':
            m = GO.match(text)
            if not m:
                errors.append(f'line {n}: malformed {tag} row: {text}')
                continue
            pid = int(m.group(1))
            p = prims.get(pid)
            if p is None:
                errors.append(f'line {n}: GO #{pid} without its EXEC')
                continue
            if p['go'] is not None or p['end'] is not None:
                errors.append(f'line {n}: GO #{pid} after its GO or END')
            p['go'] = dict(cyc=cyc, kind=m.group(2), w=int(m.group(3)), h=int(m.group(4)),
                           setup=int(m.group(5)))
        elif tag == 'END':
            m = END.match(text)
            if not m:
                errors.append(f'line {n}: malformed {tag} row: {text}')
                continue
            pid = int(m.group(1))
            p = prims.get(pid)
            if p is None:
                errors.append(f'line {n}: END #{pid} without its EXEC')
                continue
            if p['end'] is not None:
                errors.append(f'line {n}: END #{pid} twice')
            how = m.group(3)
            if how == 'lost':
                errors.append(f'line {n}: #{pid} lost (a stage taken over before it ended)')
            e = dict(cyc=cyc, kind=m.group(2), how=how, total=int(m.group(4)))
            if m.group(5) is not None:
                e.update(draw=int(m.group(5)), px=int(m.group(6)), rd=int(m.group(7)),
                         wr=int(m.group(8)), wait=int(m.group(9)))
                if p['go'] is None:
                    errors.append(f'line {n}: #{pid} drew without a GO')
            p['end'] = e
        elif tag == 'LST':
            m = LST.match(text)
            if not m:
                errors.append(f'line {n}: malformed {tag} row: {text}')
                continue
            lists.append(dict(cyc=cyc, how=m.group(1), words=int(m.group(2)), rd=int(m.group(3))))
        elif tag == 'ERR':
            errs.append((cyc, text))
        elif tag == 'CTL':
            ctl[text.split()[0]] += 1

    open_ids = [pid for pid, p in prims.items() if p['end'] is None]
    # The last primitive may still be running when the simulation ends
    for pid in open_ids[:-1] if open_ids and open_ids[-1] == next(reversed(prims)) else open_ids:
        errors.append(f'#{pid} (line {prims[pid]["line"]}) never ended')

    # Per kind
    kinds = OrderedDict()
    tot_rd = tot_wr = 0
    for pid, p in prims.items():
        e = p['end']
        if e is None:
            continue
        k = kinds.setdefault(e['kind'], defaultdict(int))
        k['n'] += 1
        k[e['how']] += 1
        if 'draw' in e:
            for f in ('draw', 'px', 'rd', 'wr', 'wait'):
                k[f] += e[f]
            tot_rd += e['rd']
            tot_wr += e['wr']
        if p['go'] is not None:
            k['setup'] += p['go']['setup']
    list_rd = sum(lst['rd'] for lst in lists)

    if args.perf:
        perf = None
        with open(args.perf, errors='replace') as fh:
            for line in fh:
                m = PERF.search(line)
                if m:
                    perf = (int(m.group(1)), int(m.group(2)))
        if perf is None:
            errors.append(f'{args.perf}: no PERF: line')
        elif open_ids:
            pass                                # a primitive still drawing: totals not final
        elif (tot_rd + list_rd, tot_wr) != perf:
            msg = (f'traced rd={tot_rd}+{list_rd} wr={tot_wr}, PERF gpu_rd={perf[0]} gpu_wr={perf[1]}')
            errors.append(msg)

    if not args.quiet:
        if busy_since is not None:
            busy += last_cyc - busy_since
        if wait_since is not None:
            wait += last_cyc - wait_since
        print(f'{args.trace}: {npsh} words pushed ({ndrop} dropped), {nfrm} frames, '
              f'GPU busy {busy} cycles' + (f', {wait} of them waiting for a frame end ({nwait} waits)' if nwait else ''))
        print(f'  {ncmd} commands, {len(prims)} primitives, {len(lists)} lists, '
              f'{len(errs)} errors' + ''.join(f', {v} {k}' for k, v in ctl.items() if k != 'GPU_EN=1'))
        if kinds:
            print(f'  {"kind":8} {"n":>6} {"empty":>6} {"abandon":>7} {"setup":>8} {"draw":>9} '
                  f'{"px":>9} {"cyc/px":>7} {"rd":>8} {"wr":>8} {"wait":>7}')
            for kind, k in kinds.items():
                cpp = f'{k["draw"] / k["px"]:.2f}' if k['px'] else '-'
                print(f'  {kind:8} {k["n"]:6} {k["empty"]:6} {k["abort"] + k["bound"] + k["drop"]:7} '
                      f'{k["setup"]:8} {k["draw"]:9} {k["px"]:9} {cpp:>7} {k["rd"]:8} {k["wr"]:8} {k["wait"]:7}')
        if lists:
            print(f'  lists: {len(lists)}, {sum(lst["words"] for lst in lists)} words, {list_rd} reads')
        drawn = [(pid, p) for pid, p in prims.items() if p['end'] and 'draw' in p['end']]
        drawn.sort(key=lambda x: -x[1]['end']['total'])
        if drawn and args.top:
            print(f'  slowest:')
            for pid, p in drawn[:args.top]:
                e, g = p['end'], p['go']
                print(f'    #{pid:<6} {e["kind"]:8} {g["w"]}x{g["h"]:<6} total={e["total"]:<7} '
                      f'px={e["px"]:<7} rd={e["rd"]:<6} wr={e["wr"]:<6} wait={e["wait"]:<5} '
                      f'(EXEC at cycle {p["exec_cyc"]})')
        for cyc, text in errs:
            print(f'  ERR at {cyc}: {text}')

    for e in errors[:20]:
        print(f'CHECK FAILED: {e}')
    if len(errors) > 20:
        print(f'CHECK FAILED: ... {len(errors) - 20} more')
    if not errors and not args.quiet:
        print('  checks: OK')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
